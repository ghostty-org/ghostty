const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const macos = @import("macos");
const harfbuzz = @import("harfbuzz");
const font = @import("../main.zig");
const opentype = @import("../opentype.zig");
const quirks = @import("../../quirks.zig");

const log = std.log.scoped(.font_face);

pub const Face = struct {
    /// Our font face
    font: *macos.text.Font,

    /// Harfbuzz font corresponding to this face. We only use this
    /// if we're using Harfbuzz.
    hb_font: if (harfbuzz_shaper) harfbuzz.Font else void,

    /// Set quirks.disableDefaultFontFeatures
    quirks_disable_default_font_features: bool = false,

    /// True if this font face should be rasterized with a synthetic bold
    /// effect. This is used for fonts that don't have a bold variant.
    synthetic_bold: ?f64 = null,

    /// If the face can possibly be colored, then this is the state
    /// used to check for color information. This is null if the font
    /// can't possibly be colored (i.e. doesn't have SVG, sbix, etc
    /// tables).
    color: ?ColorState = null,

    /// The current size this font is set to.
    size: font.face.DesiredSize,

    /// True if our build is using Harfbuzz. If we're not, we can avoid
    /// some Harfbuzz-specific code paths.
    const harfbuzz_shaper = font.options.backend.hasHarfbuzz();

    /// The matrix applied to a regular font to auto-italicize it.
    pub const italic_skew = macos.graphics.AffineTransform{
        .a = 1,
        .b = 0,
        .c = 0.267949, // approx. tan(15)
        .d = 1,
        .tx = 0,
        .ty = 0,
    };

    /// Initialize a CoreText-based font from a TTF/TTC in memory.
    pub fn init(
        lib: font.Library,
        source: [:0]const u8,
        opts: font.face.Options,
    ) !Face {
        _ = lib;

        const data = try macos.foundation.Data.createWithBytesNoCopy(source);
        defer data.release();

        const desc = macos.text.createFontDescriptorFromData(data) orelse
            return error.FontInitFailure;
        defer desc.release();

        const ct_font = try macos.text.Font.createWithFontDescriptor(desc, 12);
        defer ct_font.release();

        return try initFontCopy(ct_font, opts);
    }

    /// Initialize a CoreText-based face from another initialized font face
    /// but with a new size. This is often how CoreText fonts are initialized
    /// because the font is loaded at a default size during discovery, and then
    /// adjusted to the final size for final load.
    pub fn initFontCopy(base: *macos.text.Font, opts: font.face.Options) !Face {
        // Create a copy. The copyWithAttributes docs say the size is in points,
        // but we need to scale the points by the DPI and to do that we use our
        // function called "pixels".
        const ct_font = try base.copyWithAttributes(
            opts.size.pixels(),
            null,
            null,
        );
        errdefer ct_font.release();

        return try initFont(ct_font, opts);
    }

    /// Initialize a face with a CTFont. This will take ownership over
    /// the CTFont. This does NOT copy or retain the CTFont.
    pub fn initFont(ct_font: *macos.text.Font, opts: font.face.Options) !Face {
        const traits = ct_font.getSymbolicTraits();

        var hb_font = if (comptime harfbuzz_shaper) font: {
            var hb_font = try harfbuzz.coretext.createFont(ct_font);
            const pixels: opentype.sfnt.F26Dot6 = .from(opts.size.pixels());
            hb_font.setScale(@bitCast(pixels), @bitCast(pixels));
            break :font hb_font;
        } else {};
        errdefer if (comptime harfbuzz_shaper) hb_font.destroy();

        const color: ?ColorState = if (traits.color_glyphs)
            try .init(ct_font)
        else
            null;
        errdefer if (color) |v| v.deinit();

        var result: Face = .{
            .font = ct_font,
            .hb_font = hb_font,
            .color = color,
            .size = opts.size,
        };
        result.quirks_disable_default_font_features = quirks.disableDefaultFontFeatures(&result);

        // In debug mode, we output information about available variation axes,
        // if they exist.
        if (comptime builtin.mode == .Debug) {
            if (ct_font.copyAttribute(.variation_axes)) |axes| {
                defer axes.release();

                var buf: [1024]u8 = undefined;
                log.debug("variation axes font={s}", .{try result.name(&buf)});

                const len = axes.getCount();
                for (0..len) |i| {
                    const dict = axes.getValueAtIndex(macos.foundation.Dictionary, i);
                    const Key = macos.text.FontVariationAxisKey;
                    const cf_name = dict.getValue(Key.name.Value(), Key.name.key()).?;
                    const cf_id = dict.getValue(Key.identifier.Value(), Key.identifier.key()).?;
                    const cf_min = dict.getValue(Key.minimum_value.Value(), Key.minimum_value.key()).?;
                    const cf_max = dict.getValue(Key.maximum_value.Value(), Key.maximum_value.key()).?;
                    const cf_def = dict.getValue(Key.default_value.Value(), Key.default_value.key()).?;

                    const namestr = cf_name.cstring(&buf, .utf8) orelse "";

                    var id_raw: c_int = 0;
                    _ = cf_id.getValue(.int, &id_raw);
                    const id: font.face.Variation.Id = @bitCast(id_raw);

                    var min: f64 = 0;
                    _ = cf_min.getValue(.double, &min);

                    var max: f64 = 0;
                    _ = cf_max.getValue(.double, &max);

                    var def: f64 = 0;
                    _ = cf_def.getValue(.double, &def);

                    log.debug("variation axis: name={s} id={s} min={} max={} def={}", .{
                        namestr,
                        id.str(),
                        min,
                        max,
                        def,
                    });
                }
            }
        }

        return result;
    }

    pub fn deinit(self: *Face) void {
        self.font.release();
        if (comptime harfbuzz_shaper) self.hb_font.destroy();
        if (self.color) |v| v.deinit();
        self.* = undefined;
    }

    /// Return a new face that is the same as this but has a transformation
    /// matrix applied to italicize it.
    pub fn syntheticItalic(self: *const Face, opts: font.face.Options) !Face {
        const ct_font = try self.font.copyWithAttributes(0.0, &italic_skew, null);
        errdefer ct_font.release();
        return try initFont(ct_font, opts);
    }

    /// Return a new face that is the same as this but applies a synthetic
    /// bold effect to it. This is useful for fonts that don't have a bold
    /// variant.
    pub fn syntheticBold(self: *const Face, opts: font.face.Options) !Face {
        const ct_font = try self.font.copyWithAttributes(0.0, null, null);
        errdefer ct_font.release();
        var face = try initFont(ct_font, opts);

        // To determine our synthetic bold line width we get a multiplier
        // from the font size in points. This is a heuristic that is based
        // on the fact that a line width of 1 looks good to me at a certain
        // point size. We want to scale that up roughly linearly with the
        // font size.
        const points_f64: f64 = @floatCast(opts.size.points);
        const line_width = @max(points_f64 / 14.0, 1);
        // log.debug("synthetic bold line width={}", .{line_width});
        face.synthetic_bold = line_width;

        return face;
    }

    /// Returns the font name. If allocation is required, buf will be used,
    /// but sometimes allocation isn't required and a static string is
    /// returned.
    pub fn name(self: *const Face, buf: []u8) Allocator.Error![]const u8 {
        const family_name = self.font.copyFamilyName();
        if (family_name.cstringPtr(.utf8)) |str| return str;

        // "NULL if the internal storage of theString does not allow
        // this to be returned efficiently." In this case, we need
        // to allocate.
        return family_name.cstring(buf, .utf8) orelse error.OutOfMemory;
    }

    /// Resize the font in-place. If this succeeds, the caller is responsible
    /// for clearing any glyph caches, font atlas data, etc.
    pub fn setSize(self: *Face, opts: font.face.Options) !void {
        // We just create a copy and replace ourself
        const face = try initFontCopy(self.font, opts);
        self.deinit();
        self.* = face;
    }

    /// Set the variation axes for this font. This will modify this font
    /// in-place.
    pub fn setVariations(
        self: *Face,
        vs: []const font.face.Variation,
        opts: font.face.Options,
    ) !void {
        // If we have no variations, we don't need to do anything.
        if (vs.len == 0) return;

        // Create a new font descriptor with all the variations set.
        var desc = self.font.copyDescriptor();
        defer desc.release();
        for (vs) |v| {
            const id = try macos.foundation.Number.create(.int, @ptrCast(&v.id));
            defer id.release();
            const next = try desc.createCopyWithVariation(id, v.value);
            desc.release();
            desc = next;
        }

        // Put our current size in the opts so that we don't change size.
        var new_opts = opts;
        new_opts.size = self.size;

        // Initialize a font based on these attributes.
        const ct_font = try self.font.copyWithAttributes(0, null, desc);
        errdefer ct_font.release();
        const face = try initFont(ct_font, new_opts);
        self.deinit();
        self.* = face;
    }

    /// Returns true if the face has any glyphs that are colorized.
    /// To determine if an individual glyph is colorized you must use
    /// isColorGlyph.
    pub fn hasColor(self: *const Face) bool {
        return self.color != null;
    }

    /// Returns true if the given glyph ID is colorized.
    pub fn isColorGlyph(self: *const Face, glyph_id: u32) bool {
        const c = self.color orelse return false;
        return c.isColorGlyph(glyph_id);
    }

    /// Returns the glyph index for the given Unicode code point. If this
    /// face doesn't support this glyph, null is returned.
    pub fn glyphIndex(self: Face, cp: u32) ?u32 {
        // Turn UTF-32 into UTF-16 for CT API
        var unichars: [2]u16 = undefined;
        const pair = macos.foundation.stringGetSurrogatePairForLongCharacter(cp, &unichars);
        const len: usize = if (pair) 2 else 1;

        // Get our glyphs
        var glyphs = [2]macos.graphics.Glyph{ 0, 0 };
        if (!self.font.getGlyphsForCharacters(unichars[0..len], glyphs[0..len]))
            return null;

        // We can have pairs due to chars like emoji but we expect all of them
        // to decode down into exactly one glyph ID.
        if (pair) assert(glyphs[1] == 0);

        return @intCast(glyphs[0]);
    }

    pub fn renderGlyph(
        self: Face,
        alloc: Allocator,
        atlas: *font.Atlas,
        glyph_index: u32,
        opts: font.face.RenderOptions,
    ) !font.Glyph {
        var glyphs = [_]macos.graphics.Glyph{@intCast(glyph_index)};

        // Get the bounding rect for rendering this glyph.
        // This is in a coordinate space with (0.0, 0.0)
        // in the bottom left and +Y pointing up.
        var rect = self.font.getBoundingRectsForGlyphs(.horizontal, &glyphs, null);

        // Determine whether this is a color glyph.
        const is_color = self.isColorGlyph(glyph_index);
        // And whether it's (probably) a bitmap (sbix).
        const sbix = is_color and self.color != null and self.color.?.sbix;

        // If we're rendering a synthetic bold then we will gain 50% of
        // the line width on every edge, which means we should increase
        // our width and height by the line width and subtract half from
        // our origin points.
        //
        // We don't add extra size if it's a sbix color font though,
        // since bitmaps aren't affected by synthetic bold.
        if (!sbix) if (self.synthetic_bold) |line_width| {
            rect.size.width += line_width;
            rect.size.height += line_width;
            rect.origin.x -= line_width / 2;
            rect.origin.y -= line_width / 2;
        };

        // If our rect is smaller than a quarter pixel in either axis
        // then it has no outlines or they're too small to render.
        //
        // In this case we just return 0-sized glyph struct.
        if (rect.size.width < 0.25 or rect.size.height < 0.25)
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
                .width = rect.size.width,
                .height = rect.size.height,
                .x = rect.origin.x,
                .y = rect.origin.y + cell_baseline,
            },
            metrics,
            opts.constraint_width,
        );

        var x = glyph_size.x;
        var y = glyph_size.y;
        var width = glyph_size.width;
        var height = glyph_size.height;

        // We center all glyphs within the pixel-rounded and adjusted
        // cell width if it's larger than the face width, so that they
        // aren't weirdly off to the left.
        //
        // We don't do this if the glyph has a stretch constraint,
        // since in that case the position was already calculated with the
        // new cell width in mind.
        if ((constraint.size != .stretch) and (metrics.face_width < cell_width)) {
            // We add half the difference to re-center.
            x += (cell_width - metrics.face_width) / 2;
        }

        // If this is a bitmap glyph, it will always render as full pixels,
        // not fractional pixels, so we need to quantize its position and
        // size accordingly to align to full pixels so we get good results.
        if (sbix) {
            width = cell_width - @round(cell_width - width - x) - @round(x);
            height = cell_height - @round(cell_height - height - y) - @round(y);
            x = @round(x);
            y = @round(y);
        }

        // We make an assumption that font smoothing ("thicken")
        // adds no more than 1 extra pixel to any edge. We don't
        // add extra size if it's a sbix color font though, since
        // bitmaps aren't affected by smoothing.
        const canvas_padding: u32 = if (opts.thicken and !sbix) 1 else 0;

        // Our whole-pixel bearings for the final glyph.
        // The fractional portion will be included in the rasterized position.
        const px_x = @as(i32, @intFromFloat(@floor(x))) - @as(i32, @intCast(canvas_padding));
        const px_y = @as(i32, @intFromFloat(@floor(y))) - @as(i32, @intCast(canvas_padding));

        // We keep track of the fractional part of the pixel bearings, which
        // we will add as an offset when rasterizing to make sure we get the
        // correct sub-pixel position.
        const frac_x = x - @floor(x);
        const frac_y = y - @floor(y);

        // Add the fractional pixel to the width and height and take
        // the ceiling to get a canvas size that will definitely fit
        // our drawn glyph, including the fractional offset and font smoothing.
        const px_width = @as(u32, @intFromFloat(@ceil(width + frac_x))) + (2 * canvas_padding);
        const px_height = @as(u32, @intFromFloat(@ceil(height + frac_y))) + (2 * canvas_padding);

        // Settings that are specific to if we are rendering text or emoji.
        const color: struct {
            color: bool,
            depth: u32,
            space: *macos.graphics.ColorSpace,
            context_opts: c_uint,
        } = if (!is_color) .{
            .color = false,
            .depth = 1,
            .space = try macos.graphics.ColorSpace.createNamed(.linearGray),
            .context_opts = @intFromEnum(macos.graphics.ImageAlphaInfo.only),
        } else .{
            .color = true,
            .depth = 4,
            .space = try macos.graphics.ColorSpace.createNamed(.displayP3),
            .context_opts = @intFromEnum(macos.graphics.BitmapInfo.byte_order_32_little) |
                @intFromEnum(macos.graphics.ImageAlphaInfo.premultiplied_first),
        };
        defer color.space.release();

        // This is just a safety check.
        if (atlas.format.depth() != color.depth) {
            log.warn("font atlas color depth doesn't equal font color depth atlas={} font={}", .{
                atlas.format.depth(),
                color.depth,
            });
            return error.InvalidAtlasFormat;
        }

        // Our buffer for rendering. We could cache this but glyph rasterization
        // usually stabilizes pretty quickly and is very infrequent so I think
        // the allocation overhead is acceptable compared to the cost of
        // caching it forever or having to deal with a cache lifetime.
        const buf = try alloc.alloc(u8, px_width * px_height * color.depth);
        defer alloc.free(buf);
        @memset(buf, 0);

        const context = macos.graphics.BitmapContext.context;
        const ctx = try macos.graphics.BitmapContext.create(
            buf,
            px_width,
            px_height,
            8,
            px_width * color.depth,
            color.space,
            color.context_opts,
        );
        defer context.release(ctx);

        // Perform an initial fill. This ensures that we don't have any
        // uninitialized pixels in the bitmap.
        if (color.color)
            context.setRGBFillColor(ctx, 0, 0, 0, 0)
        else
            context.setGrayFillColor(ctx, 0, 0);
        context.fillRect(ctx, .{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{
                .width = @floatFromInt(px_width),
                .height = @floatFromInt(px_height),
            },
        });

        // "Font smoothing" is what we call "thickening", it's an attempt
        // to compensate for optical thinning of fonts, but at this point
        // it's just something that makes the text look closer to system
        // applications if users want that.
        context.setAllowsFontSmoothing(ctx, true);
        context.setShouldSmoothFonts(ctx, opts.thicken);

        // Subpixel positioning allows glyphs to be placed at non-integer
        // coordinates. We need this for our alignment.
        context.setAllowsFontSubpixelPositioning(ctx, true);
        context.setShouldSubpixelPositionFonts(ctx, true);

        // We don't want subpixel quantization, since we very carefully
        // manage the position of our glyphs ourselves, and dont want to
        // mess that up.
        context.setAllowsFontSubpixelQuantization(ctx, false);
        context.setShouldSubpixelQuantizeFonts(ctx, false);

        // Anti-aliasing is self explanatory.
        context.setAllowsAntialiasing(ctx, true);
        context.setShouldAntialias(ctx, true);

        // Set our color for drawing
        if (color.color) {
            context.setRGBFillColor(ctx, 1, 1, 1, 1);
            context.setRGBStrokeColor(ctx, 1, 1, 1, 1);
        } else {
            const strength: f64 = @floatFromInt(opts.thicken_strength);
            context.setGrayFillColor(ctx, strength / 255.0, 1);
            context.setGrayStrokeColor(ctx, strength / 255.0, 1);
        }

        // If we are drawing with synthetic bold then use a fill stroke
        // which strokes the outlines of the glyph making a more bold look.
        if (self.synthetic_bold) |line_width| {
            context.setTextDrawingMode(ctx, .fill_stroke);
            context.setLineWidth(ctx, line_width);
        }

        // Translate our drawing context so that when we draw our
        // glyph the bottom/left edge is at the correct sub-pixel
        // position. The bottom/left edges are guaranteed to be at
        // exactly [0, 0] relative to this because when we call to
        // `drawGlyphs`, we pass the negated bearings.
        context.translateCTM(
            ctx,
            frac_x + @as(f64, @floatFromInt(canvas_padding)),
            frac_y + @as(f64, @floatFromInt(canvas_padding)),
        );

        // Scale the drawing context so that when we draw
        // our glyph it's stretched to the constrained size.
        context.scaleCTM(
            ctx,
            width / rect.size.width,
            height / rect.size.height,
        );

        // Draw our glyph.
        //
        // We offset the position by the negated bearings so that the
        // glyph is drawn at exactly [0, 0], which is then offset to
        // the appropriate fractional position by the translation we
        // did before scaling.
        self.font.drawGlyphs(&glyphs, &.{.{
            .x = -rect.origin.x,
            .y = -rect.origin.y,
        }}, ctx);

        // Write our rasterized glyph to the atlas.
        const region = try atlas.reserve(alloc, px_width, px_height);
        atlas.set(region, buf);

        // This should be the distance from the bottom of
        // the cell to the top of the glyph's bounding box.
        const offset_y: i32 = px_y + @as(i32, @intCast(px_height));

        // This should be the distance from the left of
        // the cell to the left of the glyph's bounding box.
        const offset_x: i32 = px_x;

        return .{
            .width = px_width,
            .height = px_height,
            .offset_x = offset_x,
            .offset_y = offset_y,
            .atlas_x = region.x,
            .atlas_y = region.y,
        };
    }

    /// Get the `FaceMetrics` for this face.
    pub fn getMetrics(self: *Face) font.Metrics.FaceMetrics {
        const ct_font = self.font;

        // Read the 'head' table out of the font data.
        const head_: ?opentype.Head = head: {
            // macOS bitmap-only fonts use a 'bhed' tag rather than 'head', but
            // the table format is byte-identical to the 'head' table, so if we
            // can't find 'head' we try 'bhed' instead before failing.
            //
            // ref: https://fontforge.org/docs/techref/bitmaponlysfnt.html
            const head_tag = macos.text.FontTableTag.init("head");
            const bhed_tag = macos.text.FontTableTag.init("bhed");
            const data =
                ct_font.copyTable(head_tag) orelse
                ct_font.copyTable(bhed_tag) orelse
                break :head null;
            defer data.release();
            const ptr = data.getPointer();
            const len = data.getLength();
            break :head opentype.Head.init(ptr[0..len]) catch |err| {
                log.warn("error parsing head table: {}", .{err});
                break :head null;
            };
        };

        // Read the 'post' table out of the font data.
        const post_: ?opentype.Post = post: {
            const tag = macos.text.FontTableTag.init("post");
            const data = ct_font.copyTable(tag) orelse break :post null;
            defer data.release();
            const ptr = data.getPointer();
            const len = data.getLength();
            break :post opentype.Post.init(ptr[0..len]) catch |err| {
                log.warn("error parsing post table: {}", .{err});
                break :post null;
            };
        };

        // Read the 'OS/2' table out of the font data if it's available.
        const os2_: ?opentype.OS2 = os2: {
            const tag = macos.text.FontTableTag.init("OS/2");
            const data = ct_font.copyTable(tag) orelse break :os2 null;
            defer data.release();
            const ptr = data.getPointer();
            const len = data.getLength();
            break :os2 opentype.OS2.init(ptr[0..len]) catch |err| {
                log.warn("error parsing OS/2 table: {}", .{err});
                break :os2 null;
            };
        };

        // Read the 'hhea' table out of the font data.
        const hhea_: ?opentype.Hhea = hhea: {
            const tag = macos.text.FontTableTag.init("hhea");
            const data = ct_font.copyTable(tag) orelse break :hhea null;
            defer data.release();
            const ptr = data.getPointer();
            const len = data.getLength();
            break :hhea opentype.Hhea.init(ptr[0..len]) catch |err| {
                log.warn("error parsing hhea table: {}", .{err});
                break :hhea null;
            };
        };

        const units_per_em: f64 =
            if (head_) |head|
                @floatFromInt(head.unitsPerEm)
            else
                @floatFromInt(self.font.getUnitsPerEm());
        const px_per_em: f64 = ct_font.getSize();
        const px_per_unit: f64 = px_per_em / units_per_em;

        const ascent: f64, const descent: f64, const line_gap: f64 = vertical_metrics: {
            // If we couldn't get the hhea table, rely on metrics from CoreText.
            const hhea = hhea_ orelse break :vertical_metrics .{
                self.font.getAscent(),
                -self.font.getDescent(),
                self.font.getLeading(),
            };

            const hhea_ascent: f64 = @floatFromInt(hhea.ascender);
            const hhea_descent: f64 = @floatFromInt(hhea.descender);
            const hhea_line_gap: f64 = @floatFromInt(hhea.lineGap);

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
            if (os2.fsSelection.use_typo_metrics) break :vertical_metrics .{
                os2_ascent * px_per_unit,
                os2_descent * px_per_unit,
                os2_line_gap * px_per_unit,
            };

            // Otherwise we prefer the height metrics from 'hhea' if they
            // are available, or else OS/2 sTypo* metrics, and if all else
            // fails then we use OS/2 usWin* metrics.
            //
            // This is not "standard" behavior, but it's our best bet to
            // account for fonts being... just weird. It's pretty much what
            // FreeType does to get its generic ascent and descent metrics.

            if (hhea.ascender != 0 or hhea.descender != 0) break :vertical_metrics .{
                hhea_ascent * px_per_unit,
                hhea_descent * px_per_unit,
                hhea_line_gap * px_per_unit,
            };

            if (os2_ascent != 0 or os2_descent != 0) break :vertical_metrics .{
                os2_ascent * px_per_unit,
                os2_descent * px_per_unit,
                os2_line_gap * px_per_unit,
            };

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

        const underline_position, const underline_thickness = ul: {
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

        // We fall back to whatever CoreText does if the
        // OS/2 table doesn't specify a cap or ex height.
        const cap_height: f64, const ex_height: f64 = heights: {
            const os2 = os2_ orelse break :heights .{
                ct_font.getCapHeight(),
                ct_font.getXHeight(),
            };

            break :heights .{
                if (os2.sCapHeight) |sCapHeight|
                    @as(f64, @floatFromInt(sCapHeight)) * px_per_unit
                else
                    ct_font.getCapHeight(),

                if (os2.sxHeight) |sxHeight|
                    @as(f64, @floatFromInt(sxHeight)) * px_per_unit
                else
                    ct_font.getXHeight(),
            };
        };

        // Cell width is calculated by calculating the widest width of the
        // visible ASCII characters. Usually 'M' is widest but we just take
        // whatever is widest.
        //
        // ASCII height is calculated as the height of the overall bounding
        // box of the same characters.
        const cell_width: f64, const ascii_height: f64 = measurements: {
            // Build a comptime array of all the ASCII chars
            const unichars = comptime unichars: {
                const len = 127 - 32;
                var result: [len]u16 = undefined;
                var i: u16 = 32;
                while (i < 127) : (i += 1) {
                    result[i - 32] = i;
                }

                break :unichars result;
            };

            // Get our glyph IDs for the ASCII chars
            var glyphs: [unichars.len]macos.graphics.Glyph = undefined;
            _ = ct_font.getGlyphsForCharacters(&unichars, &glyphs);

            // Get all our advances
            var advances: [unichars.len]macos.graphics.Size = undefined;
            _ = ct_font.getAdvancesForGlyphs(.horizontal, &glyphs, &advances);

            // Find the maximum advance
            var max: f64 = 0;
            var i: usize = 0;
            while (i < advances.len) : (i += 1) {
                max = @max(advances[i].width, max);
            }

            // Get the overall bounding rect for the glyphs
            const rect = ct_font.getBoundingRectsForGlyphs(.horizontal, &glyphs, null);

            break :measurements .{ max, rect.size.height };
        };

        // Measure "水" (CJK water ideograph, U+6C34) for our ic width.
        const ic_width: ?f64 = ic_width: {
            const glyph = self.glyphIndex('水') orelse break :ic_width null;

            const advance = ct_font.getAdvancesForGlyphs(
                .horizontal,
                &.{@intCast(glyph)},
                null,
            );

            const bounds = ct_font.getBoundingRectsForGlyphs(
                .horizontal,
                &.{@intCast(glyph)},
                null,
            );

            // If the advance of the glyph is less than the width of the actual
            // glyph then we just treat it as invalid since it's probably wrong
            // and using it for size normalization will instead make the font
            // way too big.
            //
            // This can sometimes happen if there's a CJK font that has been
            // patched with the nerd fonts patcher and it butchers the advance
            // values so the advance ends up half the width of the actual glyph.
            if (bounds.size.width > advance) {
                var buf: [1024]u8 = undefined;
                const font_name = self.name(&buf) catch "<Error getting font name>";
                log.warn(
                    "(getMetrics) Width of glyph '水' for font \"{s}\" is greater than its advance ({d} > {d}), discarding ic_width metric.",
                    .{
                        font_name,
                        bounds.size.width,
                        advance,
                    },
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
    pub fn copyTable(
        self: Face,
        alloc: Allocator,
        tag: *const [4]u8,
    ) Allocator.Error!?[]u8 {
        const data = self.font.copyTable(macos.text.FontTableTag.init(tag)) orelse
            return null;
        defer data.release();

        const buf = try alloc.alloc(u8, data.getLength());
        errdefer alloc.free(buf);

        const ptr = data.getPointer();
        @memcpy(buf, ptr[0..buf.len]);

        return buf;
    }
};

/// The state associated with a font face that may have colorized glyphs.
/// This is used to determine if a specific glyph ID is colorized.
const ColorState = struct {
    /// True if there is an sbix font table. For now, the mere presence
    /// of an sbix font table causes us to assume the glyph is colored.
    /// We can improve this later.
    sbix: bool,

    /// The SVG font table data (if any), which we can use to determine
    /// if a glyph is present in the SVG table.
    svg: ?opentype.SVG,
    svg_data: ?*macos.foundation.Data,

    pub const Error = error{InvalidSVGTable};

    pub fn init(f: *macos.text.Font) Error!ColorState {
        // sbix is true if the table exists in the font data at all.
        // In the future we probably want to actually parse it and
        // check for glyphs.
        const sbix: bool = sbix: {
            const tag = macos.text.FontTableTag.init("sbix");
            const data = f.copyTable(tag) orelse break :sbix false;
            data.release();
            break :sbix data.getLength() > 0;
        };

        // Read the SVG table out of the font data.
        const svg: ?struct {
            svg: opentype.SVG,
            data: *macos.foundation.Data,
        } = svg: {
            const tag = macos.text.FontTableTag.init("SVG ");
            const data = f.copyTable(tag) orelse break :svg null;
            errdefer data.release();
            const ptr = data.getPointer();
            const len = data.getLength();
            const svg = opentype.SVG.init(ptr[0..len]) catch |err| {
                return switch (err) {
                    error.EndOfStream,
                    error.SVGVersionNotSupported,
                    => error.InvalidSVGTable,
                };
            };

            break :svg .{
                .svg = svg,
                .data = data,
            };
        };

        return .{
            .sbix = sbix,
            .svg = if (svg) |v| v.svg else null,
            .svg_data = if (svg) |v| v.data else null,
        };
    }

    pub fn deinit(self: *const ColorState) void {
        if (self.svg_data) |v| v.release();
    }

    /// Returns true if the given glyph ID is colored.
    pub fn isColorGlyph(self: *const ColorState, glyph_id: u32) bool {
        // Our font system uses 32-bit glyph IDs for special values but
        // actual fonts only contain 16-bit glyph IDs so if we can't cast
        // into it it must be false.
        const glyph_u16 = std.math.cast(u16, glyph_id) orelse return false;

        // sbix is always true for now
        if (self.sbix) return true;

        // if we have svg data, check it
        if (self.svg) |svg| {
            if (svg.hasGlyph(glyph_u16)) return true;
        }

        return false;
    }
};

test {
    const testing = std.testing;
    const alloc = testing.allocator;

    var atlas = try font.Atlas.init(alloc, 512, .grayscale);
    defer atlas.deinit(alloc);

    const name = try macos.foundation.String.createWithBytes("Monaco", .utf8, false);
    defer name.release();
    const desc = try macos.text.FontDescriptor.createWithNameAndSize(name, 12);
    defer desc.release();
    const ct_font = try macos.text.Font.createWithFontDescriptor(desc, 12);
    defer ct_font.release();

    var face = try Face.initFontCopy(ct_font, .{ .size = .{ .points = 12 } });
    defer face.deinit();

    // Generate all visible ASCII
    var i: u8 = 32;
    while (i < 127) : (i += 1) {
        try testing.expect(face.glyphIndex(i) != null);
        _ = try face.renderGlyph(
            alloc,
            &atlas,
            face.glyphIndex(i).?,
            .{ .grid_metrics = font.Metrics.calc(face.getMetrics()) },
        );
    }
}

test "name" {
    const testing = std.testing;

    const name = try macos.foundation.String.createWithBytes("Menlo", .utf8, false);
    defer name.release();
    const desc = try macos.text.FontDescriptor.createWithNameAndSize(name, 12);
    defer desc.release();
    const ct_font = try macos.text.Font.createWithFontDescriptor(desc, 12);
    defer ct_font.release();

    var face = try Face.initFontCopy(ct_font, .{ .size = .{ .points = 12 } });
    defer face.deinit();

    var buf: [1024]u8 = undefined;
    const font_name = try face.name(&buf);
    try testing.expectEqualStrings(font_name, "Menlo");
}

test "emoji" {
    const testing = std.testing;

    const name = try macos.foundation.String.createWithBytes("Apple Color Emoji", .utf8, false);
    defer name.release();
    const desc = try macos.text.FontDescriptor.createWithNameAndSize(name, 12);
    defer desc.release();
    const ct_font = try macos.text.Font.createWithFontDescriptor(desc, 12);
    defer ct_font.release();

    var face = try Face.initFontCopy(ct_font, .{ .size = .{ .points = 18 } });
    defer face.deinit();

    // Glyph index check
    {
        const id = face.glyphIndex('🥸').?;
        try testing.expect(face.isColorGlyph(id));
    }
}

test "in-memory" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.regular;

    var atlas = try font.Atlas.init(alloc, 512, .grayscale);
    defer atlas.deinit(alloc);

    var lib = try font.Library.init(alloc);
    defer lib.deinit();

    var face = try Face.init(lib, testFont, .{ .size = .{ .points = 12 } });
    defer face.deinit();

    // Generate all visible ASCII
    var i: u8 = 32;
    while (i < 127) : (i += 1) {
        try testing.expect(face.glyphIndex(i) != null);
        _ = try face.renderGlyph(
            alloc,
            &atlas,
            face.glyphIndex(i).?,
            .{ .grid_metrics = font.Metrics.calc(face.getMetrics()) },
        );
    }
}

test "variable" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.variable;

    var atlas = try font.Atlas.init(alloc, 512, .grayscale);
    defer atlas.deinit(alloc);

    var lib = try font.Library.init(alloc);
    defer lib.deinit();

    var face = try Face.init(lib, testFont, .{ .size = .{ .points = 12 } });
    defer face.deinit();

    // Generate all visible ASCII
    var i: u8 = 32;
    while (i < 127) : (i += 1) {
        try testing.expect(face.glyphIndex(i) != null);
        _ = try face.renderGlyph(
            alloc,
            &atlas,
            face.glyphIndex(i).?,
            .{ .grid_metrics = font.Metrics.calc(face.getMetrics()) },
        );
    }
}

test "variable set variation" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.variable;

    var atlas = try font.Atlas.init(alloc, 512, .grayscale);
    defer atlas.deinit(alloc);

    var lib = try font.Library.init(alloc);
    defer lib.deinit();

    var face = try Face.init(lib, testFont, .{ .size = .{ .points = 12 } });
    defer face.deinit();

    try face.setVariations(&.{
        .{ .id = font.face.Variation.Id.init("wght"), .value = 400 },
    }, .{ .size = .{ .points = 12 } });

    // Generate all visible ASCII
    var i: u8 = 32;
    while (i < 127) : (i += 1) {
        try testing.expect(face.glyphIndex(i) != null);
        _ = try face.renderGlyph(
            alloc,
            &atlas,
            face.glyphIndex(i).?,
            .{ .grid_metrics = font.Metrics.calc(face.getMetrics()) },
        );
    }
}

test "svg font table" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.julia_mono;

    var lib = try font.Library.init(alloc);
    defer lib.deinit();

    var face = try Face.init(lib, testFont, .{ .size = .{ .points = 12 } });
    defer face.deinit();

    const table = (try face.copyTable(alloc, "SVG ")).?;
    defer alloc.free(table);

    try testing.expect(table.len > 0);
}

test "glyphIndex colored vs text" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.julia_mono;

    var lib = try font.Library.init(alloc);
    defer lib.deinit();

    var face = try Face.init(lib, testFont, .{ .size = .{ .points = 12 } });
    defer face.deinit();

    {
        const glyph = face.glyphIndex('A').?;
        try testing.expectEqual(4, glyph);
        try testing.expect(!face.isColorGlyph(glyph));
    }

    {
        const glyph = face.glyphIndex(0xE800).?;
        try testing.expectEqual(11482, glyph);
        try testing.expect(face.isColorGlyph(glyph));
    }
}
