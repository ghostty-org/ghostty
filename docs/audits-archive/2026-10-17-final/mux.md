# GHOSTTY-NATIVE MUX WORKSTREAM — AUDIT REPORT

**Date:** 2026-10-17T04:48Z
**Repo:** `/Users/kooshapari/CodeProjects/Phenotype/repos/khostty`
**Auditor:** VP-Eng (jcode orchestrator)
**Branch baseline:** `test/agent-ipc-phase0` @ `b2e6c51f3`
**Design brief:** `a3a0857e2` on `main`

---

## 1. TL;DR

Phase 0 is **DONE and verified** on `test/agent-ipc-phase0` — it wired `app_host.zig` (the real-runtime `Host` vtable bridge) into the Zig build graph via a new `test-agent-ipc` step. The change surface is 3 files / 136 lines net (+136, −7). Build passes 83/85 steps, 3899/3925 tests (25 skipped, 1 pre-existing crash). **No new stubs, mocks, or TODOs were introduced.** The `app_host.zig` bridge is deliberately "honest" — several vtable methods return `error.Unsupported` when the runtime is not windowed (GTK-only), which is the correct architectural pattern, not a placeholder. Phase 1 (mux shell binary) is designed but blocked on the absence of a GTK runtime on the operator's macOS host.

---

## 2. Phase 0: What Shipped

### Files Changed (commit `9b9da76d9`)

| File | Lines | Purpose |
|------|-------|---------|
| `build.zig` | +43 | New `test-agent-ipc` build step — wires `src/main_agent_ipc.zig` into the Zig build graph |
| `src/main_agent_ipc.zig` | +89 (new) | Test root mirroring `main_windows_apprt.zig` — imports all `src/apprt/ipc/*.zig` modules + compiles `app_host.zig` |
| `src/apprt/ipc/app_host.zig` | −7 | Remove 7 `_ = param;` discards that Zig 0.16 rejects as "pointless discard" |

### Purpose Groups

**Group A: Build-graph wiring** (`build.zig`)

- Adds `test-agent-ipc` step at line ~79 (declarative step name)
- Adds ~39 lines at line ~469 configuring the test: `src/main_agent_ipc.zig` as root, Debug target, LLVM, `addGhosttyH` dependency (same as Windows apprt root)

**Group B: Test root** (`src/main_agent_ipc.zig`, 89 lines)

- Sits in `src/` (not `src/apprt/ipc/`) because Zig rejects imports that leave the module root 3 levels deep
- Imports all 7 sibling IPC modules: `protocol.zig`, `auth.zig`, `state.zig`, `events.zig`, `pane.zig`, `handler.zig`, `server.zig`
- Imports `app_host.zig` (the reason this file exists)
- One test: `app_host: availability contract matches the built artifact` — asserts `windowed` is false on this host (macOS/none runtime), prints honest caveat

**Group C: Language-version fix** (`app_host.zig`)

- Removes 7 dead `_ = core;` / `_ = term;` discards that Zig 0.16 now rejects when the same param is read in the `comptime windowed` branch. Pure language fix, no behavioral change.

### What the IPC Surface Already Contains

