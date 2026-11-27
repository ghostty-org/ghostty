//! Headless OpenGL contexts for Windows, created through WGL.
//!
//! The OpenGL renderer draws into its own framebuffer and hands finished
//! frames to the apprt, so it never presents to a window. WGL still needs a
//! device context with a pixel format to attach a context to, so each
//! `Context` owns a small hidden window that exists only for that purpose.
const std = @import("std");

const log = std.log.scoped(.opengl);

const Handle = *anyopaque;

const WS_POPUP: u32 = 0x80000000;

const PFD_DRAW_TO_WINDOW: u32 = 0x00000004;
const PFD_SUPPORT_OPENGL: u32 = 0x00000020;
const PFD_DOUBLEBUFFER: u32 = 0x00000001;
const PFD_TYPE_RGBA: u8 = 0;

const WGL_CONTEXT_MAJOR_VERSION_ARB: c_int = 0x2091;
const WGL_CONTEXT_MINOR_VERSION_ARB: c_int = 0x2092;
const WGL_CONTEXT_PROFILE_MASK_ARB: c_int = 0x9126;
const WGL_CONTEXT_CORE_PROFILE_BIT_ARB: c_int = 0x0001;

const PixelFormatDescriptor = extern struct {
    size: u16 = @sizeOf(PixelFormatDescriptor),
    version: u16 = 1,
    flags: u32,
    pixel_type: u8,
    color_bits: u8,
    red_bits: u8 = 0,
    red_shift: u8 = 0,
    green_bits: u8 = 0,
    green_shift: u8 = 0,
    blue_bits: u8 = 0,
    blue_shift: u8 = 0,
    alpha_bits: u8,
    alpha_shift: u8 = 0,
    accum_bits: u8 = 0,
    accum_red_bits: u8 = 0,
    accum_green_bits: u8 = 0,
    accum_blue_bits: u8 = 0,
    accum_alpha_bits: u8 = 0,
    depth_bits: u8,
    stencil_bits: u8,
    aux_buffers: u8 = 0,
    layer_type: u8 = 0,
    reserved: u8 = 0,
    layer_mask: u32 = 0,
    visible_mask: u32 = 0,
    damage_mask: u32 = 0,
};

const CreateContextAttribsFn = *const fn (
    hdc: Handle,
    share: ?Handle,
    attribs: [*:0]const c_int,
) callconv(.c) ?Handle;

extern "user32" fn CreateWindowExW(
    ex_style: u32,
    class_name: [*:0]const u16,
    window_name: [*:0]const u16,
    style: u32,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    parent: ?Handle,
    menu: ?Handle,
    instance: ?Handle,
    param: ?*anyopaque,
) callconv(.c) ?Handle;
extern "user32" fn DestroyWindow(hwnd: Handle) callconv(.c) c_int;
extern "user32" fn GetDC(hwnd: Handle) callconv(.c) ?Handle;
extern "user32" fn ReleaseDC(hwnd: Handle, hdc: Handle) callconv(.c) c_int;

extern "gdi32" fn ChoosePixelFormat(hdc: Handle, pfd: *const PixelFormatDescriptor) callconv(.c) c_int;
extern "gdi32" fn SwapBuffers(hdc: Handle) callconv(.c) c_int;
extern "gdi32" fn SetPixelFormat(hdc: Handle, format: c_int, pfd: *const PixelFormatDescriptor) callconv(.c) c_int;

extern "opengl32" fn wglCreateContext(hdc: Handle) callconv(.c) ?Handle;
extern "opengl32" fn wglDeleteContext(context: Handle) callconv(.c) c_int;
extern "opengl32" fn wglMakeCurrent(hdc: ?Handle, context: ?Handle) callconv(.c) c_int;
extern "opengl32" fn wglGetProcAddress(name: [*:0]const u8) callconv(.c) ?*const anyopaque;

extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(.c) ?Handle;
extern "kernel32" fn GetProcAddress(module: Handle, name: [*:0]const u8) callconv(.c) ?*const anyopaque;

pub const Error = error{
    WindowCreateFailed,
    PixelFormatFailed,
    ContextCreateFailed,
    MakeCurrentFailed,
};

/// Windows has no process-wide GL device the way EGL has a display, so the
/// device holds nothing. It exists to satisfy the renderer's device interface.
pub const Device = struct {
    pub const Options = struct {};

    pub fn init(alloc: std.mem.Allocator, _: Options) !*Device {
        return try alloc.create(Device);
    }

    pub fn deinit(self: *Device, alloc: std.mem.Allocator) void {
        alloc.destroy(self);
    }
};

