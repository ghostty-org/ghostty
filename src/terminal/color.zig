const colorpkg = @This();

const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const x11_color = @import("x11_color.zig");

/// The default palette.
pub const default: Palette = default: {
    var result: Palette = undefined;

    // Named values
    var i: u8 = 0;
    while (i < 16) : (i += 1) {
        result[i] = Name.default(@enumFromInt(i)) catch unreachable;
    }

    // Cube
    assert(i == 16);
    var r: u8 = 0;
    while (r < 6) : (r += 1) {
        var g: u8 = 0;
        while (g < 6) : (g += 1) {
            var b: u8 = 0;
            while (b < 6) : (b += 1) {
                result[i] = .{
                    .r = if (r == 0) 0 else (r * 40 + 55),
                    .g = if (g == 0) 0 else (g * 40 + 55),
                    .b = if (b == 0) 0 else (b * 40 + 55),
                };

                i += 1;
            }
        }
    }

    // Gray ramp
    assert(i == 232);
    assert(@TypeOf(i) == u8);
    while (i > 0) : (i +%= 1) {
        const value = ((i - 232) * 10) + 8;
        result[i] = .{ .r = value, .g = value, .b = value };
    }

    break :default result;
};

/// Palette is the 256 color palette.
pub const Palette = [256]RGB;

/// A palette that can have its colors changed and reset. Purposely built
/// for terminal color operations.
pub const DynamicPalette = struct {
    /// The current palette including any user modifications.
    current: Palette,

    /// The original/default palette values.
    original: Palette,

    /// A bitset where each bit represents whether the corresponding
    /// palette index has been modified from its default value.
    mask: Mask,

    const Mask = std.StaticBitSet(@typeInfo(Palette).array.len);

    pub const default: DynamicPalette = .init(colorpkg.default);

    /// Initialize a dynamic palette with a default palette.
    pub fn init(def: Palette) DynamicPalette {
        return .{
            .current = def,
            .original = def,
            .mask = .initEmpty(),
        };
    }

    /// Set a custom color at the given palette index.
    pub fn set(self: *DynamicPalette, idx: u8, color: RGB) void {
        self.current[idx] = color;
        self.mask.set(idx);
    }

    /// Reset the color at the given palette index to its original value.
    pub fn reset(self: *DynamicPalette, idx: u8) void {
        self.current[idx] = self.original[idx];
        self.mask.unset(idx);
    }

    /// Reset all colors to their original values.
    pub fn resetAll(self: *DynamicPalette) void {
        self.* = .init(self.original);
    }

    /// Change the default palette, but preserve the changed values.
    pub fn changeDefault(self: *DynamicPalette, def: Palette) void {
        self.original = def;

        // Fast path, the palette is usually not changed.
        if (self.mask.count() == 0) {
            self.current = self.original;
            return;
        }

        // There are usually less set than unset, so iterate over the changed
        // values and override them.
        var current = def;
        var it = self.mask.iterator(.{});
        while (it.next()) |idx| current[idx] = self.current[idx];
        self.current = current;
    }
};

/// RGB value that can be changed and reset. This can also be totally unset
/// in every way, in which case the caller can determine their own ultimate
/// default.
pub const DynamicRGB = struct {
    override: ?RGB,
    default: ?RGB,

    pub const unset: DynamicRGB = .{ .override = null, .default = null };

    pub fn init(def: RGB) DynamicRGB {
        return .{
            .override = null,
            .default = def,
        };
    }

    pub fn get(self: *const DynamicRGB) ?RGB {
        return self.override orelse self.default;
    }

    pub fn set(self: *DynamicRGB, color: RGB) void {
        self.override = color;
    }

    pub fn reset(self: *DynamicRGB) void {
        self.override = self.default;
    }
};

