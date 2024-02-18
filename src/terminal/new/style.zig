const std = @import("std");
const assert = std.debug.assert;
const color = @import("../color.zig");
const sgr = @import("../sgr.zig");
const size = @import("size.zig");
const Offset = size.Offset;
const hash_map = @import("hash_map.zig");
const AutoOffsetHashMap = hash_map.AutoOffsetHashMap;

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

/// A set of styles.
pub const Set = struct {
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
    pub fn layoutForCapacity(base: usize, cap: usize) Layout {
        const md_start = std.mem.alignForward(usize, base, MetadataMap.base_align);
        const md_end = md_start + MetadataMap.bufferSize(@intCast(cap));

        const id_start = std.mem.alignForward(usize, md_end, IdMap.base_align);
        const id_end = id_start + IdMap.bufferSize(@intCast(cap));

        const total_size = id_end - base;

        return .{
            .cap = cap,
            .md_start = md_start,
            .id_start = id_start,
            .total_size = total_size,
        };
    }

    pub const Layout = struct {
        cap: usize,
        md_start: usize,
        id_start: usize,
        total_size: usize,
    };

    pub fn init(base: []u8, layout: Layout) Set {
        assert(base.len >= layout.total_size);

        var styles = MetadataMap.init(@intCast(layout.cap), base[layout.md_start..]);
        styles.metadata.offset += @intCast(layout.md_start);

        var id_map = IdMap.init(@intCast(layout.cap), base[layout.id_start..]);
        id_map.metadata.offset += @intCast(layout.id_start);

        return .{
            .styles = styles,
            .id_map = id_map,
        };
    }

    /// Upsert a style into the set and return a pointer to the metadata
    /// for that style. The pointer is valid for the lifetime of the set
    /// so long as the style is not removed.
    pub fn upsert(self: *Set, base: anytype, style: Style) !*Metadata {
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
};

/// Metadata about a style. This is used to track the reference count
/// and the unique identifier for a style. The unique identifier is used
/// to track the style in the full style map.
pub const Metadata = struct {
    ref: size.CellCountInt = 1,
    id: Id = 0,
};

test {
    _ = Style;
    _ = Set;
}

// test "Set basic usage" {
//     const testing = std.testing;
//     const alloc = testing.allocator;
//     const layout = Set.layoutForCapacity(0, 16);
//     const buf = try alloc.alloc(u8, layout.total_size);
//     defer alloc.free(buf);
//
//     const style: Style = .{ .flags = .{ .bold = true } };
//
//     var set = Set.init(buf, layout);
//
//     // Upsert
//     const meta = try set.upsert(buf, style);
//     try testing.expect(meta.id > 0);
//
//     // Second upsert should return the same metadata.
//     {
//         const meta2 = try set.upsert(buf, style);
//         try testing.expectEqual(meta.id, meta2.id);
//     }
//
//     // Look it up
//     {
//         const v = set.lookupId(buf, meta.id).?;
//         try testing.expect(v.flags.bold);
//     }
// }
