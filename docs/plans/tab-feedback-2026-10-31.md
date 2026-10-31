# Tab presentation feedback fixes

Baseline: e58d81259. Scope: move-picker layout, split previews, current-pane
decoration, native tab-strip visibility and creation/idle overhead.

## Findings and changes

- Moving-tab context now shares the header row with "Move Tab". It truncates in
  the middle and exposes the full title through its tooltip. Search/list geometry
  and the picker size stay unchanged between switcher and move pages.
- Split preview content has explicit 320-point width and bounded height, with a
  frame-managed diagram and scroll region. It no longer depends on a stack
  inferring its width from a scroll view. One weak preview owner prevents multiple
  previews remaining open. Delayed dismissal permits moving into the preview;
  hit testing does not require the hover popover to become key.
- Current pane uses the theme accent. Attention/error/done remain semantic
  colors. Tiny per-pane borders are removed, including the done-state border.
- Native multi-tab groups do not reliably hide their bar with `toggleTabBar`.
  A two-tab direction-switch regression reproduced 637 repeated visibility
  attempts in 0.3 seconds. Rejected accessory installation additionally left
  native bookkeeping out of sync with the visible hierarchy.
- AppKit now installs its accessory normally. Its public `isHidden` property
  collapses the strip to zero height in vertical mode. Horizontal mode reveals
  it; only the selected window requests creation of a missing native strip.
  Native zoom-reset titlebar placement follows actual accessory visibility.
  The titlebar separator is disabled for the OMG chrome.
- A tab pending attachment does not materialize a temporary native tab group.
  Hidden horizontal controls do not resolve workspace state or pane icons.
  Workspace title/width changes invalidate layout only when dimensions change.

## Native API boundary

Horizontal Agent/split controls remain in `NSWindowTab.accessoryView`, which
AppKit publicly constrains to the right. Moving the live interactive view to the
left would require changing the native tab rendering contract. An attributed
title attachment would only supply a static image and lose the current animated,
interactive pane preview. This change preserves the native strip and the live
controls; it does not claim to move them to the left.

## Validation

The initial regression intentionally failed on incorrect visibility and a
non-settling refresh loop. After the visibility fix, 11 focused tests passed;
the expanded run passed 31 tests in five suites. A 0.3-second test-host idle
sample recorded zero refreshes, zero toggles and 0.00376 CPU seconds. This is a
bounded test-host result, not an end-user workload benchmark.

Final-source repeat: 30/31 passed. The remote-agent scroll timing check took
90.0 ms against an 84.7 ms threshold; the same unchanged check passed in
isolation (local 10.5 ms, remote 16.6 ms, remote-agent 18.8 ms). No thresholds
or assertions were relaxed. Final idle sample again recorded zero refreshes
and toggles, with 0.004952 CPU seconds over 0.3 seconds. The final batch is
not described as entirely green.

The preview test opens an actual NSPopover and verifies the root, diagram and
scroll document dimensions. The move-picker test compares actual search-field
coordinates. Direction tests preserve existing window/surface identities and
check repeated two-tab selection in both directions.

Desktop click/drag/fullscreen tests were explicitly attempted. The Xcode test
host did not obtain the foreground key window or event-posting permission,
although the invoking command-line process had event permission. These are not
passed desktop acceptance checks. The first run also reached workspace
fullscreen switching and failed its extra-pane focus assertion in both modes.
That fixture manually replaced the split tree and assigned the model's focus
without establishing actual keyboard focus. It now uses the production
`newSplit` path and requires the new pane to own the responder before switching.
In its isolated rerun, the horizontal scenario completed; the vertical scenario
stopped at the foreground prerequisite. Original assertions remain intact.

Logs: `/tmp/omg-tab-feedback-tests.log` (initial failure),
`/tmp/omg-tab-feedback-tests-3.log` (11 passing),
`/tmp/omg-tab-feedback-regression.log` (31 passing),
`/tmp/omg-tab-feedback-desktop.log` (desktop failures),
`/tmp/omg-tab-feedback-fullscreen-focus.log` (fixture rerun),
`/tmp/omg-tab-feedback-final.log` (final-source batch),
`/tmp/omg-tab-feedback-scroll.log` (isolated timing check).
