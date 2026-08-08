//! Symbols for Legacy Computing | U+1FB00...U+1FBFF
//! https://en.wikipedia.org/wiki/Symbols_for_Legacy_Computing
//!
//! 🬀 🬁 🬂 🬃 🬄 🬅 🬆 🬇 🬈 🬉 🬊 🬋 🬌 🬍 🬎 🬏
//! 🬐 🬑 🬒 🬓 🬔 🬕 🬖 🬗 🬘 🬙 🬚 🬛 🬜 🬝 🬞 🬟
//! 🬠 🬡 🬢 🬣 🬤 🬥 🬦 🬧 🬨 🬩 🬪 🬫 🬬 🬭 🬮 🬯
//! 🬰 🬱 🬲 🬳 🬴 🬵 🬶 🬷 🬸 🬹 🬺 🬻 🬼 🬽 🬾 🬿
//! 🭀 🭁 🭂 🭃 🭄 🭅 🭆 🭇 🭈 🭉 🭊 🭋 🭌 🭍 🭎 🭏
//! 🭐 🭑 🭒 🭓 🭔 🭕 🭖 🭗 🭘 🭙 🭚 🭛 🭜 🭝 🭞 🭟
//! 🭠 🭡 🭢 🭣 🭤 🭥 🭦 🭧 🭨 🭩 🭪 🭫 🭬 🭭 🭮 🭯
//! 🭰 🭱 🭲 🭳 🭴 🭵 🭶 🭷 🭸 🭹 🭺 🭻 🭼 🭽 🭾 🭿
//! 🮀 🮁 🮂 🮃 🮄 🮅 🮆 🮇 🮈 🮉 🮊 🮋 🮌 🮍 🮎 🮏
//! 🮐 🮑 🮒   🮔 🮕 🮖 🮗 🮘 🮙 🮚 🮛 🮜 🮝 🮞 🮟
//! 🮠 🮡 🮢 🮣 🮤 🮥 🮦 🮧 🮨 🮩 🮪 🮫 🮬 🮭 🮮 🮯
//! 🮰 🮱 🮲 🮳 🮴 🮵 🮶 🮷 🮸 🮹 🮺 🮻 🮼 🮽 🮾 🮿
//! 🯀 🯁 🯂 🯃 🯄 🯅 🯆 🯇 🯈 🯉 🯊 🯋 🯌 🯍 🯎 🯏
//! 🯐 🯑 🯒 🯓 🯔 🯕 🯖 🯗 🯘 🯙 🯚 🯛 🯜 🯝 🯞 🯟
//! 🯠 🯡 🯢 🯣 🯤 🯥 🯦 🯧 🯨 🯩 🯪 🯫 🯬 🯭 🯮 🯯
//! 🯰 🯱 🯲 🯳 🯴 🯵 🯶 🯷 🯸 🯹
//!

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("quirks").inlineAssert;

const common = @import("common.zig");
const Thickness = common.Thickness;
const Alignment = common.Alignment;
const Fraction = common.Fraction;
const Corner = common.Corner;
const Quads = common.Quads;
const Edge = common.Edge;
const Shade = common.Shade;
const fill = common.fill;

const box = @import("box.zig");
const block = @import("block.zig");
const geo = @import("geometric_shapes.zig");

const font = @import("../../main.zig");

// Utility names for common fractions
const one_eighth: f64 = 0.125;
const one_quarter: f64 = 0.25;
const one_third: f64 = (1.0 / 3.0);
const three_eighths: f64 = 0.375;
const half: f64 = 0.5;
const five_eighths: f64 = 0.625;
const two_thirds: f64 = (2.0 / 3.0);
const three_quarters: f64 = 0.75;
const seven_eighths: f64 = 0.875;

const SmoothMosaic = packed struct(u10) {
    tl: bool,
    ul: bool,
    ll: bool,
    bl: bool,
    bc: bool,
    br: bool,
    lr: bool,
    ur: bool,
    tr: bool,
    tc: bool,

    fn from(comptime pattern: *const [15:0]u8) SmoothMosaic {
        return .{
            .tl = pattern[0] == '#',

            .ul = pattern[4] == '#' and
                (pattern[0] != '#' or pattern[8] != '#'),

            .ll = pattern[8] == '#' and
                (pattern[4] != '#' or pattern[12] != '#'),

            .bl = pattern[12] == '#',

            .bc = pattern[13] == '#' and
                (pattern[12] != '#' or pattern[14] != '#'),

            .br = pattern[14] == '#',

            .lr = pattern[10] == '#' and
                (pattern[14] != '#' or pattern[6] != '#'),

            .ur = pattern[6] == '#' and
                (pattern[10] != '#' or pattern[2] != '#'),

            .tr = pattern[2] == '#',

            .tc = pattern[1] == '#' and
                (pattern[2] != '#' or pattern[0] != '#'),
        };
    }
};

