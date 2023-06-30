const std = @import("std");
const assert = std.debug.assert;
const c = @import("c.zig");

pub const AffineTransform = extern struct {
    a: c.CGFloat,
    b: c.CGFloat,
    c: c.CGFloat,
    d: c.CGFloat,
    tx: c.CGFloat,
    ty: c.CGFloat,

    pub fn identity() AffineTransform {
        return @bitCast(c.CGAffineTransformIdentity);
    }

    pub fn cval(self: AffineTransform) c.struct_CGAffineTransform {
        return @bitCast(self);
    }
};
