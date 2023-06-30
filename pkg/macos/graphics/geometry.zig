const c = @import("c.zig");

pub const Point = extern struct {
    x: c.CGFloat,
    y: c.CGFloat,

    pub fn cval(self: Point) c.struct_CGPoint {
        return @bitCast(self);
    }
};

pub const Rect = extern struct {
    origin: Point,
    size: Size,

    pub fn init(x: f64, y: f64, width: f64, height: f64) Rect {
        return @bitCast(c.CGRectMake(x, y, width, height));
    }

    pub fn cval(self: Rect) c.struct_CGRect {
        return @bitCast(self);
    }

    pub fn isNull(self: Rect) bool {
        return c.CGRectIsNull(self.cval());
    }
};

pub const Size = extern struct {
    width: c.CGFloat,
    height: c.CGFloat,

    pub fn cval(self: Size) c.struct_CGSize {
        return @bitCast(self);
    }
};
