//! Application Runtime for Native Windows

const std = @import("std");

const glfw = @import("glfw");
const opengl = @import("opengl");

const zigwin32 = @import("zigwin32");
const win32 = zigwin32.everything;

const HINSTANCE = win32.HINSTANCE;

const CoreApp = @import("../App.zig");
const Config = @import("../config.zig").Config;
const CoreSurface = @import("../Surface.zig");
const apprt = @import("../apprt.zig");
const terminal = @import("../terminal/main.zig");
const configpkg = @import("../config.zig");

const windows = std.os.windows;

const Utf8To16 = std.unicode.utf8ToUtf16LeStringLiteral;

const log = std.log.scoped(.win32);

pub const App = struct {
    app: *CoreApp,
    config: Config,

    hInst: HINSTANCE,

    pub const Options = struct {};

    pub fn init(core_app: *CoreApp, _: Options) !App {
        // Load our configuration
        var config = try Config.load(core_app.alloc);
        errdefer config.deinit();

        // Queue a single new window that starts on launch
        _ = core_app.mailbox.push(.{
            .new_window = .{},
        }, .{ .forever = {} });

        return .{
            .app = core_app,
            .config = config,
            .hInst = win32.GetModuleHandleW(null) orelse {
                panicLastMessage("Failed to get module handle");
            },
        };
    }

    // /// Doesn't return until the app has exited
    pub fn run(app: *App) !void {
        while (true) {
            // Input stuff

            const should_quit = try app.app.tick(app);
            if (should_quit or app.app.surfaces.items.len != 0) {
                for (app.app.surfaces.items) |surface| {
                    surface.close(false);
                }

                return;
            }
        }
    }

    pub fn terminate(app: *App) void {
        app.config.deinit();
    }

    /// Create a new window for the app.
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

    /// Close the given surface.
    pub fn closeSurface(app: *App, surface: *Surface) void {
        surface.deinit();
        app.app.alloc.destroy(surface);
    }

    pub fn redrawSurface(app: *App, surface: *Surface) void {
        _ = app;
        _ = surface;

        @panic("This should never be called for WIN32.");
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
        _ = app;
        // Does nothing. Later we will post an empty event here

    }
};

