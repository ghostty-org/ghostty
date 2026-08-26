const std = @import("std");
const lib = @import("../lib.zig");
const color = @import("../color.zig");
const x11_color = @import("../x11_color.zig");
const Result = @import("result.zig").Result;

/// C: GhosttyColorPaletteMask
pub const PaletteMask = extern struct {
    bits: [4]u64,

    /// Convert to the Zig PaletteMask (std.StaticBitSet(256)).
    pub fn toZig(self: *const PaletteMask) color.PaletteMask {
        var result = color.PaletteMask.initEmpty();
        for (0..256) |i| {
            if (((self.bits[i >> 6] >> @as(u6, @intCast(i & 63))) & 1) != 0) {
                result.set(i);
            }
        }
        return result;
    }
};

/// C: GhosttyColorX11Entry
pub const X11Entry = extern struct {
    /// Null-terminated color name; null marks the end of the table.
    name: ?[*:0]const u8,
    color: color.RGB.C,
};

/// Comptime-built static table, terminated by a null-name entry.
const x11_entries: [x11_color.entries.len + 1]X11Entry = entries: {
    @setEvalBranchQuota(10_000);
    var result: [x11_color.entries.len + 1]X11Entry = undefined;
    for (x11_color.entries, 0..) |entry, i| result[i] = .{
        .name = entry.name.ptr,
        .color = entry.color.cval(),
    };
    result[x11_color.entries.len] = .{ .name = null, .color = .{ .r = 0, .g = 0, .b = 0 } };
    break :entries result;
};

pub fn rgb_get(
    c: *const color.RGB.C,
    r: *u8,
    g: *u8,
    b: *u8,
) callconv(lib.calling_conv) void {
    r.* = c.r;
    g.* = c.g;
    b.* = c.b;
}

pub fn parse_x11(
    name_: ?[*]const u8,
    len: usize,
    out: *color.RGB.C,
) callconv(lib.calling_conv) Result {
    const name = (name_ orelse return .invalid_value)[0..len];
    const trimmed = std.mem.trim(u8, name, " \t");
    const rgb = x11_color.map.get(trimmed) orelse return .invalid_value;
    out.* = rgb.cval();
    return .success;
}

pub fn parse(
    value_: ?[*]const u8,
    len: usize,
    out: *color.RGB.C,
) callconv(lib.calling_conv) Result {
    const value = (value_ orelse return .invalid_value)[0..len];
    const rgb = color.RGB.parse(value) catch return .invalid_value;
    out.* = rgb.cval();
    return .success;
}

pub fn palette_default(out: *color.PaletteC) callconv(lib.calling_conv) void {
    out.* = color.paletteCval(&color.default);
}

/// Generate a 256-color palette. The output may alias the base input.
pub fn palette_generate(
    base_: ?*const color.PaletteC,
    skip_: ?*const PaletteMask,
    bg: *const color.RGB.C,
    fg: *const color.RGB.C,
    harmonious: bool,
    out: *color.PaletteC,
) callconv(lib.calling_conv) void {
    const base: color.Palette = if (base_) |base|
        color.paletteZval(base)
    else
        color.default;
    const skip: color.PaletteMask = if (skip_) |skip|
        skip.toZig()
    else
        .initEmpty();
    const result = color.generate256Color(
        base,
        skip,
        .fromC(bg.*),
        .fromC(fg.*),
        harmonious,
    );
    out.* = color.paletteCval(&result);
}

pub fn x11_names() callconv(lib.calling_conv) [*]const X11Entry {
    return x11_entries[0..].ptr;
}

pub fn x11_name_count() callconv(lib.calling_conv) usize {
    return x11_color.entries.len;
}

pub fn parse_palette_entry(
    value_: ?[*]const u8,
    len: usize,
    out_index: *u8,
    out_rgb: *color.RGB.C,
) callconv(lib.calling_conv) Result {
    const value = (value_ orelse return .invalid_value)[0..len];
    const entry = color.parsePaletteEntry(value) catch return .invalid_value;
    out_index.* = entry.index;
    out_rgb.* = entry.color.cval();
    return .success;
}

pub fn luminance(c: *const color.RGB.C) callconv(lib.calling_conv) f64 {
    return color.RGB.fromC(c.*).luminance();
}

