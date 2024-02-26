const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const harfbuzz = @import("harfbuzz");
const macos = @import("macos");
const trace = @import("tracy").trace;
const font = @import("../main.zig");
const Face = font.Face;
const DeferredFace = font.DeferredFace;
const Group = font.Group;
const GroupCache = font.GroupCache;
const Library = font.Library;
const Style = font.Style;
const Presentation = font.Presentation;
const terminal = @import("../../terminal/main.zig");

const log = std.log.scoped(.font_shaper);

/// Shaper that uses CoreText.
///
/// WARNING: This is not ready for production usage. This is why this shaper
/// can't be configured at build-time without modifying the source. There are
/// a couple major missing features (quirks mode, font features) and I haven't
/// very carefully audited all my memory management.
///
/// The purpose of this shaper is to keep us honest with our other shapers
/// and to help us find bugs in our other shapers.
pub const Shaper = struct {
    /// The allocated used for the feature list and cell buf.
    alloc: Allocator,

    /// The string used for shaping the current run.
    codepoints: CodepointList = .{},

    /// The font features we want to use. The hardcoded features are always
    /// set first.
    features: FeatureList = .{},

    /// The shared memory used for shaping results.
    cell_buf: CellBuf,

    const CellBuf = std.ArrayListUnmanaged(font.shape.Cell);
    const CodepointList = std.ArrayListUnmanaged(Codepoint);
    const Codepoint = struct {
        codepoint: u32,
        cluster: u32,
    };

    const FeatureList = std.ArrayListUnmanaged(Feature);
    const Feature = struct {
        key: *macos.foundation.String,
        value: *macos.foundation.Number,

        pub fn init(name_raw: []const u8) !Feature {
            const name = if (name_raw[0] == '-') name_raw[1..] else name_raw;
            const value_num: c_int = if (name_raw[0] == '-') 0 else 1;

            var key = try macos.foundation.String.createWithBytes(name, .utf8, false);
            errdefer key.release();
            var value = try macos.foundation.Number.create(.int, &value_num);
            defer value.release();

            return .{ .key = key, .value = value };
        }

        pub fn deinit(self: Feature) void {
            self.key.release();
            self.value.release();
        }
    };

    // These features are hardcoded to always be on by default. Users
    // can turn them off by setting the features to "-liga" for example.
    const hardcoded_features = [_][]const u8{ "dlig", "liga" };

    /// The cell_buf argument is the buffer to use for storing shaped results.
    /// This should be at least the number of columns in the terminal.
    pub fn init(alloc: Allocator, opts: font.shape.Options) !Shaper {
        var feats: FeatureList = .{};
        errdefer {
            for (feats.items) |feature| feature.deinit();
            feats.deinit(alloc);
        }

        for (hardcoded_features) |name| {
            const feat = try Feature.init(name);
            errdefer feat.deinit();
            try feats.append(alloc, feat);
        }

        for (opts.features) |name| {
            const feat = try Feature.init(name);
            errdefer feat.deinit();
            try feats.append(alloc, feat);
        }

        return Shaper{
            .alloc = alloc,
            .cell_buf = .{},
            .features = feats,
        };
    }

    pub fn deinit(self: *Shaper) void {
        self.cell_buf.deinit(self.alloc);
        self.codepoints.deinit(self.alloc);
        for (self.features.items) |feature| feature.deinit();
        self.features.deinit(self.alloc);
    }

    pub fn runIterator(
        self: *Shaper,
        group: *GroupCache,
        row: terminal.Screen.Row,
        selection: ?terminal.Selection,
        cursor_x: ?usize,
    ) font.shape.RunIterator {
        return .{
            .hooks = .{ .shaper = self },
            .group = group,
            .row = row,
            .selection = selection,
            .cursor_x = cursor_x,
        };
    }

    pub fn shape(self: *Shaper, run: font.shape.TextRun) ![]const font.shape.Cell {
        // TODO: quirks fonts
        // TODO: font features

        // Special fonts aren't shaped and their codepoint == glyph so we
        // can just return the codepoints as-is.
        if (run.font_index.special() != null) {
            self.cell_buf.clearRetainingCapacity();
            try self.cell_buf.ensureTotalCapacity(self.alloc, self.codepoints.items.len);
            for (self.codepoints.items) |entry| {
                self.cell_buf.appendAssumeCapacity(.{
                    .x = @intCast(entry.cluster),
                    .glyph_index = @intCast(entry.codepoint),
                });
            }

            return self.cell_buf.items;
        }

        // Create an arena for any Zig-based allocations we do
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const alloc = arena.allocator();

        // Build up our string contents
        const str = str: {
            const str = try macos.foundation.MutableString.create(0);
            errdefer str.release();

            for (self.codepoints.items) |entry| {
                var unichars: [2]u16 = undefined;
                const pair = macos.foundation.stringGetSurrogatePairForLongCharacter(
                    entry.codepoint,
                    &unichars,
                );
                const len: usize = if (pair) 2 else 1;
                str.appendCharacters(unichars[0..len]);
                // log.warn("append codepoint={} unichar_len={}", .{ cp, len });
            }

            break :str str;
        };
        defer str.release();

        // Get our font and use that get the attributes to set for the
        // attributed string so the whole string uses the same font.
        const attr_dict = dict: {
            const face = try run.group.group.faceFromIndex(run.font_index);
            var keys = [_]?*const anyopaque{macos.text.StringAttribute.font.key()};
            var values = [_]?*const anyopaque{face.font};
            break :dict try macos.foundation.Dictionary.create(&keys, &values);
        };
        defer attr_dict.release();

        // Create an attributed string from our string
        const attr_str = try macos.foundation.AttributedString.create(
            str.string(),
            attr_dict,
        );
        defer attr_str.release();

        // We should always have one run because we do our own run splitting.
        const line = try macos.text.Line.createWithAttributedString(attr_str);
        defer line.release();
        const runs = line.getGlyphRuns();
        assert(runs.getCount() == 1);
        const ctrun = runs.getValueAtIndex(macos.text.Run, 0);

        // Get our glyphs and positions
        const glyphs = try ctrun.getGlyphs(alloc);
        const positions = try ctrun.getPositions(alloc);
        const advances = try ctrun.getAdvances(alloc);
        const indices = try ctrun.getStringIndices(alloc);
        assert(glyphs.len == positions.len);
        assert(glyphs.len == advances.len);
        assert(glyphs.len == indices.len);

        // This keeps track of the current offsets within a single cell.
        var cell_offset: struct {
            cluster: u32 = 0,
            x: f64 = 0,
            y: f64 = 0,
        } = .{};

        self.cell_buf.clearRetainingCapacity();
        try self.cell_buf.ensureTotalCapacity(self.alloc, glyphs.len);
        for (glyphs, positions, advances, indices) |glyph, pos, advance, index| {
            // Our cluster is also our cell X position. If the cluster changes
            // then we need to reset our current cell offsets.
            const cluster = self.codepoints.items[index].cluster;
            if (cell_offset.cluster != cluster) cell_offset = .{
                .cluster = cluster,
            };

            self.cell_buf.appendAssumeCapacity(.{
                .x = @intCast(cluster),
                .x_offset = @intFromFloat(@round(cell_offset.x)),
                .y_offset = @intFromFloat(@round(cell_offset.y)),
                .glyph_index = glyph,
            });

            // Add our advances to keep track of our current cell offsets.
            // Advances apply to the NEXT cell.
            cell_offset.x += advance.width;
            cell_offset.y += advance.height;

            // TODO: harfbuzz shaper has handling for inserting blank
            // cells for multi-cell ligatures. Do we need to port that?
            // Example: try Monaspace "===" with a background color.

            _ = pos;
            // const i = self.cell_buf.items.len - 1;
            // log.warn(
            //     "i={} codepoint={} glyph={} pos={} advance={} index={} cluster={}",
            //     .{ i, self.codepoints.items[index].codepoint, glyph, pos, advance, index, cluster },
            // );
        }
        //log.warn("-------------------------------", .{});

        return self.cell_buf.items;
    }

    /// The hooks for RunIterator.
    pub const RunIteratorHook = struct {
        shaper: *Shaper,

        pub fn prepare(self: *RunIteratorHook) !void {
            self.shaper.codepoints.clearRetainingCapacity();
        }

        pub fn addCodepoint(self: RunIteratorHook, cp: u32, cluster: u32) !void {
            try self.shaper.codepoints.append(self.shaper.alloc, .{
                .codepoint = cp,
                .cluster = cluster,
            });
        }

        pub fn finalize(self: RunIteratorHook) !void {
            _ = self;
        }
    };
};

