const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const harfbuzz = @import("harfbuzz");
const font = @import("../main.zig");
const terminal = @import("../../terminal/main.zig");
const config = @import("../../config.zig");
const Feature = font.shape.Feature;
const FeatureList = font.shape.FeatureList;
const default_features = font.shape.default_features;
const Face = font.Face;
const Collection = font.Collection;
const DeferredFace = font.DeferredFace;
const Library = font.Library;
const SharedGrid = font.SharedGrid;
const Style = font.Style;
const Presentation = font.Presentation;

const log = std.log.scoped(.font_shaper);

/// Shaper that uses Harfbuzz.
pub const Shaper = struct {
    /// The allocated used for the feature list and cell buf.
    alloc: Allocator,

    /// The buffer used for text shaping. We reuse it across multiple shaping
    /// calls to prevent allocations.
    hb_buf: harfbuzz.Buffer,

    /// The shared memory used for shaping results.
    cell_buf: CellBuf,

    /// The features to use for shaping.
    hb_feats: []harfbuzz.Feature,

    const CellBuf = std.ArrayListUnmanaged(font.shape.Cell);

    /// The cell_buf argument is the buffer to use for storing shaped results.
    /// This should be at least the number of columns in the terminal.
    pub fn init(alloc: Allocator, opts: font.shape.Options) !Shaper {
        // Parse all the features we want to use.
        const hb_feats = hb_feats: {
            var feature_list: FeatureList = .{};
            defer feature_list.deinit(alloc);
            try feature_list.features.appendSlice(alloc, &default_features);
            for (opts.features) |feature_str| {
                try feature_list.appendFromString(alloc, feature_str);
            }

            var list = try alloc.alloc(harfbuzz.Feature, feature_list.features.items.len);
            errdefer alloc.free(list);

            for (feature_list.features.items, 0..) |feature, i| {
                list[i] = .{
                    .tag = std.mem.nativeToBig(u32, @bitCast(feature.tag)),
                    .value = feature.value,
                    .start = harfbuzz.c.HB_FEATURE_GLOBAL_START,
                    .end = harfbuzz.c.HB_FEATURE_GLOBAL_END,
                };
            }

            break :hb_feats list;
        };
        errdefer alloc.free(hb_feats);

        return Shaper{
            .alloc = alloc,
            .hb_buf = try harfbuzz.Buffer.create(),
            .cell_buf = .{},
            .hb_feats = hb_feats,
        };
    }

    pub fn deinit(self: *Shaper) void {
        self.hb_buf.destroy();
        self.cell_buf.deinit(self.alloc);
        self.alloc.free(self.hb_feats);
    }

    pub fn endFrame(self: *const Shaper) void {
        _ = self;
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
        opts: font.shape.RunOptions,
    ) font.shape.RunIterator {
        return .{
            .hooks = .{ .shaper = self },
            .opts = opts,
        };
    }

    /// Shape the given text run. The text run must be the immediately previous
    /// text run that was iterated since the text run does share state with the
    /// Shaper struct.
    ///
    /// The return value is only valid until the next shape call is called.
    ///
    /// If there is not enough space in the cell buffer, an error is returned.
    pub fn shape(self: *Shaper, run: font.shape.TextRun) ![]const font.shape.Cell {
        // We only do shaping if the font is not a special-case. For special-case
        // fonts, the codepoint == glyph_index so we don't need to run any shaping.
        if (run.font_index.special() == null) {
            // We have to lock the grid to get the face and unfortunately
            // freetype faces (typically used with harfbuzz) are not thread
            // safe so this has to be an exclusive lock.
            run.grid.lock.lock();
            defer run.grid.lock.unlock();

            const face = try run.grid.resolver.collection.getFace(run.font_index);
            const i = if (!face.quirks_disable_default_font_features) 0 else i: {
                // If we are disabling default font features we just offset
                // our features by the hardcoded items because always
                // add those at the beginning.
                break :i default_features.len;
            };

            harfbuzz.shape(face.hb_font, self.hb_buf, self.hb_feats[i..]);
        }

        // If our buffer is empty, we short-circuit the rest of the work
        // return nothing.
        if (self.hb_buf.getLength() == 0) return self.cell_buf.items[0..0];
        const info = self.hb_buf.getGlyphInfos();
        const pos = self.hb_buf.getGlyphPositions() orelse return error.HarfbuzzFailed;

        // This is perhaps not true somewhere, but we currently assume it is true.
        // If it isn't true, I'd like to catch it and learn more.
        assert(info.len == pos.len);

        // This keeps track of the current offsets within a single cell.
        var cell_offset: struct {
            cluster: u32 = 0,
            x: i32 = 0,
            y: i32 = 0,
        } = .{};

        // Convert all our info/pos to cells and set it.
        self.cell_buf.clearRetainingCapacity();
        for (info, pos) |info_v, pos_v| {
            // If our cluster changed then we've moved to a new cell.
            if (info_v.cluster != cell_offset.cluster) cell_offset = .{
                .cluster = info_v.cluster,
            };

            try self.cell_buf.append(self.alloc, .{
                .x = @intCast(info_v.cluster),
                .x_offset = @intCast(cell_offset.x),
                .y_offset = @intCast(cell_offset.y),
                .glyph_index = info_v.codepoint,
            });

            if (font.options.backend.hasFreetype()) {
                // Freetype returns 26.6 fixed point values, so we need to
                // divide by 64 to get the actual value. I can't find any
                // HB API to stop this.
                cell_offset.x += pos_v.x_advance >> 6;
                cell_offset.y += pos_v.y_advance >> 6;
            } else {
                cell_offset.x += pos_v.x_advance;
                cell_offset.y += pos_v.y_advance;
            }

            // const i = self.cell_buf.items.len - 1;
            // log.warn("i={} info={} pos={} cell={}", .{ i, info_v, pos_v, self.cell_buf.items[i] });
        }
        //log.warn("----------------", .{});

        return self.cell_buf.items;
    }

    /// The hooks for RunIterator.
    pub const RunIteratorHook = struct {
        shaper: *Shaper,

        pub fn prepare(self: RunIteratorHook) !void {
            // Reset the buffer for our current run
            self.shaper.hb_buf.reset();
            self.shaper.hb_buf.setContentType(.unicode);

            // We don't support RTL text because RTL in terminals is messy.
            // Its something we want to improve. For now, we force LTR because
            // our renderers assume a strictly increasing X value.
            self.shaper.hb_buf.setDirection(.ltr);
        }

        pub fn addCodepoint(self: RunIteratorHook, cp: u32, cluster: u32) !void {
            // log.warn("cluster={} cp={x}", .{ cluster, cp });
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
        var screen = try terminal.Screen.init(alloc, 5, 3, 0);
        defer screen.deinit();
        try screen.testWriteString("ABCD");

        // Get our run iterator
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .screen = &screen,
            .row = screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
        });
        var count: usize = 0;
        while (try it.next(alloc)) |_| count += 1;
        try testing.expectEqual(@as(usize, 1), count);
    }

    // Spaces should be part of a run
    {
        var screen = try terminal.Screen.init(alloc, 10, 3, 0);
        defer screen.deinit();
        try screen.testWriteString("ABCD   EFG");

        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .screen = &screen,
            .row = screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
        });
        var count: usize = 0;
        while (try it.next(alloc)) |_| count += 1;
        try testing.expectEqual(@as(usize, 1), count);
    }

    {
        // Make a screen with some data
        var screen = try terminal.Screen.init(alloc, 5, 3, 0);
        defer screen.deinit();
        try screen.testWriteString("A😃D");

        // Get our run iterator
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .screen = &screen,
            .row = screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
        });
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
        var screen = try terminal.Screen.init(alloc, 5, 3, 0);
        defer screen.deinit();
        try screen.setAttribute(.{ .direct_color_bg = .{ .r = 0xFF, .g = 0, .b = 0 } });
        try screen.testWriteString("A");

        // Get our first row
        {
            const list_cell = screen.pages.getCell(.{ .active = .{ .x = 1 } }).?;
            const cell = list_cell.cell;
            cell.* = .{
                .content_tag = .bg_color_rgb,
                .content = .{ .color_rgb = .{ .r = 0xFF, .g = 0, .b = 0 } },
            };
        }
        {
            const list_cell = screen.pages.getCell(.{ .active = .{ .x = 2 } }).?;
            const cell = list_cell.cell;
            cell.* = .{
                .content_tag = .bg_color_rgb,
                .content = .{ .color_rgb = .{ .r = 0xFF, .g = 0, .b = 0 } },
            };
        }

        // Get our run iterator
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .screen = &screen,
            .row = screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
        });
        {
            const run = (try it.next(alloc)).?;
            try testing.expectEqual(@as(u32, 3), shaper.hb_buf.getLength());
            const cells = try shaper.shape(run);
            try testing.expectEqual(@as(usize, 3), cells.len);
        }
        try testing.expect(try it.next(alloc) == null);
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
    var screen = try terminal.Screen.init(alloc, 10, 3, 0);
    defer screen.deinit();
    try screen.testWriteString(buf[0..buf_idx]);

    // Get our run iterator
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .screen = &screen,
        .row = screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
    });
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
        var screen = try terminal.Screen.init(alloc, 5, 3, 0);
        defer screen.deinit();
        try screen.testWriteString(">=");

        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .screen = &screen,
            .row = screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
        });
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;

            try testing.expectEqual(@as(usize, 2), run.cells);

            const cells = try shaper.shape(run);
            try testing.expectEqual(@as(usize, 1), cells.len);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }

    {
        var screen = try terminal.Screen.init(alloc, 5, 3, 0);
        defer screen.deinit();
        try screen.testWriteString("===");

        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .screen = &screen,
            .row = screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
        });
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;

            try testing.expectEqual(@as(usize, 3), run.cells);

            const cells = try shaper.shape(run);
            try testing.expectEqual(@as(usize, 1), cells.len);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }
}

