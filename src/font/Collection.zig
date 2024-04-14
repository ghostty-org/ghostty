//! A font collection is a list of faces of different styles. The list is
//! ordered by priority (per style). All fonts in a collection share the same
//! size so they can be used interchangeably in cases a glyph is missing in one
//! and present in another.
//!
//! The purpose of a collection is to store a list of fonts by style
//! and priority order. A collection does not handle searching for font
//! callbacks, rasterization, etc. For this, see CodepointResolver.
//!
//! The collection can contain both loaded and deferred faces. Deferred faces
//! typically use less memory while still providing some necessary information
//! such as codepoint support, presentation, etc. This is useful for looking
//! for fallback fonts as efficiently as possible. For example, when the glyph
//! "X" is not found, we can quickly search through deferred fonts rather
//! than loading the font completely.
const Collection = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const font = @import("main.zig");
const options = font.options;
const DeferredFace = font.DeferredFace;
const DesiredSize = font.face.DesiredSize;
const Face = font.Face;
const Library = font.Library;
const Metrics = font.face.Metrics;
const Presentation = font.Presentation;
const Style = font.Style;

const log = std.log.scoped(.font_collection);

/// The available faces we have. This shouldn't be modified manually.
/// Instead, use the functions available on Collection.
faces: StyleArray,

/// The load options for deferred faces in the face list. If this
/// is not set, then deferred faces will not be loaded. Attempting to
/// add a deferred face will result in an error.
load_options: ?LoadOptions = null,

/// Initialize an empty collection.
pub fn init(
    alloc: Allocator,
) !Collection {
    // Initialize our styles array, preallocating some space that is
    // likely to be used.
    var faces = StyleArray.initFill(.{});
    for (&faces.values) |*v| try v.ensureTotalCapacityPrecise(alloc, 2);
    return .{ .faces = faces };
}

pub fn deinit(self: *Collection, alloc: Allocator) void {
    var it = self.faces.iterator();
    while (it.next()) |entry| {
        for (entry.value.items) |*item| item.deinit();
        entry.value.deinit(alloc);
    }

    if (self.load_options) |*v| v.deinit(alloc);
}

pub const AddError = Allocator.Error || error{
    CollectionFull,
    DeferredLoadingUnavailable,
};

pub const Wasm = struct {
    const wasm = @import("../os/wasm.zig");
    const alloc = wasm.alloc;

    export fn collection_new() ?*Collection {
        return collection_new_() catch null;
    }

    fn collection_new_() !*Collection {
        var collection = try Collection.init(alloc);
        errdefer collection.deinit(alloc);

        const result = try alloc.create(Collection);
        errdefer alloc.destroy(result);
        result.* = collection;
        return result;
    }

    export fn collection_add(self: *Collection, style: u16, face: *DeferredFace) void {
        _ = self.add(alloc, @enumFromInt(style), .{ .deferred = face.* }) catch |err| {
            log.warn("error adding face to collection err:{}", .{err});
            return;
        };
        return;
    }
};

/// Add a face to the collection for the given style. This face will be added
/// next in priority if others exist already, i.e. it'll be the _last_ to be
/// searched for a glyph in that list.
///
/// The collection takes ownership of the face. The face will be deallocated
/// when the collection is deallocated.
///
/// If a loaded face is added to the collection, it should be the same
/// size as all the other faces in the collection. This function will not
/// verify or modify the size until the size of the entire collection is
/// changed.
pub fn add(
    self: *Collection,
    alloc: Allocator,
    style: Style,
    face: Entry,
) AddError!Index {
    const list = self.faces.getPtr(style);

    // We have some special indexes so we must never pass those.
    if (list.items.len >= Index.Special.start - 1)
        return error.CollectionFull;

    // If this is deferred and we don't have load options, we can't.
    if (face.isDeferred() and self.load_options == null)
        return error.DeferredLoadingUnavailable;

    const idx = list.items.len;
    try list.append(alloc, face);
    return .{ .style = style, .idx = @intCast(idx) };
}