test "run iterator" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    {
        // Make a screen with some data
        var screen = try terminal.Screen.init(alloc, 3, 5, 0);
        defer screen.deinit();
        try screen.testWriteString("ABCD");

        // Get our run iterator
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(testdata.cache, screen.getRow(.{ .screen = 0 }), null, null);
        var count: usize = 0;
        while (try it.next(alloc)) |_| count += 1;
        try testing.expectEqual(@as(usize, 1), count);
    }

    // Spaces should be part of a run
    {
        var screen = try terminal.Screen.init(alloc, 3, 10, 0);
        defer screen.deinit();
        try screen.testWriteString("ABCD   EFG");

        var shaper = &testdata.shaper;
        var it = shaper.runIterator(testdata.cache, screen.getRow(.{ .screen = 0 }), null, null);
        var count: usize = 0;
        while (try it.next(alloc)) |_| count += 1;
        try testing.expectEqual(@as(usize, 1), count);
    }

    {
        // Make a screen with some data
        var screen = try terminal.Screen.init(alloc, 3, 5, 0);
        defer screen.deinit();
        try screen.testWriteString("A😃D");

        // Get our run iterator
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(testdata.cache, screen.getRow(.{ .screen = 0 }), null, null);
        var count: usize = 0;
        while (try it.next(alloc)) |_| count += 1;
        try testing.expectEqual(@as(usize, 3), count);
    }
}

