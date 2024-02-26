//! A font group is a a set of multiple font faces of potentially different
//! styles that are used together to find glyphs. They usually share sizing
//! properties so that they can be used interchangeably with each other in cases
//! a codepoint doesn't map cleanly. For example, if a user requests a bold
//! char and it doesn't exist we can fallback to a regular non-bold char so
//! we show SOMETHING.
//!
//! Note this is made specifically for terminals so it has some features
//! that aren't generally helpful, such as detecting and drawing the terminal
//! box glyphs and requiring cell sizes for such glyphs.
const Group = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ziglyph = @import("ziglyph");

const font = @import("main.zig");
const DeferredFace = @import("main.zig").DeferredFace;
const Face = @import("main.zig").Face;
const Library = @import("main.zig").Library;
const Glyph = @import("main.zig").Glyph;
const Style = @import("main.zig").Style;
const Presentation = @import("main.zig").Presentation;
const options = @import("main.zig").options;
const quirks = @import("../quirks.zig");

const log = std.log.scoped(.font_group);

/// Packed array to map our styles to a set of faces.
// Note: this is not the most efficient way to store these, but there is
// usually only one font group for the entire process so this isn't the
// most important memory efficiency we can look for. This is totally opaque
// to the user so we can change this later.
const StyleArray = std.EnumArray(Style, std.ArrayListUnmanaged(GroupFace));

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
    font.discovery.Descriptor,
    ?FontIndex,
    struct {
        const KeyType = font.discovery.Descriptor;

        pub fn hash(ctx: @This(), k: KeyType) u64 {
            _ = ctx;
            return k.hash();
        }

        pub fn eql(ctx: @This(), a: KeyType, b: KeyType) bool {
            return ctx.hash(a) == ctx.hash(b);
        }
    },
    std.hash_map.default_max_load_percentage,
);

/// The requested presentation for a codepoint.
const PresentationMode = union(enum) {
    /// The codepoint has an explicit presentation that is required,
    /// i.e. VS15/V16.
    explicit: Presentation,

    /// The codepoint has no explicit presentation and we should use
    /// the presentation from the UCd.
    default: Presentation,

    /// The codepoint can be any presentation.
    any: void,
};

/// The allocator for this group
alloc: Allocator,

/// The library being used for all the faces.
lib: Library,

/// The desired font size. All fonts in a group must share the same size.
size: font.face.DesiredSize,

/// Metric modifiers to apply to loaded fonts. The Group takes ownership
/// over the memory and will use the associated allocator to free it.
metric_modifiers: ?font.face.Metrics.ModifierSet = null,

/// The available faces we have. This shouldn't be modified manually.
/// Instead, use the functions available on Group.
faces: StyleArray,

/// The set of statuses and whether they're enabled or not. This defaults
/// to true. This can be changed at runtime with no ill effect. If you
/// change this at runtime and are using a GroupCache, the GroupCache
/// must be reset.
styles: StyleStatus = StyleStatus.initFill(true),

/// If discovery is available, we'll look up fonts where we can't find
/// the codepoint. This can be set after initialization.
discover: ?*font.Discover = null,

/// A map of codepoints to font requests for codepoint-level overrides.
/// The memory associated with the map is owned by the caller and is not
/// modified or freed by Group.
codepoint_map: ?font.CodepointMap = null,

/// The descriptor cache is used to cache the descriptor to font face
/// mapping for codepoint maps.
descriptor_cache: DescriptorCache = .{},

/// Set this to a non-null value to enable sprite glyph drawing. If this
/// isn't enabled we'll just fall through to trying to use regular fonts
/// to render sprite glyphs. But more than likely, if this isn't set then
/// terminal rendering will look wrong.
sprite: ?font.sprite.Face = null,

