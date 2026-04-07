/// Win32 application runtime for Ghostty. This is a minimal native Windows
/// application using the Win32 API with OpenGL rendering.
const App = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const Config = configpkg.Config;
const CoreApp = @import("../../App.zig");
const CoreSurface = @import("../../Surface.zig");
const Surface = @import("Surface.zig");
const renderer = @import("../../renderer.zig");

const log = std.log.scoped(.win32);

// Win32 type definitions
const BOOL = i32;
const UINT = u32;
const DWORD = u32;
const WPARAM = usize;
const LPARAM = isize;
const LRESULT = isize;
const HWND = std.os.windows.HWND;
const HINSTANCE = std.os.windows.HINSTANCE;
const HICON = ?*anyopaque;
const HCURSOR = ?*anyopaque;
const HBRUSH = ?*anyopaque;
const HDC = ?*anyopaque;
const HMENU = ?*anyopaque;
const ATOM = u16;
const LONG_PTR = isize;

const POINT = extern struct {
    x: i32,
    y: i32,
};

const MSG = extern struct {
    hwnd: ?HWND,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
};

const RECT = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

const PAINTSTRUCT = extern struct {
    hdc: HDC,
    fErase: BOOL,
    rcPaint: RECT,
    fRestore: BOOL,
    fIncUpdate: BOOL,
    rgbReserved: [32]u8,
};

const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;

const WNDCLASSEXW = extern struct {
    cbSize: UINT,
    style: UINT,
    lpfnWndProc: WNDPROC,
    cbClsExtra: c_int,
    cbWndExtra: c_int,
    hInstance: ?HINSTANCE,
    hIcon: HICON,
    hCursor: HCURSOR,
    hbrBackground: HBRUSH,
    lpszMenuName: ?[*:0]const u16,
    lpszClassName: [*:0]const u16,
    hIconSm: HICON,
};

// Win32 constants
const WM_CLOSE = 0x0010;
const WM_DESTROY = 0x0002;
const WM_PAINT = 0x000F;
const WM_SIZE = 0x0005;
const WM_KEYDOWN = 0x0100;
const WM_CHAR = 0x0102;
const WM_USER = 0x0400;
const WM_WAKEUP = WM_USER + 1;
const CS_HREDRAW = 0x0002;
const CS_VREDRAW = 0x0001;
const CS_OWNDC = 0x0020;
const WS_OVERLAPPEDWINDOW = 0x00CF0000;
const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));
const SW_SHOWNORMAL = 1;
const IDC_ARROW: ?[*:0]align(1) const u16 = @ptrFromInt(32512);
const GWLP_USERDATA: c_int = -21;

// Win32 API extern declarations
extern "user32" fn RegisterClassExW(lpWndClass: *const WNDCLASSEXW) callconv(.winapi) ATOM;
extern "user32" fn CreateWindowExW(dwExStyle: DWORD, lpClassName: ?[*:0]const u16, lpWindowName: ?[*:0]const u16, dwStyle: DWORD, x: i32, y: i32, nWidth: i32, nHeight: i32, hWndParent: ?HWND, hMenu: HMENU, hInstance: ?HINSTANCE, lpParam: ?*anyopaque) callconv(.winapi) ?HWND;
extern "user32" fn ShowWindow(hWnd: HWND, nCmdShow: c_int) callconv(.winapi) BOOL;
extern "user32" fn UpdateWindow(hWnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn DefWindowProcW(hWnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn GetMessageW(lpMsg: *MSG, hWnd: ?HWND, wMsgFilterMin: UINT, wMsgFilterMax: UINT) callconv(.winapi) BOOL;
extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.winapi) BOOL;
extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.winapi) LRESULT;
extern "user32" fn PostMessageW(hWnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) BOOL;
extern "user32" fn PostQuitMessage(nExitCode: c_int) callconv(.winapi) void;
extern "user32" fn BeginPaint(hWnd: HWND, lpPaint: *PAINTSTRUCT) callconv(.winapi) HDC;
extern "user32" fn EndPaint(hWnd: HWND, lpPaint: *const PAINTSTRUCT) callconv(.winapi) BOOL;
extern "user32" fn LoadCursorW(hInstance: ?HINSTANCE, lpCursorName: ?[*:0]align(1) const u16) callconv(.winapi) HCURSOR;
extern "user32" fn SetWindowLongPtrW(hWnd: HWND, nIndex: c_int, dwNewLong: LONG_PTR) callconv(.winapi) LONG_PTR;
extern "user32" fn GetWindowLongPtrW(hWnd: HWND, nIndex: c_int) callconv(.winapi) LONG_PTR;
extern "user32" fn GetClientRect(hWnd: HWND, lpRect: *RECT) callconv(.winapi) BOOL;
extern "user32" fn InvalidateRect(hWnd: ?HWND, lpRect: ?*const RECT, bErase: BOOL) callconv(.winapi) BOOL;
extern "kernel32" fn GetModuleHandleW(lpModuleName: ?[*:0]const u16) callconv(.winapi) ?HINSTANCE;

/// The core app instance.
core_app: *CoreApp,

/// The configuration.
config: *Config,

/// The allocator.
alloc: Allocator,

/// Whether the app is running.
running: bool = true,

/// The main window handle.
hwnd: ?HWND = null,

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

    // Store self pointer in window for use in wndProc
    _ = SetWindowLongPtrW(self.hwnd.?, GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    // Initialize the core surface (terminal emulation + rendering)
    try self.initCoreSurface();
}

