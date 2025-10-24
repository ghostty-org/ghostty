const std = @import("std");
const enumpkg = @import("enum.zig");

pub const allocator = @import("allocator.zig");
pub const Enum = enumpkg.Enum;
pub const EnumTarget = enumpkg.Target;

test {
    std.testing.refAllDecls(@This());
}
