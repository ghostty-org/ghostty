//! Block Elements | U+2580...U+259F
//! https://en.wikipedia.org/wiki/Block_Elements
//!
//! ▀▁▂▃▄▅▆▇█▉▊▋▌▍▎▏
//! ▐░▒▓▔▕▖▗▘▙▚▛▜▝▞▟
//!

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const z2d = @import("z2d");

const common = @import("common.zig");
const Shade = common.Shade;
const Quads = common.Quads;
const Alignment = common.Alignment;
const fill = common.fill;

const font = @import("../../main.zig");
const Sprite = @import("../../sprite.zig").Sprite;

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

pub fn draw2580_259F(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = width;
    _ = height;

    switch (cp) {
        // '▀' UPPER HALF BLOCK
        0x2580 => block(metrics, canvas, .upper, 1, half),
        // '▁' LOWER ONE EIGHTH BLOCK
        0x2581 => block(metrics, canvas, .lower, 1, one_eighth),
        // '▂' LOWER ONE QUARTER BLOCK
        0x2582 => block(metrics, canvas, .lower, 1, one_quarter),
        // '▃' LOWER THREE EIGHTHS BLOCK
        0x2583 => block(metrics, canvas, .lower, 1, three_eighths),
        // '▄' LOWER HALF BLOCK
        0x2584 => block(metrics, canvas, .lower, 1, half),
        // '▅' LOWER FIVE EIGHTHS BLOCK
        0x2585 => block(metrics, canvas, .lower, 1, five_eighths),
        // '▆' LOWER THREE QUARTERS BLOCK
        0x2586 => block(metrics, canvas, .lower, 1, three_quarters),
        // '▇' LOWER SEVEN EIGHTHS BLOCK
        0x2587 => block(metrics, canvas, .lower, 1, seven_eighths),
        // '█' FULL BLOCK
        0x2588 => fullBlockShade(metrics, canvas, .on),
        // '▉' LEFT SEVEN EIGHTHS BLOCK
        0x2589 => block(metrics, canvas, .left, seven_eighths, 1),
        // '▊' LEFT THREE QUARTERS BLOCK
        0x258a => block(metrics, canvas, .left, three_quarters, 1),
        // '▋' LEFT FIVE EIGHTHS BLOCK
        0x258b => block(metrics, canvas, .left, five_eighths, 1),
        // '▌' LEFT HALF BLOCK
        0x258c => block(metrics, canvas, .left, half, 1),
        // '▍' LEFT THREE EIGHTHS BLOCK
        0x258d => block(metrics, canvas, .left, three_eighths, 1),
        // '▎' LEFT ONE QUARTER BLOCK
        0x258e => block(metrics, canvas, .left, one_quarter, 1),
        // '▏' LEFT ONE EIGHTH BLOCK
        0x258f => block(metrics, canvas, .left, one_eighth, 1),

        // '▐' RIGHT HALF BLOCK
        0x2590 => block(metrics, canvas, .right, half, 1),
        // '░'
        0x2591 => fullBlockShade(metrics, canvas, .light),
        // '▒'
        0x2592 => fullBlockShade(metrics, canvas, .medium),
        // '▓'
        0x2593 => fullBlockShade(metrics, canvas, .dark),
        // '▔' UPPER ONE EIGHTH BLOCK
        0x2594 => block(metrics, canvas, .upper, 1, one_eighth),
        // '▕' RIGHT ONE EIGHTH BLOCK
        0x2595 => block(metrics, canvas, .right, one_eighth, 1),
        // '▖'
        0x2596 => quadrant(metrics, canvas, .{ .bl = true }),
        // '▗'
        0x2597 => quadrant(metrics, canvas, .{ .br = true }),
        // '▘'
        0x2598 => quadrant(metrics, canvas, .{ .tl = true }),
        // '▙'
        0x2599 => quadrant(metrics, canvas, .{ .tl = true, .bl = true, .br = true }),
        // '▚'
        0x259a => quadrant(metrics, canvas, .{ .tl = true, .br = true }),
        // '▛'
        0x259b => quadrant(metrics, canvas, .{ .tl = true, .tr = true, .bl = true }),
        // '▜'
        0x259c => quadrant(metrics, canvas, .{ .tl = true, .tr = true, .br = true }),
        // '▝'
        0x259d => quadrant(metrics, canvas, .{ .tr = true }),
        // '▞'
        0x259e => quadrant(metrics, canvas, .{ .tr = true, .bl = true }),
        // '▟'
        0x259f => quadrant(metrics, canvas, .{ .tr = true, .bl = true, .br = true }),

        else => unreachable,
    }
}

pub fn block(
    metrics: font.Metrics,
    canvas: *font.sprite.Canvas,
    comptime alignment: Alignment,
    comptime width: f64,
    comptime height: f64,
) void {
    blockShade(metrics, canvas, alignment, width, height, .on);
}

pub fn blockShade(
    metrics: font.Metrics,
    canvas: *font.sprite.Canvas,
    comptime alignment: Alignment,
    comptime width: f64,
    comptime height: f64,
    comptime shade: Shade,
) void {
    const float_width: f64 = @floatFromInt(metrics.cell_width);
    const float_height: f64 = @floatFromInt(metrics.cell_height);

    const w: u32 = @intFromFloat(@round(float_width * width));
    const h: u32 = @intFromFloat(@round(float_height * height));

    const x = switch (alignment.horizontal) {
        .left => 0,
        .right => metrics.cell_width - w,
        .center => (metrics.cell_width - w) / 2,
    };
    const y = switch (alignment.vertical) {
        .top => 0,
        .bottom => metrics.cell_height - h,
        .middle => (metrics.cell_height - h) / 2,
    };

    canvas.rect(.{
        .x = @intCast(x),
        .y = @intCast(y),
        .width = @intCast(w),
        .height = @intCast(h),
    }, @as(font.sprite.Color, @enumFromInt(@intFromEnum(shade))));
}

pub fn fullBlockShade(
    metrics: font.Metrics,
    canvas: *font.sprite.Canvas,
    shade: Shade,
) void {
    canvas.box(
        0,
        0,
        @intCast(metrics.cell_width),
        @intCast(metrics.cell_height),
        @as(font.sprite.Color, @enumFromInt(@intFromEnum(shade))),
    );
}

fn quadrant(
    metrics: font.Metrics,
    canvas: *font.sprite.Canvas,
    comptime quads: Quads,
) void {
    if (quads.tl) fill(metrics, canvas, .zero, .half, .zero, .half);
    if (quads.tr) fill(metrics, canvas, .half, .full, .zero, .half);
    if (quads.bl) fill(metrics, canvas, .zero, .half, .half, .full);
    if (quads.br) fill(metrics, canvas, .half, .full, .half, .full);
}
