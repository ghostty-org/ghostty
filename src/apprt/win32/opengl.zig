/// OpenGL context creation and management for Win32 using WGL.
const std = @import("std");
const c = @import("c.zig");
const gl = @import("opengl");

const log = std.log.scoped(.win32_opengl);

const HDC = c.HDC;
const HGLRC = c.HGLRC;
const HMODULE = std.os.windows.HMODULE;
const WINAPI = std.builtin.CallingConvention.winapi;

extern "kernel32" fn GetModuleHandleA(lpModuleName: [*:0]const u8) callconv(WINAPI) ?HMODULE;
extern "kernel32" fn GetProcAddress(hModule: HMODULE, lpProcName: [*:0]const u8) callconv(WINAPI) ?*anyopaque;

// WGL extension constants
const WGL_CONTEXT_MAJOR_VERSION_ARB: c_int = 0x2091;
const WGL_CONTEXT_MINOR_VERSION_ARB: c_int = 0x2092;
const WGL_CONTEXT_PROFILE_MASK_ARB: c_int = 0x9126;
const WGL_CONTEXT_CORE_PROFILE_BIT_ARB: c_int = 0x00000001;
const WGL_CONTEXT_FLAGS_ARB: c_int = 0x2094;
const WGL_CONTEXT_DEBUG_BIT_ARB: c_int = 0x0001;

// Function pointer types for WGL extensions
const PFNWGLCREATECONTEXTATTRIBSARBPROC = *const fn (
    hDC: HDC,
    hShareContext: ?HGLRC,
    attribList: [*c]const c_int,
) callconv(c.WINAPI) ?HGLRC;

const PFNWGLSWAPINTERVALEXTPROC = *const fn (interval: c_int) callconv(c.WINAPI) c_int;

/// Creates an OpenGL context for the given device context.
/// This creates a modern OpenGL 4.3 core profile context.
pub fn createContext(hdc: HDC) !HGLRC {
    // Step 1: Set up pixel format
    try setupPixelFormat(hdc);

    // Step 2: Create a temporary legacy context to load WGL extensions
    const temp_ctx = c.wglCreateContext(hdc) orelse {
        log.err("Failed to create temporary OpenGL context", .{});
        return error.CreateContextFailed;
    };
    defer _ = c.wglDeleteContext(temp_ctx);

    if (c.wglMakeCurrent(hdc, temp_ctx) == 0) {
        log.err("Failed to make temporary context current", .{});
        return error.MakeCurrentFailed;
    }

    // Step 3: Load WGL extensions
    const wglCreateContextAttribsARB = blk: {
        const proc = c.wglGetProcAddress("wglCreateContextAttribsARB");
        if (proc == null) {
            log.err("wglCreateContextAttribsARB not available", .{});
            return error.WGLExtensionNotAvailable;
        }
        const func: PFNWGLCREATECONTEXTATTRIBSARBPROC = @ptrCast(proc);
        break :blk func;
    };

    // Step 4: Create modern OpenGL 4.3 core context
    const attribs = [_]c_int{
        WGL_CONTEXT_MAJOR_VERSION_ARB, 4,
        WGL_CONTEXT_MINOR_VERSION_ARB, 3,
        WGL_CONTEXT_PROFILE_MASK_ARB,  WGL_CONTEXT_CORE_PROFILE_BIT_ARB,
        // Enable debug context in debug builds
        if (std.debug.runtime_safety)
            WGL_CONTEXT_FLAGS_ARB
        else
            0,
        if (std.debug.runtime_safety)
            WGL_CONTEXT_DEBUG_BIT_ARB
        else
            0,
        0, // Terminator
    };

    const ctx = wglCreateContextAttribsARB(hdc, null, &attribs) orelse {
        log.err("Failed to create OpenGL 4.3 core context", .{});
        return error.CreateModernContextFailed;
    };

    // Step 5: Switch to the new context
    _ = c.wglMakeCurrent(null, null);
    if (c.wglMakeCurrent(hdc, ctx) == 0) {
        _ = c.wglDeleteContext(ctx);
        log.err("Failed to make new context current", .{});
        return error.MakeCurrentFailed;
    }

    // Step 6: Load OpenGL functions using glad
    try prepareContext();

    // Step 7: Disable vsync so SwapBuffers doesn't block the renderer
    // thread for ~16ms per frame. Without this, the renderer can't
    // process new notifications while blocked in SwapBuffers, which
    // causes visible input and action latency.
    if (c.wglGetProcAddress("wglSwapIntervalEXT")) |proc| {
        const wglSwapIntervalEXT: PFNWGLSWAPINTERVALEXTPROC = @ptrCast(proc);
        _ = wglSwapIntervalEXT(0);
        log.info("Disabled vsync (swap interval = 0)", .{});
    } else {
        log.warn("wglSwapIntervalEXT not available, vsync may cause latency", .{});
    }

    log.info("Created OpenGL 4.3 core context successfully", .{});
    return ctx;
}

