const std = @import("std");
const c = @import("c.zig");
const pixman = @import("main.zig");

pub const FormatCode = enum(c_uint) {
    // 128bpp formats
    rgba_float = c.PIXMAN_FORMAT_BYTE(128, c.PIXMAN_TYPE_RGBA_FLOAT, 32, 32, 32, 32),

    // 96bpp formats
    rgb_float = c.PIXMAN_FORMAT_BYTE(96, c.PIXMAN_TYPE_RGBA_FLOAT, 0, 32, 32, 32),

    // 32bpp formats
    a8r8g8b8 = c.PIXMAN_FORMAT(32, c.PIXMAN_TYPE_ARGB, 8, 8, 8, 8),
    x8r8g8b8 = c.PIXMAN_FORMAT(32, c.PIXMAN_TYPE_ARGB, 0, 8, 8, 8),
    a8b8g8r8 = c.PIXMAN_FORMAT(32, c.PIXMAN_TYPE_ABGR, 8, 8, 8, 8),
    x8b8g8r8 = c.PIXMAN_FORMAT(32, c.PIXMAN_TYPE_ABGR, 0, 8, 8, 8),
    b8g8r8a8 = c.PIXMAN_FORMAT(32, c.PIXMAN_TYPE_BGRA, 8, 8, 8, 8),
    b8g8r8x8 = c.PIXMAN_FORMAT(32, c.PIXMAN_TYPE_BGRA, 0, 8, 8, 8),
    r8g8b8a8 = c.PIXMAN_FORMAT(32, c.PIXMAN_TYPE_RGBA, 8, 8, 8, 8),
    r8g8b8x8 = c.PIXMAN_FORMAT(32, c.PIXMAN_TYPE_RGBA, 0, 8, 8, 8),
    x14r6g6b6 = c.PIXMAN_FORMAT(32, c.PIXMAN_TYPE_ARGB, 0, 6, 6, 6),
    x2r10g10b10 = c.PIXMAN_FORMAT(32, c.PIXMAN_TYPE_ARGB, 0, 10, 10, 10),
    a2r10g10b10 = c.PIXMAN_FORMAT(32, c.PIXMAN_TYPE_ARGB, 2, 10, 10, 10),
    x2b10g10r10 = c.PIXMAN_FORMAT(32, c.PIXMAN_TYPE_ABGR, 0, 10, 10, 10),
    a2b10g10r10 = c.PIXMAN_FORMAT(32, c.PIXMAN_TYPE_ABGR, 2, 10, 10, 10),

    // sRGB formats
    a8r8g8b8_sRGB = c.PIXMAN_FORMAT(32, c.PIXMAN_TYPE_ARGB_SRGB, 8, 8, 8, 8),
    r8g8b8_sRGB = c.PIXMAN_FORMAT(24, c.PIXMAN_TYPE_ARGB_SRGB, 0, 8, 8, 8),

    // 24bpp formats
    r8g8b8 = c.PIXMAN_FORMAT(24, c.PIXMAN_TYPE_ARGB, 0, 8, 8, 8),
    b8g8r8 = c.PIXMAN_FORMAT(24, c.PIXMAN_TYPE_ABGR, 0, 8, 8, 8),

    // 16bpp formats
    r5g6b5 = c.PIXMAN_FORMAT(16, c.PIXMAN_TYPE_ARGB, 0, 5, 6, 5),
    b5g6r5 = c.PIXMAN_FORMAT(16, c.PIXMAN_TYPE_ABGR, 0, 5, 6, 5),

    a1r5g5b5 = c.PIXMAN_FORMAT(16, c.PIXMAN_TYPE_ARGB, 1, 5, 5, 5),
    x1r5g5b5 = c.PIXMAN_FORMAT(16, c.PIXMAN_TYPE_ARGB, 0, 5, 5, 5),
    a1b5g5r5 = c.PIXMAN_FORMAT(16, c.PIXMAN_TYPE_ABGR, 1, 5, 5, 5),
    x1b5g5r5 = c.PIXMAN_FORMAT(16, c.PIXMAN_TYPE_ABGR, 0, 5, 5, 5),
    a4r4g4b4 = c.PIXMAN_FORMAT(16, c.PIXMAN_TYPE_ARGB, 4, 4, 4, 4),
    x4r4g4b4 = c.PIXMAN_FORMAT(16, c.PIXMAN_TYPE_ARGB, 0, 4, 4, 4),
    a4b4g4r4 = c.PIXMAN_FORMAT(16, c.PIXMAN_TYPE_ABGR, 4, 4, 4, 4),
    x4b4g4r4 = c.PIXMAN_FORMAT(16, c.PIXMAN_TYPE_ABGR, 0, 4, 4, 4),

    // 8bpp formats
    a8 = c.PIXMAN_FORMAT(8, c.PIXMAN_TYPE_A, 8, 0, 0, 0),
    r3g3b2 = c.PIXMAN_FORMAT(8, c.PIXMAN_TYPE_ARGB, 0, 3, 3, 2),
    b2g3r3 = c.PIXMAN_FORMAT(8, c.PIXMAN_TYPE_ABGR, 0, 3, 3, 2),
    a2r2g2b2 = c.PIXMAN_FORMAT(8, c.PIXMAN_TYPE_ARGB, 2, 2, 2, 2),
    a2b2g2r2 = c.PIXMAN_FORMAT(8, c.PIXMAN_TYPE_ABGR, 2, 2, 2, 2),

    c8 = c.PIXMAN_FORMAT(8, c.PIXMAN_TYPE_COLOR, 0, 0, 0, 0),
    g8 = c.PIXMAN_FORMAT(8, c.PIXMAN_TYPE_GRAY, 0, 0, 0, 0),

    x4a4 = c.PIXMAN_FORMAT(8, c.PIXMAN_TYPE_A, 4, 0, 0, 0),

    // c8/g8 equivalent
    // x4c4 = c.PIXMAN_FORMAT(8, c.PIXMAN_TYPE_COLOR, 0, 0, 0, 0),
    // x4g4 = c.PIXMAN_FORMAT(8, c.PIXMAN_TYPE_GRAY, 0, 0, 0, 0),

    // 4bpp formats
    a4 = c.PIXMAN_FORMAT(4, c.PIXMAN_TYPE_A, 4, 0, 0, 0),
    r1g2b1 = c.PIXMAN_FORMAT(4, c.PIXMAN_TYPE_ARGB, 0, 1, 2, 1),
    b1g2r1 = c.PIXMAN_FORMAT(4, c.PIXMAN_TYPE_ABGR, 0, 1, 2, 1),
    a1r1g1b1 = c.PIXMAN_FORMAT(4, c.PIXMAN_TYPE_ARGB, 1, 1, 1, 1),
    a1b1g1r1 = c.PIXMAN_FORMAT(4, c.PIXMAN_TYPE_ABGR, 1, 1, 1, 1),

    c4 = c.PIXMAN_FORMAT(4, c.PIXMAN_TYPE_COLOR, 0, 0, 0, 0),
    g4 = c.PIXMAN_FORMAT(4, c.PIXMAN_TYPE_GRAY, 0, 0, 0, 0),

    // 1bpp formats
    a1 = c.PIXMAN_FORMAT(1, c.PIXMAN_TYPE_A, 1, 0, 0, 0),

    g1 = c.PIXMAN_FORMAT(1, c.PIXMAN_TYPE_GRAY, 0, 0, 0, 0),

    // YUV formats
    yuy2 = c.PIXMAN_FORMAT(16, c.PIXMAN_TYPE_YUY2, 0, 0, 0, 0),
    yv12 = c.PIXMAN_FORMAT(12, c.PIXMAN_TYPE_YV12, 0, 0, 0, 0),

    pub inline fn bpp(self: FormatCode) u32 {
        return self.reshift(24, 8);
    }

    /// Calculates a valid stride for the bpp and width. Based on Cairo.
    pub fn strideForWidth(self: FormatCode, width: u32) c_int {
        const alignment = @sizeOf(u32);
        const val = @as(c_int, @intCast((self.bpp() * width + 7) / 8));
        return val + (alignment - 1) & -alignment;
    }

    // Converted from pixman.h
    fn reshift(self: FormatCode, ofs: u5, num: u5) u32 {
        const val = @intFromEnum(self);
        const v1 = val >> ofs;
        const v2 = @as(c_uint, 1) << num;
        const v3 = @as(u5, @intCast((val >> 22) & 3));
        return ((v1 & (v2 - 1)) << v3);
    }
};

test "bpp" {
    const testing = std.testing;

    try testing.expectEqual(@as(u32, 1), FormatCode.g1.bpp());
    try testing.expectEqual(@as(u32, 4), FormatCode.g4.bpp());
    try testing.expectEqual(@as(u32, 8), FormatCode.g8.bpp());
}

test "stride" {
    const testing = std.testing;

    try testing.expectEqual(@as(c_int, 4), FormatCode.g1.strideForWidth(10));
    try testing.expectEqual(@as(c_int, 8), FormatCode.g4.strideForWidth(10));
    try testing.expectEqual(@as(c_int, 12), FormatCode.g8.strideForWidth(10));
}
