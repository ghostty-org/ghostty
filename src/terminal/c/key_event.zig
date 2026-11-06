const std = @import("std");
const Allocator = std.mem.Allocator;
const lib = @import("../lib.zig");
const CAllocator = lib.alloc.Allocator;
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
    result_: ?*Event,
) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.input_encode)) {
        if (result_) |o| o.* = null;
        return .unsupported;
    }
    const result = result_ orelse return .invalid_value;
    const alloc = lib.alloc.default(alloc_);
    const ptr = alloc.create(KeyEventWrapper) catch
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
    action: lib.CEnum(key.Action),
) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.input_encode)) return .unsupported;
    const event: *key.KeyEvent = &(event_ orelse return .invalid_value).event;
    event.action = lib.enumFromC(key.Action, action) orelse
        return .invalid_value;
    return .success;
}

pub fn get_action(event_: Event) callconv(lib.calling_conv) key.Action {
    if (comptime !lib.feature(.input_encode)) return .release;
    const wrapper = event_ orelse return .release;
    return wrapper.event.action;
}

pub fn set_key(
    event_: Event,
    k: lib.CEnum(key.Key),
) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.input_encode)) return .unsupported;
    const event: *key.KeyEvent = &(event_ orelse return .invalid_value).event;
    event.key = lib.enumFromC(key.Key, k) orelse return .invalid_value;
    return .success;
}

pub fn get_key(event_: Event) callconv(lib.calling_conv) key.Key {
    if (comptime !lib.feature(.input_encode)) return .unidentified;
    const wrapper = event_ orelse return .unidentified;
    return wrapper.event.key;
}

pub fn set_mods(event_: Event, mods: key.Mods) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.input_encode)) return .unsupported;
    const event: *key.KeyEvent = &(event_ orelse return .invalid_value).event;
    event.mods = mods;
    return .success;
}

pub fn get_mods(event_: Event) callconv(lib.calling_conv) key.Mods {
    if (comptime !lib.feature(.input_encode)) return .{};
    const wrapper = event_ orelse return .{};
    return wrapper.event.mods;
}

pub fn set_consumed_mods(
    event_: Event,
    consumed_mods: key.Mods,
) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.input_encode)) return .unsupported;
    const event: *key.KeyEvent = &(event_ orelse return .invalid_value).event;
    event.consumed_mods = consumed_mods;
    return .success;
}

pub fn get_consumed_mods(event_: Event) callconv(lib.calling_conv) key.Mods {
    if (comptime !lib.feature(.input_encode)) return .{};
    const wrapper = event_ orelse return .{};
    return wrapper.event.consumed_mods;
}

pub fn set_composing(event_: Event, composing: bool) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.input_encode)) return .unsupported;
    const event: *key.KeyEvent = &(event_ orelse return .invalid_value).event;
    event.composing = composing;
    return .success;
}

pub fn get_composing(event_: Event) callconv(lib.calling_conv) bool {
    if (comptime !lib.feature(.input_encode)) return false;
    const wrapper = event_ orelse return false;
    return wrapper.event.composing;
}

pub fn set_utf8(event_: Event, utf8: lib.String) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.input_encode)) return .unsupported;
    const event: *key.KeyEvent = &(event_ orelse return .invalid_value).event;

    // A zero-length string clears the text. Don't read the pointer here
    // because C callers may pass NULL when the length is zero.
    event.utf8 = if (utf8.len == 0) "" else utf8.ptr[0..utf8.len];
    return .success;
}

pub fn get_utf8(event_: Event) callconv(lib.calling_conv) lib.String {
    if (comptime !lib.feature(.input_encode)) return .{ .ptr = "", .len = 0 };
    const wrapper = event_ orelse return .init(@as([]const u8, ""));
    return .init(wrapper.event.utf8);
}

pub fn set_unshifted_codepoint(
    event_: Event,
    codepoint: u32,
) callconv(lib.calling_conv) Result {
    if (comptime !lib.feature(.input_encode)) return .unsupported;
    const event: *key.KeyEvent = &(event_ orelse return .invalid_value).event;
    event.unshifted_codepoint = @truncate(codepoint);
    return .success;
}

pub fn get_unshifted_codepoint(event_: Event) callconv(lib.calling_conv) u32 {
    if (comptime !lib.feature(.input_encode)) return 0;
    const wrapper = event_ orelse return 0;
    return wrapper.event.unshifted_codepoint;
}

test "alloc" {
    const testing = std.testing;
    var e: Event = undefined;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &e,
    ));
    free(e);
}

