//! Geometric Shapes | U+25A0...U+25FF
//! https://en.wikipedia.org/wiki/Geometric_Shapes_(Unicode_block)
//!
//! ■ □ ▢ ▣ ▤ ▥ ▦ ▧ ▨ ▩ ▪ ▫ ▬ ▭ ▮ ▯
//! ▰ ▱ ▲ △ ▴ ▵ ▶ ▷ ▸ ▹ ► ▻ ▼ ▽ ▾ ▿
//! ◀ ◁ ◂ ◃ ◄ ◅ ◆ ◇ ◈ ◉ ◊ ○ ◌ ◍ ◎ ●
//! ◐ ◑ ◒ ◓ ◔ ◕ ◖ ◗ ◘ ◙ ◚ ◛ ◜ ◝ ◞ ◟
//! ◠ ◡ ◢ ◣ ◤ ◥ ◦ ◧ ◨ ◩ ◪ ◫ ◬ ◭ ◮ ◯
//! ◰ ◱ ◲ ◳ ◴ ◵ ◶ ◷ ◸ ◹ ◺ ◻ ◼ ◽︎◾︎◿
//!
//! Only a subset of this block is viable for sprite drawing; filling
//! out this file to have full coverage of this block is not the goal.
//!

const std = @import("std");
const Allocator = std.mem.Allocator;

const z2d = @import("z2d");

const common = @import("common.zig");
const Thickness = common.Thickness;
const Corner = common.Corner;
const Shade = common.Shade;

const font = @import("../../main.zig");

/// ◢ ◣ ◤ ◥
pub fn draw25E2_25E5(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = width;
    _ = height;
    switch (cp) {
        // ◢
        0x25e2 => try cornerTriangleShade(metrics, canvas, .br, .on),
        // ◣
        0x25e3 => try cornerTriangleShade(metrics, canvas, .bl, .on),
        // ◤
        0x25e4 => try cornerTriangleShade(metrics, canvas, .tl, .on),
        // ◥
        0x25e5 => try cornerTriangleShade(metrics, canvas, .tr, .on),

        else => unreachable,
    }
}

/// ◸ ◹ ◺
pub fn draw25F8_25FA(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = width;
    _ = height;
    switch (cp) {
        // ◸
        0x25f8 => try cornerTriangleOutline(metrics, canvas, .tl),
        // ◹
        0x25f9 => try cornerTriangleOutline(metrics, canvas, .tr),
        // ◺
        0x25fa => try cornerTriangleOutline(metrics, canvas, .bl),

        else => unreachable,
    }
}

/// ◿
pub fn draw25FF(
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) !void {
    _ = cp;
    _ = width;
    _ = height;
    try cornerTriangleOutline(metrics, canvas, .br);
}

pub fn cornerTriangleShade(
    metrics: font.Metrics,
    canvas: *font.sprite.Canvas,
    comptime corner: Corner,
    comptime shade: Shade,
) !void {
    const float_width: f64 = @floatFromInt(metrics.cell_width);
    const float_height: f64 = @floatFromInt(metrics.cell_height);

    const x0, const y0, const x1, const y1, const x2, const y2 =
        switch (corner) {
            .tl => .{
                0,
                0,
                0,
                float_height,
                float_width,
                0,
            },
            .tr => .{
                0,
                0,
                float_width,
                float_height,
                float_width,
                0,
            },
            .bl => .{
                0,
                0,
                0,
                float_height,
                float_width,
                float_height,
            },
            .br => .{
                0,
                float_height,
                float_width,
                float_height,
                float_width,
                0,
            },
        };

    var path = canvas.staticPath(5); // nodes.len = 0
    path.moveTo(x0, y0); // +1, nodes.len = 1
    path.lineTo(x1, y1); // +1, nodes.len = 2
    path.lineTo(x2, y2); // +1, nodes.len = 3
    path.close(); // +2, nodes.len = 5

    try canvas.fillPath(
        path.wrapped_path,
        .{},
        @enumFromInt(@intFromEnum(shade)),
    );
}

pub fn cornerTriangleOutline(
    metrics: font.Metrics,
    canvas: *font.sprite.Canvas,
    comptime corner: Corner,
) !void {
    const float_thick: f64 = @floatFromInt(Thickness.light.height(metrics.box_thickness));
    const float_width: f64 = @floatFromInt(metrics.cell_width);
    const float_height: f64 = @floatFromInt(metrics.cell_height);

    const x0, const y0, const x1, const y1, const x2, const y2 =
        switch (corner) {
            .tl => .{
                0,
                0,
                0,
                float_height,
                float_width,
                0,
            },
            .tr => .{
                0,
                0,
                float_width,
                float_height,
                float_width,
                0,
            },
            .bl => .{
                0,
                0,
                0,
                float_height,
                float_width,
                float_height,
            },
            .br => .{
                0,
                float_height,
                float_width,
                float_height,
                float_width,
                0,
            },
        };

    var path = canvas.staticPath(5); // nodes.len = 0
    path.moveTo(x0, y0); // +1, nodes.len = 1
    path.lineTo(x1, y1); // +1, nodes.len = 2
    path.lineTo(x2, y2); // +1, nodes.len = 3
    path.close(); // +2, nodes.len = 5

    try canvas.innerStrokePath(path.wrapped_path, .{
        .line_cap_mode = .butt,
        .line_width = float_thick,
    }, .on);
}
