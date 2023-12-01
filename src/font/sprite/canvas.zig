//! This exposes primitives to draw 2D graphics and export the graphic to
//! a font atlas.
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const js = @import("zig-js");
const pixman = @import("pixman");
const font = @import("../main.zig");

pub const Point = struct {
    x: i32,
    y: i32,
};

pub const Line = struct {
    p1: Point,
    p2: Point,
};

pub const Box = struct {
    x1: i32,
    y1: i32,
    x2: i32,
    y2: i32,

    pub fn rect(self: Box) Rect {
        const tl_x = @min(self.x1, self.x2);
        const tl_y = @min(self.y1, self.y2);
        const br_x = @max(self.x1, self.x2);
        const br_y = @max(self.y1, self.y2);
        return .{
            .x = tl_x,
            .y = tl_y,
            .width = @intCast(br_x - tl_x),
            .height = @intCast(br_y - tl_y),
        };
    }
};

pub const Rect = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
};

pub const Triangle = struct {
    p1: Point,
    p2: Point,
    p3: Point,
};

pub const Trapezoid = struct {
    top: i32,
    bottom: i32,
    left: Line,
    right: Line,
};

/// We only use alpha-channel so a pixel can only be "on" or "off".
pub const Color = enum(u8) {
    const CSS_BUF_MAX = 24;

    on = 255,
    off = 0,
    _,

    fn pixmanColor(self: Color) pixman.Color {
        // pixman uses u16 for color while our color value is u8 so we
        // scale it up proportionally.
        const max = @as(f32, @floatFromInt(std.math.maxInt(u8)));
        const max_u16 = @as(f32, @floatFromInt(std.math.maxInt(u16)));
        const unscaled = @as(f32, @floatFromInt(@intFromEnum(self)));
        const scaled = @as(u16, @intFromFloat((unscaled * max_u16) / max));
        return .{ .red = 0, .green = 0, .blue = 0, .alpha = scaled };
    }

    fn cssColor(self: Color, buf: []u8) ![]u8 {
        return try std.fmt.bufPrint(buf, "rgba(0, 0, 0, {:.2})", .{
            @as(f32, @floatFromInt(@intFromEnum(self))) / 255,
        });
    }
};

/// Composition operations that are supported.
pub const CompositionOp = enum {
    // Note: more can be added here as needed.

    source_out,

    fn pixmanOp(self: CompositionOp) pixman.Op {
        return switch (self) {
            .source_out => .out,
        };
    }

    fn jsOp(self: CompositionOp) js.String {
        return switch (self) {
            .source_out => js.string("source-out"),
        };
    }
};

pub const Canvas = switch (font.options.backend) {
    .web_canvas => WebCanvasImpl,
    else => PixmanImpl,
};