/// A face in a group can be deferred or loaded. A deferred face
/// is not yet fully loaded and only represents the font descriptor
/// and usually uses less resources. A loaded face is fully parsed,
/// ready to rasterize, and usually uses more resources than a
/// deferred version.
///
/// A face can also be a "fallback" variant that is still either
/// deferred or loaded. Today, there is only one different between
/// fallback and non-fallback (or "explicit") faces: the handling
/// of emoji presentation.
///
/// For explicit faces, when an explicit emoji presentation is
/// not requested, we will use any glyph for that codepoint found
/// even if the font presentation does not match the UCD
/// (Unicode Character Database) value. When an explicit presentation
/// is requested (via either VS15/V16), that is always honored.
/// The reason we do this is because we assume that if a user
/// explicitly chosen a font face (hence it is "explicit" and
/// not "fallback"), they want to use any glyphs possible within that
/// font face. Fallback fonts on the other hand are picked as a
/// last resort, so we should prefer exactness if possible.
pub const GroupFace = union(enum) {
    deferred: DeferredFace, // Not loaded
    loaded: Face, // Loaded, explicit use

    // The same as deferred/loaded but fallback font semantics (see large
    // comment above GroupFace).
    fallback_deferred: DeferredFace,
    fallback_loaded: Face,

    pub fn deinit(self: *GroupFace) void {
        switch (self.*) {
            inline .deferred,
            .loaded,
            .fallback_deferred,
            .fallback_loaded,
            => |*v| v.deinit(),
        }
    }

    /// True if this face satisfies the given codepoint and presentation.
    fn hasCodepoint(self: GroupFace, cp: u32, p_mode: PresentationMode) bool {
        return switch (self) {
            // Non-fallback fonts require explicit presentation matching but
            // otherwise don't care about presentation
            .deferred => |v| switch (p_mode) {
                .explicit => |p| v.hasCodepoint(cp, p),
                .default, .any => v.hasCodepoint(cp, null),
            },

            .loaded => |face| switch (p_mode) {
                .explicit => |p| face.presentation == p and face.glyphIndex(cp) != null,
                .default, .any => face.glyphIndex(cp) != null,
            },

            // Fallback fonts require exact presentation matching.
            .fallback_deferred => |v| switch (p_mode) {
                .explicit, .default => |p| v.hasCodepoint(cp, p),
                .any => v.hasCodepoint(cp, null),
            },

            .fallback_loaded => |face| switch (p_mode) {
                .explicit,
                .default,
                => |p| face.presentation == p and face.glyphIndex(cp) != null,
                .any => face.glyphIndex(cp) != null,
            },
        };
    }
};

pub fn init(
    alloc: Allocator,
    lib: Library,
    size: font.face.DesiredSize,
) !Group {
    var result = Group{ .alloc = alloc, .lib = lib, .size = size, .faces = undefined };

    // Initialize all our styles to initially sized lists.
    var i: usize = 0;
    while (i < StyleArray.len) : (i += 1) {
        result.faces.values[i] = .{};
        try result.faces.values[i].ensureTotalCapacityPrecise(alloc, 2);
    }

    return result;
}

pub fn deinit(self: *Group) void {
    {
        var it = self.faces.iterator();
        while (it.next()) |entry| {
            for (entry.value.items) |*item| item.deinit();
            entry.value.deinit(self.alloc);
        }
    }

    if (self.metric_modifiers) |*v| v.deinit(self.alloc);

    self.descriptor_cache.deinit(self.alloc);
}

/// Returns the options for initializing a face based on the options associated
/// with this font group.
pub fn faceOptions(self: *const Group) font.face.Options {
    return .{
        .size = self.size,
        .metric_modifiers = if (self.metric_modifiers) |*v| v else null,
    };
}

/// Add a face to the list for the given style. This face will be added as
/// next in priority if others exist already, i.e. it'll be the _last_ to be
/// searched for a glyph in that list.
///
/// The group takes ownership of the face. The face will be deallocated when
/// the group is deallocated.
pub fn addFace(self: *Group, style: Style, face: GroupFace) !FontIndex {
    const list = self.faces.getPtr(style);

    // We have some special indexes so we must never pass those.
    if (list.items.len >= FontIndex.Special.start - 1) return error.GroupFull;

    const idx = list.items.len;
    try list.append(self.alloc, face);
    return .{ .style = style, .idx = @intCast(idx) };
}

/// This will automatically create an italicized font from the regular
/// font face if we don't have any italicized fonts.
pub fn italicize(self: *Group) !void {
    // If we have an italic font, do nothing.
    const italic_list = self.faces.getPtr(.italic);
    if (italic_list.items.len > 0) return;

    // Not all font backends support auto-italicization.
    if (comptime !@hasDecl(Face, "italicize")) {
        log.warn("no italic font face available, italics will not render", .{});
        return;
    }

    // Our regular font. If we have no regular font we also do nothing.
    const regular = regular: {
        const list = self.faces.get(.regular);
        if (list.items.len == 0) return;

        // Find our first font that is text.
        for (0..list.items.len) |i| {
            const face = try self.faceFromIndex(.{
                .style = .regular,
                .idx = @intCast(i),
            });
            if (face.presentation == .text) break :regular face;
        }

        return;
    };

    // Try to italicize it.
    const face = try regular.italicize(self.faceOptions());
    try italic_list.append(self.alloc, .{ .loaded = face });

    var buf: [128]u8 = undefined;
    if (face.name(&buf)) |name| {
        log.info("font auto-italicized: {s}", .{name});
    } else |_| {}
}

