const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const c = @import("c.zig").c;

pub const Log = opaque {
    pub fn create(
        subsystem: [:0]const u8,
        category: [:0]const u8,
    ) *Log {
        return @ptrCast(c.os_log_create(
            subsystem.ptr,
            category.ptr,
        ).?);
    }

    pub fn release(self: *Log) void {
        c.os_release(self);
    }

    pub fn typeEnabled(self: *Log, typ: LogType) bool {
        return c.os_log_type_enabled(
            @ptrCast(self),
            @intFromEnum(typ),
        );
    }

    pub fn log(
        self: *Log,
        alloc: Allocator,
        typ: LogType,
        comptime format: []const u8,
        args: anytype,
    ) void {
        const str = nosuspend std.fmt.allocPrintZ(
            alloc,
            format,
            args,
        ) catch return;
        defer alloc.free(str);
        zig_os_log_with_type(self, typ, str.ptr);
    }

    extern "c" fn zig_os_log_with_type(*Log, LogType, [*c]const u8) void;
};

/// https://developer.apple.com/documentation/os/os_log_type_t?language=objc
pub const LogType = enum(c.os_log_type_t) {
    default = c.OS_LOG_TYPE_DEFAULT,
    debug = c.OS_LOG_TYPE_DEBUG,
    info = c.OS_LOG_TYPE_INFO,
    err = c.OS_LOG_TYPE_ERROR,
    fault = c.OS_LOG_TYPE_FAULT,
};

test {
    const testing = std.testing;

    const log = Log.create("com.mitchellh.ghostty", "test");
    defer log.release();

    try testing.expect(log.typeEnabled(.fault));
    log.log(testing.allocator, .default, "hello {d}", .{12});
}
