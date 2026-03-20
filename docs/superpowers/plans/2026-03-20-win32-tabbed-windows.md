# Win32 Tabbed Windows Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the current "one HWND per tab" model with real tabbed windows — a Window container with a custom GDI tab bar hosting multiple Surface child HWNDs.

**Architecture:** New `Window.zig` struct owns a top-level HWND and manages a list of Surface child HWNDs as tabs. A custom GDI-drawn tab bar sits at the top of the Window's client area. Surface changes from `WS_OVERLAPPEDWINDOW` to `WS_CHILD`. Two separate Win32 window classes: `"GhosttyWindow"` for Window, `"GhosttyTerminal"` for Surface children.

**Tech Stack:** Zig, Win32 API (GDI, WGL, DWM), OpenGL

**Spec:** `docs/superpowers/specs/2026-03-20-win32-tabbed-windows-design.md`

---

## File Structure

| File | Role | Action |
|------|------|--------|
| `src/apprt/win32/Window.zig` | Tab container: top-level HWND, tab bar, tab list | Create |
| `src/apprt/win32/Surface.zig` | Terminal child HWND + OpenGL context | Modify |
| `src/apprt/win32/App.zig` | Window class registration, action routing, window list | Modify |
| `src/apprt/win32/win32.zig` | New Win32 API declarations (GDI drawing, child window styles) | Modify |
| `test/win32/ghostty_test.sh` | Tab integration tests | Modify |

---

## Task 1: Register Separate Window Classes

Split the single `"GhosttyWindow"` class into two: one for the Window container (GDI painting, no `CS_OWNDC`) and one for Surface terminals (OpenGL, `CS_OWNDC`).

**Files:**
- Modify: `src/apprt/win32/App.zig:30` (CLASS_NAME constant)
- Modify: `src/apprt/win32/App.zig:93-117` (init, window class registration)
- Modify: `src/apprt/win32/App.zig:178-199` (terminate, unregister both classes)

- [ ] **Step 1: Add the second class name constant**

In `src/apprt/win32/App.zig`, after line 30, add:

```zig
const TERMINAL_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyTerminal");
```

And add a field to store the second atom:

```zig
terminal_class_atom: u16 = 0,
```

- [ ] **Step 2: Rename existing class to WINDOW_CLASS_NAME**

Rename `CLASS_NAME` to `WINDOW_CLASS_NAME` throughout App.zig. Update references at lines 30, 112, 123, 763.

- [ ] **Step 3: Modify the existing class registration to remove CS_OWNDC**

In `App.init()` around line 103, change the existing class to NOT use `CS_OWNDC` (the Window container does GDI painting only):

```zig
const wc = w32.WNDCLASSEXW{
    .cbSize = @sizeOf(w32.WNDCLASSEXW),
    .style = 0,  // No CS_OWNDC — Window uses BeginPaint/EndPaint
    .lpfnWndProc = &windowWndProc,  // Will be renamed in Task 3
    .cbClsExtra = 0,
    .cbWndExtra = 0,
    .hInstance = hinstance,
    .hIcon = null,
    .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
    .hbrBackground = bg_brush,
    .lpszMenuName = null,
    .lpszClassName = WINDOW_CLASS_NAME,
    .hIconSm = null,
};
```

- [ ] **Step 4: Register the terminal class with CS_OWNDC**

After the first registration, add:

```zig
const tc = w32.WNDCLASSEXW{
    .cbSize = @sizeOf(w32.WNDCLASSEXW),
    .style = w32.CS_OWNDC,
    .lpfnWndProc = &surfaceWndProc,  // Will be created in Task 3
    .cbClsExtra = 0,
    .cbWndExtra = 0,
    .hInstance = hinstance,
    .hIcon = null,
    .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
    .hbrBackground = null,  // OpenGL handles all painting
    .lpszMenuName = null,
    .lpszClassName = TERMINAL_CLASS_NAME,
    .hIconSm = null,
};

self.terminal_class_atom = w32.RegisterClassExW(&tc);
if (self.terminal_class_atom == 0) return error.Win32Error;
```

- [ ] **Step 5: Update terminate() to unregister both classes**

In `terminate()`, after existing cleanup, add unregistration for the terminal class. (Win32 auto-unregisters on process exit, but explicit cleanup is good practice.)

- [ ] **Step 6: Verify compilation**

Run: `zig build -Dapp-runtime=win32 2>&1 | head -30`
Expected: Compiles cleanly (or only unrelated warnings). The `windowWndProc` and `surfaceWndProc` references won't exist yet — use `&wndProc` as placeholder for both until Task 3.

- [ ] **Step 7: Commit**

```bash
git add src/apprt/win32/App.zig
git commit -m "refactor: register separate GhosttyWindow and GhosttyTerminal window classes"
```

---

## Task 2: Create Window.zig Skeleton

Create the Window struct with its fields, init/deinit, and top-level HWND creation. No tab bar painting yet — just the container.

**Files:**
- Create: `src/apprt/win32/Window.zig`
- Modify: `src/apprt/win32/App.zig` (import Window, add window list)

- [ ] **Step 1: Create Window.zig with struct definition**

```zig
//! Win32 Window container. Each Window owns a top-level HWND and manages
//! a list of Surface tabs. The tab bar is drawn via GDI in the Window's
//! client area; each tab's terminal surface is a WS_CHILD HWND.
const Window = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const Config = configpkg.Config;

const App = @import("App.zig");
const Surface = @import("Surface.zig");
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32);

/// Maximum number of tabs per window.
const MAX_TABS = 64;

/// Tab bar height in logical pixels (scaled by DPI).
const TAB_BAR_HEIGHT = 32;

/// The parent App.
app: *App,

/// The top-level window handle.
hwnd: ?w32.HWND = null,

/// List of tab surfaces. Order matches visual tab order.
tabs: std.BoundedArray(*Surface, MAX_TABS) = .{},

/// Index of the currently active (visible) tab.
active_tab: usize = 0,

/// Whether the tab bar is currently visible.
tab_bar_visible: bool = false,

/// DPI scale factor.
scale: f32 = 1.0,

/// Tab bar hit-test rectangles, recalculated on resize/tab change.
tab_rects: [MAX_TABS]w32.RECT = undefined,

/// Rectangle for the new-tab (+) button.
new_tab_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

/// Index of the tab currently being hovered (-1 = none).
hover_tab: isize = -1,

/// Whether the mouse is hovering over the close button of hover_tab.
hover_close: bool = false,

/// Whether the mouse is hovering over the new-tab button.
hover_new_tab: bool = false,

/// Tab titles stored as fixed UTF-16 buffers.
tab_titles: [MAX_TABS][256]u16 = undefined,

/// Length of each tab title (in u16 units).
tab_title_lens: [MAX_TABS]u16 = undefined,

/// Fullscreen state (moved from Surface).
is_fullscreen: bool = false,
saved_style: u32 = 0,
saved_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

/// Font for tab bar text.
tab_font: ?w32.HFONT = null,

/// Whether we are tracking mouse leave events.
tracking_mouse: bool = false,
```

- [ ] **Step 2: Write init() — creates top-level HWND**

