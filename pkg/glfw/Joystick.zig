//! Represents a Joystick or gamepad
//!
//! It can be manually crafted via e.g. `glfw.Joystick{.jid = .one}`, but more
//! typically you'll want to discover the joystick using `glfw.Joystick.setCallback`.

const std = @import("std");

const c = @import("c.zig").c;
const Window = @import("Window.zig");
const Action = @import("action.zig").Action;
const GamepadAxis = @import("gamepad_axis.zig").GamepadAxis;
const GamepadButton = @import("gamepad_button.zig").GamepadButton;
const Hat = @import("hat.zig").Hat;

const internal_debug = @import("internal_debug.zig");

const Joystick = @This();

/// The GLFW joystick ID.
jid: Id,

/// Joystick IDs.
///
/// See glfw.Joystick.setCallback for how these are used.
pub const Id = enum(c_int) {
    one = c.GLFW_JOYSTICK_1,
    two = c.GLFW_JOYSTICK_2,
    three = c.GLFW_JOYSTICK_3,
    four = c.GLFW_JOYSTICK_4,
    five = c.GLFW_JOYSTICK_5,
    six = c.GLFW_JOYSTICK_6,
    seven = c.GLFW_JOYSTICK_7,
    eight = c.GLFW_JOYSTICK_8,
    nine = c.GLFW_JOYSTICK_9,
    ten = c.GLFW_JOYSTICK_10,
    eleven = c.GLFW_JOYSTICK_11,
    twelve = c.GLFW_JOYSTICK_12,
    thirteen = c.GLFW_JOYSTICK_13,
    fourteen = c.GLFW_JOYSTICK_14,
    fifteen = c.GLFW_JOYSTICK_15,
    sixteen = c.GLFW_JOYSTICK_16,
    pub const last = @as(@This(), @enumFromInt(c.GLFW_JOYSTICK_LAST));
};

/// Gamepad input state
///
/// This describes the input state of a gamepad.
///
/// see also: gamepad, glfwGetGamepadState
const GamepadState = extern struct {
    /// The states of each gamepad button (see gamepad_buttons), `glfw.Action.press` or `glfw.Action.release`.
    ///
    /// Use the enumeration helper e.g. `.getButton(.dpad_up)` to access these indices.
    buttons: [15]u8,

    /// The states of each gamepad axis (see gamepad_axes), in the range -1.0 to 1.0 inclusive.
    ///
    /// Use the enumeration helper e.g. `.getAxis(.left_x)` to access these indices.
    axes: [6]f32,

    /// Returns the state of the specified gamepad button.
    pub fn getButton(self: @This(), which: GamepadButton) Action {
        return @as(Action, @enumFromInt(self.buttons[@as(u32, @intCast(@intFromEnum(which)))]));
    }

    /// Returns the status of the specified gamepad axis, in the range -1.0 to 1.0 inclusive.
    pub fn getAxis(self: @This(), which: GamepadAxis) f32 {
        return self.axes[@as(u32, @intCast(@intFromEnum(which)))];
    }
};

/// Returns whether the specified joystick is present.
///
/// This function returns whether the specified joystick is present.
///
/// There is no need to call this function before other functions that accept a joystick ID, as
/// they all check for presence before performing any other work.
///
/// @return `true` if the joystick is present, or `false` otherwise.
///
/// Possible errors include glfw.ErrorCode.InvalidEnum and glfw.ErrorCode.PlatformError.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: joystick
pub inline fn present(self: Joystick) bool {
    internal_debug.assertInitialized();
    const is_present = c.glfwJoystickPresent(@intFromEnum(self.jid));
    return is_present == c.GLFW_TRUE;
}

/// Returns the values of all axes of the specified joystick.
///
/// This function returns the values of all axes of the specified joystick. Each element in the
/// array is a value between -1.0 and 1.0.
///
/// If the specified joystick is not present this function will return null but will not generate
/// an error. This can be used instead of first calling glfw.Joystick.present.
///
/// @return An array of axis values, or null if the joystick is not present.
///
/// Possible errors include glfw.ErrorCode.InvalidEnum and glfw.ErrorCode.PlatformError.
/// null is additionally returned in the event of an error.
///
/// @pointer_lifetime The returned array is allocated and freed by GLFW. You should not free it
/// yourself. It is valid until the specified joystick is disconnected or the library is
/// terminated.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: joystick_axis
/// Replaces `glfwGetJoystickPos`.
pub inline fn getAxes(self: Joystick) ?[]const f32 {
    internal_debug.assertInitialized();
    var count: c_int = undefined;
    const axes = c.glfwGetJoystickAxes(@intFromEnum(self.jid), &count);
    if (axes == null) return null;
    return axes[0..@as(u32, @intCast(count))];
}

