const std = @import("std");
const assert = std.debug.assert;
const c = @import("c");

pub const ComparisonResult = enum(c_int) {
    less = -1,
    equal = 0,
    greater = 1,
};

pub const Range = extern struct {
    location: c.CFIndex,
    length: c.CFIndex,

    pub fn init(loc: usize, len: usize) Range {
        return @bitCast(c.CFRangeMake(@intCast(loc), @intCast(len)));
    }
};

pub const FourCharCode = packed struct(u32) {
    d: u8,
    c: u8,
    b: u8,
    a: u8,

    pub fn init(v: *const [4]u8) FourCharCode {
        return .{ .a = v[0], .b = v[1], .c = v[2], .d = v[3] };
    }

    /// Converts the ID to a string. The return value is only valid
    /// for the lifetime of the self pointer.
    pub fn str(self: FourCharCode) [4]u8 {
        return .{ self.a, self.b, self.c, self.d };
    }
};
