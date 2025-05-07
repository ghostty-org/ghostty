//! Window type and related functions

const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const c = @import("c.zig").c;

const glfw = @import("main.zig");
const Image = @import("Image.zig");
const Monitor = @import("Monitor.zig");
const Cursor = @import("Cursor.zig");
const Key = @import("key.zig").Key;
const Action = @import("action.zig").Action;
const Mods = @import("mod.zig").Mods;
const MouseButton = @import("mouse_button.zig").MouseButton;

const internal_debug = @import("internal_debug.zig");

const Window = @This();

handle: *c.GLFWwindow,

/// Returns a Zig GLFW window from an underlying C GLFW window handle.
pub inline fn from(handle: *anyopaque) Window {
    return Window{ .handle = @as(*c.GLFWwindow, @ptrCast(@alignCast(handle))) };
}

/// Resets all window hints to their default values.
///
/// This function resets all window hints to their default values.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: window_hints, glfw.Window.hint, glfw.Window.hintString
pub inline fn defaultHints() void {
    internal_debug.assertInitialized();
    c.glfwDefaultWindowHints();
}

/// Window hints
const Hint = enum(c_int) {
    resizable = c.GLFW_RESIZABLE,
    visible = c.GLFW_VISIBLE,
    decorated = c.GLFW_DECORATED,
    focused = c.GLFW_FOCUSED,
    auto_iconify = c.GLFW_AUTO_ICONIFY,
    floating = c.GLFW_FLOATING,
    maximized = c.GLFW_MAXIMIZED,
    center_cursor = c.GLFW_CENTER_CURSOR,
    transparent_framebuffer = c.GLFW_TRANSPARENT_FRAMEBUFFER,
    focus_on_show = c.GLFW_FOCUS_ON_SHOW,
    mouse_passthrough = c.GLFW_MOUSE_PASSTHROUGH,
    position_x = c.GLFW_POSITION_X,
    position_y = c.GLFW_POSITION_Y,
    scale_to_monitor = c.GLFW_SCALE_TO_MONITOR,

    /// Framebuffer hints
    red_bits = c.GLFW_RED_BITS,
    green_bits = c.GLFW_GREEN_BITS,
    blue_bits = c.GLFW_BLUE_BITS,
    alpha_bits = c.GLFW_ALPHA_BITS,
    depth_bits = c.GLFW_DEPTH_BITS,
    stencil_bits = c.GLFW_STENCIL_BITS,
    accum_red_bits = c.GLFW_ACCUM_RED_BITS,
    accum_green_bits = c.GLFW_ACCUM_GREEN_BITS,
    accum_blue_bits = c.GLFW_ACCUM_BLUE_BITS,
    accum_alpha_bits = c.GLFW_ACCUM_ALPHA_BITS,
    aux_buffers = c.GLFW_AUX_BUFFERS,

    /// Framebuffer MSAA samples
    samples = c.GLFW_SAMPLES,

    /// Monitor refresh rate
    refresh_rate = c.GLFW_REFRESH_RATE,

    /// OpenGL stereoscopic rendering
    stereo = c.GLFW_STEREO,

    /// Framebuffer sRGB
    srgb_capable = c.GLFW_SRGB_CAPABLE,

    /// Framebuffer double buffering
    doublebuffer = c.GLFW_DOUBLEBUFFER,

    client_api = c.GLFW_CLIENT_API,
    context_creation_api = c.GLFW_CONTEXT_CREATION_API,

    context_version_major = c.GLFW_CONTEXT_VERSION_MAJOR,
    context_version_minor = c.GLFW_CONTEXT_VERSION_MINOR,

    context_robustness = c.GLFW_CONTEXT_ROBUSTNESS,
    context_release_behavior = c.GLFW_CONTEXT_RELEASE_BEHAVIOR,
    context_no_error = c.GLFW_CONTEXT_NO_ERROR,
    // NOTE: This supersedes opengl_debug_context / GLFW_OPENGL_DEBUG_CONTEXT
    context_debug = c.GLFW_CONTEXT_DEBUG,

    opengl_forward_compat = c.GLFW_OPENGL_FORWARD_COMPAT,
    opengl_profile = c.GLFW_OPENGL_PROFILE,

    /// macOS specific
    cocoa_retina_framebuffer = c.GLFW_COCOA_RETINA_FRAMEBUFFER,

    /// macOS specific
    cocoa_frame_name = c.GLFW_COCOA_FRAME_NAME,

    /// macOS specific
    cocoa_graphics_switching = c.GLFW_COCOA_GRAPHICS_SWITCHING,

    /// X11 specific
    x11_class_name = c.GLFW_X11_CLASS_NAME,

    /// X11 specific
    x11_instance_name = c.GLFW_X11_INSTANCE_NAME,

    /// Windows specific
    win32_keyboard_menu = c.GLFW_WIN32_KEYBOARD_MENU,

    /// Allows specification of the Wayland app_id.
    wayland_app_id = c.GLFW_WAYLAND_APP_ID,
};

/// Window hints
pub const Hints = struct {
    // Note: The defaults here are directly from the GLFW source of the glfwDefaultWindowHints function
    resizable: bool = true,
    visible: bool = true,
    decorated: bool = true,
    focused: bool = true,
    auto_iconify: bool = true,
    floating: bool = false,
    maximized: bool = false,
    center_cursor: bool = true,
    transparent_framebuffer: bool = false,
    focus_on_show: bool = true,
    mouse_passthrough: bool = false,
    position_x: c_int = @intFromEnum(Position.any),
    position_y: c_int = @intFromEnum(Position.any),

    scale_to_monitor: bool = false,

    /// Framebuffer hints
    red_bits: ?PositiveCInt = 8,
    green_bits: ?PositiveCInt = 8,
    blue_bits: ?PositiveCInt = 8,
    alpha_bits: ?PositiveCInt = 8,
    depth_bits: ?PositiveCInt = 24,
    stencil_bits: ?PositiveCInt = 8,
    accum_red_bits: ?PositiveCInt = 0,
    accum_green_bits: ?PositiveCInt = 0,
    accum_blue_bits: ?PositiveCInt = 0,
    accum_alpha_bits: ?PositiveCInt = 0,
    aux_buffers: ?PositiveCInt = 0,

    /// Framebuffer MSAA samples
    samples: ?PositiveCInt = 0,

    /// Monitor refresh rate
    refresh_rate: ?PositiveCInt = null,

    /// OpenGL stereoscopic rendering
    stereo: bool = false,

    /// Framebuffer sRGB
    srgb_capable: bool = false,

    /// Framebuffer double buffering
    doublebuffer: bool = true,

    client_api: ClientAPI = .opengl_api,
    context_creation_api: ContextCreationAPI = .native_context_api,

    context_version_major: c_int = 1,
    context_version_minor: c_int = 0,

    context_robustness: ContextRobustness = .no_robustness,
    context_release_behavior: ContextReleaseBehavior = .any_release_behavior,

    /// Note: disables the context creating errors,
    /// instead turning them into undefined behavior.
    context_no_error: bool = false,
    context_debug: bool = false,

    opengl_forward_compat: bool = false,

    opengl_profile: OpenGLProfile = .opengl_any_profile,

    /// macOS specific
    cocoa_retina_framebuffer: bool = true,

    /// macOS specific
    cocoa_frame_name: [:0]const u8 = "",

    /// macOS specific
    cocoa_graphics_switching: bool = false,

    /// X11 specific
    x11_class_name: [:0]const u8 = "",

    /// X11 specific
    x11_instance_name: [:0]const u8 = "",

    /// Windows specific
    win32_keyboard_menu: bool = false,

    /// Allows specification of the Wayland app_id.
    wayland_app_id: [:0]const u8 = "",

    pub const PositiveCInt = std.math.IntFittingRange(0, std.math.maxInt(c_int));

    pub const ClientAPI = enum(c_int) {
        opengl_api = c.GLFW_OPENGL_API,
        opengl_es_api = c.GLFW_OPENGL_ES_API,
        no_api = c.GLFW_NO_API,
    };

    pub const ContextCreationAPI = enum(c_int) {
        native_context_api = c.GLFW_NATIVE_CONTEXT_API,
        egl_context_api = c.GLFW_EGL_CONTEXT_API,
        osmesa_context_api = c.GLFW_OSMESA_CONTEXT_API,
    };

    pub const ContextRobustness = enum(c_int) {
        no_robustness = c.GLFW_NO_ROBUSTNESS,
        no_reset_notification = c.GLFW_NO_RESET_NOTIFICATION,
        lose_context_on_reset = c.GLFW_LOSE_CONTEXT_ON_RESET,
    };

    pub const ContextReleaseBehavior = enum(c_int) {
        any_release_behavior = c.GLFW_ANY_RELEASE_BEHAVIOR,
        release_behavior_flush = c.GLFW_RELEASE_BEHAVIOR_FLUSH,
        release_behavior_none = c.GLFW_RELEASE_BEHAVIOR_NONE,
    };

    pub const OpenGLProfile = enum(c_int) {
        opengl_any_profile = c.GLFW_OPENGL_ANY_PROFILE,
        opengl_compat_profile = c.GLFW_OPENGL_COMPAT_PROFILE,
        opengl_core_profile = c.GLFW_OPENGL_CORE_PROFILE,
    };

    pub const Position = enum(c_int) {
        /// By default, newly created windows use the placement recommended by the window system,
        ///
        /// To create the window at a specific position, make it initially invisible using the
        /// Window.Hint.visible hint, set its Window.Hint.position and then Window.hide() it.
        ///
        /// To create the window at a specific position, set the Window.Hint.position_x and
        /// Window.Hint.position_y hints before creation. To restore the default behavior, set
        /// either or both hints back to Window.Hints.Position.any
        any = @bitCast(c.GLFW_ANY_POSITION),
    };

    fn set(hints: Hints) void {
        internal_debug.assertInitialized();
        inline for (comptime std.meta.fieldNames(Hint)) |field_name| {
            const hint_tag = @intFromEnum(@field(Hint, field_name));
            const hint_value = @field(hints, field_name);
            switch (@TypeOf(hint_value)) {
                bool => c.glfwWindowHint(hint_tag, @intFromBool(hint_value)),
                ?PositiveCInt => c.glfwWindowHint(hint_tag, if (hint_value) |unwrapped| unwrapped else glfw.dont_care),
                c_int => c.glfwWindowHint(hint_tag, hint_value),

                ClientAPI,
                ContextCreationAPI,
                ContextRobustness,
                ContextReleaseBehavior,
                OpenGLProfile,
                Position,
                => c.glfwWindowHint(hint_tag, @intFromEnum(hint_value)),

                [:0]const u8 => c.glfwWindowHintString(hint_tag, hint_value.ptr),

                else => unreachable,
            }
        }
    }
};

