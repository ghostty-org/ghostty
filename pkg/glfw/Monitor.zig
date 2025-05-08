//! Monitor type and related functions

const std = @import("std");
const mem = std.mem;
const testing = std.testing;
const c = @import("c.zig").c;

const GammaRamp = @import("GammaRamp.zig");
const VideoMode = @import("VideoMode.zig");

const internal_debug = @import("internal_debug.zig");

const Monitor = @This();

handle: *c.GLFWmonitor,

/// A monitor position, in screen coordinates, of the upper left corner of the monitor on the
/// virtual screen.
const Pos = struct {
    /// The x coordinate.
    x: u32,
    /// The y coordinate.
    y: u32,
};

/// Returns the position of the monitor's viewport on the virtual screen.
///
/// Possible errors include glfw.ErrorCode.PlatformError.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: monitor_properties
pub inline fn getPos(self: Monitor) Pos {
    internal_debug.assertInitialized();
    var xpos: c_int = 0;
    var ypos: c_int = 0;
    c.glfwGetMonitorPos(self.handle, &xpos, &ypos);
    return Pos{ .x = @as(u32, @intCast(xpos)), .y = @as(u32, @intCast(ypos)) };
}

/// The monitor workarea, in screen coordinates.
///
/// This is the position of the upper-left corner of the work area of the monitor, along with the
/// work area size. The work area is defined as the area of the monitor not occluded by the
/// window system task bar where present. If no task bar exists then the work area is the
/// monitor resolution in screen coordinates.
const Workarea = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

/// Retrieves the work area of the monitor.
///
/// Possible errors include glfw.ErrorCode.PlatformError.
/// A zero value is returned in the event of an error.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: monitor_workarea
pub inline fn getWorkarea(self: Monitor) Workarea {
    internal_debug.assertInitialized();
    var xpos: c_int = 0;
    var ypos: c_int = 0;
    var width: c_int = 0;
    var height: c_int = 0;
    c.glfwGetMonitorWorkarea(self.handle, &xpos, &ypos, &width, &height);
    return Workarea{ .x = @as(u32, @intCast(xpos)), .y = @as(u32, @intCast(ypos)), .width = @as(u32, @intCast(width)), .height = @as(u32, @intCast(height)) };
}

/// The physical size, in millimetres, of the display area of a monitor.
const PhysicalSize = struct {
    width_mm: u32,
    height_mm: u32,
};

/// Returns the physical size of the monitor.
///
/// Some platforms do not provide accurate monitor size information, either because the monitor
/// [EDID](https://en.wikipedia.org/wiki/Extended_display_identification_data)
/// data is incorrect or because the driver does not report it accurately.
///
/// win32: On Windows 8 and earlier the physical size is calculated from
/// the current resolution and system DPI instead of querying the monitor EDID data
/// @thread_safety This function must only be called from the main thread.
///
/// see also: monitor_properties
pub inline fn getPhysicalSize(self: Monitor) PhysicalSize {
    internal_debug.assertInitialized();
    var width_mm: c_int = 0;
    var height_mm: c_int = 0;
    c.glfwGetMonitorPhysicalSize(self.handle, &width_mm, &height_mm);
    return PhysicalSize{ .width_mm = @as(u32, @intCast(width_mm)), .height_mm = @as(u32, @intCast(height_mm)) };
}

/// The content scale for a monitor.
///
/// This is the ratio between the current DPI and the platform's default DPI. This is especially
/// important for text and any UI elements. If the pixel dimensions of your UI scaled by this look
/// appropriate on your machine then it should appear at a reasonable size on other machines
/// regardless of their DPI and scaling settings. This relies on the system DPI and scaling
/// settings being somewhat correct.
///
/// The content scale may depend on both the monitor resolution and pixel density and on users
/// settings. It may be very different from the raw DPI calculated from the physical size and
/// current resolution.
const ContentScale = struct {
    x_scale: f32,
    y_scale: f32,
};

/// Returns the content scale for the monitor.
///
/// Possible errors include glfw.ErrorCode.PlatformError.
/// A zero value is returned in the event of an error.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: monitor_scale, glfw.Window.getContentScale
pub inline fn getContentScale(self: Monitor) ContentScale {
    internal_debug.assertInitialized();
    var x_scale: f32 = 0;
    var y_scale: f32 = 0;
    c.glfwGetMonitorContentScale(self.handle, &x_scale, &y_scale);
    return ContentScale{ .x_scale = @as(f32, @floatCast(x_scale)), .y_scale = @as(f32, @floatCast(y_scale)) };
}

