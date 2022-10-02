const std = @import("std");
const build_options = @import("build_options");

pub const discovery = @import("discovery.zig");
pub const DeferredFace = @import("DeferredFace.zig");
pub const Face = @import("Face.zig");
pub const Group = @import("Group.zig");
pub const GroupCache = @import("GroupCache.zig");
pub const Glyph = @import("Glyph.zig");
pub const Library = @import("Library.zig");
pub const Shaper = @import("Shaper.zig");
pub const Descriptor = discovery.Descriptor;
pub const Discover = discovery.Discover;

/// Build options
pub const options: struct {
    coretext: bool = false,
    fontconfig: bool = false,
} = .{
    .coretext = build_options.coretext,
    .fontconfig = build_options.fontconfig,
};

/// The styles that a family can take.
pub const Style = enum(u3) {
    regular = 0,
    bold = 1,
    italic = 2,
    bold_italic = 3,
};

/// The presentation for a an emoji.
pub const Presentation = enum(u1) {
    text = 0, // U+FE0E
    emoji = 1, // U+FEOF
};

/// Font metrics useful for things such as grid calculation.
pub const Metrics = struct {
    /// The width and height of a monospace cell.
    cell_width: f32,
    cell_height: f32,

    /// The baseline offset that can be used to place underlines.
    cell_baseline: f32,
};

test {
    @import("std").testing.refAllDecls(@This());
}
