# Win32 Application Runtime

Native Win32 apprt for Ghostty on Windows. Uses raw Win32 API (no frameworks) with OpenGL/D3D11 rendering.

## Build

```
zig build -Dapp-runtime=win32 -Dwinui=true
```

A successful build produces no output (exit code 0). Only errors/warnings are printed.

Uses Zig 0.15.2. No external dependencies beyond Windows system libraries (user32, gdi32, opengl32, imm32, shell32, advapi32, kernel32, dwmapi, winmm).

## File Overview

| File | Lines | Role |
|------|-------|------|
| `App.zig` | ~920 | App lifecycle, message loop, action dispatch, window tracking |
| `Window.zig` | ~640 | Top-level window, tab management, split tree, layout |
| `Surface.zig` | ~750 | Child window, OpenGL/D3D11, input, clipboard, cursor |
| `TabBar.zig` | ~310 | Custom-drawn tab bar (GDI), tab switching/close |
| `input.zig` | ~560 | Keyboard VK mapping, mouse handlers, deferred key pattern |
| `opengl.zig` | ~256 | WGL context creation, glad loader (complete) |
| `c.zig` | ~580 | Win32 API bindings (extern functions, constants, structs) |

## Architecture

### Hierarchy
```
App
 └── Window (top-level HWND, "GhosttyWindow")
      ├── TabBar (child HWND, "GhosttyTabBar", hidden when 1 tab)
      └── Tab[] (one or more)
           └── SplitTree(Surface)
                └── Surface (child HWND, "GhosttySurface", CS_OWNDC)
```

### Message Loop (App.zig)
The app uses a `PeekMessageW` loop (non-blocking) with a high-resolution waitable timer. Each iteration:
1. Drains all pending Windows messages via `PeekMessageW`/`TranslateMessage`/`DispatchMessageW`
2. Flushes pending keyboard events across all surfaces in all windows/tabs
3. Ticks the core app (`core_app.tick`)

### Deferred Key Pattern (input.zig)
Windows delivers keyboard input as separate messages: `WM_KEYDOWN` (physical key) followed by `WM_CHAR` (character text). Ghostty's core expects a single event with both. The solution:
- `WM_KEYDOWN`: Build a `KeyEvent` and store it in `surface.pending_key` (don't fire yet)
- `WM_CHAR`: Fill `pending_key.utf8` with the character, fire the combined event
- End of message batch: Flush any unconsumed pending key (non-character keys like arrows, F-keys)
- `WM_KEYUP`: Fire immediately (no text expected)
- `WM_DEADCHAR`: Mark pending key as `composing = true`

### Window/Surface Separation
- **Window** = top-level HWND. Handles fullscreen, maximize, decorations, sizing, title, timer, DPI, color scheme.
- **Surface** = child HWND (`WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS`). Owns OpenGL/D3D11 context, core surface, and handles keyboard/mouse input.
- Surfaces claim keyboard focus via `SetFocus(self.hwnd)` on mouse click.

### Split Panes (SplitTree)
- Uses `datastruct.SplitTree(Surface)` — immutable tree, operations create new trees.
- Surface implements View interface: `ref`, `unref`, `eql` methods with Allocator parameter.
- `ref_count` starts at 0; `SplitTree.init` refs to 1. When ref reaches 0, `destroy()` is called.
- `closing` flag prevents double `DestroyWindow` during WM_DESTROY cascade.
- Surface close flow: `close()` → `PostMessageW(self.hwnd, WM_CLOSE)` → `PostMessageW(parent, WM_GHOSTTY_CLOSE_SURFACE)` → `Window.closeSurface()` → tree removal.
- Layout uses `SplitTree.spatial()` for normalized 0-1 coordinates, converted to pixel positions.

### Tabs
- `Window.tabs: ArrayListUnmanaged(Tab)` with `active_tab_idx`.
- Tab switching: hide all surfaces of old tab (`ShowWindow SW_HIDE`), show new tab surfaces, relayout.
- TabBar is custom-painted with GDI (FillRect, DrawTextW). Created on-demand when 2+ tabs.
- Tab bar posts custom messages to parent Window: `WM_GHOSTTY_NEW_TAB`, `WM_GHOSTTY_CLOSE_TAB`, `WM_GHOSTTY_SELECT_TAB`.

### Action Dispatch (App.zig)
`performAction` is a comptime-generic function over `apprt.Action.Key`. Routes:
- Window-level actions (title, fullscreen, maximize, decorations, float, sizing) → Window
- Surface-level actions (render, mouse, clipboard) → Surface
- Tab actions (new_tab, close_tab, goto_tab, move_tab) → Window
- Split actions (new_split, goto_split, resize_split, equalize, zoom) → Window.activeTab()

## Zig-Specific Gotchas

- **IDC cursor constants need `align(1)`**: `IDC_IBEAM = 32513` (odd integer). These are `MAKEINTRESOURCE` values (integers cast to pointers), so they need `[*:0]align(1) const u16` type.
- **`HCURSOR` is already optional**: It's `?*opaque{}`. Don't wrap in another `?` for extern function parameters (causes `??*opaque{}` error).
- **No comptime extern calls**: Struct field defaults can't call extern functions like `LoadCursorW`. Initialize these in `create()` instead.
- **Private module members**: `input.mouse` is private. Use re-exported names: `input.MouseButton`, `input.MouseButtonState`, `input.ScrollMods`.
- **Pointless discard in comptime switch**: `_ = value;` in one arm of `performAction` causes a compile error if another arm uses `value`. Just omit it.
- **`ArrayListUnmanaged.pop()` returns `?T`**: Use `orderedRemove` for non-optional return type.
- **Parameter name shadowing**: Function params can't shadow struct method names (e.g. `layout` param vs `layout()` method).

## Core Surface Callbacks

The core surface exposes these callbacks that the apprt must call:

| Callback | Signature | When |
|----------|-----------|------|
| `mouseButtonCallback` | `(action, button, mods)` | Mouse press/release |
| `cursorPosCallback` | `(pos, ?mods)` | Mouse move, leave (`{-1,-1}`) |
| `scrollCallback` | `(xoff, yoff, scroll_mods)` | Mouse wheel |
| `focusCallback` | `(focused)` | `WM_SETFOCUS`/`WM_KILLFOCUS` |
| `keyCallback` | `(KeyEvent)` | Keyboard input |
| `colorSchemeCallback` | `(scheme)` | Dark/light mode change |
| `sizeCallback` | `(SurfaceSize)` | `WM_SIZE` |
| `contentScaleCallback` | `(ContentScale)` | `WM_DPICHANGED` |

## Implemented Actions

`quit`, `new_window`, `new_tab`, `close_tab`, `goto_tab`, `move_tab`, `new_split`, `goto_split`, `resize_split`, `equalize_splits`, `toggle_split_zoom`, `set_title`, `render`, `mouse_shape`, `mouse_visibility`, `close_window`, `close_all_windows`, `ring_bell`, `cell_size`, `pwd`, `color_change`, `renderer_health`, `config_change`, `command_finished`, `initial_size`, `size_limit`, `reset_window_size`, `open_url`, `open_config`, `reload_config`, `quit_timer`, `toggle_fullscreen`, `toggle_maximize`, `toggle_window_decorations`, `float_window`, `toggle_background_opacity`, `goto_window`

## Not Yet Implemented

- Inspector overlay
- Scrollbar
- Application icon
- Proper IME cursor positioning (currently uses mouse cursor pos)
- IPC server (named pipe listener)
- Taskbar flash on command completion
- Secure keyboard input mode
