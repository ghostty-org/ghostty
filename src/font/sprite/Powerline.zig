//! This file contains functions for drawing certain characters from Powerline
//! Extra (https://github.com/ryanoasis/powerline-extra-symbols). These
//! characters are similarly to box-drawing characters (see Box.zig), so the
//! logic will be mainly the same, just with a much reduced character set.
//!
//! Note that this is not the complete list of Powerline glyphs that may be
//! needed, so this may grow to add other glyphs from the set.
const Powerline = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const font = @import("../main.zig");
const Quad = @import("canvas.zig").Quad;

const log = std.log.scoped(.powerline_font);

/// The cell width and height because the boxes are fit perfectly
/// into a cell so that they all properly connect with zero spacing.
width: u32,
height: u32,

/// Base thickness value for glyphs that are not completely solid (backslashes,
/// thin half-circles, etc). If you want to do any DPI scaling, it is expected
/// to be done earlier.
///
/// TODO: this and Thickness are currently unused but will be when the
/// aforementioned glyphs are added.
thickness: u32,

/// The thickness of a line.
const Thickness = enum {
    super_light,
    light,
    heavy,

    /// Calculate the real height of a line based on its thickness
    /// and a base thickness value. The base thickness value is expected
    /// to be in pixels.
    fn height(self: Thickness, base: u32) u32 {
        return switch (self) {
            .super_light => @max(base / 2, 1),
            .light => base,
            .heavy => base * 2,
        };
    }
};

inline fn sq(x: anytype) @TypeOf(x) {
    return x * x;
}

pub fn renderGlyph(
    self: Powerline,
    alloc: Allocator,
    atlas: *font.Atlas,
    cp: u32,
) !font.Glyph {
    // Create the canvas we'll use to draw
    var canvas = try font.sprite.Canvas.init(alloc, self.width, self.height);
    defer canvas.deinit(alloc);

    // Perform the actual drawing
    try self.draw(alloc, &canvas, cp);

    // Write the drawing to the atlas
    const region = try canvas.writeAtlas(alloc, atlas);

    // Our coordinates start at the BOTTOM for our renderers so we have to
    // specify an offset of the full height because we rendered a full size
    // cell.
    const offset_y = @as(i32, @intCast(self.height));

    return font.Glyph{
        .width = self.width,
        .height = self.height,
        .offset_x = 0,
        .offset_y = offset_y,
        .atlas_x = region.x,
        .atlas_y = region.y,
        .advance_x = @floatFromInt(self.width),
    };
}

fn draw(self: Powerline, alloc: Allocator, canvas: *font.sprite.Canvas, cp: u32) !void {
    switch (cp) {
        // Hard dividers and triangles
        0xE0B0,
        0xE0B2,
        0xE0B8,
        0xE0BA,
        0xE0BC,
        0xE0BE,
        => try self.draw_wedge_triangle(canvas, cp),

        // Soft Dividers
        0xE0B1,
        0xE0B3,
        => try self.draw_chevron(canvas, cp),

        // Half-circles
        0xE0B4,
        0xE0B6,
        => try self.draw_half_circle(alloc, canvas, cp),

        // Mirrored top-down trapezoids
        0xE0D2,
        0xE0D4,
        => try self.draw_trapezoid_top_bottom(canvas, cp),

        else => return error.InvalidCodepoint,
    }
}

fn draw_chevron(self: Powerline, canvas: *font.sprite.Canvas, cp: u32) !void {
    const width = self.width;
    const height = self.height;
    
    var p1_x: u32 = 0;
    var p1_y: u32 = 0;
    var p2_x: u32 = 0;
    var p2_y: u32 = 0;
    var p3_x: u32 = 0;
    var p3_y: u32 = 0;


    switch (cp) {
        0xE0B1 => {
            p1_x = 0;
            p1_y = 0;
            p2_x = width;
            p2_y = height / 2;
            p3_x = 0;
            p3_y = height;
        },
        0xE0B3 => {
            p1_x = width;
            p1_y = 0;
            p2_x = 0;
            p2_y = height / 2;
            p3_x = width;
            p3_y = height;
        },
        
        else => unreachable,

    }

    try canvas.triangle_outline(.{
        .p0 = .{ .x = @floatFromInt(p1_x), .y = @floatFromInt(p1_y) },
        .p1 = .{ .x = @floatFromInt(p2_x), .y = @floatFromInt(p2_y) },
        .p2 = .{ .x = @floatFromInt(p3_x), .y = @floatFromInt(p3_y) },
    }, 
    @floatFromInt(Thickness.light.height(self.thickness)),
    .on);

}