/// Resize the fonts to the desired size.
pub fn setSize(self: *Group, size: font.face.DesiredSize) !void {
    // Note: there are some issues here with partial failure. We don't
    // currently handle it in any meaningful way if one face can resize
    // but another can't.

    // Set our size for future loads
    self.size = size;

    // Resize all our faces that are loaded
    var it = self.faces.iterator();
    while (it.next()) |entry| {
        for (entry.value.items) |*elem| switch (elem.*) {
            .deferred, .fallback_deferred => continue,
            .loaded, .fallback_loaded => |*f| try f.setSize(self.faceOptions()),
        };
    }
}

/// This represents a specific font in the group.
pub const FontIndex = packed struct(FontIndex.Backing) {
    const Backing = u16;
    const backing_bits = @typeInfo(Backing).Int.bits;

    /// The number of bits we use for the index.
    const idx_bits = backing_bits - @typeInfo(@typeInfo(Style).Enum.tag_type).Int.bits;
    pub const IndexInt = @Type(.{ .Int = .{ .signedness = .unsigned, .bits = idx_bits } });

    /// The special-case fonts that we support.
    pub const Special = enum(IndexInt) {
        // We start all special fonts at this index so they can be detected.
        pub const start = std.math.maxInt(IndexInt);

        /// Sprite drawing, this is rendered JIT using 2D graphics APIs.
        sprite = start,
    };

    style: Style = .regular,
    idx: IndexInt = 0,

    /// Initialize a special font index.
    pub fn initSpecial(v: Special) FontIndex {
        return .{ .style = .regular, .idx = @intFromEnum(v) };
    }

    /// Convert to int
    pub fn int(self: FontIndex) Backing {
        return @bitCast(self);
    }

    /// Returns true if this is a "special" index which doesn't map to
    /// a real font face. We can still render it but there is no face for
    /// this font.
    pub fn special(self: FontIndex) ?Special {
        if (self.idx < Special.start) return null;
        return @enumFromInt(self.idx);
    }

    test {
        // We never want to take up more than a byte since font indexes are
        // everywhere so if we increase the size of this we'll dramatically
        // increase our memory usage.
        try std.testing.expectEqual(@sizeOf(Backing), @sizeOf(FontIndex));

        // Just so we're aware when this changes. The current maximum number
        // of fonts for a style is 13 bits or 8192 fonts.
        try std.testing.expectEqual(13, idx_bits);
    }
};

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
pub fn indexForCodepoint(
    self: *Group,
    cp: u32,
    style: Style,
    p: ?Presentation,
) ?FontIndex {
    // If we've disabled a font style, then fall back to regular.
    if (style != .regular and !self.styles.get(style)) {
        return self.indexForCodepoint(cp, .regular, p);
    }

    // Codepoint overrides.
    if (self.indexForCodepointOverride(cp)) |idx_| {
        if (idx_) |idx| return idx;
    } else |err| {
        log.warn("codepoint override failed codepoint={} err={}", .{ cp, err });
    }

    // If we have sprite drawing enabled, check if our sprite face can
    // handle this.
    if (self.sprite) |sprite| {
        if (sprite.hasCodepoint(cp, p)) {
            return FontIndex.initSpecial(.sprite);
        }
    }

    // Build our presentation mode. If we don't have an explicit presentation
    // given then we use the UCD (Unicode Character Database) to determine
    // the default presentation. Note there is some inefficiency here because
    // we'll do this muliple times if we recurse, but this is a cached function
    // call higher up (GroupCache) so this should be rare.
    const p_mode: PresentationMode = if (p) |v| .{ .explicit = v } else .{
        .default = if (ziglyph.emoji.isEmojiPresentation(@intCast(cp)))
            .emoji
        else
            .text,
    };

    // If we can find the exact value, then return that.
    if (self.indexForCodepointExact(cp, style, p_mode)) |value| return value;

    // If we're not a regular font style, try looking for a regular font
    // that will satisfy this request. Blindly looking for unmatched styled
    // fonts to satisfy one codepoint results in some ugly rendering.
    if (style != .regular) {
        if (self.indexForCodepoint(cp, .regular, p)) |value| return value;
    }

    // If we are regular, try looking for a fallback using discovery.
    if (style == .regular and font.Discover != void) {
        log.debug("searching for a fallback font for cp={x}", .{cp});
        if (self.discover) |disco| discover: {
            var disco_it = disco.discover(self.alloc, .{
                .codepoint = cp,
                .size = self.size.points,
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
                const face: GroupFace = .{ .fallback_deferred = deferred_face };
                if (!face.hasCodepoint(cp, p_mode)) {
                    deferred_face.deinit();
                    continue;
                }

                var buf: [256]u8 = undefined;
                log.info("found codepoint 0x{x} in fallback face={s}", .{
                    cp,
                    deferred_face.name(&buf) catch "<error>",
                });
                return self.addFace(style, face) catch {
                    deferred_face.deinit();
                    break :discover;
                };
            }

            log.debug("no fallback face found for cp={x}", .{cp});
        }
    }

    // If this is already regular, we're done falling back.
    if (style == .regular and p == null) return null;

    // For non-regular fonts, we fall back to regular with any presentation
    return self.indexForCodepointExact(cp, .regular, .{ .any = {} });
}

fn indexForCodepointExact(
    self: Group,
    cp: u32,
    style: Style,
    p_mode: PresentationMode,
) ?FontIndex {
    for (self.faces.get(style).items, 0..) |elem, i| {
        if (elem.hasCodepoint(cp, p_mode)) {
            return FontIndex{
                .style = style,
                .idx = @intCast(i),
            };
        }
    }

    // Not found
    return null;
}

/// Checks if the codepoint is in the map of codepoint overrides,
/// finds the override font, and returns it.
fn indexForCodepointOverride(self: *Group, cp: u32) !?FontIndex {
    if (comptime font.Discover == void) return null;
    const map = self.codepoint_map orelse return null;

    // If we have a codepoint too large or isn't in the map, then we
    // don't have an override.
    const cp_u21 = std.math.cast(u21, cp) orelse return null;
    const desc = map.get(cp_u21) orelse return null;

    // Fast path: the descriptor is already loaded.
    const idx_: ?FontIndex = self.descriptor_cache.get(desc) orelse idx: {
        // Slow path: we have to find this descriptor and load the font
        const discover = self.discover orelse return null;
        var disco_it = try discover.discover(self.alloc, desc);
        defer disco_it.deinit();

        const face = (try disco_it.next()) orelse {
            log.warn(
                "font lookup for codepoint map failed codepoint={} err=FontNotFound",
                .{cp},
            );

            // Add null to the cache so we don't do a lookup again later.
            try self.descriptor_cache.put(self.alloc, desc, null);
            return null;
        };

        // Add the font to our list of fonts so we can get an index for it,
        // and ensure the index is stored in the descriptor cache for next time.
        const idx = try self.addFace(.regular, .{ .deferred = face });
        try self.descriptor_cache.put(self.alloc, desc, idx);

        break :idx idx;
    };

    // The descriptor cache will populate null if the descriptor is not found
    // to avoid expensive discoveries later.
    const idx = idx_ orelse return null;

    // We need to verify that this index has the codepoint we want.
    if (self.hasCodepoint(idx, cp, null)) {
        log.debug("codepoint override based on config codepoint={} family={s}", .{
            cp,
            desc.family orelse "",
        });

        return idx;
    }

    return null;
}

/// Check if a specific font index has a specific codepoint. This does not
/// necessarily force the font to load. The presentation value "p" will
/// verify the Emoji representation matches if it is non-null. If "p" is
/// null then any presentation will be accepted.
pub fn hasCodepoint(self: *Group, index: FontIndex, cp: u32, p: ?Presentation) bool {
    const list = self.faces.getPtr(index.style);
    if (index.idx >= list.items.len) return false;
    return list.items[index.idx].hasCodepoint(
        cp,
        if (p) |v| .{ .explicit = v } else .{ .any = {} },
    );
}

/// Returns the presentation for a specific font index. This is useful for
/// determining what atlas is needed.
pub fn presentationFromIndex(self: *Group, index: FontIndex) !font.Presentation {
    if (index.special()) |sp| switch (sp) {
        .sprite => return .text,
    };

    const face = try self.faceFromIndex(index);
    return face.presentation;
}

/// Return the Face represented by a given FontIndex. Note that special
/// fonts (i.e. box glyphs) do not have a face. The returned face pointer is
/// only valid until the set of faces change.
pub fn faceFromIndex(self: *Group, index: FontIndex) !*Face {
    if (index.special() != null) return error.SpecialHasNoFace;
    const list = self.faces.getPtr(index.style);
    const item = &list.items[index.idx];
    return switch (item.*) {
        inline .deferred, .fallback_deferred => |*d, tag| deferred: {
            const face = try d.load(self.lib, self.faceOptions());
            d.deinit();
            item.* = switch (tag) {
                .deferred => .{ .loaded = face },
                .fallback_deferred => .{ .fallback_loaded = face },
                else => unreachable,
            };

            break :deferred switch (tag) {
                .deferred => &item.loaded,
                .fallback_deferred => &item.fallback_loaded,
                else => unreachable,
            };
        },

        .loaded, .fallback_loaded => |*f| f,
    };
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
    self: *Group,
    alloc: Allocator,
    atlas: *font.Atlas,
    index: FontIndex,
    glyph_index: u32,
    opts: font.face.RenderOptions,
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

    const face = try self.faceFromIndex(index);
    const glyph = try face.renderGlyph(alloc, atlas, glyph_index, opts);
    // log.warn("GLYPH={}", .{glyph});
    return glyph;
}

/// The wasm-compatible API.
pub const Wasm = struct {
    const wasm = @import("../os/wasm.zig");
    const alloc = wasm.alloc;

    export fn group_new(pts: u16) ?*Group {
        return group_new_(pts) catch null;
    }

    fn group_new_(pts: u16) !*Group {
        var group = try Group.init(alloc, .{}, .{ .points = pts });
        errdefer group.deinit();

        const result = try alloc.create(Group);
        errdefer alloc.destroy(result);
        result.* = group;
        return result;
    }

    export fn group_free(ptr: ?*Group) void {
        if (ptr) |v| {
            v.deinit();
            alloc.destroy(v);
        }
    }

    export fn group_init_sprite_face(self: *Group) void {
        return group_init_sprite_face_(self) catch |err| {
            log.warn("error initializing sprite face err={}", .{err});
            return;
        };
    }

    fn group_init_sprite_face_(self: *Group) !void {
        const metrics = metrics: {
            const index = self.indexForCodepoint('M', .regular, .text).?;
            const face = try self.faceFromIndex(index);
            break :metrics face.metrics;
        };

        // Set details for our sprite font
        self.sprite = font.sprite.Face{
            .width = metrics.cell_width,
            .height = metrics.cell_height,
            .thickness = 2,
            .cursor_thickness_adjustment = 0,
            .underline_position = metrics.underline_position,
        };
    }

    export fn group_add_face(self: *Group, style: u16, face: *font.DeferredFace) void {
        return self.addFace(@enumFromInt(style), face.*) catch |err| {
            log.warn("error adding face to group err={}", .{err});
            return;
        };
    }

    export fn group_set_size(self: *Group, size: u16) void {
        return self.setSize(.{ .points = size }) catch |err| {
            log.warn("error setting group size err={}", .{err});
            return;
        };
    }

    /// Presentation is negative for doesn't matter.
    export fn group_index_for_codepoint(self: *Group, cp: u32, style: u16, p: i16) i16 {
        const presentation: ?Presentation = if (p < 0) null else @enumFromInt(p);
        const idx = self.indexForCodepoint(
            cp,
            @enumFromInt(style),
            presentation,
        ) orelse return -1;
        return @intCast(@as(u8, @bitCast(idx)));
    }

    export fn group_render_glyph(
        self: *Group,
        atlas: *font.Atlas,
        idx: i16,
        cp: u32,
        max_height: u16,
    ) ?*Glyph {
        return group_render_glyph_(self, atlas, idx, cp, max_height) catch |err| {
            log.warn("error rendering group glyph err={}", .{err});
            return null;
        };
    }

    fn group_render_glyph_(
        self: *Group,
        atlas: *font.Atlas,
        idx_: i16,
        cp: u32,
        max_height_: u16,
    ) !*Glyph {
        const idx = @as(FontIndex, @bitCast(@as(u8, @intCast(idx_))));
        const max_height = if (max_height_ <= 0) null else max_height_;
        const glyph = try self.renderGlyph(alloc, atlas, idx, cp, .{
            .max_height = max_height,
        });

        const result = try alloc.create(Glyph);
        errdefer alloc.destroy(result);
        result.* = glyph;
        return result;
    }
};

test {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = @import("test.zig").fontRegular;
    const testEmoji = @import("test.zig").fontEmoji;
    const testEmojiText = @import("test.zig").fontEmojiText;

    var atlas_greyscale = try font.Atlas.init(alloc, 512, .greyscale);
    defer atlas_greyscale.deinit(alloc);

    var lib = try Library.init();
    defer lib.deinit();

    var group = try init(alloc, lib, .{ .points = 12 });
    defer group.deinit();

    _ = try group.addFace(
        .regular,
        .{ .loaded = try Face.init(lib, testFont, .{ .size = .{ .points = 12 } }) },
    );

    if (font.options.backend != .coretext) {
        // Coretext doesn't support Noto's format
        _ = try group.addFace(
            .regular,
            .{ .loaded = try Face.init(lib, testEmoji, .{ .size = .{ .points = 12 } }) },
        );
    }
    _ = try group.addFace(
        .regular,
        .{ .loaded = try Face.init(lib, testEmojiText, .{ .size = .{ .points = 12 } }) },
    );

    // Should find all visible ASCII
    var i: u32 = 32;
    while (i < 127) : (i += 1) {
        const idx = group.indexForCodepoint(i, .regular, null).?;
        try testing.expectEqual(Style.regular, idx.style);
        try testing.expectEqual(@as(FontIndex.IndexInt, 0), idx.idx);

        // Render it
        const face = try group.faceFromIndex(idx);
        const glyph_index = face.glyphIndex(i).?;
        _ = try group.renderGlyph(
            alloc,
            &atlas_greyscale,
            idx,
            glyph_index,
            .{},
        );
    }

    // Try emoji
    {
        const idx = group.indexForCodepoint('🥸', .regular, null).?;
        try testing.expectEqual(Style.regular, idx.style);
        try testing.expectEqual(@as(FontIndex.IndexInt, 1), idx.idx);
    }

    // Try text emoji
    {
        const idx = group.indexForCodepoint(0x270C, .regular, .text).?;
        try testing.expectEqual(Style.regular, idx.style);
        const text_idx = if (font.options.backend == .coretext) 1 else 2;
        try testing.expectEqual(@as(FontIndex.IndexInt, text_idx), idx.idx);
    }
    {
        const idx = group.indexForCodepoint(0x270C, .regular, .emoji).?;
        try testing.expectEqual(Style.regular, idx.style);
        try testing.expectEqual(@as(FontIndex.IndexInt, 1), idx.idx);
    }

    // Box glyph should be null since we didn't set a box font
    {
        try testing.expect(group.indexForCodepoint(0x1FB00, .regular, null) == null);
    }
}

test "disabled font style" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = @import("test.zig").fontRegular;

    var atlas_greyscale = try font.Atlas.init(alloc, 512, .greyscale);
    defer atlas_greyscale.deinit(alloc);

    var lib = try Library.init();
    defer lib.deinit();

    var group = try init(alloc, lib, .{ .points = 12 });
    defer group.deinit();

    // Disable bold
    group.styles.set(.bold, false);

    // Same font but we can test the style in the index
    const opts: font.face.Options = .{ .size = .{ .points = 12 } };
    _ = try group.addFace(.regular, .{ .loaded = try Face.init(lib, testFont, opts) });
    _ = try group.addFace(.bold, .{ .loaded = try Face.init(lib, testFont, opts) });
    _ = try group.addFace(.italic, .{ .loaded = try Face.init(lib, testFont, opts) });

    // Regular should work fine
    {
        const idx = group.indexForCodepoint('A', .regular, null).?;
        try testing.expectEqual(Style.regular, idx.style);
        try testing.expectEqual(@as(FontIndex.IndexInt, 0), idx.idx);
    }

    // Bold should go to regular
    {
        const idx = group.indexForCodepoint('A', .bold, null).?;
        try testing.expectEqual(Style.regular, idx.style);
        try testing.expectEqual(@as(FontIndex.IndexInt, 0), idx.idx);
    }

    // Italic should still work
    {
        const idx = group.indexForCodepoint('A', .italic, null).?;
        try testing.expectEqual(Style.italic, idx.style);
        try testing.expectEqual(@as(FontIndex.IndexInt, 0), idx.idx);
    }
}