/// Sextants
pub fn draw1FB00_1FB3B(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = width;
    _ = height;

    const Sextants = packed struct(u6) {
        tl: bool,
        tr: bool,
        ml: bool,
        mr: bool,
        bl: bool,
        br: bool,
    };

    assert(cp >= 0x1fb00 and cp <= 0x1fb3b);
    const idx = cp - 0x1fb00;
    const sex: Sextants = @bitCast(@as(u6, @intCast(
        idx + (idx / 0x14) + 1,
    )));
    if (sex.tl) fill(metrics, canvas, .zero, .half, .zero, .one_third);
    if (sex.tr) fill(metrics, canvas, .half, .full, .zero, .one_third);
    if (sex.ml) fill(metrics, canvas, .zero, .half, .one_third, .two_thirds);
    if (sex.mr) fill(metrics, canvas, .half, .full, .one_third, .two_thirds);
    if (sex.bl) fill(metrics, canvas, .zero, .half, .two_thirds, .end);
    if (sex.br) fill(metrics, canvas, .half, .full, .two_thirds, .end);
}

/// Smooth Mosaics
pub fn draw1FB3C_1FB67(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = width;
    _ = height;

    // Hand written lookup table for these shapes since I couldn't
    // determine any sort of mathematical pattern in the codepoints.
    const mosaic: SmoothMosaic = switch (cp) {
        // '🬼'
        0x1fb3c => SmoothMosaic.from(
            \\...
            \\...
            \\#..
            \\##.
        ),
        // '🬽'
        0x1fb3d => SmoothMosaic.from(
            \\...
            \\...
            \\#\.
            \\###
        ),
        // '🬾'
        0x1fb3e => SmoothMosaic.from(
            \\...
            \\#..
            \\#\.
            \\##.
        ),
        // '🬿'
        0x1fb3f => SmoothMosaic.from(
            \\...
            \\#..
            \\##.
            \\###
        ),
        // '🭀'
        0x1fb40 => SmoothMosaic.from(
            \\#..
            \\#..
            \\##.
            \\##.
        ),

        // '🭁'
        0x1fb41 => SmoothMosaic.from(
            \\/##
            \\###
            \\###
            \\###
        ),
        // '🭂'
        0x1fb42 => SmoothMosaic.from(
            \\./#
            \\###
            \\###
            \\###
        ),
        // '🭃'
        0x1fb43 => SmoothMosaic.from(
            \\.##
            \\.##
            \\###
            \\###
        ),
        // '🭄'
        0x1fb44 => SmoothMosaic.from(
            \\..#
            \\.##
            \\###
            \\###
        ),
        // '🭅'
        0x1fb45 => SmoothMosaic.from(
            \\.##
            \\.##
            \\.##
            \\###
        ),
        // '🭆'
        0x1fb46 => SmoothMosaic.from(
            \\...
            \\./#
            \\###
            \\###
        ),

        // '🭇'
        0x1fb47 => SmoothMosaic.from(
            \\...
            \\...
            \\..#
            \\.##
        ),
        // '🭈'
        0x1fb48 => SmoothMosaic.from(
            \\...
            \\...
            \\./#
            \\###
        ),
        // '🭉'
        0x1fb49 => SmoothMosaic.from(
            \\...
            \\..#
            \\./#
            \\.##
        ),
        // '🭊'
        0x1fb4a => SmoothMosaic.from(
            \\...
            \\..#
            \\.##
            \\###
        ),
        // '🭋'
        0x1fb4b => SmoothMosaic.from(
            \\..#
            \\..#
            \\.##
            \\.##
        ),

        // '🭌'
        0x1fb4c => SmoothMosaic.from(
            \\##\
            \\###
            \\###
            \\###
        ),
        // '🭍'
        0x1fb4d => SmoothMosaic.from(
            \\#\.
            \\###
            \\###
            \\###
        ),
        // '🭎'
        0x1fb4e => SmoothMosaic.from(
            \\##.
            \\##.
            \\###
            \\###
        ),
        // '🭏'
        0x1fb4f => SmoothMosaic.from(
            \\#..
            \\##.
            \\###
            \\###
        ),
        // '🭐'
        0x1fb50 => SmoothMosaic.from(
            \\##.
            \\##.
            \\##.
            \\###
        ),
        // '🭑'
        0x1fb51 => SmoothMosaic.from(
            \\...
            \\#\.
            \\###
            \\###
        ),

        // '🭒'
        0x1fb52 => SmoothMosaic.from(
            \\###
            \\###
            \\###
            \\\##
        ),
        // '🭓'
        0x1fb53 => SmoothMosaic.from(
            \\###
            \\###
            \\###
            \\.\#
        ),
        // '🭔'
        0x1fb54 => SmoothMosaic.from(
            \\###
            \\###
            \\.##
            \\.##
        ),
        // '🭕'
        0x1fb55 => SmoothMosaic.from(
            \\###
            \\###
            \\.##
            \\..#
        ),
        // '🭖'
        0x1fb56 => SmoothMosaic.from(
            \\###
            \\.##
            \\.##
            \\.##
        ),

        // '🭗'
        0x1fb57 => SmoothMosaic.from(
            \\##.
            \\#..
            \\...
            \\...
        ),
        // '🭘'
        0x1fb58 => SmoothMosaic.from(
            \\###
            \\#/.
            \\...
            \\...
        ),
        // '🭙'
        0x1fb59 => SmoothMosaic.from(
            \\##.
            \\#/.
            \\#..
            \\...
        ),
        // '🭚'
        0x1fb5a => SmoothMosaic.from(
            \\###
            \\##.
            \\#..
            \\...
        ),
        // '🭛'
        0x1fb5b => SmoothMosaic.from(
            \\##.
            \\##.
            \\#..
            \\#..
        ),

        // '🭜'
        0x1fb5c => SmoothMosaic.from(
            \\###
            \\###
            \\#/.
            \\...
        ),
        // '🭝'
        0x1fb5d => SmoothMosaic.from(
            \\###
            \\###
            \\###
            \\##/
        ),
        // '🭞'
        0x1fb5e => SmoothMosaic.from(
            \\###
            \\###
            \\###
            \\#/.
        ),
        // '🭟'
        0x1fb5f => SmoothMosaic.from(
            \\###
            \\###
            \\##.
            \\##.
        ),
        // '🭠'
        0x1fb60 => SmoothMosaic.from(
            \\###
            \\###
            \\##.
            \\#..
        ),
        // '🭡'
        0x1fb61 => SmoothMosaic.from(
            \\###
            \\##.
            \\##.
            \\##.
        ),

        // '🭢'
        0x1fb62 => SmoothMosaic.from(
            \\.##
            \\..#
            \\...
            \\...
        ),
        // '🭣'
        0x1fb63 => SmoothMosaic.from(
            \\###
            \\.\#
            \\...
            \\...
        ),
        // '🭤'
        0x1fb64 => SmoothMosaic.from(
            \\.##
            \\.\#
            \\..#
            \\...
        ),
        // '🭥'
        0x1fb65 => SmoothMosaic.from(
            \\###
            \\.##
            \\..#
            \\...
        ),
        // '🭦'
        0x1fb66 => SmoothMosaic.from(
            \\.##
            \\.##
            \\..#
            \\..#
        ),
        // '🭧'
        0x1fb67 => SmoothMosaic.from(
            \\###
            \\###
            \\.\#
            \\...
        ),
        else => unreachable,
    };

    const top: f64 = 0.0;
    const upper: f64 = Fraction.one_third.float(metrics.cell_height);
    const lower: f64 = Fraction.two_thirds.float(metrics.cell_height);
    const bottom: f64 = @floatFromInt(metrics.cell_height);
    const left: f64 = 0.0;
    const center: f64 = Fraction.half.float(metrics.cell_width);
    const right: f64 = @floatFromInt(metrics.cell_width);

    var path = canvas.staticPath(12); // nodes.len = 0
    if (mosaic.tl) path.lineTo(left, top); // +1, nodes.len = 1
    if (mosaic.ul) path.lineTo(left, upper); // +1, nodes.len = 2
    if (mosaic.ll) path.lineTo(left, lower); // +1, nodes.len = 3
    if (mosaic.bl) path.lineTo(left, bottom); // +1, nodes.len = 4
    if (mosaic.bc) path.lineTo(center, bottom); // +1, nodes.len = 5
    if (mosaic.br) path.lineTo(right, bottom); // +1, nodes.len = 6
    if (mosaic.lr) path.lineTo(right, lower); // +1, nodes.len = 7
    if (mosaic.ur) path.lineTo(right, upper); // +1, nodes.len = 8
    if (mosaic.tr) path.lineTo(right, top); // +1, nodes.len = 9
    if (mosaic.tc) path.lineTo(center, top); // +1, nodes.len = 10
    path.close(); // +2, nodes.len = 12

    try canvas.fillPath(path.wrapped_path, .{}, .on);
}