/// Returns the state of all buttons of the specified joystick.
///
/// This function returns the state of all buttons of the specified joystick. Each element in the
/// array is either `glfw.Action.press` or `glfw.Action.release`.
///
/// For backward compatibility with earlier versions that did not have glfw.Joystick.getHats, the
/// button array also includes all hats, each represented as four buttons. The hats are in the same
/// order as returned by glfw.Joystick.getHats and are in the order _up_, _right_, _down_ and
/// _left_. To disable these extra buttons, set the glfw.joystick_hat_buttons init hint before
/// initialization.
///
/// If the specified joystick is not present this function will return null but will not generate an
/// error. This can be used instead of first calling glfw.Joystick.present.
///
/// @return An array of button states, or null if the joystick is not present.
///
/// Possible errors include glfw.ErrorCode.InvalidEnum and glfw.ErrorCode.PlatformError.
/// null is additionally returned in the event of an error.
///
/// @pointer_lifetime The returned array is allocated and freed by GLFW. You should not free it
/// yourself. It is valid until the specified joystick is disconnected or the library is terminated.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: joystick_button
pub inline fn getButtons(self: Joystick) ?[]const u8 {
    internal_debug.assertInitialized();
    var count: c_int = undefined;
    const buttons = c.glfwGetJoystickButtons(@intFromEnum(self.jid), &count);
    if (buttons == null) return null;
    return buttons[0..@as(u32, @intCast(count))];
}

/// Returns the state of all hats of the specified joystick.
///
/// This function returns the state of all hats of the specified joystick. Each element in the array
/// is one of the following values:
///
/// | Name                      | Value                                       |
/// |---------------------------|---------------------------------------------|
/// | `glfw.RawHats.centered`   | 0                                           |
/// | `glfw.RawHats.up`         | 1                                           |
/// | `glfw.RawHats.right`      | 2                                           |
/// | `glfw.RawHats.down`       | 4                                           |
/// | `glfw.RawHats.left`       | 8                                           |
/// | `glfw.RawHats.right_up`   | `glfw.RawHats.right` \| `glfw.RawHats.up`   |
/// | `glfw.RawHats.right_down` | `glfw.RawHats.right` \| `glfw.RawHats.down` |
/// | `glfw.RawHats.left_up`    | `glfw.RawHats.left` \| `glfw.RawHats.up`    |
/// | `glfw.RawHats.left_down`  | `glfw.RawHats.left` \| `glfw.RawHats.down`  |
///
/// The diagonal directions are bitwise combinations of the primary (up, right, down and left)
/// directions, since the Zig GLFW wrapper returns a packed struct it is trivial to test for these:
///
/// ```
/// if (hats.up and hats.right) {
///     // up-right!
/// }
/// ```
///
/// If the specified joystick is not present this function will return null but will not generate an
/// error. This can be used instead of first calling glfw.Joystick.present.
///
/// @return An array of hat states, or null if the joystick is not present.
///
/// Possible errors include glfw.ErrorCode.InvalidEnum and glfw.ErrorCode.PlatformError.
/// null is additionally returned in the event of an error.
///
/// @pointer_lifetime The returned array is allocated and freed by GLFW. You should not free it
/// yourself. It is valid until the specified joystick is disconnected, this function is called
/// again for that joystick or the library is terminated.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: joystick_hat
pub inline fn getHats(self: Joystick) ?[]const Hat {
    internal_debug.assertInitialized();
    var count: c_int = undefined;
    const hats = c.glfwGetJoystickHats(@intFromEnum(self.jid), &count);
    if (hats == null) return null;
    const slice = hats[0..@as(u32, @intCast(count))];
    return @as(*const []const Hat, @ptrCast(&slice)).*;
}