test "face count limit" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = @import("test.zig").fontRegular;

    var atlas_greyscale = try font.Atlas.init(alloc, 512, .greyscale);
    defer atlas_greyscale.deinit(alloc);

    var lib = try Library.init();
    defer lib.deinit();

    const opts: font.face.Options = .{ .size = .{ .points = 12 } };
    var group = try init(alloc, lib, opts.size);
    defer group.deinit();

    for (0..FontIndex.Special.start - 1) |_| {
        _ = try group.addFace(.regular, .{ .loaded = try Face.init(lib, testFont, opts) });
    }

    try testing.expectError(error.GroupFull, group.addFace(
        .regular,
        .{ .loaded = try Face.init(lib, testFont, opts) },
    ));
}

test "box glyph" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var atlas_greyscale = try font.Atlas.init(alloc, 512, .greyscale);
    defer atlas_greyscale.deinit(alloc);

    var lib = try Library.init();
    defer lib.deinit();

    var group = try init(alloc, lib, .{ .points = 12 });
    defer group.deinit();

    // Set box font
    group.sprite = font.sprite.Face{
        .width = 18,
        .height = 36,
        .thickness = 2,
        .cursor_thickness_adjustment = 0,
    };

    // Should find a box glyph
    const idx = group.indexForCodepoint(0x2500, .regular, null).?;
    try testing.expectEqual(Style.regular, idx.style);
    try testing.expectEqual(@intFromEnum(FontIndex.Special.sprite), idx.idx);

    // Should render it
    const glyph = try group.renderGlyph(
        alloc,
        &atlas_greyscale,
        idx,
        0x2500,
        .{},
    );
    try testing.expectEqual(@as(u32, 36), glyph.height);
}

