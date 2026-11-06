const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const lib = @import("../lib.zig");
const CAllocator = lib.alloc.Allocator;
const key = @import("../../input/key.zig");
const mouse = @import("../../input/mouse.zig");
const mouse_encode = @import("../../input/mouse_encode.zig");
const Result = @import("result.zig").Result;

const log = std.log.scoped(.mouse_event);

/// Wrapper around mouse event that tracks the allocator for C API usage.
const MouseEventWrapper = struct {
    event: mouse_encode.Event = .{},
    alloc: Allocator,
};

/// C: GhosttyMouseEvent
pub const Event = ?*MouseEventWrapper;

/// C: GhosttyMouseAction
pub const Action = mouse.Action;

/// C: GhosttyMouseButton
pub const Button = mouse.Button;

/// C: GhosttyMousePosition
pub const Position = mouse_encode.Event.Pos;

/// C: GhosttyMods
pub const Mods = key.Mods;

pub fn new(
    alloc_: ?*const CAllocator,
    result_: ?*Event,
) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.input_encode)) {
        if (result_) |o| o.* = null;
        return .unsupported;
    }
    const result = result_ orelse return .invalid_value;
    const alloc = lib.alloc.default(alloc_);
    const ptr = alloc.create(MouseEventWrapper) catch
        return .out_of_memory;
    ptr.* = .{ .alloc = alloc };
    result.* = ptr;
    return .success;
}

pub fn free(event_: Event) callconv(lib.calling_conv) void {
    if (comptime !lib.feature(.input_encode)) return;
    const wrapper = event_ orelse return;
    const alloc = wrapper.alloc;
    alloc.destroy(wrapper);
}

pub fn set_action(
    event_: Event,
    action: lib.CEnum(Action),
) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.input_encode)) return .unsupported;
    const wrapper = event_ orelse return .invalid_value;
    wrapper.event.action = lib.enumFromC(Action, action) orelse
        return .invalid_value;
    return .success;
}

pub fn get_action(event_: Event) callconv(lib.calling_conv) Action {
    if (comptime !lib.feature(.input_encode)) return .press;
    const wrapper = event_ orelse return .press;
    return wrapper.event.action;
}

pub fn set_button(
    event_: Event,
    button: lib.CEnum(Button),
) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.input_encode)) return .unsupported;
    const wrapper = event_ orelse return .invalid_value;
    wrapper.event.button = lib.enumFromC(Button, button) orelse
        return .invalid_value;
    return .success;
}

pub fn clear_button(event_: Event) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.input_encode)) return .unsupported;
    const wrapper = event_ orelse return .invalid_value;
    wrapper.event.button = null;
    return .success;
}

pub fn get_button(event_: Event, out_: ?*Button) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.input_encode)) return .unsupported;
    const wrapper = event_ orelse return .invalid_value;
    const out = out_ orelse return .invalid_value;
    out.* = wrapper.event.button orelse return .no_value;
    return .success;
}

pub fn set_mods(event_: Event, mods: Mods) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.input_encode)) return .unsupported;
    const wrapper = event_ orelse return .invalid_value;
    wrapper.event.mods = mods;
    return .success;
}

pub fn get_mods(event_: Event) callconv(lib.calling_conv) Mods {
    if (comptime !lib.feature(.input_encode)) return .{};
    const wrapper = event_ orelse return .{};
    return wrapper.event.mods;
}

pub fn set_position(event_: Event, pos: Position) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.input_encode)) return .unsupported;
    const wrapper = event_ orelse return .invalid_value;
    wrapper.event.pos = pos;
    return .success;
}

pub fn get_position(event_: Event) callconv(lib.calling_conv) Position {
    if (comptime !lib.feature(.input_encode)) return .{};
    const wrapper = event_ orelse return .{ .x = 0, .y = 0 };
    return wrapper.event.pos;
}

test "alloc" {
    var e: Event = undefined;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &e,
    ));
    free(e);
}

test "free null" {
    free(null);
}

test "set/get" {
    var e: Event = undefined;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &e,
    ));
    defer free(e);

    // Action
    try testing.expectEqual(Result.success, set_action(e, .motion));
    try testing.expectEqual(Action.motion, get_action(e));

    // Button
    try testing.expectEqual(Result.success, set_button(e, .left));
    var button: Button = .unknown;
    try testing.expectEqual(Result.success, get_button(e, &button));
    try testing.expectEqual(Button.left, button);
    try testing.expectEqual(Result.invalid_value, get_button(e, null));

    // No button leaves the output untouched.
    try testing.expectEqual(Result.success, clear_button(e));
    button = .right;
    try testing.expectEqual(Result.no_value, get_button(e, &button));
    try testing.expectEqual(Button.right, button);

    // Mods
    const mods: Mods = .{ .shift = true, .ctrl = true };
    try testing.expectEqual(Result.success, set_mods(e, mods));
    const got_mods = get_mods(e);
    try testing.expect(got_mods.shift);
    try testing.expect(got_mods.ctrl);
    try testing.expect(!got_mods.alt);

    // Position
    try testing.expectEqual(Result.success, set_position(e, .{ .x = 12.5, .y = -4.0 }));
    const pos = get_position(e);
    try testing.expectEqual(@as(f32, 12.5), pos.x);
    try testing.expectEqual(@as(f32, -4.0), pos.y);
}

test "no button on a new event" {
    var e: Event = undefined;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &e,
    ));
    defer free(e);

    var button: Button = .left;
    try testing.expectEqual(Result.no_value, get_button(e, &button));
    try testing.expectEqual(Button.left, button);
}

test "null event" {
    // Setters report a NULL event.
    try testing.expectEqual(Result.invalid_value, set_action(null, .press));
    try testing.expectEqual(Result.invalid_value, set_button(null, .left));
    try testing.expectEqual(Result.invalid_value, clear_button(null));
    try testing.expectEqual(Result.invalid_value, set_mods(null, .{ .shift = true }));
    try testing.expectEqual(Result.invalid_value, set_position(null, .{ .x = 1, .y = 2 }));

    // get_button reports it and leaves the output untouched.
    var button: Button = .left;
    try testing.expectEqual(Result.invalid_value, get_button(null, &button));
    try testing.expectEqual(Button.left, button);
    try testing.expectEqual(Result.invalid_value, get_button(null, null));

    // Getters return the zero value of their type.
    try testing.expectEqual(Action.press, get_action(null));
    try testing.expectEqual(Mods{}, get_mods(null));
    const pos = get_position(null);
    try testing.expectEqual(@as(f32, 0), pos.x);
    try testing.expectEqual(@as(f32, 0), pos.y);
}
