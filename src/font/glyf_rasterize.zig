//! Rasterization for OpenType glyf outlines.
//!
//! This module intentionally lives in `font` rather than `font/opentype`
//! because I wanted to keep `font/opentype` dependency free on the font
//! package.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const z2d = @import("z2d");

const Glyph = @import("Glyph.zig");
const glyf = @import("opentype/glyf.zig");

const DesignMetrics = Glyph.DesignMetrics;

/// An owned, tightly packed alpha8 bitmap.
pub const Bitmap = struct {
    width: u32,
    height: u32,
    data: []u8,

    // An empty 0x0 bitmap.
    pub const empty: Bitmap = .{ .width = 0, .height = 0, .data = "" };

    pub fn initEmpty(alloc: Allocator, width: u32, height: u32) Allocator.Error!Bitmap {
        const data = try alloc.alloc(u8, @as(usize, width) * @as(usize, height));
        @memset(data, 0);
        return .{ .width = width, .height = height, .data = data };
    }

    pub fn deinit(self: *Bitmap, alloc: Allocator) void {
        alloc.free(self.data);
        self.* = undefined;
    }
};

pub const Error = Allocator.Error || z2d.Path.Error || z2d.painter.FillError;

/// Rasterize a decoded glyf outline to a full-cell alpha bitmap.
///
/// The returned bitmap is always `grid_metrics.cell_width * cell_width` by
/// `grid_metrics.cell_height`. `opts.constraint` is applied using the same
/// `RenderOptions.Constraint` machinery used by the platform font
/// backends.
///
/// The caller owns the returned bitmap.
pub fn rasterize(
    alloc: Allocator,
    outline: glyf.Glyf.Outline,
    design: DesignMetrics,
    opts: Glyph.RenderOptions,
) Error!Bitmap {
    assert(design.units_per_em > 0);
    assert(design.advance_width > 0);
    assert(design.line_height > 0);

    // Calculate our final width/height.
    const width: u32 = std.math.mul(
        u32,
        opts.grid_metrics.cell_width,
        opts.cell_width orelse 1,
    ) catch std.math.maxInt(u32);
    const height = opts.grid_metrics.cell_height;
    assert(width > 0 and height > 0);

    // If we have no contours or points then we have no drawable shape, but the
    // caller still asked for a cell-sized bitmap. Return that full bitmap with
    // zero coverage so downstream atlas/upload code doesn't need a separate
    // size contract for empty glyphs.
    if (outline.contours.len == 0 or outline.points.len == 0) return Bitmap.initEmpty(alloc, width, height);

    // Glyf entries have a header bounding box, but this rasterizer operates on
    // the decoded Outline only. Recompute bounds from the decoded coordinate
    // data so placement and scaling follow the geometry we actually draw. If a
    // source glyf header disagrees with its points, the point data is the safer
    // source of truth for rasterization; the header belongs in decode-time
    // validation/metadata, not this font-level drawing API.
    const bounds: Bounds = bounds: {
        var bounds: Bounds = .{
            .x_min = @floatFromInt(outline.points[0].x),
            .y_min = @floatFromInt(outline.points[0].y),
            .x_max = @floatFromInt(outline.points[0].x),
            .y_max = @floatFromInt(outline.points[0].y),
        };
        for (outline.points[1..]) |p| {
            const x: f64 = @floatFromInt(p.x);
            const y: f64 = @floatFromInt(p.y);
            bounds.x_min = @min(bounds.x_min, x);
            bounds.y_min = @min(bounds.y_min, y);
            bounds.x_max = @max(bounds.x_max, x);
            bounds.y_max = @max(bounds.y_max, y);
        }
        break :bounds bounds;
    };

    // Degenerate point bounds can't produce filled area and would make the
    // point-to-bitmap transform divide by zero, so return a full transparent
    // bitmap just like an empty outline.
    if (bounds.width() == 0 or bounds.height() == 0) return Bitmap.initEmpty(alloc, width, height);

    // Build the surface we'll draw on. This is a simple alpha8 drawing.
    var sfc: z2d.Surface = try .init(
        .image_surface_alpha8,
        alloc,
        @intCast(width),
        @intCast(height),
    );
    defer sfc.deinit(alloc);

    var path: z2d.Path = .empty;
    defer path.deinit(alloc);

    const placement: Placement = .init(bounds, design, opts);
    for (0..outline.contours.len) |i| try appendContourPath(
        alloc,
        &path,
        outline.contour(i),
        bounds,
        placement,
    );

    try z2d.painter.fill(
        alloc,
        &sfc,
        &.{ .opaque_pattern = .{
            .pixel = .{ .alpha8 = .{ .a = 255 } },
        } },
        path.nodes.items,
        .{},
    );

    return .{
        .width = width,
        .height = height,
        .data = try alloc.dupe(u8, std.mem.sliceAsBytes(sfc.image_surface_alpha8.buf)),
    };
}

