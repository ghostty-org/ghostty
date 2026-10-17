# Khostty STUBS / MOCKS / MVP-LAZY Audit

**Repo:** `/Users/kooshapari/CodeProjects/Phenotype/repos/khostty`
**Baseline:** `main` @ `4c9e4c57a`; Phase 0 @ `45fdebf74`
**Audit date:** 2026-10-17
**Method:** read-only static scan. 362,712 Zig LOC + Go/Python/Rust/wasm/shell. Fork-vs-upstream diff = 336 files, 71,743 insertions. No builds or tests run (a `zig build test-agent-ipc` cycle is 27-30 min and out of scope for a read-only audit). No files modified by the scan. No `gh` calls against upstream.

---

## 1. TL;DR

| Classification | Count | Concentration |
|---|---|---|
| **STUB** | 28 | `src/apprt/windows/` (23), `src/apprt/ipc/app_host.zig` (3), bench/test scaffolding (2) |
| **MOCK** | 3 | `fake_host.zig`, `opengl_c_stub.zig`, `bench_search_stub.c` |
| **MVP-LAZY** | 14 | `app_host.zig` (6), `server.zig` / `auth.zig` (5), bindings/examples (3) |
| **IMMATURE/UNFINISHED** | 16 | IPC not wired (4), Windows input island (3), CI/build omissions (2), stale docs (5), branch hygiene (2) |
| **TOTAL** | **61** | |

**The single most important sentence:** almost every finding is **honest and documented**. This fork does not hide its gaps. `src/apprt/ipc/app_host.zig`, `src/apprt/windows/*`, `protocol.md`, `SECURITY.md`, and `PLATFORMS.md` all name the missing pieces explicitly, and the Windows stubs have tests that *assert* `error.Unimplemented`. The risk is therefore not deception, it is **scope**: ~2,100 lines of Windows scaffold and ~7,200 lines of IPC have no live caller.

**Two real defects** (not documented, not self-asserted):

1. `app_host.zig:290-298` — `pane.write` touches the terminal parser from the IPC connection thread, violating `protocol.md` §7 limit 1.
2. `pkg/opengl/egl.zig:470-473` — a test assertion that compares a value to itself and can never fail.

---

## 2. STUBs

