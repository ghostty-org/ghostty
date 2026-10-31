# Workspace popover dismissal and retained native tabs

## Report

The installed `0.18.0-dev.58ced12a` could stop responding to a workspace
selection made with the mouse in native fullscreen until another key command.
Returning to an already loaded Personal workspace with about 40 tabs also
paused visibly. The earlier intent-queue repair did not address both causes.

## Findings and changes

### Accepted commands must complete popover dismissal

`NSPopover.performClose` is a conditional close. The local AppKit SDK explicitly
documents that a child window or nested popover can prevent it from closing.
Waiting exclusively for `popoverDidClose` then leaves the accepted workspace
command waiting indefinitely.

`WorkspacePopoverPresentation` now uses `close()` for its owned dismissal.
Actions originating in button tracking defer dismissal until the tracking
stack returns. A close generation and an idempotent completion protect against
late delegate callbacks. Completion also checks the actual closed state after
`close()` returns. A keyboard command with no presented content bypasses
popover dismissal and enters the existing coalescing coordinator directly.

A real NSPopover/NSButton regression attaches a nonactivating child panel.
With `performClose`, the action enters the model but fails five assertions
covering dismissal and switching. With `close()`, the regression passes.
The user session's particular transient child was not captured, so this is a
confirmed reachable failure mechanism rather than proof of every reported hang.

### Repeated vertical workspace switches must not reconstruct native groups

The previous adapter detached outgoing workspace windows and reattached every
incoming window on each switch. A 40-tab return therefore repeated many AppKit
window-stack mutations even though the controllers and terminal surfaces
already existed.

For a vertical host, loaded workspaces now share a retained native tab group.
The coordinator keeps each workspace's logical membership, relative order,
selection, layout, and parked state. Switching selects the destination and
publishes its logical projection without detaching and reattaching the group.
Horizontal mode, native bulk close, and entry into borderless fullscreen
isolate the active workspace when a physical per-workspace group is required.
Failed native application restores the previous graph and retained-host mode.

Native membership is not presentation eligibility. Parked workspaces remain
ineligible for sidebar and Inspector work even when AppKit reports an attached
or visible window. Numeric navigation, move/reorder, drop positions, close
actions, undo, AppleScript tab enumeration, and selected-tab restoration use
the logical workspace projection.

### Preserve selection and topology at exceptional boundaries

Tab layout is part of the native projection snapshot, not a mutable property
read back from a controller after changing it. The adapter applies the captured
mode during both normal presentation and compensation. Rollback deliberately
bypasses the already-parked shortcut: a failed partial attach can leave a parked
window in the active native group even though its parked flag never changed.
The failure-injection test rejects the second attach and verifies the complete
old catalog, physical membership, layout modes, and Surface identities.

Borderless fullscreen temporarily selects another native tab while removing
the titlebar. That synchronous presentation interval now suppresses native
activation echo. The coordinator commits the actual fullscreen owner on entry
and the exiting controller on restoration, rather than allowing the temporary
replacement selection to become the restore target. An eight-cycle regression
checks both logical selection and physical membership after every cycle.

## Evidence

All timings below are local synchronous AppKit operation timings in a test
process. They are not hardware input-to-pixel latency measurements.

| 40-tab experiment | Previous implementation | Retained native group |
| --- | ---: | ---: |
| First A-to-B switch | 407.832 ms | 476.708 ms |
| Mean of loaded workspace switches | 250.370 ms | 80.471 ms |
| Maximum loaded workspace switch | 413.585 ms | 97.007 ms |
| Warm native attach calls | 164 | 0 |

After the layout rollback and borderless boundary repairs, the same 40-tab
test recorded 409.388 ms for first creation, 84.974 ms warm mean, 111.151 ms warm
maximum, and zero warm attaches. Timings vary with the window-server/test load.
This later measurement is in
`/tmp/omg-workspace-boundary-final-2026-11-01.log`.

The optimization targets switching among loaded workspaces. The first creation
of a workspace or terminal still performs initialization and was not improved
by this experiment.

Bounded local logs:

- `/tmp/omg-workspace-retained-baseline-2026-11-01.log`
- `/tmp/omg-workspace-retained-first-2026-11-01.log`
- `/tmp/omg-workspace-popup-child-baseline-2026-11-01.log`
- `/tmp/omg-workspace-popup-child-repair-2026-11-01.log`
- `/tmp/omg-workspace-popup-desktop40-repair-2026-11-01.log`

The desktop regression runs a real foreground native fullscreen Space,
creates 40 source tabs, attaches the child panel to the actual popover, and
dispatches mouse-down/mouse-up through NSApplication and NSButton tracking.
It clicks to the destination and back without another key, then checks key
window, active Space, fullscreen state, native membership, and picker reuse.
The initial repaired run passed in 11.214 seconds.

A control run of the old implementation without the child panel also passed
the ordinary fullscreen mouse path. That control must not be presented as
having reproduced the conditional-close failure.

## Validation status

The first focused functional run passed 16 tests across four suites. The
updated popup/keyboard regressions passed 20 tests across two suites, including
release of the picker controller after closing. The first broad run exposed
outdated physical-membership assertions and additional native-boundary cases;
those are tracked separately from these focused successes.

The final boundary-focused run passed 22 tests across two suites, including
the repeated borderless transition and partial-attach compensation checks.
Temporary diagnostic reads before fullscreen transitions were removed: reading
native tab-group properties can itself affect AppKit behavior, so the final
tests retain only their normal assertions.

The desktop became locked before final validation. The final-revision native
fullscreen mouse/drag acceptance remains NOT RUN; the earlier foreground run
described above is not a substitute for testing the final installed binary.
The user session's current checkpoint has 74 tabs, with 60 tabs in its active
Personal group. Development installation preserves that current checkpoint,
rather than relying on the earlier 40-tab workload observation.

Final routine validation passed 1,307 tests across 164 suites, split into 16
serial app-hosted batches. The final broad run's 40-tab measurement was
98.086 ms warm mean, 120.297 ms warm maximum, and zero warm attaches. Results
and per-batch logs are in
`/tmp/omg-workspace-full-regression-9ja5q6h7/final-results.json`.

The selector contract passed all 41 Python tests. SwiftLint found zero
violations in the 19 changed Swift files. Documentation, plist, settings-schema,
core build, and bundled session-runtime checks passed. Desktop/XCUITest results
are not included in the routine count.

The pre-install checkpoint and old Dev bundle are preserved together in the
private directory `/tmp/omg-workspace-install-backup-20261101-033915`. Installation
uses the standard Dev installer with this task's commit version. Exact installed
version and post-launch recovery checks belong to the delivery report. No release
application is modified.
