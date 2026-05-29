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
    // cursor_vintage is the base codepoint for vintage cursor sprites.
    // Heights 1..100 are encoded as cursor_vintage+0 .. cursor_vintage+99.
    // Use sprite.cursorVintageCp() to get the codepoint for a given height.
    cursor_vintage,

    test {
        const testing = std.testing;
        try testing.expectEqual(start, @intFromEnum(Sprite.underline));
    }
};

/// Returns the codepoint for a vintage cursor of the given height percent.
/// Height 1..100 maps to cursor_vintage+0 .. cursor_vintage+99.
pub fn cursorVintageCp(height_pct: u32) u32 {
    const h = @max(1, @min(100, height_pct));
    return @intFromEnum(Sprite.cursor_vintage) + h - 1;
}

test {
    @import("std").testing.refAllDecls(@This());
}
