const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const freetype = @import("freetype");
const Collection = @import("main.zig").Collection;
const DeferredFace = @import("main.zig").DeferredFace;
const Variation = @import("main.zig").face.Variation;

const log = std.log.scoped(.discovery);

pub const Discover = Windows;

pub const Descriptor = struct {
    family: ?[:0]const u8 = null,
    style: ?[:0]const u8 = null,
    codepoint: u32 = 0,
    size: f32 = 0,
    bold: bool = false,
    italic: bool = false,
    monospace: bool = false,
    variations: []const Variation = &.{},

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
            autoHash(hasher, @as(i64, @intFromFloat(variation.value)));
        }
    }

    pub fn hashcode(self: Descriptor) u64 {
        var hasher = std.hash.Wyhash.init(0);
        self.hash(&hasher);
        return hasher.final();
    }

    pub fn clone(self: *const Descriptor, alloc: Allocator) !Descriptor {
        var copy = self.*;
        copy.family = if (self.family) |src| try alloc.dupeZ(u8, src) else null;
        copy.style = if (self.style) |src| try alloc.dupeZ(u8, src) else null;
        copy.variations = try alloc.dupe(Variation, self.variations);
        return copy;
    }
};

pub const Windows = struct {
    alloc: Allocator,
    fonts_dir: [:0]const u8,
    records: []Record,

    const Record = struct {
        path: [:0]const u8,
        face_index: i32,
        family_name: [:0]const u8,
        style_name: [:0]const u8,
        full_name: [:0]const u8,
        monospace: bool,
        bold: bool,
        italic: bool,
        color: bool,
        variable: bool,
        has_codepoint: bool,

        fn deinit(self: *Record, alloc: Allocator) void {
            alloc.free(self.path);
            alloc.free(self.family_name);
            alloc.free(self.style_name);
            alloc.free(self.full_name);
            self.* = undefined;
        }
    };

    pub fn init() Windows {
        const alloc = std.heap.page_allocator;
        const fonts_dir = windowsFontsDir(alloc) catch |err| {
            log.warn("windows font discovery disabled: {}", .{err});
            return empty(alloc);
        };

        const records = scanFonts(alloc, fonts_dir) catch |err| {
            log.warn("windows font discovery scan failed dir={s} err={}", .{ fonts_dir, err });
            alloc.free(fonts_dir);
            return empty(alloc);
        };

        return .{ .alloc = alloc, .fonts_dir = fonts_dir, .records = records };
    }

    pub fn deinit(self: *Windows) void {
        const alloc = self.alloc;
        for (self.records) |*record| record.deinit(alloc);
        alloc.free(self.records);
        alloc.free(self.fonts_dir);
        self.* = undefined;
    }

    fn empty(alloc: Allocator) Windows {
        return .{
            .alloc = alloc,
            .fonts_dir = alloc.dupeZ(u8, "") catch unreachable,
            .records = alloc.alloc(Record, 0) catch unreachable,
        };
    }

    pub fn discover(
        self: *const Windows,
        alloc: Allocator,
        desc: Descriptor,
    ) !DiscoverIterator {
        const filtered = try filterRecords(alloc, self.records, desc);
        errdefer alloc.free(filtered);

        std.mem.sortUnstable(Record, filtered, desc, struct {
            fn lessThan(desc_inner: Descriptor, lhs: Record, rhs: Record) bool {
                return score(desc_inner, lhs) > score(desc_inner, rhs);
            }
        }.lessThan);

        return .{
            .alloc = alloc,
            .records = filtered,
            .variations = desc.variations,
            .i = 0,
        };
    }

    pub fn discoverFallback(
        self: *const Windows,
        alloc: Allocator,
        collection: *Collection,
        desc: Descriptor,
    ) !DiscoverIterator {
        _ = collection;
        return try self.discover(alloc, desc);
    }

    pub const DiscoverIterator = struct {
        alloc: Allocator,
        records: []Record,
        variations: []const Variation,
        i: usize,

        pub fn deinit(self: *DiscoverIterator) void {
            self.alloc.free(self.records);
            self.* = undefined;
        }

        pub fn next(self: *DiscoverIterator) !?DeferredFace {
            if (self.i >= self.records.len) return null;
            defer self.i += 1;

            const record = self.records[self.i];
            return DeferredFace{
                .win = .{
                    .alloc = self.alloc,
                    .path = try self.alloc.dupeZ(u8, record.path),
                    .face_index = record.face_index,
                    .family_name = try self.alloc.dupeZ(u8, record.family_name),
                    .style_name = try self.alloc.dupeZ(u8, record.style_name),
                    .full_name = try self.alloc.dupeZ(u8, record.full_name),
                    .variations = try self.alloc.dupe(Variation, self.variations),
                    .color = record.color,
                },
            };
        }
    };

    fn windowsFontsDir(alloc: Allocator) ![:0]const u8 {
        const base = envBase: {
            const windir = envDir(alloc, "WINDIR") catch |err| switch (err) {
                error.EnvironmentVariableNotFound => envDir(alloc, "SystemRoot") catch |inner| switch (inner) {
                    error.EnvironmentVariableNotFound => break :envBase try alloc.dupe(u8, "C:\\Windows"),
                    else => return inner,
                },
                else => return err,
            };
            break :envBase windir;
        };
        defer alloc.free(base);
        const path = try std.fmt.allocPrint(alloc, "{s}\\Fonts", .{base});
        defer alloc.free(path);
        return try alloc.dupeZ(u8, path);
    }

    fn envDir(alloc: Allocator, key: []const u8) ![]u8 {
        return try std.process.getEnvVarOwned(alloc, key);
    }

    fn scanFonts(alloc: Allocator, fonts_dir: [:0]const u8) ![]Record {
        var dir = try std.fs.openDirAbsolute(fonts_dir, .{ .iterate = true });
        defer dir.close();

        var lib = try freetype.Library.init();
        defer lib.deinit();

        var records: std.ArrayListUnmanaged(Record) = .{};
        errdefer {
            for (records.items) |*record| record.deinit(alloc);
            records.deinit(alloc);
        }

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!supportedFontFile(entry.name)) continue;

            const path = try std.fs.path.joinZ(alloc, &.{ fonts_dir, entry.name });
            errdefer alloc.free(path);

            var face0 = lib.initFace(path, 0) catch |err| {
                log.debug("windows font discovery skipped path={s} err={}", .{ path, err });
                continue;
            };
            defer face0.deinit();

            const num_faces: usize = @intCast(@max(face0.handle.*.num_faces, 1));
            for (0..num_faces) |i| {
                const face_index: i32 = @intCast(i);
                const face = if (i == 0) face0 else lib.initFace(path, face_index) catch |err| {
                    log.debug("windows font discovery face skipped path={s} index={} err={}", .{ path, face_index, err });
                    continue;
                };
                defer if (i != 0) face.deinit();

                var record = try inspectFace(alloc, path, face, face_index);
                errdefer record.deinit(alloc);
                try records.append(alloc, record);
            }
        }

        return try records.toOwnedSlice(alloc);
    }

    fn inspectFace(
        alloc: Allocator,
        path: [:0]const u8,
        face: freetype.Face,
        face_index: i32,
    ) !Record {
        const family_name = try dupFaceString(alloc, face.handle.*.family_name, "Unknown");
        errdefer alloc.free(family_name);

        const style_name = try dupFaceString(alloc, face.handle.*.style_name, "Regular");
        errdefer alloc.free(style_name);

        const full_name = try buildFullName(alloc, family_name, style_name);
        errdefer alloc.free(full_name);

        const style_flags = face.handle.*.style_flags;
        const face_flags = face.handle.*.face_flags;

        return .{
            .path = try alloc.dupeZ(u8, path),
            .face_index = face_index,
            .family_name = family_name,
            .style_name = style_name,
            .full_name = full_name,
            .monospace = face_flags & freetype.c.FT_FACE_FLAG_FIXED_WIDTH != 0,
            .bold = style_flags & freetype.c.FT_STYLE_FLAG_BOLD != 0,
            .italic = style_flags & freetype.c.FT_STYLE_FLAG_ITALIC != 0 or
                containsIgnoreCase(style_name, "oblique"),
            .color = face.hasColor() or face.hasSBIX(),
            .variable = face.hasMultipleMasters(),
            .has_codepoint = false,
        };
    }

    fn filterRecords(
        alloc: Allocator,
        records: []const Record,
        desc: Descriptor,
    ) ![]Record {
        var result: std.ArrayListUnmanaged(Record) = .{};
        errdefer result.deinit(alloc);

        for (records) |record| {
            if (!matchesDescriptor(record, desc)) continue;

            var copy = record;
            if (desc.codepoint > 0) {
                copy.has_codepoint = recordHasCodepoint(record, desc.codepoint);
                if (!copy.has_codepoint) continue;
            }

            try result.append(alloc, copy);
        }

        return try result.toOwnedSlice(alloc);
    }

    fn matchesDescriptor(record: Record, desc: Descriptor) bool {
        if (desc.family) |family| {
            if (std.ascii.eqlIgnoreCase(family, "monospace")) {
                if (!record.monospace) return false;
            } else if (!containsIgnoreCase(record.family_name, family) and
                !containsIgnoreCase(record.full_name, family))
            {
                return false;
            }
        }

        if (desc.style) |style| {
            if (!containsIgnoreCase(record.style_name, style) and
                !containsIgnoreCase(record.full_name, style))
            {
                return false;
            }
        }

        if (desc.bold and !record.bold) return false;
        if (desc.italic and !record.italic) return false;
        if (desc.monospace and !record.monospace) return false;

        return true;
    }

    fn score(desc: Descriptor, record: Record) u32 {
        var result: u32 = 0;

        if (desc.codepoint > 0 and record.has_codepoint) result |= 1 << 20;

        if (desc.family) |family| {
            if (std.ascii.eqlIgnoreCase(record.family_name, family)) result |= 1 << 19;
            if (std.ascii.eqlIgnoreCase(record.full_name, family)) result |= 1 << 18;
            if (containsIgnoreCase(record.family_name, family)) result |= 1 << 17;
        }

        if (desc.style) |style| {
            if (std.ascii.eqlIgnoreCase(record.style_name, style)) result |= 1 << 16;
            if (containsIgnoreCase(record.style_name, style)) result |= 1 << 15;
        }

        if (desc.monospace and record.monospace) result |= 1 << 14;
        if (desc.bold and record.bold) result |= 1 << 13;
        if (desc.italic and record.italic) result |= 1 << 12;
        if (desc.variations.len > 0 and record.variable) result |= 1 << 11;
        if (record.color) result |= 1 << 10;

        return result;
    }

    fn recordHasCodepoint(record: Record, codepoint: u32) bool {
        var lib = freetype.Library.init() catch return false;
        defer lib.deinit();

        const face = lib.initFace(record.path, record.face_index) catch return false;
        defer face.deinit();

        face.selectCharmap(.unicode) catch return false;
        return face.getCharIndex(codepoint) != null;
    }

    fn supportedFontFile(name: []const u8) bool {
        const ext = std.fs.path.extension(name);
        return std.ascii.eqlIgnoreCase(ext, ".ttf") or
            std.ascii.eqlIgnoreCase(ext, ".otf") or
            std.ascii.eqlIgnoreCase(ext, ".ttc") or
            std.ascii.eqlIgnoreCase(ext, ".otc");
    }

    fn dupFaceString(
        alloc: Allocator,
        ptr: anytype,
        fallback: []const u8,
    ) ![:0]const u8 {
        const bytes: []const u8 = if (ptr) |value|
            std.mem.span(value)
        else
            fallback;
        return try alloc.dupeZ(u8, bytes);
    }

    fn buildFullName(
        alloc: Allocator,
        family_name: []const u8,
        style_name: []const u8,
    ) ![:0]const u8 {
        if (style_name.len == 0 or std.ascii.eqlIgnoreCase(style_name, "Regular")) {
            return try alloc.dupeZ(u8, family_name);
        }

        const full_name = try std.fmt.allocPrint(alloc, "{s} {s}", .{ family_name, style_name });
        defer alloc.free(full_name);
        return try alloc.dupeZ(u8, full_name);
    }

    fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len == 0) return true;
        if (needle.len > haystack.len) return false;

        var i: usize = 0;
        while (i + needle.len <= haystack.len) : (i += 1) {
            if (std.ascii.eqlIgnoreCase(
                haystack[i .. i + needle.len],
                needle,
            )) return true;
        }

        return false;
    }
};

test "windowsSupportedFontFileHelper" {
    try std.testing.expect(Windows.supportedFontFile("foo.ttf"));
    try std.testing.expect(Windows.supportedFontFile("foo.OTF"));
    try std.testing.expect(Windows.supportedFontFile("foo.ttc"));
    try std.testing.expect(!Windows.supportedFontFile("foo.txt"));
}

test "windowsDescriptorMatchingHelper" {
    const record: Windows.Record = .{
        .path = undefined,
        .face_index = 0,
        .family_name = "Cascadia Mono",
        .style_name = "Bold Italic",
        .full_name = "Cascadia Mono Bold Italic",
        .monospace = true,
        .bold = true,
        .italic = true,
        .color = false,
        .variable = true,
        .has_codepoint = true,
    };

    try std.testing.expect(Windows.matchesDescriptor(record, .{
        .family = "cascadia mono",
        .bold = true,
        .italic = true,
        .monospace = true,
    }));
    try std.testing.expect(!Windows.matchesDescriptor(record, .{
        .family = "Segoe UI",
    }));
}
