//! Types and functions related to Kitty protocols.

const build_options = @import("terminal_options");

const key = @import("kitty/key.zig");
pub const color = @import("kitty/color.zig");
pub const graphics = if (build_options.kitty_graphics) @import("kitty/graphics.zig") else struct {};

pub const KeyFlags = key.Flags;
pub const KeyFlagStack = key.FlagStack;
pub const KeySetMode = key.SetMode;

test {
    @import("std").testing.refAllDecls(@This());
}
