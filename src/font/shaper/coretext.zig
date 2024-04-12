const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const macos = @import("macos");
const trace = @import("tracy").trace;
const font = @import("../main.zig");
const Face = font.Face;
const Collection = font.Collection;
const DeferredFace = font.DeferredFace;
const Group = font.Group;
const Library = font.Library;
const SharedGrid = font.SharedGrid;
const Style = font.Style;
const Presentation = font.Presentation;
const terminal = @import("../../terminal/main.zig");

const log = std.log.scoped(.font_shaper);

/// Shaper that uses CoreText.
///
/// CoreText shaping differs in subtle ways from HarfBuzz so it may result
/// in inconsistent rendering across platforms. But it also fixes many
/// issues (some macOS specific):
///
///   - Theta hat offset is incorrect in HarfBuzz but correct by default
///     on macOS applications using CoreText. (See:
///     https://github.com/harfbuzz/harfbuzz/discussions/4525)
///
///   - Hyphens (U+2010) can be synthesized by CoreText but not by HarfBuzz.
///     See: https://github.com/mitchellh/ghostty/issues/1643
///
pub const Shaper = struct {
    /// The allocated used for the feature list and cell buf.
    alloc: Allocator,

    /// The string used for shaping the current run.
    run_state: RunState,

    /// The font features we want to use. The hardcoded features are always
    /// set first.
    features: FeatureList,

    /// The shared memory used for shaping results.
    cell_buf: CellBuf,

    const CellBuf = std.ArrayListUnmanaged(font.shape.Cell);
    const CodepointList = std.ArrayListUnmanaged(Codepoint);
    const Codepoint = struct {
        codepoint: u32,
        cluster: u32,
    };

    const RunState = struct {
        str: *macos.foundation.MutableString,
        codepoints: CodepointList,

        fn init() !RunState {
            var str = try macos.foundation.MutableString.create(0);
            errdefer str.release();
            return .{ .str = str, .codepoints = .{} };
        }

        fn deinit(self: *RunState, alloc: Allocator) void {
            self.codepoints.deinit(alloc);
            self.str.release();
        }

        fn reset(self: *RunState) !void {
            self.codepoints.clearRetainingCapacity();
            self.str.release();
            self.str = try macos.foundation.MutableString.create(0);
        }
    };

    /// List of font features, parsed into the data structures used by
    /// the CoreText API. The CoreText API requires a pretty annoying wrapping
    /// to setup font features:
    ///
    ///   - The key parsed into a CFString
    ///   - The value parsed into a CFNumber
    ///   - The key and value are then put into a CFDictionary
    ///   - The CFDictionary is then put into a CFArray
    ///   - The CFArray is then put into another CFDictionary
    ///   - The CFDictionary is then passed to the CoreText API to create
    ///     a new font with the features set.
    ///
    /// This structure handles up to the point that we have a CFArray of
    /// CFDictionary objects representing the font features and provides
    /// functions for creating the dictionary to init the font.
    const FeatureList = struct {
        list: *macos.foundation.MutableArray,

        pub fn init() !FeatureList {
            var list = try macos.foundation.MutableArray.create();
            errdefer list.release();
            return .{ .list = list };
        }

        pub fn deinit(self: FeatureList) void {
            self.list.release();
        }

        /// Append the given feature to the list. The feature syntax is
        /// the same as Harfbuzz: "feat" enables it and "-feat" disables it.
        pub fn append(self: *FeatureList, name_raw: []const u8) !void {
            // If the name is `-name` then we are disabling the feature,
            // otherwise we are enabling it, so we need to parse this out.
            const name = if (name_raw[0] == '-') name_raw[1..] else name_raw;
            const dict = try featureDict(name, name_raw[0] != '-');
            defer dict.release();
            self.list.appendValue(macos.foundation.Dictionary, dict);
        }

        /// Create the dictionary for the given feature and value.
        fn featureDict(name: []const u8, v: bool) !*macos.foundation.Dictionary {
            const value_num: c_int = @intFromBool(v);

            // Keys can only be ASCII.
            var key = try macos.foundation.String.createWithBytes(name, .ascii, false);
            defer key.release();
            var value = try macos.foundation.Number.create(.int, &value_num);
            defer value.release();

            const dict = try macos.foundation.Dictionary.create(
                &[_]?*const anyopaque{
                    macos.text.c.kCTFontOpenTypeFeatureTag,
                    macos.text.c.kCTFontOpenTypeFeatureValue,
                },
                &[_]?*const anyopaque{
                    key,
                    value,
                },
            );
            errdefer dict.release();
            return dict;
        }

        /// Returns the dictionary to use with the font API to set the
        /// features. This should be released by the caller.
        pub fn attrsDict(
            self: FeatureList,
            omit_defaults: bool,
        ) !*macos.foundation.Dictionary {
            // Get our feature list. If we're omitting defaults then we
            // slice off the hardcoded features.
            const list = if (!omit_defaults) self.list else list: {
                const list = try macos.foundation.MutableArray.createCopy(@ptrCast(self.list));
                for (hardcoded_features) |_| list.removeValue(0);
                break :list list;
            };
            defer if (omit_defaults) list.release();

            var dict = try macos.foundation.Dictionary.create(
                &[_]?*const anyopaque{macos.text.c.kCTFontFeatureSettingsAttribute},
                &[_]?*const anyopaque{list},
            );
            errdefer dict.release();
            return dict;
        }
    };

    // These features are hardcoded to always be on by default. Users
    // can turn them off by setting the features to "-liga" for example.
    const hardcoded_features = [_][]const u8{ "dlig", "liga" };

    /// The cell_buf argument is the buffer to use for storing shaped results.
    /// This should be at least the number of columns in the terminal.
    pub fn init(alloc: Allocator, opts: font.shape.Options) !Shaper {
        var feats = try FeatureList.init();
        errdefer feats.deinit();
        for (hardcoded_features) |name| try feats.append(name);
        for (opts.features) |name| try feats.append(name);

        const run_state = try RunState.init();
        errdefer run_state.deinit();

        return Shaper{
            .alloc = alloc,
            .cell_buf = .{},
            .run_state = run_state,
            .features = feats,
        };
    }

    pub fn deinit(self: *Shaper) void {
        self.cell_buf.deinit(self.alloc);
        self.run_state.deinit(self.alloc);
        self.features.deinit();
    }

    pub fn runIterator(
        self: *Shaper,
        grid: *SharedGrid,
        screen: *const terminal.Screen,
        row: terminal.Pin,
        selection: ?terminal.Selection,
        cursor_x: ?usize,
    ) font.shape.RunIterator {
        return .{
            .hooks = .{ .shaper = self },
            .grid = grid,
            .screen = screen,
            .row = row,
            .selection = selection,
            .cursor_x = cursor_x,
        };
    }

    pub fn shape(self: *Shaper, run: font.shape.TextRun) ![]const font.shape.Cell {
        const state = &self.run_state;

        // Special fonts aren't shaped and their codepoint == glyph so we
        // can just return the codepoints as-is.
        if (run.font_index.special() != null) {
            self.cell_buf.clearRetainingCapacity();
            try self.cell_buf.ensureTotalCapacity(self.alloc, state.codepoints.items.len);
            for (state.codepoints.items) |entry| {
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

        // Get our font. We have to apply the font features we want for
        // the font here.
        const run_font: *macos.text.Font = font: {
            // The CoreText shaper relies on CoreText and CoreText claims
            // that CTFonts are threadsafe. See:
            // https://developer.apple.com/documentation/coretext/
            //
            // Quote:
            // All individual functions in Core Text are thread-safe. Font
            // objects (CTFont, CTFontDescriptor, and associated objects) can
            // be used simultaneously by multiple operations, work queues, or
            // threads. However, the layout objects (CTTypesetter,
            // CTFramesetter, CTRun, CTLine, CTFrame, and associated objects)
            // should be used in a single operation, work queue, or thread.
            //
            // Because of this, we only acquire the read lock to grab the
            // face and set it up, then release it.
            run.grid.lock.lockShared();
            defer run.grid.lock.unlockShared();

            const face = try run.grid.resolver.collection.getFace(run.font_index);
            const original = face.font;

            const attrs = try self.features.attrsDict(face.quirks_disable_default_font_features);
            defer attrs.release();

            const desc = try macos.text.FontDescriptor.createWithAttributes(attrs);
            defer desc.release();

            const copied = try original.copyWithAttributes(0, null, desc);
            errdefer copied.release();
            break :font copied;
        };
        defer run_font.release();

        // Get our font and use that get the attributes to set for the
        // attributed string so the whole string uses the same font.
        const attr_dict = dict: {
            var keys = [_]?*const anyopaque{macos.text.StringAttribute.font.key()};
            var values = [_]?*const anyopaque{run_font};
            break :dict try macos.foundation.Dictionary.create(&keys, &values);
        };
        defer attr_dict.release();

        // Create an attributed string from our string
        const attr_str = try macos.foundation.AttributedString.create(
            state.str.string(),
            attr_dict,
        );
        defer attr_str.release();

        // We should always have one run because we do our own run splitting.
        const line = try macos.text.Line.createWithAttributedString(attr_str);
        defer line.release();

        // This keeps track of the current offsets within a single cell.
        var cell_offset: struct {
            cluster: u32 = 0,
            x: f64 = 0,
            y: f64 = 0,
        } = .{};
        self.cell_buf.clearRetainingCapacity();

        // CoreText may generate multiple runs even though our input to
        // CoreText is already split into runs by our own run iterator.
        // The runs as far as I can tell are always sequential to each
        // other so we can iterate over them and just append to our
        // cell buffer.
        const runs = line.getGlyphRuns();
        for (0..runs.getCount()) |i| {
            const ctrun = runs.getValueAtIndex(macos.text.Run, i);

            // Get our glyphs and positions
            const glyphs = try ctrun.getGlyphs(alloc);
            const positions = try ctrun.getPositions(alloc);
            const advances = try ctrun.getAdvances(alloc);
            const indices = try ctrun.getStringIndices(alloc);
            assert(glyphs.len == positions.len);
            assert(glyphs.len == advances.len);
            assert(glyphs.len == indices.len);

            for (
                glyphs,
                positions,
                advances,
                indices,
            ) |glyph, pos, advance, index| {
                try self.cell_buf.ensureUnusedCapacity(
                    self.alloc,
                    glyphs.len,
                );

                // Our cluster is also our cell X position. If the cluster changes
                // then we need to reset our current cell offsets.
                const cluster = state.codepoints.items[index].cluster;
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
        }

        return self.cell_buf.items;
    }

    /// The hooks for RunIterator.
    pub const RunIteratorHook = struct {
        shaper: *Shaper,

        pub fn prepare(self: *RunIteratorHook) !void {
            try self.shaper.run_state.reset();
            // log.warn("----------- run reset -------------", .{});
        }

        pub fn addCodepoint(self: RunIteratorHook, cp: u32, cluster: u32) !void {
            // Build our UTF-16 string for CoreText
            var unichars: [2]u16 = undefined;
            const pair = macos.foundation.stringGetSurrogatePairForLongCharacter(
                cp,
                &unichars,
            );
            const len: usize = if (pair) 2 else 1;
            const state = &self.shaper.run_state;
            state.str.appendCharacters(unichars[0..len]);

            // Build our reverse lookup table for codepoints to clusters
            try state.codepoints.append(self.shaper.alloc, .{
                .codepoint = cp,
                .cluster = cluster,
            });
            // log.warn("run cp={X}", .{cp});

            // If the UTF-16 codepoint is a pair then we need to insert
            // a dummy entry so that the CTRunGetStringIndices() function
            // maps correctly.
            if (pair) {
                try state.codepoints.append(self.shaper.alloc, .{
                    .codepoint = 0,
                    .cluster = cluster,
                });
                log.warn("run pair cp=0", .{});
            }
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
        var screen = try terminal.Screen.init(alloc, 5, 3, 0);
        defer screen.deinit();
        try screen.testWriteString("ABCD");

        // Get our run iterator
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(
            testdata.grid,
            &screen,
            screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
            null,
            null,
        );
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
        var it = shaper.runIterator(
            testdata.grid,
            &screen,
            screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
            null,
            null,
        );
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
        var it = shaper.runIterator(
            testdata.grid,
            &screen,
            screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
            null,
            null,
        );
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
        var it = shaper.runIterator(
            testdata.grid,
            &screen,
            screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
            null,
            null,
        );
        {
            const run = (try it.next(alloc)).?;
            const cells = try shaper.shape(run);
            try testing.expectEqual(@as(usize, 1), cells.len);
        }
        {
            const run = (try it.next(alloc)).?;
            const cells = try shaper.shape(run);
            try testing.expectEqual(@as(usize, 2), cells.len);
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
    var it = shaper.runIterator(
        testdata.grid,
        &screen,
        screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
        null,
        null,
    );
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;
        _ = try shaper.shape(run);
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "shape nerd fonts" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaperWithFont(alloc, .nerd_font);
    defer testdata.deinit();

    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;
    buf_idx += try std.unicode.utf8Encode(' ', buf[buf_idx..]); // space
    buf_idx += try std.unicode.utf8Encode(0xF024B, buf[buf_idx..]); // nf-md-folder
    buf_idx += try std.unicode.utf8Encode(' ', buf[buf_idx..]); // space

    // Make a screen with some data
    var screen = try terminal.Screen.init(alloc, 10, 3, 0);
    defer screen.deinit();
    try screen.testWriteString(buf[0..buf_idx]);

    // Get our run iterator
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(
        testdata.grid,
        &screen,
        screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
        null,
        null,
    );
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;
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
        var it = shaper.runIterator(
            testdata.grid,
            &screen,
            screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
            null,
            null,
        );
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;

            const cells = try shaper.shape(run);
            try testing.expectEqual(@as(usize, 1), cells.len);
            try testing.expect(cells[0].glyph_index != null);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }

    {
        var screen = try terminal.Screen.init(alloc, 5, 3, 0);
        defer screen.deinit();
        try screen.testWriteString("===");

        var shaper = &testdata.shaper;
        var it = shaper.runIterator(
            testdata.grid,
            &screen,
            screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
            null,
            null,
        );
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;

            const cells = try shaper.shape(run);
            try testing.expectEqual(@as(usize, 1), cells.len);
            try testing.expect(cells[0].glyph_index != null);
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
        var it = shaper.runIterator(
            testdata.grid,
            &screen,
            screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
            null,
            null,
        );
        var count: usize = 0;
        while (try it.next(alloc)) |run| {
            count += 1;

            const cells = try shaper.shape(run);
            try testing.expectEqual(@as(usize, 1), cells.len);
            try testing.expect(cells[0].glyph_index != null);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }
}

// https://github.com/mitchellh/ghostty/issues/1664
test "shape U+3C9 with JB Mono" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaperWithFont(alloc, .jetbrains_mono);
    defer testdata.deinit();

    {
        var screen = try terminal.Screen.init(alloc, 10, 3, 0);
        defer screen.deinit();
        try screen.testWriteString("\u{03C9} foo");

        var shaper = &testdata.shaper;
        var it = shaper.runIterator(
            testdata.grid,
            &screen,
            screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
            null,
            null,
        );

        var run_count: usize = 0;
        var cell_count: usize = 0;
        while (try it.next(alloc)) |run| {
            run_count += 1;
            const cells = try shaper.shape(run);
            cell_count += cells.len;
        }
        try testing.expectEqual(@as(usize, 1), run_count);
        try testing.expectEqual(@as(usize, 5), cell_count);
    }
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
        var it = shaper.runIterator(
            testdata.grid,
            &screen,
            screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
            null,
            null,
        );
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
    var screen = try terminal.Screen.init(alloc, 30, 3, 0);
    defer screen.deinit();
    try screen.testWriteString(buf[0..buf_idx]);

    // Get our run iterator
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(
        testdata.grid,
        &screen,
        screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
        null,
        null,
    );
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;
        const cells = try shaper.shape(run);

        // screen.testWriteString isn't grapheme aware, otherwise this is two
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
    var it = shaper.runIterator(
        testdata.grid,
        &screen,
        screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
        null,
        null,
    );
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
    var screen = try terminal.Screen.init(alloc, 10, 3, 0);
    defer screen.deinit();
    try screen.testWriteString(buf[0..buf_idx]);

    // Get our run iterator
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(
        testdata.grid,
        &screen,
        screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
        null,
        null,
    );
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
    var screen = try terminal.Screen.init(alloc, 30, 3, 0);
    defer screen.deinit();
    try screen.testWriteString("A");
    screen.cursorRight(5);
    try screen.testWriteString("B");

    // Get our run iterator
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(
        testdata.grid,
        &screen,
        screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
        null,
        null,
    );
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
    var it = shaper.runIterator(
        testdata.grid,
        &screen,
        screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
        null,
        null,
    );
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
    var it = shaper.runIterator(
        testdata.grid,
        &screen,
        screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
        null,
        null,
    );
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;
        const cells = try shaper.shape(run);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u32, 0x2500), cells[0].glyph_index.?);
        try testing.expectEqual(@as(u16, 0), cells[0].x);
        try testing.expectEqual(@as(u32, 0x2501), cells[1].glyph_index.?);
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
        var it = shaper.runIterator(
            testdata.grid,
            &screen,
            screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
            terminal.Selection.init(
                screen.pages.pin(.{ .active = .{ .x = 0, .y = 0 } }).?,
                screen.pages.pin(.{ .active = .{ .x = screen.pages.cols - 1, .y = 0 } }).?,
                false,
            ),
            null,
        );
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
        var it = shaper.runIterator(
            testdata.grid,
            &screen,
            screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
            terminal.Selection.init(
                screen.pages.pin(.{ .active = .{ .x = 2, .y = 0 } }).?,
                screen.pages.pin(.{ .active = .{ .x = screen.pages.cols - 1, .y = 0 } }).?,
                false,
            ),
            null,
        );
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
        var it = shaper.runIterator(
            testdata.grid,
            &screen,
            screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
            terminal.Selection.init(
                screen.pages.pin(.{ .active = .{ .x = 0, .y = 0 } }).?,
                screen.pages.pin(.{ .active = .{ .x = 3, .y = 0 } }).?,
                false,
            ),
            null,
        );
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
        var it = shaper.runIterator(
            testdata.grid,
            &screen,
            screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
            terminal.Selection.init(
                screen.pages.pin(.{ .active = .{ .x = 1, .y = 0 } }).?,
                screen.pages.pin(.{ .active = .{ .x = 3, .y = 0 } }).?,
                false,
            ),
            null,
        );
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
        var it = shaper.runIterator(
            testdata.grid,
            &screen,
            screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
            terminal.Selection.init(
                screen.pages.pin(.{ .active = .{ .x = 1, .y = 0 } }).?,
                screen.pages.pin(.{ .active = .{ .x = 1, .y = 0 } }).?,
                false,
            ),
            null,
        );
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
        var it = shaper.runIterator(
            testdata.grid,
            &screen,
            screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
            null,
            null,
        );
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
        var it = shaper.runIterator(
            testdata.grid,
            &screen,
            screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
            null,
            0,
        );
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
        var it = shaper.runIterator(
            testdata.grid,
            &screen,
            screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
            null,
            1,
        );
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
        var it = shaper.runIterator(
            testdata.grid,
            &screen,
            screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
            null,
            9,
        );
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
        var it = shaper.runIterator(
            testdata.grid,
            &screen,
            screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
            null,
            null,
        );
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
        var it = shaper.runIterator(
            testdata.grid,
            &screen,
            screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
            null,
            0,
        );
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
        var it = shaper.runIterator(
            testdata.grid,
            &screen,
            screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
            null,
            1,
        );
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
        var it = shaper.runIterator(
            testdata.grid,
            &screen,
            screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
            null,
            null,
        );
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
        var it = shaper.runIterator(
            testdata.grid,
            &screen,
            screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
            null,
            null,
        );
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
        var it = shaper.runIterator(
            testdata.grid,
            &screen,
            screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
            null,
            null,
        );
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
        try screen.setAttribute(.{ .direct_color_bg = .{ .r = 1, .g = 2, .b = 3 } });
        try screen.testWriteString(">");
        try screen.setAttribute(.{ .direct_color_bg = .{ .r = 3, .g = 2, .b = 1 } });
        try screen.testWriteString("=");

        var shaper = &testdata.shaper;
        var it = shaper.runIterator(
            testdata.grid,
            &screen,
            screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
            null,
            null,
        );
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
        try screen.setAttribute(.{ .direct_color_bg = .{ .r = 1, .g = 2, .b = 3 } });
        try screen.testWriteString(">");
        try screen.testWriteString("=");

        var shaper = &testdata.shaper;
        var it = shaper.runIterator(
            testdata.grid,
            &screen,
            screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
            null,
            null,
        );
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
    jetbrains_mono,
    monaspace_neon,
    nerd_font,
};

/// Helper to return a fully initialized shaper.
fn testShaper(alloc: Allocator) !TestShaper {
    return try testShaperWithFont(alloc, .inconsolata);
}

fn testShaperWithFont(alloc: Allocator, font_req: TestFont) !TestShaper {
    const testEmoji = @import("../test.zig").fontEmoji;
    const testEmojiText = @import("../test.zig").fontEmojiText;
    const testFont = switch (font_req) {
        .inconsolata => @import("../test.zig").fontRegular,
        .jetbrains_mono => @import("../test.zig").fontJetBrainsMono,
        .monaspace_neon => @import("../test.zig").fontMonaspaceNeon,
        .nerd_font => @import("../test.zig").fontNerdFont,
    };

    var lib = try Library.init();
    errdefer lib.deinit();

    var c = try Collection.init(alloc);
    c.load_options = .{ .library = lib };

    // Setup group
    _ = try c.add(alloc, .regular, .{ .loaded = try Face.init(
        lib,
        testFont,
        .{ .size = .{ .points = 12 } },
    ) });

    if (font.options.backend != .coretext) {
        // Coretext doesn't support Noto's format
        _ = try c.add(alloc, .regular, .{ .loaded = try Face.init(
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
    _ = try c.add(alloc, .regular, .{ .loaded = try Face.init(
        lib,
        testEmojiText,
        .{ .size = .{ .points = 12 } },
    ) });

    const grid_ptr = try alloc.create(SharedGrid);
    errdefer alloc.destroy(grid_ptr);
    grid_ptr.* = try SharedGrid.init(alloc, .{ .collection = c }, false);
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
