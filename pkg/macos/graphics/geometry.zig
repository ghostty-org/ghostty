const std = @import("std");
const assert = std.debug.assert;
const c = @import("c.zig").c;

pub const Point = extern struct {
    x: c.CGFloat,
    y: c.CGFloat,
};

pub const Rect = extern struct {
    origin: Point,
    size: Size,

    pub fn init(x: f64, y: f64, width: f64, height: f64) Rect {
        return .{
            .origin = .{ .x = x, .y = y },
            .size = .{ .width = width, .height = height },
        };
    }

    pub fn cval(self: Rect) c.CGRect {
        return .{
            .origin = .{ .x = self.origin.x, .y = self.origin.y },
            .size = .{ .width = self.size.width, .height = self.size.height },
        };
    }

    pub fn fromC(value: c.CGRect) Rect {
        return .{
            .origin = .{ .x = value.origin.x, .y = value.origin.y },
            .size = .{ .width = value.size.width, .height = value.size.height },
        };
    }

    pub fn isNull(self: Rect) bool {
        return c.CGRectIsNull(self.cval());
    }

    pub fn getHeight(self: Rect) c.CGFloat {
        return c.CGRectGetHeight(self.cval());
    }

    pub fn getWidth(self: Rect) c.CGFloat {
        return c.CGRectGetWidth(self.cval());
    }
};

pub const Size = extern struct {
    width: c.CGFloat,
    height: c.CGFloat,
};