pub fn draw1FB68_1FB6F(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = width;
    _ = height;

    switch (cp) {
        // '🭨'
        0x1fb68 => {
            try edgeTriangle(metrics, canvas, .left);
            canvas.invert();
            // Set the clip so we don't include anything outside of the cell.
            canvas.clip_left = canvas.padding_x;
            canvas.clip_right = canvas.padding_x;
            canvas.clip_top = canvas.padding_y;
            canvas.clip_bottom = canvas.padding_y;
        },
        // '🭩'
        0x1fb69 => {
            try edgeTriangle(metrics, canvas, .top);
            canvas.invert();
            // Set the clip so we don't include anything outside of the cell.
            canvas.clip_left = canvas.padding_x;
            canvas.clip_right = canvas.padding_x;
            canvas.clip_top = canvas.padding_y;
            canvas.clip_bottom = canvas.padding_y;
        },
        // '🭪'
        0x1fb6a => {
            try edgeTriangle(metrics, canvas, .right);
            canvas.invert();
            // Set the clip so we don't include anything outside of the cell.
            canvas.clip_left = canvas.padding_x;
            canvas.clip_right = canvas.padding_x;
            canvas.clip_top = canvas.padding_y;
            canvas.clip_bottom = canvas.padding_y;
        },
        // '🭫'
        0x1fb6b => {
            try edgeTriangle(metrics, canvas, .bottom);
            canvas.invert();
            // Set the clip so we don't include anything outside of the cell.
            canvas.clip_left = canvas.padding_x;
            canvas.clip_right = canvas.padding_x;
            canvas.clip_top = canvas.padding_y;
            canvas.clip_bottom = canvas.padding_y;
        },
        // '🭬'
        0x1fb6c => try edgeTriangle(metrics, canvas, .left),
        // '🭭'
        0x1fb6d => try edgeTriangle(metrics, canvas, .top),
        // '🭮'
        0x1fb6e => try edgeTriangle(metrics, canvas, .right),
        // '🭯'
        0x1fb6f => try edgeTriangle(metrics, canvas, .bottom),

        else => unreachable,
    }
}

