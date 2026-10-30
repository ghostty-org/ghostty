# Native workspace and commit popup polish

Scope: OMG-owned workspace presentation and Git commit options only. Workspace
switching/tab/session ownership, PTYs, Ghostty search, and Git submit rules are
unchanged.

## Changes

- Workspace shortcuts, edit and delete controls occupy a fixed trailing group;
  the opening hit target fills the remaining row width. Native row tracking
  supplies hover without changing selection or operation targets.
- The move-tab entry is a lightweight native footer action with a separator.
- Back is a fixed-size icon-only native control, without NSButton's default
  title. Workspace names use the common themed AppKit text field.
- Create/edit actions align at the bottom trailing edge. Their page size no
  longer inherits an expanded switcher list's height.
- The header measures only visible elements and honors finite width proposals;
  the attention dot reserves space only when visible. Text and chevron follow
  the window's OMG palette.
- Commit options use an AppKit NSPopover with themed native action rows, opening
  above the flipped anchor (subject to AppKit screen-edge fallback). A Core
  Animation chevron transition honors Reduce Motion. No SwiftUI popup content
  or gesture implementation is introduced.
- Options update in place on same-repository status changes. Repository changes,
  disabling, and detaching the anchor dismiss the popup. Selection validates the
  latest enabled action and closes before submitting. Up/down, Return, Space,
  Escape, and native transient dismissal remain available.

## Verification

- Initial controls/workspace regression passed (25 tests); focused new appearance and
  popup tests passed (4 tests). The popup fixture checks its actual screen frame
  is above the anchor, arrow animation, disabled behavior, keyboard navigation,
  context/anchor invalidation, and close-before-action.
- Workspace fixture checks row trailing alignment, hover without selection,
  icon-only back, visible-dot sizing, and bottom-pinned editor actions.
- Dark/light native fixture PNGs were rendered and inspected at
  `/tmp/omg-workspace-create-dark.png`, `/tmp/omg-workspace-edit-light.png`, and
  `/tmp/omg-commit-options-{dark,light}.png`. These are test renders, not installed
  application screenshots.
- Git/terminal and dependent routine regression: **848 tests, 847 passed and
  1 failed**. `terminalTitlesDoNotInvalidateWholeController()` failed its exact
  published-title sequence assertion. The isolated rerun plus final workspace
  and commit-option suites passed **30/30**, including that method. This does
  not turn the broad run into a clean pass. Logs:
  `/tmp/omg-popup-regression.log` and `/tmp/omg-popup-final-tests.log`.
- The explicit desktop workspace-click test stopped at the foreground/key-window
  prerequisite (`NSApp.isActive && window.isKeyWindow`). Physical pointer
  acceptance therefore remains unverified; see `/tmp/omg-popup-desktop-tests.log`.
- Strict SwiftLint passed for all six changed/new Swift files; the documentation
  contract and `git diff --check` passed.
- No commit, push, installation, or release application modification is part of
  this batch.
