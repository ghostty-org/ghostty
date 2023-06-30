const c = @import("c.zig");

pub const Point = extern struct {
    x: c.CGFloat,
    y: c.CGFloat,

    pub fn cval(self: Point) c.struct_CGPoint {
        return @as(c.struct_CGPoint, @bitCast(self));
    }
};

pub const Rect = extern struct {
    origin: Point,
    size: Size,

    pub fn init(x: f64, y: f64, width: f64, height: f64) Rect {
        return @as(Rect, @bitCast(c.CGRectMake(x, y, width, height)));
    }

    pub fn cval(self: Rect) c.struct_CGRect {
        return @as(c.struct_CGRect, @bitCast(self));
    }

    pub fn isNull(self: Rect) bool {
        return c.CGRectIsNull(self.cval());
    }
};

pub const Size = extern struct {
    width: c.CGFloat,
    height: c.CGFloat,

    pub fn cval(self: Size) c.struct_CGSize {
        return @as(c.struct_CGSize, @bitCast(self));
    }
};
