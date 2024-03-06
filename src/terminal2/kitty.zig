//! Types and functions related to Kitty protocols.

pub const graphics = @import("kitty/graphics.zig");
pub usingnamespace @import("kitty/key.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
