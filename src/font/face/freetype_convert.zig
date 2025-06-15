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
        result[i] = .initFill(null);
    }

    // Map our converters
    result[freetype.c.FT_PIXEL_MODE_MONO].set(.grayscale, monoToGrayscale);

    return result;
}

pub fn monoToGrayscale(alloc: Allocator, bm: Bitmap) Allocator.Error!Bitmap {
    var buf = try alloc.alloc(u8, bm.width * bm.rows);
    errdefer alloc.free(buf);

    for (0..bm.rows) |y| {
        const row_offset = y * @as(usize, @intCast(bm.pitch));
        for (0..bm.width) |x| {
            const byte_offset = row_offset + @divTrunc(x, 8);
            const mask = @as(u8, 1) << @intCast(7 - (x % 8));
            const bit: u8 = @intFromBool((bm.buffer[byte_offset] & mask) != 0);
            buf[y * bm.width + x] = bit * 255;
        }
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

test "mono to grayscale" {
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

    const result = try monoToGrayscale(alloc, source);
    defer alloc.free(result.buffer[0..(result.width * result.rows)]);
    try testing.expect(result.pixel_mode == freetype.c.FT_PIXEL_MODE_GRAY);
    try testing.expectEqual(@as(u8, 255), result.buffer[0]);
}
