const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const testing = std.testing;
const lib = @import("../lib.zig");
const packed_lib = @import("../../lib/main.zig");
const style = @import("../style.zig");
const color = @import("../color.zig");
const sgr = @import("../sgr.zig");

/// C: GhosttyStyleColorTag
///
/// The C enum is int-sized, but GhosttyStyleColor stores the tag in a
/// single byte (`uint8_t tag`) so the color matches the internal 4-byte
/// layout.
pub const ColorTag = enum(c_int) {
    none = 0,
    palette = 1,
    rgb = 2,

    // The C tag byte is the internal tag byte, which requires the
    // internal and C tag values to line up.
    comptime {
        const Tag = style.Style.Color.Tag;
        for (@typeInfo(Tag).@"enum".field_names, @typeInfo(Tag).@"enum".field_values) |f, f_value| {
            assert(f_value == @backingInt(@field(ColorTag, f)));
        }
    }
};

/// C: GhosttyStyleColorValue
///
/// The three payload bytes of a style color. `palette` is byte 0 and
/// `rgb` is bytes 0 to 2 (r, g, b). For a palette color bytes 1 and 2
/// are zero, and for no color all three are zero.
pub const ColorValue = extern union {
    palette: u8,
    rgb: color.RGB.C,
};

/// C: GhosttyStyleColor
///
/// Four bytes: the tag byte followed by the payload. This is the
/// little-endian byte layout of the internal `Style.Color`
/// `packed struct(u32)`.
pub const Color = extern struct {
    /// One of GhosttyStyleColorTag, stored as a byte.
    tag: u8,
    value: ColorValue,

    /// No color (GHOSTTY_STYLE_COLOR_NONE). All four bytes are zero.
    pub const none: Color = .{ .tag = 0, .value = .{ .rgb = .{ .r = 0, .g = 0, .b = 0 } } };

    comptime {
        assert(@sizeOf(Color) == 4);
        assert(@offsetOf(Color, "tag") == 0);
        assert(@offsetOf(Color, "value") == 1);
        assert(@sizeOf(ColorValue) == 3);
        assert(@bitOffsetOf(style.Style.Color, "tag") == 0);
        assert(@bitOffsetOf(style.Style.Color, "data") == 8);
    }

    /// Convert an internal color without relying on byte order.
    fn fromColor(c: style.Style.Color) Color {
        var result: Color = undefined;
        const bytes: *[4]u8 = @ptrCast(&result);
        bytes[0] = @backingInt(c.tag);
        bytes[1] = @truncate(c.data);
        bytes[2] = @truncate(c.data >> 8);
        bytes[3] = @truncate(c.data >> 16);
        return result;
    }
};

/// C: GhosttyStyleFlags
///
/// This is the internal `Style.Flags` packed struct itself, so the C
/// field and the core field share one definition. Its bit positions
/// are now part of the ABI, so they are pinned here. They must match
/// the GHOSTTY_STYLE_FLAG_* and GHOSTTY_STYLE_UNDERLINE_* macros in
/// style.h.
pub const Flags = @FieldType(style.Style, "flags");

comptime {
    for ([_][]const u8{
        "bold",    "italic",    "faint",         "blink",
        "inverse", "invisible", "strikethrough", "overline",
    }, 0..) |name, bit| {
        assert(@bitOffsetOf(Flags, name) == bit);
    }
    assert(@bitOffsetOf(Flags, "underline") == 8);
    assert(@bitSizeOf(sgr.Attribute.Underline) == 3);
    assert(@bitOffsetOf(Flags, "_padding") == 11);
}

/// The GhosttyStyleFlags entry in the type manifest. The padding bits
/// are left out because they are reserved.
pub const FlagsLayout = packed_lib.Packed(Flags, .{ .fields = .{
    .underline = .{ .type_name = "GhosttySgrUnderline" },
    ._padding = .{ .omit = true },
} });