fn draw_wedge_triangle(self: Powerline, canvas: *font.sprite.Canvas, cp: u32) !void {
    const width = self.width;
    const height = self.height;

    var p1_x: u32 = 0;
    var p2_x: u32 = 0;
    var p3_x: u32 = 0;
    var p1_y: u32 = 0;
    var p2_y: u32 = 0;
    var p3_y: u32 = 0;

    switch (cp) {
        0xE0B0 => {
            p1_x = 0;
            p1_y = 0;
            p2_x = width;
            p2_y = height / 2;
            p3_x = 0;
            p3_y = height;
        },

        0xE0B2 => {
            p1_x = width;
            p1_y = 0;
            p2_x = 0;
            p2_y = height / 2;
            p3_x = width;
            p3_y = height;
        },

        0xE0B8 => {
            p1_x = 0;
            p1_y = 0;
            p2_x = width;
            p2_y = height;
            p3_x = 0;
            p3_y = height;
        },

        0xE0BA => {
            p1_x = width;
            p1_y = 0;
            p2_x = width;
            p2_y = height;
            p3_x = 0;
            p3_y = height;
        },

        0xE0BC => {
            p1_x = 0;
            p1_y = 0;
            p2_x = width;
            p2_y = 0;
            p3_x = 0;
            p3_y = height;
        },

        0xE0BE => {
            p1_x = 0;
            p1_y = 0;
            p2_x = width;
            p2_y = 0;
            p3_x = width;
            p3_y = height;
        },

        else => unreachable,
    }

    try canvas.triangle(.{
        .p0 = .{ .x = @floatFromInt(p1_x), .y = @floatFromInt(p1_y) },
        .p1 = .{ .x = @floatFromInt(p2_x), .y = @floatFromInt(p2_y) },
        .p2 = .{ .x = @floatFromInt(p3_x), .y = @floatFromInt(p3_y) },
    }, .on);
}

