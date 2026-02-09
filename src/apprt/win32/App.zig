/// This is the main entrypoint to the apprt for Ghostty on Windows.
/// Ghostty will initialize this in main to start the application.
const App = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const configpkg = @import("../../config.zig");
const renderer = @import("../../renderer.zig");
const terminal = @import("../../terminal/main.zig");
const apprt = @import("../../apprt.zig");
const CoreApp = @import("../../App.zig");
const CoreSurface = @import("../../Surface.zig");
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");
const TabBar = @import("TabBar.zig");
const SearchBar = @import("SearchBar.zig");
const WinUI = @import("WinUI.zig");
const c = @import("c.zig");

const log = std.log.scoped(.win32);

const HINSTANCE = c.HINSTANCE;
const HWND = c.HWND;
const MSG = c.MSG;
const UINT = u32;
const WPARAM = c.WPARAM;
const LPARAM = c.LPARAM;
const LRESULT = c.LRESULT;

/// Module-level state for the title prompt dialog. The dialog wndProc sets
/// this to signal the modal loop to exit. `true` = OK, `false` = Cancel/Close.
var dialog_result: ?bool = null;

/// Window procedure for the "GhosttyDialog" class used by showTitlePrompt.
/// Handles WM_COMMAND from buttons and WM_CLOSE to set dialog_result.
fn dialogWndProc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) callconv(c.WINAPI) LRESULT {
    switch (msg) {
        c.WM_COMMAND => {
            const id = c.LOWORD(wparam);
            const code: u16 = @truncate((@as(usize, @bitCast(wparam)) >> 16) & 0xFFFF);
            if (code == c.BN_CLICKED) {
                if (id == 1) { // OK
                    dialog_result = true;
                    return 0;
                } else if (id == 2) { // Cancel
                    dialog_result = false;
                    return 0;
                }
            }
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        c.WM_CLOSE => {
            dialog_result = false;
            return 0;
        },
        else => return c.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

/// Win32 application ID (for single instance detection)
pub const application_id = switch (builtin.mode) {
    .Debug, .ReleaseSafe => "ghostty-debug",
    .ReleaseFast, .ReleaseSmall => "ghostty",
};

/// HINSTANCE for the application
hinstance: HINSTANCE,

/// Core Ghostty app
core_app: *CoreApp,

/// Application config
config: configpkg.Config,

/// Running state for event loop
running: bool = false,

/// Main window (first window created)
main_window: ?*Window = null,

/// All open windows
windows: std.ArrayListUnmanaged(*Window) = .{},

/// Whether we have added a notification tray icon
notify_icon_added: bool = false,

/// Whether all windows are currently visible
visible: bool = true,

/// WinUI 3 runtime loader (DLL loaded on demand)
winui: WinUI = .{},

pub fn init(
    self: *App,
    core_app: *CoreApp,
    opts: struct {},
) !void {
    _ = opts;

    const alloc = core_app.alloc;
    const hinstance: HINSTANCE = c.GetModuleHandleW(null) orelse return error.GetModuleHandleFailed;

    // Load configuration
    var config = configpkg.Config.load(alloc) catch |err| err: {
        log.warn("error loading config: {}, using defaults", .{err});
        break :err try configpkg.Config.default(alloc);
    };
    errdefer config.deinit();

    self.* = .{
        .hinstance = hinstance,
        .core_app = core_app,
        .config = config,
    };

    // Set system timer resolution to 1ms.
    _ = c.timeBeginPeriod(1);

    // Set DPI awareness (non-fatal)
    setDpiAwarenessContext();

    // Register window classes
    try registerWindowClass(hinstance);
    try registerSurfaceClass(hinstance);
    try registerTabBarClass(hinstance);
    try registerSearchBarClass(hinstance);
    try registerDialogClass(hinstance);
    try registerDragOverlayClass(hinstance);

    // Attempt to load the WinUI 3 shim DLL (non-fatal).
    self.winui.load();
    if (self.winui.isAvailable()) {
        log.info("WinUI 3 controls available", .{});
    } else {
        log.info("WinUI 3 not available, using GDI controls", .{});
    }

    log.info("Win32 application initialized", .{});
}

pub fn run(self: *App) !void {
    self.running = true;
    log.info("Starting Win32 message loop", .{});

    // Request the initial window from the core app.
    _ = self.core_app.mailbox.push(.{
        .new_window = .{},
    }, .{ .forever = {} });

    // Create a high-resolution waitable timer for precise loop timing.
    const timer_handle = c.CreateWaitableTimerExW(
        null,
        null,
        c.CREATE_WAITABLE_TIMER_HIGH_RESOLUTION,
        c.TIMER_ALL_ACCESS,
    );
    defer {
        if (timer_handle) |h| _ = c.CloseHandle(h);
    }

    if (timer_handle != null) {
        log.info("Using high-resolution waitable timer for main loop", .{});
    } else {
        log.warn("High-resolution timer unavailable, main loop may have ~15ms granularity", .{});
    }

    var msg: MSG = undefined;
    const inputmod = @import("input.zig");

    // Main message loop
    while (self.running) {
        // Process all available Windows messages without blocking
        while (c.PeekMessageW(&msg, null, 0, 0, c.PM_REMOVE) != 0) {
            if (msg.message == c.WM_QUIT) {
                self.running = false;
                break;
            }
            // Let WinUI XAML process the message first.
            if (self.winui.winui_pre_translate_message) |ptm| {
                if (ptm(&msg) != 0) continue;
            }
            _ = c.TranslateMessage(&msg);
            _ = c.DispatchMessageW(&msg);
        }

        // Flush any pending key events from the last message batch.
        for (self.windows.items) |w| {
            for (w.tabs.items) |*tab| {
                var it = tab.tree.iterator();
                while (it.next()) |entry| {
                    inputmod.flushPendingKey(entry.view) catch {};
                }
            }
        }

        if (!self.running) break;

        // Tick the core app
        try self.core_app.tick(self);

        // Wait for new messages or the high-resolution timer.
        if (timer_handle) |h| {
            var due_time: i64 = -10000;
            _ = c.SetWaitableTimer(h, &due_time, 0, null, null, 0);
            const handles = [_]c.HANDLE{h};
            _ = c.MsgWaitForMultipleObjects(1, &handles, 0, c.INFINITE, c.QS_ALLINPUT);
        } else {
            _ = c.MsgWaitForMultipleObjects(0, null, 0, 1, c.QS_ALLINPUT);
        }
    }

    log.info("Win32 message loop exited", .{});
}

pub fn terminate(self: *App) void {
    log.info("Terminating Win32 application", .{});

    // Remove notification tray icon if we added one
    if (self.notify_icon_added) {
        var nid: c.NOTIFYICONDATAW = std.mem.zeroes(c.NOTIFYICONDATAW);
        nid.cbSize = @sizeOf(c.NOTIFYICONDATAW);
        nid.hWnd = if (self.main_window) |w| w.hwnd else null;
        nid.uID = 1;
        _ = c.Shell_NotifyIconW(c.NIM_DELETE, &nid);
        self.notify_icon_added = false;
    }

    // Unload WinUI DLL before tearing down windows.
    self.winui.unload();

    _ = c.timeEndPeriod(1);
    self.windows.deinit(self.core_app.alloc);
    self.config.deinit();
    self.running = false;
}

pub fn wakeup(self: *App) void {
    if (self.main_window) |window| {
        _ = c.PostMessageW(window.hwnd, c.WM_NULL, 0, 0);
    }
}

pub fn performAction(
    self: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    switch (action) {
        .quit => {
            log.info("Quit action received", .{});
            self.terminate();
            return true;
        },

        .new_window => {
            const parent: ?*CoreSurface = switch (target) {
                .surface => |s| s,
                .app => null,
            };
            try self.newWindow(parent);
            return true;
        },

        .set_title => {
            // Store per-surface title for tab display.
            if (self.surfaceFromTarget(target)) |surface| {
                surface.setTitle(value.title);
            }
            // Also set window-level title (shown in taskbar/titlebar).
            const window = self.windowFromTarget(target) orelse return false;
            window.setTitle(value.title);
            return true;
        },

        .render => {
            const surface = self.surfaceFromTarget(target) orelse return false;
            _ = c.InvalidateRect(surface.hwnd, null, 0);
            return true;
        },

        .mouse_shape => {
            const surface = self.surfaceFromTarget(target) orelse return false;
            surface.current_cursor = Surface.mouseShapeToCursor(value);
            _ = c.PostMessageW(surface.hwnd, c.WM_SETCURSOR, 0, @bitCast(@as(isize, c.HTCLIENT)));
            return true;
        },

        .mouse_visibility => {
            const surface = self.surfaceFromTarget(target) orelse return false;
            surface.mouse_hidden = (value == .hidden);
            _ = c.PostMessageW(surface.hwnd, c.WM_SETCURSOR, 0, @bitCast(@as(isize, c.HTCLIENT)));
            return true;
        },

        .close_window => {
            const window = self.windowFromTarget(target) orelse return false;
            _ = c.PostMessageW(window.hwnd, c.WM_CLOSE, 0, 0);
            return true;
        },

        .close_all_windows => {
            for (self.windows.items) |window| {
                _ = c.PostMessageW(window.hwnd, c.WM_CLOSE, 0, 0);
            }
            return true;
        },

        .ring_bell => {
            _ = c.MessageBeep(0xFFFFFFFF);
            return true;
        },

        .cell_size => {
            const window = self.windowFromTarget(target) orelse return false;
            window.cell_width = value.width;
            window.cell_height = value.height;
            return true;
        },

        .pwd => {
            return true;
        },

        .color_change => {
            const surface = self.surfaceFromTarget(target) orelse return false;
            _ = c.InvalidateRect(surface.hwnd, null, 0);
            return true;
        },

        .renderer_health => {
            log.info("Renderer health: {s}", .{@tagName(value)});
            return true;
        },

        .config_change => {
            return true;
        },

        .command_finished => {
            return true;
        },

        .initial_size => {
            const window = self.windowFromTarget(target) orelse return false;
            window.initial_width = value.width;
            window.initial_height = value.height;

            // Resize the window to match
            var rect = c.RECT{
                .left = 0,
                .top = 0,
                .right = @intCast(value.width),
                .bottom = @intCast(value.height),
            };
            const style: c.DWORD = @bitCast(@as(u32, @truncate(@as(usize, @bitCast(c.GetWindowLongPtrW(window.hwnd, c.GWL_STYLE))))));
            const ex_style: c.DWORD = @bitCast(@as(u32, @truncate(@as(usize, @bitCast(c.GetWindowLongPtrW(window.hwnd, c.GWL_EXSTYLE))))));
            _ = c.AdjustWindowRectEx(&rect, style, 0, ex_style);
            _ = c.SetWindowPos(
                window.hwnd,
                null,
                0,
                0,
                rect.right - rect.left,
                rect.bottom - rect.top,
                c.SWP_NOMOVE | c.SWP_NOZORDER,
            );
            return true;
        },

        .size_limit => {
            const window = self.windowFromTarget(target) orelse return false;
            window.min_width = if (value.min_width > 0) @intCast(value.min_width) else 0;
            window.min_height = if (value.min_height > 0) @intCast(value.min_height) else 0;
            window.max_width = if (value.max_width > 0) @intCast(value.max_width) else 0;
            window.max_height = if (value.max_height > 0) @intCast(value.max_height) else 0;
            return true;
        },

        .reset_window_size => {
            const window = self.windowFromTarget(target) orelse return false;
            if (window.initial_width > 0 and window.initial_height > 0) {
                var rect = c.RECT{
                    .left = 0,
                    .top = 0,
                    .right = @intCast(window.initial_width),
                    .bottom = @intCast(window.initial_height),
                };
                const style: c.DWORD = @bitCast(@as(u32, @truncate(@as(usize, @bitCast(c.GetWindowLongPtrW(window.hwnd, c.GWL_STYLE))))));
                const ex_style: c.DWORD = @bitCast(@as(u32, @truncate(@as(usize, @bitCast(c.GetWindowLongPtrW(window.hwnd, c.GWL_EXSTYLE))))));
                _ = c.AdjustWindowRectEx(&rect, style, 0, ex_style);
                _ = c.SetWindowPos(
                    window.hwnd,
                    null,
                    0,
                    0,
                    rect.right - rect.left,
                    rect.bottom - rect.top,
                    c.SWP_NOMOVE | c.SWP_NOZORDER,
                );
            }
            return true;
        },

        .open_url => {
            const url = value.url;
            if (url.len == 0) return false;

            const alloc = self.core_app.alloc;

            // Copy URL to local buffer first in case the source is freed
            // before ShellExecuteW processes it (the core may reuse the buffer).
            const url_copy = alloc.dupeZ(u8, url) catch return false;
            defer alloc.free(url_copy);

            const wide = std.unicode.utf8ToUtf16LeAlloc(alloc, url_copy) catch return false;
            defer alloc.free(wide);

            const wide_z = alloc.allocSentinel(u16, wide.len, 0) catch return false;
            defer alloc.free(wide_z);
            @memcpy(wide_z[0..wide.len], wide);

            const open_str = std.unicode.utf8ToUtf16LeStringLiteral("open");
            const hwnd_val = if (self.main_window) |w| w.hwnd else null;
            _ = c.ShellExecuteW(hwnd_val, open_str, wide_z, null, null, c.SW_SHOWNORMAL);
            return true;
        },

        .open_config => {
            const alloc = self.core_app.alloc;
            const config_edit = @import("../../config/edit.zig");
            const path = config_edit.openPath(alloc) catch |err| {
                log.warn("Failed to get config path: {}", .{err});
                return false;
            };
            defer alloc.free(path);

            const wide = std.unicode.utf8ToUtf16LeAlloc(alloc, path) catch return false;
            defer alloc.free(wide);
            const wide_z = alloc.allocSentinel(u16, wide.len, 0) catch return false;
            defer alloc.free(wide_z);
            @memcpy(wide_z[0..wide.len], wide);

            const open_str = std.unicode.utf8ToUtf16LeStringLiteral("open");
            _ = c.ShellExecuteW(null, open_str, wide_z, null, null, c.SW_SHOWNORMAL);
            return true;
        },

        .reload_config => {
            if (value.soft) {
                self.core_app.updateConfig(self, &self.config) catch |err| {
                    log.warn("Failed to soft-reload config: {}", .{err});
                    return false;
                };
            } else {
                const alloc = self.core_app.alloc;
                var new_config = configpkg.Config.load(alloc) catch |err| {
                    log.warn("Failed to reload config: {}", .{err});
                    return false;
                };
                self.core_app.updateConfig(self, &new_config) catch |err| {
                    log.warn("Failed to apply config: {}", .{err});
                    new_config.deinit();
                    return false;
                };
                self.config.deinit();
                self.config = new_config;
            }
            return true;
        },

        .quit_timer => {
            if (self.main_window) |window| {
                switch (value) {
                    .start => _ = c.SetTimer(window.hwnd, Window.QUIT_TIMER_ID, 1000, null),
                    .stop => _ = c.KillTimer(window.hwnd, Window.QUIT_TIMER_ID),
                }
            }
            return true;
        },

        .toggle_fullscreen => {
            const window = self.windowFromTarget(target) orelse return false;
            if (window.is_fullscreen) {
                // Exit fullscreen: restore style and placement.
                _ = c.SetWindowLongPtrW(window.hwnd, c.GWL_STYLE, window.saved_style);
                _ = c.SetWindowPlacement(window.hwnd, &window.saved_placement);
                _ = c.SetWindowPos(
                    window.hwnd,
                    null,
                    0,
                    0,
                    0,
                    0,
                    c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_NOOWNERZORDER | c.SWP_FRAMECHANGED,
                );
                window.is_fullscreen = false;
                window.extendFrameIntoClientArea();
            } else {
                // Enter fullscreen: save state and go borderless fullscreen.
                window.saved_style = c.GetWindowLongPtrW(window.hwnd, c.GWL_STYLE);
                window.saved_placement.length = @sizeOf(c.WINDOWPLACEMENT);
                _ = c.GetWindowPlacement(window.hwnd, &window.saved_placement);

                const new_style = window.saved_style & ~@as(isize, @bitCast(@as(usize, c.WS_CAPTION | c.WS_THICKFRAME)));
                _ = c.SetWindowLongPtrW(window.hwnd, c.GWL_STYLE, new_style);

                const monitor = c.MonitorFromWindow(window.hwnd, c.MONITOR_DEFAULTTONEAREST);
                if (monitor) |mon| {
                    var mi = c.MONITORINFO{
                        .cbSize = @sizeOf(c.MONITORINFO),
                        .rcMonitor = undefined,
                        .rcWork = undefined,
                        .dwFlags = 0,
                    };
                    if (c.GetMonitorInfoW(mon, &mi) != 0) {
                        _ = c.SetWindowPos(
                            window.hwnd,
                            null,
                            mi.rcMonitor.left,
                            mi.rcMonitor.top,
                            mi.rcMonitor.right - mi.rcMonitor.left,
                            mi.rcMonitor.bottom - mi.rcMonitor.top,
                            c.SWP_NOZORDER | c.SWP_NOOWNERZORDER | c.SWP_FRAMECHANGED,
                        );
                    }
                }
                window.is_fullscreen = true;
            }
            return true;
        },

        .toggle_maximize => {
            const window = self.windowFromTarget(target) orelse return false;
            if (c.IsZoomed(window.hwnd) != 0) {
                _ = c.ShowWindow(window.hwnd, c.SW_RESTORE);
            } else {
                _ = c.ShowWindow(window.hwnd, c.SW_MAXIMIZE);
            }
            return true;
        },

        .toggle_window_decorations => {
            const window = self.windowFromTarget(target) orelse return false;
            const style = c.GetWindowLongPtrW(window.hwnd, c.GWL_STYLE);
            const has_caption = (style & @as(isize, @bitCast(@as(usize, c.WS_CAPTION)))) != 0;
            const new_style = if (has_caption)
                style & ~@as(isize, @bitCast(@as(usize, c.WS_CAPTION | c.WS_THICKFRAME)))
            else
                style | @as(isize, @bitCast(@as(usize, c.WS_CAPTION | c.WS_THICKFRAME)));
            _ = c.SetWindowLongPtrW(window.hwnd, c.GWL_STYLE, new_style);
            _ = c.SetWindowPos(
                window.hwnd,
                null,
                0,
                0,
                0,
                0,
                c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_FRAMECHANGED,
            );
            return true;
        },

        .float_window => {
            const window = self.windowFromTarget(target) orelse return false;
            switch (value) {
                .on => _ = c.SetWindowPos(window.hwnd, c.HWND_TOPMOST, 0, 0, 0, 0, c.SWP_NOMOVE | c.SWP_NOSIZE),
                .off => _ = c.SetWindowPos(window.hwnd, c.HWND_NOTOPMOST, 0, 0, 0, 0, c.SWP_NOMOVE | c.SWP_NOSIZE),
                .toggle => {
                    const ex_style = c.GetWindowLongPtrW(window.hwnd, c.GWL_EXSTYLE);
                    const is_topmost = (ex_style & @as(isize, @bitCast(@as(usize, c.WS_EX_TOPMOST)))) != 0;
                    if (is_topmost) {
                        _ = c.SetWindowPos(window.hwnd, c.HWND_NOTOPMOST, 0, 0, 0, 0, c.SWP_NOMOVE | c.SWP_NOSIZE);
                    } else {
                        _ = c.SetWindowPos(window.hwnd, c.HWND_TOPMOST, 0, 0, 0, 0, c.SWP_NOMOVE | c.SWP_NOSIZE);
                    }
                },
            }
            return true;
        },

        .toggle_background_opacity => {
            const window = self.windowFromTarget(target) orelse return false;
            const ex_style = c.GetWindowLongPtrW(window.hwnd, c.GWL_EXSTYLE);
            const is_layered = (ex_style & @as(isize, @bitCast(@as(usize, c.WS_EX_LAYERED)))) != 0;
            if (is_layered) {
                _ = c.SetWindowLongPtrW(window.hwnd, c.GWL_EXSTYLE, ex_style & ~@as(isize, @bitCast(@as(usize, c.WS_EX_LAYERED))));
            } else {
                _ = c.SetWindowLongPtrW(window.hwnd, c.GWL_EXSTYLE, ex_style | @as(isize, @bitCast(@as(usize, c.WS_EX_LAYERED))));
                _ = c.SetLayeredWindowAttributes(window.hwnd, 0, 200, c.LWA_ALPHA);
            }
            _ = c.InvalidateRect(window.hwnd, null, 0);
            return true;
        },

        .new_split => {
            const window = self.windowFromTarget(target) orelse return false;
            const direction: Window.SurfaceSplitTree.Split.Direction = switch (value) {
                .right => .right,
                .left => .left,
                .up => .up,
                .down => .down,
            };
            window.activeTab().newSplit(window, direction) catch |err| {
                log.warn("Failed to create split: {}", .{err});
                return false;
            };
            return true;
        },

        .goto_split => {
            const window = self.windowFromTarget(target) orelse return false;
            const goto_target: Window.SurfaceSplitTree.Goto = switch (value) {
                .previous => .previous,
                .next => .next,
                .up => .{ .spatial = .up },
                .left => .{ .spatial = .left },
                .down => .{ .spatial = .down },
                .right => .{ .spatial = .right },
            };
            window.activeTab().gotoSplit(window, goto_target) catch |err| {
                log.warn("Failed to goto split: {}", .{err});
                return false;
            };
            return true;
        },

        .resize_split => {
            const window = self.windowFromTarget(target) orelse return false;
            const layout: Window.SurfaceSplitTree.Split.Layout = switch (value.direction) {
                .left, .right => .horizontal,
                .up, .down => .vertical,
            };
            const sign: f16 = switch (value.direction) {
                .right, .down => 1.0,
                .left, .up => -1.0,
            };
            const ratio_delta: f16 = sign * @as(f16, @floatFromInt(value.amount)) / 100.0;
            window.activeTab().resizeSplit(window, layout, ratio_delta) catch |err| {
                log.warn("Failed to resize split: {}", .{err});
                return false;
            };
            return true;
        },

        .equalize_splits => {
            const window = self.windowFromTarget(target) orelse return false;
            window.activeTab().equalizeSplits(window) catch |err| {
                log.warn("Failed to equalize splits: {}", .{err});
                return false;
            };
            return true;
        },

        .toggle_split_zoom => {
            const window = self.windowFromTarget(target) orelse return false;
            window.activeTab().toggleZoom(window);
            return true;
        },

        .new_tab => {
            const window = self.windowFromTarget(target) orelse return false;
            window.newTab() catch |err| {
                log.warn("Failed to create new tab: {}", .{err});
                return false;
            };
            return true;
        },

        .close_tab => {
            const window = self.windowFromTarget(target) orelse return false;
            window.closeTabMode(value);
            return true;
        },

        .goto_tab => {
            const window = self.windowFromTarget(target) orelse return false;
            window.gotoTab(value);
            return true;
        },

        .move_tab => {
            const window = self.windowFromTarget(target) orelse return false;
            window.moveTab(value.amount);
            return true;
        },

        .goto_window => {
            if (self.windows.items.len == 0) return false;
            const current_window = self.windowFromTarget(target);
            const current_idx: usize = if (current_window) |cw| blk: {
                for (self.windows.items, 0..) |w, i| {
                    if (w == cw) break :blk i;
                }
                break :blk 0;
            } else 0;

            const len = self.windows.items.len;
            const next_idx: usize = switch (value) {
                .next => (current_idx + 1) % len,
                .previous => if (current_idx == 0) len - 1 else current_idx - 1,
            };
            _ = c.SetForegroundWindow(self.windows.items[next_idx].hwnd);
            return true;
        },

        .present_terminal => {
            const window = self.windowFromTarget(target) orelse return false;
            _ = c.SetForegroundWindow(window.hwnd);
            return true;
        },

        .toggle_visibility => {
            self.visible = !self.visible;
            const cmd: c_int = if (self.visible) c.SW_SHOW else c.SW_HIDE;
            for (self.windows.items) |window| {
                _ = c.ShowWindow(window.hwnd, cmd);
            }
            return true;
        },

        .readonly => {
            return true;
        },

        .mouse_over_link => {
            // Store the URL on the surface for cursor shape and potential tooltip.
            const surface = self.surfaceFromTarget(target) orelse return false;
            surface.link_url_len = @min(value.url.len, surface.link_url_buf.len);
            if (surface.link_url_len > 0) {
                @memcpy(surface.link_url_buf[0..surface.link_url_len], value.url[0..surface.link_url_len]);
            }
            return true;
        },

        .key_sequence => {
            // Show a key sequence indicator in the window title.
            const window = self.windowFromTarget(target) orelse return false;
            switch (value) {
                .trigger => {
                    window.setKeySequenceActive(true);
                },
                .end => {
                    window.setKeySequenceActive(false);
                },
            }
            return true;
        },

        .key_table => {
            return true;
        },

        .scrollbar => {
            return true;
        },

        .progress_report => {
            // Flash the taskbar button to indicate progress.
            const window = self.windowFromTarget(target) orelse return false;
            var flash_info = c.FLASHWINFO{
                .cbSize = @sizeOf(c.FLASHWINFO),
                .hwnd = window.hwnd,
                .dwFlags = c.FLASHW_ALL,
                .uCount = 1,
                .dwTimeout = 0,
            };
            _ = c.FlashWindowEx(&flash_info);
            return true;
        },

        .prompt_title => {
            log.info("prompt_title action received: {s}", .{@tagName(value)});
            const window = self.windowFromTarget(target) orelse return false;
            self.showTitlePrompt(window, target, value);
            return true;
        },

        .desktop_notification => {
            log.info("desktop_notification action received: title='{s}' body='{s}'", .{ value.title, value.body });
            self.showDesktopNotification(value.title, value.body);
            return true;
        },

        .show_child_exited => {
            const surface = self.surfaceFromTarget(target) orelse return false;
            surface.showChildExited(.{
                .exit_code = value.exit_code,
                .runtime_ms = value.runtime_ms,
            });
            return true;
        },

        .start_search => {
            const surface = self.surfaceFromTarget(target) orelse return false;
            surface.showSearch(value.needle);
            return true;
        },

        .end_search => {
            const surface = self.surfaceFromTarget(target) orelse return false;
            surface.hideSearch();
            return true;
        },

        .search_total => {
            const surface = self.surfaceFromTarget(target) orelse return false;
            surface.updateSearchTotal(value.total);
            return true;
        },

        .search_selected => {
            const surface = self.surfaceFromTarget(target) orelse return false;
            surface.updateSearchSelected(value.selected);
            return true;
        },

        else => {
            log.debug("Unhandled action: {s}", .{@tagName(action)});
            return false;
        },
    }
}

/// Get the Surface from a target.
fn surfaceFromTarget(self: *App, target: apprt.Target) ?*Surface {
    return switch (target) {
        .surface => |cs| cs.rt_surface,
        .app => if (self.main_window) |w| w.activeSurface() else null,
    };
}

/// Get the Window from a target.
fn windowFromTarget(self: *App, target: apprt.Target) ?*Window {
    return switch (target) {
        .surface => |cs| cs.rt_surface.window,
        .app => self.main_window,
    };
}

/// Remove a window from tracking.
pub fn removeWindow(self: *App, window: *Window) void {
    for (self.windows.items, 0..) |w, i| {
        if (w == window) {
            _ = self.windows.swapRemove(i);
            break;
        }
    }
    if (self.main_window == window) {
        self.main_window = if (self.windows.items.len > 0) self.windows.items[0] else null;
    }
}

/// Show a desktop notification using Shell_NotifyIconW balloon tips.
fn showDesktopNotification(self: *App, title: [:0]const u8, body: [:0]const u8) void {
    log.info("showDesktopNotification called: title='{s}' body='{s}'", .{ title, body });

    const hwnd = if (self.main_window) |w| w.hwnd else {
        log.warn("Cannot show notification: no main window", .{});
        return;
    };

    // Ensure the notification icon exists in the tray
    if (!self.notify_icon_added) {
        var nid: c.NOTIFYICONDATAW = std.mem.zeroes(c.NOTIFYICONDATAW);
        nid.cbSize = @sizeOf(c.NOTIFYICONDATAW);
        nid.hWnd = hwnd;
        nid.uID = 1;
        nid.uFlags = c.NIF_ICON | c.NIF_TIP | c.NIF_MESSAGE;
        nid.uCallbackMessage = c.WM_APP + 1;
        nid.hIcon = c.LoadIconW(null, c.IDI_APPLICATION);

        if (nid.hIcon == null) {
            log.warn("LoadIconW returned null for IDI_APPLICATION", .{});
        }

        // Set tooltip to "Ghostty"
        const tip = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");
        @memcpy(nid.szTip[0..tip.len], tip);

        log.info("Calling Shell_NotifyIconW NIM_ADD, cbSize={}", .{nid.cbSize});

        if (c.Shell_NotifyIconW(c.NIM_ADD, &nid) != 0) {
            self.notify_icon_added = true;
            log.info("Notification icon added to tray successfully", .{});

            // Set version for modern notification behavior
            nid.uVersion = c.NOTIFYICON_VERSION_4;
            if (c.Shell_NotifyIconW(c.NIM_SETVERSION, &nid) == 0) {
                log.warn("NIM_SETVERSION failed (error={}), continuing anyway", .{c.GetLastError()});
            }
        } else {
            const err = c.GetLastError();
            log.warn("Shell_NotifyIconW NIM_ADD failed (error={})", .{err});
            return;
        }
    }

    // Show the balloon notification via NIM_MODIFY
    var nid: c.NOTIFYICONDATAW = std.mem.zeroes(c.NOTIFYICONDATAW);
    nid.cbSize = @sizeOf(c.NOTIFYICONDATAW);
    nid.hWnd = hwnd;
    nid.uID = 1;
    nid.uFlags = c.NIF_INFO;
    nid.dwInfoFlags = c.NIIF_INFO;

    // Convert title (UTF-8 -> UTF-16) and copy into szInfoTitle
    const alloc = self.core_app.alloc;
    if (std.unicode.utf8ToUtf16LeAlloc(alloc, title)) |wide_title| {
        defer alloc.free(wide_title);
        const title_len = @min(wide_title.len, nid.szInfoTitle.len - 1);
        @memcpy(nid.szInfoTitle[0..title_len], wide_title[0..title_len]);
    } else |_| {
        log.warn("Failed to convert notification title to UTF-16", .{});
    }

    // Convert body (UTF-8 -> UTF-16) and copy into szInfo
    if (std.unicode.utf8ToUtf16LeAlloc(alloc, body)) |wide_body| {
        defer alloc.free(wide_body);
        const body_len = @min(wide_body.len, nid.szInfo.len - 1);
        @memcpy(nid.szInfo[0..body_len], wide_body[0..body_len]);
    } else |_| {
        log.warn("Failed to convert notification body to UTF-16", .{});
    }

    if (c.Shell_NotifyIconW(c.NIM_MODIFY, &nid) == 0) {
        const err = c.GetLastError();
        log.warn("Shell_NotifyIconW NIM_MODIFY failed (error={})", .{err});
    } else {
        log.info("Desktop notification shown successfully: title='{s}'", .{title});
    }
}

/// Context for WinUI title dialog async callback.
const TitleDialogContext = struct {
    app: *App,
    window: *Window,
    target: apprt.Target,
    prompt_type: apprt.action.PromptTitle,
};

/// Callback from WinUI ContentDialog.
fn winuiTitleDialogResult(ctx_ptr: ?*anyopaque, accepted: i32, new_title: ?[*:0]const u8) callconv(.c) void {
    const ctx: *TitleDialogContext = @ptrCast(@alignCast(ctx_ptr));
    defer ctx.app.core_app.alloc.destroy(ctx);

    if (accepted != 0) {
        if (new_title) |title| {
            switch (ctx.prompt_type) {
                .surface => {
                    if (ctx.app.surfaceFromTarget(ctx.target)) |surface| {
                        surface.setTitle(std.mem.span(title));
                    }
                },
                .tab => {
                    ctx.window.setTitle(std.mem.span(title));
                },
            }
        }
    }
}

/// Show a title prompt dialog. Uses WinUI ContentDialog if available,
/// otherwise creates a Win32 popup with edit control and OK/Cancel buttons.
fn showTitlePrompt(self: *App, window: *Window, target: apprt.Target, prompt_type: apprt.action.PromptTitle) void {
    // Try WinUI ContentDialog first.
    if (self.winui.isAvailable() and window.using_winui) {
        if (self.winui.title_dialog_show) |show_fn| {
            const label: [*:0]const u8 = switch (prompt_type) {
                .surface => "Surface title:",
                .tab => "Tab title:",
            };
            const current = if (window.getTitle()) |t| t else "";

            // We need to pass context for the callback. Pack window/target/prompt_type
            // into a heap-allocated context struct that the callback will free.
            const alloc = self.core_app.alloc;
            const ctx = alloc.create(TitleDialogContext) catch return;
            ctx.* = .{
                .app = self,
                .window = window,
                .target = target,
                .prompt_type = prompt_type,
            };
            show_fn(window.winui_tabview, label, current, @ptrCast(ctx), &winuiTitleDialogResult);
            return;
        }
    }

    // GDI fallback.
    const hinstance = self.hinstance;

    const label_w = switch (prompt_type) {
        .surface => std.unicode.utf8ToUtf16LeStringLiteral("Surface title:"),
        .tab => std.unicode.utf8ToUtf16LeStringLiteral("Tab title:"),
    };

    // Dialog dimensions
    const dlg_w: i32 = 400;
    const dlg_h: i32 = 130;

    // Center on parent window
    var parent_rect: c.RECT = undefined;
    _ = c.GetWindowRect(window.hwnd, &parent_rect);
    const px = @divTrunc((parent_rect.right + parent_rect.left - dlg_w), 2);
    const py = @divTrunc((parent_rect.bottom + parent_rect.top - dlg_h), 2);

    // Create the dialog window using the dedicated dialog class.
    const dlg_class = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyDialog");
    const dlg_title = std.unicode.utf8ToUtf16LeStringLiteral("Set Title");
    const dlg_hwnd = c.CreateWindowExW(
        0,
        dlg_class,
        dlg_title,
        c.WS_OVERLAPPED | c.WS_CAPTION | c.WS_SYSMENU,
        px,
        py,
        dlg_w,
        dlg_h,
        window.hwnd,
        null,
        hinstance,
        null,
    ) orelse return;

    // Get the default GUI font
    const font = c.GetStockObject(c.DEFAULT_GUI_FONT);

    // Create label
    const label_class = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
    const label_hwnd = c.CreateWindowExW(
        0,
        label_class,
        label_w,
        c.WS_CHILD | c.WS_VISIBLE,
        10,
        10,
        dlg_w - 20,
        20,
        dlg_hwnd,
        null,
        hinstance,
        null,
    );
    if (label_hwnd) |h| {
        _ = c.SendMessageW(h, c.WM_SETFONT, @intFromPtr(font), 1);
    }

    // Create edit control
    const edit_class = std.unicode.utf8ToUtf16LeStringLiteral("EDIT");
    const empty_str = std.unicode.utf8ToUtf16LeStringLiteral("");
    const edit_hwnd = c.CreateWindowExW(
        c.WS_EX_CLIENTEDGE,
        edit_class,
        empty_str,
        c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.ES_LEFT | c.ES_AUTOHSCROLL,
        10,
        35,
        dlg_w - 20,
        24,
        dlg_hwnd,
        null,
        hinstance,
        null,
    ) orelse {
        _ = c.DestroyWindow(dlg_hwnd);
        return;
    };
    _ = c.SendMessageW(edit_hwnd, c.WM_SETFONT, @intFromPtr(font), 1);

    // Create OK button (ID = 1)
    const btn_class = std.unicode.utf8ToUtf16LeStringLiteral("BUTTON");
    const ok_text = std.unicode.utf8ToUtf16LeStringLiteral("OK");
    const ok_hwnd = c.CreateWindowExW(
        0,
        btn_class,
        ok_text,
        c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.BS_DEFPUSHBUTTON,
        dlg_w - 180,
        70,
        80,
        28,
        dlg_hwnd,
        @ptrFromInt(1),
        hinstance,
        null,
    );
    if (ok_hwnd) |h| {
        _ = c.SendMessageW(h, c.WM_SETFONT, @intFromPtr(font), 1);
    }

    // Create Cancel button (ID = 2)
    const cancel_text = std.unicode.utf8ToUtf16LeStringLiteral("Cancel");
    const cancel_hwnd = c.CreateWindowExW(
        0,
        btn_class,
        cancel_text,
        c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP,
        dlg_w - 90,
        70,
        80,
        28,
        dlg_hwnd,
        @ptrFromInt(2),
        hinstance,
        null,
    );
    if (cancel_hwnd) |h| {
        _ = c.SendMessageW(h, c.WM_SETFONT, @intFromPtr(font), 1);
    }

    // Disable the parent window (make dialog modal)
    _ = c.EnableWindow(window.hwnd, 0);

    // Show the dialog and focus the edit control
    _ = c.ShowWindow(dlg_hwnd, c.SW_SHOW);
    _ = c.UpdateWindow(dlg_hwnd);
    _ = c.SetFocus(edit_hwnd);

    // Modal message loop for the dialog. The dialogWndProc sets
    // dialog_result when OK/Cancel/Close is triggered.
    dialog_result = null;
    var msg: MSG = undefined;

    while (dialog_result == null) {
        if (c.PeekMessageW(&msg, null, 0, 0, c.PM_REMOVE) == 0) {
            _ = c.MsgWaitForMultipleObjects(0, null, 0, 10, c.QS_ALLINPUT);
            continue;
        }

        if (msg.message == c.WM_QUIT) {
            c.PostQuitMessage(0);
            break;
        }

        // Handle Enter/Escape in the edit control before dispatching.
        if (msg.message == c.WM_KEYDOWN and msg.hwnd == edit_hwnd) {
            const vk: u8 = @truncate(msg.wParam);
            if (vk == c.VK_RETURN) {
                dialog_result = true;
                break;
            } else if (vk == c.VK_ESCAPE) {
                dialog_result = false;
                break;
            }
        }

        // Let IsDialogMessageW handle Tab navigation between controls.
        if (c.IsDialogMessageW(dlg_hwnd, &msg) != 0) continue;

        _ = c.TranslateMessage(&msg);
        _ = c.DispatchMessageW(&msg);
    }

    const confirmed = dialog_result orelse false;

    // Re-enable parent window
    _ = c.EnableWindow(window.hwnd, 1);
    _ = c.SetForegroundWindow(window.hwnd);

    if (confirmed) {
        // Read text from edit control
        var buf: [256]u16 = undefined;
        const text_len = c.GetWindowTextW(edit_hwnd, &buf, 256);
        if (text_len > 0) {
            const wide_slice = buf[0..@intCast(text_len)];
            const alloc = self.core_app.alloc;
            if (std.unicode.utf16LeToUtf8Alloc(alloc, wide_slice)) |utf8| {
                defer alloc.free(utf8);
                const title_z = alloc.allocSentinel(u8, utf8.len, 0) catch {
                    _ = c.DestroyWindow(dlg_hwnd);
                    return;
                };
                defer alloc.free(title_z);
                @memcpy(title_z[0..utf8.len], utf8);

                switch (prompt_type) {
                    .surface => {
                        if (self.surfaceFromTarget(target)) |surface| {
                            surface.setTitle(title_z);
                        }
                    },
                    .tab => {
                        window.setTitle(title_z);
                    },
                }
            } else |_| {}
        }
    }

    _ = c.DestroyWindow(dlg_hwnd);
}

/// Create a new window with a surface.
fn newWindow(self: *App, parent: ?*CoreSurface) !void {
    _ = parent; // TODO: inherit properties from parent surface

    const alloc = self.core_app.alloc;

    // Create the window (which creates its child surface)
    const window = try Window.create(self);
    errdefer {
        // Window.create already set up the surface; cleanup via DestroyWindow cascade
        _ = c.DestroyWindow(window.hwnd);
        alloc.destroy(window);
    }

    // Track the window
    try self.windows.append(alloc, window);

    // Set as main window if first
    if (self.main_window == null) {
        self.main_window = window;
    }

    // Get the surface for core initialization
    const surface = window.activeSurface();

    // Create the core surface config
    var config = try apprt.surface.newConfig(self.core_app, &self.config, .window);
    defer config.deinit();

    // Create and initialize the core surface
    const core_surface = try alloc.create(CoreSurface);
    errdefer alloc.destroy(core_surface);

    try self.core_app.addSurface(surface);
    errdefer self.core_app.deleteSurface(surface);

    try core_surface.init(
        alloc,
        &config,
        self.core_app,
        self,
        surface,
    );
    surface.core_surface = core_surface;

    // Detect initial color scheme
    const scheme = Window.detectColorScheme();
    core_surface.colorSchemeCallback(scheme) catch {};

    // Show the window and set focus to the surface
    _ = c.ShowWindow(window.hwnd, c.SW_SHOW);
    _ = c.UpdateWindow(window.hwnd);
    _ = c.SetFocus(surface.hwnd);

    log.info("New window created", .{});
}

/// Send the given IPC to a running Ghostty instance.
pub fn performIpc(
    alloc: Allocator,
    target: apprt.ipc.Target,
    comptime action: apprt.ipc.Action.Key,
    value: apprt.ipc.Action.Value(action),
) !bool {
    switch (action) {
        .new_window => return try ipcNewWindow(alloc, target, value),
    }
}

fn ipcNewWindow(
    alloc: Allocator,
    target: apprt.ipc.Target,
    value: anytype,
) !bool {
    _ = alloc;
    _ = value;

    const pipe_name = switch (target) {
        .class => pipe_name_str,
        .detect => pipe_name_str,
    };

    const pipe = c.CreateFileW(
        pipe_name,
        c.GENERIC_WRITE,
        0,
        null,
        c.OPEN_EXISTING,
        0,
        null,
    );

    if (pipe == c.INVALID_HANDLE_VALUE) {
        log.debug("No running Ghostty instance found via named pipe", .{});
        return false;
    }
    defer _ = c.CloseHandle(pipe);

    const cmd = "new_window\n";
    var bytes_written: u32 = 0;
    if (c.WriteFile(pipe, cmd.ptr, cmd.len, &bytes_written, null) == 0) {
        log.warn("Failed to send IPC command", .{});
        return false;
    }

    log.info("Sent new_window IPC to running instance", .{});
    return true;
}

const pipe_name_str = std.unicode.utf8ToUtf16LeStringLiteral("\\\\.\\pipe\\ghostty_" ++ application_id);

/// Redraw the inspector for the given surface.
pub fn redrawInspector(_: *App, surface: *Surface) void {
    surface.redrawInspector();
}

// --- Private implementation ---

fn setDpiAwarenessContext() void {
    const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: c.DPI_AWARENESS_CONTEXT =
        @ptrFromInt(@as(usize, @bitCast(@as(isize, -4))));

    if (c.SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) != 0) {
        log.info("Set DPI awareness to Per-Monitor V2", .{});
        return;
    }

    const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE: c.DPI_AWARENESS_CONTEXT =
        @ptrFromInt(@as(usize, @bitCast(@as(isize, -3))));

    if (c.SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE) != 0) {
        log.info("Set DPI awareness to Per-Monitor V1", .{});
        return;
    }

    log.warn("Failed to set DPI awareness, continuing anyway", .{});
}

/// Register the window class for top-level Ghostty windows.
fn registerWindowClass(hinstance: HINSTANCE) !void {
    const class_name_w = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyWindow");

    const wc = c.WNDCLASSEXW{
        .cbSize = @sizeOf(c.WNDCLASSEXW),
        .style = c.CS_HREDRAW | c.CS_VREDRAW,
        .lpfnWndProc = Window.windowProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = c.LoadCursorW(null, c.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = class_name_w,
        .hIconSm = null,
    };

    const atom = c.RegisterClassExW(&wc);
    if (atom == 0) {
        log.err("Failed to register window class", .{});
        return error.RegisterClassFailed;
    }

    log.info("Registered window class", .{});
}

/// Register the window class for child surface windows.
fn registerSurfaceClass(hinstance: HINSTANCE) !void {
    const class_name_w = std.unicode.utf8ToUtf16LeStringLiteral("GhosttySurface");

    const wc = c.WNDCLASSEXW{
        .cbSize = @sizeOf(c.WNDCLASSEXW),
        .style = c.CS_OWNDC,
        .lpfnWndProc = Surface.windowProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = c.LoadCursorW(null, c.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = class_name_w,
        .hIconSm = null,
    };

    const atom = c.RegisterClassExW(&wc);
    if (atom == 0) {
        log.err("Failed to register surface class", .{});
        return error.RegisterClassFailed;
    }

    log.info("Registered surface class", .{});
}

/// Register the window class for the tab bar.
fn registerTabBarClass(hinstance: HINSTANCE) !void {
    const class_name_w = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyTabBar");

    const wc = c.WNDCLASSEXW{
        .cbSize = @sizeOf(c.WNDCLASSEXW),
        .style = c.CS_HREDRAW | c.CS_VREDRAW | c.CS_DBLCLKS,
        .lpfnWndProc = TabBar.windowProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = c.LoadCursorW(null, c.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = class_name_w,
        .hIconSm = null,
    };

    const atom = c.RegisterClassExW(&wc);
    if (atom == 0) {
        log.err("Failed to register tab bar class", .{});
        return error.RegisterClassFailed;
    }

    log.info("Registered tab bar class", .{});
}

/// Register the window class for the search bar.
fn registerSearchBarClass(hinstance: HINSTANCE) !void {
    const class_name_w = std.unicode.utf8ToUtf16LeStringLiteral("GhosttySearchBar");

    const wc = c.WNDCLASSEXW{
        .cbSize = @sizeOf(c.WNDCLASSEXW),
        .style = c.CS_HREDRAW | c.CS_VREDRAW,
        .lpfnWndProc = SearchBar.windowProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = c.LoadCursorW(null, c.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = class_name_w,
        .hIconSm = null,
    };

    const atom = c.RegisterClassExW(&wc);
    if (atom == 0) {
        log.err("Failed to register search bar class", .{});
        return error.RegisterClassFailed;
    }

    log.info("Registered search bar class", .{});
}

/// Register the window class for the title prompt dialog.
fn registerDialogClass(hinstance: HINSTANCE) !void {
    const class_name_w = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyDialog");

    const wc = c.WNDCLASSEXW{
        .cbSize = @sizeOf(c.WNDCLASSEXW),
        .style = c.CS_HREDRAW | c.CS_VREDRAW,
        .lpfnWndProc = dialogWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = c.LoadCursorW(null, c.IDC_ARROW),
        .hbrBackground = @ptrFromInt(c.COLOR_BTNFACE + 1),
        .lpszMenuName = null,
        .lpszClassName = class_name_w,
        .hIconSm = null,
    };

    const atom = c.RegisterClassExW(&wc);
    if (atom == 0) {
        log.err("Failed to register dialog class", .{});
        return error.RegisterClassFailed;
    }

    log.info("Registered dialog class", .{});
}

/// Register the window class for the WinUI drag overlay.
/// This transparent child window sits on top of the XAML Island to
/// intercept mouse messages for window dragging, resizing, and
/// caption button hit-testing (like Windows Terminal's drag bar).
fn registerDragOverlayClass(hinstance: HINSTANCE) !void {
    const class_name_w = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyDragOverlay");

    const wc = c.WNDCLASSEXW{
        .cbSize = @sizeOf(c.WNDCLASSEXW),
        .style = c.CS_HREDRAW | c.CS_VREDRAW | c.CS_DBLCLKS,
        .lpfnWndProc = Window.dragOverlayProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = c.LoadCursorW(null, c.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = class_name_w,
        .hIconSm = null,
    };

    const atom = c.RegisterClassExW(&wc);
    if (atom == 0) {
        log.err("Failed to register drag overlay class", .{});
        return error.RegisterClassFailed;
    }

    log.info("Registered drag overlay class", .{});
}

