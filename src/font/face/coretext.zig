const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const macos = @import("macos");
const harfbuzz = @import("harfbuzz");
const font = @import("../main.zig");

const log = std.log.scoped(.font_face);

pub const Face = struct {
    /// Our font face
    font: *macos.text.Font,

    /// Harfbuzz font corresponding to this face.
    hb_font: harfbuzz.Font,

    /// The presentation for this font.
    presentation: font.Presentation,

    /// Metrics for this font face. These are useful for renderers.
    metrics: font.face.Metrics,

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
    pub fn init(lib: font.Library, source: [:0]const u8, size: font.face.DesiredSize) !Face {
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

        return try initFontCopy(ct_font, size);
    }

    /// Initialize a CoreText-based face from another initialized font face
    /// but with a new size. This is often how CoreText fonts are initialized
    /// because the font is loaded at a default size during discovery, and then
    /// adjusted to the final size for final load.
    pub fn initFontCopy(base: *macos.text.Font, size: font.face.DesiredSize) !Face {
        // Create a copy. The copyWithAttributes docs say the size is in points,
        // but we need to scale the points by the DPI and to do that we use our
        // function called "pixels".
        const ct_font = try base.copyWithAttributes(@floatFromInt(size.pixels()), null, null);
        errdefer ct_font.release();

        var hb_font = try harfbuzz.coretext.createFont(ct_font);
        errdefer hb_font.destroy();

        const traits = ct_font.getSymbolicTraits();

        return Face{
            .font = ct_font,
            .hb_font = hb_font,
            .presentation = if (traits.color_glyphs) .emoji else .text,
            .metrics = try calcMetrics(ct_font),
        };
    }

    pub fn deinit(self: *Face) void {
        self.font.release();
        self.hb_font.destroy();
        self.* = undefined;
    }

    /// Return a new face that is the same as this but has a transformation
    /// matrix applied to italicize it.
    pub fn italicize(self: *const Face) !Face {
        const ct_font = try self.font.copyWithAttributes(0.0, &italic_skew, null);
        defer ct_font.release();
        return try initFontCopy(ct_font, .{ .points = 0 });
    }

    /// Returns the font name. If allocation is required, buf will be used,
    /// but sometimes allocation isn't required and a static string is
    /// returned.
    pub fn name(self: *const Face, buf: []u8) Allocator.Error![]const u8 {
        const display_name = self.font.copyDisplayName();
        if (display_name.cstringPtr(.utf8)) |str| return str;

        // "NULL if the internal storage of theString does not allow
        // this to be returned efficiently." In this case, we need
        // to allocate.
        return display_name.cstring(buf, .utf8) orelse error.OutOfMemory;
    }

    /// Resize the font in-place. If this succeeds, the caller is responsible
    /// for clearing any glyph caches, font atlas data, etc.
    pub fn setSize(self: *Face, size: font.face.DesiredSize) !void {
        // We just create a copy and replace ourself
        const face = try initFontCopy(self.font, size);
        self.deinit();
        self.* = face;
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
        const rect = self.font.getBoundingRectForGlyphs(.horizontal, &glyphs, null);

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

        // Settings that are specific to if we are rendering text or emoji.
        const color: struct {
            color: bool,
            depth: u32,
            space: *macos.graphics.ColorSpace,
            context_opts: c_uint,
        } = if (self.presentation == .text) .{
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
        var buf = try alloc.alloc(u8, width * height * color.depth);
        defer alloc.free(buf);
        @memset(buf, 0);

        const ctx = try macos.graphics.BitmapContext.create(
            buf,
            width,
            height,
            8,
            width * color.depth,
            color.space,
            color.context_opts,
        );
        defer ctx.release();

        // Perform an initial fill. This ensures that we don't have any
        // uninitialized pixels in the bitmap.
        if (color.color)
            ctx.setRGBFillColor(1, 1, 1, 0)
        else
            ctx.setGrayFillColor(0, 0);
        ctx.fillRect(.{
            .origin = .{ .x = 0, .y = 0 },
            .size = .{
                .width = @floatFromInt(width),
                .height = @floatFromInt(height),
            },
        });

        ctx.setAllowsFontSmoothing(true);
        ctx.setShouldSmoothFonts(opts.thicken); // The amadeus "enthicken"
        ctx.setAllowsFontSubpixelQuantization(true);
        ctx.setShouldSubpixelQuantizeFonts(true);
        ctx.setAllowsFontSubpixelPositioning(true);
        ctx.setShouldSubpixelPositionFonts(true);
        ctx.setAllowsAntialiasing(true);
        ctx.setShouldAntialias(true);

        // Set our color for drawing
        if (color.color) {
            ctx.setRGBFillColor(1, 1, 1, 1);
            ctx.setRGBStrokeColor(1, 1, 1, 1);
        } else {
            ctx.setGrayFillColor(1, 1);
            ctx.setGrayStrokeColor(1, 1);
        }

        // We want to render the glyphs at (0,0), but the glyphs themselves
        // are offset by bearings, so we have to undo those bearings in order
        // to get them to 0,0. We also add the padding so that they render
        // slightly off the edge of the bitmap.
        self.font.drawGlyphs(&glyphs, &.{
            .{
                .x = -1 * render_x,
                .y = render_y,
            },
        }, ctx);

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
        atlas.set(region, buf);

        const offset_y: i32 = offset_y: {
            // Our Y coordinate in 3D is (0, 0) bottom left, +y is UP.
            // We need to calculate our baseline from the bottom of a cell.
            const baseline_from_bottom: f64 = @floatFromInt(self.metrics.cell_baseline);

            // Next we offset our baseline by the bearing in the font. We
            // ADD here because CoreText y is UP.
            const baseline_with_offset = baseline_from_bottom + glyph_ascent;

            break :offset_y @intFromFloat(@ceil(baseline_with_offset));
        };

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
            .width = width,
            .height = height,
            .offset_x = @intFromFloat(render_x),
            .offset_y = offset_y,
            .atlas_x = region.x,
            .atlas_y = region.y,

            // This is not used, so we don't bother calculating it. If we
            // ever need it, we can calculate it using getAdvancesForGlyph.
            .advance_x = 0,
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
        } = metrics: {
            const ascent = @round(ct_font.getAscent());
            const descent = @round(ct_font.getDescent());
            const leading = @round(ct_font.getLeading());
            break :metrics .{
                .height = @floatCast(ascent + descent + leading),
                .ascent = @floatCast(ascent),
            };
        };

        // All of these metrics are based on our layout above.
        const cell_height = @ceil(layout_metrics.height);
        const cell_baseline = @ceil(layout_metrics.height - layout_metrics.ascent);
        const underline_thickness = @ceil(@as(f32, @floatCast(ct_font.getUnderlineThickness())));
        const strikethrough_position = @ceil(layout_metrics.height - (layout_metrics.ascent * 0.6));
        const strikethrough_thickness = underline_thickness;

        // Underline position reported is usually something like "-1" to
        // represent the amount under the baseline. We add this to our real
        // baseline to get the actual value from the bottom (+y is up).
        // The final underline position is +y from the TOP (confusing)
        // so we have to subtract from the cell height.
        const underline_position = cell_height -
            (cell_baseline + @ceil(@as(f32, @floatCast(ct_font.getUnderlinePosition())))) +
            1;

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
};

test {
    const testing = std.testing;
    const alloc = testing.allocator;

    var atlas = try font.Atlas.init(alloc, 512, .greyscale);
    defer atlas.deinit(alloc);

    const name = try macos.foundation.String.createWithBytes("Monaco", .utf8, false);
    defer name.release();
    const desc = try macos.text.FontDescriptor.createWithNameAndSize(name, 12);
    defer desc.release();
    const ct_font = try macos.text.Font.createWithFontDescriptor(desc, 12);
    defer ct_font.release();

    var face = try Face.initFontCopy(ct_font, .{ .points = 12 });
    defer face.deinit();

    try testing.expectEqual(font.Presentation.text, face.presentation);

    // Generate all visible ASCII
    var i: u8 = 32;
    while (i < 127) : (i += 1) {
        try testing.expect(face.glyphIndex(i) != null);
        _ = try face.renderGlyph(alloc, &atlas, face.glyphIndex(i).?, .{});
    }
}

test "emoji" {
    const testing = std.testing;

    const name = try macos.foundation.String.createWithBytes("Apple Color Emoji", .utf8, false);
    defer name.release();
    const desc = try macos.text.FontDescriptor.createWithNameAndSize(name, 12);
    defer desc.release();
    const ct_font = try macos.text.Font.createWithFontDescriptor(desc, 12);
    defer ct_font.release();

    var face = try Face.initFontCopy(ct_font, .{ .points = 18 });
    defer face.deinit();

    // Presentation
    try testing.expectEqual(font.Presentation.emoji, face.presentation);

    // Glyph index check
    try testing.expect(face.glyphIndex('🥸') != null);
}

test "in-memory" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = @import("../test.zig").fontRegular;

    var atlas = try font.Atlas.init(alloc, 512, .greyscale);
    defer atlas.deinit(alloc);

    var lib = try font.Library.init();
    defer lib.deinit();

    var face = try Face.init(lib, testFont, .{ .points = 12 });
    defer face.deinit();

    try testing.expectEqual(font.Presentation.text, face.presentation);

    // Generate all visible ASCII
    var i: u8 = 32;
    while (i < 127) : (i += 1) {
        try testing.expect(face.glyphIndex(i) != null);
        _ = try face.renderGlyph(alloc, &atlas, face.glyphIndex(i).?, .{});
    }
}