/// Color names in the standard 8 or 16 color palette.
pub const Name = enum(u8) {
    black = 0,
    red = 1,
    green = 2,
    yellow = 3,
    blue = 4,
    magenta = 5,
    cyan = 6,
    white = 7,

    bright_black = 8,
    bright_red = 9,
    bright_green = 10,
    bright_yellow = 11,
    bright_blue = 12,
    bright_magenta = 13,
    bright_cyan = 14,
    bright_white = 15,

    // Remainders are valid unnamed values in the 256 color palette.
    _,

    pub const C = u8;

    pub fn cval(self: Name) C {
        return @intFromEnum(self);
    }

    /// Default colors for tagged values.
    pub fn default(self: Name) !RGB {
        return switch (self) {
            .black => RGB{ .r = 0x1D, .g = 0x1F, .b = 0x21 },
            .red => RGB{ .r = 0xCC, .g = 0x66, .b = 0x66 },
            .green => RGB{ .r = 0xB5, .g = 0xBD, .b = 0x68 },
            .yellow => RGB{ .r = 0xF0, .g = 0xC6, .b = 0x74 },
            .blue => RGB{ .r = 0x81, .g = 0xA2, .b = 0xBE },
            .magenta => RGB{ .r = 0xB2, .g = 0x94, .b = 0xBB },
            .cyan => RGB{ .r = 0x8A, .g = 0xBE, .b = 0xB7 },
            .white => RGB{ .r = 0xC5, .g = 0xC8, .b = 0xC6 },

            .bright_black => RGB{ .r = 0x66, .g = 0x66, .b = 0x66 },
            .bright_red => RGB{ .r = 0xD5, .g = 0x4E, .b = 0x53 },
            .bright_green => RGB{ .r = 0xB9, .g = 0xCA, .b = 0x4A },
            .bright_yellow => RGB{ .r = 0xE7, .g = 0xC5, .b = 0x47 },
            .bright_blue => RGB{ .r = 0x7A, .g = 0xA6, .b = 0xDA },
            .bright_magenta => RGB{ .r = 0xC3, .g = 0x97, .b = 0xD8 },
            .bright_cyan => RGB{ .r = 0x70, .g = 0xC0, .b = 0xB1 },
            .bright_white => RGB{ .r = 0xEA, .g = 0xEA, .b = 0xEA },

            else => error.NoDefaultValue,
        };
    }
};

/// The "special colors" as denoted by xterm. These can be set via
/// OSC 5 or via OSC 4 by adding the palette length to it.
///
/// https://invisible-island.net/xterm/ctlseqs/ctlseqs.html
pub const Special = enum(u3) {
    bold = 0,
    underline = 1,
    blink = 2,
    reverse = 3,
    italic = 4,

    pub fn osc4(self: Special) u16 {
        // "The special colors can also be set by adding the maximum
        // number of colors (e.g., 88 or 256) to these codes in an
        // OSC 4  control" - xterm ctlseqs
        const max = @typeInfo(Palette).array.len;
        return @as(u16, @intCast(@intFromEnum(self))) + max;
    }

    test "osc4" {
        const testing = std.testing;
        try testing.expectEqual(256, Special.bold.osc4());
        try testing.expectEqual(257, Special.underline.osc4());
        try testing.expectEqual(258, Special.blink.osc4());
        try testing.expectEqual(259, Special.reverse.osc4());
        try testing.expectEqual(260, Special.italic.osc4());
    }
};

test Special {
    _ = Special;
}

/// The "dynamic colors" as denoted by xterm. These can be set via
/// OSC 10 through 19.
pub const Dynamic = enum(u5) {
    foreground = 10,
    background = 11,
    cursor = 12,
    pointer_foreground = 13,
    pointer_background = 14,
    tektronix_foreground = 15,
    tektronix_background = 16,
    highlight_background = 17,
    tektronix_cursor = 18,
    highlight_foreground = 19,

    /// The next dynamic color sequentially. This is required because
    /// specifying colors sequentially without their index will automatically
    /// use the next dynamic color.
    ///
    /// "Each successive parameter changes the next color in the list.  The
    /// value of Ps tells the starting point in the list."
    pub fn next(self: Dynamic) ?Dynamic {
        return std.meta.intToEnum(
            Dynamic,
            @intFromEnum(self) + 1,
        ) catch null;
    }

    test "next" {
        const testing = std.testing;
        try testing.expectEqual(.background, Dynamic.foreground.next());
        try testing.expectEqual(.cursor, Dynamic.background.next());
        try testing.expectEqual(.pointer_foreground, Dynamic.cursor.next());
        try testing.expectEqual(.pointer_background, Dynamic.pointer_foreground.next());
        try testing.expectEqual(.tektronix_foreground, Dynamic.pointer_background.next());
        try testing.expectEqual(.tektronix_background, Dynamic.tektronix_foreground.next());
        try testing.expectEqual(.highlight_background, Dynamic.tektronix_background.next());
        try testing.expectEqual(.tektronix_cursor, Dynamic.highlight_background.next());
        try testing.expectEqual(.highlight_foreground, Dynamic.tektronix_cursor.next());
        try testing.expectEqual(null, Dynamic.highlight_foreground.next());
    }
};

