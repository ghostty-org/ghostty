const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const foundation = @import("../foundation.zig");
const graphics = @import("../graphics.zig");
const text = @import("../text.zig");
const c = @import("c.zig");

pub const Framesetter = opaque {
    pub fn createWithAttributedString(str: *foundation.AttributedString) Allocator.Error!*Framesetter {
        return @as(
            ?*Framesetter,
            @ptrFromInt(@intFromPtr(c.CTFramesetterCreateWithAttributedString(
                @ptrCast(str),
            ))),
        ) orelse Allocator.Error.OutOfMemory;
    }

    pub fn release(self: *Framesetter) void {
        foundation.CFRelease(self);
    }

    pub fn createFrame(
        self: *Framesetter,
        range: foundation.Range,
        path: *graphics.Path,
        attrs: ?*foundation.Dictionary,
    ) !*text.Frame {
        return @as(
            ?*text.Frame,
            @ptrFromInt(@intFromPtr(c.CTFramesetterCreateFrame(
                @ptrCast(self),
                @bitCast(range),
                @ptrCast(path),
                @ptrCast(attrs),
            ))),
        ) orelse error.FrameCreateFailed;
    }
};

test {
    const str = try foundation.MutableAttributedString.create(0);
    defer str.release();
    {
        const rep = try foundation.String.createWithBytes("hello", .utf8, false);
        defer rep.release();
        str.replaceString(foundation.Range.init(0, 0), rep);
    }

    const fs = try Framesetter.createWithAttributedString(@ptrCast(str));
    defer fs.release();

    const path = try graphics.Path.createWithRect(graphics.Rect.init(0, 0, 100, 200), null);
    defer path.release();
    const frame = try fs.createFrame(
        foundation.Range.init(0, 0),
        path,
        null,
    );
    defer frame.release();

    {
        var points: [1]graphics.Point = undefined;
        frame.getLineOrigins(foundation.Range.init(0, 1), &points);
    }
}
