/// Win32 surface - represents a terminal surface within a window.
/// Manages the WGL OpenGL context and provides the interface
/// expected by CoreSurface.
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const CoreSurface = @import("../../Surface.zig");
const CoreApp = @import("../../App.zig");

const log = std.log.scoped(.win32_surface);

// Win32 types
const HWND = std.os.windows.HWND;
const HINSTANCE = std.os.windows.HINSTANCE;
const BOOL = i32;
const HDC = ?*anyopaque;
const HGLRC = ?*anyopaque;

const PIXELFORMATDESCRIPTOR = extern struct {
    nSize: u16,
    nVersion: u16,
    dwFlags: u32,
    iPixelType: u8,
    cColorBits: u8,
    cRedBits: u8,
    cRedShift: u8,
    cGreenBits: u8,
    cGreenShift: u8,
    cBlueBits: u8,
    cBlueShift: u8,
    cAlphaBits: u8,
    cAlphaShift: u8,
    cAccumBits: u8,
    cAccumRedBits: u8,
    cAccumGreenBits: u8,
    cAccumBlueBits: u8,
    cAccumAlphaBits: u8,
    cDepthBits: u8,
    cStencilBits: u8,
    cAuxBuffers: u8,
    iLayerType: u8,
    bReserved: u8,
    dwLayerMask: u32,
    dwVisibleMask: u32,
    dwDamageMask: u32,
};

// WGL / GDI constants
const PFD_DRAW_TO_WINDOW = 0x00000004;
const PFD_SUPPORT_OPENGL = 0x00000020;
const PFD_DOUBLEBUFFER = 0x00000001;
const PFD_TYPE_RGBA = 0;
const PFD_MAIN_PLANE = 0;

// WGL / GDI extern declarations
extern "user32" fn GetDC(hWnd: ?HWND) callconv(.winapi) HDC;
extern "user32" fn ReleaseDC(hWnd: ?HWND, hDC: HDC) callconv(.winapi) c_int;
extern "gdi32" fn ChoosePixelFormat(hdc: HDC, ppfd: *const PIXELFORMATDESCRIPTOR) callconv(.winapi) c_int;
extern "gdi32" fn SetPixelFormat(hdc: HDC, format: c_int, ppfd: *const PIXELFORMATDESCRIPTOR) callconv(.winapi) BOOL;
extern "gdi32" fn SwapBuffers(hdc: HDC) callconv(.winapi) BOOL;
extern "opengl32" fn wglCreateContext(hdc: HDC) callconv(.winapi) HGLRC;
extern "opengl32" fn wglDeleteContext(hglrc: HGLRC) callconv(.winapi) BOOL;
extern "opengl32" fn wglMakeCurrent(hdc: HDC, hglrc: HGLRC) callconv(.winapi) BOOL;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;

/// The window this surface belongs to.
hwnd: HWND,

/// Pointer back to the App.
app: ?*App = null,

/// GDI device context.
hdc: HDC = null,

/// OpenGL rendering context.
hglrc: HGLRC = null,

/// The core surface, if initialized.
core_surface: ?*CoreSurface = null,

/// Window dimensions.
width: u32 = 800,
height: u32 = 600,

const App = @import("App.zig");

pub fn core(self: *Self) *CoreSurface {
    return self.core_surface.?;
}

pub fn rtApp(self: *Self) *App {
    return self.app.?;
}

pub fn init(self: *Self, hwnd: HWND) !void {
    self.* = .{ .hwnd = hwnd };
    try self.initOpenGL();
}

pub fn deinit(self: *Self) void {
    if (self.core_surface) |surface| {
        surface.deinit();
        // core_surface is allocated by CoreApp, freed there
    }
    if (self.hglrc != null) {
        _ = wglMakeCurrent(null, null);
        _ = wglDeleteContext(self.hglrc);
    }
    if (self.hdc != null) {
        _ = ReleaseDC(self.hwnd, self.hdc);
    }
}

