const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const foundation = @import("../foundation.zig");
const c = @import("c.zig");

pub const Dictionary = opaque {
    pub fn create(
        keys: ?[]?*const anyopaque,
        values: ?[]?*const anyopaque,
    ) Allocator.Error!*Dictionary {
        if (keys != null or values != null) {
            assert(keys != null);
            assert(values != null);
            assert(keys.?.len == values.?.len);
        }

        return @as(?*Dictionary, @ptrFromInt(@intFromPtr(c.CFDictionaryCreate(
            null,
            @as([*c]?*const anyopaque, @ptrCast(if (keys) |slice| slice.ptr else null)),
            @as([*c]?*const anyopaque, @ptrCast(if (values) |slice| slice.ptr else null)),
            @as(c.CFIndex, @intCast(if (keys) |slice| slice.len else 0)),
            &c.kCFTypeDictionaryKeyCallBacks,
            &c.kCFTypeDictionaryValueCallBacks,
        )))) orelse Allocator.Error.OutOfMemory;
    }

    pub fn release(self: *Dictionary) void {
        foundation.CFRelease(self);
    }

    pub fn getCount(self: *Dictionary) usize {
        return @as(usize, @intCast(c.CFDictionaryGetCount(@as(c.CFDictionaryRef, @ptrCast(self)))));
    }

    pub fn getValue(self: *Dictionary, comptime V: type, key: ?*const anyopaque) ?*V {
        return @as(?*V, @ptrFromInt(@intFromPtr(c.CFDictionaryGetValue(
            @as(c.CFDictionaryRef, @ptrCast(self)),
            key,
        ))));
    }
};

pub const MutableDictionary = opaque {
    pub fn create(cap: usize) Allocator.Error!*MutableDictionary {
        return @as(?*MutableDictionary, @ptrFromInt(@intFromPtr(c.CFDictionaryCreateMutable(
            null,
            @as(c.CFIndex, @intCast(cap)),
            &c.kCFTypeDictionaryKeyCallBacks,
            &c.kCFTypeDictionaryValueCallBacks,
        )))) orelse Allocator.Error.OutOfMemory;
    }

    pub fn createMutableCopy(cap: usize, src: *Dictionary) Allocator.Error!*MutableDictionary {
        return @as(?*MutableDictionary, @ptrFromInt(@intFromPtr(c.CFDictionaryCreateMutableCopy(
            null,
            @as(c.CFIndex, @intCast(cap)),
            @as(c.CFDictionaryRef, @ptrCast(src)),
        )))) orelse Allocator.Error.OutOfMemory;
    }

    pub fn release(self: *MutableDictionary) void {
        foundation.CFRelease(self);
    }

    pub fn setValue(self: *MutableDictionary, key: ?*const anyopaque, value: ?*const anyopaque) void {
        c.CFDictionarySetValue(
            @as(c.CFMutableDictionaryRef, @ptrCast(self)),
            key,
            value,
        );
    }
};

test "dictionary" {
    const testing = std.testing;

    const str = try foundation.String.createWithBytes("hello", .unicode, false);
    defer str.release();

    var keys = [_]?*const anyopaque{c.kCFURLIsPurgeableKey};
    var values = [_]?*const anyopaque{str};
    const dict = try Dictionary.create(&keys, &values);
    defer dict.release();

    try testing.expectEqual(@as(usize, 1), dict.getCount());
    try testing.expect(dict.getValue(foundation.String, c.kCFURLIsPurgeableKey) != null);
    try testing.expect(dict.getValue(foundation.String, c.kCFURLIsVolumeKey) == null);
}

test "mutable dictionary" {
    const testing = std.testing;

    const dict = try MutableDictionary.create(0);
    defer dict.release();

    const str = try foundation.String.createWithBytes("hello", .unicode, false);
    defer str.release();

    dict.setValue(c.kCFURLIsPurgeableKey, str);

    {
        const imm = @as(*Dictionary, @ptrCast(dict));
        try testing.expectEqual(@as(usize, 1), imm.getCount());
        try testing.expect(imm.getValue(foundation.String, c.kCFURLIsPurgeableKey) != null);
        try testing.expect(imm.getValue(foundation.String, c.kCFURLIsVolumeKey) == null);
    }
}
