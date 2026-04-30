//! This file contains glyph drawing functions for all of the
//! non-Unicode sprite glyphs, such as cursors and underlines.
//!
//! The naming convention in this file differs from the usual
//! because the draw functions for special sprites are found by
//! having names that exactly match the enum fields in Sprite.

const std = @import("std");
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

    // We can go beyond the height of the cell a bit, but
    // we want to be sure never to exceed the height of the
    // canvas, which extends a quarter cell below the cell
    // height.
    const y = @min(
        metrics.underline_position,
        height +| canvas.padding_y -| metrics.underline_thickness,
    );

    canvas.rect(.{
        .x = 0,
        .y = @intCast(y),
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

    // We can go beyond the height of the cell a bit, but
    // we want to be sure never to exceed the height of the
    // canvas, which extends a quarter cell below the cell
    // height.
    const y = @min(
        metrics.underline_position,
        height +| canvas.padding_y -| 2 * metrics.underline_thickness,
    );

    // We place one underline above the underline position, and one below
    // by one thickness, creating a "negative" underline where the single
    // underline would be placed.
    canvas.rect(.{
        .x = 0,
        .y = @intCast(y -| metrics.underline_thickness),
        .width = @intCast(width),
        .height = @intCast(metrics.underline_thickness),
    }, .on);
    canvas.rect(.{
        .x = 0,
        .y = @intCast(y +| metrics.underline_thickness),
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

    var ctx = canvas.getContext();
    defer ctx.deinit();

    const float_width: f64 = @floatFromInt(width);
    const float_height: f64 = @floatFromInt(height);
    const float_pos: f64 = @floatFromInt(metrics.underline_position);
    const float_thick: f64 = @floatFromInt(metrics.underline_thickness);

    // The diameter will be sqrt2 * the usual underline thickness
    // since otherwise dotted underlines look somewhat anemic.
    const radius = std.math.sqrt1_2 * float_thick;

    // We can go beyond the height of the cell a bit, but
    // we want to be sure never to exceed the height of the
    // canvas, which extends a quarter cell below the cell
    // height.
    const padding: f64 = @floatFromInt(canvas.padding_y);
    const y = @min(
        // The center of the underline stem.
        float_pos + 0.5 * float_thick,
        // The lowest we can go on the canvas and not get clipped.
        float_height + padding - @ceil(radius),
    );

    const dot_count: f64 = @max(
        @min(
            // We should try to have enough dots that the
            // space between them matches their diameter.
            @ceil(float_width / (4 * radius)),
            // And not enough that the space between
            // each dot is less than their radius.
            @floor(float_width / (3 * radius)),
            // And definitely not enough that the space
            // between them is less than a single pixel.
            @floor(float_width / (2 * radius + 1)),
        ),
        // And we must have at least one dot per cell.
        1.0,
    );

    // What we essentially do is divide the cell in to
    // dot_count areas with a dot centered in each one.
    var x: f64 = (float_width / dot_count) / 2;
    for (0..@as(usize, @intFromFloat(dot_count))) |_| {
        try ctx.arc(x, y, radius, 0.0, std.math.tau);
        try ctx.closePath();
        x += float_width / dot_count;
    }

    try ctx.fill();
}

pub fn underline_dashed(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;

    // We can go beyond the height of the cell a bit, but
    // we want to be sure never to exceed the height of the
    // canvas, which extends a quarter cell below the cell
    // height.
    const y = @min(
        metrics.underline_position,
        height +| canvas.padding_y -| metrics.underline_thickness,
    );

    const dash_width = width / 3 + 1;
    const dash_count = (width / dash_width) + 1;
    var i: u32 = 0;
    while (i < dash_count) : (i += 2) {
        const x = i * dash_width;
        canvas.rect(.{
            .x = @intCast(x),
            .y = @intCast(y),
            .width = @intCast(dash_width),
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

    var ctx = canvas.getContext();
    defer ctx.deinit();

    const float_width: f64 = @floatFromInt(width);
    const float_height: f64 = @floatFromInt(height);
    const float_pos: f64 = @floatFromInt(metrics.underline_position);

    // Because of we way we draw the undercurl, we end up making it around 1px
    // thicker than it should be, to fix this we just reduce the thickness by 1.
    //
    // We use a minimum thickness of 0.414 because this empirically produces
    // the nicest undercurls at 1px underline thickness; thinner tends to look
    // too thin compared to straight underlines and has artefacting.
    ctx.line_width = @floatFromInt(metrics.underline_thickness);

    // Rounded caps, adjacent underlines will have these overlap and so not be
    // visible, but it makes the ends look cleaner.
    ctx.line_cap_mode = .round;

    // Empirically this looks good.
    const amplitude = float_width / std.math.pi;

    // Make sure we don't exceed the drawable area. This can still be outside
    // of the cell by some amount (one quarter of the height), but we don't
    // want underlines to disappear for fonts with bad metadata or when users
    // set their underline position way too low.
    const padding: f64 = @floatFromInt(canvas.padding_y);
    const top: f64 = @min(
        float_pos,
        // The lowest we can draw this and not get clipped.
        float_height + padding - amplitude - ctx.line_width,
    );
    const bottom = top + amplitude;

    // Curvature multiplier.
    // To my eye, 0.4 creates a nice smooth wiggle.
    const r = 0.4;

    const center = 0.5 * float_width;

    // We create a single cycle of a wave that peaks at the center of the cell.
    try ctx.moveTo(0, bottom);
    try ctx.curveTo(
        center * r,
        bottom,
        center - center * r,
        top,
        center,
        top,
    );
    try ctx.curveTo(
        center + center * r,
        top,
        float_width - center * r,
        bottom,
        float_width,
        bottom,
    );
    try ctx.stroke();
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

    // We can go beyond the top of the cell a bit, but we
    // want to be sure never to exceed the height of the
    // canvas, which extends a quarter cell above the top
    // of the cell.
    const y = @max(
        metrics.overline_position,
        -@as(i32, @intCast(canvas.padding_y)),
    );

    canvas.rect(.{
        .x = 0,
        .y = y,
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

    // We can go beyond the height of the cell a bit, but
    // we want to be sure never to exceed the height of the
    // canvas, which extends a quarter cell below the cell
    // height.
    const y = @min(
        metrics.underline_position,
        height +| canvas.padding_y -| metrics.underline_thickness,
    );

    canvas.rect(.{
        .x = 0,
        .y = @intCast(y),
        .width = @intCast(width),
        .height = @intCast(metrics.cursor_thickness),
    }, .on);
}
