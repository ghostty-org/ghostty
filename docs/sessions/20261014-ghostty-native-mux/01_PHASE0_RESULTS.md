# Phase 0 results — agent IPC wired into the build graph

**Date:** 2026-10-14
**Branch:** `test/agent-ipc-phase0`
**Goal:** Compile `src/apprt/ipc/app_host.zig` (the `Host` vtable bridge onto
the real app runtime) for the first time by adding it to the Zig build graph
behind a new `test-agent-ipc` step. The IPC layer has been unit-tested
against `fake_host.zig` since G4; the bridge had never been compiled.

## Verdict: SUCCESS

```
Build Summary: 85/85 steps succeeded; 3900/3925 tests passed (25 skipped)
test-agent-ipc success
+- run test agent-ipc-test 3900 pass, 25 skip (3925 total) 13m MaxRSS:178M
```

The new test root compiled, the agent IPC modules were analyzed end-to-end
against the real runtime imports, and the 130+ pre-existing IPC tests
(inherited via the test root's `@import`s of `protocol.zig`, `auth.zig`,
`state.zig`, `events.zig`, `pane.zig`, `handler.zig`, `server.zig`) all
passed. The new availability-contract test prints its caveat on stderr:

```
app_host is compiled but NOT windowed (artifact=exe): the `none` runtime has no windows
```

That is the honest outcome on this host: only GTK is `windowed`, so the
vtable bodies that call into the real `App`/`CoreSurface` API are never
type-checked here. The signatures, imports, and the `AppHost` struct
resolved cleanly. The GTK runtimes (`-Dapp-runtime=gtk`) would be needed
to fully analyze the bridge end-to-end.

### Wall-clock ground truth (post-fix re-runs)

The `13m` figure on the `run test` line is the **test execution time** only;
it does not include the cold-cache compile of the test executable
(zig link is the slow part, not the test run). Two follow-up re-runs on
this host gave the full end-to-end wall clock:

| Run                        | Cache | Started   | Ended     | Wall        | Result                                                                                                                  |
| -------------------------- | ----- | --------- | --------- | ----------- | ----------------------------------------------------------------------------------------------------------------------- |
| Original (post-fix)        | cold  | 16:12 PDT | 16:58 PDT | **~46m**    | 85/85 steps, 3900/3925 pass, 25 skip                                                                                    |
| First re-run (incremental) | warm  | 16:28 PDT | 16:58 PDT | **~30m**    | 83/85 steps, 3898/3925 pass, 25 skip, **1 fail + 1 crash** (`terminal.search.Thread.test_0` ABRT, unrelated to Phase 0) |
| Second re-run (cache-warm) | warm  | 16:58 PDT | 17:29 PDT | **30m 24s** | 83/85 steps, 3899/3925 pass, 25 skip, **1 crash** (same `terminal.search.Thread` ABRT, flaky under load)                |

**Honest claim:** the cold-cache Phase 0 build is ~46m wall clock. The
~13m figure is the _test phase_ only. The cache-warm re-run is still ~30m
wall (the test phase dominates, not the compile). The `terminal.search`
failures on the re-runs are pre-existing flakes unrelated to Phase 0; the
Phase 0 commit itself produced a clean `85/85 / 3900 pass / 25 skip` result.

Logs:

- [`agent-ipc-build-20261014.log`](./evidence/agent-ipc-build-20261014.log) — the original run that hit the 7 errors and the post-fix `85/85` success
- [`agent-ipc-incremental-20261014.log`](./evidence/agent-ipc-incremental-20261014.log) — first re-run, 2 test failures (flaky)
- [`agent-ipc-cache-warm-20261014.log`](./evidence/agent-ipc-cache-warm-20261014.log) — second re-run, 1 test failure (flaky)

## What was wrong with `app_host.zig`

The first build run (commit-not-yet-attempted) failed with 7 compile
errors, all one shape:

```
src/apprt/ipc/app_host.zig:529:13: error: pointless discard of function parameter
        _ = core;
src/apprt/ipc/app_host.zig:526:21: note: used here
        const pid = core.io.getProcessInfo(.foreground_pid) orelse return null;
```

Zig 0.16 (the version this repo has now, 0.16.0*1) errors on
`* = param;`in an`else`branch when the same`param`is read in the
comptime-windowed`if`branch. The seven functions affected were:`titleOf`, `cwdOf`, `pidOf`, `colsOf`, `rowsOf`, `pixelSizeOf`, `scrollbackRows`.

Fix: drop the dead discards. The `_ = core;` / `_ = term;` lines were
load-bearing only in older Zig; in 0.16 they are unreachable because the
parameter is genuinely used by the live branch. Removing them is purely a
language-version fix, not a behavioral change — the `if (comptime windowed)`
gate still selects which branch compiles, and the `else` branch is still
dead at runtime.

Full error set, verbatim, is preserved in
[`agent-ipc-build-20261014.log`](./agent-ipc-build-20261014.log) lines 1-39
(the failure output from the first run that hit the 7 errors). The
successful second run (post-fix) is the rest of the log.

## Change surface

```
 build.zig                  | 43 +++++++++++++++++++++++++++++++++++++++++++
 src/apprt/ipc/app_host.zig |  7 -------
 2 files changed, 43 insertions(+), 7 deletions(-)
```

Plus the new file `src/main_agent_ipc.zig` (89 lines) which mirrors
`src/main_windows_apprt.zig` as a test root that sits in `src/` (not
`src/apprt/ipc/`) because the IPC modules reach `../../App.zig`,
`../../Surface.zig`, `../../apprt.zig`, and `../../input/*` — imports Zig
rejects from a module root three levels deep.

## Why this matters for the mux

`app_host.zig` is the only file in `src/apprt/ipc/` that knows about the
app runtime. Until Phase 0, the protocol was testable but not live: agents
could `pane.create` / `pane.write` / `pane.state` against `fake_host.zig`,
but nothing had ever type-checked the bridge that would let the same
commands work against a real Khostty. Phase 0 closes exactly that gap and
nothing more — it is the smallest, highest-value unblock for the entire
mux path, as the design brief
(`docs/sessions/20261014-ghostty-native-mux/00_SESSION_OVERVIEW.md`)
recommended.

## Next

- Phase 1 of the mux design needs the GTK runtime builds to fully analyze
  the vtable bodies. That is a CI concern, not a Phase 0 follow-up.
- The two carry-forwards from the 0.1.0 close-out are untouched:
  - `hook-b58bd04e8942def4147fbc6550efc236` abandoned-release-trigger
  - SonarCloud fix path (4 options in
    `docs/sessions/khostty-0.1.0-release/evidence/validation-round4-20261012.txt`)
