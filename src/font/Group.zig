//! A font group is a a set of multiple font faces of potentially different
//! styles that are used together to find glyphs. They usually share sizing
//! properties so that they can be used interchangably with each other in cases
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

const font = @import("main.zig");
const DeferredFace = @import("main.zig").DeferredFace;
const Face = @import("main.zig").Face;
const Library = @import("main.zig").Library;
const Glyph = @import("main.zig").Glyph;
const Style = @import("main.zig").Style;
const Presentation = @import("main.zig").Presentation;
const options = @import("main.zig").options;

const log = std.log.scoped(.font_group);

/// Packed array to map our styles to a set of faces.
// Note: this is not the most efficient way to store these, but there is
// usually only one font group for the entire process so this isn't the
// most important memory efficiency we can look for. This is totally opaque
// to the user so we can change this later.
const StyleArray = std.EnumArray(Style, std.ArrayListUnmanaged(DeferredFace));

/// The allocator for this group
alloc: Allocator,

/// The library being used for all the faces.
lib: Library,

/// The desired font size. All fonts in a group must share the same size.
size: font.face.DesiredSize,

/// The available faces we have. This shouldn't be modified manually.
/// Instead, use the functions available on Group.
faces: StyleArray,

/// If discovery is available, we'll look up fonts where we can't find
/// the codepoint. This can be set after initialization.
discover: ?font.Discover = null,

/// Set this to a non-null value to enable sprite glyph drawing. If this
/// isn't enabled we'll just fall through to trying to use regular fonts
/// to render sprite glyphs. But more than likely, if this isn't set then
/// terminal rendering will look wrong.
sprite: ?font.sprite.Face = null,

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
    var it = self.faces.iterator();
    while (it.next()) |entry| {
        for (entry.value.items) |*item| item.deinit();
        entry.value.deinit(self.alloc);
    }

    if (font.Discover != void) {
        if (self.discover) |*discover| discover.deinit();
    }
}

/// Add a face to the list for the given style. This face will be added as
/// next in priority if others exist already, i.e. it'll be the _last_ to be
/// searched for a glyph in that list.
///
/// The group takes ownership of the face. The face will be deallocated when
/// the group is deallocated.
pub fn addFace(self: *Group, alloc: Allocator, style: Style, face: DeferredFace) !void {
    const list = self.faces.getPtr(style);

    // We have some special indexes so we must never pass those.
    if (list.items.len >= FontIndex.Special.start - 1) return error.GroupFull;

    try list.append(alloc, face);
}

/// Resize the fonts to the desired size.
pub fn setSize(self: *Group, size: font.face.DesiredSize) !void {
    // Note: there are some issues here with partial failure. We don't
    // currently handle it in any meaningful way if one face can resize
    // but another can't.

    // Resize all our faces that are loaded
    var it = self.faces.iterator();
    while (it.next()) |entry| {
        for (entry.value.items) |*deferred| {
            if (!deferred.loaded()) continue;
            try deferred.face.?.setSize(size);
        }
    }

    // Set our size for future loads
    self.size = size;
}

/// This represents a specific font in the group.
pub const FontIndex = packed struct(u8) {
    /// The number of bits we use for the index.
    const idx_bits = 8 - @typeInfo(@typeInfo(Style).Enum.tag_type).Int.bits;
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
    pub fn int(self: FontIndex) u8 {
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
        try std.testing.expectEqual(@sizeOf(u8), @sizeOf(FontIndex));
    }
};

/// Looks up the font that should be used for a specific codepoint.
/// The font index is valid as long as font faces aren't removed. This
/// isn't cached; it is expected that downstream users handle caching if
/// that is important.
///
/// Optionally, a presentation format can be specified. This presentation
/// format will be preferred but if it can't be found in this format,
/// any text format will be accepted. If presentation is null, any presentation
/// is allowed. This func will NOT determine the default presentation for
/// a code point.
pub fn indexForCodepoint(
    self: *Group,
    cp: u32,
    style: Style,
    p: ?Presentation,
) ?FontIndex {
    // If we have sprite drawing enabled, check if our sprite face can
    // handle this.
    if (self.sprite) |sprite| {
        if (sprite.hasCodepoint(cp, p)) {
            return FontIndex.initSpecial(.sprite);
        }
    }

    // If we can find the exact value, then return that.
    if (self.indexForCodepointExact(cp, style, p)) |value| return value;

    // Try looking for another font that will satisfy this request.
    if (font.Discover != void) {
        if (self.discover) |*disco| discover: {
            var disco_it = disco.discover(.{
                .codepoint = cp,
                .size = self.size.points,
                .bold = style == .bold or style == .bold_italic,
                .italic = style == .italic or style == .bold_italic,
            }) catch break :discover;
            defer disco_it.deinit();

            if (disco_it.next() catch break :discover) |face| {
                log.info("found codepoint 0x{x} in fallback face={s}", .{
                    cp,
                    face.name() catch "<error>",
                });
                self.addFace(self.alloc, style, face) catch break :discover;
                if (self.indexForCodepointExact(cp, style, p)) |value| return value;
            }
        }
    }

    // If this is already regular, we're done falling back.
    if (style == .regular and p == null) return null;

    // For non-regular fonts, we fall back to regular.
    return self.indexForCodepointExact(cp, .regular, null);
}