test "resize" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = @import("test.zig").fontRegular;

    var atlas_greyscale = try font.Atlas.init(alloc, 512, .greyscale);
    defer atlas_greyscale.deinit(alloc);

    var lib = try Library.init();
    defer lib.deinit();

    var group = try init(alloc, lib, .{ .points = 12, .xdpi = 96, .ydpi = 96 });
    defer group.deinit();

    _ = try group.addFace(.regular, .{ .loaded = try Face.init(
        lib,
        testFont,
        .{ .size = .{ .points = 12, .xdpi = 96, .ydpi = 96 } },
    ) });

    // Load a letter
    {
        const idx = group.indexForCodepoint('A', .regular, null).?;
        const face = try group.faceFromIndex(idx);
        const glyph_index = face.glyphIndex('A').?;
        const glyph = try group.renderGlyph(
            alloc,
            &atlas_greyscale,
            idx,
            glyph_index,
            .{},
        );

        try testing.expectEqual(@as(u32, 11), glyph.height);
    }

    // Resize
    try group.setSize(.{ .points = 24, .xdpi = 96, .ydpi = 96 });
    {
        const idx = group.indexForCodepoint('A', .regular, null).?;
        const face = try group.faceFromIndex(idx);
        const glyph_index = face.glyphIndex('A').?;
        const glyph = try group.renderGlyph(
            alloc,
            &atlas_greyscale,
            idx,
            glyph_index,
            .{},
        );

        try testing.expectEqual(@as(u32, 21), glyph.height);
    }
}

