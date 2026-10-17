# Khostty Final Audit — 2026-10-17

**Repo:** `/Users/kooshapari/CodeProjects/Phenotype/repos/khostty` (fork of `ghostty-org/ghostty`)
**Observed:** 2026-10-17T05:18Z · **Method:** synthesis of 4 sibling reports (read-only).
**Author:** VP-Eng (jcode orchestrator, tier-0 M3) · **Companion:** [`20261017-FWD-PATH.md`](20261017-FWD-PATH.md)

**Inputs (consolidated):**
- [`20261017-state.md`](20261017-state.md) — canonical current state, ~258 lines
- [`20261017-mux.md`](20261017-mux.md) — Phase 0/1 detail, 262 lines (stale on Phase 0 merge — it IS merged)
- [`20261017-stubs.md`](20261017-stubs.md) — 61 findings, 217 lines (stale on Phase 0 merge)
- [`20261017-usability.md`](20261017-usability.md) — CVP / MVP / intended user, 302 lines

**Conflict resolution rule (binding):** Where the 4 reports disagree, `state.md` is authoritative (it is the only one written after the Phase 0 merge). Both `mux.md` and `stubs.md` list "merge Phase 0 → main" as an open carry-forward; **Phase 0 merged via PR #15 at `ebc033eba` on 2026-10-15** and is now on `main`. Those two carry-forwards are void.

**Binding (operator 2026-10-15):** FORK-ONLY. No `gh pr/issue/discussion create` or `gh api POST/PATCH/DELETE` against `ghostty-org/ghostty` or any other upstream repo. Reading, copying, tracking, `zig build` against upstream: fine. Push to `KooshaPari/*`: fine.

