const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const harfbuzz = @import("harfbuzz");
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
const quirks = @import("../../quirks.zig");

const log = std.log.scoped(.font_shaper);

/// Shaper that uses Harfbuzz.
pub const Shaper = struct {
    /// The buffer used for text shaping. We reuse it across multiple shaping
    /// calls to prevent allocations.
    hb_buf: harfbuzz.Buffer,

    /// The shared memory used for shaping results.
    cell_buf: []font.shape.Cell,

    /// The features to use for shaping.
    hb_feats: FeatureList,

    const FeatureList = std.ArrayList(harfbuzz.Feature);

    // These features are hardcoded to always be on by default. Users
    // can turn them off by setting the features to "-liga" for example.
    const hardcoded_features = [_][]const u8{ "dlig", "liga" };

    /// The cell_buf argument is the buffer to use for storing shaped results.
    /// This should be at least the number of columns in the terminal.
    pub fn init(alloc: Allocator, opts: font.shape.Options) !Shaper {
        // Parse all the features we want to use. We use
        var hb_feats = hb_feats: {
            var list = try FeatureList.initCapacity(alloc, opts.features.len + hardcoded_features.len);
            errdefer list.deinit();

            for (hardcoded_features) |name| {
                if (harfbuzz.Feature.fromString(name)) |feat| {
                    try list.append(feat);
                } else log.warn("failed to parse font feature: {s}", .{name});
            }

            for (opts.features) |name| {
                if (harfbuzz.Feature.fromString(name)) |feat| {
                    try list.append(feat);
                } else log.warn("failed to parse font feature: {s}", .{name});
            }

            break :hb_feats list;
        };
        errdefer hb_feats.deinit();

        return Shaper{
            .hb_buf = try harfbuzz.Buffer.create(),
            .cell_buf = opts.cell_buf,
            .hb_feats = hb_feats,
        };
    }

    pub fn deinit(self: *Shaper) void {
        self.hb_buf.destroy();
        self.hb_feats.deinit();
    }

    /// Returns an iterator that returns one text run at a time for the
    /// given terminal row. Note that text runs are are only valid one at a time
    /// for a Shaper struct since they share state.
    ///
    /// The selection must be a row-only selection (height = 1). See
    /// Selection.containedRow. The run iterator will ONLY look at X values
    /// and assume the y value matches.
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

    /// Shape the given text run. The text run must be the immediately previous
    /// text run that was iterated since the text run does share state with the
    /// Shaper struct.
    ///
    /// The return value is only valid until the next shape call is called.
    ///
    /// If there is not enough space in the cell buffer, an error is returned.
    pub fn shape(self: *Shaper, run: font.shape.TextRun) ![]font.shape.Cell {
        const tracy = trace(@src());
        defer tracy.end();

        // We only do shaping if the font is not a special-case. For special-case
        // fonts, the codepoint == glyph_index so we don't need to run any shaping.
        if (run.font_index.special() == null) {
            const face = try run.group.group.faceFromIndex(run.font_index);
            const i = if (!quirks.disableDefaultFontFeatures(face)) 0 else i: {
                // If we are disabling default font features we just offset
                // our features by the hardcoded items because always
                // add those at the beginning.
                break :i hardcoded_features.len;
            };

            harfbuzz.shape(face.hb_font, self.hb_buf, self.hb_feats.items[i..]);
        }

        // If our buffer is empty, we short-circuit the rest of the work
        // return nothing.
        if (self.hb_buf.getLength() == 0) return self.cell_buf[0..0];
        const info = self.hb_buf.getGlyphInfos();
        const pos = self.hb_buf.getGlyphPositions() orelse return error.HarfbuzzFailed;

        // This is perhaps not true somewhere, but we currently assume it is true.
        // If it isn't true, I'd like to catch it and learn more.
        assert(info.len == pos.len);

        // Convert all our info/pos to cells and set it.
        if (info.len > self.cell_buf.len) return error.OutOfMemory;
        //log.warn("info={} pos={} run={}", .{ info.len, pos.len, run });

        for (info, 0..) |v, i| {
            self.cell_buf[i] = .{
                .x = @intCast(v.cluster),
                .glyph_index = v.codepoint,
            };

            //log.warn("i={} info={} pos={} cell={}", .{ i, v, pos[i], self.cell_buf[i] });
        }

        return self.cell_buf[0..info.len];
    }

    /// The hooks for RunIterator.
    pub const RunIteratorHook = struct {
        shaper: *Shaper,

        pub fn prepare(self: RunIteratorHook) !void {
            // Reset the buffer for our current run
            self.shaper.hb_buf.reset();
            self.shaper.hb_buf.setContentType(.unicode);
        }

        pub fn addCodepoint(self: RunIteratorHook, cp: u32, cluster: u32) !void {
            self.shaper.hb_buf.add(cp, cluster);
        }

        pub fn finalize(self: RunIteratorHook) !void {
            self.shaper.hb_buf.guessSegmentProperties();
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
        var shaper = testdata.shaper;
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

        var shaper = testdata.shaper;
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
        var shaper = testdata.shaper;
        var it = shaper.runIterator(testdata.cache, screen.getRow(.{ .screen = 0 }), null, null);
        var count: usize = 0;
        while (try it.next(alloc)) |_| {
            count += 1;

            // All runs should be exactly length 1
            try testing.expectEqual(@as(u32, 1), shaper.hb_buf.getLength());
        }
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
        try screen.testWriteString("A");

        // Get our first row
        const row = screen.getRow(.{ .active = 0 });
        row.getCellPtr(1).bg = try terminal.color.Name.cyan.default();
        row.getCellPtr(1).attrs.has_bg = true;
        row.getCellPtr(2).fg = try terminal.color.Name.yellow.default();
        row.getCellPtr(2).attrs.has_fg = true;

        // Get our run iterator
        var shaper = testdata.shaper;
        var it = shaper.runIterator(testdata.cache, screen.getRow(.{ .screen = 0 }), null, null);
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;

            // The run should have length 3 because of the two background
            // cells.
            try testing.expectEqual(@as(u32, 3), shaper.hb_buf.getLength());
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
    var shaper = testdata.shaper;
    var it = shaper.runIterator(testdata.cache, screen.getRow(.{ .screen = 0 }), null, null);
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;
        try testing.expectEqual(@as(u32, 3), shaper.hb_buf.getLength());
        _ = try shaper.shape(run);
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "shape inconsolata ligs" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    {
        var screen = try terminal.Screen.init(alloc, 3, 5, 0);
        defer screen.deinit();
        try screen.testWriteString(">=");

        var shaper = testdata.shaper;
        var it = shaper.runIterator(testdata.cache, screen.getRow(.{ .screen = 0 }), null, null);
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;

            const cells = try shaper.shape(run);
            try testing.expectEqual(@as(usize, 1), cells.len);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }

    {
        var screen = try terminal.Screen.init(alloc, 3, 5, 0);
        defer screen.deinit();
        try screen.testWriteString("===");

        var shaper = testdata.shaper;
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

test "shape emoji width" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    {
        var screen = try terminal.Screen.init(alloc, 3, 5, 0);
        defer screen.deinit();
        try screen.testWriteString("👍");

        var shaper = testdata.shaper;
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
    var shaper = testdata.shaper;
    var it = shaper.runIterator(testdata.cache, screen.getRow(.{ .screen = 0 }), null, null);
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;
        try testing.expectEqual(@as(u32, 4), shaper.hb_buf.getLength());

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
    var shaper = testdata.shaper;
    var it = shaper.runIterator(testdata.cache, screen.getRow(.{ .screen = 0 }), null, null);
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;
        try testing.expectEqual(@as(u32, 1), shaper.hb_buf.getLength());

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
    var shaper = testdata.shaper;
    var it = shaper.runIterator(testdata.cache, screen.getRow(.{ .screen = 0 }), null, null);
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;
        try testing.expectEqual(@as(u32, 1), shaper.hb_buf.getLength());

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
    var shaper = testdata.shaper;
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
    var shaper = testdata.shaper;
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
    var shaper = testdata.shaper;
    var it = shaper.runIterator(testdata.cache, screen.getRow(.{ .screen = 0 }), null, null);
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;
        try testing.expectEqual(@as(u32, 2), shaper.hb_buf.getLength());
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
        var shaper = testdata.shaper;
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
        var shaper = testdata.shaper;
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
        var shaper = testdata.shaper;
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
        var shaper = testdata.shaper;
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
        var shaper = testdata.shaper;
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
        var shaper = testdata.shaper;
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
        var shaper = testdata.shaper;
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
        var shaper = testdata.shaper;
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
        var shaper = testdata.shaper;
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
        var shaper = testdata.shaper;
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
        var shaper = testdata.shaper;
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
        var shaper = testdata.shaper;
        var it = shaper.runIterator(testdata.cache, screen.getRow(.{ .screen = 0 }), null, 1);
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
    cell_buf: []font.shape.Cell,

    pub fn deinit(self: *TestShaper) void {
        self.shaper.deinit();
        self.cache.deinit(self.alloc);
        self.alloc.destroy(self.cache);
        self.alloc.free(self.cell_buf);
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
    try cache_ptr.group.addFace(alloc, .regular, DeferredFace.initLoaded(try Face.init(lib, testFont, .{ .points = 12 })));
    if (font.options.backend != .coretext) {
        // Coretext doesn't support Noto's format
        try cache_ptr.group.addFace(alloc, .regular, DeferredFace.initLoaded(try Face.init(lib, testEmoji, .{ .points = 12 })));
    }
    try cache_ptr.group.addFace(alloc, .regular, DeferredFace.initLoaded(try Face.init(lib, testEmojiText, .{ .points = 12 })));

    var cell_buf = try alloc.alloc(font.shape.Cell, 80);
    errdefer alloc.free(cell_buf);

    var shaper = try Shaper.init(alloc, .{ .cell_buf = cell_buf });
    errdefer shaper.deinit();

    return TestShaper{
        .alloc = alloc,
        .shaper = shaper,
        .cache = cache_ptr,
        .lib = lib,
        .cell_buf = cell_buf,
    };
}
