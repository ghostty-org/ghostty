//! Property set per codepoint that Ghostty cares about.
//!
//! Adding to this lets you find new properties but also potentially makes
//! our lookup tables less efficient. Any changes to this should run the
//! benchmarks in src/bench to verify that we haven't regressed.

const std = @import("std");
const uucode = @import("uucode");

pub const Properties = packed struct {
    /// Codepoint width. We clamp to [0, 2] since Ghostty handles control
    /// characters and we max out at 2 for wide characters (i.e. 3-em dash
    /// becomes a 2-em dash).
    width: u2 = 0,

    /// Whether the code point does not contribute to the width of a grapheme
    /// cluster (not used for single code point cells).
    width_zero_in_grapheme: bool = false,

    /// Grapheme break property.
    grapheme_break: uucode.x.types.GraphemeBreakNoControl = .other,

    /// Emoji VS compatibility
    emoji_vs_base: bool = false,

    // Needed for lut.Generator
    pub fn eql(a: Properties, b: Properties) bool {
        return a.width == b.width and
            a.width_zero_in_grapheme == b.width_zero_in_grapheme and
            a.grapheme_break == b.grapheme_break and
            a.emoji_vs_base == b.emoji_vs_base;
    }

    // Needed for lut.Generator
    pub fn format(
        self: Properties,
        writer: *std.Io.Writer,
    ) !void {
        try writer.print(
            \\.{{
            \\    .width= {},
            \\    .width_zero_in_grapheme= {},
            \\    .grapheme_break= .{s},
            \\    .emoji_vs_base= {},
            \\}}
        , .{
            self.width,
            self.width_zero_in_grapheme,
            @tagName(self.grapheme_break),
            self.emoji_vs_base,
        });
    }
};
