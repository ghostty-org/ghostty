---
title: Linear MCP Capability Probe — Findings
date: 2026-04-23
branch: feat/linear-capability-probe
status: diagnostic (read-only; not shipped into the app)
---

# Linear MCP Capability Probe — Findings

## TL;DR

- **Endpoint:** `https://mcp.linear.app/mcp` (legacy `/sse` is deprecated).
- **Transport:** Streamable HTTP (MCP spec `2025-11-25`). Linear also supports stdio indirectly via the `mcp-remote` npm bridge.
- **Auth:** OAuth 2.1 with dynamic client registration **or** `Authorization: Bearer <token>` using a Linear Personal API Key (simplest for a local probe).
- **Our existing client lib only has stdio.** We bridge to Linear via `npx mcp-remote <url> --header "Authorization: Bearer $LINEAR_API_KEY"`, which is a first-party proxy recommended by Anthropic and Cloudflare's MCP guides.
- **Subscriptions:** Documentation does **not** advertise `resources/subscribe`. The probe's job is to confirm this empirically from the `initialize` response.

## 1. Research

### 1.1 Linear's MCP server URL + transport

Linear publishes a hosted MCP server at `https://mcp.linear.app/mcp`. Per the Linear docs and changelog:

> The server supports "Streamable HTTP transports" as the primary method. For backwards compatibility with clients lacking remote MCP support, the `mcp-remote` module enables stdio-based connection.
>
> — <https://linear.app/docs/mcp>

Key points:

- Streamable HTTP is a single unified endpoint (`POST /mcp`) that returns either plain JSON (for request/response) or upgrades to SSE for streaming. See MCP spec §Transports (2025-11-25).
- The legacy `https://mcp.linear.app/sse` endpoint is deprecated; clients should migrate to `/mcp`.
- There is no stdio subprocess option published by Linear — the server is hosted only.

### 1.2 Auth

Linear supports two mechanisms:

1. **OAuth 2.1 with dynamic client registration** — interactive browser flow. Suited for desktop apps that can pop a browser window; not appropriate for a one-shot probe CLI.
2. **`Authorization: Bearer <token>` header** using either:
   - A **Personal API Key** (Linear → Settings → Security & access → Personal API keys → New API key). Simplest. Read-only scopes are possible via restricted keys.
   - An **OAuth developer token** (for app-to-Linear use cases).

For this probe we use option 2 with a Personal API Key read from `LINEAR_API_KEY`.

Sources:

- <https://linear.app/docs/mcp>
- <https://shinzo.ai/blog/how-to-use-linear-mcp-server>
- <https://www.morphllm.com/linear-mcp-server>

### 1.3 What MCP methods does Linear expose?

Linear's docs list high-level capabilities ("finding, creating, and updating issues, projects, and comments") but do not publish a full tool or capabilities manifest. This is exactly why we need the probe — we want the server's own `initialize` response + `tools/list` output to tell us.

Resource primitives (`resources/list`, `resources/subscribe`) are **not mentioned** in Linear's docs. The probe confirms or denies subscription support directly from the server's advertised capabilities.

### 1.4 How do other clients talk to Linear over MCP?

Three dominant approaches in the wild:

1. **Native remote MCP clients** (Claude Desktop, Claude Code, Cursor, the official Anthropic `claude_ai_Linear` integration). These speak Streamable HTTP directly and drive the OAuth flow themselves.
2. **`mcp-remote` stdio bridge** (`npx mcp-remote <url> [--header ...]`). The most widely recommended fallback for clients that only speak stdio. Published by the MCP ecosystem; used in Claude Desktop, Cursor, Windsurf configs.
3. **Self-hosted community servers** (e.g. `jerhadf/linear-mcp-server`, `dvcrn/mcp-server-linear`). These wrap Linear's GraphQL API in a stdio MCP server. Not using Linear's hosted MCP at all — out of scope for this probe.

Sources:

- <https://www.npmjs.com/package/mcp-remote>
- <https://github.com/geelen/mcp-remote>
- <https://github.com/jerhadf/linear-mcp-server>

## 2. Scope decision

Sean's existing `GhosttiesMCPClient/` ships only `MCPStdioTransport`. Options:

| Option                                                                             | Summary                                                                                                                                                                        | Verdict                                                                                                                                                                                                                                                           |
| ---------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **A — Build HTTP+SSE transport in our client lib**                                 | Implement `URLSession`-based `MCPStreamableHTTPTransport` conforming to `MCPTransport`. Requires SSE parsing, session-id management, reconnect, and OAuth eventually.          | **No.** Too much infrastructure for a diagnostic. Linear's answer may be "no subscriptions — lazy refresh" which would make a full HTTP transport premature. Defer until the v0 sync strategy is locked.                                                          |
| **B — Standalone bash + `curl` script**                                            | Hit `https://mcp.linear.app/mcp` directly with JSON-RPC over curl.                                                                                                             | **No.** Streamable HTTP requires correct `Accept: application/json, text/event-stream` headers, session-id round-tripping, and SSE framing parsed correctly. Rolling that in bash to get an answer is not cheaper than C, and the output will be less structured. |
| **C — Use `mcp-remote` as a stdio bridge, reuse our existing `MCPStdioTransport`** | `npx mcp-remote https://mcp.linear.app/mcp --header "Authorization: Bearer $LINEAR_API_KEY"` subprocess. Our Swift code talks line-delimited JSON-RPC over its stdio as usual. | **Yes.** Zero new transport code, tests the real hosted server, uses exactly the same client path the app will eventually use (once we wire a real transport). Requires `npx` on `$PATH`, which Sean already has.                                                 |