/// C: GhosttyStyle
///
/// A frozen 16-byte layout. On little-endian targets it is bit-identical
/// to the internal `Style` `packed struct(u128)` with its padding bits
/// cleared, so converting a style is a single 16-byte store. Reserved
/// bits are always zero. Adding style attributes requires a new type.
pub const Style = extern struct {
    fg_color: Color,
    bg_color: Color,
    underline_color: Color,

    /// Text attributes and underline style. `_padding` is reserved.
    flags: Flags,

    /// Reserved, always zero.
    reserved: u16,

    /// The default (empty) style: all zero.
    pub const default: Style = .{
        .fg_color = .none,
        .bg_color = .none,
        .underline_color = .none,
        .flags = .{},
        .reserved = 0,
    };

    /// The bits of the C layout that are reserved and must be zero, as
    /// they appear when the struct is viewed as a native u128.
    const reserved_bits: u128 = bits: {
        var s: Style = .default;
        s.flags = .{ ._padding = std.math.maxInt(u5) };
        s.reserved = 0xFFFF;
        break :bits s.toBits();
    };

    /// The struct as a native u128. Zig does not allow @bitCast on an
    /// extern struct, but the struct has no padding so reading it as an
    /// integer is well defined.
    fn toBits(self: *const Style) u128 {
        return @as(*align(@alignOf(Style)) const u128, @ptrCast(self)).*;
    }

    const little_endian = builtin.target.cpu.arch.endian() == .little;

    // The frozen layout must match the internal layout byte for byte
    // on little-endian targets.
    comptime {
        assert(@sizeOf(Style) == 16);
        assert(@sizeOf(Style) == @sizeOf(style.Style));
        assert(@offsetOf(Style, "fg_color") == 0);
        assert(@offsetOf(Style, "bg_color") == 4);
        assert(@offsetOf(Style, "underline_color") == 8);
        assert(@offsetOf(Style, "flags") == 12);
        assert(@offsetOf(Style, "reserved") == 14);
        for ([_][]const u8{
            "fg_color", "bg_color", "underline_color", "flags",
        }) |name| {
            assert(@bitOffsetOf(style.Style, name) == @offsetOf(Style, name) * 8);
        }
        assert(@bitOffsetOf(style.Style, "_padding") == @offsetOf(Style, "reserved") * 8);
    }

    /// Write the C representation of the given style directly through
    /// the out pointer. The hot per-cell style read in the render
    /// state API uses this. On little-endian targets this is a single
    /// 16-byte store.
    pub fn write(s: style.Style, out: *Style) void {
        if (comptime little_endian) {
            // The core keeps its padding bits zero, but this is an ABI
            // promise, so we mask rather than rely on it.
            const bits: u128 = @bitCast(s);
            @as(*align(@alignOf(Style)) u128, @ptrCast(out)).* = bits & ~reserved_bits;
        } else {
            out.* = fromStylePortable(s);
        }
    }

    /// Return the C representation of the given style. Prefer `write`
    /// when the destination is already known.
    pub fn fromStyle(s: style.Style) Style {
        var result: Style = undefined;
        write(s, &result);
        return result;
    }

    /// Field by field conversion that does not depend on byte order.
    fn fromStylePortable(s: style.Style) Style {
        return .{
            .fg_color = .fromColor(s.fg_color),
            .bg_color = .fromColor(s.bg_color),
            .underline_color = .fromColor(s.underline_color),
            .flags = flags: {
                var f = s.flags;
                f._padding = 0;
                break :flags f;
            },
            .reserved = 0,
        };
    }
};

/// Sets the style to the default style, which is all zero bytes.
pub fn default_style(result: *Style) callconv(lib.calling_conv) void {
    result.* = .default;
}

/// Returns true if the style is the default style. Reserved bits are
/// ignored, so a caller that leaves garbage in them still gets the
/// right answer.
pub fn style_is_default(s: *const Style) callconv(lib.calling_conv) bool {
    return s.toBits() & ~Style.reserved_bits == 0;
}

test "default style" {
    var s: Style = undefined;
    default_style(&s);
    try testing.expect(style_is_default(&s));
    try testing.expectEqual(@as([16]u8, @splat(0)), std.mem.toBytes(s));
}

