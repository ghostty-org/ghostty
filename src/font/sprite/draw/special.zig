//! This file contains glyph drawing functions for all of the
//! non-Unicode sprite glyphs, such as cursors and underlines.
//!
//! The naming convention in this file differs from the usual
//! because the draw functions for special sprites are found by
//! having names that exactly match the enum fields in Sprite.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const font = @import("../../main.zig");
const Sprite = font.sprite.Sprite;

pub fn underline(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    _ = height;

    canvas.rect(.{
        .x = 0,
        .y = @intCast(metrics.underline_position),
        .width = @intCast(width),
        .height = @intCast(metrics.underline_thickness),
    }, .on);
}

pub fn underline_double(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    _ = height;

    // We place one underline above the underline position, and one below
    // by one thickness, creating a "negative" underline where the single
    // underline would be placed.
    canvas.rect(.{
        .x = 0,
        .y = @intCast(metrics.underline_position -| metrics.underline_thickness),
        .width = @intCast(width),
        .height = @intCast(metrics.underline_thickness),
    }, .on);
    canvas.rect(.{
        .x = 0,
        .y = @intCast(metrics.underline_position +| metrics.underline_thickness),
        .width = @intCast(width),
        .height = @intCast(metrics.underline_thickness),
    }, .on);
}

pub fn underline_dotted(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    _ = height;

    // TODO: Rework this now that we can go out of bounds, just
    //       make sure that  adjacent versions of this glyph align.
    const dot_width = @max(metrics.underline_thickness, 3);
    const dot_count = @max((width / dot_width) / 2, 1);
    const gap_width = std.math.divCeil(
        u32,
        width -| (dot_count * dot_width),
        dot_count,
    ) catch return error.MathError;
    var i: u32 = 0;
    while (i < dot_count) : (i += 1) {
        // Ensure we never go out of bounds for the rect
        const x = @min(i * (dot_width + gap_width), width - 1);
        const rect_width = @min(width - x, dot_width);
        canvas.rect(.{
            .x = @intCast(x),
            .y = @intCast(metrics.underline_position),
            .width = @intCast(rect_width),
            .height = @intCast(metrics.underline_thickness),
        }, .on);
    }
}

pub fn underline_dashed(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    _ = height;

    const dash_width = width / 3 + 1;
    const dash_count = (width / dash_width) + 1;
    var i: u32 = 0;
    while (i < dash_count) : (i += 2) {
        // Ensure we never go out of bounds for the rect
        const x = @min(i * dash_width, width - 1);
        const rect_width = @min(width - x, dash_width);
        canvas.rect(.{
            .x = @intCast(x),
            .y = @intCast(metrics.underline_position),
            .width = @intCast(rect_width),
            .height = @intCast(metrics.underline_thickness),
        }, .on);
    }
}

