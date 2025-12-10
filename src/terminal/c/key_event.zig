const std = @import("std");
const Allocator = std.mem.Allocator;
const lib_alloc = @import("../../lib/allocator.zig");
const CAllocator = lib_alloc.Allocator;
const key = @import("../../input/key.zig");
const Result = @import("result.zig").Result;

const log = std.log.scoped(.key_event);

/// Wrapper around KeyEvent that tracks the allocator for C API usage.
/// The UTF-8 text is not owned by this wrapper - the caller is responsible
/// for ensuring the lifetime of any UTF-8 text set via set_utf8.
const KeyEventWrapper = struct {
    event: key.KeyEvent = .{},
    alloc: Allocator,
};

/// C: GhosttyKeyEvent
pub const Event = ?*KeyEventWrapper;

pub fn new(
    alloc_: ?*const CAllocator,
    result: *Event,
) callconv(.c) Result {
    const alloc = lib_alloc.default(alloc_);
    const ptr = alloc.create(KeyEventWrapper) catch
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

pub fn set_action(event_: Event, action: key.Action) callconv(.c) void {
    if (comptime std.debug.runtime_safety) {
        _ = std.meta.intToEnum(key.Action, @intFromEnum(action)) catch {
            log.warn("set_action invalid action value={d}", .{@intFromEnum(action)});
            return;
        };
    }

    const event: *key.KeyEvent = &event_.?.event;
    event.action = action;
}

pub fn get_action(event_: Event) callconv(.c) key.Action {
    const event: *key.KeyEvent = &event_.?.event;
    return event.action;
}

pub fn set_key(event_: Event, k: key.Key) callconv(.c) void {
    if (comptime std.debug.runtime_safety) {
        _ = std.meta.intToEnum(key.Key, @intFromEnum(k)) catch {
            log.warn("set_key invalid key value={d}", .{@intFromEnum(k)});
            return;
        };
    }

    const event: *key.KeyEvent = &event_.?.event;
    event.key = k;
}

pub fn get_key(event_: Event) callconv(.c) key.Key {
    const event: *key.KeyEvent = &event_.?.event;
    return event.key;
}

pub fn set_mods(event_: Event, mods: key.Mods) callconv(.c) void {
    const event: *key.KeyEvent = &event_.?.event;
    event.mods = mods;
}

pub fn get_mods(event_: Event) callconv(.c) key.Mods {
    const event: *key.KeyEvent = &event_.?.event;
    return event.mods;
}

pub fn set_consumed_mods(event_: Event, consumed_mods: key.Mods) callconv(.c) void {
    const event: *key.KeyEvent = &event_.?.event;
    event.consumed_mods = consumed_mods;
}

pub fn get_consumed_mods(event_: Event) callconv(.c) key.Mods {
    const event: *key.KeyEvent = &event_.?.event;
    return event.consumed_mods;
}

pub fn set_composing(event_: Event, composing: bool) callconv(.c) void {
    const event: *key.KeyEvent = &event_.?.event;
    event.composing = composing;
}

pub fn get_composing(event_: Event) callconv(.c) bool {
    const event: *key.KeyEvent = &event_.?.event;
    return event.composing;
}

pub fn set_utf8(event_: Event, utf8: ?[*]const u8, len: usize) callconv(.c) void {
    const event: *key.KeyEvent = &event_.?.event;
    event.utf8 = if (utf8) |ptr| ptr[0..len] else "";
}

pub fn get_utf8(event_: Event, len: ?*usize) callconv(.c) ?[*]const u8 {
    const event: *key.KeyEvent = &event_.?.event;
    if (len) |l| l.* = event.utf8.len;
    return if (event.utf8.len == 0) null else event.utf8.ptr;
}

pub fn set_unshifted_codepoint(event_: Event, codepoint: u32) callconv(.c) void {
    const event: *key.KeyEvent = &event_.?.event;
    event.unshifted_codepoint = @truncate(codepoint);
}

pub fn get_unshifted_codepoint(event_: Event) callconv(.c) u32 {
    const event: *key.KeyEvent = &event_.?.event;
    return event.unshifted_codepoint;
}

test "alloc" {
    const testing = std.testing;
    var e: Event = undefined;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &e,
    ));
    free(e);
}

