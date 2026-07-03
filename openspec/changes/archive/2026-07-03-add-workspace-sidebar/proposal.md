## Why

Ghostty has no concept of grouping tabs into higher-level workspaces, and it does not run on the workflow cmux popularized on macOS (vertical workspace sidebar, git/PR-aware tabs, notifications, etc.). cmux itself does not support Linux. This change starts a lightweight, Linux-native alternative — lcmux — by forking Ghostty's own GTK application and adding the single highest-value piece of that workflow: a workspace sidebar that groups tabs, with lifecycle and navigation shortcuts. Everything else (rendering, splits, per-tab behavior, config/theme/font parsing, existing keybindings) is inherited unchanged from Ghostty.

## What Changes

- Add a toggleable sidebar (Ctrl+Shift+B) listing all open workspaces in a window.
- Add a `Workspace` concept that owns a set of Ghostty tabs/splits, rendered exactly as stock Ghostty renders tabs today.
- New workspace creation (Ctrl+Shift+N): creates a workspace containing one new tab and switches to it.
- Workspace lifecycle: a workspace is destroyed automatically when its last tab is closed. If the destroyed workspace was the only one left, a fresh empty workspace (with one new tab) is created automatically so the app is never left with zero workspaces.
- Workspace navigation:
  - Ctrl+Shift+PgUp / Ctrl+Shift+PgDown: switch to the previous/next workspace, wrapping around at the ends of the list.
  - Ctrl+Shift+1 through Ctrl+Shift+9: jump directly to the workspace at that position (1-indexed).
  - Ctrl+Shift+0: jump directly to the last (highest-index) workspace.
- New keybinding actions (`new_workspace`, `workspace_previous`, `workspace_next`, `workspace_goto`, `toggle_sidebar`) registered through Ghostty's existing config/keybind system, so they are user-remappable the same way as built-in Ghostty actions.
- Project is maintained as a fork of `ghostty-org/ghostty`, tracking upstream via periodic rebase; it ships and updates as its own independent binary (not linked against any system Ghostty package).
- The built GTK application executable is installed as `lcmux`, distinguishing this fork's binary from upstream Ghostty while leaving inherited resources and terminal behavior unchanged.

## Capabilities

### New Capabilities
- `workspace-management`: Workspace lifecycle — creation, auto-destruction when empty, the zero-workspace guarantee, and the relationship between a workspace and the tabs/splits it owns.
- `workspace-navigation`: Keyboard-driven switching between workspaces (prev/next with wraparound, direct positional jump 1-9, jump to last).
- `workspace-sidebar-ui`: The visible sidebar itself — showing/hiding, what's listed per workspace, and how it reflects the active workspace and lifecycle events from `workspace-management`.
- `lcmux-binary`: Build/install identity for this fork's executable, ensuring users run `lcmux` rather than an upstream-named `ghostty` binary.

### Modified Capabilities
(none — this is a greenfield project with no existing specs)

## Impact

- New fork of `ghostty-org/ghostty`; changes are concentrated in `src/apprt/gtk/` (new `Workspace` type/widget, sidebar widget, window changes to host both), the keybinding action table/config parsing used to register new actions, and the executable build name.
- No changes to core terminal emulation, rendering, font handling, or config/theme parsing — these remain byte-for-byte Ghostty behavior.
- Introduces an ongoing maintenance obligation: periodic rebase onto upstream Ghostty and independent build/release of the fork's binary.
