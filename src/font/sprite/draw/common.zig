//! This file contains a set of useful helper functions
//! and types for drawing our sprite font glyphs. These
//! are generally applicable to multiple sets of glyphs
//! rather than being single-use.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const z2d = @import("z2d");

const font = @import("../../main.zig");
const Sprite = @import("../../sprite.zig").Sprite;

const log = std.log.scoped(.sprite_font);

// Utility names for common fractions
pub const one_eighth: f64 = 0.125;
pub const one_quarter: f64 = 0.25;
pub const one_third: f64 = (1.0 / 3.0);
pub const three_eighths: f64 = 0.375;
pub const half: f64 = 0.5;
pub const five_eighths: f64 = 0.625;
pub const two_thirds: f64 = (2.0 / 3.0);
pub const three_quarters: f64 = 0.75;
pub const seven_eighths: f64 = 0.875;

/// The thickness of a line.
pub const Thickness = enum {
    super_light,
    light,
    heavy,

    /// Calculate the real height of a line based on its
    /// thickness and a base thickness value. The base
    /// thickness value is expected to be in pixels.
    pub fn height(self: Thickness, base: u32) u32 {
        return switch (self) {
            .super_light => @max(base / 2, 1),
            .light => base,
            .heavy => base * 2,
        };
    }
};

/// Shades.
pub const Shade = enum(u8) {
    off = 0x00,
    light = 0x40,
    medium = 0x80,
    dark = 0xc0,
    on = 0xff,

    _,
};

/// Applicable to any set of glyphs with features
/// that may be present or not in each quadrant.
pub const Quads = packed struct(u4) {
    tl: bool = false,
    tr: bool = false,
    bl: bool = false,
    br: bool = false,
};

/// A corner of a cell.
pub const Corner = enum(u2) {
    tl,
    tr,
    bl,
    br,
};

/// An edge of a cell.
pub const Edge = enum(u2) {
    top,
    left,
    bottom,
    right,
};

/// Alignment of a figure within a cell.
pub const Alignment = struct {
    horizontal: enum {
        left,
        right,
        center,
    } = .center,

    vertical: enum {
        top,
        bottom,
        middle,
    } = .middle,

    pub const upper: Alignment = .{ .vertical = .top };
    pub const lower: Alignment = .{ .vertical = .bottom };
    pub const left: Alignment = .{ .horizontal = .left };
    pub const right: Alignment = .{ .horizontal = .right };

    pub const upper_left: Alignment = .{ .vertical = .top, .horizontal = .left };
    pub const upper_right: Alignment = .{ .vertical = .top, .horizontal = .right };
    pub const lower_left: Alignment = .{ .vertical = .bottom, .horizontal = .left };
    pub const lower_right: Alignment = .{ .vertical = .bottom, .horizontal = .right };

    pub const center: Alignment = .{};

    pub const upper_center = upper;
    pub const lower_center = lower;
    pub const middle_left = left;
    pub const middle_right = right;
    pub const middle_center: Alignment = center;

    pub const top = upper;
    pub const bottom = lower;
    pub const center_top = top;
    pub const center_bottom = bottom;

    pub const top_left = upper_left;
    pub const top_right = upper_right;
    pub const bottom_left = lower_left;
    pub const bottom_right = lower_right;
};

/// Fill a rect, clamped to within the cell boundaries.
///
/// TODO: Eliminate usages of this, prefer `canvas.box`.
pub fn rect(
    metrics: font.Metrics,
    canvas: *font.sprite.Canvas,
    x1: u32,
    y1: u32,
    x2: u32,
    y2: u32,
) void {
    canvas.box(
        @intCast(@min(@max(x1, 0), metrics.cell_width)),
        @intCast(@min(@max(y1, 0), metrics.cell_height)),
        @intCast(@min(@max(x2, 0), metrics.cell_width)),
        @intCast(@min(@max(y2, 0), metrics.cell_height)),
        .on,
    );
}

/// Centered vertical line of the provided thickness.
pub fn vlineMiddle(
    metrics: font.Metrics,
    canvas: *font.sprite.Canvas,
    thickness: Thickness,
) void {
    const thick_px = thickness.height(metrics.box_thickness);
    vline(
        canvas,
        0,
        @intCast(metrics.cell_height),
        @intCast((metrics.cell_width -| thick_px) / 2),
        thick_px,
    );
}

/// Centered horizontal line of the provided thickness.
pub fn hlineMiddle(
    metrics: font.Metrics,
    canvas: *font.sprite.Canvas,
    thickness: Thickness,
) void {
    const thick_px = thickness.height(metrics.box_thickness);
    hline(
        canvas,
        0,
        @intCast(metrics.cell_width),
        @intCast((metrics.cell_height -| thick_px) / 2),
        thick_px,
    );
}

/// Vertical line with the left edge at `x`, between `y1` and `y2`.
pub fn vline(
    canvas: *font.sprite.Canvas,
    y1: i32,
    y2: i32,
    x: i32,
    thickness_px: u32,
) void {
    canvas.box(x, y1, x + @as(i32, @intCast(thickness_px)), y2, .on);
}

/// Horizontal line with the top edge at `y`, between `x1` and `x2`.
pub fn hline(
    canvas: *font.sprite.Canvas,
    x1: i32,
    x2: i32,
    y: i32,
    thickness_px: u32,
) void {
    canvas.box(x1, y, x2, y + @as(i32, @intCast(thickness_px)), .on);
}

/// xHalfs[0] should be used as the right edge of a left-aligned half.
/// xHalfs[1] should be used as the left edge of a right-aligned half.
pub fn xHalfs(metrics: font.Metrics) [2]u32 {
    const float_width: f64 = @floatFromInt(metrics.cell_width);
    const half_width: u32 = @intFromFloat(@round(0.5 * float_width));
    return .{ half_width, metrics.cell_width - half_width };
}

/// Use these values as such:
/// yThirds[0] bottom edge of the first third.
/// yThirds[1] top edge of the second third.
/// yThirds[2] bottom edge of the second third.
/// yThirds[3] top edge of the final third.
pub fn yThirds(metrics: font.Metrics) [4]u32 {
    const float_height: f64 = @floatFromInt(metrics.cell_height);
    const one_third_height: u32 = @intFromFloat(@round(one_third * float_height));
    const two_thirds_height: u32 = @intFromFloat(@round(two_thirds * float_height));
    return .{
        one_third_height,
        metrics.cell_height - two_thirds_height,
        two_thirds_height,
        metrics.cell_height - one_third_height,
    };
}

/// Use these values as such:
/// yQuads[0] bottom edge of first quarter.
/// yQuads[1] top edge of second quarter.
/// yQuads[2] bottom edge of second quarter.
/// yQuads[3] top edge of third quarter.
/// yQuads[4] bottom edge of third quarter
/// yQuads[5] top edge of fourth quarter.
pub fn yQuads(metrics: font.Metrics) [6]u32 {
    const float_height: f64 = @floatFromInt(metrics.cell_height);
    const quarter_height: u32 = @intFromFloat(@round(0.25 * float_height));
    const half_height: u32 = @intFromFloat(@round(0.50 * float_height));
    const three_quarters_height: u32 = @intFromFloat(@round(0.75 * float_height));
    return .{
        quarter_height,
        metrics.cell_height - three_quarters_height,
        half_height,
        metrics.cell_height - half_height,
        three_quarters_height,
        metrics.cell_height - quarter_height,
    };
}