test "set" {
    const testing = std.testing;
    var e: Event = undefined;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &e,
    ));
    defer free(e);

    // Test action
    set_action(e, .press);
    try testing.expectEqual(key.Action.press, e.?.event.action);

    // Test key
    set_key(e, .key_a);
    try testing.expectEqual(key.Key.key_a, e.?.event.key);

    // Test mods
    const mods: key.Mods = .{ .shift = true, .ctrl = true };
    set_mods(e, mods);
    try testing.expect(e.?.event.mods.shift);
    try testing.expect(e.?.event.mods.ctrl);

    // Test consumed mods
    const consumed: key.Mods = .{ .shift = true };
    set_consumed_mods(e, consumed);
    try testing.expect(e.?.event.consumed_mods.shift);
    try testing.expect(!e.?.event.consumed_mods.ctrl);

    // Test composing
    set_composing(e, true);
    try testing.expect(e.?.event.composing);

    // Test UTF-8
    const text = "hello";
    set_utf8(e, text.ptr, text.len);
    try testing.expectEqualStrings(text, e.?.event.utf8);

    // Test UTF-8 null
    set_utf8(e, null, 0);
    try testing.expectEqualStrings("", e.?.event.utf8);

    // Test unshifted codepoint
    set_unshifted_codepoint(e, 'a');
    try testing.expectEqual(@as(u21, 'a'), e.?.event.unshifted_codepoint);
}

test "get" {
    const testing = std.testing;
    var e: Event = undefined;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &e,
    ));
    defer free(e);

    // Set some values
    set_action(e, .repeat);
    set_key(e, .key_z);

    const mods: key.Mods = .{ .alt = true, .super = true };
    set_mods(e, mods);

    const consumed: key.Mods = .{ .alt = true };
    set_consumed_mods(e, consumed);

    set_composing(e, true);

    const text = "test";
    set_utf8(e, text.ptr, text.len);

    set_unshifted_codepoint(e, 'z');

    // Get them back
    try testing.expectEqual(key.Action.repeat, get_action(e));
    try testing.expectEqual(key.Key.key_z, get_key(e));

    const got_mods = get_mods(e);
    try testing.expect(got_mods.alt);
    try testing.expect(got_mods.super);

    const got_consumed = get_consumed_mods(e);
    try testing.expect(got_consumed.alt);
    try testing.expect(!got_consumed.super);

    try testing.expect(get_composing(e));

    var utf8_len: usize = undefined;
    const got_utf8 = get_utf8(e, &utf8_len);
    try testing.expect(got_utf8 != null);
    try testing.expectEqual(@as(usize, 4), utf8_len);
    try testing.expectEqualStrings("test", got_utf8.?[0..utf8_len]);

    try testing.expectEqual(@as(u32, 'z'), get_unshifted_codepoint(e));
}

test "complete key event" {
    const testing = std.testing;
    var e: Event = undefined;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &e,
    ));
    defer free(e);

    // Build a complete key event for shift+a
    set_action(e, .press);
    set_key(e, .key_a);

    const mods: key.Mods = .{ .shift = true };
    set_mods(e, mods);

    const consumed: key.Mods = .{ .shift = true };
    set_consumed_mods(e, consumed);

    const text = "A";
    set_utf8(e, text.ptr, text.len);

    set_unshifted_codepoint(e, 'a');

    // Verify all fields
    try testing.expectEqual(key.Action.press, e.?.event.action);
    try testing.expectEqual(key.Key.key_a, e.?.event.key);
    try testing.expect(e.?.event.mods.shift);
    try testing.expect(e.?.event.consumed_mods.shift);
    try testing.expectEqualStrings("A", e.?.event.utf8);
    try testing.expectEqual(@as(u21, 'a'), e.?.event.unshifted_codepoint);

    // Also test the getter
    var utf8_len: usize = undefined;
    const got_utf8 = get_utf8(e, &utf8_len);
    try testing.expect(got_utf8 != null);
    try testing.expectEqual(@as(usize, 1), utf8_len);
    try testing.expectEqualStrings("A", got_utf8.?[0..utf8_len]);
}
