---
title: "test(terminal.search.Thread): intermittent SIGABRT on macOS via libxev kqueue race"
labels: ["bug"]
---

## Summary

Test `terminal.search.Thread.test_0` intermittently SIGABRTs on macOS / Zig 0.16.0_1 / xev kqueue backend. When the search thread is stopped via `xev.Async.notify()` followed by `std.Thread.join()`, a race between the search thread's `loop.run(.once)` and the test thread's `loop.deinit()` causes `kevent()` to be called on an already-closed kqueue FD. libxev's `kqueue.zig:1916` then fires `.BADF => unreachable` (the comment "Always a race condition" at that line is correct).

## Crash signature

```
thread N panic: reached unreachable code
zig-pkg/libxev-0.0.0-XXX/src/backend/kqueue.zig:1916:22  kevent_syscall
  .BADF => unreachable, // Always a race condition.
                    ^
zig-pkg/libxev-0.0.0-XXX/src/backend/kqueue.zig:493:48  tick
zig-pkg/libxev-0.0.0-XXX/src/backend/kqueue.zig:305:35  run
src/terminal/search/Thread.zig:197:30  threadMain_
src/terminal/search/Thread.zig:136:21  threadMain
```

## Precursor warnings (preceding the crash)

```
[page] (warn): page integrity violation y=0 grapheme data but row not marked
[page] (warn): page integrity violation style ref count mismatch id=1 expected=10 actual=9
[page] (warn): page integrity violation zero row count
[page] (warn): page integrity violation zero col count
[terminal] (warn): alternate screen resize failed, replacing it err=error.OutOfMemory
[terminal] (warn): alternate screen resize failed, replacing it err=error.OutOfMemory
[terminal] (warn): alternate screen resize failed, replacing it err=error.OutOfMemory
[terminal] (warn): restoreCursor error updating style err=error.OutOfSpace
```

The page allocator is being corrupted during teardown before the FD race fires.

## Repro

- **Reliable on a heavy test root** (3900+ tests, 4GB RSS peak): reproduces ~2/3 of runs.
- **Hidden on the default test root** (76 tests, 26MB RSS): did not reproduce across 59 attempts across 4 invocation methods including `--test-filter terminal.search.Thread.test_0` and full-suite 25-iteration loops.

The race is latent; memory and threading pressure is what surfaces it.

## Suggested fix

Either:

1. Guard `self.loop.run(.once)` in `Thread.zig::threadMain_` (`Thread.zig:197` and `:211`) with `if (!self.loop.stopped())` so a stop notification that races with the search thread's `loop.run` doesn't trigger a kevent on a closing FD.
2. Upstream a recoverable BADF path to libxev's `kqueue.zig:1916` — the `.BADF => unreachable` should re-arm the loop or exit cleanly when the loop is being torn down, since the comment "Always a race condition" is already admitting this is a known foot-gun, not an actual programmer error.

## Environment

- macOS aarch64 (Apple Silicon)
- Zig 0.16.0_1
- libxev 0.0.0 (vendored at `zig-pkg/libxev-.../`)
- Ghostty fork at `KooshaPari/Khostty`, branch `test/agent-ipc-phase0` (commit `cf4178ade`)
- Full investigation report with stack trace, affected files, and repro attempts: see fork docs (link to follow if you want the long form)
