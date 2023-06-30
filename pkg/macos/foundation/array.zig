const std = @import("std");
const Allocator = std.mem.Allocator;
const cftype = @import("type.zig");

pub const Array = opaque {
    pub fn create(comptime T: type, values: []*const T) Allocator.Error!*Array {
        return CFArrayCreate(
            null,
            @ptrCast(values.ptr),
            @intCast(values.len),
            null,
        ) orelse error.OutOfMemory;
    }

    pub fn release(self: *Array) void {
        cftype.CFRelease(self);
    }

    pub fn getCount(self: *Array) usize {
        return CFArrayGetCount(self);
    }

    /// Note the return type is actually a `*const T` but we strip the
    /// constness so that further API calls work correctly. The Foundation
    /// API doesn't properly mark things const/non-const.
    pub fn getValueAtIndex(self: *Array, comptime T: type, idx: usize) *T {
        return @ptrCast(CFArrayGetValueAtIndex(self, idx));
    }

    pub extern "c" fn CFArrayCreate(
        allocator: ?*anyopaque,
        values: [*]*const anyopaque,
        num_values: usize,
        callbacks: ?*const anyopaque,
    ) ?*Array;
    pub extern "c" fn CFArrayGetCount(*Array) usize;
    pub extern "c" fn CFArrayGetValueAtIndex(*Array, usize) *anyopaque;
    extern "c" var kCFTypeArrayCallBacks: anyopaque;
};

test "array" {
    const testing = std.testing;

    const str = "hello";
    var values = [_]*const u8{ &str[0], &str[1] };
    const arr = try Array.create(u8, &values);
    defer arr.release();

    try testing.expectEqual(@as(usize, 2), arr.getCount());

    {
        const ch = arr.getValueAtIndex(u8, 0);
        try testing.expectEqual(@as(u8, 'h'), ch.*);
    }
}
