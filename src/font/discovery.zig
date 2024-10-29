const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const fontconfig = @import("fontconfig");
const macos = @import("macos");
const options = @import("main.zig").options;
const Collection = @import("main.zig").Collection;
const DeferredFace = @import("main.zig").DeferredFace;
const Variation = @import("main.zig").face.Variation;

const log = std.log.scoped(.discovery);

/// Discover implementation for the compile options.
pub const Discover = switch (options.backend) {
    .freetype => void, // no discovery
    .fontconfig_freetype => Fontconfig,
    .web_canvas => void, // no discovery
    .coretext,
    .coretext_freetype,
    .coretext_harfbuzz,
    .coretext_noshape,
    => CoreText,
};

/// Descriptor is used to search for fonts. The only required field
/// is "family". The rest are ignored unless they're set to a non-zero
/// value.
pub const Descriptor = struct {
    /// Font family to search for. This can be a fully qualified font
    /// name such as "Fira Code", "monospace", "serif", etc. Memory is
    /// owned by the caller and should be freed when this descriptor
    /// is no longer in use. The discovery structs will never store the
    /// descriptor.
    ///
    /// On systems that use fontconfig (Linux), this can be a full
    /// fontconfig pattern, such as "Fira Code-14:bold".
    family: ?[:0]const u8 = null,

    /// Specific font style to search for. This will filter the style
    /// string the font advertises. The "bold/italic" booleans later in this
    /// struct filter by the style trait the font has, not the string, so
    /// these can be used in conjunction or not.
    style: ?[:0]const u8 = null,

    /// A codepoint that this font must be able to render.
    codepoint: u32 = 0,

    /// Font size in points that the font should support. For conversion
    /// to pixels, we will use 72 DPI for Mac and 96 DPI for everything else.
    /// (If pixel conversion is necessary, i.e. emoji fonts)
    size: f32 = 0,

    /// True if we want to search specifically for a font that supports
    /// specific styles.
    bold: bool = false,
    italic: bool = false,
    monospace: bool = false,

    /// Variation axes to apply to the font. This also impacts searching
    /// for fonts since fonts with the ability to set these variations
    /// will be preferred, but not guaranteed.
    variations: []const Variation = &.{},

    /// Hash the descriptor with the given hasher.
    pub fn hash(self: Descriptor, hasher: anytype) void {
        const autoHash = std.hash.autoHash;
        const autoHashStrat = std.hash.autoHashStrat;
        autoHashStrat(hasher, self.family, .Deep);
        autoHashStrat(hasher, self.style, .Deep);
        autoHash(hasher, self.codepoint);
        autoHash(hasher, @as(u32, @bitCast(self.size)));
        autoHash(hasher, self.bold);
        autoHash(hasher, self.italic);
        autoHash(hasher, self.monospace);
        autoHash(hasher, self.variations.len);
        for (self.variations) |variation| {
            autoHash(hasher, variation.id);

            // This is not correct, but we don't currently depend on the
            // hash value being different based on decimal values of variations.
            autoHash(hasher, @as(u64, @intFromFloat(variation.value)));
        }
    }

    /// Returns a hash code that can be used to uniquely identify this
    /// action.
    pub fn hashcode(self: Descriptor) u64 {
        var hasher = std.hash.Wyhash.init(0);
        self.hash(&hasher);
        return hasher.final();
    }

    /// Deep copy of the struct. The given allocator is expected to
    /// be an arena allocator of some sort since the descriptor
    /// itself doesn't support fine-grained deallocation of fields.
    pub fn clone(self: *const Descriptor, alloc: Allocator) !Descriptor {
        // We can't do any errdefer cleanup in here. As documented we
        // expect the allocator to be an arena so any errors should be
        // cleaned up somewhere else.

        var copy = self.*;
        copy.family = if (self.family) |src| try alloc.dupeZ(u8, src) else null;
        copy.style = if (self.style) |src| try alloc.dupeZ(u8, src) else null;
        copy.variations = try alloc.dupe(Variation, self.variations);
        return copy;
    }

    /// Convert to Fontconfig pattern to use for lookup. The pattern does
    /// not have defaults filled/substituted (Fontconfig thing) so callers
    /// must still do this.
    pub fn toFcPattern(self: Descriptor) *fontconfig.Pattern {
        const pat = fontconfig.Pattern.create();
        if (self.family) |family| {
            assert(pat.add(.family, .{ .string = family }, false));
        }
        if (self.style) |style| {
            assert(pat.add(.style, .{ .string = style }, false));
        }
        if (self.codepoint > 0) {
            const cs = fontconfig.CharSet.create();
            defer cs.destroy();
            assert(cs.addChar(self.codepoint));
            assert(pat.add(.charset, .{ .char_set = cs }, false));
        }
        if (self.size > 0) assert(pat.add(
            .size,
            .{ .integer = @intFromFloat(@round(self.size)) },
            false,
        ));
        if (self.bold) assert(pat.add(
            .weight,
            .{ .integer = @intFromEnum(fontconfig.Weight.bold) },
            false,
        ));
        if (self.italic) assert(pat.add(
            .slant,
            .{ .integer = @intFromEnum(fontconfig.Slant.italic) },
            false,
        ));

        // For fontconfig, we always add monospace in the pattern. Since
        // fontconfig sorts by closeness to the pattern, this doesn't fully
        // exclude non-monospace but helps prefer it.
        assert(pat.add(
            .spacing,
            .{ .integer = @intFromEnum(fontconfig.Spacing.mono) },
            false,
        ));

        return pat;
    }

    /// Convert to Core Text font descriptor to use for lookup or
    /// conversion to a specific font.
    pub fn toCoreTextDescriptor(self: Descriptor) !*macos.text.FontDescriptor {
        const attrs = try macos.foundation.MutableDictionary.create(0);
        defer attrs.release();

        // Family
        if (self.family) |family_bytes| {
            const family = try macos.foundation.String.createWithBytes(family_bytes, .utf8, false);
            defer family.release();
            attrs.setValue(
                macos.text.FontAttribute.family_name.key(),
                family,
            );
        }

        // Style
        if (self.style) |style_bytes| {
            const style = try macos.foundation.String.createWithBytes(style_bytes, .utf8, false);
            defer style.release();
            attrs.setValue(
                macos.text.FontAttribute.style_name.key(),
                style,
            );
        }

        // Codepoint support
        if (self.codepoint > 0) {
            const cs = try macos.foundation.CharacterSet.createWithCharactersInRange(.{
                .location = self.codepoint,
                .length = 1,
            });
            defer cs.release();
            attrs.setValue(
                macos.text.FontAttribute.character_set.key(),
                cs,
            );
        }

        // Set our size attribute if set
        if (self.size > 0) {
            const size32: i32 = @intFromFloat(@round(self.size));
            const size = try macos.foundation.Number.create(
                .sint32,
                &size32,
            );
            defer size.release();
            attrs.setValue(
                macos.text.FontAttribute.size.key(),
                size,
            );
        }

        // Build our traits. If we set any, then we store it in the attributes
        // otherwise we do nothing. We determine this by setting up the packed
        // struct, converting to an int, and checking if it is non-zero.
        const traits: macos.text.FontSymbolicTraits = .{
            .bold = self.bold,
            .italic = self.italic,
            .monospace = self.monospace,
        };
        const traits_cval: u32 = @bitCast(traits);
        if (traits_cval > 0) {
            // Setting traits is a pain. We have to create a nested dictionary
            // of the symbolic traits value, and set that in our attributes.
            const traits_num = try macos.foundation.Number.create(
                .sint32,
                @as(*const i32, @ptrCast(&traits_cval)),
            );
            defer traits_num.release();

            const traits_dict = try macos.foundation.MutableDictionary.create(0);
            defer traits_dict.release();
            traits_dict.setValue(
                macos.text.FontTraitKey.symbolic.key(),
                traits_num,
            );

            attrs.setValue(
                macos.text.FontAttribute.traits.key(),
                traits_dict,
            );
        }

        // Build our descriptor from attrs
        var desc = try macos.text.FontDescriptor.createWithAttributes(@ptrCast(attrs));
        errdefer desc.release();

        // Variations are built by copying the descriptor. I don't know a way
        // to set it on attrs directly.
        for (self.variations) |v| {
            const id = try macos.foundation.Number.create(.int, @ptrCast(&v.id));
            defer id.release();
            const next = try desc.createCopyWithVariation(id, v.value);
            desc.release();
            desc = next;
        }

        return desc;
    }
};