fn draw_half_circle(self: Powerline, alloc: Allocator, canvas: *font.sprite.Canvas, cp: u32) !void {
    const supersample = 4;

    // We make a canvas big enough for the whole circle, with the supersample
    // applied.
    const width = self.width * 2 * supersample;
    const height = self.height * supersample;

    // We set a minimum super-sampled canvas to assert on. The minimum cell
    // size is 1x3px, and this looked safe in empirical testing.
    std.debug.assert(width >= 8); // 1 * 2 * 4
    std.debug.assert(height >= 12); // 3 * 4

    const center_x = width / 2 - 1;
    const center_y = height / 2 - 1;

    // Our radii. We're technically drawing an ellipse here to ensure that this
    // works for fonts with different aspect ratios than a typical 2:1 H*W, e.g.
    // Iosevka (which is around 2.6:1).
    const radius_x = width / 2 - 1; // This gives us a small margin for smoothing
    const radius_y = height / 2;

    // Pre-allocate a matrix to plot the points on.
    const cap = height * width;
    var points = try alloc.alloc(u8, cap);
    defer alloc.free(points);
    @memset(points, 0);

    {
        // This is a midpoint ellipse algorithm, similar to a midpoint circle
        // algorithm in that we only draw the octants we need and then reflect
        // the result across the other axes. Since an ellipse has two radii, we
        // need to calculate two octants instead of one. There are variations
        // on the algorithm and you can find many examples online. This one
        // does use some floating point math in calculating the decision
        // parameter, but I've found it clear in its implementation and it does
        // not require adjustment for integer error.
        //
        // This algorithm has undergone some iterations, so the following
        // references might be helpful for understanding:
        //
        //   * "Drawing a circle, point by point, without floating point
        //   support" (Dennis Yurichev,
        //   https://yurichev.com/news/20220322_circle/), which describes the
        //   midpoint circle algorithm and implementation we initially adapted
        //   here.
        //
        //   * "Ellipse-Generating Algorithms" (RTU Latvia,
        //   https://daugavpils.rtu.lv/wp-content/uploads/sites/34/2020/11/LEC_3.pdf),
        //   which was used to further adapt the algorithm for ellipses.
        //
        //   * "An Effective Approach to Minimize Error in Midpoint Ellipse
        //   Drawing Algorithm" (Dr. M. Javed Idrisi, Aayesha Ashraf,
        //   https://arxiv.org/abs/2103.04033), which includes a synopsis of
        //   the history of ellipse drawing algorithms, and further references.

        // Declare some casted constants for use in various calculations below
        const rx: i32 = @intCast(radius_x);
        const ry: i32 = @intCast(radius_y);
        const rxf: f64 = @floatFromInt(radius_x);
        const ryf: f64 = @floatFromInt(radius_y);
        const cx: i32 = @intCast(center_x);
        const cy: i32 = @intCast(center_y);

        // Our plotting x and y
        var x: i32 = 0;
        var y: i32 = @intCast(radius_y);

        // Decision parameter, initialized for region 1
        var dparam: f64 = sq(ryf) - sq(rxf) * ryf + sq(rxf) * 0.25;

        // Region 1
        while (2 * sq(ry) * x < 2 * sq(rx) * y) {
            // Right side
            const x1 = @max(0, cx + x);
            const y1 = @max(0, cy + y);
            const x2 = @max(0, cx + x);
            const y2 = @max(0, cy - y);

            // Left side
            const x3 = @max(0, cx - x);
            const y3 = @max(0, cy + y);
            const x4 = @max(0, cx - x);
            const y4 = @max(0, cy - y);

            // Points
            const p1 = y1 * width + x1;
            const p2 = y2 * width + x2;
            const p3 = y3 * width + x3;
            const p4 = y4 * width + x4;

            // Set the points in the matrix, ignore any out of bounds
            if (p1 < cap) points[p1] = 0xFF;
            if (p2 < cap) points[p2] = 0xFF;
            if (p3 < cap) points[p3] = 0xFF;
            if (p4 < cap) points[p4] = 0xFF;

            // Calculate next pixels based on midpoint bounds
            x += 1;
            if (dparam < 0) {
                const xf: f64 = @floatFromInt(x);
                dparam += 2 * sq(ryf) * xf + sq(ryf);
            } else {
                y -= 1;
                const xf: f64 = @floatFromInt(x);
                const yf: f64 = @floatFromInt(y);
                dparam += 2 * sq(ryf) * xf - 2 * sq(rxf) * yf + sq(ryf);
            }
        }

        // Region 2
        {
            // Reset our decision parameter for region 2
            const xf: f64 = @floatFromInt(x);
            const yf: f64 = @floatFromInt(y);
            dparam = sq(ryf) * sq(xf + 0.5) + sq(rxf) * sq(yf - 1) - sq(rxf) * sq(ryf);
        }
        while (y >= 0) {
            // Right side
            const x1 = @max(0, cx + x);
            const y1 = @max(0, cy + y);
            const x2 = @max(0, cx + x);
            const y2 = @max(0, cy - y);

            // Left side
            const x3 = @max(0, cx - x);
            const y3 = @max(0, cy + y);
            const x4 = @max(0, cx - x);
            const y4 = @max(0, cy - y);

            // Points
            const p1 = y1 * width + x1;
            const p2 = y2 * width + x2;
            const p3 = y3 * width + x3;
            const p4 = y4 * width + x4;

            // Set the points in the matrix, ignore any out of bounds
            if (p1 < cap) points[p1] = 0xFF;
            if (p2 < cap) points[p2] = 0xFF;
            if (p3 < cap) points[p3] = 0xFF;
            if (p4 < cap) points[p4] = 0xFF;

            // Calculate next pixels based on midpoint bounds
            y -= 1;
            if (dparam > 0) {
                const yf: f64 = @floatFromInt(y);
                dparam -= 2 * sq(rxf) * yf + sq(rxf);
            } else {
                x += 1;
                const xf: f64 = @floatFromInt(x);
                const yf: f64 = @floatFromInt(y);
                dparam += 2 * sq(ryf) * xf - 2 * sq(rxf) * yf + sq(rxf);
            }
        }
    }

    // Fill
    {
        const u_height: u32 = @intCast(height);
        const u_width: u32 = @intCast(width);

        for (0..u_height) |yf| {
            for (0..u_width) |left| {
                // Count forward from the left to the first filled pixel
                if (points[yf * u_width + left] != 0) {
                    // Count back to our left point from the right to the first
                    // filled pixel on the other side.
                    var right: usize = u_width - 1;
                    while (right > left) : (right -= 1) {
                        if (points[yf * u_width + right] != 0) {
                            break;
                        }
                    }

                    // Start filling 1 index after the left and go until we hit
                    // the right; this will be a no-op if the line length is <
                    // 3 as both left and right will have already been filled.
                    const start = yf * u_width + left;
                    const end = yf * u_width + right;
                    if (end - start >= 3) {
                        for (start + 1..end) |idx| {
                            points[idx] = 0xFF;
                        }
                    }
                }
            }
        }
    }

    // Now that we have our points, we need to "split" our matrix on the x
    // axis for the downsample.
    {
        // The side of the circle we're drawing
        const offset_j: u32 = if (cp == 0xE0B4) center_x + 1 else 0;

        for (0..self.height) |r| {
            for (0..self.width) |c| {
                var total: u32 = 0;
                for (0..supersample) |i| {
                    for (0..supersample) |j| {
                        const idx = (r * supersample + i) * width + (c * supersample + j + offset_j);
                        total += points[idx];
                    }
                }

                const average = @as(u8, @intCast(@min(total / (supersample * supersample), 0xFF)));
                canvas.rect(
                    .{
                        .x = @intCast(c),
                        .y = @intCast(r),
                        .width = 1,
                        .height = 1,
                    },
                    @as(font.sprite.Color, @enumFromInt(average)),
                );
            }
        }
    }
}

