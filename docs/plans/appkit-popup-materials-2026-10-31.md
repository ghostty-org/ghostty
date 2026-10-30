# Popup interaction and material follow-up

Base: `064de7ffa`. Scope: the ten screenshot findings; no tab/workspace
ownership, SSH runtime, or Ghostty search changes.

## Presentation

- Workspace pages share a 360 x 500 point canvas. Header height and insets are
  explicit; list content absorbs excess height rather than stretching the move
  description/header. Editor actions remain at the bottom.
- The workspace trigger no longer looks selected while its popover is open.
  Pointer hover and keyboard focus feedback remain.
- One table-owned hover target replaces independent row enter/exit histories.
  Layout, scrolling, exit and row reattachment clear stale hover; selection and
  action targets remain independent.
- Forty SF Symbols and fixed circular color swatches use native button input,
  themed hover and explicit selection. Color selection uses an outer ring rather
  than stretching a checkmark/button bezel.
- Commit options, worktree checkout choices and tab grouping/ordering now share
  `NativeActionPopoverController`. The tab menu no longer uses a SwiftUI Menu.
  Worktree choices retain NSPopUpButton selection and target/action semantics.
- The history scope picker uses a neutral filter glyph, not an arrow implying
  the wrong opening direction.
- Git diff always exposes wrapping and passes its value to full-source editors
  without changing the global editor setting. Conditional linked-scroll controls
  reserve their slot to the left of the right toolbar cluster; the file summary
  occupies a stable pseudo-centered column. Mode changes do not shift controls.

## Shared materials

`OMGNativeTheme` now carries opacity and the full Ghostty blur enum. The shared
native surface applies opacity to the background only, never text/controls;
uses Ghostty's existing window-blur hook for radius modes; and reuses
`TerminalGlassView` for supported regular/clear glass modes. Configuration
notifications update already-open surfaces. Reduce Transparency, forced opaque
terminals and native fullscreen retain opaque behavior.

Workspace tables no longer paint an opaque layer over the shared material.
The remote file chooser was another unmatched native surface and now uses the
same themed root, fields and action controls. Git dialogs, Agent History filter
surfaces and commit-agent forms already use this root and inherit its policy.

This does not replace AppKit's popover frame/shadow or promise identical physical
blur pixels between terminal and popup. System alerts, native file panels and
remaining standard context menus retain system presentation. Actual compositor
appearance with transparent windows needs installed-app visual acceptance;
offscreen PNGs alone cannot prove blur or glass quality.

## Validation

- Initial targeted native appearance/interaction suites: 43 tests passed.
- Full-source wrap and mode-change layout test, remote picker and focused
  controls: 25 tests passed before final lifecycle refinements.
- Routine regression: 1,229 tests, two failures and one skipped benchmark (cached-link timing and exact
  terminal-title publication sequence). Logs: `/tmp/omg-popup-round2-regression.log`.
  These are retained as failures regardless of isolated rerun outcome.
- Final targeted run after refinements: **28/28 passed**, including both failed
  methods, dropdown selection/disabled behavior, source-editor wrapping and
  toolbar position, opacity transitions, and workspace appearance.
  Log: `/tmp/omg-popup-round2-rerun.log`.
- Explicit desktop-click test could not meet `NSApp.isActive && window.isKeyWindow`;
  physical pointer acceptance remains unverified. Log:
  `/tmp/omg-popup-round2-desktop.log`.
- Dark/light workspace editor and popup fixture renders were inspected.
- Strict SwiftLint: no violations in 18 changed/new Swift files.
- No commit, push, installation, or release-app modification performed.
