const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const js = @import("zig-js");
const font = @import("../main.zig");

const log = std.log.scoped(.font_face);

pub const Face = struct {
    /// See graphemes field for more details.
    const grapheme_start: u32 = 0x10FFFF + 1;
    const grapheme_end: u32 = std.math.maxInt(u32);

    /// The web canvas face makes use of an allocator when interacting
    /// with the JS environment.
    alloc: Allocator,

    /// The CSS "font" attribute, excluding size.
    font_str: []const u8,

    /// The size we currently have set.
    size: font.face.DesiredSize,

    /// The presentation for this font.
    presentation: font.Presentation,

    /// Metrics for this font face. These are useful for renderers.
    metrics: font.Metrics,

    /// The canvas element that we will reuse to render glyphs
    canvas: js.Object,

    /// The map to store multi-codepoint grapheme clusters that are rendered.
    /// We use 1 above the maximum unicode codepoint up to the max 32-bit
    /// unsigned integer to store the "glyph index" for graphemes.
    grapheme_to_glyph: std.StringHashMapUnmanaged(u32) = .{},
    glyph_to_grapheme: std.AutoHashMapUnmanaged(u32, []u8) = .{},
    grapheme_next: u32 = grapheme_start,

    /// Initialize a web canvas font with a "raw" value. The "raw" value can
    /// be any valid value for a CSS "font" property EXCLUDING the size. The
    /// size is always added via the `size` parameter.
    ///
    /// The raw value is copied so the caller can free it after it is gone.
    ///
    /// The presentation is given here directly because the browser gives
    /// us no easy way to determine the presentation we want for this font.
    /// Callers should just tell us what to expect.
    pub fn initNamed(
        alloc: Allocator,
        raw: []const u8,
        size: font.face.DesiredSize,
        presentation: font.Presentation,
    ) !Face {
        // Copy our font string because we're going to have to reuse it.
        const font_str = try alloc.dupe(u8, raw);
        errdefer alloc.free(font_str);

        // Create our canvas that we're going to continue to reuse.
        const doc = try js.global.get(js.Object, "document");
        defer doc.deinit();
        const canvas = try doc.call(js.Object, "createElement", .{js.string("canvas")});
        errdefer canvas.deinit();

        var result = Face{
            .alloc = alloc,
            .font_str = font_str,
            .size = size,
            .presentation = presentation,

            .canvas = canvas,

            // We're going to calculate these right after initialization.
            .metrics = undefined,
        };
        try result.calcMetrics();

        log.debug("face initialized: {s}", .{raw});
        return result;
    }

    pub fn deinit(self: *Face) void {
        self.alloc.free(self.font_str);
        self.grapheme_to_glyph.deinit(self.alloc);
        {
            var it = self.glyph_to_grapheme.valueIterator();
            while (it.next()) |value| self.alloc.free(value.*);
            self.glyph_to_grapheme.deinit(self.alloc);
        }
        self.canvas.deinit();
        self.* = undefined;
    }

    /// Resize the font in-place. If this succeeds, the caller is responsible
    /// for clearing any glyph caches, font atlas data, etc.
    pub fn setSize(self: *Face, size: font.face.DesiredSize) !void {
        const old = self.size;
        self.size = size;
        errdefer self.size = old;
        try self.calcMetrics();
    }

    /// Returns the glyph index for the given Unicode code point. For canvas,
    /// we support every glyph and the ID is just the codepoint since we don't
    /// have access to the underlying tables anyways. We let the browser deal
    /// with bad codepoints.
    pub fn glyphIndex(self: Face, cp: u32) ?u32 {
        // If this is a multi-codepoint grapheme then we only check if
        // we actually know about it.
        if (cp >= grapheme_start) {
            if (!self.glyph_to_grapheme.contains(cp)) return null;
        }

        // Render the glyph to determine if it is colored or not. We
        // have to do this because the browser will always try to render
        // whatever we give it and we have no API to determine color.
        //
        // We don't want to say yes to the wrong presentation because
        // it will go into the wrong Atlas.
        const p: font.Presentation = if (cp <= 255) .text else p: {
            break :p self.glyphPresentation(cp) catch {
                // In this case, we assume we are unable to render
                // this glyph and therefore just say we don't support it.
                return null;
            };
        };
        if (p != self.presentation) return null;

        return cp;
    }

    /// This determines the presentation of the glyph by literally
    /// inspecting the image data to look for any color. This isn't
    /// super performant but we don't have a better choice given the
    /// canvas APIs.
    fn glyphPresentation(
        self: Face,
        cp: u32,
    ) !font.Presentation {
        // Render the glyph
        var render = try self.renderGlyphInternal(self.alloc, cp);
        defer render.deinit();

        // Inspect the image data for any non-zeros in the RGB value.
        // NOTE(perf): this is an easy candidate for SIMD.
        var i: usize = 0;
        while (i < render.bitmap.len) : (i += 4) {
            if (render.bitmap[i] > 0 or
                render.bitmap[i + 1] > 0 or
                render.bitmap[i + 2] > 0) return .emoji;
        }

        return .text;
    }

    /// Returns the glyph index for the given grapheme cluster. The same
    /// cluster will always map to the same glyph index. This does not render
    /// the grapheme at this time, only reserves the index.
    pub fn graphemeGlyphIndex(self: *Face, cluster: []const u8) error{OutOfMemory}!u32 {
        // If we already have this stored then return it
        const gop = try self.grapheme_to_glyph.getOrPut(self.alloc, cluster);
        if (gop.found_existing) return gop.value_ptr.*;
        errdefer _ = self.grapheme_to_glyph.remove(cluster);

        // We don't have it stored. Ensure we have space to store. The
        // next will be "0" if we're out of space due to unsigned int wrapping.
        if (self.grapheme_next == 0) return error.OutOfMemory;

        // Copy the cluster for our reverse mapping
        const copy = try self.alloc.dupe(u8, cluster);
        errdefer self.alloc.free(copy);

        // Grow space for the reverse mapping
        try self.glyph_to_grapheme.ensureUnusedCapacity(self.alloc, 1);

        // Store it
        gop.value_ptr.* = self.grapheme_next;
        self.glyph_to_grapheme.putAssumeCapacity(self.grapheme_next, copy);

        self.grapheme_next +%= 1;
        return gop.value_ptr.*;
    }

    /// Render a glyph using the glyph index. The rendered glyph is stored
    /// in the given texture atlas.
    pub fn renderGlyph(
        self: Face,
        alloc: Allocator,
        atlas: *font.Atlas,
        glyph_index: u32,
        opts: font.face.RenderOptions,
    ) !font.Glyph {
        _ = opts;

        var render = try self.renderGlyphInternal(alloc, glyph_index);
        defer render.deinit();

        // Convert the format of the bitmap if necessary
        const bitmap_formatted: []u8 = switch (atlas.format) {
            // Bitmap is already in RGBA
            .rgba => render.bitmap,

            // Convert down to A8
            .grayscale => a8: {
                assert(@mod(render.bitmap.len, 4) == 0);
                var bitmap_a8 = try alloc.alloc(u8, render.bitmap.len / 4);
                errdefer alloc.free(bitmap_a8);
                var i: usize = 0;
                while (i < bitmap_a8.len) : (i += 1) {
                    bitmap_a8[i] = render.bitmap[(i * 4) + 3];
                }

                break :a8 bitmap_a8;
            },

            else => return error.UnsupportedAtlasFormat,
        };
        defer if (bitmap_formatted.ptr != render.bitmap.ptr) {
            alloc.free(bitmap_formatted);
        };

        // Put it in our atlas
        const region = try atlas.reserve(alloc, render.width, render.height);
        if (region.width > 0 and region.height > 0) {
            atlas.set(region, bitmap_formatted);
        }

        return font.Glyph{
            .width = render.width,
            .height = render.height,
            // TODO: this can't be right
            .offset_x = 0,
            .offset_y = 0,
            .atlas_x = region.x,
            .atlas_y = region.y,
        };
    }

    /// Calculate the metrics associated with a given face.
    fn calcMetrics(self: *Face) !void {
        const ctx = try self.context();
        defer ctx.deinit();

        // Cell width is the width of our M text
        const cell_width: f32 = cell_width: {
            const metrics = try ctx.call(js.Object, "measureText", .{js.string("M")});
            defer metrics.deinit();

            // We prefer the bounding box since it is tighter but certain
            // text such as emoji do not have a bounding box set so we use
            // the full run width instead.
            const bounding_right = try metrics.get(f32, "actualBoundingBoxRight");
            if (bounding_right > 0) break :cell_width bounding_right;
            break :cell_width try metrics.get(f32, "width");
        };

        // To get the cell height we render a high and low character and get
        // the total of the ascent and descent. This should equal our
        // pixel height but this is a more surefire way to get it.
        const height_metrics = try ctx.call(js.Object, "measureText", .{js.string("M_")});
        defer height_metrics.deinit();
        const asc = try height_metrics.get(f32, "actualBoundingBoxAscent");
        const desc = try height_metrics.get(f32, "actualBoundingBoxDescent");
        const cell_height = asc + desc;
        const cell_baseline = desc;

        // There isn't a declared underline position for canvas measurements
        // so we just go 1 under the cell height to match freetype logic
        // at this time (our freetype logic).
        const underline_position = cell_height - 1;
        const underline_thickness: f32 = 1;

        const result = font.Metrics{
            .cell_width = @intFromFloat(cell_width),
            .cell_height = @intFromFloat(cell_height),
            .cell_baseline = @intFromFloat(cell_baseline),
            .underline_position = @intFromFloat(underline_position),
            .underline_thickness = @intFromFloat(underline_thickness),
            .strikethrough_position = @intFromFloat(underline_position),
            .strikethrough_thickness = @intFromFloat(underline_thickness),
        };

        self.metrics = result;
        log.debug("metrics font={s} value={}", .{ self.font_str, self.metrics });
    }

    /// Returns the 2d context configured for drawing
    fn context(self: Face) !js.Object {
        // This will return the same context on subsequent calls so it
        // is important to reset it.
        const ctx = try self.canvas.call(js.Object, "getContext", .{js.string("2d")});
        errdefer ctx.deinit();

        // Clear the canvas
        {
            const width = try self.canvas.get(f64, "width");
            const height = try self.canvas.get(f64, "height");
            try ctx.call(void, "clearRect", .{ 0, 0, width, height });
        }

        // Set our context font
        const font_val = try std.fmt.allocPrint(
            self.alloc,
            "{d}px {s}",
            .{ self.size.points, self.font_str },
        );
        defer self.alloc.free(font_val);
        try ctx.set("font", js.string(font_val));

        // If the font property didn't change, then the font set didn't work.
        // We do this check because it is very easy to put an invalid font
        // in and this at least makes it show up in the logs.
        const check = try ctx.getAlloc(js.String, self.alloc, "font");
        defer self.alloc.free(check);
        if (!std.mem.eql(u8, font_val, check)) {
            log.warn("canvas font didn't set, fonts may be broken, expected={s} got={s}", .{
                font_val,
                check,
            });
        }

        return ctx;
    }

    /// An internal (web-canvas-only) format for rendered glyphs
    /// since we do render passes in multiple different situations.
    const RenderedGlyph = struct {
        alloc: Allocator,
        metrics: js.Object,
        width: u32,
        height: u32,
        bitmap: []u8,

        pub fn deinit(self: *RenderedGlyph) void {
            self.metrics.deinit();
            self.alloc.free(self.bitmap);
            self.* = undefined;
        }
    };

    /// Shared logic for rendering a glyph.
    fn renderGlyphInternal(
        self: Face,
        alloc: Allocator,
        glyph_index: u32,
    ) !RenderedGlyph {
        // Encode our glyph to UTF-8 so we can build a JS string out of it.
        var utf8: [4]u8 = undefined;
        const glyph_str = glyph_str: {
            // If we are a normal glyph then we are a single codepoint and
            // we just UTF8 encode it as-is.
            if (glyph_index < grapheme_start) {
                const utf8_len = try std.unicode.utf8Encode(@intCast(glyph_index), &utf8);
                break :glyph_str js.string(utf8[0..utf8_len]);
            }

            // We are a multi-codepoint glyph so we have to read the glyph
            // from the map and it is already utf8 encoded.
            const slice = self.glyph_to_grapheme.get(glyph_index) orelse
                return error.UnknownGraphemeCluster;
            break :glyph_str js.string(slice);
        };

        // Get our drawing context
        const measure_ctx = try self.context();
        defer measure_ctx.deinit();

        // Get the width and height of the render
        const metrics = try measure_ctx.call(js.Object, "measureText", .{glyph_str});
        errdefer metrics.deinit();
        const width: u32 = @as(u32, @intFromFloat(@ceil(width: {
            // We prefer the bounding box since it is tighter but certain
            // text such as emoji do not have a bounding box set so we use
            // the full run width instead.
            const bounding_right = try metrics.get(f32, "actualBoundingBoxRight");
            if (bounding_right > 0) break :width bounding_right;
            break :width try metrics.get(f32, "width");
        }))) + 1;

        const left = try metrics.get(f32, "actualBoundingBoxLeft");
        const asc = try metrics.get(f32, "actualBoundingBoxAscent");
        const desc = try metrics.get(f32, "actualBoundingBoxDescent");

        // On Firefox on Linux, the bounding box is broken in some cases for
        // ideographic glyphs (such as emoji). We detect this and behave
        // differently.
        const broken_bbox = asc + desc < 0.001;

        // Height is our ascender + descender for this char
        const height = if (!broken_bbox) @as(u32, @intFromFloat(@ceil(asc + desc))) + 1 else width;

        // Note: width and height both get "+ 1" added to them above. This
        // is important so that there is a 1px border around the glyph to avoid
        // any clipping in the atlas.

        // Resize canvas to match the glyph size exactly
        {
            try self.canvas.set("width", width);
            try self.canvas.set("height", height);

            const width_str = try std.fmt.allocPrint(alloc, "{d}px", .{width});
            defer alloc.free(width_str);
            const height_str = try std.fmt.allocPrint(alloc, "{d}px", .{height});
            defer alloc.free(height_str);

            const style = try self.canvas.get(js.Object, "style");
            defer style.deinit();
            try style.set("width", js.string(width_str));
            try style.set("height", js.string(height_str));
        }

        // Reload our context since we resized the canvas
        const ctx = try self.context();
        defer ctx.deinit();

        // For the broken bounding box case we render ideographic baselines
        // so that we just render the glyph fully in the box with no offsets.
        if (broken_bbox) {
            try ctx.set("textBaseline", js.string("ideographic"));
        }

        // Draw background
        try ctx.set("fillStyle", js.string("transparent"));
        try ctx.call(void, "fillRect", .{
            0,
            0,
            width,
            height,
        });

        // Draw glyph
        try ctx.set("fillStyle", js.string("black"));
        try ctx.call(void, "fillText", .{
            glyph_str,
            left + 1,
            if (!broken_bbox) asc + 1 else @as(f32, @floatFromInt(height)),
        });

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

        return RenderedGlyph{
            .alloc = alloc,
            .metrics = metrics,
            .width = width,
            .height = height,
            .bitmap = bitmap,
        };
    }
};