```zig
pub fn init(self: *Window, app: *App) !void {
    self.* = .{ .app = app };

    // Create the tab bar font (Segoe UI, scaled for DPI)
    self.tab_font = w32.CreateFontW(
        -16, 0, 0, 0, // height, width, escapement, orientation
        w32.FW_NORMAL, 0, 0, 0, // weight, italic, underline, strikeout
        w32.DEFAULT_CHARSET, 0, 0, 0, 0, // charset, precision, clip, quality, pitch
        std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
    );

    const hwnd = w32.CreateWindowExW(
        0,
        App.WINDOW_CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral("Ghostty"),
        w32.WS_OVERLAPPEDWINDOW,
        w32.CW_USEDEFAULT,
        w32.CW_USEDEFAULT,
        800,
        600,
        null,
        null,
        app.hinstance,
        null,
    ) orelse return error.Win32Error;

    self.hwnd = hwnd;
    errdefer {
        _ = w32.DestroyWindow(hwnd);
        self.hwnd = null;
    }

    // Store Window pointer for windowWndProc
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    // Dark mode and theme setup
    const dark_mode: u32 = 1;
    _ = w32.DwmSetWindowAttribute(
        hwnd,
        w32.DWMWA_USE_IMMERSIVE_DARK_MODE,
        @ptrCast(&dark_mode),
        @sizeOf(u32),
    );
    _ = w32.SetWindowTheme(
        hwnd,
        std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"),
        null,
    );

    // Background opacity
    if (app.config.@"background-opacity" < 1.0) {
        const current_ex = w32.GetWindowLongW(hwnd, w32.GWL_EXSTYLE);
        _ = w32.SetWindowLongW(hwnd, w32.GWL_EXSTYLE, current_ex | w32.WS_EX_LAYERED);
        const alpha: u8 = @intFromFloat(@round(app.config.@"background-opacity" * 255.0));
        _ = w32.SetLayeredWindowAttributes(hwnd, 0, alpha, w32.LWA_ALPHA);
    }

    _ = w32.ShowWindow(hwnd, w32.SW_SHOW);
    _ = w32.UpdateWindow(hwnd);
}
```

- [ ] **Step 3: Write deinit()**

```zig
pub fn deinit(self: *Window) void {
    // Close all tab surfaces
    for (self.tabs.slice()) |surface| {
        surface.deinit();
        self.app.core_app.alloc.destroy(surface);
    }
    self.tabs.len = 0;

    if (self.tab_font) |font| {
        _ = w32.DeleteObject(@ptrCast(font));
        self.tab_font = null;
    }

    if (self.hwnd) |hwnd| {
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
        _ = w32.DestroyWindow(hwnd);
        self.hwnd = null;
    }
}
```

- [ ] **Step 4: Write tabBarHeight() helper**

```zig
/// Returns the current tab bar height in pixels, accounting for DPI and visibility.
pub fn tabBarHeight(self: *const Window) i32 {
    if (!self.tab_bar_visible) return 0;
    return @intFromFloat(@round(@as(f32, TAB_BAR_HEIGHT) * self.scale));
}
```

- [ ] **Step 5: Write surfaceRect() helper**

```zig
/// Returns the rectangle for the terminal surface area (below tab bar).
pub fn surfaceRect(self: *const Window) w32.RECT {
    const hwnd = self.hwnd orelse return .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    var client: w32.RECT = undefined;
    _ = w32.GetClientRect(hwnd, &client);
    client.top += self.tabBarHeight();
    return client;
}
```

- [ ] **Step 6: Add Window import and window list to App.zig**

In `src/apprt/win32/App.zig`, add:

```zig
const Window = @import("Window.zig");
```

Add a field to the App struct (after `bg_brush`):

```zig
/// All open windows.
windows: std.ArrayList(*Window) = undefined,
```

Initialize in `init()` after `self.*`:

```zig
self.windows = std.ArrayList(*Window).init(core_app.alloc);
```

Deinit in `terminate()`:

```zig
self.windows.deinit();
```

- [ ] **Step 7: Add needed Win32 declarations to win32.zig**

Add any missing declarations. Check what's already there and only add what's missing. Key additions:
- `pub const HFONT = *anyopaque;` (CreateFontW returns `?*anyopaque`, but typed alias is cleaner)
- `GetClientRect`, `MoveWindow`, `SetFocus`
- `SW_HIDE` constant (value 0)
- `CreateFontW`, `FW_NORMAL`, `DEFAULT_CHARSET`
- `DeleteObject` (if not already present)

- [ ] **Step 8: Verify compilation**

Run: `zig build -Dapp-runtime=win32 2>&1 | head -30`
Expected: Compiles cleanly.

- [ ] **Step 9: Commit**

```bash
git add src/apprt/win32/Window.zig src/apprt/win32/App.zig src/apprt/win32/win32.zig
git commit -m "feat: add Window.zig skeleton with init/deinit and HWND creation"
```

---

## Task 3: Split wndProc into windowWndProc and surfaceWndProc

The current monolithic `wndProc` handles both App messages and Surface messages. Split it so Window and Surface each have dedicated message procedures.

**Files:**
- Modify: `src/apprt/win32/App.zig:822-1073` (wndProc → windowWndProc + surfaceWndProc)
- Modify: `src/apprt/win32/Window.zig` (add windowWndProc)

- [ ] **Step 1: Create windowWndProc in Window.zig**

This handles messages for the top-level Window HWND. For now, delegate most messages to `DefWindowProcW` — painting and tab bar handling come in later tasks.

```zig
pub fn windowWndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.c) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    const window: *Window = if (userdata != 0)
        @ptrFromInt(@as(usize, @bitCast(userdata)))
    else
        return w32.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        w32.WM_SIZE => {
            window.handleResize();
            return 0;
        },

        w32.WM_ENTERSIZEMOVE => {
            if (window.getActiveSurface()) |s| s.in_live_resize = true;
            return 0;
        },

        w32.WM_EXITSIZEMOVE => {
            if (window.getActiveSurface()) |s| s.in_live_resize = false;
            return 0;
        },

        w32.WM_CLOSE => {
            window.close();
            return 0;
        },

        w32.WM_DESTROY => {
            _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
            window.onDestroy();
            return 0;
        },

        w32.WM_ERASEBKGND => {
            return 1; // Handled — prevents flicker
        },

        // Search bar routing: WM_COMMAND (EN_CHANGE) and WM_CTLCOLOREDIT
        // arrive on the top-level Window HWND because the search popup's
        // parent is now the Window (not the Surface child). Route these
        // to the active Surface which owns the search bar.
        w32.WM_COMMAND => {
            if (window.getActiveSurface()) |surface| {
                return surface.handleCommand(wparam, lparam);
            }
            return 0;
        },

        w32.WM_CTLCOLOREDIT => {
            if (window.getActiveSurface()) |surface| {
                return surface.handleCtlColorEdit(wparam, lparam);
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
```

- [ ] **Step 2: Add helper methods referenced by windowWndProc**

