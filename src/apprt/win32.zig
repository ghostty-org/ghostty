//! Application Runtime for Native Windows

const std = @import("std");

const opengl = @import("opengl");

const win32 = struct {
    usingnamespace @import("zigwin32").everything;
    usingnamespace @import("zigwin32").zig;
};

pub fn panic(msg: []const u8, trace: ?*std.builtin.StackTrace, addr: ?usize) noreturn {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    if (arena.allocator().dupeZ(u8, msg)) |msg_z| {
        _ = win32.MessageBoxA(null, msg_z, "Ghostty Panic", win32.MB_OK);
    } else |_| {
        _ = win32.MessageBoxA(null, "Out of memory", "Ghostty Panic", win32.MB_OK);
    }
    std.builtin.default_panic(msg, trace, addr);
}

// contains declarations that need to be fixed in zigwin32
const win32fix = struct {
    pub extern "user32" fn LoadImageW(
        hInst: ?win32.HINSTANCE,
        name: ?[*:0]align(1) const u16,
        type: win32.GDI_IMAGE_TYPE,
        cx: i32,
        cy: i32,
        flags: win32.IMAGE_FLAGS,
    ) callconv(windows.WINAPI) ?win32.HANDLE;
    pub extern "user32" fn LoadCursorW(
        hInstance: ?win32.HINSTANCE,
        lpCursorName: ?[*:0]align(1) const u16,
    ) callconv(windows.WINAPI) ?win32.HCURSOR;
};

const c = @cImport({
    @cInclude("GhosttyResourceNames.h");
});

const HWND = win32.HWND;
const HDC = win32.HDC;
const HICON = win32.HICON;

const CoreApp = @import("../App.zig");
const Config = @import("../config.zig").Config;
const CoreSurface = @import("../Surface.zig");
const apprt = @import("../apprt.zig");
const input = @import("../input.zig");
const terminal = @import("../terminal/main.zig");
const configpkg = @import("../config.zig");

const windows = std.os.windows;

const Utf8To16 = std.unicode.utf8ToUtf16LeStringLiteral;

const log = std.log.scoped(.win32);

pub const App = struct {
    app: *CoreApp,
    config: Config,

    // only used for sanity checks
    thread_id: u32,

    // An application-wide Message-Only Window that will take care of calling app.tick.
    //
    // Note that we don't do this with bare "thread messages" because modal APIs like
    // ShellExecute won't be able to route those messages and will result in dropping them.
    // see https://devblogs.microsoft.com/oldnewthing/20050426-18/?p=35783
    hwnd: HWND,

    pub const Options = struct {};

    const WND_CLASS_NAME = Utf8To16("AppMessageOnly");
    pub fn initStable(app: *App, core_app: *CoreApp, _: Options) !void {
        {
            const wc = win32.WNDCLASSEXW{
                .cbSize = @intCast(@sizeOf(win32.WNDCLASSEXW)),
                .style = .{},
                .lpfnWndProc = AppWndProc,
                .cbClsExtra = 0,
                .cbWndExtra = @sizeOf(usize),
                .hInstance = win32.GetModuleHandleW(null),
                .hIcon = null,
                .hCursor = null,
                .hbrBackground = null,
                .lpszMenuName = null,
                .lpszClassName = WND_CLASS_NAME,
                .hIconSm = null,
            };
            if (0 == win32.RegisterClassExW(&wc))
                panicLastMessage("RegisterClassEx for app window failed");
        }
        const hwnd = win32.CreateWindowExW(
            .{}, // ex style
            WND_CLASS_NAME,
            null,
            .{}, // style
            0,
            0, // position
            0,
            0, // size
            win32.HWND_MESSAGE, // parent window
            null, // menu bar
            null, // hInstance
            app,
        ) orelse panicLastMessage("CreateWindow for the app window failed");

        var config = try Config.load(core_app.alloc);
        errdefer config.deinit();

        // Queue a single new window that starts on launch
        _ = core_app.mailbox.push(.{
            .new_window = .{},
        }, .{ .forever = {} });
        app.* = .{
            .app = core_app,
            .config = config,
            .thread_id = win32.GetCurrentThreadId(),
            .hwnd = hwnd,
        };
    }

    /// Doesn't return until the app has exited
    pub fn run(app: *App) !void {
        app.wakeup();
        // WARNING:
        // Be careful about modifying this loop because it can be circumvented
        // by modal APIs that won't have modifications made here.
        // You can use the message-only app window for app-level customizations.
        while (true) {
            var msg: win32.MSG = undefined;
            if (0 == win32.GetMessageW(&msg, null, 0, 0))
                break;
            _ = win32.TranslateMessage(&msg);
            _ = win32.DispatchMessageW(&msg);
        }
    }

    pub fn terminate(app: *App) void {
        app.config.deinit();
        if (0 == win32.DestroyWindow(app.hwnd))
            panicLastMessage("DestroyWindow failed");
        if (0 == win32.UnregisterClassW(WND_CLASS_NAME, win32.GetModuleHandleW(null)))
            panicLastMessage("UnregisterClass failed");
    }

    pub fn newWindow(app: *App, parent_: ?*CoreSurface) !void {
        _ = try app.newSurface(parent_);
    }

    fn newSurface(app: *App, _: ?*CoreSurface) !*Surface {
        // Grab a surface allocation because we're going to need it.
        var surface = try app.app.alloc.create(Surface);
        errdefer app.app.alloc.destroy(surface);

        // Create the surface -- because windows are surfaces for glfw.
        try surface.init(app);
        errdefer surface.deinit();

        return surface;
    }

    pub fn closeSurface(app: *App, surface: *Surface) void {
        surface.deinit();
        app.app.alloc.destroy(surface);
    }

    pub fn redrawSurface(app: *App, surface: *Surface) void {
        if (win32.GetCurrentThreadId() != app.thread_id) @panic("codebug");
        const hwnd = surface.maybe_hwnd orelse return;
        if (0 == win32.InvalidateRect(hwnd, null, 0))
            panicLastMessage("InvalidateRect failed");
    }

    pub fn redrawInspector(app: *App, surface: *Surface) void {
        _ = app;
        _ = surface;

        // Win32 doesn't support the inspector
    }

    pub fn reloadConfig(app: *App) !?*const Config {
        // Load our configuration
        var config = try Config.load(app.app.alloc);
        errdefer config.deinit();

        // Update the existing config, be sure to clean up the old one.
        app.config.deinit();
        app.config = config;

        return &app.config;
    }

    /// Open the configuration in the system editor.
    pub fn openConfig(app: *App) !void {
        try configpkg.edit.open(app.app.alloc);
    }

    /// Wakeup the event loop. This should be able to be called from any thread.
    pub fn wakeup(app: *const App) void {
        if (0 == win32.PostMessageW(app.hwnd, WM_GHOSTTY_WAKEUP, 0, 0))
            panicLastMessage("PostMessage for app tick failed");
    }
};

