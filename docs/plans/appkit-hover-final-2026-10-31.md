# Native hover and glyph follow-up

Base: `2e4882fec`. No installation or commit in this batch.

## Fixes

- Native action controls own their backing pixels and explicitly clear before
  painting translucent states. Painting transparent source-over was not enough
  to erase a previous hover background. Applied the same erasure policy to
  workspace/Git rows, swatches, segments and themed popup fields.
- SF Symbols preserve their source aspect ratio inside the centered 12-point
  glyph slot. Flat ellipses and narrow pull/push arrows no longer stretch square.
- Hover entry/reconciliation checks the current screen pointer, actual topmost
  window and clipped visible rect. Detached, inactive or covered views reject
  stale tracking events. Window transitions refresh action-control state.
- Repository-name controls retain copy context actions but suppress hover fill.
- Files and Agent History use one tracking area per list. Only the previous and
  next visible row are invalidated; no timer, snapshot reload, row measurement,
  or selection mutation is involved. Scroll notifications are source-filtered.
- Keyboard focus outline and expanded trigger state remain distinct from hover.
- Git history uses overlay scrollbars: expanding a long message no longer steals
  17 points from the content width and shifts file/header controls.

## Validation

- Pixel regression draws hovered then idle into the same bitmap and verifies
  the old fill becomes transparent. Geometry tests cover ellipsis, pull/push,
  refresh and stop glyph ratios and centers.
- Hover tests cover detached enter events, repository opt-out, exclusive row
  hover and unchanged selection; existing 10,000-file identity tests pass.
- Initial focused checks: 31/31 passed. Routine sweep: 1,232 tests, five failed
  methods and one skipped benchmark. Three timing/fullscreen failures passed
  isolated rerun. Two repeatable Git-history width tests exposed the scrollbar
  shift above and passed after the fix. The broad sweep remains a failed run.
- Final focused check: **40 tests in 8 suites passed**.
  Logs: `/tmp/omg-hover-regression.log`, `/tmp/omg-hover-rerun.log`,
  `/tmp/omg-hover-final-check.log`.
- Physical hover across windows and fast popup transitions still requires
  installed-app pointer acceptance; synthetic/pixel tests do not replace it.
- Explicit workspace desktop-click test stopped at the active/key-window
  prerequisite; log: `/tmp/omg-hover-desktop.log`. Strict SwiftLint on all 13
  changed/new Swift files, documentation checks and `git diff --check` passed.
