//! Win32 Surface. Each Surface corresponds to one HWND (window) and
//! owns an OpenGL (WGL) context for rendering.
const Surface = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const CoreSurface = @import("../../Surface.zig");
const internal_os = @import("../../os/main.zig");

const App = @import("App.zig");
const w32 = @import("win32.zig");

const log = std.log.scoped(.win32);

/// The Win32 window handle.
hwnd: ?w32.HWND = null,

/// Device context for the window (with CS_OWNDC, this persists for the
/// lifetime of the window).
hdc: ?w32.HDC = null,

/// WGL OpenGL rendering context.
hglrc: ?w32.HGLRC = null,

/// Current client area dimensions in pixels.
width: u32 = 800,
height: u32 = 600,

/// DPI scale factor (DPI / 96.0).
scale: f32 = 1.0,

/// The parent App.
app: *App,

/// The core terminal surface. Initialized by init() after creating
/// the window and WGL context. Manages fonts, renderer, PTY, and IO.
core_surface: CoreSurface = undefined,

/// Initialize a new Surface by creating a Win32 window and WGL context,
/// then initialize the core terminal surface (fonts, renderer, PTY, IO).
pub fn init(self: *Surface, app: *App) !void {
    self.* = .{
        .app = app,
    };

    // Create the window through the App
    const hwnd = try app.createWindow();
    self.hwnd = hwnd;

    // Store the Surface pointer in the window's GWLP_USERDATA so that
    // the WndProc can retrieve it.
    _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    // Get the device context. With CS_OWNDC, this DC is valid for
    // the lifetime of the window.
    self.hdc = w32.GetDC(hwnd);
    if (self.hdc == null) return error.Win32Error;

    // Set up the pixel format for OpenGL
    try self.setupPixelFormat();

    // Create the WGL context
    self.hglrc = w32.wglCreateContext(self.hdc.?);
    if (self.hglrc == null) return error.Win32Error;

    // Query the initial DPI and size
    self.updateDpiScale();
    self.updateClientSize();

    log.info("Win32 surface created: {}x{} scale={d:.2}", .{
        self.width,
        self.height,
        self.scale,
    });

    // --- Core terminal surface initialization ---
    const alloc = app.core_app.alloc;

    // Register this surface with the core app.
    try app.core_app.addSurface(self);
    errdefer app.core_app.deleteSurface(self);

    // Create a config copy for this surface.
    var config = try apprt.surface.newConfig(app.core_app, &app.config, .window);
    defer config.deinit();

    // Initialize the core surface. This sets up fonts, the renderer, PTY,
    // and spawns the renderer + IO threads.
    try self.core_surface.init(
        alloc,
        &config,
        app.core_app,
        app,
        self,
    );
}

pub fn deinit(self: *Surface) void {
    // Deinit the core surface first (stops renderer/IO threads, cleans up
    // terminal state, PTY, fonts, etc.).
    self.core_surface.deinit();

    // Unregister from the core app's surface list.
    self.app.core_app.deleteSurface(self);

    if (self.hglrc) |hglrc| {
        // Ensure the context is not current before deleting
        _ = w32.wglMakeCurrent(null, null);
        _ = w32.wglDeleteContext(hglrc);
        self.hglrc = null;
    }

    if (self.hdc) |hdc| {
        if (self.hwnd) |hwnd| {
            _ = w32.ReleaseDC(hwnd, hdc);
        }
        self.hdc = null;
    }

    if (self.hwnd) |hwnd| {
        _ = w32.DestroyWindow(hwnd);
        self.hwnd = null;
    }
}

/// Set up a pixel format suitable for OpenGL rendering.
fn setupPixelFormat(self: *Surface) !void {
    const pfd = w32.PIXELFORMATDESCRIPTOR{
        .nSize = @sizeOf(w32.PIXELFORMATDESCRIPTOR),
        .nVersion = 1,
        .dwFlags = w32.PFD_DRAW_TO_WINDOW | w32.PFD_SUPPORT_OPENGL | w32.PFD_DOUBLEBUFFER,
        .iPixelType = w32.PFD_TYPE_RGBA,
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
        .cStencilBits = 8,
        .cAuxBuffers = 0,
        .iLayerType = 0, // PFD_MAIN_PLANE
        .bReserved = 0,
        .dwLayerMask = 0,
        .dwVisibleMask = 0,
        .dwDamageMask = 0,
    };

    const format = w32.ChoosePixelFormat(self.hdc.?, &pfd);
    if (format == 0) return error.Win32Error;

    if (w32.SetPixelFormat(self.hdc.?, format, &pfd) == 0)
        return error.Win32Error;
}

