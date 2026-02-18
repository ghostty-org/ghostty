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

/// Mask that can be used to set which palette indexes were set.
pub const PaletteMask = std.StaticBitSet(@typeInfo(Palette).array.len);

/// Generate the 256-color palette from the user's base16 theme colors,
/// terminal background, and terminal foreground.
///
/// Motivation: The default 256-color palette uses fixed, fully-saturated
/// colors that clash with custom base16 themes, have poor readability in
/// dark shades (the first non-black shade jumps to 37% intensity instead
/// of the expected 20%), and exhibit inconsistent perceived brightness
/// across hues of the same shade (e.g., blue appears darker than green).
/// By generating the extended palette from the user's chosen colors,
/// programs can use the richer 256-color range without requiring their
/// own theme configuration, and light/dark switching works automatically.
///
/// The 216-color cube (indices 16–231) is built via trilinear
/// interpolation in OKLCH space over the 8 base colors. The base16
/// palette maps to the 8 corners of a 6×6×6 RGB cube as follows:
///
///   R=0 edge: bg      → base[1] (red)
///   R=5 edge: base[6] → fg
///   G=0 edge: bg/base[6] (via R) → base[2]/base[4] (green/blue via R)
///   G=5 edge: base[1]/fg (via R) → base[3]/base[5] (yellow/magenta via R)
///
/// For each R slice, four corner colors (c0–c3) are interpolated along
/// the R axis, then for each G row two edge colors (c4–c5) are
/// interpolated along G, and finally each B cell is interpolated along B
/// to produce the final color. OKLCH interpolation ensures perceptually
/// uniform brightness transitions across different hues, with natural
/// hue blending along the shortest arc.
///
/// The 24-step grayscale ramp (indices 232–255) is a simple linear
/// interpolation in OKLCH from the background to the foreground,
/// excluding pure black and white (available in the cube at (0,0,0)
/// and (5,5,5)). The interpolation parameter runs from 1/25 to 24/25.
///
/// Fill `skip` with user-defined color indexes to avoid replacing them.
///
/// Reference: https://gist.github.com/jake-stewart/0a8ea46159a7da2c808e5be2177e1783
pub fn generate256Color(
    base: Palette,
    skip: PaletteMask,
    bg: RGB,
    fg: RGB,
) Palette {
    // Convert the background, foreground, and 8 base theme colors into
    // OKLCH space so that all interpolation is perceptually uniform.
    const bg_lch: OKLCH = .fromRgb(bg);
    const fg_lch: OKLCH = .fromRgb(fg);
    const base8_lch: [8]OKLCH = base8: {
        var base8: [8]OKLCH = undefined;
        for (0..8) |i| base8[i] = .fromRgb(base[i]);
        break :base8 base8;
    };

    // Start from the base palette so indices 0–15 are preserved as-is.
    var result = base;

    // Build the 216-color cube (indices 16–231) via trilinear interpolation
    // in OKLCH. The three nested loops correspond to the R, G, and B axes
    // of a 6×6×6 cube. For each R slice, four corner colors (c0–c3) are
    // interpolated along R from the 8 base colors, mapping the cube corners
    // to theme-aware anchors (see doc comment for the mapping). Then for
    // each G row, two edge colors (c4–c5) blend along G, and finally each
    // B cell interpolates along B to produce the final color.
    var idx: usize = 16;
    for (0..6) |ri| {
        // R-axis corners: blend base colors along the red dimension.
        const tr = @as(f32, @floatFromInt(ri)) / 5.0;
        const c0: OKLCH = .lerp(tr, bg_lch, base8_lch[1]);
        const c1: OKLCH = .lerp(tr, base8_lch[2], base8_lch[3]);
        const c2: OKLCH = .lerp(tr, base8_lch[4], base8_lch[5]);
        const c3: OKLCH = .lerp(tr, base8_lch[6], fg_lch);
        for (0..6) |gi| {
            // G-axis edges: blend the R-interpolated corners along green.
            const tg = @as(f32, @floatFromInt(gi)) / 5.0;
            const c4: OKLCH = .lerp(tg, c0, c1);
            const c5: OKLCH = .lerp(tg, c2, c3);
            for (0..6) |bi| {
                // B-axis: final interpolation along blue, then convert back to RGB.
                if (!skip.isSet(idx)) {
                    const c6: OKLCH = .lerp(
                        @as(f32, @floatFromInt(bi)) / 5.0,
                        c4,
                        c5,
                    );
                    result[idx] = c6.toRgb();
                }

                idx += 1;
            }
        }
    }

    // Build the 24-step grayscale ramp (indices 232–255) by linearly
    // interpolating in OKLCH from background to foreground. The parameter
    // runs from 1/25 to 24/25, excluding the endpoints which are already
    // available in the cube at (0,0,0) and (5,5,5).
    for (0..24) |i| {
        const t = @as(f32, @floatFromInt(i + 1)) / 25.0;
        if (!skip.isSet(idx)) {
            const c: OKLCH = .lerp(t, bg_lch, fg_lch);
            result[idx] = c.toRgb();
        }
        idx += 1;
    }

    return result;
}