test "style write produces the frozen byte layout" {
    // Expected bytes are the little-endian layout. The portable path
    // is still checked against the fast path below on any target.
    if (comptime !Style.little_endian) return error.SkipZigTest;

    const with_padding = padding: {
        // Every padding bit set, plus bold so the flags are not empty.
        const flags_pad: u128 = 0x1F << (96 + 11);
        const style_pad: u128 = 0xFFFF << 112;
        break :padding @as(style.Style, @bitCast(flags_pad | style_pad | (1 << 96)));
    };
    const only_padding = padding: {
        const flags_pad: u128 = 0x1F << (96 + 11);
        const style_pad: u128 = 0xFFFF << 112;
        break :padding @as(style.Style, @bitCast(flags_pad | style_pad));
    };

    const cases = [_]struct { style.Style, [16]u8 }{
        .{ .{}, .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } },

        // Colors, every tag kind in every slot.
        .{ .{ .fg_color = .palette(42) }, .{ 1, 42, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } },
        .{ .{ .fg_color = .palette(255) }, .{ 1, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } },
        .{ .{ .fg_color = .rgb(.{ .r = 1, .g = 2, .b = 3 }) }, .{ 2, 1, 2, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } },
        .{ .{ .bg_color = .palette(7) }, .{ 0, 0, 0, 0, 1, 7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } },
        .{ .{ .bg_color = .rgb(.{ .r = 255, .g = 128, .b = 64 }) }, .{ 0, 0, 0, 0, 2, 255, 128, 64, 0, 0, 0, 0, 0, 0, 0, 0 } },
        .{ .{ .underline_color = .palette(9) }, .{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 9, 0, 0, 0, 0, 0, 0 } },
        .{ .{ .underline_color = .rgb(.{ .r = 10, .g = 20, .b = 30 }) }, .{ 0, 0, 0, 0, 0, 0, 0, 0, 2, 10, 20, 30, 0, 0, 0, 0 } },

        // Each flag on its own.
        .{ .{ .flags = .{ .bold = true } }, .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0 } },
        .{ .{ .flags = .{ .italic = true } }, .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0 } },
        .{ .{ .flags = .{ .faint = true } }, .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0, 0 } },
        .{ .{ .flags = .{ .blink = true } }, .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 8, 0, 0, 0 } },
        .{ .{ .flags = .{ .inverse = true } }, .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 16, 0, 0, 0 } },
        .{ .{ .flags = .{ .invisible = true } }, .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 32, 0, 0, 0 } },
        .{ .{ .flags = .{ .strikethrough = true } }, .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 64, 0, 0, 0 } },
        .{ .{ .flags = .{ .overline = true } }, .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 128, 0, 0, 0 } },

        // Every underline style.
        .{ .{ .flags = .{ .underline = .single } }, .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0 } },
        .{ .{ .flags = .{ .underline = .double } }, .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0 } },
        .{ .{ .flags = .{ .underline = .curly } }, .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0 } },
        .{ .{ .flags = .{ .underline = .dotted } }, .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4, 0, 0 } },
        .{ .{ .flags = .{ .underline = .dashed } }, .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5, 0, 0 } },

        // Everything at once.
        .{
            .{
                .fg_color = .rgb(.{ .r = 0xAA, .g = 0xBB, .b = 0xCC }),
                .bg_color = .palette(200),
                .underline_color = .rgb(.{ .r = 0xFF, .g = 0xFF, .b = 0xFF }),
                .flags = @bitCast(@as(u16, 0xFF) | (@as(u16, 5) << 8)),
            },
            .{ 2, 0xAA, 0xBB, 0xCC, 1, 200, 0, 0, 2, 0xFF, 0xFF, 0xFF, 0xFF, 5, 0, 0 },
        },

        // Internal padding bits never reach C.
        .{ with_padding, .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0 } },
        .{ only_padding, .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } },
    };

    for (cases) |case| {
        const s, const expected = case;

        var out: Style = undefined;
        Style.write(s, &out);
        try testing.expectEqual(expected, std.mem.toBytes(out));
        try testing.expectEqual(expected, std.mem.toBytes(Style.fromStylePortable(s)));
        try testing.expectEqual(
            std.mem.allEqual(u8, &expected, 0),
            style_is_default(&out),
        );
    }
}

test "style_is_default ignores reserved bits" {
    var s: Style = .default;
    s.reserved = 0xFFFF;
    s.flags = .{ ._padding = std.math.maxInt(u5) };
    try testing.expect(style_is_default(&s));
    s.flags.overline = true;
    try testing.expect(!style_is_default(&s));
}
