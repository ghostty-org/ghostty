const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const c = @import("wuffs_c");
const Error = @import("error.zig").Error;

const log = std.log.scoped(.wuffs_swizzler);

pub fn gToRgba(alloc: Allocator, src: []const u8) Error![]u8 {
    return swizzle(
        alloc,
        src,
        c.WUFFS_BASE__PIXEL_FORMAT__Y,
        c.WUFFS_BASE__PIXEL_FORMAT__RGBA_PREMUL,
    );
}

pub fn gaToRgba(alloc: Allocator, src: []const u8) Error![]u8 {
    // Wuffs doesn't support YA_PREMUL as a swizzle source. The nonpremul
    // pair produces the same bytes (r=g=b=y, a=a, no alpha math), which
    // is what we want: alpha semantics are preserved as-is, matching the
    // other conversions here.
    return swizzle(
        alloc,
        src,
        c.WUFFS_BASE__PIXEL_FORMAT__YA_NONPREMUL,
        c.WUFFS_BASE__PIXEL_FORMAT__RGBA_NONPREMUL,
    );
}

pub fn rgbToRgba(alloc: Allocator, src: []const u8) Error![]u8 {
    return swizzle(
        alloc,
        src,
        c.WUFFS_BASE__PIXEL_FORMAT__RGB,
        c.WUFFS_BASE__PIXEL_FORMAT__RGBA_PREMUL,
    );
}

pub fn bgrToRgba(alloc: Allocator, src: []const u8) Error![]u8 {
    return swizzle(
        alloc,
        src,
        c.WUFFS_BASE__PIXEL_FORMAT__BGR,
        c.WUFFS_BASE__PIXEL_FORMAT__RGBA_PREMUL,
    );
}

pub fn bgraToRgba(alloc: Allocator, src: []const u8) Error![]u8 {
    return swizzle(
        alloc,
        src,
        c.WUFFS_BASE__PIXEL_FORMAT__BGRA_PREMUL,
        c.WUFFS_BASE__PIXEL_FORMAT__RGBA_PREMUL,
    );
}

/// Composite `src` over `dst` in place. Both are straight
/// (non-premultiplied) alpha RGBA of the same length. A transparent
/// destination pixel takes the source pixel exactly; wuffs composites
/// everything else in 16-bit integer space.
pub fn rgbaSrcOver(dst: []u8, src: []const u8) void {
    assert(dst.len == src.len);
    assert(dst.len % 4 == 0);

    var swizzler: c.wuffs_base__pixel_swizzler = undefined;
    const status = c.wuffs_base__pixel_swizzler__prepare(
        &swizzler,
        c.wuffs_base__make_pixel_format(c.WUFFS_BASE__PIXEL_FORMAT__RGBA_NONPREMUL),
        c.wuffs_base__empty_slice_u8(),
        c.wuffs_base__make_pixel_format(c.WUFFS_BASE__PIXEL_FORMAT__RGBA_NONPREMUL),
        c.wuffs_base__empty_slice_u8(),
        c.WUFFS_BASE__PIXEL_BLEND__SRC_OVER,
    );
    // This format pair and blend mode is a supported swizzle, so
    // preparation can only fail on a programming error.
    assert(c.wuffs_base__status__is_ok(&status));

    _ = c.wuffs_base__pixel_swizzler__swizzle_interleaved_from_slice(
        &swizzler,
        c.wuffs_base__make_slice_u8(dst.ptr, dst.len),
        c.wuffs_base__empty_slice_u8(),
        c.wuffs_base__make_slice_u8(@constCast(src.ptr), src.len),
    );
}

test "gaToRgba" {
    const rgba = try gaToRgba(std.testing.allocator, &.{ 7, 100, 8, 200 });
    defer std.testing.allocator.free(rgba);

    try std.testing.expectEqualSlices(u8, &.{
        7, 7, 7, 100,
        8, 8, 8, 200,
    }, rgba);
}

test "rgbaSrcOver" {
    // 50% white over opaque black, opaque over anything, transparent
    // source over anything, and anything over a transparent
    // destination (exact source passthrough).
    var dst = [_]u8{
        0,  0,  0,  255,
        10, 20, 30, 40,
        10, 20, 30, 40,
        0,  0,  0,  0,
    };
    rgbaSrcOver(&dst, &.{
        255, 255, 255, 128,
        100, 110, 120, 255,
        100, 110, 120, 0,
        200, 100, 50,  128,
    });
    try std.testing.expectEqualSlices(u8, &.{
        128, 128, 128, 255,
        100, 110, 120, 255,
        10,  20,  30,  40,
        200, 100, 50,  128,
    }, &dst);
}

fn swizzle(
    alloc: Allocator,
    src: []const u8,
    comptime src_pixel_format: u32,
    comptime dst_pixel_format: u32,
) Error![]u8 {
    const src_slice = c.wuffs_base__make_slice_u8(
        @constCast(src.ptr),
        src.len,
    );

    const dst_fmt = c.wuffs_base__make_pixel_format(
        dst_pixel_format,
    );

    assert(c.wuffs_base__pixel_format__is_direct(&dst_fmt));
    assert(c.wuffs_base__pixel_format__is_interleaved(&dst_fmt));
    assert(c.wuffs_base__pixel_format__bits_per_pixel(&dst_fmt) % 8 == 0);

    const dst_size = c.wuffs_base__pixel_format__bits_per_pixel(&dst_fmt) / 8;

    const src_fmt = c.wuffs_base__make_pixel_format(
        src_pixel_format,
    );

    assert(c.wuffs_base__pixel_format__is_direct(&src_fmt));
    assert(c.wuffs_base__pixel_format__is_interleaved(&src_fmt));
    assert(c.wuffs_base__pixel_format__bits_per_pixel(&src_fmt) % 8 == 0);

    const src_size = c.wuffs_base__pixel_format__bits_per_pixel(&src_fmt) / 8;

    assert(src.len % src_size == 0);

    const dst = try alloc.alloc(u8, src.len * dst_size / src_size);
    errdefer alloc.free(dst);

    const dst_slice = c.wuffs_base__make_slice_u8(
        dst.ptr,
        dst.len,
    );

    var swizzler: c.wuffs_base__pixel_swizzler = undefined;
    {
        const status = c.wuffs_base__pixel_swizzler__prepare(
            &swizzler,
            dst_fmt,
            c.wuffs_base__empty_slice_u8(),
            src_fmt,
            c.wuffs_base__empty_slice_u8(),
            c.WUFFS_BASE__PIXEL_BLEND__SRC,
        );
        if (!c.wuffs_base__status__is_ok(&status)) {
            const e = c.wuffs_base__status__message(&status);
            log.warn("{s}", .{e});
            return error.WuffsError;
        }
    }
    {
        _ = c.wuffs_base__pixel_swizzler__swizzle_interleaved_from_slice(
            &swizzler,
            dst_slice,
            c.wuffs_base__empty_slice_u8(),
            src_slice,
        );
    }

    return dst;
}
