//! This structure represents the state required to render a terminal
//! grid using the font subsystem. It is "shared" because it is able to
//! be shared across multiple surfaces.
//!
//! It is desirable for the grid state to be shared because the font
//! configuration for a set of surfaces is almost always the same and
//! font data is relatively memory intensive. Further, the font subsystem
//! should be read-heavy compared to write-heavy, so it handles concurrent
//! reads well. Going even further, the font subsystem should be very rarely
//! read at all since it should only be necessary when the grid actively
//! changes.
//!
//! SharedGrid does NOT support resizing, font-family changes, font removals
//! in collections, etc. Because the Grid is shared this would cause a
//! major disruption in the rendering of multiple surfaces (i.e. increasing
//! the font size in one would increase it in all). In many cases this isn't
//! desirable so to implement configuration changes the grid should be
//! reinitialized and all surfaces should switch over to using that one.
const SharedGrid = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const renderer = @import("../renderer.zig");
const font = @import("main.zig");
const Atlas = font.Atlas;
const CodepointResolver = font.CodepointResolver;
const Collection = font.Collection;
const Face = font.Face;
const Glyph = font.Glyph;
const Library = font.Library;
const Metrics = font.Metrics;
const Presentation = font.Presentation;
const Style = font.Style;
const RenderOptions = font.face.RenderOptions;

const log = std.log.scoped(.font_shared_grid);

/// Cache for codepoints to font indexes in a group.
codepoints: std.AutoHashMapUnmanaged(CodepointKey, ?Collection.Index) = .{},

/// Cache for glyph renders into the atlas.
glyphs: std.HashMapUnmanaged(GlyphKey, Render, GlyphKey.Context, 80) = .{},

/// The texture atlas to store renders in. The Glyph data in the glyphs
/// cache is dependent on the atlas matching.
atlas_grayscale: Atlas,
atlas_color: Atlas,

/// The underlying resolver for font data, fallbacks, etc. The shared
/// grid takes ownership of the resolver and will free it.
resolver: CodepointResolver,

/// The currently active grid metrics dictating the layout of the grid.
/// This is calculated based on the resolver and current fonts.
metrics: Metrics,

/// The RwLock used to protect the shared grid. Callers are expected to use
/// this directly if they need to i.e. access the atlas directly. Because
/// callers can use this lock directly, maintainers need to be extra careful
/// to review call sites to ensure they are using the lock correctly.
lock: std.Thread.RwLock,

/// Initialize the grid.
///
/// The resolver must have a collection that supports deferred loading
/// (collection.load_options != null). This is because we need the load
/// options data to determine grid metrics and setup our sprite font.
///
/// SharedGrid always configures the sprite font. This struct is expected to be
/// used with a terminal grid and therefore the sprite font is always
/// necessary for correct rendering.
pub fn init(
    alloc: Allocator,
    resolver: CodepointResolver,
) !SharedGrid {
    // We need to support loading options since we use the size data
    assert(resolver.collection.load_options != null);

    var atlas_grayscale = try Atlas.init(alloc, 512, .grayscale);
    errdefer atlas_grayscale.deinit(alloc);
    var atlas_color = try Atlas.init(alloc, 512, .bgra);
    errdefer atlas_color.deinit(alloc);

    var result: SharedGrid = .{
        .resolver = resolver,
        .atlas_grayscale = atlas_grayscale,
        .atlas_color = atlas_color,
        .lock = .{},
        .metrics = undefined, // Loaded below
    };

    // We set an initial capacity that can fit a good number of characters.
    // This number was picked empirically based on my own terminal usage.
    try result.codepoints.ensureTotalCapacity(alloc, 128);
    try result.glyphs.ensureTotalCapacity(alloc, 128);

    // Initialize our metrics.
    try result.reloadMetrics();

    return result;
}

/// Deinit. Assumes no concurrent access so no lock is taken.
pub fn deinit(self: *SharedGrid, alloc: Allocator) void {
    self.codepoints.deinit(alloc);
    self.glyphs.deinit(alloc);
    self.atlas_grayscale.deinit(alloc);
    self.atlas_color.deinit(alloc);
    self.resolver.deinit(alloc);
}

fn reloadMetrics(self: *SharedGrid) !void {
    const collection = &self.resolver.collection;
    try collection.updateMetrics();

    self.metrics = collection.metrics.?;

    // Setup our sprite font.
    self.resolver.sprite = .{ .metrics = self.metrics };
}

