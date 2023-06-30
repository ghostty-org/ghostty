const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const foundation = @import("../foundation.zig");
const text = @import("../text.zig");
const c = @import("c.zig");

pub const AttributedString = opaque {
    pub fn release(self: *AttributedString) void {
        foundation.CFRelease(self);
    }

    pub fn getLength(self: *AttributedString) usize {
        return @as(
            usize,
            @intCast(c.CFAttributedStringGetLength(@as(c.CFAttributedStringRef, @ptrCast(self)))),
        );
    }

    pub fn getString(self: *AttributedString) *foundation.String {
        return @as(
            *foundation.String,
            @ptrFromInt(@intFromPtr(
                c.CFAttributedStringGetString(@as(c.CFAttributedStringRef, @ptrCast(self))),
            )),
        );
    }
};

pub const MutableAttributedString = opaque {
    pub fn create(cap: usize) Allocator.Error!*MutableAttributedString {
        return @as(
            ?*MutableAttributedString,
            @ptrFromInt(@intFromPtr(c.CFAttributedStringCreateMutable(
                null,
                @as(c.CFIndex, @intCast(cap)),
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
            @as(c.CFMutableAttributedStringRef, @ptrCast(self)),
            range.cval(),
            @as(c.CFStringRef, @ptrCast(replacement)),
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
        const Key = if (info != .Pointer) T else info.Pointer.child;
        const key_arg = if (@hasDecl(Key, "key"))
            key.key()
        else
            key;

        c.CFAttributedStringSetAttribute(
            @as(c.CFMutableAttributedStringRef, @ptrCast(self)),
            range.cval(),
            @as(c.CFStringRef, @ptrCast(key_arg)),
            value,
        );
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
