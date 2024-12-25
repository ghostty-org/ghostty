//! Types and functions related to Kitty protocols.

const key = @import("kitty/key.zig");
pub const color = @import("kitty/color.zig");
pub const desktop = @import("kitty/desktop.zig");
pub const graphics = @import("kitty/graphics.zig");

pub const KeyFlags = key.Flags;
pub const KeyFlagStack = key.FlagStack;
pub const KeySetMode = key.SetMode;

test {
    @import("std").testing.refAllDecls(@This());
}