test "discover monospace with fontconfig and freetype" {
    if (options.backend != .fontconfig_freetype) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const Discover = @import("main.zig").Discover;

    // Search for fonts
    var fc = Discover.init();
    var it = try fc.discover(alloc, .{ .family = "monospace", .size = 12 });
    defer it.deinit();

    // Initialize the group with the deferred face
    var lib = try Library.init();
    defer lib.deinit();
    var group = try init(alloc, lib, .{ .points = 12 });
    defer group.deinit();
    _ = try group.addFace(.regular, .{ .deferred = (try it.next()).? });

    // Should find all visible ASCII
    var atlas_greyscale = try font.Atlas.init(alloc, 512, .greyscale);
    defer atlas_greyscale.deinit(alloc);
    var i: u32 = 32;
    while (i < 127) : (i += 1) {
        const idx = group.indexForCodepoint(i, .regular, null).?;
        try testing.expectEqual(Style.regular, idx.style);
        try testing.expectEqual(@as(FontIndex.IndexInt, 0), idx.idx);

        // Render it
        const face = try group.faceFromIndex(idx);
        const glyph_index = face.glyphIndex(i).?;
        _ = try group.renderGlyph(
            alloc,
            &atlas_greyscale,
            idx,
            glyph_index,
            .{},
        );
    }
}

