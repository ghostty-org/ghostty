const std = @import("std");
const assert = std.debug.assert;
const c = @import("c");
const Level = @import("level.zig").Level;

/// sentry_value_t
pub const Value = struct {
    /// The underlying value. This is a union that could be represented with
    /// an extern union but I don't want to risk C ABI issues so we wrap it
    /// in a struct.
    value: c.sentry_value_t,

    pub fn initMessageEvent(
        level: Level,
        logger: ?[]const u8,
        message: []const u8,
    ) Value {
        return .{ .value = c.sentry_value_new_message_event_n(
            @intFromEnum(level),
            if (logger) |v| v.ptr else null,
            if (logger) |v| v.len else 0,
            message.ptr,
            message.len,
        ) };
    }

    pub fn initObject() Value {
        return .{ .value = c.sentry_value_new_object() };
    }

    pub fn initString(value: []const u8) Value {
        return .{ .value = c.sentry_value_new_string_n(value.ptr, value.len) };
    }

    pub fn initBool(value: bool) Value {
        return .{ .value = c.sentry_value_new_bool(@intFromBool(value)) };
    }

    pub fn initInt32(value: i32) Value {
        return .{ .value = c.sentry_value_new_int32(value) };
    }

    pub fn decref(self: Value) void {
        c.sentry_value_decref(self.value);
    }

    pub fn incref(self: Value) Value {
        c.sentry_value_incref(self.value);
    }

    pub fn isNull(self: Value) bool {
        return c.sentry_value_is_null(self.value) != 0;
    }

    /// sentry_value_set_by_key_n
    pub fn set(self: Value, key: []const u8, value: Value) void {
        _ = c.sentry_value_set_by_key_n(
            self.value,
            key.ptr,
            key.len,
            value.value,
        );
    }

    /// sentry_value_set_by_key_n
    pub fn get(self: Value, key: []const u8) ?Value {
        const val: Value = .{ .value = c.sentry_value_get_by_key_n(
            self.value,
            key.ptr,
            key.len,
        ) };
        if (val.isNull()) return null;
        return val;
    }
};