/// Vertical one eighth blocks
pub fn draw1FB70_1FB75(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = width;
    _ = height;

    const n = cp + 1 - 0x1fb70;

    fill(
        metrics,
        canvas,
        Fraction.eighths[n],
        Fraction.eighths[n + 1],
        .top,
        .bottom,
    );
}

/// Horizontal one eighth blocks
pub fn draw1FB76_1FB7B(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = width;
    _ = height;

    const n = cp + 1 - 0x1fb76;

    fill(
        metrics,
        canvas,
        .left,
        .right,
        Fraction.eighths[n],
        Fraction.eighths[n + 1],
    );
}

pub fn draw1FB7C_1FB97(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    switch (cp) {

        // '🭼' LEFT AND LOWER ONE EIGHTH BLOCK
        0x1fb7c => {
            block.block(metrics, canvas, .left, one_eighth, 1);
            block.block(metrics, canvas, .lower, 1, one_eighth);
        },
        // '🭽' LEFT AND UPPER ONE EIGHTH BLOCK
        0x1fb7d => {
            block.block(metrics, canvas, .left, one_eighth, 1);
            block.block(metrics, canvas, .upper, 1, one_eighth);
        },
        // '🭾' RIGHT AND UPPER ONE EIGHTH BLOCK
        0x1fb7e => {
            block.block(metrics, canvas, .right, one_eighth, 1);
            block.block(metrics, canvas, .upper, 1, one_eighth);
        },
        // '🭿' RIGHT AND LOWER ONE EIGHTH BLOCK
        0x1fb7f => {
            block.block(metrics, canvas, .right, one_eighth, 1);
            block.block(metrics, canvas, .lower, 1, one_eighth);
        },
        // '🮀' UPPER AND LOWER ONE EIGHTH BLOCK
        0x1fb80 => {
            block.block(metrics, canvas, .upper, 1, one_eighth);
            block.block(metrics, canvas, .lower, 1, one_eighth);
        },
        // '🮁' Horizontal One Eighth Block 1358
        0x1fb81 => {
            // We just call the draw function for each of the relevant codepoints.
            // The first codepoint is actually a lie, it's before the range, but
            // we need it to get the first (0th) block position. This might be a
            // bit brittle, oh well, if it breaks we can fix it.
            try draw1FB76_1FB7B(0x1fb74 + 1, canvas, width, height, metrics);
            try draw1FB76_1FB7B(0x1fb74 + 3, canvas, width, height, metrics);
            try draw1FB76_1FB7B(0x1fb74 + 5, canvas, width, height, metrics);
            try draw1FB76_1FB7B(0x1fb74 + 8, canvas, width, height, metrics);
        },

        // '🮂' UPPER ONE QUARTER BLOCK
        0x1fb82 => block.block(metrics, canvas, .upper, 1, one_quarter),
        // '🮃' UPPER THREE EIGHTHS BLOCK
        0x1fb83 => block.block(metrics, canvas, .upper, 1, three_eighths),
        // '🮄' UPPER FIVE EIGHTHS BLOCK
        0x1fb84 => block.block(metrics, canvas, .upper, 1, five_eighths),
        // '🮅' UPPER THREE QUARTERS BLOCK
        0x1fb85 => block.block(metrics, canvas, .upper, 1, three_quarters),
        // '🮆' UPPER SEVEN EIGHTHS BLOCK
        0x1fb86 => block.block(metrics, canvas, .upper, 1, seven_eighths),

        // '🮇' RIGHT ONE QUARTER BLOCK
        0x1fb87 => block.block(metrics, canvas, .right, one_quarter, 1),
        // '🮈' RIGHT THREE EIGHTHS BLOCK
        0x1fb88 => block.block(metrics, canvas, .right, three_eighths, 1),
        // '🮉' RIGHT FIVE EIGHTHS BLOCK
        0x1fb89 => block.block(metrics, canvas, .right, five_eighths, 1),
        // '🮊' RIGHT THREE QUARTERS BLOCK
        0x1fb8a => block.block(metrics, canvas, .right, three_quarters, 1),
        // '🮋' RIGHT SEVEN EIGHTHS BLOCK/
        0x1fb8b => block.block(metrics, canvas, .right, seven_eighths, 1),

        // '🮌'
        0x1fb8c => block.blockShade(metrics, canvas, .left, half, 1, .medium),
        // '🮍'
        0x1fb8d => block.blockShade(metrics, canvas, .right, half, 1, .medium),
        // '🮎'
        0x1fb8e => block.blockShade(metrics, canvas, .upper, 1, half, .medium),
        // '🮏'
        0x1fb8f => block.blockShade(metrics, canvas, .lower, 1, half, .medium),

        // '🮐'
        0x1fb90 => block.fullBlockShade(metrics, canvas, .medium),
        // '🮑'
        0x1fb91 => {
            block.fullBlockShade(metrics, canvas, .medium);
            block.block(metrics, canvas, .upper, 1, half);
        },
        // '🮒'
        0x1fb92 => {
            block.fullBlockShade(metrics, canvas, .medium);
            block.block(metrics, canvas, .lower, 1, half);
        },
        0x1fb93 => {
            // NOTE: This codepoint is currently un-allocated, it's a hole
            //       in the unicode block, so it's safe to just render it
            //       as an empty glyph, probably.
        },
        // '🮔'
        0x1fb94 => {
            block.fullBlockShade(metrics, canvas, .medium);
            block.block(metrics, canvas, .right, half, 1);
        },
        // '🮕'
        0x1fb95 => checkerboardFill(metrics, canvas, 0),
        // '🮖'
        0x1fb96 => checkerboardFill(metrics, canvas, 1),
        // '🮗'
        0x1fb97 => {
            canvas.box(
                0,
                @intCast(height / 4),
                @intCast(width),
                @intCast(2 * height / 4),
                .on,
            );
            canvas.box(
                0,
                @intCast(3 * height / 4),
                @intCast(width),
                @intCast(height),
                .on,
            );
        },

        else => unreachable,
    }
}

