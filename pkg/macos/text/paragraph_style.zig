const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const foundation = @import("../foundation.zig");
const graphics = @import("../graphics.zig");
const text = @import("../text.zig");
const c = @import("c");

// https://developer.apple.com/documentation/coretext/ctparagraphstyle?language=objc
pub const ParagraphStyle = opaque {
    pub fn create(
        settings: []const ParagraphStyleSetting,
    ) Allocator.Error!*ParagraphStyle {
        return @ptrCast(@constCast(c.CTParagraphStyleCreate(
            @ptrCast(settings.ptr),
            settings.len,
        )));
    }

    pub fn release(self: *ParagraphStyle) void {
        foundation.CFRelease(self);
    }
};

/// https://developer.apple.com/documentation/coretext/ctparagraphstylesetting?language=objc
pub const ParagraphStyleSetting = extern struct {
    spec: ParagraphStyleSpecifier,
    value_size: usize,
    value: *const anyopaque,
};

/// https://developer.apple.com/documentation/coretext/ctparagraphstylespecifier?language=objc
pub const ParagraphStyleSpecifier = enum(c_uint) {
    base_writing_direction = 13,
};

/// https://developer.apple.com/documentation/uikit/nswritingdirectionattributename?language=objc
pub const WritingDirection = enum(c_int) {
    natural = -1,
    ltr = 0,
    rtl = 1,
    lro = 2,
    rlo = 3,
};

test ParagraphStyle {
    const p = try ParagraphStyle.create(&.{});
    defer p.release();
}