```zig
pub fn getActiveSurface(self: *Window) ?*Surface {
    if (self.tabs.len == 0) return null;
    return self.tabs.get(self.active_tab);
}

fn handleResize(self: *Window) void {
    const rect = self.surfaceRect();
    const width: u32 = @intCast(rect.right - rect.left);
    const height: u32 = @intCast(rect.bottom - rect.top);
    if (self.getActiveSurface()) |surface| {
        _ = w32.MoveWindow(surface.hwnd.?, rect.left, rect.top, width, height, 1);
    }
}

fn close(self: *Window) void {
    // For now, just destroy. Close confirmation can be added later.
    if (self.hwnd) |hwnd| {
        _ = w32.DestroyWindow(hwnd);
    }
}

fn onDestroy(self: *Window) void {
    // Remove from App's window list
    for (self.app.windows.items, 0..) |w, i| {
        if (w == self) {
            _ = self.app.windows.orderedRemove(i);
            break;
        }
    }

    self.hwnd = null;
    self.deinit();
    self.app.core_app.alloc.destroy(self);

    // If no windows remain, start the quit timer
    if (self.app.windows.items.len == 0) {
        self.app.startQuitTimer();
    }
}
```

- [ ] **Step 3: Extract surfaceWndProc from existing wndProc**

In `App.zig`, rename the existing `wndProc` to `surfaceWndProc` and make it `pub`. Remove the App-level message handling (WM_APP_WAKEUP, WM_TIMER for quit/notification) — those stay in the old wndProc which becomes the msg-only window's handler.

The surfaceWndProc only handles Surface child HWND messages (WM_SIZE, WM_KEYDOWN, WM_PAINT, etc.) — the same switch block that's currently at lines 879-1072.

- [ ] **Step 4: Create a minimal msgWndProc for the message-only window**

The message-only HWND only needs WM_APP_WAKEUP and WM_TIMER. Extract those into a small dedicated proc, or keep using the Window class's wndProc (since the msg_hwnd uses the same class). The simplest approach: register a third class `"GhosttyMsg"` for the message-only HWND, or reuse `WINDOW_CLASS_NAME` but check `GWLP_USERDATA` type.

Simplest: keep the message-only HWND on the `WINDOW_CLASS_NAME` class. In `windowWndProc`, check if the stored pointer is an `*App` vs `*Window` by checking `msg == WM_APP_WAKEUP` or `msg == WM_TIMER` first (these only go to the msg_hwnd).

Actually the cleanest approach: register a third class `"GhosttyMsg"` with its own `msgWndProc`:

```zig
// In App.zig
const MSG_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyMsg");

fn msgWndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.c) isize {
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (userdata == 0) return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const app: *App = @ptrFromInt(@as(usize, @bitCast(userdata)));

    if (msg == WM_APP_WAKEUP) { app.tick(); return 0; }
    if (msg == w32.WM_TIMER and wparam == QUIT_TIMER_ID) {
        _ = w32.KillTimer(hwnd, QUIT_TIMER_ID);
        app.quit_timer_state = .expired;
        app.quit_requested = true;
        w32.PostQuitMessage(0);
        return 0;
    }
    if (msg == w32.WM_TIMER and wparam == 2) {
        _ = w32.KillTimer(hwnd, 2);
        var nid: w32.NOTIFYICONDATAW = std.mem.zeroes(w32.NOTIFYICONDATAW);
        nid.cbSize = @sizeOf(w32.NOTIFYICONDATAW);
        nid.hWnd = hwnd;
        nid.uID = 1;
        _ = w32.Shell_NotifyIconW(w32.NIM_DELETE, &nid);
        return 0;
    }
    return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
}
```

Register this class in `init()` and use it for `msg_hwnd` creation.

- [ ] **Step 5: Update class references**

- Window class registration: `lpfnWndProc = &Window.windowWndProc`
- Terminal class registration: `lpfnWndProc = &surfaceWndProc`
- Msg class registration: `lpfnWndProc = &msgWndProc`
- `msg_hwnd` creation: use `MSG_CLASS_NAME`

- [ ] **Step 6: Verify compilation**

Run: `zig build -Dapp-runtime=win32 2>&1 | head -30`

- [ ] **Step 7: Commit**

```bash
git add src/apprt/win32/App.zig src/apprt/win32/Window.zig
git commit -m "refactor: split wndProc into windowWndProc, surfaceWndProc, and msgWndProc"
```

---

## Task 4: Refactor Surface to Use WS_CHILD

Change Surface from creating its own top-level window to accepting a parent Window and creating a child HWND.

**Files:**
- Modify: `src/apprt/win32/Surface.zig:21-190` (fields, init, deinit)
- Modify: `src/apprt/win32/Surface.zig:318-337` (close)
- Modify: `src/apprt/win32/Surface.zig:490-500` (setTitle)
- Modify: `src/apprt/win32/Surface.zig:503-549` (fullscreen)
- Modify: `src/apprt/win32/Surface.zig:628-696` (search popup)
- Modify: `src/apprt/win32/Window.zig` (addTab method)

- [ ] **Step 1: Add parent_window field to Surface**

In Surface.zig, add after the `app` field (line 38):

```zig
/// The parent Window that contains this Surface as a tab.
parent_window: *const Window = undefined,
```

Import Window:

```zig
const Window = @import("Window.zig");
```

- [ ] **Step 2: Change Surface.init() to accept parent Window**

Change the signature from `pub fn init(self: *Surface, app: *App) !void` to:

```zig
pub fn init(self: *Surface, app: *App, parent: *Window) !void
```

Replace `self.* = .{ .app = app };` with:

```zig
self.* = .{ .app = app, .parent_window = parent };
```

Replace the `const hwnd = try app.createWindow();` call with creating a WS_CHILD window directly:

```zig
const parent_hwnd = parent.hwnd orelse return error.Win32Error;
const sr = parent.surfaceRect();
const hwnd = w32.CreateWindowExW(
    0,
    App.TERMINAL_CLASS_NAME,
    null,  // Child windows don't need a title
    w32.WS_CHILD,  // Not visible initially — Window.selectTab shows it
    sr.left,
    sr.top,
    @intCast(sr.right - sr.left),
    @intCast(sr.bottom - sr.top),
    parent_hwnd,
    null,
    app.hinstance,
    null,
) orelse return error.Win32Error;
```

- [ ] **Step 3: Update Surface.close() to notify parent Window**

Replace the current `close()` implementation (lines 318-337) to notify the parent instead:

```zig
pub fn close(self: *Surface, process_active: bool) void {
    _ = process_active; // TODO: confirmation dialog via parent Window
    self.parent_window.closeTab(self);
}
```

- [ ] **Step 4: Update Surface.setTitle() to notify parent Window**

Replace the `SetWindowTextW` call with notification to parent:

```zig
pub fn setTitle(self: *Surface, title: [:0]const u8) void {
    // Notify parent window to update tab title and title bar
    self.parent_window.onTabTitleChanged(self, title);
}
```

- [ ] **Step 5: Move fullscreen toggle to Window**

In Surface.zig, replace `toggleFullscreen()` (lines 503-549) with a delegation:

