const std = @import("std");
const assert = std.debug.assert;
const c = @import("c");
const Value = @import("value.zig").Value;

/// sentry_envelope_t
pub const Envelope = opaque {
    pub fn deinit(self: *Envelope) void {
        c.sentry_envelope_free(@ptrCast(self));
    }

    pub fn writeToFile(self: *Envelope, path: []const u8) !void {
        if (c.sentry_envelope_write_to_file_n(
            @ptrCast(self),
            path.ptr,
            path.len,
        ) != 0) return error.WriteFailed;
    }

    pub fn serialize(self: *Envelope) []u8 {
        var len: usize = 0;
        const ptr = c.sentry_envelope_serialize(@ptrCast(self), &len).?;
        return ptr[0..len];
    }

    pub fn event(self: *Envelope) ?Value {
        const val: Value = .{ .value = c.sentry_envelope_get_event(@ptrCast(self)) };
        if (val.isNull()) return null;
        return val;
    }
};