pub const Fontconfig = struct {
    fc_config: *fontconfig.Config,

    pub fn init() Fontconfig {
        // safe to call multiple times and concurrently
        _ = fontconfig.init();
        return .{ .fc_config = fontconfig.initLoadConfigAndFonts() };
    }

    pub fn deinit(self: *Fontconfig) void {
        self.fc_config.destroy();
    }

    /// Discover fonts from a descriptor. This returns an iterator that can
    /// be used to build up the deferred fonts.
    pub fn discover(
        self: *const Fontconfig,
        alloc: Allocator,
        desc: Descriptor,
    ) !DiscoverIterator {
        _ = alloc;

        // Build our pattern that we'll search for
        const pat = desc.toFcPattern();
        errdefer pat.destroy();
        assert(self.fc_config.substituteWithPat(pat, .pattern));
        pat.defaultSubstitute();

        // Search
        const res = self.fc_config.fontSort(pat, false, null);
        if (res.result != .match) return error.FontConfigFailed;
        errdefer res.fs.destroy();

        return .{
            .config = self.fc_config,
            .pattern = pat,
            .set = res.fs,
            .fonts = res.fs.fonts(),
            .variations = desc.variations,
            .i = 0,
        };
    }

    pub fn discoverFallback(
        self: *const Fontconfig,
        alloc: Allocator,
        collection: *Collection,
        desc: Descriptor,
    ) !DiscoverIterator {
        _ = collection;
        return try self.discover(alloc, desc);
    }

    pub const DiscoverIterator = struct {
        config: *fontconfig.Config,
        pattern: *fontconfig.Pattern,
        set: *fontconfig.FontSet,
        fonts: []*fontconfig.Pattern,
        variations: []const Variation,
        i: usize,

        pub fn deinit(self: *DiscoverIterator) void {
            self.set.destroy();
            self.pattern.destroy();
            self.* = undefined;
        }

        pub fn next(self: *DiscoverIterator) fontconfig.Error!?DeferredFace {
            if (self.i >= self.fonts.len) return null;

            // Get the copied pattern from our fontset that has the
            // attributes configured for rendering.
            const font_pattern = try self.config.fontRenderPrepare(
                self.pattern,
                self.fonts[self.i],
            );
            errdefer font_pattern.destroy();

            // Increment after we return
            defer self.i += 1;

            return DeferredFace{
                .fc = .{
                    .pattern = font_pattern,
                    .charset = (try font_pattern.get(.charset, 0)).char_set,
                    .langset = (try font_pattern.get(.lang, 0)).lang_set,
                    .variations = self.variations,
                },
            };
        }
    };
};