/// Creates a window and its associated context.
///
/// This function creates a window and its associated OpenGL or OpenGL ES context. Most of the
/// options controlling how the window and its context should be created are specified with window
/// hints using `glfw.Window.hint`.
///
/// Successful creation does not change which context is current. Before you can use the newly
/// created context, you need to make it current using `glfw.makeContextCurrent`. For
/// information about the `share` parameter, see context_sharing.
///
/// The created window, framebuffer and context may differ from what you requested, as not all
/// parameters and hints are hard constraints. This includes the size of the window, especially for
/// full screen windows. To query the actual attributes of the created window, framebuffer and
/// context, see glfw.Window.getAttrib, glfw.Window.getSize and glfw.window.getFramebufferSize.
///
/// To create a full screen window, you need to specify the monitor the window will cover. If no
/// monitor is specified, the window will be windowed mode. Unless you have a way for the user to
/// choose a specific monitor, it is recommended that you pick the primary monitor. For more
/// information on how to query connected monitors, see @ref monitor_monitors.
///
/// For full screen windows, the specified size becomes the resolution of the window's _desired
/// video mode_. As long as a full screen window is not iconified, the supported video mode most
/// closely matching the desired video mode is set for the specified monitor. For more information
/// about full screen windows, including the creation of so called _windowed full screen_ or
/// _borderless full screen_ windows, see window_windowed_full_screen.
///
/// Once you have created the window, you can switch it between windowed and full screen mode with
/// glfw.Window.setMonitor. This will not affect its OpenGL or OpenGL ES context.
///
/// By default, newly created windows use the placement recommended by the window system. To create
/// the window at a specific position, make it initially invisible using the `visible` window
/// hint, set its position and then show it.
///
/// As long as at least one full screen window is not iconified, the screensaver is prohibited from
/// starting.
///
/// Window systems put limits on window sizes. Very large or very small window dimensions may be
/// overridden by the window system on creation. Check the actual size after creation.
///
/// The swap interval is not set during window creation and the initial value may vary depending on
/// driver settings and defaults.
///
/// Possible errors include glfw.ErrorCode.InvalidEnum, glfw.ErrorCode.InvalidValue,
/// glfw.ErrorCode.APIUnavailable, glfw.ErrorCode.VersionUnavailable, glfw.ErrorCode.FormatUnavailable and
/// glfw.ErrorCode.PlatformError.
/// Returns null in the event of an error.
///
/// Parameters are as follows:
///
/// * `width` The desired width, in screen coordinates, of the window.
/// * `height` The desired height, in screen coordinates, of the window.
/// * `title` The initial, UTF-8 encoded window title.
/// * `monitor` The monitor to use for full screen mode, or `null` for windowed mode.
/// * `share` The window whose context to share resources with, or `null` to not share resources.
///
/// win32: Window creation will fail if the Microsoft GDI software OpenGL implementation is the
/// only one available.
///
/// win32: If the executable has an icon resource named `GLFW_ICON`, it will be set as the initial
/// icon for the window. If no such icon is present, the `IDI_APPLICATION` icon will be used
/// instead. To set a different icon, see glfw.Window.setIcon.
///
/// win32: The context to share resources with must not be current on any other thread.
///
/// macos: The OS only supports forward-compatible core profile contexts for OpenGL versions 3.2
/// and later. Before creating an OpenGL context of version 3.2 or later you must set the
/// `glfw.opengl_forward_compat` and `glfw.opengl_profile` hints accordingly. OpenGL 3.0 and 3.1
/// contexts are not supported at all on macOS.
///
/// macos: The OS only supports core profile contexts for OpenGL versions 3.2 and later. Before
/// creating an OpenGL context of version 3.2 or later you must set the `glfw.opengl_profile` hint
/// accordingly. OpenGL 3.0 and 3.1 contexts are not supported at all on macOS.
///
/// macos: The GLFW window has no icon, as it is not a document window, but the dock icon will be
/// the same as the application bundle's icon. For more information on bundles, see the
/// [Bundle Programming Guide](https://developer.apple.com/library/mac/documentation/CoreFoundation/Conceptual/CFBundles/)
/// in the Mac Developer Library.
///
/// macos: On OS X 10.10 and later the window frame will not be rendered at full resolution on
/// Retina displays unless the glfw.cocoa_retina_framebuffer hint is true (1) and the `NSHighResolutionCapable`
/// key is enabled in the application bundle's `Info.plist`. For more information, see
/// [High Resolution Guidelines for OS X](https://developer.apple.com/library/mac/documentation/GraphicsAnimation/Conceptual/HighResolutionOSX/Explained/Explained.html)
/// in the Mac Developer Library. The GLFW test and example programs use a custom `Info.plist`
/// template for this, which can be found as `CMake/Info.plist.in` in the source tree.
///
/// macos: When activating frame autosaving with glfw.cocoa_frame_name, the specified window size
/// and position may be overridden by previously saved values.
///
/// x11: Some window managers will not respect the placement of initially hidden windows.
///
/// x11: Due to the asynchronous nature of X11, it may take a moment for a window to reach its
/// requested state. This means you may not be able to query the final size, position or other
/// attributes directly after window creation.
///
/// x11: The class part of the `WM_CLASS` window property will by default be set to the window title
/// passed to this function. The instance part will use the contents of the `RESOURCE_NAME`
/// environment variable, if present and not empty, or fall back to the window title. Set the glfw.x11_class_name
/// and glfw.x11_instance_name window hints to override this.
///
/// wayland: Compositors should implement the xdg-decoration protocol for GLFW to decorate the
/// window properly. If this protocol isn't supported, or if the compositor prefers client-side
/// decorations, a very simple fallback frame will be drawn using the wp_viewporter protocol. A
/// compositor can still emit close, maximize or fullscreen events, using for instance a keybind
/// mechanism. If neither of these protocols is supported, the window won't be decorated.
///
/// wayland: A full screen window will not attempt to change the mode, no matter what the
/// requested size or refresh rate.
///
/// wayland: Screensaver inhibition requires the idle-inhibit protocol to be implemented in the
/// user's compositor.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: window_creation, glfw.Window.destroy
pub inline fn create(
    width: u32,
    height: u32,
    title: [*:0]const u8,
    monitor: ?Monitor,
    share: ?Window,
    hints: Hints,
) ?Window {
    internal_debug.assertInitialized();
    const ignore_hints_struct = if (comptime @import("builtin").is_test) testing_ignore_window_hints_struct else false;
    if (!ignore_hints_struct) hints.set();

    if (c.glfwCreateWindow(
        @as(c_int, @intCast(width)),
        @as(c_int, @intCast(height)),
        &title[0],
        if (monitor) |m| m.handle else null,
        if (share) |w| w.handle else null,
    )) |handle| return from(handle);
    return null;
}

var testing_ignore_window_hints_struct = if (@import("builtin").is_test) false else @as(void, {});

/// Destroys the specified window and its context.
///
/// This function destroys the specified window and its context. On calling this function, no
/// further callbacks will be called for that window.
///
/// If the context of the specified window is current on the main thread, it is detached before
/// being destroyed.
///
/// note: The context of the specified window must not be current on any other thread when this
/// function is called.
///
/// Possible errors include glfw.ErrorCode.PlatformError.
///
/// @reentrancy This function must not be called from a callback.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: window_creation, glfw.Window.create
pub inline fn destroy(self: Window) void {
    internal_debug.assertInitialized();
    c.glfwDestroyWindow(self.handle);
}

/// Checks the close flag of the specified window.
///
/// This function returns the value of the close flag of the specified window.
///
/// @thread_safety This function may be called from any thread. Access is not synchronized.
///
/// see also: window_close
pub inline fn shouldClose(self: Window) bool {
    internal_debug.assertInitialized();
    return c.glfwWindowShouldClose(self.handle) == c.GLFW_TRUE;
}

/// Sets the close flag of the specified window.
///
/// This function sets the value of the close flag of the specified window. This can be used to
/// override the user's attempt to close the window, or to signal that it should be closed.
///
/// @thread_safety This function may be called from any thread. Access is not
/// synchronized.
///
/// see also: window_close
pub inline fn setShouldClose(self: Window, value: bool) void {
    internal_debug.assertInitialized();
    const boolean = if (value) c.GLFW_TRUE else c.GLFW_FALSE;
    c.glfwSetWindowShouldClose(self.handle, boolean);
}

/// Sets the UTF-8 encoded title of the specified window.
///
/// This function sets the window title, encoded as UTF-8, of the specified window.
///
/// Possible errors include glfw.ErrorCode.PlatformError.
///
/// macos: The window title will not be updated until the next time you process events.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: window_title
pub inline fn setTitle(self: Window, title: [*:0]const u8) void {
    internal_debug.assertInitialized();
    c.glfwSetWindowTitle(self.handle, title);
}

/// Sets the icon for the specified window.
///
/// This function sets the icon of the specified window. If passed an array of candidate images,
/// those of or closest to the sizes desired by the system are selected. If no images are
/// specified, the window reverts to its default icon.
///
/// The pixels are 32-bit, little-endian, non-premultiplied RGBA, i.e. eight bits per channel with
/// the red channel first. They are arranged canonically as packed sequential rows, starting from
/// the top-left corner.
///
/// The desired image sizes varies depending on platform and system settings. The selected images
/// will be rescaled as needed. Good sizes include 16x16, 32x32 and 48x48.
///
/// @pointer_lifetime The specified image data is copied before this function returns.
///
/// macos: Regular windows do not have icons on macOS. This function will emit FeatureUnavailable.
/// The dock icon will be the same as the application bundle's icon. For more information on
/// bundles, see the [Bundle Programming Guide](https://developer.apple.com/library/mac/documentation/CoreFoundation/Conceptual/CFBundles/)
/// in the Mac Developer Library.
///
/// wayland: There is no existing protocol to change an icon, the window will thus inherit the one
/// defined in the application's desktop file. This function will emit glfw.ErrorCode.FeatureUnavailable.
///
/// Possible errors include glfw.ErrorCode.InvalidValue, glfw.ErrorCode.FeatureUnavailable
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: window_icon
pub inline fn setIcon(self: Window, allocator: mem.Allocator, images: ?[]const Image) mem.Allocator.Error!void {
    internal_debug.assertInitialized();
    if (images) |im| {
        const tmp = try allocator.alloc(c.GLFWimage, im.len);
        defer allocator.free(tmp);
        for (im, 0..) |img, index| tmp[index] = img.toC();
        c.glfwSetWindowIcon(self.handle, @as(c_int, @intCast(im.len)), &tmp[0]);
    } else c.glfwSetWindowIcon(self.handle, 0, null);
}

pub const Pos = struct {
    x: i64,
    y: i64,
};

/// Retrieves the position of the content area of the specified window.
///
/// This function retrieves the position, in screen coordinates, of the upper-left corner of the
/// content area of the specified window.
///
/// Possible errors include glfw.ErrorCode.FeatureUnavailable.
/// Additionally returns a zero value in the event of an error.
///
/// wayland: There is no way for an application to retrieve the global position of its windows,
/// this function will always emit glfw.ErrorCode.FeatureUnavailable.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: window_pos glfw.Window.setPos
pub inline fn getPos(self: Window) Pos {
    internal_debug.assertInitialized();
    var x: c_int = 0;
    var y: c_int = 0;
    c.glfwGetWindowPos(self.handle, &x, &y);
    return Pos{ .x = @as(i64, @intCast(x)), .y = @as(i64, @intCast(y)) };
}

/// Sets the position of the content area of the specified window.
///
/// This function sets the position, in screen coordinates, of the upper-left corner of the content
/// area of the specified windowed mode window. If the window is a full screen window, this
/// function does nothing.
///
/// __Do not use this function__ to move an already visible window unless you have very good
/// reasons for doing so, as it will confuse and annoy the user.
///
/// The window manager may put limits on what positions are allowed. GLFW cannot and should not
/// override these limits.
///
/// Possible errors include glfw.ErrorCode.FeatureUnavailable.
///
/// wayland: There is no way for an application to set the global position of its windows, this
/// function will always emit glfw.ErrorCode.FeatureUnavailable.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: window_pos, glfw.Window.getPos
pub inline fn setPos(self: Window, pos: Pos) void {
    internal_debug.assertInitialized();
    c.glfwSetWindowPos(self.handle, @as(c_int, @intCast(pos.x)), @as(c_int, @intCast(pos.y)));
}

pub const Size = struct {
    width: u32,
    height: u32,
};

/// Retrieves the size of the content area of the specified window.
///
/// This function retrieves the size, in screen coordinates, of the content area of the specified
/// window. If you wish to retrieve the size of the framebuffer of the window in pixels, see
/// glfw.Window.getFramebufferSize.
///
/// Possible errors include glfw.ErrorCode.PlatformError.
/// Additionally returns a zero value in the event of an error.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: window_size, glfw.Window.setSize
pub inline fn getSize(self: Window) Size {
    internal_debug.assertInitialized();
    var width: c_int = 0;
    var height: c_int = 0;
    c.glfwGetWindowSize(self.handle, &width, &height);
    return Size{ .width = @as(u32, @intCast(width)), .height = @as(u32, @intCast(height)) };
}

