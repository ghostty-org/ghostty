const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const foundation = @import("../foundation.zig");
const graphics = @import("../graphics.zig");
const text = @import("../text.zig");
const c = @import("c.zig");

pub const Font = opaque {
    pub fn createWithFontDescriptor(desc: *text.FontDescriptor, size: f32) Allocator.Error!*Font {
        return @as(
            ?*Font,
            @ptrFromInt(@intFromPtr(c.CTFontCreateWithFontDescriptor(
                @as(c.CTFontDescriptorRef, @ptrCast(desc)),
                size,
                null,
            ))),
        ) orelse Allocator.Error.OutOfMemory;
    }

    pub fn copyWithAttributes(self: *Font, size: f32, attrs: ?*text.FontDescriptor) Allocator.Error!*Font {
        return @as(
            ?*Font,
            @ptrFromInt(@intFromPtr(c.CTFontCreateCopyWithAttributes(
                @as(c.CTFontRef, @ptrCast(self)),
                size,
                null,
                @as(c.CTFontDescriptorRef, @ptrCast(attrs)),
            ))),
        ) orelse Allocator.Error.OutOfMemory;
    }

    pub fn release(self: *Font) void {
        c.CFRelease(self);
    }

    pub fn getGlyphsForCharacters(self: *Font, chars: []const u16, glyphs: []graphics.Glyph) bool {
        assert(chars.len == glyphs.len);
        return c.CTFontGetGlyphsForCharacters(
            @as(c.CTFontRef, @ptrCast(self)),
            chars.ptr,
            glyphs.ptr,
            @as(c_long, @intCast(chars.len)),
        );
    }

    pub fn drawGlyphs(
        self: *Font,
        glyphs: []const graphics.Glyph,
        positions: []const graphics.Point,
        context: anytype, // Must be some context type from graphics
    ) void {
        assert(positions.len == glyphs.len);
        c.CTFontDrawGlyphs(
            @as(c.CTFontRef, @ptrCast(self)),
            glyphs.ptr,
            @as([*]const c.struct_CGPoint, @ptrCast(positions.ptr)),
            glyphs.len,
            @as(c.CGContextRef, @ptrCast(context)),
        );
    }

    pub fn getBoundingRectForGlyphs(
        self: *Font,
        orientation: FontOrientation,
        glyphs: []const graphics.Glyph,
        rects: ?[]graphics.Rect,
    ) graphics.Rect {
        if (rects) |s| assert(glyphs.len == s.len);
        return @as(graphics.Rect, @bitCast(c.CTFontGetBoundingRectsForGlyphs(
            @as(c.CTFontRef, @ptrCast(self)),
            @intFromEnum(orientation),
            glyphs.ptr,
            @as(?[*]c.struct_CGRect, @ptrCast(if (rects) |s| s.ptr else null)),
            @as(c_long, @intCast(glyphs.len)),
        )));
    }

    pub fn getAdvancesForGlyphs(
        self: *Font,
        orientation: FontOrientation,
        glyphs: []const graphics.Glyph,
        advances: ?[]graphics.Size,
    ) f64 {
        if (advances) |s| assert(glyphs.len == s.len);
        return c.CTFontGetAdvancesForGlyphs(
            @as(c.CTFontRef, @ptrCast(self)),
            @intFromEnum(orientation),
            glyphs.ptr,
            @as(?[*]c.struct_CGSize, @ptrCast(if (advances) |s| s.ptr else null)),
            @as(c_long, @intCast(glyphs.len)),
        );
    }

    pub fn copyAttribute(self: *Font, comptime attr: text.FontAttribute) attr.Value() {
        return @as(attr.Value(), @ptrFromInt(@intFromPtr(c.CTFontCopyAttribute(
            @as(c.CTFontRef, @ptrCast(self)),
            @as(c.CFStringRef, @ptrCast(attr.key())),
        ))));
    }

    pub fn copyDisplayName(self: *Font) *foundation.String {
        return @as(
            *foundation.String,
            @ptrFromInt(@intFromPtr(c.CTFontCopyDisplayName(@as(c.CTFontRef, @ptrCast(self))))),
        );
    }

    pub fn getSymbolicTraits(self: *Font) text.FontSymbolicTraits {
        return @as(text.FontSymbolicTraits, @bitCast(c.CTFontGetSymbolicTraits(
            @as(c.CTFontRef, @ptrCast(self)),
        )));
    }

    pub fn getAscent(self: *Font) f64 {
        return c.CTFontGetAscent(@as(c.CTFontRef, @ptrCast(self)));
    }

    pub fn getDescent(self: *Font) f64 {
        return c.CTFontGetDescent(@as(c.CTFontRef, @ptrCast(self)));
    }

    pub fn getLeading(self: *Font) f64 {
        return c.CTFontGetLeading(@as(c.CTFontRef, @ptrCast(self)));
    }

    pub fn getBoundingBox(self: *Font) graphics.Rect {
        return @as(graphics.Rect, @bitCast(c.CTFontGetBoundingBox(@as(c.CTFontRef, @ptrCast(self)))));
    }

    pub fn getUnderlinePosition(self: *Font) f64 {
        return c.CTFontGetUnderlinePosition(@as(c.CTFontRef, @ptrCast(self)));
    }

    pub fn getUnderlineThickness(self: *Font) f64 {
        return c.CTFontGetUnderlineThickness(@as(c.CTFontRef, @ptrCast(self)));
    }
};

