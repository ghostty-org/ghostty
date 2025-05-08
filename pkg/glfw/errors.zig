//! Errors

const testing = @import("std").testing;
const mem = @import("std").mem;
const c = @import("c.zig").c;

/// Errors that GLFW can produce.
pub const ErrorCode = error{
    /// GLFW has not been initialized.
    ///
    /// This occurs if a GLFW function was called that must not be called unless the library is
    /// initialized.
    NotInitialized,

    /// No context is current for this thread.
    ///
    /// This occurs if a GLFW function was called that needs and operates on the current OpenGL or
    /// OpenGL ES context but no context is current on the calling thread. One such function is
    /// glfw.SwapInterval.
    NoCurrentContext,

    /// One of the arguments to the function was an invalid enum value.
    ///
    /// One of the arguments to the function was an invalid enum value, for example requesting
    /// glfw.red_bits with glfw.getWindowAttrib.
    InvalidEnum,

    /// One of the arguments to the function was an invalid value.
    ///
    /// One of the arguments to the function was an invalid value, for example requesting a
    /// non-existent OpenGL or OpenGL ES version like 2.7.
    ///
    /// Requesting a valid but unavailable OpenGL or OpenGL ES version will instead result in a
    /// glfw.ErrorCode.VersionUnavailable error.
    InvalidValue,

    /// A memory allocation failed.
    OutOfMemory,

    /// GLFW could not find support for the requested API on the system.
    ///
    /// The installed graphics driver does not support the requested API, or does not support it
    /// via the chosen context creation API. Below are a few examples.
    ///
    /// Some pre-installed Windows graphics drivers do not support OpenGL. AMD only supports
    /// OpenGL ES via EGL, while Nvidia and Intel only support it via a WGL or GLX extension. macOS
    /// does not provide OpenGL ES at all. The Mesa EGL, OpenGL and OpenGL ES libraries do not
    /// interface with the Nvidia binary driver. Older graphics drivers do not support Vulkan.
    APIUnavailable,

    /// The requested OpenGL or OpenGL ES version (including any requested context or framebuffer
    /// hints) is not available on this machine.
    ///
    /// The machine does not support your requirements. If your application is sufficiently
    /// flexible, downgrade your requirements and try again. Otherwise, inform the user that their
    /// machine does not match your requirements.
    ///
    /// Future invalid OpenGL and OpenGL ES versions, for example OpenGL 4.8 if 5.0 comes out
    /// before the 4.x series gets that far, also fail with this error and not glfw.ErrorCode.InvalidValue,
    /// because GLFW cannot know what future versions will exist.
    VersionUnavailable,

    /// A platform-specific error occurred that does not match any of the more specific categories.
    ///
    /// A bug or configuration error in GLFW, the underlying operating system or its drivers, or a
    /// lack of required resources. Report the issue to our [issue tracker](https://github.com/glfw/glfw/issues).
    PlatformError,

    /// The requested format is not supported or available.
    ///
    /// If emitted during window creation, the requested pixel format is not supported.
    ///
    /// If emitted when querying the clipboard, the contents of the clipboard could not be
    /// converted to the requested format.
    ///
    /// If emitted during window creation, one or more hard constraints did not match any of the
    /// available pixel formats. If your application is sufficiently flexible, downgrade your
    /// requirements and try again. Otherwise, inform the user that their machine does not match
    /// your requirements.
    ///
    /// If emitted when querying the clipboard, ignore the error or report it to the user, as
    /// appropriate.
    FormatUnavailable,

    /// The specified window does not have an OpenGL or OpenGL ES context.
    ///
    /// A window that does not have an OpenGL or OpenGL ES context was passed to a function that
    /// requires it to have one.
    NoWindowContext,

    /// The specified cursor shape is not available.
    ///
    /// The specified standard cursor shape is not available, either because the
    /// current platform cursor theme does not provide it or because it is not
    /// available on the platform.
    ///
    /// analysis: Platform or system settings limitation. Pick another standard cursor shape or
    /// create a custom cursor.
    CursorUnavailable,

    /// The requested feature is not provided by the platform.
    ///
    /// The requested feature is not provided by the platform, so GLFW is unable to
    /// implement it. The documentation for each function notes if it could emit
    /// this error.
    ///
    /// analysis: Platform or platform version limitation. The error can be ignored
    /// unless the feature is critical to the application.
    ///
    /// A function call that emits this error has no effect other than the error and
    /// updating any existing out parameters.
    ///
    FeatureUnavailable,

    /// The requested feature is not implemented for the platform.
    ///
    /// The requested feature has not yet been implemented in GLFW for this platform.
    ///
    /// analysis: An incomplete implementation of GLFW for this platform, hopefully
    /// fixed in a future release. The error can be ignored unless the feature is
    /// critical to the application.
    ///
    /// A function call that emits this error has no effect other than the error and
    /// updating any existing out parameters.
    ///
    FeatureUnimplemented,

    /// Platform unavailable or no matching platform was found.
    ///
    /// If emitted during initialization, no matching platform was found. If glfw.InitHint.platform
    /// is set to `.any_platform`, GLFW could not detect any of the platforms supported by this
    /// library binary, except for the Null platform. If set to a specific platform, it is either
    /// not supported by this library binary or GLFW was not able to detect it.
    ///
    /// If emitted by a native access function, GLFW was initialized for a different platform
    /// than the function is for.
    ///
    /// analysis: Failure to detect any platform usually only happens on non-macOS Unix
    /// systems, either when no window system is running or the program was run from
    /// a terminal that does not have the necessary environment variables. Fall back to
    /// a different platform if possible or notify the user that no usable platform was
    /// detected.
    ///
    /// Failure to detect a specific platform may have the same cause as above or be because
    /// support for that platform was not compiled in. Call glfw.platformSupported to
    /// check whether a specific platform is supported by a library binary.
    ///
    PlatformUnavailable,
};