/// Returns the name of the specified monitor.
///
/// This function returns a human-readable name, encoded as UTF-8, of the specified monitor. The
/// name typically reflects the make and model of the monitor and is not guaranteed to be unique
/// among the connected monitors.
///
/// @pointer_lifetime The returned string is allocated and freed by GLFW. You should not free it
/// yourself. It is valid until the specified monitor is disconnected or the library is terminated.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: monitor_properties
pub inline fn getName(self: Monitor) [*:0]const u8 {
    internal_debug.assertInitialized();
    if (c.glfwGetMonitorName(self.handle)) |name| return @as([*:0]const u8, @ptrCast(name));
    // `glfwGetMonitorName` returns `null` only for errors, but the only error is unreachable
    // (NotInitialized)
    unreachable;
}

/// Sets the user pointer of the specified monitor.
///
/// This function sets the user-defined pointer of the specified monitor. The current value is
/// retained until the monitor is disconnected.
///
/// This function may be called from the monitor callback, even for a monitor that is being
/// disconnected.
///
/// @thread_safety This function may be called from any thread. Access is not synchronized.
///
/// see also: monitor_userptr, glfw.Monitor.getUserPointer
pub inline fn setUserPointer(self: Monitor, comptime T: type, ptr: *T) void {
    internal_debug.assertInitialized();
    c.glfwSetMonitorUserPointer(self.handle, ptr);
}

/// Returns the user pointer of the specified monitor.
///
/// This function returns the current value of the user-defined pointer of the specified monitor.
///
/// This function may be called from the monitor callback, even for a monitor that is being
/// disconnected.
///
/// @thread_safety This function may be called from any thread. Access is not synchronized.
///
/// see also: monitor_userptr, glfw.Monitor.setUserPointer
pub inline fn getUserPointer(self: Monitor, comptime T: type) ?*T {
    internal_debug.assertInitialized();
    const ptr = c.glfwGetMonitorUserPointer(self.handle);
    if (ptr == null) return null;
    return @as(*T, @ptrCast(@alignCast(ptr.?)));
}

/// Returns the available video modes for the specified monitor.
///
/// This function returns an array of all video modes supported by the monitor. The returned slice
/// is sorted in ascending order, first by color bit depth (the sum of all channel depths) and
/// then by resolution area (the product of width and height), then resolution width and finally
/// by refresh rate.
///
/// Possible errors include glfw.ErrorCode.PlatformError, glfw.ErrorCode.FeatureUnavailable.
/// Returns null in the event of an error.
///
/// The returned slice memory is owned by the caller.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: monitor_modes, glfw.Monitor.getVideoMode
///
/// wayland: Gamma handling is privileged protocol, this function will thus never be implemented and
/// emits glfw.ErrorCode.FeatureUnavailable
///
/// TODO(glfw): rewrite this to not require any allocation.
pub inline fn getVideoModes(self: Monitor, allocator: mem.Allocator) mem.Allocator.Error!?[]VideoMode {
    internal_debug.assertInitialized();
    var count: c_int = 0;
    if (c.glfwGetVideoModes(self.handle, &count)) |modes| {
        const slice = try allocator.alloc(VideoMode, @as(u32, @intCast(count)));
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            slice[i] = VideoMode{ .handle = @as([*c]const c.GLFWvidmode, @ptrCast(modes))[i] };
        }
        return slice;
    }
    return null;
}

/// Returns the current mode of the specified monitor.
///
/// This function returns the current video mode of the specified monitor. If you have created a
/// full screen window for that monitor, the return value will depend on whether that window is
/// iconified.
///
/// Possible errors include glfw.ErrorCode.PlatformError, glfw.ErrorCode.FeatureUnavailable.
/// Additionally returns null in the event of an error.
///
/// @thread_safety This function must only be called from the main thread.
///
/// wayland: Gamma handling is a privileged protocol, this function will thus never be implemented
/// and will thus never be implemented and emits glfw.ErrorCode.FeatureUnavailable
///
/// see also: monitor_modes, glfw.Monitor.getVideoModes
pub inline fn getVideoMode(self: Monitor) ?VideoMode {
    internal_debug.assertInitialized();
    if (c.glfwGetVideoMode(self.handle)) |mode| return VideoMode{ .handle = mode.* };
    return null;
}

