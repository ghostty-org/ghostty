const std = @import("std");
const c = @import("c.zig");

/// Compute (a*b)/0x10000 with maximum accuracy. Its main use is to multiply
/// a given value by a 16.16 fixed-point factor.
pub fn mulFix(a: i32, b: i32) i32 {
    return @intCast(c.FT_MulFix(a, b));
}
