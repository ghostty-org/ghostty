//! Face represents a single font face. A single font face has a single set
//! of properties associated with it such as style, weight, etc.
//!
//! A Face isn't typically meant to be used directly. It is usually used
//! via a Family in order to store it in an Atlas.

const std = @import("std");
const builtin = @import("builtin");
const freetype = @import("freetype");
const harfbuzz = @import("harfbuzz");
const stb = @import("../../stb/main.zig");
const assert = std.debug.assert;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const font = @import("../main.zig");
const Glyph = font.Glyph;
const Library = font.Library;
const opentype = @import("../opentype.zig");
const fastmem = @import("../../fastmem.zig");
const quirks = @import("../../quirks.zig");
const config = @import("../../config.zig");

const F26Dot6 = opentype.sfnt.F26Dot6;

const log = std.log.scoped(.font_face);

pub const Face = struct {
    comptime {
        // If we have the freetype backend, we should have load flags.
        assert(font.face.FreetypeLoadFlags != void);
    }

    /// Our Library
    lib: Library,

    /// Our font face.
    face: freetype.Face,

    /// This mutex MUST be held while doing anything with the
    /// glyph slot on the freetype face, because this struct
    /// may be shared across multiple surfaces.
    ///
    /// This means that anywhere where `self.face.loadGlyph`
    /// is called, this mutex must be held.
    ft_mutex: *std.Thread.Mutex,

    /// Harfbuzz font corresponding to this face.
    hb_font: harfbuzz.Font,

    /// Freetype load flags for this font face.
    load_flags: font.face.FreetypeLoadFlags,

    /// Set quirks.disableDefaultFontFeatures
    quirks_disable_default_font_features: bool = false,

    /// Set to true to apply a synthetic italic to the face.
    synthetic: packed struct {
        italic: bool = false,
        bold: bool = false,
    } = .{},

    /// The current size this font is set to.
    size: font.face.DesiredSize,

    /// Initialize a new font face with the given source in-memory.
    pub fn initFile(
        lib: Library,
        path: [:0]const u8,
        index: i32,
        opts: font.face.Options,
    ) !Face {
        lib.mutex.lock();
        defer lib.mutex.unlock();
        const face = try lib.lib.initFace(path, index);
        errdefer face.deinit();
        return try initFace(lib, face, opts);
    }

    /// Initialize a new font face with the given source in-memory.
    pub fn init(
        lib: Library,
        source: [:0]const u8,
        opts: font.face.Options,
    ) !Face {
        lib.mutex.lock();
        defer lib.mutex.unlock();
        const face = try lib.lib.initMemoryFace(source, 0);
        errdefer face.deinit();
        return try initFace(lib, face, opts);
    }

    fn initFace(
        lib: Library,
        face: freetype.Face,
        opts: font.face.Options,
    ) !Face {
        try face.selectCharmap(.unicode);
        try setSize_(face, opts.size);

        var hb_font = try harfbuzz.freetype.createFont(face.handle);
        errdefer hb_font.destroy();

        const ft_mutex = try lib.alloc.create(std.Thread.Mutex);
        errdefer lib.alloc.destroy(ft_mutex);
        ft_mutex.* = .{};

        var result: Face = .{
            .lib = lib,
            .face = face,
            .hb_font = hb_font,
            .ft_mutex = ft_mutex,
            .load_flags = opts.freetype_load_flags,
            .size = opts.size,
        };
        result.quirks_disable_default_font_features = quirks.disableDefaultFontFeatures(&result);

        // In debug mode, we output information about available variation axes,
        // if they exist.
        if (comptime builtin.mode == .Debug) mm: {
            if (!face.hasMultipleMasters()) break :mm;
            var buf: [1024]u8 = undefined;
            log.debug("variation axes font={s}", .{try result.name(&buf)});

            const mm = try face.getMMVar();
            defer lib.lib.doneMMVar(mm);
            for (0..mm.num_axis) |i| {
                const axis = mm.axis[i];
                const id_raw = std.math.cast(c_int, axis.tag) orelse continue;
                const id: font.face.Variation.Id = @bitCast(id_raw);
                log.debug("variation axis: name={s} id={s} min={} max={} def={}", .{
                    std.mem.sliceTo(axis.name, 0),
                    id.str(),
                    axis.minimum >> 16,
                    axis.maximum >> 16,
                    axis.def >> 16,
                });
            }
        }

        return result;
    }

    pub fn deinit(self: *Face) void {
        self.lib.alloc.destroy(self.ft_mutex);
        {
            self.lib.mutex.lock();
            defer self.lib.mutex.unlock();

            self.face.deinit();
        }
        self.hb_font.destroy();
        self.* = undefined;
    }

    /// Returns the font name. If allocation is required, buf will be used,
    /// but sometimes allocation isn't required and a static string is
    /// returned.
    pub fn name(self: *const Face, buf: []u8) Allocator.Error![]const u8 {
        const count = self.face.getSfntNameCount();

        // We look for the font family entry.
        for (0..count) |i| {
            const entry = self.face.getSfntName(i) catch continue;
            if (entry.name_id == freetype.c.TT_NAME_ID_FONT_FAMILY) {
                const string = entry.string[0..entry.string_len];
                // There are other encodings that are something other than UTF-8
                // but this is one we've seen "in the wild" so far.
                if (entry.platform_id == freetype.c.TT_PLATFORM_MICROSOFT and entry.encoding_id == freetype.c.TT_MS_ID_UNICODE_CS) skip: {
                    if (string.len % 2 != 0) break :skip;
                    if (string.len > 1024) break :skip;
                    var tmp: [512]u16 = undefined;
                    const max = string.len / 2;
                    for (@as([]const u16, @ptrCast(@alignCast(string))), 0..) |c, j| tmp[j] = @byteSwap(c);
                    const len = std.unicode.utf16LeToUtf8(buf, tmp[0..max]) catch return string;
                    return buf[0..len];
                }
                return string;
            }
        }

        return "";
    }

    test "face name" {
        const embedded = @import("../embedded.zig");

        var lib: Library = try .init(testing.allocator);
        defer lib.deinit();

        {
            var face: Face = try .init(lib, embedded.variable, .{ .size = .{ .points = 14 } });
            defer face.deinit();

            var buf: [1024]u8 = undefined;
            const actual = try face.name(&buf);

            try testing.expectEqualStrings("JetBrains Mono", actual);
        }

        {
            var face: Face = try .init(lib, embedded.inconsolata, .{ .size = .{ .points = 14 } });
            defer face.deinit();

            var buf: [1024]u8 = undefined;
            const actual = try face.name(&buf);

            try testing.expectEqualStrings("Inconsolata", actual);
        }
    }

    /// Return a new face that is the same as this but also has synthetic
    /// bold applied.
    pub fn syntheticBold(self: *const Face, opts: font.face.Options) !Face {
        // Increase face ref count
        self.face.ref();
        errdefer self.face.deinit();

        var f = try initFace(self.lib, self.face, opts);
        errdefer f.deinit();
        f.synthetic = self.synthetic;
        f.synthetic.bold = true;

        return f;
    }

    /// Return a new face that is the same as this but has a transformation
    /// matrix applied to italicize it.
    pub fn syntheticItalic(self: *const Face, opts: font.face.Options) !Face {
        // Increase face ref count
        self.face.ref();
        errdefer self.face.deinit();

        var f = try initFace(self.lib, self.face, opts);
        errdefer f.deinit();
        f.synthetic = self.synthetic;
        f.synthetic.italic = true;

        return f;
    }

    /// Resize the font in-place. If this succeeds, the caller is responsible
    /// for clearing any glyph caches, font atlas data, etc.
    pub fn setSize(self: *Face, opts: font.face.Options) !void {
        try setSize_(self.face, opts.size);
        self.size = opts.size;
    }

    fn setSize_(face: freetype.Face, size: font.face.DesiredSize) !void {
        // If we have fixed sizes, we just have to try to pick the one closest
        // to what the user requested. Otherwise, we can choose an arbitrary
        // pixel size.
        if (face.isScalable()) {
            const size_26dot6: i32 = @intFromFloat(@round(size.points * 64));
            try face.setCharSize(0, size_26dot6, size.xdpi, size.ydpi);
        } else try selectSizeNearest(face, @intFromFloat(@round(size.pixels())));
    }

    /// Selects the fixed size in the loaded face that is closest to the
    /// requested pixel size.
    fn selectSizeNearest(face: freetype.Face, size: u32) !void {
        var i: i32 = 0;
        var best_i: i32 = 0;
        var best_diff: i32 = 0;
        while (i < face.handle.*.num_fixed_sizes) : (i += 1) {
            const width = face.handle.*.available_sizes[@intCast(i)].width;
            const diff = @as(i32, @intCast(size)) - @as(i32, @intCast(width));
            if (i == 0 or diff < best_diff) {
                best_diff = diff;
                best_i = i;
            }
        }

        try face.selectSize(best_i);
    }

    /// Set the variation axes for this font. This will modify this font
    /// in-place.
    pub fn setVariations(
        self: *Face,
        vs: []const font.face.Variation,
        opts: font.face.Options,
    ) !void {
        _ = opts;

        // If this font doesn't support variations, we can't do anything.
        if (!self.face.hasMultipleMasters() or vs.len == 0) return;

        // Freetype requires that we send ALL coordinates in at once so the
        // first thing we have to do is get all the vars and put them into
        // an array.
        const mm = try self.face.getMMVar();
        defer self.lib.lib.doneMMVar(mm);

        // To avoid allocations, we cap the number of variation axes we can
        // support. This is arbitrary but Firefox caps this at 16 so I
        // feel like that's probably safe... and we do double cause its
        // cheap.
        var coords_buf: [32]freetype.c.FT_Fixed = undefined;
        var coords = coords_buf[0..@min(coords_buf.len, mm.num_axis)];
        try self.face.getVarDesignCoordinates(coords);

        // Now we go through each axis and see if its set. This is slow
        // but there usually aren't many axes and usually not many set
        // variations, either.
        for (0..mm.num_axis) |i| {
            const axis = mm.axis[i];
            const id = std.math.cast(u32, axis.tag) orelse continue;
            for (vs) |v| {
                if (id == @as(u32, @bitCast(v.id))) {
                    coords[i] = @intFromFloat(v.value * 65536);
                    break;
                }
            }
        }

        // Set them!
        try self.face.setVarDesignCoordinates(coords);
    }

    /// Returns the glyph index for the given Unicode code point. If this
    /// face doesn't support this glyph, null is returned.
    pub fn glyphIndex(self: Face, cp: u32) ?u32 {
        return self.face.getCharIndex(cp);
    }

    /// Returns true if this font is colored. This can be used by callers to
    /// determine what kind of atlas to pass in.
    pub fn hasColor(self: Face) bool {
        return self.face.hasColor();
    }

    /// Returns true if the given glyph ID is colorized.
    pub fn isColorGlyph(self: *const Face, glyph_id: u32) bool {
        self.ft_mutex.lock();
        defer self.ft_mutex.unlock();

        // Load the glyph and see what pixel mode it renders with.
        // All modes other than BGRA are non-color.
        // If the glyph fails to load, just return false.
        self.face.loadGlyph(glyph_id, .{
            .render = true,
            .color = self.face.hasColor(),
            // NO_SVG set to true because we don't currently support rendering
            // SVG glyphs under FreeType, since that requires bundling another
            // dependency to handle rendering the SVG.
            .no_svg = true,
        }) catch return false;

        const glyph = self.face.handle.*.glyph;

        return glyph.*.bitmap.pixel_mode == freetype.c.FT_PIXEL_MODE_BGRA;
    }

    /// Set the load flags to use when loading a glyph for measurement or
    /// rendering.
    fn glyphLoadFlags(self: Face, constrained: bool) freetype.LoadFlags {
        // Hinting should only be enabled if the configured load flags specify
        // it and the provided constraint doesn't actually do anything, since
        // if it does, then it'll mess up the hinting anyway when it moves or
        // resizes the glyph.
        const do_hinting = self.load_flags.hinting and !constrained;

        return .{
            // If our glyph has color, we want to render the color
            .color = self.face.hasColor(),

            // We don't render, because we'll invoke the render
            // manually after applying constraints further down.
            .render = false,

            // use options from config
            .no_hinting = !do_hinting,
            .force_autohint = self.load_flags.@"force-autohint",
            .no_autohint = !self.load_flags.autohint,

            // If we're gonna be rendering this glyph in monochrome,
            // then we should use the monochrome hinter as well, or
            // else it won't look very good at all.
            .target_mono = self.load_flags.monochrome,

            // NO_SVG set to true because we don't currently support rendering
            // SVG glyphs under FreeType, since that requires bundling another
            // dependency to handle rendering the SVG.
            .no_svg = true,
        };
    }

    /// Get a rect that represents the position and size of the loaded glyph.
    fn getGlyphSize(glyph: freetype.c.FT_GlyphSlot) font.face.GlyphSize {
        // If we're dealing with an outline glyph then we get the
        // outline's bounding box instead of using the built-in
        // metrics, since that's more precise and allows better
        // cell-fitting.
        if (glyph.*.format == freetype.c.FT_GLYPH_FORMAT_OUTLINE) {
            // Get the glyph's bounding box before we transform it at all.
            // We use this rather than the metrics, since it's more precise.
            var bbox: freetype.c.FT_BBox = undefined;
            _ = freetype.c.FT_Outline_Get_BBox(&glyph.*.outline, &bbox);

            return .{
                .x = f26dot6ToF64(bbox.xMin),
                .y = f26dot6ToF64(bbox.yMin),
                .width = f26dot6ToF64(bbox.xMax - bbox.xMin),
                .height = f26dot6ToF64(bbox.yMax - bbox.yMin),
            };
        }

        return .{
            .x = f26dot6ToF64(glyph.*.metrics.horiBearingX),
            .y = f26dot6ToF64(glyph.*.metrics.horiBearingY - glyph.*.metrics.height),
            .width = f26dot6ToF64(glyph.*.metrics.width),
            .height = f26dot6ToF64(glyph.*.metrics.height),
        };
    }

    /// Render a glyph using the glyph index. The rendered glyph is stored in the
    /// given texture atlas.
    pub fn renderGlyph(
        self: Face,
        alloc: Allocator,
        atlas: *font.Atlas,
        glyph_index: u32,
        opts: font.face.RenderOptions,
    ) !Glyph {
        self.ft_mutex.lock();
        defer self.ft_mutex.unlock();

        // Load the glyph.
        try self.face.loadGlyph(glyph_index, self.glyphLoadFlags(opts.constraint.doesAnything()));
        const glyph = self.face.handle.*.glyph;

        // For synthetic bold, we embolden the glyph.
        if (self.synthetic.bold) {
            // We need to scale the embolden amount based on the font size.
            // This is a heuristic I found worked well across a variety of
            // founts: 1 pixel per 64 units of height.
            const font_height: f64 = @floatFromInt(self.face.handle.*.size.*.metrics.height);
            const ratio: f64 = 64.0 / 2048.0;
            const amount = @ceil(font_height * ratio);
            _ = freetype.c.FT_Outline_Embolden(&glyph.*.outline, @intFromFloat(amount));
        }

        // We get a rect that represents the position
        // and size of the glyph before constraints.
        const rect = getGlyphSize(glyph);

        // If our glyph is smaller than a quarter pixel in either axis
        // then it has no outlines or they're too small to render.
        //
        // In this case we just return 0-sized glyph struct.
        if (rect.width < 0.25 or rect.height < 0.25)
            return font.Glyph{
                .width = 0,
                .height = 0,
                .offset_x = 0,
                .offset_y = 0,
                .atlas_x = 0,
                .atlas_y = 0,
            };

        const metrics = opts.grid_metrics;
        const cell_width: f64 = @floatFromInt(metrics.cell_width);
        const cell_height: f64 = @floatFromInt(metrics.cell_height);

        // Next we apply any constraints to get the final size of the glyph.
        const constraint = opts.constraint;

        // We need to add the baseline position before passing to the constrain
        // function since it operates on cell-relative positions, not baseline.
        const cell_baseline: f64 = @floatFromInt(metrics.cell_baseline);

        const glyph_size = constraint.constrain(
            .{
                .width = rect.width,
                .height = rect.height,
                .x = rect.x,
                .y = rect.y + cell_baseline,
            },
            metrics,
            opts.constraint_width,
        );

        var width = glyph_size.width;
        var height = glyph_size.height;
        var x = glyph_size.x;
        var y = glyph_size.y;

        // We center all glyphs within the pixel-rounded and adjusted
        // cell width if it's larger than the face width, so that they
        // aren't weirdly off to the left.
        //
        // We don't do this if the glyph has a stretch constraint,
        // since in that case the position was already calculated with the
        // new cell width in mind.
        if ((constraint.size != .stretch) and (metrics.face_width < cell_width)) {
            // We add half the difference to re-center.
            //
            // NOTE: We round this to a whole-pixel amount because under
            //       FreeType, the outlines will be hinted, which isn't
            //       the case under CoreText. If we move the outlines by
            //       a non-whole-pixel amount, it completely ruins the
            //       hinting.
            x += @round((cell_width - metrics.face_width) / 2);
        }

        // If this is a bitmap glyph, it will always render as full pixels,
        // not fractional pixels, so we need to quantize its position and
        // size accordingly to align to full pixels so we get good results.
        if (glyph.*.format == freetype.c.FT_GLYPH_FORMAT_BITMAP) {
            width = cell_width - @round(cell_width - width - x) - @round(x);
            height = cell_height - @round(cell_height - height - y) - @round(y);
            x = @round(x);
            y = @round(y);
        }

        // Now we can render the glyph.
        var bitmap: freetype.c.FT_Bitmap = undefined;
        _ = freetype.c.FT_Bitmap_Init(&bitmap);
        defer _ = freetype.c.FT_Bitmap_Done(self.lib.lib.handle, &bitmap);
        switch (glyph.*.format) {
            freetype.c.FT_GLYPH_FORMAT_OUTLINE => {
                // Manually adjust the glyph outline with this transform.
                //
                // This offers better precision than using the freetype transform
                // matrix, since that has 16.16 coefficients, and also I was having
                // weird issues that I can only assume where due to freetype doing
                // some bad caching or something when I did this using the matrix.
                const scale_x = width / rect.width;
                const scale_y = height / rect.height;
                const skew: f64 =
                    if (self.synthetic.italic)
                        // We skew by 12 degrees to synthesize italics.
                        @tan(std.math.degreesToRadians(12))
                    else
                        0.0;

                const outline = &glyph.*.outline;
                for (outline.points[0..@intCast(outline.n_points)]) |*p| {
                    // Convert to f64 for processing
                    var px = f26dot6ToF64(p.x);
                    var py = f26dot6ToF64(p.y);

                    // Subtract original bearings
                    px -= rect.x;
                    py -= rect.y;

                    // Scale
                    px *= scale_x;
                    py *= scale_y;

                    // Add new bearings
                    px += x;
                    py += y - cell_baseline;

                    // Skew
                    px += py * skew;

                    // Convert back and store
                    p.x = @as(i32, @bitCast(F26Dot6.from(px)));
                    p.y = @as(i32, @bitCast(F26Dot6.from(py)));
                }

                try self.face.renderGlyph(
                    if (self.load_flags.monochrome)
                        .mono
                    else
                        .normal,
                );

                // Copy the glyph's bitmap, making sure
                // that it's 8bpp and densely packed.
                if (freetype.c.FT_Bitmap_Convert(
                    self.lib.lib.handle,
                    &glyph.*.bitmap,
                    &bitmap,
                    1,
                ) != 0) {
                    return error.BitmapHandlingError;
                }
            },

            freetype.c.FT_GLYPH_FORMAT_BITMAP => {
                // If our glyph has a non-color bitmap, we need
                // to convert it to dense 8bpp so that the scale
                // operation works correctly.
                switch (glyph.*.bitmap.pixel_mode) {
                    freetype.c.FT_PIXEL_MODE_BGRA,
                    freetype.c.FT_PIXEL_MODE_GRAY,
                    => {},
                    else => {
                        // Make sure the slot owns its bitmap,
                        // since we'll be modifying it here.
                        if (freetype.c.FT_GlyphSlot_Own_Bitmap(glyph) != 0) {
                            return error.BitmapHandlingError;
                        }

                        var converted: freetype.c.FT_Bitmap = undefined;
                        freetype.c.FT_Bitmap_Init(&converted);
                        if (freetype.c.FT_Bitmap_Convert(
                            self.lib.lib.handle,
                            &glyph.*.bitmap,
                            &converted,
                            1,
                        ) != 0) {
                            return error.BitmapHandlingError;
                        }
                        // Free the existing glyph bitmap and
                        // replace it with the converted one.
                        _ = freetype.c.FT_Bitmap_Done(
                            self.lib.lib.handle,
                            &glyph.*.bitmap,
                        );
                        glyph.*.bitmap = converted;
                    },
                }

                const glyph_bitmap = glyph.*.bitmap;

                // Round our target width and height
                // as the size for our scaled bitmap.
                const w: u32 = @intFromFloat(@round(width));
                const h: u32 = @intFromFloat(@round(height));
                const pitch = w * atlas.format.depth();

                // Allocate a buffer for our scaled bitmap.
                //
                // We'll copy this to the original bitmap once we're
                // done so we can free it at the end of this scope.
                const buf = try alloc.alloc(u8, pitch * h);
                defer alloc.free(buf);

                // Resize
                if (stb.stbir_resize_uint8(
                    glyph_bitmap.buffer,
                    @intCast(glyph_bitmap.width),
                    @intCast(glyph_bitmap.rows),
                    glyph_bitmap.pitch,
                    buf.ptr,
                    @intCast(w),
                    @intCast(h),
                    @intCast(pitch),
                    atlas.format.depth(),
                ) == 0) {
                    // This should never fail because this is a
                    // fairly straightforward in-memory operation...
                    return error.GlyphResizeFailed;
                }

                const scaled_bitmap: freetype.c.FT_Bitmap = .{
                    .buffer = buf.ptr,
                    .width = @intCast(w),
                    .rows = @intCast(h),
                    .pitch = @intCast(pitch),
                    .pixel_mode = glyph_bitmap.pixel_mode,
                    .num_grays = glyph_bitmap.num_grays,
                };

                // Replace the bitmap's buffer and size info.
                if (freetype.c.FT_Bitmap_Copy(
                    self.lib.lib.handle,
                    &scaled_bitmap,
                    &bitmap,
                ) != 0) {
                    return error.BitmapHandlingError;
                }

                // Update the bearings to account for the new positioning.
                glyph.*.bitmap_top = @intFromFloat(@floor(y - cell_baseline + height));
                glyph.*.bitmap_left = @intFromFloat(@floor(x));
            },

            else => |f| {
                // Glyph formats are tags, so we can
                // output a semi-readable error here.
                log.err(
                    "Can't render glyph with unsupported glyph format \"{s}\"",
                    .{[4]u8{
                        @truncate(f >> 24),
                        @truncate(f >> 16),
                        @truncate(f >> 8),
                        @truncate(f >> 0),
                    }},
                );
                return error.UnsupportedGlyphFormat;
            },
        }

        // If this is a color glyph but we're trying to render it to the
        // grayscale atlas, or vice versa, then we throw and error. Maybe
        // in the future we could convert, but for now it should be fine.
        switch (bitmap.pixel_mode) {
            freetype.c.FT_PIXEL_MODE_GRAY => if (atlas.format != .grayscale) {
                return error.WrongAtlas;
            },
            freetype.c.FT_PIXEL_MODE_BGRA => if (atlas.format != .bgra) {
                return error.WrongAtlas;
            },
            else => {
                log.warn("glyph={} pixel mode={}", .{ glyph_index, bitmap.pixel_mode });
                @panic("unsupported pixel mode");
            },
        }

        // Our whole-pixel bearings for the final glyph.
        // The fractional portion will be included in the rasterized position.
        //
        // For the Y position, FreeType's `bitmap_top` is the distance from the
        // baseline to the top of the glyph, but we need the distance from the
        // bottom of the cell to the bottom of the glyph, so first we add the
        // baseline to get the distance from the bottom of the cell to the top
        // of the glyph, then we subtract the height of the glyph to get the
        // bottom.
        const px_x: i32 = glyph.*.bitmap_left;
        const px_y: i32 = glyph.*.bitmap_top +
            @as(i32, @intCast(metrics.cell_baseline)) -
            @as(i32, @intCast(bitmap.rows));

        const px_width = bitmap.width;
        const px_height = bitmap.rows;
        const len: usize = @intCast(
            @as(c_uint, @intCast(@abs(bitmap.pitch))) * bitmap.rows,
        );

        // If our bitmap is grayscale, make sure to multiply all pixel
        // values by the right factor to bring `num_grays` up to 256.
        //
        // This is necessary because FT_Bitmap_Convert doesn't do this,
        // it just sets num_grays to the correct number and uses the
        // original smaller pixel values.
        if (bitmap.pixel_mode == freetype.c.FT_PIXEL_MODE_GRAY and
            bitmap.num_grays < 256)
        {
            const factor: u8 = @intCast(255 / (bitmap.num_grays - 1));
            for (bitmap.buffer[0..len]) |*p| {
                p.* *= factor;
            }
            bitmap.num_grays = 256;
        }

        // Must have non-empty bitmap because we return earlier if zero.
        // We assume the rest of this that it is non-zero so this is important.
        assert(px_width > 0 and px_height > 0);

        // If this doesn't match then something is wrong.
        assert(px_width * atlas.format.depth() == bitmap.pitch);

        // Allocate our texture atlas region and copy our bitmap in to it.
        const region = try atlas.reserve(alloc, px_width, px_height);
        atlas.set(region, bitmap.buffer[0..len]);

        // This should be the distance from the bottom of
        // the cell to the top of the glyph's bounding box.
        const offset_y: i32 = px_y + @as(i32, @intCast(px_height));

        // This should be the distance from the left of
        // the cell to the left of the glyph's bounding box.
        const offset_x: i32 = px_x;

        return Glyph{
            .width = px_width,
            .height = px_height,
            .offset_x = offset_x,
            .offset_y = offset_y,
            .atlas_x = region.x,
            .atlas_y = region.y,
        };
    }

    /// Convert 16.6 pixel format to pixels based on the scale factor of the
    /// current font size.
    fn unitsToPxY(self: Face, units: i32) i32 {
        return @intCast(freetype.mulFix(
            units,
            @intCast(self.face.handle.*.size.*.metrics.y_scale),
        ) >> 6);
    }

    /// Convert 26.6 pixel format to f32
    fn f26dot6ToFloat(v: freetype.c.FT_F26Dot6) f32 {
        return @floatFromInt(v >> 6);
    }

    fn f26dot6ToF64(v: freetype.c.FT_F26Dot6) f64 {
        return @as(F26Dot6, @bitCast(@as(i32, @intCast(v)))).to(f64);
    }

    /// Get the `FaceMetrics` for this face.
    pub fn getMetrics(self: *Face) font.Metrics.FaceMetrics {
        const face = self.face;

        const size_metrics = face.handle.*.size.*.metrics;

        // This code relies on this assumption, and it should always be
        // true since we don't do any non-uniform scaling on the font ever.
        assert(size_metrics.x_ppem == size_metrics.y_ppem);

        // Read the 'head' table out of the font data.
        const head_ = face.getSfntTable(.head);

        // Read the 'post' table out of the font data.
        const post_ = face.getSfntTable(.post);

        // Read the 'OS/2' table out of the font data.
        const os2_: ?*freetype.c.TT_OS2 = os2: {
            const os2 = face.getSfntTable(.os2) orelse break :os2 null;
            if (os2.version == 0xFFFF) break :os2 null;
            break :os2 os2;
        };

        // Read the 'hhea' table out of the font data.
        const hhea_ = face.getSfntTable(.hhea);

        // Whether the font is in a scalable format. We need to know this
        // because many of the metrics provided by FreeType are invalid for
        // non-scalable fonts.
        const is_scalable = face.handle.*.face_flags & freetype.c.FT_FACE_FLAG_SCALABLE != 0;

        // We get the UPM from the head table.
        //
        // If we have no head, but it is a scalable face, take the UPM from
        // FreeType's units_per_EM, otherwise we'll assume that UPM == PPEM.
        const units_per_em: freetype.c.FT_UShort =
            if (head_) |head|
                head.Units_Per_EM
            else if (is_scalable)
                face.handle.*.units_per_EM
            else
                size_metrics.y_ppem;
        const px_per_em: f64 = @floatFromInt(size_metrics.y_ppem);
        const px_per_unit = px_per_em / @as(f64, @floatFromInt(units_per_em));

        const ascent: f64, const descent: f64, const line_gap: f64 = vertical_metrics: {
            const hhea = hhea_ orelse {
                // If we couldn't get the hhea table, rely on metrics from FreeType.
                const ascender = f26dot6ToF64(size_metrics.ascender);
                const descender = f26dot6ToF64(size_metrics.descender);
                const height = f26dot6ToF64(size_metrics.height);
                break :vertical_metrics .{
                    ascender,
                    descender,
                    // We compute the line gap by adding the (negative) descender
                    // and subtracting the (positive) ascender from the line height
                    // to get the remaining gap size.
                    //
                    // NOTE: This might always be 0... but it doesn't hurt to do.
                    height + descender - ascender,
                };
            };

            const hhea_ascent: f64 = @floatFromInt(hhea.Ascender);
            const hhea_descent: f64 = @floatFromInt(hhea.Descender);
            const hhea_line_gap: f64 = @floatFromInt(hhea.Line_Gap);

            // If our font has no OS/2 table, then we just
            // blindly use the metrics from the hhea table.
            const os2 = os2_ orelse break :vertical_metrics .{
                hhea_ascent * px_per_unit,
                hhea_descent * px_per_unit,
                hhea_line_gap * px_per_unit,
            };

            const os2_ascent: f64 = @floatFromInt(os2.sTypoAscender);
            const os2_descent: f64 = @floatFromInt(os2.sTypoDescender);
            const os2_line_gap: f64 = @floatFromInt(os2.sTypoLineGap);

            // If the font says to use typo metrics, trust it.
            // (The USE_TYPO_METRICS bit is bit 7)
            if (os2.fsSelection & (1 << 7) != 0) {
                break :vertical_metrics .{
                    os2_ascent * px_per_unit,
                    os2_descent * px_per_unit,
                    os2_line_gap * px_per_unit,
                };
            }

            // Otherwise we prefer the height metrics from 'hhea' if they
            // are available, or else OS/2 sTypo* metrics, and if all else
            // fails then we use OS/2 usWin* metrics.
            //
            // This is not "standard" behavior, but it's our best bet to
            // account for fonts being... just weird. It's pretty much what
            // FreeType does to get its generic ascent and descent metrics.

            if (hhea.Ascender != 0 or hhea.Descender != 0) {
                break :vertical_metrics .{
                    hhea_ascent * px_per_unit,
                    hhea_descent * px_per_unit,
                    hhea_line_gap * px_per_unit,
                };
            }

            if (os2_ascent != 0 or os2_descent != 0) {
                break :vertical_metrics .{
                    os2_ascent * px_per_unit,
                    os2_descent * px_per_unit,
                    os2_line_gap * px_per_unit,
                };
            }

            const win_ascent: f64 = @floatFromInt(os2.usWinAscent);
            const win_descent: f64 = @floatFromInt(os2.usWinDescent);
            break :vertical_metrics .{
                win_ascent * px_per_unit,
                // usWinDescent is *positive* -> down unlike sTypoDescender
                // and hhea.Descender, so we flip its sign to fix this.
                -win_descent * px_per_unit,
                0.0,
            };
        };

        const underline_position: ?f64, const underline_thickness: ?f64 = ul: {
            const post = post_ orelse break :ul .{ null, null };

            // Some fonts have degenerate 'post' tables where the underline
            // thickness (and often position) are 0. We consider them null
            // if this is the case and use our own fallbacks when we calculate.
            const has_broken_underline = post.underlineThickness == 0;

            // If the underline position isn't 0 then we do use it,
            // even if the thickness is't properly specified.
            const pos: ?f64 = if (has_broken_underline and post.underlinePosition == 0)
                null
            else
                @as(f64, @floatFromInt(post.underlinePosition)) * px_per_unit;

            const thick: ?f64 = if (has_broken_underline)
                null
            else
                @as(f64, @floatFromInt(post.underlineThickness)) * px_per_unit;

            break :ul .{ pos, thick };
        };

        // Similar logic to the underline above.
        const strikethrough_position, const strikethrough_thickness = st: {
            const os2 = os2_ orelse break :st .{ null, null };

            const has_broken_strikethrough = os2.yStrikeoutSize == 0;

            const pos: ?f64 = if (has_broken_strikethrough and os2.yStrikeoutPosition == 0)
                null
            else
                @as(f64, @floatFromInt(os2.yStrikeoutPosition)) * px_per_unit;

            const thick: ?f64 = if (has_broken_strikethrough)
                null
            else
                @as(f64, @floatFromInt(os2.yStrikeoutSize)) * px_per_unit;

            break :st .{ pos, thick };
        };

        // Cell width is calculated by calculating the widest width of the
        // visible ASCII characters. Usually 'M' is widest but we just take
        // whatever is widest.
        //
        // ASCII height is calculated as the height of the overall bounding
        // box of the same characters.
        //
        // If we fail to load any visible ASCII we just use max_advance from
        // the metrics provided by FreeType, and set ascii_height to null as
        // it's optional.
        const cell_width: f64, const ascii_height: ?f64 = measurements: {
            self.ft_mutex.lock();
            defer self.ft_mutex.unlock();

            var max: f64 = 0.0;
            var top: f64 = 0.0;
            var bottom: f64 = 0.0;
            var c: u8 = ' ';
            while (c < 127) : (c += 1) {
                if (face.getCharIndex(c)) |glyph_index| {
                    if (face.loadGlyph(glyph_index, self.glyphLoadFlags(false))) {
                        const glyph = face.handle.*.glyph;
                        max = @max(
                            f26dot6ToF64(glyph.*.advance.x),
                            max,
                        );
                        const rect = getGlyphSize(glyph);
                        top = @max(rect.y + rect.height, top);
                        bottom = @min(rect.y, bottom);
                    } else |_| {}
                }
            }

            // If we couldn't get valid measurements, just use
            // FreeType's max_advance and null, respectively.
            if (max == 0.0) {
                max = f26dot6ToF64(size_metrics.max_advance);
            }
            const rect_height: ?f64 = rect_height: {
                const estimate = top - bottom;
                if (estimate <= 0.0) {
                    break :rect_height null;
                }
                break :rect_height estimate;
            };

            break :measurements .{ max, rect_height };
        };

        // We use the cap and ex heights specified by the font if they're
        // available, otherwise we try to measure the `H` and `x` glyphs.
        const cap_height: ?f64, const ex_height: ?f64 = heights: {
            if (os2_) |os2| {
                // The OS/2 table does not include these metrics in version 1.
                if (os2.version >= 2) {
                    break :heights .{
                        @as(f64, @floatFromInt(os2.sCapHeight)) * px_per_unit,
                        @as(f64, @floatFromInt(os2.sxHeight)) * px_per_unit,
                    };
                }
            }

            break :heights .{
                cap: {
                    self.ft_mutex.lock();
                    defer self.ft_mutex.unlock();
                    if (face.getCharIndex('H')) |glyph_index| {
                        if (face.loadGlyph(glyph_index, self.glyphLoadFlags(false))) {
                            break :cap getGlyphSize(face.handle.*.glyph).height;
                        } else |_| {}
                    }
                    break :cap null;
                },
                ex: {
                    self.ft_mutex.lock();
                    defer self.ft_mutex.unlock();
                    if (face.getCharIndex('x')) |glyph_index| {
                        if (face.loadGlyph(glyph_index, self.glyphLoadFlags(false))) {
                            break :ex getGlyphSize(face.handle.*.glyph).height;
                        } else |_| {}
                    }
                    break :ex null;
                },
            };
        };

        // Measure "水" (CJK water ideograph, U+6C34) for our ic width.
        const ic_width: ?f64 = ic_width: {
            self.ft_mutex.lock();
            defer self.ft_mutex.unlock();

            const glyph = face.getCharIndex('水') orelse break :ic_width null;

            face.loadGlyph(glyph, self.glyphLoadFlags(false)) catch break :ic_width null;

            const ft_glyph = face.handle.*.glyph;

            // If the advance of the glyph is less than the width of the actual
            // glyph then we just treat it as invalid since it's probably wrong
            // and using it for size normalization will instead make the font
            // way too big.
            //
            // This can sometimes happen if there's a CJK font that has been
            // patched with the nerd fonts patcher and it butchers the advance
            // values so the advance ends up half the width of the actual glyph.
            const ft_glyph_width = getGlyphSize(ft_glyph).width;
            const advance = f26dot6ToF64(ft_glyph.*.advance.x);
            if (ft_glyph_width > advance) {
                var buf: [1024]u8 = undefined;
                const font_name = self.name(&buf) catch "<Error getting font name>";
                log.warn(
                    "(getMetrics) Width of glyph '水' for font \"{s}\" is greater than its advance ({d} > {d}), discarding ic_width metric.",
                    .{ font_name, ft_glyph_width, advance },
                );
                break :ic_width null;
            }

            break :ic_width advance;
        };

        return .{
            .px_per_em = px_per_em,

            .cell_width = cell_width,

            .ascent = ascent,
            .descent = descent,
            .line_gap = line_gap,

            .underline_position = underline_position,
            .underline_thickness = underline_thickness,

            .strikethrough_position = strikethrough_position,
            .strikethrough_thickness = strikethrough_thickness,

            .cap_height = cap_height,
            .ex_height = ex_height,
            .ascii_height = ascii_height,
            .ic_width = ic_width,
        };
    }

    /// Copy the font table data for the given tag.
    pub fn copyTable(self: Face, alloc: Allocator, tag: *const [4]u8) !?[]u8 {
        return try self.face.loadSfntTable(alloc, freetype.Tag.init(tag));
    }
};