/// Sets the size of the content area of the specified window.
///
/// This function sets the size, in screen coordinates, of the content area of the specified window.
///
/// For full screen windows, this function updates the resolution of its desired video mode and
/// switches to the video mode closest to it, without affecting the window's context. As the
/// context is unaffected, the bit depths of the framebuffer remain unchanged.
///
/// If you wish to update the refresh rate of the desired video mode in addition to its resolution,
/// see glfw.Window.setMonitor.
///
/// The window manager may put limits on what sizes are allowed. GLFW cannot and should not
/// override these limits.
///
/// Possible errors include glfw.ErrorCode.PlatformError.
///
/// wayland: A full screen window will not attempt to change the mode, no matter what the requested
/// size.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: window_size, glfw.Window.getSize, glfw.Window.SetMonitor
pub inline fn setSize(self: Window, size: Size) void {
    internal_debug.assertInitialized();
    c.glfwSetWindowSize(self.handle, @as(c_int, @intCast(size.width)), @as(c_int, @intCast(size.height)));
}

/// A size with option width/height, used to represent e.g. constraints on a windows size while
/// allowing specific axis to be unconstrained (null) if desired.
pub const SizeOptional = struct {
    width: ?u32 = null,
    height: ?u32 = null,
};

/// Sets the size limits of the specified window's content area.
///
/// This function sets the size limits of the content area of the specified window. If the window
/// is full screen, the size limits only take effect/ once it is made windowed. If the window is not
/// resizable, this function does nothing.
///
/// The size limits are applied immediately to a windowed mode window and may cause it to be resized.
///
/// The maximum dimensions must be greater than or equal to the minimum dimensions. glfw.dont_care
/// may be used for any width/height parameter.
///
/// Possible errors include glfw.ErrorCode.InvalidValue and glfw.ErrorCode.PlatformError.
///
/// If you set size limits and an aspect ratio that conflict, the results are undefined.
///
/// wayland: The size limits will not be applied until the window is actually resized, either by
/// the user or by the compositor.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: window_sizelimits, glfw.Window.setAspectRatio
pub inline fn setSizeLimits(self: Window, min: SizeOptional, max: SizeOptional) void {
    internal_debug.assertInitialized();

    if (min.width != null and max.width != null) {
        std.debug.assert(min.width.? <= max.width.?);
    }
    if (min.height != null and max.height != null) {
        std.debug.assert(min.height.? <= max.height.?);
    }

    c.glfwSetWindowSizeLimits(
        self.handle,
        if (min.width) |min_width| @as(c_int, @intCast(min_width)) else glfw.dont_care,
        if (min.height) |min_height| @as(c_int, @intCast(min_height)) else glfw.dont_care,
        if (max.width) |max_width| @as(c_int, @intCast(max_width)) else glfw.dont_care,
        if (max.height) |max_height| @as(c_int, @intCast(max_height)) else glfw.dont_care,
    );
}

/// Sets the aspect ratio of the specified window.
///
/// This function sets the required aspect ratio of the content area of the specified window. If
/// the window is full screen, the aspect ratio only takes effect once it is made windowed. If the
/// window is not resizable, this function does nothing.
///
/// The aspect ratio is specified as a numerator and a denominator and both values must be greater
/// than zero. For example, the common 16:9 aspect ratio is specified as 16 and 9, respectively.
///
/// If the numerator AND denominator is set to `glfw.dont_care` then the aspect ratio limit is
/// disabled.
///
/// The aspect ratio is applied immediately to a windowed mode window and may cause it to be
/// resized.
///
/// Possible errors include glfw.ErrorCode.InvalidValue and glfw.ErrorCode.PlatformError.
///
/// If you set size limits and an aspect ratio that conflict, the results are undefined.
///
/// wayland: The aspect ratio will not be applied until the window is actually resized, either by
/// the user or by the compositor.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: window_sizelimits, glfw.Window.setSizeLimits
///
/// WARNING: on wayland it will return glfw.ErrorCode.FeatureUnimplemented
pub inline fn setAspectRatio(self: Window, numerator: ?u32, denominator: ?u32) void {
    internal_debug.assertInitialized();

    if (numerator != null and denominator != null) {
        std.debug.assert(numerator.? > 0);
        std.debug.assert(denominator.? > 0);
    }

    c.glfwSetWindowAspectRatio(
        self.handle,
        if (numerator) |numerator_unwrapped| @as(c_int, @intCast(numerator_unwrapped)) else glfw.dont_care,
        if (denominator) |denominator_unwrapped| @as(c_int, @intCast(denominator_unwrapped)) else glfw.dont_care,
    );
}

/// Retrieves the size of the framebuffer of the specified window.
///
/// This function retrieves the size, in pixels, of the framebuffer of the specified window. If you
/// wish to retrieve the size of the window in screen coordinates, see @ref glfwGetWindowSize.
///
/// Possible errors include glfw.ErrorCode.PlatformError.
/// Additionally returns a zero value in the event of an error.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: window_fbsize, glfwWindow.setFramebufferSizeCallback
pub inline fn getFramebufferSize(self: Window) Size {
    internal_debug.assertInitialized();
    var width: c_int = 0;
    var height: c_int = 0;
    c.glfwGetFramebufferSize(self.handle, &width, &height);
    return Size{ .width = @as(u32, @intCast(width)), .height = @as(u32, @intCast(height)) };
}

pub const FrameSize = struct {
    left: u32,
    top: u32,
    right: u32,
    bottom: u32,
};

/// Retrieves the size of the frame of the window.
///
/// This function retrieves the size, in screen coordinates, of each edge of the frame of the
/// specified window. This size includes the title bar, if the window has one. The size of the
/// frame may vary depending on the window-related hints used to create it.
///
/// Because this function retrieves the size of each window frame edge and not the offset along a
/// particular coordinate axis, the retrieved values will always be zero or positive.
///
/// Possible errors include glfw.ErrorCode.PlatformError.
/// Additionally returns a zero value in the event of an error.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: window_size
pub inline fn getFrameSize(self: Window) FrameSize {
    internal_debug.assertInitialized();
    var left: c_int = 0;
    var top: c_int = 0;
    var right: c_int = 0;
    var bottom: c_int = 0;
    c.glfwGetWindowFrameSize(self.handle, &left, &top, &right, &bottom);
    return FrameSize{
        .left = @as(u32, @intCast(left)),
        .top = @as(u32, @intCast(top)),
        .right = @as(u32, @intCast(right)),
        .bottom = @as(u32, @intCast(bottom)),
    };
}

pub const ContentScale = struct {
    x_scale: f32,
    y_scale: f32,
};

/// Retrieves the content scale for the specified window.
///
/// This function retrieves the content scale for the specified window. The content scale is the
/// ratio between the current DPI and the platform's default DPI. This is especially important for
/// text and any UI elements. If the pixel dimensions of your UI scaled by this look appropriate on
/// your machine then it should appear at a reasonable size on other machines regardless of their
/// DPI and scaling settings. This relies on the system DPI and scaling settings being somewhat
/// correct.
///
/// On platforms where each monitors can have its own content scale, the window content scale will
/// depend on which monitor the system considers the window to be on.
///
/// Possible errors include glfw.ErrorCode.PlatformError.
/// Additionally returns a zero value in the event of an error.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: window_scale, glfwSetWindowContentScaleCallback, glfwGetMonitorContentScale
pub inline fn getContentScale(self: Window) ContentScale {
    internal_debug.assertInitialized();
    var x_scale: f32 = 0;
    var y_scale: f32 = 0;
    c.glfwGetWindowContentScale(self.handle, &x_scale, &y_scale);
    return ContentScale{ .x_scale = x_scale, .y_scale = y_scale };
}

/// Returns the opacity of the whole window.
///
/// This function returns the opacity of the window, including any decorations.
///
/// The opacity (or alpha) value is a positive finite number between zero and one, where zero is
/// fully transparent and one is fully opaque. If the system does not support whole window
/// transparency, this function always returns one.
///
/// The initial opacity value for newly created windows is one.
///
/// Possible errors include glfw.ErrorCode.PlatformError.
/// Additionally returns a zero value in the event of an error.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: window_transparency, glfw.Window.setOpacity
pub inline fn getOpacity(self: Window) f32 {
    internal_debug.assertInitialized();
    const opacity = c.glfwGetWindowOpacity(self.handle);
    return opacity;
}

/// Sets the opacity of the whole window.
///
/// This function sets the opacity of the window, including any decorations.
///
/// The opacity (or alpha) value is a positive finite number between zero and one, where zero is
/// fully transparent and one is fully opaque.
///
/// The initial opacity value for newly created windows is one.
///
/// A window created with framebuffer transparency may not use whole window transparency. The
/// results of doing this are undefined.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: window_transparency, glfw.Window.getOpacity
pub inline fn setOpacity(self: Window, opacity: f32) void {
    internal_debug.assertInitialized();
    c.glfwSetWindowOpacity(self.handle, opacity);
}

/// Iconifies the specified window.
///
/// This function iconifies (minimizes) the specified window if it was previously restored. If the
/// window is already iconified, this function does nothing.
///
/// If the specified window is a full screen window, GLFW restores the original video mode of the
/// monitor. The window's desired video mode is set again when the window is restored.
///
/// Possible errors include glfw.ErrorCode.PlatformError.
///
/// wayland: Once a window is iconified, glfw.Window.restorebe able to restore it. This is a design
/// decision of the xdg-shell protocol.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: window_iconify, glfw.Window.restore, glfw.Window.maximize
pub inline fn iconify(self: Window) void {
    internal_debug.assertInitialized();
    c.glfwIconifyWindow(self.handle);
}

/// Restores the specified window.
///
/// This function restores the specified window if it was previously iconified (minimized) or
/// maximized. If the window is already restored, this function does nothing.
///
/// If the specified window is an iconified full screen window, its desired video mode is set
/// again for its monitor when the window is restored.
///
/// Possible errors include glfw.ErrorCode.PlatformError.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: window_iconify, glfw.Window.iconify, glfw.Window.maximize
pub inline fn restore(self: Window) void {
    internal_debug.assertInitialized();
    c.glfwRestoreWindow(self.handle);
}

/// Maximizes the specified window.
///
/// This function maximizes the specified window if it was previously not maximized. If the window
/// is already maximized, this function does nothing.
///
/// If the specified window is a full screen window, this function does nothing.
///
/// Possible errors include glfw.ErrorCode.PlatformError.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: window_iconify, glfw.Window.iconify, glfw.Window.restore
pub inline fn maximize(self: Window) void {
    internal_debug.assertInitialized();
    c.glfwMaximizeWindow(self.handle);
}

/// Makes the specified window visible.
///
/// This function makes the specified window visible if it was previously hidden. If the window is
/// already visible or is in full screen mode, this function does nothing.
///
/// By default, windowed mode windows are focused when shown Set the glfw.focus_on_show window hint
/// to change this behavior for all newly created windows, or change the
/// behavior for an existing window with glfw.Window.setAttrib.
///
/// wayland: Because Wayland wants every frame of the desktop to be complete, this function does
/// not immediately make the window visible. Instead it will become visible the next time the window
/// framebuffer is updated after this call.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: window_hide, glfw.Window.hide
///
/// WARNING: on wayland it will return glfw.ErrorCode.FeatureUnavailable
pub inline fn show(self: Window) void {
    internal_debug.assertInitialized();
    c.glfwShowWindow(self.handle);
}

/// Hides the specified window.
///
/// This function hides the specified window if it was previously visible. If the window is already
/// hidden or is in full screen mode, this function does nothing.
///
/// Possible errors include glfw.ErrorCode.PlatformError.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: window_hide, glfw.Window.show
pub inline fn hide(self: Window) void {
    internal_debug.assertInitialized();
    c.glfwHideWindow(self.handle);
}