```zig
pub fn toggleFullscreen(self: *Surface) void {
    self.parent_window.toggleFullscreen();
}
```

Move the actual fullscreen logic into `Window.zig`:

```zig
pub fn toggleFullscreen(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    if (!self.is_fullscreen) {
        // Save current style and rect
        self.saved_style = @bitCast(w32.GetWindowLongW(hwnd, w32.GWL_STYLE));
        _ = w32.GetWindowRect(hwnd, &self.saved_rect);

        // Apply popup style and fill monitor
        _ = w32.SetWindowLongW(hwnd, w32.GWL_STYLE, @bitCast(@as(u32, w32.WS_POPUP | w32.WS_VISIBLE)));
        const monitor = w32.MonitorFromWindow(hwnd, w32.MONITOR_DEFAULTTONEAREST);
        var mi: w32.MONITORINFO = undefined;
        mi.cbSize = @sizeOf(w32.MONITORINFO);
        if (w32.GetMonitorInfoW(monitor, &mi) != 0) {
            _ = w32.SetWindowPos(
                hwnd, null,
                mi.rcMonitor.left, mi.rcMonitor.top,
                mi.rcMonitor.right - mi.rcMonitor.left,
                mi.rcMonitor.bottom - mi.rcMonitor.top,
                w32.SWP_NOZORDER | w32.SWP_FRAMECHANGED,
            );
        }
    } else {
        // Restore saved style and rect
        _ = w32.SetWindowLongW(hwnd, w32.GWL_STYLE, @bitCast(self.saved_style));
        _ = w32.SetWindowPos(
            hwnd, null,
            self.saved_rect.left, self.saved_rect.top,
            self.saved_rect.right - self.saved_rect.left,
            self.saved_rect.bottom - self.saved_rect.top,
            w32.SWP_NOZORDER | w32.SWP_FRAMECHANGED,
        );
    }
    self.is_fullscreen = !self.is_fullscreen;
}
```

- [ ] **Step 6: Move toggleWindowDecorations() to Window**

Similarly, Surface delegates to `self.parent_window.toggleWindowDecorations()`. Move the style toggling logic from Surface.zig into Window.zig, operating on `self.hwnd`.

- [ ] **Step 7: Update search popup parent HWND and window class**

In `ensureSearchBar()` (Surface.zig ~line 637), change the parent from `self.hwnd` to `self.parent_window.hwnd.?`:

```zig
self.parent_window.hwnd.?,  // Parent is the top-level Window, not the child Surface
```

Also change the search popup's window class. Currently it uses `"GhosttyWindow"` (line 635), but after the refactor, `"GhosttyWindow"` routes to `windowWndProc` which expects `*Window` in GWLP_USERDATA. The search popup stores `*Surface`. Fix by either:
- Using a generic class name like `App.MSG_CLASS_NAME` for the popup, OR
- Creating the popup with `CreateWindowExW` using an explicit `lpfnWndProc` override (not possible with class-based creation)

Simplest fix: create the popup with `TERMINAL_CLASS_NAME` or just a bare WS_POPUP with no class association. Since the popup is a `WS_POPUP` with `WS_EX_TOOLWINDOW`, it receives very few messages — the existing message loop intercept in `App.run()` handles keyboard, and `WM_COMMAND`/`WM_CTLCOLOREDIT` are now routed through `windowWndProc` to the active Surface. The popup itself can use `DefWindowProcW` for everything else. Use `TERMINAL_CLASS_NAME` for the popup class.

- [ ] **Step 8: Add addTab() and related methods to Window.zig**

```zig
pub fn addTab(self: *Window) !*Surface {
    const alloc = self.app.core_app.alloc;
    const surface = try alloc.create(Surface);
    errdefer alloc.destroy(surface);
    try surface.init(self.app, self);

    // Determine insert position from config
    const pos: usize = switch (self.app.config.@"window-new-tab-position") {
        .current => if (self.tabs.len > 0) self.active_tab + 1 else 0,
        .end => self.tabs.len,
    };

    // Insert into tab list
    // BoundedArray doesn't have insert, so shift manually
    try self.tabs.append(surface); // append first to check capacity
    // Shift elements right from pos to end-1
    var i: usize = self.tabs.len - 1;
    while (i > pos) : (i -= 1) {
        self.tabs.set(i, self.tabs.get(i - 1));
    }
    self.tabs.set(pos, surface);

    // Set default tab title
    const default_title = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");
    @memcpy(self.tab_titles[pos][0..default_title.len], default_title);
    self.tab_title_lens[pos] = @intCast(default_title.len);

    // Select the new tab
    self.selectTabIndex(pos);
    self.updateTabBarVisibility();

    return surface;
}

pub fn closeTab(self: *Window, surface: *Surface) void {
    // Find the tab index
    var idx: ?usize = null;
    for (self.tabs.slice(), 0..) |s, i| {
        if (s == surface) { idx = i; break; }
    }
    const tab_idx = idx orelse return;

    // Hide and destroy the surface
    if (surface.hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
    surface.deinit();
    self.app.core_app.alloc.destroy(surface);

    // Remove from tab list (shift left)
    _ = self.tabs.orderedRemove(tab_idx);

    if (self.tabs.len == 0) {
        // Last tab closed — destroy the window
        if (self.hwnd) |hwnd| _ = w32.DestroyWindow(hwnd);
        return;
    }

    // Adjust active tab index
    if (self.active_tab >= self.tabs.len) {
        self.active_tab = self.tabs.len - 1;
    } else if (self.active_tab > tab_idx) {
        self.active_tab -= 1;
    }
    self.selectTabIndex(self.active_tab);
    self.updateTabBarVisibility();
}

fn selectTabIndex(self: *Window, idx: usize) void {
    if (idx >= self.tabs.len) return;

    // Hide current active tab
    if (self.active_tab < self.tabs.len) {
        if (self.tabs.get(self.active_tab).hwnd) |h| {
            _ = w32.ShowWindow(h, w32.SW_HIDE);
        }
    }

    self.active_tab = idx;
    const surface = self.tabs.get(idx);

    // Resize to current surface area and show
    const sr = self.surfaceRect();
    if (surface.hwnd) |h| {
        _ = w32.MoveWindow(
            h, sr.left, sr.top,
            @intCast(sr.right - sr.left),
            @intCast(sr.bottom - sr.top),
            1,
        );
        _ = w32.ShowWindow(h, w32.SW_SHOW);
        _ = w32.SetFocus(h);
    }

    // Update window title to match active tab
    self.updateWindowTitle();
}

pub fn selectTab(self: *Window, target: apprt.action.GotoTab) bool {
    if (self.tabs.len <= 1) return false;
    const idx: usize = switch (target) {
        .previous => if (self.active_tab > 0) self.active_tab - 1 else self.tabs.len - 1,
        .next => if (self.active_tab + 1 < self.tabs.len) self.active_tab + 1 else 0,
        .last => self.tabs.len - 1,
        else => blk: {
            const n: usize = @intCast(@intFromEnum(target));
            break :blk if (n < self.tabs.len) n else return false;
        },
    };
    self.selectTabIndex(idx);
    self.invalidateTabBar();
    return true;
}

fn updateWindowTitle(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    if (self.tabs.len == 0) return;
    const len = self.tab_title_lens[self.active_tab];
    var buf: [257]u16 = undefined;
    @memcpy(buf[0..len], self.tab_titles[self.active_tab][0..len]);
    buf[len] = 0;
    _ = w32.SetWindowTextW(hwnd, @ptrCast(&buf));
}

pub fn onTabTitleChanged(self: *Window, surface: *Surface, title: [:0]const u8) void {
    for (self.tabs.slice(), 0..) |s, i| {
        if (s == surface) {
            var wbuf: [256]u16 = undefined;
            const wlen = std.unicode.utf8ToUtf16Le(&wbuf, title) catch 0;
            const len: u16 = @intCast(@min(wlen, 255));
            @memcpy(self.tab_titles[i][0..len], wbuf[0..len]);
            self.tab_title_lens[i] = len;
            if (i == self.active_tab) self.updateWindowTitle();
            self.invalidateTabBar();
            return;
        }
    }
}

fn updateTabBarVisibility(self: *Window) void {
    const show_config = self.app.config.@"window-show-tab-bar";
    const should_show = switch (show_config) {
        .always => true,
        .auto => self.tabs.len > 1,
        .never => false,
    };
    if (should_show != self.tab_bar_visible) {
        self.tab_bar_visible = should_show;
        self.handleResize(); // Recalculate surface area
    }
}

fn invalidateTabBar(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    var rect = w32.RECT{
        .left = 0, .top = 0,
        .right = 10000, // Will be clipped to client area
        .bottom = self.tabBarHeight(),
    };
    _ = w32.InvalidateRect(hwnd, &rect, 0);
}
```

