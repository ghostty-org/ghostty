const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const c = @import("c.zig").c;
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
    return swizzle(
        alloc,
        src,
        c.WUFFS_BASE__PIXEL_FORMAT__YA_PREMUL,
        c.WUFFS_BASE__PIXEL_FORMAT__RGBA_PREMUL,
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