pub const CoreText = struct {
    pub fn init() CoreText {
        // Required for the "interface" but does nothing for CoreText.
        return .{};
    }

    pub fn deinit(self: *CoreText) void {
        _ = self;
    }

    /// Discover fonts from a descriptor. This returns an iterator that can
    /// be used to build up the deferred fonts.
    pub fn discover(self: *const CoreText, alloc: Allocator, desc: Descriptor) !DiscoverIterator {
        _ = self;

        // Build our pattern that we'll search for
        const ct_desc = try desc.toCoreTextDescriptor();
        defer ct_desc.release();

        // Our descriptors have to be in an array
        var ct_desc_arr = [_]*const macos.text.FontDescriptor{ct_desc};
        const desc_arr = try macos.foundation.Array.create(macos.text.FontDescriptor, &ct_desc_arr);
        defer desc_arr.release();

        // Build our collection
        const set = try macos.text.FontCollection.createWithFontDescriptors(desc_arr);
        defer set.release();
        const list = set.createMatchingFontDescriptors();
        defer list.release();

        // Sort our descriptors
        const zig_list = try copyMatchingDescriptors(alloc, list);
        errdefer alloc.free(zig_list);
        sortMatchingDescriptors(&desc, zig_list);

        return DiscoverIterator{
            .alloc = alloc,
            .list = zig_list,
            .i = 0,
        };
    }

    pub fn discoverFallback(
        self: *const CoreText,
        alloc: Allocator,
        collection: *Collection,
        desc: Descriptor,
    ) !DiscoverIterator {
        // If we have a codepoint within the CJK unified ideographs block
        // then we fallback to macOS to find a font that supports it because
        // there isn't a better way manually with CoreText that I can find that
        // properly takes into account system locale.
        //
        // References:
        // - http://unicode.org/charts/PDF/U4E00.pdf
        // - https://chromium.googlesource.com/chromium/src/+/main/third_party/blink/renderer/platform/fonts/LocaleInFonts.md#unified-han-ideographs
        if (desc.codepoint >= 0x4E00 and
            desc.codepoint <= 0x9FFF)
        han: {
            const han = try self.discoverCodepoint(
                collection,
                desc,
            ) orelse break :han;

            // This is silly but our discover iterator needs a slice so
            // we allocate here. This isn't a performance bottleneck but
            // this is something we can optimize very easily...
            const list = try alloc.alloc(*macos.text.FontDescriptor, 1);
            errdefer alloc.free(list);
            list[0] = han;

            return DiscoverIterator{
                .alloc = alloc,
                .list = list,
                .i = 0,
            };
        }

        const it = try self.discover(alloc, desc);

        // If our normal discovery doesn't find anything and we have a specific
        // codepoint, then fallback to using CTFontCreateForString to find a
        // matching font CoreText wants to use. See:
        // https://github.com/ghostty-org/ghostty/issues/2499
        if (it.list.len == 0 and desc.codepoint > 0) codepoint: {
            const ct_desc = try self.discoverCodepoint(
                collection,
                desc,
            ) orelse break :codepoint;

            const list = try alloc.alloc(*macos.text.FontDescriptor, 1);
            errdefer alloc.free(list);
            list[0] = ct_desc;

            return DiscoverIterator{
                .alloc = alloc,
                .list = list,
                .i = 0,
            };
        }

        return it;
    }

    /// Discover a font for a specific codepoint using the CoreText
    /// CTFontCreateForString API.
    fn discoverCodepoint(
        self: *const CoreText,
        collection: *Collection,
        desc: Descriptor,
    ) !?*macos.text.FontDescriptor {
        _ = self;

        if (comptime options.backend.hasFreetype()) {
            // If we have freetype, we can't use CoreText to find a font
            // that supports a specific codepoint because we need to
            // have a CoreText font to be able to do so.
            return null;
        }

        assert(desc.codepoint > 0);

        // Get our original font. This is dependent on the requested style
        // from the descriptor.
        const original = original: {
            // In all the styles below, we try to match it but if we don't
            // we always fall back to some other option. The order matters
            // here.

            if (desc.bold and desc.italic) {
                const entries = collection.faces.get(.bold_italic);
                if (entries.count() > 0) {
                    break :original try collection.getFace(.{ .style = .bold_italic });
                }
            }

            if (desc.bold) {
                const entries = collection.faces.get(.bold);
                if (entries.count() > 0) {
                    break :original try collection.getFace(.{ .style = .bold });
                }
            }

            if (desc.italic) {
                const entries = collection.faces.get(.italic);
                if (entries.count() > 0) {
                    break :original try collection.getFace(.{ .style = .italic });
                }
            }

            break :original try collection.getFace(.{ .style = .regular });
        };

        // We need it in utf8 format
        var buf: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(
            @intCast(desc.codepoint),
            &buf,
        );

        // We need a CFString
        const str = try macos.foundation.String.createWithBytes(
            buf[0..len],
            .utf8,
            false,
        );
        defer str.release();

        // Get our range length for CTFontCreateForString. It looks like
        // the range uses UTF-16 codepoints and not UTF-32 codepoints.
        const range_len: usize = range_len: {
            var unichars: [2]u16 = undefined;
            const pair = macos.foundation.stringGetSurrogatePairForLongCharacter(
                desc.codepoint,
                &unichars,
            );
            break :range_len if (pair) 2 else 1;
        };

        // Get our font
        const font = original.font.createForString(
            str,
            macos.foundation.Range.init(0, range_len),
        ) orelse return null;
        defer font.release();

        // Do not allow the last resort font to go through. This is the
        // last font used by CoreText if it can't find anything else and
        // only contains replacement characters.
        last_resort: {
            const name_str = font.copyPostScriptName();
            defer name_str.release();

            // If the name doesn't fit in our buffer, then it can't
            // be the last resort font so we break out.
            var name_buf: [64]u8 = undefined;
            const name: []const u8 = name_str.cstring(&name_buf, .utf8) orelse
                break :last_resort;

            // If the name is "LastResort" then we don't want to use it.
            if (std.mem.eql(u8, "LastResort", name)) return null;
        }

        // Get the descriptor
        return font.copyDescriptor();
    }

    fn copyMatchingDescriptors(
        alloc: Allocator,
        list: *macos.foundation.Array,
    ) ![]*macos.text.FontDescriptor {
        var result = try alloc.alloc(*macos.text.FontDescriptor, list.getCount());
        errdefer alloc.free(result);
        for (0..result.len) |i| {
            result[i] = list.getValueAtIndex(macos.text.FontDescriptor, i);

            // We need to retain becauseonce the list is freed it will
            // release all its members.
            result[i].retain();
        }
        return result;
    }

    fn sortMatchingDescriptors(
        desc: *const Descriptor,
        list: []*macos.text.FontDescriptor,
    ) void {
        var desc_mut = desc.*;
        if (desc_mut.style == null) {
            // If there is no explicit style set, we set a preferred
            // based on the style bool attributes.
            //
            // TODO: doesn't handle i18n font names well, we should have
            // another mechanism that uses the weight attribute if it exists.
            // Wait for this to be a real problem.
            desc_mut.style = if (desc_mut.bold and desc_mut.italic)
                "Bold Italic"
            else if (desc_mut.bold)
                "Bold"
            else if (desc_mut.italic)
                "Italic"
            else
                null;
        }

        std.mem.sortUnstable(*macos.text.FontDescriptor, list, &desc_mut, struct {
            fn lessThan(
                desc_inner: *const Descriptor,
                lhs: *macos.text.FontDescriptor,
                rhs: *macos.text.FontDescriptor,
            ) bool {
                const lhs_score = score(desc_inner, lhs);
                const rhs_score = score(desc_inner, rhs);
                // Higher score is "less" (earlier)
                return lhs_score.int() > rhs_score.int();
            }
        }.lessThan);
    }

    /// We represent our sorting score as a packed struct so that we can
    /// compare scores numerically but build scores symbolically.
    const Score = packed struct {
        const Backing = @typeInfo(@This()).Struct.backing_integer.?;

        glyph_count: u16 = 0, // clamped if > intmax
        traits: Traits = .unmatched,
        style: Style = .unmatched,
        monospace: bool = false,
        codepoint: bool = false,

        const Traits = enum(u8) { unmatched = 0, _ };
        const Style = enum(u8) { unmatched = 0, match = 0xFF, _ };

        pub fn int(self: Score) Backing {
            return @bitCast(self);
        }
    };

    fn score(desc: *const Descriptor, ct_desc: *const macos.text.FontDescriptor) Score {
        var score_acc: Score = .{};

        // We always load the font if we can since some things can only be
        // inspected on the font itself.
        const font_: ?*macos.text.Font = macos.text.Font.createWithFontDescriptor(
            ct_desc,
            12,
        ) catch null;
        defer if (font_) |font| font.release();

        // If we have a font, prefer the font with more glyphs.
        if (font_) |font| {
            const Type = @TypeOf(score_acc.glyph_count);
            score_acc.glyph_count = std.math.cast(
                Type,
                font.getGlyphCount(),
            ) orelse std.math.maxInt(Type);
        }

        // If we're searching for a codepoint, prioritize fonts that
        // have that codepoint.
        if (desc.codepoint > 0) codepoint: {
            const font = font_ orelse break :codepoint;

            // Turn UTF-32 into UTF-16 for CT API
            var unichars: [2]u16 = undefined;
            const pair = macos.foundation.stringGetSurrogatePairForLongCharacter(
                desc.codepoint,
                &unichars,
            );
            const len: usize = if (pair) 2 else 1;

            // Get our glyphs
            var glyphs = [2]macos.graphics.Glyph{ 0, 0 };
            score_acc.codepoint = font.getGlyphsForCharacters(unichars[0..len], glyphs[0..len]);
        }

        // Get our symbolic traits for the descriptor so we can compare
        // boolean attributes like bold, monospace, etc.
        const symbolic_traits: macos.text.FontSymbolicTraits = traits: {
            const traits = ct_desc.copyAttribute(.traits) orelse break :traits .{};
            defer traits.release();

            const key = macos.text.FontTraitKey.symbolic.key();
            const symbolic = traits.getValue(macos.foundation.Number, key) orelse
                break :traits .{};

            break :traits macos.text.FontSymbolicTraits.init(symbolic);
        };

        score_acc.monospace = symbolic_traits.monospace;

        score_acc.style = style: {
            const style = ct_desc.copyAttribute(.style_name) orelse
                break :style .unmatched;
            defer style.release();

            // If we have a specific desired style, attempt to search for that.
            if (desc.style) |desired_style| {
                var buf: [128]u8 = undefined;
                const style_str = style.cstring(&buf, .utf8) orelse break :style .unmatched;

                // Matching style string gets highest score
                if (std.mem.eql(u8, desired_style, style_str)) break :style .match;

                // Otherwise the score is based on the length of the style string.
                // Shorter styles are scored higher.
                break :style @enumFromInt(100 -| style_str.len);
            }

            // If we do not, and we have no symbolic traits, then we try
            // to find "regular" (or no style). If we have symbolic traits
            // we do nothing but we can improve scoring by taking that into
            // account, too.
            if (!desc.bold and !desc.italic) {
                var buf: [128]u8 = undefined;
                const style_str = style.cstring(&buf, .utf8) orelse break :style .unmatched;
                if (std.mem.eql(u8, "Regular", style_str)) break :style .match;
            }

            break :style .unmatched;
        };

        score_acc.traits = traits: {
            var count: u8 = 0;
            if (desc.bold == symbolic_traits.bold) count += 1;
            if (desc.italic == symbolic_traits.italic) count += 1;
            break :traits @enumFromInt(count);
        };

        return score_acc;
    }

    pub const DiscoverIterator = struct {
        alloc: Allocator,
        list: []const *macos.text.FontDescriptor,
        i: usize,

        pub fn deinit(self: *DiscoverIterator) void {
            self.alloc.free(self.list);
            self.* = undefined;
        }

        pub fn next(self: *DiscoverIterator) !?DeferredFace {
            if (self.i >= self.list.len) return null;

            // Get our descriptor. We need to remove the character set
            // limitation because we may have used that to filter but we
            // don't want it anymore because it'll restrict the characters
            // available.
            //const desc = self.list.getValueAtIndex(macos.text.FontDescriptor, self.i);
            const desc = desc: {
                const original = self.list[self.i];

                // For some reason simply copying the attributes and recreating
                // the descriptor removes the charset restriction. This is tested.
                const attrs = original.copyAttributes();
                defer attrs.release();
                break :desc try macos.text.FontDescriptor.createWithAttributes(@ptrCast(attrs));
            };
            defer desc.release();

            // Create our font. We need a size to initialize it so we use size
            // 12 but we will alter the size later.
            const font = try macos.text.Font.createWithFontDescriptor(desc, 12);
            errdefer font.release();

            // Increment after we return
            defer self.i += 1;

            return DeferredFace{
                .ct = .{ .font = font },
            };
        }
    };
};