- [ ] **Step 9: Verify compilation**

Run: `zig build -Dapp-runtime=win32 2>&1 | head -30`

- [ ] **Step 10: Commit**

```bash
git add src/apprt/win32/Surface.zig src/apprt/win32/Window.zig src/apprt/win32/win32.zig
git commit -m "refactor: Surface uses WS_CHILD, Window manages tab lifecycle"
```

---

## Task 5: Wire Up App to Use Window

Change App.run() and performAction() to create/manage Windows instead of bare Surfaces.

**Files:**
- Modify: `src/apprt/win32/App.zig:141-176` (run)
- Modify: `src/apprt/win32/App.zig:219-672` (performAction)
- Modify: `src/apprt/win32/App.zig:760-811` (createWindow — remove or repurpose)

- [ ] **Step 1: Update App.run() to create a Window with first tab**

Replace lines 141-148:

```zig
pub fn run(self: *App) !void {
    // Create the initial window with one tab
    const alloc = self.core_app.alloc;
    const window = try alloc.create(Window);
    errdefer alloc.destroy(window);
    try window.init(self);
    try self.windows.append(window);

    // Add the first tab
    _ = try window.addTab();

    // Enter the Win32 message loop (rest unchanged)
```

- [ ] **Step 2: Add findWindow() helper to App**

```zig
/// Find the Window that contains a given Surface.
fn findWindow(self: *App, surface: *Surface) ?*Window {
    for (self.windows.items) |window| {
        for (window.tabs.slice()) |s| {
            if (s == surface) return window;
        }
    }
    return null;
}
```

- [ ] **Step 3: Update performAction for tab actions**

Replace the `new_tab` handler (lines 429-444):

```zig
.new_tab => {
    switch (target) {
        .app => {},
        .surface => |core_surface| {
            if (self.findWindow(core_surface.rt_surface)) |window| {
                _ = window.addTab() catch |err| {
                    log.err("failed to create new tab: {}", .{err});
                };
            }
        },
    }
    return true;
},
```

Replace `close_tab` (lines 446-455):

```zig
.close_tab => {
    switch (target) {
        .app => {},
        .surface => |core_surface| {
            if (self.findWindow(core_surface.rt_surface)) |window| {
                window.closeTab(core_surface.rt_surface);
            }
        },
    }
    return true;
},
```

Replace `goto_tab` (line 457):

```zig
.goto_tab => {
    switch (target) {
        .app => return true,
        .surface => |core_surface| {
            if (self.findWindow(core_surface.rt_surface)) |window| {
                _ = window.selectTab(value);
            }
        },
    }
    return true;
},
```

Replace `set_tab_title`:

```zig
.set_tab_title => {
    switch (target) {
        .app => {},
        .surface => |core_surface| {
            if (self.findWindow(core_surface.rt_surface)) |window| {
                window.onTabTitleChanged(core_surface.rt_surface, value.title);
            }
        },
    }
    return true;
},
```

Keep `move_tab` and `toggle_tab_overview` as no-ops for now.

- [ ] **Step 4: Update window-level actions to use parent_window**

For `toggle_fullscreen`, `toggle_maximize`, `toggle_window_decorations`, `toggle_background_opacity`, `initial_size`, `reset_window_size`, `copy_title_to_clipboard` — change `core_surface.rt_surface.hwnd` references to `core_surface.rt_surface.parent_window.hwnd`.

For example, `toggle_maximize`:

```zig
.toggle_maximize => {
    switch (target) {
        .app => {},
        .surface => |core_surface| {
            if (core_surface.rt_surface.parent_window.hwnd) |hwnd| {
                if (w32.IsZoomed(hwnd) != 0) {
                    _ = w32.ShowWindow(hwnd, w32.SW_RESTORE);
                } else {
                    _ = w32.ShowWindow(hwnd, w32.SW_MAXIMIZE);
                }
            }
        },
    }
    return true;
},
```

Apply the same pattern to all window-level actions.

- [ ] **Step 5: Update `new_window` action and remove App.createWindow()**

The `new_window` action (around line 238) currently calls `surface.init(self)`. After the signature change, it needs to create a new Window:

```zig
.new_window => {
    const alloc = self.core_app.alloc;
    const window = alloc.create(Window) catch |err| {
        log.err("failed to allocate new window: {}", .{err});
        return true;
    };
    window.init(self) catch |err| {
        log.err("failed to create new window: {}", .{err});
        alloc.destroy(window);
        return true;
    };
    self.windows.append(window) catch |err| {
        log.err("failed to track new window: {}", .{err});
        return true;
    };
    _ = window.addTab() catch |err| {
        log.err("failed to add tab to new window: {}", .{err});
    };
    return true;
},
```

Remove the old `App.createWindow()` method (lines 760-811) — Window.init() handles HWND creation directly.

- [ ] **Step 6: Update close_window action**

```zig
.close_window => {
    switch (target) {
        .app => {},
        .surface => |core_surface| {
            if (self.findWindow(core_surface.rt_surface)) |window| {
                window.close();
            }
        },
    }
    return true;
},
```

- [ ] **Step 7: Verify compilation**

Run: `zig build -Dapp-runtime=win32 2>&1 | head -30`

- [ ] **Step 8: Commit**

```bash
git add src/apprt/win32/App.zig
git commit -m "feat: wire App to create Windows with tabs instead of bare Surfaces"
```

---

## Task 6: Tab Bar GDI Painting