const Bounds = struct {
    x_min: f64,
    y_min: f64,
    x_max: f64,
    y_max: f64,

    fn width(self: Bounds) f64 {
        return self.x_max - self.x_min;
    }

    fn height(self: Bounds) f64 {
        return self.y_max - self.y_min;
    }
};

/// Cell-relative pixel rectangle where the decoded outline bounds should be
/// rasterized within the output bitmap.
///
/// This is deliberately the placement of the outline's computed point bounds,
/// not the full declared advance/line-height box. `advance_width` and
/// `line_height` describe the design-space layout box the outline was drawn
/// within: they include intentional bearings and whitespace around the visible
/// points. We use that declared box when applying `RenderOptions.Constraint` so
/// sizing and alignment preserve those bearings consistently with other font
/// backends; once that is resolved, we rasterize only the actual outline bounds
/// into this rectangle.
///
/// ```text
/// output bitmap / terminal cell
/// ╭────────────────────────────────────────────────────────────────────────╮ top
/// │                                                                        │
/// │   declared advance/line-height box                                     │
/// │   (outer layout box used for constraints)                              │
/// │   ╭────────────────────────────────────────────────────────────────╮   │
/// │   │                                                                │   │
/// │◀──────── x ────────▶╭────────── width ──────────╮                  │   │
/// │   │                 │ Placement                 │ ▲ height         │   │
/// │   │                 │ outline point bounds      │ │                │   │
/// │   │                 │ pixels to draw            │ │                │   │
/// │   │                 │                           │ │                │   │
/// │   │                 ╰───────────────────────────╯ ▼                │   │
/// │   ╰─────────────────▲──────────────────────────────────────────────╯   │
/// │                     │ y                                                │
/// ╰────────────────────────────────────────────────────────────────────────╯ bottom
///              x is measured from the bitmap left to the Placement left.
///              y is measured from the bitmap bottom to the Placement bottom.
///              bitmap_height is the full top-to-bottom bitmap height.
/// ```
///
/// Constraints are applied to the outer box so the whitespace remains part of
/// alignment decisions. `Placement` is the inner rectangle after that outer box
/// has been constrained.
const Placement = struct {
    /// Left edge of the rasterized outline bounds in bitmap pixels, measured
    /// from the bitmap's left edge.
    x: f64,

    /// Bottom edge of the rasterized outline bounds in bitmap pixels, measured
    /// from the bitmap's bottom edge. This matches the cell-relative y axis
    /// used by font.Glyph.Size and is converted to z2d's y-down axis when
    /// points are transformed.
    y: f64,

    /// Width of the rasterized outline bounds in bitmap pixels after applying
    /// font.Glyph.RenderOptions.Constraint.
    width: f64,

    /// Height of the rasterized outline bounds in bitmap pixels after applying
    /// font.Glyph.RenderOptions.Constraint.
    height: f64,

    /// Full bitmap height in pixels, used to convert cell-relative y-up-ish
    /// placement into the y-down coordinate system used by z2d surfaces.
    bitmap_height: f64,

    /// Calculate where the decoded point bounds should land in the output
    /// bitmap.
    ///
    /// The glyf protocol supplies declared metrics (`units_per_em`,
    /// `advance_width`, and `line_height`) in design units, while Ghostty's
    /// font constraint code works in cell-relative pixels. We first map the em
    /// square to one cell height, matching the linked glyph rasterizer's
    /// baseline model where design-space `y=0` is the bottom/baseline of the em
    /// and `y=units_per_em` is its top. Then we describe the actual outline
    /// bounds as a relative sub-rectangle of the declared advance/line-height
    /// box. That declared box includes any intentional side bearings or
    /// vertical whitespace around the outline; constraints should apply to that
    /// layout box rather than to the tight point bounds alone. This returns the
    /// final pixel rectangle for only the outline bounds that we will rasterize.
    fn init(
        bounds: Bounds,
        design: DesignMetrics,
        opts: Glyph.RenderOptions,
    ) Placement {
        // Start with protocol-like design units mapped so that the em square
        // occupies one cell. This makes units_per_em the scale reference and
        // preserves the linked rasterizer's y=0 baseline/bottom behavior.
        // Callers can then use RenderOptions.Constraint to fit/cover/stretch/
        // align the declared advance/line-height box using existing font logic.
        const scale = @as(f64, @floatFromInt(opts.grid_metrics.cell_height)) /
            @as(f64, @floatFromInt(design.units_per_em));

        // Convert the decoded point bounds into the same pixel coordinate space
        // expected by RenderOptions.Constraint. This rectangle is the visible
        // outline bounds, not the full advance/line-height layout box.
        const glyph: Glyph.Size = .{
            .width = bounds.width() * scale,
            .height = bounds.height() * scale,
            .x = bounds.x_min * scale,
            .y = bounds.y_min * scale,
        };

        // Convert the declared layout box to pixels. This is the box that
        // carries intentional bearings/whitespace and should be constrained.
        const group_width = @as(f64, @floatFromInt(design.advance_width)) * scale;
        const group_height = @as(f64, @floatFromInt(design.line_height)) * scale;

        // Apply the same fit/cover/stretch/alignment/padding rules used by
        // normal font rendering. The result is still the outline bounds, but
        // placed as if its containing advance/line-height box was constrained.
        const constraint: Glyph.RenderOptions.Constraint = constraint: {
            var constraint = opts.constraint;
            if (group_width > 0 and group_height > 0) {
                // Tell Constraint that `glyph` is a sub-rectangle of the
                // declared layout box. Constraint will size/align the outer box
                // and then return the corresponding transformed inner box.
                constraint.relative_width = glyph.width / group_width;
                constraint.relative_height = glyph.height / group_height;
                constraint.relative_x = glyph.x / group_width;
                constraint.relative_y = glyph.y / group_height;
            }
            break :constraint constraint;
        };
        const constrained = constraint.constrain(
            glyph,
            opts.grid_metrics,
            opts.constraint_width,
        );

        // Store the final outline placement plus the full bitmap height needed
        // later to flip from cell-relative y to z2d's y-down surface space.
        return .{
            .x = constrained.x,
            .y = constrained.y,
            .width = constrained.width,
            .height = constrained.height,
            .bitmap_height = @floatFromInt(opts.grid_metrics.cell_height),
        };
    }
};