pub const Surface = struct {
    // Window Handles
    hwnd: win32.HWND,
    hdc: win32.HDC,
    hglrc: win32.HGLRC,

    /// The app we're part of
    app: *App,

    core_surface: CoreSurface,

    pub fn init(surface: *Surface, app: *App) !void {
        const GhosttyClassName = Utf8To16("GhosttyWindowClass");

        // Register the window class
        var wc = win32.WNDCLASSEXW{
            .cbSize = @intCast(@sizeOf(win32.WNDCLASSEXW)),
            .style = @enumFromInt(1 | 2),
            .lpfnWndProc = win32.DefWindowProcW,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = app.hInst,
            .hIcon = null,
            .hCursor = null,
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = GhosttyClassName.ptr,
            .hIconSm = null,
        };

        const atom = win32.RegisterClassExW(&wc);
        if (atom == 0) {
            panicLastMessage("Failed to Register Class");
        }

        const GhosttyWindowName = Utf8To16("Ghostty");

        // Create the window
        const hwnd = win32.CreateWindowExW(
            win32.WS_EX_NOREDIRECTIONBITMAP,

            GhosttyClassName.ptr,
            GhosttyWindowName.ptr,

            win32.WS_OVERLAPPEDWINDOW,

            // Size and position
            win32.CW_USEDEFAULT,
            win32.CW_USEDEFAULT,
            win32.CW_USEDEFAULT,
            win32.CW_USEDEFAULT,

            null, // Parent window
            null, // Menu
            app.hInst,
            null, // lpParam
        ) orelse panicLastMessage("Failed to create Window");

        // Create the pixel format descriptor
        const pfd: win32.PIXELFORMATDESCRIPTOR = .{
            .nSize = @intCast(@sizeOf(win32.PIXELFORMATDESCRIPTOR)),
            .nVersion = 1,
            .dwFlags = win32.PFD_FLAGS.initFlags(
                .{
                    .DRAW_TO_WINDOW = 1,
                    .SUPPORT_OPENGL = 1,
                    .DOUBLEBUFFER = 1,
                },
            ),
            .iPixelType = win32.PFD_TYPE_RGBA,
            .cColorBits = 16,
            .cRedBits = 0,
            .cRedShift = 0,
            .cGreenBits = 0,
            .cGreenShift = 0,
            .cBlueBits = 0,
            .cBlueShift = 0,
            .cAlphaBits = 0,
            .cAlphaShift = 0,
            .cAccumBits = 0,
            .cAccumRedBits = 0,
            .cAccumGreenBits = 0,
            .cAccumBlueBits = 0,
            .cAccumAlphaBits = 0,
            .cDepthBits = 16,
            .cStencilBits = 0,
            .cAuxBuffers = 0,
            .iLayerType = win32.PFD_MAIN_PLANE,
            .bReserved = 0,
            .dwLayerMask = 0,
            .dwVisibleMask = 0,
            .dwDamageMask = 0,
        };

        // Get device context
        const hdc = win32.GetDC(hwnd) orelse panicLastMessage("Failed to get device context");

        // Choose the pixel format
        const pixel_format = win32.ChoosePixelFormat(hdc, &pfd);
        if (pixel_format == 0) {
            panicLastMessage("Failed to choose pixel format");
        }

        // Set the pixel format
        const pixel_format_result = win32.SetPixelFormat(hdc, pixel_format, &pfd);
        if (pixel_format_result == 0) {
            panicLastMessage("Failed to set pixel format");
        }

        // Create the OpenGL context
        const hglrc = win32.wglCreateContext(hdc) orelse panicLastMessage("Failed to create OpenGL context");

        // Make the context current
        const make_current_result = win32.wglMakeCurrent(hdc, hglrc);
        if (make_current_result == 0) {
            panicLastMessage("Failed to make OpenGL context current");
        }

        // If the window was previously visible, the return value is nonzero.
        // If the window was previously hidden, the return value is zero.
        _ = win32.ShowWindow(hwnd, win32.SW_SHOWDEFAULT);
        _ = win32.SetForegroundWindow(hwnd);
        _ = win32.SetFocus(hwnd);

        // Build our result
        surface.* = .{
            .hwnd = hwnd,
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
    }

    pub fn deinit(surface: *Surface) void {
        // Remove ourselves from the list of known surfaces in the app.
        surface.app.app.deleteSurface(surface);

        // Clean up our core surface so that all the rendering and IO stop.
        surface.core_surface.deinit();

        // Destroy the OpenGL context
        _ = win32.wglMakeCurrent(null, null);

        // Release the device context
        _ = win32.ReleaseDC(surface.hwnd, surface.hdc);

        // Destroy the window
        _ = win32.DestroyWindow(surface.hwnd);

        // Unregister the window class
        _ = win32.UnregisterClassW(Utf8To16("GhosttyWindowClass"), surface.app.hInst);
    }

    pub fn shouldClose(surface: *Surface) bool {
        _ = surface;

        return false;
    }

    pub fn setShouldClose(surface: *Surface) void {
        _ = surface;

        // Does nothing on Win32
    }

    pub fn close(surface: *Surface, _: bool) void {
        surface.setShouldClose();
        surface.deinit();
        surface.app.app.alloc.destroy(surface);
    }

    pub fn setTitle(surface: *Surface, slice: [:0]const u8) !void {
        const name16 = try surface.app.app.alloc.allocSentinel(u16, slice.len, 0);
        _ = try std.unicode.utf8ToUtf16Le(name16, slice);

        const result = win32.SetWindowTextW(surface.hwnd, name16.ptr);

        if (result == 0) {
            panicLastMessage("Failed to set window title");
        }
    }

    /// Set the visibility of the mouse cursor.
    pub fn setMouseVisibility(self: *Surface, visible: bool) void {
        _ = self;
        _ = visible;

        // Does nothing on Win32
    }

    /// Set the shape of the mouse cursor. Unused by Win32.
    pub fn setMouseShape(self: *Surface, shape: terminal.MouseShape) !void {
        _ = self;
        _ = shape;
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
        state: apprt.ClipboardRequest,
    ) !void {
        _ = self;
        _ = clipboard_type;
        _ = state;
    }

    /// Set the clipboard.
    pub fn setClipboardString(
        self: *const Surface,
        val: [:0]const u8,
        clipboard_type: apprt.Clipboard,
        confirm: bool,
    ) !void {
        _ = self;
        _ = val;
        _ = clipboard_type;
        _ = confirm;
    }

    /// Returns the content scale for the created window.
    pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
        _ = self;

        // Does nothing on Win32
        return .{
            .x = 1.0,
            .y = 1.0,
        };
    }

    pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
        _ = self;

        // Does nothing on Win32
        return .{
            .width = 640,
            .height = 480,
        };
    }

    pub fn setSizeLimits(self: *Surface, min: apprt.SurfaceSize, max_: ?apprt.SurfaceSize) !void {
        _ = self;
        _ = min;
        _ = max_;

        // Does nothing on Win32
    }

    /// Set the initial window size. This is called exactly once at
    /// surface initialization time. This may be called before "self"
    /// is fully initialized.
    pub fn setInitialWindowSize(self: *const Surface, width: u32, height: u32) !void {
        _ = self;
        _ = width;
        _ = height;

        // Does nothing on Win32
    }
};

fn panicLastMessage(comptime msg: []const u8) noreturn {
    const err = win32.GetLastError();

    // 614 is the length of the longest windows error description
    var buf_wstr: [614:0]windows.WCHAR = undefined;
    var buf_utf8: [614:0]u8 = undefined;

    const len = win32.FormatMessageW(
        @enumFromInt(
            windows.FORMAT_MESSAGE_FROM_SYSTEM | windows.FORMAT_MESSAGE_IGNORE_INSERTS,
        ),
        null,
        @intFromEnum(err),
        MAKELANGID(windows.LANG.NEUTRAL, windows.SUBLANG.DEFAULT),
        &buf_wstr,
        buf_wstr.len,
        null,
    );
    _ = std.unicode.utf16leToUtf8(&buf_utf8, buf_wstr[0..len]) catch unreachable;
    std.debug.panic(msg ++ " {d}: {s}\n", .{ @intFromEnum(err), buf_utf8[0..len] });
}

inline fn MAKELANGID(p: c_ushort, s: c_ushort) windows.LANGID {
    return (s << 10) | p;
}
