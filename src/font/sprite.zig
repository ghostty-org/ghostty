const std = @import("std");
const canvas = @import("sprite/canvas.zig");
pub const Face = @import("sprite/Face.zig");

pub const Box = canvas.Box;
pub const Point = canvas.Point;
pub const Canvas = canvas.Canvas;
pub const Color = canvas.Color;

/// Sprites are represented as special codepoints outside of the Unicode
/// codepoint range. Unicode maxes out at U+10FFFF (21 bits), and we use the
/// high 11 bits to hide our special characters.
///
/// These characters are ONLY used for rendering and NEVER used written to
/// text files or any other exported format, so we don't use the Private Use
/// Area of Unicode.
pub const Sprite = enum(u32) {
    // Start 1 above the maximum Unicode codepoint.
    pub const start: u32 = std.math.maxInt(u21) + 1;
    pub const end: u32 = std.math.maxInt(u32);

    underline = start,
    underline_double,
    underline_dotted,
    underline_dashed,
    underline_curly,

    strikethrough,

    overline,

    cursor_rect,
    cursor_hollow_rect,
    cursor_bar,
    cursor_underline,

    test {
        const testing = std.testing;
        try testing.expectEqual(start, @intFromEnum(Sprite.underline));
    }
};

test {
    @import("std").testing.refAllDecls(@This());
}