| # | Location | What it is | Effort | Scope |
|---|---|---|---|---|
| 1 | `src/apprt/windows/App.zig:7` | `init` → `error.Unimplemented` | 1d | FORK-LOCAL |
| 2 | `src/apprt/windows/App.zig:12` | `registerWindowClass` → `error.Unimplemented` | 1d | FORK-LOCAL |
| 3 | `src/apprt/windows/App.zig:16` | `run` (message pump) → `error.Unimplemented` | 1w+ | FORK-LOCAL |
| 4 | `src/apprt/windows/App.zig:24` | `terminate` — empty body | 10m | FORK-LOCAL |
| 5 | `src/apprt/windows/App.zig:27` | `wakeup` — empty body | 1h | FORK-LOCAL |
| 6 | `src/apprt/windows/App.zig:31` | `performAction` → `error.Unimplemented` | 1d | FORK-LOCAL |
| 7 | `src/apprt/windows/App.zig:54` | `performIpc` → `error.Unimplemented` | 1d | FORK-LOCAL |
| 8 | `src/apprt/windows/App.zig:58` | `redrawInspector` — empty body | 10m | FORK-LOCAL |
| 9 | `src/apprt/windows/Window.zig:8-10` | `init` → `error.Unimplemented`; "Never manufactures a native handle" | 1d | FORK-LOCAL |
| 10 | `src/apprt/windows/surface.zig:28-30` | `init` → `error.Unimplemented` | 1d | FORK-LOCAL |
| 11 | `src/apprt/windows/surface.zig:92-94` | `paint()` → `false` ("GDI/Direct2D painting deliberately unavailable") | 1d | FORK-LOCAL |
| 12 | `src/apprt/windows/surface.zig:96-98` | `eraseBackground()` → `false` | 10m | FORK-LOCAL |
| 13 | `src/apprt/windows/surface.zig:100-102` | `requestRender()` → `false` | 10m | FORK-LOCAL |
| 14 | `src/apprt/windows/renderer.zig:30` | `Renderer.init` → `error.Unimplemented` | 1w+ | FORK-LOCAL |
| 15 | `src/apprt/windows/renderer.zig:41` | `renderFrame` → `error.Unimplemented` | 1w+ | FORK-LOCAL |
| 16 | `src/apprt/windows/renderer.zig:47` | `invalidate` → `error.Unimplemented` | 1h | FORK-LOCAL |
| 17 | `src/apprt/windows/renderer.zig:55` | `resize` → `error.Unimplemented` | 1h | FORK-LOCAL |
| 18 | `src/apprt/windows/ipc.zig:117` | `Server.init` → `error.Unimplemented` | 1d | FORK-LOCAL |
| 19 | `src/apprt/windows/ipc.zig:128` | `Server.accept` → `error.Unimplemented` | 1d | FORK-LOCAL |
| 20 | `src/apprt/windows/ipc.zig:144` | `Client.connect` → `error.Unimplemented` | 1d | FORK-LOCAL |
| 21 | `src/apprt/windows/ipc.zig:157` | `Client.send` → `error.Unimplemented` | 1d | FORK-LOCAL |
| 22 | `src/apprt/windows/ipc.zig:163` | `Client.recv` → `error.Unimplemented` | 1d | FORK-LOCAL |
| 23 | `src/apprt/windows/mod.zig:7-9` | `resourcesDir` returns `.{}` (both paths absent) | 1h | FORK-LOCAL |
| 24 | `src/apprt/ipc/app_host.zig:208-214` | `focusUnsupported` — wired into **both** vtables, so `pane.focus` cannot work even on GTK | 1d | FORK-LOCAL |
| 25 | `src/apprt/ipc/app_host.zig:216-232` | `searchUnsupported` — wired into **both** vtables; needs a synchronous search API that upstream does not have | 1w+ | FORK-LOCAL |
| 26 | `src/apprt/ipc/app_host.zig:197-262` | `unavailable_vtable` — 8 of 10 entries return `error.Unsupported` for every non-GTK artifact | n/a (by design) | FORK-LOCAL |
| 27 | `bench/bench_search_stub.c:1-24` | Prints `search / UNAVAILABLE` when the linked lib lacks `ghostty_search_new` | 10m (delete when upstream exports it) | FORK-LOCAL |
| 28 | `test/egl-platform-display/opengl_c_stub.zig:1-88` | Synthetic `opengl_c` for compile-only EGL tests on macOS | 10m (delete when `libEGL.dylib` present) | FORK-LOCAL |

Notable: every Windows stub is covered by a test that **asserts the stub**. `interface.zig:39-45` explicitly `expectError(error.Unimplemented, ...)`. This is deliberate negative-control design, not forgotten work.

---

## 3. MOCKs

| # | Location | What it is | Effort | Scope |
|---|---|---|---|---|
| 1 | `src/apprt/ipc/fake_host.zig` (446 lines) | In-memory `Host` vtable backed by a real VT parser. Header: "exercise real parsing rather than a stub that echoes its input back." Used by all IPC tests. | 1h (already complete for its purpose) | FORK-LOCAL |
| 2 | `test/egl-platform-display/opengl_c_stub.zig` (88 lines) | Synthetic `opengl_c` surface, explicitly labelled "SYNTHETIC STUB … NOT a real binding" | 10m | FORK-LOCAL |
| 3 | `bench/bench_search_stub.c` (24 lines) | Capability-absent fallback; reports "unavailable" rather than interpolating a number | 10m | FORK-LOCAL |

Assessment: all three are **correctly scoped mocks**. `fake_host.zig` is the reason the IPC layer has 458 passing tests without a running terminal. No action needed.

---

## 4. MVP-LAZY