/// Upper Left to Lower Right Fill
/// 🮘
pub fn draw1FB98(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    _ = width;
    _ = height;

    // Set the clip so we don't include anything outside of the cell.
    canvas.clip_left = canvas.padding_x;
    canvas.clip_right = canvas.padding_x;
    canvas.clip_top = canvas.padding_y;
    canvas.clip_bottom = canvas.padding_y;

    // TODO: This doesn't align properly for most cell sizes, fix that.

    const thick_px = Thickness.light.height(metrics.box_thickness);
    const line_count = metrics.cell_width / (2 * thick_px);

    const float_width: f64 = @floatFromInt(metrics.cell_width);
    const float_height: f64 = @floatFromInt(metrics.cell_height);
    const float_thick: f64 = @floatFromInt(thick_px);
    const stride = @round(float_width / @as(f64, @floatFromInt(line_count)));

    for (0..line_count * 2 + 1) |_i| {
        const i = @as(i32, @intCast(_i)) - @as(i32, @intCast(line_count));
        const top_x = @as(f64, @floatFromInt(i)) * stride;
        const bottom_x = float_width + top_x;
        canvas.line(.{
            .p0 = .{ .x = top_x, .y = 0 },
            .p1 = .{ .x = bottom_x, .y = float_height },
        }, float_thick, .on) catch {};
    }
}

/// Upper Right to Lower Left Fill
/// 🮙
pub fn draw1FB99(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    _ = width;
    _ = height;

    // Set the clip so we don't include anything outside of the cell.
    canvas.clip_left = canvas.padding_x;
    canvas.clip_right = canvas.padding_x;
    canvas.clip_top = canvas.padding_y;
    canvas.clip_bottom = canvas.padding_y;

    // TODO: This doesn't align properly for most cell sizes, fix that.

    const thick_px = Thickness.light.height(metrics.box_thickness);
    const line_count = metrics.cell_width / (2 * thick_px);

    const float_width: f64 = @floatFromInt(metrics.cell_width);
    const float_height: f64 = @floatFromInt(metrics.cell_height);
    const float_thick: f64 = @floatFromInt(thick_px);
    const stride = @round(float_width / @as(f64, @floatFromInt(line_count)));

    for (0..line_count * 2 + 1) |_i| {
        const i = @as(i32, @intCast(_i)) - @as(i32, @intCast(line_count));
        const bottom_x = @as(f64, @floatFromInt(i)) * stride;
        const top_x = float_width + bottom_x;
        canvas.line(.{
            .p0 = .{ .x = top_x, .y = 0 },
            .p1 = .{ .x = bottom_x, .y = float_height },
        }, float_thick, .on) catch {};
    }
}

pub fn draw1FB9A_1FB9F(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = width;
    _ = height;

    switch (cp) {
        // '🮚'
        0x1fb9a => {
            try edgeTriangle(metrics, canvas, .top);
            try edgeTriangle(metrics, canvas, .bottom);
        },
        // '🮛'
        0x1fb9b => {
            try edgeTriangle(metrics, canvas, .left);
            try edgeTriangle(metrics, canvas, .right);
        },
        // '🮜'
        0x1fb9c => try geo.cornerTriangleShade(metrics, canvas, .tl, .medium),
        // '🮝'
        0x1fb9d => try geo.cornerTriangleShade(metrics, canvas, .tr, .medium),
        // '🮞'
        0x1fb9e => try geo.cornerTriangleShade(metrics, canvas, .br, .medium),
        // '🮟'
        0x1fb9f => try geo.cornerTriangleShade(metrics, canvas, .bl, .medium),

        else => unreachable,
    }
}