test "shape monaspace ligs" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaperWithFont(alloc, .monaspace_neon);
    defer testdata.deinit();

    {
        var screen = try terminal.Screen.init(alloc, 5, 3, 0);
        defer screen.deinit();
        try screen.testWriteString("===");

        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .screen = &screen,
            .row = screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
        });
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;

            try testing.expectEqual(@as(usize, 3), run.cells);

            const cells = try shaper.shape(run);
            try testing.expectEqual(@as(usize, 1), cells.len);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }
}

// Ghostty doesn't currently support RTL and our renderers assume
// that cells are in strict LTR order. This means that we need to
// force RTL text to be LTR for rendering. This test ensures that
// we are correctly forcing RTL text to be LTR.
test "shape arabic forced LTR" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaperWithFont(alloc, .arabic);
    defer testdata.deinit();

    var screen = try terminal.Screen.init(alloc, 120, 30, 0);
    defer screen.deinit();
    try screen.testWriteString(@embedFile("testdata/arabic.txt"));

    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .screen = &screen,
        .row = screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
    });
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;
        try testing.expectEqual(@as(usize, 25), run.cells);

        const cells = try shaper.shape(run);
        try testing.expectEqual(@as(usize, 25), cells.len);

        var x: u16 = cells[0].x;
        for (cells[1..]) |cell| {
            try testing.expectEqual(x + 1, cell.x);
            x = cell.x;
        }
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "shape emoji width" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    {
        var screen = try terminal.Screen.init(alloc, 5, 3, 0);
        defer screen.deinit();
        try screen.testWriteString("👍");

        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .screen = &screen,
            .row = screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
        });
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;

            try testing.expectEqual(@as(usize, 2), run.cells);

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

    // Make a screen and add a long emoji sequence to it.
    var screen = try terminal.Screen.init(alloc, 30, 3, 0);
    defer screen.deinit();

    var page = screen.pages.pages.first.?.data;
    var row = page.getRow(1);
    const cell = &row.cells.ptr(page.memory)[0];
    cell.* = .{
        .content_tag = .codepoint,
        .content = .{ .codepoint = 0x1F9D4 }, // Person with beard
    };
    var graphemes = [_]u21{
        0x1F3FB, // Light skin tone (Fitz 1-2)
        0x200D, // ZWJ
        0x2642, // Male sign
        0xFE0F, // Emoji presentation selector
    };
    try page.setGraphemes(
        row,
        cell,
        graphemes[0..],
    );

    // Get our run iterator
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .screen = &screen,
        .row = screen.pages.pin(.{ .screen = .{ .y = 1 } }).?,
    });
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
    var screen = try terminal.Screen.init(alloc, 10, 3, 0);
    defer screen.deinit();
    try screen.testWriteString(buf[0..buf_idx]);

    // Get our run iterator
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .screen = &screen,
        .row = screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
    });
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
    var screen = try terminal.Screen.init(alloc, 10, 3, 0);
    defer screen.deinit();
    try screen.testWriteString(buf[0..buf_idx]);

    // Get our run iterator
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .screen = &screen,
        .row = screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
    });
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
    var screen = try terminal.Screen.init(alloc, 30, 3, 0);
    defer screen.deinit();
    try screen.testWriteString("A");
    screen.cursorRight(5);
    try screen.testWriteString("B");

    // Get our run iterator
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .screen = &screen,
        .row = screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
    });
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;

        const cells = try shaper.shape(run);
        try testing.expectEqual(@as(usize, 1), count);
        try testing.expectEqual(@as(usize, 7), cells.len);
    }
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
    var screen = try terminal.Screen.init(alloc, 30, 3, 0);
    defer screen.deinit();
    try screen.testWriteString(buf[0..buf_idx]);

    // Get our run iterator
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .screen = &screen,
        .row = screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
    });
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

    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;
    buf_idx += try std.unicode.utf8Encode(0x2500, buf[buf_idx..]); // horiz line
    buf_idx += try std.unicode.utf8Encode(0x2501, buf[buf_idx..]); //

    // Make a screen with some data
    var screen = try terminal.Screen.init(alloc, 10, 3, 0);
    defer screen.deinit();
    try screen.testWriteString(buf[0..buf_idx]);

    // Get our run iterator
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .screen = &screen,
        .row = screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
    });
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
    var screen = try terminal.Screen.init(alloc, 10, 3, 0);
    defer screen.deinit();
    try screen.testWriteString("a1b2c3d4e5");

    // Full line selection
    {
        // Get our run iterator
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .screen = &screen,
            .row = screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
            .selection = terminal.Selection.init(
                screen.pages.pin(.{ .active = .{ .x = 0, .y = 0 } }).?,
                screen.pages.pin(.{ .active = .{ .x = screen.pages.cols - 1, .y = 0 } }).?,
                false,
            ),
        });
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
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .screen = &screen,
            .row = screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
            .selection = terminal.Selection.init(
                screen.pages.pin(.{ .active = .{ .x = 2, .y = 0 } }).?,
                screen.pages.pin(.{ .active = .{ .x = screen.pages.cols - 1, .y = 0 } }).?,
                false,
            ),
        });
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
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .screen = &screen,
            .row = screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
            .selection = terminal.Selection.init(
                screen.pages.pin(.{ .active = .{ .x = 0, .y = 0 } }).?,
                screen.pages.pin(.{ .active = .{ .x = 3, .y = 0 } }).?,
                false,
            ),
        });
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
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .screen = &screen,
            .row = screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
            .selection = terminal.Selection.init(
                screen.pages.pin(.{ .active = .{ .x = 1, .y = 0 } }).?,
                screen.pages.pin(.{ .active = .{ .x = 3, .y = 0 } }).?,
                false,
            ),
        });
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
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .screen = &screen,
            .row = screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
            .selection = terminal.Selection.init(
                screen.pages.pin(.{ .active = .{ .x = 1, .y = 0 } }).?,
                screen.pages.pin(.{ .active = .{ .x = 1, .y = 0 } }).?,
                false,
            ),
        });
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
    var screen = try terminal.Screen.init(alloc, 10, 3, 0);
    defer screen.deinit();
    try screen.testWriteString("a1b2c3d4e5");

    // No cursor is full line
    {
        // Get our run iterator
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .screen = &screen,
            .row = screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
        });
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }

    {
        // Cursor at index 0 is two runs
        {
            // Get our run iterator
            var shaper = &testdata.shaper;
            var it = shaper.runIterator(.{
                .grid = testdata.grid,
                .screen = &screen,
                .row = screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
                .cursor_x = 0,
            });
            var count: usize = 0;
            while (try it.next(alloc)) |run| {
                count += 1;
                _ = try shaper.shape(run);
            }
            try testing.expectEqual(@as(usize, 2), count);
        }
        // And without cursor splitting remains one
        {
            // Get our run iterator
            var shaper = &testdata.shaper;
            var it = shaper.runIterator(.{
                .grid = testdata.grid,
                .screen = &screen,
                .row = screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
            });
            var count: usize = 0;
            while (try it.next(alloc)) |run| {
                count += 1;
                _ = try shaper.shape(run);
            }
            try testing.expectEqual(@as(usize, 1), count);
        }
    }

    {
        // Cursor at index 1 is three runs
        {
            // Get our run iterator
            var shaper = &testdata.shaper;
            var it = shaper.runIterator(.{
                .grid = testdata.grid,
                .screen = &screen,
                .row = screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
                .cursor_x = 1,
            });
            var count: usize = 0;
            while (try it.next(alloc)) |run| {
                count += 1;
                _ = try shaper.shape(run);
            }
            try testing.expectEqual(@as(usize, 3), count);
        }
        // And without cursor splitting remains one
        {
            // Get our run iterator
            var shaper = &testdata.shaper;
            var it = shaper.runIterator(.{
                .grid = testdata.grid,
                .screen = &screen,
                .row = screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
            });
            var count: usize = 0;
            while (try it.next(alloc)) |run| {
                count += 1;
                _ = try shaper.shape(run);
            }
            try testing.expectEqual(@as(usize, 1), count);
        }
    }
    {
        // Cursor at last col is two runs
        {
            // Get our run iterator
            var shaper = &testdata.shaper;
            var it = shaper.runIterator(.{
                .grid = testdata.grid,
                .screen = &screen,
                .row = screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
                .cursor_x = 9,
            });
            var count: usize = 0;
            while (try it.next(alloc)) |run| {
                count += 1;
                _ = try shaper.shape(run);
            }
            try testing.expectEqual(@as(usize, 2), count);
        }
        // And without cursor splitting remains one
        {
            // Get our run iterator
            var shaper = &testdata.shaper;
            var it = shaper.runIterator(.{
                .grid = testdata.grid,
                .screen = &screen,
                .row = screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
            });
            var count: usize = 0;
            while (try it.next(alloc)) |run| {
                count += 1;
                _ = try shaper.shape(run);
            }
            try testing.expectEqual(@as(usize, 1), count);
        }
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
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .screen = &screen,
            .row = screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
        });
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
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .screen = &screen,
            .row = screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
            .cursor_x = 0,
        });
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
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .screen = &screen,
            .row = screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
        });
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
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .screen = &screen,
            .row = screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
            .cursor_x = 1,
        });
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
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .screen = &screen,
            .row = screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
        });
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
        var screen = try terminal.Screen.init(alloc, 10, 3, 0);
        defer screen.deinit();
        try screen.testWriteString(">=");

        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .screen = &screen,
            .row = screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
        });
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
        try screen.setAttribute(.{ .bold = {} });
        try screen.testWriteString("=");

        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .screen = &screen,
            .row = screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
        });
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
        try screen.setAttribute(.{ .direct_color_fg = .{ .r = 1, .g = 2, .b = 3 } });
        try screen.testWriteString(">");
        try screen.setAttribute(.{ .direct_color_fg = .{ .r = 3, .g = 2, .b = 1 } });
        try screen.testWriteString("=");

        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .screen = &screen,
            .row = screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
        });
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 2), count);
    }

    // Changing bg color should not split
    {
        var screen = try terminal.Screen.init(alloc, 3, 10, 0);
        defer screen.deinit();
        try screen.setAttribute(.{ .direct_color_bg = .{ .r = 1, .g = 2, .b = 3 } });
        try screen.testWriteString(">");
        try screen.setAttribute(.{ .direct_color_bg = .{ .r = 3, .g = 2, .b = 1 } });
        try screen.testWriteString("=");

        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .screen = &screen,
            .row = screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
        });
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;
            _ = try shaper.shape(run);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }

    // Same bg color should not split
    {
        var screen = try terminal.Screen.init(alloc, 3, 10, 0);
        defer screen.deinit();
        try screen.setAttribute(.{ .direct_color_bg = .{ .r = 1, .g = 2, .b = 3 } });
        try screen.testWriteString(">");
        try screen.testWriteString("=");

        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .screen = &screen,
            .row = screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
        });
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
    grid: *SharedGrid,
    lib: Library,

    pub fn deinit(self: *TestShaper) void {
        self.shaper.deinit();
        self.grid.deinit(self.alloc);
        self.alloc.destroy(self.grid);
        self.lib.deinit();
    }
};

