# Fullscreen workspace input ordering

Baseline: `e28d3cd13`, verified in the running OMG Dev bundle. The reported
window uses native fullscreen, with 40 tabs in its Personal workspace and
single-tab destinations. This review concerns command ordering and native
window work, not another replacement of SwiftUI controls with AppKit.

## Reproduced defects

1. Workspace keyboard shortcuts called the synchronous switch transaction
   directly. A burst presented every intermediate destination. The existing
   latest-target queue applied only while a native fullscreen notification
   marked a transition in progress.
2. A switch requested from inside an AppKit operation was rejected by the
   `applying` guard. Window operations can deliver callbacks before the
   transaction returns; those requests need to remain pending until it ends.
3. Picker clicks registered their target only after the popover closed. A newer
   keyboard request could arrive first, then be replaced by the older close
   callback. That callback also unconditionally raised the old source window.

The first two new regressions failed on the original scheduler. A separate
regression reproduced the third failure after the initial queue repair.

## Repair

- Both keyboard and picker switching use one replaceable intent per logical
  host. Input is accepted before native window mutation; a main-queue drain
  resolves the source from committed host state.
- The drain waits for both the current transaction and native fullscreen
  transitions. Finishing a transaction schedules any request received during
  its native callbacks.
- Picker selection registers its intent before dismissal. A unique dismissal
  token lets the matching close callback release that request; an older close
  callback cannot overwrite a newer intent.
- Closing the picker-owning tab cancels its waiting request with `superseded`,
  including rollback that closes a temporary controller while applying.
- Superseded completions run after the replacement is installed. If a completion
  submits a newer request synchronously, the outer request cannot overwrite it.
- Native activation notifications do not cancel an already queued explicit
  user request. A close callback no longer raises the outgoing window.
- Closing a tracked fullscreen-transition window schedules a completion check,
  rather than removing its transition and leaving the host queue waiting.

The synchronous `switchWorkspace` primitive remains available for internal
transactions and explicit construction. Create, move, and delete retain their
transaction semantics; they are not folded into the replaceable switch queue.

## Native work found in the live sample

`rapid-switch.sample` captured actual workspace commands in the installed Dev
process. Its synchronous show path includes:

`showWindow -> makeKeyAndOrderFront -> NSWindowStackController.setSelectedWindow
-> _enterWindow:intoFullScreenWithWindow -> _NSEnterFullScreenTransitionController`

It also captured parked titlebar refreshes reading `window.tabGroup`, which
causes AppKit to create a tab stack. Parked chrome now skips this work and
refreshes again when reactivated. The adapter no longer cancels, reads the
native group, and orders out every already-hidden parked window on each switch.
Unchanged window frames are not reassigned.

These are observed operations and eliminated redundant work, not proof of a
single underlying AppKit deadlock. The first sample missed the commands and
mostly showed the main run loop idle; it is not used as failure evidence.

## Desktop evidence boundary

The current tool can send targeted keys and read screenshots from the Dev
process, but mouse input reports `noWindowsAvailable`. A separate read-only
WindowServer check reported the app inactive and zero on-screen windows:
its fullscreen Space was not the active desktop. Consequently these samples
and screenshots do not establish foreground input-to-display latency.

The new explicitly opted-in desktop diagnostic stopped at its active/key
prerequisite. It is not counted as passed. The test retains that prerequisite
and checks real fullscreen completion, active Space, key/visible selection,
content and Surface identity, focus, and return to the original multi-tab group.
Its trace deliberately avoids reading `tabGroup` in notification/show/attach
logging, because that getter itself can change the topology being investigated.

## Local evidence

Private directory: `/tmp/omg-workspace-fullscreen-1r6ds583/`.

- `baseline-tests.log`: the two original scheduling regressions failed; the
  desktop diagnostic did not pass its foreground prerequisite.
- `picker-order-baseline.log`: delayed picker dismissal overwrote the newer
  keyboard request.
- `scheduler-repair.log`: new scheduling and parked-chrome regressions passed.
  The combined run retained two borderless-fullscreen failures.
- `borderless-baseline-control.log`: both borderless failures also occurred
  with all three changed product files temporarily replaced by `e28d3cd13`.
  Current edited files were restored in a `finally` block. These failures
  remain known issues, not waived successful tests.
- `picker-order-repair.log`: all 12 scheduling tests then present passed,
  including the delayed-picker regression. Additional lifecycle regressions
  were added afterward and are covered by the final-tree runs.
- `final-workspace-regression.log`: final-tree scheduling, transactional
  rollback/refactoring, integration, state, and appearance coverage passed:
  **60 tests in five suites**.
- `final-presentation-regression.log`: final-tree management, presentation,
  and live-tab layout coverage passed: **36 tests in three suites**. The two
  earlier borderless failures passed in this run; their earlier failures
  and failing baseline control remain evidence of timing sensitivity.
- `final-desktop.log`: the final-tree desktop diagnostic again stopped at
  `foregroundReady`, before entering fullscreen or performing the scenario.
  It remains **not passed**.
