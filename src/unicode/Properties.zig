//! Property set per codepoint that Ghostty cares about.
//!
//! Adding to this lets you find new properties but also potentially makes
//! our lookup tables less efficient. Any changes to this should run the
//! benchmarks in src/bench to verify that we haven't regressed.
const Properties = @This();

const std = @import("std");

/// Codepoint width. We clamp to [0, 2] since Ghostty handles control
/// characters and we max out at 2 for wide characters (i.e. 3-em dash
/// becomes a 2-em dash).
width: u2 = 0,

/// Grapheme boundary class.
grapheme_boundary_class: GraphemeBoundaryClass = .invalid,

// Needed for lut.Generator
pub fn eql(a: Properties, b: Properties) bool {
    return a.width == b.width and
        a.grapheme_boundary_class == b.grapheme_boundary_class;
}

// Needed for lut.Generator
pub fn format(
    self: Properties,
    writer: *std.Io.Writer,
) !void {
    try writer.print(
        \\.{{
        \\    .width= {},
        \\    .grapheme_boundary_class= .{s},
        \\}}
    , .{
        self.width,
        @tagName(self.grapheme_boundary_class),
    });
}

/// Possible grapheme boundary classes. This isn't an exhaustive list:
/// we omit control, CR, LF, etc. because in Ghostty's usage that are
/// impossible because they're handled by the terminal.
pub const GraphemeBoundaryClass = enum(u4) {
    invalid,
    L,
    V,
    T,
    LV,
    LVT,
    prepend,
    extend,
    zwj,
    spacing_mark,
    regional_indicator,
    extended_pictographic,
    extended_pictographic_base, // \p{Extended_Pictographic} & \p{Emoji_Modifier_Base}
    emoji_modifier, // \p{Emoji_Modifier}

    /// Returns true if this is an extended pictographic type. This
    /// should be used instead of comparing the enum value directly
    /// because we classify multiple.
    pub fn isExtendedPictographic(self: GraphemeBoundaryClass) bool {
        return switch (self) {
            .extended_pictographic,
            .extended_pictographic_base,
            => true,

            else => false,
        };
    }
};
