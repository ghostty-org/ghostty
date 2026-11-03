# Dock reopening and retained native tab selection

## Evidence

The installed baseline is `0.18.0-dev.a079fd41`. A normal Cmd-Q on the observed
GUI process completed termination, and reopening retained the 43 saved tab IDs.
The remaining `omg +ssh` command belongs to a persistent shell and is distinct
from the GUI process. This observation does not reproduce a stuck termination.

Two regressions fail on the baseline presentation code:

- Selecting a retained parked tab leaves the committed workspace, selected tab
  and sidebar on the outgoing workspace. The native refresh callback returns
  immediately when it sees a parked selection.
- Dock reopening accepts AppKit's `hasVisibleWindows=true` before checking
  whether the current workspace is actually displayed. A selected parked tab
  therefore prevents the existing recovery path from running.

Local session data was backed up before the installed-app quit/reopen. Some
pre-existing panes report a lost local runtime session; recovering a window
does not recover a lost PTY or justify silently replacing it with a new shell.
Raw session checkpoints and diagnostic samples remain private.

## Repair

Native refresh passes a parked selection to the existing coordinator activation
boundary. Activation commits both its workspace and the exact selected tab in
one presentation transaction, preserving deferred command precedence.

Dock reopening first attempts the existing current-workspace visibility repair.
The coordinator reports whether it repaired presentation so the host can
suppress AppKit's subsequent default selection. Healthy visible windows retain
the existing default behavior. Restoration, termination and native transition
guards continue to apply.

The host delegate forwards the request to a fork-owned terminal extension.
Window recovery reuses existing controllers and Surface objects.

The Dev installer now matches GUI invocations separately from `omg +ssh`
commands. Its old broad process match refused to install after the GUI exited
if a persistent shell still ran SSH. The installer still requests normal GUI
termination and refuses replacement while that GUI is running; it leaves CLI
sessions alive.

## Validation

The two focused baseline tests failed before the repair: the Dock test reported
two failed expectations, and the native parked-selection test reported five.
The final native-selection regression waits for the actual native group's KVO
notification and scheduled refresh rather than invoking refresh itself. It
checks workspace, exact selection, sidebar membership and Surface identity.
A healthy-window regression also checks that reopening does not replay
presentation or change the committed catalog.

- All 1,380 routine Swift tests in 173 suites passed in 15 serial fresh-host
  batches, with interactive desktop methods excluded.
- The 60-tab native fullscreen termination test passed after activating its
  verified ready PID through the exact test-bundle path. The first attempt
  stopped at `active=false, key=false` before termination assertions.
- Three Dev-installer process-matching tests and 42 test-selector contract
  tests passed. Strict lint passed for all five changed Swift files.
- Documentation, shell syntax, plist, settings JSON and diff checks passed.

The broader optional
`VerticalTabsIntegrationTests.appKitTabGroupDrivesVerticalTabsWithoutRecreatingSurfaces`
test reported six sidebar/Inspector/shortcut/appearance assertions. A separate
run with the original coordinator, native refresh and reopen logic reported the
same six assertions at lines 713, 789, 814, 1017, 1304 and 1472. This comparison
does not count as a desktop pass or repair those existing failures. The exact
fixed source bytes were restored after the comparison.
The restored final tree then passed 38 targeted tests in five suites covering
launch/reopen, termination, retained tabs, deferred switches and tab-selection
restoration.

The installed baseline quit/reopen retained all 43 tab IDs, 45 pane IDs and
tab owners. Fixed-version installation and live acceptance are checked
separately from the app-hosted test results.