test Dynamic {
    _ = Dynamic;
}

/// RGB
pub const RGB = packed struct(u24) {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,

    pub const C = extern struct {
        r: u8,
        g: u8,
        b: u8,
    };

    pub fn cval(self: RGB) C {
        return .{
            .r = self.r,
            .g = self.g,
            .b = self.b,
        };
    }

    pub fn eql(self: RGB, other: RGB) bool {
        return self.r == other.r and self.g == other.g and self.b == other.b;
    }

    /// Calculates the contrast ratio between two colors. The contrast
    /// ration is a value between 1 and 21 where 1 is the lowest contrast
    /// and 21 is the highest contrast.
    ///
    /// https://www.w3.org/TR/WCAG20/#contrast-ratiodef
    pub fn contrast(self: RGB, other: RGB) f64 {
        // pair[0] = lighter, pair[1] = darker
        const pair: [2]f64 = pair: {
            const self_lum = self.luminance();
            const other_lum = other.luminance();
            if (self_lum > other_lum) break :pair .{ self_lum, other_lum };
            break :pair .{ other_lum, self_lum };
        };

        return (pair[0] + 0.05) / (pair[1] + 0.05);
    }

    /// Calculates luminance based on the W3C formula. This returns a
    /// normalized value between 0 and 1 where 0 is black and 1 is white.
    ///
    /// https://www.w3.org/TR/WCAG20/#relativeluminancedef
    pub fn luminance(self: RGB) f64 {
        const r_lum = componentLuminance(self.r);
        const g_lum = componentLuminance(self.g);
        const b_lum = componentLuminance(self.b);
        return 0.2126 * r_lum + 0.7152 * g_lum + 0.0722 * b_lum;
    }

    /// Calculates single-component luminance based on the W3C formula.
    ///
    /// Expects sRGB color space which at the time of writing we don't
    /// generally use but it's a good enough approximation until we fix that.
    /// https://www.w3.org/TR/WCAG20/#relativeluminancedef
    fn componentLuminance(c: u8) f64 {
        const c_f64: f64 = @floatFromInt(c);
        const normalized: f64 = c_f64 / 255;
        if (normalized <= 0.03928) return normalized / 12.92;
        return std.math.pow(f64, (normalized + 0.055) / 1.055, 2.4);
    }

    /// Calculates "perceived luminance" which is better for determining
    /// light vs dark.
    ///
    /// Source: https://www.w3.org/TR/AERT/#color-contrast
    pub fn perceivedLuminance(self: RGB) f64 {
        const r_f64: f64 = @floatFromInt(self.r);
        const g_f64: f64 = @floatFromInt(self.g);
        const b_f64: f64 = @floatFromInt(self.b);
        return 0.299 * (r_f64 / 255) + 0.587 * (g_f64 / 255) + 0.114 * (b_f64 / 255);
    }

    comptime {
        assert(@bitSizeOf(RGB) == 24);
        assert(@sizeOf(RGB) == 4);
    }

    /// Parse a color from a floating point intensity value.
    ///
    /// The value should be between 0.0 and 1.0, inclusive.
    fn fromIntensity(value: []const u8) !u8 {
        const i = std.fmt.parseFloat(f64, value) catch {
            @branchHint(.cold);
            return error.InvalidFormat;
        };
        if (i < 0.0 or i > 1.0) {
            @branchHint(.cold);
            return error.InvalidFormat;
        }

        return @intFromFloat(i * std.math.maxInt(u8));
    }

    /// Parse a color from a string of hexadecimal digits
    ///
    /// The string can contain 1, 2, 3, or 4 characters and represents the color
    /// value scaled in 4, 8, 12, or 16 bits, respectively.
    fn fromHex(value: []const u8) !u8 {
        if (value.len == 0 or value.len > 4) {
            @branchHint(.cold);
            return error.InvalidFormat;
        }

        const color = std.fmt.parseUnsigned(u16, value, 16) catch {
            @branchHint(.cold);
            return error.InvalidFormat;
        };

        const divisor: usize = switch (value.len) {
            1 => std.math.maxInt(u4),
            2 => std.math.maxInt(u8),
            3 => std.math.maxInt(u12),
            4 => std.math.maxInt(u16),
            else => unreachable,
        };

        return @intCast(@as(usize, color) * std.math.maxInt(u8) / divisor);
    }

    /// Parse a color specification.
    ///
    /// Any of the following forms are accepted:
    ///
    /// 1. rgb:<red>/<green>/<blue>
    ///
    ///    <red>, <green>, <blue> := h | hh | hhh | hhhh
    ///
    ///    where `h` is a single hexadecimal digit.
    ///
    /// 2. rgbi:<red>/<green>/<blue>
    ///
    ///    where <red>, <green>, and <blue> are floating point values between
    ///    0.0 and 1.0 (inclusive).
    ///
    /// 3. #rgb, #rrggbb, #rrrgggbbb #rrrrggggbbbb
    ///
    ///    where `r`, `g`, and `b` are a single hexadecimal digit.
    ///    These specify a color with 4, 8, 12, and 16 bits of precision
    ///    per color channel.
    pub fn parse(value: []const u8) !RGB {
        if (value.len == 0) {
            @branchHint(.cold);
            return error.InvalidFormat;
        }

        if (value[0] == '#') {
            switch (value.len) {
                4 => return RGB{
                    .r = try RGB.fromHex(value[1..2]),
                    .g = try RGB.fromHex(value[2..3]),
                    .b = try RGB.fromHex(value[3..4]),
                },
                7 => return RGB{
                    .r = try RGB.fromHex(value[1..3]),
                    .g = try RGB.fromHex(value[3..5]),
                    .b = try RGB.fromHex(value[5..7]),
                },
                10 => return RGB{
                    .r = try RGB.fromHex(value[1..4]),
                    .g = try RGB.fromHex(value[4..7]),
                    .b = try RGB.fromHex(value[7..10]),
                },
                13 => return RGB{
                    .r = try RGB.fromHex(value[1..5]),
                    .g = try RGB.fromHex(value[5..9]),
                    .b = try RGB.fromHex(value[9..13]),
                },

                else => {
                    @branchHint(.cold);
                    return error.InvalidFormat;
                },
            }
        }

        // Check for X11 named colors. We allow whitespace around the edges
        // of the color because Kitty allows whitespace. This is not part of
        // any spec I could find.
        if (x11_color.map.get(std.mem.trim(u8, value, " "))) |rgb| return rgb;

        if (value.len < "rgb:a/a/a".len or !std.mem.eql(u8, value[0..3], "rgb")) {
            @branchHint(.cold);
            return error.InvalidFormat;
        }

        var i: usize = 3;

        const use_intensity = if (value[i] == 'i') blk: {
            i += 1;
            break :blk true;
        } else false;

        if (value[i] != ':') {
            @branchHint(.cold);
            return error.InvalidFormat;
        }

        i += 1;

        const r = r: {
            const slice = if (std.mem.indexOfScalarPos(u8, value, i, '/')) |end|
                value[i..end]
            else {
                @branchHint(.cold);
                return error.InvalidFormat;
            };

            i += slice.len + 1;

            break :r if (use_intensity)
                try RGB.fromIntensity(slice)
            else
                try RGB.fromHex(slice);
        };

        const g = g: {
            const slice = if (std.mem.indexOfScalarPos(u8, value, i, '/')) |end|
                value[i..end]
            else {
                @branchHint(.cold);
                return error.InvalidFormat;
            };

            i += slice.len + 1;

            break :g if (use_intensity)
                try RGB.fromIntensity(slice)
            else
                try RGB.fromHex(slice);
        };

        const b = if (use_intensity)
            try RGB.fromIntensity(value[i..])
        else
            try RGB.fromHex(value[i..]);

        return RGB{
            .r = r,
            .g = g,
            .b = b,
        };
    }
};

