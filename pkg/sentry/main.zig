pub const c = @import("c");

const transport = @import("transport.zig");

pub const Envelope = @import("envelope.zig").Envelope;
pub const Level = @import("level.zig").Level;
pub const Transport = transport.Transport;
pub const Value = @import("value.zig").Value;
pub const UUID = @import("uuid.zig").UUID;

pub fn captureEvent(value: Value) ?UUID {
    const uuid: UUID = .{ .value = c.sentry_capture_event(value.value) };
    if (uuid.isNil()) return null;
    return uuid;
}

pub fn setContext(key: []const u8, value: Value) void {
    c.sentry_set_context_n(key.ptr, key.len, value.value);
}

pub fn removeContext(key: []const u8) void {
    c.sentry_remove_context_n(key.ptr, key.len);
}

pub fn setTag(key: []const u8, value: []const u8) void {
    c.sentry_set_tag_n(key.ptr, key.len, value.ptr, value.len);
}

pub fn free(ptr: *anyopaque) void {
    c.sentry_free(ptr);
}

test {
    @import("std").testing.refAllDecls(@This());
}