/// Makes the given context current for the device context.
pub fn makeCurrent(hdc: HDC, hglrc: ?HGLRC) !void {
    if (c.wglMakeCurrent(hdc, hglrc) == 0) {
        return error.MakeCurrentFailed;
    }
}

/// Swaps the front and back buffers for the device context.
pub fn swapBuffers(hdc: HDC) !void {
    if (c.SwapBuffers(hdc) == 0) {
        return error.SwapBuffersFailed;
    }
}

/// Sets up the pixel format for OpenGL rendering.
fn setupPixelFormat(hdc: HDC) !void {
    const pfd = c.PIXELFORMATDESCRIPTOR{
        .nSize = @sizeOf(c.PIXELFORMATDESCRIPTOR),
        .nVersion = 1,
        .dwFlags = c.PFD_DRAW_TO_WINDOW | c.PFD_SUPPORT_OPENGL | c.PFD_DOUBLEBUFFER,
        .iPixelType = c.PFD_TYPE_RGBA,
        .cColorBits = 32,
        .cDepthBits = 24,
        .cStencilBits = 8,
        .iLayerType = c.PFD_MAIN_PLANE,
    };

    const format = c.ChoosePixelFormat(hdc, &pfd);
    if (format == 0) {
        log.err("Failed to choose pixel format", .{});
        return error.ChoosePixelFormatFailed;
    }

    if (c.SetPixelFormat(hdc, format, &pfd) == 0) {
        log.err("Failed to set pixel format", .{});
        return error.SetPixelFormatFailed;
    }

    log.debug("Set pixel format successfully", .{});
}

/// Prepares the OpenGL context by loading functions with glad.
/// This is similar to the prepareContext function in OpenGL.zig but adapted for WGL.
/// This is public so the renderer thread can reload the threadlocal glad context.
pub fn prepareContext() !void {
    // Load OpenGL functions using wglGetProcAddress
    const version = try gl.glad.load(struct {
        fn getProcAddress(name: [:0]const u8) ?*const anyopaque {
            // wglGetProcAddress only returns extension functions.
            // For core functions, we need to fall back to GetProcAddress from opengl32.dll
            if (c.wglGetProcAddress(name.ptr)) |proc| {
                return proc;
            }

            // Fallback: Try to get it from opengl32.dll for core OpenGL 1.1 functions
            const opengl32 = GetModuleHandleA("opengl32.dll") orelse return null;

            if (GetProcAddress(opengl32, name.ptr)) |proc| {
                return @ptrCast(proc);
            }

            return null;
        }
    }.getProcAddress);

    const major = gl.glad.versionMajor(@intCast(version));
    const minor = gl.glad.versionMinor(@intCast(version));

    log.info("Loaded OpenGL {}.{}", .{ major, minor });

    // Check version
    const MIN_VERSION_MAJOR = 4;
    const MIN_VERSION_MINOR = 3;

    if (major < MIN_VERSION_MAJOR or
        (major == MIN_VERSION_MAJOR and minor < MIN_VERSION_MINOR))
    {
        log.err(
            "OpenGL version is too old. Ghostty requires OpenGL {d}.{d}",
            .{ MIN_VERSION_MAJOR, MIN_VERSION_MINOR },
        );
        return error.OpenGLOutdated;
    }

    // Ensure vsync is disabled on this thread. The initial createContext sets
    // swap interval 0 on the main thread, but some drivers reset it when the
    // context migrates to the renderer thread.
    if (c.wglGetProcAddress("wglSwapIntervalEXT")) |proc| {
        const wglSwapIntervalEXT: *const fn (c_int) callconv(c.WINAPI) c_int = @ptrCast(proc);
        _ = wglSwapIntervalEXT(0);
        log.info("Vsync disabled on current thread (swap interval = 0)", .{});
    }

    // Enable debug output in debug builds (asynchronous to avoid stalling
    // the GPU pipeline — GL_DEBUG_OUTPUT_SYNCHRONOUS forces CPU/GPU sync on
    // every GL call which adds significant latency).
    if (std.debug.runtime_safety) {
        if (gl.glad.context.DebugMessageCallback) |debugCallback| {
            const GL_DEBUG_OUTPUT: c_uint = 0x92E0;
            debugCallback(@ptrCast(&glDebugMessageCallback), null);
            if (gl.glad.context.Enable) |glEnable| {
                glEnable(GL_DEBUG_OUTPUT);
            }
            log.debug("Enabled OpenGL debug output (async)", .{});
        }
    }
}

