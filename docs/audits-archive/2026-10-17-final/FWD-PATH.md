# Khostty Forward-Path Roadmap — 2026-10-17

**Repo:** `/Users/kooshapari/CodeProjects/Phenotype/repos/khostty`
**Observed:** 2026-10-17T05:18Z · **Method:** synthesis of 4 sibling reports (read-only).
**Author:** VP-Eng (jcode orchestrator, tier-0 M3) · **Companion:** [`20261017-FINAL-AUDIT.md`](20261017-FINAL-AUDIT.md)

**Binding (operator 2026-10-15):** FORK-ONLY. No `gh pr/issue/discussion create` or `gh api POST/PATCH/DELETE` against `ghostty-org/ghostty` or any other upstream repo. Reading, copying, tracking, `zig build` against upstream: fine. Push to `KooshaPari/*`: fine.

**File status (binding rule #10):** This file is in `docs/audits/`, which is **untracked** by binding rule. Do not `git add` it.

**Operator scope (2026-10-17):** "Bring the project as close to finish as possible" — EXCLUDING scaling, sunset, user feedback, intent evolution. So: close the open carry-forwards, resolve the stubs, finish the unmerged/half-done work.

**Phase 0 status (canonical, 2026-10-15):** **MERGED** via PR #15 at `ebc033eba` on `main`. The Phase 0 "wiring" is done; what remains is **wiring the IPC server into a runtime that calls `Server.bind`**.

---

## §1. The "finish" picture (what done looks like, 3-5 sentences)

Khostty is "finished" in fork-only scope when **(a)** the post-SUNSET polish batch lands, **(b)** the IPC server is wired into a runtime that boots on at least one platform (GTK-on-Linux preferred), **(c)** `pane.focus` and `pane.search` are honestly disclosed as `error.Unsupported` in user-facing docs, **(d)** the Phase 1 mux shell has a documented architecture and a compile-checked skeleton, and **(e)** three operator-only registry actions (PyPI trusted publisher, SonarCloud token + App uninstall) complete the post-merge hooks. **What "done" does NOT include** (operator scope): upstream-core API work for focus-by-id or synchronous scan, real Windows GUI runtime (G3 deferral stays), benchmark harness (G8 out of scope), scaling/sunset/user-feedback/intent-evolution (operator-excluded).

### "Done" checklist

- [ ] Phase A polish batch (3h, 7 tasks) merged to `main`
- [ ] IPC server wired into GTK runtime; `pane.write` mailbox hop landed together (Phase B)
- [ ] `pane.focus` and `pane.search` disclosed as unsupported in `protocol.md` + `AGENT.md §4` (10m docs update — part of A1)
- [ ] Phase 1 architecture doc written (Phase C4)
- [ ] PyPI publish complete (`khostty_vt` 0.1.0 published) — operator action
- [ ] SonarCloud `SONAR_TOKEN` set + inherited App uninstalled — operator action
- [ ] All stale branches deleted (Phase A4)
- [ ] `wasm/package.json` bumped to `0.1.0` (Phase A6)

### What "done" explicitly does NOT include

| Excluded | Why |
|---|---|
| Windows GUI real runtime (G3) | Program deferral in `ROADMAP.md`; 3-4w scope; out of operator scope |
| `bench/` (G8) | `-Demit-bench` is upstream tooling, not a fork deliverable |
| Upstream-core focus-by-id API | FORK-ONLY binding; out of scope |
| Upstream-core synchronous scan API | FORK-ONLY binding; out of scope |
| Pytest 3.8/3.9 CVE-2025-71176 fix | 3.10+ lane already patched; deliberately left open on 3.8/3.9 |
| WSL `kooshapari-desk` r4 sync | Tailscale offline; per binding, no probes |
| Linux box setup | Requires operator decision (Q1) |

---

## §2. Phase 0: post-merge polish batch (~3h, 10m-1h tasks)

**Source:** State audit §6 + FINAL-AUDIT §4 + §7. All tasks are low-risk, well-scoped, no design decisions.

Each task: file:line + effort + dependency. Total: ~3h.

### A1 — Refresh 5 stale doc claims (1h)

**Why:** The docs currently *understate* the code; any plan generated from `SECURITY.md`/`PLATFORMS.md`/`protocol.md` will over-estimate remaining work.

| File | Lines | Stale claim | Correct state |
|---|---|---|---|
| `docs/SECURITY.md` | 128-130 | "No `server.zig`" / "No `app_host.zig`" | both exist (1,238 + 574 lines, 458 tests) |
| `docs/SECURITY.md` | 146-167 | "PIPE_PREFIX is malformed" | `windows/ipc.zig:34-39` now spells bytes individually; `ipc.zig:181-200` asserts byte positions |
| `docs/SECURITY.md` | 169-176, 313, 350 | "No ACL design exists" | `PIPE_DACL_SDDL = "D:P(A;;GA;;;OW)"` + `PIPE_HANDLE_INHERITABLE = false` decided and tested |
| `docs/PLATFORMS.md` | 234-238 | "Known defect: imports `Surface.zig` (wrong case)" | `mod.zig:4` now imports `surface.zig` (lowercase) |
| `docs/SECURITY.md` + `docs/AGENT.md §4` | — | Agent IPC claimed "not yet in build graph" | Phase 0 wired `test-agent-ipc` at `build.zig:472-508` on `main` |
| `docs/src/apprt/ipc/protocol.md` | 21 | `app_host.zig` row says "not yet in the build graph" | Phase 0 wired it |

**Effort:** 1h (read each context, rewrite 5 short passages). **Block:** none.

### A2 — Fix EGL tautological assertion (10m)

**File:** `pkg/opengl/egl.zig:470-473`

```zig
// CURRENT (always passes — false control)
expectEqualStrings(comptimeArmName(X), comptimeArmName(X))

// PROPOSED: actually verify the translator output matches the declared type
// Option: assert comptimeArmName(X) equals the C-string-typed equivalent
```

**Effort:** 10m. **Block:** none.

### A3 — Delete orphaned `windows/renderer.zig` (10m)

**File:** `src/apprt/windows/renderer.zig` (64 lines, 8 `Unimplemented`)

- **Verify first:** `rg 'windows/renderer.zig' src/` → 0 hits (confirmed in stubs §7). Safe to delete.
- **Keep:** the test that imports it from `main_windows_apprt.zig` must be removed or stubbed.

**Effort:** 10m. **Block:** none.

### A4 — Verify `ci16-fix`/`ci17-fix` then delete stale branches (10m)

Per state §2 branch inventory:

```sh
# Verify before delete
git diff origin/main ci16-fix -- src/.github/  # should be empty or ≤ PR #16 surface
git diff origin/main ci17-fix -- .github/workflows/zig-fork-tests.yml  # should be empty or ≤ PR #17 surface
# Delete via safe (lowercase -d, not -D)
git branch -d ci16-fix ci17-fix
git branch -d ci17-fix-realbase fix/egl-typed-platform-display fix/ipc-test-oversized-linux-rst fix/ipc-test-oversized-linux-rst-v2 ci/sonar-custom-workflow ci/zig-fork-tests
git push origin --delete test/agent-ipc-phase0 sync/upstream-20261015 lanes/a-s0-s4-20261016 stubs/khostty-lane-b-20261016 stubs/khostty-lane-c-20261016 fix/khostty-prettier-20261016
```

**Effort:** 10m. **Block:** none (note: `git branch -d` is safe; `git push origin --delete` is non-destructive and policy-allowed).

### A5 — Fix `terminal.search.Thread.test_0` ABRT flake (1h)

**File:** `src/terminal/search/Thread.zig:197` (per mux §6 #3 evidence `evidence/flake-investigation-20261015.md`)

**Fix:** catch `error.BadFileDescriptor` from the kqueue race and treat it as a clean teardown (log + return instead of panic). Add a `@import("std").posix.fd_t` guard before the kevent call.

**Effort:** 1h. **Block:** none.

### A6 — Bump `wasm/package.json` to `0.1.0` (10m)

**File:** `wasm/package.json` (currently `0.0.0`; npm published artifact is `0.1.0`)

```sh
# Verify drift
diff <(jq .version wasm/package.json) <(npm view @khostty/libghostty-vt-wasm version | jq -R .)
# Bump
# Update wasm/package.json "version": "0.0.0" -> "0.1.0"
# Also update any 0.0.0 references in wasm/README.md, wasm/CHANGELOG.md
```

**Effort:** 10m. **Block:** none.

### A7 — Delete `src/apprt/windows/win32api.zig` if confirmed unused (10m)

**File:** `src/apprt/windows/win32api.zig:60-67`

- **Verify first:** `rg 'win32api' src/` → confirmed 1 hit (`main_windows_apprt.zig:29`, test root only per stubs §7).
- **If unused:** remove; reduce fork delta by 85 lines.
- **If used by anything in `App.zig`/`Window.zig`:** leave (deferred with Windows GUI).

**Effort:** 10m (5m verify + 5m delete). **Block:** none.

### A1+A6 also disclose the G4 limitation honestly

While editing `protocol.md` for A1, add a single line in §1 (overview) and §3 (command surface) noting that **`pane.focus` and `pane.search` return `error.Unsupported` against the real GTK runtime** (this is per `app_host.zig:177-178` + `app_host.zig:208-232`; usability §5 #2). The fix is upstream-core API work and out of fork-only scope; the disclosure is in-scope and free with A1.

---

## §3. Phase 1: G4 finish — wire IPC server into runtime (1d, requires GTK/Linux)

**Source:** State audit §6 #8 + stubs IMMATURE #1 + mux §2 + usability §5 #1.

### The actual G4 finish line

| Task | Where | Effort | Block |
|---|---|---|---|
| **B1** Wire `Server.bind` from GTK runtime | `src/apprt/gtk/App.zig` (file:line TBD by audit subagent) | 1d | **GTK-on-Linux** |
| **B2** Fix `pane.write` cross-thread parser access (mailbox hop) | `src/apprt/ipc/app_host.zig:290-298` (replace direct parser access with `Surface.queueIo`) | 1d (with B1) | **GTK-on-Linux** |
| **B3** Add `max_connections` + rate limit | `src/apprt/ipc/server.zig` | 1h | none |
| **B4** Map 4 event publish hooks (title/child-exit/resize/bell) | `src/apprt/gtk/` (file:line TBD) | 1d | **GTK-on-Linux** |
| **B5** Snapshot counters (bell/exit/command/last_activity) | `src/apprt/ipc/app_host.zig:479-489` | 1d | GTK |
| **B6** Add `conformance/` + `wasm/` to CI | `.github/workflows/` (new `ci/conformance.yml` + extend `ci/zig-fork-tests.yml`) | 1h | none |

### B1 — Wire `Server.bind` from GTK runtime (1d, dependency: GTK host)

**Approach:**
1. Audit subagent reads `src/apprt/gtk/App.zig` (28 files in `src/apprt/gtk/` — find the lifecycle hook called after the GTK loop is up).
2. Construct `apprt.ipc.Server` with the documented socket path (`auth.zig:188-198` for platform path).
3. Call `Server.bind(...)` from the GTK runtime; pass an `apprt.ipc.AppHost` instance.
4. Verify via local GTK build on Linux; the agent IPC socket should appear at the platform-correct path.

**Acceptance (per protocol.md + state §6):**
- After `zig build` + `khostty` boots on GTK Linux, `ls $XDG_RUNTIME_DIR/khostty/ipc.sock` returns the socket.
- `khostty-client ping` returns `{"ok":true}`.
- `khostty-client pane.list` returns at least the focused pane.

**Effort:** 1d. **Block:** macOS operator host cannot build GTK.

### B2 — Fix `pane.write` cross-thread parser access (1d, with B1)

**File:** `src/apprt/ipc/app_host.zig:290-298`

**Approach:**
1. Audit subagent traces `CoreSurface.queueIo` in `src/Surface.zig` (state §8 #4 + §9 #2 — currently untraced).
2. Replace the direct `stream.nextSlice(data)` call with `surface.queueIo(...)` (or whatever the mailbox primitive turns out to be).
3. Verify by `pane.write` test in the GTK context (cross-thread); previously this would race; after the fix, it should serialize.

**Effort:** 1d. **Block:** must be co-shipped with B1.

### B3 — Add `max_connections` + rate limit (1h)

**File:** `src/apprt/ipc/server.zig` (per stubs MVP-LAZY #9)

**Approach:**
- Add `max_connections: u32` field to `Server` config (default 32, env override `KHOSTTY_IPC_MAX_CONNECTIONS`).
- Add a `Semaphore` or atomic counter around `acceptLoop`.
- Add per-connection token-bucket rate limit (default 100 cmd/s; env override `KHOSTTY_IPC_RATE_LIMIT`).
- Tests: 33 simultaneous connect attempts → 33rd is rejected.

**Effort:** 1h. **Block:** none (independent of GTK).

### B4 — Map 4 event publish hooks (1d)

**Per `app_host.zig:54-58`:** the 4 publish hooks belong next to the runtime's existing callbacks. **File:line TBD by audit subagent.** Candidates per mux §3 evidence:

| Event | Likely upstream hook |
|---|---|
| `titleChange` | OSC title response (in `src/terminal/Terminal.zig`) |
| `childExit` | child-process wait callback (in `src/runner.zig` or `src/Command.zig`) |
| `resize` | resize callback (in `src/Surface.zig`) |
| `bell` | bell path (in `src/terminal/Terminal.zig`) |

**Effort:** 1d (audit + wire). **Block:** GTK runtime.

### B5 — Snapshot counters (1d)

**File:** `src/apprt/ipc/app_host.zig:479-489`

Add the runtime-side tracking for `bell_count`, `exited`, `exit_code`, `exit_signal`, `command`, `last_activity_ms`. Currently all `null` (stubs MVP-LAZY #3). Cross-references with B4's hook insertion points.

**Effort:** 1d. **Block:** GTK runtime.

### B6 — Add `conformance/` + `wasm/` to CI (1h)

**File:** new `.github/workflows/ci-conformance.yml` + extend `.github/workflows/zig-fork-tests.yml`

```yaml
# ci-conformance.yml (new)
name: ci/conformance
on:
  push:
    branches: [main]
    paths:
      - 'conformance/**'
      - 'wasm/**'
jobs:
  conformance:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: ./conformance/build.sh run
      - run: ./wasm/build.sh && ./wasm/test/*.test.mjs
```

**Effort:** 1h. **Block:** none.

### G4 finish — total: ~5 working days (with Linux box available)

- B3 + B6 = 2h, no GTK
- B1 + B2 + B4 + B5 = ~4d, requires Linux box

---

## §4. Phase 2: Phase 1 mux shell (2d design + 1w+ build, blocked on operator Q1)

**Source:** Mux audit §5 + state §6 #15 + usability §5 #1.

### Phase 1 design tasks (2d, no runtime needed)

| # | Task | Where | Effort |
|---|---|---|---|
| **C1** | Audit `embedded.zig` for mux compatibility (multi-pane, lifecycle, surface API) | `src/apprt/embedded.zig` (89,852 bytes) | 1d |
| **C2** | Trace `CoreSurface.queueIo` mailbox; write 1-pager | `src/Surface.zig` + new doc `docs/sessions/20261014-ghostty-native-mux/02_MAILBOX_INTEGRATION.md` | 1d |
| **C3** | Map event hook insertion points in GTK runtime | `src/apprt/gtk/` + new doc `docs/sessions/20261014-ghostty-native-mux/03_EVENT_HOOKS.md` | 4h |
| **C4** | Phase 1 architecture doc | new doc `docs/sessions/20261014-ghostty-native-mux/04_MUX_ARCHITECTURE.md` | 4h |
| **C5** | Mock mux prototype skeleton (compile-check only) | `src/apprt/ipc/mux_shell.zig` | 4h |

C1 + C2 are pre-requisites for Q1(b) (embedded-on-macOS option). C3 is pre-requisite for the operator decision (Q1(a) needs Linux box for validation; C3 specifies the menu swap surface).

### Phase 1 implementation tasks (1w+, blocked on Q1)

Per mux §5:

- New Zig binary `khostty-mux` (not a modification of `ghostty`).
- One `khostty-mux.sock` socket; agents connect here; mux fans out to per-instance `khostty.sock` sockets.
- Routing table: `(instance_id, pane_id) → client connection`.
- Protocol reuse: `protocol.zig` + `auth.zig` verbatim.
- New commands (deliberately few): `mux.list`, `mux.focus`, `mux.attach`/`mux.detach`, `mux.layout.save`/`mux.layout.restore`.
- Presenter: reuse `src/apprt/embedded.zig` to render panes inside a mux-owned window.

**GTD/E2E acceptance:** agent connects to mux socket, `mux.list` returns multiple instances, `mux.focus` routes keyboard to pane across instances, `mux.attach` survives client disconnect.

**Block:** Q1 (operator windowed-runtime decision).

### Phase 1 + lock ordering (carry-forward #23)

**File:** `src/apprt/ipc/pane.zig` documents strict `Manager → Broker` lock ordering + no-reentrancy. The mux shell introduces a new layer above this. Phase 1 architecture doc (C4) MUST include a "Lock Ordering" section specifying how the mux layer composes with the existing contract. This is **the single highest-risk design decision** in Phase 1 (mux §5 design risk #2).

---

## §5. Phase 3: Windows GUI (deferred per G3 decision)

Per state §3.2 + stubs §2: Windows GUI expansion is **deliberately deferred** until G3's windowing scaffold leaves `error.Unimplemented`. This is a program decision (recorded in `ROADMAP.md` + `20260916-fork-assessment/02_DEEP_WBS.md`), not an audit finding.

**If the operator lifts G3**, the work would be:

| # | Task | Where | Effort |
|---|---|---|---|
| W1 | Wire Windows runtime into `src/apprt.zig` comptime switch | `src/apprt.zig` | 1h |
| W2 | `App.zig` lifecycle (`init`/`registerWindowClass`/`run`/`terminate`/`wakeup`/`performAction`/`performIpc`/`redrawInspector`) — currently all `error.Unimplemented` | `src/apprt/windows/App.zig` | 1-2w |
| W3 | `Window.zig` HWND handle | `src/apprt/windows/Window.zig` | 1d |
| W4 | `surface.zig` GDI/Direct2D paint | `src/apprt/windows/surface.zig:92-94` | 1w |
| W5 | `renderer.zig` (or new GDI/DirectWrite/D2D file) | `src/apprt/windows/` (new file) | 1-2w |
| W6 | `keyboard.zig` modifier state (`GetKeyState`/`GetAsyncKeyState`/`ToUnicodeEx`) | `src/apprt/windows/keyboard.zig:46-52` | 1d |
| W7 | `mouse.zig` `TrackMouseEvent(TME_LEAVE)` | `src/apprt/windows/mouse.zig:42-48` | 1h |
| W8 | Named-pipe IPC transport (`ConvertStringSecurityDescriptorToSecurityDescriptorW`) | `src/apprt/windows/ipc.zig:117-163` | 1d |
| W9 | `mod.zig` `resourcesDir` returns actual paths | `src/apprt/windows/mod.zig:7-9` | 1h |
| W10 | Windows GUI launch verification on real hardware | (operator-only) | 1d |

**Total if lifted: 3-4 weeks.** Plus the windows runtime E2E test on a real Windows machine (operator-only).

**Not in the fwd-path roadmap per operator scope.** Recorded here for completeness.

---

## §6. Open carry-forwards — items needing operator action or decisions

### Operator-only (10m or less)

| # | Item | Why operator-only | Effort |
|---|---|---|---|
| O1 | PyPI `khostty_vt` trusted publisher registration | Requires operator's PyPI account | 10m |
| O2 | PyPI dispatch hook approval | Requires operator's PyPI account | 5m |
| O3 | SonarCloud `SONAR_TOKEN` secret set | Requires operator's SonarCloud account | 1m |
| O4 | SonarCloud inherited GitHub App uninstall | Requires operator's repo settings access | 1m |

**Total operator time: 17m.** Unblocks: Python binding publication (carry-forward #17, #22), SonarCloud scanning (carry-forward #18, #19).

### Operator decision (no time estimate — needs judgment)

| # | Question | Options |
|---|---|---|
| Q1 | **Windowed-runtime for Phase 1** | (a) Linux box with GTK; (b) `embedded.zig` surface-within-surface on macOS; (c) mock-only prototype, defer real runtime |
| Q2 | **`pane.focus` priority** | ship without focus (defer to fork post-1.0); or schedule upstream work |
| Q3 | **`pane.search` priority** | same as Q2 — out of fork-only scope |
| Q6 | **`ci16-fix`/`ci17-fix` cleanup verification** | verify against `ccfa79f2a`/`6da47d0c2` then delete; OR rebase onto current `main` |
| Q7 | **Lift G3 Windows GUI deferral?** | stay deferred; lift and start 3-4w Windows GUI work |
| Q8 | **Upstream drift cadence** | rebase cadence (none / weekly / per Phase); EGL BOTH-arms harness must re-run on every EGL-touching rebase |
| Q9 | **Fork-discipline CI guard** | add `tools/check-fork-discipline.zig` + CI job; or accept silent regression risk |

### Operator-pending (no action needed now)

| # | Item | Note |
|---|---|---|
| — | WSL `kooshapari-desk` r4 sync | Tailscale offline 2026-10-15; per binding, no further probes |
| — | Dependabot #1 (pytest CVE-2025-71176) | 3.10+ lane already patched; 3.8/3.9 lane deliberately left open |

---

## §7. What is explicitly OUT of scope (per operator)

| Excluded | Reason | Source |
|---|---|---|
| **Scaling** (multi-host, federation, cloud) | operator-excluded | operator 2026-10-17 |
| **Sunset** (deprecation, EOL signaling) | operator-excluded | operator 2026-10-17; SUNSET arc complete 2026-10-16T22:31Z |
| **User feedback** (after-launch telemetry, in-app surveys) | operator-excluded | operator 2026-10-17 |
| **Intent evolution** (new features beyond the existing G0-G10 scope) | operator-excluded | operator 2026-10-17 |
| Windows GUI expansion (G3) | program-deferred | `ROADMAP.md` |
| `bench/` (G8) | out of scope per `ROADMAP.md` | `ROADMAP.md` |
| Upstream-core API changes (focus-by-id, synchronous scan) | FORK-ONLY binding | operator 2026-10-15 |
| Publishing to `ghostty-org/ghostty` | FORK-ONLY binding | operator 2026-10-15 |
| Phase 2 (durable sessions + `pane.execute`) | not designed yet | state §9 #10 |
| Pytest 3.8/3.9 CVE-2025-71176 fix | 3.10+ patched; 3.9 left open by triage 2026-09-29 | state §5 #7 |

---

## §8. Effort budget for the operator's "as close to finish as possible" goal

| Phase | Effort | Operator blocks | Net available work |
|---|---:|---|---|
| Phase A — polish batch | **3h** | none | 7 low-risk tasks |
| Phase B — G4 wire-up | **5d** | GTK/Linux host (B1, B2, B4, B5) | 4h no-GTK + 4d GTK |
| Phase C — Phase 1 design | **2d** | none (audit + docs only) | 5 design tasks |
| Phase D — Phase 1 implementation | **1w+** | Q1 (windowed-runtime) + Linux box | blocked on Q1 |
| Phase E — upstream-core APIs | 1d + 1w+ | Q2, Q3 (out of fork scope) | blocked on operator commitment |
| Phase F — Windows GUI | 3-4w | Q7 (lift G3 deferral) | out of fwd-path scope |

### "As close to finish as possible" — minimum-viable completion

**Required:**
- Phase A (3h)
- Phase B non-GTK parts: B3 (1h) + B6 (1h) = **2h**
- Phase C design (2d, ~16h)
- O1-O4 operator actions (17m operator time)

**Total agent work: ~22h** (3h + 2h + 16h + small carry) over 3-4 working days.

**Total operator time: ~17m** for registry actions + ~10m for each Q1/Q2/Q3 decision (operator's call).

**Total calendar: 1 working week** if all operator decisions are made immediately and a Linux box is available.

### "As close to finish as possible" — with G4 actually reachable on macOS

**Additional requirement:** Q1(b) — verify `embedded.zig` can host multiple panes (Phase C1, 1d audit). If yes, Phase D implementation can target macOS via `embedded.zig` surface-within-surface. **Adds 1d to design + ~1w to implementation.**

### "As close to finish as possible" — with Windows GUI (if G3 lifted)

**Additional requirement:** Q7 — operator lifts G3 deferral. Adds **3-4w** (per Phase §5).

---

## §9. Suggested execution order

1. **Today (operator):** O1-O4 registry actions (~17m). Reads: `HANDOFF-20261015.md` (5m).
2. **Today (agent, parallel with #1):** Phase A polish batch (3h, low-risk, can be a single PR).
3. **Today (operator):** Q1 decision (5m) — picks the Phase 1 runtime path.
4. **Day 1-2 (agent):** Phase C design (16h) — answers the audit questions mux §8 lists.
5. **Day 1 (agent, parallel with #4):** B3 + B6 (2h) — non-GTK Phase B work.
6. **Day 2-3 (agent, blocked on Linux box if Q1=a):** B1 + B2 + B4 + B5 (4d) — Phase B runtime wire-up.
7. **Day 4-5 (agent):** Phase D implementation (1w+, blocked on Q1 result).
8. **Day 5 (operator):** merge any of the above PRs; arm the next 0.1.x release.

**Total calendar: 5 working days** if the operator makes decisions on Q1+Q6+Q7 within the first hour and a Linux box is reachable.

---

## §10. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Phase 0 "green" is shallower than it looks (signatures prove, not behavior) | Phase B1 GTK-on-Linux validation is the only true e2e |
| `pane.write` race fires the moment B1 lands | B2 must be co-shipped (state §6 + stubs MVP-LAZY #1) |
| Upstream EGL moves break the fork (`e37bee08a`-class) | EGL BOTH-arms synthetic harness (`69e955cfc`/`5055d2c17`) must re-run on every EGL-touching rebase (state §8 #8) |
| Fork-discipline is silent (a `src/terminal/` mod regresses upstream-merge-cheap property) | Carry-forward #24 — fork-discipline CI guard |
| `ci/zig-fork-tests` cannot fire on tag push (binding rule #6) | by design; PR-trigger is the safety net |
| `main` drift vs operator host inability to run GTK | `ci/zig-fork-tests.yml` covers Linux; `ci/test` runs on every push |
| PyPI v1 publish failure after trusted-publisher setup | Pre-flighted `publish-pypi.yml`; if it fails, operator-visible error |
| Build host at 96-98% disk (state §7) | `zig build` cold-cache is 27-30m; only one in flight at a time |
| Tailscale `kooshapari-desk` offline | r4 sync blocked; Linux box should be a different host (operator's call) |

---

## §11. Acceptance for the "as close to finish as possible" claim

The fork is "as close to finish as possible" when:

1. `git log origin/main -1` shows a HEAD with Phase A + Phase B non-GTK + Phase C docs merged.
2. `rg 'Server.bind' src/` returns ≥ 1 hit outside `src/apprt/ipc/`.
3. The 5 stale doc claims are refreshed (A1).
4. `zig build test-agent-ipc` passes; 3899/3925 tests pass (or 3925/3925 if A5 lands).
5. `wasm/package.json` is `0.1.0` (A6).
6. Stale branches deleted (A4).
7. `gh release list` shows a `0.1.1` or `0.2.0` with Phase A + B changelog.
8. PyPI shows `khostty_vt 0.1.0` (after O1-O2).

**Not required for the claim:** G4 actual runtime e2e on a real GTK Linux host (that is Phase B1); Phase 1 mux implementation (Phase D); Windows GUI (Phase F).

---

**End of FWD-PATH.**