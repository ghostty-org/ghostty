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

## Fullscreen termination follow-up

A second installed-app comparison selected Personal's 60 tabs in native
fullscreen before quitting. Baseline `105c84f6` took 20.182 seconds and the
presentation-guard implementation `312b27f9` still took 18.511 seconds.
Both used the same normal AppleScript quit path and external sampling. The
baseline process additionally retained two closed, empty test surfaces; all
75 user tab identities, owners and 76 persisted surfaces were verified across
the restart. These are single observations, not a distribution.

The follow-up confirms a separate AppKit cost. In the guard implementation's
main-thread sample, 7,836 of 8,768 observations were under
`NSWindow._closeForTermination`; 5,696 were under native tab selection and 2,738
under fullscreen successor promotion. The old OMG `window.tabGroup` reads from
the close callback had disappeared, but AppKit's default close ordering still
promoted each successor into fullscreen. Counts are inclusive and overlap.

Confirmed termination now snapshots nonselected windows before teardown and
closes them first, leaving each group's selected window for AppKit's final
close pass. This runs only after checkpoint flush, runtime shutdown and
scrollback capture. It uses normal `NSWindow.close()` with existing delegate
cleanup, and only closes windows owned by the terminating coordinator.

The focused termination suite passes all three routine tests, including the
new background-close ordering, pending-quit no-op, independent coordinator and
unchanged checkpoint checks. The new 60-tab fullscreen regression requires an
unlocked foreground desktop. Its initial attempts stopped at the activation
prerequisite before any teardown assertions; native desktop inspection
confirmed the Mac was locked. That is not a passing fullscreen result.

The final ordered-close tree passes 1,329 routine tests across 167 suites in
16 serial batches. This reruns the complete routine regression after the
ordering change; the earlier 1,328-test result applies to `312b27f9`.
The desktop-selector contract includes the new opt-in method and passes all
42 offline checks. Strict lint on the three changed Swift files and the
documentation contract also pass.

## Installed ordered-close result and unresolved desktop gate

`0.18.0-dev.972d2699` is installed at `/Applications/OMG Dev.app`. Its executable
and debug dylib match the built artifact; signing and bundled runtime checks,
including six SSH wrapper checks, passed.

While the desktop was locked, the preceding `312b27f9` build took 20.426
seconds to quit and `972d2699` took 4.902 seconds. Both observations used the
normal application quit request and external sampling. The session had 75 tabs,
14 workspaces and 76 surfaces, with Personal's 60-tab workspace selected. The
pre-quit checkpoint reported native fullscreen.

The ordered-close sample no longer contains native successor selection or
`_enterWindow:intoFullScreenWithWindow:`. Its remaining main-thread work includes
background-window cleanup (749 observations), scrollback capture (537), and
AppKit's final close pass (270), out of 1,772 observations. These counts overlap
and are not durations.

However, the post-quit restart saved `fullscreen=false` for the large host.
Two bounded requests through the existing fullscreen action API were accepted
but did not restore that flag while locked. Thus the apparent timing reduction
is **not accepted as a verified foreground/fullscreen A/B result**: actual
fullscreen restoration and pixel behavior could not be confirmed. This also
needs a checkpoint captured between process exit and reopening to distinguish
shutdown persistence from startup restoration. No session files were rewritten
to manufacture a passing state.

All 75 original tab IDs, their window/workspace/group owners, and all 76 pane
IDs were verified after both restarts. The app remains running on Personal;
its last observed fullscreen checkpoint flag is false. The new foreground
60-tab termination regression and the real unlocked quit/switch acceptance
remain outstanding. Further UI retries/restarts were stopped at this concrete
desktop prerequisite.

## Unlocked desktop follow-up

After the user unlocked the Mac, the installed `972d2699` app was placed in
native fullscreen through its actual window control. Its 60-tab Personal group
and all 75 tabs / 76 panes were checked before Cmd-Q. Two actual Cmd-Q runs
observed process exit 2.277 and 2.605 seconds after the automation dispatched
the shortcut. These times include dispatch/activation overhead and external
sampling; they are not unsampled input-to-pixel timings or a controlled
percentage improvement over the earlier locked runs. Neither unlocked sample
contains the repeated native successor-selection/fullscreen-promotion paths.

The first run copied the checkpoint both before quit and after process exit,
before reopening the app. Both copies retained generation 1540, all 75 tabs,
and `fullscreen=true` / native mode for Personal. Reopening on the unlocked
desktop again retained that fullscreen flag and all tab/pane identities and
owners. Thus confirmed termination did not erase the fullscreen checkpoint;
the earlier locked observation does not establish a termination regression.

The 60-tab native fullscreen termination regression now passes on the actual
foreground desktop. It observes no background-tab key or fullscreen promotion,
keeps the selected window in fullscreen, releases background content views and
preserves the checkpoint. Its background-only close phase took 157.754 ms;
this excludes application persistence/final exit and must not replace the
installed-app timings above.

The foreground gate required activating the already-running test app through
the normal launcher, using its exact path and verified ready PID. Raising a
background test window was insufficient. The fixture now creates its tabs
through the real `TerminalController.newTab` path, waits for presentation and
selects its already-shown first window. It reports active/key/active-Space and
fullscreen transition state separately. The debugging skill documents this
activation procedure and warns that app lookup after a test exits can launch
a non-test instance against the real Dev session.

Four additional desktop tests passed: the 60-tab fullscreen workspace mouse
round trip, both parameterized fullscreen layout tests, and native tab clicks.
The workspace stress fixture also exercises an attached transient child panel.
Its cold leave, which creates the destination's first terminal, measured
655-684 ms; return to the existing large workspace measured 190-213 ms. Warm
mouse leave to the already-created destination measured 343-504 ms. Those
event-to-committed-state timings include popover dismissal and run-loop work;
they are not directly comparable with the 81.6 ms windowed coordinator-only
benchmark.

One instrumented warm run spent 51.787 ms inside `native.show`, out of 342.843
ms total. That does not identify `showWindow` as the dominant remaining cost,
so the fullscreen selection/geometry path was not changed on that hypothesis.
The cut-out latency remains an explicit limitation, despite functional
fullscreen switching and quit acceptance now passing.

Final validation of the updated test tree passed seven focused routine tests
in two suites and reran the real fullscreen workspace mouse test successfully.
No production implementation changed in this follow-up; the installed app
remains `0.18.0-dev.972d2699`.
