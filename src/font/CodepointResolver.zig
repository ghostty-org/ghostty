//! CodepointResolver maps a codepoint to a font. It is more dynamic
//! than "Collection" since it supports mapping codepoint ranges to
//! specific fonts, searching for fallback fonts, and more.
//!
//! To initialize the codepoint resolver, manually initialize using
//! Zig initialization syntax: .{}-style. Set the fields you want set,
//! and begin using the resolver.
//!
//! Deinit must still be called on the resolver to free any memory
//! allocated during use. All functions that take allocators should use
//! the same allocator.
const CodepointResolver = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const ziglyph = @import("ziglyph");
const font = @import("main.zig");
const Atlas = font.Atlas;
const CodepointMap = font.CodepointMap;
const Collection = font.Collection;
const Discover = font.Discover;
const DiscoveryDescriptor = font.discovery.Descriptor;
const Face = font.Face;
const Glyph = font.Glyph;
const Library = font.Library;
const Presentation = font.Presentation;
const RenderOptions = font.face.RenderOptions;
const SpriteFace = font.SpriteFace;
const Style = font.Style;

const log = std.log.scoped(.font_codepoint_resolver);

/// The underlying collection of fonts. This will be modified as
/// new fonts are found via the resolver. The resolver takes ownership
/// of the collection and will deinit it when it is deinitialized.
collection: Collection,

/// The set of statuses and whether they're enabled or not. This defaults
/// to true. This can be changed at runtime with no ill effect.
styles: StyleStatus = .initFill(true),

/// If discovery is available, we'll look up fonts where we can't find
/// the codepoint. This can be set after initialization.
discover: ?*Discover = null,

/// A map of codepoints to font requests for codepoint-level overrides.
/// The memory associated with the map is owned by the caller and is not
/// modified or freed by Group.
codepoint_map: ?CodepointMap = null,

/// The descriptor cache is used to cache the descriptor to font face
/// mapping for codepoint maps.
descriptor_cache: DescriptorCache = .{},

/// Set this to a non-null value to enable sprite glyph drawing. If this
/// isn't enabled we'll just fall through to trying to use regular fonts
/// to render sprite glyphs. But more than likely, if this isn't set then
/// terminal rendering will look wrong.
sprite: ?SpriteFace = null,

pub fn deinit(self: *CodepointResolver, alloc: Allocator) void {
    self.collection.deinit(alloc);
    self.descriptor_cache.deinit(alloc);
}

