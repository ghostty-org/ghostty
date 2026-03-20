# Win32 Tabbed Windows Design

## Overview

Implement real tabbed windows for the Ghostty Windows port. Currently, `new_tab` opens a separate OS window (HWND). This design introduces a `Window` container struct that hosts multiple terminal surfaces as tabs within a single top-level window, with a custom GDI-drawn tab bar.

## Goals

- Real tabs within a single window, matching GTK/macOS behavior
- Custom-drawn tab bar that matches Ghostty's dark theme
- Support core tab actions: new_tab, close_tab, goto_tab, set_tab_title
- Respect existing tab-related config options
- Minimal disruption to existing Surface code

## Non-Goals (Deferred)

- Drag reorder tabs
- `move_tab` action (keyboard reorder)
- Tab overview / grid view
- Title bar integration (tabs in non-client area)
- Tab bar at bottom position
- `close_tab` modes: `other`, `right`
- Tab context menu (right-click)
- Tab colors

## Architecture

### Struct Hierarchy

```
App
 └─ Window (top-level HWND, WS_OVERLAPPEDWINDOW)
     ├─ Tab bar (reserved region at top of client area, GDI-drawn)
     └─ Tab list: [Surface, Surface, Surface, ...]
          └─ Surface (child HWND, WS_CHILD, each with own HDC + HGLRC)
```

- `App` tracks a list of `Window`s via `std.ArrayList(*Window)`.
- `Window` owns the top-level HWND and manages the tab list.
- Each `Surface` becomes a `WS_CHILD` window inside the Window, with its own OpenGL context.
- Only the active tab's Surface HWND is visible.

### Window Classes

Two separate Win32 window classes are registered:

- **`"GhosttyWindow"`** — for Window's top-level HWND. Uses its own `windowWndProc`. Does NOT need `CS_OWNDC` (uses GDI via `BeginPaint`/`EndPaint` temporary DCs).
- **`"GhosttyTerminal"`** — for Surface child HWNDs. Uses the existing `surfaceWndProc` (renamed from current `wndProc`). Retains `CS_OWNDC` for persistent DC needed by OpenGL.

Both store a pointer in `GWLP_USERDATA`: Window stores `*Window`, Surface stores `*Surface`. No ambiguity since they have separate wndProcs.

The existing App message-only HWND continues to use `"GhosttyWindow"` class (or a third class if needed for clarity) — it is identified by checking `GWLP_USERDATA` for `*App` vs `*Window`.

### New File: `Window.zig`

Responsibilities moved from Surface to Window:

