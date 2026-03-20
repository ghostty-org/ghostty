//! Win32 Window. Each Window is a top-level container HWND that owns
//! one or more Surface child HWNDs as tabs. The Window manages the tab
//! bar, tab switching, and window-level state (fullscreen, DPI scale).
const Window = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");

const App = @import("App.zig");
const Surface = @import("Surface.zig");
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32);

/// Maximum number of tabs per window.
const MAX_TABS: usize = 64;

/// The parent App.
app: *App,

/// The top-level window handle.
hwnd: ?w32.HWND = null,

/// Tab surfaces owned by this window (fixed-capacity inline array).
tab_count: usize = 0,
tab_surfaces: [64]*Surface = undefined,

/// Index of the currently active (visible) tab.
active_tab: usize = 0,

/// Whether the tab bar is visible (shown when >1 tab).
tab_bar_visible: bool = false,

/// DPI scale factor (DPI / 96.0).
scale: f32 = 1.0,

/// Hit-test rectangles for each tab in the tab bar.
tab_rects: [64]w32.RECT = undefined,

/// Hit-test rectangle for the "+" (new tab) button.
new_tab_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

/// Index of the tab currently being hovered (-1 = none).
hover_tab: isize = -1,

/// Whether the close button on the hovered tab is being hovered.
hover_close: bool = false,

/// Whether the "+" (new tab) button is being hovered.
hover_new_tab: bool = false,

/// UTF-16 title buffers for each tab (for painting the tab bar).
tab_titles: [64][256]u16 = undefined,

/// Length of each tab title in UTF-16 code units.
tab_title_lens: [64]u16 = undefined,

/// Whether the window is currently in fullscreen mode.
is_fullscreen: bool = false,

/// Saved window style for restoring from fullscreen.
saved_style: u32 = 0,

/// Saved window rect for restoring from fullscreen.
saved_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

/// Font used for painting the tab bar (Segoe UI).
tab_font: ?*anyopaque = null,

/// Whether WM_MOUSELEAVE tracking is active for the tab bar.
tracking_mouse: bool = false,

/// Initialize the Window by creating the top-level HWND and tab bar font.
pub fn init(self: *Window, app: *App) !void {
    self.* = .{
        .app = app,
    };

    // Create the top-level container window using the GhosttyWindow class.
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

    // Store the Window pointer in GWLP_USERDATA for the WndProc.
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    // Enable dark mode window chrome so the title bar matches the
    // terminal's dark background.
    const dark_mode: u32 = 1;
    _ = w32.DwmSetWindowAttribute(
        hwnd,
        w32.DWMWA_USE_IMMERSIVE_DARK_MODE,
        @ptrCast(&dark_mode),
        @sizeOf(u32),
    );

    // Apply dark theme to common controls (scrollbar, etc.).
    _ = w32.SetWindowTheme(
        hwnd,
        std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"),
        null,
    );

    // If background opacity is less than 1.0, make the window transparent.
    if (app.config.@"background-opacity" < 1.0) {
        const current_ex = w32.GetWindowLongW(hwnd, w32.GWL_EXSTYLE);
        _ = w32.SetWindowLongW(hwnd, w32.GWL_EXSTYLE, current_ex | w32.WS_EX_LAYERED);
        const alpha: u8 = @intFromFloat(@round(app.config.@"background-opacity" * 255.0));
        _ = w32.SetLayeredWindowAttributes(hwnd, 0, alpha, w32.LWA_ALPHA);
    }

    // Query DPI scale.
    const dpi = w32.GetDpiForWindow(hwnd);
    if (dpi != 0) {
        self.scale = @as(f32, @floatFromInt(dpi)) / 96.0;
    }

    // Create the tab bar font (Segoe UI, 12px at 96 DPI, scaled).
    const font_height: i32 = -@as(i32, @intFromFloat(16.0 * self.scale));
    self.tab_font = w32.CreateFontW(
        font_height, // cHeight (negative = character height)
        0, // cWidth
        0, // cEscapement
        0, // cOrientation
        w32.FW_NORMAL, // cWeight
        0, // bItalic
        0, // bUnderline
        0, // bStrikeOut
        w32.DEFAULT_CHARSET, // iCharSet
        0, // iOutPrecision
        0, // iClipPrecision
        0, // iQuality
        0, // iPitchAndFamily
        std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
    );

    _ = w32.ShowWindow(hwnd, w32.SW_SHOW);
    _ = w32.UpdateWindow(hwnd);
}