pub fn perceived_luminance(c: *const color.RGB.C) callconv(lib.calling_conv) f64 {
    return color.RGB.fromC(c.*).perceivedLuminance();
}

pub fn contrast(a: *const color.RGB.C, b: *const color.RGB.C) callconv(lib.calling_conv) f64 {
    return color.RGB.fromC(a.*).contrast(.fromC(b.*));
}

fn expectRgb(expected: color.RGB, actual: color.RGB.C) !void {
    try std.testing.expectEqual(expected, color.RGB.fromC(actual));
}

fn expectPaletteC(expected: *const color.PaletteC, actual: *const color.PaletteC) !void {
    for (expected.*, actual.*) |expected_rgb, actual_rgb| {
        try expectRgb(color.RGB.fromC(expected_rgb), actual_rgb);
    }
}

fn generatePalette(
    base_: ?*const color.PaletteC,
    skip_: ?*const PaletteMask,
    bg: color.RGB,
    fg: color.RGB,
    harmonious: bool,
) color.PaletteC {
    var out: color.PaletteC = undefined;
    const bg_c = bg.cval();
    const fg_c = fg.cval();
    palette_generate(base_, skip_, &bg_c, &fg_c, harmonious, &out);
    return out;
}

fn setMaskBit(mask: *PaletteMask, idx: usize) void {
    mask.bits[idx >> 6] |= @as(u64, 1) << @as(u6, @intCast(idx & 63));
}

test "color: parse_x11 valid" {
    const testing = std.testing;

    const cases = [_]struct {
        input: []const u8,
        expected: color.RGB,
    }{
        .{ .input = "white", .expected = .{ .r = 255, .g = 255, .b = 255 } },
        .{ .input = "medium spring green", .expected = .{ .r = 0, .g = 250, .b = 154 } },
        .{ .input = "ForestGreen", .expected = .{ .r = 34, .g = 139, .b = 34 } },
        .{ .input = "FoReStGReen", .expected = .{ .r = 34, .g = 139, .b = 34 } },
        .{ .input = " Forest Green ", .expected = .{ .r = 34, .g = 139, .b = 34 } },
        .{ .input = "\tblack\t", .expected = .{ .r = 0, .g = 0, .b = 0 } },
    };

    for (cases) |case| {
        var out: color.RGB.C = undefined;
        try testing.expectEqual(.success, parse_x11(case.input.ptr, case.input.len, &out));
        try expectRgb(case.expected, out);
    }
}

test "color: parse_x11 invalid" {
    const testing = std.testing;

    const cases = [_][]const u8{
        "nosuchcolor",
        "",
        "   ",
        "#ffffff",
    };

    for (cases) |case| {
        var out: color.RGB.C = undefined;
        try testing.expectEqual(.invalid_value, parse_x11(case.ptr, case.len, &out));
    }

    var out: color.RGB.C = undefined;
    try testing.expectEqual(.invalid_value, parse_x11(null, 0, &out));
}

test "color: parse valid" {
    const testing = std.testing;

    const cases = [_]struct {
        input: []const u8,
        expected: color.RGB,
    }{
        .{ .input = "black", .expected = .{ .r = 0, .g = 0, .b = 0 } },
        .{ .input = "#AABBCC", .expected = .{ .r = 170, .g = 187, .b = 204 } },
        .{ .input = "0A0B0C", .expected = .{ .r = 10, .g = 11, .b = 12 } },
        .{ .input = "FFF", .expected = .{ .r = 255, .g = 255, .b = 255 } },
        .{ .input = "#345", .expected = .{ .r = 51, .g = 68, .b = 85 } },
        .{ .input = "rgb:1/2/3", .expected = .{ .r = 17, .g = 34, .b = 51 } },
        .{ .input = "  black ", .expected = .{ .r = 0, .g = 0, .b = 0 } },
        .{ .input = " #AABBCC   ", .expected = .{ .r = 170, .g = 187, .b = 204 } },
    };

    for (cases) |case| {
        var out: color.RGB.C = undefined;
        try testing.expectEqual(.success, parse(case.input.ptr, case.input.len, &out));
        try expectRgb(case.expected, out);
    }
}