/// Brings the specified window to front and sets input focus.
///
/// This function brings the specified window to front and sets input focus. The window should
/// already be visible and not iconified.
///
/// By default, both windowed and full screen mode windows are focused when initially created. Set
/// the glfw.focused to disable this behavior.
///
/// Also by default, windowed mode windows are focused when shown with glfw.Window.show. Set the
/// glfw.focus_on_show to disable this behavior.
///
/// __Do not use this function__ to steal focus from other applications unless you are certain that
/// is what the user wants. Focus stealing can be extremely disruptive.
///
/// For a less disruptive way of getting the user's attention, see [attention requests (window_attention).
///
/// wayland It is not possible for an application to set the input focus. This function will emit
/// glfw.ErrorCode.FeatureUnavailable.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: window_focus, window_attention
pub inline fn focus(self: Window) void {
    internal_debug.assertInitialized();
    c.glfwFocusWindow(self.handle);
}

/// Requests user attention to the specified window.
///
/// This function requests user attention to the specified window. On platforms where this is not
/// supported, attention is requested to the application as a whole.
///
/// Once the user has given attention, usually by focusing the window or application, the system will end the request automatically.
///
/// Possible errors include glfw.ErrorCode.PlatformError.
///
/// macos: Attention is requested to the application as a whole, not the
/// specific window.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: window_attention
///
/// WARNING: on wayland it will return glfw.ErrorCode.FeatureUnimplemented
pub inline fn requestAttention(self: Window) void {
    internal_debug.assertInitialized();
    c.glfwRequestWindowAttention(self.handle);
}

/// Swaps the front and back buffers of the specified window.
///
/// This function swaps the front and back buffers of the specified window when rendering with
/// OpenGL or OpenGL ES. If the swap interval is greater than zero, the GPU driver waits the
/// specified number of screen updates before swapping the buffers.
///
/// The specified window must have an OpenGL or OpenGL ES context. Specifying a window without a
/// context will generate glfw.ErrorCode.NoWindowContext.
///
/// This function does not apply to Vulkan. If you are rendering with Vulkan, see `vkQueuePresentKHR`
/// instead.
///
/// @param[in] window The window whose buffers to swap.
///
/// Possible errors include glfw.ErrorCode.NoWindowContext and glfw.ErrorCode.PlatformError.
///
/// __EGL:__ The context of the specified window must be current on the calling thread.
///
/// @thread_safety This function may be called from any thread.
///
/// see also: buffer_swap, glfwSwapInterval
pub inline fn swapBuffers(self: Window) void {
    internal_debug.assertInitialized();
    c.glfwSwapBuffers(self.handle);
}

/// Returns the monitor that the window uses for full screen mode.
///
/// This function returns the handle of the monitor that the specified window is in full screen on.
///
/// @return The monitor, or null if the window is in windowed mode.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: window_monitor, glfw.Window.setMonitor
pub inline fn getMonitor(self: Window) ?Monitor {
    internal_debug.assertInitialized();
    if (c.glfwGetWindowMonitor(self.handle)) |monitor| return Monitor{ .handle = monitor };
    return null;
}

/// Sets the mode, monitor, video mode and placement of a window.
///
/// This function sets the monitor that the window uses for full screen mode or, if the monitor is
/// null, makes it windowed mode.
///
/// When setting a monitor, this function updates the width, height and refresh rate of the desired
/// video mode and switches to the video mode closest to it. The window position is ignored when
/// setting a monitor.
///
/// When the monitor is null, the position, width and height are used to place the window content
/// area. The refresh rate is ignored when no monitor is specified.
///
/// If you only wish to update the resolution of a full screen window or the size of a windowed
/// mode window, see @ref glfwSetWindowSize.
///
/// When a window transitions from full screen to windowed mode, this function restores any
/// previous window settings such as whether it is decorated, floating, resizable, has size or
/// aspect ratio limits, etc.
///
/// @param[in] window The window whose monitor, size or video mode to set.
/// @param[in] monitor The desired monitor, or null to set windowed mode.
/// @param[in] xpos The desired x-coordinate of the upper-left corner of the content area.
/// @param[in] ypos The desired y-coordinate of the upper-left corner of the content area.
/// @param[in] width The desired with, in screen coordinates, of the content area or video mode.
/// @param[in] height The desired height, in screen coordinates, of the content area or video mode.
/// @param[in] refreshRate The desired refresh rate, in Hz, of the video mode, or `glfw.dont_care`.
///
/// Possible errors include glfw.ErrorCode.PlatformError.
///
/// The OpenGL or OpenGL ES context will not be destroyed or otherwise affected by any resizing or
/// mode switching, although you may need to update your viewport if the framebuffer size has
/// changed.
///
/// wayland: The desired window position is ignored, as there is no way for an application to set
/// this property.
///
/// wayland: Setting the window to full screen will not attempt to change the mode, no matter what
/// the requested size or refresh rate.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: window_monitor, window_full_screen, glfw.Window.getMonitor, glfw.Window.setSize
pub inline fn setMonitor(self: Window, monitor: ?Monitor, xpos: i32, ypos: i32, width: u32, height: u32, refresh_rate: ?u32) void {
    internal_debug.assertInitialized();
    c.glfwSetWindowMonitor(
        self.handle,
        if (monitor) |m| m.handle else null,
        @as(c_int, @intCast(xpos)),
        @as(c_int, @intCast(ypos)),
        @as(c_int, @intCast(width)),
        @as(c_int, @intCast(height)),
        if (refresh_rate) |refresh_rate_unwrapped| @as(c_int, @intCast(refresh_rate_unwrapped)) else glfw.dont_care,
    );
}

/// Window attributes
pub const Attrib = enum(c_int) {
    iconified = c.GLFW_ICONIFIED,
    resizable = c.GLFW_RESIZABLE,
    visible = c.GLFW_VISIBLE,
    decorated = c.GLFW_DECORATED,
    focused = c.GLFW_FOCUSED,
    auto_iconify = c.GLFW_AUTO_ICONIFY,
    floating = c.GLFW_FLOATING,
    maximized = c.GLFW_MAXIMIZED,
    transparent_framebuffer = c.GLFW_TRANSPARENT_FRAMEBUFFER,
    hovered = c.GLFW_HOVERED,
    focus_on_show = c.GLFW_FOCUS_ON_SHOW,
    mouse_passthrough = c.GLFW_MOUSE_PASSTHROUGH,
    doublebuffer = c.GLFW_DOUBLEBUFFER,

    client_api = c.GLFW_CLIENT_API,
    context_creation_api = c.GLFW_CONTEXT_CREATION_API,
    context_version_major = c.GLFW_CONTEXT_VERSION_MAJOR,
    context_version_minor = c.GLFW_CONTEXT_VERSION_MINOR,
    context_revision = c.GLFW_CONTEXT_REVISION,

    context_robustness = c.GLFW_CONTEXT_ROBUSTNESS,
    context_release_behavior = c.GLFW_CONTEXT_RELEASE_BEHAVIOR,
    context_no_error = c.GLFW_CONTEXT_NO_ERROR,
    context_debug = c.GLFW_CONTEXT_DEBUG,

    opengl_forward_compat = c.GLFW_OPENGL_FORWARD_COMPAT,
    opengl_profile = c.GLFW_OPENGL_PROFILE,
};

/// Returns an attribute of the specified window.
///
/// This function returns the value of an attribute of the specified window or its OpenGL or OpenGL
/// ES context.
///
/// @param[in] attrib The window attribute (see window_attribs) whose value to return.
/// @return The value of the attribute, or zero if an error occurred.
///
/// Possible errors include glfw.ErrorCode.InvalidEnum and glfw.ErrorCode.PlatformError.
/// Additionally returns a zero value in the event of an error.
///
/// Framebuffer related hints are not window attributes. See window_attribs_fb for more information.
///
/// Zero is a valid value for many window and context related attributes so you cannot use a return
/// value of zero as an indication of errors. However, this function should not fail as long as it
/// is passed valid arguments and the library has been initialized.
///
/// @thread_safety This function must only be called from the main thread.
///
/// wayland: The Wayland protocol provides no way to check whether a window is iconified, so
/// glfw.Window.Attrib.iconified always returns `false`.
///
/// see also: window_attribs, glfw.Window.setAttrib
pub inline fn getAttrib(self: Window, attrib: Attrib) i32 {
    internal_debug.assertInitialized();
    return c.glfwGetWindowAttrib(self.handle, @intFromEnum(attrib));
}

/// Sets an attribute of the specified window.
///
/// This function sets the value of an attribute of the specified window.
///
/// The supported attributes are glfw.decorated, glfw.resizable, glfw.floating, glfw.auto_iconify,
/// glfw.focus_on_show.
///
/// Some of these attributes are ignored for full screen windows. The new value will take effect
/// if the window is later made windowed.
///
/// Some of these attributes are ignored for windowed mode windows. The new value will take effect
/// if the window is later made full screen.
///
/// @param[in] attrib A supported window attribute.
///
/// Possible errors include glfw.ErrorCode.InvalidEnum, glfw.ErrorCode.InvalidValue,
/// glfw.ErrorCode.PlatformError, glfw.ErrorCode.FeatureUnavailable
///
/// Calling glfw.Window.getAttrib will always return the latest
/// value, even if that value is ignored by the current mode of the window.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: window_attribs, glfw.Window.getAttrib
///
pub inline fn setAttrib(self: Window, attrib: Attrib, value: bool) void {
    internal_debug.assertInitialized();
    std.debug.assert(switch (attrib) {
        .decorated,
        .resizable,
        .floating,
        .auto_iconify,
        .focus_on_show,
        .mouse_passthrough,
        .doublebuffer,
        => true,
        else => false,
    });
    c.glfwSetWindowAttrib(self.handle, @intFromEnum(attrib), if (value) c.GLFW_TRUE else c.GLFW_FALSE);
}

/// Sets the user pointer of the specified window.
///
/// This function sets the user-defined pointer of the specified window. The current value is
/// retained until the window is destroyed. The initial value is null.
///
/// @thread_safety This function may be called from any thread. Access is not synchronized.
///
/// see also: window_userptr, glfw.Window.getUserPointer
pub inline fn setUserPointer(self: Window, pointer: ?*anyopaque) void {
    internal_debug.assertInitialized();
    c.glfwSetWindowUserPointer(self.handle, pointer);
}

/// Returns the user pointer of the specified window.
///
/// This function returns the current value of the user-defined pointer of the specified window.
/// The initial value is null.
///
/// @thread_safety This function may be called from any thread. Access is not synchronized.
///
/// see also: window_userptr, glfw.Window.setUserPointer
pub inline fn getUserPointer(self: Window, comptime T: type) ?*T {
    internal_debug.assertInitialized();
    if (c.glfwGetWindowUserPointer(self.handle)) |user_pointer| return @as(?*T, @ptrCast(@alignCast(user_pointer)));
    return null;
}

/// Sets the position callback for the specified window.
///
/// This function sets the position callback of the specified window, which is called when the
/// window is moved. The callback is provided with the position, in screen coordinates, of the
/// upper-left corner of the content area of the window.
///
/// @param[in] callback The new callback, or null to remove the currently set callback.
///
/// @callback_param `window` the window that moved.
/// @callback_param `xpos` the new x-coordinate, in screen coordinates, of the upper-left corner of
/// the content area of the window.
/// @callback_param `ypos` the new y-coordinate, in screen coordinates, of the upper-left corner of
/// the content area of the window.
///
/// wayland: This callback will never be called, as there is no way for an application to know its
/// global position.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: window_pos
pub inline fn setPosCallback(self: Window, comptime callback: ?fn (window: Window, xpos: i32, ypos: i32) void) void {
    internal_debug.assertInitialized();

    if (callback) |user_callback| {
        const CWrapper = struct {
            pub fn posCallbackWrapper(handle: ?*c.GLFWwindow, xpos: c_int, ypos: c_int) callconv(.c) void {
                @call(.always_inline, user_callback, .{
                    from(handle.?),
                    @as(i32, @intCast(xpos)),
                    @as(i32, @intCast(ypos)),
                });
            }
        };

        if (c.glfwSetWindowPosCallback(self.handle, CWrapper.posCallbackWrapper) != null) return;
    } else {
        if (c.glfwSetWindowPosCallback(self.handle, null) != null) return;
    }
}