test {
    const testFont = font.embedded.inconsolata;
    const alloc = testing.allocator;

    var lib = try Library.init(alloc);
    defer lib.deinit();

    var atlas = try font.Atlas.init(alloc, 512, .grayscale);
    defer atlas.deinit(alloc);

    var ft_font = try Face.init(
        lib,
        testFont,
        .{ .size = .{ .points = 12, .xdpi = 96, .ydpi = 96 } },
    );
    defer ft_font.deinit();

    // Generate all visible ASCII
    var i: u8 = 32;
    while (i < 127) : (i += 1) {
        _ = try ft_font.renderGlyph(
            alloc,
            &atlas,
            ft_font.glyphIndex(i).?,
            .{ .grid_metrics = font.Metrics.calc(ft_font.getMetrics()) },
        );
    }

    // Test resizing
    {
        const g1 = try ft_font.renderGlyph(
            alloc,
            &atlas,
            ft_font.glyphIndex('A').?,
            .{ .grid_metrics = font.Metrics.calc(ft_font.getMetrics()) },
        );
        try testing.expectEqual(@as(u32, 11), g1.height);

        try ft_font.setSize(.{ .size = .{ .points = 24, .xdpi = 96, .ydpi = 96 } });
        const g2 = try ft_font.renderGlyph(
            alloc,
            &atlas,
            ft_font.glyphIndex('A').?,
            .{ .grid_metrics = font.Metrics.calc(ft_font.getMetrics()) },
        );
        try testing.expectEqual(@as(u32, 20), g2.height);
    }
}