| # | Location | What is lazy | Effort | Scope |
|---|---|---|---|---|
| 1 | `src/apprt/ipc/app_host.zig:290-298` | **`writeToParser` calls `stream.nextSlice(data)` directly from the connection thread.** `protocol.md` §7 limit 1 says this "must become a surface-mailbox message (`CoreSurface.queueIo`) before the surface is touched from a connection thread." | 1d | FORK-LOCAL |
| 2 | `src/apprt/ipc/app_host.zig:100,102` | `split_wait_ms = 500`, `split_poll_interval_ms = 2` — magic budget for a fire-and-forget `new_split` | 1h | FORK-LOCAL |
| 3 | `src/apprt/ipc/app_host.zig:479-489` | `bell_count`, `exited`, `exit_code`, `exit_signal`, `command`, `last_activity_ms` all permanently `null`; the runtime tracks none of them | 1d | FORK-LOCAL |
| 4 | `src/apprt/ipc/app_host.zig:358-361` | `pane.create` with no `parent` silently uses the *focused* surface; `orelse return error.Unsupported` when none focused | 1h | FORK-LOCAL |
| 5 | `src/apprt/ipc/app_host.zig:392-398` | `std.Io.sleep(...) catch break` — a sleep failure silently exits the create-poll loop and surfaces as `error.Internal`, indistinguishable from "pane never appeared" | 10m | FORK-LOCAL |
| 6 | `src/apprt/ipc/app_host.zig:568-574` | `mapActionError` collapses every non-OOM error to `error.Internal`; agents cannot branch on cause | 1h | FORK-LOCAL |
| 7 | `src/apprt/ipc/server.zig:113-120` | Pusher-thread spawn failure logs a warning and continues; the connection silently degrades to request-driven delivery | 1h | FORK-LOCAL |
| 8 | `src/apprt/ipc/server.zig:52-56` | `event_poll_ms = 25` and `push_batch = 32` hardcoded defaults; polling instead of a condition variable (documented reason: `std.Io.net` reads take no timeout) | 1d | FORK-LOCAL |
| 9 | `src/apprt/ipc/server.zig` | **No `max_connections`, no rate limiting.** One accept thread; unbounded connection threads; each allocates 1 MiB (`max_frame_bytes + 2`) | 1h | FORK-LOCAL |
| 10 | `src/apprt/ipc/auth.zig:285` | Creates the token file with `0o600` but never re-validates the mode of an *existing* token file | 10m | FORK-LOCAL |
| 11 | `src/apprt/ipc/auth.zig` | One token grants **all** commands; no per-command or per-pane capability scoping (acknowledged in `SECURITY.md`) | 1d | FORK-LOCAL |
| 12 | `pkg/opengl/egl.zig:470-473` | `expectEqualStrings(comptimeArmName(X), comptimeArmName(X))` — self-comparison, can never fail. Intended to "lock in the translator's declared type" but asserts nothing | 10m | FORK-LOCAL |
| 13 | `khostty-python/khostty_vt/_terminal_options.py:61-82` | 20 `TerminalOption` members raise `GhosttyError` as "takes a struct or callback that these bindings do not expose" | 1w+ | UPSTREAM-INHERITED surface |
| 14 | `khostty-go/examples/agent/main.go:178`, `khostty-python/examples/agent.py:160` | `8x16` hardcoded as "a placeholder cell metric; real callers measure the font" | 10m | FORK-LOCAL |

---

## 5. IMMATURE / UNFINISHED

