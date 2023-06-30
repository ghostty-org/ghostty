const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const foundation = @import("../foundation.zig");
const c = @import("c.zig");

pub const CharacterSet = opaque {
    pub fn createWithCharactersInString(
        str: *foundation.String,
    ) Allocator.Error!*CharacterSet {
        return @as(?*CharacterSet, @ptrFromInt(@intFromPtr(c.CFCharacterSetCreateWithCharactersInString(
            null,
            @ptrCast(str),
        )))) orelse Allocator.Error.OutOfMemory;
    }

    pub fn createWithCharactersInRange(
        range: foundation.Range,
    ) Allocator.Error!*CharacterSet {
        return @as(?*CharacterSet, @ptrFromInt(@intFromPtr(c.CFCharacterSetCreateWithCharactersInRange(
            null,
            range.cval(),
        )))) orelse Allocator.Error.OutOfMemory;
    }

    pub fn release(self: *CharacterSet) void {
        c.CFRelease(self);
    }
};

test "character set" {
    //const testing = std.testing;

    const str = try foundation.String.createWithBytes("hello world", .ascii, false);
    defer str.release();

    const cs = try CharacterSet.createWithCharactersInString(str);
    defer cs.release();
}

test "character set range" {
    //const testing = std.testing;

    const cs = try CharacterSet.createWithCharactersInRange(.{
        .location = 'A',
        .length = 1,
    });
    defer cs.release();
}