const WM_GHOSTTY_WAKEUP = win32.WM_USER + 0;

fn AppWndProc(
    hwnd: HWND,
    uMsg: u32,
    wParam: win32.WPARAM,
    lParam: win32.LPARAM,
) callconv(windows.WINAPI) win32.LRESULT {
    switch (uMsg) {
        win32.WM_CREATE => {
            const data: *win32.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lParam)));
            if (0 != setWindowLongPtr(hwnd, 0, @intFromPtr(data.lpCreateParams))) unreachable;
            return 0;
        },
        WM_GHOSTTY_WAKEUP => {
            const app: *App = @ptrFromInt(getWindowLongPtr(hwnd, 0));
            const should_quit = app.app.tick(app) catch |err|
                std.debug.panic("app tick failed with {s}", .{@errorName(err)});
            if (should_quit or app.app.surfaces.items.len == 0) {
                win32.PostQuitMessage(0);
            }
        },
        else => {},
    }
    return win32.DefWindowProcW(hwnd, uMsg, wParam, lParam);
}

pub const Surface = struct {
    maybe_hwnd: ?HWND = null,
    hdc: HDC,
    hglrc: win32.HGLRC,

    app: *App,

    core_surface: CoreSurface,

    pub const opengl_single_threaded_draw = true;

    const WND_CLASS_NAME = Utf8To16("Ghostty");

    pub fn init(surface: *Surface, app: *App) !void {
        const icons = getIcons();

        var wc = win32.WNDCLASSEXW{
            .cbSize = @sizeOf(win32.WNDCLASSEXW),
            .style = win32.CS_OWNDC,
            .lpfnWndProc = SurfaceWndProc,
            .cbClsExtra = 0,
            .cbWndExtra = @sizeOf(usize),
            .hInstance = win32.GetModuleHandleW(null),
            .hIcon = icons.large,
            .hCursor = win32fix.LoadCursorW(null, win32.IDC_ARROW),
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = WND_CLASS_NAME,
            .hIconSm = icons.small,
        };

        if (0 == win32.RegisterClassExW(&wc))
            panicLastMessage("Failed to Register Class");

        const hwnd = win32.CreateWindowExW(
            .{},
            WND_CLASS_NAME,
            Utf8To16("Ghostty"),
            win32.WS_OVERLAPPEDWINDOW,
            win32.CW_USEDEFAULT,
            win32.CW_USEDEFAULT, // position
            640,
            480,
            null, // Parent window
            null, // Menu
            win32.GetModuleHandleW(null),
            surface,
        ) orelse panicLastMessage("Failed to create Window");
        errdefer if (0 == win32.DestroyWindow(hwnd)) panicLastMessage("DestroyWindow failed");

        const pfd = win32.PIXELFORMATDESCRIPTOR{
            .nSize = @sizeOf(win32.PIXELFORMATDESCRIPTOR),
            .nVersion = 1,
            .dwFlags = win32.PFD_FLAGS{
                .DRAW_TO_WINDOW = 1,
                .SUPPORT_OPENGL = 1,
                .DOUBLEBUFFER = 1,
            },
            .iPixelType = .RGBA,
            .cColorBits = 32,
            .cRedBits = 0,
            .cRedShift = 0,
            .cGreenBits = 0,
            .cGreenShift = 0,
            .cBlueBits = 0,
            .cBlueShift = 0,
            .cAlphaBits = 8,
            .cAlphaShift = 0,
            .cAccumBits = 0,
            .cAccumRedBits = 0,
            .cAccumGreenBits = 0,
            .cAccumBlueBits = 0,
            .cAccumAlphaBits = 0,
            .cDepthBits = 24,
            .cStencilBits = 0,
            .cAuxBuffers = 0,
            .iLayerType = .MAIN_PLANE,
            .bReserved = 0,
            .dwLayerMask = 0,
            .dwVisibleMask = 0,
            .dwDamageMask = 0,
        };
        const hdc = win32.GetDC(hwnd) orelse
            apprt.win32.panicLastMessage("GetDC failed");
        // do not release hdc because of CS_OWNDC
        const pixel_format = win32.ChoosePixelFormat(hdc, &pfd);
        if (pixel_format == 0)
            panicLastMessage("ChoosePixelFormat failed");
        if (0 == win32.SetPixelFormat(hdc, pixel_format, &pfd))
            panicLastMessage("SetPixelFormat failed");
        const hglrc = win32.wglCreateContext(hdc) orelse
            panicLastMessage("wglCreateContext failed");
        if (0 == win32.wglMakeCurrent(hdc, hglrc))
            panicLastMessage("Failed to make OpenGL context current");

        const version = try opengl.glad.load(null);
        errdefer opengl.glad.unload();
        log.info("loaded OpenGL {}.{}", .{
            opengl.glad.versionMajor(@intCast(version)),
            opengl.glad.versionMinor(@intCast(version)),
        });

        surface.* = .{
            .maybe_hwnd = hwnd,
            .hdc = hdc,
            .hglrc = hglrc,
            .app = app,
            .core_surface = undefined,
        };

        // Add ourselves to the list of surfaces on the app.
        try app.app.addSurface(surface);
        errdefer app.app.deleteSurface(surface);

        // Get our new surface config
        var config = try apprt.surface.newConfig(app.app, &app.config);
        defer config.deinit();

        // Initialize our surface now that we have the stable pointer.
        try surface.core_surface.init(
            app.app.alloc,
            &config,
            app.app,
            app,
            surface,
        );
        errdefer surface.core_surface.deinit();

        _ = win32.UpdateWindow(hwnd);
        _ = win32.ShowWindow(hwnd, win32.SW_SHOWDEFAULT);
        _ = win32.SetForegroundWindow(hwnd);
        _ = win32.SetFocus(hwnd);
    }

    pub fn deinit(surface: *Surface) void {
        // Remove ourselves from the list of known surfaces in the app.
        surface.app.app.deleteSurface(surface);

        // Clean up our core surface so that all the rendering and IO stop.
        surface.core_surface.deinit();

        if (0 == win32.wglMakeCurrent(surface.hdc, null))
            panicLastMessage("wglMakeCurrent failed");
        if (0 == win32.wglDeleteContext(surface.hglrc))
            panicLastMessage("wglDeleteContext failed");
        // do not release surface.hdc because of CS_OWNDC
        if (surface.maybe_hwnd) |hwnd| {
            if (0 == win32.DestroyWindow(hwnd))
                panicLastMessage("DestroyWindow failed");
            surface.maybe_hwnd = null;
        }
        if (0 == win32.UnregisterClassW(WND_CLASS_NAME, win32.GetModuleHandleW(null)))
            panicLastMessage("UnregisterClass failed");
    }

    pub fn shouldClose(surface: *Surface) bool {
        return surface.maybe_hwnd == null;
    }

    pub fn setShouldClose(surface: *Surface) void {
        if (surface.maybe_hwnd) |hwnd| {
            if (0 == win32.DestroyWindow(hwnd)) panicLastMessage("DestroyWindow failed");
            surface.maybe_hwnd = null;
        }
    }

    pub fn close(surface: *Surface, _: bool) void {
        surface.setShouldClose();
        surface.deinit();
        surface.app.app.alloc.destroy(surface);
    }

    pub fn setTitle(surface: *Surface, title: [:0]const u8) !void {
        if (surface.maybe_hwnd) |hwnd| {
            if (0 == win32.SetWindowTextA(hwnd, title))
                panicLastMessage("Failed to set window title");
        }
    }

    /// Set the visibility of the mouse cursor.
    pub fn setMouseVisibility(self: *Surface, visible: bool) void {
        _ = self;
        _ = visible;

        // Does nothing on Win32
    }

    pub fn setMouseShape(self: *Surface, shape: terminal.MouseShape) !void {
        _ = self;
        const id: ?[*:0]align(1) const u16 = switch (shape) {
            else => null,
        };
        log.info("mouse shape {s} {}", .{ @tagName(shape), @intFromPtr(id) });
        if (true) @panic("todo: this is not getting called yet, not sure why?");
        // TODO: we probably need to verify the cursor is inside our client area
        //       before calling SetCurso
        _ = win32.SetCursor(win32fix.LoadCursorW(null, id));
    }

    /// Set the cell size. Unused by Win32.
    pub fn setCellSize(self: *const Surface, width: u32, height: u32) !void {
        _ = self;
        _ = width;
        _ = height;
    }

    /// Start an async clipboard request.
    pub fn clipboardRequest(
        self: *Surface,
        clipboard_type: apprt.Clipboard,
        request: apprt.ClipboardRequest,
    ) !void {
        _ = self;
        log.warn("TODO: implement clipboard request type={s} request={s}!", .{
            @tagName(clipboard_type),
            @tagName(request),
        });
    }

    pub fn setClipboardString(
        self: *const Surface,
        val: [:0]const u8,
        clipboard_type: apprt.Clipboard,
        confirm: bool,
    ) !void {
        _ = self;
        _ = clipboard_type;

        if (confirm) @panic("todo: setClipboardString confirm");

        if (0 == win32.OpenClipboard(null))
            panicLastMessage("OpenClipboard failed");
        defer if (0 == win32.CloseClipboard())
            panicLastMessage("CloseClipboard failed");
        if (0 == win32.EmptyClipboard())
            panicLastMessage("EmptyClipboard failed");
        const hmem = win32.GlobalAlloc(.{ .MEM_MOVEABLE = 1 }, val.len + 1);
        if (hmem == 0) panicLastMessage("GlobalAlloc failed");

        var hmem_owned = true;
        defer if (hmem_owned) {
            if (0 == win32.GlobalFree(hmem))
                panicLastMessage("GlobalFree failed");
        };

        {
            const mem = win32.GlobalLock(hmem);
            defer if (0 != win32.GlobalUnlock(hmem))
                panicLastMessage("GlobalUnlock failed");
            @memcpy(@as([*]u8, @ptrCast(mem)), val);
            @as([*]u8, @ptrCast(mem))[val.len] = 0;
        }

        // TODO: do we need to close this handle?
        _ = win32.SetClipboardData(
            @intFromEnum(win32.CF_TEXT),
            @ptrFromInt(@as(usize, @bitCast(hmem))),
        ) orelse panicLastMessage("SetClipboardData failed");

        hmem_owned = false; // ownership transferred to the system
    }

    /// Returns the content scale for the created window.
    pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
        _ = self;

        // TODO: use GetDpiForWindow
        //       note that the DPI can change, use WM_DPICHANGED
        //       to get notified of this and WM_GETDPISCALEDSIZE to
        //       control the window size change before it changes.
        return .{
            .x = 1.0,
            .y = 1.0,
        };
    }

    pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
        const hwnd = self.maybe_hwnd orelse return .{ .width = 0, .height = 0 };
        var rect: win32.RECT = undefined;
        if (0 == win32.GetClientRect(hwnd, &rect))
            panicLastMessage("GetClientRect failed");
        return .{
            .width = @intCast(rect.right - rect.left),
            .height = @intCast(rect.bottom - rect.top),
        };
    }

    /// Returns the cursor position in scaled pixels relative to the
    /// upper-left of the window.
    pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
        const hwnd = self.maybe_hwnd orelse {
            log.warn("getCursorPos called after window destroyed", .{});
            return .{ .x = 0, .y = 0 };
        };

        var pt: win32.POINT = undefined;
        if (0 == win32.GetCursorPos(&pt))
            panicLastMessage("GetCursorPos failed");
        if (0 == win32.ScreenToClient(hwnd, &pt))
            panicLastMessage("ScreenToClient failed");
        log.info("getCursorPos {}x{}", .{ pt.x, pt.y });
        return .{
            .x = @floatFromInt(pt.x),
            .y = @floatFromInt(pt.y),
        };
    }

    pub fn setSizeLimits(self: *Surface, min: apprt.SurfaceSize, max_: ?apprt.SurfaceSize) !void {
        _ = self;
        _ = min;
        _ = max_;

        // TODO
    }

    /// Set the initial window size. This is called exactly once at
    /// surface initialization time. This may be called before "self"
    /// is fully initialized.
    pub fn setInitialWindowSize(self: *const Surface, width: u32, height: u32) !void {
        const hwnd = self.maybe_hwnd orelse return;
        if (0 == win32.SetWindowPos(
            hwnd,
            null,
            0,
            0,
            @intCast(width),
            @intCast(height),
            win32.SET_WINDOW_POS_FLAGS{
                .NOACTIVATE = 1,
                .NOZORDER = 1,
                .NOMOVE = 1,
            },
        ))
            panicLastMessage("SetWindowPos failed");
    }
};

