//! Types and functions related to Kitty protocols.

// TODO: migrate to terminal2
pub const graphics = @import("../terminal/kitty/graphics.zig");
pub usingnamespace @import("../terminal/kitty/key.zig");

test {
    @import("std").testing.refAllDecls(@This());

    _ = @import("kitty/graphics.zig");
    _ = @import("kitty/key.zig");
}