/// Generates a gamma ramp and sets it for the specified monitor.
///
/// This function generates an appropriately sized gamma ramp from the specified exponent and then
/// calls glfw.Monitor.setGammaRamp with it. The value must be a finite number greater than zero.
///
/// The software controlled gamma ramp is applied _in addition_ to the hardware gamma correction,
/// which today is usually an approximation of sRGB gamma. This means that setting a perfectly
/// linear ramp, or gamma 1.0, will produce the default (usually sRGB-like) behavior.
///
/// For gamma correct rendering with OpenGL or OpenGL ES, see the glfw.srgb_capable hint.
///
/// Possible errors include glfw.ErrorCode.PlatformError, glfw.ErrorCode.FeatureUnavailable.
///
/// wayland: Gamma handling is privileged protocol, this function will thus never be implemented and
/// emits glfw.ErrorCode.FeatureUnavailable
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: monitor_gamma
pub inline fn setGamma(self: Monitor, gamma: f32) void {
    internal_debug.assertInitialized();

    std.debug.assert(!std.math.isNan(gamma));
    std.debug.assert(gamma >= 0);
    std.debug.assert(gamma <= std.math.f32_max);

    c.glfwSetGamma(self.handle, gamma);
}

/// Returns the current gamma ramp for the specified monitor.
///
/// This function returns the current gamma ramp of the specified monitor.
///
/// Possible errors include glfw.ErrorCode.PlatformError.
/// Additionally returns null in the event of an error.
///
/// wayland: Gamma handling is a privileged protocol, this function will thus never be implemented
/// and returns glfw.ErrorCode.FeatureUnavailable.
///
/// The returned gamma ramp is `.owned = true` by GLFW, and is valid until the monitor is
/// disconnected, this function is called again, or `glfw.terminate()` is called.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: monitor_gamma
pub inline fn getGammaRamp(self: Monitor) ?GammaRamp {
    internal_debug.assertInitialized();
    if (c.glfwGetGammaRamp(self.handle)) |ramp| return GammaRamp.fromC(ramp.*);
    return null;
}

/// Sets the current gamma ramp for the specified monitor.
///
/// This function sets the current gamma ramp for the specified monitor. The original gamma ramp
/// for that monitor is saved by GLFW the first time this function is called and is restored by
/// `glfw.terminate()`.
///
/// The software controlled gamma ramp is applied _in addition_ to the hardware gamma correction,
/// which today is usually an approximation of sRGB gamma. This means that setting a perfectly
/// linear ramp, or gamma 1.0, will produce the default (usually sRGB-like) behavior.
///
/// For gamma correct rendering with OpenGL or OpenGL ES, see the glfw.srgb_capable hint.
///
/// Possible errors include glfw.ErrorCode.PlatformError, glfw.ErrorCode.FeatureUnavailable.
///
/// The size of the specified gamma ramp should match the size of the current ramp for that
/// monitor. On win32, the gamma ramp size must be 256.
///
/// wayland: Gamma handling is a privileged protocol, this function will thus never be implemented
/// and returns glfw.ErrorCode.FeatureUnavailable.
///
/// @pointer_lifetime The specified gamma ramp is copied before this function returns.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: monitor_gamma
pub inline fn setGammaRamp(self: Monitor, ramp: GammaRamp) void {
    internal_debug.assertInitialized();
    c.glfwSetGammaRamp(self.handle, &ramp.toC());
}

/// Returns the currently connected monitors.
///
/// This function returns a slice of all currently connected monitors. The primary monitor is
/// always first. If no monitors were found, this function returns an empty slice.
///
/// The returned slice memory is owned by the caller. The underlying handles are owned by GLFW, and
/// are valid until the monitor configuration changes or `glfw.terminate` is called.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: monitor_monitors, monitor_event, glfw.monitor.getPrimary
pub inline fn getAll(allocator: mem.Allocator) mem.Allocator.Error![]Monitor {
    internal_debug.assertInitialized();
    var count: c_int = 0;
    if (c.glfwGetMonitors(&count)) |monitors| {
        const slice = try allocator.alloc(Monitor, @as(u32, @intCast(count)));
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            slice[i] = Monitor{ .handle = @as([*c]const ?*c.GLFWmonitor, @ptrCast(monitors))[i].? };
        }
        return slice;
    }
    // `glfwGetMonitors` returning null can be either an error or no monitors, but the only error is
    // unreachable (NotInitialized)
    return &[_]Monitor{};
}

/// Returns the primary monitor.
///
/// This function returns the primary monitor. This is usually the monitor where elements like
/// the task bar or global menu bar are located.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: monitor_monitors, glfw.monitors.getAll
pub inline fn getPrimary() ?Monitor {
    internal_debug.assertInitialized();
    if (c.glfwGetPrimaryMonitor()) |handle| return Monitor{ .handle = handle };
    return null;
}