fn setWindowLongPtr(hwnd: HWND, index: usize, value: usize) usize {
    return @bitCast(win32.SetWindowLongPtrW(hwnd, @enumFromInt(index), @bitCast(value)));
}
fn getWindowLongPtr(hwnd: HWND, index: usize) usize {
    return @as(usize, @bitCast(win32.GetWindowLongPtrW(hwnd, @enumFromInt(index))));
}

// TODO: add this to zig.zig in zigwin32
fn LOWORD(value: anytype) u16 {
    return @intCast(value & 0xffff);
}
fn HIWORD(value: anytype) u16 {
    return @intCast((value >> 16) & 0xffff);
}

fn keyState(keyboard_state: *const [256]u8, vk: win32.VIRTUAL_KEY) u8 {
    return keyboard_state[@intFromEnum(vk)];
}

fn modsFromKeyboardState(keyboard_state: *const [256]u8) input.Mods {
    var mods = input.Mods{};
    if (0 != (0x80 & keyState(keyboard_state, .SHIFT))) mods.shift = true;
    if (0 != (0x80 & keyState(keyboard_state, .CONTROL))) mods.ctrl = true;
    if (0 != (0x80 & keyState(keyboard_state, .MENU))) mods.alt = true;
    if (0 != (0x80 & keyState(keyboard_state, .SHIFT))) mods.shift = true;
    if ((0 != (0x80 & keyState(keyboard_state, .LWIN))) or
        (0 != (0x80 & keyState(keyboard_state, .RWIN)))) mods.super = true;
    if (0 != (0x01 & keyState(keyboard_state, .CAPITAL))) mods.caps_lock = true;
    if (0 != (0x01 & keyState(keyboard_state, .NUMLOCK))) mods.num_lock = true;
    return mods;
}

