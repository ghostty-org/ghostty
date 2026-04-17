const std = @import("std");
const assert = std.debug.assert;
const c = @import("c");

pub const Matrix = extern struct {
    xx: f64,
    xy: f64,
    yx: f64,
    yy: f64,
};
