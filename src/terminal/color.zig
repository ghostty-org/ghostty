const std = @import("std");
const assert = std.debug.assert;

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

    // Grey ramp
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

///  HSL color representation used for minimum contrast calculations
const HSL = struct {
    h: u9 = 0, // 0-360
    s: f32 = 0, // 0-1
    l: f32 = 0, // 0-1

    pub fn fromRGB(rgb: RGB) HSL {
        const r: f32 = @as(f32, @floatFromInt(rgb.r)) / 255.0;
        const g: f32 = @as(f32, @floatFromInt(rgb.g)) / 255.0;
        const b: f32 = @as(f32, @floatFromInt(rgb.b)) / 255.0;

        const max_val: f32 = @max(@max(r, g), b);
        const min_val: f32 = @min(@min(r, g), b);

        var h: f32 = 0; // undefined, but commonly set to 0
        var s: f32 = 0;
        const lum: f32 = (max_val + min_val) / 2;

        if (max_val != min_val) {
            const delta = max_val - min_val;
            s = delta / (1 - @abs(2 * lum - 1));

            if (max_val == r) {
                h = (g - b) / delta;
            } else if (max_val == g) {
                h = 2 + (b - r) / delta;
            } else if (max_val == b) {
                // h = 60 * (4 + (r - g) / delta)
                h = 4 + (r - g) / delta;
            }
            h *= 60;
        }

        return HSL{
            // .h = (h + 360.0) % 360, // Ensure the hue is in the range [0, 360]
            .h = @intFromFloat(@mod(h + 360.0, 360)), // Ensure the hue is in the range [0, 360]
            .s = s,
            .l = lum,
        };
    }

    fn hue_to_rgb(p: f32, q: f32, t: f32) u8 {
        var mul: f32 = 0;
        if (t < 1 / 6) {
            mul = p + (q - p) * 6 * t;
        } else if (t < 0.5) {
            mul = q;
        } else if (t < 2 / 3) {
            mul = p + (q - p) * (2 / 3 - t) * 6;
        } else {
            mul = p;
        }
        return @intFromFloat(mul * 255);
    }

    pub fn toRGB(self: HSL) RGB {
        if (self.s == 0) {
            // no saturation, so greyscale
            const lum: u8 = @intFromFloat(self.l * 255);
            return RGB{ .r = lum, .g = lum, .b = lum };
        }

        var q: f32 = 0;
        if (self.l < 0.5) {
            q = self.l * (1 + self.s);
        } else {
            q = self.l + self.s - self.l * self.s;
        }

        const p = 2 * self.l - q;
        const h: f32 = @as(f32, @floatFromInt(self.h)) / 255.0;

        return RGB{
            .r = hue_to_rgb(p, q, h + 1 / 3),
            .g = hue_to_rgb(p, q, h),
            .b = hue_to_rgb(p, q, h - 1 / 3),
        };
    }
};