pub fn underline_curly(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    _ = height;

    // TODO: Rework this using z2d, this is pretty cool code and all but
    //       it doesn't need to be highly optimized and z2d path drawing
    //       code would be clearer and nicer to have.

    const float_width: f64 = @floatFromInt(width);
    // Because of we way we draw the undercurl, we end up making it around 1px
    // thicker than it should be, to fix this we just reduce the thickness by 1.
    //
    // We use a minimum thickness of 0.414 because this empirically produces
    // the nicest undercurls at 1px underline thickness; thinner tends to look
    // too thin compared to straight underlines and has artefacting.
    const float_thick: f64 = @max(
        0.414,
        @as(f64, @floatFromInt(metrics.underline_thickness -| 1)),
    );

    // Calculate the wave period for a single character
    //   `2 * pi...` = 1 peak per character
    //   `4 * pi...` = 2 peaks per character
    const wave_period = 2 * std.math.pi / float_width;

    // The full amplitude of the wave can be from the bottom to the
    // underline position. We also calculate our mid y point of the wave
    const half_amplitude = 1.0 / wave_period;
    const y_mid: f64 = half_amplitude + float_thick * 0.5 + 1;

    // Offset to move the undercurl up slightly.
    const y_off: u32 = @intFromFloat(half_amplitude * 0.5);

    // This is used in calculating the offset curve estimate below.
    const offset_factor = @min(1.0, float_thick * 0.5 * wave_period) * @min(
        1.0,
        half_amplitude * wave_period,
    );

    // follow Xiaolin Wu's antialias algorithm to draw the curve
    var x: u32 = 0;
    while (x < width) : (x += 1) {
        // We sample the wave function at the *middle* of each
        // pixel column, to ensure that it renders symmetrically.
        const t: f64 = (@as(f64, @floatFromInt(x)) + 0.5) * wave_period;
        // Use the slope at this location to add thickness to
        // the line on this column, counteracting the thinning
        // caused by the slope.
        //
        // This is not the exact offset curve for a sine wave,
        // but it's a decent enough approximation.
        //
        // How did I derive this? I stared at Desmos and fiddled
        // with numbers for an hour until it was good enough.
        const t_u: f64 = t + std.math.pi;
        const slope_factor_u: f64 =
            (@sin(t_u) * @sin(t_u) * offset_factor) /
            ((1.0 + @cos(t_u / 2) * @cos(t_u / 2) * 2) * wave_period);
        const slope_factor_l: f64 =
            (@sin(t) * @sin(t) * offset_factor) /
            ((1.0 + @cos(t / 2) * @cos(t / 2) * 2) * wave_period);

        const cosx: f64 = @cos(t);
        // This will be the center of our stroke.
        const y: f64 = y_mid + half_amplitude * cosx;

        // The upper pixel and lower pixel are
        // calculated relative to the center.
        const y_u: f64 = y - float_thick * 0.5 - slope_factor_u;
        const y_l: f64 = y + float_thick * 0.5 + slope_factor_l;
        const y_upper: u32 = @intFromFloat(@floor(y_u));
        const y_lower: u32 = @intFromFloat(@ceil(y_l));
        const alpha_u: u8 = @intFromFloat(
            @round(255 * (1.0 - @abs(y_u - @floor(y_u)))),
        );
        const alpha_l: u8 = @intFromFloat(
            @round(255 * (1.0 - @abs(y_l - @ceil(y_l)))),
        );

        // upper and lower bounds
        canvas.pixel(
            @intCast(x),
            @intCast(metrics.underline_position +| y_upper -| y_off),
            @enumFromInt(alpha_u),
        );
        canvas.pixel(
            @intCast(x),
            @intCast(metrics.underline_position +| y_lower -| y_off),
            @enumFromInt(alpha_l),
        );

        // fill between upper and lower bound
        var y_fill: u32 = y_upper + 1;
        while (y_fill < y_lower) : (y_fill += 1) {
            canvas.pixel(
                @intCast(x),
                @intCast(metrics.underline_position +| y_fill -| y_off),
                .on,
            );
        }
    }
}

pub fn strikethrough(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    _ = height;

    canvas.rect(.{
        .x = 0,
        .y = @intCast(metrics.strikethrough_position),
        .width = @intCast(width),
        .height = @intCast(metrics.strikethrough_thickness),
    }, .on);
}

pub fn overline(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    _ = height;

    canvas.rect(.{
        .x = 0,
        .y = @intCast(metrics.overline_position),
        .width = @intCast(width),
        .height = @intCast(metrics.overline_thickness),
    }, .on);
}

pub fn cursor_rect(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    _ = metrics;

    canvas.rect(.{
        .x = 0,
        .y = 0,
        .width = @intCast(width),
        .height = @intCast(height),
    }, .on);
}

pub fn cursor_hollow_rect(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;

    // We fill the entire rect and then hollow out the inside, this isn't very
    // efficient but it doesn't need to be and it's the easiest way to write it.
    canvas.rect(.{
        .x = 0,
        .y = 0,
        .width = @intCast(width),
        .height = @intCast(height),
    }, .on);
    canvas.rect(.{
        .x = @intCast(metrics.cursor_thickness),
        .y = @intCast(metrics.cursor_thickness),
        .width = @intCast(width -| metrics.cursor_thickness * 2),
        .height = @intCast(height -| metrics.cursor_thickness * 2),
    }, .off);
}

pub fn cursor_bar(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    _ = width;

    // We place the bar cursor half of its thickness over the left edge of the
    // cell, so that it sits centered between characters, not biased to a side.
    //
    // We round up (add 1 before dividing by 2) because, empirically, having a
    // 1px cursor shifted left a pixel looks better than having it not shifted.
    canvas.rect(.{
        .x = -@as(i32, @intCast((metrics.cursor_thickness + 1) / 2)),
        .y = 0,
        .width = @intCast(metrics.cursor_thickness),
        .height = @intCast(height),
    }, .on);
}

pub fn cursor_underline(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    _ = height;

    canvas.rect(.{
        .x = 0,
        .y = @intCast(metrics.underline_position),
        .width = @intCast(width),
        .height = @intCast(metrics.cursor_thickness),
    }, .on);
}