/// Deinitialize the Window: close all tabs, delete font, destroy HWND.
pub fn deinit(self: *Window) void {
    // Close all tab surfaces.
    const alloc = self.app.core_app.alloc;
    while (self.tab_count > 0) {
        self.tab_count -= 1;
        const surface = self.tab_surfaces[self.tab_count];
        surface.deinit();
        alloc.destroy(surface);
    }

    // Delete the tab bar font.
    if (self.tab_font) |font| {
        _ = w32.DeleteObject(font);
        self.tab_font = null;
    }

    // Clear GWLP_USERDATA before destroying to prevent stale pointer access.
    if (self.hwnd) |hwnd| {
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
        _ = w32.DestroyWindow(hwnd);
        self.hwnd = null;
    }
}

/// Returns the tab bar height in pixels, accounting for DPI scale.
/// Returns 0 if the tab bar is not visible.
pub fn tabBarHeight(self: *const Window) i32 {
    if (!self.tab_bar_visible) return 0;
    return @intFromFloat(@round(32.0 * self.scale));
}

/// Returns the client rect available for the active surface, which is
/// the full client area minus the tab bar height from the top.
pub fn surfaceRect(self: *const Window) w32.RECT {
    const hwnd = self.hwnd orelse return .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    var rect: w32.RECT = undefined;
    if (w32.GetClientRect(hwnd, &rect) == 0) {
        return .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    }
    rect.top += self.tabBarHeight();
    return rect;
}

/// Returns the currently active Surface, or null if there are no tabs.
pub fn getActiveSurface(self: *Window) ?*Surface {
    if (self.tab_count == 0) return null;
    return self.tab_surfaces[self.active_tab];
}

/// Add a new tab surface to this window. The surface is created,
/// initialized, and inserted at the position dictated by config.
pub fn addTab(self: *Window) !*Surface {
    if (self.tab_count >= MAX_TABS) return error.TooManyTabs;

    const alloc = self.app.core_app.alloc;
    const surface = try alloc.create(Surface);
    errdefer alloc.destroy(surface);
    try surface.init(self.app, self);

    // Determine insert position based on config.
    const pos: usize = switch (self.app.config.@"window-new-tab-position") {
        .current => if (self.tab_count > 0) self.active_tab + 1 else 0,
        .end => self.tab_count,
    };

    // Shift elements right to make room at pos.
    var i: usize = self.tab_count;
    while (i > pos) : (i -= 1) {
        self.tab_surfaces[i] = self.tab_surfaces[i - 1];
        self.tab_titles[i] = self.tab_titles[i - 1];
        self.tab_title_lens[i] = self.tab_title_lens[i - 1];
    }
    self.tab_surfaces[pos] = surface;
    self.tab_count += 1;

    // Set default title.
    const default_title = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");
    @memcpy(self.tab_titles[pos][0..default_title.len], default_title);
    self.tab_title_lens[pos] = @intCast(default_title.len);

    self.selectTabIndex(pos);
    self.updateTabBarVisibility();
    return surface;
}