/// Looks up the font that should be used for a specific codepoint.
/// The font index is valid as long as font faces aren't removed. This
/// isn't cached; it is expected that downstream users handle caching if
/// that is important.
///
/// Optionally, a presentation format can be specified. This presentation
/// format will be preferred but if it can't be found in this format,
/// any format will be accepted. If presentation is null, the UCD
/// (Unicode Character Database) will be used to determine the default
/// presentation for the codepoint.
/// a code point.
///
/// An allocator is required because certain functionality (codepoint
/// mapping, fallback fonts, etc.) may require memory allocation. Curiously,
/// this function cannot error! If an error occurs for any reason, including
/// memory allocation, the associated functionality is ignored and the
/// resolver attempts to use a different method to satisfy the codepoint.
/// This behavior is intentional to make the resolver apply best-effort
/// logic to satisfy the codepoint since its better to render something
/// than nothing.
///
/// This logic is relatively complex so the exact algorithm is documented
/// here. If this gets out of sync with the code, ask questions.
///
///   1. If a font style is requested that is disabled (i.e. bold),
///      we start over with the regular font style. The regular font style
///      cannot be disabled, but it can be replaced with a stylized font
///      face.
///
///   2. If there is a codepoint override for the codepoint, we satisfy
///      that requirement if we can, no matter what style or presentation.
///
///   3. If this is a sprite codepoint (such as an underline), then the
///      sprite font always is the result.
///
///   4. If the exact style and presentation request can be satisfied by
///      one of our loaded fonts, we return that value. We search loaded
///      fonts in the order they're added to the group, so the caller must
///      set the priority order.
///
///   5. If the style isn't regular, we restart this process at this point
///      but with the regular style. This lets us fall back to regular with
///      our loaded fonts before trying a fallback. We'd rather show a regular
///      version of a codepoint from a loaded font than find a new font in
///      the correct style because styles in other fonts often change
///      metrics like glyph widths.
///
///   6. If the style is regular, and font discovery is enabled, we look
///      for a fallback font to satisfy our request.
///
///   7. Finally, as a last resort, we fall back to restarting this whole
///      process with a regular font face satisfying ANY presentation for
///      the codepoint. If this fails, we return null.
///
pub fn getIndex(
    self: *CodepointResolver,
    alloc: Allocator,
    cp: u32,
    style: Style,
    p: ?Presentation,
) ?Collection.Index {
    // If we've disabled a font style, then fall back to regular.
    if (style != .regular and !self.styles.get(style)) {
        return self.getIndex(alloc, cp, .regular, p);
    }

    // Codepoint overrides.
    if (self.getIndexCodepointOverride(alloc, cp)) |idx_| {
        if (idx_) |idx| return idx;
    } else |err| {
        log.warn("codepoint override failed codepoint={} err={}", .{ cp, err });
    }

    // If we have sprite drawing enabled, check if our sprite face can
    // handle this.
    if (self.sprite) |sprite| {
        if (sprite.hasCodepoint(cp, p)) {
            return .initSpecial(.sprite);
        }
    }

    // Build our presentation mode. If we don't have an explicit presentation
    // given then we use the UCD (Unicode Character Database) to determine
    // the default presentation. Note there is some inefficiency here because
    // we'll do this multiple times if we recurse, but this is a cached function
    // call higher up (GroupCache) so this should be rare.
    const p_mode: Collection.PresentationMode = if (p) |v| .{ .explicit = v } else .{
        .default = if (ziglyph.emoji.isEmojiPresentation(@intCast(cp)))
            .emoji
        else
            .text,
    };

    // If we can find the exact value, then return that.
    if (self.collection.getIndex(cp, style, p_mode)) |value| return value;

    // If we're not a regular font style, try looking for a regular font
    // that will satisfy this request. Blindly looking for unmatched styled
    // fonts to satisfy one codepoint results in some ugly rendering.
    if (style != .regular) {
        if (self.getIndex(alloc, cp, .regular, p)) |value| return value;
    }

    // If we are regular, try looking for a fallback using discovery.
    if (style == .regular and font.Discover != void) {
        log.debug("searching for a fallback font for cp={X}", .{cp});
        if (self.discover) |disco| discover: {
            const load_opts = self.collection.load_options orelse
                break :discover;
            var disco_it = disco.discoverFallback(alloc, &self.collection, .{
                .codepoint = cp,
                .size = load_opts.size.points,
                .bold = style == .bold or style == .bold_italic,
                .italic = style == .italic or style == .bold_italic,
                .monospace = false,
            }) catch break :discover;
            defer disco_it.deinit();

            while (true) {
                var deferred_face = (disco_it.next() catch |err| {
                    log.warn("fallback search failed with error err={}", .{err});
                    break;
                }) orelse break;

                // Discovery is supposed to only return faces that have our
                // codepoint but we can't search presentation in discovery so
                // we have to check it here.
                const face: Collection.Entry = .{ .fallback_deferred = deferred_face };
                if (!face.hasCodepoint(cp, p_mode)) {
                    deferred_face.deinit();
                    continue;
                }

                var buf: [256]u8 = undefined;
                log.info("found codepoint 0x{X} in fallback face={s}", .{
                    cp,
                    deferred_face.name(&buf) catch "<error>",
                });
                return self.collection.add(alloc, style, face) catch {
                    deferred_face.deinit();
                    break :discover;
                };
            }

            log.debug("no fallback face found for cp={X}", .{cp});
        }
    }

    // If this is regular with any matching presentation, then we are done
    // there is nothing more we can do. Otherwise we fall through and do
    // an any presentation search.
    if (style == .regular and p_mode == .any) return null;

    // For non-regular fonts, we fall back to regular with any presentation
    return self.collection.getIndex(cp, .regular, .{ .any = {} });
}