test "run iterator: empty cells with background set" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    {
        // Make a screen with some data
        var screen = try terminal.Screen.init(alloc, 3, 5, 0);
        defer screen.deinit();
        screen.cursor.pen.bg = try terminal.color.Name.cyan.default();
        screen.cursor.pen.attrs.has_bg = true;
        try screen.testWriteString("A");

        // Get our first row
        const row = screen.getRow(.{ .active = 0 });
        row.getCellPtr(1).* = screen.cursor.pen;
        row.getCellPtr(2).* = screen.cursor.pen;

        // Get our run iterator
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(testdata.cache, screen.getRow(.{ .screen = 0 }), null, null);
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;

            // The run should have length 3 because of the two background
            // cells.
            try testing.expectEqual(@as(usize, 3), shaper.codepoints.items.len);
            const cells = try shaper.shape(run);
            try testing.expectEqual(@as(usize, 3), cells.len);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }
}

test "shape" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;
    buf_idx += try std.unicode.utf8Encode(0x1F44D, buf[buf_idx..]); // Thumbs up plain
    buf_idx += try std.unicode.utf8Encode(0x1F44D, buf[buf_idx..]); // Thumbs up plain
    buf_idx += try std.unicode.utf8Encode(0x1F3FD, buf[buf_idx..]); // Medium skin tone

    // Make a screen with some data
    var screen = try terminal.Screen.init(alloc, 3, 10, 0);
    defer screen.deinit();
    try screen.testWriteString(buf[0..buf_idx]);

    // Get our run iterator
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(testdata.cache, screen.getRow(.{ .screen = 0 }), null, null);
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;
        _ = try shaper.shape(run);
    }
    try testing.expectEqual(@as(usize, 1), count);
}

