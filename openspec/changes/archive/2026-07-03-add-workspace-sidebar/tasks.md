## 1. Repo housekeeping

- [x] 1.1 Add a README section (or new `README.lcmux.md` linked from the top of `README.md`) noting this repo is a fork of `ghostty-org/ghostty`, tracked via an `upstream` git remote, describing lcmux's added workspace sidebar feature and the periodic-rebase maintenance model.
- [x] 1.2 Add a keybindings table to the README listing the new workspace shortcuts (`new_workspace` Ctrl+Shift+N, `previous_workspace`/`next_workspace` Ctrl+Shift+PgUp/PgDown, `goto_workspace` Ctrl+Shift+1-9, `last_workspace` Ctrl+Shift+0, `toggle_workspace_sidebar` Ctrl+Shift+B), noting that this fork overrides Ghostty's default `new_window` and `move_tab` bindings on the N and PgUp/PgDown combos.
- [x] 1.3 Add a "Building lcmux" note to the README with the build/run commands (`zig build`, `zig build run`), pointing to `HACKING.md` for full details.

## 2. Workspace core type

- [x] 2.1 Create `src/apprt/gtk/class/workspace.zig` defining a `Workspace` GObject class that owns an `adw.TabView` and the tab-management logic currently on `Window` (`newTabPage`, `selectTab`/`SelectTab`, per-workspace `notify::n-pages` handling).
- [x] 2.2 Move the relevant tab-handling methods/fields from `src/apprt/gtk/class/window.zig` into `Workspace`, preserving method names/signatures where possible to minimize the diff against upstream.
- [x] 2.3 Add a `Workspace` signal (e.g. `empty`) emitted when its tab count reaches 0, replacing the direct `self.as(gtk.Window).close()` call in the old `tabViewNPages`.

## 3. Window integration

- [x] 3.1 Change `Window`'s private state from a single `tab_view` to an ordered list of `Workspace` instances plus an `active_workspace_index`.
- [x] 3.2 Implement `Window.newWorkspace()`: creates a `Workspace` with one new tab, appends it to the list, activates it.
- [x] 3.3 Implement `Window.selectWorkspace(SelectWorkspace)` mirroring `selectTab`'s `previous | next | last | n: usize` union, with wraparound for `previous`/`next` and clamp-to-last for `n` (matching `goto_tab` behavior per design.md).
- [x] 3.4 Implement `Window`'s handler for a `Workspace`'s `empty` signal: remove it from the list/sidebar, activate an adjacent workspace if any remain, otherwise create a fresh workspace (zero-workspace guarantee).
- [x] 3.5 Wire the content area to display only the active workspace's `adw.TabView`, swapping when `active_workspace_index` changes.

## 4. Sidebar UI

- [x] 4.1 Wrap `Window`'s content in an `AdwOverlaySplitView`; confirm the libadwaita version requirement against `src/apprt/gtk/adw_version.zig` and gate accordingly if it exceeds Ghostty's current minimum.
- [x] 4.2 Build the sidebar widget: a `GtkListBox` (or `blp` blueprint + Zig binding, following existing patterns in `src/apprt/gtk/class/`) bound to `Window`'s workspace list, one row per workspace.
- [x] 4.3 Highlight the active workspace's row; update the highlight on every workspace switch (navigation, sidebar click, creation, destruction).
- [x] 4.4 Wire row click to call `Window.selectWorkspace(.{ .n = <position> })`.
- [x] 4.5 Wire sidebar visibility to `AdwOverlaySplitView`'s `show-sidebar` property.

## 5. Keybinding actions

- [x] 5.1 Add `new_workspace`, `previous_workspace`, `next_workspace`, `last_workspace`, `goto_workspace: usize`, `toggle_workspace_sidebar` to the `Action` union in `src/input/Binding.zig`, with doc comments matching the style of the existing `*_tab` actions.
- [x] 5.2 Add corresponding variants (and a `GotoWorkspace` enum mirroring `GotoTab`) to `apprt.Action` in `src/apprt/action.zig`.
- [x] 5.3 Add translation from the new `Binding.Action` variants to the new `apprt.Action` variants in `src/Surface.zig`, alongside the existing tab-action translation (~line 5281).
- [x] 5.4 Add dispatch functions (`Action.newWorkspace`, `Action.gotoWorkspace`, `Action.previousWorkspace`, `Action.nextWorkspace`, `Action.lastWorkspace`, `Action.toggleWorkspaceSidebar`) in `src/apprt/gtk/class/application.zig`, following the exact pattern of `Action.gotoTab`/`Action.newTab`, and wire them into the `performAction` switch.

## 6. Default keybindings

- [x] 6.1 In `src/config/Config.zig`'s non-macOS default keybind block, replace the existing Ctrl+Shift+N → `new_window` default with `new_workspace`.
- [x] 6.2 Replace the existing Ctrl+Shift+PageUp/PageDown → `move_tab -1`/`move_tab 1` defaults with `previous_workspace`/`next_workspace`.
- [x] 6.3 Add new default bindings: Ctrl+Shift+1 through Ctrl+Shift+9 → `goto_workspace 1`-`9`, Ctrl+Shift+0 → `last_workspace`, Ctrl+Shift+B → `toggle_workspace_sidebar`.

## 7. Verification

- [x] 7.1 `zig build` succeeds and the app launches with a visible sidebar showing one default workspace.
- [x] 7.2 Manually verify each spec scenario from `specs/workspace-management/spec.md`, `specs/workspace-navigation/spec.md`, `specs/workspace-sidebar-ui/spec.md`, and `specs/lcmux-binary/spec.md` against the running app/build output.
- [x] 7.3 `zig build test` passes (add/update unit tests for the new `Binding.Action` parsing and `Window`/`Workspace` selection logic where existing tests cover `*_tab` equivalents).
- [x] 7.4 `zig fmt .` run before committing.

## 8. Binary identity

- [x] 8.1 Rename the primary GTK application executable emitted by `src/build/GhosttyExe.zig` from `ghostty` to `lcmux`.
- [x] 8.2 Verify the build emits `zig-out/bin/lcmux`.