/// Describes an event relating to a monitor.
pub const Event = enum(c_int) {
    /// The device was connected.
    connected = c.GLFW_CONNECTED,

    /// The device was disconnected.
    disconnected = c.GLFW_DISCONNECTED,
};

/// Sets the monitor configuration callback.
///
/// This function sets the monitor configuration callback, or removes the currently set callback.
/// This is called when a monitor is connected to or disconnected from the system. Example:
///
/// ```
/// fn monitorCallback(monitor: glfw.Monitor, event: glfw.Monitor.Event, data: *MyData) void {
///     // data is the pointer you passed into setCallback.
///     // event is one of .connected or .disconnected
/// }
/// ...
/// glfw.Monitor.setCallback(MyData, &myData, monitorCallback)
/// ```
///
/// `event` may be one of .connected or .disconnected. More events may be added in the future.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: monitor_event
pub inline fn setCallback(comptime callback: ?fn (monitor: Monitor, event: Event) void) void {
    internal_debug.assertInitialized();

    if (callback) |user_callback| {
        const CWrapper = struct {
            pub fn monitorCallbackWrapper(monitor: ?*c.GLFWmonitor, event: c_int) callconv(.c) void {
                @call(.always_inline, user_callback, .{
                    Monitor{ .handle = monitor.? },
                    @as(Event, @enumFromInt(event)),
                });
            }
        };

        if (c.glfwSetMonitorCallback(CWrapper.monitorCallbackWrapper) != null) return;
    } else {
        if (c.glfwSetMonitorCallback(null) != null) return;
    }
}

test "getAll" {
    const glfw = @import("main.zig");
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const allocator = testing.allocator;
    const monitors = try getAll(allocator);
    defer allocator.free(monitors);
}

test "getPrimary" {
    const glfw = @import("main.zig");
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    _ = getPrimary();
}

test "getPos" {
    const glfw = @import("main.zig");
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const monitor = getPrimary();
    if (monitor) |m| {
        _ = m.getPos();
    }
}

test "getWorkarea" {
    const glfw = @import("main.zig");
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const monitor = getPrimary();
    if (monitor) |m| {
        _ = m.getWorkarea();
    }
}

test "getPhysicalSize" {
    const glfw = @import("main.zig");
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const monitor = getPrimary();
    if (monitor) |m| {
        _ = m.getPhysicalSize();
    }
}

test "getContentScale" {
    const glfw = @import("main.zig");
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const monitor = getPrimary();
    if (monitor) |m| {
        _ = m.getContentScale();
    }
}

test "getName" {
    const glfw = @import("main.zig");
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const monitor = getPrimary();
    if (monitor) |m| {
        _ = m.getName();
    }
}

test "userPointer" {
    const glfw = @import("main.zig");
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const monitor = getPrimary();
    if (monitor) |m| {
        var p = m.getUserPointer(u32);
        try testing.expect(p == null);
        var x: u32 = 5;
        m.setUserPointer(u32, &x);
        p = m.getUserPointer(u32);
        try testing.expectEqual(p.?.*, 5);
    }
}

test "setCallback" {
    const glfw = @import("main.zig");
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    setCallback(struct {
        fn callback(monitor: Monitor, event: Event) void {
            _ = monitor;
            _ = event;
        }
    }.callback);
}

test "getVideoModes" {
    const glfw = @import("main.zig");
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const monitor = getPrimary();
    if (monitor) |m| {
        const allocator = testing.allocator;
        const modes_maybe = try m.getVideoModes(allocator);
        if (modes_maybe) |modes| {
            defer allocator.free(modes);
        }
    }
}

test "getVideoMode" {
    const glfw = @import("main.zig");
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const monitor = getPrimary();
    if (monitor) |m| {
        _ = m.getVideoMode();
    }
}

test "set_getGammaRamp" {
    const allocator = testing.allocator;
    const glfw = @import("main.zig");
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const monitor = getPrimary();
    if (monitor) |m| {
        if (m.getGammaRamp()) |ramp| {
            // Set it to the exact same value; if we do otherwise an our tests fail it wouldn't call
            // terminate and our made-up gamma ramp would get stuck.
            m.setGammaRamp(ramp);

            // technically not needed here / noop because GLFW owns this gamma ramp.
            defer ramp.deinit(allocator);
        }
    }
}
