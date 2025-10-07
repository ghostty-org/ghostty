const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const foundation = @import("../foundation.zig");
const graphics = @import("../graphics.zig");
const text = @import("../text.zig");
const c = @import("c.zig").c;

pub const Typesetter = opaque {
    pub fn createWithAttributedStringAndOptions(
        str: *foundation.AttributedString,
        opts: *foundation.Dictionary,
    ) Allocator.Error!*Typesetter {
        return @as(
            ?*Typesetter,
            @ptrFromInt(@intFromPtr(c.CTTypesetterCreateWithAttributedStringAndOptions(
                @ptrCast(str),
                @ptrCast(opts),
            ))),
        ) orelse Allocator.Error.OutOfMemory;
    }

    pub fn release(self: *Typesetter) void {
        foundation.CFRelease(self);
    }

    pub fn createLine(
        self: *Typesetter,
        range: foundation.c.CFRange,
    ) *text.Line {
        return @ptrFromInt(@intFromPtr(c.CTTypesetterCreateLine(
            @ptrCast(self),
            range,
        )));
    }
};