// test "shape inconsolata ligs" {
//     const testing = std.testing;
//     const alloc = testing.allocator;
//
//     var testdata = try testShaper(alloc);
//     defer testdata.deinit();
//
//     {
//         var screen = try terminal.Screen.init(alloc, 3, 5, 0);
//         defer screen.deinit();
//         try screen.testWriteString(">=");
//
//         var shaper = &testdata.shaper;
//         var it = shaper.runIterator(testdata.cache, screen.getRow(.{ .screen = 0 }), null, null);
//         var count: usize = 0;
//         while (try it.next(alloc)) |run| {
//             count += 1;
//
//             const cells = try shaper.shape(run);
//             try testing.expectEqual(@as(usize, 1), cells.len);
//         }
//         try testing.expectEqual(@as(usize, 1), count);
//     }
//
//     {
//         var screen = try terminal.Screen.init(alloc, 3, 5, 0);
//         defer screen.deinit();
//         try screen.testWriteString("===");
//
//         var shaper = &testdata.shaper;
//         var it = shaper.runIterator(testdata.cache, screen.getRow(.{ .screen = 0 }), null, null);
//         var count: usize = 0;
//         while (try it.next(alloc)) |run| {
//             count += 1;
//
//             const cells = try shaper.shape(run);
//             try testing.expectEqual(@as(usize, 1), cells.len);
//         }
//         try testing.expectEqual(@as(usize, 1), count);
//     }
// }

test "shape emoji width" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    {
        var screen = try terminal.Screen.init(alloc, 3, 5, 0);
        defer screen.deinit();
        try screen.testWriteString("👍");

        var shaper = &testdata.shaper;
        var it = shaper.runIterator(testdata.cache, screen.getRow(.{ .screen = 0 }), null, null);
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;

            const cells = try shaper.shape(run);
            try testing.expectEqual(@as(usize, 1), cells.len);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }
}

