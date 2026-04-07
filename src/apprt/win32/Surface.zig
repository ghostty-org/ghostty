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
extern "opengl32" fn wglGetProcAddress(lpszProc: [*:0]const u8) callconv(.winapi) ?*const anyopaque;

// Clipboard API
const UINT = u32;
const HANDLE = ?*anyopaque;
extern "user32" fn OpenClipboard(hWndNewOwner: ?HWND) callconv(.winapi) BOOL;
extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
extern "user32" fn GetClipboardData(uFormat: UINT) callconv(.winapi) HANDLE;
extern "user32" fn SetClipboardData(uFormat: UINT, hMem: HANDLE) callconv(.winapi) HANDLE;
extern "kernel32" fn GlobalAlloc(uFlags: UINT, dwBytes: usize) callconv(.winapi) HANDLE;
extern "kernel32" fn GlobalFree(hMem: HANDLE) callconv(.winapi) HANDLE;
extern "kernel32" fn GlobalLock(hMem: HANDLE) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalUnlock(hMem: HANDLE) callconv(.winapi) BOOL;

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

    // Set initial viewport to client area
    var client_rect: RECT = std.mem.zeroes(RECT);
    if (GetClientRect(self.hwnd, &client_rect) != 0) {
        self.width = @intCast(client_rect.right - client_rect.left);
        self.height = @intCast(client_rect.bottom - client_rect.top);
    }
    glViewport(0, 0, @intCast(self.width), @intCast(self.height));

    log.info("WGL OpenGL context created, client area {}x{}", .{ self.width, self.height });
}

const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
extern "user32" fn GetClientRect(hWnd: HWND, lpRect: *RECT) callconv(.winapi) BOOL;

pub fn swapBuffers(self: *Self) void {
    if (self.hdc != null) {
        _ = SwapBuffers(self.hdc);
    }
}

/// Disable VSync via WGL extension for lower input latency.
pub fn disableVSync(_: *Self) void {
    const func: ?*const fn (i32) callconv(.winapi) i32 = @ptrCast(wglGetProcAddress("wglSwapIntervalEXT"));
    if (func) |setInterval| {
        _ = setInterval(0);
    }
}

/// Update the OpenGL viewport to match the current window size.
/// Called from the renderer thread before each frame.
pub fn updateViewport(self: *Self) void {
    glViewport(0, 0, @intCast(self.width), @intCast(self.height));
}

extern "opengl32" fn glViewport(x: i32, y: i32, width: i32, height: i32) callconv(.winapi) void;

/// Make the WGL context current on the calling thread.
pub fn makeContextCurrent(self: *Self) void {
    if (self.hdc != null and self.hglrc != null) {
        _ = wglMakeCurrent(self.hdc, self.hglrc);
    }
}

/// Release the WGL context from the calling thread.
pub fn releaseContext() void {
    _ = wglMakeCurrent(null, null);
}

/// Release context from the main thread before handing off to renderer thread.
pub fn releaseMainThreadContext(self: *Self) void {
    _ = self;
    _ = wglMakeCurrent(null, null);
}

// --- Interface methods required by CoreSurface ---

pub fn getContentScale(self: *const Self) !apprt.ContentScale {
    const dpi = GetDpiForWindow(self.hwnd);
    if (dpi == 0) return .{ .x = 1.0, .y = 1.0 };
    const scale: f32 = @as(f32, @floatFromInt(dpi)) / 96.0;
    return .{ .x = scale, .y = scale };
}

extern "user32" fn GetDpiForWindow(hWnd: HWND) callconv(.winapi) u32;

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
    self: *Self,
    _: apprt.Clipboard,
    req: apprt.ClipboardRequest,
) !bool {
    const surface = self.core_surface orelse return false;

    // Try to read text from the Win32 clipboard synchronously
    if (OpenClipboard(self.hwnd) == 0) return false;
    defer _ = CloseClipboard();

    const CF_UNICODETEXT: UINT = 13;
    const handle = GetClipboardData(CF_UNICODETEXT);
    if (handle == null) return false;

    const ptr: ?[*:0]const u16 = @ptrCast(@alignCast(GlobalLock(handle)));
    if (ptr == null) return false;
    defer _ = GlobalUnlock(handle);

    // Convert UTF-16 to UTF-8
    const alloc = if (self.app) |app| app.alloc else std.heap.page_allocator;
    const utf8 = std.unicode.utf16LeToUtf8AllocZ(alloc, std.mem.span(ptr.?)) catch return false;
    defer alloc.free(utf8);

    try surface.completeClipboardRequest(req, utf8, true);
    return true;
}

pub fn setClipboard(
    self: *Self,
    _: apprt.Clipboard,
    contents: []const apprt.ClipboardContent,
    _: bool,
) !void {
    if (contents.len == 0) return;

    const text = contents[0].data;
    const alloc = if (self.app) |app| app.alloc else std.heap.page_allocator;

    // Convert UTF-8 to UTF-16
    const utf16 = try std.unicode.utf8ToUtf16LeAllocZ(alloc, text);
    defer alloc.free(utf16);

    const byte_len = (utf16.len + 1) * 2; // include null terminator
    const GMEM_MOVEABLE: UINT = 0x0002;
    const hmem = GlobalAlloc(GMEM_MOVEABLE, byte_len);
    if (hmem == null) return;

    const dst: ?[*]u16 = @ptrCast(@alignCast(GlobalLock(hmem)));
    if (dst == null) {
        _ = GlobalFree(hmem);
        return;
    }
    @memcpy(dst.?[0..utf16.len], utf16);
    dst.?[utf16.len] = 0;
    _ = GlobalUnlock(hmem);

    if (OpenClipboard(self.hwnd) == 0) {
        _ = GlobalFree(hmem);
        return;
    }
    _ = EmptyClipboard();
    const CF_UNICODETEXT: UINT = 13;
    _ = SetClipboardData(CF_UNICODETEXT, hmem);
    _ = CloseClipboard();
}

pub fn defaultTermioEnv(self: *Self) !std.process.EnvMap {
    const alloc = if (self.app) |app| app.alloc else std.heap.page_allocator;
    return try @import("../../os/main.zig").getEnvMap(alloc);
}

pub fn redrawInspector(_: *Self) void {}
