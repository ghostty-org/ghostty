# Linear Sync Preset

Pulls your assigned Linear issues into the Ghostties Inbox via your AI agent. The agent (Claude Code, Codex, or any MCP-aware client) does the work — Ghostties never talks to Linear directly.

This is the canonical example of a **Phase 5 source preset**: text + config that orients an agent to bridge an external task source into the Ghostties MCP server.

## What you get

- New Linear issues land in the Ghostties **Inbox** lane.
- Status changes in Linear (Todo → In Progress → In Review) flow into Ghostties lanes (`inbox` → `running` → `review`).
- Each task is tagged `source: linear` and `source-id: SEA-NNN` so it shows the Linear glyph in the sidebar and stays linked.
- No app-side polling. No background daemon. The sync runs when you ask the agent to run it.

## Prerequisites

- **Ghostties** installed (`/Applications/Ghostties.app`).
- **`ghostties-mcp`** binary on `$PATH`. If you haven't installed it yet, see `cli/Sources/ghostties-mcp/README.md` — `gt mcp install` will be the one-command path once it ships.
- **An MCP-capable agent** — Claude Code (`claude`), Codex, Cursor, or similar. Examples below use Claude Code.
- **Node.js / npm** — required by the `mcp-remote` bridge (`npx`). Most macOS dev setups already have this.
- **A Linear account** — you'll OAuth into it on first sync.

## Setup

### 1. Wire the MCP servers into your agent

Copy the contents of `mcp-servers.json` into your agent's MCP config. For Claude Code, that's `~/.claude.json` (global) or a project-local `.mcp.json`:

```bash
# Inspect the preset's server config:
cat /Applications/Ghostties.app/Contents/Resources/presets/linear-sync/mcp-servers.json

# Merge it into your agent config (manual for now — a one-command loader is on the roadmap).
```

Edit the `ghostties` server's `--tasks-dir` arg to point at the tasks directory you want this agent to manage. Default is `~/.ghostties/tasks` (the global drawer).

### 2. Load the system primer

Paste the contents of `system.md` into your agent's system prompt — or, in Claude Code, save it as a custom command file and invoke it by slash command.

The v0 manual flow looks like this in Claude Code:

```bash
# Open a terminal in your project
claude --append-system-prompt-file /Applications/Ghostties.app/Contents/Resources/presets/linear-sync/system.md
```

A bundled "Linear Sync" template that does this automatically is planned but not yet wired into the sidebar's template picker.

### 3. Authenticate to Linear (first run only)

The first time the agent calls a Linear tool, `mcp-remote` will open a browser for OAuth. Approve the workspace and the scopes Linear requests. The token is cached by `mcp-remote` under `~/.mcp-auth/`; you won't see this dialog again on the same machine.

If you'd rather use a Personal API key (no browser dance), set `LINEAR_API_KEY` in your shell and edit `mcp-servers.json` to add `--header "Authorization: Bearer ${LINEAR_API_KEY}"` to the `linear` server's args. See `docs/linear-mcp-probe-findings.md` for the exact incantation.

## Using it

Once setup is done, you talk to your agent in plain English. The agent reads `system.md`, knows the mapping rules, and does the work.

```
> Sync my Linear inbox.
Synced 4 Linear issues: 3 created (SEA-141, SEA-142, SEA-143), 1 lane change (SEA-135 → review).

> Pull SEA-135 into Ghostties.
Created SEA-135 in inbox.

> Refresh Linear.
No changes — Linear inbox already in sync.
```

Open Ghostties and the new tasks appear in the Inbox lane with the Linear glyph next to them.

## Troubleshooting

- **"Linear authentication failed"** — the OAuth dance didn't complete or the cached token expired. Run `npx mcp-remote https://mcp.linear.app/mcp` once on its own to re-auth, then retry.
- **"ghostties-mcp: command not found"** — the binary isn't on `$PATH`. Build it (`cd cli && swift build -c release && cp .build/release/ghostties-mcp /usr/local/bin/`) or update the `command` in `mcp-servers.json` to an absolute path.
- **Tasks created but not appearing in the sidebar** — the agent wrote to a different `--tasks-dir` than the app reads from. Confirm both point at the same directory (typically `~/.ghostties/tasks`).
- **Duplicate Linear issues in Ghostties** — the agent skipped its dedupe step. Re-run with: "List my Ghostties tasks with `source: linear`, then sync — don't create duplicates." If it persists, check that `source_id` is being written correctly on existing tasks.
- **Linear status changes not propagating** — by default this preset pulls Linear → Ghostties only. Status flow-back is a stretch behavior; ask the agent: "Push Ghostties statuses back to Linear for `source: linear` tasks."

## What this preset does NOT do

- It does not run on a timer. There's no scheduler — you trigger sync manually.
- It does not write back to Linear by default. Flow-back is opt-in and stretch.
- It does not delete Ghostties tasks when Linear issues are deleted. Stale-task cleanup is the agent's job on the next run; the v0 behavior is to leave them in place.
- It does not handle non-Linear sources. Each external source gets its own preset.