/// Close a tab by surface pointer. Removes from the tab list,
/// deinits the surface, and adjusts the active tab index.
pub fn closeTab(self: *Window, surface: *Surface) void {
    // Find tab index.
    var tab_idx: ?usize = null;
    for (self.tab_surfaces[0..self.tab_count], 0..) |s, i| {
        if (s == surface) {
            tab_idx = i;
            break;
        }
    }
    const idx = tab_idx orelse return;

    // Hide and destroy.
    if (surface.hwnd) |h| _ = w32.ShowWindow(h, w32.SW_HIDE);
    surface.deinit();
    self.app.core_app.alloc.destroy(surface);

    // Shift left to fill gap.
    var i: usize = idx;
    while (i + 1 < self.tab_count) : (i += 1) {
        self.tab_surfaces[i] = self.tab_surfaces[i + 1];
        self.tab_titles[i] = self.tab_titles[i + 1];
        self.tab_title_lens[i] = self.tab_title_lens[i + 1];
    }
    self.tab_count -= 1;

    if (self.tab_count == 0) {
        if (self.hwnd) |hwnd| _ = w32.DestroyWindow(hwnd);
        return;
    }

    // Adjust active tab.
    if (self.active_tab >= self.tab_count) {
        self.active_tab = self.tab_count - 1;
    } else if (self.active_tab > idx) {
        self.active_tab -= 1;
    }
    self.selectTabIndex(self.active_tab);
    self.updateTabBarVisibility();
}

/// Switch to the tab at the given index.
pub fn selectTabIndex(self: *Window, idx: usize) void {
    if (idx >= self.tab_count) return;

    // Hide current tab.
    if (self.active_tab < self.tab_count) {
        if (self.tab_surfaces[self.active_tab].hwnd) |h| {
            _ = w32.ShowWindow(h, w32.SW_HIDE);
        }
    }

    self.active_tab = idx;
    const surface = self.tab_surfaces[idx];

    // Resize and show the new active tab.
    const sr = self.surfaceRect();
    if (surface.hwnd) |h| {
        _ = w32.MoveWindow(h, sr.left, sr.top, @intCast(@max(sr.right - sr.left, 1)), @intCast(@max(sr.bottom - sr.top, 1)), 1);
        _ = w32.ShowWindow(h, w32.SW_SHOW);
        _ = w32.SetFocus(h);
    }
    self.updateWindowTitle();
}

/// Navigate to a tab by GotoTab target (previous, next, last, or index).
pub fn selectTab(self: *Window, target: apprt.action.GotoTab) bool {
    if (self.tab_count <= 1) return false;
    const idx: usize = switch (target) {
        .previous => if (self.active_tab > 0) self.active_tab - 1 else self.tab_count - 1,
        .next => if (self.active_tab + 1 < self.tab_count) self.active_tab + 1 else 0,
        .last => self.tab_count - 1,
        _ => blk: {
            const n: usize = @intCast(@intFromEnum(target));
            break :blk if (n < self.tab_count) n else return false;
        },
    };
    self.selectTabIndex(idx);
    self.invalidateTabBar();
    return true;
}

/// Update the top-level window title to match the active tab's title.
fn updateWindowTitle(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    if (self.tab_count == 0) return;
    const len = self.tab_title_lens[self.active_tab];
    var buf: [257]u16 = undefined;
    @memcpy(buf[0..len], self.tab_titles[self.active_tab][0..len]);
    buf[len] = 0;
    _ = w32.SetWindowTextW(hwnd, @ptrCast(&buf));
}