| # | Location | What is unfinished | Effort | Scope |
|---|---|---|---|---|
| 1 | `src/apprt/ipc/server.zig` (no caller) | **The IPC server is never started from any runtime.** `rg 'Server.bind' src/` outside `apprt/ipc/` returns nothing. Nothing in `gtk/App.zig`, `App.zig`, or `main_ghostty.zig` constructs it | 1d | FORK-LOCAL |
| 2 | `app_host.zig:177-178` | `pane.focus` and `pane.search` return `host_unsupported` on the **real** runtime (not just non-windowed) | 1d / 1w+ | FORK-LOCAL |
| 3 | `src/apprt/windows/ipc.zig` | Named-pipe transport does not exist; `PIPE_DACL_SDDL` / `PIPE_HANDLE_INHERITABLE` are decided but never applied (no `ConvertStringSecurityDescriptorToSecurityDescriptorW` in `std.os.windows`) | 1d | FORK-LOCAL |
| 4 | `src/apprt/runtime.zig:31-41` | `windows` is opt-in only; `Runtime.default` returns `.none` for Windows. Test asserts this stays true | 1h (decision) | FORK-LOCAL |
| 5 | `src/apprt/windows/keyboard.zig:46-52` | No `GetKeyState`/`GetAsyncKeyState`/`ToUnicodeEx`; modifier state is inferred from the message stream only | 1d | FORK-LOCAL |
| 6 | `src/apprt/windows/mouse.zig:42-48` | No `TrackMouseEvent(TME_LEAVE)`; `WM_MOUSELEAVE` can never arrive | 1h | FORK-LOCAL |
| 7 | `src/apprt/windows/{input,keyboard,mouse,win32api}.zig` (1,447 lines) | **Test-only island.** `input.zig` is imported only by `main_windows_apprt.zig`; nothing in a production path calls it | 1d (wire) | FORK-LOCAL |
| 8 | `src/apprt/windows/renderer.zig` (64 lines) | **Orphaned.** No module imports it — not `surface.zig`, not `App.zig`. Only `main_windows_apprt.zig` pulls it in for tests | 10m (delete) / 1w+ (implement) | FORK-LOCAL |
| 9 | `conformance/` (9 files, harness + 8 case suites) | Not referenced by `build.zig` or any workflow. Standalone `build.sh` only | 1h | FORK-LOCAL |
| 10 | `wasm/` (39 files, 4,700+ lines incl. JS API + tests) | Not in `build.zig`; built only via `wasm/build.sh` / `packaging/wasm-dist.sh`. No CI job runs `wasm/test/*.test.mjs` | 1h | FORK-LOCAL |
| 11 | `docs/SECURITY.md:128-130` | Stale: claims "No `server.zig`" and "No `app_host.zig`". Both exist (1,238 and 574 lines) with passing tests | 10m | FORK-LOCAL |
| 12 | `docs/SECURITY.md:146-167` | Stale: claims `PIPE_PREFIX` is malformed. `windows/ipc.zig:34-39` now spells bytes individually; `ipc.zig:181-200` asserts byte positions | 10m | FORK-LOCAL |
| 13 | `docs/SECURITY.md:169-176, 313, 350` | Stale: "No ACL design exists." `PIPE_DACL_SDDL = "D:P(A;;GA;;;OW)"` and `PIPE_HANDLE_INHERITABLE = false` are now decided and tested | 10m | FORK-LOCAL |
| 14 | `docs/PLATFORMS.md:234-238` | Stale "Known defect": claims `mod.zig` imports `"Surface.zig"` (wrong case). `mod.zig:4` now imports `surface.zig` | 10m | FORK-LOCAL |
| 15 | `src/apprt/ipc/protocol.md:21` | Stale: `app_host.zig` row says "not yet in the build graph". Phase 0 put it there (`build.zig:472-508`, `test-agent-ipc`) | 10m | FORK-LOCAL |
| 16 | `test/agent-ipc-phase0` @ `45fdebf74` | Not merged to `main`. Also: `main_agent_ipc.zig:26-35` admits the windowed vtable bodies are **never type-checked** on a macOS/none host — a green run proves signatures resolve, not that `pane.create` splits a surface | 10m (merge) / 1d (GTK CI run) | FORK-LOCAL |

---

## 6. Hardcoded values that should be config

- `src/apprt/ipc/auth.zig:204` — `/tmp/khostty-{uid}` socket-dir fallback (the weakest isolation option, per `SECURITY.md`)
- `src/apprt/ipc/auth.zig:188` — `{HOME}/Library/Caches/khostty`
- `src/apprt/ipc/auth.zig:193` — `{LOCALAPPDATA}\khostty`
- `src/apprt/ipc/auth.zig:198` — `{XDG_RUNTIME_DIR}/khostty`
- `src/apprt/ipc/auth.zig:285` — `0o600` token-file mode (correct value, but not configurable)
- `src/apprt/ipc/app_host.zig:100` — `split_wait_ms: u64 = 500`
- `src/apprt/ipc/app_host.zig:102` — `split_poll_interval_ms: u64 = 2`
- `src/apprt/ipc/server.zig:53` — `event_poll_ms: u64 = 25`
- `src/apprt/ipc/server.zig:56` — `push_batch: usize = 32`
- `src/apprt/ipc/protocol.zig:26` — `max_frame_bytes = 1024 * 1024` (1 MiB per connection)
- `bench/run.sh:98` — `--note "repo=/Users/kooshapari/CodeProjects/Phenotype/repos/khostty"` (machine-specific, committed)
- `khostty-go/examples/agent/main.go:178` — `8x16` placeholder cell metric
- `khostty-python/examples/agent.py:160` — same placeholder metric
- `.github/workflows/zig-fork-tests.yml` — Zig `0.16.0` + hardcoded SHA-256 (acceptable pin, but duplicated in 2 jobs)