/// Sets the size callback for the specified window.
///
/// This function sets the size callback of the specified window, which is called when the window
/// is resized. The callback is provided with the size, in screen coordinates, of the content area
/// of the window.
///
/// @callback_param `window` the window that was resized.
/// @callback_param `width` the new width, in screen coordinates, of the window.
/// @callback_param `height` the new height, in screen coordinates, of the window.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: window_size
pub inline fn setSizeCallback(self: Window, comptime callback: ?fn (window: Window, width: i32, height: i32) void) void {
    internal_debug.assertInitialized();

    if (callback) |user_callback| {
        const CWrapper = struct {
            pub fn sizeCallbackWrapper(handle: ?*c.GLFWwindow, width: c_int, height: c_int) callconv(.c) void {
                @call(.always_inline, user_callback, .{
                    from(handle.?),
                    @as(i32, @intCast(width)),
                    @as(i32, @intCast(height)),
                });
            }
        };

        if (c.glfwSetWindowSizeCallback(self.handle, CWrapper.sizeCallbackWrapper) != null) return;
    } else {
        if (c.glfwSetWindowSizeCallback(self.handle, null) != null) return;
    }
}

/// Sets the close callback for the specified window.
///
/// This function sets the close callback of the specified window, which is called when the user
/// attempts to close the window, for example by clicking the close widget in the title bar.
///
/// The close flag is set before this callback is called, but you can modify it at any time with
/// glfw.Window.setShouldClose.
///
/// The close callback is not triggered by glfw.Window.destroy.
///
/// @param[in] window The window whose callback to set.
/// @param[in] callback The new callback, or null to remove the currently set callback.
///
/// @callback_param `window` the window that the user attempted to close.
///
/// macos: Selecting Quit from the application menu will trigger the close callback for all
/// windows.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: window_close
pub inline fn setCloseCallback(self: Window, comptime callback: ?fn (window: Window) void) void {
    internal_debug.assertInitialized();

    if (callback) |user_callback| {
        const CWrapper = struct {
            pub fn closeCallbackWrapper(handle: ?*c.GLFWwindow) callconv(.c) void {
                @call(.always_inline, user_callback, .{
                    from(handle.?),
                });
            }
        };

        if (c.glfwSetWindowCloseCallback(self.handle, CWrapper.closeCallbackWrapper) != null) return;
    } else {
        if (c.glfwSetWindowCloseCallback(self.handle, null) != null) return;
    }
}

/// Sets the refresh callback for the specified window.
///
/// This function sets the refresh callback of the specified window, which is
/// called when the content area of the window needs to be redrawn, for example
/// if the window has been exposed after having been covered by another window.
///
/// On compositing window systems such as Aero, Compiz, Aqua or Wayland, where
/// the window contents are saved off-screen, this callback may be called only
/// very infrequently or never at all.
///
/// @param[in] window The window whose callback to set.
/// @param[in] callback The new callback, or null to remove the currently set
/// callback.
///
/// @callback_param `window` the window whose content needs to be refreshed.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: window_refresh
pub inline fn setRefreshCallback(self: Window, comptime callback: ?fn (window: Window) void) void {
    internal_debug.assertInitialized();

    if (callback) |user_callback| {
        const CWrapper = struct {
            pub fn refreshCallbackWrapper(handle: ?*c.GLFWwindow) callconv(.c) void {
                @call(.always_inline, user_callback, .{
                    from(handle.?),
                });
            }
        };

        if (c.glfwSetWindowRefreshCallback(self.handle, CWrapper.refreshCallbackWrapper) != null) return;
    } else {
        if (c.glfwSetWindowRefreshCallback(self.handle, null) != null) return;
    }
}

/// Sets the focus callback for the specified window.
///
/// This function sets the focus callback of the specified window, which is
/// called when the window gains or loses input focus.
///
/// After the focus callback is called for a window that lost input focus,
/// synthetic key and mouse button release events will be generated for all such
/// that had been pressed. For more information, see @ref glfwSetKeyCallback
/// and @ref glfwSetMouseButtonCallback.
///
/// @param[in] window The window whose callback to set.
/// @param[in] callback The new callback, or null to remove the currently set
/// callback.
///
/// @callback_param `window` the window whose input focus has changed.
/// @callback_param `focused` `true` if the window was given input focus, or `false` if it lost it.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: window_focus
pub inline fn setFocusCallback(self: Window, comptime callback: ?fn (window: Window, focused: bool) void) void {
    internal_debug.assertInitialized();

    if (callback) |user_callback| {
        const CWrapper = struct {
            pub fn focusCallbackWrapper(handle: ?*c.GLFWwindow, focused: c_int) callconv(.c) void {
                @call(.always_inline, user_callback, .{
                    from(handle.?),
                    focused == c.GLFW_TRUE,
                });
            }
        };

        if (c.glfwSetWindowFocusCallback(self.handle, CWrapper.focusCallbackWrapper) != null) return;
    } else {
        if (c.glfwSetWindowFocusCallback(self.handle, null) != null) return;
    }
}

/// Sets the iconify callback for the specified window.
///
/// This function sets the iconification callback of the specified window, which
/// is called when the window is iconified or restored.
///
/// @param[in] window The window whose callback to set.
/// @param[in] callback The new callback, or null to remove the currently set
/// callback.
///
/// @callback_param `window` the window which was iconified or restored.
/// @callback_param `iconified` `true` if the window was iconified, or `false` if it was restored.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: window_iconify
pub inline fn setIconifyCallback(self: Window, comptime callback: ?fn (window: Window, iconified: bool) void) void {
    internal_debug.assertInitialized();

    if (callback) |user_callback| {
        const CWrapper = struct {
            pub fn iconifyCallbackWrapper(handle: ?*c.GLFWwindow, iconified: c_int) callconv(.c) void {
                @call(.always_inline, user_callback, .{
                    from(handle.?),
                    iconified == c.GLFW_TRUE,
                });
            }
        };

        if (c.glfwSetWindowIconifyCallback(self.handle, CWrapper.iconifyCallbackWrapper) != null) return;
    } else {
        if (c.glfwSetWindowIconifyCallback(self.handle, null) != null) return;
    }
}

/// Sets the maximize callback for the specified window.
///
/// This function sets the maximization callback of the specified window, which
/// is called when the window is maximized or restored.
///
/// @param[in] window The window whose callback to set.
/// @param[in] callback The new callback, or null to remove the currently set
/// callback.
///
/// @callback_param `window` the window which was maximized or restored.
/// @callback_param `maximized` `true` if the window was maximized, or `false` if it was restored.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: window_maximize
// GLFWAPI GLFWwindowmaximizefun glfwSetWindowMaximizeCallback(GLFWwindow* window, GLFWwindowmaximizefun callback);
pub inline fn setMaximizeCallback(self: Window, comptime callback: ?fn (window: Window, maximized: bool) void) void {
    internal_debug.assertInitialized();

    if (callback) |user_callback| {
        const CWrapper = struct {
            pub fn maximizeCallbackWrapper(handle: ?*c.GLFWwindow, maximized: c_int) callconv(.c) void {
                @call(.always_inline, user_callback, .{
                    from(handle.?),
                    maximized == c.GLFW_TRUE,
                });
            }
        };

        if (c.glfwSetWindowMaximizeCallback(self.handle, CWrapper.maximizeCallbackWrapper) != null) return;
    } else {
        if (c.glfwSetWindowMaximizeCallback(self.handle, null) != null) return;
    }
}

/// Sets the framebuffer resize callback for the specified window.
///
/// This function sets the framebuffer resize callback of the specified window,
/// which is called when the framebuffer of the specified window is resized.
///
/// @param[in] window The window whose callback to set.
/// @param[in] callback The new callback, or null to remove the currently set
/// callback.
///
/// @callback_param `window` the window whose framebuffer was resized.
/// @callback_param `width` the new width, in pixels, of the framebuffer.
/// @callback_param `height` the new height, in pixels, of the framebuffer.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: window_fbsize
pub inline fn setFramebufferSizeCallback(self: Window, comptime callback: ?fn (window: Window, width: u32, height: u32) void) void {
    internal_debug.assertInitialized();

    if (callback) |user_callback| {
        const CWrapper = struct {
            pub fn framebufferSizeCallbackWrapper(handle: ?*c.GLFWwindow, width: c_int, height: c_int) callconv(.c) void {
                @call(.always_inline, user_callback, .{
                    from(handle.?),
                    @as(u32, @intCast(width)),
                    @as(u32, @intCast(height)),
                });
            }
        };

        if (c.glfwSetFramebufferSizeCallback(self.handle, CWrapper.framebufferSizeCallbackWrapper) != null) return;
    } else {
        if (c.glfwSetFramebufferSizeCallback(self.handle, null) != null) return;
    }
}

/// Sets the window content scale callback for the specified window.
///
/// This function sets the window content scale callback of the specified window,
/// which is called when the content scale of the specified window changes.
///
/// @param[in] window The window whose callback to set.
/// @param[in] callback The new callback, or null to remove the currently set
/// callback.
///
/// @callback_param `window` the window whose content scale changed.
/// @callback_param `xscale` the new x-axis content scale of the window.
/// @callback_param `yscale` the new y-axis content scale of the window.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: window_scale, glfw.Window.getContentScale
pub inline fn setContentScaleCallback(self: Window, comptime callback: ?fn (window: Window, xscale: f32, yscale: f32) void) void {
    internal_debug.assertInitialized();

    if (callback) |user_callback| {
        const CWrapper = struct {
            pub fn windowScaleCallbackWrapper(handle: ?*c.GLFWwindow, xscale: f32, yscale: f32) callconv(.c) void {
                @call(.always_inline, user_callback, .{
                    from(handle.?),
                    xscale,
                    yscale,
                });
            }
        };

        if (c.glfwSetWindowContentScaleCallback(self.handle, CWrapper.windowScaleCallbackWrapper) != null) return;
    } else {
        if (c.glfwSetWindowContentScaleCallback(self.handle, null) != null) return;
    }
}

pub const InputMode = enum(c_int) {
    cursor = c.GLFW_CURSOR,
    sticky_keys = c.GLFW_STICKY_KEYS,
    sticky_mouse_buttons = c.GLFW_STICKY_MOUSE_BUTTONS,
    lock_key_mods = c.GLFW_LOCK_KEY_MODS,
    raw_mouse_motion = c.GLFW_RAW_MOUSE_MOTION,
};

/// A cursor input mode to be supplied to `glfw.Window.setInputModeCursor`
pub const InputModeCursor = enum(c_int) {
    /// Makes the cursor visible and behaving normally.
    normal = c.GLFW_CURSOR_NORMAL,

    /// Makes the cursor invisible when it is over the content area of the window but does not
    /// restrict it from leaving.
    hidden = c.GLFW_CURSOR_HIDDEN,

    /// Hides and grabs the cursor, providing virtual and unlimited cursor movement. This is useful
    /// for implementing for example 3D camera controls.
    disabled = c.GLFW_CURSOR_DISABLED,

    /// Makes the cursor visible but confines it to the content area of the window.
    captured = c.GLFW_CURSOR_CAPTURED,
};

/// Sets the input mode of the cursor, whether it should behave normally, be hidden, or grabbed.
pub inline fn setInputModeCursor(self: Window, value: InputModeCursor) void {
    return self.setInputMode(InputMode.cursor, value);
}