test "shape emoji width long" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;
    buf_idx += try std.unicode.utf8Encode(0x1F9D4, buf[buf_idx..]); // man: beard
    buf_idx += try std.unicode.utf8Encode(0x1F3FB, buf[buf_idx..]); // light skin tone (Fitz 1-2)
    buf_idx += try std.unicode.utf8Encode(0x200D, buf[buf_idx..]); // ZWJ
    buf_idx += try std.unicode.utf8Encode(0x2642, buf[buf_idx..]); // male sign
    buf_idx += try std.unicode.utf8Encode(0xFE0F, buf[buf_idx..]); // emoji representation

    // Make a screen with some data
    var screen = try terminal.Screen.init(alloc, 3, 30, 0);
    defer screen.deinit();
    try screen.testWriteString(buf[0..buf_idx]);

    // Get our run iterator
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(testdata.cache, screen.getRow(.{ .screen = 0 }), null, null);
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;
        const cells = try shaper.shape(run);
        try testing.expectEqual(@as(usize, 1), cells.len);
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "shape variation selector VS15" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;
    buf_idx += try std.unicode.utf8Encode(0x270C, buf[buf_idx..]); // Victory sign (default text)
    buf_idx += try std.unicode.utf8Encode(0xFE0E, buf[buf_idx..]); // ZWJ to force text

    // Make a screen with some data
    var screen = try terminal.Screen.init(alloc, 3, 10, 0);
    defer screen.deinit();
    try screen.testWriteString(buf[0..buf_idx]);

    // Get our run iterator
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(testdata.cache, screen.getRow(.{ .screen = 0 }), null, null);
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;
        const cells = try shaper.shape(run);
        try testing.expectEqual(@as(usize, 1), cells.len);
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "shape variation selector VS16" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;
    buf_idx += try std.unicode.utf8Encode(0x270C, buf[buf_idx..]); // Victory sign (default text)
    buf_idx += try std.unicode.utf8Encode(0xFE0F, buf[buf_idx..]); // ZWJ to force color

    // Make a screen with some data
    var screen = try terminal.Screen.init(alloc, 3, 10, 0);
    defer screen.deinit();
    try screen.testWriteString(buf[0..buf_idx]);

    // Get our run iterator
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(testdata.cache, screen.getRow(.{ .screen = 0 }), null, null);
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;
        const cells = try shaper.shape(run);
        try testing.expectEqual(@as(usize, 1), cells.len);
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "shape with empty cells in between" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    // Make a screen with some data
    var screen = try terminal.Screen.init(alloc, 3, 30, 0);
    defer screen.deinit();
    try screen.testWriteString("A");
    screen.cursor.x += 5;
    try screen.testWriteString("B");

    // Get our run iterator
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(testdata.cache, screen.getRow(.{ .screen = 0 }), null, null);
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;

        const cells = try shaper.shape(run);
        try testing.expectEqual(@as(usize, 7), cells.len);
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "shape Chinese characters" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;
    buf_idx += try std.unicode.utf8Encode('n', buf[buf_idx..]); // Combining
    buf_idx += try std.unicode.utf8Encode(0x0308, buf[buf_idx..]); // Combining
    buf_idx += try std.unicode.utf8Encode(0x0308, buf[buf_idx..]);
    buf_idx += try std.unicode.utf8Encode('a', buf[buf_idx..]);

    // Make a screen with some data
    var screen = try terminal.Screen.init(alloc, 3, 30, 0);
    defer screen.deinit();
    try screen.testWriteString(buf[0..buf_idx]);

    // Get our run iterator
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(testdata.cache, screen.getRow(.{ .screen = 0 }), null, null);
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;

        const cells = try shaper.shape(run);
        try testing.expectEqual(@as(usize, 4), cells.len);
        try testing.expectEqual(@as(u16, 0), cells[0].x);
        try testing.expectEqual(@as(u16, 0), cells[1].x);
        try testing.expectEqual(@as(u16, 0), cells[2].x);
        try testing.expectEqual(@as(u16, 1), cells[3].x);
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "shape box glyphs" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    // Setup the box font
    testdata.cache.group.sprite = font.sprite.Face{
        .width = 18,
        .height = 36,
        .thickness = 2,
        .cursor_thickness_adjustment = 0,
    };

    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;
    buf_idx += try std.unicode.utf8Encode(0x2500, buf[buf_idx..]); // horiz line
    buf_idx += try std.unicode.utf8Encode(0x2501, buf[buf_idx..]); //

    // Make a screen with some data
    var screen = try terminal.Screen.init(alloc, 3, 10, 0);
    defer screen.deinit();
    try screen.testWriteString(buf[0..buf_idx]);

    // Get our run iterator
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(testdata.cache, screen.getRow(.{ .screen = 0 }), null, null);
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;
        //try testing.expectEqual(@as(u32, 2), shaper.hb_buf.getLength());
        const cells = try shaper.shape(run);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u32, 0x2500), cells[0].glyph_index);
        try testing.expectEqual(@as(u16, 0), cells[0].x);
        try testing.expectEqual(@as(u32, 0x2501), cells[1].glyph_index);
        try testing.expectEqual(@as(u16, 1), cells[1].x);
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "shape selection boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    // Make a screen with some data
    var screen = try terminal.Screen.init(alloc, 3, 10, 0);
    defer screen.deinit();
    try screen.testWriteString("a1b2c3d4e5");

    // Full line selection
    {
        // Get our run iterator
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(testdata.cache, screen.getRow(.{ .screen = 0 }), .{
            .start = .{ .x = 0, .y = 0 },
            .end = .{ .x = screen.cols - 1, .y = 0 },
        }, null);
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }

    // Offset x, goes to end of line selection
    {
        // Get our run iterator
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(testdata.cache, screen.getRow(.{ .screen = 0 }), .{
            .start = .{ .x = 2, .y = 0 },
            .end = .{ .x = screen.cols - 1, .y = 0 },
        }, null);
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 2), count);
    }

    // Offset x, starts at beginning of line
    {
        // Get our run iterator
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(testdata.cache, screen.getRow(.{ .screen = 0 }), .{
            .start = .{ .x = 0, .y = 0 },
            .end = .{ .x = 3, .y = 0 },
        }, null);
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 2), count);
    }

    // Selection only subset of line
    {
        // Get our run iterator
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(testdata.cache, screen.getRow(.{ .screen = 0 }), .{
            .start = .{ .x = 1, .y = 0 },
            .end = .{ .x = 3, .y = 0 },
        }, null);
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 3), count);
    }

    // Selection only one character
    {
        // Get our run iterator
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(testdata.cache, screen.getRow(.{ .screen = 0 }), .{
            .start = .{ .x = 1, .y = 0 },
            .end = .{ .x = 1, .y = 0 },
        }, null);
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 3), count);
    }
}

