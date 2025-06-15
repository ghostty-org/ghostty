const std = @import("std");
const builtin = @import("builtin");

const c = @import("c.zig").c;
const Window = @import("Window.zig");

const internal_debug = @import("internal_debug.zig");

/// Makes the context of the specified window current for the calling thread.
///
/// This function makes the OpenGL or OpenGL ES context of the specified window current on the
/// calling thread. A context must only be made current on a single thread at a time and each
/// thread can have only a single current context at a time.
///
/// When moving a context between threads, you must make it non-current on the old thread before
/// making it current on the new one.
///
/// By default, making a context non-current implicitly forces a pipeline flush. On machines that
/// support `GL_KHR_context_flush_control`, you can control whether a context performs this flush
/// by setting the glfw.context_release_behavior hint.
///
/// The specified window must have an OpenGL or OpenGL ES context. Specifying a window without a
/// context will generate glfw.ErrorCode.NoWindowContext.
///
/// @param[in] window The window whose context to make current, or null to
/// detach the current context.
///
/// Possible errors include glfw.ErrorCode.NoWindowContext and glfw.ErrorCode.PlatformError.
///
/// @thread_safety This function may be called from any thread.
///
/// see also: context_current, glfwGetCurrentContext
pub inline fn makeContextCurrent(window: ?Window) void {
    internal_debug.assertInitialized();
    if (window) |w| c.glfwMakeContextCurrent(w.handle) else c.glfwMakeContextCurrent(null);
}

/// Returns the window whose context is current on the calling thread.
///
/// This function returns the window whose OpenGL or OpenGL ES context is current on the calling
/// thread.
///
/// Returns he window whose context is current, or null if no window's context is current.
///
/// @thread_safety This function may be called from any thread.
///
/// see also: context_current, glfwMakeContextCurrent
pub inline fn getCurrentContext() ?Window {
    internal_debug.assertInitialized();
    if (c.glfwGetCurrentContext()) |handle| return .from(handle);
    return null;
}

/// Sets the swap interval for the current context.
///
/// This function sets the swap interval for the current OpenGL or OpenGL ES context, i.e. the
/// number of screen updates to wait from the time glfw.SwapBuffers was called before swapping the
/// buffers and returning. This is sometimes called _vertical synchronization_, _vertical retrace
/// synchronization_ or just _vsync_.
///
/// A context that supports either of the `WGL_EXT_swap_control_tear` and `GLX_EXT_swap_control_tear`
/// extensions also accepts _negative_ swap intervals, which allows the driver to swap immediately
/// even if a frame arrives a little bit late. You can check for these extensions with glfw.extensionSupported.
///
/// A context must be current on the calling thread. Calling this function without a current context
/// will cause glfw.ErrorCode.NoCurrentContext.
///
/// This function does not apply to Vulkan. If you are rendering with Vulkan, see the present mode
/// of your swapchain instead.
///
/// @param[in] interval The minimum number of screen updates to wait for until the buffers are
/// swapped by glfw.swapBuffers.
///
/// Possible errors include glfw.ErrorCode.NoCurrentContext and glfw.ErrorCode.PlatformError.
///
/// This function is not called during context creation, leaving the swap interval set to whatever
/// is the default for that API. This is done because some swap interval extensions used by
/// GLFW do not allow the swap interval to be reset to zero once it has been set to a non-zero
/// value.
///
/// Some GPU drivers do not honor the requested swap interval, either because of a user setting
/// that overrides the application's request or due to bugs in the driver.
///
/// @thread_safety This function may be called from any thread.
///
/// see also: buffer_swap, glfwSwapBuffers
pub inline fn swapInterval(interval: i32) void {
    internal_debug.assertInitialized();
    c.glfwSwapInterval(@as(c_int, @intCast(interval)));
}

