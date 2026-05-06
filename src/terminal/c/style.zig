const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const lib = @import("../lib.zig");
const style = @import("../style.zig");
const color = @import("../color.zig");
const sgr = @import("../sgr.zig");

/// C: GhosttyStyleColorTag
pub const ColorTag = enum(c_int) {
    none = 0,
    palette = 1,
    rgb = 2,
};

/// C: GhosttyStyleColorValue
pub const ColorValue = extern union {
    palette: u8,
    rgb: color.RGB.C,
    _padding: u64,
};

/// C: GhosttyStyleColor
pub const Color = extern struct {
    tag: ColorTag,
    value: ColorValue,

    pub fn fromColor(c: style.Style.Color) Color {
        return switch (c) {
            .none => .{
                .tag = .none,
                .value = .{ ._padding = 0 },
            },
            .palette => |idx| .{
                .tag = .palette,
                .value = .{ .palette = idx },
            },
            .rgb => |rgb| .{
                .tag = .rgb,
                .value = .{ .rgb = rgb.cval() },
            },
        };
    }
};

/// C: GhosttyStyle
pub const Style = extern struct {
    size: usize = @sizeOf(Style),
    fg_color: Color,
    bg_color: Color,
    underline_color: Color,
    bold: bool,
    italic: bool,
    faint: bool,
    blink: bool,
    inverse: bool,
    invisible: bool,
    strikethrough: bool,
    overline: bool,
    underline: c_int,

    pub fn fromStyle(s: style.Style) Style {
        return .{
            .fg_color = .fromColor(s.fg_color),
            .bg_color = .fromColor(s.bg_color),
            .underline_color = .fromColor(s.underline_color),
            .bold = s.flags.bold,
            .italic = s.flags.italic,
            .faint = s.flags.faint,
            .blink = s.flags.blink,
            .inverse = s.flags.inverse,
            .invisible = s.flags.invisible,
            .strikethrough = s.flags.strikethrough,
            .overline = s.flags.overline,
            .underline = @intFromEnum(s.flags.underline),
        };
    }
};

/// Returns the default style.
pub fn default_style(result: *Style) callconv(lib.calling_conv) void {
    result.* = .fromStyle(.{});
    assert(result.size == @sizeOf(Style));
}

/// Returns true if the style is the default style.
pub fn style_is_default(s: *const Style) callconv(lib.calling_conv) bool {
    assert(s.size == @sizeOf(Style));
    return s.fg_color.tag == .none and
        s.bg_color.tag == .none and
        s.underline_color.tag == .none and
        s.bold == false and
        s.italic == false and
        s.faint == false and
        s.blink == false and
        s.inverse == false and
        s.invisible == false and
        s.strikethrough == false and
        s.overline == false and
        s.underline == 0;
}

test "default style" {
    var s: Style = undefined;
    default_style(&s);
    try testing.expect(style_is_default(&s));
    try testing.expectEqual(ColorTag.none, s.fg_color.tag);
    try testing.expectEqual(ColorTag.none, s.bg_color.tag);
    try testing.expectEqual(ColorTag.none, s.underline_color.tag);
    try testing.expect(!s.bold);
    try testing.expect(!s.italic);
    try testing.expectEqual(@as(c_int, 0), s.underline);
}

test "convert style with colors" {
    const zig_style: style.Style = .{
        .fg_color = .{ .palette = 42 },
        .bg_color = .{ .rgb = .{ .r = 255, .g = 128, .b = 64 } },
        .underline_color = .none,
        .flags = .{ .bold = true, .underline = .curly },
    };

    const c_style: Style = .fromStyle(zig_style);
    try testing.expectEqual(ColorTag.palette, c_style.fg_color.tag);
    try testing.expectEqual(@as(u8, 42), c_style.fg_color.value.palette);
    try testing.expectEqual(ColorTag.rgb, c_style.bg_color.tag);
    try testing.expectEqual(@as(u8, 255), c_style.bg_color.value.rgb.r);
    try testing.expectEqual(@as(u8, 128), c_style.bg_color.value.rgb.g);
    try testing.expectEqual(@as(u8, 64), c_style.bg_color.value.rgb.b);
    try testing.expectEqual(ColorTag.none, c_style.underline_color.tag);
    try testing.expect(c_style.bold);
    try testing.expectEqual(@as(c_int, 3), c_style.underline);
    try testing.expect(!style_is_default(&c_style));
}
