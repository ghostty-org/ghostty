//! Various conversions from Freetype formats to Atlas formats. These are
//! currently implemented naively. There are definitely MUCH faster ways
//! to do this (likely using SIMD), but I started simple.
const std = @import("std");
const freetype = @import("freetype");
const font = @import("../main.zig");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

/// The mapping from freetype format to atlas format.
pub const map = genMap();

/// The map type.
pub const Map = [freetype.c.FT_PIXEL_MODE_MAX]AtlasArray;

/// Conversion function type. The returning bitmap buffer is guaranteed
/// to be exactly `width * rows * depth` long for freeing it. The caller must
/// free the bitmap buffer. The depth is the depth of the atlas format in the
/// map.
pub const Func = *const fn (Allocator, Bitmap) Allocator.Error!Bitmap;

/// Alias for the freetype FT_Bitmap type to make it easier to type.
pub const Bitmap = freetype.c.struct_FT_Bitmap_;

const AtlasArray = std.EnumArray(font.Atlas.Format, ?Func);

fn genMap() Map {
    var result: Map = undefined;

    // Initialize to no converter
    var i: usize = 0;
    while (i < freetype.c.FT_PIXEL_MODE_MAX) : (i += 1) {
        result[i] = AtlasArray.initFill(null);
    }

    // Map our converters
    result[freetype.c.FT_PIXEL_MODE_MONO].set(.greyscale, monoToGreyscale);

    return result;
}

pub fn monoToGreyscale(alloc: Allocator, bm: Bitmap) Allocator.Error!Bitmap {
    var buf = try alloc.alloc(u8, bm.width * bm.rows);
    errdefer alloc.free(buf);

    // width divided by 8 because each byte has 8 pixels. This is therefore
    // the number of bytes in each row.
    const bytes_per_row = bm.width >> 3;

    var source_i: usize = 0;
    var target_i: usize = 0;
    var i: usize = bm.rows;
    while (i > 0) : (i -= 1) {
        var j: usize = bytes_per_row;
        while (j > 0) : (j -= 1) {
            var bit: u4 = 8;
            while (bit > 0) : (bit -= 1) {
                const mask = @as(u8, 1) << @as(u3, @intCast(bit - 1));
                const bitval: u8 = if (bm.buffer[source_i + (j - 1)] & mask > 0) 0xFF else 0;
                buf[target_i] = bitval;
                target_i += 1;
            }
        }

        source_i += @intCast(bm.pitch);
    }

    var copy = bm;
    copy.buffer = buf.ptr;
    copy.pixel_mode = freetype.c.FT_PIXEL_MODE_GRAY;
    copy.pitch = @as(c_int, @intCast(bm.width));
    return copy;
}

test {
    // Force comptime to run
    _ = map;
}

test "mono to greyscale" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var mono_data = [_]u8{0b1010_0101};
    const source: Bitmap = .{
        .rows = 1,
        .width = 8,
        .pitch = 1,
        .buffer = @ptrCast(&mono_data),
        .num_grays = 0,
        .pixel_mode = freetype.c.FT_PIXEL_MODE_MONO,
        .palette_mode = 0,
        .palette = null,
    };

    const result = try monoToGreyscale(alloc, source);
    defer alloc.free(result.buffer[0..(result.width * result.rows)]);
    try testing.expect(result.pixel_mode == freetype.c.FT_PIXEL_MODE_GRAY);
    try testing.expectEqual(@as(u8, 255), result.buffer[0]);
}