pub const FontOrientation = enum(c_uint) {
    default = c.kCTFontOrientationDefault,
    horizontal = c.kCTFontOrientationHorizontal,
    vertical = c.kCTFontOrientationVertical,
};

test {
    const testing = std.testing;

    const name = try foundation.String.createWithBytes("Monaco", .utf8, false);
    defer name.release();
    const desc = try text.FontDescriptor.createWithNameAndSize(name, 12);
    defer desc.release();

    const font = try Font.createWithFontDescriptor(desc, 12);
    defer font.release();

    // Traits
    {
        const traits = font.getSymbolicTraits();
        try testing.expect(!traits.color_glyphs);
    }

    var glyphs = [1]graphics.Glyph{0};
    try testing.expect(font.getGlyphsForCharacters(
        &[_]u16{'A'},
        &glyphs,
    ));
    try testing.expect(glyphs[0] > 0);

    // Bounding rect
    {
        var rect = font.getBoundingRectForGlyphs(.horizontal, &glyphs, null);
        try testing.expect(rect.size.width > 0);

        var singles: [1]graphics.Rect = undefined;
        rect = font.getBoundingRectForGlyphs(.horizontal, &glyphs, &singles);
        try testing.expect(rect.size.width > 0);
        try testing.expect(singles[0].size.width > 0);
    }

    // Advances
    {
        var advance = font.getAdvancesForGlyphs(.horizontal, &glyphs, null);
        try testing.expect(advance > 0);

        var singles: [1]graphics.Size = undefined;
        advance = font.getAdvancesForGlyphs(.horizontal, &glyphs, &singles);
        try testing.expect(advance > 0);
        try testing.expect(singles[0].width > 0);
    }

    // Draw
    {
        const cs = try graphics.ColorSpace.createDeviceGray();
        defer cs.release();
        const ctx = try graphics.BitmapContext.create(null, 80, 80, 8, 80, cs, 0);
        defer ctx.release();

        var pos = [_]graphics.Point{.{ .x = 0, .y = 0 }};
        font.drawGlyphs(
            &glyphs,
            &pos,
            ctx,
        );
    }
}

test "copy" {
    const name = try foundation.String.createWithBytes("Monaco", .utf8, false);
    defer name.release();
    const desc = try text.FontDescriptor.createWithNameAndSize(name, 12);
    defer desc.release();

    const font = try Font.createWithFontDescriptor(desc, 12);
    defer font.release();

    const f2 = try font.copyWithAttributes(14, null);
    defer f2.release();
}