/// The wasm-compatible API.
pub const Wasm = struct {
    const wasm = @import("../../os/wasm.zig");
    const alloc = wasm.alloc;

    export fn face_new(ptr: [*]const u8, len: usize, pts: u16, p: u16) ?*Face {
        return face_new_(ptr, len, pts, p) catch null;
    }

    fn face_new_(ptr: [*]const u8, len: usize, pts: f32, presentation: u16) !*Face {
        var face = try Face.initNamed(
            alloc,
            ptr[0..len],
            .{ .points = pts },
            @enumFromInt(presentation),
        );
        errdefer face.deinit();

        const result = try alloc.create(Face);
        errdefer alloc.destroy(result);
        result.* = face;
        return result;
    }

    export fn face_free(ptr: ?*Face) void {
        if (ptr) |v| {
            v.deinit();
            alloc.destroy(v);
        }
    }

    /// Resulting pointer must be freed using the global "free".
    export fn face_render_glyph(
        face: *Face,
        atlas: *font.Atlas,
        codepoint: u32,
    ) ?*font.Glyph {
        return face_render_glyph_(face, atlas, codepoint) catch |err| {
            log.warn("error rendering glyph err={}", .{err});
            return null;
        };
    }

    export fn face_debug_canvas(face: *Face) void {
        face_debug_canvas_(face) catch |err| {
            log.warn("error adding debug canvas err={}", .{err});
        };
    }

    fn face_debug_canvas_(face: *Face) !void {
        const doc = try js.global.get(js.Object, "document");
        defer doc.deinit();

        const elem = try doc.call(
            ?js.Object,
            "getElementById",
            .{js.string("face-canvas")},
        ) orelse return error.CanvasContainerNotFound;
        defer elem.deinit();

        try elem.call(void, "append", .{face.canvas});
    }

    fn face_render_glyph_(face: *Face, atlas: *font.Atlas, codepoint: u32) !*font.Glyph {
        const glyph = try face.renderGlyph(alloc, atlas, codepoint, .{});

        const result = try alloc.create(font.Glyph);
        errdefer alloc.destroy(result);
        _ = try wasm.toHostOwned(result);
        result.* = glyph;
        return result;
    }
};