/// A palette that can have its colors changed and reset. Purposely built
/// for terminal color operations.
pub const DynamicPalette = struct {
    /// The current palette including any user modifications.
    current: Palette,

    /// The original/default palette values.
    original: Palette,

    /// A bitset where each bit represents whether the corresponding
    /// palette index has been modified from its default value.
    mask: PaletteMask,

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
    pub fn default(self: Name) error{NoDefaultValue}!RGB {
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
    fn fromIntensity(value: []const u8) error{InvalidFormat}!u8 {
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
    fn fromHex(value: []const u8) error{InvalidFormat}!u8 {
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
    pub fn parse(value: []const u8) error{InvalidFormat}!RGB {
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

/// OKLCH color space (Lightness, Chroma, Hue).
///
/// OKLCH is the cylindrical form of Oklab, a perceptually uniform color
/// space designed by Björn Ottosson. Compared to CIELAB, Oklab has better
/// perceptual uniformity (especially for blues) and a simpler, more
/// accurate conversion from/to sRGB. The cylindrical LCH form enables
/// natural hue interpolation along the shortest arc.
///
/// Reference: https://bottosson.github.io/posts/oklab/
const OKLCH = struct {
    /// Perceived lightness (0 = black, 1 = white).
    l: f32,
    /// Chroma (colorfulness), 0 for achromatic grays.
    c: f32,
    /// Hue angle in radians.
    h: f32,

    /// Convert an sRGB color to OKLCH.
    pub fn fromRgb(rgb: RGB) OKLCH {
        // Step 1: Normalize sRGB channels from [0, 255] to [0.0, 1.0].
        var r: f32 = @as(f32, @floatFromInt(rgb.r)) / 255.0;
        var g: f32 = @as(f32, @floatFromInt(rgb.g)) / 255.0;
        var b: f32 = @as(f32, @floatFromInt(rgb.b)) / 255.0;

        // Step 2: Linearize sRGB (inverse sRGB companding).
        r = if (r > 0.04045) std.math.pow(f32, (r + 0.055) / 1.055, 2.4) else r / 12.92;
        g = if (g > 0.04045) std.math.pow(f32, (g + 0.055) / 1.055, 2.4) else g / 12.92;
        b = if (b > 0.04045) std.math.pow(f32, (b + 0.055) / 1.055, 2.4) else b / 12.92;

        // Step 3: Linear RGB to LMS (Oklab M1 matrix).
        const l_lms = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b;
        const m_lms = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b;
        const s_lms = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b;

        // Step 4: Cube root (nonlinear compression).
        const l_ = std.math.cbrt(l_lms);
        const m_ = std.math.cbrt(m_lms);
        const s_ = std.math.cbrt(s_lms);

        // Step 5: LMS to Oklab (M2 matrix).
        const lab_l = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_;
        const lab_a = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_;
        const lab_b = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_;

        // Step 6: Oklab rectangular (L, a, b) to cylindrical (L, C, h).
        const c = @sqrt(lab_a * lab_a + lab_b * lab_b);
        const h = std.math.atan2(lab_b, lab_a);

        return .{ .l = lab_l, .c = c, .h = h };
    }

    /// Convert OKLCH back to sRGB.
    pub fn toRgb(self: OKLCH) RGB {
        // Step 1: OKLCH cylindrical to Oklab rectangular.
        const lab_a = self.c * @cos(self.h);
        const lab_b = self.c * @sin(self.h);

        // Step 2: Oklab to LMS (inverse M2 matrix).
        const l_ = self.l + 0.3963377774 * lab_a + 0.2158037573 * lab_b;
        const m_ = self.l - 0.1055613458 * lab_a - 0.0638541728 * lab_b;
        const s_ = self.l - 0.0894841775 * lab_a - 1.2914855480 * lab_b;

        // Step 3: Undo cube root.
        const l_lms = l_ * l_ * l_;
        const m_lms = m_ * m_ * m_;
        const s_lms = s_ * s_ * s_;

        // Step 4: LMS to linear RGB (inverse M1 matrix).
        var r = 4.0767416621 * l_lms - 3.3077115913 * m_lms + 0.2309699292 * s_lms;
        var g = -1.2684380046 * l_lms + 2.6097574011 * m_lms - 0.3413193965 * s_lms;
        var b = -0.0041960863 * l_lms - 0.7034186147 * m_lms + 1.7076147010 * s_lms;

        // Step 5: Apply sRGB companding (gamma correction).
        r = if (r > 0.0031308) 1.055 * std.math.pow(f32, r, 1.0 / 2.4) - 0.055 else 12.92 * r;
        g = if (g > 0.0031308) 1.055 * std.math.pow(f32, g, 1.0 / 2.4) - 0.055 else 12.92 * g;
        b = if (b > 0.0031308) 1.055 * std.math.pow(f32, b, 1.0 / 2.4) - 0.055 else 12.92 * b;

        // Step 6: Clamp, scale to [0, 255], and round.
        return .{
            .r = @intFromFloat(@min(@max(r, 0.0), 1.0) * 255.0 + 0.5),
            .g = @intFromFloat(@min(@max(g, 0.0), 1.0) * 255.0 + 0.5),
            .b = @intFromFloat(@min(@max(b, 0.0), 1.0) * 255.0 + 0.5),
        };
    }

    /// Interpolate between two OKLCH colors.
    ///
    /// Lightness and chroma are linearly interpolated. Hue is interpolated
    /// along the shortest arc. When either endpoint is achromatic (chroma
    /// near zero), the other endpoint's hue is used to avoid artifacts.
    pub fn lerp(t: f32, a: OKLCH, b: OKLCH) OKLCH {
        // Determine effective hues, handling achromatic endpoints.
        const achromatic_threshold = 1e-4;
        const a_achromatic = a.c < achromatic_threshold;
        const b_achromatic = b.c < achromatic_threshold;
        const ha = if (a_achromatic) b.h else a.h;
        const hb = if (b_achromatic) a.h else b.h;

        // Shortest-arc hue interpolation.
        var dh = hb - ha;
        if (dh > std.math.pi) dh -= 2.0 * std.math.pi;
        if (dh < -std.math.pi) dh += 2.0 * std.math.pi;

        return .{
            .l = a.l + t * (b.l - a.l),
            .c = a.c + t * (b.c - a.c),
            .h = ha + t * dh,
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

test "OKLCH.fromRgb" {
    const testing = std.testing;
    const epsilon = 0.005;

    // White (255, 255, 255) -> L≈1.0, C≈0, H=any
    const white = OKLCH.fromRgb(.{ .r = 255, .g = 255, .b = 255 });
    try testing.expectApproxEqAbs(@as(f32, 1.0), white.l, epsilon);
    try testing.expectApproxEqAbs(@as(f32, 0.0), white.c, epsilon);

    // Black (0, 0, 0) -> L≈0, C≈0, H=any
    const black = OKLCH.fromRgb(.{ .r = 0, .g = 0, .b = 0 });
    try testing.expectApproxEqAbs(@as(f32, 0.0), black.l, epsilon);
    try testing.expectApproxEqAbs(@as(f32, 0.0), black.c, epsilon);

    // Pure red (255, 0, 0) -> L≈0.6279, C≈0.2577, H≈29.23° (0.5101 rad)
    const red = OKLCH.fromRgb(.{ .r = 255, .g = 0, .b = 0 });
    try testing.expectApproxEqAbs(@as(f32, 0.6279), red.l, epsilon);
    try testing.expectApproxEqAbs(@as(f32, 0.2577), red.c, epsilon);
    try testing.expectApproxEqAbs(@as(f32, 0.5101), red.h, 0.01);

    // Pure green (0, 128, 0) -> L≈0.5195, C≈0.1768, H≈142.50° (2.487 rad)
    const green = OKLCH.fromRgb(.{ .r = 0, .g = 128, .b = 0 });
    try testing.expectApproxEqAbs(@as(f32, 0.5195), green.l, epsilon);
    try testing.expectApproxEqAbs(@as(f32, 0.1768), green.c, epsilon);
    try testing.expectApproxEqAbs(@as(f32, 2.487), green.h, 0.01);

    // Pure blue (0, 0, 255) -> L≈0.4520, C≈0.3132, H≈264.05° (-1.674 rad)
    const blue = OKLCH.fromRgb(.{ .r = 0, .g = 0, .b = 255 });
    try testing.expectApproxEqAbs(@as(f32, 0.4520), blue.l, epsilon);
    try testing.expectApproxEqAbs(@as(f32, 0.3132), blue.c, epsilon);
    try testing.expectApproxEqAbs(@as(f32, -1.674), blue.h, 0.01);
}

test "generate256Color: base16 preserved" {
    const testing = std.testing;

    const bg = RGB{ .r = 0, .g = 0, .b = 0 };
    const fg = RGB{ .r = 255, .g = 255, .b = 255 };
    const palette = generate256Color(default, .initEmpty(), bg, fg);

    // The first 16 colors (base16) must remain unchanged.
    for (0..16) |i| {
        try testing.expectEqual(default[i], palette[i]);
    }
}

test "generate256Color: cube corners match base colors" {
    const testing = std.testing;

    const bg = RGB{ .r = 0, .g = 0, .b = 0 };
    const fg = RGB{ .r = 255, .g = 255, .b = 255 };
    const palette = generate256Color(default, .initEmpty(), bg, fg);

    // Index 16 is cube (0,0,0) which should equal bg.
    try testing.expectEqual(bg, palette[16]);

    // Index 231 is cube (5,5,5) which should equal fg.
    try testing.expectEqual(fg, palette[231]);
}

test "generate256Color: grayscale ramp monotonic luminance" {
    const testing = std.testing;

    const bg = RGB{ .r = 0, .g = 0, .b = 0 };
    const fg = RGB{ .r = 255, .g = 255, .b = 255 };
    const palette = generate256Color(default, .initEmpty(), bg, fg);

    // The grayscale ramp (232–255) should have monotonically increasing
    // luminance from near-black to near-white.
    var prev_lum: f64 = 0.0;
    for (232..256) |i| {
        const lum = palette[i].luminance();
        try testing.expect(lum >= prev_lum);
        prev_lum = lum;
    }
}

test "generate256Color: skip mask preserves original colors" {
    const testing = std.testing;

    const bg = RGB{ .r = 0, .g = 0, .b = 0 };
    const fg = RGB{ .r = 255, .g = 255, .b = 255 };

    // Mark a few indices as skipped; they should keep their base value.
    var skip: PaletteMask = .initEmpty();
    skip.set(20);
    skip.set(100);
    skip.set(240);

    const palette = generate256Color(default, skip, bg, fg);
    try testing.expectEqual(default[20], palette[20]);
    try testing.expectEqual(default[100], palette[100]);
    try testing.expectEqual(default[240], palette[240]);

    // A non-skipped index in the cube should differ from the default.
    try testing.expect(!palette[21].eql(default[21]));
}

test "OKLCH.toRgb" {
    const testing = std.testing;

    // Round-trip: RGB -> OKLCH -> RGB should recover the original values.
    const cases = [_]RGB{
        .{ .r = 255, .g = 255, .b = 255 },
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 255, .g = 0, .b = 0 },
        .{ .r = 0, .g = 128, .b = 0 },
        .{ .r = 0, .g = 0, .b = 255 },
        .{ .r = 128, .g = 128, .b = 128 },
        .{ .r = 64, .g = 224, .b = 208 },
    };

    for (cases) |expected| {
        const lch = OKLCH.fromRgb(expected);
        const actual = lch.toRgb();
        try testing.expectEqual(expected.r, actual.r);
        try testing.expectEqual(expected.g, actual.g);
        try testing.expectEqual(expected.b, actual.b);
    }
}