fn draw_trapezoid_top_bottom(self: Powerline, canvas: *font.sprite.Canvas, cp: u32) !void {
    const t_top: Quad(f64) = if (cp == 0xE0D4)
        .{
            .p0 = .{
                .x = 0,
                .y = 0,
            },
            .p1 = .{
                .x = @floatFromInt(self.width - self.width / 3),
                .y = @floatFromInt(self.height / 2 - self.height / 20),
            },
            .p2 = .{
                .x = @floatFromInt(self.width),
                .y = @floatFromInt(self.height / 2 - self.height / 20),
            },
            .p3 = .{
                .x = @floatFromInt(self.width),
                .y = 0,
            },
        }
    else
        .{
            .p0 = .{
                .x = 0,
                .y = 0,
            },
            .p1 = .{
                .x = 0,
                .y = @floatFromInt(self.height / 2 - self.height / 20),
            },
            .p2 = .{
                .x = @floatFromInt(self.width / 3),
                .y = @floatFromInt(self.height / 2 - self.height / 20),
            },
            .p3 = .{
                .x = @floatFromInt(self.width),
                .y = 0,
            },
        };

    const t_bottom: Quad(f64) = if (cp == 0xE0D4)
        .{
            .p0 = .{
                .x = @floatFromInt(self.width - self.width / 3),
                .y = @floatFromInt(self.height / 2 + self.height / 20),
            },
            .p1 = .{
                .x = 0,
                .y = @floatFromInt(self.height),
            },
            .p2 = .{
                .x = @floatFromInt(self.width),
                .y = @floatFromInt(self.height),
            },
            .p3 = .{
                .x = @floatFromInt(self.width),
                .y = @floatFromInt(self.height / 2 + self.height / 20),
            },
        }
    else
        .{
            .p0 = .{
                .x = 0,
                .y = @floatFromInt(self.height / 2 + self.height / 20),
            },
            .p1 = .{
                .x = 0,
                .y = @floatFromInt(self.height),
            },
            .p2 = .{
                .x = @floatFromInt(self.width),
                .y = @floatFromInt(self.height),
            },
            .p3 = .{
                .x = @floatFromInt(self.width / 3),
                .y = @floatFromInt(self.height / 2 + self.height / 20),
            },
        };

    try canvas.quad(t_top, .on);
    try canvas.quad(t_bottom, .on);
}

test "all" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const cps = [_]u32{
        0xE0B0,
        0xE0B2,
        0xE0B8,
        0xE0BA,
        0xE0BC,
        0xE0BE,
        0xE0B4,
        0xE0B6,
        0xE0D2,
        0xE0D4,
        0xE0B1,
        0xE0B3,
    };
    for (cps) |cp| {
        var atlas_grayscale = try font.Atlas.init(alloc, 512, .grayscale);
        defer atlas_grayscale.deinit(alloc);

        const face: Powerline = .{ .width = 18, .height = 36, .thickness = 2 };
        const glyph = try face.renderGlyph(
            alloc,
            &atlas_grayscale,
            cp,
        );
        try testing.expectEqual(@as(u32, face.width), glyph.width);
        try testing.expectEqual(@as(u32, face.height), glyph.height);
    }
}