/// Checks if the codepoint is in the map of codepoint overrides,
/// finds the override font, and returns it.
fn getIndexCodepointOverride(
    self: *CodepointResolver,
    alloc: Allocator,
    cp: u32,
) !?Collection.Index {
    // If discovery is disabled then we can't do codepoint overrides
    // since the override is based on discovery to find the font.
    if (comptime font.Discover == void) return null;

    // Get our codepoint map. If we have no map set then we have no
    // codepoint overrides and we're done.
    const map = self.codepoint_map orelse return null;

    // If we have a codepoint too large or isn't in the map, then we
    // don't have an override. The map returns a descriptor that can be
    // used with font discovery to search for a matching font.
    const cp_u21 = std.math.cast(u21, cp) orelse return null;
    const desc = map.get(cp_u21) orelse return null;

    // Fast path: the descriptor is already loaded. This means that we
    // already did the search before and we have an exact font for this
    // codepoint.
    const idx_: ?Collection.Index = self.descriptor_cache.get(desc) orelse idx: {
        // Slow path: we have to find this descriptor and load the font
        const discover = self.discover orelse return null;
        var disco_it = try discover.discover(alloc, desc);
        defer disco_it.deinit();

        const face = (try disco_it.next()) orelse {
            log.warn(
                "font lookup for codepoint map failed codepoint={} err=FontNotFound",
                .{cp},
            );

            // Add null to the cache so we don't do a lookup again later.
            try self.descriptor_cache.put(alloc, desc, null);
            return null;
        };

        // Add the font to our list of fonts so we can get an index for it,
        // and ensure the index is stored in the descriptor cache for next time.
        const idx = try self.collection.add(
            alloc,
            .regular,
            .{ .deferred = face },
        );
        try self.descriptor_cache.put(alloc, desc, idx);

        break :idx idx;
    };

    // The descriptor cache will populate null if the descriptor is not found
    // to avoid expensive discoveries later, so if it is null then we already
    // searched and found nothing.
    const idx = idx_ orelse return null;

    // We need to verify that this index has the codepoint we want.
    if (self.collection.hasCodepoint(idx, cp, .{ .any = {} })) {
        log.debug("codepoint override based on config codepoint={} family={s}", .{
            cp,
            desc.family orelse "",
        });

        return idx;
    }

    return null;
}

/// Returns the presentation for a specific font index. This is useful for
/// determining what atlas is needed.
pub fn getPresentation(
    self: *CodepointResolver,
    index: Collection.Index,
    glyph_index: u32,
) !Presentation {
    if (index.special()) |sp| return switch (sp) {
        .sprite => .text,
    };

    const face = try self.collection.getFace(index);
    return if (face.isColorGlyph(glyph_index)) .emoji else .text;
}

/// Render a glyph by glyph index into the given font atlas and return
/// metadata about it.
///
/// This performs no caching, it is up to the caller to cache calls to this
/// if they want. This will also not resize the atlas if it is full.
///
/// IMPORTANT: this renders by /glyph index/ and not by /codepoint/. The caller
/// is expected to translate codepoints to glyph indexes in some way. The most
/// trivial way to do this is to get the Face and call glyphIndex. If you're
/// doing text shaping, the text shaping library (i.e. HarfBuzz) will automatically
/// determine glyph indexes for a text run.
pub fn renderGlyph(
    self: *CodepointResolver,
    alloc: Allocator,
    atlas: *Atlas,
    index: Collection.Index,
    glyph_index: u32,
    opts: RenderOptions,
) !Glyph {
    // Special-case fonts are rendered directly.
    if (index.special()) |sp| switch (sp) {
        .sprite => return try self.sprite.?.renderGlyph(
            alloc,
            atlas,
            glyph_index,
            opts,
        ),
    };

    const face = try self.collection.getFace(index);
    const glyph = try face.renderGlyph(alloc, atlas, glyph_index, opts);
    // log.warn("GLYPH={}", .{glyph});
    return glyph;
}

/// Packed array of booleans to indicate if a style is enabled or not.
pub const StyleStatus = std.EnumArray(Style, bool);

/// Map of descriptors to faces. This is used with manual codepoint maps
/// to ensure that we don't load the same font multiple times.
///
/// Note that the current implementation will load the same font multiple
/// times if the font used for a codepoint map is identical to a font used
/// for a regular style. That's just an inefficient choice made now because
/// the implementation is simpler and codepoint maps matching a regular
/// font is a rare case.
const DescriptorCache = std.HashMapUnmanaged(
    DiscoveryDescriptor,
    ?Collection.Index,
    struct {
        const KeyType = DiscoveryDescriptor;

        pub fn hash(ctx: @This(), k: KeyType) u64 {
            _ = ctx;
            return k.hashcode();
        }

        pub fn eql(ctx: @This(), a: KeyType, b: KeyType) bool {
            // Note that this means its possible to have two different
            // descriptors match when there is a hash collision so we
            // should button this up later.
            return ctx.hash(a) == ctx.hash(b);
        }
    },
    std.hash_map.default_max_load_percentage,
);