/// Returns the name of the specified joystick.
///
/// This function returns the name, encoded as UTF-8, of the specified joystick. The returned string
/// is allocated and freed by GLFW. You should not free it yourself.
///
/// If the specified joystick is not present this function will return null but will not generate an
/// error. This can be used instead of first calling glfw.Joystick.present.
///
/// @return The UTF-8 encoded name of the joystick, or null if the joystick is not present or an
/// error occurred.
///
/// Possible errors include glfw.ErrorCode.InvalidEnum and glfw.ErrorCode.PlatformError.
/// null is additionally returned in the event of an error.
///
/// @pointer_lifetime The returned string is allocated and freed by GLFW. You should not free it
/// yourself. It is valid until the specified joystick is disconnected or the library is terminated.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: joystick_name
pub inline fn getName(self: Joystick) ?[:0]const u8 {
    internal_debug.assertInitialized();
    const name_opt = c.glfwGetJoystickName(@intFromEnum(self.jid));
    return if (name_opt) |name|
        std.mem.span(@as([*:0]const u8, @ptrCast(name)))
    else
        null;
}

/// Returns the SDL compatible GUID of the specified joystick.
///
/// This function returns the SDL compatible GUID, as a UTF-8 encoded hexadecimal string, of the
/// specified joystick. The returned string is allocated and freed by GLFW. You should not free it
/// yourself.
///
/// The GUID is what connects a joystick to a gamepad mapping. A connected joystick will always have
/// a GUID even if there is no gamepad mapping assigned to it.
///
/// If the specified joystick is not present this function will return null but will not generate an
/// error. This can be used instead of first calling glfw.Joystick.present.
///
/// The GUID uses the format introduced in SDL 2.0.5. This GUID tries to uniquely identify the make
/// and model of a joystick but does not identify a specific unit, e.g. all wired Xbox 360
/// controllers will have the same GUID on that platform. The GUID for a unit may vary between
/// platforms depending on what hardware information the platform specific APIs provide.
///
/// @return The UTF-8 encoded GUID of the joystick, or null if the joystick is not present.
///
/// Possible errors include glfw.ErrorCode.InvalidEnum and glfw.ErrorCode.PlatformError.
/// null is additionally returned in the event of an error.
///
/// @pointer_lifetime The returned string is allocated and freed by GLFW. You should not free it
/// yourself. It is valid until the specified joystick is disconnected or the library is terminated.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: gamepad
pub inline fn getGUID(self: Joystick) ?[:0]const u8 {
    internal_debug.assertInitialized();
    const guid_opt = c.glfwGetJoystickGUID(@intFromEnum(self.jid));
    return if (guid_opt) |guid|
        std.mem.span(@as([*:0]const u8, @ptrCast(guid)))
    else
        null;
}

/// Sets the user pointer of the specified joystick.
///
/// This function sets the user-defined pointer of the specified joystick. The current value is
/// retained until the joystick is disconnected. The initial value is null.
///
/// This function may be called from the joystick callback, even for a joystick that is being disconnected.
///
/// @thread_safety This function may be called from any thread. Access is not synchronized.
///
/// see also: joystick_userptr, glfw.Joystick.getUserPointer
pub inline fn setUserPointer(self: Joystick, comptime T: type, pointer: *T) void {
    internal_debug.assertInitialized();
    c.glfwSetJoystickUserPointer(@intFromEnum(self.jid), @as(*anyopaque, @ptrCast(pointer)));
}

/// Returns the user pointer of the specified joystick.
///
/// This function returns the current value of the user-defined pointer of the specified joystick.
/// The initial value is null.
///
/// This function may be called from the joystick callback, even for a joystick that is being
/// disconnected.
///
/// @thread_safety This function may be called from any thread. Access is not synchronized.
///
/// see also: joystick_userptr, glfw.Joystick.setUserPointer
pub inline fn getUserPointer(self: Joystick, comptime PointerType: type) ?PointerType {
    internal_debug.assertInitialized();
    const ptr = c.glfwGetJoystickUserPointer(@intFromEnum(self.jid));
    if (ptr) |p| return @as(PointerType, @ptrCast(@alignCast(p)));
    return null;
}

/// Describes an event relating to a joystick.
pub const Event = enum(c_int) {
    /// The device was connected.
    connected = c.GLFW_CONNECTED,

    /// The device was disconnected.
    disconnected = c.GLFW_DISCONNECTED,
};

