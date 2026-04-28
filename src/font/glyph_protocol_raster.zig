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
const colr = apc_glyph.request.colr;

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

/// Rasterize `outline` into a `width × height` alpha bitmap using a
/// uniform scale of `height / upm` (glyphs are typed at em size, so
/// mapping em → cell height is the natural default).
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

    // Transform: uniform scale em → pixel. glyf Y is up, raster Y is down,
    // so flip around y_max. An optional x-offset centres narrow glyphs in
    // the cell (callers that want cell-fit layout can override upstream).
    const scale: f64 = @as(f64, @floatFromInt(height)) / @as(f64, @floatFromInt(upm));
    const y_base: f64 = @as(f64, @floatFromInt(outline.y_max)) * scale;

    var path: z2d.Path = .empty;
    defer path.deinit(alloc);

    for (outline.contours) |contour| {
        try appendContour(alloc, &path, contour, scale, y_base);
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
    y_base: f64,
) Error!void {
    const n = contour.len;
    if (n == 0) return;

    // Choose a starting on-curve point per TrueType rules: prefer the
    // first point when on-curve; otherwise the last; otherwise the
    // midpoint of the first and last (synthesized). `steps` is the
    // number of contour points we'll visit in the walk loop.
    const start = pickStart(contour, scale, y_base);

    try path.moveTo(alloc, start.x, start.y);

    var i = start.idx;
    var cur_x = start.x;
    var cur_y = start.y;
    var pending: ?Ctrl = null;
    var visited: usize = 0;
    while (visited < start.steps) : (visited += 1) {
        const p = contour[i];
        const px = transformX(p.x, scale);
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

fn pickStart(contour: []const glyf.Point, scale: f64, y_base: f64) Start {
    const n = contour.len;
    if (contour[0].on_curve) {
        return .{
            .x = transformX(contour[0].x, scale),
            .y = transformY(contour[0].y, scale, y_base),
            .idx = 1,
            .steps = n - 1,
        };
    }
    if (contour[n - 1].on_curve) {
        return .{
            .x = transformX(contour[n - 1].x, scale),
            .y = transformY(contour[n - 1].y, scale, y_base),
            .idx = 0,
            .steps = n - 1,
        };
    }
    // Both endpoints off-curve: synthesized midpoint. Scale+flip is an
    // affine transform, so the rendered midpoint equals the midpoint of
    // the rendered endpoints.
    return .{
        .x = (transformX(contour[0].x, scale) + transformX(contour[n - 1].x, scale)) / 2.0,
        .y = (transformY(contour[0].y, scale, y_base) + transformY(contour[n - 1].y, scale, y_base)) / 2.0,
        .idx = 0,
        .steps = n,
    };
}

inline fn transformX(x: i32, scale: f64) f64 {
    return @as(f64, @floatFromInt(x)) * scale;
}

inline fn transformY(y: i32, scale: f64, y_base: f64) f64 {
    // Y-flip: glyf coordinates grow upward; raster coordinates grow
    // downward. Subtract from y_base so y_max maps to 0 (top).
    return y_base - @as(f64, @floatFromInt(y)) * scale;
}

// =============================================================================
// Colour (COLR) rasterization

/// Straight-alpha sRGBA colour used by the colour rasterizer inputs
/// (CPAL palette entries and the current foreground). Converted to
/// z2d's premultiplied representation at fill time.
pub const Rgba = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,
};

/// RGBA8 bitmap produced by the COLR rasterizer. Row-major, top-left
/// origin, stride = `width * 4`, straight alpha.
pub const ColorBitmap = struct {
    width: u32,
    height: u32,
    /// Length = `width * height * 4`.
    data: []u8,

    pub fn deinit(self: *ColorBitmap, alloc: Allocator) void {
        alloc.free(self.data);
        self.* = undefined;
    }
};

pub const ColorError = Error || colr.ParseError || glyf.DecodeError;

/// Render a COLR v0 container into a colour bitmap at (`width`,
/// `height`). Walks the layer chain for glyph 0 (the base), resolving
/// each layer's palette index to either a CPAL colour or the supplied
/// `foreground` (for index `0xFFFF`).
///
/// Layers composite in painter order with `src-over` — COLR v0 defines
/// no other compositing mode, so no graphics-state stack is needed.
pub fn rasterizeColrV0(
    alloc: Allocator,
    container: colr.Container,
    upm: u16,
    width: u32,
    height: u32,
    foreground: Rgba,
) ColorError!ColorBitmap {
    if (width == 0 or height == 0 or upm == 0) return error.InvalidSize;

    var sfc: z2d.Surface = try .init(
        .image_surface_rgba,
        alloc,
        @intCast(width),
        @intCast(height),
    );
    defer sfc.deinit(alloc);

    const colr_table = try colr.parseColrV0(container.colr);
    const cpal_table = try colr.parseCpal(container.cpal);

    // Spec §8.6 says glyph 0 of the container is the base. In practice
    // many extractors keep the source font's original glyph ids (glyph
    // 0 reserved for `.notdef`), so the base record isn't at glyph_id
    // 0 — fall back to the first base record in sorted order, which
    // by the OpenType `sorted by glyphID` rule is the one we want.
    const base = colr_table.findBaseGlyph(0) orelse
        (colr_table.baseGlyphAt(0) catch null);

    if (base) |b| {
        var i: u16 = 0;
        while (i < b.num_layers) : (i += 1) {
            const layer = try colr_table.layerAt(b.first_layer_index + i);
            const colour = resolveColor(cpal_table, layer.palette_index, foreground);
            try fillLayer(
                alloc,
                &sfc,
                container,
                layer.glyph_id,
                upm,
                width,
                height,
                colour,
            );
        }
    } else {
        // Empty COLR — render whatever's at outline 0 in foreground.
        try fillLayer(alloc, &sfc, container, 0, upm, width, height, foreground);
    }

    return extractRgba(alloc, &sfc, width, height);
}

/// Render a COLR v1 container. The full v1 paint graph (gradients,
/// affine transforms, compositing modes) isn't implemented yet; this
/// walker reuses the v0 base/layer records that v1 preserves for
/// back-compat. If the v1 font omitted those (numBaseGlyphRecords=0
/// — all state lives in the paint graph), we fall back to painting
/// every non-`.notdef` outline in foreground, producing a monochrome
/// silhouette — still not the author's intended look, but a visible
/// stand-in until the real paint-graph walker lands.
pub fn rasterizeColrV1(
    alloc: Allocator,
    container: colr.Container,
    upm: u16,
    width: u32,
    height: u32,
    foreground: Rgba,
) ColorError!ColorBitmap {
    if (width == 0 or height == 0 or upm == 0) return error.InvalidSize;

    var sfc: z2d.Surface = try .init(
        .image_surface_rgba,
        alloc,
        @intCast(width),
        @intCast(height),
    );
    defer sfc.deinit(alloc);

    // Step 1: try the v0 walker. Many "v1" containers populate both
    // tables for fallback; if they do, treat the v1 like a v0 here.
    if (colr.parseColrV0(container.colr)) |colr_table| {
        if (colr_table.num_base_records > 0) {
            const maybe_cpal: ?colr.Cpal = if (container.cpal.len == 0)
                null
            else
                colr.parseCpal(container.cpal) catch null;

            const base = colr_table.findBaseGlyph(0) orelse
                (colr_table.baseGlyphAt(0) catch null);

            if (base) |b| {
                var i: u16 = 0;
                while (i < b.num_layers) : (i += 1) {
                    const layer = try colr_table.layerAt(b.first_layer_index + i);
                    const colour = if (maybe_cpal) |cpal|
                        resolveColor(cpal, layer.palette_index, foreground)
                    else
                        foreground;
                    try fillLayer(
                        alloc,
                        &sfc,
                        container,
                        layer.glyph_id,
                        upm,
                        width,
                        height,
                        colour,
                    );
                }
                return extractRgba(alloc, &sfc, width, height);
            }
        }
    } else |_| {}

    // Step 2: silhouette fallback. Paint every non-empty outline past
    // index 0 (.notdef is reserved at 0 by fontTools/nanoemoji) with
    // the CPAL[0] colour or the current foreground.
    const silhouette_colour = if (container.cpal.len == 0)
        foreground
    else blk: {
        const cpal_table = colr.parseCpal(container.cpal) catch break :blk foreground;
        break :blk if (cpal_table.resolve(0)) |c| Rgba{
            .r = c.r,
            .g = c.g,
            .b = c.b,
            .a = c.a,
        } else foreground;
    };

    var i: u16 = 1;
    while (i < container.outlines.len) : (i += 1) {
        fillLayer(alloc, &sfc, container, i, upm, width, height, silhouette_colour) catch |err| switch (err) {
            // A malformed inner outline shouldn't take down the whole
            // glyph — skip the bad layer and keep going.
            error.Composite, error.Hinted, error.Malformed => continue,
            else => return err,
        };
    }

    return extractRgba(alloc, &sfc, width, height);
}

fn resolveColor(cpal: colr.Cpal, index: u16, foreground: Rgba) Rgba {
    if (index == colr.Cpal.foreground_index) return foreground;
    if (cpal.resolve(index)) |c| return .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a };
    return foreground;
}