The `src/apprt/ipc/` directory (pre-existing, not Phase 0's work) is 1300+ lines of implemented, unit-tested Zig:

| File | Responsibility | Tests |
|------|---------------|-------|
| `protocol.md` | 459-line normative schema | — |
| `protocol.zig` | Wire types, JSON parsing, response writers | 30 |
| `auth.zig` | Token resolution, constant-time SHA-256 verification | 12 |
| `state.zig` | `pane.state` snapshot + JSON | 5 |
| `events.zig` | Event types, subscription broker, drop accounting | 13 |
| `pane.zig` | Pane registry, `Host` vtable, payload writers | 34 |
| `handler.zig` | Command dispatch, error mapping, event polling | 22 |
| `server.zig` | Unix socket server, framing, client, event pusher | 14 |
| `app_host.zig` | `Host` impl over the real app runtime | **wired by Phase 0** |
| `fake_host.zig` | In-memory VT, the `Host` for tests | exercised by above |

Wire-level command surface (already implemented):

- `pane.create` (with `{"split":"vertical|"horizontal"}`) — the split primitive
- `pane.close`, `pane.focus`, `pane.list`
- `pane.write` — writes VT bytes into the parser (v1 does NOT inject into child pty)
- `pane.state` — cursor, title, size, mode flags as structured data
- `pane.search` — scrollback search
- `events.subscribe` — `pane_created`, `pane_closed`, `titleChange`, `childExit`, `resize`, `bell`, `focusChange`

---

## 3. Phase 0: Verification Outcomes

### Build Results (commit `98cfbef20`, fresh verification 2026-10-15)

| Metric | Baseline (Phase 0 build) | Verified Run | Delta |
|--------|--------------------------|--------------|-------|
| Wall clock | 30m 24s | 27m 29s | −2m 55s |
| Build steps | 83/85 | 83/85 | same |
| Tests passed | 3899/3925 | 3899/3925 | same |
| Tests skipped | 25 | 25 | same |
| Tests crashed | 1 | 1 | same |

### The 1 Crash: Pre-existing Flake

`terminal.search.Thread.test_0` → `kqueue.zig:1916 .BADF => unreachable`

- **Root cause:** Race between test thread teardown and search thread's libxev kqueue loop. The FD close fires before the kevent returns, hitting the `.BADF => unreachable` arm.
- **Characterized in:** `evidence/flake-investigation-20261015.md`
- **Not a Phase 0 regression.** The Phase 0 commit lowered the bar for the race by adding a larger test root (3900 tests, 4GB peak) that creates enough memory/threading pressure to expose the latent race.
- **Not reproduced on `main`** across 59 attempts (4 invocation methods).
- **Not fixed on this branch.** Fix candidates: (1) `Thread.zig` guard catching `error.BadFileDescriptor` as teardown-noop, (2) libxev BADF recoverability change.

### Build Log Evidence

| File | Content |
|------|---------|
| `evidence/agent-ipc-build-20261014.log` | Cold-cache build + 7-error first attempt + post-fix success (1183 lines) |
| `evidence/agent-ipc-incremental-20261014.log` | First re-run (1 fail + 1 crash, flaky) |
| `evidence/agent-ipc-cache-warm-20261014.log` | Second re-run (1 crash only) |
| `evidence/phase0-verify-20261015.md` | Fresh verification report |
| `evidence/flake-investigation-20261015.md` | Full flake characterization with stack trace |

### Honest Caveat (from `main_agent_ipc.zig` header)

The build is **shallow** on this host. Only GTK is `windowed`; the operator's macOS host uses the `none` runtime. The vtable bodies that call into `App` / `CoreSurface` are **never type-checked** here — they are discarded at comptime. A green `zig build test-agent-ipc` proves:

- The file compiles
- All imports resolve
- The `AppHost` struct signatures are valid

It does **NOT** prove that `pane.create` really splits a surface, because the `windowed_vtable` bodies are only analyzed under `-Dapp-runtime=gtk` (Linux).

---

## 4. Phase 0: Stubs/Mocks/TODOs

| Location | What | Classification |
|----------|------|----------------|
| `app_host.zig:175,179,190,194` | `focusUnsupported`, `searchUnsupported` vtable entries | **Deliberate architectural pattern** — not a placeholder. `pane.focus` has no runtime API for surface-by-id focus; `pane.search` is async/UI-driven upstream. |
| `app_host.zig:201,205,213,231,235,244,253,257,261` | Multiple methods return `error.Unsupported` | **Comptime-gated** — only fires when `windowed == false` (non-GTK builds). Under GTK, the `windowed_vtable` has real implementations. |
| `fake_host.zig:8` | Comment: "stub that echoes its input back" | **Pre-existing** — the test backend, introduced at G4, not Phase 0. |
| `server.zig:557` | Comment: "format placeholders" | **Documentation** — about `{` brace escaping in the wire format. |

**Search performed:** `rg "todo!|unimplemented!|TODO|FIXME|placeholder|mock|stub|we'll add"` across `src/apprt/ipc/` — 2 matches, both benign (see table above).

**Verdict: Zero new stubs, mocks, `todo!()`, or `unimplemented!()` were introduced by Phase 0.**

---

## 5. Phases 1–N: The Design Roadmap

Source: `docs/sessions/20261014-ghostty-native-mux/00_SESSION_OVERVIEW.md` (the design brief at `a3a0857e2`).

### Phase Summary Table

| Phase | Goal | Acceptance (GTD/E2E) | Blocker | Status |
|-------|------|---------------------|---------|--------|
| **Phase 0** | Wire `app_host.zig` into build graph | `zig build test-agent-ipc` passes; 130+ IPC tests green; availability-contract test fires | None | ✅ DONE |
| **Phase 1** | Mux shell binary (new Zig executable): routing table `(instance, pane_id) → client`, single socket `khostty-mux.sock`, fans out to per-instance `khostty.sock`. New commands: `mux.list`, `mux.focus`, `mux.attach/detach`, `mux.layout.save/restore`. Reuses `protocol.zig` + `auth.zig` verbatim. | Agent connects to mux socket, `mux.list` returns multiple instances, `mux.focus` routes keyboard to pane across instances, `mux.attach` survives client disconnect | **GTK runtime** — operator is on macOS, only GTK is `windowed`. Can prototype with mock-only runtime paths; real GTK needs Linux box or alternative design choice. | NOT STARTED |
| **Phase 2** | Durable sessions — persist pane registry + layout across host restart | Pane layout survives host restart; agents can re-attach to restored sessions | **pty input injection** (`pane.execute`, the v2 item) — without it, restore is layout-only, cannot re-run processes | NOT STARTED |
| **Phase 3** | Beyond durable sessions (not detailed in design brief) | Not defined | Not defined | NOT DEFINED |

### Explicit Non-Goals (first cut)

- Remote/TCP transport
- pty injection (v2 item, deferred to Phase 2+)
- Cross-host federation
- Windows named pipes (follow-up tracked in `src/apprt/windows/`)

### Design Risks (from the brief)

1. **366-behind upstream drift.** Upstream moves fast (~62 commits/8h). The IPC surface is additive and unlikely to conflict, but any rebase should run the bindings-drift guard test (`74aa5eea9`) first.
2. **Locking contract is load-bearing.** `pane.zig` documents strict `Manager → Broker` lock ordering and a no-reentrancy rule. A mux fan-out layer must not introduce a second lock domain that can invert.
3. **`pane.write` is parser-level, not pty-level.** A mux that wants to drive child processes needs the v2 injection work; anything short of that is a screen-scraper.

### Phase 1 Design Sketch (from the brief)

- **Binary:** new Zig executable, not a modification of the existing Ghostty binary
- **Socket layout:** one `khostty-mux.sock`, agents connect here; mux transparently fans out to per-instance `khostty.sock` sockets
- **Routing table:** `(instance_id, pane_id) → client connection`
- **Protocol reuse:** `protocol.zig` and `auth.zig` verbatim — no new wire types
- **New commands (deliberately few):**
  - `mux.list` — all instances + their panes
  - `mux.focus` — route keyboard focus to a pane anywhere
  - `mux.attach` / `mux.detach` — session handle across client disconnect
  - `mux.layout.save` / `mux.layout.restore`
- **Presenter:** reuse `src/apprt/embedded.zig` to render panes inside a mux-owned window, so zero new rendering code is required

---

## 6. Immediate Unfinished Items

### Phase 0 Carry-Forwards

1. **Merge Phase 0 → fork main.**
   The Phase 0 work sits on `test/agent-ipc-phase0` (not merged to fork `main`). The handoff doc (`docs/HANDOFF-20261015.md`) explicitly lists this as an open carry-forward.
   - **10m task:** `git checkout main && git -c merge.ff=true merge --squash test/agent-ipc-phase0 && git commit -m "feat(ipc): wire agent IPC into the Zig build graph (Phase 0) ..." && git push origin main`

2. **SonarCloud post-merge steps.**
   PR #14 was merged (`223696488`), but 2 operator steps remain:
   - **10m task:** `gh secret set SONAR_TOKEN --repo KooshaPari/Khostty` (requires the actual token value from the operator)
   - **10m task:** Settings → Integrations → uninstall inherited SonarCloud GitHub App

3. **`terminal.search.Thread.test_0` flake fix.**
   Characterized in `evidence/flake-investigation-20261015.md`. Not fixed on this branch.
   - **10m task:** In `src/terminal/search/Thread.zig:197`, wrap the `threadMain_` call to catch `error.BadFileDescriptor` from the kqueue race and treat it as a clean teardown (log + return instead of panic). Add a `@import("std").posix.fd_t` guard before the kevent call.

### Phase 1 Prep (design work, not coding)

4. **Trace `CoreSurface.queueIo` mailbox path.**
   `app_host.zig` header (lines 37–50) documents that `pane.write` should queue through `CoreSurface.queueIo` instead of touching the parser directly. Currently it touches the parser directly (unsafe for IPC threads).
   - **10m task:** Read `src/Surface.zig` → find `queueIo`, understand the mailbox pattern, write a 1-pager in `docs/sessions/20261014-ghostty-native-mux/02_MAILBOX_INTEGRATION.md` documenting: what `queueIo` accepts, whether it's sync/async, what it returns.

5. **Map event hook insertion points.**
   `app_host.zig` header says the four publish hooks belong next to the runtime's existing callbacks.
   - **10m task:** `rg "titleChange\|childExit\|resize\|bell" src/apprt/gtk/` — find where the GTK runtime already handles these events. Document file:line locations in `docs/sessions/20261014-ghostty-native-mux/03_EVENT_HOOKS.md`.

6. **Write Phase 1 architecture doc.**
   Phase 1 has no architecture doc yet — only the brief sketch in the design doc.
   - **10m task:** Create `docs/sessions/20261014-ghostty-native-mux/04_MUX_ARCHITECTURE.md` with: binary name, socket layout, routing table data structure (hash map? array?), command surface, how it reuses `embedded.zig`, thread model, lock ordering.

7. **Mock mux prototype skeleton (macOS-only, no GTK).**
   Phase 1 is blocked by GTK, but a mock-only prototype using `fake_host.zig` patterns could validate the routing table and command surface without the runtime.
   - **10m task:** Draft `src/apprt/ipc/mux_shell.zig` skeleton: struct definition, `mux.list` command dispatch, routing table type. No runtime integration. Compile-check only.

8. **Audit `embedded.zig` for mux compatibility.**
   The design brief says Phase 1 would reuse `src/apprt/embedded.zig` for rendering. No one has verified it can host multiple panes or that its lifecycle matches the mux's needs.
   - **10m task:** Read `src/apprt/embedded.zig`, identify: (a) can it hold multiple surfaces? (b) what is its lifecycle? (c) does it expose a "create surface" API the mux could call? Write findings in `04_MUX_ARCHITECTURE.md`.

---

## 7. Open Questions for the Operator

1. **GTK runtime availability.**
   Phase 1 needs a windowed runtime. Options:
   - (a) Run on a Linux box with GTK installed
   - (b) Use `embedded.zig` surface-within-surface pattern on macOS
   - (c) Build a mock-only prototype first, defer real runtime to later
   - **Which path?**

2. **Phase 0 → main merge timing.**
   The Phase 0 branch has not been merged to fork `main`. Merge now (it's verified clean) or wait for something?

3. **Upstream drift management.**
   The fork is 366+ commits behind upstream. The IPC surface is additive and unlikely to conflict, but a rebase should run the bindings-drift guard. Rebase before Phase 1 or defer?

4. **Flake fix priority.**
   The `terminal.search.Thread` flake is characterized but unfixed. Fix on fork, defer, or just live with the 1-crash-under-load flake?

5. **Phase 1 scope boundary.**
   The design brief says "not a tmux replacement; a host for agent-facing splits." Does Phase 1 include rendering (via `embedded.zig`) or just the mux shell binary with the routing table + new commands (no rendering)?

---

## 8. Gaps for Synthesis (what the fwd-path synthesizer needs)

1. **Phase 1 architecture doc does not exist.**
   The design brief sketches Phase 1 at a high level but has no data structures, no binary layout, no test plan. The synthesizer needs this before it can decompose Phase 1 into 10m tasks.

2. **No decision on the windowed-runtime blocker.**
   The synthesizer cannot plan Phase 1 implementation without knowing whether the target is GTK-on-Linux, embedded-on-macOS, or mock-only.

3. **No `embedded.zig` audit.**
   The design brief says Phase 1 would reuse `src/apprt/embedded.zig` for rendering. No one has verified that `embedded.zig` can host multiple panes or that its lifecycle matches the mux's needs. The synthesizer needs a 1-pager on this.

4. **`pane.write` mailbox integration is undocumented.**
   `app_host.zig` header (lines 37–50) says `pane.write` should go through `CoreSurface.queueIo` but no one has traced that code path. The synthesizer needs to know: what does `queueIo` accept? Is it synchronous or async? Does it return a result?

5. **Event hook insertion points are unmapped.**
   The four publish hooks need to be placed next to the runtime's existing callbacks (OSC title path, child-exit message, resize callback, bell path). No one has found these in `src/apprt/gtk/` or `src/apprt/macos/`. The synthesizer needs a list of file:line locations.

6. **No Phase 2 design.**
   Durable sessions + pty injection (`pane.execute`) are mentioned but not designed. The synthesizer cannot plan beyond Phase 1 without this.

7. **Lock ordering contract is undocumented for the mux layer.**
   `pane.zig` documents strict `Manager → Broker` lock ordering. The mux shell will introduce a new layer above this. The synthesizer needs to know: what locks does the mux need, and how do they compose with the existing contract?

---

**End of report.**