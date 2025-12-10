const color = @import("../color.zig");

pub fn rgb_get(
    c: color.RGB.C,
    r: *u8,
    g: *u8,
    b: *u8,
) callconv(.c) void {
    r.* = c.r;
    g.* = c.g;
    b.* = c.b;
}