test "color emoji" {
    const alloc = testing.allocator;
    const testFont = font.embedded.emoji;

    var lib = try Library.init(alloc);
    defer lib.deinit();

    var atlas = try font.Atlas.init(alloc, 512, .bgra);
    defer atlas.deinit(alloc);

    var ft_font = try Face.init(
        lib,
        testFont,
        .{ .size = .{ .points = 12, .xdpi = 96, .ydpi = 96 } },
    );
    defer ft_font.deinit();

    _ = try ft_font.renderGlyph(
        alloc,
        &atlas,
        ft_font.glyphIndex('🥸').?,
        .{ .grid_metrics = font.Metrics.calc(ft_font.getMetrics()) },
    );

    // Make sure this glyph has color
    {
        try testing.expect(ft_font.hasColor());
        const glyph_id = ft_font.glyphIndex('🥸').?;
        try testing.expect(ft_font.isColorGlyph(glyph_id));
    }
}

test "mono to bgra" {
    const alloc = testing.allocator;
    const testFont = font.embedded.emoji;

    var lib = try Library.init(alloc);
    defer lib.deinit();

    var atlas = try font.Atlas.init(alloc, 512, .bgra);
    defer atlas.deinit(alloc);

    var ft_font = try Face.init(lib, testFont, .{ .size = .{ .points = 12, .xdpi = 72, .ydpi = 72 } });
    defer ft_font.deinit();

    // glyph 3 is mono in Noto
    _ = try ft_font.renderGlyph(
        alloc,
        &atlas,
        3,
        .{ .grid_metrics = font.Metrics.calc(ft_font.getMetrics()) },
    );
}

