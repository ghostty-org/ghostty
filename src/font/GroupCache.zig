//! A glyph cache sits on top of a Group and caches the results from it.
const GroupCache = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const font = @import("main.zig");
const Face = @import("main.zig").Face;
const DeferredFace = @import("main.zig").DeferredFace;
const Library = @import("main.zig").Library;
const Glyph = @import("main.zig").Glyph;
const Style = @import("main.zig").Style;
const Group = @import("main.zig").Group;
const Presentation = @import("main.zig").Presentation;

const log = std.log.scoped(.font_groupcache);

/// Cache for codepoints to font indexes in a group.
codepoints: std.AutoHashMapUnmanaged(CodepointKey, ?Group.FontIndex) = .{},

/// Cache for glyph renders.
glyphs: std.AutoHashMapUnmanaged(GlyphKey, Glyph) = .{},

/// The underlying font group. Users are expected to use this directly
/// to setup the group or make changes. Beware some changes require a reset
/// (see reset).
group: Group,

/// The texture atlas to store renders in. The GroupCache has to store these
/// because the cached Glyph result is dependent on the Atlas.
atlas_greyscale: font.Atlas,
atlas_color: font.Atlas,

const CodepointKey = struct {
    style: Style,
    codepoint: u32,
    presentation: ?Presentation,
};

const GlyphKey = struct {
    index: Group.FontIndex,
    glyph: u32,
    opts: font.face.RenderOptions,
};

/// The GroupCache takes ownership of Group and will free it.
pub fn init(alloc: Allocator, group: Group) !GroupCache {
    var atlas_greyscale = try font.Atlas.init(alloc, 512, .greyscale);
    errdefer atlas_greyscale.deinit(alloc);
    var atlas_color = try font.Atlas.init(alloc, 512, .rgba);
    errdefer atlas_color.deinit(alloc);

    var result: GroupCache = .{
        .group = group,
        .atlas_greyscale = atlas_greyscale,
        .atlas_color = atlas_color,
    };

    // We set an initial capacity that can fit a good number of characters.
    // This number was picked empirically based on my own terminal usage.
    try result.codepoints.ensureTotalCapacity(alloc, 128);
    try result.glyphs.ensureTotalCapacity(alloc, 128);

    return result;
}

pub fn deinit(self: *GroupCache, alloc: Allocator) void {
    self.codepoints.deinit(alloc);
    self.glyphs.deinit(alloc);
    self.atlas_greyscale.deinit(alloc);
    self.atlas_color.deinit(alloc);
    self.group.deinit();
}

/// Reset the cache. This should be called:
///
///   - If an Atlas was reset
///   - If a font group font size was changed
///   - If a font group font set was changed
///
pub fn reset(self: *GroupCache) void {
    self.codepoints.clearRetainingCapacity();
    self.glyphs.clearRetainingCapacity();
}

/// Resize the fonts in the group. This will clear the cache.
pub fn setSize(self: *GroupCache, size: font.face.DesiredSize) !void {
    try self.group.setSize(size);

    // Reset our internal state
    self.reset();

    // Clear our atlases
    self.atlas_greyscale.clear();
    self.atlas_color.clear();
}

/// Get the font index for a given codepoint. This is cached.
pub fn indexForCodepoint(
    self: *GroupCache,
    alloc: Allocator,
    cp: u32,
    style: Style,
    p: ?Presentation,
) !?Group.FontIndex {
    const key: CodepointKey = .{ .style = style, .codepoint = cp, .presentation = p };
    const gop = try self.codepoints.getOrPut(alloc, key);

    // If it is in the cache, use it.
    if (gop.found_existing) return gop.value_ptr.*;

    // Load a value and cache it. This even caches negative matches.
    const value = self.group.indexForCodepoint(cp, style, p);
    gop.value_ptr.* = value;
    return value;
}

/// Render a glyph. This automatically determines the correct texture
/// atlas to use and caches the result.
pub fn renderGlyph(
    self: *GroupCache,
    alloc: Allocator,
    index: Group.FontIndex,
    glyph_index: u32,
    opts: font.face.RenderOptions,
) !Glyph {
    const key: GlyphKey = .{ .index = index, .glyph = glyph_index, .opts = opts };
    const gop = try self.glyphs.getOrPut(alloc, key);

    // If it is in the cache, use it.
    if (gop.found_existing) return gop.value_ptr.*;

    // Uncached, render it
    const atlas: *font.Atlas = switch (try self.group.presentationFromIndex(index)) {
        .text => &self.atlas_greyscale,
        .emoji => &self.atlas_color,
    };
    const glyph = self.group.renderGlyph(
        alloc,
        atlas,
        index,
        glyph_index,
        opts,
    ) catch |err| switch (err) {
        // If the atlas is full, we resize it
        error.AtlasFull => blk: {
            try atlas.grow(alloc, atlas.size * 2);
            break :blk try self.group.renderGlyph(
                alloc,
                atlas,
                index,
                glyph_index,
                opts,
            );
        },

        else => return err,
    };

    // Cache and return
    gop.value_ptr.* = glyph;
    return glyph;
}