const TestFont = enum {
    inconsolata,
    monaspace_neon,
    arabic,
};

/// Helper to return a fully initialized shaper.
fn testShaper(alloc: Allocator) !TestShaper {
    return try testShaperWithFont(alloc, .inconsolata);
}

fn testShaperWithFont(alloc: Allocator, font_req: TestFont) !TestShaper {
    const testEmoji = font.embedded.emoji;
    const testEmojiText = font.embedded.emoji_text;
    const testFont = switch (font_req) {
        .inconsolata => font.embedded.inconsolata,
        .monaspace_neon => font.embedded.monaspace_neon,
        .arabic => font.embedded.arabic,
    };

    var lib = try Library.init(alloc);
    errdefer lib.deinit();

    var c = Collection.init();
    c.load_options = .{ .library = lib };

    // Setup group
    _ = try c.add(alloc, .regular, .{ .loaded = try .init(
        lib,
        testFont,
        .{ .size = .{ .points = 12 } },
    ) });

    if (comptime !font.options.backend.hasCoretext()) {
        // Coretext doesn't support Noto's format
        _ = try c.add(alloc, .regular, .{ .loaded = try .init(
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
        _ = try c.add(alloc, .regular, .{ .deferred = face });
    }
    _ = try c.add(alloc, .regular, .{ .loaded = try .init(
        lib,
        testEmojiText,
        .{ .size = .{ .points = 12 } },
    ) });

    const grid_ptr = try alloc.create(SharedGrid);
    errdefer alloc.destroy(grid_ptr);
    grid_ptr.* = try .init(alloc, .{ .collection = c });
    errdefer grid_ptr.*.deinit(alloc);

    var shaper = try Shaper.init(alloc, .{});
    errdefer shaper.deinit();

    return TestShaper{
        .alloc = alloc,
        .shaper = shaper,
        .grid = grid_ptr,
        .lib = lib,
    };
}
