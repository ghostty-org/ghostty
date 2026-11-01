# Large-workspace exit and application termination

## Observed workload

The installed Dev baseline was `0.18.0-dev.105c84f6`, with 75 tabs, 14
workspaces and 76 terminal surfaces. A private workspace checkpoint was copied
before a normal application quit. The process was sampled externally and
reopened afterward; all persisted tab identities/workspace assignments and
the live surface count were verified after restoration.

The quit request took 6.043 seconds to reach process exit with sampling enabled.
That first quit had a small workspace selected, while the large workspace's
windows remained retained. It establishes the shared teardown problem, not
the exact visual ordering of quitting from Personal.
Its main-thread sample contained 3,462 observations. AppKit's
`_deallocHardCore -> _closeForTermination` path accounted for 2,306; the
`TerminalController.windowWillClose` callback accounted for 2,170. Of those,
1,543 were under a `window.tabGroup` read that caused AppKit to reconstruct a
stack controller and lay it out while the window was already being destroyed.
These inclusive counts overlap and are not additive CPU-time measurements.

Scrollback capture also appeared in the sample (489 observations), so skipping
UI work must not be confused with eliminating all necessary exit work.

## Confirmed termination phase

`prepareToQuit` can precede a confirmation dialog or window review and remains
cancellable. A distinct, monotonic `commitTermination` is entered only from
`applicationWillTerminate`, after AppKit has accepted the quit.

During this final phase:

- Closing a window does not read its tab group, choose a successor, reparent a
  sidebar, relabel tabs, or update cascade geometry.
- Native tab refresh work is cancelled by its owning workspace coordinator.
  Queued callbacks revalidate that owner before executing, rather than using
  an arbitrary window or cancelling another coordinator's work.
- Sidebar, native chrome, key/main-window and delayed presentation callbacks
  stop publishing the disappearing UI.
- Base window cleanup, Editor/Inspector/activity cleanup, scrollback capture,
  durable checkpoint flush and remote relay shutdown remain in place.
- Registry and parked-controller references are released without modifying the
  checkpoint that must restore the next launch.

The isolated regression closes the selected tab first, followed by the rest
of a 60-tab workspace and a parked workspace. It checks that sidebar refreshes
and mounts do not increase, all content views are released, parked references
are removed, and all 61 identities remain in the checkpoint. A separate
regression verifies pending-quit cancellation and another coordinator's
continued tab selection and UI updates.

## Workspace switching

Existing windowed tabs already attached to a retained native group now select
their window directly, using an Objective-C exception boundary. This avoids
running initial positioning and last-window restoration again. New windows,
new attachments, fullscreen geometry handling and rollback retain the full
presentation path. Membership is checked against the group at entry, not a
set already modified by the current attachment loop.

Warm frame/selection preservation, cold-window presentation and failure
rollback have focused coverage. The native group and Surface identities remain
stable across the 60-tab benchmark.

The timing result is limited. Identically configured 60-tab/120-switch
experiments with ten-second external sampling measured:

| Measure | Baseline | Retained-selection implementation |
| --- | ---: | ---: |
| Leave large workspace, mean | 81.635 ms | 81.555 ms |
| Enter large workspace, mean | 99.015 ms | 88.755 ms |
| Warm switch median | 53.399 ms | 52.232 ms |
| Warm switch p95 | 413.131 ms | 373.434 ms |
| Native attachments during warm switches | 0 | 0 |

The leave mean did not materially improve. The remaining sample is dominated
by AppKit selecting a window and attaching its native tab-bar hierarchy, even
when the vertical UI hides that bar. This is a windowed test-process benchmark,
not an input-to-pixel measurement or proof of faster native fullscreen exit.

Two further experiments were withdrawn: deferring key-view-loop recalculation
during the transaction (leave mean 80.984 ms), and suppressing duplicate
metadata publication (83.079 ms). Neither showed a material improvement worth
changing the established focus/first-frame behavior. A separate public-API
probe also found that setting `tabbingMode` to disallowed, then toggling the
tab bar, did not hide a two-window group's native bar; this was not adopted.

Private measurements and logs are under `/tmp/omg-switch-quit-7c3fxnp9/`.

## Validation and live-probe limits

The focused run passed 26 tests in four suites. The final routine regression
passed 1,328 tests across 167 suites in 16 serial batches. Strict SwiftLint
passed for all 12 changed Swift files.

The real foreground desktop run passed three tests in three suites, including
the 60-tab native fullscreen mouse round trip, horizontal/vertical fullscreen
cases, and native tab click/focus preservation. Returning to the 60-tab group
in that run took 203.691 ms; this is a single event-to-committed-presentation
observation, not a comparison showing faster fullscreen workspace exit.

A separate live keyboard-automation run was discarded: the automation tool
redirected some input to another window and created two empty local tabs.
Their IDs and foreground shell processes were verified, and only those two
temporary tabs were closed through OMG's terminal-object API. All original
75 tab identities and owners, and the secondary window's selected workspace,
were rechecked afterward. Subsequent live targeting used explicit terminal
IDs rather than ambiguous app-wide keyboard targeting.

The explicit-focus live probe exercised the existing large/small workspaces
without creating tabs. It measures application scripting request to persisted
workspace checkpoint, including process launch and asynchronous focus handling,
so its timings are not comparable to the in-process switch benchmark. AppKit
window selection remained its largest active main-thread path.
