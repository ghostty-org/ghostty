# Ghostty-native mux — design brief (2026-10-14)

**Question asked:** "ghostty-native herdr\cmux\honeymux etc style solu?"

**Answer up front:** the fork already ships ~80% of the substrate for a
ghostty-native agent mux. What is missing is the orchestration layer above
it. This brief documents what exists, what is missing, and a concrete
first cut.

---

## What exists (verified in the tree today, not from docs)

### The IPC protocol — `src/apprt/ipc/`

This is the important find. It is **not** a design sketch; it is 1300+ lines
of implemented, unit-tested Zig code already committed to `origin/main`.
`src/apprt/ipc/protocol.md` describes it as "Khostty Agent IPC Protocol (v1)"
with "Status: **v1 implemented in this directory**".

| File            | Responsibility                                       | Tests                  |
| --------------- | ---------------------------------------------------- | ---------------------- |
| `protocol.md`   | 459-line normative schema                            | —                      |
| `protocol.zig`  | wire types, JSON parsing, response writers           | 30                     |
| `auth.zig`      | token resolution, constant-time SHA-256 verification | 12                     |
| `state.zig`     | `pane.state` snapshot + JSON                         | 5                      |
| `events.zig`    | event types, subscription broker, drop accounting    | 13                     |
| `pane.zig`      | pane registry, `Host` vtable, payload writers        | 34                     |
| `handler.zig`   | command dispatch, error mapping, event polling       | 22                     |
| `server.zig`    | Unix socket server, framing, client, event pusher    | 14                     |
| `app_host.zig`  | `Host` impl over the real app runtime                | **not in build graph** |
| `fake_host.zig` | in-memory VT, the `Host` for tests                   | exercised by above     |

The command surface already addressed at the wire level:

- `pane.create` (with `{"split":"vertical"|"horizontal"}`) — the split primitive
- `pane.close`, `pane.focus`, `pane.list`
- `pane.write` — writes **VT bytes into the parser** (e.g. `"ls -la\n"` or
  `"\u001b[31mred\u001b[0m"`). v1 explicitly does **not** inject into the child
  pty — that is a v2 non-goal.
- `pane.state` — cursor, title, size, mode flags as structured data
- `pane.search` — scrollback search
- `events.subscribe` — `pane_created`, `pane_closed`, `titleChange`,
  `childExit`, `resize`, `bell`, `focusChange`, all with `pane_id`

Auth is deliberately fail-closed and constant-time. Socket path defaults are
cross-platform (`KHOSTTY_IPC_SOCKET` override, macOS/Linux defaults, Windows
named-pipe follow-up). Pane ceiling is 64 per instance, lock-serialized, with
a documented allocator contract so the `Host` never needs to be thread-safe.

### The VT bindings — `khostty-python/khostty_vt/`

The PyPI package the fork ships exposes the whole terminal as data:

- `snapshot.py` — read the screen as a grid
- `search.py` — scrollback search from Python
- `keyencoder.py` / `key.py` / `mouse.py` — structured input
- `formatter.py` — the fork's own wrapped-formatter surface
- `constants.py`, `errors.py`, `_ffi.py`, `_cdef.py`

`examples/agent.py` states the thesis in its docstring: "Instead of scraping
a rendered screen, an agent asks the terminal structured questions."

### The embedding surface — `src/apprt/embedded.zig`

Ghostty's "surface within a surface" apprt. A parent host owns the app
lifecycle; Ghostty renders inside it. This is the shape a mux shell would use
if it wanted to host panes without spawning separate Ghostty processes.

### What is NOT there

- No orchestrator process. The IPC is **agent ↔ one running instance**.
  There is no "agent ↔ mux ↔ N instances" layer.
- `app_host.zig` — the `Host` vtable bridge to the real runtime — is
  explicitly "not yet in the build graph". Everything tests against
  `fake_host.zig`. **This is the single highest-leverage unblock**: wire
  `app_host.zig` in and the IPC goes from testable to live.
- No attach/detach, no persistent sessions, no multiplexed focus routing, no
  layout save/restore, no reconnection after a host restart.
- No pty input injection (v2 by design), so a mux cannot type into children.

---

## Where it sits vs herdr / cmux / honeymux

