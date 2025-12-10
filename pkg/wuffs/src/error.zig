const std = @import("std");

const c = @import("c.zig").c;

pub const Error = std.mem.Allocator.Error || error{ WuffsError, Overflow };

pub fn check(log: anytype, status: *const c.struct_wuffs_base__status__struct) error{WuffsError}!void {
    if (!c.wuffs_base__status__is_ok(status)) {
        const e = c.wuffs_base__status__message(status);
        log.warn("decode err={s}", .{e});
        return error.WuffsError;
    }
}
