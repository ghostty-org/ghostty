const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const graphics = @import("../graphics.zig");
const context = @import("context.zig");
const c = @import("c");

pub const ImageAlphaInfo = enum(c_uint) {
    none = c.kCGImageAlphaNone,
    premultiplied_last = c.kCGImageAlphaPremultipliedLast,
    premultiplied_first = c.kCGImageAlphaPremultipliedFirst,
    last = c.kCGImageAlphaLast,
    first = c.kCGImageAlphaFirst,
    none_skip_last = c.kCGImageAlphaNoneSkipLast,
    none_skip_first = c.kCGImageAlphaNoneSkipFirst,
    only = c.kCGImageAlphaOnly,
};

pub const BitmapInfo = enum(c_uint) {
    alpha_mask = c.kCGBitmapAlphaInfoMask,
    float_mask = c.kCGBitmapFloatInfoMask,
    float_components = c.kCGBitmapFloatComponents,
    byte_order_mask = c.kCGBitmapByteOrderMask,
    byte_order_default = c.kCGBitmapByteOrderDefault,
    byte_order_16_little = c.kCGBitmapByteOrder16Little,
    byte_order_32_little = c.kCGBitmapByteOrder32Little,
    byte_order_16_big = c.kCGBitmapByteOrder16Big,
    byte_order_32_big = c.kCGBitmapByteOrder32Big,

    _,
};