/// Sets the joystick configuration callback.
///
/// This function sets the joystick configuration callback, or removes the currently set callback.
/// This is called when a joystick is connected to or disconnected from the system.
///
/// For joystick connection and disconnection events to be delivered on all platforms, you need to
/// call one of the event processing (see events) functions. Joystick disconnection may also be
/// detected and the callback called by joystick functions. The function will then return whatever
/// it returns if the joystick is not present.
///
/// @param[in] callback The new callback, or null to remove the currently set callback.
///
/// @callback_param `jid` The joystick that was connected or disconnected.
/// @callback_param `event` One of `.connected` or `.disconnected`. Future releases may add
/// more events.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: joystick_event
pub inline fn setCallback(comptime callback: ?fn (joystick: Joystick, event: Event) void) void {
    internal_debug.assertInitialized();

    if (callback) |user_callback| {
        const CWrapper = struct {
            pub fn joystickCallbackWrapper(jid: c_int, event: c_int) callconv(.c) void {
                @call(.always_inline, user_callback, .{
                    Joystick{ .jid = @as(Joystick.Id, @enumFromInt(jid)) },
                    @as(Event, @enumFromInt(event)),
                });
            }
        };

        if (c.glfwSetJoystickCallback(CWrapper.joystickCallbackWrapper) != null) return;
    } else {
        if (c.glfwSetJoystickCallback(null) != null) return;
    }
}

/// Adds the specified SDL_GameControllerDB gamepad mappings.
///
/// This function parses the specified ASCII encoded string and updates the internal list with any
/// gamepad mappings it finds. This string may contain either a single gamepad mapping or many
/// mappings separated by newlines. The parser supports the full format of the `gamecontrollerdb.txt`
/// source file including empty lines and comments.
///
/// See gamepad_mapping for a description of the format.
///
/// If there is already a gamepad mapping for a given GUID in the internal list, it will be
/// replaced by the one passed to this function. If the library is terminated and re-initialized
/// the internal list will revert to the built-in default.
///
/// @param[in] string The string containing the gamepad mappings.
///
/// Possible errors include glfw.ErrorCode.InvalidValue.
/// Returns a boolean indicating success.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: gamepad, glfw.Joystick.isGamepad, glfwGetGamepadName
///
///
/// @ingroup input
pub inline fn updateGamepadMappings(gamepad_mappings: [*:0]const u8) bool {
    internal_debug.assertInitialized();
    return c.glfwUpdateGamepadMappings(gamepad_mappings) == c.GLFW_TRUE;
}

/// Returns whether the specified joystick has a gamepad mapping.
///
/// This function returns whether the specified joystick is both present and has a gamepad mapping.
///
/// If the specified joystick is present but does not have a gamepad mapping this function will
/// return `false` but will not generate an error. Call glfw.Joystick.present to check if a
/// joystick is present regardless of whether it has a mapping.
///
/// @return `true` if a joystick is both present and has a gamepad mapping, or `false` otherwise.
///
/// Possible errors include glfw.ErrorCode.InvalidEnum.
/// Additionally returns false in the event of an error.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: gamepad, glfw.Joystick.getGamepadState
pub inline fn isGamepad(self: Joystick) bool {
    internal_debug.assertInitialized();
    const is_gamepad = c.glfwJoystickIsGamepad(@intFromEnum(self.jid));
    return is_gamepad == c.GLFW_TRUE;
}

/// Returns the human-readable gamepad name for the specified joystick.
///
/// This function returns the human-readable name of the gamepad from the gamepad mapping assigned
/// to the specified joystick.
///
/// If the specified joystick is not present or does not have a gamepad mapping this function will
/// return null, not an error. Call glfw.Joystick.present to check whether it is
/// present regardless of whether it has a mapping.
///
/// @return The UTF-8 encoded name of the gamepad, or null if the joystick is not present or does
/// not have a mapping.
///
/// Possible errors include glfw.ErrorCode.InvalidEnum.
/// Additionally returns null in the event of an error.
///
/// @pointer_lifetime The returned string is allocated and freed by GLFW. You should not free it
/// yourself. It is valid until the specified joystick is disconnected, the gamepad mappings are
/// updated or the library is terminated.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: gamepad, glfw.Joystick.isGamepad
pub inline fn getGamepadName(self: Joystick) ?[:0]const u8 {
    internal_debug.assertInitialized();
    const name_opt = c.glfwGetGamepadName(@intFromEnum(self.jid));
    return if (name_opt) |name|
        std.mem.span(@as([*:0]const u8, @ptrCast(name)))
    else
        null;
}