test "color: parse invalid" {
    const testing = std.testing;

    const cases = [_][]const u8{
        "",
        "notacolor",
        "#12345",
    };

    for (cases) |case| {
        var out: color.RGB.C = undefined;
        try testing.expectEqual(.invalid_value, parse(case.ptr, case.len, &out));
    }

    var out: color.RGB.C = undefined;
    try testing.expectEqual(.invalid_value, parse(null, 0, &out));
}

test "color: parse_palette_entry valid" {
    const testing = std.testing;

    const cases = [_]struct {
        input: []const u8,
        index: u8,
        expected: color.RGB,
    }{
        .{ .input = "0=#AABBCC", .index = 0, .expected = .{ .r = 170, .g = 187, .b = 204 } },
        .{ .input = "0xF=#ABCDEF", .index = 15, .expected = .{ .r = 171, .g = 205, .b = 239 } },
        .{ .input = "0b1=#014589", .index = 1, .expected = .{ .r = 1, .g = 69, .b = 137 } },
        .{ .input = "0o7=#234567", .index = 7, .expected = .{ .r = 35, .g = 69, .b = 103 } },
        .{ .input = " 1= #DDEEFF    ", .index = 1, .expected = .{ .r = 221, .g = 238, .b = 255 } },
        .{ .input = "1=black", .index = 1, .expected = .{ .r = 0, .g = 0, .b = 0 } },
    };

    for (cases) |case| {
        var index: u8 = undefined;
        var rgb: color.RGB.C = undefined;
        try testing.expectEqual(.success, parse_palette_entry(
            case.input.ptr,
            case.input.len,
            &index,
            &rgb,
        ));
        try testing.expectEqual(case.index, index);
        try expectRgb(case.expected, rgb);
    }
}

test "color: parse_palette_entry invalid" {
    const testing = std.testing;

    const cases = [_][]const u8{
        "256=#AABBCC",
        "a",
        "",
        "1=notacolor",
    };

    for (cases) |case| {
        var index: u8 = undefined;
        var rgb: color.RGB.C = undefined;
        try testing.expectEqual(.invalid_value, parse_palette_entry(
            case.ptr,
            case.len,
            &index,
            &rgb,
        ));
    }

    var index: u8 = undefined;
    var rgb: color.RGB.C = undefined;
    try testing.expectEqual(.invalid_value, parse_palette_entry(null, 0, &index, &rgb));
}

test "color: palette_default" {
    var out: color.PaletteC = undefined;
    palette_default(&out);

    const expected = color.paletteCval(&color.default);
    try expectPaletteC(&expected, &out);

    try expectRgb(.{ .r = 0x1D, .g = 0x1F, .b = 0x21 }, out[0]);
    try expectRgb(.{ .r = 0, .g = 0, .b = 0 }, out[16]);
    try expectRgb(.{ .r = 255, .g = 255, .b = 255 }, out[231]);
    try expectRgb(.{ .r = 8, .g = 8, .b = 8 }, out[232]);
    try expectRgb(.{ .r = 238, .g = 238, .b = 238 }, out[255]);
}

test "color: palette_generate base16 preserved" {
    const testing = std.testing;

    const base = color.paletteCval(&color.default);
    const palette = generatePalette(
        &base,
        null,
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 255, .g = 255, .b = 255 },
        false,
    );

    for (0..16) |i| {
        try testing.expectEqual(color.RGB.fromC(base[i]), color.RGB.fromC(palette[i]));
    }
}

test "color: palette_generate cube corners" {
    const bg = color.RGB{ .r = 0, .g = 0, .b = 0 };
    const fg = color.RGB{ .r = 255, .g = 255, .b = 255 };
    const palette = generatePalette(null, null, bg, fg, false);

    try expectRgb(bg, palette[16]);
    try expectRgb(fg, palette[231]);
}

test "color: palette_generate light theme harmonious=false" {
    const white = color.RGB{ .r = 255, .g = 255, .b = 255 };
    const black = color.RGB{ .r = 0, .g = 0, .b = 0 };

    const normal = generatePalette(null, null, white, black, false);
    try expectRgb(black, normal[16]);
    try expectRgb(white, normal[231]);

    const harmonious = generatePalette(null, null, white, black, true);
    try expectRgb(white, harmonious[16]);
    try expectRgb(black, harmonious[231]);
}