/// Return the Face represented by a given Index. The returned pointer
/// is only valid as long as this collection is not modified.
///
/// This will initialize the face if it is deferred and not yet loaded,
/// which can fail.
pub fn getFace(self: *Collection, index: Index) !*Face {
    if (index.special() != null) return error.SpecialHasNoFace;
    const list = self.faces.getPtr(index.style);
    const item = &list.items[index.idx];
    return switch (item.*) {
        inline .deferred, .fallback_deferred => |*d, tag| deferred: {
            const opts = self.load_options orelse
                return error.DeferredLoadingUnavailable;
            const face = try d.load(opts.library, opts.faceOptions());
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

/// Return the index of the font in this collection that contains
/// the given codepoint, style, and presentation. If no font is found,
/// null is returned.
///
/// This does not trigger font loading; deferred fonts can be
/// searched for codepoints.
pub fn getIndex(
    self: *const Collection,
    cp: u32,
    style: Style,
    p_mode: PresentationMode,
) ?Index {
    for (self.faces.get(style).items, 0..) |elem, i| {
        if (elem.hasCodepoint(cp, p_mode)) {
            return .{
                .style = style,
                .idx = @intCast(i),
            };
        }
    }

    // Not found
    return null;
}

/// Check if a specific font index has a specific codepoint. This does not
/// necessarily force the font to load. The presentation value "p" will
/// verify the Emoji representation matches if it is non-null. If "p" is
/// null then any presentation will be accepted.
pub fn hasCodepoint(
    self: *const Collection,
    index: Index,
    cp: u32,
    p_mode: PresentationMode,
) bool {
    const list = self.faces.get(index.style);
    if (index.idx >= list.items.len) return false;
    return list.items[index.idx].hasCodepoint(cp, p_mode);
}

/// Automatically create an italicized font from the regular
/// font face if we don't have one already. If we already have
/// an italicized font face, this does nothing.
pub fn autoItalicize(self: *Collection, alloc: Allocator) !void {
    // If we have an italic font, do nothing.
    const italic_list = self.faces.getPtr(.italic);
    if (italic_list.items.len > 0) return;

    // Not all font backends support auto-italicization.
    if (comptime !@hasDecl(Face, "italicize")) {
        log.warn(
            "no italic font face available, italics will not render",
            .{},
        );
        return;
    }

    // Our regular font. If we have no regular font we also do nothing.
    const regular = regular: {
        const list = self.faces.get(.regular);
        if (list.items.len == 0) return;

        // Find our first font that is text. This will force
        // loading any deferred faces but we only load them until
        // we find a text face. A text face is almost always the
        // first face in the list.
        for (0..list.items.len) |i| {
            const face = try self.getFace(.{
                .style = .regular,
                .idx = @intCast(i),
            });
            if (face.presentation == .text) break :regular face;
        }

        // No regular text face found.
        return;
    };

    // We require loading options to auto-italicize.
    const opts = self.load_options orelse return error.DeferredLoadingUnavailable;

    // Try to italicize it.
    const face = try regular.italicize(opts.faceOptions());
    try italic_list.append(alloc, .{ .loaded = face });

    var buf: [256]u8 = undefined;
    if (face.name(&buf)) |name| {
        log.info("font auto-italicized: {s}", .{name});
    } else |_| {}
}

/// Update the size of all faces in the collection. This will
/// also update the size in the load options for future deferred
/// face loading.
///
/// This requires load options to be set.
pub fn setSize(self: *Collection, size: DesiredSize) !void {
    // Get a pointer to our options so we can modify the size.
    const opts = if (self.load_options) |*v|
        v
    else
        return error.DeferredLoadingUnavailable;
    opts.size = size;

    // Resize all our faces that are loaded
    var it = self.faces.iterator();
    while (it.next()) |entry| {
        for (entry.value.items) |*elem| switch (elem.*) {
            .deferred, .fallback_deferred => continue,
            .loaded, .fallback_loaded => |*f| try f.setSize(
                opts.faceOptions(),
            ),
        };
    }
}

/// Packed array of all Style enum cases mapped to a growable list of faces.
///
/// We use this data structure because there aren't many styles and all
/// styles are typically loaded for a terminal session. The overhead per
/// style even if it is not used or barely used is minimal given the
/// small style count.
const StyleArray = std.EnumArray(Style, std.ArrayListUnmanaged(Entry));

/// Load options are used to configure all the details a Collection
/// needs to load deferred faces.
pub const LoadOptions = struct {
    /// The library to use for loading faces. This is not owned by
    /// the collection and can be used by multiple collections. When
    /// deinitializing the collection, the library is not deinitialized.
    library: Library,

    /// The desired font size for all loaded faces.
    size: DesiredSize = .{ .points = 12 },

    /// The metric modifiers to use for all loaded faces. The memory
    /// for this is owned by the user and is not freed by the collection.
    metric_modifiers: Metrics.ModifierSet = .{},

    pub fn deinit(self: *LoadOptions, alloc: Allocator) void {
        _ = self;
        _ = alloc;
    }

    /// The options to use for loading faces.
    pub fn faceOptions(self: *const LoadOptions) font.face.Options {
        return .{
            .size = self.size,
            .metric_modifiers = &self.metric_modifiers,
        };
    }
};

/// A entry in a collection can be deferred or loaded. A deferred face
/// is not yet fully loaded and only represents the font descriptor
/// and usually uses less resources. A loaded face is fully parsed,
/// ready to rasterize, and usually uses more resources than a
/// deferred version.
///
/// A face can also be a "fallback" variant that is still either
/// deferred or loaded. Today, there is only one difference between
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
pub const Entry = union(enum) {
    deferred: DeferredFace, // Not loaded
    loaded: Face, // Loaded, explicit use

    // The same as deferred/loaded but fallback font semantics (see large
    // comment above Entry).
    fallback_deferred: DeferredFace,
    fallback_loaded: Face,

    pub fn deinit(self: *Entry) void {
        switch (self.*) {
            inline .deferred,
            .loaded,
            .fallback_deferred,
            .fallback_loaded,
            => |*v| v.deinit(),
        }
    }

    /// True if the entry is deferred.
    fn isDeferred(self: Entry) bool {
        return switch (self) {
            .deferred, .fallback_deferred => true,
            .loaded, .fallback_loaded => false,
        };
    }

    /// True if this face satisfies the given codepoint and presentation.
    pub fn hasCodepoint(
        self: Entry,
        cp: u32,
        p_mode: PresentationMode,
    ) bool {
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

/// The requested presentation for a codepoint.
pub const PresentationMode = union(enum) {
    /// The codepoint has an explicit presentation that is required,
    /// i.e. VS15/V16.
    explicit: Presentation,

    /// The codepoint has no explicit presentation and we should use
    /// the presentation from the UCd.
    default: Presentation,

    /// The codepoint can be any presentation.
    any: void,
};

/// This represents a specific font in the collection.
///
/// The backing size of this packed struct represents the total number
/// of possible usable fonts in a collection. And the number of bits
/// used for the index and not the style represents the total number
/// of possible usable fonts for a given style.
///
/// The goal is to keep the size of this struct as small as practical. We
/// accept the limitations that this imposes so long as they're reasonable.
/// At the time of writing this comment, this is a 16-bit struct with 13
/// bits used for the index, supporting up to 8192 fonts per style. This
/// seems more than reasonable. There are synthetic scenarios where this
/// could be a limitation but I can't think of any that are practical.
///
/// If you somehow need more fonts per style, you can increase the size of
/// the Backing type and everything should just work fine.
pub const Index = packed struct(Index.Backing) {
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
    pub fn initSpecial(v: Special) Index {
        return .{ .style = .regular, .idx = @intFromEnum(v) };
    }

    /// Convert to int
    pub fn int(self: Index) Backing {
        return @bitCast(self);
    }

    /// Returns true if this is a "special" index which doesn't map to
    /// a real font face. We can still render it but there is no face for
    /// this font.
    pub fn special(self: Index) ?Special {
        if (self.idx < Special.start) return null;
        return @enumFromInt(self.idx);
    }

    test {
        // We never want to take up more than a byte since font indexes are
        // everywhere so if we increase the size of this we'll dramatically
        // increase our memory usage.
        try std.testing.expectEqual(@sizeOf(Backing), @sizeOf(Index));

        // Just so we're aware when this changes. The current maximum number
        // of fonts for a style is 13 bits or 8192 fonts.
        try std.testing.expectEqual(13, idx_bits);
    }
};

test init {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c = try init(alloc);
    defer c.deinit(alloc);
}

test "add full" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = @import("test.zig").fontRegular;

    var lib = try Library.init();
    defer lib.deinit();

    var c = try init(alloc);
    defer c.deinit(alloc);

    for (0..Index.Special.start - 1) |_| {
        _ = try c.add(alloc, .regular, .{ .loaded = try Face.init(
            lib,
            testFont,
            .{ .size = .{ .points = 12 } },
        ) });
    }

    try testing.expectError(error.CollectionFull, c.add(
        alloc,
        .regular,
        .{ .loaded = try Face.init(
            lib,
            testFont,
            .{ .size = .{ .points = 12 } },
        ) },
    ));
}

test "add deferred without loading options" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c = try init(alloc);
    defer c.deinit(alloc);

    try testing.expectError(error.DeferredLoadingUnavailable, c.add(
        alloc,
        .regular,

        // This can be undefined because it should never be accessed.
        .{ .deferred = undefined },
    ));
}

test getFace {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = @import("test.zig").fontRegular;

    var lib = try Library.init();
    defer lib.deinit();

    var c = try init(alloc);
    defer c.deinit(alloc);

    const idx = try c.add(alloc, .regular, .{ .loaded = try Face.init(
        lib,
        testFont,
        .{ .size = .{ .points = 12, .xdpi = 96, .ydpi = 96 } },
    ) });

    {
        const face1 = try c.getFace(idx);
        const face2 = try c.getFace(idx);
        try testing.expectEqual(@intFromPtr(face1), @intFromPtr(face2));
    }
}

test getIndex {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = @import("test.zig").fontRegular;

    var lib = try Library.init();
    defer lib.deinit();

    var c = try init(alloc);
    defer c.deinit(alloc);

    _ = try c.add(alloc, .regular, .{ .loaded = try Face.init(
        lib,
        testFont,
        .{ .size = .{ .points = 12, .xdpi = 96, .ydpi = 96 } },
    ) });

    // Should find all visible ASCII
    var i: u32 = 32;
    while (i < 127) : (i += 1) {
        const idx = c.getIndex(i, .regular, .{ .any = {} });
        try testing.expect(idx != null);
    }

    // Should not find emoji
    {
        const idx = c.getIndex('🥸', .regular, .{ .any = {} });
        try testing.expect(idx == null);
    }
}

test autoItalicize {
    if (comptime !@hasDecl(Face, "italicize")) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = @import("test.zig").fontRegular;

    var lib = try Library.init();
    defer lib.deinit();

    var c = try init(alloc);
    defer c.deinit(alloc);
    c.load_options = .{ .library = lib };

    _ = try c.add(alloc, .regular, .{ .loaded = try Face.init(
        lib,
        testFont,
        .{ .size = .{ .points = 12, .xdpi = 96, .ydpi = 96 } },
    ) });

    try testing.expect(c.getIndex('A', .italic, .{ .any = {} }) == null);
    try c.autoItalicize(alloc);
    try testing.expect(c.getIndex('A', .italic, .{ .any = {} }) != null);
}

test setSize {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = @import("test.zig").fontRegular;

    var lib = try Library.init();
    defer lib.deinit();

    var c = try init(alloc);
    defer c.deinit(alloc);
    c.load_options = .{ .library = lib };

    _ = try c.add(alloc, .regular, .{ .loaded = try Face.init(
        lib,
        testFont,
        .{ .size = .{ .points = 12, .xdpi = 96, .ydpi = 96 } },
    ) });

    try testing.expectEqual(@as(u32, 12), c.load_options.?.size.points);
    try c.setSize(.{ .points = 24 });
    try testing.expectEqual(@as(u32, 24), c.load_options.?.size.points);
}

test hasCodepoint {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = @import("test.zig").fontRegular;

    var lib = try Library.init();
    defer lib.deinit();

    var c = try init(alloc);
    defer c.deinit(alloc);
    c.load_options = .{ .library = lib };

    const idx = try c.add(alloc, .regular, .{ .loaded = try Face.init(
        lib,
        testFont,
        .{ .size = .{ .points = 12, .xdpi = 96, .ydpi = 96 } },
    ) });

    try testing.expect(c.hasCodepoint(idx, 'A', .{ .any = {} }));
    try testing.expect(!c.hasCodepoint(idx, '🥸', .{ .any = {} }));
}

test "hasCodepoint emoji default graphical" {
    if (options.backend != .fontconfig_freetype) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const testEmoji = @import("test.zig").fontEmoji;

    var lib = try Library.init();
    defer lib.deinit();

    var c = try init(alloc);
    defer c.deinit(alloc);
    c.load_options = .{ .library = lib };

    const idx = try c.add(alloc, .regular, .{ .loaded = try Face.init(
        lib,
        testEmoji,
        .{ .size = .{ .points = 12, .xdpi = 96, .ydpi = 96 } },
    ) });

    try testing.expect(!c.hasCodepoint(idx, 'A', .{ .any = {} }));
    try testing.expect(c.hasCodepoint(idx, '🥸', .{ .any = {} }));
    // TODO(fontmem): test explicit/implicit
}