test getIndex {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.regular;
    const testEmoji = font.embedded.emoji;
    const testEmojiText = font.embedded.emoji_text;

    var lib = try Library.init(alloc);
    defer lib.deinit();

    var c = Collection.init();
    c.load_options = .{ .library = lib };

    {
        errdefer c.deinit(alloc);
        _ = try c.add(alloc, .regular, .{ .loaded = try .init(
            lib,
            testFont,
            .{ .size = .{ .points = 12, .xdpi = 96, .ydpi = 96 } },
        ) });
        if (comptime !font.options.backend.hasCoretext()) {
            // Coretext doesn't support Noto's format
            _ = try c.add(
                alloc,
                .regular,
                .{ .loaded = try .init(
                    lib,
                    testEmoji,
                    .{ .size = .{ .points = 12 } },
                ) },
            );
        }
        _ = try c.add(
            alloc,
            .regular,
            .{ .loaded = try .init(
                lib,
                testEmojiText,
                .{ .size = .{ .points = 12 } },
            ) },
        );
    }

    var r: CodepointResolver = .{ .collection = c };
    defer r.deinit(alloc);

    // Should find all visible ASCII
    var i: u32 = 32;
    while (i < 127) : (i += 1) {
        const idx = r.getIndex(alloc, i, .regular, null).?;
        try testing.expectEqual(Style.regular, idx.style);
        try testing.expectEqual(@as(Collection.Index.IndexInt, 0), idx.idx);
    }

    // Try emoji
    {
        const idx = r.getIndex(alloc, '🥸', .regular, null).?;
        try testing.expectEqual(Style.regular, idx.style);
        try testing.expectEqual(@as(Collection.Index.IndexInt, 1), idx.idx);
    }

    // Try text emoji
    {
        const idx = r.getIndex(alloc, 0x270C, .regular, .text).?;
        try testing.expectEqual(Style.regular, idx.style);
        const text_idx = if (comptime font.options.backend.hasCoretext()) 1 else 2;
        try testing.expectEqual(@as(Collection.Index.IndexInt, text_idx), idx.idx);
    }
    {
        const idx = r.getIndex(alloc, 0x270C, .regular, .emoji).?;
        try testing.expectEqual(Style.regular, idx.style);
        try testing.expectEqual(@as(Collection.Index.IndexInt, 1), idx.idx);
    }

    // Box glyph should be null since we didn't set a box font
    {
        try testing.expect(r.getIndex(alloc, 0x1FB00, .regular, null) == null);
    }
}

test "getIndex disabled font style" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = font.embedded.regular;

    var atlas_grayscale = try font.Atlas.init(alloc, 512, .grayscale);
    defer atlas_grayscale.deinit(alloc);

    var lib = try Library.init(alloc);
    defer lib.deinit();

    var c = Collection.init();
    c.load_options = .{ .library = lib };

    _ = try c.add(alloc, .regular, .{ .loaded = try .init(
        lib,
        testFont,
        .{ .size = .{ .points = 12, .xdpi = 96, .ydpi = 96 } },
    ) });
    _ = try c.add(alloc, .bold, .{ .loaded = try .init(
        lib,
        testFont,
        .{ .size = .{ .points = 12, .xdpi = 96, .ydpi = 96 } },
    ) });
    _ = try c.add(alloc, .italic, .{ .loaded = try .init(
        lib,
        testFont,
        .{ .size = .{ .points = 12, .xdpi = 96, .ydpi = 96 } },
    ) });

    var r: CodepointResolver = .{ .collection = c };
    defer r.deinit(alloc);
    r.styles.set(.bold, false); // Disable bold

    // Regular should work fine
    {
        const idx = r.getIndex(alloc, 'A', .regular, null).?;
        try testing.expectEqual(Style.regular, idx.style);
        try testing.expectEqual(@as(Collection.Index.IndexInt, 0), idx.idx);
    }

    // Bold should go to regular
    {
        const idx = r.getIndex(alloc, 'A', .bold, null).?;
        try testing.expectEqual(Style.regular, idx.style);
        try testing.expectEqual(@as(Collection.Index.IndexInt, 0), idx.idx);
    }

    // Italic should still work
    {
        const idx = r.getIndex(alloc, 'A', .italic, null).?;
        try testing.expectEqual(Style.italic, idx.style);
        try testing.expectEqual(@as(Collection.Index.IndexInt, 0), idx.idx);
    }
}

test "getIndex box glyph" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var lib = try Library.init(alloc);
    defer lib.deinit();

    const c = Collection.init();

    var r: CodepointResolver = .{
        .collection = c,
        .sprite = .{
            .metrics = font.Metrics.calc(.{
                .cell_width = 18.0,
                .ascent = 30.0,
                .descent = -6.0,
                .line_gap = 0.0,
            }),
        },
    };
    defer r.deinit(alloc);

    // Should find a box glyph
    const idx = r.getIndex(alloc, 0x2500, .regular, null).?;
    try testing.expectEqual(Style.regular, idx.style);
    try testing.expectEqual(@intFromEnum(Collection.Index.Special.sprite), idx.idx);
}