test {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = @import("test.zig").fontRegular;
    // const testEmoji = @import("test.zig").fontEmoji;

    var atlas_greyscale = try font.Atlas.init(alloc, 512, .greyscale);
    defer atlas_greyscale.deinit(alloc);

    var lib = try Library.init();
    defer lib.deinit();

    var cache = try init(alloc, try Group.init(
        alloc,
        lib,
        .{ .points = 12 },
    ));
    defer cache.deinit(alloc);

    // Setup group
    _ = try cache.group.addFace(
        .regular,
        .{ .loaded = try Face.init(lib, testFont, .{ .size = .{ .points = 12 } }) },
    );
    var group = cache.group;

    // Visible ASCII. Do it twice to verify cache.
    var i: u32 = 32;
    while (i < 127) : (i += 1) {
        const idx = (try cache.indexForCodepoint(alloc, i, .regular, null)).?;
        try testing.expectEqual(Style.regular, idx.style);
        try testing.expectEqual(@as(Group.FontIndex.IndexInt, 0), idx.idx);

        // Render
        const face = try cache.group.faceFromIndex(idx);
        const glyph_index = face.glyphIndex(i).?;
        _ = try cache.renderGlyph(
            alloc,
            idx,
            glyph_index,
            .{},
        );
    }

    // Do it again, but reset the group so that we know for sure its not hitting it
    {
        cache.group = undefined;
        defer cache.group = group;

        i = 32;
        while (i < 127) : (i += 1) {
            const idx = (try cache.indexForCodepoint(alloc, i, .regular, null)).?;
            try testing.expectEqual(Style.regular, idx.style);
            try testing.expectEqual(@as(Group.FontIndex.IndexInt, 0), idx.idx);

            // Render
            const face = try group.faceFromIndex(idx);
            const glyph_index = face.glyphIndex(i).?;
            _ = try cache.renderGlyph(
                alloc,
                idx,
                glyph_index,
                .{},
            );
        }
    }
}

/// The wasm-compatible API.
pub const Wasm = struct {
    const wasm = @import("../os/wasm.zig");
    const alloc = wasm.alloc;

    export fn group_cache_new(group: *Group) ?*GroupCache {
        return group_cache_new_(group) catch null;
    }

    fn group_cache_new_(group: *Group) !*GroupCache {
        var gc = try GroupCache.init(alloc, group.*);
        errdefer gc.deinit(alloc);

        const result = try alloc.create(GroupCache);
        errdefer alloc.destroy(result);
        result.* = gc;
        return result;
    }

    export fn group_cache_free(ptr: ?*GroupCache) void {
        if (ptr) |v| {
            v.deinit(alloc);
            alloc.destroy(v);
        }
    }

    export fn group_cache_set_size(self: *GroupCache, size: u16) void {
        return self.setSize(.{ .points = size }) catch |err| {
            log.warn("error setting group cache size err={}", .{err});
            return;
        };
    }

    /// Presentation is negative for doesn't matter.
    export fn group_cache_index_for_codepoint(self: *GroupCache, cp: u32, style: u16, p: i16) i16 {
        const presentation: ?Presentation = if (p < 0) null else @enumFromInt(p);
        if (self.indexForCodepoint(
            alloc,
            cp,
            @enumFromInt(style),
            presentation,
        )) |idx| {
            return @intCast(@as(u8, @bitCast(idx orelse return -1)));
        } else |err| {
            log.warn("error getting index for codepoint from group cache size err={}", .{err});
            return -1;
        }
    }

    export fn group_cache_render_glyph(
        self: *GroupCache,
        idx: i16,
        cp: u32,
        max_height: u16,
    ) ?*Glyph {
        return group_cache_render_glyph_(self, idx, cp, max_height) catch |err| {
            log.warn("error rendering group cache glyph err={}", .{err});
            return null;
        };
    }

    fn group_cache_render_glyph_(
        self: *GroupCache,
        idx_: i16,
        cp: u32,
        max_height_: u16,
    ) !*Glyph {
        const idx = @as(Group.FontIndex, @bitCast(@as(u8, @intCast(idx_))));
        const max_height = if (max_height_ <= 0) null else max_height_;
        const glyph = try self.renderGlyph(alloc, idx, cp, .{
            .max_height = max_height,
        });

        const result = try alloc.create(Glyph);
        errdefer alloc.destroy(result);
        result.* = glyph;
        return result;
    }

    export fn group_cache_atlas_greyscale(self: *GroupCache) *font.Atlas {
        return &self.atlas_greyscale;
    }

    export fn group_cache_atlas_color(self: *GroupCache) *font.Atlas {
        return &self.atlas_color;
    }
};

test "resize" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const testFont = @import("test.zig").fontRegular;
    // const testEmoji = @import("test.zig").fontEmoji;

    var atlas_greyscale = try font.Atlas.init(alloc, 512, .greyscale);
    defer atlas_greyscale.deinit(alloc);

    var lib = try Library.init();
    defer lib.deinit();

    var cache = try init(alloc, try Group.init(
        alloc,
        lib,
        .{ .points = 12 },
    ));
    defer cache.deinit(alloc);

    // Setup group
    _ = try cache.group.addFace(
        .regular,
        .{ .loaded = try Face.init(
            lib,
            testFont,
            .{ .size = .{ .points = 12, .xdpi = 96, .ydpi = 96 } },
        ) },
    );

    // Load a letter
    {
        const idx = (try cache.indexForCodepoint(alloc, 'A', .regular, null)).?;
        const face = try cache.group.faceFromIndex(idx);
        const glyph_index = face.glyphIndex('A').?;
        const glyph = try cache.renderGlyph(
            alloc,
            idx,
            glyph_index,
            .{},
        );

        try testing.expectEqual(@as(u32, 11), glyph.height);
    }

    // Resize
    try cache.setSize(.{ .points = 24, .xdpi = 96, .ydpi = 96 });
    {
        const idx = (try cache.indexForCodepoint(alloc, 'A', .regular, null)).?;
        const face = try cache.group.faceFromIndex(idx);
        const glyph_index = face.glyphIndex('A').?;
        const glyph = try cache.renderGlyph(
            alloc,
            idx,
            glyph_index,
            .{},
        );

        try testing.expectEqual(@as(u32, 21), glyph.height);
    }
}
