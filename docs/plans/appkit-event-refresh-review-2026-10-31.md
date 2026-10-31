# AppKit event routing and Inspector refresh review

Baseline: `c725422e6`. Scope: idle CPU, delayed sidebar hover, Inspector
responsiveness, intermittent window disappearance and suspected process exit.

## Confirmed defects

1. Inspector content used a globally published revision. Both the terminal
   shell and titlebar observe the registry to learn about pane availability,
   so every Files/Git/history snapshot invalidated those unrelated roots in
   every observing window. Native hosts also refreshed for other panes/tabs.
   Content now has a committed, pane/tab-scoped notification stream. Catalog
   observation is reserved for descriptor changes. Hidden hosts read current
   data when presented; global plugin fallback snapshots still notify all
   hosts selecting that pane. Identical titles no longer publish catalog work.
2. Native hover handlers discarded AppKit's delivered event position and
   synchronously queried the global pointer and topmost WindowServer window.
   Fast pointer motion could therefore test a later position than the event,
   in addition to the synchronous work on the UI thread. Delivered events now
   use their own window and local position. Geometry/activation reconciliation
   retains the topmost-window check because it has no routed event to trust.
3. Action buttons and tab trailing controls listened only for enter/exit.
   If reuse, visibility or activation reset hover while the pointer remained
   inside, another movement could not repair it. They now also handle movement
   with state-change guards. Table hover materializes the hit row on first
   movement rather than waiting for a later scroll/layout to create it.
4. Git hover rebuilt tracking areas during layout and walked every available
   row on every movement, including movement within the same row. Tracking
   identity now survives layout, and unchanged routed movement does no row
   work. Structural/scroll reconciliation still refreshes recycled rows even
   when their stable ID has not changed.
5. Native tab KVO observers requested new values even though their callbacks
   only schedule a later refresh. The routine run exited during borderless
   fullscreen entry with `NSWindowStackController._selectedWindow`, KVO
   `NSKeyValueDidChange`, and `setStyleMask` in the exception stack, reporting
   `expected no items`. Asking for `.new` evaluates AppKit's getter during
   stack teardown, before the deferred callback can protect it. Both tab-model
   and chrome observers now explicitly use `options: []`. This removes that
   synchronous getter but was not sufficient: the second routine run reproduced
   the same assertion through AppKit's own selection code. Borderless entry now
   selects a remaining sibling and detaches the incoming borderless window
   while both are still titled, within a balanced screen-update transaction.
6. Borderless exit restores key status before notifying the workspace
   coordinator to restore native membership. The focus callback could commit
   its temporary singleton and lose the remaining logical members. Projection
   now continues until the coordinator finishes restoring the native group,
   including the interval after the fullscreen style clears its saved state.
7. Native loading indicators used `NSProgressIndicator`'s default threaded
   animation and only stopped when their loading model changed. A later routine
   run stalled with Dispatch's 75-thread soft limit reached; the external sample
   shows many workers inside `NSAnimation._runBlocking`, while the main thread
   waits normally. This is a concrete animation-resource failure in the test
   workload, not a measurement of the user's reported idle CPU.
   `NativeProgressIndicator` now uses AppKit's timer mode, separates loading
   intent from running animation, and stops for hidden/occluded/detached/closed
   views. Nine native owners use it, including Git rows, Files rows, history,
   dialogs, file picker and settings. Cached loading intent resumes on show.
   A follow-up sample still found 76 blocked animation stacks in the monolithic
   test host, so this control repair is not claimed to eliminate all AppKit
   animation accumulation. The stacks do not identify the creating control;
   further framework/SwiftUI animation attribution remains open.

## Runtime evidence and limits

- Installed and running at review start: `/Applications/OMG Dev.app`,
  `0.18.0-dev.c725422e`, PID 59188, launched October 31 at 13:46:08 +0800.
- A five-second, 10 ms interval external stack sample at 13:49:42 showed
  442 of 444 main-thread samples waiting in the run loop. This observation
  does not reproduce or disprove the reported 20% CPU in another UI state,
  and is not a before/after performance comparison.
- The installed bundle passed `codesign --verify --deep --strict`.
- October 31 11:30-11:33 diagnostic reports concern `omgd`: invalid signatures
  in source-build artifacts, followed by missing dylibs in temporary probe
  directories. Existing commit `34aec20f0` repairs signing after load-command
  changes. These reports are not evidence of a new AppKit main-process crash.
- No October 31 `omg` main-process crash report was found in the user's
  DiagnosticReports directory or its Retired subdirectory. Absence of a report
  cannot exclude a clean exit, signal termination or a window-only issue.
- Reviewed native shell layout, pane caching, sidebar handoff, workspace window
  parking and screen-update transactions. The later test-host exception above
  identifies a concrete window-stack defect, but is not proof of the user's
  original disappearance. Existing bounded layout, retained hosts and balanced
  screen-update transactions remain in place.
