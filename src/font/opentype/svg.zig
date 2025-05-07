const std = @import("std");
const assert = std.debug.assert;
const font = @import("../main.zig");

/// SVG glyphs description table.
///
/// This struct is focused purely on the operations we need for Ghostty,
/// namely to be able to look up whether an glyph ID is present in the SVG
/// table or not. This struct isn't meant to be a general purpose SVG table
/// reader.
///
/// References:
/// - https://www.w3.org/2013/10/SVG_in_OpenType/#thesvg
/// - https://learn.microsoft.com/en-us/typography/opentype/spec/svg
pub const SVG = struct {
    /// The start and end glyph IDs (inclusive) that are present in the
    /// table. This is used to very quickly include/exclude a glyph from
    /// the table.
    start_glyph_id: u16,
    end_glyph_id: u16,

    /// All records in the table.
    records: []const [12]u8,

    pub fn init(data: []const u8) error{
        EndOfStream,
        SVGVersionNotSupported,
    }!SVG {
        var fbs = std.io.fixedBufferStream(data);
        const reader = fbs.reader();

        // Version
        if (try reader.readInt(u16, .big) != 0) {
            return error.SVGVersionNotSupported;
        }

        // Offset
        const offset = try reader.readInt(u32, .big);

        // Seek to the offset to get our document list
        try fbs.seekTo(offset);

        // Get our document records along with the start/end glyph range.
        const len = try reader.readInt(u16, .big);
        const records: [*]const [12]u8 = @ptrCast(data[try fbs.getPos()..]);
        const start_range = try glyphRange(&records[0]);
        const end_range = if (len == 1) start_range else try glyphRange(&records[(len - 1)]);

        return .{
            .start_glyph_id = start_range[0],
            .end_glyph_id = end_range[1],
            .records = records[0..len],
        };
    }

    pub fn hasGlyph(self: SVG, glyph_id: u16) bool {
        // Fast path: outside the table range
        if (glyph_id < self.start_glyph_id or glyph_id > self.end_glyph_id) {
            return false;
        }

        // Fast path, matches the start/end glyph IDs
        if (glyph_id == self.start_glyph_id or glyph_id == self.end_glyph_id) {
            return true;
        }

        // Slow path: binary search our records
        return std.sort.binarySearch(
            [12]u8,
            self.records,
            glyph_id,
            compareGlyphId,
        ) != null;
    }

    fn compareGlyphId(glyph_id: u16, record: [12]u8) std.math.Order {
        const start, const end = glyphRange(&record) catch return .lt;
        if (glyph_id < start) {
            return .lt;
        } else if (glyph_id > end) {
            return .gt;
        } else {
            return .eq;
        }
    }

    fn glyphRange(record: []const u8) !struct { u16, u16 } {
        var fbs = std.io.fixedBufferStream(record);
        const reader = fbs.reader();
        return .{
            try reader.readInt(u16, .big),
            try reader.readInt(u16, .big),
        };
    }
};

test "SVG" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.julia_mono;

    var lib = try font.Library.init(alloc);
    defer lib.deinit();

    var face = try font.Face.init(lib, testFont, .{ .size = .{ .points = 12 } });
    defer face.deinit();

    const table = (try face.copyTable(alloc, "SVG ")).?;
    defer alloc.free(table);

    const svg = try SVG.init(table);
    try testing.expectEqual(11482, svg.start_glyph_id);
    try testing.expectEqual(11482, svg.end_glyph_id);
    try testing.expect(svg.hasGlyph(11482));
}
