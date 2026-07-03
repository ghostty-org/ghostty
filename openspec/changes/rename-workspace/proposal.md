## Why

Workspaces are currently identified only by generated positional labels such as `Workspace 1`, which makes them hard to distinguish in real projects once multiple workspaces are open. Users need a keyboard-driven way to give the active workspace a meaningful name without leaving the terminal workflow.

## What Changes

- Add a `rename_workspace` keybinding action that targets the active workspace in the current window.
- Provide a GTK prompt for renaming the active workspace, reusing the existing title-prompt pattern where practical.
- Store a user-provided workspace title on each `Workspace`, falling back to the generated `Workspace N` label when no custom title is set.
- Update the workspace sidebar to display custom workspace titles and refresh immediately after rename.
- Allow users to bind the action in config, for example `keybind = ctrl+shift+r=rename_workspace`.

## Capabilities

### New Capabilities
- `workspace-renaming`: User-driven workspace naming, including the rename action, prompt behavior, title storage, fallback labels, and sidebar updates.

### Modified Capabilities
- `workspace-sidebar-ui`: Sidebar entries display the current workspace title, including custom names after a rename.

## Impact

- Affects the input/action pipeline: `src/input/Binding.zig`, `src/apprt/action.zig`, `src/Surface.zig`, and `src/apprt/gtk/class/application.zig`.
- Affects GTK workspace/window state in `src/apprt/gtk/class/workspace.zig` and `src/apprt/gtk/class/window.zig`.
- May reuse or extend existing title prompt UI patterns from tab/surface renaming.
- Adds config-level support for `rename_workspace`; default keybinding choice should be checked for conflicts before implementation.