/// Gets the current input mode of the cursor.
pub inline fn getInputModeCursor(self: Window) InputModeCursor {
    return @as(InputModeCursor, @enumFromInt(self.getInputMode(InputMode.cursor)));
}

/// Sets the input mode of sticky keys, if enabled a key press will ensure that `glfw.Window.getKey`
/// return `.press` the next time it is called even if the key had been released before the call.
///
/// This is useful when you are only interested in whether keys have been pressed but not when or
/// in which order.
pub inline fn setInputModeStickyKeys(self: Window, enabled: bool) void {
    return self.setInputMode(InputMode.sticky_keys, enabled);
}

/// Tells if the sticky keys input mode is enabled.
pub inline fn getInputModeStickyKeys(self: Window) bool {
    return self.getInputMode(InputMode.sticky_keys) == 1;
}

/// Sets the input mode of sticky mouse buttons, if enabled a mouse button press will ensure that
/// `glfw.Window.getMouseButton` return `.press` the next time it is called even if the button had
/// been released before the call.
///
/// This is useful when you are only interested in whether buttons have been pressed but not when
/// or in which order.
pub inline fn setInputModeStickyMouseButtons(self: Window, enabled: bool) void {
    return self.setInputMode(InputMode.sticky_mouse_buttons, enabled);
}

/// Tells if the sticky mouse buttons input mode is enabled.
pub inline fn getInputModeStickyMouseButtons(self: Window) bool {
    return self.getInputMode(InputMode.sticky_mouse_buttons) == 1;
}

/// Sets the input mode of locking key modifiers, if enabled callbacks that receive modifier bits
/// will also have the glfw.mod.caps_lock bit set when the event was generated with Caps Lock on,
/// and the glfw.mod.num_lock bit when Num Lock was on.
pub inline fn setInputModeLockKeyMods(self: Window, enabled: bool) void {
    return self.setInputMode(InputMode.lock_key_mods, enabled);
}

/// Tells if the locking key modifiers input mode is enabled.
pub inline fn getInputModeLockKeyMods(self: Window) bool {
    return self.getInputMode(InputMode.lock_key_mods) == 1;
}

/// Sets whether the raw mouse motion input mode is enabled, if enabled unscaled and unaccelerated
/// mouse motion events will be sent, otherwise standard mouse motion events respecting the user's
/// OS settings will be sent.
///
/// If raw motion is not supported, attempting to set this will emit glfw.ErrorCode.FeatureUnavailable.
/// Call glfw.rawMouseMotionSupported to check for support.
pub inline fn setInputModeRawMouseMotion(self: Window, enabled: bool) void {
    return self.setInputMode(InputMode.raw_mouse_motion, enabled);
}

/// Tells if the raw mouse motion input mode is enabled.
pub inline fn getInputModeRawMouseMotion(self: Window) bool {
    return self.getInputMode(InputMode.raw_mouse_motion) == 1;
}

/// Returns the value of an input option for the specified window.
///
/// Consider using one of the following variants instead, if applicable, as they'll give you a
/// typed return value:
///
/// * `glfw.Window.getInputModeCursor`
/// * `glfw.Window.getInputModeStickyKeys`
/// * `glfw.Window.getInputModeStickyMouseButtons`
/// * `glfw.Window.getInputModeLockKeyMods`
/// * `glfw.Window.getInputModeRawMouseMotion`
///
/// This function returns the value of an input option for the specified window. The mode must be
/// one of the `glfw.Window.InputMode` enumerations.
///
/// Boolean values, such as for `glfw.Window.InputMode.raw_mouse_motion`, are returned as integers.
/// You may convert to a boolean using `== 1`.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: glfw.Window.setInputMode
pub inline fn getInputMode(self: Window, mode: InputMode) i32 {
    internal_debug.assertInitialized();
    const value = c.glfwGetInputMode(self.handle, @intFromEnum(mode));
    return @as(i32, @intCast(value));
}

/// Sets an input option for the specified window.
///
/// Consider using one of the following variants instead, if applicable, as they'll guide you to
/// the right input value via enumerations:
///
/// * `glfw.Window.setInputModeCursor`
/// * `glfw.Window.setInputModeStickyKeys`
/// * `glfw.Window.setInputModeStickyMouseButtons`
/// * `glfw.Window.setInputModeLockKeyMods`
/// * `glfw.Window.setInputModeRawMouseMotion`
///
/// @param[in] mode One of the `glfw.Window.InputMode` enumerations.
/// @param[in] value The new value of the specified input mode.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: glfw.Window.getInputMode
pub inline fn setInputMode(self: Window, mode: InputMode, value: anytype) void {
    internal_debug.assertInitialized();
    const T = @TypeOf(value);
    std.debug.assert(switch (mode) {
        .cursor => switch (@import("shims.zig").typeInfo(T)) {
            .@"enum" => T == InputModeCursor,
            .enum_literal => @hasField(InputModeCursor, @tagName(value)),
            else => false,
        },
        .sticky_keys => T == bool,
        .sticky_mouse_buttons => T == bool,
        .lock_key_mods => T == bool,
        .raw_mouse_motion => T == bool,
    });
    const int_value: c_int = switch (@import("shims.zig").typeInfo(T)) {
        .@"enum",
        .enum_literal,
        => @intFromEnum(@as(InputModeCursor, value)),
        else => @intFromBool(value),
    };
    c.glfwSetInputMode(self.handle, @intFromEnum(mode), int_value);
}

/// Returns the last reported press state of a keyboard key for the specified window.
///
/// This function returns the last press state reported for the specified key to the specified
/// window. The returned state is one of `true` (pressed) or `false` (released).
///
/// * `glfw.Action.repeat` is only reported to the key callback.
///
/// If the `glfw.sticky_keys` input mode is enabled, this function returns `glfw.Action.press` the
/// first time you call it for a key that was pressed, even if that key has already been released.
///
/// The key functions deal with physical keys, with key tokens (see keys) named after their use on
/// the standard US keyboard layout. If you want to input text, use the Unicode character callback
/// instead.
///
/// The modifier key bit masks (see mods) are not key tokens and cannot be used with this function.
///
/// __Do not use this function__ to implement text input, use glfw.Window.setCharCallback instead.
///
/// @param[in] window The desired window.
/// @param[in] key The desired keyboard key (see keys). `glfw.key.unknown` is not a valid key for
/// this function.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: input_key
pub inline fn getKey(self: Window, key: Key) Action {
    internal_debug.assertInitialized();
    const state = c.glfwGetKey(self.handle, @intFromEnum(key));
    return @as(Action, @enumFromInt(state));
}

/// Returns the last reported state of a mouse button for the specified window.
///
/// This function returns whether the specified mouse button is pressed or not.
///
/// If the glfw.sticky_mouse_buttons input mode is enabled, this function returns `true` the first
/// time you call it for a mouse button that was pressed, even if that mouse button has already been
/// released.
///
/// @param[in] button The desired mouse button.
/// @return One of `true` (if pressed) or `false` (if released)
///
/// Possible errors include glfw.ErrorCode.InvalidEnum.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: input_mouse_button
pub inline fn getMouseButton(self: Window, button: MouseButton) Action {
    internal_debug.assertInitialized();
    const state = c.glfwGetMouseButton(self.handle, @intFromEnum(button));
    return @as(Action, @enumFromInt(state));
}

pub const CursorPos = struct {
    xpos: f64,
    ypos: f64,
};

/// Retrieves the position of the cursor relative to the content area of the window.
///
/// This function returns the position of the cursor, in screen coordinates, relative to the
/// upper-left corner of the content area of the specified window.
///
/// If the cursor is disabled (with `glfw.cursor_disabled`) then the cursor position is unbounded
/// and limited only by the minimum and maximum values of a `f64`.
///
/// The coordinate can be converted to their integer equivalents with the `floor` function. Casting
/// directly to an integer type works for positive coordinates, but fails for negative ones.
///
/// Any or all of the position arguments may be null. If an error occurs, all non-null position
/// arguments will be set to zero.
///
/// @param[in] window The desired window.
/// @param[out] xpos Where to store the cursor x-coordinate, relative to the left edge of the
/// content area, or null.
/// @param[out] ypos Where to store the cursor y-coordinate, relative to the to top edge of the
/// content area, or null.
///
/// Possible errors include glfw.ErrorCode.PlatformError.
/// Additionally returns a zero value in the event of an error.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: cursor_pos, glfw.Window.setCursorPos
pub inline fn getCursorPos(self: Window) CursorPos {
    internal_debug.assertInitialized();
    var pos: CursorPos = undefined;
    c.glfwGetCursorPos(self.handle, &pos.xpos, &pos.ypos);
    return pos;
}

/// Sets the position of the cursor, relative to the content area of the window.
///
/// This function sets the position, in screen coordinates, of the cursor relative to the upper-left
/// corner of the content area of the specified window. The window must have input focus. If the
/// window does not have input focus when this function is called, it fails silently.
///
/// __Do not use this function__ to implement things like camera controls. GLFW already provides the
/// `glfw.cursor_disabled` cursor mode that hides the cursor, transparently re-centers it and
/// provides unconstrained cursor motion. See glfw.Window.setInputMode for more information.
///
/// If the cursor mode is `glfw.cursor_disabled` then the cursor position is unconstrained and
/// limited only by the minimum and maximum values of a `double`.
///
/// @param[in] window The desired window.
/// @param[in] xpos The desired x-coordinate, relative to the left edge of the content area.
/// @param[in] ypos The desired y-coordinate, relative to the top edge of the content area.
///
/// Possible errors include glfw.ErrorCode.PlatformError, glfw.ErrorCode.FeatureUnavailable.
///
/// wayland: This function will only work when the cursor mode is `glfw.cursor_disabled`, otherwise
/// it will do nothing.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: cursor_pos, glfw.Window.getCursorPos
pub inline fn setCursorPos(self: Window, xpos: f64, ypos: f64) void {
    internal_debug.assertInitialized();
    c.glfwSetCursorPos(self.handle, xpos, ypos);
}

/// Sets the cursor for the window.
///
/// This function sets the cursor image to be used when the cursor is over the content area of the
/// specified window. The set cursor will only be visible when the cursor mode (see cursor_mode) of
/// the window is `glfw.Cursor.normal`.
///
/// On some platforms, the set cursor may not be visible unless the window also has input focus.
///
/// @param[in] cursor The cursor to set, or null to switch back to the default arrow cursor.
///
/// Possible errors include glfw.ErrorCode.PlatformError.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: cursor_object
pub inline fn setCursor(self: Window, cursor: ?Cursor) void {
    internal_debug.assertInitialized();
    c.glfwSetCursor(self.handle, if (cursor) |cs| cs.ptr else null);
}