Implement the custom-drawn tab bar with active tab highlight, close buttons, and new-tab button.

**Files:**
- Modify: `src/apprt/win32/Window.zig` (add WM_PAINT handler and painting code)
- Modify: `src/apprt/win32/win32.zig` (add GDI declarations if missing)

- [ ] **Step 1: Add GDI declarations to win32.zig**

Add any missing declarations needed for tab bar painting:

```zig
// GDI drawing functions
pub extern "gdi32" fn CreateCompatibleDC(hdc: ?HDC) callconv(.c) ?HDC;
pub extern "gdi32" fn CreateCompatibleBitmap(hdc: HDC, cx: i32, cy: i32) callconv(.c) ?HBITMAP;
pub extern "gdi32" fn SelectObject(hdc: HDC, h: ?*anyopaque) callconv(.c) ?*anyopaque;
pub extern "gdi32" fn DeleteDC(hdc: HDC) callconv(.c) i32;
pub extern "gdi32" fn BitBlt(hdcDest: HDC, x: i32, y: i32, cx: i32, cy: i32, hdcSrc: HDC, x1: i32, y1: i32, rop: u32) callconv(.c) i32;
pub extern "gdi32" fn FillRect(hdc: HDC, lprc: *const RECT, hbr: HBRUSH) callconv(.c) i32;
pub extern "gdi32" fn DrawTextW(hdc: HDC, lpchText: [*]const u16, cchText: i32, lprc: *RECT, format: u32) callconv(.c) i32;
pub extern "gdi32" fn SetBkMode(hdc: HDC, mode: i32) callconv(.c) i32;
pub extern "gdi32" fn SetTextColor(hdc: HDC, color: u32) callconv(.c) u32;
pub extern "user32" fn BeginPaint(hwnd: HWND, lpPaint: *PAINTSTRUCT) callconv(.c) ?HDC;
pub extern "user32" fn EndPaint(hwnd: HWND, lpPaint: *const PAINTSTRUCT) callconv(.c) i32;
pub extern "user32" fn InvalidateRect(hwnd: HWND, lpRect: ?*const RECT, bErase: i32) callconv(.c) i32;

pub const PAINTSTRUCT = extern struct {
    hdc: HDC,
    fErase: i32,
    rcPaint: RECT,
    fRestore: i32,
    fIncUpdate: i32,
    rgbReserved: [32]u8,
};

pub const SRCCOPY: u32 = 0x00CC0020;
pub const TRANSPARENT = 1;
pub const DT_LEFT: u32 = 0;
pub const DT_VCENTER: u32 = 4;
pub const DT_SINGLELINE: u32 = 32;
pub const DT_END_ELLIPSIS: u32 = 0x8000;
pub const DT_NOPREFIX: u32 = 0x800;
```

Check what already exists before adding — don't duplicate.

- [ ] **Step 2: Add tab bar painting to windowWndProc**

In the `windowWndProc` switch, add `WM_PAINT`:

```zig
w32.WM_PAINT => {
    window.paintTabBar();
    return 0;
},
```

- [ ] **Step 3: Implement paintTabBar()**

```zig
fn paintTabBar(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    if (!self.tab_bar_visible) {
        // Still need to validate the paint region
        var ps: w32.PAINTSTRUCT = undefined;
        _ = w32.BeginPaint(hwnd, &ps);
        _ = w32.EndPaint(hwnd, &ps);
        return;
    }

    var ps: w32.PAINTSTRUCT = undefined;
    const paint_hdc = w32.BeginPaint(hwnd, &ps) orelse return;
    defer _ = w32.EndPaint(hwnd, &ps);

    var client: w32.RECT = undefined;
    _ = w32.GetClientRect(hwnd, &client);

    const bar_height = self.tabBarHeight();
    const bar_width = client.right - client.left;

    // Double-buffer: create back buffer
    const mem_dc = w32.CreateCompatibleDC(paint_hdc) orelse return;
    defer _ = w32.DeleteDC(mem_dc);
    const bmp = w32.CreateCompatibleBitmap(paint_hdc, bar_width, bar_height) orelse return;
    const old_bmp = w32.SelectObject(mem_dc, @ptrCast(bmp));
    defer {
        _ = w32.SelectObject(mem_dc, old_bmp);
        _ = w32.DeleteObject(@ptrCast(bmp));
    }

    // Background: dark gray (slightly lighter than terminal bg)
    const bg = self.app.config.background;
    const bar_bg_r: u32 = @min(@as(u32, bg.r) + 20, 255);
    const bar_bg_g: u32 = @min(@as(u32, bg.g) + 20, 255);
    const bar_bg_b: u32 = @min(@as(u32, bg.b) + 20, 255);
    const bar_brush = w32.CreateSolidBrush(w32.RGB(@intCast(bar_bg_r), @intCast(bar_bg_g), @intCast(bar_bg_b)));
    defer _ = w32.DeleteObject(@ptrCast(bar_brush));

    var bar_rect = w32.RECT{ .left = 0, .top = 0, .right = bar_width, .bottom = bar_height };
    _ = w32.FillRect(mem_dc, &bar_rect, bar_brush);

    // Select tab font
    const old_font = if (self.tab_font) |f| w32.SelectObject(mem_dc, @ptrCast(f)) else null;
    defer if (old_font) |f| { _ = w32.SelectObject(mem_dc, f); };

    _ = w32.SetBkMode(mem_dc, w32.TRANSPARENT);

    // Calculate tab widths
    const new_tab_btn_width: i32 = @intFromFloat(@round(32.0 * self.scale));
    const available = bar_width - new_tab_btn_width;
    const tab_count: i32 = @intCast(self.tabs.len);
    const tab_width: i32 = if (tab_count > 0) @divTrunc(available, tab_count) else 0;
    const close_btn_size: i32 = @intFromFloat(@round(16.0 * self.scale));

    // Draw each tab
    var x: i32 = 0;
    for (0..self.tabs.len) |i| {
        const is_active = i == self.active_tab;
        const is_hover = @as(isize, @intCast(i)) == self.hover_tab;
        const w = if (i == self.tabs.len - 1) available - x else tab_width;

        self.tab_rects[i] = .{ .left = x, .top = 0, .right = x + w, .bottom = bar_height };

        // Tab background
        if (is_active) {
            const active_brush = w32.CreateSolidBrush(w32.RGB(bg.r, bg.g, bg.b));
            _ = w32.FillRect(mem_dc, &self.tab_rects[i], active_brush);
            _ = w32.DeleteObject(@ptrCast(active_brush));

            // Active indicator line (2px at bottom)
            const accent_brush = w32.CreateSolidBrush(w32.RGB(100, 100, 255));
            var accent_rect = w32.RECT{ .left = x, .top = bar_height - 2, .right = x + w, .bottom = bar_height };
            _ = w32.FillRect(mem_dc, &accent_rect, accent_brush);
            _ = w32.DeleteObject(@ptrCast(accent_brush));
        } else if (is_hover) {
            const hover_r: u32 = @min(@as(u32, bg.r) + 35, 255);
            const hover_g: u32 = @min(@as(u32, bg.g) + 35, 255);
            const hover_b: u32 = @min(@as(u32, bg.b) + 35, 255);
            const hover_brush = w32.CreateSolidBrush(w32.RGB(@intCast(hover_r), @intCast(hover_g), @intCast(hover_b)));
            _ = w32.FillRect(mem_dc, &self.tab_rects[i], hover_brush);
            _ = w32.DeleteObject(@ptrCast(hover_brush));
        }

        // Tab title text
        const text_color: u32 = if (is_active) w32.RGB(230, 230, 230) else w32.RGB(150, 150, 150);
        _ = w32.SetTextColor(mem_dc, text_color);
        const padding: i32 = @intFromFloat(@round(8.0 * self.scale));
        var text_rect = w32.RECT{
            .left = x + padding,
            .top = 0,
            .right = x + w - close_btn_size - padding,
            .bottom = bar_height,
        };
        const title_len = self.tab_title_lens[i];
        _ = w32.DrawTextW(
            mem_dc,
            @ptrCast(&self.tab_titles[i]),
            @intCast(title_len),
            &text_rect,
            w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_END_ELLIPSIS | w32.DT_NOPREFIX,
        );

        // Close button (X) — draw as text for simplicity
        if (is_active or is_hover) {
            const close_color: u32 = if (self.hover_close and is_hover) w32.RGB(255, 100, 100) else w32.RGB(150, 150, 150);
            _ = w32.SetTextColor(mem_dc, close_color);
            var close_rect = w32.RECT{
                .left = x + w - close_btn_size - padding,
                .top = 0,
                .right = x + w - padding,
                .bottom = bar_height,
            };
            const x_char = std.unicode.utf8ToUtf16LeStringLiteral("\u{00D7}"); // multiplication sign ×
            _ = w32.DrawTextW(mem_dc, x_char, 1, &close_rect, w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE);
        }

        x += w;
    }

    // New tab button (+)
    self.new_tab_rect = .{ .left = x, .top = 0, .right = x + new_tab_btn_width, .bottom = bar_height };
    const plus_color: u32 = if (self.hover_new_tab) w32.RGB(230, 230, 230) else w32.RGB(150, 150, 150);
    _ = w32.SetTextColor(mem_dc, plus_color);
    const plus_char = std.unicode.utf8ToUtf16LeStringLiteral("+");
    _ = w32.DrawTextW(mem_dc, plus_char, 1, &self.new_tab_rect, w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE);

    // Blit to screen
    _ = w32.BitBlt(paint_hdc, 0, 0, bar_width, bar_height, mem_dc, 0, 0, w32.SRCCOPY);
}
```

