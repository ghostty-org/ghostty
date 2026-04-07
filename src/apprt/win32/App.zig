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
extern "user32" fn GetKeyState(nVirtKey: c_int) callconv(.winapi) i16;
extern "user32" fn SetWindowTextW(hWnd: HWND, lpString: [*:0]const u16) callconv(.winapi) BOOL;
extern "user32" fn AdjustWindowRectEx(lpRect: *RECT, dwStyle: DWORD, bMenu: BOOL, dwExStyle: DWORD) callconv(.winapi) BOOL;
extern "user32" fn SetWindowPos(hWnd: HWND, hWndInsertAfter: ?HWND, x: i32, y: i32, cx: i32, cy: i32, uFlags: UINT) callconv(.winapi) BOOL;
extern "user32" fn GetDpiForWindow(hWnd: HWND) callconv(.winapi) UINT;
extern "user32" fn SetProcessDpiAwarenessContext(value: isize) callconv(.winapi) BOOL;
const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: isize = -4;

const COMPOSITIONFORM = extern struct {
    dwStyle: DWORD,
    ptCurrentPos: POINT,
    rcArea: RECT,
};

extern "imm32" fn ImmGetContext(hWnd: HWND) callconv(.winapi) ?*anyopaque;
extern "imm32" fn ImmReleaseContext(hWnd: HWND, hIMC: ?*anyopaque) callconv(.winapi) BOOL;
extern "imm32" fn ImmSetCompositionWindow(hIMC: ?*anyopaque, lpCompForm: *COMPOSITIONFORM) callconv(.winapi) BOOL;
extern "user32" fn SetCapture(hWnd: HWND) callconv(.winapi) ?HWND;
extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;

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

    // Enable Per-Monitor DPI awareness
    _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

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
    _ = target;

    switch (action) {
        .quit => {
            PostQuitMessage(0);
            return true;
        },
        .set_title => {
            if (self.hwnd) |hwnd| {
                const utf16 = std.unicode.utf8ToUtf16LeAllocZ(self.alloc, value.title) catch return false;
                defer self.alloc.free(utf16);
                _ = SetWindowTextW(hwnd, utf16.ptr);
            }
            return true;
        },
        .new_window => {
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

    // Resize window to match configured grid size using actual font metrics.
    // Like GTK, only resize when both window-width and window-height are set.
    self.applyConfiguredWindowSize();
}

fn applyConfiguredWindowSize(self: *App) void {
    const cfg_w = self.config.@"window-width";
    const cfg_h = self.config.@"window-height";
    if (cfg_w == 0 or cfg_h == 0) return;
    const hwnd = self.hwnd orelse return;
    const core = self.surface.core_surface orelse return;

    const cell_width = core.size.cell.width;
    const cell_height = core.size.cell.height;
    if (cell_width == 0 or cell_height == 0) return;

    const w: i32 = @intCast(@max(10, cfg_w) * cell_width);
    const h: i32 = @intCast(@max(4, cfg_h) * cell_height);

    // AdjustWindowRect to account for title bar and borders
    var rect: RECT = .{ .left = 0, .top = 0, .right = w, .bottom = h };
    _ = AdjustWindowRectEx(&rect, WS_OVERLAPPEDWINDOW, 0, 0);
    _ = SetWindowPos(hwnd, null, 0, 0, rect.right - rect.left, rect.bottom - rect.top, 0x0002 | 0x0004); // SWP_NOMOVE | SWP_NOZORDER
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

    // Get the actual client area size (excludes title bar and borders)
    var client_rect: RECT = std.mem.zeroes(RECT);
    if (GetClientRect(self.hwnd.?, &client_rect) != 0) {
        self.surface.width = @intCast(client_rect.right - client_rect.left);
        self.surface.height = @intCast(client_rect.bottom - client_rect.top);
    }
}

fn getApp(hwnd: HWND) ?*App {
    const ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    if (ptr == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(ptr)));
}

