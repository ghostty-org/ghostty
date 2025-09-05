const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const foundation = @import("../foundation.zig");
const text = @import("../text.zig");
const c = @import("c.zig").c;

pub const AttributedString = opaque {
    pub fn create(
        str: *foundation.String,
        attributes: *foundation.Dictionary,
    ) Allocator.Error!*AttributedString {
        return @ptrCast(@constCast(c.CFAttributedStringCreate(
            null,
            @ptrCast(str),
            @ptrCast(attributes),
        ) orelse return Allocator.Error.OutOfMemory));
    }

    pub fn release(self: *AttributedString) void {
        foundation.CFRelease(self);
    }

    pub fn getLength(self: *AttributedString) usize {
        return @intCast(c.CFAttributedStringGetLength(@ptrCast(self)));
    }

    pub fn getString(self: *AttributedString) *foundation.String {
        return @ptrFromInt(@intFromPtr(
            c.CFAttributedStringGetString(@ptrCast(self)),
        ));
    }
};

pub const MutableAttributedString = opaque {
    pub fn create(cap: usize) Allocator.Error!*MutableAttributedString {
        return @as(
            ?*MutableAttributedString,
            @ptrFromInt(@intFromPtr(c.CFAttributedStringCreateMutable(
                null,
                @intCast(cap),
            ))),
        ) orelse Allocator.Error.OutOfMemory;
    }

    pub fn release(self: *MutableAttributedString) void {
        foundation.CFRelease(self);
    }

    pub fn replaceString(
        self: *MutableAttributedString,
        range: foundation.Range,
        replacement: *foundation.String,
    ) void {
        c.CFAttributedStringReplaceString(
            @ptrCast(self),
            @bitCast(range),
            @ptrCast(replacement),
        );
    }

    pub fn setAttribute(
        self: *MutableAttributedString,
        range: foundation.Range,
        key: anytype,
        value: ?*anyopaque,
    ) void {
        const T = @TypeOf(key);
        const info = @typeInfo(T);
        const Key = if (info != .pointer) T else info.pointer.child;
        const key_arg = if (@hasDecl(Key, "key"))
            key.key()
        else
            key;

        c.CFAttributedStringSetAttribute(
            @ptrCast(self),
            @bitCast(range),
            @ptrCast(key_arg),
            value,
        );
    }

    pub fn getLength(self: *MutableAttributedString) usize {
        return @intCast(c.CFAttributedStringGetLength(@ptrCast(self)));
    }
};

test "mutable attributed string" {
    //const testing = std.testing;

    const str = try MutableAttributedString.create(0);
    defer str.release();

    {
        const rep = try foundation.String.createWithBytes("hello", .utf8, false);
        defer rep.release();
        str.replaceString(foundation.Range.init(0, 0), rep);
    }

    str.setAttribute(foundation.Range.init(0, 0), text.FontAttribute.url, null);
    str.setAttribute(foundation.Range.init(0, 0), text.FontAttribute.name.key(), null);
}