fn numberKeySymbol(number: u4) u8 {
    return switch (number) {
        0 => ')',
        1 => '!',
        2 => '@',
        3 => '#',
        4 => '$',
        5 => '%',
        6 => '^',
        7 => '&',
        8 => '*',
        9 => '(',
        else => unreachable,
    };
}

fn wmKey(hwnd: HWND, wParam: win32.WPARAM, lParam: win32.LPARAM, action: input.Action) void {
    _ = lParam;
    // TODO: get repeat count from lParam

    var keyboard_state: [256]u8 = undefined;
    if (0 == win32.GetKeyboardState(&keyboard_state))
        panicLastMessage("GetKeyboardState failed");

    const mods = modsFromKeyboardState(&keyboard_state);
    const info: struct { key: input.Key, utf8: []const u8 = "" } = blk: {
        switch (wParam) {
            @intFromEnum(win32.VK_BACK) => break :blk .{ .key = .backspace },
            @intFromEnum(win32.VK_TAB) => break :blk .{ .key = .tab },
            @intFromEnum(win32.VK_RETURN) => break :blk .{ .key = .enter },
            @intFromEnum(win32.VK_ESCAPE) => break :blk .{ .key = .escape },
            @intFromEnum(win32.VK_SPACE) => break :blk .{ .key = .space, .utf8 = " " },
            @intFromEnum(win32.VK_PRIOR) => break :blk .{ .key = .page_up },
            @intFromEnum(win32.VK_NEXT) => break :blk .{ .key = .page_down },
            @intFromEnum(win32.VK_END) => break :blk .{ .key = .end },
            @intFromEnum(win32.VK_HOME) => break :blk .{ .key = .home },
            @intFromEnum(win32.VK_LEFT) => break :blk .{ .key = .left },
            @intFromEnum(win32.VK_UP) => break :blk .{ .key = .up },
            @intFromEnum(win32.VK_RIGHT) => break :blk .{ .key = .right },
            @intFromEnum(win32.VK_DOWN) => break :blk .{ .key = .down },
            @intFromEnum(win32.VK_SNAPSHOT) => break :blk .{ .key = .print_screen },
            @intFromEnum(win32.VK_INSERT) => break :blk .{ .key = .insert },
            @intFromEnum(win32.VK_DELETE) => break :blk .{ .key = .delete },
            inline '0'...'9' => |vk| {
                const off = vk - '0';
                break :blk .{
                    .key = @enumFromInt(@intFromEnum(input.Key.zero) + off),
                    .utf8 = if (mods.shift) &.{ numberKeySymbol(off) } else &.{'0' + off},
                };
            },
            inline @intFromEnum(win32.VK_A)...@intFromEnum(win32.VK_Z) => |vk| {
                const off = vk - @intFromEnum(win32.VK_A);
                break :blk .{
                    .key = @enumFromInt(@intFromEnum(input.Key.a) + off),
                    .utf8 = if (mods.shift or mods.caps_lock) &.{'A' + off} else &.{'a' + off},
                };
            },
            inline @intFromEnum(win32.VK_NUMPAD0)...@intFromEnum(win32.VK_NUMPAD9) => |vk| {
                const off = vk - @intFromEnum(win32.VK_NUMPAD0);
                break :blk .{
                    .key = @enumFromInt(@intFromEnum(input.Key.kp_0) + off),
                    .utf8 = if (mods.num_lock) &.{'0' + off} else "",
                };
            },
            @intFromEnum(win32.VK_MULTIPLY) => break :blk .{ .key = .kp_multiply },
            @intFromEnum(win32.VK_ADD) => break :blk .{ .key = .kp_add },
            @intFromEnum(win32.VK_SUBTRACT) => break :blk .{ .key = .kp_subtract },
            @intFromEnum(win32.VK_DECIMAL) => break :blk .{ .key = .kp_decimal },
            @intFromEnum(win32.VK_DIVIDE) => break :blk .{ .key = .kp_divide },
            inline @intFromEnum(win32.VK_F1)...@intFromEnum(win32.VK_F24) => |vk| {
                const off = vk - @intFromEnum(win32.VK_F1);
                break :blk .{
                    .key = @enumFromInt(@intFromEnum(input.Key.f1) + off),
                };
            },
            @intFromEnum(win32.VK_OEM_1) => break :blk .{
                .key = .semicolon,
                .utf8 = if (mods.shift) ":" else ";",
            },
            @intFromEnum(win32.VK_OEM_PLUS) => break :blk .{
                .key = if (mods.shift) .plus else .equal,
                .utf8 = if (mods.shift) "+" else "=",
            },
            @intFromEnum(win32.VK_OEM_COMMA) => break :blk .{
                .key = .comma,
                .utf8 = if (mods.shift) "<" else ",",
            },
            @intFromEnum(win32.VK_OEM_MINUS) => break :blk .{
                .key = .minus,
                .utf8 = if (mods.shift) "_" else "-",
            },
            @intFromEnum(win32.VK_OEM_PERIOD) => break :blk .{
                .key = .period,
                .utf8 = if (mods.shift) ">" else ".",
            },
            @intFromEnum(win32.VK_OEM_2) => break :blk .{
                .key = .slash,
                .utf8 = if (mods.shift) "?" else "/",
            },
            @intFromEnum(win32.VK_OEM_3) => break :blk .{
                .key = .grave_accent,
                .utf8 = if (mods.shift) "~" else "`",
            },
            @intFromEnum(win32.VK_OEM_4) => break :blk .{
                .key = .left_bracket,
                .utf8 = if (mods.shift) "{" else "[",
            },
            @intFromEnum(win32.VK_OEM_5) => break :blk .{
                .key = .backslash,
                .utf8 = if (mods.shift) "|" else "\\",
            },
            @intFromEnum(win32.VK_OEM_6) => break :blk .{
                .key = .right_bracket,
                .utf8 = if (mods.shift) "}" else "]",
            },
            @intFromEnum(win32.VK_OEM_7) => break :blk .{
                .key = .apostrophe,
                .utf8 = if (mods.shift) "\"" else "'",
            },
            else => {
                log.info("TODO: handle key VK_{s}({})", .{
                    std.enums.tagName(win32.VIRTUAL_KEY, @enumFromInt(LOWORD(wParam))) orelse "?",
                    wParam,
                });
                break :blk .{ .key = .invalid };
            },
        }
    };

    const surface: *Surface = @ptrFromInt(getWindowLongPtr(hwnd, 0));
    _ = surface.core_surface.keyCallback(.{
        .action = action,
        .key = info.key,
        .physical_key = info.key,
        .mods = mods,
        .utf8 = info.utf8,
    }) catch |err| std.debug.panic("keyCallback failed with {s}", .{@errorName(err)});
}