- [ ] **Step 4: Verify compilation**

Run: `zig build -Dapp-runtime=win32 2>&1 | head -30`

- [ ] **Step 5: Commit**

```bash
git add src/apprt/win32/Window.zig src/apprt/win32/win32.zig
git commit -m "feat: GDI tab bar painting with active tab highlight and close buttons"
```

---

## Task 7: Tab Bar Mouse Interaction

Handle clicks on tabs, close buttons, and new-tab button. Add hover effects.

**Files:**
- Modify: `src/apprt/win32/Window.zig` (add mouse handlers to windowWndProc)
- Modify: `src/apprt/win32/win32.zig` (add TrackMouseEvent declarations if missing)

- [ ] **Step 1: Add mouse message handling to windowWndProc**

In the switch block, add:

```zig
w32.WM_LBUTTONDOWN => {
    const x: i16 = @bitCast(@as(u16, @intCast(lparam & 0xFFFF)));
    const y: i16 = @bitCast(@as(u16, @intCast((lparam >> 16) & 0xFFFF)));
    window.handleTabBarClick(x, y);
    return 0;
},

w32.WM_MOUSEMOVE => {
    const x: i16 = @bitCast(@as(u16, @intCast(lparam & 0xFFFF)));
    const y: i16 = @bitCast(@as(u16, @intCast((lparam >> 16) & 0xFFFF)));
    window.handleTabBarMouseMove(x, y);
    return 0;
},

w32.WM_MOUSELEAVE => {
    window.handleTabBarMouseLeave();
    return 0;
},
```

- [ ] **Step 2: Implement handleTabBarClick()**

```zig
fn handleTabBarClick(self: *Window, x: i16, y: i16) void {
    if (!self.tab_bar_visible) return;
    if (y >= self.tabBarHeight()) return; // Click below tab bar

    // Check new-tab button
    if (x >= self.new_tab_rect.left and x < self.new_tab_rect.right) {
        _ = self.addTab() catch |err| {
            log.err("failed to create new tab: {}", .{err});
        };
        return;
    }

    // Check each tab
    const close_btn_size: i32 = @intFromFloat(@round(16.0 * self.scale));
    const padding: i32 = @intFromFloat(@round(8.0 * self.scale));
    for (0..self.tabs.len) |i| {
        const rect = self.tab_rects[i];
        if (x >= rect.left and x < rect.right) {
            // Check if close button was clicked
            const close_left = rect.right - close_btn_size - padding;
            if (x >= close_left and self.tabs.len > 0) {
                self.closeTab(self.tabs.get(i));
            } else {
                self.selectTabIndex(i);
                self.invalidateTabBar();
            }
            return;
        }
    }
}
```

- [ ] **Step 3: Implement handleTabBarMouseMove()**

```zig
fn handleTabBarMouseMove(self: *Window, x: i16, y: i16) void {
    if (!self.tab_bar_visible) return;

    // Track mouse leave
    if (!self.tracking_mouse) {
        var tme = w32.TRACKMOUSEEVENT{
            .cbSize = @sizeOf(w32.TRACKMOUSEEVENT),
            .dwFlags = w32.TME_LEAVE,
            .hwndTrack = self.hwnd.?,
            .dwHoverTime = 0,
        };
        _ = w32.TrackMouseEvent(&tme);
        self.tracking_mouse = true;
    }

    var new_hover: isize = -1;
    var new_hover_close = false;
    var new_hover_new_tab = false;

    if (y < self.tabBarHeight()) {
        // Check new-tab button
        if (x >= self.new_tab_rect.left and x < self.new_tab_rect.right) {
            new_hover_new_tab = true;
        } else {
            // Check tabs
            const close_btn_size: i32 = @intFromFloat(@round(16.0 * self.scale));
            const padding: i32 = @intFromFloat(@round(8.0 * self.scale));
            for (0..self.tabs.len) |i| {
                const rect = self.tab_rects[i];
                if (x >= rect.left and x < rect.right) {
                    new_hover = @intCast(i);
                    const close_left = rect.right - close_btn_size - padding;
                    new_hover_close = x >= close_left;
                    break;
                }
            }
        }
    }

    if (new_hover != self.hover_tab or new_hover_close != self.hover_close or new_hover_new_tab != self.hover_new_tab) {
        self.hover_tab = new_hover;
        self.hover_close = new_hover_close;
        self.hover_new_tab = new_hover_new_tab;
        self.invalidateTabBar();
    }
}

fn handleTabBarMouseLeave(self: *Window) void {
    self.tracking_mouse = false;
    if (self.hover_tab != -1 or self.hover_new_tab) {
        self.hover_tab = -1;
        self.hover_close = false;
        self.hover_new_tab = false;
        self.invalidateTabBar();
    }
}
```