test "color: palette_generate grayscale monotonic" {
    const testing = std.testing;

    const palette = generatePalette(
        null,
        null,
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 255, .g = 255, .b = 255 },
        false,
    );

    var prev_lum: f64 = 0.0;
    for (232..256) |i| {
        const lum = color.RGB.fromC(palette[i]).luminance();
        try testing.expect(lum >= prev_lum);
        prev_lum = lum;
    }
}

test "color: palette_generate skip mask" {
    const testing = std.testing;

    const base = color.paletteCval(&color.default);
    var skip: PaletteMask = .{ .bits = .{ 0, 0, 0, 0 } };
    setMaskBit(&skip, 20);
    setMaskBit(&skip, 100);
    setMaskBit(&skip, 240);

    const palette = generatePalette(
        &base,
        &skip,
        .{ .r = 0, .g = 0, .b = 0 },
        .{ .r = 255, .g = 255, .b = 255 },
        false,
    );

    try testing.expectEqual(color.RGB.fromC(base[20]), color.RGB.fromC(palette[20]));
    try testing.expectEqual(color.RGB.fromC(base[100]), color.RGB.fromC(palette[100]));
    try testing.expectEqual(color.RGB.fromC(base[240]), color.RGB.fromC(palette[240]));
    try testing.expect(!color.RGB.fromC(palette[21]).eql(color.RGB.fromC(base[21])));
}

test "color: palette_generate dark harmonious no-op" {
    const testing = std.testing;

    const bg = color.RGB{ .r = 0, .g = 0, .b = 0 };
    const fg = color.RGB{ .r = 255, .g = 255, .b = 255 };
    const normal = generatePalette(null, null, bg, fg, false);
    const harmonious = generatePalette(null, null, bg, fg, true);

    for (16..256) |i| {
        try testing.expectEqual(color.RGB.fromC(normal[i]), color.RGB.fromC(harmonious[i]));
    }
}

test "color: palette_generate light harmonious ramp" {
    const testing = std.testing;

    const bg = color.RGB{ .r = 255, .g = 255, .b = 255 };
    const fg = color.RGB{ .r = 0, .g = 0, .b = 0 };

    {
        const palette = generatePalette(null, null, bg, fg, false);
        var prev_lum: f64 = 0.0;
        for (232..256) |i| {
            const lum = color.RGB.fromC(palette[i]).luminance();
            try testing.expect(lum >= prev_lum);
            prev_lum = lum;
        }
    }

    {
        const palette = generatePalette(null, null, bg, fg, true);
        var prev_lum: f64 = 1.0;
        for (232..256) |i| {
            const lum = color.RGB.fromC(palette[i]).luminance();
            try testing.expect(lum <= prev_lum);
            prev_lum = lum;
        }
    }
}

test "color: palette_generate NULL base uses default" {
    const base = color.paletteCval(&color.default);
    const bg = color.RGB{ .r = 5, .g = 10, .b = 15 };
    const fg = color.RGB{ .r = 245, .g = 250, .b = 255 };

    const null_base = generatePalette(null, null, bg, fg, false);
    const explicit = generatePalette(&base, null, bg, fg, false);
    try expectPaletteC(&explicit, &null_base);
}

test "color: palette_generate NULL skip" {
    const base = color.paletteCval(&color.default);
    const bg = color.RGB{ .r = 5, .g = 10, .b = 15 };
    const fg = color.RGB{ .r = 245, .g = 250, .b = 255 };
    const skip: PaletteMask = .{ .bits = .{ 0, 0, 0, 0 } };

    const null_skip = generatePalette(&base, null, bg, fg, false);
    const explicit = generatePalette(&base, &skip, bg, fg, false);
    try expectPaletteC(&explicit, &null_skip);
}

test "color: palette_generate matches generate256Color" {
    const base_c = color.paletteCval(&color.default);
    const bg = color.RGB{ .r = 16, .g = 32, .b = 48 };
    const fg = color.RGB{ .r = 240, .g = 224, .b = 208 };
    var skip_c: PaletteMask = .{ .bits = .{ 0, 0, 0, 0 } };
    setMaskBit(&skip_c, 20);
    setMaskBit(&skip_c, 100);
    setMaskBit(&skip_c, 240);

    const actual = generatePalette(&base_c, &skip_c, bg, fg, true);
    const expected_z = color.generate256Color(
        color.paletteZval(&base_c),
        skip_c.toZig(),
        bg,
        fg,
        true,
    );
    const expected = color.paletteCval(&expected_z);
    try expectPaletteC(&expected, &actual);
}

