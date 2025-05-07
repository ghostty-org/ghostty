const std = @import("std");
const Allocator = std.mem.Allocator;
const base = @import("base.zig");
const c = @import("c.zig").c;
const cftype = @import("type.zig");
const ComparisonResult = base.ComparisonResult;
const Range = base.Range;

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
        return @ptrCast(@alignCast(CFArrayGetValueAtIndex(self, idx)));
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

pub const MutableArray = opaque {
    pub fn create() Allocator.Error!*MutableArray {
        return CFArrayCreateMutable(
            null,
            0,
            &c.kCFTypeArrayCallBacks,
        ) orelse error.OutOfMemory;
    }

    pub fn createCopy(array: *Array) Allocator.Error!*MutableArray {
        return CFArrayCreateMutableCopy(
            null,
            0,
            array,
        ) orelse error.OutOfMemory;
    }

    pub fn release(self: *MutableArray) void {
        cftype.CFRelease(self);
    }

    pub fn appendValue(
        self: *MutableArray,
        comptime Elem: type,
        value: *const Elem,
    ) void {
        CFArrayAppendValue(self, @constCast(@ptrCast(value)));
    }

    pub fn removeValue(self: *MutableArray, idx: usize) void {
        CFArrayRemoveValueAtIndex(self, idx);
    }

    pub fn sortValues(
        self: *MutableArray,
        comptime Elem: type,
        comptime Context: type,
        context: ?*Context,
        comptime comparator: ?*const fn (
            a: *const Elem,
            b: *const Elem,
            context: ?*Context,
        ) callconv(.c) ComparisonResult,
    ) void {
        CFArraySortValues(
            self,
            Range.init(0, Array.CFArrayGetCount(@ptrCast(self))),
            comparator,
            context,
        );
    }

    extern "c" fn CFArrayCreateMutable(
        allocator: ?*anyopaque,
        capacity: usize,
        callbacks: ?*const anyopaque,
    ) ?*MutableArray;
    extern "c" fn CFArrayCreateMutableCopy(
        allocator: ?*anyopaque,
        capacity: usize,
        array: *Array,
    ) ?*MutableArray;
    extern "c" fn CFArrayAppendValue(
        *MutableArray,
        *anyopaque,
    ) void;
    extern "c" fn CFArrayRemoveValueAtIndex(
        *MutableArray,
        usize,
    ) void;
    extern "c" fn CFArraySortValues(
        array: *MutableArray,
        range: Range,
        comparator: ?*const anyopaque,
        context: ?*anyopaque,
    ) void;
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

    // Can make it mutable
    var mut = try MutableArray.createCopy(arr);
    defer mut.release();
}

test "array sorting" {
    const testing = std.testing;

    const str = "hello";
    var values = [_]*const u8{ &str[0], &str[1] };
    const arr = try Array.create(u8, &values);
    defer arr.release();
    const mut = try MutableArray.createCopy(arr);
    defer mut.release();

    mut.sortValues(
        u8,
        void,
        null,
        struct {
            fn compare(a: *const u8, b: *const u8, _: ?*void) callconv(.c) ComparisonResult {
                if (a.* > b.*) return .greater;
                if (a.* == b.*) return .equal;
                return .less;
            }
        }.compare,
    );

    {
        const mutarr: *Array = @ptrCast(mut);
        const ch = mutarr.getValueAtIndex(u8, 0);
        try testing.expectEqual(@as(u8, 'e'), ch.*);
    }
    {
        const mutarr: *Array = @ptrCast(mut);
        const ch = mutarr.getValueAtIndex(u8, 1);
        try testing.expectEqual(@as(u8, 'h'), ch.*);
    }
}
