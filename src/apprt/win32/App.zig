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
const WM_PAINT = 0x000F;
const WM_USER = 0x0400;
const WM_WAKEUP = WM_USER + 1;
const CS_HREDRAW = 0x0002;
const CS_VREDRAW = 0x0001;
const CS_OWNDC = 0x0020;
const WS_OVERLAPPEDWINDOW = 0x00CF0000;
const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));
const SW_SHOWNORMAL = 1;
const IDC_ARROW: ?[*:0]align(1) const u16 = @ptrFromInt(32512);

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

pub fn redrawInspector(_: *App, _: *Surface) void {}

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

fn wndProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    switch (msg) {
        WM_CLOSE => {
            PostQuitMessage(0);
            return 0;
        },
        WM_PAINT => {
            var ps: PAINTSTRUCT = std.mem.zeroes(PAINTSTRUCT);
            _ = BeginPaint(hwnd, &ps);
            // TODO: render via OpenGL
            _ = EndPaint(hwnd, &ps);
            return 0;
        },
        WM_WAKEUP => {
            // Wakeup from core app
            return 0;
        },
        else => return DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