/// An error produced by GLFW and the description associated with it.
pub const Error = struct {
    error_code: ErrorCode,
    description: [:0]const u8,
};

fn convertError(e: c_int) ErrorCode!void {
    return switch (e) {
        c.GLFW_NO_ERROR => {},
        c.GLFW_NOT_INITIALIZED => ErrorCode.NotInitialized,
        c.GLFW_NO_CURRENT_CONTEXT => ErrorCode.NoCurrentContext,
        c.GLFW_INVALID_ENUM => ErrorCode.InvalidEnum,
        c.GLFW_INVALID_VALUE => ErrorCode.InvalidValue,
        c.GLFW_OUT_OF_MEMORY => ErrorCode.OutOfMemory,
        c.GLFW_API_UNAVAILABLE => ErrorCode.APIUnavailable,
        c.GLFW_VERSION_UNAVAILABLE => ErrorCode.VersionUnavailable,
        c.GLFW_PLATFORM_ERROR => ErrorCode.PlatformError,
        c.GLFW_FORMAT_UNAVAILABLE => ErrorCode.FormatUnavailable,
        c.GLFW_NO_WINDOW_CONTEXT => ErrorCode.NoWindowContext,
        c.GLFW_CURSOR_UNAVAILABLE => ErrorCode.CursorUnavailable,
        c.GLFW_FEATURE_UNAVAILABLE => ErrorCode.FeatureUnavailable,
        c.GLFW_FEATURE_UNIMPLEMENTED => ErrorCode.FeatureUnimplemented,
        c.GLFW_PLATFORM_UNAVAILABLE => ErrorCode.PlatformUnavailable,
        else => unreachable,
    };
}

/// Clears the last error and the error description pointer for the calling thread. Does nothing if
/// no error has occurred since the last call.
///
/// @remark This function may be called before @ref glfwInit.
///
/// @thread_safety This function may be called from any thread.
pub inline fn clearError() void {
    _ = c.glfwGetError(null);
}

/// Returns and clears the last error for the calling thread.
///
/// This function returns and clears the error code of the last error that occurred on the calling
/// thread, along with a UTF-8 encoded human-readable description of it. If no error has occurred
/// since the last call, it returns GLFW_NO_ERROR (zero) and the description pointer is set to
/// `NULL`.
///
/// @pointer_lifetime The returned string is allocated and freed by GLFW. You should not free it
/// yourself. It is guaranteed to be valid only until the next error occurs or the library is
/// terminated.
///
/// @remark This function may be called before @ref glfwInit.
///
/// @thread_safety This function may be called from any thread.
pub inline fn getError() ?Error {
    var desc: [*c]const u8 = null;
    convertError(c.glfwGetError(&desc)) catch |error_code| {
        return .{
            .error_code = error_code,
            .description = mem.sliceTo(desc, 0),
        };
    };
    return null;
}

