/// Win32 application runtime for Ghostty. This is a minimal native Windows
/// application using the Win32 API with OpenGL rendering.
const App = @This();

const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("win32").everything;
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const Config = configpkg.Config;
const CoreApp = @import("../../App.zig");
const CoreSurface = @import("../../Surface.zig");
const Surface = @import("Surface.zig");
const renderer = @import("../../renderer.zig");

const log = std.log.scoped(.win32);

/// User-defined wakeup message sent via PostMessage to break out of
/// GetMessage and run the core app's tick.
const WM_WAKEUP = win32.WM_USER + 1;

/// The core app instance.
core_app: *CoreApp,

/// The configuration.
config: *Config,

/// The allocator.
alloc: Allocator,

/// Whether the app is running.
running: bool = true,

/// The main window handle.
hwnd: ?win32.HWND = null,

/// The surface for the main window.
surface: Surface = undefined,

pub fn init(
    self: *App,
    core_app: *CoreApp,
    opts: struct {},
) !void {
    _ = opts;

    const alloc = core_app.alloc;

    // Load configuration
    var config = try Config.load(alloc);
    errdefer config.deinit();

    const config_ptr = try alloc.create(Config);
    config_ptr.* = config;

    self.* = .{
        .core_app = core_app,
        .config = config_ptr,
        .alloc = alloc,
    };

    // Create the main window
    try self.createWindow();

    // Initialize the surface with OpenGL
    try self.surface.init(self.hwnd.?);

    // Store self pointer in window for use in wndProc. SetWindowLongPtrW
    // returns the previous value, which for a freshly created window is 0;
    // we don't care about it here.
    _ = win32.SetWindowLongPtrW(
        self.hwnd.?,
        win32.GWLP_USERDATA,
        @bitCast(@intFromPtr(self)),
    );

    // Initialize the core surface (terminal emulation + rendering)
    try self.initCoreSurface();
}

pub fn run(self: *App) !void {
    log.info("starting Win32 event loop", .{});

    while (self.running) {
        var msg: win32.MSG = std.mem.zeroes(win32.MSG);
        const ret = win32.GetMessageW(&msg, null, 0, 0);
        if (ret == 0) {
            // WM_QUIT
            self.running = false;
            break;
        }
        if (ret == -1) {
            log.err("GetMessage failed: err={d}", .{@intFromEnum(win32.GetLastError())});
            return error.Win32Error;
        }
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessageW(&msg);
    }
}

pub fn terminate(self: *App) void {
    self.surface.deinit();
    if (self.hwnd) |hwnd| {
        if (win32.DestroyWindow(hwnd) == 0) {
            log.warn("DestroyWindow failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        }
        self.hwnd = null;
    }
    self.config.deinit();
    self.alloc.destroy(self.config);
}

pub fn wakeup(self: *App) void {
    if (self.hwnd) |hwnd| {
        if (win32.PostMessageW(hwnd, WM_WAKEUP, 0, 0) == 0) {
            log.warn("PostMessage(WM_WAKEUP) failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        }
    }
}

pub fn performAction(
    self: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    _ = self;
    _ = target;
    _ = value;

    switch (action) {
        .quit => {
            win32.PostQuitMessage(0);
            return true;
        },
        .new_window => {
            // TODO: implement multiple windows
            return false;
        },
        else => return false,
    }
}

pub fn performIpc(
    _: Allocator,
    _: apprt.ipc.Target,
    comptime action: apprt.ipc.Action.Key,
    _: apprt.ipc.Action.Value(action),
) !bool {
    return false;
}

pub fn redrawInspector(_: *App, surface: *Surface) void {
    surface.redrawInspector();
}

fn initCoreSurface(self: *App) !void {
    const alloc = self.alloc;

    // Set the app pointer on the surface
    self.surface.app = self;

    // Create the core surface
    const core_surface = try alloc.create(CoreSurface);
    errdefer alloc.destroy(core_surface);

    // Register with the core app
    try self.core_app.addSurface(&self.surface);
    errdefer self.core_app.deleteSurface(&self.surface);

    // Create a surface config
    var config = try apprt.surface.newConfig(
        self.core_app,
        self.config,
        .window,
    );
    defer config.deinit();

    // Initialize the core surface
    core_surface.init(
        alloc,
        &config,
        self.core_app,
        self,
        &self.surface,
    ) catch |err| {
        log.err("failed to initialize core surface: {}", .{err});
        return err;
    };

    self.surface.core_surface = core_surface;
    log.info("core surface initialized successfully", .{});
}

fn createWindow(self: *App) !void {
    const class_name = win32.L("GhosttyWindow");
    const hinstance = win32.GetModuleHandleW(null);

    const wc: win32.WNDCLASSEXW = .{
        .cbSize = @sizeOf(win32.WNDCLASSEXW),
        .style = .{ .HREDRAW = 1, .VREDRAW = 1, .OWNDC = 1 },
        .lpfnWndProc = wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = win32.LoadCursorW(null, win32.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = class_name,
        .hIconSm = null,
    };

    if (win32.RegisterClassExW(&wc) == 0) {
        log.err("RegisterClassExW failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return error.Win32Error;
    }

    const title = win32.L("Ghostty");

    self.hwnd = win32.CreateWindowExW(
        .{},
        class_name,
        title,
        win32.WS_OVERLAPPEDWINDOW,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        800,
        600,
        null,
        null,
        hinstance,
        null,
    ) orelse {
        log.err("CreateWindowExW failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return error.Win32Error;
    };

    _ = win32.ShowWindow(self.hwnd.?, win32.SW_SHOWNORMAL);
    _ = win32.UpdateWindow(self.hwnd.?);
}

fn getApp(hwnd: win32.HWND) ?*App {
    const ptr = win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA);
    if (ptr == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(ptr)));
}

fn wndProc(hwnd: win32.HWND, msg: u32, wparam: win32.WPARAM, lparam: win32.LPARAM) callconv(.winapi) win32.LRESULT {
    switch (msg) {
        win32.WM_CLOSE => {
            win32.PostQuitMessage(0);
            return 0;
        },
        win32.WM_SIZE => {
            if (getApp(hwnd)) |app| {
                const width: u32 = @intCast(lparam & 0xFFFF);
                const height: u32 = @intCast((lparam >> 16) & 0xFFFF);
                if (width > 0 and height > 0) {
                    app.surface.width = width;
                    app.surface.height = height;
                    if (app.surface.core_surface) |core| {
                        core.sizeCallback(.{
                            .width = width,
                            .height = height,
                        }) catch |err| {
                            log.err("size callback error: {}", .{err});
                        };
                    }
                }
            }
            return 0;
        },
        win32.WM_PAINT => {
            var ps: win32.PAINTSTRUCT = std.mem.zeroes(win32.PAINTSTRUCT);
            _ = win32.BeginPaint(hwnd, &ps);
            if (getApp(hwnd)) |app| {
                app.surface.swapBuffers();
            }
            _ = win32.EndPaint(hwnd, &ps);
            return 0;
        },
        WM_WAKEUP => {
            if (getApp(hwnd)) |app| {
                app.core_app.tick(app) catch |err| {
                    log.err("core app tick failed: {}", .{err});
                };
            }
            return 0;
        },
        else => return win32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
