# AppKit native ownership migration — 2026-10-30

This implements the ownership boundaries from
`appkit-ui-review-2026-10-30.md` in the main checkout. Terminal/workspace tab
chrome remains a separate integration task. There are no changes to the
Ghostty Surface/PTY, SplitTree model, filesystem services, history storage,
editor text engine, or plugin wire protocol.

## Implemented boundaries

| Review | Implementation | Preserved leaf content |
| --- | --- | --- |
| A1 | `TerminalShellController` assigns the leading, center and trailing rectangles; center/Inspector hosts retain identity, while the shared tab sidebar keeps its existing release-on-collapse contract. | Existing tab sidebar and chrome controls |
| A2 | `AgentQuickInputDockContainer` owns terminal/composer/queue height constraints; accessory heights are committed together and clamped in small windows. | ComposerTextView, draft/queue actions and card rendering |
| A3 | `InspectorHostController` coalesces model notifications, observes the current Surface, and publishes presentation from explicit visibility and native attachment. | Cached provider content in `InspectorPaneDeck` |
| B1 | `InspectorFileTreeController` uses an `NSOutlineView`, stable node objects, subtree reconciliation, selection and viewport anchors, native disclosure and contextual actions. | Provider-owned asynchronous loading, path validation, compact folders and icons |
| B2 | Quick Input history uses a native controller/table and persistent native IME search input. | History store, insertion policy and presentation/navigation model |
| B3 | Agent session history uses an `NSTableView` with grouped rows, incremental updates and viewport anchoring. | Search/filter models, static filter controls and transcript table |
| B4 | Command palette uses `NSSearchField` and reusable table rows in the existing window overlay. | Command catalog, ranking, matching and actions |
| B6 | `EditorContentDeckController` controls native visibility and caches visited documents by identity. The terminal is always mounted, including when an editor is restored as visible. | Document tab chrome, text controllers, Undo, preview and asynchronous saving |
| B7 | Editor-owned native completion table and native find/replace/go-to-line controls. | Completion providers, search/replace algorithms, keymaps and native input engine |

The SwiftUI adapters supply model values and environment values. Native owners
assign outer geometry and visibility; static content can continue to render
with SwiftUI. Cached document views are evicted when their model closes.

Inspector lifecycle changes are documented in `docs/PLUGIN_DEVELOPMENT.md`.
Menus retain the context/action callback from the snapshot that created them,
so a later pane change cannot silently retarget a pending menu action.

## Deferred by the review

- Terminal/workspace tab bars and document tab chrome remain separate work.
- Git diff (B5) remains unchanged. A synthetic layout-algorithm check does not
  establish actual scrolling/rendering performance. A replacement requires a
  real large-diff benchmark plus cross-line text selection, aligned wrapped
  columns, folding and source-row anchor validation.
- The terminal split tree is not coupled to the shell migration.
- Low-priority Git/SSH picker content and static settings/help pages retain
  their existing implementation. They are not required framework translations.

## Validation

Native adapter tests cover cached view identity, shell geometry, small-window
dock clamping, provider hide/detach lifecycle, selection and viewport retention,
menu context, and editor input ownership. Existing model tests remain in place.

The change selector requests all routine Swift suites because command-palette
source paths currently trigger its conservative fallback. Desktop tests are a
separate gate; passing adapter tests does not establish physical IME behavior,
fullscreen interaction, SSH behavior, or PTY resize notification counts.

Executed checks:

- Final targeted run: **45 tests in 11 suites passed**, including every new
  native adapter suite, editor completion and editor visibility coverage.
  Log: `/tmp/omg-appkit-acceptance-tests.log`.
- Initial broad run: 1,183 tests in 139 suites, with six issues across five
  methods. It exposed the shared sidebar's release-on-collapse contract; that
  regression was fixed without changing tab implementation files.
- Regression rerun: **43 of 44 tests passed**. The link-batcher timing check,
  hosted workspace popover and workspace deletion failures did not reproduce.
  The sidebar-collapse regression passed.
  Log: `/tmp/omg-appkit-regression-tests.log`.
- The remaining regular failure,
  `TerminalWorkspaceManagementTests.nonNativeFullscreenSupportsWorkspaceCreationAndReturn`,
  expects two native tab-group windows after leaving borderless fullscreen but
  observes one. An isolated checkout of unchanged `e8799ef4b`, using the same
  GhosttyKit build input, reproduces that exact failure and the hosting-view
  reentrant-layout warning. This establishes a baseline failure in this
  environment; it is not counted as a pass.
  Log: `/tmp/omg-appkit-baseline-tests.log`. The temporary checkout was removed.
- Desktop opt-in was attempted. Quick Input footer clicking, workspace-button
  clicking and the tab visual test failed their active-app/key-window
  prerequisites. Native fullscreen cases also failed active-window/fullscreen/
  focus assertions. These interactions are **not validated** by this run.
  The same run passed its regular editor, shell and pane-cache suites.
  Log: `/tmp/omg-appkit-desktop-tests.log`.

Physical IME interaction, the desktop failures above and direct PTY notification
count measurements remain acceptance gaps. The tree and session adapters have
model/selection coverage, but this is not a new end-to-end remote SSH UI test.
No development app was installed and no release, push or PR was created.
