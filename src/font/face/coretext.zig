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

    /// Metrics for this font face. These are useful for renderers.
    metrics: font.face.Metrics,

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
    pub fn init(lib: font.Library, source: [:0]const u8, opts: font.face.Options) !Face {
        _ = lib;

        const data = try macos.foundation.Data.createWithBytesNoCopy(source);
        defer data.release();

        const arr = macos.text.createFontDescriptorsFromData(data) orelse
            return error.FontInitFailure;
        defer arr.release();
        if (arr.getCount() == 0) return error.FontInitFailure;

        const desc = arr.getValueAtIndex(macos.text.FontDescriptor, 0);
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
            @floatFromInt(opts.size.pixels()),
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
        const metrics = metrics: {
            var metrics = try calcMetrics(ct_font);
            if (opts.metric_modifiers) |v| metrics.apply(v.*);
            break :metrics metrics;
        };

        var hb_font = if (comptime harfbuzz_shaper) font: {
            var hb_font = try harfbuzz.coretext.createFont(ct_font);
            hb_font.setScale(opts.size.pixels(), opts.size.pixels());
            break :font hb_font;
        } else {};
        errdefer if (comptime harfbuzz_shaper) hb_font.destroy();

        const color: ?ColorState = if (traits.color_glyphs)
            try ColorState.init(ct_font)
        else
            null;
        errdefer if (color) |v| v.deinit();

        var result: Face = .{
            .font = ct_font,
            .hb_font = hb_font,
            .metrics = metrics,
            .color = color,
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

        // Initialize a font based on these attributes.
        const ct_font = try self.font.copyWithAttributes(0, null, desc);
        errdefer ct_font.release();
        const face = try initFont(ct_font, opts);
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
        const rect = self.font.getBoundingRectsForGlyphs(.horizontal, &glyphs, null);

        // The x/y that we render the glyph at. The Y value has to be flipped
        // because our coordinates in 3D space are (0, 0) bottom left with
        // +y being up.
        const render_x = @floor(rect.origin.x);
        const render_y = @ceil(-rect.origin.y);

        // The ascent is the amount of pixels above the baseline this glyph
        // is rendered. The ascent can be calculated by adding the full
        // glyph height to the origin.
        const glyph_ascent = @ceil(rect.size.height + rect.origin.y);

        // The glyph height is basically rect.size.height but we do the
        // ascent plus the descent because both are rounded elements that
        // will make us more accurate.
        const height: u32 = @intFromFloat(glyph_ascent + render_y);

        // The glyph width is our advertised bounding with plus the rounding
        // difference from our rendering X.
        const width: u32 = @intFromFloat(@ceil(rect.size.width + (rect.origin.x - render_x)));

        // This bitmap is blank. I've seen it happen in a font, I don't know why.
        // If it is empty, we just return a valid glyph struct that does nothing.
        if (width == 0 or height == 0) return font.Glyph{
            .width = 0,
            .height = 0,
            .offset_x = 0,
            .offset_y = 0,
            .atlas_x = 0,
            .atlas_y = 0,
            .advance_x = 0,
        };

        // Additional padding we need to add to the bitmap context itself
        // due to the glyph being larger than standard.
        const padding_ctx: u32 = padding_ctx: {
            // If we're doing thicken, then getBoundsForGlyphs does not take
            // into account the anti-aliasing that will be added to the glyph.
            // We need to add some padding to allow that to happen. A padding of
            // 2 is usually enough for anti-aliasing.
            var result: u32 = if (opts.thicken) 2 else 0;

            // If we have a synthetic bold, add padding for the stroke width
            if (self.synthetic_bold) |line_width| {
                // x2 for top and bottom padding
                result += @intFromFloat(@ceil(line_width) * 2);
            }

            break :padding_ctx result;
        };
        const padded_width: u32 = width + (padding_ctx * 2);
        const padded_height: u32 = height + (padding_ctx * 2);

        // Settings that are specific to if we are rendering text or emoji.
        const color: struct {
            color: bool,
            depth: u32,
            space: *macos.graphics.ColorSpace,
            context_opts: c_uint,
        } = if (!self.isColorGlyph(glyph_index)) .{
            .color = false,
            .depth = 1,
            .space = try macos.graphics.ColorSpace.createDeviceGray(),
            .context_opts = @intFromEnum(macos.graphics.BitmapInfo.alpha_mask) &
                @intFromEnum(macos.graphics.ImageAlphaInfo.none),
        } else .{
            .color = true,
            .depth = 4,
            .space = try macos.graphics.ColorSpace.createDeviceRGB(),
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
        const buf = try alloc.alloc(u8, padded_width * padded_height * color.depth);
        defer alloc.free(buf);
        @memset(buf, 0);

        const context = macos.graphics.BitmapContext.context;
        const ctx = try macos.graphics.BitmapContext.create(
            buf,
            padded_width,
            padded_height,
            8,
            padded_width * color.depth,
            color.space,
            color.context_opts,
        );
        defer context.release(ctx);

        // Perform an initial fill. This ensures that we don't have any
        // uninitialized pixels in the bitmap.
        if (color.color)
            context.setRGBFillColor(ctx, 1, 1, 1, 0)
        else
            context.setGrayFillColor(ctx, 0, 0);
        context.fillRect(ctx, .{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{
                .width = @floatFromInt(padded_width),
                .height = @floatFromInt(padded_height),
            },
        });

        context.setAllowsFontSmoothing(ctx, true);
        context.setShouldSmoothFonts(ctx, opts.thicken); // The amadeus "enthicken"
        context.setAllowsFontSubpixelQuantization(ctx, true);
        context.setShouldSubpixelQuantizeFonts(ctx, true);
        context.setAllowsFontSubpixelPositioning(ctx, true);
        context.setShouldSubpixelPositionFonts(ctx, true);
        context.setAllowsAntialiasing(ctx, true);
        context.setShouldAntialias(ctx, true);

        // Set our color for drawing
        if (color.color) {
            context.setRGBFillColor(ctx, 1, 1, 1, 1);
            context.setRGBStrokeColor(ctx, 1, 1, 1, 1);
        } else {
            context.setGrayFillColor(ctx, 1, 1);
            context.setGrayStrokeColor(ctx, 1, 1);
        }

        // If we are drawing with synthetic bold then use a fill stroke
        // which strokes the outlines of the glyph making a more bold look.
        if (self.synthetic_bold) |line_width| {
            context.setTextDrawingMode(ctx, .fill_stroke);
            context.setLineWidth(ctx, line_width);
        }

        // We want to render the glyphs at (0,0), but the glyphs themselves
        // are offset by bearings, so we have to undo those bearings in order
        // to get them to 0,0. We also add the padding so that they render
        // slightly off the edge of the bitmap.
        const padding_ctx_f64: f64 = @floatFromInt(padding_ctx);
        self.font.drawGlyphs(&glyphs, &.{
            .{
                .x = -1 * (render_x - padding_ctx_f64),
                .y = render_y + padding_ctx_f64,
            },
        }, ctx);

        const region = region: {
            // We need to add a 1px padding to the font so that we don't
            // get fuzzy issues when blending textures.
            const padding = 1;

            // Get the full padded region
            var region = try atlas.reserve(
                alloc,
                padded_width + (padding * 2), // * 2 because left+right
                padded_height + (padding * 2), // * 2 because top+bottom
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
        atlas.set(region, buf);

        const metrics = opts.grid_metrics orelse self.metrics;
        const offset_y: i32 = offset_y: {
            // Our Y coordinate in 3D is (0, 0) bottom left, +y is UP.
            // We need to calculate our baseline from the bottom of a cell.
            const baseline_from_bottom: f64 = @floatFromInt(metrics.cell_baseline);

            // Next we offset our baseline by the bearing in the font. We
            // ADD here because CoreText y is UP.
            const baseline_with_offset = baseline_from_bottom + glyph_ascent;

            // Add our context padding we may have created.
            const baseline_with_padding = baseline_with_offset + padding_ctx_f64;

            break :offset_y @intFromFloat(@ceil(baseline_with_padding));
        };

        const offset_x: i32 = offset_x: {
            // Don't forget to apply our context padding if we have one
            var result: i32 = @intFromFloat(render_x - padding_ctx_f64);

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

        // Get our advance
        var advances: [glyphs.len]macos.graphics.Size = undefined;
        _ = self.font.getAdvancesForGlyphs(.horizontal, &glyphs, &advances);

        // std.log.warn("renderGlyph rect={} width={} height={} render_x={} render_y={} offset_y={} ascent={} cell_height={} cell_baseline={}", .{
        //     rect,
        //     width,
        //     height,
        //     render_x,
        //     render_y,
        //     offset_y,
        //     glyph_ascent,
        //     self.metrics.cell_height,
        //     self.metrics.cell_baseline,
        // });

        return .{
            .width = padded_width,
            .height = padded_height,
            .offset_x = offset_x,
            .offset_y = offset_y,
            .atlas_x = region.x,
            .atlas_y = region.y,
            .advance_x = @floatCast(advances[0].width),
        };
    }

    fn calcMetrics(ct_font: *macos.text.Font) !font.face.Metrics {
        // Cell width is calculated by calculating the widest width of the
        // visible ASCII characters. Usually 'M' is widest but we just take
        // whatever is widest.
        const cell_width: f32 = cell_width: {
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

            break :cell_width @floatCast(@ceil(max));
        };

        // Calculate the layout metrics for height/ascent by just asking
        // the font. I also tried Kitty's approach at one point which is to
        // use the CoreText layout engine but this led to some glyphs being
        // set incorrectly.
        const layout_metrics: struct {
            height: f32,
            ascent: f32,
            leading: f32,
        } = metrics: {
            const ascent = ct_font.getAscent();
            const descent = ct_font.getDescent();

            // Leading is the value between lines at the TOP of a line.
            // Because we are rendering a fixed size terminal grid, we
            // want the leading to be split equally between the top and bottom.
            const leading = ct_font.getLeading();

            // We ceil the metrics below because we don't want to cut off any
            // potential used pixels. This tends to only make a one pixel
            // difference but at small font sizes this can be noticeable.
            break :metrics .{
                .height = @floatCast(@ceil(ascent + descent + leading)),
                .ascent = @floatCast(@ceil(ascent + (leading / 2))),
                .leading = @floatCast(leading),
            };
        };

        // All of these metrics are based on our layout above.
        const cell_height = @ceil(layout_metrics.height);
        const cell_baseline = @ceil(layout_metrics.height - layout_metrics.ascent);

        const underline_thickness = @ceil(@as(f32, @floatCast(ct_font.getUnderlineThickness())));
        const strikethrough_thickness = underline_thickness;

        const strikethrough_position = strikethrough_position: {
            // This is the height of lower case letters in our font.
            const ex_height = ct_font.getXHeight();

            // We want to position the strikethrough so that it's
            // vertically centered on any lower case text. This is
            // a fairly standard choice for strikethrough positioning.
            //
            // Because our `strikethrough_position` is relative to the
            // top of the cell we start with the ascent metric, which
            // is the distance from the top down to the baseline, then
            // we subtract half of the ex height to go back up to the
            // correct height that should evenly split lowercase text.
            const pos = layout_metrics.ascent -
                ex_height * 0.5 -
                strikethrough_thickness * 0.5;

            break :strikethrough_position @ceil(pos);
        };

        // Underline position reported is usually something like "-1" to
        // represent the amount under the baseline. We add this to our real
        // baseline to get the actual value from the bottom (+y is up).
        // The final underline position is +y from the TOP (confusing)
        // so we have to subtract from the cell height.
        const underline_position = @ceil(layout_metrics.ascent -
            @as(f32, @floatCast(ct_font.getUnderlinePosition())));

        // Note: is this useful?
        // const units_per_em = ct_font.getUnitsPerEm();
        // const units_per_point = @intToFloat(f64, units_per_em) / ct_font.getSize();

        const result = font.face.Metrics{
            .cell_width = @intFromFloat(cell_width),
            .cell_height = @intFromFloat(cell_height),
            .cell_baseline = @intFromFloat(cell_baseline),
            .underline_position = @intFromFloat(underline_position),
            .underline_thickness = @intFromFloat(underline_thickness),
            .strikethrough_position = @intFromFloat(strikethrough_position),
            .strikethrough_thickness = @intFromFloat(strikethrough_thickness),
        };

        // std.log.warn("font size size={d}", .{ct_font.getSize()});
        // std.log.warn("font metrics={}", .{result});

        return result;
    }

    /// Copy the font table data for the given tag.
    pub fn copyTable(self: Face, alloc: Allocator, tag: *const [4]u8) !?[]u8 {
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

    pub fn init(f: *macos.text.Font) !ColorState {
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
            break :svg .{
                .svg = try opentype.SVG.init(ptr[0..len]),
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
        _ = try face.renderGlyph(alloc, &atlas, face.glyphIndex(i).?, .{});
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
    try testing.expect(std.mem.eql(u8, font_name, "Menlo"));
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

    var lib = try font.Library.init();
    defer lib.deinit();

    var face = try Face.init(lib, testFont, .{ .size = .{ .points = 12 } });
    defer face.deinit();

    // Generate all visible ASCII
    var i: u8 = 32;
    while (i < 127) : (i += 1) {
        try testing.expect(face.glyphIndex(i) != null);
        _ = try face.renderGlyph(alloc, &atlas, face.glyphIndex(i).?, .{});
    }
}

test "variable" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.variable;

    var atlas = try font.Atlas.init(alloc, 512, .grayscale);
    defer atlas.deinit(alloc);

    var lib = try font.Library.init();
    defer lib.deinit();

    var face = try Face.init(lib, testFont, .{ .size = .{ .points = 12 } });
    defer face.deinit();

    // Generate all visible ASCII
    var i: u8 = 32;
    while (i < 127) : (i += 1) {
        try testing.expect(face.glyphIndex(i) != null);
        _ = try face.renderGlyph(alloc, &atlas, face.glyphIndex(i).?, .{});
    }
}

test "variable set variation" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.variable;

    var atlas = try font.Atlas.init(alloc, 512, .grayscale);
    defer atlas.deinit(alloc);

    var lib = try font.Library.init();
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
        _ = try face.renderGlyph(alloc, &atlas, face.glyphIndex(i).?, .{});
    }
}

test "svg font table" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.julia_mono;

    var lib = try font.Library.init();
    defer lib.deinit();

    var face = try Face.init(lib, testFont, .{ .size = .{ .points = 12 } });
    defer face.deinit();

    const table = (try face.copyTable(alloc, "SVG ")).?;
    defer alloc.free(table);

    try testing.expect(table.len > 0);
}

test "glyphIndex colored vs text" {
    const testing = std.testing;
    const testFont = font.embedded.julia_mono;

    var lib = try font.Library.init();
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