/// Returns the grid cell size.
///
/// This is not thread safe.
pub fn cellSize(self: *SharedGrid) renderer.CellSize {
    return .{
        .width = self.metrics.cell_width,
        .height = self.metrics.cell_height,
    };
}

/// Get the font index for a given codepoint. This is cached.
///
/// This always forces loading any deferred fonts since we assume that if
/// you're looking up an index that the caller plans to use the font. By
/// loading the font in this function we can ensure thread-safety on the
/// load without complicating future calls.
pub fn getIndex(
    self: *SharedGrid,
    alloc: Allocator,
    cp: u32,
    style: Style,
    p: ?Presentation,
) !?Collection.Index {
    const key: CodepointKey = .{ .style = style, .codepoint = cp, .presentation = p };

    // Fast path: the cache has the value. This is almost always true and
    // only requires a read lock.
    {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        if (self.codepoints.get(key)) |v| return v;
    }

    // Slow path: we need to search this codepoint
    self.lock.lock();
    defer self.lock.unlock();

    // Try to get it, if it is now in the cache another thread beat us to it.
    const gop = try self.codepoints.getOrPut(alloc, key);
    if (gop.found_existing) return gop.value_ptr.*;
    errdefer self.codepoints.removeByPtr(gop.key_ptr);

    // Load a value and cache it. This even caches negative matches.
    const value = self.resolver.getIndex(alloc, cp, style, p);
    gop.value_ptr.* = value;

    if (value) |idx| preload: {
        // If the font is a sprite font then we don't need to preload
        // because getFace doesn't work with special fonts.
        if (idx.special() != null) break :preload;

        // Load the face in case its deferred. If this fails then we would've
        // failed to load it in the future anyways so we want to undo all
        // the caching we did.
        _ = try self.resolver.collection.getFace(idx);
    }

    return value;
}

/// Returns true if the given font index has the codepoint and presentation.
pub fn hasCodepoint(
    self: *SharedGrid,
    idx: Collection.Index,
    cp: u32,
    p: ?Presentation,
) bool {
    self.lock.lockShared();
    defer self.lock.unlockShared();
    return self.resolver.collection.hasCodepoint(
        idx,
        cp,
        if (p) |v| .{ .explicit = v } else .{ .any = {} },
    );
}

pub const Render = struct {
    glyph: Glyph,
    presentation: Presentation,
};

/// Render a codepoint. This uses the first font index that has the codepoint
/// and matches the presentation requested. If the codepoint cannot be found
/// in any font, an null render is returned.
pub fn renderCodepoint(
    self: *SharedGrid,
    alloc: Allocator,
    cp: u32,
    style: Style,
    p: ?Presentation,
    opts: RenderOptions,
) !?Render {
    // Note: we could optimize the below to use way less locking, but
    // at the time of writing this codepath is only called for preedit
    // text which is relatively rare and almost non-existent in multiple
    // surfaces at the same time.

    // Get the font that has the codepoint
    const index = try self.getIndex(alloc, cp, style, p) orelse return null;

    // Get the glyph for the font
    const glyph_index = glyph_index: {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        const face = try self.resolver.collection.getFace(index);
        break :glyph_index face.glyphIndex(cp) orelse return null;
    };

    // Render
    return try self.renderGlyph(alloc, index, glyph_index, opts);
}