const WebCanvasImpl = struct {
    /// The canvas element that is our final image.
    canvas: js.Object,

    /// Store the dimensions for easy access later.
    width: u32,
    height: u32,

    pub fn init(alloc: Allocator, width: u32, height: u32) !WebCanvasImpl {
        _ = alloc;

        // Create our canvas that we're going to continue to reuse.
        const doc = try js.global.get(js.Object, "document");
        defer doc.deinit();
        const canvas = try doc.call(js.Object, "createElement", .{js.string("canvas")});
        errdefer canvas.deinit();

        // Set our dimensions.
        try canvas.set("width", width);
        try canvas.set("height", height);

        return WebCanvasImpl{
            .canvas = canvas,
            .width = width,
            .height = height,
        };
    }

    pub fn deinit(self: *WebCanvasImpl, alloc: Allocator) void {
        _ = alloc;
        self.canvas.deinit();
        self.* = undefined;
    }

    pub fn pixel(self: *WebCanvasImpl, x: u32, y: u32, color: Color) void {
        const ctx = self.context(color) catch return;
        defer ctx.deinit();
        ctx.call(void, "fillRect", .{ x, y, 1, 1 }) catch return;
    }

    pub fn rect(self: *WebCanvasImpl, v: Rect, color: Color) void {
        const ctx = self.context(color) catch return;
        defer ctx.deinit();
        ctx.call(void, "fillRect", .{
            @as(u32, @intCast(v.x)),
            @as(u32, @intCast(v.y)),
            v.width,
            v.height,
        }) catch return;
    }

    pub fn trapezoid(self: *WebCanvasImpl, t: Trapezoid) void {
        const ctx = self.context(.on) catch return;
        defer ctx.deinit();

        ctx.call(void, "beginPath", .{}) catch return;
        ctx.call(void, "moveTo", .{ t.left.p1.x, t.left.p1.y }) catch return;
        ctx.call(void, "lineTo", .{ t.right.p1.x, t.right.p1.y }) catch return;
        ctx.call(void, "lineTo", .{ t.right.p2.x, t.right.p2.y }) catch return;
        ctx.call(void, "lineTo", .{ t.left.p2.x, t.left.p2.y }) catch return;
        ctx.call(void, "fill", .{}) catch return;
    }

    pub fn triangle(self: *WebCanvasImpl, t: Triangle, color: Color) void {
        const ctx = self.context(color) catch return;
        defer ctx.deinit();

        ctx.call(void, "beginPath", .{}) catch return;
        ctx.call(void, "moveTo", .{ t.p1.x, t.p1.y }) catch return;
        ctx.call(void, "lineTo", .{ t.p2.x, t.p2.y }) catch return;
        ctx.call(void, "lineTo", .{ t.p3.x, t.p3.y }) catch return;
        ctx.call(void, "fill", .{}) catch return;
    }

    pub fn composite(
        self: *WebCanvasImpl,
        op: CompositionOp,
        src: *const WebCanvasImpl,
        dest: Rect,
    ) void {
        const ctx = self.context(Color.on) catch return;
        defer ctx.deinit();

        // Set our compositing operation
        ctx.set("globalCompositeOperation", op.jsOp()) catch return;

        // Composite
        ctx.call(void, "drawImage", .{
            src.canvas,
            dest.x,
            dest.y,
            dest.width,
            dest.height,
        }) catch return;
    }

    fn context(self: WebCanvasImpl, fill: ?Color) !js.Object {
        const ctx = try self.canvas.call(js.Object, "getContext", .{js.string("2d")});
        errdefer ctx.deinit();

        // Reset our composite operation
        try ctx.set("globalCompositeOperation", js.string("source-over"));

        // Set our fill color
        if (fill) |c| {
            var buf: [Color.CSS_BUF_MAX]u8 = undefined;
            const color = try c.cssColor(&buf);
            try ctx.set("fillStyle", js.string(color));
        }

        return ctx;
    }

    pub fn writeAtlas(self: *WebCanvasImpl, alloc: Allocator, atlas: *font.Atlas) !font.Atlas.Region {
        assert(atlas.format == .greyscale);

        // Reload our context since we resized the canvas
        const ctx = try self.context(null);
        defer ctx.deinit();

        // Set our width/height. Set to vars in case we just query the canvas later.
        const width = self.width;
        const height = self.height;

        // Read the image data and get it into a []u8 on our side
        const bitmap: []u8 = bitmap: {
            // Read the raw bitmap data and get the "data" value which is a
            // Uint8ClampedArray.
            const data = try ctx.call(js.Object, "getImageData", .{ 0, 0, width, height });
            defer data.deinit();
            const src_array = try data.get(js.Object, "data");
            defer src_array.deinit();

            // Allocate our local memory to copy the data to.
            const len = try src_array.get(u32, "length");
            const bitmap = try alloc.alloc(u8, @intCast(len));
            errdefer alloc.free(bitmap);

            // Create our target Uint8Array that we can use to copy from src.
            const mem_array = mem_array: {
                // Get our runtime memory
                const mem = try js.runtime.get(js.Object, "memory");
                defer mem.deinit();
                const buf = try mem.get(js.Object, "buffer");
                defer buf.deinit();

                // Construct our array to peer into our memory
                const Uint8Array = try js.global.get(js.Object, "Uint8Array");
                defer Uint8Array.deinit();
                const mem_array = try Uint8Array.new(.{ buf, bitmap.ptr });
                errdefer mem_array.deinit();

                break :mem_array mem_array;
            };
            defer mem_array.deinit();

            // Copy
            try mem_array.call(void, "set", .{src_array});

            break :bitmap bitmap;
        };
        errdefer alloc.free(bitmap);

        // Convert the format of the bitmap to A8 since the raw canvas data
        // is in RGBA.
        // NOTE(mitchellh): do we need a 1px buffer to avoid artifacts?
        const bitmap_a8: []u8 = a8: {
            assert(@mod(bitmap.len, 4) == 0);
            assert(bitmap.len == width * height * 4);
            var bitmap_a8 = try alloc.alloc(u8, bitmap.len / 4);
            errdefer alloc.free(bitmap_a8);
            var i: usize = 0;
            while (i < bitmap_a8.len) : (i += 1) {
                bitmap_a8[i] = bitmap[(i * 4) + 3];
            }

            break :a8 bitmap_a8;
        };
        defer alloc.free(bitmap_a8);

        // Write the glyph information into the atlas
        const region = try atlas.reserve(alloc, width, height);
        if (region.width > 0 and region.height > 0) {
            assert(region.width == width);
            assert(region.height == height);
            atlas.set(region, bitmap_a8);
        }

        return region;
    }
};