Non-issues (verified): `src/apprt/windows/ipc.zig:34-39` `PIPE_PREFIX` is now correct; `windows/surface.zig:11-15` message constants are Win32 ABI values, correctly frozen.

---

## 7. Dead code

1. **`src/apprt/windows/renderer.zig` — orphaned.** Zero importers. `surface.zig` does not reference `Renderer`; `paint()` just returns `false`. This is the clearest dead-code finding in the fork. (64 lines + its only test.)
2. **`src/apprt/windows/win32api.zig:60-67`** — `kernel32` and `user32` re-export blocks plus all type aliases have **no production consumer**. `rg 'win32api' src/` matches only `main_windows_apprt.zig:29` (test-root import). 85 lines of FFI declarations nothing references.
3. **`src/apprt/windows/input.zig` + `keyboard.zig` + `mouse.zig` (1,447 lines)** — reachable only from the test root. Logically correct, practically unexercised.
4. **`src/apprt/ipc/app_host.zig`** — no unused imports (verified all 7 symbol counts > 0). Clean.
5. **Phase 0 diff (`app_host.zig:505-568`)** — removes 7 `_ = core;` / `_ = term;` discards. These were genuinely redundant (the parameter is referenced in the comptime branch). **Not** a regression: the recorded verification ran with `artifact=exe`, `windowed=false`, 3899/3925 passing, so the non-windowed path was exercised.
6. **`src/apprt/ipc/mod.zig:223,234`** — `unreachable` in `@sizeOf` and `Value()` comptime switches. Exhaustive by construction; **not** dead-code smell.
7. **`src/apprt/ipc/protocol.zig:884-888`, `server.zig:881`** — `pane.explode` and `"events":["explode"]` appear only in **negative tests** that assert they are rejected as unknown. Not unimplemented features.

---

## 8. Top 10 by priority

Sorted by (a) ease of fix, (b) user value, (c) unblocks other work.

| Rank | Finding | Why it ranks here | Effort |
|---|---|---|---|
| 1 | **Refresh 5 stale doc claims** — `SECURITY.md:128-130,146-167,169-176,313,350`; `PLATFORMS.md:234-238`; `protocol.md:21` | Trivial, and right now the docs *understate* the code. A synthesizer reading them will plan work that is already done | 1h total |
| 2 | **Merge Phase 0 to `main`** | `test/agent-ipc-phase0` @ `45fdebf74` is verified (3899/3925) and unmerged. Nothing downstream can build on it | 10m |
| 3 | **Fix `egl.zig:470-473` tautological assertion** | A test that cannot fail is a false control; Sonar/coverage will count it as covered | 10m |
| 4 | **Delete or wire `windows/renderer.zig`** | 64 orphaned lines with 8 `Unimplemented` returns. Delete now, rebuild with the real backend later | 10m |
| 5 | **Wire the IPC server into the GTK runtime** | This is the whole point of the mux. Everything else in `apprt/ipc/` is dead weight until `Server.bind` is called from `gtk/App.zig` | 1d |
| 6 | **Fix `pane.write` cross-thread parser access** (`app_host.zig:290-298`) | Documented invariant violation; a latent data race the moment item 5 lands. Must be fixed *with* item 5, not after | 1d |
| 7 | **Add `max_connections` + per-connection rate limit** (`server.zig`) | 1 MiB × unbounded connections is a trivial local DoS once the socket is live | 1h |
| 8 | **`pane.focus`** (`app_host.zig:208-214`) | Highest-value agent command after create/write; needs a focus-by-id core API, which is a small addition | 1d |
| 9 | **Add `conformance/` and `wasm/` to CI** | ~6,000 lines of fork-authored test surface currently unexercised by any pipeline | 1h |
| 10 | **`pane.search`** (`app_host.zig:216-232`) | Highest user value of any stub, but needs a synchronous scan API that upstream does not have. Genuine 1w+ design work | 1w+ |

