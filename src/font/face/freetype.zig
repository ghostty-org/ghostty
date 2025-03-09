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
const convert = @import("freetype_convert.zig");
const opentype = @import("../opentype.zig");
const fastmem = @import("../../fastmem.zig");
const quirks = @import("../../quirks.zig");
const config = @import("../../config.zig");

const log = std.log.scoped(.font_face);

pub const Face = struct {
    comptime {
        // If we have the freetype backend, we should have load flags.
        assert(font.face.FreetypeLoadFlags != void);
    }

    /// Our freetype library
    lib: freetype.Library,

    /// Our font face.
    face: freetype.Face,

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

    /// The matrix applied to a regular font to create a synthetic italic.
    const italic_matrix: freetype.c.FT_Matrix = .{
        .xx = 0x10000,
        .xy = 0x044ED, // approx. tan(15)
        .yx = 0,
        .yy = 0x10000,
    };

    /// Initialize a new font face with the given source in-memory.
    pub fn initFile(lib: Library, path: [:0]const u8, index: i32, opts: font.face.Options) !Face {
        const face = try lib.lib.initFace(path, index);
        errdefer face.deinit();
        return try initFace(lib, face, opts);
    }

    /// Initialize a new font face with the given source in-memory.
    pub fn init(lib: Library, source: [:0]const u8, opts: font.face.Options) !Face {
        const face = try lib.lib.initMemoryFace(source, 0);
        errdefer face.deinit();
        return try initFace(lib, face, opts);
    }

    fn initFace(lib: Library, face: freetype.Face, opts: font.face.Options) !Face {
        try face.selectCharmap(.unicode);
        try setSize_(face, opts.size);

        var hb_font = try harfbuzz.freetype.createFont(face.handle);
        errdefer hb_font.destroy();

        var result: Face = .{
            .lib = lib.lib,
            .face = face,
            .hb_font = hb_font,
            .load_flags = opts.freetype_load_flags,
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
        self.face.deinit();
        self.hb_font.destroy();
        self.* = undefined;
    }

    /// Returns the font name. If allocation is required, buf will be used,
    /// but sometimes allocation isn't required and a static string is
    /// returned.
    pub fn name(self: *const Face, buf: []u8) Allocator.Error![]const u8 {
        // We don't use this today but its possible the table below
        // returns UTF-16 in which case we'd want to use this for conversion.
        _ = buf;

        const count = self.face.getSfntNameCount();

        // We look for the font family entry.
        for (0..count) |i| {
            const entry = self.face.getSfntName(i) catch continue;
            if (entry.name_id == freetype.c.TT_NAME_ID_FONT_FAMILY) {
                return entry.string[0..entry.string_len];
            }
        }

        return "";
    }

    /// Return a new face that is the same as this but also has synthetic
    /// bold applied.
    pub fn syntheticBold(self: *const Face, opts: font.face.Options) !Face {
        // Increase face ref count
        self.face.ref();
        errdefer self.face.deinit();

        var f = try initFace(
            .{ .lib = self.lib },
            self.face,
            opts,
        );
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

        var f = try initFace(
            .{ .lib = self.lib },
            self.face,
            opts,
        );
        errdefer f.deinit();
        f.synthetic = self.synthetic;
        f.synthetic.italic = true;

        return f;
    }

    /// Resize the font in-place. If this succeeds, the caller is responsible
    /// for clearing any glyph caches, font atlas data, etc.
    pub fn setSize(self: *Face, opts: font.face.Options) !void {
        try setSize_(self.face, opts.size);
    }

    fn setSize_(face: freetype.Face, size: font.face.DesiredSize) !void {
        // If we have fixed sizes, we just have to try to pick the one closest
        // to what the user requested. Otherwise, we can choose an arbitrary
        // pixel size.
        if (face.isScalable()) {
            const size_26dot6: i32 = @intFromFloat(@round(size.points * 64));
            try face.setCharSize(0, size_26dot6, size.xdpi, size.ydpi);
        } else try selectSizeNearest(face, size.pixels());
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
        defer self.lib.doneMMVar(mm);

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
        // sbix table is always true for now
        if (self.face.hasSBIX()) return true;

        // CBDT/CBLC tables always imply colorized glyphs.
        // These are used by Noto.
        if (self.face.hasSfntTable(freetype.Tag.init("CBDT"))) return true;
        if (self.face.hasSfntTable(freetype.Tag.init("CBLC"))) return true;

        // Otherwise, load the glyph and see what format it is in.
        self.face.loadGlyph(glyph_id, .{
            .render = true,
            .color = self.face.hasColor(),
        }) catch return false;

        // If the glyph is SVG we assume colorized
        const glyph = self.face.handle.*.glyph;
        if (glyph.*.format == freetype.c.FT_GLYPH_FORMAT_SVG) return true;

        return false;
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
        const metrics = opts.grid_metrics;

        // If we have synthetic italic, then we apply a transformation matrix.
        // We have to undo this because synthetic italic works by increasing
        // the ref count of the base face.
        if (self.synthetic.italic) self.face.setTransform(&italic_matrix, null);
        defer if (self.synthetic.italic) self.face.setTransform(null, null);

        // If our glyph has color, we want to render the color
        try self.face.loadGlyph(glyph_index, .{
            .color = self.face.hasColor(),

            // If we have synthetic bold, we have to set some additional
            // glyph properties before render so we don't render here.
            .render = !self.synthetic.bold,

            // use options from config
            .no_hinting = !self.load_flags.hinting,
            .force_autohint = !self.load_flags.@"force-autohint",
            .monochrome = !self.load_flags.monochrome,
            .no_autohint = !self.load_flags.autohint,
        });
        const glyph = self.face.handle.*.glyph;

        // For synthetic bold, we embolden the glyph and render it.
        if (self.synthetic.bold) {
            // We need to scale the embolden amount based on the font size.
            // This is a heuristic I found worked well across a variety of
            // founts: 1 pixel per 64 units of height.
            const height: f64 = @floatFromInt(self.face.handle.*.size.*.metrics.height);
            const ratio: f64 = 64.0 / 2048.0;
            const amount = @ceil(height * ratio);
            _ = freetype.c.FT_Outline_Embolden(&glyph.*.outline, @intFromFloat(amount));
            try self.face.renderGlyph(.normal);
        }

        // This bitmap is blank. I've seen it happen in a font, I don't know why.
        // If it is empty, we just return a valid glyph struct that does nothing.
        const bitmap_ft = glyph.*.bitmap;
        if (bitmap_ft.rows == 0) return .{
            .width = 0,
            .height = 0,
            .offset_x = 0,
            .offset_y = 0,
            .atlas_x = 0,
            .atlas_y = 0,
            .advance_x = 0,
        };

        // Ensure we know how to work with the font format. And assure that
        // or color depth is as expected on the texture atlas. If format is null
        // it means there is no native color format for our Atlas and we must try
        // conversion.
        const format: ?font.Atlas.Format = switch (bitmap_ft.pixel_mode) {
            freetype.c.FT_PIXEL_MODE_MONO => null,
            freetype.c.FT_PIXEL_MODE_GRAY => .grayscale,
            freetype.c.FT_PIXEL_MODE_BGRA => .rgba,
            else => {
                log.warn("glyph={} pixel mode={}", .{ glyph_index, bitmap_ft.pixel_mode });
                @panic("unsupported pixel mode");
            },
        };

        // If our atlas format doesn't match, look for conversions if possible.
        const bitmap_converted = if (format == null or atlas.format != format.?) blk: {
            const func = convert.map[bitmap_ft.pixel_mode].get(atlas.format) orelse {
                log.warn("glyph={} pixel mode={}", .{ glyph_index, bitmap_ft.pixel_mode });
                return error.UnsupportedPixelMode;
            };

            log.debug("converting from pixel_mode={} to atlas_format={}", .{
                bitmap_ft.pixel_mode,
                atlas.format,
            });
            break :blk try func(alloc, bitmap_ft);
        } else null;
        defer if (bitmap_converted) |bm| {
            const len = @as(usize, @intCast(bm.pitch)) * @as(usize, @intCast(bm.rows));
            alloc.free(bm.buffer[0..len]);
        };

        // Now we need to see if we need to resize this bitmap. This can happen
        // in scenarios where we have fixed size glyphs. For example, emoji
        // can be quite large (i.e. 128x128) when we have a cell width of 24!
        // The issue with large bitmaps is they take a huge amount of space in
        // the atlas and force resizes quite frequently. We pay some CPU cost
        // up front to resize the glyph to avoid significant CPU cost to resize
        // and copy the atlas.
        const bitmap_original = bitmap_converted orelse bitmap_ft;
        const bitmap_resized: ?freetype.c.struct_FT_Bitmap_ = resized: {
            const original_width = bitmap_original.width;
            const original_height = bitmap_original.rows;
            var result = bitmap_original;
            // TODO: We are limiting this to only emoji. We can rework this after a future
            // improvement (promised by Qwerasd) which implements more flexible resizing rules. For
            // now, this will suffice
            if (self.isColorGlyph(glyph_index) and opts.cell_width != null) {
                const cell_width = opts.cell_width orelse unreachable;
                // If we have a cell_width, we constrain the glyph to fit within the cell
                result.width = metrics.cell_width * @as(u32, cell_width);
                result.rows = (result.width * original_height) / original_width;
            } else {
                // If we don't have a cell_width, we scale to fill vertically
                result.rows = metrics.cell_height;
                result.width = (metrics.cell_height * original_width) / original_height;
            }

            // If we already fit, we don't need to resize
            if (original_height <= result.rows and original_width <= result.width) {
                break :resized null;
            }

            result.pitch = @as(c_int, @intCast(result.width)) * atlas.format.depth();

            const buf = try alloc.alloc(
                u8,
                @as(usize, @intCast(result.pitch)) * @as(usize, @intCast(result.rows)),
            );
            result.buffer = buf.ptr;
            errdefer alloc.free(buf);

            if (stb.stbir_resize_uint8(
                bitmap_original.buffer,
                @intCast(original_width),
                @intCast(original_height),
                bitmap_original.pitch,
                result.buffer,
                @intCast(result.width),
                @intCast(result.rows),
                result.pitch,
                atlas.format.depth(),
            ) == 0) {
                // This should never fail because this is a fairly straightforward
                // in-memory operation...
                return error.GlyphResizeFailed;
            }

            break :resized result;
        };
        defer if (bitmap_resized) |bm| {
            const len = @as(usize, @intCast(bm.pitch)) * @as(usize, @intCast(bm.rows));
            alloc.free(bm.buffer[0..len]);
        };

        const bitmap = bitmap_resized orelse (bitmap_converted orelse bitmap_ft);
        const tgt_w = bitmap.width;
        const tgt_h = bitmap.rows;

        // Must have non-empty bitmap because we return earlier
        // if zero. We assume the rest of this that it is nont-zero so
        // this is important.
        assert(tgt_w > 0 and tgt_h > 0);

        // If we resized our bitmap, we need to recalculate some metrics that
        // we use such as the top/left offsets. These need to be scaled by the
        // same ratio as the resize.
        const glyph_metrics = if (bitmap_resized) |bm| metrics: {
            // Our ratio for the resize
            const ratio = ratio: {
                const new: f64 = @floatFromInt(bm.rows);
                const old: f64 = @floatFromInt(bitmap_original.rows);
                break :ratio new / old;
            };

            var copy = glyph.*;
            copy.bitmap_top = @as(c_int, @intFromFloat(@round(@as(f64, @floatFromInt(copy.bitmap_top)) * ratio)));
            copy.bitmap_left = @as(c_int, @intFromFloat(@round(@as(f64, @floatFromInt(copy.bitmap_left)) * ratio)));
            break :metrics copy;
        } else glyph.*;

        // Allocate our texture atlas region
        const region = region: {
            // We need to add a 1px padding to the font so that we don't
            // get fuzzy issues when blending textures.
            const padding = 1;

            // Get the full padded region
            var region = try atlas.reserve(
                alloc,
                tgt_w + (padding * 2), // * 2 because left+right
                tgt_h + (padding * 2), // * 2 because top+bottom
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

        // Copy the image into the region.
        assert(region.width > 0 and region.height > 0);
        {
            const depth = atlas.format.depth();

            // We can avoid a buffer copy if our atlas width and bitmap
            // width match and the bitmap pitch is just the width (meaning
            // the data is tightly packed).
            const needs_copy = !(tgt_w == bitmap.width and (bitmap.width * depth) == bitmap.pitch);

            // If we need to copy the data, we copy it into a temporary buffer.
            const buffer = if (needs_copy) buffer: {
                const temp = try alloc.alloc(u8, tgt_w * tgt_h * depth);
                var dst_ptr = temp;
                var src_ptr = bitmap.buffer;
                var i: usize = 0;
                while (i < bitmap.rows) : (i += 1) {
                    fastmem.copy(u8, dst_ptr, src_ptr[0 .. bitmap.width * depth]);
                    dst_ptr = dst_ptr[tgt_w * depth ..];
                    src_ptr += @as(usize, @intCast(bitmap.pitch));
                }
                break :buffer temp;
            } else bitmap.buffer[0..(tgt_w * tgt_h * depth)];
            defer if (buffer.ptr != bitmap.buffer) alloc.free(buffer);

            // Write the glyph information into the atlas
            assert(region.width == tgt_w);
            assert(region.height == tgt_h);
            atlas.set(region, buffer);
        }

        const offset_y: c_int = offset_y: {
            // For non-scalable colorized fonts, we assume they are pictographic
            // and just center the glyph. So far this has only applied to emoji
            // fonts. Emoji fonts don't always report a correct ascender/descender
            // (mainly Apple Emoji) so we just center them. Also, since emoji font
            // aren't scalable, cell_baseline is incorrect anyways.
            //
            // NOTE(mitchellh): I don't know if this is right, this doesn't
            // _feel_ right, but it makes all my limited test cases work.
            if (self.face.hasColor() and !self.face.isScalable()) {
                break :offset_y @intCast(tgt_h + (metrics.cell_height -| tgt_h) / 2);
            }

            // The Y offset is the offset of the top of our bitmap PLUS our
            // baseline calculation. The baseline calculation is so that everything
            // is properly centered when we render it out into a monospace grid.
            // Note: we add here because our X/Y is actually reversed, adding goes UP.
            break :offset_y glyph_metrics.bitmap_top + @as(c_int, @intCast(metrics.cell_baseline));
        };

        const offset_x: i32 = offset_x: {
            var result: i32 = glyph_metrics.bitmap_left;

            // If our cell was resized to be wider then we center our
            // glyph in the cell.
            if (metrics.original_cell_width) |original_width| {
                if (original_width < metrics.cell_width) {
                    const diff = (metrics.cell_width - original_width) / 2;
                    result += @intCast(diff);
                }
            }

            break :offset_x result;
        };

        // log.warn("renderGlyph width={} height={} offset_x={} offset_y={} glyph_metrics={}", .{
        //     tgt_w,
        //     tgt_h,
        //     glyph_metrics.bitmap_left,
        //     offset_y,
        //     glyph_metrics,
        // });

        // Store glyph metadata
        return Glyph{
            .width = tgt_w,
            .height = tgt_h,
            .offset_x = offset_x,
            .offset_y = offset_y,
            .atlas_x = region.x,
            .atlas_y = region.y,
            .advance_x = f26dot6ToFloat(glyph_metrics.advance.x),
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
        return @as(opentype.sfnt.F26Dot6, @bitCast(@as(u32, @intCast(v)))).to(f64);
    }

    pub const GetMetricsError = error{
        CopyTableError,
    };

    /// Get the `FaceMetrics` for this face.
    pub fn getMetrics(self: *Face) GetMetricsError!font.Metrics.FaceMetrics {
        const face = self.face;

        const size_metrics = face.handle.*.size.*.metrics;

        // This code relies on this assumption, and it should always be
        // true since we don't do any non-uniform scaling on the font ever.
        assert(size_metrics.x_ppem == size_metrics.y_ppem);

        // Read the 'head' table out of the font data.
        const head = face.getSfntTable(.head) orelse return error.CopyTableError;

        // Read the 'post' table out of the font data.
        const post = face.getSfntTable(.post) orelse return error.CopyTableError;

        // Read the 'OS/2' table out of the font data.
        const os2_: ?*freetype.c.TT_OS2 = os2: {
            const os2 = face.getSfntTable(.os2) orelse break :os2 null;
            if (os2.version == 0xFFFF) break :os2 null;
            break :os2 os2;
        };

        // Read the 'hhea' table out of the font data.
        const hhea = face.getSfntTable(.hhea) orelse return error.CopyTableError;

        const units_per_em = head.Units_Per_EM;
        const px_per_em: f64 = @floatFromInt(size_metrics.y_ppem);
        const px_per_unit = px_per_em / @as(f64, @floatFromInt(units_per_em));

        const ascent: f64, const descent: f64, const line_gap: f64 = vertical_metrics: {
            const hhea_ascent: f64 = @floatFromInt(hhea.Ascender);
            const hhea_descent: f64 = @floatFromInt(hhea.Descender);
            const hhea_line_gap: f64 = @floatFromInt(hhea.Line_Gap);

            if (os2_) |os2| {
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
            }

            // If our font has no OS/2 table, then we just
            // blindly use the metrics from the hhea table.
            break :vertical_metrics .{
                hhea_ascent * px_per_unit,
                hhea_descent * px_per_unit,
                hhea_line_gap * px_per_unit,
            };
        };

        // Some fonts have degenerate 'post' tables where the underline
        // thickness (and often position) are 0. We consider them null
        // if this is the case and use our own fallbacks when we calculate.
        const has_broken_underline = post.underlineThickness == 0;

        // If the underline position isn't 0 then we do use it,
        // even if the thickness is't properly specified.
        const underline_position = if (has_broken_underline and post.underlinePosition == 0)
            null
        else
            @as(f64, @floatFromInt(post.underlinePosition)) * px_per_unit;

        const underline_thickness = if (has_broken_underline)
            null
        else
            @as(f64, @floatFromInt(post.underlineThickness)) * px_per_unit;

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
        // If we fail to load any visible ASCII we just use max_advance from
        // the metrics provided by FreeType.
        const cell_width: f64 = cell_width: {
            var max: f64 = 0.0;
            var c: u8 = ' ';
            while (c < 127) : (c += 1) {
                if (face.getCharIndex(c)) |glyph_index| {
                    if (face.loadGlyph(glyph_index, .{ .render = true })) {
                        max = @max(
                            f26dot6ToF64(face.handle.*.glyph.*.advance.x),
                            max,
                        );
                    } else |_| {}
                }
            }

            // If we couldn't get any widths, just use FreeType's max_advance.
            if (max == 0.0) {
                break :cell_width f26dot6ToF64(size_metrics.max_advance);
            }

            break :cell_width max;
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
                    if (face.getCharIndex('H')) |glyph_index| {
                        if (face.loadGlyph(glyph_index, .{ .render = true })) {
                            break :cap f26dot6ToF64(face.handle.*.glyph.*.metrics.height);
                        } else |_| {}
                    }
                    break :cap null;
                },
                ex: {
                    if (face.getCharIndex('x')) |glyph_index| {
                        if (face.loadGlyph(glyph_index, .{ .render = true })) {
                            break :ex f26dot6ToF64(face.handle.*.glyph.*.metrics.height);
                        } else |_| {}
                    }
                    break :ex null;
                },
            };
        };

        return .{
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

    var lib = try Library.init();
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
            .{ .grid_metrics = font.Metrics.calc(try ft_font.getMetrics()) },
        );
    }

    // Test resizing
    {
        const g1 = try ft_font.renderGlyph(
            alloc,
            &atlas,
            ft_font.glyphIndex('A').?,
            .{ .grid_metrics = font.Metrics.calc(try ft_font.getMetrics()) },
        );
        try testing.expectEqual(@as(u32, 11), g1.height);

        try ft_font.setSize(.{ .size = .{ .points = 24, .xdpi = 96, .ydpi = 96 } });
        const g2 = try ft_font.renderGlyph(
            alloc,
            &atlas,
            ft_font.glyphIndex('A').?,
            .{ .grid_metrics = font.Metrics.calc(try ft_font.getMetrics()) },
        );
        try testing.expectEqual(@as(u32, 20), g2.height);
    }
}

test "color emoji" {
    const alloc = testing.allocator;
    const testFont = font.embedded.emoji;

    var lib = try Library.init();
    defer lib.deinit();

    var atlas = try font.Atlas.init(alloc, 512, .rgba);
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
        .{ .grid_metrics = font.Metrics.calc(try ft_font.getMetrics()) },
    );

    // Make sure this glyph has color
    {
        try testing.expect(ft_font.hasColor());
        const glyph_id = ft_font.glyphIndex('🥸').?;
        try testing.expect(ft_font.isColorGlyph(glyph_id));
    }

    // resize
    {
        const glyph = try ft_font.renderGlyph(
            alloc,
            &atlas,
            ft_font.glyphIndex('🥸').?,
            .{ .grid_metrics = .{
                .cell_width = 10,
                .cell_height = 24,
                .cell_baseline = 0,
                .underline_position = 0,
                .underline_thickness = 0,
                .strikethrough_position = 0,
                .strikethrough_thickness = 0,
                .overline_position = 0,
                .overline_thickness = 0,
                .box_thickness = 0,
                .cursor_height = 0,
            } },
        );
        try testing.expectEqual(@as(u32, 24), glyph.height);
    }
}

test "mono to rgba" {
    const alloc = testing.allocator;
    const testFont = font.embedded.emoji;

    var lib = try Library.init();
    defer lib.deinit();

    var atlas = try font.Atlas.init(alloc, 512, .rgba);
    defer atlas.deinit(alloc);

    var ft_font = try Face.init(lib, testFont, .{ .size = .{ .points = 12, .xdpi = 72, .ydpi = 72 } });
    defer ft_font.deinit();

    // glyph 3 is mono in Noto
    _ = try ft_font.renderGlyph(
        alloc,
        &atlas,
        3,
        .{ .grid_metrics = font.Metrics.calc(try ft_font.getMetrics()) },
    );
}

test "svg font table" {
    const alloc = testing.allocator;
    const testFont = font.embedded.julia_mono;

    var lib = try font.Library.init();
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

    var lib = try Library.init();
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
        .{ .grid_metrics = font.Metrics.calc(try ft_font.getMetrics()) },
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
