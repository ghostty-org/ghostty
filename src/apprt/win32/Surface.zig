/// Win32 surface - represents a terminal surface within a window.
/// Manages the WGL OpenGL context and provides the interface
/// expected by CoreSurface.
const Self = @This();

const std = @import("std");
const win32 = @import("win32").everything;
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const CoreSurface = @import("../../Surface.zig");
const CoreApp = @import("../../App.zig");

const log = std.log.scoped(.win32_surface);

/// The window this surface belongs to.
hwnd: win32.HWND,

/// Pointer back to the App.
app: ?*App = null,

/// GDI device context.
hdc: ?win32.HDC = null,

/// OpenGL rendering context.
hglrc: ?win32.HGLRC = null,

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

pub fn init(self: *Self, hwnd: win32.HWND) !void {
    self.* = .{ .hwnd = hwnd };
    try self.initOpenGL();
}

pub fn deinit(self: *Self) void {
    if (self.core_surface) |surface| {
        surface.deinit();
        // core_surface is allocated by CoreApp, freed there
    }
    if (self.hglrc) |hglrc| {
        _ = win32.wglMakeCurrent(null, null);
        _ = win32.wglDeleteContext(hglrc);
    }
    if (self.hdc) |hdc| {
        _ = win32.ReleaseDC(self.hwnd, hdc);
    }
}

fn initOpenGL(self: *Self) !void {
    self.hdc = win32.GetDC(self.hwnd) orelse {
        log.err("GetDC failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return error.Win32Error;
    };

    var pfd: win32.PIXELFORMATDESCRIPTOR = std.mem.zeroes(win32.PIXELFORMATDESCRIPTOR);
    pfd.nSize = @sizeOf(win32.PIXELFORMATDESCRIPTOR);
    pfd.nVersion = 1;
    pfd.dwFlags = .{ .DRAW_TO_WINDOW = 1, .SUPPORT_OPENGL = 1, .DOUBLEBUFFER = 1 };
    pfd.iPixelType = .RGBA;
    pfd.cColorBits = 32;
    pfd.cDepthBits = 24;
    pfd.cStencilBits = 8;
    pfd.iLayerType = .MAIN_PLANE;

    const pixel_format = win32.ChoosePixelFormat(self.hdc, &pfd);
    if (pixel_format == 0) {
        log.err("ChoosePixelFormat failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return error.Win32Error;
    }

    if (win32.SetPixelFormat(self.hdc, pixel_format, &pfd) == 0) {
        log.err("SetPixelFormat failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return error.Win32Error;
    }

    self.hglrc = win32.wglCreateContext(self.hdc) orelse {
        log.err("wglCreateContext failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return error.Win32Error;
    };

    if (win32.wglMakeCurrent(self.hdc, self.hglrc) == 0) {
        log.err("wglMakeCurrent failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        return error.Win32Error;
    }

    log.info("WGL OpenGL context created successfully", .{});
}

pub fn swapBuffers(self: *Self) void {
    if (self.hdc) |hdc| {
        if (win32.SwapBuffers(hdc) == 0) {
            log.warn("SwapBuffers failed: err={d}", .{@intFromEnum(win32.GetLastError())});
        }
    }
}

/// Make the WGL context current on the calling thread.
pub fn makeContextCurrent(self: *Self) void {
    if (self.hdc) |hdc| {
        if (self.hglrc) |hglrc| {
            if (win32.wglMakeCurrent(hdc, hglrc) == 0) {
                log.warn("wglMakeCurrent failed: err={d}", .{@intFromEnum(win32.GetLastError())});
            }
        }
    }
}

/// Release the WGL context from the calling thread.
pub fn releaseContext() void {
    if (win32.wglMakeCurrent(null, null) == 0) {
        log.warn("wglMakeCurrent(null) failed: err={d}", .{@intFromEnum(win32.GetLastError())});
    }
}

/// Release context from the main thread before handing off to renderer thread.
pub fn releaseMainThreadContext(self: *Self) void {
    _ = self;
    if (win32.wglMakeCurrent(null, null) == 0) {
        log.warn("wglMakeCurrent(null) failed: err={d}", .{@intFromEnum(win32.GetLastError())});
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
