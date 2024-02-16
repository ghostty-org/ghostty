const std = @import("std");
const color = @import("../color.zig");
const sgr = @import("../sgr.zig");
const size = @import("size.zig");

/// The unique identifier for a style. This is at most the number of cells
/// that can fit into a terminal page.
pub const Id = size.CellCountInt;

/// The style attributes for a cell.
pub const Style = struct {
    /// Various colors, all self-explanatory.
    fg_color: Color = .none,
    bg_color: Color = .none,
    underline_color: Color = .none,

    /// On/off attributes that don't require much bit width so we use
    /// a packed struct to make this take up significantly less space.
    flags: packed struct {
        bold: bool = false,
        italic: bool = false,
        faint: bool = false,
        blink: bool = false,
        inverse: bool = false,
        invisible: bool = false,
        strikethrough: bool = false,
        underline: sgr.Attribute.Underline = .none,
    } = .{},

    /// The color for an SGR attribute. A color can come from multiple
    /// sources so we use this to track the source plus color value so that
    /// we can properly react to things like palette changes.
    pub const Color = union(enum) {
        none: void,
        palette: u8,
        rgb: color.RGB,
    };

    test {
        // The size of the struct so we can be aware of changes.
        const testing = std.testing;
        try testing.expectEqual(@as(usize, 14), @sizeOf(Style));
    }
};

/// Maps a style definition to metadata about that style.
pub const MetadataMap = std.AutoHashMapUnmanaged(Style, Metadata);

/// Maps the unique style ID to the concrete style definition.
pub const IdMap = std.AutoHashMapUnmanaged(size.CellCountInt, Style);

/// Metadata about a style. This is used to track the reference count
/// and the unique identifier for a style. The unique identifier is used
/// to track the style in the full style map.
pub const Metadata = struct {
    ref: size.CellCountInt = 0,
    id: size.CellCountInt = 0,
};

test {
    _ = Style;
}
