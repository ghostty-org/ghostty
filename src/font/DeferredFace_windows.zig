const std = @import("std");
const Allocator = std.mem.Allocator;
const freetype = @import("freetype");
const font = @import("main.zig");
const Library = @import("main.zig").Library;
const Face = @import("main.zig").Face;
const Presentation = @import("main.zig").Presentation;

const log = std.log.scoped(.deferred_face);

const DeferredFace = @This();

win: Windows,

pub const Windows = struct {
    alloc: Allocator,
    path: [:0]const u8,
    face_index: i32,
    family_name: [:0]const u8,
    style_name: [:0]const u8,
    full_name: [:0]const u8,
    variations: []const font.face.Variation,
    color: bool,
    charset: []const u32,

    pub fn deinit(self: *Windows) void {
        self.alloc.free(self.charset);
        self.alloc.free(self.path);
        self.alloc.free(self.family_name);
        self.alloc.free(self.style_name);
        self.alloc.free(self.full_name);
        self.alloc.free(self.variations);
        self.* = undefined;
    }
};

pub fn deinit(self: *DeferredFace) void {
    self.win.deinit();
    self.* = undefined;
}

pub fn familyName(self: DeferredFace, buf: []u8) ![]const u8 {
    _ = buf;
    return self.win.family_name;
}

pub fn name(self: DeferredFace, buf: []u8) ![]const u8 {
    _ = buf;
    return self.win.full_name;
}

pub fn load(
    self: *DeferredFace,
    lib: Library,
    opts: font.face.Options,
) !Face {
    var face = try Face.initFile(lib, self.win.path, self.win.face_index, opts);
    errdefer face.deinit();
    try face.setVariations(self.win.variations, opts);
    return face;
}

/// Check if a codepoint exists in this font using the pre-computed charset.
/// The charset is a sorted array of u32 codepoints extracted during font
/// discovery, so this is an O(log n) binary search instead of the previous
/// O(1)-but-expensive approach of creating a new FreeType library + face
/// per call.
pub fn hasCodepoint(self: DeferredFace, cp: u32, p: ?Presentation) bool {
    if (p) |desired| {
        const actual: Presentation = if (self.win.color) .emoji else .text;
        if (actual != desired) return false;
    }

    // Binary search in the pre-computed sorted charset
    const result = std.sort.binarySearch(u32, self.win.charset, cp, struct {
        fn order(target: u32, item: u32) std.math.Order {
            return std.math.order(target, item);
        }
    }.order);
    return result != null;
}
