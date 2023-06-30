const std = @import("std");
const c = @import("c.zig");
const pixman = @import("main.zig");

pub const Op = enum(c_uint) {
    clear = 0x00,
    src = 0x01,
    dst = 0x02,
    over = 0x03,
    over_reverse = 0x04,
    in = 0x05,
    in_reverse = 0x06,
    out = 0x07,
    out_reverse = 0x08,
    atop = 0x09,
    atop_reverse = 0x0a,
    xor = 0x0b,
    add = 0x0c,
    saturate = 0x0d,

    disjoint_clear = 0x10,
    disjoint_src = 0x11,
    disjoint_dst = 0x12,
    disjoint_over = 0x13,
    disjoint_over_reverse = 0x14,
    disjoint_in = 0x15,
    disjoint_in_reverse = 0x16,
    disjoint_out = 0x17,
    disjoint_out_reverse = 0x18,
    disjoint_atop = 0x19,
    disjoint_atop_reverse = 0x1a,
    disjoint_xor = 0x1b,

    conjoint_clear = 0x20,
    conjoint_src = 0x21,
    conjoint_dst = 0x22,
    conjoint_over = 0x23,
    conjoint_over_reverse = 0x24,
    conjoint_in = 0x25,
    conjoint_in_reverse = 0x26,
    conjoint_out = 0x27,
    conjoint_out_reverse = 0x28,
    conjoint_atop = 0x29,
    conjoint_atop_reverse = 0x2a,
    conjoint_xor = 0x2b,

    multiply = 0x30,
    screen = 0x31,
    overlay = 0x32,
    darken = 0x33,
    lighten = 0x34,
    color_dodge = 0x35,
    color_burn = 0x36,
    hard_light = 0x37,
    soft_light = 0x38,
    difference = 0x39,
    exclusion = 0x3a,
    hsl_hue = 0x3b,
    hsl_saturation = 0x3c,
    hsl_color = 0x3d,
    hsl_luminosity = 0x3e,
};

pub const Color = extern struct {
    red: u16,
    green: u16,
    blue: u16,
    alpha: u16,
};

pub const Fixed = enum(i32) {
    _,

    pub fn init(v: anytype) Fixed {
        return switch (@TypeOf(v)) {
            comptime_int, i32, u32 => @enumFromInt(v << 16),
            f64 => @enumFromInt(@as(i32, @intFromFloat(v * 65536))),
            else => {
                @compileLog(@TypeOf(v));
                @compileError("unsupported type");
            },
        };
    }
};

pub const PointFixed = extern struct {
    x: Fixed,
    y: Fixed,
};

pub const LineFixed = extern struct {
    p1: PointFixed,
    p2: PointFixed,
};

pub const Triangle = extern struct {
    p1: PointFixed,
    p2: PointFixed,
    p3: PointFixed,
};

pub const Trapezoid = extern struct {
    top: Fixed,
    bottom: Fixed,
    left: LineFixed,
    right: LineFixed,
};

pub const Rectangle16 = extern struct {
    x: i16,
    y: i16,
    width: u16,
    height: u16,
};

pub const Box32 = extern struct {
    x1: i32,
    y1: i32,
    x2: i32,
    y2: i32,
};

pub const Indexed = extern struct {
    color: bool,
    rgba: [256]u32,
    ent: [32768]u8,
};

test {
    std.testing.refAllDecls(@This());
}