const Point = struct {
    x: f64,
    y: f64,
};

/// Append one contour to a z2d path.
///
/// Glyf contours are quadratic outlines with explicit on-curve points and
/// off-curve control points. Consecutive off-curve points imply an on-curve
/// point halfway between them, and a contour may begin with an off-curve point.
/// This normalizes those cases while walking the closed contour and emits z2d
/// line/cubic-curve operations in bitmap coordinates.
fn appendContourPath(
    alloc: Allocator,
    path: *z2d.Path,
    contour: []const glyf.Glyf.Outline.Point,
    bounds: Bounds,
    placement: Placement,
) Error!void {
    if (contour.len == 0) return;

    const first = contour[0];
    const last = contour[contour.len - 1];

    var current: Point = undefined;
    var i: usize = 0;

    // Choose the starting on-curve point for this closed contour. If the first
    // point is off-curve then the contour logically starts either at the final
    // on-curve point, or at the implied midpoint between the final and first
    // off-curve points.
    if (first.on_curve) {
        i = 1;
        current = transformPoint(
            first,
            bounds,
            placement,
        );
    } else if (last.on_curve) {
        current = transformPoint(
            last,
            bounds,
            placement,
        );
    } else {
        current = midpoint(
            transformPoint(last, bounds, placement),
            transformPoint(first, bounds, placement),
        );
    }

    // Move to the beginning
    try path.moveTo(alloc, current.x, current.y);

    // Go through the points and connect em!
    while (i < contour.len) {
        const p = contour[i];

        // On-curve points connect to the current point with a straight line.
        if (p.on_curve) {
            current = transformPoint(p, bounds, placement);
            try path.lineTo(alloc, current.x, current.y);
            i += 1;
            continue;
        }

        // Off-curve points are quadratic control points. The following point is
        // either the curve endpoint or, if it is also off-curve, contributes an
        // implied on-curve endpoint halfway between the two controls.
        const control = transformPoint(p, bounds, placement);
        const next = contour[(i + 1) % contour.len];
        const end = if (next.on_curve) transformPoint(
            next,
            bounds,
            placement,
        ) else midpoint(
            control,
            transformPoint(next, bounds, placement),
        );

        // z2d paths only expose cubic curves, so convert the TrueType
        // quadratic segment to an equivalent cubic segment before appending it.
        const c1 = Point{
            .x = current.x + ((2.0 / 3.0) * (control.x - current.x)),
            .y = current.y + ((2.0 / 3.0) * (control.y - current.y)),
        };
        const c2 = Point{
            .x = end.x + ((2.0 / 3.0) * (control.x - end.x)),
            .y = end.y + ((2.0 / 3.0) * (control.y - end.y)),
        };
        try path.curveTo(
            alloc,
            c1.x,
            c1.y,
            c2.x,
            c2.y,
            end.x,
            end.y,
        );

        current = end;

        // If we consumed an explicit on-curve endpoint then skip it; otherwise
        // the next off-curve point still needs to be used as the control point
        // for the following quadratic segment.
        i += if (next.on_curve) 2 else 1;
    }

    try path.close(alloc);
}