/// Update the DPI scale factor from the window's DPI.
fn updateDpiScale(self: *Surface) void {
    if (self.hwnd) |hwnd| {
        const dpi = w32.GetDpiForWindow(hwnd);
        if (dpi != 0) {
            self.scale = @as(f32, @floatFromInt(dpi)) / 96.0;
        }
    }
}

/// Update the cached client area size.
fn updateClientSize(self: *Surface) void {
    if (self.hwnd) |hwnd| {
        var rect: w32.RECT = undefined;
        if (w32.GetClientRect(hwnd, &rect) != 0) {
            self.width = @intCast(rect.right - rect.left);
            self.height = @intCast(rect.bottom - rect.top);
        }
    }
}

// -----------------------------------------------------------------------
// Methods called by the core Surface.zig (rt_surface.*)
// -----------------------------------------------------------------------

pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
    return .{ .x = self.scale, .y = self.scale };
}

pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
    return .{ .width = self.width, .height = self.height };
}

pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
    if (self.hwnd) |hwnd| {
        var point: w32.POINT = undefined;
        if (w32.GetCursorPos_(&point) != 0) {
            _ = w32.ScreenToClient(hwnd, &point);
            return .{
                .x = @floatFromInt(point.x),
                .y = @floatFromInt(point.y),
            };
        }
    }
    return .{ .x = 0, .y = 0 };
}

pub fn getTitle(self: *const Surface) ?[:0]const u8 {
    _ = self;
    // TODO: Store and return the title set via setTitle.
    return null;
}

pub fn close(self: *Surface, process_active: bool) void {
    _ = process_active;
    if (self.hwnd) |hwnd| {
        _ = w32.DestroyWindow(hwnd);
    }
}

pub fn supportsClipboard(
    self: *const Surface,
    clipboard_type: apprt.Clipboard,
) bool {
    _ = self;
    return switch (clipboard_type) {
        .standard => true,
        .selection, .primary => false,
    };
}

pub fn clipboardRequest(
    self: *Surface,
    clipboard_type: apprt.Clipboard,
    state: apprt.ClipboardRequest,
) !bool {
    _ = self;
    _ = clipboard_type;
    _ = state;
    // TODO: Implement clipboard read
    return false;
}

pub fn setClipboard(
    self: *Surface,
    clipboard_type: apprt.Clipboard,
    contents: []const apprt.ClipboardContent,
    confirm: bool,
) !void {
    _ = self;
    _ = clipboard_type;
    _ = contents;
    _ = confirm;
    // TODO: Implement clipboard write
}

pub fn defaultTermioEnv(self: *const Surface) !std.process.EnvMap {
    const alloc = self.app.core_app.alloc;
    var env = try internal_os.getEnvMap(alloc);
    errdefer env.deinit();

    // Set TERM
    try env.put("TERM", "xterm-256color");

    // COLORTERM signals 24-bit color support
    try env.put("COLORTERM", "truecolor");

    return env;
}

/// Set the window title. Called from performAction(.set_title).
pub fn setTitle(self: *Surface, title: [:0]const u8) void {
    if (self.hwnd) |hwnd| {
        // Convert UTF-8 title to UTF-16 for Win32
        var buf: [512]u16 = undefined;
        const len = std.unicode.utf8ToUtf16Le(&buf, title) catch return;
        if (len < buf.len) {
            buf[len] = 0;
            _ = w32.SetWindowTextW(hwnd, @ptrCast(&buf));
        }
    }
}

// -----------------------------------------------------------------------
// Message handlers called from App.wndProc
// -----------------------------------------------------------------------

/// Handle WM_SIZE.
pub fn handleResize(self: *Surface, width: u32, height: u32) void {
    self.width = width;
    self.height = height;
}

/// Handle WM_DESTROY.
pub fn handleDestroy(self: *Surface) void {
    // The window is already being destroyed at this point.
    // Clear the hwnd so deinit() doesn't try to destroy it again.
    self.hwnd = null;

    // Grab the allocator and app pointer before deinit clears them.
    const alloc = self.app.core_app.alloc;

    // Deinit the surface (core surface, WGL, etc.)
    self.deinit();

    // Free the heap-allocated Surface.
    alloc.destroy(self);
}

/// Handle WM_DPICHANGED.
pub fn handleDpiChange(self: *Surface) void {
    self.updateDpiScale();
}

/// Return a pointer to the core terminal surface.
pub fn core(self: *Surface) *CoreSurface {
    return &self.core_surface;
}

/// Return a reference to the App for use by core code.
pub fn rtApp(self: *Surface) *App {
    return self.app;
}
