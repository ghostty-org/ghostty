//! Rasterize Glyph Protocol `glyf` outlines into alpha8 bitmaps via
//! z2d (the same pure-Zig 2D library ghostty uses for its sprite font).
//!
//! The outline comes from `terminal.apc.glyph.glyf.decode()`, which
//! produces a list of contours of `Point{x,y,on_curve}` in the
//! authored `upm` coordinate space (Y-up). This module:
//!
//!   1. walks each contour applying the standard TrueType quadratic
//!      Bézier rules (on-curve, off-curve, implied-on-curve at the
//!      midpoint of two consecutive off-curve points),
//!   2. emits z2d path nodes (z2d only exposes cubic `curveTo`, so
//!      quadratics are degree-elevated to cubics),
//!   3. fills the path into an `image_surface_alpha8` of the requested
//!      pixel dimensions, Y-flipped so the glyph sits visually upright.
//!
//! The returned `Bitmap` owns a grayscale-alpha byte buffer ready to
//! copy into the renderer's grayscale atlas.

const std = @import("std");
const Allocator = std.mem.Allocator;
const z2d = @import("z2d");
const apc_glyph = @import("../terminal/apc/glyph.zig");
const glyf = apc_glyph.glyf;

/// Alpha-only, row-major, top-left origin, stride = `width`.
pub const Bitmap = struct {
    width: u32,
    height: u32,
    data: []u8,

    pub fn deinit(self: *Bitmap, alloc: Allocator) void {
        alloc.free(self.data);
        self.* = undefined;
    }
};

pub const Error = Allocator.Error || z2d.painter.FillError ||
    error{ InvalidSize, InvalidMatrix, NoCurrentPoint };

/// Rasterize `outline` into a `width × height` alpha bitmap.
///
/// The em-square (sized by `upm`) is uniformly scaled to fit the
/// smaller of the two cell dimensions and centred inside the cell.
/// This treats the registration's render span as a single cell — a
/// square glyph in a narrow (1-cell, `width=1`) span never overflows
/// into adjacent cells. Once the v1.7 placement options (`size`,
/// `align`, `pad`, `width`) are wired in, this becomes the
/// `size=contain; align=center,center; pad=0,0,0,0` case.
pub fn rasterize(
    alloc: Allocator,
    outline: glyf.Outline,
    upm: u16,
    width: u32,
    height: u32,
) Error!Bitmap {
    if (width == 0 or height == 0 or upm == 0) return error.InvalidSize;

    var sfc: z2d.Surface = try .init(
        .image_surface_alpha8,
        alloc,
        @intCast(width),
        @intCast(height),
    );
    defer sfc.deinit(alloc);

    // Empty-glyph fast path: allocate a zero bitmap and return.
    if (outline.contours.len == 0) {
        const data = try alloc.alloc(u8, @as(usize, width) * @as(usize, height));
        @memset(data, 0);
        return .{ .width = width, .height = height, .data = data };
    }

    // Transform: uniform scale em → pixel, fitting the em-square into the
    // cell at its smaller dimension so a square glyph never overflows a
    // narrow (1-cell) render span. The em is then centred horizontally
    // and vertically inside the cell.
    //
    // glyf Y is up, raster Y is down. We pin glyf y=upm to the top of the
    // centred em (so the authored top of the em-square lands at the top
    // of the centred area), then transformY flips around `y_base`.
    const w_f: f64 = @floatFromInt(width);
    const h_f: f64 = @floatFromInt(height);
    const upm_f: f64 = @floatFromInt(upm);
    const scale: f64 = @min(w_f / upm_f, h_f / upm_f);
    const em_extent: f64 = upm_f * scale;
    const x_offset: f64 = (w_f - em_extent) / 2.0;
    const y_top: f64 = (h_f - em_extent) / 2.0;
    const y_base: f64 = y_top + em_extent;

    var path: z2d.Path = .empty;
    defer path.deinit(alloc);

    for (outline.contours) |contour| {
        try appendContour(alloc, &path, contour, scale, x_offset, y_base);
    }

    try z2d.painter.fill(
        alloc,
        &sfc,
        &.{ .opaque_pattern = .{
            .pixel = .{ .alpha8 = .{ .a = 255 } },
        } },
        path.nodes.items,
        .{},
    );

    const src = std.mem.sliceAsBytes(sfc.image_surface_alpha8.buf);
    const data = try alloc.alloc(u8, src.len);
    @memcpy(data, src);
    return .{ .width = width, .height = height, .data = data };
}