/// Convert a decoded glyf point from design-space coordinates to z2d bitmap
/// coordinates.
///
/// `bounds` describes the decoded outline's point/control bounds in glyf
/// design units. `placement` describes where those bounds should land in the
/// output bitmap after constraints are applied. Glyf coordinates are y-up; z2d
/// surfaces are y-down, so this also flips the y axis using
/// `placement.bitmap_height`.
fn transformPoint(
    p: glyf.Glyf.Outline.Point,
    bounds: Bounds,
    placement: Placement,
) Point {
    const scale_x = placement.width / bounds.width();
    const scale_y = placement.height / bounds.height();
    const x_design: f64 = @floatFromInt(p.x);
    const y_design: f64 = @floatFromInt(p.y);
    return .{
        .x = placement.x + ((x_design - bounds.x_min) * scale_x),
        .y = placement.bitmap_height - placement.y -
            ((y_design - bounds.y_min) * scale_y),
    };
}

/// Return the implied on-curve point between two off-curve TrueType control
/// points.
fn midpoint(a: Point, b: Point) Point {
    return .{
        .x = (a.x + b.x) / 2.0,
        .y = (a.y + b.y) / 2.0,
    };
}

fn testMetrics(width: u32, height: u32) @import("Metrics.zig") {
    return .{
        .cell_width = width,
        .cell_height = height,
        .cell_baseline = 0,
        .underline_position = height,
        .underline_thickness = 1,
        .strikethrough_position = height / 2,
        .strikethrough_thickness = 1,
        .overline_position = 0,
        .overline_thickness = 1,
        .box_thickness = 1,
        .cursor_thickness = 1,
        .cursor_height = height,
        .icon_height = @floatFromInt(height),
        .icon_height_single = @floatFromInt(height),
        .face_width = @floatFromInt(width),
        .face_height = @floatFromInt(height),
        .face_y = 0,
    };
}