test "faceFromIndex returns pointer" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = @import("test.zig").fontRegular;

    var atlas_greyscale = try font.Atlas.init(alloc, 512, .greyscale);
    defer atlas_greyscale.deinit(alloc);

    var lib = try Library.init();
    defer lib.deinit();

    var group = try init(alloc, lib, .{ .points = 12, .xdpi = 96, .ydpi = 96 });
    defer group.deinit();

    _ = try group.addFace(.regular, .{ .loaded = try Face.init(
        lib,
        testFont,
        .{ .size = .{ .points = 12, .xdpi = 96, .ydpi = 96 } },
    ) });

    {
        const idx = group.indexForCodepoint('A', .regular, null).?;
        const face1 = try group.faceFromIndex(idx);
        const face2 = try group.faceFromIndex(idx);
        try testing.expectEqual(@intFromPtr(face1), @intFromPtr(face2));
    }
}

test "indexFromCodepoint: prefer emoji in non-fallback font" {
    // CoreText can't load Noto
    if (font.options.backend == .coretext) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const testCozette = @import("test.zig").fontCozette;
    const testEmoji = @import("test.zig").fontEmoji;

    var atlas_greyscale = try font.Atlas.init(alloc, 512, .greyscale);
    defer atlas_greyscale.deinit(alloc);

    var lib = try Library.init();
    defer lib.deinit();

    var group = try init(alloc, lib, .{ .points = 12 });
    defer group.deinit();

    _ = try group.addFace(
        .regular,
        .{ .loaded = try Face.init(
            lib,
            testCozette,
            .{ .size = .{ .points = 12 } },
        ) },
    );
    _ = try group.addFace(
        .regular,
        .{ .fallback_loaded = try Face.init(
            lib,
            testEmoji,
            .{ .size = .{ .points = 12 } },
        ) },
    );

    // The "alien" emoji is default emoji presentation but present
    // in Cozette as text. Since Cozette isn't a fallback, we shoulod
    // load it from there.
    {
        const idx = group.indexForCodepoint(0x1F47D, .regular, null).?;
        try testing.expectEqual(Style.regular, idx.style);
        try testing.expectEqual(@as(FontIndex.IndexInt, 0), idx.idx);
    }

    // If we specifically request emoji, we should find it in the fallback.
    {
        const idx = group.indexForCodepoint(0x1F47D, .regular, .emoji).?;
        try testing.expectEqual(Style.regular, idx.style);
        try testing.expectEqual(@as(FontIndex.IndexInt, 1), idx.idx);
    }
}

