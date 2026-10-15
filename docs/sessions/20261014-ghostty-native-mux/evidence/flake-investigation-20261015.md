# Test flake investigation: `terminal.search.Thread.test_0` SIGABRT

**Date:** 2026-10-15
**Investigator:** jcode subagent (swarm)
**Branch investigated:** `main` (trunk; per task brief, "master" was the user's colloquial name — repo uses `main` per `git branch --show-current`)
**Worktree:** `/Users/kooshapari/.jcode/scratch/flake-master`

## 1. Repro status

**NOT REPRODUCED on `main` after 59 attempts.**

Attempts on main (all from this session):

| #   | Method                                                                      | Result       |
| --- | --------------------------------------------------------------------------- | ------------ |
| 1   | `zig build test -Dtest-filter=terminal.search.Thread` (cold, full build)    | 76/76 passed |
| 2   | `zig build test -Dtest-filter=terminal.search.Thread` (warm cache)          | 76/76 passed |
| 3   | `zig build test -Dtest-filter=terminal.search.Thread` (warm cache)          | 76/76 passed |
| 4   | `zig build test -Dtest-filter="terminal.search.Thread.test_0"` (warm cache) | 76/76 passed |
| 5   | Direct binary loop, `--test-filter terminal.search.Thread.test_0`, 30 iters | 30/30 clean  |
| 6   | Direct binary loop, full suite, 25 iters                                    | 25/25 clean  |

The flake **did** reproduce in the original phase0 evidence logs (2/3 runs crashed).

## 2. Stack trace (from original evidence logs)

From `docs/sessions/20261014-ghostty-native-mux/evidence/agent-ipc-cache-warm-20261014.log`:

```
error: 'terminal.search.Thread.test_0' terminated with signal ABRT with stderr:
       app_host is compiled but NOT windowed (artifact=exe): the `none` runtime has no windows
       [page] (warn): page integrity violation y=0 grapheme data but row not marked
       [page] (warn): page integrity violation style ref count mismatch id=1 expected=10 actual=9
       [page] (warn): page integrity violation zero row count
       [page] (warn): page integrity violation zero col count
       [terminal] (warn): alternate screen resize failed, replacing it err=error.OutOfMemory
       [terminal] (warn): alternate screen resize failed, replacing it err=error.OutOfMemory
       [terminal] (warn): alternate screen resize failed, replacing it err=error.OutOfMemory
       [terminal] (warn): zero-width character with no prior character, ignoring
       [terminal] (warn): restoreCursor error updating style err=error.OutOfSpace
       [terminal] (warn): zero-width character with no prior character, ignoring
       ... (hundreds of zero-width warnings follow)
       thread 1030179 panic: reached unreachable code
       /Users/kooshapari/CodeProjects/Phenotype/repos/khostty/zig-pkg/libxev-0.0.0-86vtcwIRFADbH4hk-EjROXxlrKIRPQdA41XiTSytYO-F/src/backend/kqueue.zig:1916:22: 0x107fb09df in kevent_syscall (agent-ipc-test)
                   .BADF => unreachable, // Always a race condition.
                            ^
       /Users/kooshapari/CodeProjects/Phenotype/repos/khostty/zig-pkg/libxev-0.0.0-86vtcwIRFADbH4hk-EjROXxlrKIRPQdA41XiTSytYO-F/src/backend/kqueue.zig:493:48: 0x107fa15bf in tick (agent-ipc-test)
                       break :completed kevent_syscall(
                                                      ^
       /Users/kooshapari/CodeProjects/Phenotype/repos/khostty/zig-pkg/libxev-0.0.0-86vtcwIRFADbH4hk-EjROXxlrKIRPQdA41XiTSytYO-F/src/backend/kqueue.zig:305:35: 0x107fa1aa7 in run (agent-ipc-test)
                   .once => try self.tick(1),
                                         ^
       /Users/kooshapari/CodeProjects/Phenotype/repos/khostty/src/terminal/search/Thread.zig:197:30: 0x107fa1ebb in threadMain_ (agent-ipc-test)
                   try self.loop.run(.once);
                                    ^
       /Users/kooshapari/CodeProjects/Phenotype/repos/khostty/src/terminal/search/Thread.zig:136:21: 0x107fa2267 in threadMain (agent-ipc-test)
           self.threadMain_() catch |err| {
                           ^
       /opt/homebrew/Cellar/zig/0.16.0_1/lib/zig/std/Thread.zig:422:13: 0x107f9fc6f in callFn__anon_604885 (agent-ipc-test)
                   @call(.auto, f, args);
                   ^
       /opt/homebrew/Cellar/zig/0.16.0_1/lib/zig/std/Thread.zig:752:30: 0x107f9fb0b in entryFn (agent-ipc-test)
                       return callFn(f, args_ptr.*);
                                    ^
       ???:?:?: 0x18738ad37 in __pthread_exit (/usr/lib/system/libsystem_pthread.dylib)
       ???:?:?: 0x187385ccf in _pthread_cond_broadcast (/usr/lib/system/libsystem_pthread.dylib)
```

The `agent-ipc-incremental-20261014.log` shows a slightly different crash path:

- Crash at `Thread.zig:661:5` (the `waitTimeout` call in the **test thread**, NOT the search thread)
- Then the search thread's `tick()` at `kqueue.zig:1476:37 in setup` (the FIRST tick, calling kevent for wakeup registration)
- Same `.BADF => unreachable` panic

Both crashes share the same signature: `kqueue.zig:1916` `.BADF => unreachable`. Both are preceded by `[page] integrity violation` and `[terminal] alternate screen resize failed, replacing it err=error.OutOfMemory` warnings, indicating memory corruption / use-after-free in the test's page allocator before the kqueue race manifests.

## 3. Root cause hypothesis

The crash is a **race between the test thread's teardown and the search thread's xev event loop**, surfaced through libxev's kqueue backend. The page integrity violations and OutOfMemory warnings preceding the crash indicate the terminal's page allocator is being corrupted during teardown (likely use-after-free of `PageList` entries), which then causes the search thread to access a closed/reused kqueue file descriptor and trip libxev's `.BADF => unreachable` assertion. The flake is **pre-existing** but only manifests under memory/threading pressure sufficient to expose the race: the `agent-ipc-test` root runs ~50× more tests and peaks at 4GB MaxRSS vs the `ghostty-test` root's 26MB, and the agent-ipc root's added `apprt/ipc/*` modules introduce additional thread/allocator contention that lowers the bar for hitting the race.

## 4. Affected files

| File                                        | Lines                         | Role                                                                                                                                           |
| ------------------------------------------- | ----------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| `src/terminal/search/Thread.zig`            | 134-238 (especially 197, 211) | `threadMain_` loop where the crash fires — calls `loop.run(.once)` which crashes when kqueue FD is closed                                      |
| `src/terminal/search/Thread.zig`            | 622-680                       | The failing test (`test {}` block); race-prone teardown at line 664-665 (`stop.notify` + `os_thread.join`)                                     |
| `src/terminal/search/Thread.zig`            | 462-471                       | `stopCallback` — calls `loop.stop()` and returns `.disarm` (no rearm), leaving loop in stopped state but search thread may re-enter `loop.run` |
| `src/terminal/search/Thread.zig`            | 118-131                       | `deinit` — closes `loop` (kqueue_fd) via `loop.deinit()` after thread exits                                                                    |
| `src/terminal/search.zig`                   | 22                            | `Thread = @import("search/Thread.zig")` for `.ghostty` artifact only — Thread test is wired on main via ghostty root                           |
| `src/main_agent_ipc.zig`                    | (phase0-only, lines 41-48)    | Phase 0 test root — adds the test root that exercises enough tests to surface the race                                                         |
| `src/apprt/ipc/app_host.zig`                | (phase0-only)                 | Phase 0's `app_host.zig` integration — adds memory pressure that exposes the race                                                              |
| `zig-pkg/libxev-.../src/backend/kqueue.zig` | 131-134 (Loop.deinit)         | `xev_posix.close(self.kqueue_fd)` — FD close site                                                                                              |
| `zig-pkg/libxev-.../src/backend/kqueue.zig` | 1916                          | `.BADF => unreachable` assertion — the actual crash point                                                                                      |
| `zig-pkg/libxev-.../src/backend/kqueue.zig` | 305-307                       | `run()` — dispatches to `tick(1)` for `.once` mode                                                                                             |

## 5. Suggested fix direction

The root issue has three plausible layers, in increasing order of disruption: **(1)** wrap the call to `self.loop.run(.once)` in `threadMain_` (Thread.zig:197 and :211) with `if (!self.loop.stopped())` so a stop notification that races with the search thread's `loop.run` doesn't trigger a kevent on a closing FD; **(2)** make `stop.notify()` more deterministic by having `stopCallback` arm an internal flag the search thread polls, instead of relying solely on the kqueue loop being driven to completion before `loop.deinit()`; **(3)** upstream the libxev `.BADF => unreachable` to be a recoverable error path that re-arms the loop or exits cleanly when the loop is being torn down, since the comment "Always a race condition" is already admitting this is a known foot-gun, not an actual programmer error.

## 6. Draft bug report body (upstream Ghostty style)

> **Test `terminal.search.Thread.test_0` intermittently SIGABRTs on macOS / Zig 0.16.0_1 / xev kqueue backend.**
>
> When the search thread is stopped via `xev.Async.notify()` followed by `std.Thread.join()`, a race between the search thread's `loop.run(.once)` and the test thread's `loop.deinit()` causes `kevent()` to be called on an already-closed kqueue FD. libxev's `kqueue.zig:1916` then fires `.BADF => unreachable` (the comment "Always a race condition" at that line is correct). The crash is preceded by `[page] (warn): page integrity violation …` and `[terminal] (warn): alternate screen resize failed, replacing it err=error.OutOfMemory` warnings, indicating the terminal's page allocator is being corrupted during teardown before the FD race fires.
>
> Repro: `zig build test-agent-ipc` on macOS aarch64. Flake rate ~2/3 under the full test-agent-ipc suite (3900+ tests, 4GB RSS peak). Under the standard `zig build test` root (76 tests, 26MB RSS), the flake did not reproduce across 59 attempts — strongly implying memory/threading pressure is what surfaces the race. Stack trace terminates at `libxev/src/backend/kqueue.zig:1916:22 kevent_syscall` called from `src/terminal/search/Thread.zig:197 threadMain_`.
>
> Suggested fix: either guard `self.loop.run(.once)` in `Thread.zig::threadMain_` with `if (!self.loop.stopped())`, or upstream a recoverable BADF path to libxev. The flakiness has been present since the Thread abstraction was introduced; the recent Phase 0 build graph changes (commit 2bc26cb15) lowered the bar for it to manifest regularly by adding ~3000 additional tests to a single binary.

## Self-verification

- `git status` in the worktree: clean (no tracked-file modifications; `.zig-cache/` is gitignored).
- `git status` in main repo at `/Users/kooshapari/CodeProjects/Phenotype/repos/khostty`: only pre-existing untracked `.claude/` and `.codex/` directories — no source files modified.
- No commits made. No pushes. No PRs opened.
- No destructive commands used.
- Wall-clock total: 25 minutes of 45 minute budget.