/// RGB
pub const RGB = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,

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

    /// If the contrast between self and fg is less than min_contrast_pct percent,
    /// adjust fg's color away from self until it is at least that
    /// else leave unchanged
    pub fn minContrastWith(self: RGB, fg: RGB, min_contrast_pct: u7) RGB {
        if (min_contrast_pct == 0) return fg;
        const increase: bool = self.luminance() < fg.luminance();
        return self.minContrastColor(min_contrast_pct, increase);
    }

    /// Binary search in the specified direction for the color with the
    /// specified minimum contrast percentage
    pub fn minContrastColor(self: RGB, min_contrast_pct: u7, increase: bool) RGB {
        const min_contrast: f64 = @as(f64, @floatFromInt(min_contrast_pct)) / 5 + 1;
        // std.log.info("minConstrastColor({}, {}, {})", .{ self, min_contrast, increase });

        const black_or_white = RGB{
            .r = if (increase) 255 else 0,
            .g = if (increase) 255 else 0,
            .b = if (increase) 255 else 0,
        };
        const max_contrast = self.contrast(black_or_white);
        if (max_contrast <= min_contrast) {
            // std.log.info("max_contrast is {}, so returning {}", .{ max_contrast, black_or_white });
            return black_or_white;
        }

        // ideally we could compute the color, but color math is hard, so search instead
        var left: RGB = if (increase) self.clone() else black_or_white;
        var right = if (increase) black_or_white else self.clone();
        while (left.cmp(right) == .lt) {
            const mid = left.colorHalfwayToward(right);
            const mid_contrast = self.contrast(mid);
            // std.log.info("left: {} right: {} mid: {} with contrast {}", .{ left, right, mid, mid_contrast });
            if (mid.eql(left) or mid.eql(right)) break;
            if (mid_contrast == min_contrast) {
                // std.log.info("Exact contrast found! How unlikely! returning {}", .{mid});
                return mid;
            } else if (mid_contrast < min_contrast) {
                // std.log.info("contrast too low", .{});
                if (increase) {
                    // std.log.info("changing left", .{});
                    left = mid;
                } else {
                    // std.log.info("changing right", .{});
                    right = mid;
                }
            } else {
                // std.log.info("contrast too high", .{});
                if (increase) {
                    // std.log.info("changing right", .{});
                    right = mid;
                } else {
                    // std.log.info("changing left", .{});
                    left = mid;
                }
            }
        }
        // std.log.info("Contrast found. returning {}", .{if (increase) right else left});
        return if (increase) right else left;
    }

    fn cmp(self: RGB, other: RGB) ?std.math.Order {
        if (self.eql(other)) {
            return .eq;
        }
        if (self.r <= other.r and
            self.g <= other.g and
            self.b <= other.b)
        {
            return .lt;
        }
        if (self.r >= other.r and
            self.g >= other.g and
            self.b >= other.b)
        {
            return .gt;
        }
        return null;
    }

    fn avg(a: u8, b: u8) u8 {
        return @intCast((@as(u9, a) + @as(u9, b)) / 2);
    }

    fn colorHalfwayToward(self: RGB, other: RGB) RGB {
        return RGB{
            .r = avg(self.r, other.r),
            .g = avg(self.g, other.g),
            .b = avg(self.b, other.b),
        };
    }

    fn clone(self: RGB) RGB {
        return RGB{
            .r = self.r,
            .g = self.g,
            .b = self.b,
        };
    }

    test "colorHalfwayToward" {
        const black = RGB{ .r = 0, .g = 0, .b = 0 };
        const red = RGB{ .r = 128, .g = 0, .b = 0 };
        const green = RGB{ .r = 0, .g = 128, .b = 0 };
        const white = RGB{ .r = 255, .g = 255, .b = 255 };
        const grey = RGB{ .r = 215, .g = 215, .b = 215 };

        try std.testing.expectEqual(RGB{ .r = 64, .g = 0, .b = 0 }, black.colorHalfwayToward(red));
        try std.testing.expectEqual(RGB{ .r = 0, .g = 64, .b = 0 }, black.colorHalfwayToward(green));
        try std.testing.expectEqual(RGB{ .r = 235, .g = 235, .b = 235 }, grey.colorHalfwayToward(white));
    }

    test "find color with minimum contrast" {
        const black = RGB{ .r = 0, .g = 0, .b = 0 };
        const grey = RGB{ .r = 127, .g = 127, .b = 127 };

        try std.testing.expectEqual(RGB{ .r = 137, .g = 137, .b = 137 }, black.minContrastColor(25, true));
        try std.testing.expectEqual(RGB{ .r = 188, .g = 188, .b = 188 }, black.minContrastColor(50, true));
        try std.testing.expectEqual(RGB{ .r = 225, .g = 225, .b = 225 }, black.minContrastColor(75, true));

        try std.testing.expectEqual(RGB{ .r = 8, .g = 8, .b = 8 }, grey.minContrastColor(20, false));
        try std.testing.expectEqual(RGB{ .r = 255, .g = 255, .b = 255 }, grey.minContrastColor(15, true));
    }

    pub fn minContrastWithViaHSL(self: RGB, fg: RGB, min_contrast_pct: u7) RGB {
        if (min_contrast_pct == 0) return fg;

        const min_contrast: f32 = @as(f32, @floatFromInt(min_contrast_pct)) / 100.0 / 0.7;
        const bg_hsl = HSL.fromRGB(self);
        var fg_hsl = HSL.fromRGB(fg);

        if (min_contrast < @abs(bg_hsl.l - fg_hsl.l)) {
            std.log.warn("min contrast {d:0.2} already achieved: bg Lum: {d:0.2} fg Lum: {d:0.2}", .{ min_contrast, bg_hsl.l, fg_hsl.l });
            return fg;
        }
        std.log.warn("min contrast {d:0.2} not achieved: bg Lum: {d:0.2} fg Lum: {d:0.2}", .{ min_contrast, bg_hsl.l, fg_hsl.l });

        if (fg_hsl.l > bg_hsl.l) {
            fg_hsl.l = bg_hsl.l + min_contrast;
            if (fg_hsl.l > 1) {
                // not enough contrast by increasing, try decreasing
                fg_hsl.l = bg_hsl.l - min_contrast;
            }
            if (fg_hsl.l < 0) {
                // can't get full contrast that way either, so use maximum available contrast
                fg_hsl.l = if (bg_hsl.l >= 0.5) 0 else 1;
            }
        } else {
            fg_hsl.l = bg_hsl.l - min_contrast;
            if (fg_hsl.l < 0) {
                // not enough contrast by decreasing, try increasing
                fg_hsl.l = bg_hsl.l + min_contrast;
            }
            if (fg_hsl.l > 1) {
                // can't get full contrast that way either, so use maximum available contrast
                fg_hsl.l = if (bg_hsl.l >= 0.5) 0 else 1;
            }
        }
        const new_fg = fg_hsl.toRGB();
        std.log.warn("new fg Lum: {d:0.2} results in new fg {}", .{ fg_hsl.l, new_fg });
        return new_fg;
    }

    test "find color with minimum contrast via HSL" {
        const black = RGB{ .r = 0, .g = 0, .b = 0 };
        const dkgrey = RGB{ .r = 64, .g = 64, .b = 64 };

        // std.log.warn("\nref lums: black: {d:0.2} dkgrey: {d:0.2} grey: {d:0.2} ltgrey: {d:0.2}", .{ black.luminance(), dkgrey.luminance(), grey.luminance(), ltgrey.luminance() });
        var other = black.minContrastWithViaHSL(dkgrey, 50);
        std.log.warn("dkgrey on black to 50% gets {} with lum: {d:0.2}", .{ other, other.luminance() });
        try std.testing.expectApproxEqAbs(@as(f64, 0.5), @abs(black.minContrastWithViaHSL(dkgrey, 50).luminance() - black.luminance()), 0.05);

        other = black.minContrastWithViaHSL(dkgrey, 25);
        std.log.warn("dkgrey on black to 25% gets {} with lum: {d:0.2}", .{ other, other.luminance() });
        try std.testing.expectApproxEqAbs(@as(f64, 0.25), @abs(black.minContrastWithViaHSL(dkgrey, 25).luminance() - black.luminance()), 0.05);
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

    test "size" {
        try std.testing.expectEqual(@as(usize, 24), @bitSizeOf(RGB));
        try std.testing.expectEqual(@as(usize, 3), @sizeOf(RGB));
    }

    /// Parse a color from a floating point intensity value.
    ///
    /// The value should be between 0.0 and 1.0, inclusive.
    fn fromIntensity(value: []const u8) !u8 {
        const i = std.fmt.parseFloat(f64, value) catch return error.InvalidFormat;
        if (i < 0.0 or i > 1.0) {
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
            return error.InvalidFormat;
        }

        const color = std.fmt.parseUnsigned(u16, value, 16) catch return error.InvalidFormat;
        const divisor: usize = switch (value.len) {
            1 => std.math.maxInt(u4),
            2 => std.math.maxInt(u8),
            3 => std.math.maxInt(u12),
            4 => std.math.maxInt(u16),
            else => unreachable,
        };

        return @intCast(@as(usize, color) * std.math.maxInt(u8) / divisor);
    }

    /// Parse a color specification of the form
    ///
    ///     rgb:<red>/<green>/<blue>
    ///
    ///     <red>, <green>, <blue> := h | hh | hhh | hhhh
    ///
    /// where `h` is a single hexadecimal digit.
    ///
    /// Alternatively, the form
    ///
    ///     rgbi:<red>/<green>/<blue>
    ///
    /// where <red>, <green>, and <blue> are floating point values between 0.0
    /// and 1.0 (inclusive) is also accepted.
    pub fn parse(value: []const u8) !RGB {
        const minimum_length = "rgb:a/a/a".len;
        if (value.len < minimum_length or !std.mem.eql(u8, value[0..3], "rgb")) {
            return error.InvalidFormat;
        }

        var i: usize = 3;

        const use_intensity = if (value[i] == 'i') blk: {
            i += 1;
            break :blk true;
        } else false;

        if (value[i] != ':') {
            return error.InvalidFormat;
        }

        i += 1;

        const r = r: {
            const slice = if (std.mem.indexOfScalarPos(u8, value, i, '/')) |end|
                value[i..end]
            else
                return error.InvalidFormat;

            i += slice.len + 1;

            break :r if (use_intensity)
                try RGB.fromIntensity(slice)
            else
                try RGB.fromHex(slice);
        };

        const g = g: {
            const slice = if (std.mem.indexOfScalarPos(u8, value, i, '/')) |end|
                value[i..end]
            else
                return error.InvalidFormat;

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
}