test "indexFromCodepoint: prefer emoji with correct presentation" {
    // CoreText can't load Noto
    if (font.options.backend == .coretext) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const testCozette = @import("test.zig").fontCozette;
    const testEmoji = @import("test.zig").fontEmoji;

    var atlas_greyscale = try font.Atlas.init(alloc, 512, .greyscale);
    defer atlas_greyscale.deinit(alloc);

    var lib = try Library.init();
    defer lib.deinit();

    var group = try init(alloc, lib, .{ .points = 12 });
    defer group.deinit();

    _ = try group.addFace(
        .regular,
        .{ .loaded = try Face.init(
            lib,
            testEmoji,
            .{ .size = .{ .points = 12 } },
        ) },
    );
    _ = try group.addFace(
        .regular,
        .{ .loaded = try Face.init(
            lib,
            testCozette,
            .{ .size = .{ .points = 12 } },
        ) },
    );

    // Check that we check the default presentation
    {
        const idx = group.indexForCodepoint(0x1F47D, .regular, null).?;
        try testing.expectEqual(Style.regular, idx.style);
        try testing.expectEqual(@as(FontIndex.IndexInt, 0), idx.idx);
    }

    // If we specifically request text
    {
        const idx = group.indexForCodepoint(0x1F47D, .regular, .text).?;
        try testing.expectEqual(Style.regular, idx.style);
        try testing.expectEqual(@as(FontIndex.IndexInt, 1), idx.idx);
    }
}
