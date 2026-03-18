//! Win32 application runtime. Manages the Win32 window class, message loop,
//! and surface (window) lifecycle.
const App = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const Config = configpkg.Config;
const CoreApp = @import("../../App.zig");
const CoreSurface = @import("../../Surface.zig");
const internal_os = @import("../../os/main.zig");

const Surface = @import("Surface.zig");
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32);

/// OpenGL draws happen on the renderer thread, not the app thread.
pub const must_draw_from_app_thread = false;

/// Custom window message used to wake up the message loop so that
/// core_app.tick() is called.
const WM_APP_WAKEUP: u32 = w32.WM_APP + 1;

/// The Win32 window class name (wide string).
const CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyWindow");

/// The core application.
core_app: *CoreApp,

/// A message-only window used to receive WM_APP_WAKEUP.
/// This is not a visible window; it just participates in the message loop.
msg_hwnd: ?w32.HWND = null,

/// The HINSTANCE for this module.
hinstance: w32.HINSTANCE,

/// Window class atom from RegisterClassExW.
class_atom: u16 = 0,

/// Whether quit has been requested.
quit_requested: bool = false,

pub fn init(
    self: *App,
    core_app: *CoreApp,
    opts: struct {},
) !void {
    _ = opts;

    const hinstance = w32.GetModuleHandleW(null) orelse
        return error.Win32Error;

    self.* = .{
        .core_app = core_app,
        .hinstance = hinstance,
    };

    // Register the window class
    const wc = w32.WNDCLASSEXW{
        .cbSize = @sizeOf(w32.WNDCLASSEXW),
        .style = w32.CS_HREDRAW | w32.CS_VREDRAW | w32.CS_OWNDC,
        .lpfnWndProc = &wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = CLASS_NAME,
        .hIconSm = null,
    };

    self.class_atom = w32.RegisterClassExW(&wc);
    if (self.class_atom == 0) return error.Win32Error;

    // Create a message-only window for receiving WM_APP_WAKEUP.
    // HWND_MESSAGE makes it a message-only window (invisible, no rendering).
    self.msg_hwnd = w32.CreateWindowExW(
        0,
        CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral("GhosttyMsg"),
        0, // no style needed
        0,
        0,
        0,
        0,
        w32.HWND_MESSAGE,
        null,
        hinstance,
        null,
    );
    if (self.msg_hwnd == null) return error.Win32Error;

    // Store self pointer in msg_hwnd's GWLP_USERDATA for wndProc access
    _ = w32.SetWindowLongPtrW(self.msg_hwnd.?, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
}

pub fn run(self: *App) !void {
    // Create the initial window
    var initial_surface: Surface = undefined;
    try initial_surface.init(self);

    // Enter the Win32 message loop
    var msg: w32.MSG = undefined;
    while (!self.quit_requested) {
        const result = w32.GetMessageW(&msg, null, 0, 0);
        if (result == 0) break; // WM_QUIT
        if (result < 0) return error.Win32Error;

        _ = w32.TranslateMessage(&msg);
        _ = w32.DispatchMessageW(&msg);
    }
}

pub fn terminate(self: *App) void {
    if (self.msg_hwnd) |hwnd| {
        _ = w32.DestroyWindow(hwnd);
        self.msg_hwnd = null;
    }
}

/// Wake up the message loop from any thread by posting a message
/// to the message-only window.
pub fn wakeup(self: *App) void {
    if (self.msg_hwnd) |hwnd| {
        _ = w32.PostMessageW(hwnd, WM_APP_WAKEUP, 0, 0);
    }
}

/// IPC from external processes. Not yet implemented for Win32.
pub fn performIpc(
    _: Allocator,
    _: apprt.ipc.Target,
    comptime action: apprt.ipc.Action.Key,
    _: apprt.ipc.Action.Value(action),
) !bool {
    return false;
}

pub fn performAction(
    self: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    switch (action) {
        .quit => {
            self.quit_requested = true;
            w32.PostQuitMessage(0);
            return true;
        },

        .new_window => {
            var surface: Surface = undefined;
            surface.init(self) catch |err| {
                log.err("failed to create new window err={}", .{err});
                return true;
            };
            return true;
        },

        .set_title => {
            switch (target) {
                .app => {},
                .surface => |core_surface| {
                    const rt_surface = core_surface.rt_surface;
                    rt_surface.setTitle(value.title);
                },
            }
            return true;
        },

        .ring_bell => {
            _ = w32.MessageBeep(0xFFFFFFFF);
            return true;
        },

        .quit_timer => {
            // For now, just quit immediately when the last surface closes.
            switch (value) {
                .start => {
                    self.quit_requested = true;
                    w32.PostQuitMessage(0);
                },
                .stop => {},
            }
            return true;
        },

        // Return false for unhandled actions
        else => return false,
    }
}

/// Create a new visible window. This is called by Surface.init and
/// by performAction(.new_window).
pub fn createWindow(self: *App) !w32.HWND {
    const hwnd = w32.CreateWindowExW(
        0,
        CLASS_NAME,
        std.unicode.utf8ToUtf16LeStringLiteral("Ghostty"),
        w32.WS_OVERLAPPEDWINDOW,
        w32.CW_USEDEFAULT,
        w32.CW_USEDEFAULT,
        800,
        600,
        null,
        null,
        self.hinstance,
        null,
    ) orelse return error.Win32Error;

    _ = w32.ShowWindow(hwnd, w32.SW_SHOW);
    _ = w32.UpdateWindow(hwnd);

    return hwnd;
}

/// Notify the core app of a tick.
fn tick(self: *App) void {
    self.core_app.tick(self) catch |err| {
        log.err("core app tick error: {}", .{err});
    };
}

/// The Win32 window procedure. Routes messages to the appropriate Surface
/// or handles app-level messages.
fn wndProc(
    hwnd: w32.HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) callconv(.c) isize {
    // Try to get the Surface from GWLP_USERDATA. For the message-only window
    // we store the App pointer instead (set in init); for regular windows we
    // store the Surface pointer (set in Surface.init).
    //
    // During window creation (before SetWindowLongPtrW), this will be 0.
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);

    switch (msg) {
        WM_APP_WAKEUP => {
            // This comes to the message-only window. The userdata is the App.
            if (userdata != 0) {
                const app: *App = @ptrFromInt(@as(usize, @bitCast(userdata)));
                app.tick();
            }
            return 0;
        },

        w32.WM_SIZE => {
            if (userdata != 0) {
                const surface: *Surface = @ptrFromInt(@as(usize, @bitCast(userdata)));
                const width: u32 = @intCast(lparam & 0xFFFF);
                const height: u32 = @intCast((lparam >> 16) & 0xFFFF);
                surface.handleResize(width, height);
            }
            return 0;
        },

        w32.WM_CLOSE => {
            if (userdata != 0) {
                const surface: *Surface = @ptrFromInt(@as(usize, @bitCast(userdata)));
                surface.close(false);
            }
            return 0;
        },

        w32.WM_DESTROY => {
            if (userdata != 0) {
                const surface: *Surface = @ptrFromInt(@as(usize, @bitCast(userdata)));
                surface.handleDestroy();
            }
            return 0;
        },

        w32.WM_PAINT => {
            // For now just validate the paint region
            _ = w32.ValidateRect(hwnd, null);
            return 0;
        },

        w32.WM_DPICHANGED => {
            if (userdata != 0) {
                const surface: *Surface = @ptrFromInt(@as(usize, @bitCast(userdata)));
                surface.handleDpiChange();
            }
            return 0;
        },

        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