test "palette: default" {
    const testing = std.testing;

    // Safety check
    var i: u8 = 0;
    while (i < 16) : (i += 1) {
        try testing.expectEqual(Name.default(@as(Name, @enumFromInt(i))), default[i]);
    }
}

test "RGB.parse" {
    const testing = std.testing;

    try testing.expectEqual(RGB{ .r = 255, .g = 0, .b = 0 }, try RGB.parse("rgbi:1.0/0/0"));
    try testing.expectEqual(RGB{ .r = 127, .g = 160, .b = 0 }, try RGB.parse("rgb:7f/a0a0/0"));
    try testing.expectEqual(RGB{ .r = 255, .g = 255, .b = 255 }, try RGB.parse("rgb:f/ff/fff"));
    try testing.expectEqual(RGB{ .r = 255, .g = 255, .b = 255 }, try RGB.parse("#ffffff"));
    try testing.expectEqual(RGB{ .r = 255, .g = 255, .b = 255 }, try RGB.parse("#fff"));
    try testing.expectEqual(RGB{ .r = 255, .g = 255, .b = 255 }, try RGB.parse("#fffffffff"));
    try testing.expectEqual(RGB{ .r = 255, .g = 255, .b = 255 }, try RGB.parse("#ffffffffffff"));
    try testing.expectEqual(RGB{ .r = 255, .g = 0, .b = 16 }, try RGB.parse("#ff0010"));

    try testing.expectEqual(RGB{ .r = 0, .g = 0, .b = 0 }, try RGB.parse("black"));
    try testing.expectEqual(RGB{ .r = 255, .g = 0, .b = 0 }, try RGB.parse("red"));
    try testing.expectEqual(RGB{ .r = 0, .g = 255, .b = 0 }, try RGB.parse("green"));
    try testing.expectEqual(RGB{ .r = 0, .g = 0, .b = 255 }, try RGB.parse("blue"));
    try testing.expectEqual(RGB{ .r = 255, .g = 255, .b = 255 }, try RGB.parse("white"));

    try testing.expectEqual(RGB{ .r = 124, .g = 252, .b = 0 }, try RGB.parse("LawnGreen"));
    try testing.expectEqual(RGB{ .r = 0, .g = 250, .b = 154 }, try RGB.parse("medium spring green"));
    try testing.expectEqual(RGB{ .r = 34, .g = 139, .b = 34 }, try RGB.parse(" Forest Green "));

    // Invalid format
    try testing.expectError(error.InvalidFormat, RGB.parse("rgb;"));
    try testing.expectError(error.InvalidFormat, RGB.parse("rgb:"));
    try testing.expectError(error.InvalidFormat, RGB.parse(":a/a/a"));
    try testing.expectError(error.InvalidFormat, RGB.parse("a/a/a"));
    try testing.expectError(error.InvalidFormat, RGB.parse("rgb:a/a/a/"));
    try testing.expectError(error.InvalidFormat, RGB.parse("rgb:00000///"));
    try testing.expectError(error.InvalidFormat, RGB.parse("rgb:000/"));
    try testing.expectError(error.InvalidFormat, RGB.parse("rgbi:a/a/a"));
    try testing.expectError(error.InvalidFormat, RGB.parse("rgb:0.5/0.0/1.0"));
    try testing.expectError(error.InvalidFormat, RGB.parse("rgb:not/hex/zz"));
    try testing.expectError(error.InvalidFormat, RGB.parse("#"));
    try testing.expectError(error.InvalidFormat, RGB.parse("#ff"));
    try testing.expectError(error.InvalidFormat, RGB.parse("#ffff"));
    try testing.expectError(error.InvalidFormat, RGB.parse("#fffff"));
    try testing.expectError(error.InvalidFormat, RGB.parse("#gggggg"));
}

