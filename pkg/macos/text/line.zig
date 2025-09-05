const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const foundation = @import("../foundation.zig");
const graphics = @import("../graphics.zig");
const text = @import("../text.zig");
const c = @import("c.zig").c;

pub const Line = opaque {
    pub fn createWithAttributedString(str: *foundation.AttributedString) Allocator.Error!*Line {
        return @as(
            ?*Line,
            @ptrFromInt(@intFromPtr(c.CTLineCreateWithAttributedString(
                @ptrCast(str),
            ))),
        ) orelse Allocator.Error.OutOfMemory;
    }

    pub fn release(self: *Line) void {
        foundation.CFRelease(self);
    }

    pub fn getGlyphCount(self: *Line) usize {
        return @intCast(c.CTLineGetGlyphCount(
            @ptrCast(self),
        ));
    }

    pub fn getBoundsWithOptions(
        self: *Line,
        opts: LineBoundsOptions,
    ) graphics.Rect {
        return @bitCast(c.CTLineGetBoundsWithOptions(
            @ptrCast(self),
            @bitCast(opts),
        ));
    }

    pub fn getTypographicBounds(
        self: *Line,
        ascent: ?*f64,
        descent: ?*f64,
        leading: ?*f64,
    ) f64 {
        return c.CTLineGetTypographicBounds(
            @ptrCast(self),
            ascent,
            descent,
            leading,
        );
    }

    pub fn getGlyphRuns(self: *Line) *foundation.Array {
        return @ptrCast(@constCast(c.CTLineGetGlyphRuns(@ptrCast(self))));
    }
};

pub const LineBoundsOptions = packed struct {
    exclude_leading: bool = false,
    exclude_shifts: bool = false,
    hanging_punctuation: bool = false,
    glyph_path_bounds: bool = false,
    use_optical_bounds: bool = false,
    language_extents: bool = false,
    _padding: u58 = 0,

    test {
        try std.testing.expectEqual(
            @bitSizeOf(c.CTLineBoundsOptions),
            @bitSizeOf(LineBoundsOptions),
        );
    }

    test "bitcast" {
        const actual: c.CTLineBoundsOptions = c.kCTLineBoundsExcludeTypographicShifts |
            c.kCTLineBoundsUseOpticalBounds;
        const expected: LineBoundsOptions = .{
            .exclude_shifts = true,
            .use_optical_bounds = true,
        };

        try std.testing.expectEqual(actual, @as(c.CTLineBoundsOptions, @bitCast(expected)));
    }
};

test {
    @import("std").testing.refAllDecls(@This());
}

test "line" {
    const testing = std.testing;

    const font = font: {
        const name = try foundation.String.createWithBytes("Monaco", .utf8, false);
        defer name.release();
        const desc = try text.FontDescriptor.createWithNameAndSize(name, 12);
        defer desc.release();

        break :font try text.Font.createWithFontDescriptor(desc, 12);
    };
    defer font.release();

    const rep = try foundation.String.createWithBytes("hello", .utf8, false);
    defer rep.release();
    const str = try foundation.MutableAttributedString.create(rep.getLength());
    defer str.release();
    str.replaceString(foundation.Range.init(0, 0), rep);
    str.setAttribute(
        foundation.Range.init(0, rep.getLength()),
        text.StringAttribute.font,
        font,
    );

    const line = try Line.createWithAttributedString(@as(*foundation.AttributedString, @ptrCast(str)));
    defer line.release();

    try testing.expectEqual(@as(usize, 5), line.getGlyphCount());

    // TODO: this is a garbage value but should work...
    const bounds = line.getBoundsWithOptions(.{});
    _ = bounds;
    //std.log.warn("bounds={}", .{bounds});
}