- Top-level HWND creation (`CreateWindowExW` with `WS_OVERLAPPEDWINDOW`)
- Fullscreen toggle (operates on top-level HWND)
- Window title management (shows active tab's title)
- DWM dark mode and opacity setup
- Tab bar painting and hit testing
- Tab lifecycle (add, remove, select)
- Live resize synchronization (`WM_ENTERSIZEMOVE`/`WM_EXITSIZEMOVE`)
- `WM_DPICHANGED` handling (forward to active Surface, mark inactive tabs stale)

### Window Lifecycle

- `App` heap-allocates `Window` and calls `Window.init()`.
- `Window.init()` creates the top-level HWND and first Surface tab.
- `Window.deinit()` destroys all child Surfaces, then the top-level HWND.
- When all tabs close, Window calls `DestroyWindow` on itself.
- `WM_DESTROY` on the Window HWND triggers `Window.deinit()` and removes itself from App's window list.
- App's quit timer logic checks `windows.items.len == 0` instead of checking for remaining Surfaces.

### Surface Changes

Minimal refactor of Surface.zig:

- `init()` accepts a parent `*Window` reference. Creates with `WS_CHILD | WS_VISIBLE` style using the `"GhosttyTerminal"` window class, parented to the Window's HWND.
- Surface stores a `parent_window: *Window` back-reference for actions that need the top-level window.
- Sizing controlled by parent Window (Surface no longer handles top-level `WM_SIZE`).
- `close()` notifies parent Window (`Window.closeTab(self)`) instead of directly destroying the top-level HWND.
- Title changes notify parent Window (`Window.onTabTitleChanged(self)`) for tab bar repaint and title bar update.
- Fullscreen, maximize, opacity, decorations: delegated to parent Window via `parent_window`.
- Search popup: parent HWND changed from Surface's child HWND to `parent_window.hwnd` (top-level HWND). `GWLP_USERDATA` on the search popup still points to `*Surface`.
- Scrollbar remains on the Surface's child HWND (each tab has independent scroll state).

Everything else stays the same: OpenGL init, HDC/HGLRC, input handling, IME, core_surface ownership, rendering.

### Why Child HWNDs

Each tab's terminal surface is a separate child HWND with its own OpenGL context. This approach:

- Matches GTK (each Surface is a separate GtkWidget inside TabView)
- Matches macOS (each tab contains a separate NSView)
- Keeps existing Surface OpenGL code intact (no context sharing/switching)
- Is the standard Win32 pattern for multi-pane applications
- Makes future split panes natural (more child HWNDs)

## Tab Bar Design

### Rendering

- **API:** GDI (simple, no dependencies, sufficient for rectangles + text)
- **Region:** Reserved area at top of Window's client area (not a separate child HWND)
- **Height:** ~32px, DPI-scaled
- **Background:** Ghostty's configured background color, slightly lighter for contrast
- **Font:** Segoe UI (matches search bar) via `CreateFontW`, or `GetStockObject(DEFAULT_GUI_FONT)`
- **Flicker prevention:** Handle `WM_ERASEBKGND` on Window HWND returning 1 (already erased). Paint the full tab bar in `WM_PAINT` using double-buffering (`CreateCompatibleDC` + `BitBlt`).

### Tab Appearance

- **Active tab:** highlighted background + 2px bottom accent line
- **Inactive tabs:** dimmer text color
- **Hover:** subtle background highlight
- **Close button (X):** per-tab, right side of each tab
- **New tab button (+):** fixed at end of tab strip
- **Overflow:** tabs shrink proportionally when they exceed available width

### Tab Title Storage

Each tab stores its title as a `[256]u16` fixed-size UTF-16 buffer (consistent with Surface.zig's existing `setTitle` which uses a 512-element `u16` stack buffer). This avoids heap allocation for titles.

### Painting Flow

1. `WM_PAINT` on Window HWND → `BeginPaint`
2. Create back buffer DC (`CreateCompatibleDC` + `CreateCompatibleBitmap`)
3. Draw tab bar background rectangle
4. For each tab: draw background, text (`DrawTextW`), close button
5. Draw new-tab button (+)
6. `BitBlt` back buffer to screen DC
7. `EndPaint`
8. Surface child HWNDs handle their own painting independently (OpenGL)

### Hit Testing

- `WM_LBUTTONDOWN` in tab bar region: determine which tab, close button, or new-tab button was clicked
- Tab rects stored in an array, recalculated on resize and tab changes
- Hover effects via `WM_MOUSEMOVE` + `TrackMouseEvent` for `WM_MOUSELEAVE`

## Action Routing

### Current Flow

`App.performAction` handles all actions, operating directly on Surfaces.

### New Flow

| Action | Handler |
|--------|---------|
| `new_tab` | Find Window owning target surface → `Window.addTab()` |
| `close_tab` (.this) | `Window.closeTab(surface)` → if last tab, close Window |
| `goto_tab` | `Window.selectTab(target)` |
| `set_tab_title` | `Window.setTabTitle(surface, title)` → repaint tab bar |
| `close_window` | `Window.close()` → closes all tabs |

### Window-Level Action Migration

These existing actions currently operate on Surface's HWND but must be retargeted to Window's top-level HWND after refactor:

| Action | Current target | New target |
|--------|---------------|------------|
| `toggle_fullscreen` | `Surface.hwnd` | `Surface.parent_window.hwnd` |
| `toggle_maximize` | `rt_surface.hwnd` | `rt_surface.parent_window.hwnd` |
| `initial_size` | `rt_surface.hwnd` | `rt_surface.parent_window.hwnd` |
| `reset_window_size` | `rt_surface.hwnd` | `rt_surface.parent_window.hwnd` |
| `toggle_background_opacity` | `rt_surface.hwnd` | `rt_surface.parent_window.hwnd` |
| `toggle_window_decorations` | `Surface.hwnd` | `Surface.parent_window.hwnd` |
| `copy_title_to_clipboard` | `rt_surface.hwnd` | `rt_surface.parent_window.hwnd` |

### Window Tab Management Methods

- **`addTab()`**: Create new Surface as `WS_CHILD`, add to tab list at position determined by `window-new-tab-position` config, select it, update tab bar visibility (auto mode), repaint tab bar.
- **`closeTab(surface)`**: Hide Surface, remove from tab list, select adjacent tab, update tab bar visibility (auto mode). If last tab, close Window.
- **`selectTab(target)`**: Hide current Surface HWND. Resize target Surface to current client area if dimensions are stale (see Inactive Tab Handling). Show target Surface HWND, set keyboard focus, update window title, repaint tab bar.
- **`setTabTitle(surface, title)`**: Update stored title for tab, repaint tab bar. If active tab, also update window title bar.

## Inactive Tab Handling

### Resize

When `WM_SIZE` arrives on the Window HWND, only the active Surface child is resized immediately (triggering `sizeCallback` → SIGWINCH to PTY). Inactive tabs are marked with a `size_stale` flag. When `selectTab` activates a stale tab, it resizes the Surface to the current client area dimensions before showing it. This avoids sending SIGWINCH to hidden terminals.

### DPI Changes

When `WM_DPICHANGED` arrives, the active Surface receives the DPI update immediately. Inactive tabs are marked `dpi_stale`. On activation via `selectTab`, stale tabs receive the DPI update before being shown.

### Live Resize

`WM_ENTERSIZEMOVE` and `WM_EXITSIZEMOVE` arrive on the Window's top-level HWND. Window forwards `in_live_resize` state to the active Surface so the existing flicker-free resize logic (wait for renderer frame event) continues to work. On tab switch during live resize, the new active Surface inherits the `in_live_resize` state.

## Config Integration

### v1 Configs

| Config | Behavior |
|--------|----------|
| `window-new-tab-position: current` | Insert new tab after the currently active tab |
| `window-new-tab-position: end` | Append new tab at end of tab list |
| `window-show-tab-bar: always` | Always display tab bar |
| `window-show-tab-bar: auto` | Show tab bar only when 2+ tabs exist |
| `window-show-tab-bar: never` | Never show tab bar; tabs via keyboard only |

### Tab Bar Visibility Transitions

When tab bar visibility changes (e.g., second tab added in `auto` mode, or last extra tab closed):

1. Recalculate the Surface client area (full height vs. offset by tab bar height)
2. Resize the active Surface child in a single operation
3. Repaint: use `SWP_NOREDRAW` on the Surface resize, then `InvalidateRect` on the Window to repaint tab bar and let the Surface's renderer handle its own repaint on the next frame

This ensures the layout transition is a single, smooth visual update without flash.

## Message Routing

### Window's windowWndProc

The Window's top-level HWND uses `windowWndProc` that:

1. Handles `WM_PAINT` for the tab bar region (double-buffered GDI)
2. Handles `WM_ERASEBKGND` → returns 1 (prevents flicker)
3. Handles `WM_LBUTTONDOWN` / `WM_MOUSEMOVE` / `WM_MOUSELEAVE` in the tab bar region
4. Handles `WM_SIZE` → resizes tab bar and active Surface child, marks inactive tabs stale
5. Handles `WM_DPICHANGED` → forwards to active Surface, marks inactive tabs stale
6. Handles `WM_ENTERSIZEMOVE` / `WM_EXITSIZEMOVE` → forwards to active Surface
7. Handles `WM_CLOSE` → confirmation and cleanup
8. Handles `WM_DESTROY` → deinit Window, remove from App's window list
9. Delegates keyboard and other messages to the active Surface's child HWND or lets Win32 route them naturally (child HWND with focus receives keyboard messages directly)

### Keyboard Focus

When a tab is selected, `SetFocus()` is called on the Surface's child HWND. Win32 automatically routes `WM_KEYDOWN`, `WM_CHAR`, etc. to the focused child window, so no manual forwarding needed.

## Testing

Update existing test harness (`test/win32/test_harness.ps1`) to verify:

- `new_tab` creates a tab in the same window (not a new OS window) — verify OS window count stays at 1 while tab count increases
- Tab switching works (`goto_tab`) — verify window title changes
- Tab close works (`close_tab`) — verify tab count decreases
- Last tab close closes the window — verify OS window count drops to 0
- Window title reflects active tab's title
- `window-show-tab-bar: auto` hides bar with single tab

The test harness needs new capabilities:
- **`counttabs`**: Enumerate child HWNDs within a Ghostty window to count visible/total tab surfaces
- **`gettitle`**: Read the Window's title bar text to verify it matches the active tab
- Or alternatively: use accessibility APIs / window enumeration to inspect the Window's child structure