test "DynamicPalette: init" {
    const testing = std.testing;

    var p: DynamicPalette = .init(default);
    try testing.expectEqual(default, p.current);
    try testing.expectEqual(default, p.original);
    try testing.expectEqual(@as(usize, 0), p.mask.count());
}

test "DynamicPalette: set" {
    const testing = std.testing;

    var p: DynamicPalette = .init(default);
    const new_color = RGB{ .r = 255, .g = 0, .b = 0 };

    p.set(0, new_color);
    try testing.expectEqual(new_color, p.current[0]);
    try testing.expect(p.mask.isSet(0));
    try testing.expectEqual(@as(usize, 1), p.mask.count());

    try testing.expectEqual(default[0], p.original[0]);
}

test "DynamicPalette: reset" {
    const testing = std.testing;

    var p: DynamicPalette = .init(default);
    const new_color = RGB{ .r = 255, .g = 0, .b = 0 };

    p.set(0, new_color);
    try testing.expect(p.mask.isSet(0));

    p.reset(0);
    try testing.expectEqual(default[0], p.current[0]);
    try testing.expect(!p.mask.isSet(0));
    try testing.expectEqual(@as(usize, 0), p.mask.count());
}

test "DynamicPalette: resetAll" {
    const testing = std.testing;

    var p: DynamicPalette = .init(default);
    const new_color = RGB{ .r = 255, .g = 0, .b = 0 };

    p.set(0, new_color);
    p.set(5, new_color);
    p.set(10, new_color);
    try testing.expectEqual(@as(usize, 3), p.mask.count());

    p.resetAll();
    try testing.expectEqual(default, p.current);
    try testing.expectEqual(default, p.original);
    try testing.expectEqual(@as(usize, 0), p.mask.count());
}