fn initOpenGL(self: *Self) !void {
    self.hdc = GetDC(self.hwnd);
    if (self.hdc == null) {
        log.err("GetDC failed", .{});
        return error.Win32Error;
    }

    var pfd: PIXELFORMATDESCRIPTOR = std.mem.zeroes(PIXELFORMATDESCRIPTOR);
    pfd.nSize = @sizeOf(PIXELFORMATDESCRIPTOR);
    pfd.nVersion = 1;
    pfd.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER;
    pfd.iPixelType = PFD_TYPE_RGBA;
    pfd.cColorBits = 32;
    pfd.cDepthBits = 24;
    pfd.cStencilBits = 8;
    pfd.iLayerType = PFD_MAIN_PLANE;

    const pixel_format = ChoosePixelFormat(self.hdc, &pfd);
    if (pixel_format == 0) {
        log.err("ChoosePixelFormat failed", .{});
        return error.Win32Error;
    }

    if (SetPixelFormat(self.hdc, pixel_format, &pfd) == 0) {
        log.err("SetPixelFormat failed", .{});
        return error.Win32Error;
    }

    self.hglrc = wglCreateContext(self.hdc);
    if (self.hglrc == null) {
        log.err("wglCreateContext failed", .{});
        return error.Win32Error;
    }

    if (wglMakeCurrent(self.hdc, self.hglrc) == 0) {
        log.err("wglMakeCurrent failed", .{});
        return error.Win32Error;
    }

    log.info("WGL OpenGL context created successfully", .{});
}

pub fn swapBuffers(self: *Self) void {
    if (self.hdc != null) {
        if (SwapBuffers(self.hdc) == 0) {
            log.warn("SwapBuffers failed: err={d}", .{GetLastError()});
        }
    }
}

/// Make the WGL context current on the calling thread.
pub fn makeContextCurrent(self: *Self) void {
    if (self.hdc != null and self.hglrc != null) {
        if (wglMakeCurrent(self.hdc, self.hglrc) == 0) {
            log.warn("wglMakeCurrent failed: err={d}", .{GetLastError()});
        }
    }
}

/// Release the WGL context from the calling thread.
pub fn releaseContext() void {
    if (wglMakeCurrent(null, null) == 0) {
        log.warn("wglMakeCurrent(null) failed: err={d}", .{GetLastError()});
    }
}

/// Release context from the main thread before handing off to renderer thread.
pub fn releaseMainThreadContext(self: *Self) void {
    _ = self;
    if (wglMakeCurrent(null, null) == 0) {
        log.warn("wglMakeCurrent(null) failed: err={d}", .{GetLastError()});
    }
}

// --- Interface methods required by CoreSurface ---

pub fn getContentScale(_: *const Self) !apprt.ContentScale {
    // TODO: query DPI from the monitor
    return .{ .x = 1.0, .y = 1.0 };
}

pub fn getSize(self: *const Self) !apprt.SurfaceSize {
    return .{
        .width = self.width,
        .height = self.height,
    };
}

pub fn getCursorPos(_: *const Self) !apprt.CursorPos {
    // TODO: track mouse position
    return .{ .x = 0, .y = 0 };
}

pub fn getTitle(_: *Self) ?[:0]const u8 {
    return null;
}

pub fn close(_: *Self, _: bool) void {
    // TODO: handle close with confirmation
}

pub fn supportsClipboard(_: *Self, clipboard: apprt.Clipboard) bool {
    return clipboard == .standard;
}

pub fn clipboardRequest(
    _: *Self,
    _: apprt.Clipboard,
    _: apprt.ClipboardRequest,
) !bool {
    // TODO: implement clipboard read
    return false;
}

pub fn setClipboard(
    _: *Self,
    _: apprt.Clipboard,
    _: []const apprt.ClipboardContent,
    _: bool,
) !void {
    // TODO: implement clipboard write
}

pub fn defaultTermioEnv(_: *Self) !std.process.EnvMap {
    // Return an empty env map; the shell will inherit the process env.
    return std.process.EnvMap.init(std.heap.page_allocator);
}

pub fn redrawInspector(_: *Self) void {}