- The app's own crash directory was also checked. The newest five envelopes
  (12:34 and this run's 14:00 exit) identify the source-build application and
  load `GhosttyTests.xctest`; they do not establish an installed-app crash.
- Baseline cached pane switching with 500 file/history rows measured a median
  of 0.219 ms and a maximum of 0.552 ms. The existing explicit display sequence
  was retained: this fixture does not justify removing its blank-frame defense.
  First-time remote loading and the user's complete workload are separate
  acceptance cases.

## Validation

New tests cover committed content delivery, no catalog invalidation on content
updates, tab/pane/global-fallback routing, catalog title deduplication, unrelated
content not rereading the selected native host, event-local pointer coordinates,
hover recovery without another enter, stale/hidden/detached events, and native
table hover without a prior click or scroll.

The first focused run passed 38 tests in six suites, including real Git
checkbox staging/unstaging and bulk index updates. The first routine run
reported 1,270 tests: 1,264 passed, five failed, one skipped. It also restarted
the test host after the fullscreen exception.

An isolated rerun passed the link-cache, workspace-deletion and modal-event
cases, but retained a fullscreen round-trip assertion and a sidebar fixture
failure. The sidebar fixture assumed no grouping while inheriting persisted
grouping preferences; it now specifies ungrouped/manual presentation locally.
After the KVO repair, 25 tests in the window-management, native sidebar and
Inspector-host suites passed, including both fullscreen regressions. The next
routine run exposed the remaining native teardown and logical-projection gaps
described above; isolated success was not treated as full acceptance.

Two existing regression fixtures were corrected without relaxing their
behavioral assertions: deletion now explicitly targets a live *inactive*
workspace from the active fallback, matching the current deletion rule; the
link-cache test waits for its actual cold reply because an automatically
scheduled drain can make its explicit `flush()` return early. The warm-before-
cold assertion remains, and completion has a one-minute test limit.

The topology repair passed 61 tests in five suites. The subsequent routine run
stalled after 488 completed test methods with animation worker exhaustion.
That test invocation alone was interrupted after a bounded diagnostic sample;
the installed app was not stopped. The loading-indicator repair then passed
40 tests in seven suites, including 100 detached loading indicators and
hide/unhide, occlusion, detach/reattach, close and stopped-state transitions.

Strict SwiftLint passed all 551 scanned files with zero violations. The initial
lint invocation encountered a stale `SDKROOT`; clearing that environment
override used the installed SDK successfully.

Both stalled monolithic invocations were interrupted after sampling. Final
routine validation uses the repository's discovered suite catalog, excludes the
same desktop suites/methods as `build.nu`, and runs all 158 routine suites in
seven serial fresh-process batches. This is a validation isolation strategy,
not a claim that the monolithic animation exhaustion is fixed.

Final fresh-process results: **1,273 tests: 1,272 passed, zero failed, one
pre-existing benchmark skipped**, across all 158 routine suites. Batch counts
are 304, 159, 127, 158, 197, 198 and 130. The first batch contains the skipped
benchmark. All seven `build.nu` invocations exited successfully. Result bundles
were available for batches 1-3 and 6-7; batches 4-5 counts are preserved in their
successful logs after their bundles became unavailable.

Three explicitly opted-in desktop tests stopped at the active/key-window
prerequisite. A follow-up attempt to focus the native click fixture through the
desktop tool confirmed that the Mac was locked and could not be automatically
unlocked. No physical hover/click acceptance or foreground CPU comparison is
claimed. The installed `/Applications/OMG Dev.app` was not replaced or restarted.
Only source-build test processes were launched/stopped.

Final static/support checks passed: SwiftLint (551 files, zero violations),
Zig formatting, documentation contract, Info.plist and settings JSON validation,
four diagnostic-sampler tests, 41 test-selection tests and `git diff --check`.

Private evidence:

- `/tmp/omg-appkit-review-sample.txt`
- `/tmp/omg-appkit-baseline-tests.log`
- `/tmp/omg-appkit-repair-tests.log`
- `/tmp/omg-appkit-routine-tests.log`
- `/tmp/omg-appkit-isolated-tests.log`
- `/tmp/omg-appkit-window-tests.log`
- `/tmp/omg-appkit-routine-final.log`
- `/tmp/omg-appkit-fullscreen-detach-tests.log`
- `/tmp/omg-appkit-window-final-tests.log`
- `/tmp/omg-appkit-test-stall.sample`
- `/tmp/omg-appkit-animation-tests.log`
- `/tmp/omg-appkit-routine-complete.log`
- `/tmp/omg-appkit-animation-followup.sample`
- `/tmp/omg-appkit-batch-plan.json`
- `/tmp/omg-appkit-batch-results.json`
- `/tmp/omg-appkit-batch-summary.json`
- `/tmp/omg-appkit-desktop-tests.log`
- `/tmp/omg-appkit-desktop-focus-tests.log`
- `/tmp/omg-appkit-swiftlint.log`