/// OpenGL debug message callback
fn glDebugMessageCallback(
    src: gl.c.GLenum,
    typ: gl.c.GLenum,
    id: gl.c.GLuint,
    severity: gl.c.GLenum,
    len: gl.c.GLsizei,
    msg: [*c]const gl.c.GLchar,
    user_param: ?*const anyopaque,
) callconv(.c) void {
    _ = user_param;

    const src_str: []const u8 = switch (src) {
        gl.c.GL_DEBUG_SOURCE_API => "OpenGL API",
        gl.c.GL_DEBUG_SOURCE_WINDOW_SYSTEM => "Window System",
        gl.c.GL_DEBUG_SOURCE_SHADER_COMPILER => "Shader Compiler",
        gl.c.GL_DEBUG_SOURCE_THIRD_PARTY => "Third Party",
        gl.c.GL_DEBUG_SOURCE_APPLICATION => "User",
        gl.c.GL_DEBUG_SOURCE_OTHER => "Other",
        else => "Unknown",
    };

    const typ_str: []const u8 = switch (typ) {
        gl.c.GL_DEBUG_TYPE_ERROR => "Error",
        gl.c.GL_DEBUG_TYPE_DEPRECATED_BEHAVIOR => "Deprecated Behavior",
        gl.c.GL_DEBUG_TYPE_UNDEFINED_BEHAVIOR => "Undefined Behavior",
        gl.c.GL_DEBUG_TYPE_PORTABILITY => "Portability Issue",
        gl.c.GL_DEBUG_TYPE_PERFORMANCE => "Performance Issue",
        gl.c.GL_DEBUG_TYPE_MARKER => "Marker",
        gl.c.GL_DEBUG_TYPE_PUSH_GROUP => "Group Push",
        gl.c.GL_DEBUG_TYPE_POP_GROUP => "Group Pop",
        gl.c.GL_DEBUG_TYPE_OTHER => "Other",
        else => "Unknown",
    };

    const msg_str = msg[0..@intCast(len)];

    (switch (severity) {
        gl.c.GL_DEBUG_SEVERITY_HIGH => log.err(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        gl.c.GL_DEBUG_SEVERITY_MEDIUM => log.warn(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        gl.c.GL_DEBUG_SEVERITY_LOW => log.info(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        gl.c.GL_DEBUG_SEVERITY_NOTIFICATION => log.debug(
            "[{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
        else => log.warn(
            "UNKNOWN SEVERITY [{d}] ({s}: {s}) {s}",
            .{ id, src_str, typ_str, msg_str },
        ),
    });
}