/// An OpenGL context together with the hidden window that backs it. A
/// context can be current on only one thread at a time, so each surface
/// gets its own.
pub const Context = struct {
    hwnd: Handle,
    hdc: Handle,
    hglrc: Handle,

    /// True when the context made the window it draws to, and so removes it.
    owns_window: bool = true,

    /// Create a core profile context of at least the requested version.
    pub fn create(major: c_int, minor: c_int) Error!Context {
        // "STATIC" is a window class every process already has, which saves
        // us from registering one just to own a pixel format.
        const hwnd = CreateWindowExW(
            0,
            std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
            std.unicode.utf8ToUtf16LeStringLiteral("ghostty-gl"),
            WS_POPUP,
            0,
            0,
            1,
            1,
            null,
            null,
            GetModuleHandleW(null),
            null,
        ) orelse return error.WindowCreateFailed;
        errdefer _ = DestroyWindow(hwnd);

        return createOn(hwnd, true, major, minor);
    }

    /// Create a core profile context that draws to a window that already
    /// exists. A window can only be given a pixel format once.
    pub fn createOn(hwnd: Handle, owns_window: bool, major: c_int, minor: c_int) Error!Context {
        const hdc = GetDC(hwnd) orelse return error.WindowCreateFailed;
        errdefer _ = ReleaseDC(hwnd, hdc);

        const pfd: PixelFormatDescriptor = .{
            .flags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER,
            .pixel_type = PFD_TYPE_RGBA,
            .color_bits = 32,
            .alpha_bits = 8,
            .depth_bits = 0,
            .stencil_bits = 0,
        };
        const format = ChoosePixelFormat(hdc, &pfd);
        if (format == 0 or SetPixelFormat(hdc, format, &pfd) == 0) {
            return error.PixelFormatFailed;
        }

        // Windows only hands out legacy contexts directly. The function that
        // creates a core profile context has to be loaded through a legacy
        // context first, which is thrown away once we have it.
        const bootstrap = wglCreateContext(hdc) orelse return error.ContextCreateFailed;
        if (wglMakeCurrent(hdc, bootstrap) == 0) {
            _ = wglDeleteContext(bootstrap);
            return error.MakeCurrentFailed;
        }
        const create_attribs: ?CreateContextAttribsFn = @ptrCast(
            wglGetProcAddress("wglCreateContextAttribsARB"),
        );
        _ = wglMakeCurrent(null, null);
        _ = wglDeleteContext(bootstrap);

        const attribs = [_:0]c_int{
            WGL_CONTEXT_MAJOR_VERSION_ARB,    major,
            WGL_CONTEXT_MINOR_VERSION_ARB,    minor,
            WGL_CONTEXT_PROFILE_MASK_ARB,     WGL_CONTEXT_CORE_PROFILE_BIT_ARB,
        };
        const hglrc = (create_attribs orelse {
            log.warn("driver lacks WGL_ARB_create_context", .{});
            return error.ContextCreateFailed;
        })(hdc, null, &attribs) orelse return error.ContextCreateFailed;

        return .{ .hwnd = hwnd, .hdc = hdc, .hglrc = hglrc, .owns_window = owns_window };
    }

    pub fn destroy(self: Context) void {
        _ = wglMakeCurrent(null, null);
        _ = wglDeleteContext(self.hglrc);
        _ = ReleaseDC(self.hwnd, self.hdc);
        if (self.owns_window) _ = DestroyWindow(self.hwnd);
    }

    /// Show what has been drawn.
    pub fn swapBuffers(self: Context) void {
        _ = SwapBuffers(self.hdc);
    }

    pub fn makeCurrent(self: Context) Error!void {
        if (wglMakeCurrent(self.hdc, self.hglrc) == 0) return error.MakeCurrentFailed;
    }
};

/// Detach whatever context is current on the calling thread.
pub fn releaseCurrent() void {
    _ = wglMakeCurrent(null, null);
}

/// Look up an OpenGL function for the context current on this thread.
/// `wglGetProcAddress` only knows functions newer than OpenGL 1.1; the
/// original ones live in opengl32.dll itself.
pub fn getProcAddress(name: [*:0]const u8) callconv(.c) ?*const anyopaque {
    if (wglGetProcAddress(name)) |proc| {
        // Some drivers return small integers instead of null for failures.
        const addr = @intFromPtr(proc);
        if (addr > 3 and addr != std.math.maxInt(usize)) return proc;
    }
    const module = GetModuleHandleW(
        std.unicode.utf8ToUtf16LeStringLiteral("opengl32.dll"),
    ) orelse return null;
    return GetProcAddress(module, name);
}