test "shape cursor boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    // Make a screen with some data
    var screen = try terminal.Screen.init(alloc, 3, 10, 0);
    defer screen.deinit();
    try screen.testWriteString("a1b2c3d4e5");

    // No cursor is full line
    {
        // Get our run iterator
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(testdata.cache, screen.getRow(.{ .screen = 0 }), null, null);
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }

    // Cursor at index 0 is two runs
    {
        // Get our run iterator
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(testdata.cache, screen.getRow(.{ .screen = 0 }), null, 0);
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 2), count);
    }

    // Cursor at index 1 is three runs
    {
        // Get our run iterator
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(testdata.cache, screen.getRow(.{ .screen = 0 }), null, 1);
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 3), count);
    }

    // Cursor at last col is two runs
    {
        // Get our run iterator
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(testdata.cache, screen.getRow(.{ .screen = 0 }), null, 9);
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 2), count);
    }
}

test "shape cursor boundary and colored emoji" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    // Make a screen with some data
    var screen = try terminal.Screen.init(alloc, 3, 10, 0);
    defer screen.deinit();
    try screen.testWriteString("👍🏼");

    // No cursor is full line
    {
        // Get our run iterator
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(testdata.cache, screen.getRow(.{ .screen = 0 }), null, null);
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }

    // Cursor on emoji does not split it
    {
        // Get our run iterator
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(testdata.cache, screen.getRow(.{ .screen = 0 }), null, 0);
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }
    {
        // Get our run iterator
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(testdata.cache, screen.getRow(.{ .screen = 0 }), null, 1);
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }
}