pub fn draw1FBA0_1FBAE(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = width;
    _ = height;

    switch (cp) {
        // '🮠'
        0x1fba0 => cornerDiagonalLines(metrics, canvas, .{ .tl = true }),
        // '🮡'
        0x1fba1 => cornerDiagonalLines(metrics, canvas, .{ .tr = true }),
        // '🮢'
        0x1fba2 => cornerDiagonalLines(metrics, canvas, .{ .bl = true }),
        // '🮣'
        0x1fba3 => cornerDiagonalLines(metrics, canvas, .{ .br = true }),
        // '🮤'
        0x1fba4 => cornerDiagonalLines(metrics, canvas, .{ .tl = true, .bl = true }),
        // '🮥'
        0x1fba5 => cornerDiagonalLines(metrics, canvas, .{ .tr = true, .br = true }),
        // '🮦'
        0x1fba6 => cornerDiagonalLines(metrics, canvas, .{ .bl = true, .br = true }),
        // '🮧'
        0x1fba7 => cornerDiagonalLines(metrics, canvas, .{ .tl = true, .tr = true }),
        // '🮨'
        0x1fba8 => cornerDiagonalLines(metrics, canvas, .{ .tl = true, .br = true }),
        // '🮩'
        0x1fba9 => cornerDiagonalLines(metrics, canvas, .{ .tr = true, .bl = true }),
        // '🮪'
        0x1fbaa => cornerDiagonalLines(metrics, canvas, .{ .tr = true, .bl = true, .br = true }),
        // '🮫'
        0x1fbab => cornerDiagonalLines(metrics, canvas, .{ .tl = true, .bl = true, .br = true }),
        // '🮬'
        0x1fbac => cornerDiagonalLines(metrics, canvas, .{ .tl = true, .tr = true, .br = true }),
        // '🮭'
        0x1fbad => cornerDiagonalLines(metrics, canvas, .{ .tl = true, .tr = true, .bl = true }),
        // '🮮'
        0x1fbae => cornerDiagonalLines(metrics, canvas, .{ .tl = true, .tr = true, .bl = true, .br = true }),

        else => unreachable,
    }
}

/// 🮯
pub fn draw1FBAF(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    _ = width;
    _ = height;

    box.linesChar(metrics, canvas, .{
        .up = .heavy,
        .down = .heavy,
        .left = .light,
        .right = .light,
    });
}

/// 🮽
pub fn draw1FBBD(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    _ = width;
    _ = height;

    box.lightDiagonalCross(metrics, canvas);
    canvas.invert();
    // Set the clip so we don't include anything outside of the cell.
    canvas.clip_left = canvas.padding_x;
    canvas.clip_right = canvas.padding_x;
    canvas.clip_top = canvas.padding_y;
    canvas.clip_bottom = canvas.padding_y;
}

/// 🮾
pub fn draw1FBBE(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    _ = width;
    _ = height;

    cornerDiagonalLines(metrics, canvas, .{ .br = true });
    canvas.invert();
    // Set the clip so we don't include anything outside of the cell.
    canvas.clip_left = canvas.padding_x;
    canvas.clip_right = canvas.padding_x;
    canvas.clip_top = canvas.padding_y;
    canvas.clip_bottom = canvas.padding_y;
}

/// 🮿
pub fn draw1FBBF(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    _ = width;
    _ = height;

    cornerDiagonalLines(metrics, canvas, .{
        .tl = true,
        .tr = true,
        .bl = true,
        .br = true,
    });
    canvas.invert();
    // Set the clip so we don't include anything outside of the cell.
    canvas.clip_left = canvas.padding_x;
    canvas.clip_right = canvas.padding_x;
    canvas.clip_top = canvas.padding_y;
    canvas.clip_bottom = canvas.padding_y;
}

/// 🯎
pub fn draw1FBCE(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    _ = width;
    _ = height;

    block.block(metrics, canvas, .left, two_thirds, 1);
}

// 🯏
pub fn draw1FBCF(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    _ = width;
    _ = height;

    block.block(metrics, canvas, .left, one_third, 1);
}