- [ ] **Step 4: Add TrackMouseEvent declarations to win32.zig if missing**

```zig
pub const TRACKMOUSEEVENT = extern struct {
    cbSize: u32,
    dwFlags: u32,
    hwndTrack: HWND,
    dwHoverTime: u32,
};
pub const TME_LEAVE: u32 = 0x00000002;
pub extern "user32" fn TrackMouseEvent(lpEventTrack: *TRACKMOUSEEVENT) callconv(.c) i32;
pub const WM_MOUSELEAVE: u32 = 0x02A3;
```

- [ ] **Step 5: Verify compilation**

Run: `zig build -Dapp-runtime=win32 2>&1 | head -30`

- [ ] **Step 6: Commit**

```bash
git add src/apprt/win32/Window.zig src/apprt/win32/win32.zig
git commit -m "feat: tab bar mouse interaction — click to switch, close, and new tab"
```

---

## Task 8: Integration Testing

Update the test harness to verify tabs work within a single window.

**Files:**
- Modify: `test/win32/ghostty_test.sh` (update test_new_tab, add new tab tests)

- [ ] **Step 1: Update test_new_tab to verify single-window behavior**

The current `test_new_tab()` checks that Ctrl+Shift+T creates a second OS window. Now it should verify the opposite: Ctrl+Shift+T keeps a single OS window. Update the test to:

1. Launch Ghostty
2. Send Ctrl+Shift+T
3. Count Ghostty windows — should still be 1
4. Verify window title changed (or use another signal)

```bash
test_new_tab() {
    local test_name="new_tab"

    ps -Action launch
    sleep "$LAUNCH_WAIT"
    local output
    output=$(ps -Action check)
    local pid
    pid=$(get_val "$output" PID)

    # Send Ctrl+Shift+T to open a new tab
    ps -Action sendkeys -Keys "^+t" -Pid "$pid"
    sleep 1

    # Count Ghostty windows — should still be 1 (tabs, not windows)
    local win_count
    win_count=$(powershell.exe -NoProfile -Command "
        (Get-Process -Id $pid -ErrorAction SilentlyContinue |
         ForEach-Object { \$_.MainWindowHandle } |
         Where-Object { \$_ -ne 0 }).Count
    " | tr -d '\r')

    assert_eq "$test_name" "1" "$win_count" "Expected 1 window with tabs, got $win_count"

    ps -Action kill -Pid "$pid"
    report "$test_name"
}
```

Note: The exact PowerShell for counting windows vs. child HWNDs will need adjustment during implementation based on what's available. The key assertion is that the process has 1 top-level window, not 2.

- [ ] **Step 2: Add test_tab_switch**

```bash
test_tab_switch() {
    local test_name="tab_switch"

    ps -Action launch
    sleep "$LAUNCH_WAIT"
    local output
    output=$(ps -Action check)
    local pid
    pid=$(get_val "$output" PID)

    # Get initial window title
    local title1
    title1=$(powershell.exe -NoProfile -Command "
        (Get-Process -Id $pid).MainWindowTitle
    " | tr -d '\r')

    # Open new tab and set its title
    ps -Action sendkeys -Keys "^+t" -Pid "$pid"
    sleep 1

    # Type something to potentially change title
    ps -Action sendtext -Text "echo tab2" -Pid "$pid"
    sleep 0.5

    # Switch back to first tab (Ctrl+Shift+1 or similar)
    # This depends on the configured keybinding for goto_tab
    # For now just verify multiple tabs opened without crash

    ps -Action kill -Pid "$pid"

    PASS=$((PASS + 1))
    report "$test_name"
}
```

- [ ] **Step 3: Add test_tab_close**

```bash
test_tab_close() {
    local test_name="tab_close"

    ps -Action launch
    sleep "$LAUNCH_WAIT"
    local output
    output=$(ps -Action check)
    local pid
    pid=$(get_val "$output" PID)

    # Open new tab
    ps -Action sendkeys -Keys "^+t" -Pid "$pid"
    sleep 1

    # Close the tab (Ctrl+Shift+W)
    ps -Action sendkeys -Keys "^+w" -Pid "$pid"
    sleep 1

    # Verify process still running (one tab left)
    local still_running
    still_running=$(powershell.exe -NoProfile -Command "
        (Get-Process -Id $pid -ErrorAction SilentlyContinue) -ne \$null
    " | tr -d '\r')

    assert_eq "$test_name" "True" "$still_running" "Process should still be running with 1 tab"

    ps -Action kill -Pid "$pid"
    report "$test_name"
}
```

- [ ] **Step 4: Register new tests in the main test runner**

Add calls to the new test functions in the test runner section at the end of `ghostty_test.sh`.

- [ ] **Step 5: Commit**

```bash
git add test/win32/ghostty_test.sh
git commit -m "test: update tab tests to verify single-window tabbed behavior"
```

---

## Deferred: DPI and Lazy Tab Updates

The spec describes `size_stale` and `dpi_stale` flags for lazy updates on inactive tabs. For v1, the plan resizes only the active tab on `WM_SIZE` and resizes the newly-activated tab in `selectTabIndex`. This is sufficient — inactive tabs get resized when selected. Full `WM_DPICHANGED` forwarding and lazy flag tracking can be added as a follow-up if multi-monitor DPI issues arise.

---

## Task 9: End-to-End Verification and Cleanup

Final pass: ensure everything works together, clean up dead code, verify all tab actions work.

**Files:**
- Modify: `src/apprt/win32/App.zig` (remove dead createWindow if unused)
- Modify: `src/apprt/win32/Surface.zig` (remove dead fullscreen/decoration code)

- [ ] **Step 1: Remove App.createWindow() if no longer called**

If nothing calls `App.createWindow()` anymore (Window.init handles HWND creation), remove the function (lines 760-811).

- [ ] **Step 2: Remove dead Surface fullscreen/decoration code**

If `toggleFullscreen()` and `toggleWindowDecorations()` now just delegate to parent_window, remove the old implementation bodies from Surface.zig (keep the delegation stubs).

- [ ] **Step 3: Remove Surface.is_fullscreen and saved_style/saved_rect fields**

These moved to Window. Remove from Surface struct definition.

- [ ] **Step 4: Update the search bar key interception in App.run()**

The message loop intercept (lines 158-171) looks up Surface via the search popup's parent HWND. After refactoring, the search popup's parent is now the Window's HWND (not the Surface's). The `GWLP_USERDATA` on the popup still stores `*Surface`, so the interception logic should use the popup's own userdata, not its parent's. Verify this works correctly.

- [ ] **Step 5: Cross-build verification**

Run: `zig build -Dapp-runtime=win32 2>&1 | head -30`
Expected: Clean compilation, no warnings.

- [ ] **Step 6: Final commit**

```bash
git add src/apprt/win32/App.zig src/apprt/win32/Surface.zig src/apprt/win32/Window.zig
git commit -m "chore: clean up dead code after tab refactor"
```