pub inline fn mustGetError() Error {
    return getError() orelse {
        @panic("glfw: mustGetError called but no error is present");
    };
}

/// Returns and clears the last error for the calling thread.
///
/// This function returns and clears the error code of the last error that occurred on the calling
/// thread. If no error has occurred since the last call, it returns GLFW_NO_ERROR (zero).
///
/// @return The last error code for the calling thread, or @ref GLFW_NO_ERROR (zero).
///
/// @remark This function may be called before @ref glfwInit.
///
/// @thread_safety This function may be called from any thread.
pub inline fn getErrorCode() ErrorCode!void {
    return convertError(c.glfwGetError(null));
}

/// Returns and clears the last error code for the calling thread. If no error is present, this
/// function panics.
pub inline fn mustGetErrorCode() ErrorCode {
    try getErrorCode();
    @panic("glfw: mustGetErrorCode called but no error is present");
}

/// Returns and clears the last error description for the calling thread.
///
/// This function returns a UTF-8 encoded human-readable description of the last error that occured
/// on the calling thread. If no error has occurred since the last call, it returns null.
///
/// @pointer_lifetime The returned string is allocated and freed by GLFW. You should not free it
/// yourself. It is guaranteed to be valid only until the next error occurs or the library is
/// terminated.
///
/// @remark This function may be called before @ref glfwInit.
///
/// @thread_safety This function may be called from any thread.
pub inline fn getErrorString() ?[:0]const u8 {
    var desc: [*c]const u8 = null;
    const error_code = c.glfwGetError(&desc);
    if (error_code != c.GLFW_NO_ERROR) {
        return mem.sliceTo(desc, 0);
    }
    return null;
}

/// Returns and clears the last error description for the calling thread. If no error is present,
/// this function panics.
pub inline fn mustGetErrorString() [:0]const u8 {
    return getErrorString() orelse {
        @panic("glfw: mustGetErrorString called but no error is present");
    };
}

/// Sets the error callback.
///
/// This function sets the error callback, which is called with an error code
/// and a human-readable description each time a GLFW error occurs.
///
/// The error code is set before the callback is called. Calling @ref
/// glfwGetError from the error callback will return the same value as the error
/// code argument.
///
/// The error callback is called on the thread where the error occurred. If you
/// are using GLFW from multiple threads, your error callback needs to be
/// written accordingly.
///
/// Because the description string may have been generated specifically for that
/// error, it is not guaranteed to be valid after the callback has returned. If
/// you wish to use it after the callback returns, you need to make a copy.
///
/// Once set, the error callback remains set even after the library has been
/// terminated.
///
/// @param[in] callback The new callback, or `NULL` to remove the currently set
/// callback.
///
/// @callback_param `error_code` An error code. Future releases may add more error codes.
/// @callback_param `description` A UTF-8 encoded string describing the error.
///
/// @errors None.
///
/// @remark This function may be called before @ref glfwInit.
///
/// @thread_safety This function must only be called from the main thread.
pub fn setErrorCallback(comptime callback: ?fn (error_code: ErrorCode, description: [:0]const u8) void) void {
    if (callback) |user_callback| {
        const CWrapper = struct {
            pub fn errorCallbackWrapper(err_int: c_int, c_description: [*c]const u8) callconv(.c) void {
                convertError(err_int) catch |error_code| {
                    user_callback(error_code, mem.sliceTo(c_description, 0));
                };
            }
        };

        _ = c.glfwSetErrorCallback(CWrapper.errorCallbackWrapper);
        return;
    }

    _ = c.glfwSetErrorCallback(null);
}

test "set error callback" {
    const TestStruct = struct {
        pub fn callback(_: ErrorCode, _: [:0]const u8) void {}
    };
    setErrorCallback(TestStruct.callback);
}

test "error string" {
    try testing.expect(getErrorString() == null);
}

test "error code" {
    try getErrorCode();
}

test "error code and string" {
    try testing.expect(getError() == null);
}

test "clear error" {
    clearError();
}