test "shape cell attribute change" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    // Plain >= should shape into 1 run
    {
        var screen = try terminal.Screen.init(alloc, 3, 10, 0);
        defer screen.deinit();
        try screen.testWriteString(">=");

        var shaper = &testdata.shaper;
        var it = shaper.runIterator(testdata.cache, screen.getRow(.{ .screen = 0 }), null, null);
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }

    // Bold vs regular should split
    {
        var screen = try terminal.Screen.init(alloc, 3, 10, 0);
        defer screen.deinit();
        try screen.testWriteString(">");
        screen.cursor.pen.attrs.bold = true;
        try screen.testWriteString("=");

        var shaper = &testdata.shaper;
        var it = shaper.runIterator(testdata.cache, screen.getRow(.{ .screen = 0 }), null, null);
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 2), count);
    }

    // Changing fg color should split
    {
        var screen = try terminal.Screen.init(alloc, 3, 10, 0);
        defer screen.deinit();
        screen.cursor.pen.attrs.has_fg = true;
        screen.cursor.pen.fg = .{ .r = 1, .g = 2, .b = 3 };
        try screen.testWriteString(">");
        screen.cursor.pen.fg = .{ .r = 3, .g = 2, .b = 1 };
        try screen.testWriteString("=");

        var shaper = &testdata.shaper;
        var it = shaper.runIterator(testdata.cache, screen.getRow(.{ .screen = 0 }), null, null);
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 2), count);
    }

    // Changing bg color should split
    {
        var screen = try terminal.Screen.init(alloc, 3, 10, 0);
        defer screen.deinit();
        screen.cursor.pen.attrs.has_bg = true;
        screen.cursor.pen.bg = .{ .r = 1, .g = 2, .b = 3 };
        try screen.testWriteString(">");
        screen.cursor.pen.bg = .{ .r = 3, .g = 2, .b = 1 };
        try screen.testWriteString("=");

        var shaper = &testdata.shaper;
        var it = shaper.runIterator(testdata.cache, screen.getRow(.{ .screen = 0 }), null, null);
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 2), count);
    }

    // Same bg color should not split
    {
        var screen = try terminal.Screen.init(alloc, 3, 10, 0);
        defer screen.deinit();
        screen.cursor.pen.attrs.has_bg = true;
        screen.cursor.pen.bg = .{ .r = 1, .g = 2, .b = 3 };
        try screen.testWriteString(">");
        try screen.testWriteString("=");

        var shaper = &testdata.shaper;
        var it = shaper.runIterator(testdata.cache, screen.getRow(.{ .screen = 0 }), null, null);
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }
}

const TestShaper = struct {
    alloc: Allocator,
    shaper: Shaper,
    cache: *GroupCache,
    lib: Library,

    pub fn deinit(self: *TestShaper) void {
        self.shaper.deinit();
        self.cache.deinit(self.alloc);
        self.alloc.destroy(self.cache);
        self.lib.deinit();
    }
};

/// Helper to return a fully initialized shaper.
fn testShaper(alloc: Allocator) !TestShaper {
    const testFont = @import("../test.zig").fontRegular;
    const testEmoji = @import("../test.zig").fontEmoji;
    const testEmojiText = @import("../test.zig").fontEmojiText;

    var lib = try Library.init();
    errdefer lib.deinit();

    var cache_ptr = try alloc.create(GroupCache);
    errdefer alloc.destroy(cache_ptr);
    cache_ptr.* = try GroupCache.init(alloc, try Group.init(
        alloc,
        lib,
        .{ .points = 12 },
    ));
    errdefer cache_ptr.*.deinit(alloc);

    // Setup group
    _ = try cache_ptr.group.addFace(.regular, .{ .loaded = try Face.init(
        lib,
        testFont,
        .{ .size = .{ .points = 12 } },
    ) });

    if (font.options.backend != .coretext) {
        // Coretext doesn't support Noto's format
        _ = try cache_ptr.group.addFace(.regular, .{ .loaded = try Face.init(
            lib,
            testEmoji,
            .{ .size = .{ .points = 12 } },
        ) });
    } else {
        // On CoreText we want to load Apple Emoji, we should have it.
        var disco = font.Discover.init();
        defer disco.deinit();
        var disco_it = try disco.discover(alloc, .{
            .family = "Apple Color Emoji",
            .size = 12,
            .monospace = false,
        });
        defer disco_it.deinit();
        var face = (try disco_it.next()).?;
        errdefer face.deinit();
        _ = try cache_ptr.group.addFace(.regular, .{ .deferred = face });
    }
    _ = try cache_ptr.group.addFace(.regular, .{ .loaded = try Face.init(
        lib,
        testEmojiText,
        .{ .size = .{ .points = 12 } },
    ) });

    var shaper = try Shaper.init(alloc, .{});
    errdefer shaper.deinit();

    return TestShaper{
        .alloc = alloc,
        .shaper = shaper,
        .cache = cache_ptr,
        .lib = lib,
    };
}
