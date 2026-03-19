const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const lib_alloc = @import("../../lib/allocator.zig");
const CAllocator = lib_alloc.Allocator;
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
    result: *Event,
) callconv(.c) Result {
    const alloc = lib_alloc.default(alloc_);
    const ptr = alloc.create(MouseEventWrapper) catch
        return .out_of_memory;
    ptr.* = .{ .alloc = alloc };
    result.* = ptr;
    return .success;
}

pub fn free(event_: Event) callconv(.c) void {
    const wrapper = event_ orelse return;
    const alloc = wrapper.alloc;
    alloc.destroy(wrapper);
}

pub fn set_action(event_: Event, action: Action) callconv(.c) void {
    if (comptime std.debug.runtime_safety) {
        _ = std.meta.intToEnum(Action, @intFromEnum(action)) catch {
            log.warn("set_action invalid action value={d}", .{@intFromEnum(action)});
            return;
        };
    }

    event_.?.event.action = action;
}

pub fn get_action(event_: Event) callconv(.c) Action {
    return event_.?.event.action;
}

pub fn set_button(event_: Event, button: Button) callconv(.c) void {
    if (comptime std.debug.runtime_safety) {
        _ = std.meta.intToEnum(Button, @intFromEnum(button)) catch {
            log.warn("set_button invalid button value={d}", .{@intFromEnum(button)});
            return;
        };
    }

    event_.?.event.button = button;
}

pub fn clear_button(event_: Event) callconv(.c) void {
    event_.?.event.button = null;
}

pub fn get_button(event_: Event, out: ?*Button) callconv(.c) bool {
    if (event_.?.event.button) |button| {
        if (out) |ptr| ptr.* = button;
        return true;
    }

    return false;
}

pub fn set_mods(event_: Event, mods: Mods) callconv(.c) void {
    event_.?.event.mods = mods;
}

pub fn get_mods(event_: Event) callconv(.c) Mods {
    return event_.?.event.mods;
}

pub fn set_position(event_: Event, pos: Position) callconv(.c) void {
    event_.?.event.pos = pos;
}

pub fn get_position(event_: Event) callconv(.c) Position {
    return event_.?.event.pos;
}

test "alloc" {
    var e: Event = undefined;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
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
        &lib_alloc.test_allocator,
        &e,
    ));
    defer free(e);

    // Action
    set_action(e, .motion);
    try testing.expectEqual(Action.motion, get_action(e));

    // Button
    set_button(e, .left);
    var button: Button = .unknown;
    try testing.expect(get_button(e, &button));
    try testing.expectEqual(Button.left, button);
    try testing.expect(get_button(e, null));

    clear_button(e);
    try testing.expect(!get_button(e, &button));

    // Mods
    const mods: Mods = .{ .shift = true, .ctrl = true };
    set_mods(e, mods);
    const got_mods = get_mods(e);
    try testing.expect(got_mods.shift);
    try testing.expect(got_mods.ctrl);
    try testing.expect(!got_mods.alt);

    // Position
    set_position(e, .{ .x = 12.5, .y = -4.0 });
    const pos = get_position(e);
    try testing.expectEqual(@as(f32, 12.5), pos.x);
    try testing.expectEqual(@as(f32, -4.0), pos.y);
}