/// Sets the key callback.
///
/// This function sets the key callback of the specified window, which is called when a key is
/// pressed, repeated or released.
///
/// The key functions deal with physical keys, with layout independent key tokens (see keys) named
/// after their values in the standard US keyboard layout. If you want to input text, use the
/// character callback (see glfw.Window.setCharCallback) instead.
///
/// When a window loses input focus, it will generate synthetic key release events for all pressed
/// keys. You can tell these events from user-generated events by the fact that the synthetic ones
/// are generated after the focus loss event has been processed, i.e. after the window focus
/// callback (see glfw.Window.setFocusCallback) has been called.
///
/// The scancode of a key is specific to that platform or sometimes even to that machine. Scancodes
/// are intended to allow users to bind keys that don't have a GLFW key token. Such keys have `key`
/// set to `glfw.key.unknown`, their state is not saved and so it cannot be queried with
/// glfw.Window.getKey.
///
/// Sometimes GLFW needs to generate synthetic key events, in which case the scancode may be zero.
///
/// @param[in] window The window whose callback to set.
/// @param[in] callback The new key callback, or null to remove the currently set callback.
///
/// @callback_param[in] window The window that received the event.
/// @callback_param[in] key The keyboard key (see keys) that was pressed or released.
/// @callback_param[in] scancode The platform-specific scancode of the key.
/// @callback_param[in] action `glfw.Action.press`, `glfw.Action.release` or `glfw.Action.repeat`.
/// Future releases may add more actions.
/// @callback_param[in] mods Bit field describing which modifier keys (see mods) were held down.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: input_key
pub inline fn setKeyCallback(self: Window, comptime callback: ?fn (window: Window, key: Key, scancode: i32, action: Action, mods: Mods) void) void {
    internal_debug.assertInitialized();

    if (callback) |user_callback| {
        const CWrapper = struct {
            pub fn keyCallbackWrapper(handle: ?*c.GLFWwindow, key: c_int, scancode: c_int, action: c_int, mods: c_int) callconv(.c) void {
                @call(.always_inline, user_callback, .{
                    from(handle.?),
                    @as(Key, @enumFromInt(key)),
                    @as(i32, @intCast(scancode)),
                    @as(Action, @enumFromInt(action)),
                    Mods.fromInt(mods),
                });
            }
        };

        if (c.glfwSetKeyCallback(self.handle, CWrapper.keyCallbackWrapper) != null) return;
    } else {
        if (c.glfwSetKeyCallback(self.handle, null) != null) return;
    }
}

/// Sets the Unicode character callback.
///
/// This function sets the character callback of the specified window, which is called when a
/// Unicode character is input.
///
/// The character callback is intended for Unicode text input. As it deals with characters, it is
/// keyboard layout dependent, whereas the key callback (see glfw.Window.setKeyCallback) is not.
/// Characters do not map 1:1 to physical keys, as a key may produce zero, one or more characters.
/// If you want to know whether a specific physical key was pressed or released, see the key
/// callback instead.
///
/// The character callback behaves as system text input normally does and will not be called if
/// modifier keys are held down that would prevent normal text input on that platform, for example a
/// Super (Command) key on macOS or Alt key on Windows.
///
/// @param[in] window The window whose callback to set.
/// @param[in] callback The new callback, or null to remove the currently set callback.
///
/// @callback_param[in] window The window that received the event.
/// @callback_param[in] codepoint The Unicode code point of the character.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: input_char
pub inline fn setCharCallback(self: Window, comptime callback: ?fn (window: Window, codepoint: u21) void) void {
    internal_debug.assertInitialized();

    if (callback) |user_callback| {
        const CWrapper = struct {
            pub fn charCallbackWrapper(handle: ?*c.GLFWwindow, codepoint: c_uint) callconv(.c) void {
                @call(.always_inline, user_callback, .{
                    from(handle.?),
                    @as(u21, @intCast(codepoint)),
                });
            }
        };

        if (c.glfwSetCharCallback(self.handle, CWrapper.charCallbackWrapper) != null) return;
    } else {
        if (c.glfwSetCharCallback(self.handle, null) != null) return;
    }
}

/// Sets the mouse button callback.
///
/// This function sets the mouse button callback of the specified window, which is called when a
/// mouse button is pressed or released.
///
/// When a window loses input focus, it will generate synthetic mouse button release events for all
/// pressed mouse buttons. You can tell these events from user-generated events by the fact that the
/// synthetic ones are generated after the focus loss event has been processed, i.e. after the
/// window focus callback (see glfw.Window.setFocusCallback) has been called.
///
/// @param[in] window The window whose callback to set.
/// @param[in] callback The new callback, or null to remove the currently set callback.
///
/// @callback_param[in] window The window that received the event.
/// @callback_param[in] button The mouse button that was pressed or released.
/// @callback_param[in] action One of `glfw.Action.press` or `glfw.Action.release`. Future releases
/// may add more actions.
/// @callback_param[in] mods Bit field describing which modifier keys (see mods) were held down.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: input_mouse_button
pub inline fn setMouseButtonCallback(self: Window, comptime callback: ?fn (window: Window, button: MouseButton, action: Action, mods: Mods) void) void {
    internal_debug.assertInitialized();

    if (callback) |user_callback| {
        const CWrapper = struct {
            pub fn mouseButtonCallbackWrapper(handle: ?*c.GLFWwindow, button: c_int, action: c_int, mods: c_int) callconv(.c) void {
                @call(.always_inline, user_callback, .{
                    from(handle.?),
                    @as(MouseButton, @enumFromInt(button)),
                    @as(Action, @enumFromInt(action)),
                    Mods.fromInt(mods),
                });
            }
        };

        if (c.glfwSetMouseButtonCallback(self.handle, CWrapper.mouseButtonCallbackWrapper) != null) return;
    } else {
        if (c.glfwSetMouseButtonCallback(self.handle, null) != null) return;
    }
}

/// Sets the cursor position callback.
///
/// This function sets the cursor position callback of the specified window, which is called when
/// the cursor is moved. The callback is provided with the position, in screen coordinates, relative
/// to the upper-left corner of the content area of the window.
///
/// @param[in] callback The new callback, or null to remove the currently set callback.
///
/// @callback_param[in] window The window that received the event.
/// @callback_param[in] xpos The new cursor x-coordinate, relative to the left edge of the content
/// area.
/// callback_@param[in] ypos The new cursor y-coordinate, relative to the top edge of the content
/// area.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: cursor_pos
pub inline fn setCursorPosCallback(self: Window, comptime callback: ?fn (window: Window, xpos: f64, ypos: f64) void) void {
    internal_debug.assertInitialized();

    if (callback) |user_callback| {
        const CWrapper = struct {
            pub fn cursorPosCallbackWrapper(handle: ?*c.GLFWwindow, xpos: f64, ypos: f64) callconv(.c) void {
                @call(.always_inline, user_callback, .{
                    from(handle.?),
                    xpos,
                    ypos,
                });
            }
        };

        if (c.glfwSetCursorPosCallback(self.handle, CWrapper.cursorPosCallbackWrapper) != null) return;
    } else {
        if (c.glfwSetCursorPosCallback(self.handle, null) != null) return;
    }
}

/// Sets the cursor enter/leave callback.
///
/// This function sets the cursor boundary crossing callback of the specified window, which is
/// called when the cursor enters or leaves the content area of the window.
///
/// @param[in] callback The new callback, or null to remove the currently set callback.
///
/// @callback_param[in] window The window that received the event.
/// @callback_param[in] entered `true` if the cursor entered the window's content area, or `false`
/// if it left it.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: cursor_enter
pub inline fn setCursorEnterCallback(self: Window, comptime callback: ?fn (window: Window, entered: bool) void) void {
    internal_debug.assertInitialized();

    if (callback) |user_callback| {
        const CWrapper = struct {
            pub fn cursorEnterCallbackWrapper(handle: ?*c.GLFWwindow, entered: c_int) callconv(.c) void {
                @call(.always_inline, user_callback, .{
                    from(handle.?),
                    entered == c.GLFW_TRUE,
                });
            }
        };

        if (c.glfwSetCursorEnterCallback(self.handle, CWrapper.cursorEnterCallbackWrapper) != null) return;
    } else {
        if (c.glfwSetCursorEnterCallback(self.handle, null) != null) return;
    }
}

/// Sets the scroll callback.
///
/// This function sets the scroll callback of the specified window, which is called when a scrolling
/// device is used, such as a mouse wheel or scrolling area of a touchpad.
///
/// The scroll callback receives all scrolling input, like that from a mouse wheel or a touchpad
/// scrolling area.
///
/// @param[in] window The window whose callback to set.
/// @param[in] callback The new scroll callback, or null to remove the currently set callback.
///
/// @callback_param[in] window The window that received the event.
/// @callback_param[in] xoffset The scroll offset along the x-axis.
/// @callback_param[in] yoffset The scroll offset along the y-axis.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: scrolling
pub inline fn setScrollCallback(self: Window, comptime callback: ?fn (window: Window, xoffset: f64, yoffset: f64) void) void {
    internal_debug.assertInitialized();

    if (callback) |user_callback| {
        const CWrapper = struct {
            pub fn scrollCallbackWrapper(handle: ?*c.GLFWwindow, xoffset: f64, yoffset: f64) callconv(.c) void {
                @call(.always_inline, user_callback, .{
                    from(handle.?),
                    xoffset,
                    yoffset,
                });
            }
        };

        if (c.glfwSetScrollCallback(self.handle, CWrapper.scrollCallbackWrapper) != null) return;
    } else {
        if (c.glfwSetScrollCallback(self.handle, null) != null) return;
    }
}

/// Sets the path drop callback.
///
/// This function sets the path drop callback of the specified window, which is called when one or
/// more dragged paths are dropped on the window.
///
/// Because the path array and its strings may have been generated specifically for that event, they
/// are not guaranteed to be valid after the callback has returned. If you wish to use them after
/// the callback returns, you need to make a deep copy.
///
/// @param[in] callback The new file drop callback, or null to remove the currently set callback.
///
/// @callback_param[in] window The window that received the event.
/// @callback_param[in] path_count The number of dropped paths.
/// @callback_param[in] paths The UTF-8 encoded file and/or directory path names.
///
/// @callback_pointer_lifetime The path array and its strings are valid until the callback function
/// returns.
///
/// wayland: File drop is currently unimplemented.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: path_drop
pub inline fn setDropCallback(self: Window, comptime callback: ?fn (window: Window, paths: [][*:0]const u8) void) void {
    internal_debug.assertInitialized();

    if (callback) |user_callback| {
        const CWrapper = struct {
            pub fn dropCallbackWrapper(handle: ?*c.GLFWwindow, path_count: c_int, paths: [*c][*c]const u8) callconv(.c) void {
                @call(.always_inline, user_callback, .{
                    from(handle.?),
                    @as([*][*:0]const u8, @ptrCast(paths))[0..@as(u32, @intCast(path_count))],
                });
            }
        };

        if (c.glfwSetDropCallback(self.handle, CWrapper.dropCallbackWrapper) != null) return;
    } else {
        if (c.glfwSetDropCallback(self.handle, null) != null) return;
    }
}

/// For testing purposes only; see glfw.Window.Hints and glfw.Window.create for the public API.
/// Sets the specified window hint to the desired value.
///
/// This function sets hints for the next call to glfw.Window.create. The hints, once set, retain
/// their values until changed by a call to this function or glfw.window.defaultHints, or until the
/// library is terminated.
///
/// This function does not check whether the specified hint values are valid. If you set hints to
/// invalid values this will instead be reported by the next call to glfw.createWindow.
///
/// Some hints are platform specific. These may be set on any platform but they will only affect
/// their specific platform. Other platforms will ignore them.
///
/// Possible errors include glfw.ErrorCode.InvalidEnum.
///
/// @pointer_lifetime in the event that value is of a str type, the specified string is copied before this function returns.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: window_hints, glfw.Window.defaultHints
inline fn hint(h: Hint, value: anytype) void {
    internal_debug.assertInitialized();
    const value_type = @TypeOf(value);
    const value_type_info: @import("shims.zig").std.builtin.Type = @import("shims.zig").typeInfo(value_type);

    switch (value_type_info) {
        .int, .comptime_int => {
            c.glfwWindowHint(@intFromEnum(h), @as(c_int, @intCast(value)));
        },
        .bool => {
            const int_value = @intFromBool(value);
            c.glfwWindowHint(@intFromEnum(h), @as(c_int, @intCast(int_value)));
        },
        .@"enum" => {
            const int_value = @intFromEnum(value);
            c.glfwWindowHint(@intFromEnum(h), @as(c_int, @intCast(int_value)));
        },
        .array => |arr_type| {
            if (arr_type.child != u8) {
                @compileError("expected array of u8, got " ++ @typeName(arr_type));
            }
            c.glfwWindowHintString(@intFromEnum(h), &value[0]);
        },
        .pointer => |pointer_info| {
            const pointed_type = @import("shims.zig").typeInfo(pointer_info.child);
            switch (pointed_type) {
                .array => |arr_type| {
                    if (arr_type.child != u8) {
                        @compileError("expected pointer to array of u8, got " ++ @typeName(arr_type));
                    }
                },
                else => @compileError("expected pointer to array, got " ++ @typeName(pointed_type)),
            }

            c.glfwWindowHintString(@intFromEnum(h), &value[0]);
        },
        else => {
            @compileError("expected a int, bool, enum, array, or pointer, got " ++ @typeName(value_type));
        },
    }
}