fn posFromLParam(lParam: win32.LPARAM) struct { x: i16, y: i16 } {
    return .{
        .x = @truncate(0xffff & lParam),
        .y = @truncate(0xffff & (lParam >> 16)),
    };
}
fn cursorPosFromLParamClient(lParam: win32.LPARAM) apprt.CursorPos {
    const pos = posFromLParam(lParam);
    //log.info("mouse move {}x{}", .{ pos.x, pos.y });
    return .{
        .x = @floatFromInt(pos.x),
        .y = @floatFromInt(pos.y),
    };
}
fn cursorPosFromLParamScreen(hwnd: HWND, lParam: win32.LPARAM) apprt.CursorPos {
    const pos_screen = posFromLParam(lParam);
    var pos_client = win32.POINT{
        .x = pos_screen.x,
        .y = pos_screen.y,
    };
    if (0 == win32.ScreenToClient(hwnd, &pos_client))
        panicLastMessage("ScreenToClient failed");
    //log.info("mouse move {}x{}", .{ pos_client.x, pos_client.y });
    return .{
        .x = @floatFromInt(pos_client.x),
        .y = @floatFromInt(pos_client.y),
    };
}

fn wmMouseButton(
    hwnd: HWND,
    lParam: win32.LPARAM,
    button: input.MouseButton,
    action: input.MouseButtonState,
) void {
    const surface: *Surface = @ptrFromInt(getWindowLongPtr(hwnd, 0));
    surface.core_surface.cursorPosCallback(
        cursorPosFromLParamClient(lParam),
    ) catch |err| std.debug.panic(
        "cursorPosCallback failed with {s}",
        .{@errorName(err)},
    );

    // TODO: could mouseButtonCallback be updated to not take
    //       mods so we don't have to get this info here?
    var keyboard_state: [256]u8 = undefined;
    if (0 == win32.GetKeyboardState(&keyboard_state))
        panicLastMessage("GetKeyboardState failed");
    const mods = modsFromKeyboardState(&keyboard_state);
    surface.core_surface.mouseButtonCallback(
        action,
        button,
        mods,
    ) catch |err| std.debug.panic(
        "mouseButtonCallback failed, error={s}",
        .{@errorName(err)},
    );
}

