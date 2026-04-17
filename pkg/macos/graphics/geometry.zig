const std = @import("std");
const assert = std.debug.assert;
const c = @import("c");

pub const Point = extern struct {
    x: c.CGFloat,
    y: c.CGFloat,
};

pub const Rect = extern struct {
    origin: Point,
    size: Size,

    pub fn init(x: f64, y: f64, width: f64, height: f64) Rect {
        return @bitCast(c.CGRectMake(x, y, width, height));
    }

    pub fn isNull(self: Rect) bool {
        return c.CGRectIsNull(@bitCast(self));
    }

    pub fn getHeight(self: Rect) c.CGFloat {
        return c.CGRectGetHeight(@bitCast(self));
    }

    pub fn getWidth(self: Rect) c.CGFloat {
        return c.CGRectGetWidth(@bitCast(self));
    }
};

pub const Size = extern struct {
    width: c.CGFloat,
    height: c.CGFloat,
};