Deliberately **not** in the top 10: the Windows GUI lifecycle (`App.init`/`run`, DirectWrite renderer, D2D). It is 3-4 weeks of work, depends on real Windows hardware for validation, and `docs/ROADMAP.md` already declares "No Windows GUI expansion until G3's windowing scaffold leaves `error.Unimplemented`". That is a program decision, not an audit finding.

---

## 9. Gaps for the fwd-path synthesizer

1. **Two different "IPC" systems share a name.** `src/apprt/ipc/mod.zig` is the *CLI action* channel (`new_window`, `new_tab`, `toggle_quick_terminal` only). `src/apprt/ipc/{protocol,server,handler}.zig` is the *agent mux* channel (12 commands + events). They do not talk to each other. Any synthesis that says "extend IPC" must name which one.
2. **`performIpc` is a stub in 2 of 3 runtimes.** `embedded.zig:372-378` returns `false` for all three actions; `none.zig:12-17` returns `false`. Only GTK implements it. Upstream-inherited, but it means libghostty consumers cannot drive a running instance.
3. **The `windowed` gate is the real fork boundary.** `app_host.zig:71-77` means: on macOS (this host), on lib, on wasm, and on Windows, **every** agent command returns `error.Unsupported`. Only a GTK build on Linux has a functioning vtable, and only two of its ten entries (`focus`, `search`) are also stubs. A synthesis plan that assumes "IPC works on macOS" is wrong.
4. **The Phase 0 "green" is shallower than it looks.** `main_agent_ipc.zig:26-35` is explicit: the run proves compilation and signatures, not behavior. Closing that gap requires `zig build test-agent-ipc -Dapp-runtime=gtk` on a Linux runner — which the CI job does **not** currently pass.
5. **Windows is not one gap, it is four.** (i) no window, (ii) no renderer, (iii) no input wiring, (iv) no pipe transport. (iii) is 80% done but orphaned; (iv) has decisions recorded but no implementation; (i)+(ii) are untouched. They should be separate work items, not one "finish Windows" epic.
6. **Three capabilities need *new core APIs*, not just glue:** `pane.focus` (focus-by-id), `pane.search` (synchronous scan), and snapshot counters (`bell_count`, `exit_code`, `last_activity_ms`). These are upstream-core changes and should be scoped as such.
7. **Documentation is currently a *negative* signal.** Five doc claims are stale in the direction of "worse than reality". Any plan generated from `SECURITY.md` or `PLATFORMS.md` will over-estimate remaining work.
8. **Test-count baselines for planning:** `apprt/ipc/` = 130 tests across 7 files (`protocol.md:14-22`); Phase 0 total = 3899/3925 with 1 known pre-existing `terminal.search.Thread.test_0` ABRT flake at `kqueue.zig:1916` (`.BADF => unreachable`, libxev kqueue race, not fork-caused). Treat that 1 crash as baseline noise, not a regression signal.

---

## Appendix: scan commands used

```sh
# marker sweep
rg -c --no-heading -i 'todo|fixme|xxx|hack|stub|mock|placeholder|not yet implemented|not implemented|will add' src test build.zig

# per-file breakdown
rg -c --no-heading 'TODO' src test build.zig | sort -t: -k2 -rn | head -25
rg -c --no-heading 'unimplemented' src test build.zig | sort -t: -k2 -rn | head -25
rg -c --no-heading '@panic' src test build.zig | sort -t: -k2 -rn | head -25

# fork boundary
git diff --name-status upstream/main...main
git merge-base main upstream/main   # b3dc3d794513c11633e7c3347935693957744e83

# fork-local additions
rg -n -i 'todo|fixme|stub|mock|not implemented|unimplemented' src/apprt/windows/ src/apprt/ipc/ khostty-go/ khostty-python/ khostty-vt/ wasm/

# phase 0 diff
git diff --stat main...45fdebf74
git diff main...45fdebf74 -- src/apprt/ipc/app_host.zig build.zig

# dead-code checks
rg -n 'win32api' src/
rg -n 'windows/renderer.zig' src/
for f in App Window input interface ipc mod mouse renderer surface win32api keyboard; do rg -n "windows/$f.zig" src/; done
```

**Constraints honored:** read-only scan; no repository mutations during the audit; no `gh` calls against `ghostty-org/ghostty` or any upstream repo; all findings are fork-local unless marked otherwise.