/// Walk a single glyf contour and append its path nodes to `path`.
/// Implements the TrueType quadratic-Bézier interpretation:
///
///   - two on-curves in a row → straight line,
///   - on → off → on → quadratic Bézier with the off-curve as control,
///   - two off-curves in a row → quadratic to the midpoint of the two
///     off-curve points (implied on-curve), and the second off-curve
///     becomes the next control.
///
/// Quadratics are elevated to cubics for z2d (which only exposes
/// `curveTo`).
fn appendContour(
    alloc: Allocator,
    path: *z2d.Path,
    contour: []const glyf.Point,
    scale: f64,
    x_offset: f64,
    y_base: f64,
) Error!void {
    const n = contour.len;
    if (n == 0) return;

    // Choose a starting on-curve point per TrueType rules: prefer the
    // first point when on-curve; otherwise the last; otherwise the
    // midpoint of the first and last (synthesized). `steps` is the
    // number of contour points we'll visit in the walk loop.
    const start = pickStart(contour, scale, x_offset, y_base);

    try path.moveTo(alloc, start.x, start.y);

    var i = start.idx;
    var cur_x = start.x;
    var cur_y = start.y;
    var pending: ?Ctrl = null;
    var visited: usize = 0;
    while (visited < start.steps) : (visited += 1) {
        const p = contour[i];
        const px = transformX(p.x, scale, x_offset);
        const py = transformY(p.y, scale, y_base);

        if (p.on_curve) {
            if (pending) |c| {
                try quadToCubic(alloc, path, cur_x, cur_y, c.x, c.y, px, py);
                pending = null;
            } else {
                try path.lineTo(alloc, px, py);
            }
            cur_x = px;
            cur_y = py;
        } else if (pending) |c| {
            // Two off-curves in a row: implied on-curve at their midpoint.
            const mx = (c.x + px) / 2.0;
            const my = (c.y + py) / 2.0;
            try quadToCubic(alloc, path, cur_x, cur_y, c.x, c.y, mx, my);
            cur_x = mx;
            cur_y = my;
            pending = .{ .x = px, .y = py };
        } else {
            pending = .{ .x = px, .y = py };
        }
        i = (i + 1) % n;
    }

    // Close the last segment back to the start if a control is still pending.
    if (pending) |c| {
        try quadToCubic(alloc, path, cur_x, cur_y, c.x, c.y, start.x, start.y);
    }

    try path.close(alloc);
}

const Ctrl = struct { x: f64, y: f64 };

const Start = struct {
    x: f64,
    y: f64,
    /// Index of the first contour point to visit after MoveTo.
    idx: usize,
    /// Number of points to visit in the walk. When the start is a real
    /// contour point we skip it in the walk (n-1); when the start is a
    /// synthesized midpoint we walk every point (n).
    steps: usize,
};

fn pickStart(contour: []const glyf.Point, scale: f64, x_offset: f64, y_base: f64) Start {
    const n = contour.len;
    if (contour[0].on_curve) {
        return .{
            .x = transformX(contour[0].x, scale, x_offset),
            .y = transformY(contour[0].y, scale, y_base),
            .idx = 1,
            .steps = n - 1,
        };
    }
    if (contour[n - 1].on_curve) {
        return .{
            .x = transformX(contour[n - 1].x, scale, x_offset),
            .y = transformY(contour[n - 1].y, scale, y_base),
            .idx = 0,
            .steps = n - 1,
        };
    }
    // Both endpoints off-curve: synthesized midpoint. Scale+offset+flip
    // is an affine transform, so the rendered midpoint equals the
    // midpoint of the rendered endpoints.
    return .{
        .x = (transformX(contour[0].x, scale, x_offset) + transformX(contour[n - 1].x, scale, x_offset)) / 2.0,
        .y = (transformY(contour[0].y, scale, y_base) + transformY(contour[n - 1].y, scale, y_base)) / 2.0,
        .idx = 0,
        .steps = n,
    };
}

inline fn transformX(x: i32, scale: f64, x_offset: f64) f64 {
    return x_offset + @as(f64, @floatFromInt(x)) * scale;
}

inline fn transformY(y: i32, scale: f64, y_base: f64) f64 {
    // Y-flip: glyf coordinates grow upward; raster coordinates grow
    // downward. Subtract from y_base so y_max maps to 0 (top).
    return y_base - @as(f64, @floatFromInt(y)) * scale;
}

/// Elevate a quadratic Bézier (cur, ctrl, end) to a cubic the z2d
/// path API can accept:
///
///   cp1 = cur + 2/3 * (ctrl - cur)
///   cp2 = end + 2/3 * (ctrl - end)
fn quadToCubic(
    alloc: Allocator,
    path: *z2d.Path,
    cur_x: f64,
    cur_y: f64,
    cx: f64,
    cy: f64,
    ex: f64,
    ey: f64,
) Error!void {
    const third: f64 = 2.0 / 3.0;
    const cp1x = cur_x + third * (cx - cur_x);
    const cp1y = cur_y + third * (cy - cur_y);
    const cp2x = ex + third * (cx - ex);
    const cp2y = ey + third * (cy - ey);
    try path.curveTo(alloc, cp1x, cp1y, cp2x, cp2y, ex, ey);
}

// -----------------------------------------------------------------------------
// tests

const testing = std.testing;

