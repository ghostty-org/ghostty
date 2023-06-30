const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const foundation = @import("../foundation.zig");
const graphics = @import("../graphics.zig");
const text = @import("../text.zig");
const c = @import("c.zig");

pub const Frame = opaque {
    pub fn release(self: *Frame) void {
        foundation.CFRelease(self);
    }

    pub fn getLineOrigins(
        self: *Frame,
        range: foundation.Range,
        points: []graphics.Point,
    ) void {
        c.CTFrameGetLineOrigins(
            @as(c.CTFrameRef, @ptrCast(self)),
            @as(c.CFRange, @bitCast(range)),
            @as(*c.CGPoint, @ptrCast(points.ptr)),
        );
    }

    pub fn getLines(self: *Frame) *foundation.Array {
        return @as(
            *foundation.Array,
            @ptrFromInt(@intFromPtr(c.CTFrameGetLines(@as(c.CTFrameRef, @ptrCast(self))))),
        );
    }
};

test {
    // See framesetter tests...
}