test {
    _ = @import("glyf_rasterize_png_test.zig");
}

test "glyf_rasterize: empty outline returns empty bitmap" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var bm = try rasterize(alloc, .{ .points = &.{}, .contours = &.{} }, .{
        .units_per_em = 1000,
        .advance_width = 1000,
        .line_height = 1000,
    }, .{
        .grid_metrics = testMetrics(20, 20),
    });
    defer bm.deinit(alloc);

    try testing.expectEqual(@as(u32, 20), bm.width);
    try testing.expectEqual(@as(u32, 20), bm.height);
    try testing.expectEqual(@as(usize, 20 * 20), bm.data.len);
    for (bm.data) |v| try testing.expectEqual(@as(u8, 0), v);
}

test "glyf_rasterize: square fills bitmap center" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const outline: glyf.Glyf.Outline = .{
        .points = &.{
            .{ .x = 0, .y = 0, .on_curve = true },
            .{ .x = 1000, .y = 0, .on_curve = true },
            .{ .x = 1000, .y = 1000, .on_curve = true },
            .{ .x = 0, .y = 1000, .on_curve = true },
        },
        .contours = &.{3},
    };

    var bm = try rasterize(alloc, outline, .{
        .units_per_em = 1000,
        .advance_width = 1000,
        .line_height = 1000,
    }, .{
        .grid_metrics = testMetrics(20, 20),
    });
    defer bm.deinit(alloc);

    try testing.expect(bm.data[10 * bm.width + 10] > 200);
}

test "glyf_rasterize: quadratic contour renders" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const outline: glyf.Glyf.Outline = .{
        .points = &.{
            .{ .x = 0, .y = 0, .on_curve = true },
            .{ .x = 500, .y = 1000, .on_curve = false },
            .{ .x = 1000, .y = 0, .on_curve = true },
        },
        .contours = &.{2},
    };

    var bm = try rasterize(alloc, outline, .{
        .units_per_em = 1000,
        .advance_width = 1000,
        .line_height = 1000,
    }, .{
        .grid_metrics = testMetrics(20, 20),
    });
    defer bm.deinit(alloc);

    var nonzero = false;
    for (bm.data) |v| nonzero = nonzero or v != 0;
    try testing.expect(nonzero);
}

test "glyf_rasterize: consecutive off-curve points render" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const outline: glyf.Glyf.Outline = .{
        .points = &.{
            .{ .x = 0, .y = 0, .on_curve = true },
            .{ .x = 250, .y = 1000, .on_curve = false },
            .{ .x = 750, .y = 1000, .on_curve = false },
            .{ .x = 1000, .y = 0, .on_curve = true },
        },
        .contours = &.{3},
    };

    var bm = try rasterize(alloc, outline, .{
        .units_per_em = 1000,
        .advance_width = 1000,
        .line_height = 1000,
    }, .{
        .grid_metrics = testMetrics(20, 20),
    });
    defer bm.deinit(alloc);

    var nonzero = false;
    for (bm.data) |v| nonzero = nonzero or v != 0;
    try testing.expect(nonzero);
}

test "glyf_rasterize: units per em controls baseline scale" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const outline: glyf.Glyf.Outline = .{
        .points = &.{
            .{ .x = 0, .y = 0, .on_curve = true },
            .{ .x = 1000, .y = 0, .on_curve = true },
            .{ .x = 1000, .y = 1000, .on_curve = true },
            .{ .x = 0, .y = 1000, .on_curve = true },
        },
        .contours = &.{3},
    };

    var bm = try rasterize(alloc, outline, .{
        .units_per_em = 2000,
        .advance_width = 1000,
        .line_height = 1000,
    }, .{
        .grid_metrics = testMetrics(20, 20),
    });
    defer bm.deinit(alloc);

    // With a 2000-unit em in a 20px cell, this 1000-unit square occupies the
    // bottom half of the cell. This matches the linked rasterizer's y=0
    // baseline/bottom behavior and proves units_per_em is the scale reference.
    try testing.expect(bm.data[15 * bm.width + 5] > 200);
    try testing.expectEqual(@as(u8, 0), bm.data[5 * bm.width + 5]);
}