/// Cell diagonals.
pub fn draw1FBD0_1FBDF(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = width;
    _ = height;

    switch (cp) {
        // '🯐'
        0x1fbd0 => cellDiagonal(
            metrics,
            canvas,
            .middle_right,
            .lower_left,
        ),
        // '🯑'
        0x1fbd1 => cellDiagonal(
            metrics,
            canvas,
            .upper_right,
            .middle_left,
        ),
        // '🯒'
        0x1fbd2 => cellDiagonal(
            metrics,
            canvas,
            .upper_left,
            .middle_right,
        ),
        // '🯓'
        0x1fbd3 => cellDiagonal(
            metrics,
            canvas,
            .middle_left,
            .lower_right,
        ),
        // '🯔'
        0x1fbd4 => cellDiagonal(
            metrics,
            canvas,
            .upper_left,
            .lower_center,
        ),
        // '🯕'
        0x1fbd5 => cellDiagonal(
            metrics,
            canvas,
            .upper_center,
            .lower_right,
        ),
        // '🯖'
        0x1fbd6 => cellDiagonal(
            metrics,
            canvas,
            .upper_right,
            .lower_center,
        ),
        // '🯗'
        0x1fbd7 => cellDiagonal(
            metrics,
            canvas,
            .upper_center,
            .lower_left,
        ),
        // '🯘'
        0x1fbd8 => {
            cellDiagonal(
                metrics,
                canvas,
                .upper_left,
                .middle_center,
            );
            cellDiagonal(
                metrics,
                canvas,
                .middle_center,
                .upper_right,
            );
        },
        // '🯙'
        0x1fbd9 => {
            cellDiagonal(
                metrics,
                canvas,
                .upper_right,
                .middle_center,
            );
            cellDiagonal(
                metrics,
                canvas,
                .middle_center,
                .lower_right,
            );
        },
        // '🯚'
        0x1fbda => {
            cellDiagonal(
                metrics,
                canvas,
                .lower_left,
                .middle_center,
            );
            cellDiagonal(
                metrics,
                canvas,
                .middle_center,
                .lower_right,
            );
        },
        // '🯛'
        0x1fbdb => {
            cellDiagonal(
                metrics,
                canvas,
                .upper_left,
                .middle_center,
            );
            cellDiagonal(
                metrics,
                canvas,
                .middle_center,
                .lower_left,
            );
        },
        // '🯜'
        0x1fbdc => {
            cellDiagonal(
                metrics,
                canvas,
                .upper_left,
                .lower_center,
            );
            cellDiagonal(
                metrics,
                canvas,
                .lower_center,
                .upper_right,
            );
        },
        // '🯝'
        0x1fbdd => {
            cellDiagonal(
                metrics,
                canvas,
                .upper_right,
                .middle_left,
            );
            cellDiagonal(
                metrics,
                canvas,
                .middle_left,
                .lower_right,
            );
        },
        // '🯞'
        0x1fbde => {
            cellDiagonal(
                metrics,
                canvas,
                .lower_left,
                .upper_center,
            );
            cellDiagonal(
                metrics,
                canvas,
                .upper_center,
                .lower_right,
            );
        },
        // '🯟'
        0x1fbdf => {
            cellDiagonal(
                metrics,
                canvas,
                .upper_left,
                .middle_right,
            );
            cellDiagonal(
                metrics,
                canvas,
                .middle_right,
                .lower_left,
            );
        },

        else => unreachable,
    }
}

pub fn draw1FBE0_1FBEF(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = width;
    _ = height;

    switch (cp) {
        // '🯠'
        0x1fbe0 => circle(metrics, canvas, .top, false),
        // '🯡'
        0x1fbe1 => circle(metrics, canvas, .right, false),
        // '🯢'
        0x1fbe2 => circle(metrics, canvas, .bottom, false),
        // '🯣'
        0x1fbe3 => circle(metrics, canvas, .left, false),
        // '🯤'
        0x1fbe4 => block.block(metrics, canvas, .upper_center, 0.5, 0.5),
        // '🯥'
        0x1fbe5 => block.block(metrics, canvas, .lower_center, 0.5, 0.5),
        // '🯦'
        0x1fbe6 => block.block(metrics, canvas, .middle_left, 0.5, 0.5),
        // '🯧'
        0x1fbe7 => block.block(metrics, canvas, .middle_right, 0.5, 0.5),
        // '🯨'
        0x1fbe8 => circle(metrics, canvas, .top, true),
        // '🯩'
        0x1fbe9 => circle(metrics, canvas, .right, true),
        // '🯪'
        0x1fbea => circle(metrics, canvas, .bottom, true),
        // '🯫'
        0x1fbeb => circle(metrics, canvas, .left, true),
        // '🯬'
        0x1fbec => circle(metrics, canvas, .top_right, true),
        // '🯭'
        0x1fbed => circle(metrics, canvas, .bottom_left, true),
        // '🯮'
        0x1fbee => circle(metrics, canvas, .bottom_right, true),
        // '🯯'
        0x1fbef => circle(metrics, canvas, .top_left, true),

        else => unreachable,
    }
}

fn edgeTriangle(
    metrics: font.Metrics,
    canvas: *font.sprite.Canvas,
    comptime edge: Edge,
) !void {
    const upper: f64 = 0.0;
    const middle: f64 = @round(@as(f64, @floatFromInt(metrics.cell_height)) / 2);
    const lower: f64 = @floatFromInt(metrics.cell_height);
    const left: f64 = 0.0;
    const center: f64 = @round(@as(f64, @floatFromInt(metrics.cell_width)) / 2);
    const right: f64 = @floatFromInt(metrics.cell_width);

    const x0, const y0, const x1, const y1 = switch (edge) {
        .top => .{ right, upper, left, upper },
        .left => .{ left, upper, left, lower },
        .bottom => .{ left, lower, right, lower },
        .right => .{ right, lower, right, upper },
    };

    var path = canvas.staticPath(5); // nodes.len = 0
    path.moveTo(center, middle); // +1, nodes.len = 1
    path.lineTo(x0, y0); // +1, nodes.len = 2
    path.lineTo(x1, y1); // +1, nodes.len = 3
    path.close(); // +2, nodes.len = 5

    try canvas.fillPath(path.wrapped_path, .{}, .on);
}