/// Decode one inner outline from `container.outlines[glyph_id]`, walk
/// it into a z2d path, and fill on `sfc` with `colour`.
fn fillLayer(
    alloc: Allocator,
    sfc: *z2d.Surface,
    container: colr.Container,
    glyph_id: u16,
    upm: u16,
    width: u32,
    height: u32,
    colour: Rgba,
) ColorError!void {
    if (glyph_id >= container.outlines.len) return error.Malformed;
    const glyf_bytes = container.outlines[glyph_id];

    // Empty inner outlines are legal container entries (e.g. a layer
    // that should render nothing). Skip them without allocating.
    if (glyf_bytes.len == 0) return;

    var outline = try glyf.decode(alloc, glyf_bytes);
    defer outline.deinit(alloc);
    if (outline.contours.len == 0) return;

    var path: z2d.Path = .empty;
    defer path.deinit(alloc);

    const scale: f64 = @as(f64, @floatFromInt(height)) / @as(f64, @floatFromInt(upm));
    const y_base: f64 = @as(f64, @floatFromInt(outline.y_max)) * scale;
    _ = width;

    for (outline.contours) |contour| {
        try appendContour(alloc, &path, contour, scale, y_base);
    }

    // z2d premultiplies for us when we construct the pixel from
    // straight alpha via `fromClamped`.
    const px = z2d.pixel.RGBA.fromClamped(
        @as(f64, @floatFromInt(colour.r)) / 255.0,
        @as(f64, @floatFromInt(colour.g)) / 255.0,
        @as(f64, @floatFromInt(colour.b)) / 255.0,
        @as(f64, @floatFromInt(colour.a)) / 255.0,
    );
    try z2d.painter.fill(
        alloc,
        sfc,
        &.{ .opaque_pattern = .{ .pixel = .{ .rgba = px } } },
        path.nodes.items,
        .{},
    );
}

/// Copy the z2d RGBA surface into a BGRA byte buffer, which is the
/// layout ghostty's colour atlas expects (`Atlas.Format.bgra`).
/// Packed-pixel z2d lays out `r g b a` in memory on little-endian; we
/// swap channels 0 and 2 per pixel while copying.
fn extractRgba(
    alloc: Allocator,
    sfc: *z2d.Surface,
    width: u32,
    height: u32,
) Allocator.Error!ColorBitmap {
    const src = std.mem.sliceAsBytes(sfc.image_surface_rgba.buf);
    const data = try alloc.alloc(u8, src.len);
    var i: usize = 0;
    while (i < src.len) : (i += 4) {
        data[i + 0] = src[i + 2]; // B ← R
        data[i + 1] = src[i + 1]; // G
        data[i + 2] = src[i + 0]; // R ← B
        data[i + 3] = src[i + 3]; // A
    }
    return .{ .width = width, .height = height, .data = data };
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
