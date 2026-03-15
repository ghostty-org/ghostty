# Popup Terminal Roadmap — v2 and Beyond

## Current State (v1 — shipped)

- Named popup profiles via `popup = name:key:value,...` config syntax
- Toggle/show/hide with keybindings
- Configurable position, size, autohide, persistence
- macOS + Wayland (no X11)
- Config changes require rebuild (no hot-reload)
- Single terminal per popup (no tabs, no splits inside popups)

---

## v2: Config Hot-Reload + Quality of Life

**Goal:** Popup profiles work without rebuilding. Add/remove/change popups by editing config and reloading.

### Features

**Config hot-reload for popups**
- Detect popup profile changes on `ghostty +reload-config` or SIGHUP
- New profiles become available immediately
- Changed profiles update the next time the popup is toggled
- Removed profiles: hide and destroy any running instance
- No restart required — just edit config and reload

**Per-popup working directory**
- `cwd` property: `popup = shell:cwd:~/projects,keybind:ctrl+shift+t`
- Default: inherit from focused surface (like tmux `display-popup -d '#{pane_current_path}'`)

**Per-popup opacity**
- `opacity` property for background transparency per popup
- Independent from global `background-opacity`

**Per-popup border color**
- `border-color` property: `popup = lazygit:border-color:#ff6f00`
- Matches your tmux `popup-border-style "fg=#ff6f00"` setup

**Esc-to-dismiss**
- `dismiss-key` property (default: none)
- `popup = calc:dismiss-key:escape` closes the popup when Esc is pressed
- Only active when the popup has focus

---

## v3: Session Management

**Goal:** Tmux-style session switching within Ghostty — named sessions you can create, switch between, and persist.

### What is a session?

A session is a named group of windows/tabs/splits. Think of it like a tmux session — "work" might have 3 tabs with splits, "personal" has 1 tab. You switch between them instantly.

### Features

**Named sessions**
- `ghostty +new-session <name>` or keybind action `new_session:work`
- Each session has its own window layout, tabs, splits
- Switching sessions swaps the entire window content instantly

**Session switcher UI**
- Keybind action: `show_session_picker`
- Fuzzy-searchable list of sessions (like tmux `choose-session`)
- Shows session name, number of windows/tabs, last activity time

**Session persistence**
- Sessions survive app restart (macOS state restoration, Linux serialization)
- `session-save` action to manually snapshot
- Auto-save on quit (configurable)

**Popup-session integration**
- Popups can target a specific session: `popup = monitor:session:ops,command:htop`
- Session-scoped popups: popup only visible when its parent session is active

**Config syntax**
```
# Define sessions declaratively
session = work:cwd:~/projects
session = personal:cwd:~
session = ops:cwd:/var/log

# Keybinds
keybind = ctrl+shift+1=switch_session:work
keybind = ctrl+shift+2=switch_session:personal
keybind = ctrl+shift+s=show_session_picker
```

---

## v4: Vi Mode

**Goal:** Navigate terminal output with vim-style keybindings — search, yank, scroll without touching the mouse.

### What is vi mode?

Like tmux's copy mode. You press a keybind and the terminal "freezes" — you can move a cursor around the scrollback, search text, select and copy. Press Esc or Enter to exit back to the live terminal.

### Features

**Enter/exit vi mode**
- Keybind action: `enter_vi_mode` (e.g., `keybind = ctrl+shift+v=enter_vi_mode`)
- Exit: `Esc`, `q`, or `Enter`
- Visual indicator: cursor changes shape, status shows "VI MODE"

**Navigation**
- `h/j/k/l` — character/line movement
- `w/b/e` — word movement
- `0/$` — start/end of line
- `gg/G` — top/bottom of scrollback
- `Ctrl+u/Ctrl+d` — half-page up/down
- `Ctrl+b/Ctrl+f` — full page up/down
- `H/M/L` — top/middle/bottom of viewport

**Search**
- `/pattern` — forward search (regex)
- `?pattern` — backward search
- `n/N` — next/previous match
- Matches highlighted in scrollback

**Selection & yank**
- `v` — start character selection
- `V` — start line selection
- `Ctrl+v` — block/rectangle selection
- `y` — yank selection to clipboard
- `Y` — yank entire line

**Marks**
- `m{a-z}` — set mark at current position
- `'{a-z}` — jump to mark
- Marks persist within the session

---

## v5: Vi Mode with Relative Line Numbers

**Goal:** Show line numbers in the terminal gutter with relative numbering for fast vi-mode navigation.

### What are relative line numbers?

Like Neovim's `set relativenumber`. The current line shows its absolute line number. Lines above and below show their distance from the current line. This lets you jump with `5j` (down 5 lines) or `12k` (up 12 lines) without counting.

### Features

**Line number gutter**
- Config: `vi-mode-line-numbers = relative` (options: `off`, `absolute`, `relative`)
- Gutter appears on the left side of the terminal when vi mode is active
- Gutter width auto-sizes based on scrollback depth (2-5 characters)
- Subtle styling: dimmed color, thin separator from terminal content

**Relative numbering**
```
  3 │ some earlier output
  2 │ another line
  1 │ line above cursor
142 │ ← cursor is here (absolute number)
  1 │ line below cursor
  2 │ another line
  3 │ more output
```

**Jump commands**
- `5j` — jump down 5 lines (relative number tells you exactly where you'll land)
- `12k` — jump up 12 lines
- `{number}G` — jump to absolute line number

**Toggle**
- While in vi mode: `:set number` / `:set relativenumber` / `:set norelativenumber`
- Or cycle with a keybind

**Rendering considerations**
- Gutter is rendered by the GPU renderer alongside terminal content
- Does NOT shift terminal content — gutter overlays on padding area or uses a dedicated column
- Only visible during vi mode (no always-on line numbers — that's a different feature)

---

## Implementation Priority

| Version | Effort | Value | Dependencies |
|---------|--------|-------|-------------|
| v2: Config hot-reload | Medium | High | v1 complete |
| v3: Sessions | Large | High | v2 (sessions benefit from hot-reload) |
| v4: Vi mode | Large | High | Independent (can parallel v3) |
| v5: Relative line numbers | Medium | Medium | v4 (requires vi mode) |

## Architecture Notes

- **v2** is mostly config plumbing — the PopupManager already supports `updateProfileConfigs()`
- **v3** requires a new `Session` abstraction that owns a window's tab/split tree — significant apprt changes
- **v4** needs a new input mode (like how key tables work) with a cursor overlay on the renderer
- **v5** extends the renderer to draw a gutter — Metal.zig and OpenGL.zig both need updates