fn getModifiers() @import("../../input.zig").Mods {
    const input = @import("../../input.zig");
    var mods: input.Mods = .{};
    // High bit of GetKeyState return value indicates key is down
    if (GetKeyState(0x10) < 0) mods.shift = true; // VK_SHIFT
    if (GetKeyState(0x11) < 0) mods.ctrl = true; // VK_CONTROL
    if (GetKeyState(0x12) < 0) mods.alt = true; // VK_MENU
    if (GetKeyState(0x5B) < 0 or GetKeyState(0x5C) < 0) mods.super = true; // VK_LWIN/VK_RWIN
    return mods;
}

fn mapVirtualKey(vk: WPARAM) @import("../../input.zig").Key {
    return switch (vk) {
        // Letters A-Z (VK_A .. VK_Z)
        0x41 => .key_a, 0x42 => .key_b, 0x43 => .key_c, 0x44 => .key_d,
        0x45 => .key_e, 0x46 => .key_f, 0x47 => .key_g, 0x48 => .key_h,
        0x49 => .key_i, 0x4A => .key_j, 0x4B => .key_k, 0x4C => .key_l,
        0x4D => .key_m, 0x4E => .key_n, 0x4F => .key_o, 0x50 => .key_p,
        0x51 => .key_q, 0x52 => .key_r, 0x53 => .key_s, 0x54 => .key_t,
        0x55 => .key_u, 0x56 => .key_v, 0x57 => .key_w, 0x58 => .key_x,
        0x59 => .key_y, 0x5A => .key_z,
        // Digits 0-9
        0x30 => .digit_0, 0x31 => .digit_1, 0x32 => .digit_2, 0x33 => .digit_3,
        0x34 => .digit_4, 0x35 => .digit_5, 0x36 => .digit_6, 0x37 => .digit_7,
        0x38 => .digit_8, 0x39 => .digit_9,
        // Special keys
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
        // Modifier keys
        0x10 => .shift_left, // VK_SHIFT
        0x11 => .control_left, // VK_CONTROL
        0x12 => .alt_left, // VK_MENU
        // Punctuation
        0xBD => .minus, // VK_OEM_MINUS
        0xBB => .equal, // VK_OEM_PLUS (= key)
        0xDB => .bracket_left, // VK_OEM_4
        0xDD => .bracket_right, // VK_OEM_6
        0xDC => .backslash, // VK_OEM_5
        0xBA => .semicolon, // VK_OEM_1
        0xDE => .quote, // VK_OEM_7
        0xBC => .comma, // VK_OEM_COMMA
        0xBE => .period, // VK_OEM_PERIOD
        0xBF => .slash, // VK_OEM_2
        // 0xC0 => grave/backtick not in Key enum
        // Function keys
        0x70 => .f1, 0x71 => .f2, 0x72 => .f3, 0x73 => .f4,
        0x74 => .f5, 0x75 => .f6, 0x76 => .f7, 0x77 => .f8,
        0x78 => .f9, 0x79 => .f10, 0x7A => .f11, 0x7B => .f12,
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
            // Validate the window to prevent continuous WM_PAINT messages.
            // Actual rendering is done by the renderer thread via SwapBuffers.
            var ps: PAINTSTRUCT = std.mem.zeroes(PAINTSTRUCT);
            _ = BeginPaint(hwnd, &ps);
            _ = EndPaint(hwnd, &ps);
            return 0;
        },
        WM_CHAR => {
            if (getApp(hwnd)) |app| {
                if (app.surface.core_surface) |core| {
                    const mods = getModifiers();
                    const codepoint: u21 = @intCast(wparam);
                    // Skip control characters — they are already handled
                    // via WM_KEYDOWN (backspace, tab, enter, escape, Ctrl+letter).
                    if (codepoint < 0x20 or codepoint == 0x7f) return 0;
                    var utf8_buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch 0;
                    if (len > 0) {
                        const input = @import("../../input.zig");
                        const event = input.KeyEvent{
                            .action = .press,
                            .mods = mods,
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
        WM_KEYDOWN, 0x0104 => { // WM_KEYDOWN, WM_SYSKEYDOWN
            if (getApp(hwnd)) |app| {
                if (app.surface.core_surface) |core| {
                    const mods = getModifiers();
                    const key = mapVirtualKey(wparam);
                    if (key != .unidentified) {
                        const input = @import("../../input.zig");
                        const event = input.KeyEvent{
                            .action = .press,
                            .key = key,
                            .mods = mods,
                        };
                        const effect = core.keyCallback(event) catch |err| {
                            log.err("key callback error: {}", .{err});
                            return 0;
                        };
                        if (effect == .consumed or effect == .closed) return 0;
                    }
                }
            }
            // Fall through to DefWindowProc so TranslateMessage generates WM_CHAR
            return DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        0x0200 => { // WM_MOUSEMOVE
            if (getApp(hwnd)) |app| {
                if (app.surface.core_surface) |core| {
                    const x: f32 = @floatFromInt(@as(i16, @truncate(lparam & 0xFFFF)));
                    const y: f32 = @floatFromInt(@as(i16, @truncate((lparam >> 16) & 0xFFFF)));
                    core.cursorPosCallback(.{ .x = x, .y = y }, getModifiers()) catch {};
                }
            }
            return 0;
        },
        0x0201, 0x0204, 0x0207 => { // WM_LBUTTONDOWN, WM_RBUTTONDOWN, WM_MBUTTONDOWN
            if (getApp(hwnd)) |app| {
                if (app.surface.core_surface) |core| {
                    const input = @import("../../input.zig");
                    const button: input.MouseButton = switch (msg) {
                        0x0201 => .left,
                        0x0204 => .right,
                        0x0207 => .middle,
                        else => .unknown,
                    };
                    _ = core.mouseButtonCallback(.press, button, getModifiers()) catch false;
                    _ = SetCapture(hwnd);
                }
            }
            return 0;
        },
        0x0202, 0x0205, 0x0208 => { // WM_LBUTTONUP, WM_RBUTTONUP, WM_MBUTTONUP
            if (getApp(hwnd)) |app| {
                if (app.surface.core_surface) |core| {
                    const input = @import("../../input.zig");
                    const button: input.MouseButton = switch (msg) {
                        0x0202 => .left,
                        0x0205 => .right,
                        0x0208 => .middle,
                        else => .unknown,
                    };
                    _ = core.mouseButtonCallback(.release, button, getModifiers()) catch false;
                    _ = ReleaseCapture();
                }
            }
            return 0;
        },
        0x020A => { // WM_MOUSEWHEEL
            if (getApp(hwnd)) |app| {
                if (app.surface.core_surface) |core| {
                    const delta: i16 = @truncate(@as(isize, @bitCast(wparam)) >> 16);
                    const yoff: f64 = @as(f64, @floatFromInt(delta)) / 120.0;
                    const input = @import("../../input.zig");
                    core.scrollCallback(0, yoff, input.ScrollMods{}) catch {};
                }
            }
            return 0;
        },
        0x010D => { // WM_IME_STARTCOMPOSITION
            if (getApp(hwnd)) |app| {
                if (app.surface.core_surface) |core| {
                    // Get cursor position in raw pixels (no DPI scaling)
                    core.renderer_state.mutex.lock();
                    const cursor = core.renderer_state.terminal.screens.active.cursor;
                    core.renderer_state.mutex.unlock();
                    const x: i32 = @intCast(cursor.x * core.size.cell.width + core.size.padding.left);
                    const y: i32 = @intCast(cursor.y * core.size.cell.height + core.size.padding.top);

                    const himc = ImmGetContext(hwnd);
                    if (himc) |ctx| {
                        defer _ = ImmReleaseContext(hwnd, ctx);
                        var cf = COMPOSITIONFORM{
                            .dwStyle = 0x0002, // CFS_POINT
                            .ptCurrentPos = .{ .x = x, .y = y },
                            .rcArea = std.mem.zeroes(RECT),
                        };
                        _ = ImmSetCompositionWindow(ctx, &cf);
                    }
                }
            }
            return DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        0x0007, 0x0008 => { // WM_SETFOCUS, WM_KILLFOCUS
            if (getApp(hwnd)) |app| {
                const focused = msg == 0x0007;
                app.core_app.focusEvent(focused);
                if (app.surface.core_surface) |core| {
                    core.focusCallback(focused) catch {};
                }
            }
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
        else => return DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