fn wmMouseWheel(
    hwnd: HWND,
    wParam: win32.WPARAM,
    lParam: win32.LPARAM,
    direction: enum { x, y },
) void {
    const surface: *Surface = @ptrFromInt(getWindowLongPtr(hwnd, 0));
    surface.core_surface.cursorPosCallback(
        cursorPosFromLParamScreen(hwnd, lParam),
    ) catch |err| std.debug.panic(
        "cursorPosCallback failed with {s}",
        .{@errorName(err)},
    );

    const delta: i16 = @bitCast(HIWORD(wParam));
    if (delta == 0) @panic("possible?");

    var x: f64 = 0;
    var y: f64 = 0;
    const val_ref: *f64 = switch (direction) {
        .x => &x,
        .y => &y,
    };
    val_ref.* = @floatFromInt(delta);
    surface.core_surface.scrollCallback(x, y, .{}) catch |err| std.debug.panic(
        "scrollCallback failed, error={s}",
        .{@errorName(err)},
    );
}

fn SurfaceWndProc(
    hwnd: HWND,
    uMsg: u32,
    wParam: win32.WPARAM,
    lParam: win32.LPARAM,
) callconv(windows.WINAPI) win32.LRESULT {
    switch (uMsg) {
        win32.WM_MOUSEMOVE => {
            const surface: *Surface = @ptrFromInt(getWindowLongPtr(hwnd, 0));
            surface.core_surface.cursorPosCallback(
                cursorPosFromLParamClient(lParam),
            ) catch |err| std.debug.panic(
                "cursorPosCallback failed with {s}",
                .{@errorName(err)},
            );
            return 0;
        },
        win32.WM_KEYDOWN => {
            wmKey(hwnd, wParam, lParam, .press);
            return 0;
        },
        win32.WM_KEYUP => {
            wmKey(hwnd, wParam, lParam, .release);
            return 0;
        },
        win32.WM_MOUSEWHEEL => {
            wmMouseWheel(hwnd, wParam, lParam, .y);
            return 0;
        },
        win32.WM_MOUSEHWHEEL => {
            wmMouseWheel(hwnd, wParam, lParam, .x);
            return 0;
        },
        win32.WM_LBUTTONDOWN => {
            wmMouseButton(hwnd, lParam, .left, .press);
            return 0;
        },
        win32.WM_LBUTTONUP => {
            wmMouseButton(hwnd, lParam, .left, .release);
            return 0;
        },
        win32.WM_RBUTTONDOWN => {
            wmMouseButton(hwnd, lParam, .right, .press);
            return 0;
        },
        win32.WM_RBUTTONUP => {
            wmMouseButton(hwnd, lParam, .right, .release);
            return 0;
        },
        win32.WM_ACTIVATE => {
            const focus: bool = switch (LOWORD(wParam)) {
                win32.WA_INACTIVE => false,
                win32.WA_ACTIVE, win32.WA_CLICKACTIVE => true,
                else => |state| std.debug.panic("unknown WM_ACTIVATE state {}", .{state}),
            };
            const surface: *Surface = @ptrFromInt(getWindowLongPtr(hwnd, 0));
            surface.core_surface.focusCallback(focus) catch |err| std.debug.panic(
                "focusCallback failed, error={s}",
                .{@errorName(err)},
            );
            return 0;
        },
        win32.WM_SIZE => {
            const surface: *Surface = @ptrFromInt(getWindowLongPtr(hwnd, 0));
            surface.core_surface.sizeCallback(.{
                .width = LOWORD(lParam),
                .height = HIWORD(lParam),
            }) catch |err| std.debug.panic("resize failed, error={s}", .{@errorName(err)});
            return 0;
        },
        win32.WM_PAINT => {
            const surface: *Surface = @ptrFromInt(getWindowLongPtr(hwnd, 0));
            var ps: win32.PAINTSTRUCT = undefined;
            const paint_hdc = win32.BeginPaint(hwnd, &ps);
            _ = paint_hdc;
            surface.core_surface.renderer.drawFrame(surface) catch |err| std.debug.panic(
                "renderer drawFrame failed, error={s}",
                .{@errorName(err)},
            );
            _ = win32.EndPaint(hwnd, &ps);
            return 0;
        },
        win32.WM_CREATE => {
            const data: *win32.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lParam)));
            if (0 != setWindowLongPtr(hwnd, 0, @intFromPtr(data.lpCreateParams))) unreachable;
            return 0;
        },
        win32.WM_DESTROY => {
            const surface: *Surface = @ptrFromInt(getWindowLongPtr(hwnd, 0));
            if (surface.maybe_hwnd != hwnd) unreachable;
            surface.maybe_hwnd = null;
            surface.app.wakeup();
            return 0;
        },
        else => {},
    }
    return win32.DefWindowProcW(hwnd, uMsg, wParam, lParam);
}