/// Returns whether the specified extension is available.
///
/// This function returns whether the specified API extension (see context_glext) is supported by
/// the current OpenGL or OpenGL ES context. It searches both for client API extension and context
/// creation API extensions.
///
/// A context must be current on the calling thread. Calling this function without a current
/// context will cause glfw.ErrorCode.NoCurrentContext.
///
/// As this functions retrieves and searches one or more extension strings each call, it is
/// recommended that you cache its results if it is going to be used frequently. The extension
/// strings will not change during the lifetime of a context, so there is no danger in doing this.
///
/// This function does not apply to Vulkan. If you are using Vulkan, see glfw.getRequiredInstanceExtensions,
/// `vkEnumerateInstanceExtensionProperties` and `vkEnumerateDeviceExtensionProperties` instead.
///
/// @param[in] extension The ASCII encoded name of the extension.
/// @return `true` if the extension is available, or `false` otherwise.
///
/// Possible errors include glfw.ErrorCode.NoCurrentContext, glfw.ErrorCode.InvalidValue
/// and glfw.ErrorCode.PlatformError.
///
/// @thread_safety This function may be called from any thread.
///
/// see also: context_glext, glfw.getProcAddress
pub inline fn extensionSupported(extension: [:0]const u8) bool {
    internal_debug.assertInitialized();

    std.debug.assert(extension.len != 0);
    std.debug.assert(extension[0] != 0);

    return c.glfwExtensionSupported(extension.ptr) == c.GLFW_TRUE;
}

/// Client API function pointer type.
///
/// Generic function pointer used for returning client API function pointers.
///
/// see also: context_glext, glfwGetProcAddress
pub const GLProc = *const fn () callconv(if (builtin.os.tag == .windows and builtin.cpu.arch == .x86) .Stdcall else .C) void;

/// Returns the address of the specified function for the current context.
///
/// This function returns the address of the specified OpenGL or OpenGL ES core or extension
/// function (see context_glext), if it is supported by the current context.
///
/// A context must be current on the calling thread. Calling this function without a current
/// context will cause glfw.ErrorCode.NoCurrentContext.
///
/// This function does not apply to Vulkan. If you are rendering with Vulkan, see glfw.getInstanceProcAddress,
/// `vkGetInstanceProcAddr` and `vkGetDeviceProcAddr` instead.
///
/// @param[in] procname The ASCII encoded name of the function.
/// @return The address of the function, or null if an error occurred.
///
/// To maintain ABI compatability with the C glfwGetProcAddress, as it is commonly passed into
/// libraries expecting that exact ABI, this function does not return an error. Instead, if
/// glfw.ErrorCode.NotInitialized, glfw.ErrorCode.NoCurrentContext, or glfw.ErrorCode.PlatformError
/// would occur this function will panic. You should ensure a valid OpenGL context exists and the
/// GLFW is initialized before calling this function.
///
/// The address of a given function is not guaranteed to be the same between contexts.
///
/// This function may return a non-null address despite the associated version or extension
/// not being available. Always check the context version or extension string first.
///
/// @pointer_lifetime The returned function pointer is valid until the context is destroyed or the
/// library is terminated.
///
/// @thread_safety This function may be called from any thread.
///
/// see also: context_glext, glfwExtensionSupported
pub fn getProcAddress(proc_name: [*:0]const u8) callconv(.c) ?GLProc {
    internal_debug.assertInitialized();
    if (c.glfwGetProcAddress(proc_name)) |proc_address| return @ptrCast(proc_address);
    return null;
}

test "makeContextCurrent" {
    const glfw = @import("main.zig");
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "Hello, Zig!", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    glfw.makeContextCurrent(window);
}

test "getCurrentContext" {
    const glfw = @import("main.zig");
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const current_context = glfw.getCurrentContext();
    std.debug.assert(current_context == null);
}

test "swapInterval" {
    const glfw = @import("main.zig");
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "Hello, Zig!", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    glfw.makeContextCurrent(window);
    glfw.swapInterval(1);
}

test "getProcAddress" {
    const glfw = @import("main.zig");
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "Hello, Zig!", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    glfw.makeContextCurrent(window);
    _ = glfw.getProcAddress("foobar");
}

test "extensionSupported" {
    const glfw = @import("main.zig");
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "Hello, Zig!", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    glfw.makeContextCurrent(window);
    _ = glfw.extensionSupported("foobar");
}
