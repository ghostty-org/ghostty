# AppKit controls completion audit - 2026-10-30

Scope: Git, Agent History, and workspace popup controls. This follows the first
controls batch in `appkit-native-controls-2026-10-30.md`. The user subsequently
included workspace popups and their buttons; workspace/tab layout and switching
algorithms remain a separate task.

## Gaps found at the starting revision

The previous batch did not replace every control:

- Git still used SwiftUI buttons and menus in sidebar navigation, Fetch,
  notices, commit generation/submission, diff controls, and reference browsing.
  The reference-details popover still hosted a SwiftUI content root.
- Git AI settings still used SwiftUI sheets for prompt editing and model
  selection, including the adapter-update confirmation and route ordering UI.
- Agent History still used a SwiftUI load-more button and an invisible button
  to register the transcript Find shortcut.
- Workspace management had a native popover owner, but its content and trigger
  were SwiftUI. Creation, editing, deletion, moving, search, and row controls
  were not AppKit-owned.

## Implementation boundaries

NativeActionButton and NativeMenuButton are thin SwiftUI layout adapters backed
by actual NSButton and NSMenu objects. They do not host SwiftUI content. Native
menu entries capture their original actions, retain their targets, and preserve
disabled state. Sheets and popovers use native view controllers and controls.
Existing native alerts, tables, editors and menus are reused.

Local and SSH sources continue sharing the same feature frontends. No Git
executor, filesystem, Agent History storage, or workspace switching algorithm
is replaced. Git diff text rendering and static surrounding labels may remain
SwiftUI; this audit concerns controls and popup content.

Agent History Find dispatch is scoped to focused native transcript/search
content. It does not register an invisible global button or alter Ghostty's
terminal search implementation.

Workspace management retains the existing model and the close-popover-before-
performing-action boundary. Identity-bound create/edit/delete/move operations
remain in that model/coordinator.

## Validation

The final source inventory found no SwiftUI `Button`, `Menu`, `Toggle`, `Picker`,
`DisclosureGroup`, `contextMenu`, `sheet`, `popover`, or `confirmationDialog`,
and no `NSHostingView`/`NSHostingController` popup content in the following
scopes:

- `Features/Git/*.swift` and `Settings/GitCommitAISettings*.swift`.
- Inspector Agent History files and the `InspectorAgentHistoryView` region of
  `RightInspectorHost.swift` (unrelated Inspector panes are excluded).
- `TerminalWorkspacePicker.swift` and `TerminalWorkspaceView.swift`.

Static surrounding SwiftUI layout remains intentional. The native workspace
popover and reference popover are tested through their production controllers,
without unused compatibility hosting wrappers.

Executed checks:

- Compilation and targeted controls/workspace acceptance: **38 tests in
  7 suites passed**. Log: `/tmp/omg-appkit-controls-completion-targeted.log`.
- Workspace switcher, creation, moving, and deletion pages were rendered and
  visually inspected. This caught and corrected default button titles,
  selection contrast, grid spacing, and a missing move entry. The native
  creation/deletion actions, IME marked-text handling, and close-before-action
  behavior have routine fixture coverage.
- Change-selected routine sweep: **1,210 tests; 1,204 passed, 5 failed,
  1 skipped**. The sweep stalled during a Git integration test. A bounded
  process sample showed the dispatch thread soft limit of 75 reached, with
  many AppKit `NSAnimation` workers waiting. The owned test host was stopped,
  and XCTest resumed the remaining suites. The interrupted test is counted as
  a failure, not a pass. Evidence:
  `/tmp/omg-appkit-controls-completion-regression.log` and
  `/tmp/omg-appkit-regression-stall.sample`.
- The other sweep failures involved cached-link timing, two workspace
  persistence fixtures, and a native workspace test relying on lazy table
  cells appearing after a fixed delay. The latter fixture now explicitly
  materializes the actual row before operating its native button.
- Exact isolated rerun of all five methods: **5/5 passed**. Log:
  `/tmp/omg-appkit-controls-completion-rerun.log`. This does not turn the
  interrupted broad run into a clean single-run pass.
- Desktop opt-in was explicitly attempted for workspace button clicking and
  workspace creation/switching in fullscreen. All interactive cases stopped
  at the `NSApp.isActive && window.isKeyWindow` prerequisite; the render-only
  page test in that run passed. Physical pointer/fullscreen behavior therefore
  remains unverified. Log: `/tmp/omg-appkit-controls-completion-desktop.log`.
- Strict SwiftLint passed for all 25 changed/new Swift files. Documentation
  checks and `git diff --check` passed.

Preview artifacts are `/tmp/omg-workspace-management-switcher.png`,
`/tmp/omg-workspace-management-create.png`,
`/tmp/omg-workspace-management-move.png`, and
`/tmp/omg-workspace-management-delete.png`. These are fixture renders, not
screenshots of an installed release.

This batch remains uncommitted in the main checkout. No installed application,
release, remote branch, or PR was changed.
