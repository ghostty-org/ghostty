const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const foundation = @import("../foundation.zig");
const graphics = @import("../graphics.zig");
const text = @import("../text.zig");
const c = @import("c.zig").c;

pub const Font = opaque {
    pub fn createWithFontDescriptor(desc: *const text.FontDescriptor, size: f32) Allocator.Error!*Font {
        return @as(
            ?*Font,
            @ptrFromInt(@intFromPtr(c.CTFontCreateWithFontDescriptor(
                @ptrCast(desc),
                size,
                null,
            ))),
        ) orelse Allocator.Error.OutOfMemory;
    }

    pub fn createForString(
        self: *Font,
        str: *foundation.String,
        range: foundation.Range,
    ) ?*Font {
        return @ptrCast(@constCast(c.CTFontCreateForString(
            @ptrCast(self),
            @ptrCast(str),
            @bitCast(range),
        )));
    }

    pub fn copyWithAttributes(
        self: *Font,
        size: f32,
        matrix: ?*const graphics.AffineTransform,
        attrs: ?*text.FontDescriptor,
    ) Allocator.Error!*Font {
        return @as(
            ?*Font,
            @ptrFromInt(@intFromPtr(c.CTFontCreateCopyWithAttributes(
                @ptrCast(self),
                size,
                @ptrCast(matrix),
                @ptrCast(attrs),
            ))),
        ) orelse Allocator.Error.OutOfMemory;
    }

    pub fn release(self: *Font) void {
        c.CFRelease(self);
    }

    pub fn retain(self: *Font) void {
        _ = c.CFRetain(self);
    }

    pub fn copyDescriptor(self: *Font) *text.FontDescriptor {
        return @ptrCast(@constCast(c.CTFontCopyFontDescriptor(@ptrCast(self))));
    }

    pub fn copyFeatures(self: *Font) *foundation.Array {
        return @ptrCast(@constCast(c.CTFontCopyFeatures(@ptrCast(self))));
    }

    pub fn copyDefaultCascadeListForLanguages(self: *Font) *foundation.Array {
        return @ptrCast(@constCast(c.CTFontCopyDefaultCascadeListForLanguages(@ptrCast(self), null)));
    }

    pub fn copyTable(self: *Font, tag: FontTableTag) ?*foundation.Data {
        return @ptrCast(@constCast(c.CTFontCopyTable(
            @ptrCast(self),
            @intFromEnum(tag),
            c.kCTFontTableOptionNoOptions,
        )));
    }

    pub fn getGlyphCount(self: *Font) usize {
        return @intCast(c.CTFontGetGlyphCount(@ptrCast(self)));
    }

    pub fn getGlyphsForCharacters(self: *Font, chars: []const u16, glyphs: []graphics.Glyph) bool {
        assert(chars.len == glyphs.len);
        return c.CTFontGetGlyphsForCharacters(
            @ptrCast(self),
            chars.ptr,
            glyphs.ptr,
            @intCast(chars.len),
        );
    }

    pub fn createPathForGlyph(self: *Font, glyph: graphics.Glyph) ?*graphics.Path {
        return @ptrCast(@constCast(c.CTFontCreatePathForGlyph(
            @ptrCast(self),
            glyph,
            null,
        )));
    }

    pub fn drawGlyphs(
        self: *Font,
        glyphs: []const graphics.Glyph,
        positions: []const graphics.Point,
        context: anytype, // Must be some context type from graphics
    ) void {
        assert(positions.len == glyphs.len);
        c.CTFontDrawGlyphs(
            @ptrCast(self),
            glyphs.ptr,
            @ptrCast(positions.ptr),
            glyphs.len,
            @ptrCast(context),
        );
    }

    pub fn getBoundingRectsForGlyphs(
        self: *Font,
        orientation: FontOrientation,
        glyphs: []const graphics.Glyph,
        rects: ?[]graphics.Rect,
    ) graphics.Rect {
        if (rects) |s| assert(glyphs.len == s.len);
        return @bitCast(c.CTFontGetBoundingRectsForGlyphs(
            @ptrCast(self),
            @intFromEnum(orientation),
            glyphs.ptr,
            @ptrCast(if (rects) |s| s.ptr else null),
            @intCast(glyphs.len),
        ));
    }

    pub fn getAdvancesForGlyphs(
        self: *Font,
        orientation: FontOrientation,
        glyphs: []const graphics.Glyph,
        advances: ?[]graphics.Size,
    ) f64 {
        if (advances) |s| assert(glyphs.len == s.len);
        return c.CTFontGetAdvancesForGlyphs(
            @ptrCast(self),
            @intFromEnum(orientation),
            glyphs.ptr,
            @ptrCast(if (advances) |s| s.ptr else null),
            @intCast(glyphs.len),
        );
    }

    pub fn copyAttribute(self: *Font, comptime attr: text.FontAttribute) ?attr.Value() {
        return @ptrFromInt(@intFromPtr(c.CTFontCopyAttribute(
            @ptrCast(self),
            @ptrCast(attr.key()),
        )));
    }

    pub fn copyFamilyName(self: *Font) *foundation.String {
        return @ptrFromInt(@intFromPtr(c.CTFontCopyFamilyName(@ptrCast(self))));
    }

    pub fn copyDisplayName(self: *Font) *foundation.String {
        return @ptrFromInt(@intFromPtr(c.CTFontCopyDisplayName(@ptrCast(self))));
    }

    pub fn copyPostScriptName(self: *Font) *foundation.String {
        return @ptrFromInt(@intFromPtr(c.CTFontCopyPostScriptName(@ptrCast(self))));
    }

    pub fn getSymbolicTraits(self: *Font) text.FontSymbolicTraits {
        return @bitCast(c.CTFontGetSymbolicTraits(@ptrCast(self)));
    }

    pub fn getAscent(self: *Font) f64 {
        return c.CTFontGetAscent(@ptrCast(self));
    }

    pub fn getDescent(self: *Font) f64 {
        return c.CTFontGetDescent(@ptrCast(self));
    }

    pub fn getLeading(self: *Font) f64 {
        return c.CTFontGetLeading(@ptrCast(self));
    }

    pub fn getBoundingBox(self: *Font) graphics.Rect {
        return @bitCast(c.CTFontGetBoundingBox(@ptrCast(self)));
    }

    pub fn getUnderlinePosition(self: *Font) f64 {
        return c.CTFontGetUnderlinePosition(@ptrCast(self));
    }

    pub fn getUnderlineThickness(self: *Font) f64 {
        return c.CTFontGetUnderlineThickness(@ptrCast(self));
    }

    pub fn getCapHeight(self: *Font) f64 {
        return c.CTFontGetCapHeight(@ptrCast(self));
    }

    pub fn getXHeight(self: *Font) f64 {
        return c.CTFontGetXHeight(@ptrCast(self));
    }

    pub fn getUnitsPerEm(self: *Font) u32 {
        return c.CTFontGetUnitsPerEm(@ptrCast(self));
    }

    pub fn getSize(self: *Font) f64 {
        return c.CTFontGetSize(@ptrCast(self));
    }
};

pub const FontOrientation = enum(c_uint) {
    default = c.kCTFontOrientationDefault,
    horizontal = c.kCTFontOrientationHorizontal,
    vertical = c.kCTFontOrientationVertical,
};

pub const FontTableTag = enum(u32) {
    svg = c.kCTFontTableSVG,
    os2 = c.kCTFontTableOS2,
    head = c.kCTFontTableHead,
    hhea = c.kCTFontTableHhea,
    post = c.kCTFontTablePost,
    _,

    pub fn init(v: *const [4]u8) FontTableTag {
        const raw: u32 = @bitCast(foundation.FourCharCode.init(v));
        return @enumFromInt(raw);
    }
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
        var rect = font.getBoundingRectsForGlyphs(.horizontal, &glyphs, null);
        try testing.expect(rect.size.width > 0);

        var singles: [1]graphics.Rect = undefined;
        rect = font.getBoundingRectsForGlyphs(.horizontal, &glyphs, &singles);
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
        const context = graphics.BitmapContext.context;
        defer context.release(ctx);

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

    const f2 = try font.copyWithAttributes(14, null, null);
    defer f2.release();
}