test "DynamicPalette: changeDefault with no changes" {
    const testing = std.testing;

    var p: DynamicPalette = .init(default);
    var new_palette = default;
    new_palette[0] = RGB{ .r = 100, .g = 100, .b = 100 };

    p.changeDefault(new_palette);
    try testing.expectEqual(new_palette, p.original);
    try testing.expectEqual(new_palette, p.current);
    try testing.expectEqual(@as(usize, 0), p.mask.count());
}

test "DynamicPalette: changeDefault preserves changes" {
    const testing = std.testing;

    var p: DynamicPalette = .init(default);
    const custom_color = RGB{ .r = 255, .g = 0, .b = 0 };

    p.set(5, custom_color);
    try testing.expect(p.mask.isSet(5));

    var new_palette = default;
    new_palette[0] = RGB{ .r = 100, .g = 100, .b = 100 };
    new_palette[5] = RGB{ .r = 50, .g = 50, .b = 50 };

    p.changeDefault(new_palette);

    try testing.expectEqual(new_palette, p.original);
    try testing.expectEqual(new_palette[0], p.current[0]);
    try testing.expectEqual(custom_color, p.current[5]);
    try testing.expect(p.mask.isSet(5));
    try testing.expectEqual(@as(usize, 1), p.mask.count());
}

test "DynamicPalette: changeDefault with multiple changes" {
    const testing = std.testing;

    var p: DynamicPalette = .init(default);
    const red = RGB{ .r = 255, .g = 0, .b = 0 };
    const green = RGB{ .r = 0, .g = 255, .b = 0 };
    const blue = RGB{ .r = 0, .g = 0, .b = 255 };

    p.set(1, red);
    p.set(2, green);
    p.set(3, blue);

    var new_palette = default;
    new_palette[0] = RGB{ .r = 50, .g = 50, .b = 50 };
    new_palette[1] = RGB{ .r = 60, .g = 60, .b = 60 };

    p.changeDefault(new_palette);

    try testing.expectEqual(new_palette[0], p.current[0]);
    try testing.expectEqual(red, p.current[1]);
    try testing.expectEqual(green, p.current[2]);
    try testing.expectEqual(blue, p.current[3]);
    try testing.expectEqual(@as(usize, 3), p.mask.count());
}
