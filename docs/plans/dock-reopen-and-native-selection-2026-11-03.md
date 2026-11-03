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

## Automatic launch follow-up

The user rejected the previous acceptance: opening the application must show
the previous window and selected tab without choosing a Window/Dock-menu item.
The previous installed-app check selected a window manually after relaunch and
therefore did not establish automatic foreground restoration.

The historical Dev workspace and scrollback records were backed up and moved
out of the active profile with user authorization. AppKit initially reintroduced
old tab IDs from its own saved state, so the clean setup used one `open -F`
launch to suppress that legacy restoration. All subsequent quit/reopen checks
use normal launches. Fresh local A/B sessions reproduce the mismatch: the
checkpoint selects B, while the native group selects A and the sidebar shows
only one row. Both fixture processes remain alive.

The workspace checkpoint previously omitted application foreground identity.
Its reconstructed controllers also skipped the registration normally performed
by AppKit's per-window restoration callback. Consequently the existing deferred
selection restorer could not find checkpoint-owned windows.

The checkpoint now persists foreground identity and supplies its reconstructed
controllers and committed selections to the existing restorer. The handoff is
authoritative over later AppKit selection archives. Regression coverage checks
foreground-only persistence, multiple windows, delayed native selection changes,
sidebar membership, pane identity and launch without per-window callbacks.

The first regression run exposed an overly broad restoration guard that also
blocked normal native tab reconciliation for a manually assembled coordinator.
The guard now applies only while a loaded checkpoint owns restoration. The
final tree passes all 766 tests in the 84 affected routine suites across seven
serial fresh-host batches, including the normal reconciliation regression.
The foreground 60-tab fullscreen termination test also passes. Strict lint,
documentation, plist, settings JSON and whitespace checks pass.

Installed `0.18.0-dev.8191da29` was tested with only the two new A/B fixture
tabs in the active checkpoint. Separate normal quit/reopen cycles restore A
and B respectively without issuing a selection command after launch. The
selected pane UUID and shell PID match before and after each cycle.

An apparent sidebar screenshot mismatch prompted a temporary bounded diagnostic
build. Its four presentation observations report two native members, two
sidebar nodes, the correct controller/layout owner and mounted sidebar/surface
in the selected window. The probe was removed after collecting that private
evidence. The regression now additionally checks the actual mounted native
sidebar controller, node membership and window, and all nine launch tests pass.

The computer-use tool subsequently reports that the desktop is locked and
automatic unlocking failed. Thus unlocked visual/pointer acceptance remains
pending; scripting and model/view observations do not count as that pass.
Historical data remains backed up outside the active Dev restoration profile,
and only the two new fixture tabs remain active.

## Background-run quit and launch-time window loss

Cmd-Q left LaunchServices reporting OMG Dev as `exited-with-subordinates`:
`omgd host-local` was a child of the app's relay and stayed in the app
coalition despite `setsid`, so the Dock showed the app as running in the
background. Local hosts now start through a transient `gui/<uid>` launchd job
(`omgd detach`), matching Herdr. After Cmd-Q the app is no longer registered,
the hosts keep running, and reopening reattaches to the same host processes.

Windows missing after launch had a separate cause. A debuggable copy showed
restored terminal windows with AppKit `isVisible=1` and selected in their tab
groups but absent from the window server, while a plain probe window in the
same process appeared normally. `orderFront`, `orderFrontRegardless`, screen
update and CATransaction rebalancing did not reveal them; `orderOut` followed by
`makeKeyAndOrderFront` did but split native tab groups. Tracing showed the
checkpoint shows and groups windows inside `applicationDidFinishLaunching`,
before activation, where AppKit orders them only conditionally. Results varied
with timing (slowing launch under lldb hid the bug; a background launch hid
windows deterministically).

Checkpoint restoration now starts only once the app is active: immediately for
a normal launch, otherwise on first activation. With two tab groups, six normal
launches showed the current tab in both groups, and three background launches
showed nothing until activation and then both groups.
