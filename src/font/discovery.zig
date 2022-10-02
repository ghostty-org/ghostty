const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const fontconfig = @import("fontconfig");
const macos = @import("macos");
const options = @import("main.zig").options;
const DeferredFace = @import("main.zig").DeferredFace;

const log = std.log.named(.discovery);

/// Discover implementation for the compile options.
pub const Discover = if (options.fontconfig)
    Fontconfig
else if (options.coretext)
    CoreText
else
    void;

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
    family: [:0]const u8,

    /// Font size in points that the font should support. For conversion
    /// to pixels, we will use 72 DPI for Mac and 96 DPI for everything else.
    /// (If pixel conversion is necessary, i.e. emoji fonts)
    size: u16,

    /// True if we want to search specifically for a font that supports
    /// bold, italic, or both.
    bold: bool = false,
    italic: bool = false,

    /// Convert to Fontconfig pattern to use for lookup. The pattern does
    /// not have defaults filled/substituted (Fontconfig thing) so callers
    /// must still do this.
    pub fn toFcPattern(self: Descriptor) *fontconfig.Pattern {
        const pat = fontconfig.Pattern.create();
        assert(pat.add(.family, .{ .string = self.family }, false));
        if (self.size > 0) assert(pat.add(
            .size,
            .{ .integer = self.size },
            false,
        ));
        if (self.bold) assert(pat.add(
            .weight,
            .{ .integer = @enumToInt(fontconfig.Weight.bold) },
            false,
        ));
        if (self.italic) assert(pat.add(
            .slant,
            .{ .integer = @enumToInt(fontconfig.Slant.italic) },
            false,
        ));

        return pat;
    }

    /// Convert to Core Text font descriptor to use for lookup or
    /// conversion to a specific font.
    pub fn toCoreTextDescriptor(self: Descriptor) !*macos.text.FontDescriptor {
        const attrs = try macos.foundation.MutableDictionary.create(0);
        defer attrs.release();

        // Family is always set
        const family = try macos.foundation.String.createWithBytes(self.family, .utf8, false);
        defer family.release();
        attrs.setValue(
            macos.text.FontAttribute.family_name.key(),
            family,
        );

        // Set our size attribute if set
        if (self.size > 0) {
            const size32 = @intCast(i32, self.size);
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
        };
        const traits_cval = traits.cval();
        if (traits_cval > 0) {
            // Setting traits is a pain. We have to create a nested dictionary
            // of the symbolic traits value, and set that in our attributes.
            const traits_num = try macos.foundation.Number.create(
                .sint32,
                @ptrCast(*const i32, &traits_cval),
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

        return try macos.text.FontDescriptor.createWithAttributes(@ptrCast(
            *macos.foundation.Dictionary,
            attrs,
        ));
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
        _ = self;
    }

    /// Discover fonts from a descriptor. This returns an iterator that can
    /// be used to build up the deferred fonts.
    pub fn discover(self: *Fontconfig, desc: Descriptor) !DiscoverIterator {
        // Build our pattern that we'll search for
        const pat = desc.toFcPattern();
        errdefer pat.destroy();
        assert(self.fc_config.substituteWithPat(pat, .pattern));
        pat.defaultSubstitute();

        // Search
        const res = self.fc_config.fontSort(pat, true, null);
        if (res.result != .match) return error.FontConfigFailed;
        errdefer res.fs.destroy();

        return DiscoverIterator{
            .config = self.fc_config,
            .pattern = pat,
            .set = res.fs,
            .fonts = res.fs.fonts(),
            .i = 0,
        };
    }

    pub const DiscoverIterator = struct {
        config: *fontconfig.Config,
        pattern: *fontconfig.Pattern,
        set: *fontconfig.FontSet,
        fonts: []*fontconfig.Pattern,
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
                .face = null,
                .fc = .{
                    .pattern = font_pattern,
                    .charset = (try font_pattern.get(.charset, 0)).char_set,
                    .langset = (try font_pattern.get(.lang, 0)).lang_set,
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
    pub fn discover(self: *const CoreText, desc: Descriptor) !DiscoverIterator {
        _ = self;

        // Build our pattern that we'll search for
        const ct_desc = try desc.toCoreTextDescriptor();
        defer ct_desc.release();

        // Our descriptors have to be in an array
        const desc_arr = try macos.foundation.Array.create(
            macos.text.FontDescriptor,
            &[_]*const macos.text.FontDescriptor{ct_desc},
        );
        defer desc_arr.release();

        // Build our collection
        const set = try macos.text.FontCollection.createWithFontDescriptors(desc_arr);
        defer set.release();
        const list = set.createMatchingFontDescriptors();
        errdefer list.release();

        return DiscoverIterator{
            .list = list,
            .i = 0,
        };
    }

    pub const DiscoverIterator = struct {
        list: *macos.foundation.Array,
        i: usize,

        pub fn deinit(self: *DiscoverIterator) void {
            self.list.release();
            self.* = undefined;
        }

        pub fn next(self: *DiscoverIterator) !?DeferredFace {
            if (self.i >= self.list.getCount()) return null;

            // Create our font. We need a size to initialize it so we use size
            // 12 but we will alter the size later.
            const desc = self.list.getValueAtIndex(macos.text.FontDescriptor, self.i);
            const font = try macos.text.Font.createWithFontDescriptor(desc, 12);
            errdefer font.release();

            // Increment after we return
            defer self.i += 1;

            return DeferredFace{
                .face = null,
                .ct = .{ .font = font },
            };
        }
    };
};

test "fontconfig" {
    if (!options.fontconfig) return error.SkipZigTest;

    const testing = std.testing;

    var fc = Fontconfig.init();
    var it = try fc.discover(.{ .family = "monospace", .size = 12 });
    defer it.deinit();
    while (try it.next()) |face| {
        try testing.expect(!face.loaded());
    }
}

test "core text" {
    if (!options.coretext) return error.SkipZigTest;

    const testing = std.testing;

    var ct = CoreText.init();
    defer ct.deinit();
    var it = try ct.discover(.{ .family = "Monaco", .size = 12 });
    defer it.deinit();
    var count: usize = 0;
    while (try it.next()) |face| {
        count += 1;
        try testing.expect(!face.loaded());
    }
    try testing.expect(count > 0);
}