test "descriptor hash" {
    const testing = std.testing;

    var d: Descriptor = .{};
    try testing.expect(d.hashcode() != 0);
}

test "descriptor hash family names" {
    const testing = std.testing;

    var d1: Descriptor = .{ .family = "A" };
    var d2: Descriptor = .{ .family = "B" };
    try testing.expect(d1.hashcode() != d2.hashcode());
}

test "fontconfig" {
    if (options.backend != .fontconfig_freetype) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var fc = Fontconfig.init();
    var it = try fc.discover(alloc, .{ .family = "monospace", .size = 12 });
    defer it.deinit();
}

test "fontconfig codepoint" {
    if (options.backend != .fontconfig_freetype) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var fc = Fontconfig.init();
    var it = try fc.discover(alloc, .{ .codepoint = 'A', .size = 12 });
    defer it.deinit();

    // The first result should have the codepoint. Later ones may not
    // because fontconfig returns all fonts sorted.
    const face = (try it.next()).?;
    try testing.expect(face.hasCodepoint('A', null));

    // Should have other codepoints too
    try testing.expect(face.hasCodepoint('B', null));
}

test "coretext" {
    if (options.backend != .coretext and options.backend != .coretext_freetype)
        return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var ct = CoreText.init();
    defer ct.deinit();
    var it = try ct.discover(alloc, .{ .family = "Monaco", .size = 12 });
    defer it.deinit();
    var count: usize = 0;
    while (try it.next()) |_| {
        count += 1;
    }
    try testing.expect(count > 0);
}

test "coretext codepoint" {
    if (options.backend != .coretext and options.backend != .coretext_freetype)
        return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var ct = CoreText.init();
    defer ct.deinit();
    var it = try ct.discover(alloc, .{ .codepoint = 'A', .size = 12 });
    defer it.deinit();

    // The first result should have the codepoint. Later ones may not
    // because fontconfig returns all fonts sorted.
    const face = (try it.next()).?;
    try testing.expect(face.hasCodepoint('A', null));

    // Should have other codepoints too
    try testing.expect(face.hasCodepoint('B', null));
}
