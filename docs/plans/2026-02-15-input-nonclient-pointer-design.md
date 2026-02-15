# InputNonClientPointerSource for WinUI 3 Tab Bar Drag

## Problem

The XAML Island (`DesktopWindowXamlSource`) intercepts all mouse input at the composition level, bypassing the Win32 HWND hit-test tree entirely. A transparent child overlay window placed above the island never receives `WM_NCHITTEST` because the island's internal input routing captures events before Win32 message dispatch.

## Solution

Use WinUI 3's `InputNonClientPointerSource` API to define caption (drag) and passthrough (interactive) regions within the XAML Island area. This is the official Microsoft-recommended approach for custom title bars in WinUI 3.

### How It Works

1. `AppWindowTitleBar.ExtendsContentIntoTitleBar = true` -- tells the system our app handles its own title bar
2. `InputNonClientPointerSource.GetForWindowId(windowId)` -- gets the non-client input source
3. `SetRegionRects(NonClientRegionKind.Passthrough, rects)` -- marks interactive areas (tabs, buttons) that receive clicks instead of triggering drag
4. The entire title bar height becomes a caption/drag region by default; passthrough rects carve out clickable controls

## Architecture

### C++ side (`ghostty_winui.cpp`)

New exported functions:

- `ghostty_tabview_setup_drag_regions(GhosttyTabView tv, HWND parent_hwnd)` -- one-time setup: calls `ExtendsContentIntoTitleBar = true`, stores `InputNonClientPointerSource` reference, hooks `SizeChanged` for auto-updates
- `ghostty_tabview_update_drag_regions(GhosttyTabView tv, HWND parent_hwnd)` -- computes passthrough rects for each tab item + add-tab button using `TransformToVisual`, calls `SetRegionRects`. Logs each rect and element name.

Internal:
- On TabView `SizeChanged`, auto-call update. Log when this fires.
- On tab add/remove/rename, auto-call update. Log when this fires.
- All coordinate calculations multiply by `XamlRoot.RasterizationScale` for DPI correctness
- Log: element names, computed rects (both logical and physical), scale factor, total passthrough rect count

### Zig side (`Window.zig`)

Remove:
- `createDragOverlay()`, `dragOverlayProc()`, `dragOverlayHitTest()`
- `drag_overlay_hwnd` field on Window
- `registerDragOverlayClass()` in App.zig
- `ghostty_tabview_hit_test()` C++ function and its Zig binding

Add:
- Call `ghostty_tabview_setup_drag_regions` during WinUI init (after TabView creation)
- Call `ghostty_tabview_update_drag_regions` on `WM_SIZE` / resize
- Log each call with window dimensions and result

Keep:
- `WM_NCHITTEST` in parent window proc for resize borders (left/right/bottom) -- these are outside the island area and still work via Win32

### Logging Requirements

Every step must be logged for diagnostics:

**C++ side (to `ghostty_winui_log.txt`):**
- `setup_drag_regions`: parent HWND, window ID, ExtendsContentIntoTitleBar result
- `update_drag_regions`: scale factor, number of elements found, each element's name + logical rect + physical rect
- `SetRegionRects` call: number of passthrough rects passed
- SizeChanged/tab change callbacks: what triggered the update
- Any exceptions caught

**Zig side (to `std.log` scoped `win32_window`):**
- When setup/update functions are called and with what parameters
- When the drag overlay code is removed (absence of old logs confirms cleanup)
- Window resize events that trigger region updates

## Key Details

- Passthrough rects use physical pixel coordinates (multiply by RasterizationScale)
- Must recalculate on: window resize, tab add/remove, tab rename (width change), DPI change
- Caption buttons (min/max/close) handled automatically by system when ExtendsContentIntoTitleBar = true
- Top resize border: handled by system title bar logic since we extend content into it
- Left/right/bottom resize borders: still handled by existing WM_NCHITTEST in parent wndproc

## Implementation Steps

1. Add new C++ functions (`setup_drag_regions`, `update_drag_regions`) with full logging
2. Add Zig bindings in `WinUI.zig` for the new functions
3. Remove drag overlay code from `Window.zig` and `App.zig`
4. Remove `ghostty_tabview_hit_test` from C++ and Zig
5. Wire up calls in Window.zig: setup during WinUI init, update on resize
6. Build and test: verify drag works on tab bar background, tabs are clickable, resize borders work
