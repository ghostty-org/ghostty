const std = @import("std");
const assert = std.debug.assert;
const color = @import("color.zig");
const sgr = @import("sgr.zig");
const page = @import("page.zig");
const size = @import("size.zig");
const Offset = size.Offset;
const OffsetBuf = size.OffsetBuf;
const hash_map = @import("hash_map.zig");
const AutoOffsetHashMap = hash_map.AutoOffsetHashMap;

/// The unique identifier for a style. This is at most the number of cells
/// that can fit into a terminal page.
pub const Id = size.CellCountInt;

/// The Id to use for default styling.
pub const default_id: Id = 0;

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

    /// True if the style is the default style.
    pub fn default(self: Style) bool {
        const def: []const u8 = comptime std.mem.asBytes(&Style{});
        return std.mem.eql(u8, std.mem.asBytes(&self), def);
    }

    /// Returns the bg color for a cell with this style given the cell
    /// that has this style and the palette to use.
    ///
    /// Note that generally if a cell is a color-only cell, it SHOULD
    /// only have the default style, but this is meant to work with the
    /// default style as well.
    pub fn bg(
        self: Style,
        cell: *const page.Cell,
        palette: *const color.Palette,
    ) ?color.RGB {
        return switch (cell.content_tag) {
            .bg_color_palette => palette[cell.content.color_palette],
            .bg_color_rgb => rgb: {
                const rgb = cell.content.color_rgb;
                break :rgb .{ .r = rgb.r, .g = rgb.g, .b = rgb.b };
            },

            else => switch (self.bg_color) {
                .none => null,
                .palette => |idx| palette[idx],
                .rgb => |rgb| rgb,
            },
        };
    }

    /// Returns the fg color for a cell with this style given the palette.
    pub fn fg(
        self: Style,
        palette: *const color.Palette,
    ) ?color.RGB {
        return switch (self.fg_color) {
            .none => null,
            .palette => |idx| palette[idx],
            .rgb => |rgb| rgb,
        };
    }

    /// Returns the underline color for this style.
    pub fn underlineColor(
        self: Style,
        palette: *const color.Palette,
    ) ?color.RGB {
        return switch (self.underline_color) {
            .none => null,
            .palette => |idx| palette[idx],
            .rgb => |rgb| rgb,
        };
    }

    /// Returns a bg-color only cell from this style, if it exists.
    pub fn bgCell(self: Style) ?page.Cell {
        return switch (self.bg_color) {
            .none => null,
            .palette => |idx| .{
                .content_tag = .bg_color_palette,
                .content = .{ .color_palette = idx },
            },
            .rgb => |rgb| .{
                .content_tag = .bg_color_rgb,
                .content = .{ .color_rgb = .{
                    .r = rgb.r,
                    .g = rgb.g,
                    .b = rgb.b,
                } },
            },
        };
    }

    test {
        // The size of the struct so we can be aware of changes.
        const testing = std.testing;
        try testing.expectEqual(@as(usize, 14), @sizeOf(Style));
    }
};