test "defaultHints" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    defaultHints();
}

test "hint comptime int" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    hint(.focused, 1);
    defaultHints();
}

test "hint int" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const focused: i32 = 1;

    hint(.focused, focused);
    defaultHints();
}

test "hint bool" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    hint(.focused, true);
    defaultHints();
}

test "hint enum(u1)" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const MyEnum = enum(u1) {
        true = 1,
        false = 0,
    };

    hint(.focused, MyEnum.true);
    defaultHints();
}

test "hint enum(i32)" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const MyEnum = enum(i32) {
        true = 1,
        false = 0,
    };

    hint(.focused, MyEnum.true);
    defaultHints();
}

test "hint array str" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const str_arr = [_]u8{ 'm', 'y', 'c', 'l', 'a', 's', 's' };

    hint(.x11_class_name, str_arr);
    defaultHints();
}

test "hint pointer str" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    hint(.x11_class_name, "myclass");
}

test "createWindow" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();
}

test "setShouldClose" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    window.setShouldClose(true);
    defer window.destroy();
}

test "setTitle" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    window.setTitle("Updated title!");
}

test "setIcon" {
    const allocator = testing.allocator;
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    // Create an all-red icon image.
    const width: u32 = 48;
    const height: u32 = 48;
    const icon = try Image.init(allocator, width, height, width * height * 4);
    var x: u32 = 0;
    var y: u32 = 0;
    while (y <= height) : (y += 1) {
        while (x <= width) : (x += 1) {
            icon.pixels[(x * y * 4) + 0] = 255; // red
            icon.pixels[(x * y * 4) + 1] = 0; // green
            icon.pixels[(x * y * 4) + 2] = 0; // blue
            icon.pixels[(x * y * 4) + 3] = 255; // alpha
        }
    }
    try window.setIcon(allocator, &[_]Image{icon});

    icon.deinit(allocator); // glfw copies it.
}

test "getPos" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    _ = window.getPos();
}

test "setPos" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    _ = window.setPos(.{ .x = 0, .y = 0 });
}

test "getSize" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    _ = window.getSize();
}

test "setSize" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    _ = window.setSize(.{ .width = 640, .height = 480 });
}

test "setSizeLimits" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    window.setSizeLimits(
        .{ .width = 720, .height = 480 },
        .{ .width = 1080, .height = 1920 },
    );
}

test "setAspectRatio" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    window.setAspectRatio(4, 3);
}

test "getFramebufferSize" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    _ = window.getFramebufferSize();
}

test "getFrameSize" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    _ = window.getFrameSize();
}

test "getContentScale" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    _ = window.getContentScale();
}

test "getOpacity" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    _ = window.getOpacity();
}

test "iconify" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    _ = window.iconify();
}

test "restore" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    _ = window.restore();
}

test "maximize" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    _ = window.maximize();
}

test "show" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    _ = window.show();
}

test "hide" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    _ = window.hide();
}

test "focus" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    _ = window.focus();
}

test "requestAttention" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    _ = window.requestAttention();
}

test "swapBuffers" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    _ = window.swapBuffers();
}

test "getMonitor" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    _ = window.getMonitor();
}

test "setMonitor" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    window.setMonitor(null, 10, 10, 640, 480, 60);
}

test "getAttrib" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    _ = window.getAttrib(.focused);
}

test "setAttrib" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    window.setAttrib(.decorated, false);
}

test "setUserPointer" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    const T = struct { name: []const u8 };
    var my_value = T{ .name = "my window!" };

    window.setUserPointer(&my_value);
}

test "getUserPointer" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    const T = struct { name: []const u8 };
    var my_value = T{ .name = "my window!" };

    window.setUserPointer(&my_value);
    const got = window.getUserPointer(T);
    std.debug.assert(&my_value == got);
}

test "setPosCallback" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    window.setPosCallback((struct {
        fn callback(_window: Window, xpos: i32, ypos: i32) void {
            _ = _window;
            _ = xpos;
            _ = ypos;
        }
    }).callback);
}

test "setSizeCallback" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    window.setSizeCallback((struct {
        fn callback(_window: Window, width: i32, height: i32) void {
            _ = _window;
            _ = width;
            _ = height;
        }
    }).callback);
}

test "setCloseCallback" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    window.setCloseCallback((struct {
        fn callback(_window: Window) void {
            _ = _window;
        }
    }).callback);
}

test "setRefreshCallback" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    window.setRefreshCallback((struct {
        fn callback(_window: Window) void {
            _ = _window;
        }
    }).callback);
}

test "setFocusCallback" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    window.setFocusCallback((struct {
        fn callback(_window: Window, focused: bool) void {
            _ = _window;
            _ = focused;
        }
    }).callback);
}

test "setIconifyCallback" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    window.setIconifyCallback((struct {
        fn callback(_window: Window, iconified: bool) void {
            _ = _window;
            _ = iconified;
        }
    }).callback);
}

test "setMaximizeCallback" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    window.setMaximizeCallback((struct {
        fn callback(_window: Window, maximized: bool) void {
            _ = _window;
            _ = maximized;
        }
    }).callback);
}

test "setFramebufferSizeCallback" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    window.setFramebufferSizeCallback((struct {
        fn callback(_window: Window, width: u32, height: u32) void {
            _ = _window;
            _ = width;
            _ = height;
        }
    }).callback);
}

test "setContentScaleCallback" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    window.setContentScaleCallback((struct {
        fn callback(_window: Window, xscale: f32, yscale: f32) void {
            _ = _window;
            _ = xscale;
            _ = yscale;
        }
    }).callback);
}

test "setDropCallback" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    window.setDropCallback((struct {
        fn callback(_window: Window, paths: [][*:0]const u8) void {
            _ = _window;
            _ = paths;
        }
    }).callback);
}

test "getInputModeCursor" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    _ = window.getInputModeCursor();
}

test "setInputModeCursor" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    window.setInputModeCursor(.hidden);
}

test "getInputModeStickyKeys" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    _ = window.getInputModeStickyKeys();
}

test "setInputModeStickyKeys" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    window.setInputModeStickyKeys(false);
}

test "getInputModeStickyMouseButtons" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    _ = window.getInputModeStickyMouseButtons();
}

test "setInputModeStickyMouseButtons" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    window.setInputModeStickyMouseButtons(false);
}

test "getInputModeLockKeyMods" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    _ = window.getInputModeLockKeyMods();
}

test "setInputModeLockKeyMods" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    window.setInputModeLockKeyMods(false);
}

test "getInputModeRawMouseMotion" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    _ = window.getInputModeRawMouseMotion();
}

test "setInputModeRawMouseMotion" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    window.setInputModeRawMouseMotion(false);
}

test "getInputMode" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    _ = window.getInputMode(glfw.Window.InputMode.raw_mouse_motion) == 1;
}

test "setInputMode" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    // Boolean values.
    window.setInputMode(glfw.Window.InputMode.sticky_mouse_buttons, true);

    // Integer values.
    window.setInputMode(glfw.Window.InputMode.cursor, glfw.Window.InputModeCursor.hidden);
}

test "getKey" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    _ = window.getKey(glfw.Key.escape);
}

test "getMouseButton" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    _ = window.getMouseButton(.left);
}

test "getCursorPos" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    _ = window.getCursorPos();
}

test "setCursorPos" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    window.setCursorPos(0, 0);
}

test "setCursor" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    const cursor = glfw.Cursor.createStandard(.ibeam);
    if (cursor) |cur| {
        window.setCursor(cur);
        defer cur.destroy();
    }
}

test "setKeyCallback" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    window.setKeyCallback((struct {
        fn callback(_window: Window, key: Key, scancode: i32, action: Action, mods: Mods) void {
            _ = _window;
            _ = key;
            _ = scancode;
            _ = action;
            _ = mods;
        }
    }).callback);
}

test "setCharCallback" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    window.setCharCallback((struct {
        fn callback(_window: Window, codepoint: u21) void {
            _ = _window;
            _ = codepoint;
        }
    }).callback);
}

test "setMouseButtonCallback" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    window.setMouseButtonCallback((struct {
        fn callback(_window: Window, button: MouseButton, action: Action, mods: Mods) void {
            _ = _window;
            _ = button;
            _ = action;
            _ = mods;
        }
    }).callback);
}

test "setCursorPosCallback" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    window.setCursorPosCallback((struct {
        fn callback(_window: Window, xpos: f64, ypos: f64) void {
            _ = _window;
            _ = xpos;
            _ = ypos;
        }
    }).callback);
}

test "setCursorEnterCallback" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    window.setCursorEnterCallback((struct {
        fn callback(_window: Window, entered: bool) void {
            _ = _window;
            _ = entered;
        }
    }).callback);
}

test "setScrollCallback" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const window = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window.destroy();

    window.setScrollCallback((struct {
        fn callback(_window: Window, xoffset: f64, yoffset: f64) void {
            _ = _window;
            _ = xoffset;
            _ = yoffset;
        }
    }).callback);
}

test "hint-attribute default value parity" {
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    testing_ignore_window_hints_struct = true;
    const window_a = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window_a: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window_a.destroy();

    testing_ignore_window_hints_struct = false;
    const window_b = Window.create(640, 480, "GLFW example", null, null, .{}) orelse {
        std.log.warn("failed to create window_b: {?s}", .{glfw.getErrorString()});
        return error.SkipZigTest; // note: we don't exit(1) here because our CI can't open windows
    };
    defer window_b.destroy();

    inline for (comptime std.enums.values(Window.Hint)) |hint_tag| {
        if (@hasField(Window.Attrib, @tagName(hint_tag))) {
            const attrib_tag = @field(Window.Attrib, @tagName(hint_tag));
            switch (attrib_tag) {
                .resizable,
                .visible,
                .decorated,
                .auto_iconify,
                .floating,
                .maximized,
                .transparent_framebuffer,
                .focus_on_show,
                .mouse_passthrough,
                .doublebuffer,
                .client_api,
                .context_creation_api,
                .context_version_major,
                .context_version_minor,
                .context_robustness,
                .context_release_behavior,
                .context_no_error, // Note: at the time of writing this, GLFW does not list the default value for this hint in the documentation
                .context_debug,
                .opengl_forward_compat,
                .opengl_profile,
                => {
                    const expected = window_a.getAttrib(attrib_tag);
                    const actual = window_b.getAttrib(attrib_tag);

                    testing.expectEqual(expected, actual) catch |err| {
                        std.debug.print("On attribute '{}'.\n", .{hint_tag});
                        return err;
                    };
                },

                // This attribute is based on a check for which window is currently in focus,
                // and the default value, as of writing this comment, is 'true', which means
                // that first window_a takes focus, and then window_b takes focus, meaning
                // that we can't actually test for the default value.
                .focused => continue,

                .iconified,
                .hovered,
                .context_revision,
                => unreachable,
            }
        }
        // Future: we could consider hint values that can't be retrieved via attributes:
        // center_cursor
        // mouse_passthrough
        // scale_to_monitor
        // red_bits
        // green_bits
        // blue_bits
        // alpha_bits
        // depth_bits
        // stencil_bits
        // accum_red_bits
        // accum_green_bits
        // accum_blue_bits
        // accum_alpha_bits
        // aux_buffers
        // samples

        // refresh_rate
        // stereo
        // srgb_capable
        // doublebuffer

        // platform specific, and thus not considered:
        // cocoa_retina_framebuffer
        // cocoa_frame_name
        // cocoa_graphics_switching
    }
}