test "glyf_rasterize: degenerate outline returns full empty bitmap" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const outline: glyf.Glyf.Outline = .{
        .points = &.{
            .{ .x = 0, .y = 0, .on_curve = true },
            .{ .x = 1000, .y = 0, .on_curve = true },
            .{ .x = 500, .y = 0, .on_curve = true },
        },
        .contours = &.{2},
    };

    var bm = try rasterize(alloc, outline, .{
        .units_per_em = 1000,
        .advance_width = 1000,
        .line_height = 1000,
    }, .{
        .grid_metrics = testMetrics(20, 20),
    });
    defer bm.deinit(alloc);

    try testing.expectEqual(@as(u32, 20), bm.width);
    try testing.expectEqual(@as(u32, 20), bm.height);
    try testing.expectEqual(@as(usize, 20 * 20), bm.data.len);
    for (bm.data) |v| try testing.expectEqual(@as(u8, 0), v);
}

test "glyf_rasterize: contour can start off curve with final on curve point" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const outline: glyf.Glyf.Outline = .{
        .points = &.{
            .{ .x = 500, .y = 1000, .on_curve = false },
            .{ .x = 1000, .y = 0, .on_curve = true },
            .{ .x = 0, .y = 0, .on_curve = true },
        },
        .contours = &.{2},
    };

    var bm = try rasterize(alloc, outline, .{
        .units_per_em = 1000,
        .advance_width = 1000,
        .line_height = 1000,
    }, .{
        .grid_metrics = testMetrics(20, 20),
    });
    defer bm.deinit(alloc);

    var nonzero = false;
    for (bm.data) |v| nonzero = nonzero or v != 0;
    try testing.expect(nonzero);
}

test "glyf_rasterize: contour can start with implied midpoint" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const outline: glyf.Glyf.Outline = .{
        .points = &.{
            .{ .x = 250, .y = 1000, .on_curve = false },
            .{ .x = 1000, .y = 0, .on_curve = true },
            .{ .x = 750, .y = 1000, .on_curve = false },
            .{ .x = 0, .y = 0, .on_curve = true },
        },
        .contours = &.{3},
    };

    var bm = try rasterize(alloc, outline, .{
        .units_per_em = 1000,
        .advance_width = 1000,
        .line_height = 1000,
    }, .{
        .grid_metrics = testMetrics(20, 20),
    });
    defer bm.deinit(alloc);

    var nonzero = false;
    for (bm.data) |v| nonzero = nonzero or v != 0;
    try testing.expect(nonzero);
}

test "glyf_rasterize: multiple contours render independently" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const outline: glyf.Glyf.Outline = .{
        .points = &.{
            .{ .x = 0, .y = 0, .on_curve = true },
            .{ .x = 400, .y = 0, .on_curve = true },
            .{ .x = 400, .y = 400, .on_curve = true },
            .{ .x = 0, .y = 400, .on_curve = true },
            .{ .x = 600, .y = 600, .on_curve = true },
            .{ .x = 1000, .y = 600, .on_curve = true },
            .{ .x = 1000, .y = 1000, .on_curve = true },
            .{ .x = 600, .y = 1000, .on_curve = true },
        },
        .contours = &.{ 3, 7 },
    };

    var bm = try rasterize(alloc, outline, .{
        .units_per_em = 1000,
        .advance_width = 1000,
        .line_height = 1000,
    }, .{
        .grid_metrics = testMetrics(20, 20),
    });
    defer bm.deinit(alloc);

    try testing.expect(bm.data[16 * bm.width + 4] > 200);
    try testing.expect(bm.data[4 * bm.width + 16] > 200);
    try testing.expectEqual(@as(u8, 0), bm.data[10 * bm.width + 10]);
}