**Chose Option C.** The probe is a new Swift executable target `probe-linear`. We add one small additive method to `MCPClient` (`initializeAndReturnCapabilities`) so the probe can print the server's raw `capabilities` object and the `resources.subscribe` boolean specifically. All other transport/protocol plumbing is reused.

## 3. Probe layout

```
cli/
├── Package.swift                              # new executable target: probe-linear
├── Sources/
│   ├── GhosttiesMCPClient/
│   │   └── MCPClient.swift                    # +initializeAndReturnCapabilities(...)
│   └── probe-linear/
│       └── main.swift                         # the probe
└── Tests/
    └── GhosttiesMCPClientTests/
        └── MCPClientCapabilitiesTests.swift   # covers new method against mock transport
```

### What the probe does

1. Reads `LINEAR_API_KEY` from the environment. Missing → one-line instruction to stderr + exit code 64.
2. Finds `npx` via `/usr/bin/env npx` so the probe works regardless of Node install path.
3. Launches `npx mcp-remote https://mcp.linear.app/mcp --header "Authorization: Bearer $LINEAR_API_KEY"` as a subprocess via `MCPStdioTransport`.
4. Runs `initialize` with a 30s timeout (OAuth dance + cold-start SSE warmup can push past our 10s default).
5. Pretty-prints the entire `capabilities` object to stdout as JSON.
6. Explicitly surfaces `capabilities.resources.subscribe` with `SUBSCRIPTIONS SUPPORTED` vs `SUBSCRIPTIONS NOT SUPPORTED — lazy refresh required`.
7. Calls `tools/list` and logs every tool name + one-line description.
8. Attempts `resources/list`; logs URIs on success, logs "method not supported" on the expected error.
9. Exits 0 on success; non-zero on any failure, with the failing phase printed to stderr.

All subprocess stderr lines (including `mcp-remote`'s OAuth/session chatter) are prefixed `[mcp-remote]` and forwarded to our stderr — **never stdout** (stdout is JSON-RPC territory for the bridge).

### How to run it

```bash
# 1. Get a Linear Personal API Key:
#    Linear → Settings → Security & access → Personal API keys → New API key
export LINEAR_API_KEY='lin_api_xxxxxxxxxxxxxxxxxxxxxxxx'

# 2. Make sure npx is available (ships with Node). Linear's bridge requires it.
which npx

# 3. Run the probe:
cd cli
swift run -c release probe-linear
```

The first run may pause briefly while npm downloads `mcp-remote` into its cache. Subsequent runs are instant.

### Mock mode for offline verification

`swift run probe-linear --mock` uses an in-process mock MCP server (tiny actor that mimics `initialize` + `tools/list` + `resources/list`) so the probe's protocol wiring can be verified without touching Linear. This is what CI / test runs exercise; unit tests cover the capability-parsing logic directly.

## 4. Expected outcomes

The probe will output one of three result shapes into the findings section below:

- **A. Subscriptions supported.** `capabilities.resources.subscribe: true` → we push-subscribe in the app, no polling, refresh UI on `notifications/resources/updated`.
- **B. Subscriptions not supported.** `capabilities.resources.subscribe: false` or absent → lazy refresh on (a) app launch, (b) window-focus, (c) ⌘R. No polling timer.
- **C. Resources primitive entirely absent.** Linear exposes only tools, not resources. Same lazy-refresh strategy as B; the Inbox lane polls `tools/call` against a `list_issues`-type tool on the same three triggers.

## 5. Sample output

To be filled in on the next session once Sean runs the probe with a real `LINEAR_API_KEY`. The mock run is captured below as proof-of-life for the protocol wiring.

### 5.1 Mock run (offline)

```
$ swift run -c release probe-linear --mock
[probe] using mock transport (LINEAR_API_KEY not consulted)
[probe] handshake: initialize → ok
[probe] server capabilities:
{
  "tools" : {
    "listChanged" : false
  },
  "resources" : {
    "listChanged" : false,
    "subscribe" : false
  }
}
[probe] SUBSCRIPTIONS NOT SUPPORTED — lazy refresh required
[probe] tools/list → 2 tools
    - mock_list_issues — list Linear issues assigned to me
    - mock_get_issue   — fetch a single Linear issue by id
[probe] resources/list → 1 resource
    - mock://linear/issue/1
[probe] done.
```

### 5.2 Live Linear run (pending)

Sean to paste output here after running with a real key.

## 6. Follow-ups

If the live run shows subscriptions are **not** supported (the expected outcome), the next wave should:

1. Pick lazy refresh as the sync strategy. No polling timer.
2. Spec the three refresh triggers (launch / focus / ⌘R) in the v0 Inbox design.
3. Decide: do we ship Linear via `mcp-remote` bridge for v0 (fast, one external dep), or invest in a native Streamable HTTP transport in `GhosttiesMCPClient` (more work, no Node dependency)? This is a **separate** scope decision — don't conflate with this probe.

If subscriptions **are** supported, re-open the sync strategy decision and scope a push-subscribe path.

## Sources

- <https://linear.app/docs/mcp>
- <https://linear.app/changelog/2025-05-01-mcp>
- <https://www.npmjs.com/package/mcp-remote>
- <https://github.com/geelen/mcp-remote>
- <https://modelcontextprotocol.io/specification/2025-11-25/basic/transports>
- <https://shinzo.ai/blog/how-to-use-linear-mcp-server>
- <https://www.morphllm.com/linear-mcp-server>
