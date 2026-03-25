const lib = @import("../lib.zig");
const color = @import("../color.zig");

pub fn rgb_get(
    c: color.RGB.C,
    r: *u8,
    g: *u8,
    b: *u8,
) callconv(lib.calling_conv) void {
    r.* = c.r;
    g.* = c.g;
    b.* = c.b;
}