Only `herdr` is locally installed and inspectable. It is wired into this
session via four hooks (`~/bin/jcode-tool-safety`, `~/bin/jcode-herdr-report`,
`~/bin/jcode-combined-herdr-hook`). Locally its MCP/CLI surface hung on
`--help` and was cancelled; I could not enumerate its commands.

The honest position on the others:

- **cmux** — no local install, no config, no repo reference. UNKNOWN.
- **honeymux** — no local install, no docs, no repo reference. UNKNOWN.

So a real head-to-head is not possible from this machine today. What can be
said structurally: a mux layer _is_ the right shape for the Khostty 0.1.x
stack, and the fork has a native first-mover advantage no generic mux has —
it owns the VT, the parser, and the protocol. A generic mux has to scrape
or proxy a black-box terminal; Khostty can expose state natively.

---

## Proposed first cut — "khostty-mux"

**Scope:** minimum viable orchestrator that makes `pane.*` useful across more
than one instance. Not a tmux replacement; a host for agent-facing splits.

**Phase 0 — unblock the IPC (prerequisite, smallest change, highest value)**

- Wire `src/apprt/ipc/app_host.zig` into the build graph so the protocol runs
  against the real runtime instead of `fake_host.zig`
- Verify with the existing 130 tests plus one manual socket session
- Outcome: any agent can already `pane.create`, `pane.write`, `pane.state`,
  `events.subscribe` against a live Khostty

**Phase 1 — the mux shell (Zig, new binary)**

- Owns a routing table: `(instance, pane_id) -> client connection`
- One socket: `khostty-mux.sock`, agents connect here, mux transparently fans
  out to per-instance `khostty.sock` sockets
- Reuses `protocol.zig` and `auth.zig` verbatim; no new wire types
- New commands, deliberately few:
  - `mux.list` — all instances + their panes
  - `mux.focus` — route keyboard focus to a pane anywhere
  - `mux.attach` / `mux.detach` — session handle across client disconnect
  - `mux.layout.save` / `mux.layout.restore`
- Presenter: reuse `src/apprt/embedded.zig` to render panes inside a mux-owned
  window, so zero new rendering code is required

**Phase 2 — durable sessions**

- Persist pane registry + layout so a host restart does not orphan agents
- Requires pty input injection (`pane.execute`, the v2 item) to actually
  re-run processes; without it, restore is layout-only

**Explicit non-goals for the first cut:** remote/TCP transport, pty
injection, cross-host federation, Windows named pipes (follow-up already
tracked in `src/apprt/windows/`).

---

## Risks worth stating

- **The 366-behind drift.** Upstream has moved 62 commits in ~8h, including
  `terminal: fix use-after-free when scrollback prunes the cursor page`
  (#14686). The IPC surface is additive and unlikely to conflict, but any
  rebase should run the `bindings-drift guard` test (74aa5eea9) first.
  See `docs/UPSTREAM-DELTA.md`.
- **Locking contract is load-bearing.** `pane.zig` documents a strict
  `Manager -> Broker` lock ordering and a no-reentrancy rule. A mux fan-out
  layer sitting on top must not introduce a second lock domain that can
  invert against these.
- **`pane.write` is parser-level, not pty-level.** A mux that wants to drive
  child processes needs the v2 injection work first; anything short of that
  is a screen-scraper, which is exactly what this design exists to avoid.

---

## Recommendation

Do Phase 0 first, on its own branch, before deciding anything about the mux
shell. It is a build-graph change plus a manual socket check, it de-risks the
entire upstream area, and it makes the IPC usable by today's agents
regardless of whether a mux is ever built.

## Sources

- `src/apprt/ipc/protocol.md` (459 lines, normative)
- `src/apprt/ipc/pane.zig` (1209 lines)
- `src/apprt/ipc/auth.zig` (526 lines)
- `src/apprt/embedded.zig`
- `khostty-python/khostty_vt/` + `examples/agent.py`
- `docs/UPSTREAM-DELTA.md` (252 ahead / 366 behind)
- Local hook wiring: `~/bin/jcode-tool-safety`, `~/bin/jcode-herdr-report`,
  `~/bin/jcode-combined-herdr-hook`
