//! This exposes primitives to draw 2D graphics and export the graphic to
//! a font atlas.
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const z2d = @import("z2d");
const font = @import("../main.zig");

pub fn Point(comptime T: type) type {
    return struct {
        x: T,
        y: T,
    };
}

pub fn Line(comptime T: type) type {
    return struct {
        p0: Point(T),
        p1: Point(T),
    };
}

pub fn Box(comptime T: type) type {
    return struct {
        p0: Point(T),
        p1: Point(T),

        pub fn rect(self: Box(T)) Rect(T) {
            const tl_x = @min(self.p0.x, self.p1.x);
            const tl_y = @min(self.p0.y, self.p1.y);
            const br_x = @max(self.p0.x, self.p1.x);
            const br_y = @max(self.p0.y, self.p1.y);

            return .{
                .x = tl_x,
                .y = tl_y,
                .width = br_x - tl_x,
                .height = br_y - tl_y,
            };
        }
    };
}

pub fn Rect(comptime T: type) type {
    return struct {
        x: T,
        y: T,
        width: T,
        height: T,
    };
}

pub fn Triangle(comptime T: type) type {
    return struct {
        p0: Point(T),
        p1: Point(T),
        p2: Point(T),
    };
}

pub fn Quad(comptime T: type) type {
    return struct {
        p0: Point(T),
        p1: Point(T),
        p2: Point(T),
        p3: Point(T),
    };
}

/// We only use alpha-channel so a pixel can only be "on" or "off".
pub const Color = enum(u8) {
    on = 255,
    off = 0,
    _,
};

