# Native AppKit tab sidebar

The vertical sidebar has one implementation: AppKit. `SharedTerminalTabSidebar`
is the thin bridge into the existing terminal layout; the mounted sidebar
subtree contains no SwiftUI hosting view. The horizontal tab strip remains
Ghostty's native implementation.

## Ownership

`NSWindowTabGroup.windows` is the canonical order. TerminalController and
Ghostty SurfaceView retain session and PTY ownership. Sidebar nodes reference
those objects; selection, renaming, closing and pane transfer invoke their
existing methods rather than maintaining another tab/session model.

One `NativeTabSidebarHostingView` moves between the selected native windows.
Window containers retain it; `VerticalTabSidebarHost` holds it weakly. The
hosting view here is an ordinary NSView that owns a native view controller,
not an NSHostingView. The same outline, controller, scroll position and nodes
survive handoff. Outgoing containers temporarily retain pixels, not a second
interactive sidebar. Workspace/terminal persistence remains outside this view.

## Files

- `NativeTabSidebarController.swift`: header, explicit configuration, coalesced
  settings/workspace/activity subscriptions, grouping and title presentation.
- `NativeTabOutlineController.swift`: stable outline nodes, row reuse, native
  incremental insert/remove/move, keyboard and mouse activation, context menus,
  drag source and destination.
- `NativeTabIconView.swift`: native image composition for split panes, activity
  state, Core Animation working indicator and native pane preview/actions.
- `TerminalController+NativeTabDrop.swift`: whole-window cross-host attachment.
- `VerticalTabSidebarHost.swift`: shared host/container lifetime and handoff.
- `VerticalTabBarView.swift`: existing layout/state/organization and resize
  boundary, with the old SwiftUI row and drop implementations removed.

## Interaction contracts

- A repeated click still focuses its terminal. Keyboard arrows retain outline
  focus across native-window handoff; Return enters the selected terminal.
  Deferred Ghostty focus repair revalidates the responder rather than overriding
  a newer control focus.
- Row title/path changes update cells, not the entire outline. Cells detach old
  observations on reuse. Group/order topology changes are separate from visual
  refresh. Remote project grouping never probes the local filesystem.
- Reordering resolves stable identities against current zero-based native
  indexes. Shortcut labels are one-based display values only. Dropping onto a
  row resolves its upper/lower half to a native insertion marker; users do not
  have to aim at the narrow inter-row gap.
- Drag initiation switches ordering to Manual. Cancellation restores actual
  native selection. Same-list grouped drops cannot silently cross group
  boundaries. Cross-window tab drops attach the complete window/split tree;
  pane drops use Ghostty's existing surface-transfer transaction. Cross-workspace
  tab drops are rejected; the workspace move action owns that operation.
- Row menus call Ghostty's close/rename/window actions. Icons and preview
  controls use AppKit and the current OMG palette. Working animation uses
  Core Animation, honors Reduce Motion, and stops on detachment.

## Removed implementation

There is no comparison toggle or legacy sidebar renderer, no SwiftUI row/drop
delegate chain, no icon-only NSHostingView, and no global SwiftUI drag cleanup
monitor. Tests solely for the removed monitor/drop-delegate protocol were
removed; native identity, move resolution, cancellation and interaction tests
replace that coverage. Shared logo-style reference fixtures remain test-only.

This is a destructive UI replacement, not a history migration layer. It does
not delete users' stored sessions or reconstruct running surfaces merely to
change presentation.

## Validation

Initial outline tests: 7 passed. Core layout/workspace/split suites: 82 passed.
Full sidebar adoption and existing vertical integration suites: 19 passed.
These include no-hosting-view assertions, stable outline identity and cross-host
split-tree preservation.

Explicit desktop tests were attempted. Click/navigation stopped at the active
key-window prerequisite; real drag stopped at `CGPreflightPostEventAccess()`.
They are **not passed**. Foreground click/drag/cancel/fullscreen and real terminal
input remain release acceptance checks. See `/tmp/omg-native-sidebar-desktop.log`
and `/tmp/omg-native-sidebar-desktop-click.log`.

The routine sweep executed 1,237 tests: 1,233 passed, three failed, one skipped.
One Git integration test stalled with 75 dispatch workers blocked in AppKit
NSAnimation; the owned test host was sampled and terminated, and XCTest resumed.
That interruption remains a failed test. It passed isolated rerun. Two session
catalog fixtures failed in batches and passed a fresh two-test isolated run.
The sweep is not recorded as green.

Final native sidebar/outline/split/monitor checks passed **24/24**. Test-selector
contract checks passed **41/41**. Logs are `/tmp/omg-native-sidebar-regression.log`,
`/tmp/omg-native-sidebar-final.log`, `/tmp/omg-sidebar-persistence-isolated.log`,
and `/tmp/omg-native-sidebar-acceptance.log`. The stall sample is
`/tmp/omg-native-sidebar-test-stall.sample`.

After the final insertion-marker and cross-host position checks, the two native
suites passed **11/11** (`/tmp/omg-sidebar-final-source-check.log`). Strict
SwiftLint passed all 22 changed/new Swift files; docs and whitespace checks passed.

The test-window PDF/print render verifies header/text/icon/selection geometry.
Its normal bitmap/layer cache omits some native text layers in this environment;
that bitmap is not treated as a faithful screen capture or a passed handoff
visual test. The print render is `/tmp/omg-native-complete-sidebar-print.png`.

Development installation policy remains the main checkout's OMG Dev policy.
No demo-only installer, bundle identity, SDK or release configuration was copied.
