//! Powerline + Powerline Extra Symbols | U+E0B0...U+E0D4
//! https://github.com/ryanoasis/powerline-extra-symbols
//!
//!                
//!                  
//!      
//!
//! We implement the more geometric glyphs here, but not the stylized ones.
//!

const std = @import("std");
const Allocator = std.mem.Allocator;

const z2d = @import("z2d");

const common = @import("common.zig");
const Thickness = common.Thickness;
const Shade = common.Shade;

const box = @import("box.zig");

const font = @import("../../main.zig");
const Quad = font.sprite.Canvas.Quad;

/// 
pub fn drawE0B0(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    _ = metrics;
    const float_width: f64 = @floatFromInt(width);
    const float_height: f64 = @floatFromInt(height);
    try canvas.triangle(.{
        .p0 = .{ .x = 0, .y = 0 },
        .p1 = .{ .x = float_width, .y = float_height / 2 },
        .p2 = .{ .x = 0, .y = float_height },
    }, .on);
}

/// 
pub fn drawE0B2(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    _ = metrics;
    const float_width: f64 = @floatFromInt(width);
    const float_height: f64 = @floatFromInt(height);
    try canvas.triangle(.{
        .p0 = .{ .x = float_width, .y = 0 },
        .p1 = .{ .x = 0, .y = float_height / 2 },
        .p2 = .{ .x = float_width, .y = float_height },
    }, .on);
}

/// 
pub fn drawE0B8(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    _ = metrics;
    const float_width: f64 = @floatFromInt(width);
    const float_height: f64 = @floatFromInt(height);
    try canvas.triangle(.{
        .p0 = .{ .x = 0, .y = 0 },
        .p1 = .{ .x = float_width, .y = float_height },
        .p2 = .{ .x = 0, .y = float_height },
    }, .on);
}

/// 
pub fn drawE0B9(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    _ = width;
    _ = height;
    box.lightDiagonalUpperLeftToLowerRight(metrics, canvas);
}

/// 
pub fn drawE0BA(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    _ = metrics;
    const float_width: f64 = @floatFromInt(width);
    const float_height: f64 = @floatFromInt(height);
    try canvas.triangle(.{
        .p0 = .{ .x = float_width, .y = 0 },
        .p1 = .{ .x = float_width, .y = float_height },
        .p2 = .{ .x = 0, .y = float_height },
    }, .on);
}

/// 
pub fn drawE0BB(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    _ = width;
    _ = height;
    box.lightDiagonalUpperRightToLowerLeft(metrics, canvas);
}

/// 
pub fn drawE0BC(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    _ = metrics;
    const float_width: f64 = @floatFromInt(width);
    const float_height: f64 = @floatFromInt(height);
    try canvas.triangle(.{
        .p0 = .{ .x = 0, .y = 0 },
        .p1 = .{ .x = float_width, .y = 0 },
        .p2 = .{ .x = 0, .y = float_height },
    }, .on);
}

/// 
pub fn drawE0BD(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    _ = width;
    _ = height;
    box.lightDiagonalUpperRightToLowerLeft(metrics, canvas);
}

/// 
pub fn drawE0BE(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    _ = metrics;
    const float_width: f64 = @floatFromInt(width);
    const float_height: f64 = @floatFromInt(height);
    try canvas.triangle(.{
        .p0 = .{ .x = 0, .y = 0 },
        .p1 = .{ .x = float_width, .y = 0 },
        .p2 = .{ .x = float_width, .y = float_height },
    }, .on);
}

/// 
pub fn drawE0BF(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    _ = width;
    _ = height;
    box.lightDiagonalUpperLeftToLowerRight(metrics, canvas);
}

/// 
pub fn drawE0B1(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    const float_width: f64 = @floatFromInt(width);
    const float_height: f64 = @floatFromInt(height);

    var path = canvas.staticPath(3);
    path.moveTo(0, 0);
    path.lineTo(float_width, float_height / 2);
    path.lineTo(0, float_height);

    try canvas.strokePath(
        path.wrapped_path,
        .{
            .line_cap_mode = .butt,
            .line_width = @floatFromInt(
                Thickness.light.height(metrics.box_thickness),
            ),
        },
        .on,
    );
}

/// 
pub fn drawE0B3(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    try drawE0B1(cp, canvas, width, height, metrics);
    try canvas.flipHorizontal();
}

/// 
pub fn drawE0B4(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    _ = metrics;

    const float_width: f64 = @floatFromInt(width);
    const float_height: f64 = @floatFromInt(height);

    // Coefficient for approximating a circular arc.
    const c: f64 = (std.math.sqrt2 - 1.0) * 4.0 / 3.0;

    const radius: f64 = @min(float_width, float_height / 2);

    var path = canvas.staticPath(6);
    path.moveTo(0, 0);
    path.curveTo(
        radius * c,
        0,
        radius,
        radius - radius * c,
        radius,
        radius,
    );
    path.lineTo(radius, float_height - radius);
    path.curveTo(
        radius,
        float_height - radius + radius * c,
        radius * c,
        float_height,
        0,
        float_height,
    );
    path.close();

    try canvas.fillPath(path.wrapped_path, .{}, .on);
}

/// 
pub fn drawE0B5(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;

    const float_width: f64 = @floatFromInt(width);
    const float_height: f64 = @floatFromInt(height);

    // Coefficient for approximating a circular arc.
    const c: f64 = (std.math.sqrt2 - 1.0) * 4.0 / 3.0;

    const radius: f64 = @min(float_width, float_height / 2);

    var path = canvas.staticPath(4);
    path.moveTo(0, 0);
    path.curveTo(
        radius * c,
        0,
        radius,
        radius - radius * c,
        radius,
        radius,
    );
    path.lineTo(radius, float_height - radius);
    path.curveTo(
        radius,
        float_height - radius + radius * c,
        radius * c,
        float_height,
        0,
        float_height,
    );

    try canvas.innerStrokePath(path.wrapped_path, .{
        .line_width = @floatFromInt(metrics.box_thickness),
        .line_cap_mode = .butt,
    }, .on);
}

/// 
pub fn drawE0B6(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    try drawE0B4(cp, canvas, width, height, metrics);
    try canvas.flipHorizontal();
}

/// 
pub fn drawE0B7(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    try drawE0B5(cp, canvas, width, height, metrics);
    try canvas.flipHorizontal();
}

/// 
pub fn drawE0D2(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;

    const float_width: f64 = @floatFromInt(width);
    const float_height: f64 = @floatFromInt(height);
    const float_thick: f64 = @floatFromInt(metrics.box_thickness);

    // Top piece
    {
        var path = canvas.staticPath(6);
        path.moveTo(0, 0);
        path.lineTo(float_width, 0);
        path.lineTo(float_width / 2, float_height / 2 - float_thick / 2);
        path.lineTo(0, float_height / 2 - float_thick / 2);
        path.close();

        try canvas.fillPath(path.wrapped_path, .{}, .on);
    }

    // Bottom piece
    {
        var path = canvas.staticPath(6);
        path.moveTo(0, float_height);
        path.lineTo(float_width, float_height);
        path.lineTo(float_width / 2, float_height / 2 + float_thick / 2);
        path.lineTo(0, float_height / 2 + float_thick / 2);
        path.close();

        try canvas.fillPath(path.wrapped_path, .{}, .on);
    }
}

/// 
pub fn drawE0D4(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    try drawE0D2(cp, canvas, width, height, metrics);
    try canvas.flipHorizontal();
}
