const c = @import("c.zig");

pub const ComparisonResult = enum(c_int) {
    less = -1,
    equal = 0,
    greater = 1,
};

pub const Range = extern struct {
    location: c.CFIndex,
    length: c.CFIndex,

    pub fn init(loc: usize, len: usize) Range {
        return @as(Range, @bitCast(c.CFRangeMake(@as(c_long, @intCast(loc)), @as(c_long, @intCast(len)))));
    }

    pub fn cval(self: Range) c.CFRange {
        return @as(c.CFRange, @bitCast(self));
    }
};