const PixmanImpl = struct {
    /// The underlying image.
    image: *pixman.Image,

    /// The raw data buffer.
    data: []u32,

    pub fn init(alloc: Allocator, width: u32, height: u32) !Canvas {
        // Determine the config for our image buffer. The images we draw
        // for boxes are always 8bpp
        const format: pixman.FormatCode = .a8;
        const stride = format.strideForWidth(width);
        const len = @as(usize, @intCast(stride * @as(c_int, @intCast(height))));

        // Allocate our buffer. pixman uses []u32 so we divide our length
        // by 4 since u32 / u8 = 4.
        const data = try alloc.alloc(u32, len / 4);
        errdefer alloc.free(data);
        @memset(data, 0);

        // Create the image we'll draw to
        const img = try pixman.Image.createBitsNoClear(
            format,
            @intCast(width),
            @intCast(height),
            data.ptr,
            stride,
        );
        errdefer _ = img.unref();

        return Canvas{
            .image = img,
            .data = data,
        };
    }

    pub fn deinit(self: *Canvas, alloc: Allocator) void {
        alloc.free(self.data);
        _ = self.image.unref();
        self.* = undefined;
    }

    /// Write the data in this drawing to the atlas.
    pub fn writeAtlas(self: *Canvas, alloc: Allocator, atlas: *font.Atlas) !font.Atlas.Region {
        assert(atlas.format == .greyscale);

        const width = @as(u32, @intCast(self.image.getWidth()));
        const height = @as(u32, @intCast(self.image.getHeight()));

        // Allocate our texture atlas region
        const region = region: {
            // We need to add a 1px padding to the font so that we don't
            // get fuzzy issues when blending textures.
            const padding = 1;

            // Get the full padded region
            var region = try atlas.reserve(
                alloc,
                width + (padding * 2), // * 2 because left+right
                height + (padding * 2), // * 2 because top+bottom
            );

            // Modify the region so that we remove the padding so that
            // we write to the non-zero location. The data in an Altlas
            // is always initialized to zero (Atlas.clear) so we don't
            // need to worry about zero-ing that.
            region.x += padding;
            region.y += padding;
            region.width -= padding * 2;
            region.height -= padding * 2;
            break :region region;
        };

        if (region.width > 0 and region.height > 0) {
            const depth = atlas.format.depth();

            // Convert our []u32 to []u8 since we use 8bpp formats
            const stride = self.image.getStride();
            const data = @as([*]u8, @ptrCast(self.data.ptr))[0 .. self.data.len * 4];

            // We can avoid a buffer copy if our atlas width and bitmap
            // width match and the bitmap pitch is just the width (meaning
            // the data is tightly packed).
            const needs_copy = !(width * depth == stride);

            // If we need to copy the data, we copy it into a temporary buffer.
            const buffer = if (needs_copy) buffer: {
                const temp = try alloc.alloc(u8, width * height * depth);
                var dst_ptr = temp;
                var src_ptr = data.ptr;
                var i: usize = 0;
                while (i < height) : (i += 1) {
                    @memcpy(dst_ptr[0 .. width * depth], src_ptr[0 .. width * depth]);
                    dst_ptr = dst_ptr[width * depth ..];
                    src_ptr += @as(usize, @intCast(stride));
                }
                break :buffer temp;
            } else data[0..(width * height * depth)];
            defer if (buffer.ptr != data.ptr) alloc.free(buffer);

            // Write the glyph information into the atlas
            assert(region.width == width);
            assert(region.height == height);
            atlas.set(region, buffer);
        }

        return region;
    }

    /// Draw and fill a single pixel
    pub fn pixel(self: *Canvas, x: u32, y: u32, color: Color) void {
        const boxes = &[_]pixman.Box32{
            .{
                .x1 = @intCast(x),
                .y1 = @intCast(y),
                .x2 = @intCast(x + 1),
                .y2 = @intCast(y + 1),
            },
        };

        self.image.fillBoxes(.src, color.pixmanColor(), boxes) catch {};
    }

    /// Draw and fill a rectangle. This is the main primitive for drawing
    /// lines as well (which are just generally skinny rectangles...)
    pub fn rect(self: *Canvas, v: Rect, color: Color) void {
        const boxes = &[_]pixman.Box32{
            .{
                .x1 = @intCast(v.x),
                .y1 = @intCast(v.y),
                .x2 = @intCast(v.x + @as(i32, @intCast(v.width))),
                .y2 = @intCast(v.y + @as(i32, @intCast(v.height))),
            },
        };

        self.image.fillBoxes(.src, color.pixmanColor(), boxes) catch {};
    }

    /// Draw and fill a trapezoid.
    pub fn trapezoid(self: *Canvas, t: Trapezoid) void {
        self.image.rasterizeTrapezoid(.{
            .top = pixman.Fixed.init(t.top),
            .bottom = pixman.Fixed.init(t.bottom),
            .left = .{
                .p1 = .{
                    .x = pixman.Fixed.init(t.left.p1.x),
                    .y = pixman.Fixed.init(t.left.p1.y),
                },
                .p2 = .{
                    .x = pixman.Fixed.init(t.left.p2.x),
                    .y = pixman.Fixed.init(t.left.p2.y),
                },
            },
            .right = .{
                .p1 = .{
                    .x = pixman.Fixed.init(t.right.p1.x),
                    .y = pixman.Fixed.init(t.right.p1.y),
                },
                .p2 = .{
                    .x = pixman.Fixed.init(t.right.p2.x),
                    .y = pixman.Fixed.init(t.right.p2.y),
                },
            },
        }, 0, 0);
    }

    /// Draw and fill a triangle.
    pub fn triangle(self: *Canvas, t: Triangle, color: Color) void {
        const tris = &[_]pixman.Triangle{
            .{
                .p1 = .{ .x = pixman.Fixed.init(t.p1.x), .y = pixman.Fixed.init(t.p1.y) },
                .p2 = .{ .x = pixman.Fixed.init(t.p2.x), .y = pixman.Fixed.init(t.p2.y) },
                .p3 = .{ .x = pixman.Fixed.init(t.p3.x), .y = pixman.Fixed.init(t.p3.y) },
            },
        };

        const src = pixman.Image.createSolidFill(color.pixmanColor()) catch return;
        defer _ = src.unref();
        self.image.compositeTriangles(.over, src, .a8, 0, 0, 0, 0, tris);
    }

    /// Composite one image on another.
    pub fn composite(self: *Canvas, op: CompositionOp, src: *const Canvas, dest: Rect) void {
        self.image.composite(
            op.pixmanOp(),
            src.image,
            null,
            0,
            0,
            0,
            0,
            @intCast(dest.x),
            @intCast(dest.y),
            @intCast(dest.width),
            @intCast(dest.height),
        );
    }
};