fn indexForCodepointExact(self: Group, cp: u32, style: Style, p: ?Presentation) ?FontIndex {
    for (self.faces.get(style).items, 0..) |deferred, i| {
        if (deferred.hasCodepoint(cp, p)) {
            return FontIndex{
                .style = style,
                .idx = @intCast(i),
            };
        }
    }

    // Not found
    return null;
}

/// Returns the presentation for a specific font index. This is useful for
/// determining what atlas is needed.
pub fn presentationFromIndex(self: Group, index: FontIndex) !font.Presentation {
    if (index.special()) |sp| switch (sp) {
        .sprite => return .text,
    };

    const face = try self.faceFromIndex(index);
    return face.presentation;
}

/// Return the Face represented by a given FontIndex. Note that special
/// fonts (i.e. box glyphs) do not have a face.
pub fn faceFromIndex(self: Group, index: FontIndex) !*Face {
    if (index.special() != null) return error.SpecialHasNoFace;
    const deferred = &self.faces.get(index.style).items[@intCast(index.idx)];
    try deferred.load(self.lib, self.size);
    return &deferred.face.?;
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
    self: Group,
    alloc: Allocator,
    atlas: *font.Atlas,
    index: FontIndex,
    glyph_index: u32,
    max_height: ?u16,
) !Glyph {
    // Special-case fonts are rendered directly.
    if (index.special()) |sp| switch (sp) {
        .sprite => return try self.sprite.?.renderGlyph(
            alloc,
            atlas,
            glyph_index,
        ),
    };

    const face = &self.faces.get(index.style).items[@intCast(index.idx)];
    try face.load(self.lib, self.size);
    return try face.face.?.renderGlyph(alloc, atlas, glyph_index, max_height);
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

        var result = try alloc.create(Group);
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
            .width = @intFromFloat(metrics.cell_width),
            .height = @intFromFloat(metrics.cell_height),
            .thickness = 2,
            .underline_position = @intFromFloat(metrics.underline_position),
        };
    }

    export fn group_add_face(self: *Group, style: u16, face: *font.DeferredFace) void {
        return self.addFace(alloc, @enumFromInt(style), face.*) catch |err| {
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
        const glyph = try self.renderGlyph(alloc, atlas, idx, cp, max_height);

        var result = try alloc.create(Glyph);
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

    try group.addFace(alloc, .regular, DeferredFace.initLoaded(try Face.init(lib, testFont, .{ .points = 12 })));
    try group.addFace(alloc, .regular, DeferredFace.initLoaded(try Face.init(lib, testEmoji, .{ .points = 12 })));
    try group.addFace(alloc, .regular, DeferredFace.initLoaded(try Face.init(lib, testEmojiText, .{ .points = 12 })));

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
            null,
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
        try testing.expectEqual(@as(FontIndex.IndexInt, 2), idx.idx);
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
    group.sprite = font.sprite.Face{ .width = 18, .height = 36, .thickness = 2 };

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
        null,
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

    try group.addFace(alloc, .regular, DeferredFace.initLoaded(try Face.init(lib, testFont, .{ .points = 12, .xdpi = 96, .ydpi = 96 })));

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
            null,
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
            null,
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
    var it = try fc.discover(.{ .family = "monospace", .size = 12 });
    defer it.deinit();

    // Initialize the group with the deferred face
    var lib = try Library.init();
    defer lib.deinit();
    var group = try init(alloc, lib, .{ .points = 12 });
    defer group.deinit();
    try group.addFace(alloc, .regular, (try it.next()).?);

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
            null,
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

    try group.addFace(alloc, .regular, DeferredFace.initLoaded(try Face.init(lib, testFont, .{ .points = 12, .xdpi = 96, .ydpi = 96 })));

    {
        const idx = group.indexForCodepoint('A', .regular, null).?;
        const face1 = try group.faceFromIndex(idx);
        const face2 = try group.faceFromIndex(idx);
        try testing.expectEqual(@intFromPtr(face1), @intFromPtr(face2));
    }
}