fn panicLastMessage(comptime msg: []const u8) noreturn {
    const err = win32.GetLastError();
    // 614 is the length of the longest windows error description
    var buf: [614:0]windows.WCHAR = undefined;
    const len = win32.FormatMessageW(
        .{ .FROM_SYSTEM = 1, .IGNORE_INSERTS = 1 },
        null,
        @intFromEnum(err),
        MAKELANGID(windows.LANG.NEUTRAL, windows.SUBLANG.DEFAULT),
        &buf,
        buf.len,
        null,
    );
    std.debug.panic(msg ++ ", error={d} ({})\n", .{
        @intFromEnum(err),
        std.unicode.fmtUtf16le(buf[0..len]),
    });
}

inline fn MAKELANGID(p: c_ushort, s: c_ushort) windows.LANGID {
    return (s << 10) | p;
}

const Icons = struct {
    small: ?HICON,
    large: ?HICON,
};
fn getIcons() Icons {
    const small_x = win32.GetSystemMetrics(.CXSMICON);
    const small_y = win32.GetSystemMetrics(.CYSMICON);
    const large_x = win32.GetSystemMetrics(.CXICON);
    const large_y = win32.GetSystemMetrics(.CYICON);
    const small = win32fix.LoadImageW(
        win32.GetModuleHandleW(null),
        @ptrFromInt(c.ID_ICON_GHOSTTY),
        .ICON,
        small_x,
        small_y,
        win32.LR_SHARED,
    );
    if (small == null) {
        log.err("LoadImage for small icon failed, error={}", .{win32.GetLastError()});
        // not a critical error
    }
    const large = win32fix.LoadImageW(
        win32.GetModuleHandleW(null),
        @ptrFromInt(c.ID_ICON_GHOSTTY),
        .ICON,
        large_x,
        large_y,
        win32.LR_SHARED,
    );
    if (large == null) {
        log.err("LoadImage for large icon failed, error={}", .{win32.GetLastError()});
        // not a critical error
    }
    return .{ .small = @ptrCast(small), .large = @ptrCast(large) };
}