test "svg font table" {
    const alloc = testing.allocator;
    const testFont = font.embedded.julia_mono;

    var lib = try font.Library.init(alloc);
    defer lib.deinit();

    var face = try Face.init(lib, testFont, .{ .size = .{ .points = 12, .xdpi = 72, .ydpi = 72 } });
    defer face.deinit();

    const table = (try face.copyTable(alloc, "SVG ")).?;
    defer alloc.free(table);

    try testing.expectEqual(430, table.len);
}

const terminus_i =
    \\........
    \\........
    \\...#....
    \\...#....
    \\........
    \\..##....
    \\...#....
    \\...#....
    \\...#....
    \\...#....
    \\...#....
    \\..###...
    \\........
    \\........
    \\........
    \\........
;
// Including the newline
const terminus_i_pitch = 9;

test "bitmap glyph" {
    const alloc = testing.allocator;
    const testFont = font.embedded.terminus_ttf;

    var lib = try Library.init(alloc);
    defer lib.deinit();

    var atlas = try font.Atlas.init(alloc, 512, .grayscale);
    defer atlas.deinit(alloc);

    // Any glyph at 12pt @ 96 DPI is a bitmap
    var ft_font = try Face.init(lib, testFont, .{ .size = .{
        .points = 12,
        .xdpi = 96,
        .ydpi = 96,
    } });
    defer ft_font.deinit();

    // glyph 77 = 'i'
    const glyph = try ft_font.renderGlyph(
        alloc,
        &atlas,
        77,
        .{ .grid_metrics = font.Metrics.calc(ft_font.getMetrics()) },
    );

    // should render crisp
    try testing.expectEqual(8, glyph.width);
    try testing.expectEqual(16, glyph.height);
    for (0..glyph.height) |y| {
        for (0..glyph.width) |x| {
            const pixel = terminus_i[y * terminus_i_pitch + x];
            try testing.expectEqual(
                @as(u8, if (pixel == '#') 255 else 0),
                atlas.data[(glyph.atlas_y + y) * atlas.size + (glyph.atlas_x + x)],
            );
        }
    }
}