/// This is a managed struct, it keeps a reference to the allocator that is
/// used to initialize it, and the same allocator is used for any further
/// necessary allocations when drawing.
pub const Canvas = struct {
    /// The underlying z2d surface.
    sfc: z2d.Surface,

    padding_x: u32,
    padding_y: u32,

    clip_top: u32 = 0,
    clip_left: u32 = 0,
    clip_right: u32 = 0,
    clip_bottom: u32 = 0,

    alloc: Allocator,

    pub fn init(
        alloc: Allocator,
        width: u32,
        height: u32,
        padding_x: u32,
        padding_y: u32,
    ) !Canvas {
        // Create the surface we'll be using.
        // We add padding to both sides (hence `2 *`)
        const sfc = try z2d.Surface.initPixel(
            .{ .alpha8 = .{ .a = 0 } },
            alloc,
            @intCast(width + 2 * padding_x),
            @intCast(height + 2 * padding_y),
        );
        errdefer sfc.deinit(alloc);

        return .{
            .sfc = sfc,
            .padding_x = padding_x,
            .padding_y = padding_y,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *Canvas) void {
        self.sfc.deinit(self.alloc);
        self.* = undefined;
    }

    /// Write the data in this drawing to the atlas.
    pub fn writeAtlas(
        self: *Canvas,
        alloc: Allocator,
        atlas: *font.Atlas,
    ) (Allocator.Error || font.Atlas.Error)!font.Atlas.Region {
        assert(atlas.format == .grayscale);

        self.trim();

        const sfc_width: u32 = @intCast(self.sfc.getWidth());
        const sfc_height: u32 = @intCast(self.sfc.getHeight());

        // Subtract our clip margins from the
        // width and height to get region size.
        const region_width = sfc_width -| self.clip_left -| self.clip_right;
        const region_height = sfc_height -| self.clip_top -| self.clip_bottom;

        // Allocate our texture atlas region
        const region = region: {
            // Reserve a region with a 1px margin on the bottom and right edges
            // so that we can avoid interpolation between adjacent glyphs during
            // texture sampling.
            var region = try atlas.reserve(
                alloc,
                region_width + 1,
                region_height + 1,
            );

            // Modify the region to remove the margin so that we write to the
            // non-zero location. The data in an Altlas is always initialized
            // to zero (Atlas.clear) so we don't need to worry about zero-ing
            // that.
            region.width -= 1;
            region.height -= 1;
            break :region region;
        };

        if (region.width > 0 and region.height > 0) {
            const buffer: []u8 = @ptrCast(self.sfc.image_surface_alpha8.buf);

            // Write the glyph information into the atlas
            assert(region.width == region_width);
            assert(region.height == region_height);
            atlas.setFromLarger(
                region,
                buffer,
                sfc_width,
                self.clip_left,
                self.clip_top,
            );
        }

        return region;
    }

    // Adjust clip boundaries to trim off any fully transparent rows or columns.
    // This circumvents abstractions from z2d so that it can be performant.
    fn trim(self: *Canvas) void {
        const width: u32 = @intCast(self.sfc.getWidth());
        const height: u32 = @intCast(self.sfc.getHeight());

        const buf = std.mem.sliceAsBytes(self.sfc.image_surface_alpha8.buf);

        top: while (self.clip_top < height - self.clip_bottom) {
            const y = self.clip_top;
            const x0 = self.clip_left;
            const x1 = width - self.clip_right;
            for (buf[y * width ..][x0..x1]) |v| {
                if (v != 0) break :top;
            }
            self.clip_top += 1;
        }

        bottom: while (self.clip_bottom < height - self.clip_top) {
            const y = height - self.clip_bottom -| 1;
            const x0 = self.clip_left;
            const x1 = width - self.clip_right;
            for (buf[y * width ..][x0..x1]) |v| {
                if (v != 0) break :bottom;
            }
            self.clip_bottom += 1;
        }

        left: while (self.clip_left < width - self.clip_right) {
            const x = self.clip_left;
            const y0 = self.clip_top;
            const y1 = height - self.clip_bottom;
            for (y0..y1) |y| {
                if (buf[y * width + x] != 0) break :left;
            }
            self.clip_left += 1;
        }

        right: while (self.clip_right < width - self.clip_left) {
            const x = width - self.clip_right -| 1;
            const y0 = self.clip_top;
            const y1 = height - self.clip_bottom;
            for (y0..y1) |y| {
                if (buf[y * width + x] != 0) break :right;
            }
            self.clip_right += 1;
        }
    }

    /// Only really useful for test purposes, since the clipping region is
    /// automatically excluded when writing to an atlas with `writeAtlas`.
    pub fn clearClippingRegions(self: *Canvas) void {
        const buf = std.mem.sliceAsBytes(self.sfc.image_surface_alpha8.buf);
        const width: usize = @intCast(self.sfc.getWidth());
        const height: usize = @intCast(self.sfc.getHeight());

        for (0..height) |y| {
            for (0..self.clip_left) |x| {
                buf[y * width + x] = 0;
            }
        }

        for (0..height) |y| {
            for (width - self.clip_right..width) |x| {
                buf[y * width + x] = 0;
            }
        }

        for (0..self.clip_top) |y| {
            for (0..width) |x| {
                buf[y * width + x] = 0;
            }
        }

        for (height - self.clip_bottom..height) |y| {
            for (0..width) |x| {
                buf[y * width + x] = 0;
            }
        }
    }

    /// Return a transformation representing the translation for our padding.
    pub fn transformation(self: Canvas) z2d.Transformation {
        return .{
            .ax = 1,
            .by = 0,
            .cx = 0,
            .dy = 1,
            .tx = @as(f64, @floatFromInt(self.padding_x)),
            .ty = @as(f64, @floatFromInt(self.padding_y)),
        };
    }

    /// Acquires a z2d drawing context, caller MUST deinit context.
    pub fn getContext(self: *Canvas) z2d.Context {
        var ctx = z2d.Context.init(self.alloc, &self.sfc);
        // Offset by our padding to keep
        // coordinates relative to the cell.
        ctx.setTransformation(self.transformation());
        return ctx;
    }

    /// Draw and fill a single pixel
    pub fn pixel(self: *Canvas, x: i32, y: i32, color: Color) void {
        self.sfc.putPixel(
            x + @as(i32, @intCast(self.padding_x)),
            y + @as(i32, @intCast(self.padding_y)),
            .{ .alpha8 = .{ .a = @intFromEnum(color) } },
        );
    }

    /// Draw and fill a rectangle. This is the main primitive for drawing
    /// lines as well (which are just generally skinny rectangles...)
    pub fn rect(self: *Canvas, v: Rect(i32), color: Color) void {
        var y = v.y;
        while (y < v.y + v.height) : (y += 1) {
            var x = v.x;
            while (x < v.x + v.width) : (x += 1) {
                self.pixel(
                    @intCast(x),
                    @intCast(y),
                    color,
                );
            }
        }
    }

    /// Convenience wrapper for `Canvas.rect`
    pub fn box(
        self: *Canvas,
        x0: i32,
        y0: i32,
        x1: i32,
        y1: i32,
        color: Color,
    ) void {
        self.rect((Box(i32){
            .p0 = .{ .x = x0, .y = y0 },
            .p1 = .{ .x = x1, .y = y1 },
        }).rect(), color);
    }

    /// Draw and fill a quad.
    pub fn quad(self: *Canvas, q: Quad(f64), color: Color) !void {
        var path = self.staticPath(6); // nodes.len = 0
        path.moveTo(q.p0.x, q.p0.y); // +1, nodes.len = 1
        path.lineTo(q.p1.x, q.p1.y); // +1, nodes.len = 2
        path.lineTo(q.p2.x, q.p2.y); // +1, nodes.len = 3
        path.lineTo(q.p3.x, q.p3.y); // +1, nodes.len = 4
        path.close(); // +2, nodes.len = 6
        try self.fillPath(path.wrapped_path, .{}, color);
    }

    /// Draw and fill a triangle.
    pub fn triangle(self: *Canvas, t: Triangle(f64), color: Color) !void {
        var path = self.staticPath(5); // nodes.len = 0
        path.moveTo(t.p0.x, t.p0.y); // +1, nodes.len = 1
        path.lineTo(t.p1.x, t.p1.y); // +1, nodes.len = 2
        path.lineTo(t.p2.x, t.p2.y); // +1, nodes.len = 3
        path.close(); // +2, nodes.len = 5
        try self.fillPath(path.wrapped_path, .{}, color);
    }

    /// Stroke a line.
    pub fn line(
        self: *Canvas,
        l: Line(f64),
        thickness: f64,
        color: Color,
    ) !void {
        var path = self.staticPath(2); // nodes.len = 0
        path.moveTo(l.p0.x, l.p0.y); // +1, nodes.len = 1
        path.lineTo(l.p1.x, l.p1.y); // +1, nodes.len = 2
        try self.strokePath(
            path.wrapped_path,
            .{
                .line_cap_mode = .butt,
                .line_width = thickness,
            },
            color,
        );
    }

    /// Create a static path of the provided len and initialize it.
    /// Use this function instead of making the path manually since
    /// it ensures that the transform is applied.
    pub inline fn staticPath(
        self: *Canvas,
        comptime len: usize,
    ) z2d.StaticPath(len) {
        var path: z2d.StaticPath(len) = .{};
        path.init();
        path.wrapped_path.transformation = self.transformation();
        return path;
    }

    /// Stroke a z2d path.
    pub fn strokePath(
        self: *Canvas,
        path: z2d.Path,
        opts: z2d.painter.StrokeOpts,
        color: Color,
    ) z2d.painter.StrokeError!void {
        try z2d.painter.stroke(
            self.alloc,
            &self.sfc,
            &.{ .opaque_pattern = .{
                .pixel = .{ .alpha8 = .{ .a = @intFromEnum(color) } },
            } },
            path.nodes.items,
            opts,
        );
    }

    /// Do an inner stroke on a z2d path, right now this involves a pretty
    /// heavy workaround that uses two extra surfaces; in the future, z2d
    /// should add inner and outer strokes natively.
    pub fn innerStrokePath(
        self: *Canvas,
        path: z2d.Path,
        opts: z2d.painter.StrokeOpts,
        color: Color,
    ) (z2d.painter.StrokeError || z2d.painter.FillError)!void {
        // On one surface we fill the shape, this will be a mask we
        // multiply with the double-width stroke so that only the
        // part inside is used.
        var fill_sfc: z2d.Surface = try .init(
            .image_surface_alpha8,
            self.alloc,
            self.sfc.getWidth(),
            self.sfc.getHeight(),
        );
        defer fill_sfc.deinit(self.alloc);

        // On the other we'll do the double width stroke.
        var stroke_sfc: z2d.Surface = try .init(
            .image_surface_alpha8,
            self.alloc,
            self.sfc.getWidth(),
            self.sfc.getHeight(),
        );
        defer stroke_sfc.deinit(self.alloc);

        // Make a closed version of the path for our fill, so
        // that we can support open paths for inner stroke.
        var closed_path = path;
        closed_path.nodes = try path.nodes.clone(self.alloc);
        defer closed_path.deinit(self.alloc);
        try closed_path.close(self.alloc);

        // Fill the shape in white to the fill surface, we use
        // white because this is a mask that we'll multiply with
        // the stroke, we want everything inside to be the stroke
        // color.
        try z2d.painter.fill(
            self.alloc,
            &fill_sfc,
            &.{ .opaque_pattern = .{
                .pixel = .{ .alpha8 = .{ .a = 255 } },
            } },
            closed_path.nodes.items,
            .{},
        );

        // Stroke the shape with double the desired width.
        var mut_opts = opts;
        mut_opts.line_width *= 2;
        try z2d.painter.stroke(
            self.alloc,
            &stroke_sfc,
            &.{ .opaque_pattern = .{
                .pixel = .{ .alpha8 = .{ .a = @intFromEnum(color) } },
            } },
            path.nodes.items,
            mut_opts,
        );

        // We multiply the stroke sfc on to the fill surface.
        // The z2d composite operation doesn't seem to work for
        // this with alpha8 surfaces, so we have to do it manually.
        for (
            std.mem.sliceAsBytes(fill_sfc.image_surface_alpha8.buf),
            std.mem.sliceAsBytes(stroke_sfc.image_surface_alpha8.buf),
        ) |*d, s| {
            d.* = @intFromFloat(@round(
                255.0 *
                    (@as(f64, @floatFromInt(s)) / 255.0) *
                    (@as(f64, @floatFromInt(d.*)) / 255.0),
            ));
        }

        // Then we composite the result on to the main surface.
        self.sfc.composite(&fill_sfc, .src_over, 0, 0, .{});
    }

    /// Fill a z2d path.
    pub fn fillPath(
        self: *Canvas,
        path: z2d.Path,
        opts: z2d.painter.FillOpts,
        color: Color,
    ) z2d.painter.FillError!void {
        try z2d.painter.fill(
            self.alloc,
            &self.sfc,
            &.{ .opaque_pattern = .{
                .pixel = .{ .alpha8 = .{ .a = @intFromEnum(color) } },
            } },
            path.nodes.items,
            opts,
        );
    }

    /// Invert all pixels on the canvas.
    pub fn invert(self: *Canvas) void {
        for (std.mem.sliceAsBytes(self.sfc.image_surface_alpha8.buf)) |*v| {
            v.* = 255 - v.*;
        }
    }

    /// Mirror the canvas horizontally.
    pub fn flipHorizontal(self: *Canvas) Allocator.Error!void {
        const buf = std.mem.sliceAsBytes(self.sfc.image_surface_alpha8.buf);
        const clone = try self.alloc.dupe(u8, buf);
        defer self.alloc.free(clone);
        const width: usize = @intCast(self.sfc.getWidth());
        const height: usize = @intCast(self.sfc.getHeight());
        for (0..height) |y| {
            for (0..width) |x| {
                buf[y * width + x] = clone[y * width + width - x - 1];
            }
        }
        std.mem.swap(u32, &self.clip_left, &self.clip_right);
    }

    /// Mirror the canvas vertically.
    pub fn flipVertical(self: *Canvas) Allocator.Error!void {
        const buf = std.mem.sliceAsBytes(self.sfc.image_surface_alpha8.buf);
        const clone = try self.alloc.dupe(u8, buf);
        defer self.alloc.free(clone);
        const width: usize = @intCast(self.sfc.getWidth());
        const height: usize = @intCast(self.sfc.getHeight());
        for (0..height) |y| {
            for (0..width) |x| {
                buf[y * width + x] = clone[(height - y - 1) * width + x];
            }
        }
        std.mem.swap(u32, &self.clip_top, &self.clip_bottom);
    }
};