test "glyf_rasterize: non-zero bearings preserve declared whitespace" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const outline: glyf.Glyf.Outline = .{
        .points = &.{
            .{ .x = 250, .y = 0, .on_curve = true },
            .{ .x = 750, .y = 0, .on_curve = true },
            .{ .x = 750, .y = 1000, .on_curve = true },
            .{ .x = 250, .y = 1000, .on_curve = true },
        },
        .contours = &.{3},
    };

    var bm = try rasterize(alloc, outline, .{
        .units_per_em = 1000,
        .advance_width = 1000,
        .line_height = 1000,
    }, .{
        .grid_metrics = testMetrics(20, 20),
    });
    defer bm.deinit(alloc);

    try testing.expectEqual(@as(u8, 0), bm.data[10 * bm.width + 2]);
    try testing.expect(bm.data[10 * bm.width + 10] > 200);
    try testing.expectEqual(@as(u8, 0), bm.data[10 * bm.width + 17]);
}

test "glyf_rasterize: negative y coordinates descend below baseline" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const outline: glyf.Glyf.Outline = .{
        .points = &.{
            .{ .x = 0, .y = -250, .on_curve = true },
            .{ .x = 1000, .y = -250, .on_curve = true },
            .{ .x = 1000, .y = 750, .on_curve = true },
            .{ .x = 0, .y = 750, .on_curve = true },
        },
        .contours = &.{3},
    };

    var bm = try rasterize(alloc, outline, .{
        .units_per_em = 1000,
        .advance_width = 1000,
        .line_height = 1000,
    }, .{
        .grid_metrics = testMetrics(20, 20),
    });
    defer bm.deinit(alloc);

    try testing.expectEqual(@as(u8, 0), bm.data[2 * bm.width + 10]);
    try testing.expect(bm.data[10 * bm.width + 10] > 200);
    try testing.expect(bm.data[18 * bm.width + 10] > 200);
}

test "glyf_rasterize: two-cell bitmap and constraint render within width" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const outline: glyf.Glyf.Outline = .{
        .points = &.{
            .{ .x = 0, .y = 0, .on_curve = true },
            .{ .x = 1000, .y = 0, .on_curve = true },
            .{ .x = 1000, .y = 1000, .on_curve = true },
            .{ .x = 0, .y = 1000, .on_curve = true },
        },
        .contours = &.{3},
    };

    var bm = try rasterize(alloc, outline, .{
        .units_per_em = 1000,
        .advance_width = 1000,
        .line_height = 1000,
    }, .{
        .grid_metrics = testMetrics(20, 20),
        .cell_width = 2,
        .constraint_width = 2,
        .constraint = .{
            .size = .cover,
            .align_horizontal = .center,
            .align_vertical = .center,
        },
    });
    defer bm.deinit(alloc);

    try testing.expectEqual(@as(u32, 40), bm.width);
    try testing.expectEqual(@as(u32, 20), bm.height);
    try testing.expectEqual(@as(u8, 0), bm.data[10 * bm.width + 2]);
    try testing.expect(bm.data[10 * bm.width + 20] > 200);
    try testing.expectEqual(@as(u8, 0), bm.data[10 * bm.width + 37]);
}

test "glyf_rasterize: line height does not change unconstrained em scale" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const outline: glyf.Glyf.Outline = .{
        .points = &.{
            .{ .x = 0, .y = 0, .on_curve = true },
            .{ .x = 1000, .y = 0, .on_curve = true },
            .{ .x = 1000, .y = 1000, .on_curve = true },
            .{ .x = 0, .y = 1000, .on_curve = true },
        },
        .contours = &.{3},
    };

    var bm = try rasterize(alloc, outline, .{
        .units_per_em = 1000,
        .advance_width = 1000,
        .line_height = 2000,
    }, .{
        .grid_metrics = testMetrics(20, 20),
    });
    defer bm.deinit(alloc);

    try testing.expect(bm.data[10 * bm.width + 10] > 200);
    try testing.expect(bm.data[2 * bm.width + 10] > 200);
    try testing.expect(bm.data[17 * bm.width + 10] > 200);
}