/// Render a glyph index. This automatically determines the correct texture
/// atlas to use and caches the result.
pub fn renderGlyph(
    self: *SharedGrid,
    alloc: Allocator,
    index: Collection.Index,
    glyph_index: u32,
    opts: RenderOptions,
) !Render {
    const key: GlyphKey = .{ .index = index, .glyph = glyph_index, .opts = opts };

    // Fast path: the cache has the value. This is almost always true and
    // only requires a read lock.
    {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        if (self.glyphs.get(key)) |v| return v;
    }

    // Slow path: we need to search this codepoint
    self.lock.lock();
    defer self.lock.unlock();

    const gop = try self.glyphs.getOrPut(alloc, key);
    if (gop.found_existing) return gop.value_ptr.*;

    // Get the presentation to determine what atlas to use
    const p = try self.resolver.getPresentation(index, glyph_index);
    const atlas: *font.Atlas = switch (p) {
        .text => &self.atlas_grayscale,
        .emoji => &self.atlas_color,
    };

    var render_opts = opts;

    // Always use these constraints for emoji.
    if (p == .emoji) {
        render_opts.constraint = .{
            // Make the emoji as wide as possible, scaling proportionally,
            // but then scale it down as necessary if its new size exceeds
            // the cell height.
            .size_horizontal = .cover,
            .size_vertical = .fit,

            // Center the emoji in its cells.
            .align_horizontal = .center,
            .align_vertical = .center,

            // Add a small bit of padding so the emoji
            // doesn't quite touch the edges of the cells.
            .pad_left = 0.025,
            .pad_right = 0.025,
        };
    }

    // Render into the atlas
    const glyph = self.resolver.renderGlyph(
        alloc,
        atlas,
        index,
        glyph_index,
        render_opts,
    ) catch |err| switch (err) {
        // If the atlas is full, we resize it
        error.AtlasFull => blk: {
            try atlas.grow(alloc, atlas.size * 2);
            break :blk try self.resolver.renderGlyph(
                alloc,
                atlas,
                index,
                glyph_index,
                render_opts,
            );
        },

        else => return err,
    };

    // Cache and return
    gop.value_ptr.* = .{
        .glyph = glyph,
        .presentation = p,
    };

    return gop.value_ptr.*;
}

const CodepointKey = struct {
    style: Style,
    codepoint: u32,
    presentation: ?Presentation,
};

const GlyphKey = struct {
    index: Collection.Index,
    glyph: u32,
    opts: RenderOptions,

    const Context = struct {
        pub fn hash(_: Context, key: GlyphKey) u64 {
            return @bitCast(Packed.from(key));
        }

        pub fn eql(_: Context, a: GlyphKey, b: GlyphKey) bool {
            return Packed.from(a) == Packed.from(b);
        }
    };

    const Packed = packed struct(u64) {
        index: Collection.Index,
        glyph: u32,
        opts: packed struct(u16) {
            cell_width: u2,
            thicken: bool,
            thicken_strength: u8,
            constraint_width: u2,
            _padding: u3 = 0,
        },

        inline fn from(key: GlyphKey) Packed {
            return .{
                .index = key.index,
                .glyph = key.glyph,
                .opts = .{
                    .cell_width = key.opts.cell_width orelse 0,
                    .thicken = key.opts.thicken,
                    .thicken_strength = key.opts.thicken_strength,
                    .constraint_width = key.opts.constraint_width,
                },
            };
        }
    };
};

const TestMode = enum { normal };

fn testGrid(mode: TestMode, alloc: Allocator, lib: Library) !SharedGrid {
    const testFont = font.embedded.regular;

    var c = Collection.init();
    c.load_options = .{ .library = lib };

    switch (mode) {
        .normal => {
            _ = try c.add(alloc, .regular, .{ .loaded = try .init(
                lib,
                testFont,
                .{ .size = .{ .points = 12, .xdpi = 96, .ydpi = 96 } },
            ) });
        },
    }

    var r: CodepointResolver = .{ .collection = c };
    errdefer r.deinit(alloc);

    return try init(alloc, r);
}

test getIndex {
    const testing = std.testing;
    const alloc = testing.allocator;
    // const testEmoji = @import("test.zig").fontEmoji;

    var lib = try Library.init(alloc);
    defer lib.deinit();

    var grid = try testGrid(.normal, alloc, lib);
    defer grid.deinit(alloc);

    // Visible ASCII.
    for (32..127) |i| {
        const idx = (try grid.getIndex(alloc, @intCast(i), .regular, null)).?;
        try testing.expectEqual(Style.regular, idx.style);
        try testing.expectEqual(@as(Collection.Index.IndexInt, 0), idx.idx);
        try testing.expect(grid.hasCodepoint(idx, @intCast(i), null));
    }

    // Do it again without a resolver set to ensure we only hit the cache
    const old_resolver = grid.resolver;
    grid.resolver = undefined;
    defer grid.resolver = old_resolver;
    for (32..127) |i| {
        const idx = (try grid.getIndex(alloc, @intCast(i), .regular, null)).?;
        try testing.expectEqual(Style.regular, idx.style);
        try testing.expectEqual(@as(Collection.Index.IndexInt, 0), idx.idx);
    }
}
