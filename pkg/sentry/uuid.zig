const std = @import("std");
const assert = std.debug.assert;
const c = @import("c");

/// sentry_uuid_t
pub const UUID = struct {
    value: c.sentry_uuid_t,

    pub fn init() UUID {
        return .{ .value = c.sentry_uuid_new_v4() };
    }

    pub fn isNil(self: UUID) bool {
        return c.sentry_uuid_is_nil(&self.value) != 0;
    }

    pub fn string(self: UUID) [36:0]u8 {
        var buf: [36:0]u8 = undefined;
        c.sentry_uuid_as_string(&self.value, &buf);
        return buf;
    }
};
