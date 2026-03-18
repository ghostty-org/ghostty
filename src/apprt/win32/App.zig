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

/// The configuration for the application. Loaded during init and
/// updated in response to config_change actions.
config: Config,

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

    // Load the configuration for this application.
    const alloc = core_app.alloc;
    var config = Config.load(alloc) catch |err| err: {
        log.err("failed to load config: {}", .{err});
        var def: Config = try .default(alloc);
        errdefer def.deinit();
        try def.addDiagnosticFmt(
            "error loading user configuration: {}",
            .{err},
        );
        break :err def;
    };
    errdefer config.deinit();

    self.* = .{
        .core_app = core_app,
        .config = config,
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
    // Create the initial window (heap-allocated because renderer/IO
    // threads hold references to the surface).
    const alloc = self.core_app.alloc;
    const initial_surface = try alloc.create(Surface);
    errdefer alloc.destroy(initial_surface);
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

    self.config.deinit();
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
            const alloc = self.core_app.alloc;
            const surface = alloc.create(Surface) catch |err| {
                log.err("failed to allocate new surface err={}", .{err});
                return true;
            };
            surface.init(self) catch |err| {
                log.err("failed to create new window err={}", .{err});
                alloc.destroy(surface);
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

        .config_change => {
            // Update our stored config with the new one.
            if (value.config.clone(self.core_app.alloc)) |new_config| {
                self.config.deinit();
                self.config = new_config;
            } else |err| {
                log.err("error updating app config err={}", .{err});
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
    // GWLP_USERDATA stores either an *App (message-only window) or
    // *Surface (visible windows). We disambiguate by checking the message:
    // WM_APP_WAKEUP only goes to the message-only window.
    const userdata = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);

    // Handle app-level wakeup message (message-only window, userdata is *App).
    if (msg == WM_APP_WAKEUP) {
        if (userdata != 0) {
            const app: *App = @ptrFromInt(@as(usize, @bitCast(userdata)));
            app.tick();
        }
        return 0;
    }

    // All other messages are for visible (surface) windows.
    // If userdata is 0 (during creation) or this is a non-surface window,
    // fall through to DefWindowProc.
    const surface: *Surface = if (userdata != 0)
        @ptrFromInt(@as(usize, @bitCast(userdata)))
    else
        return w32.DefWindowProcW(hwnd, msg, wparam, lparam);

    // Guard: verify this is actually a surface window, not the msg-only window.
    // The msg-only window can receive WM_DESTROY during shutdown.
    if (surface.hwnd == null or surface.hwnd.? != hwnd)
        return w32.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        w32.WM_SIZE => {
            const width: u32 = @intCast(lparam & 0xFFFF);
            const height: u32 = @intCast((lparam >> 16) & 0xFFFF);
            surface.handleResize(width, height);
            return 0;
        },

        w32.WM_CLOSE => {
            surface.close(false);
            return 0;
        },

        w32.WM_DESTROY => {
            surface.handleDestroy();
            return 0;
        },

        w32.WM_PAINT => {
            _ = w32.ValidateRect(hwnd, null);
            return 0;
        },

        w32.WM_DPICHANGED => {
            surface.handleDpiChange();
            return 0;
        },

        w32.WM_KEYDOWN, w32.WM_SYSKEYDOWN => {
            surface.handleKeyEvent(wparam, lparam, .press);
            return 0;
        },

        w32.WM_KEYUP, w32.WM_SYSKEYUP => {
            surface.handleKeyEvent(wparam, lparam, .release);
            return 0;
        },

        w32.WM_CHAR => {
            // Text input is handled through keyCallback's key encoding
            // in handleKeyEvent. WM_CHAR would duplicate the input.
            // TODO: Re-enable for IME (input method editor) support.
            return 0;
        },

        w32.WM_LBUTTONDOWN => { surface.handleMouseButton(.left, .press, lparam); return 0; },
        w32.WM_LBUTTONUP => { surface.handleMouseButton(.left, .release, lparam); return 0; },
        w32.WM_RBUTTONDOWN => { surface.handleMouseButton(.right, .press, lparam); return 0; },
        w32.WM_RBUTTONUP => { surface.handleMouseButton(.right, .release, lparam); return 0; },
        w32.WM_MBUTTONDOWN => { surface.handleMouseButton(.middle, .press, lparam); return 0; },
        w32.WM_MBUTTONUP => { surface.handleMouseButton(.middle, .release, lparam); return 0; },

        w32.WM_MOUSEMOVE => {
            surface.handleMouseMove(lparam);
            return 0;
        },

        w32.WM_MOUSEWHEEL => {
            surface.handleMouseWheel(wparam);
            return 0;
        },

        w32.WM_SETFOCUS => { surface.handleFocus(true); return 0; },
        w32.WM_KILLFOCUS => { surface.handleFocus(false); return 0; },

        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