test "color: palette_generate in-place" {
    var base = color.paletteCval(&color.default);
    const bg = color.RGB{ .r = 0, .g = 0, .b = 0 };
    const fg = color.RGB{ .r = 255, .g = 255, .b = 255 };
    const expected = generatePalette(&base, null, bg, fg, false);

    const bg_c = bg.cval();
    const fg_c = fg.cval();
    palette_generate(&base, null, &bg_c, &fg_c, false, &base);
    try expectPaletteC(&expected, &base);
}

test "color: luminance" {
    const testing = std.testing;

    const black = color.RGB{ .r = 0, .g = 0, .b = 0 };
    const white = color.RGB{ .r = 255, .g = 255, .b = 255 };
    const black_c = black.cval();
    const white_c = white.cval();
    try testing.expectApproxEqAbs(@as(f64, 0.0), luminance(&black_c), 0.000001);
    try testing.expectApproxEqAbs(@as(f64, 1.0), luminance(&white_c), 0.000001);

    const samples = [_]color.RGB{
        .{ .r = 40, .g = 44, .b = 52 },
        .{ .r = 171, .g = 205, .b = 239 },
        .{ .r = 12, .g = 34, .b = 56 },
    };
    for (samples) |sample| {
        const sample_c = sample.cval();
        try testing.expectApproxEqAbs(sample.luminance(), luminance(&sample_c), 0.000001);
    }
}

test "color: perceived_luminance" {
    const testing = std.testing;

    const black = color.RGB{ .r = 0, .g = 0, .b = 0 };
    const white = color.RGB{ .r = 255, .g = 255, .b = 255 };
    const dark = color.RGB{ .r = 0x28, .g = 0x2C, .b = 0x34 };
    const black_c = black.cval();
    const white_c = white.cval();
    const dark_c = dark.cval();
    try testing.expectApproxEqAbs(@as(f64, 0.0), perceived_luminance(&black_c), 0.000001);
    try testing.expectApproxEqAbs(@as(f64, 1.0), perceived_luminance(&white_c), 0.000001);
    try testing.expect(perceived_luminance(&dark_c) < 0.5);
    try testing.expect(perceived_luminance(&white_c) > 0.5);

    const samples = [_]color.RGB{
        dark,
        .{ .r = 171, .g = 205, .b = 239 },
        .{ .r = 12, .g = 34, .b = 56 },
    };
    for (samples) |sample| {
        const sample_c = sample.cval();
        try testing.expectApproxEqAbs(
            sample.perceivedLuminance(),
            perceived_luminance(&sample_c),
            0.000001,
        );
    }
}

test "color: contrast" {
    const testing = std.testing;

    const black = color.RGB{ .r = 0, .g = 0, .b = 0 };
    const white = color.RGB{ .r = 255, .g = 255, .b = 255 };
    const gray = color.RGB{ .r = 128, .g = 128, .b = 128 };
    const black_c = black.cval();
    const white_c = white.cval();
    const gray_c = gray.cval();

    try testing.expectApproxEqAbs(@as(f64, 21.0), contrast(&white_c, &black_c), 0.000001);
    try testing.expectApproxEqAbs(
        contrast(&black_c, &white_c),
        contrast(&white_c, &black_c),
        0.000001,
    );
    try testing.expectApproxEqAbs(@as(f64, 1.0), contrast(&gray_c, &gray_c), 0.000001);
}

test "color: x11_names" {
    const testing = std.testing;

    const names = x11_names();
    const count = x11_name_count();
    try testing.expectEqual(x11_color.entries.len, count);
    try testing.expect(count > 700);

    var walked: usize = 0;
    while (names[walked].name) |name| : (walked += 1) {
        const name_slice = std.mem.span(name);
        const expected = x11_color.map.get(name_slice).?;
        try testing.expectEqual(expected, color.RGB.fromC(names[walked].color));
    }

    try testing.expectEqual(count, walked);
    try testing.expectEqual(@as(?[*:0]const u8, null), names[count].name);
}

test "color: x11_names static" {
    try std.testing.expectEqual(@intFromPtr(x11_names()), @intFromPtr(x11_names()));
}