fn makeSquare(alloc: Allocator) !glyf.Outline {
    // Axis-aligned square from (0,0) to (1000,1000), all on-curve.
    const contour = try alloc.alloc(glyf.Point, 4);
    contour[0] = .{ .x = 0, .y = 0, .on_curve = true };
    contour[1] = .{ .x = 1000, .y = 0, .on_curve = true };
    contour[2] = .{ .x = 1000, .y = 1000, .on_curve = true };
    contour[3] = .{ .x = 0, .y = 1000, .on_curve = true };
    const contours = try alloc.alloc([]glyf.Point, 1);
    contours[0] = contour;
    return .{
        .contours = contours,
        .points = contour,
        .x_min = 0,
        .y_min = 0,
        .x_max = 1000,
        .y_max = 1000,
    };
}

test "rasterize empty glyph returns zero bitmap" {
    var outline: glyf.Outline = .{
        .contours = &.{},
        .points = &.{},
        .x_min = 0,
        .y_min = 0,
        .x_max = 0,
        .y_max = 0,
    };
    defer outline.deinit(testing.allocator);

    var bm = try rasterize(testing.allocator, outline, 1000, 16, 32);
    defer bm.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 16), bm.width);
    try testing.expectEqual(@as(u32, 32), bm.height);
    try testing.expectEqual(@as(usize, 16 * 32), bm.data.len);
    for (bm.data) |b| try testing.expectEqual(@as(u8, 0), b);
}

test "rasterize rejects zero dimensions" {
    var outline = try makeSquare(testing.allocator);
    defer outline.deinit(testing.allocator);
    try testing.expectError(error.InvalidSize, rasterize(testing.allocator, outline, 1000, 0, 32));
    try testing.expectError(error.InvalidSize, rasterize(testing.allocator, outline, 1000, 16, 0));
    try testing.expectError(error.InvalidSize, rasterize(testing.allocator, outline, 0, 16, 32));
}

test "rasterize square fills every pixel" {
    var outline = try makeSquare(testing.allocator);
    defer outline.deinit(testing.allocator);

    var bm = try rasterize(testing.allocator, outline, 1000, 16, 16);
    defer bm.deinit(testing.allocator);

    // The square spans the full em and we asked for a cell the same
    // size, so every pixel except maybe the AA fringe should be fully
    // covered. Accept "strongly covered" rather than "exact 255" since
    // z2d does coverage-based AA.
    var total: u64 = 0;
    for (bm.data) |a| total += a;
    const avg = total / (16 * 16);
    try testing.expect(avg > 200);
}

test "rasterize fits a square em inside a narrow cell without overflow" {
    // Regression: a square em rasterized into a narrow (width < height)
    // cell used to be scaled by `height/upm` on both axes, making the
    // glyph's horizontal extent equal to `cell_height` — so the right
    // half spilled past the bitmap and was clipped. The fix scales by
    // `min(width, height) / upm` and centres horizontally; the right
    // edge column should now also receive coverage.
    var outline = try makeSquare(testing.allocator);
    defer outline.deinit(testing.allocator);

    const cell_w: u32 = 14;
    const cell_h: u32 = 32;
    var bm = try rasterize(testing.allocator, outline, 1000, cell_w, cell_h);
    defer bm.deinit(testing.allocator);

    // The em is scaled to `cell_w` pixels and centred vertically; the
    // glyph occupies the middle row band. Pick a row inside that band
    // and verify both the leftmost and rightmost pixels are covered —
    // proof the glyph didn't overflow the cell.
    const mid_row: usize = cell_h / 2;
    const row_start = mid_row * cell_w;
    try testing.expect(bm.data[row_start] > 200);
    try testing.expect(bm.data[row_start + cell_w - 1] > 200);
}

test "rasterize centre is opaque, corner is clear for a diamond" {
    // Small diamond: on-curve vertices at (500,0), (1000,500), (500,1000),
    // (0,500). Centre of the em should be inside, corners outside.
    const allocator = testing.allocator;
    const contour = try allocator.alloc(glyf.Point, 4);
    contour[0] = .{ .x = 500, .y = 0, .on_curve = true };
    contour[1] = .{ .x = 1000, .y = 500, .on_curve = true };
    contour[2] = .{ .x = 500, .y = 1000, .on_curve = true };
    contour[3] = .{ .x = 0, .y = 500, .on_curve = true };
    const contours = try allocator.alloc([]glyf.Point, 1);
    contours[0] = contour;
    var outline: glyf.Outline = .{
        .contours = contours,
        .points = contour,
        .x_min = 0,
        .y_min = 0,
        .x_max = 1000,
        .y_max = 1000,
    };
    defer outline.deinit(allocator);

    var bm = try rasterize(allocator, outline, 1000, 32, 32);
    defer bm.deinit(allocator);

    // Centre pixel is inside the diamond.
    const centre = bm.data[16 * 32 + 16];
    try testing.expect(centre > 200);
    // Corner (0,0) is outside — should be zero (or nearly so).
    try testing.expect(bm.data[0] < 10);
}
