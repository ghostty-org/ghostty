# Popup Terminal

Popup terminals are floating terminal windows you can toggle with a keybinding. Think of them like tmux's `display-popup` but native — no prefix key, instant show/hide, and they persist across toggles.

## Config Syntax

```
popup = <name>:<key>:<value>,<key>:<value>,...
```

Each popup is a named profile. The name comes first, followed by colon-delimited key:value pairs.

## Properties

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `position` | `center`, `top`, `bottom`, `left`, `right` | `center` | Where the popup appears on screen |
| `anchor` | `top_left`, `top_right`, `bottom_left`, `bottom_right`, `center` | none | Fine-tune the origin point for positioning |
| `x` | pixels or `N%` | none | Horizontal offset from the anchor |
| `y` | pixels or `N%` | none | Vertical offset from the anchor |
| `width` | pixels or `N%` | `80%` | Popup width |
| `height` | pixels or `N%` | `80%` | Popup height |
| `keybind` | key combo string | none | Keybinding to toggle this popup (e.g. `ctrl+shift+t`) |
| `command` | shell command | none | Command to run instead of the default shell |
| `autohide` | `true`, `false` | `true` | Hide the popup when it loses focus |
| `persist` | `true`, `false` | `true` | Keep the terminal alive when hidden. `false` destroys it on hide. |
| `cwd` | path | none | Working directory for the popup's shell. Supports `~`. If not set, inherits from the focused terminal. |
| `opacity` | `0.0` – `1.0` | none | Background opacity for this popup. If not set, inherits the global `background-opacity`. |

## Examples

### Basic shell popup

```
popup = shell:keybind:ctrl+shift+t
```

A centered 80% x 80% popup toggled with `ctrl+shift+t`. Uses your default shell.

### Lazygit

```
popup = lazygit:position:center,width:88%,height:76%,keybind:ctrl+shift+g,command:lazygit,persist:false
```

Runs `lazygit`, inherits the working directory from whatever terminal is focused, and destroys itself when closed (since `persist:false` means there's no point keeping a dead lazygit process around).

### Top-down dropdown (quake-style)

```
popup = dropdown:position:top,width:100%,height:50%,keybind:ctrl+grave_accent
```

A full-width dropdown from the top of the screen, like a classic Quake console.

### Project-specific shell

```
popup = projects:cwd:~/projects,keybind:ctrl+shift+p
```

Always opens in `~/projects`, regardless of what directory the focused terminal is in.

### Semi-transparent popup

```
popup = transparent:opacity:0.8,keybind:ctrl+shift+o
```

80% background opacity, independent of your global `background-opacity` setting.

### Everything combined

```
popup = dev:position:center,width:88%,height:76%,keybind:ctrl+shift+d,cwd:~/projects,opacity:0.85,autohide:true,persist:true
```

## Hot-Reload

Popup profiles respond to config reload (`ctrl+shift+,` or `ghostty +reload-config`). No restart required.

- **New profiles** become available immediately for toggle/show/hide
- **Changed profiles** update the next time the popup is toggled (visible popups keep running with old settings until you toggle them)
- **Removed profiles** are destroyed immediately, including any running terminal inside them

## Actions

Three keybind actions work with popups:

| Action | Description |
|--------|-------------|
| `toggle_popup:<name>` | Show if hidden, hide if visible |
| `show_popup:<name>` | Show (no-op if already visible) |
| `hide_popup:<name>` | Hide (no-op if already hidden) |

The `keybind` property on a popup profile is shorthand for `toggle_popup`. You can also bind these manually:

```
keybind = ctrl+shift+g=toggle_popup:lazygit
keybind = ctrl+shift+h=hide_popup:shell
```

Explicit `keybind = ...` lines always take precedence over the popup profile's `keybind` property if they conflict.

## Quick Terminal (backward compat)

The legacy `quick-terminal-*` config keys still work. They're automatically migrated to a popup profile named `quick`:

```
# These two are equivalent:
quick-terminal-position = top

popup = quick:position:top,width:100%,height:50%,autohide:true
```

## tmux Migration Guide

If you're coming from tmux floating popups, here's how your config maps:

| tmux | Ghostty popup |
|------|---------------|
| `display-popup -E -w 88% -h 76% -d '#{pane_current_path}' 'lazygit'` | `popup = lazygit:width:88%,height:76%,command:lazygit,persist:false,keybind:ctrl+shift+g` |
| `display-popup -x C -y C` (centered) | `position:center` (default) |
| `display-popup -d '#{pane_current_path}'` | Default behavior — CWD inherited from focused terminal |
| `display-popup -d ~/projects` | `cwd:~/projects` |
| `popup-border-style "fg=#ff6f00"` | Use an external border app (e.g. JankyBorders) |
| `@floax-width '88%'` / `@floax-height '76%'` | `width:88%,height:76%` |

### Example: full tmux popup migration

**tmux config:**
```bash
# Shell popup (floax plugin)
set -g @floax-bind 't'
set -g @floax-width '88%'
set -g @floax-height '76%'

# Lazygit
bind g display-popup -E -x C -y C -w 88% -h 76% -d '#{pane_current_path}' 'lazygit'

# Lazydocker
bind D display-popup -E -x C -y C -w 88% -h 76% -d '#{pane_current_path}' 'lazydocker'

# Dotfiles TUI
bind e display-popup -E -x C -y C -w 88% -h 76% 'dot-tui'
```

**Ghostty config:**
```
popup = shell:position:center,width:88%,height:76%,keybind:ctrl+shift+t,autohide:true
popup = lazygit:position:center,width:88%,height:76%,keybind:ctrl+shift+g,command:lazygit,persist:false
popup = lazydocker:position:center,width:88%,height:76%,keybind:ctrl+shift+d,command:lazydocker,persist:false
popup = dotfiles:position:center,width:88%,height:76%,keybind:ctrl+shift+e,command:dot-tui,persist:false
```

Key differences:
- No prefix key needed — keybinds are direct (`ctrl+shift+g` instead of `prefix` then `g`)
- CWD inheritance is automatic (no `-d '#{pane_current_path}'` needed)
- `persist:false` replaces tmux's `-E` flag (exit command = destroy popup)
- Each popup is a named profile you can toggle independently