pub fn run(self: *App) !void {
    log.info("starting Win32 event loop", .{});

    while (self.running) {
        var msg: MSG = std.mem.zeroes(MSG);
        const ret = GetMessageW(&msg, null, 0, 0);
        if (ret == 0) {
            // WM_QUIT
            self.running = false;
            break;
        }
        if (ret == -1) {
            log.err("GetMessage failed", .{});
            return error.Win32Error;
        }
        _ = TranslateMessage(&msg);
        _ = DispatchMessageW(&msg);
    }
}

pub fn terminate(self: *App) void {
    self.surface.deinit();
    if (self.hwnd) |hwnd| {
        _ = DestroyWindow(hwnd);
        self.hwnd = null;
    }
    self.config.deinit();
    self.alloc.destroy(self.config);
}

pub fn wakeup(self: *App) void {
    if (self.hwnd) |hwnd| {
        _ = PostMessageW(hwnd, WM_WAKEUP, 0, 0);
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
            PostQuitMessage(0);
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
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyWindow");
    const hinstance = GetModuleHandleW(null);

    const wc: WNDCLASSEXW = .{
        .cbSize = @sizeOf(WNDCLASSEXW),
        .style = CS_HREDRAW | CS_VREDRAW | CS_OWNDC,
        .lpfnWndProc = wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = null,
        .hCursor = LoadCursorW(null, IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = class_name,
        .hIconSm = null,
    };

    if (RegisterClassExW(&wc) == 0) {
        log.err("RegisterClassEx failed", .{});
        return error.Win32Error;
    }

    const title = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");

    self.hwnd = CreateWindowExW(
        0,
        class_name,
        title,
        WS_OVERLAPPEDWINDOW,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        800,
        600,
        null,
        null,
        hinstance,
        null,
    );

    if (self.hwnd == null) {
        log.err("CreateWindowEx failed", .{});
        return error.Win32Error;
    }

    _ = ShowWindow(self.hwnd.?, SW_SHOWNORMAL);
    _ = UpdateWindow(self.hwnd.?);
}

fn getApp(hwnd: HWND) ?*App {
    const ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    if (ptr == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(ptr)));
}

fn mapVirtualKey(vk: WPARAM) @import("../../input.zig").Key {
    return switch (vk) {
        0x08 => .backspace, // VK_BACK
        0x09 => .tab, // VK_TAB
        0x0D => .enter, // VK_RETURN
        0x1B => .escape, // VK_ESCAPE
        0x20 => .space, // VK_SPACE
        0x25 => .arrow_left, // VK_LEFT
        0x26 => .arrow_up, // VK_UP
        0x27 => .arrow_right, // VK_RIGHT
        0x28 => .arrow_down, // VK_DOWN
        0x2E => .delete, // VK_DELETE
        0x24 => .home, // VK_HOME
        0x23 => .end, // VK_END
        0x21 => .page_up, // VK_PRIOR
        0x22 => .page_down, // VK_NEXT
        0x2D => .insert, // VK_INSERT
        0x70 => .f1,
        0x71 => .f2,
        0x72 => .f3,
        0x73 => .f4,
        0x74 => .f5,
        0x75 => .f6,
        0x76 => .f7,
        0x77 => .f8,
        0x78 => .f9,
        0x79 => .f10,
        0x7A => .f11,
        0x7B => .f12,
        else => .unidentified,
    };
}

fn wndProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    switch (msg) {
        WM_CLOSE => {
            PostQuitMessage(0);
            return 0;
        },
        WM_SIZE => {
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
        WM_PAINT => {
            var ps: PAINTSTRUCT = std.mem.zeroes(PAINTSTRUCT);
            _ = BeginPaint(hwnd, &ps);
            if (getApp(hwnd)) |app| {
                app.surface.swapBuffers();
            }
            _ = EndPaint(hwnd, &ps);
            return 0;
        },
        WM_CHAR => {
            if (getApp(hwnd)) |app| {
                if (app.surface.core_surface) |core| {
                    const codepoint: u21 = @intCast(wparam);
                    var utf8_buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch 0;
                    if (len > 0) {
                        const input = @import("../../input.zig");
                        const event = input.KeyEvent{
                            .action = .press,
                            .utf8 = utf8_buf[0..len],
                        };
                        _ = core.keyCallback(event) catch |err| {
                            log.err("key callback error: {}", .{err});
                        };
                    }
                }
            }
            return 0;
        },
        WM_KEYDOWN => {
            if (getApp(hwnd)) |app| {
                if (app.surface.core_surface) |core| {
                    const key = mapVirtualKey(wparam);
                    if (key != .unidentified) {
                        const input = @import("../../input.zig");
                        const event = input.KeyEvent{
                            .action = .press,
                            .key = key,
                        };
                        const effect = core.keyCallback(event) catch |err| {
                            log.err("key callback error: {}", .{err});
                            return 0;
                        };
                        // If the key was consumed, don't pass to TranslateMessage
                        if (effect == .consumed or effect == .closed) return 0;
                    }
                }
            }
            // Fall through to DefWindowProc so TranslateMessage generates WM_CHAR
            return DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        WM_WAKEUP => {
            if (getApp(hwnd)) |app| {
                app.core_app.tick(app) catch |err| {
                    log.err("core app tick failed: {}", .{err});
                };
            }
            return 0;
        },
        else => return DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