/// Called when a tab's title changes. Updates the stored title
/// and refreshes the window title bar / tab bar if needed.
pub fn onTabTitleChanged(self: *Window, surface: *Surface, title: [:0]const u8) void {
    for (self.tab_surfaces[0..self.tab_count], 0..) |s, i| {
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

/// Update tab bar visibility based on config and tab count.
fn updateTabBarVisibility(self: *Window) void {
    const show_config = self.app.config.@"window-show-tab-bar";
    const should_show = switch (show_config) {
        .always => true,
        .auto => self.tab_count > 1,
        .never => false,
    };
    if (should_show != self.tab_bar_visible) {
        self.tab_bar_visible = should_show;
        self.handleResize();
    }
}

/// Invalidate the tab bar region so it gets repainted.
pub fn invalidateTabBar(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    var rect = w32.RECT{
        .left = 0,
        .top = 0,
        .right = 10000,
        .bottom = self.tabBarHeight(),
    };
    _ = w32.InvalidateRect(hwnd, &rect, 0);
}

/// Toggle fullscreen mode on the top-level window.
/// Saves/restores window style and placement.
pub fn toggleFullscreen(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    if (!self.is_fullscreen) {
        self.saved_style = w32.GetWindowLongW(hwnd, w32.GWL_STYLE);
        _ = w32.GetWindowRect(hwnd, &self.saved_rect);
        _ = w32.SetWindowLongW(hwnd, w32.GWL_STYLE, w32.WS_POPUP | w32.WS_VISIBLE_STYLE);
        const monitor = w32.MonitorFromWindow(hwnd, w32.MONITOR_DEFAULTTONEAREST);
        var mi: w32.MONITORINFO = undefined;
        mi.cbSize = @sizeOf(w32.MONITORINFO);
        if (w32.GetMonitorInfoW(monitor, &mi) != 0) {
            _ = w32.SetWindowPos(hwnd, null,
                mi.rcMonitor.left, mi.rcMonitor.top,
                mi.rcMonitor.right - mi.rcMonitor.left,
                mi.rcMonitor.bottom - mi.rcMonitor.top,
                w32.SWP_NOZORDER | w32.SWP_FRAMECHANGED);
        }
    } else {
        _ = w32.SetWindowLongW(hwnd, w32.GWL_STYLE, self.saved_style);
        _ = w32.SetWindowPos(hwnd, null,
            self.saved_rect.left, self.saved_rect.top,
            self.saved_rect.right - self.saved_rect.left,
            self.saved_rect.bottom - self.saved_rect.top,
            w32.SWP_NOZORDER | w32.SWP_FRAMECHANGED);
    }
    self.is_fullscreen = !self.is_fullscreen;
}

/// Toggle window decorations (title bar + borders) on/off.
pub fn toggleWindowDecorations(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    const style = w32.GetWindowLongW(hwnd, w32.GWL_STYLE);
    const has_decorations = (style & w32.WS_CAPTION) != 0;

    if (has_decorations) {
        // Remove decorations: strip caption and thick frame.
        const new_style = style & ~@as(u32, w32.WS_CAPTION | w32.WS_THICKFRAME);
        _ = w32.SetWindowLongW(hwnd, w32.GWL_STYLE, new_style);
    } else {
        // Restore decorations.
        const new_style = style | w32.WS_CAPTION | w32.WS_THICKFRAME;
        _ = w32.SetWindowLongW(hwnd, w32.GWL_STYLE, new_style);
    }
    // Force frame recalculation.
    _ = w32.SetWindowPos(hwnd, null, 0, 0, 0, 0,
        w32.SWP_NOZORDER | w32.SWP_FRAMECHANGED | w32.SWP_NOMOVE | w32.SWP_NOSIZE);
}

/// Handle WM_SIZE: resize the active surface's child HWND to fill
/// the available client area (below the tab bar).
fn handleResize(self: *Window) void {
    const rect = self.surfaceRect();
    if (self.getActiveSurface()) |surface| {
        if (surface.hwnd) |h| {
            _ = w32.MoveWindow(
                h,
                rect.left,
                rect.top,
                @intCast(rect.right - rect.left),
                @intCast(rect.bottom - rect.top),
                1,
            );
        }
    }
}

/// Handle WM_CLOSE: destroy the window.
fn close(self: *Window) void {
    if (self.hwnd) |hwnd| {
        _ = w32.DestroyWindow(hwnd);
    }
}

/// Handle WM_DESTROY: remove this window from the App's list,
/// clean up, and start the quit timer if no windows remain.
fn onDestroy(self: *Window) void {
    // Remove from App's window list.
    const items = self.app.windows.items;
    for (items, 0..) |w, i| {
        if (w == self) {
            _ = self.app.windows.orderedRemove(i);
            break;
        }
    }
    self.hwnd = null;
    self.deinit();
    self.app.core_app.alloc.destroy(self);

    // If no windows remain, start the quit timer.
    if (self.app.windows.items.len == 0) {
        self.app.startQuitTimer();
    }
}

/// Window procedure for top-level container HWNDs (GhosttyWindow class).
/// GWLP_USERDATA stores a *Window pointer.
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
        w32.WM_ERASEBKGND => return 1,
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
