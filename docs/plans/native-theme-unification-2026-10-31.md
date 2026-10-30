# Native theme and control consistency

This follow-up addresses the six screenshot findings from the
`0.18.0-dev.b0c81037` development build.

## Changes

1. Agent History's directory filter still offers All / Current Directory, but
   the redundant folder-name subtitle is hidden.
2. The Git history panel no longer displays collection list/tree controls.
   The branch-scope popover remains small for few entries and grows up to
   520 points for larger collections, bounded by the invoking screen.
3. Native action buttons share explicit glyph layout and neutral disabled
   appearance. Hover, pressed and open-menu states are rendered independently.
   The stop icon is centered in its hit target, and disabled prominent buttons
   no longer retain a bright accent fill. Pull/Push uses the same button class.
   Repository names sit beside the Git symbol rather than stretching to fill
   the header and centering their text.
4. The branch-page Worktree action precedes collection modes. Creation uses a
   native controller with themed fields, checkout selection, validation and
   buttons. The older two-button themed alert adapter also now uses a native
   controller, rather than hosting SwiftUI around native accessories.
5. Agent History uses a consistent 28-point search/action row. Refresh is
   trailing-aligned. Row height is computed from title wrapping, metadata and
   optional path/snippet; single-line titles do not reserve a blank second line.
   Width changes recompute heights while retaining the visible row anchor.
6. Workspace popup content is an opaque themed surface, including the table,
   header, search, footer and actions. It does not mix a system-gray table with
   transparent material around it. Deferred page focus checks that its target
   is still attached to the same window before changing first responder.

## Shared theme contract

`OMGNativeTheme` supplies background, foreground, accent, secondary/disabled
text, borders, control fills, hover and selected fills. The palette derives from
the resolved OMG/Ghostty configuration, not a fixed light/dark color pair.

`OMGNativeSurfaceView` binds a popup to its invoking window and subscribes to
configuration changes. Existing open surfaces and controls update in place.
`NativeActionControl`, `OMGNativeSearchField` and native form fields use that
palette. Git collection renderers keep their existing data and interaction
models, with the shared palette translated into `GitCollectionColors`.

Ghostty terminal rendering/search, workspace switching and tab algorithms,
Git execution targets, filesystem services and history storage are unchanged.
The README change withdrawn by the user remains withdrawn.

## Validation

Theme tests exercise the same attached controls across two distinct dark
configurations and a light configuration, preserving search text and view
identity. Other tests cover disabled/open/hover states, centered icon geometry,
Worktree mode and revision values, compact row measurement, history mode
visibility, branch toolbar order and bounded popover height.

Native fixture previews are generated when `/tmp/omg-unified-theme-preview`
exists. They include History, workspace, Worktree creation and the Git panel.
They are native test renders, not evidence of an updated installed application.

Executed validation:

- Initial targeted acceptance: **64 tests in 12 suites passed**.
  `/tmp/omg-unified-theme-final-targeted.log`.
- A workspace focus warning found during that run was corrected by clearing
  outgoing page focus and rejecting stale/departed focus targets. The subsequent
  32-test layout/helper run passed without that warning:
  `/tmp/omg-unified-theme-finish.log`.
- Change-selected routine regression: **1,224 tests: 1,221 passed, 2 failed,
  1 skipped**. The failures were SSH provider publication timing and cached-link
  timing. This is not recorded as a clean broad pass.
  `/tmp/omg-unified-theme-regression.log`.
- Final affected-suite run including both exact failures: **56 tests in
  13 suites passed**. This includes the final theme, placeholder, form,
  filter, row-density, Git toolbar and focus corrections.
  `/tmp/omg-unified-theme-final-rerun.log`.
- Final light/dark render review caught a stale attributed search placeholder
  on the second palette change. The placeholder now refreshes from either its
  plain or attributed text; its foreground color is asserted after each theme
  update. Disabled icon alpha is applied when compositing the tinted image,
  rather than being lost in a source-atop tint operation.
  Final verification: **46 tests in 8 suites passed**:
  `/tmp/omg-unified-theme-final-colors.log`.
- Workspace mouse-click desktop validation was attempted explicitly. It failed
  at the `NSApp.isActive && window.isKeyWindow` prerequisite, before the click
  behavior could be validated. Physical pointer interaction remains a live
  acceptance gap. `/tmp/omg-unified-theme-desktop.log`.
- All 34 changed/new Swift files passed strict SwiftLint; localization JSON,
  the OMG documentation contract, and `git diff --check` passed.

Inspected native fixture renders:

- `/tmp/omg-history-unified-dark.png` and its light variant.
- `/tmp/omg-workspace-unified-dark.png` and its light variant.
- `/tmp/omg-worktree-dark.png` and its light variant.
- `/tmp/omg-git-unified.png`.
- `/tmp/omg-controls-1e2030.png`, `/tmp/omg-controls-123456.png`, and
  `/tmp/omg-controls-f5f4ef.png` for disabled, centered-icon and menu-open states.

This batch is uncommitted. It does not install an application or publish changes.
The inspected installed OMG Dev bundle remains `0.18.0-dev.b0c81037`.