test "set" {
    const testing = std.testing;
    var e: Event = undefined;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &e,
    ));
    defer free(e);

    // Test action
    try testing.expectEqual(Result.success, set_action(e, .press));
    try testing.expectEqual(key.Action.press, e.?.event.action);

    // Test key
    try testing.expectEqual(Result.success, set_key(e, .key_a));
    try testing.expectEqual(key.Key.key_a, e.?.event.key);

    // Test mods
    const mods: key.Mods = .{ .shift = true, .ctrl = true };
    try testing.expectEqual(Result.success, set_mods(e, mods));
    try testing.expect(e.?.event.mods.shift);
    try testing.expect(e.?.event.mods.ctrl);

    // Test consumed mods
    const consumed: key.Mods = .{ .shift = true };
    try testing.expectEqual(Result.success, set_consumed_mods(e, consumed));
    try testing.expect(e.?.event.consumed_mods.shift);
    try testing.expect(!e.?.event.consumed_mods.ctrl);

    // Test composing
    try testing.expectEqual(Result.success, set_composing(e, true));
    try testing.expect(e.?.event.composing);

    // Test UTF-8
    const text = "hello";
    try testing.expectEqual(Result.success, set_utf8(e, .init(@as([]const u8, text))));
    try testing.expectEqualStrings(text, e.?.event.utf8);

    // A zero-length string clears the text.
    try testing.expectEqual(Result.success, set_utf8(e, .init(@as([]const u8, text))));
    try testing.expectEqual(Result.success, set_utf8(e, .{ .ptr = text.ptr, .len = 0 }));
    try testing.expectEqualStrings("", e.?.event.utf8);

    // No text is an empty string with a non-NULL pointer.
    const empty = get_utf8(e);
    try testing.expectEqual(@as(usize, 0), empty.len);
    try testing.expect(@intFromPtr(empty.ptr) != 0);

    // Test unshifted codepoint
    try testing.expectEqual(Result.success, set_unshifted_codepoint(e, 'a'));
    try testing.expectEqual(@as(u21, 'a'), e.?.event.unshifted_codepoint);
}

test "get" {
    const testing = std.testing;
    var e: Event = undefined;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &e,
    ));
    defer free(e);

    // Set some values
    try testing.expectEqual(Result.success, set_action(e, .repeat));
    try testing.expectEqual(Result.success, set_key(e, .key_z));

    const mods: key.Mods = .{ .alt = true, .super = true };
    try testing.expectEqual(Result.success, set_mods(e, mods));

    const consumed: key.Mods = .{ .alt = true };
    try testing.expectEqual(Result.success, set_consumed_mods(e, consumed));

    try testing.expectEqual(Result.success, set_composing(e, true));

    const text = "test";
    try testing.expectEqual(Result.success, set_utf8(e, .init(@as([]const u8, text))));

    try testing.expectEqual(Result.success, set_unshifted_codepoint(e, 'z'));

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

    const got_utf8 = get_utf8(e);
    try testing.expectEqualStrings("test", got_utf8.ptr[0..got_utf8.len]);

    try testing.expectEqual(@as(u32, 'z'), get_unshifted_codepoint(e));
}

test "complete key event" {
    const testing = std.testing;
    var e: Event = undefined;
    try testing.expectEqual(Result.success, new(
        &lib.alloc.test_allocator,
        &e,
    ));
    defer free(e);

    // Build a complete key event for shift+a
    try testing.expectEqual(Result.success, set_action(e, .press));
    try testing.expectEqual(Result.success, set_key(e, .key_a));

    const mods: key.Mods = .{ .shift = true };
    try testing.expectEqual(Result.success, set_mods(e, mods));

    const consumed: key.Mods = .{ .shift = true };
    try testing.expectEqual(Result.success, set_consumed_mods(e, consumed));

    const text = "A";
    try testing.expectEqual(Result.success, set_utf8(e, .init(@as([]const u8, text))));

    try testing.expectEqual(Result.success, set_unshifted_codepoint(e, 'a'));

    // Verify all fields
    try testing.expectEqual(key.Action.press, e.?.event.action);
    try testing.expectEqual(key.Key.key_a, e.?.event.key);
    try testing.expect(e.?.event.mods.shift);
    try testing.expect(e.?.event.consumed_mods.shift);
    try testing.expectEqualStrings("A", e.?.event.utf8);
    try testing.expectEqual(@as(u21, 'a'), e.?.event.unshifted_codepoint);

    // Also test the getter
    const got_utf8 = get_utf8(e);
    try testing.expectEqualStrings("A", got_utf8.ptr[0..got_utf8.len]);
}

test "null event" {
    const testing = std.testing;

    // Setters report a NULL event.
    try testing.expectEqual(Result.invalid_value, set_action(null, .press));
    try testing.expectEqual(Result.invalid_value, set_key(null, .key_a));
    try testing.expectEqual(Result.invalid_value, set_mods(null, .{ .shift = true }));
    try testing.expectEqual(Result.invalid_value, set_consumed_mods(null, .{ .shift = true }));
    try testing.expectEqual(Result.invalid_value, set_composing(null, true));
    try testing.expectEqual(Result.invalid_value, set_utf8(null, .init(@as([]const u8, "a"))));
    try testing.expectEqual(Result.invalid_value, set_unshifted_codepoint(null, 'a'));

    // Getters return the zero value of their type.
    try testing.expectEqual(key.Action.release, get_action(null));
    try testing.expectEqual(key.Key.unidentified, get_key(null));
    try testing.expectEqual(key.Mods{}, get_mods(null));
    try testing.expectEqual(key.Mods{}, get_consumed_mods(null));
    try testing.expect(!get_composing(null));
    const utf8 = get_utf8(null);
    try testing.expectEqual(@as(usize, 0), utf8.len);
    try testing.expect(@intFromPtr(utf8.ptr) != 0);
    try testing.expectEqual(@as(u32, 0), get_unshifted_codepoint(null));
}