/// A set of styles.
///
/// This set is created with some capacity in mind. You can determine
/// the exact memory requirement for a capacity by calling `layout`
/// and checking the total size.
///
/// When the set exceeds capacity, `error.OutOfMemory` is returned
/// from memory-using methods. The caller is responsible for determining
/// a path forward.
///
/// The general idea behind this structure is that it is optimized for
/// the scenario common in terminals where there aren't many unique
/// styles, and many cells are usually drawn with a single style before
/// changing styles.
///
/// Callers should call `upsert` when a new style is set. This will
/// return a stable pointer to metadata. You should use this metadata
/// to keep a ref count of the style usage. When it falls to zero you
/// can remove it.
pub const Set = struct {
    pub const base_align = @max(MetadataMap.base_align, IdMap.base_align);

    /// The mapping of a style to associated metadata. This is
    /// the map that contains the actual style definitions
    /// (in the form of the key).
    styles: MetadataMap,

    /// The mapping from ID to style.
    id_map: IdMap,

    /// The next ID to use for a style that isn't in the set.
    /// When this overflows we'll begin returning an IdOverflow
    /// error and the caller must manually compact the style
    /// set.
    ///
    /// Id zero is reserved and always is the default style. The
    /// default style isn't present in the map, its dependent on
    /// the terminal configuration.
    next_id: Id = 1,

    /// Maps a style definition to metadata about that style.
    const MetadataMap = AutoOffsetHashMap(Style, Metadata);

    /// Maps the unique style ID to the concrete style definition.
    const IdMap = AutoOffsetHashMap(Id, Offset(Style));

    /// Returns the memory layout for the given base offset and
    /// desired capacity. The layout can be used by the caller to
    /// determine how much memory to allocate, and the layout must
    /// be used to initialize the set so that the set knows all
    /// the offsets for the various buffers.
    pub fn layout(cap: usize) Layout {
        const md_layout = MetadataMap.layout(@intCast(cap));
        const md_start = 0;
        const md_end = md_start + md_layout.total_size;

        const id_layout = IdMap.layout(@intCast(cap));
        const id_start = std.mem.alignForward(usize, md_end, IdMap.base_align);
        const id_end = id_start + id_layout.total_size;

        const total_size = id_end;

        return .{
            .md_start = md_start,
            .md_layout = md_layout,
            .id_start = id_start,
            .id_layout = id_layout,
            .total_size = total_size,
        };
    }

    pub const Layout = struct {
        md_start: usize,
        md_layout: MetadataMap.Layout,
        id_start: usize,
        id_layout: IdMap.Layout,
        total_size: usize,
    };

    pub fn init(base: OffsetBuf, l: Layout) Set {
        const styles_buf = base.add(l.md_start);
        const id_buf = base.add(l.id_start);
        return .{
            .styles = MetadataMap.init(styles_buf, l.md_layout),
            .id_map = IdMap.init(id_buf, l.id_layout),
        };
    }

    /// Possible errors for upsert.
    pub const UpsertError = error{
        /// No more space in the backing buffer. Remove styles or
        /// grow and reinitialize.
        OutOfMemory,

        /// No more available IDs. Perform a garbage collection
        /// operation to compact ID space.
        /// TODO: implement gc operation
        Overflow,
    };

    /// Upsert a style into the set and return a pointer to the metadata
    /// for that style. The pointer is valid for the lifetime of the set
    /// so long as the style is not removed.
    ///
    /// The ref count for new styles is initialized to zero and
    /// for existing styles remains unmodified.
    pub fn upsert(self: *Set, base: anytype, style: Style) UpsertError!*Metadata {
        // If we already have the style in the map, this is fast.
        var map = self.styles.map(base);
        const gop = try map.getOrPut(style);
        if (gop.found_existing) return gop.value_ptr;

        // New style, we need to setup all the metadata. First thing,
        // let's get the ID we'll assign, because if we're out of space
        // we need to fail early.
        errdefer map.removeByPtr(gop.key_ptr);
        const id = self.next_id;
        self.next_id = try std.math.add(Id, self.next_id, 1);
        errdefer self.next_id -= 1;
        gop.value_ptr.* = .{ .id = id };

        // Setup our ID mapping
        var id_map = self.id_map.map(base);
        const id_gop = try id_map.getOrPut(id);
        errdefer id_map.removeByPtr(id_gop.key_ptr);
        assert(!id_gop.found_existing);
        id_gop.value_ptr.* = size.getOffset(Style, base, gop.key_ptr);
        return gop.value_ptr;
    }

    /// Lookup a style by its unique identifier.
    pub fn lookupId(self: *const Set, base: anytype, id: Id) ?*Style {
        const id_map = self.id_map.map(base);
        const offset = id_map.get(id) orelse return null;
        return @ptrCast(offset.ptr(base));
    }

    /// Remove a style by its id.
    pub fn remove(self: *Set, base: anytype, id: Id) void {
        // Lookup by ID, if it doesn't exist then we return. We use
        // getEntry so that we can make removal faster later by using
        // the entry's key pointer.
        var id_map = self.id_map.map(base);
        const id_entry = id_map.getEntry(id) orelse return;

        var style_map = self.styles.map(base);
        const style_ptr: *Style = @ptrCast(id_entry.value_ptr.ptr(base));

        id_map.removeByPtr(id_entry.key_ptr);
        style_map.removeByPtr(style_ptr);
    }

    /// Return the number of styles currently in the set.
    pub fn count(self: *const Set, base: anytype) usize {
        return self.id_map.map(base).count();
    }
};

/// Metadata about a style. This is used to track the reference count
/// and the unique identifier for a style. The unique identifier is used
/// to track the style in the full style map.
pub const Metadata = struct {
    ref: size.CellCountInt = 0,
    id: Id = 0,
};

test "Set basic usage" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const layout = Set.layout(16);
    const buf = try alloc.alignedAlloc(u8, Set.base_align, layout.total_size);
    defer alloc.free(buf);

    const style: Style = .{ .flags = .{ .bold = true } };

    var set = Set.init(OffsetBuf.init(buf), layout);

    // Upsert
    const meta = try set.upsert(buf, style);
    try testing.expect(meta.id > 0);

    // Second upsert should return the same metadata.
    {
        const meta2 = try set.upsert(buf, style);
        try testing.expectEqual(meta.id, meta2.id);
    }

    // Look it up
    {
        const v = set.lookupId(buf, meta.id).?;
        try testing.expect(v.flags.bold);

        const v2 = set.lookupId(buf, meta.id).?;
        try testing.expectEqual(v, v2);
    }

    // Removal
    set.remove(buf, meta.id);
    try testing.expect(set.lookupId(buf, meta.id) == null);
}
