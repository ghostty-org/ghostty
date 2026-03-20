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

- `App` tracks a list of `Window`s (instead of directly tracking Surfaces).
- `Window` owns the top-level HWND and manages the tab list.
- Each `Surface` becomes a `WS_CHILD` window inside the Window, with its own OpenGL context.
- Only the active tab's Surface HWND is visible.

### New File: `Window.zig`

Responsibilities moved from Surface to Window:

- Top-level HWND creation (`CreateWindowExW` with `WS_OVERLAPPEDWINDOW`)
- Fullscreen toggle
- Window title management (shows active tab's title)
- DWM dark mode and opacity setup
- Tab bar painting and hit testing
- Tab lifecycle (add, remove, select)

### Surface Changes

Minimal refactor of Surface.zig:

- `init()` accepts a parent HWND parameter. When provided, creates with `WS_CHILD | WS_VISIBLE` style instead of `WS_OVERLAPPEDWINDOW`.
- Sizing controlled by parent Window (Surface no longer handles top-level WM_SIZE).
- `close()` notifies parent Window instead of directly destroying the top-level HWND.
- Title management removed (delegated to Window).
- Fullscreen delegated to Window.

Everything else stays the same: OpenGL init, HDC/HGLRC, input handling, scrollbar, search popup, IME, core_surface ownership, rendering.

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

### Tab Appearance

- **Active tab:** highlighted background + 2px bottom accent line
- **Inactive tabs:** dimmer text color
- **Hover:** subtle background highlight
- **Close button (X):** per-tab, right side of each tab
- **New tab button (+):** fixed at end of tab strip
- **Overflow:** tabs shrink proportionally when they exceed available width

### Painting Flow

1. `WM_PAINT` on Window HWND → `BeginPaint`
2. Draw tab bar background rectangle
3. For each tab: draw background, text (`DrawTextW`), close button
4. Draw new-tab button (+)
5. `EndPaint`
6. Surface child HWNDs handle their own painting independently (OpenGL)

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

### Window Tab Management Methods

- **`addTab()`**: Create new Surface as `WS_CHILD`, add to tab list at position determined by `window-new-tab-position` config, select it, repaint tab bar.
- **`closeTab(surface)`**: Hide Surface, remove from tab list, select adjacent tab. If last tab, close Window.
- **`selectTab(target)`**: Hide current Surface HWND, show target Surface HWND, set keyboard focus, update window title, repaint tab bar.
- **`setTabTitle(surface, title)`**: Update stored title for tab, repaint tab bar. If active tab, also update window title bar.

## Config Integration

### v1 Configs

| Config | Behavior |
|--------|----------|
| `window-new-tab-position: current` | Insert new tab after the currently active tab |
| `window-new-tab-position: end` | Append new tab at end of tab list |
| `window-show-tab-bar: always` | Always display tab bar |
| `window-show-tab-bar: auto` | Show tab bar only when 2+ tabs exist |
| `window-show-tab-bar: never` | Never show tab bar; tabs via keyboard only |

### Tab Bar Height Adjustment

When tab bar is hidden (single tab in `auto` mode, or `never` mode), the active Surface child HWND gets the full client area. When tab bar is visible, Surface is offset below the tab bar height.

## Message Routing

### Window's wndProc

The Window's top-level HWND has its own `wndProc` that:

1. Handles `WM_PAINT` for the tab bar region
2. Handles `WM_LBUTTONDOWN` / `WM_MOUSEMOVE` / `WM_MOUSELEAVE` in the tab bar region
3. Handles `WM_SIZE` → resizes tab bar and active Surface child
4. Handles `WM_CLOSE` → confirmation and cleanup
5. Handles `WM_DESTROY` → deinit Window
6. Delegates keyboard and other messages to the active Surface's child HWND or lets Win32 route them naturally (child HWND with focus receives keyboard messages directly)

### Keyboard Focus

When a tab is selected, `SetFocus()` is called on the Surface's child HWND. Win32 automatically routes `WM_KEYDOWN`, `WM_CHAR`, etc. to the focused child window, so no manual forwarding needed.

## Testing

Update existing test harness to verify:

- `new_tab` creates a tab in the same window (not a new OS window)
- Tab switching works (goto_tab)
- Tab close works (close_tab reduces tab count)
- Last tab close closes the window
- Window title reflects active tab
- `window-show-tab-bar: auto` hides bar with single tab