/// Retrieves the state of the joystick remapped as a gamepad.
///
/// This function retrieves the state of the joystick remapped to an Xbox-like gamepad.
///
/// If the specified joystick is not present or does not have a gamepad mapping this function will
/// return `false`. Call glfw.joystickPresent to check whether it is present regardless of whether
/// it has a mapping.
///
/// The Guide button may not be available for input as it is often hooked by the system or the
/// Steam client.
///
/// Not all devices have all the buttons or axes provided by GamepadState. Unavailable buttons
/// and axes will always report `glfw.Action.release` and 0.0 respectively.
///
/// @param[in] jid The joystick (see joysticks) to query.
/// @param[out] state The gamepad input state of the joystick.
/// @return the gamepad input state if successful, or null if no joystick is connected or it has no
/// gamepad mapping.
///
/// Possible errors include glfw.ErrorCode.InvalidEnum.
/// Returns null in the event of an error.
///
/// @thread_safety This function must only be called from the main thread.
///
/// see also: gamepad, glfw.UpdateGamepadMappings, glfw.Joystick.isGamepad
pub inline fn getGamepadState(self: Joystick) ?GamepadState {
    internal_debug.assertInitialized();
    var state: GamepadState = undefined;
    const success = c.glfwGetGamepadState(@intFromEnum(self.jid), @as(*c.GLFWgamepadstate, @ptrCast(&state)));
    return if (success == c.GLFW_TRUE) state else null;
}

test "present" {
    const glfw = @import("main.zig");
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const joystick = glfw.Joystick{ .jid = .one };
    _ = joystick.present();
}

test "getAxes" {
    const glfw = @import("main.zig");
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const joystick = glfw.Joystick{ .jid = .one };
    _ = joystick.getAxes();
}

test "getButtons" {
    const glfw = @import("main.zig");
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const joystick = glfw.Joystick{ .jid = .one };
    _ = joystick.getButtons();
}

test "getHats" {
    const glfw = @import("main.zig");
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const joystick = glfw.Joystick{ .jid = .one };

    if (joystick.getHats()) |hats| {
        for (hats) |hat| {
            if (hat.down and hat.up) {
                // down-up!
            }
        }
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

    const joystick = glfw.Joystick{ .jid = .one };
    _ = joystick.getName();
}

test "getGUID" {
    const glfw = @import("main.zig");
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const joystick = glfw.Joystick{ .jid = .one };
    _ = joystick.getGUID();
}

test "setUserPointer_syntax" {
    const glfw = @import("main.zig");
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const joystick = glfw.Joystick{ .jid = .one };

    // Must be called from joystick callback, we cannot test it.
    _ = joystick;
    _ = setUserPointer;
}

test "getUserPointer_syntax" {
    const glfw = @import("main.zig");
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const joystick = glfw.Joystick{ .jid = .one };

    // Must be called from joystick callback, we cannot test it.
    _ = joystick;
    _ = getUserPointer;
}

test "setCallback" {
    const glfw = @import("main.zig");
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    glfw.Joystick.setCallback((struct {
        pub fn callback(joystick: Joystick, event: Event) void {
            _ = joystick;
            _ = event;
        }
    }).callback);
}

test "updateGamepadMappings_syntax" {
    // We don't have a gamepad mapping to test with, just confirm the syntax is good.
    _ = updateGamepadMappings;
}

test "isGamepad" {
    const glfw = @import("main.zig");
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const joystick = glfw.Joystick{ .jid = .one };
    _ = joystick.isGamepad();
}

test "getGamepadName" {
    const glfw = @import("main.zig");
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const joystick = glfw.Joystick{ .jid = .one };
    _ = joystick.getGamepadName();
}

test "getGamepadState" {
    const glfw = @import("main.zig");
    defer glfw.clearError(); // clear any error we generate
    if (!glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}", .{glfw.getErrorString()});
        std.process.exit(1);
    }
    defer glfw.terminate();

    const joystick = glfw.Joystick{ .jid = .one };
    _ = joystick.getGamepadState();
    _ = (std.mem.zeroes(GamepadState)).getAxis(.left_x);
    _ = (std.mem.zeroes(GamepadState)).getButton(.dpad_up);
}