fn cornerDiagonalLines(
    metrics: font.Metrics,
    canvas: *font.sprite.Canvas,
    comptime corners: Quads,
) void {
    const thick_px = Thickness.light.height(metrics.box_thickness);

    const float_width: f64 = @floatFromInt(metrics.cell_width);
    const float_height: f64 = @floatFromInt(metrics.cell_height);
    const float_thick: f64 = @floatFromInt(thick_px);
    const center_x: f64 = @floatFromInt(metrics.cell_width / 2 + metrics.cell_width % 2);
    const center_y: f64 = @floatFromInt(metrics.cell_height / 2 + metrics.cell_height % 2);

    if (corners.tl) canvas.line(.{
        .p0 = .{ .x = center_x, .y = 0 },
        .p1 = .{ .x = 0, .y = center_y },
    }, float_thick, .on) catch {};

    if (corners.tr) canvas.line(.{
        .p0 = .{ .x = center_x, .y = 0 },
        .p1 = .{ .x = float_width, .y = center_y },
    }, float_thick, .on) catch {};

    if (corners.bl) canvas.line(.{
        .p0 = .{ .x = center_x, .y = float_height },
        .p1 = .{ .x = 0, .y = center_y },
    }, float_thick, .on) catch {};

    if (corners.br) canvas.line(.{
        .p0 = .{ .x = center_x, .y = float_height },
        .p1 = .{ .x = float_width, .y = center_y },
    }, float_thick, .on) catch {};
}

fn cellDiagonal(
    metrics: font.Metrics,
    canvas: *font.sprite.Canvas,
    comptime from: Alignment,
    comptime to: Alignment,
) void {
    const float_width: f64 = @floatFromInt(metrics.cell_width);
    const float_height: f64 = @floatFromInt(metrics.cell_height);

    const x0: f64 = switch (from.horizontal) {
        .left => 0,
        .right => float_width,
        .center => float_width / 2,
    };
    const y0: f64 = switch (from.vertical) {
        .top => 0,
        .bottom => float_height,
        .middle => float_height / 2,
    };
    const x1: f64 = switch (to.horizontal) {
        .left => 0,
        .right => float_width,
        .center => float_width / 2,
    };
    const y1: f64 = switch (to.vertical) {
        .top => 0,
        .bottom => float_height,
        .middle => float_height / 2,
    };

    canvas.line(
        .{
            .p0 = .{ .x = x0, .y = y0 },
            .p1 = .{ .x = x1, .y = y1 },
        },
        @floatFromInt(Thickness.light.height(metrics.box_thickness)),
        .on,
    ) catch {};
}

fn checkerboardFill(
    metrics: font.Metrics,
    canvas: *font.sprite.Canvas,
    parity: u1,
) void {
    const float_width: f64 = @floatFromInt(metrics.cell_width);
    const float_height: f64 = @floatFromInt(metrics.cell_height);
    const x_size: usize = 4;
    const y_size: usize = @intFromFloat(@round(4 * (float_height / float_width)));
    for (0..x_size) |x| {
        const x0 = (metrics.cell_width * x) / x_size;
        const x1 = (metrics.cell_width * (x + 1)) / x_size;
        for (0..y_size) |y| {
            const y0 = (metrics.cell_height * y) / y_size;
            const y1 = (metrics.cell_height * (y + 1)) / y_size;
            if ((x + y) % 2 == parity) {
                canvas.rect(.{
                    .x = @intCast(x0),
                    .y = @intCast(y0),
                    .width = @intCast(x1 -| x0),
                    .height = @intCast(y1 -| y0),
                }, .on);
            }
        }
    }
}

pub fn circle(
    metrics: font.Metrics,
    canvas: *font.sprite.Canvas,
    comptime position: Alignment,
    comptime filled: bool,
) void {
    // Set the clip so we don't include anything outside of the cell.
    canvas.clip_left = canvas.padding_x;
    canvas.clip_right = canvas.padding_x;
    canvas.clip_top = canvas.padding_y;
    canvas.clip_bottom = canvas.padding_y;

    const float_width: f64 = @floatFromInt(metrics.cell_width);
    const float_height: f64 = @floatFromInt(metrics.cell_height);

    const x: f64 = switch (position.horizontal) {
        .left => 0,
        .right => float_width,
        .center => float_width / 2,
    };
    const y: f64 = switch (position.vertical) {
        .top => 0,
        .bottom => float_height,
        .middle => float_height / 2,
    };
    const r: f64 = 0.5 * @min(float_width, float_height);

    var ctx = canvas.getContext();
    defer ctx.deinit();
    ctx.setSource(.{ .opaque_pattern = .{
        .pixel = .{ .alpha8 = .{ .a = @intFromEnum(Shade.on) } },
    } });
    ctx.setLineWidth(
        @floatFromInt(Thickness.light.height(metrics.box_thickness)),
    );

    if (filled) {
        ctx.arc(x, y, r, 0, std.math.pi * 2) catch return;
        ctx.closePath() catch return;
        ctx.fill() catch return;
    } else {
        ctx.arc(x, y, r - ctx.line_width / 2, 0, std.math.pi * 2) catch return;
        ctx.closePath() catch return;
        ctx.stroke() catch return;
    }
}
