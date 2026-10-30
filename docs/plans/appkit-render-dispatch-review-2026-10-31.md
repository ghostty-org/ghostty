# Native rendering regression review

Base: `f4315ad1f`. This review supersedes the root-cause/acceptance claims in
`appkit-hover-final-2026-10-31.md`.

## Findings and repairs

1. **The tests did not cover the live display contract.** Stock NSButton and
   NSTableRowView return `wantsUpdateLayer == true`, but a second runtime probe
   confirmed that overriding `draw`/`drawBackground` can automatically return
   false. Thus the stock default is NOT proof of the original regression's cause.
   Explicit overrides now document the intended path; tests count real dispatch
   via `displayIfNeeded`, rather than invoking `draw` directly. Hover ownership
   is exclusive across native action controls even if an exit event is missed;
   AppKit's internal highlighted state only paints pressed fill when the current
   pointer is actually over that control.
2. **The prior manual clear was unsafe.** Transparent `.copy` filling can punch
   holes through ancestors during composite/cache rendering, and dirty rectangles
   may extend beyond the view. Removed those fills; AppKit owns backing-store
   clearing. Native action views clip their drawing. The test now renders via
   `displayIfNeeded`, counts actual draw dispatch, and compares idle/hover/idle
   pixels without manually invoking `draw`.
3. **Embedded history chrome painted a second backdrop.** Header/search toolbar
   roots used the same background policy as popups. Added an explicit transparent
   embedded mode while retaining theme propagation. It paints no material and
   cannot mutate its hosting window's background.
4. **Icon/button dimensions diverged.** Pull/push and options representables lacked
   size proposals matching their surrounding SwiftUI frames. Sizes now agree.
   SF Symbols use their optical point-size metrics instead of forcing every
   symbol to the same bounding-box extent. Diff segments also request 12-point
   medium symbols and 11-point labels.
5. **Diff mode switches destroyed native editors.** The conditional branches
   recreated source editors and syntax/scroll infrastructure. Reused the existing
   native content deck with three lazy, file-scoped mode keys. Hidden sources
   receive `isActive=false`; file changes discard the deck. Tests verify that
   returning to split source reuses the same two TextViews and retains toolbar
   positions. No tab/workspace session model changed.

## Verification and limits

- Runtime Swift probes compared both stock controls and custom draw subclasses.
- Focused rendering, history, workspace and diff suites passed before the final
  pixel assertions. Fixture `/tmp/omg-native-dispatch-review.png` shows idle
  toolbar/menu controls and consistent Cancel/Save styling with no retained
  hover backgrounds. Both workspace theme renders were inspected.
- Opened the source-build app (not an installed replacement). Its loaded Agent
  History showed a continuous background and intact session rows. AX activation
  opened the workspace picker; the screenshot API captured only the main window,
  so this is not visual verification of the popup itself.
- Coordinate-driven pointer interaction returned `noWindowsAvailable` in the
  computer-use tool. Fast physical hover/scroll and frame-by-frame diff flicker
  are not claimed as fully verified. Retained editor identity is structural
  evidence, not a video-level guarantee for first-time editor creation.
- No commit, push, or installed application replacement.
- Routine sweep: **1,233 tests**, seven failing methods and one skipped benchmark.
  Failures concerned SSH publication, cached-link timing and workspace/tab
  integration fixtures. A 26-test targeted rerun passed 25, retaining the
  fullscreen fixture failure; that exact method passed in a fresh isolated run.
  These outcomes do not make the routine sweep green.
- Final rendering/hover, toolbar transparency, native source identity, history,
  workspace appearance and popup checks: **42/42 passed**. Strict SwiftLint on
  17 changed Swift files, documentation checks and whitespace checks passed.
  Logs: `/tmp/omg-render-path-regression.log`, `/tmp/omg-render-path-final.log`,
  `/tmp/omg-render-fullscreen-isolated.log`, `/tmp/omg-native-review-final.log`.