**File status (binding rule #10):** This file is in `docs/audits/`, which is **untracked** by binding rule. Do not `git add` it.

---

## §1. Executive TL;DR

Khostty is **shippable as a library-first 0.1.0** (Rust + WASM + macOS app + upstream CLI IPC) and **not yet shippable as the agent-IPC story**. The agent-IPC modules are written (6,839 LOC, 458 tests, 12 wire commands) and wired into the build graph at `main` HEAD `4c9e4c57a` via `test-agent-ipc`, but `Server.bind` is not called from any runtime — `app_host.zig:79-87` returns `windowed = false` for every artifact except `.exe + .gtk`, which the macOS operator host cannot build. The remaining gap to a "finished" fork is therefore **the runtime wiring (1d GTK work)** + **two upstream-core API additions** (`pane.focus` focus-by-id, `pane.search` synchronous scan) that are out of scope for fork-only work. **Time-to-finish (operator-asked scope, excluding scaling/sunset/user-feedback/intent-evolution): ~3h polish batch + 1d GTK G4 wire-up + 2d Phase 1 design; runtime implementation of Phase 1 is blocked on the operator's windowed-runtime decision (Linux box / embedded-on-macOS / mock-only).**

---

## §2. Current state (one truth)

### Repo

| Property | Value | Source |
|---|---|---|
| `main` HEAD | `4c9e4c57a` | `git log -1 main` 2026-10-17 |
| `main` subject | `style(docs): prettier-format SUNSET.md (fixes main Lint & Format)` | state §1 |
| Phase 0 merge SHA | `ebc033eba` (PR #15, 2026-10-15) | `git log --grep 'Phase 0'` |
| `4c9e4c57a` is ahead of Phase 0 branch by | 20 commits (incl. SUNSET `11a788cd7`, PRs #17/19/31/32/16) | state §1 |
| Upstream base | Ghostty 1.3.2-dev @ `d4c88d8069912b653d707191388ca98e24751f12` | `docs/changelog/0.1.0.md` |
| Merge base w/ upstream | `b3dc3d794513c11633e7c3347935693957744e83` | stubs §1 |
| Fork ahead/behind | 252 / 366 (drift ~62 / 8h) | `UPSTREAM-DELTA.md` (2026-10-12) |
| Fork delta size | 336 files, 71,743 insertions | stubs §1 |
| Working tree | clean; `docs/audits/` and `docs/sessions/20261016-fork-reset/` untracked (binding rule #10) | state §2 |

### Branch inventory (state §2)

| Branch | HEAD | Action |
|---|---|---|
| `origin/main` | `4c9e4c57a` | current |
| `origin/test/agent-ipc-phase0` | `f786eda36` | **delete** (Phase 0 on main) |
| `origin/sync/upstream-20261015` | `0458af155` | delete (merged via `81903d0c5`) |
| `origin/lanes/a-s0-s4-20261016` | `7150ad536` | delete (merged) |
| `origin/stubs/khostty-lane-b-20261016` | `3a0a51ceb` | delete (landed) |
| `origin/stubs/khostty-lane-c-20261016` | `4a762c068` | delete (landed) |
| `origin/fix/khostty-prettier-20261016` | `6beb31df7` | delete (PR #32 merged) |
| local `ci/sonar-custom-workflow` | local | delete (PR #14 merged) |
| local `ci/zig-fork-tests` | `26da311e7` | delete (PR #17 merged) |
| local `ci16-fix` | local | **verify vs `ccfa79f2a` (PR #16)** before delete |
| local `ci17-fix` | local | **verify vs `6da47d0c2` (PR #17)** before delete |
| local `ci17-fix-realbase` | `434bbf782` | delete (merged via PR #19) |
| local `fix/egl-typed-platform-display` | local | delete (PR #19 merged) |
| local `fix/ipc-test-oversized-linux-rst{-v2}` | local | delete (landed via `25a4e3661`/`b735c59bc`/`984019cde`/`5fc36e1bc`/`3afae3dca`) |

### Build & test (state §3.1, mux §3)

- **Default targets:** `libghostty-vt` (shared + static), WASM module, macOS `.app`, docs/terminfo/themes/webdata, bench.
- **Windows runtime:** opt-in via `-Dapp-runtime=windows`. Default for Windows is `.none` (test-asserted at `src/apprt/runtime.zig:31-41`).
- **`test-agent-ipc` step:** `build.zig:472-508`. Wires `src/main_agent_ipc.zig` (89 lines, new) over 7 IPC modules. Caveat per `main_agent_ipc.zig:26-35`: on macOS/none, `windowed` vtable bodies are discarded at comptime; **build proves compilation + signatures, not runtime behavior**.
- **Test counts:** 83/85 build steps · 3899/3925 tests pass · 25 skipped · 1 pre-existing crash (`terminal.search.Thread.test_0` → `kqueue.zig:1916 .BADF => unreachable`, libxev race, characterized `evidence/flake-investigation-20261015.md`, **not fork-caused**).

### CI (state §3.7)

22 workflows total · 12 with no `actions/runs?event=push` history (fork Actions disabled by default per `SECURITY.md §8`).

| Workflow | PR / SHA | Status |
|---|---|---|
| `ci/test` | (legacy) | SUCCESS 2026-10-15T23:55Z |
| `ci/zig-fork-tests` | PR #17 / `6da47d0c2` | nightly 05:20 UTC, Zig 0.16.0 + SHA-256 pin |
| `ci/sonar-custom-workflow` | PR #14 / `223696488` | replaces failing inherited App; **`SONAR_TOKEN` secret + App uninstall pending operator** |
| `ci/pytest` | PR #16 / `ccfa79f2a` | runs 162 Python binding tests |

### Bindings / packaging (usability §2)

| Surface | Artifact | Status |
|---|---|---|
| C ABI `libghostty-vt` | `libghostty-vt.a/.dylib/.so` | DONE |
| Rust `khostty-vt` | crates.io 0.1.0 | DONE (install+run 2026-09-18) |
| Go `khostty-go` | local + examples | DONE (not observed on pkg.go.dev) |
| Python `khostty_vt` | local sdist/wheel | **DONE locally, PyPI unpublished** |
| WASM + JS/TS | npm `0.1.0` | DONE (npm published); **`wasm/package.json` is `0.0.0` (drift)** |
| macOS `.app` | `Khostty-0.1.0-macos.zip` | DONE signed, **not notarized** |
| Linux GTK `.deb` | `khostty_0.1.0_amd64.deb` | DONE (install-verified WSL Fedora 44, GUI-launch half-verified via Xvfb) |
| Windows `setup.exe` | `Khostty-0.1.0-windows-x86_64-setup.exe` | BUILT + INSTALLED + UNINSTALLED; **GUI window never launched**, only `+version` + ABI verified |
| Windows `ghostty.exe` runtime | installer drop | **SCAFFOLD** (`error.Unimplemented` for all windowing + IPC) |
| CLI `+new-window`/`+new-tab`/`+toggle-quick-term` | upstream IPC | DONE (narrow, 3 actions only) |
| Agent IPC v1 | `src/apprt/ipc/` modules | **IN PROGRESS on `main`** — modules wired, runtime not started |

### App runtime (state §3.2)

| Runtime | Status | Note |
|---|---|---|
| `embedded` (macOS AppKit) | DONE (upstream) | 89,852 bytes |
| `gtk` (Linux/FreeBSD) | DONE (upstream) | 28 files in `src/apprt/gtk/` |
| `browser` (wasm32) | DONE (upstream) | 155 bytes |
| `none` (headless) | DONE (upstream) | 539 bytes |
| `ipc` (CLI action channel) | DONE (upstream) | 3 actions: `new_window`, `new_tab`, `toggle_quick_terminal` |
| `windows` | **SCAFFOLD** (~3,300 lines, 11 files) | not in `src/apprt.zig` comptime switch |
| **agent v1** | **IN PROGRESS — wired, not started** | 6,839 LOC, 458 unit tests; server not bound by any runtime |

### Renderer (state §3.3)

- macOS Metal: upstream; bundle build unblocked 2026-09-18; `packaging/macos-app.sh --probe` returns `ok — metal compiler: usable`.
- OpenGL: upstream Linux/FreeBSD fallback; EGL type-regression fix landed via PR #19 (`795383086`) + `e37bee08a` + `431bc6fba`; preceded by BOTH-arms synthetic test (`69e955cfc`/`5055d2c17`).
- Windows: orphaned `windows/renderer.zig`. Not in scope per G3 deferral.

### IPC agent v1 surface (state §3.4, mux §2)

12 wire commands (usability §3 names 13 including `ping`):

`pane.create` (split vertical|horizontal) · `pane.close` · `pane.focus` · `pane.list` · `pane.write` · `pane.state` · `pane.search` · `pane.resize_split` · `pane.equalize` · `pane.zoom` · `events.subscribe` · `events.unsubscribe` · `ping` (the only unauthenticated command).

Auth: fail-closed token (32-byte hex, constant-time SHA-256). `KHOSTTY_IPC_TOKEN` env or `KHOSTTY_IPC_TOKEN_FILE` (fallback `ipc.token` beside socket). `protocol.md §5` + `auth.zig` agree.

Socket paths: macOS `~/Library/Caches/khostty/ipc.sock` · Linux/BSD `$XDG_RUNTIME_DIR/khostty/ipc.sock` (fallback `/tmp/khostty-{uid}/`) · Windows `%LOCALAPPDATA%\khostty\ipc.sock`. `KHOSTTY_IPC_SOCKET` override.

**Wiring status:** **wired into the build graph, NOT started from any runtime.** `rg 'Server.bind' src/` outside `src/apprt/ipc/` returns 0 hits (state §3.4).

**`pane.write` cross-thread parser access** (`app_host.zig:290-298`) violates `protocol.md §7` limit 1 (the file says it must become a `CoreSurface.queueIo` mailbox message before the surface is touched from a connection thread). **Must be fixed together with the runtime-wiring, not after.**

### Files exceeding 500-line hard limit (state §2)

| File | Lines | + over | Status |
|---|---:|---:|---|
| `src/apprt/ipc/handler.zig` | 1003 | +503 | intentional, design signal not block |
| `src/apprt/ipc/server.zig` | 1238 | +738 | intentional |
| `src/apprt/ipc/pane.zig` | 1209 | +709 | intentional |
| `src/apprt/ipc/protocol.zig` | 1129 | +629 | intentional |
| `src/apprt/ipc/events.zig` | 605 | +105 | intentional |
| `src/apprt/ipc/app_host.zig` | 574 | +74 | intentional |
| `src/apprt/ipc/auth.zig` | 526 | +26 | intentional |
| `src/apprt/windows/keyboard.zig` | 700 | +200 | intentional |

Full decomposition is plausible (`pane.zig` → `registry/host/payloads`, `handler.zig` → `dispatch/mapping`, `protocol.zig` → `types/codec/codec/errors`); **not done**, not on the fwd path (state §2 explicit).

### Session history (state §4)

| Date | Session | Outcome |
|---|---|---|
| 2026-09-16 | `20260916-fork-assessment/` | First handoff; deep WBS; 84/84 conformance |
| 2026-09-17 | `20260917-windows-apprt/` | Windows apprt scaffold; 0 Unimplemented removed |
| 2026-09-18 | `20260918-macos-app-unblock/` | macOS bundle built/signed/verified |
| 2026-09-24 | `0.1.0.md` changelog | Upstream base Ghostty 1.3.2-dev @ `d4c88d806` |
| 2026-09-27 | `20260927-0.1.0-reverify/` | All 6 success criteria PASS |
| 2026-09-29 | `20260929-release-lifecycle-refresh/` | read-only refresh |
| 2026-10-01 | `20261001-0.1.0-reverify/` | 8-check reverify |
| 2026-10-14 | `20261014-ghostty-native-mux/` | Phase 0 build wired; **PR #14720 + Discussions #14719/#14721 filed against `ghostty-org/ghostty` in error** |
| 2026-10-15 | `20261015-sync-validation/` | PR #19 BOTH-arms synthetic coverage; `ci/test` SUCCESS 2026-10-15T23:55Z; **Phase 0 PR #15 MERGED at `ebc033eba`** |
| 2026-10-15 (close) | `SESSION-CLOSE-20261015.md` | **khostty = fork-only; upstream PRs/discussions voided; memory `mem_1792099237411_16193025759751338582` saved; 6 AGENTS.md copies appended** |
| 2026-10-16 | `20261016-fork-reset/` (untracked) | Parent-context scan; SUNSET message written |
| 2026-10-16T22:31Z | SUNSET | Heartbeat loop sunset COMPLETE; no successor armed |

---

## §3. What's already done (the shippable list)

| Gate | Workstream | Status | Evidence |
|---|---|---|---|
| G0 | Repo & docs | DONE | 8 hand-curated docs (HANDOFF, ROADMAP, README, API, INSTALL, ARCH, FORK, UPSTREAM-DELTA, AGENT, PLATFORMS, BUILD, TESTING, SECURITY, GLOSSARY) |
| G1 | Conformance corpus | DONE | 84/84 across 8 categories |
| G2 | Conformance corpus (`conformance/`) | DONE | 9 files, ~6,000 lines (untracked in CI; see §6) |
| G3 | Windows runtime | SCAFFOLD | `src/apprt/windows/` 11 files, 3,300 lines; not in `src/apprt.zig` switch; **deferred per G3 program decision** |
| G4-Phase 0 | IPC build wiring | DONE | PR #15 / `ebc033eba` / `test-agent-ipc` / 3899/3925 / 1 pre-existing flake |
| G4-modules | IPC surface | DONE | 6,839 LOC, 458 tests, 12 commands, 7 events, `protocol.md` 458 lines |
| G5 | Rust `khostty-vt` | DONE | crates.io 0.1.0; install+test 2026-09-18 |
| G6 | Go + Python | LOCAL-DONE | Go present locally; Python sdist built; **PyPI unpublished** |
| G7 | WASM | DONE | npm 0.1.0 published; **`wasm/package.json` is `0.0.0` (drift)** |
| G9 | Docs | IN PROGRESS | 14 hand-curated docs |
| G10 | v0.1.0 release | DONE | GitHub release; PyPI pre-flighted but unpublished |
| — | macOS `.app` | DONE | `Khostty-0.1.0-macos.zip`; signed + interactive keystroke round-trip 2026-09-20; **not notarized** |
| — | Linux GTK `.deb` | DONE | install-verified on WSL Fedora 44 |
| — | Windows `setup.exe` | BUILT+INSTALLED+UNINSTALLED | GUI window never launched |
| — | EGL type-regression | FIXED | PR #19 / `795383086` + `e37bee08a` + `431bc6fba`; BOTH-arms synthetic harness (`69e955cfc`/`5055d2c17`) |
| — | SonarCloud fork-scoped workflow | DONE | PR #14 / `223696488`; **`SONAR_TOKEN` secret + App uninstall pending operator** |

**Shippable today:**
- `cargo add khostty-vt` → instant parser in Rust
- `npm install @khostty/libghostty-vt-wasm` → instant parser in browser/Node
- A built `Khostty.app` that runs on macOS, behaves like upstream Ghostty, exposes the 3 upstream `+new-window` / `+new-tab` / `+toggle-quick-term` actions over the existing narrow IPC.

---

## §4. What's actually unfinished (the real carry-forwards, de-duped)

State audit §6 is authoritative; mux/stubs audits' Phase 0 entries are voided.

| # | Item | Source of truth | Effort | Owner | Block |
|---|---|---|---|---|---|
| 1 | Fix 5 stale doc claims: `SECURITY.md:128-130,146-167,169-176,313,350`; `PLATFORMS.md:234-238`; `protocol.md:21` | state §6 + stubs IMMATURE #11-15 | **1h** | any agent | — |
| 2 | Fix `pkg/opengl/egl.zig:470-473` tautological `expectEqualStrings(comptimeArmName(X), comptimeArmName(X))` | stubs MVP-LAZY #12 | **10m** | any agent | — |
| 3 | Delete `src/apprt/windows/renderer.zig` (orphaned, 64 lines, 8 `Unimplemented`) | stubs IMMATURE #7 / dead-code #1 | **10m (delete)** or 1w+ (wire) | any agent | — |
| 4 | Delete stale local + remote branches (8 listed in state §2; verify `ci16-fix` / `ci17-fix` against `ccfa79f2a`/`6da47d0c2` first) | state §2 | **10m** | any agent | — |
| 5 | Fix `terminal.search.Thread.test_0` ABRT flake (catch `error.BadFileDescriptor` as teardown no-op at `src/terminal/search/Thread.zig:197`) | state §6 + mux §6 #3 | **1h** | any agent | — |
| 6 | Add `conformance/` + `wasm/` to CI (~6,000 lines of test surface unexercised) | state §6 + stubs IMMATURE #9-10 | **1h** | any agent | — |
| 7 | Add `max_connections` + per-connection rate limit to `src/apprt/ipc/server.zig` (1 MiB × unbounded = trivial local DoS once socket is live) | state §6 + stubs MVP-LAZY #9 | **1h** | any agent | — |
| 8 | **Wire the IPC server into the GTK runtime** (the actual G4 finish line; `Server.bind` from `gtk/App.zig`) | state §6 + stubs IMMATURE #1 + usability §5 #1 | **1d** | any agent | **GTK runtime on Linux** |
| 9 | Fix `pane.write` cross-thread parser access (`app_host.zig:290-298`) — must be done **with** #8, not after | state §6 + stubs MVP-LAZY #1 | **1d** | any agent | **GTK runtime on Linux** |
| 10 | Implement `pane.focus` (`app_host.zig:208-214`) | state §6 + stubs STUB #24 | **1d** | any agent | **upstream-core focus-by-id API** |
| 11 | Implement `pane.search` (`app_host.zig:216-232`) — needs synchronous scan API upstream does not have | state §6 + stubs STUB #25 | **1w+** | any agent | **upstream-core API** |
| 12 | Bump `wasm/package.json` to `0.1.0` (drift w/ npm published) | usability §5 #8 | **10m** | any agent | — |
| 13 | Phase 1 mux shell binary (windowed-runtime decision + Phase 1 architecture doc + `embedded.zig` audit + mailbox trace + event hook mapping) | state §6 #15 + mux §6 #4-8 | **2d design + 1w+ build** | any agent | **operator windowed-runtime decision** |
| 14 | Snapshot counters (`bell_count`, `exit_code`, `exit_signal`, `command`, `last_activity_ms`) — runtime tracks none; all `null` | stubs MVP-LAZY #3 | **1d** | any agent | GTK |
| 15 | Map `Surface.queueIo` mailbox for v1 (race-free shell injection; named in `app_host.zig:46-60`) | mux §6 #4 + usability §5 #3 | **1d** | any agent | GTK |
| 16 | Map 4 event publish hooks (title/child-exit/resize/bell) into GTK runtime callbacks | mux §6 #5 + usability §5 (deferred-delta) | **1d** | any agent | GTK |
| 17 | PyPI `khostty_vt` trusted publisher registration + dispatch hook approval | state §6 #13 + usability §6 | **10m** | **operator-only** | operator registry |
| 18 | SonarCloud `SONAR_TOKEN` secret set | state §6 #11 | **1m** | **operator-only** | operator registry |
| 19 | SonarCloud inherited App uninstall | state §6 #12 | **1m** | **operator-only** | operator registry |
| 20 | Windows GUI expansion (G3 windowing scaffold + DirectWrite + D2D) | state §3.2 + stubs §2 #1-7 | **3-4w** | any agent | **G3 deferral program decision** (out of fwd-path scope per operator) |
| 21 | `bench/` (G8) — `-Demit-bench` is upstream tooling; not a fork deliverable | state §3.1 | n/a | n/a | **out of scope** |
| 22 | PyPI v1 publish | state §6 #13 | **10m** | **operator-only** after #17 | operator |
| 23 | Lock ordering contract for mux layer (`Manager → Broker` documented in `pane.zig`; mux needs to compose) | state §8 #5 + mux §8 #7 | **1d design** | any agent | — |
| 24 | Fork-discipline CI guard (no `tools/check-fork-discipline.zig`; a future `src/terminal/` mod silently regresses the upstream-merge-cheap property) | usability §7 #7 | **1d** | any agent | — |
| 25 | BOTH-arms synthetic harness for EGL re-run on every rebase (defense vs `e37bee08a`-class upstream moves) | state §8 #8 | **10m re-run** | any agent | — |
| 26 | `20261016-fork-reset/00_AUDIT.md` (9,397 bytes, untracked) is the authoritative "SUNSET arc" record | state §8 #11 | n/a (read) | any agent | — |

**The "post-SUNSET polish" batch** is #1 + #2 + #3 + #4 + #5 + #12 = **~3h of low-risk cleanup** that should land before any new feature work begins. State audit §6 #16 confirms.

---

## §5. CVP / MVP status (consolidated from `usability.md`)

### Intended user (inferred)

> A developer who wants to **embed Ghostty's terminal VT engine in their own application** (Rust, Go, Python, C, or browser/Node via WASM) and, as a follow-on, drive a hosted Ghostty instance from an AI agent over a JSON IPC channel. The GUI terminal is upstream, not a Khostty product.

The repo never states a one-line intended user; this is the closest evidence from `HANDOFF-20261015.md` + `FORK.md §1` + the binding manifest set.

### CVP (3 layers, priority order)

1. **"Library first."** Polyglot FFI over Ghostty's VT layer so third-party apps can parse/render/search/snapshot/inject without forking the GUI. Headline: one C ABI (`include/ghostty/vt.h`, 203 `GHOSTTY_API` functions across 30 module headers) consumed by Rust/Go/Python/JS-TS.
2. **"Drive a running terminal from an agent."** Typed JSON IPC v1 over Unix sockets, 13 commands (`ping`, `pane.*`, `events.*`), fail-closed token auth, async event broker.
3. **"Windows-native Ghostty."** A Win32 standalone app runtime — upstream does not ship.

### MVP scoring (per AGENTS.md / PLATFORMS.md honest matrix)

| G | Workstream | Claim | Reality on `main` | Reality on `test/agent-ipc-phase0` (now stale — Phase 0 on main) |
|---|---|---|---|---|
| G0 | Repo & docs | DONE | DONE | DONE |
| G1 | Conformance | DONE | DONE | DONE |
| G2 | `conformance/` | DONE | DONE | DONE |
| G3 | Windows runtime | SCAFFOLD | SCAFFOLD (`windowed=false`; all ops `error.Unimplemented`) | same |
| G4 | Agent IPC v1 | IN PROGRESS | 6 modules + protocol.md; **no `Server.bind` caller**; `windowed=true` only for `.gtk` | modules wired; `pane.focus`/`pane.search` `error.Unsupported` even on GTK; `pane.write` parser-direct not pty-direct |
| G5 | Rust `khostty-vt` | IN PROGRESS | DONE; gap: no safe `text()`/`html()` formatter wrapper | same |
| G6 | Go + Python | IN PROGRESS | local trees present; PyPI unpublished | same |
| G7 | WASM | IN PROGRESS | DONE; `wasm/package.json` `0.0.0` drift | same |
| G8 | Benchmarks | NOT STARTED | no `bench/` in tree; `-Demit-bench` = upstream tooling | same |
| G9 | Docs | IN PROGRESS | 14 hand-curated docs | same |
| G10 | v0.1.0 release | DONE | GitHub release; PyPI pre-flighted but unpublished | same |

**Adjusted score:** 7/11 landed · 2/11 reachable-but-rough · 1/11 scaffold · 1/11 not-started.

### MVP a developer can consume today

- `cargo add khostty-vt` → instant parser in Rust.
- `npm install @khostty/libghostty-vt-wasm` → instant parser in browser/Node.
- A built `Khostty.app` that runs on macOS, behaves like upstream Ghostty, exposes 3 upstream actions over the existing narrow IPC.

The "agent drives a GUI terminal" story is **not in the MVP today**. `docs/AGENT.md §4` is explicit: *"do not build against it, and do not report it as shipped."*

### Top-5 user-facing risks (usability §5)

1. **Agent IPC unreachable on macOS.** `rg 'Server.bind' src/` returns 0 hits outside `server.zig` itself. Even if wired, `app_host.zig:79-87` returns `windowed=false` for non-`.exe + .gtk`.
2. **`pane.focus` and `pane.search` return `unsupported` even on GTK.** A protocol that advertises 13 commands but delivers only 11 on its single supported runtime is a CVP gap to be honest about in user docs.
3. **`pane.write` is parser-direct, not pty-direct.** A user who types into the pane concurrently with an agent `pane.write` sees interleaving or wrong surface.
4. **C ABI is unstable.** `include/ghostty/vt.h` opens with "incomplete, work-in-progress API"; consumers must pin a revision.
5. **Borrowed-pointer discipline.** `GhosttyString` and row/cell handles are borrowed — valid until next mutating call.

---

## §6. Stubs / mocks / dead code (consolidated, priority order)

State §6 + stubs §2-§7 + usability §5. Phase 0 merge voids all "merge Phase 0" carry-forwards.

### Highest priority (top-10 from stubs §8, after Phase 0 dedup)

| Rank | Finding | Effort | Why |
|---|---|---|---|
| 1 | Refresh 5 stale doc claims (`SECURITY.md:128-130,146-167,169-176,313,350`; `PLATFORMS.md:234-238`; `protocol.md:21`) | 1h | docs *understate* the code; any plan from them over-estimates work |
| 2 | Fix `egl.zig:470-473` tautological `expectEqualStrings(comptimeArmName(X), comptimeArmName(X))` | 10m | false control; counts as covered |
| 3 | Delete or wire `windows/renderer.zig` (64 orphaned lines, 8 `Unimplemented`) | 10m (delete) | cleanest dead-code finding |
| 4 | Wire IPC server into GTK runtime (the whole point of the mux) | 1d | everything else in `apprt/ipc/` is dead weight until `Server.bind` is called |
| 5 | Fix `pane.write` cross-thread parser access (`app_host.zig:290-298`) — must be done **with** rank 4 | 1d | latent data race the moment rank 4 lands |
| 6 | Add `max_connections` + rate limit (`server.zig`) | 1h | 1 MiB × unbounded = trivial local DoS |
| 7 | `pane.focus` (`app_host.zig:208-214`) — needs upstream-core focus-by-id | 1d | highest-value agent command after create/write |
| 8 | Add `conformance/` and `wasm/` to CI | 1h | ~6,000 lines of test surface unexercised |
| 9 | `pane.search` (`app_host.zig:216-232`) — needs upstream-core synchronous scan API | 1w+ | highest user value; genuine design work |
| 10 | Bump `wasm/package.json` to `0.1.0` | 10m | prevents accidental downgrade publish |

### Other stubs (correctly scoped, deferred)

- **Windows apprt scaffold** (`src/apprt/windows/`, 11 files, 3,300 lines): 23 stub entries, every one covered by a test that **asserts the stub** (`interface.zig:39-45` `expectError(error.Unimplemented, ...)`). Per `ROADMAP.md` / `20260916-fork-assessment/02_DEEP_WBS.md`: deliberately deferred until windowing scaffold leaves `error.Unimplemented`. **Program decision, not audit finding.**
- **`fake_host.zig`** (446 lines, IPC test backend): in-memory VT, header says "exercise real parsing rather than a stub that echoes its input back." Correctly scoped.
- **`opengl_c_stub.zig`** (88 lines, `test/egl-platform-display/`): synthetic `opengl_c` for compile-only EGL tests on macOS. 10m delete when `libEGL.dylib` present.
- **`bench_search_stub.c`** (24 lines): capability-absent fallback for unlinked lib. 10m delete when upstream exports `ghostty_search_new`.

### Honest MVP-LAZY (state-of-the-world, not bugs)

| # | Location | Lazy | Effort |
|---|---|---|---|
| 1 | `app_host.zig:290-298` | `writeToParser` calls `stream.nextSlice(data)` directly from connection thread | 1d (rank 5) |
| 2 | `app_host.zig:100,102` | `split_wait_ms=500`, `split_poll_interval_ms=2` magic budget | 1h |
| 3 | `app_host.zig:479-489` | `bell_count`, `exited`, `exit_code`, `exit_signal`, `command`, `last_activity_ms` all `null` | 1d (carry-forward #14) |
| 4 | `app_host.zig:358-361` | `pane.create` with no `parent` silently uses *focused* surface | 1h |
| 5 | `app_host.zig:392-398` | `std.Io.sleep(...) catch break` silently exits create-poll loop | 10m |
| 6 | `app_host.zig:568-574` | `mapActionError` collapses every non-OOM error to `error.Internal` | 1h |
| 7 | `server.zig:113-120` | pusher-thread spawn failure logs warning, continues | 1h |
| 8 | `server.zig:52-56` | `event_poll_ms=25`, `push_batch=32` hardcoded; polling instead of condvar (documented reason: `std.Io.net` reads take no timeout) | 1d |
| 9 | `server.zig` | No `max_connections`, no rate limit | 1h (rank 6) |
| 10 | `auth.zig:285` | creates token file with `0o600` but never re-validates mode of existing token file | 10m |
| 11 | `auth.zig` | One token grants **all** commands; no per-command/per-pane scope (acknowledged in `SECURITY.md`) | 1d |
| 12 | `pkg/opengl/egl.zig:470-473` | `expectEqualStrings(comptimeArmName(X), comptimeArmName(X))` self-compare | 10m (rank 2) |
| 13 | `khostty-python/khostty_vt/_terminal_options.py:61-82` | 20 `TerminalOption` members raise `GhosttyError` | 1w+ (UPSTREAM-INHERITED) |
| 14 | `khostty-go/examples/agent/main.go:178` + `khostty-python/examples/agent.py:160` | `8x16` placeholder cell metric | 10m |

### Dead code

| # | Location | What | Action |
|---|---|---|---|
| 1 | `src/apprt/windows/renderer.zig` | 64 lines, 0 importers, `surface.paint()` does not call it | **delete** (rank 3) |
| 2 | `src/apprt/windows/win32api.zig:60-67` | 85 lines of FFI declarations nothing references | leave (deferred with Windows) |
| 3 | `src/apprt/windows/{input,keyboard,mouse}.zig` | 1,447 lines, reachable only from test root | leave (deferred with Windows) |
| 4 | `src/apprt/ipc/mod.zig:223,234` | `unreachable` in `@sizeOf` and `Value()` comptime switches | not dead (exhaustive) |
| 5 | `src/apprt/ipc/protocol.zig:884-888`, `server.zig:881` | `pane.explode` / `"events":["explode"]` appear only in negative tests | not dead (rejection coverage) |

### Hardcoded values that should be config (stubs §6)

| Location | Value | Action |
|---|---|---|
| `auth.zig:204` | `/tmp/khostty-{uid}` socket-dir fallback (weakest isolation, per `SECURITY.md`) | config |
| `auth.zig:188` | `{HOME}/Library/Caches/khostty` | config |
| `auth.zig:193` | `{LOCALAPPDATA}\khostty` | config |
| `auth.zig:198` | `{XDG_RUNTIME_DIR}/khostty` | config |
| `app_host.zig:100` | `split_wait_ms: u64 = 500` | config |
| `app_host.zig:102` | `split_poll_interval_ms: u64 = 2` | config |
| `server.zig:53` | `event_poll_ms: u64 = 25` | config |
| `server.zig:56` | `push_batch: usize = 32` | config |
| `protocol.zig:26` | `max_frame_bytes = 1024 * 1024` (1 MiB / connection) | config |
| `bench/run.sh:98` | `--note "repo=/Users/kooshapari/..."` (machine-specific, committed) | fix or delete |
| `khostty-go/examples/agent/main.go:178` + `khostty-python/examples/agent.py:160` | `8x16` placeholder cell metric | rank-10-adjacent |
| `.github/workflows/zig-fork-tests.yml` | Zig 0.16.0 + hardcoded SHA-256 (acceptable pin, duplicated 2 jobs) | acceptable |

---

## §7. Forward path (prioritized 10m task batch + larger epics)

Detailed task breakdown in [`20261017-FWD-PATH.md`](20261017-FWD-PATH.md). Summary:

### Phase A — Post-SUNSET polish batch (~3h, all 10m–1h)

| # | Task | File:line | Effort |
|---|---|---|---|
| A1 | Refresh 5 stale doc claims | `SECURITY.md:128-130,146-167,169-176,313,350`; `PLATFORMS.md:234-238`; `protocol.md:21` | 1h |
| A2 | Fix EGL tautological assertion | `pkg/opengl/egl.zig:470-473` | 10m |
| A3 | Delete orphaned `windows/renderer.zig` | `src/apprt/windows/renderer.zig` | 10m |
| A4 | Verify `ci16-fix`/`ci17-fix` then delete stale local + remote branches | (per state §2) | 10m |
| A5 | Fix `terminal.search.Thread.test_0` ABRT flake | `src/terminal/search/Thread.zig:197` | 1h |
| A6 | Bump `wasm/package.json` to `0.1.0` | `wasm/package.json` | 10m |
| A7 | Delete `src/apprt/windows/win32api.zig` if confirmed unused | `src/apprt/windows/win32api.zig:60-67` | 10m (verify first) |

### Phase B — G4 wire-up (1d, requires GTK/Linux)

| # | Task | File:line | Effort |
|---|---|---|---|
| B1 | Wire IPC `Server.bind` from GTK runtime | `src/apprt/gtk/App.zig` (call site TBD via audit subagent) | 1d |
| B2 | Fix `pane.write` cross-thread parser access (mailbox hop via `Surface.queueIo`) | `src/apprt/ipc/app_host.zig:290-298` | 1d (with B1) |
| B3 | Add `max_connections` + rate limit | `src/apprt/ipc/server.zig` | 1h |
| B4 | Map 4 event publish hooks (title/child-exit/resize/bell) into GTK callbacks | `src/apprt/gtk/` (file:line TBD) | 1d |
| B5 | Snapshot counters (bell/exit/command/last_activity) | `src/apprt/ipc/app_host.zig:479-489` | 1d |
| B6 | Add `conformance/` + `wasm/` to CI | `.github/workflows/` | 1h |

### Phase C — Phase 1 mux shell design (2d, blocked on operator decision)

| # | Task | File:line | Effort |
|---|---|---|---|
| C1 | Audit `embedded.zig` for mux compatibility (multi-pane, lifecycle, surface API) | `src/apprt/embedded.zig` | 1d |
| C2 | Trace `CoreSurface.queueIo` mailbox; write 1-pager | `src/Surface.zig` | 1d |
| C3 | Map event hook insertion points in GTK runtime | `src/apprt/gtk/` | 4h |
| C4 | Phase 1 architecture doc (binary name, sockets, routing table, command surface, lock ordering) | new doc | 4h |
| C5 | Mock mux prototype skeleton (compile-check only) | `src/apprt/ipc/mux_shell.zig` | 4h |

### Phase D — Phase 1 implementation (1w+, blocked on operator decision + Linux box)

Implementation work; out of scope for the 3h polish batch.

### Phase E — Capabilities needing new upstream-core APIs (blocked on upstream)

| # | Task | Upstream change | Effort |
|---|---|---|---|
| E1 | `pane.focus` focus-by-id | core surface-focus API | 1d |
| E2 | `pane.search` synchronous scan | core scan API | 1w+ |

### Phase F — Out of fwd-path scope (operator decision: deferred)

- Windows GUI expansion (G3 scaffold → real runtime): 3-4w, requires Windows hardware, requires operator decision to lift G3 deferral.
- `bench/` (G8): out of scope per `docs/roadmap.md`.

---

## §8. Open questions for the operator (decisions only the operator can make)

| # | Decision | Affects | Options |
|---|---|---|---|
| Q1 | **Windowed-runtime for Phase 1** | Phase 1 mux shell implementation (carry-forward #13, design block C1-C5) | (a) Linux box with GTK; (b) `embedded.zig` surface-within-surface on macOS; (c) mock-only prototype, defer real runtime |
| Q2 | **`pane.focus` priority** | Carry-forward #10; needs upstream-core focus-by-id API | ship without focus (defer to fork post-1.0); or schedule upstream work |
| Q3 | **`pane.search` priority** | Carry-forward #11; needs upstream-core synchronous scan API | same as Q2 — out of fork-only scope |
| Q4 | **PyPI trusted publisher registration + dispatch hook approval** | Carry-forward #17, #22 | 10m operator action (unblocks Python binding to registry) |
| Q5 | **SonarCloud `SONAR_TOKEN` secret + inherited App uninstall** | Carry-forward #18, #19 | 1m + 1m operator action |
| Q6 | **Branch cleanup verification — `ci16-fix`/`ci17-fix`** | Carry-forward #4 (Phase A4) | verify against `ccfa79f2a`/`6da47d0c2` then delete; OR rebase onto current `main` |
| Q7 | **Lift G3 Windows GUI deferral?** | Phase F (out of fwd-path scope) | stay deferred; lift and start 3-4w Windows GUI work |
| Q8 | **Upstream drift cadence** | carry-forward risk on every rebase | rebase cadence (none / weekly / per Phase); EGL BOTH-arms harness must re-run on every EGL-touching rebase (state §8 #8) |
| Q9 | **Fork-discipline CI guard** | Carry-forward #24 | add `tools/check-fork-discipline.zig` + CI job; or accept silent regression risk |

---

## §9. Gaps remaining (what's still unanswerable)

These items cannot be answered from the 4 reports alone; they require either operator input or downstream agent work.

1. **Embedded-on-macOS multi-pane feasibility.** `src/apprt/embedded.zig` is upstream-inherited at 89,852 bytes; no one has verified it can host multiple panes or that its lifecycle matches the mux's needs (usability §5 + mux §8 #3). Required for Q1(b).
2. **`CoreSurface.queueIo` mailbox semantics.** `app_host.zig:46-60` documents the contract; the actual implementation in `src/Surface.zig` has not been traced (state §8 #4 + mux §8 #4). Required for carry-forward #9.
3. **GTK runtime event hook insertion points.** The 4 publish hooks (title/child-exit/resize/bell) need file:line locations in `src/apprt/gtk/` (mux §6 #5 + §8 #5). Required for carry-forward #16.
4. **Phase 1 lock-ordering contract.** `pane.zig` documents `Manager → Broker` ordering. The mux shell will introduce a new layer; how the locks compose is unanalyzed (state §8 #5 + mux §8 #7). Required for Phase C4 architecture doc.
5. **Upstream-core API shape for `pane.focus`/`pane.search`.** Both commands require upstream surface-focus-by-id and synchronous-scan primitives that do not currently exist (state §8 #4). Required for Phase E.
6. **WSL desk / Tailscale availability.** `kooshapari-desk` offline 2026-10-15; r4 WSL sync blocked; no remote wake; per binding rule, no further probes (state §5 #8 + #7).
7. **PyPI publication mechanics.** Workflow pre-flighted; trusted publisher + dispatch hook approval pending operator (carry-forward #17, #22).
8. **`src/apprt.zig` comptime switch for Windows runtime.** When G3 is lifted, the wiring-into-`src/apprt.zig` change is required; not researched in any report (state §3.2).
9. **Pytest 3.8/3.9 lane CVE-2025-71176.** Dependabot #1, deliberately left open; not actionable on the 3.8/3.9 lane; 3.10+ already resolves to patched 9.1.1 (state §5 #7).
10. **Phase 2 design (durable sessions + `pane.execute` pty injection).** Mentioned in `20261014-ghostty-native-mux/00_SESSION_OVERVIEW.md` (mux §5 phase summary) but no design doc exists. Blocked on #2 + #5 above.

---

**End of FINAL-AUDIT.**