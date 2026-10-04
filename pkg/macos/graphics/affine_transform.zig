const std = @import("std");
const assert = std.debug.assert;
const c = @import("c.zig").c;

pub const AffineTransform = extern struct {
    a: c.CGFloat,
    b: c.CGFloat,
    c: c.CGFloat,
    d: c.CGFloat,
    tx: c.CGFloat,
    ty: c.CGFloat,

    pub fn identity() AffineTransform {
        return fromC(c.CGAffineTransformIdentity);
    }

    pub fn cval(self: AffineTransform) c.CGAffineTransform {
        return .{
            .a = self.a,
            .b = self.b,
            .c = self.c,
            .d = self.d,
            .tx = self.tx,
            .ty = self.ty,
        };
    }

    fn fromC(value: c.CGAffineTransform) AffineTransform {
        return .{
            .a = value.a,
            .b = value.b,
            .c = value.c,
            .d = value.d,
            .tx = value.tx,
            .ty = value.ty,
        };
    }
};
