const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const macos = @import("macos");
const trace = @import("tracy").trace;
const font = @import("../main.zig");
const os = @import("../../os/main.zig");
const terminal = @import("../../terminal/main.zig");
const config = @import("../../config.zig");
const Feature = font.shape.Feature;
const FeatureList = font.shape.FeatureList;
const default_features = font.shape.default_features;
const Face = font.Face;
const Collection = font.Collection;
const DeferredFace = font.DeferredFace;
const Group = font.Group;
const GroupCache = font.GroupCache;
const Library = font.Library;
const SharedGrid = font.SharedGrid;
const Style = font.Style;
const Presentation = font.Presentation;
const CFReleaseThread = os.CFReleaseThread;

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
    /// The allocated used for the feature list, font cache, and cell buf.
    alloc: Allocator,

    /// The string used for shaping the current run.
    run_state: RunState,

    /// CoreFoundation Dictionary which represents our font feature settings.
    features: *macos.foundation.Dictionary,
    /// A version of the features dictionary with the default features excluded.
    features_no_default: *macos.foundation.Dictionary,

    /// The shared memory used for shaping results.
    cell_buf: CellBuf,

    /// The cached writing direction value for shaping. This isn't
    /// configurable we just use this as a cache to avoid creating
    /// and releasing many objects when shaping.
    writing_direction: *macos.foundation.Array,

    /// List where we cache fonts, so we don't have to remake them for
    /// every single shaping operation.
    ///
    /// Fonts are cached as attribute dictionaries to be applied directly to
    /// attributed strings.
    cached_fonts: std.ArrayListUnmanaged(?*macos.foundation.Dictionary),

    /// The grid that our cached fonts correspond to.
    /// If the grid changes then we need to reset our cache.
    cached_font_grid: usize,

    /// The list of CoreFoundation objects to release on the dedicated
    /// release thread. This is built up over the course of shaping and
    /// sent to the release thread when endFrame is called.
    cf_release_pool: std.ArrayListUnmanaged(*anyopaque),

    /// Dedicated thread for releasing CoreFoundation objects. Some objects,
    /// such as those produced by CoreText, have excessively slow release
    /// callback logic.
    cf_release_thread: *CFReleaseThread,
    cf_release_thr: std.Thread,

    const CellBuf = std.ArrayListUnmanaged(font.shape.Cell);
    const CodepointList = std.ArrayListUnmanaged(Codepoint);
    const Codepoint = struct {
        codepoint: u32,
        cluster: u32,
    };

    const RunState = struct {
        codepoints: CodepointList,
        unichars: std.ArrayListUnmanaged(u16),

        fn init() RunState {
            return .{ .codepoints = .{}, .unichars = .{} };
        }

        fn deinit(self: *RunState, alloc: Allocator) void {
            self.codepoints.deinit(alloc);
            self.unichars.deinit(alloc);
        }

        fn reset(self: *RunState) !void {
            self.codepoints.clearRetainingCapacity();
            self.unichars.clearRetainingCapacity();
        }
    };

    /// Create a CoreFoundation Dictionary suitable for
    /// settings the font features of a CoreText font.
    fn makeFeaturesDict(feats: []const Feature) !*macos.foundation.Dictionary {
        const list = try macos.foundation.MutableArray.create();
        // The list will be retained by the dict once we add it to it.
        defer list.release();

        for (feats) |feat| {
            const value_num: c_int = @intCast(feat.value);

            // Keys can only be ASCII.
            var key = try macos.foundation.String.createWithBytes(&feat.tag, .ascii, false);
            defer key.release();
            var value = try macos.foundation.Number.create(.int, &value_num);
            defer value.release();

            const dict = try macos.foundation.Dictionary.create(
                &[_]?*const anyopaque{
                    macos.text.c.kCTFontOpenTypeFeatureTag,
                    macos.text.c.kCTFontOpenTypeFeatureValue,
                },
                &[_]?*const anyopaque{ key, value },
            );
            defer dict.release();

            list.appendValue(macos.foundation.Dictionary, dict);
        }

        var dict = try macos.foundation.Dictionary.create(
            &[_]?*const anyopaque{macos.text.c.kCTFontFeatureSettingsAttribute},
            &[_]?*const anyopaque{list},
        );
        errdefer dict.release();

        return dict;
    }

    /// The cell_buf argument is the buffer to use for storing shaped results.
    /// This should be at least the number of columns in the terminal.
    pub fn init(alloc: Allocator, opts: font.shape.Options) !Shaper {
        var feature_list: FeatureList = .{};
        defer feature_list.deinit(alloc);
        for (opts.features) |feature_str| {
            try feature_list.appendFromString(alloc, feature_str);
        }

        // We need to construct two attrs dictionaries for font features;
        // one without the default features included, and one with them.
        const feats = feature_list.features.items;
        const feats_df = try alloc.alloc(Feature, feats.len + default_features.len);
        defer alloc.free(feats_df);

        @memcpy(feats_df[0..default_features.len], &default_features);
        @memcpy(feats_df[default_features.len..], feats);

        const features = try makeFeaturesDict(feats_df);
        errdefer features.release();
        const features_no_default = try makeFeaturesDict(feats);
        errdefer features_no_default.release();

        var run_state = RunState.init();
        errdefer run_state.deinit(alloc);

        // For now we only support LTR text. If we shape RTL text then
        // rendering will be very wrong so we need to explicitly force
        // LTR no matter what.
        //
        // See: https://github.com/mitchellh/ghostty/issues/1737
        // See: https://github.com/mitchellh/ghostty/issues/1442
        const writing_direction = array: {
            const dir: macos.text.WritingDirection = .lro;
            const num = try macos.foundation.Number.create(
                .int,
                &@intFromEnum(dir),
            );
            defer num.release();

            var arr_init = [_]*const macos.foundation.Number{num};
            break :array try macos.foundation.Array.create(
                macos.foundation.Number,
                &arr_init,
            );
        };
        errdefer writing_direction.release();

        // Create the CF release thread.
        var cf_release_thread = try alloc.create(CFReleaseThread);
        errdefer alloc.destroy(cf_release_thread);
        cf_release_thread.* = try .init(alloc);
        errdefer cf_release_thread.deinit();

        // Start the CF release thread.
        var cf_release_thr = try std.Thread.spawn(
            .{},
            CFReleaseThread.threadMain,
            .{cf_release_thread},
        );
        cf_release_thr.setName("cf_release") catch {};

        return .{
            .alloc = alloc,
            .cell_buf = .{},
            .run_state = run_state,
            .features = features,
            .features_no_default = features_no_default,
            .writing_direction = writing_direction,
            .cached_fonts = .{},
            .cached_font_grid = 0,
            .cf_release_pool = .{},
            .cf_release_thread = cf_release_thread,
            .cf_release_thr = cf_release_thr,
        };
    }

    pub fn deinit(self: *Shaper) void {
        self.cell_buf.deinit(self.alloc);
        self.run_state.deinit(self.alloc);
        self.features.release();
        self.features_no_default.release();
        self.writing_direction.release();

        {
            for (self.cached_fonts.items) |ft| {
                if (ft) |f| f.release();
            }
            self.cached_fonts.deinit(self.alloc);
        }

        if (self.cf_release_pool.items.len > 0) {
            for (self.cf_release_pool.items) |ref| macos.foundation.CFRelease(ref);

            // For tests this logic is normal because we don't want to
            // wait for a release thread. But in production this is a bug
            // and we should warn.
            if (comptime !builtin.is_test) log.warn(
                "BUG: CFRelease pool was not empty, releasing remaining objects",
                .{},
            );
        }
        self.cf_release_pool.deinit(self.alloc);

        // Stop the CF release thread
        {
            self.cf_release_thread.stop.notify() catch |err|
                log.err("error notifying cf release thread to stop, may stall err={}", .{err});
            self.cf_release_thr.join();
        }
        self.cf_release_thread.deinit();
        self.alloc.destroy(self.cf_release_thread);
    }

    pub fn endFrame(self: *Shaper) void {
        if (self.cf_release_pool.items.len == 0) return;

        // Get all the items in the pool as an owned slice so we can
        // send it to the dedicated release thread.
        const items = self.cf_release_pool.toOwnedSlice(self.alloc) catch |err| {
            log.warn("error converting release pool to owned slice, slow release err={}", .{err});
            for (self.cf_release_pool.items) |ref| macos.foundation.CFRelease(ref);
            self.cf_release_pool.clearRetainingCapacity();
            return;
        };

        // Send the items. If the send succeeds then we wake up the
        // thread to process the items. If the send fails then do a manual
        // cleanup.
        if (self.cf_release_thread.mailbox.push(.{ .release = .{
            .refs = items,
            .alloc = self.alloc,
        } }, .{ .forever = {} }) != 0) {
            self.cf_release_thread.wakeup.notify() catch |err| {
                log.warn(
                    "error notifying cf release thread to wake up, may stall err={}",
                    .{err},
                );
            };
            return;
        }

        for (items) |ref| macos.foundation.CFRelease(ref);
        self.alloc.free(items);
    }

    pub fn runIterator(
        self: *Shaper,
        opts: font.shape.RunOptions,
    ) font.shape.RunIterator {
        return .{
            .hooks = .{ .shaper = self },
            .opts = opts,
        };
    }

    /// Note that this will accumulate garbage in the release pool. The
    /// caller must ensure you're properly calling endFrame to release
    /// all the objects.
    pub fn shape(
        self: *Shaper,
        run: font.shape.TextRun,
    ) ![]const font.shape.Cell {
        const state = &self.run_state;

        // {
        //     log.debug("shape -----------------------------------", .{});
        //     for (state.codepoints.items) |entry| {
        //         log.debug("cp={X} cluster={}", .{ entry.codepoint, entry.cluster });
        //     }
        //     log.debug("shape end -------------------------------", .{});
        // }

        // Special fonts aren't shaped and their codepoint == glyph so we
        // can just return the codepoints as-is.
        if (run.font_index.special() != null) {
            self.cell_buf.clearRetainingCapacity();
            try self.cell_buf.ensureTotalCapacity(self.alloc, state.codepoints.items.len);
            for (state.codepoints.items) |entry| {
                // We use null codepoints to pad out our list so indices match
                // the UTF-16 string we constructed for CoreText. We don't want
                // to emit these if this is a special font, since they're not
                // part of the original run.
                if (entry.codepoint == 0) continue;

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

        const attr_dict: *macos.foundation.Dictionary = try self.getFont(
            run.grid,
            run.font_index,
        );

        // Make room for the attributed string and the CTLine.
        try self.cf_release_pool.ensureUnusedCapacity(self.alloc, 3);

        const str = macos.foundation.String.createWithCharactersNoCopy(state.unichars.items);
        self.cf_release_pool.appendAssumeCapacity(str);

        // Create an attributed string from our string
        const attr_str = try macos.foundation.AttributedString.create(
            str,
            attr_dict,
        );
        self.cf_release_pool.appendAssumeCapacity(attr_str);

        // We should always have one run because we do our own run splitting.
        const line = try macos.text.Line.createWithAttributedString(attr_str);
        self.cf_release_pool.appendAssumeCapacity(line);

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
            const advances = try ctrun.getAdvances(alloc);
            const indices = try ctrun.getStringIndices(alloc);
            assert(glyphs.len == advances.len);
            assert(glyphs.len == indices.len);

            for (
                glyphs,
                advances,
                indices,
            ) |glyph, advance, index| {
                // Our cluster is also our cell X position. If the cluster changes
                // then we need to reset our current cell offsets.
                const cluster = state.codepoints.items[index].cluster;
                if (cell_offset.cluster != cluster) pad: {
                    // We previously asserted this but for rtl text this is
                    // not true. So we check for this and break out. In the
                    // future we probably need to reverse pad for rtl but
                    // I don't have a solid test case for this yet so let's
                    // wait for that.
                    if (cell_offset.cluster > cluster) break :pad;

                    cell_offset = .{ .cluster = cluster };
                }

                try self.cell_buf.append(self.alloc, .{
                    .x = @intCast(cluster),
                    .x_offset = @intFromFloat(@round(cell_offset.x)),
                    .y_offset = @intFromFloat(@round(cell_offset.y)),
                    .glyph_index = glyph,
                });

                // Add our advances to keep track of our current cell offsets.
                // Advances apply to the NEXT cell.
                cell_offset.x += advance.width;
                cell_offset.y += advance.height;
            }
        }

        return self.cell_buf.items;
    }

    /// Get an attr dict for a font from a specific index.
    /// These items are cached, do not retain or release them.
    fn getFont(
        self: *Shaper,
        grid: *font.SharedGrid,
        index: font.Collection.Index,
    ) !*macos.foundation.Dictionary {
        // If this grid doesn't match the one we've cached fonts for,
        // then we reset the cache list since it's no longer valid.
        // We use an intFromPtr rather than direct pointer comparison
        // because we don't want anyone to inadvertently use the pointer.
        const grid_id: usize = @intFromPtr(grid);
        if (grid_id != self.cached_font_grid) {
            if (self.cached_font_grid > 0) {
                // Put all the currently cached fonts in to
                // the release pool before clearing the list.
                try self.cf_release_pool.ensureUnusedCapacity(
                    self.alloc,
                    self.cached_fonts.items.len,
                );
                for (self.cached_fonts.items) |ft| {
                    if (ft) |f| {
                        self.cf_release_pool.appendAssumeCapacity(f);
                    }
                }
                self.cached_fonts.clearRetainingCapacity();
            }

            self.cached_font_grid = grid_id;
        }

        const index_int = index.int();

        // The cached fonts are indexed directly by the font index, since
        // this number is usually low. Therefore, we set any index we haven't
        // seen to null.
        if (self.cached_fonts.items.len <= index_int) {
            try self.cached_fonts.ensureTotalCapacity(self.alloc, index_int + 1);
            while (self.cached_fonts.items.len <= index_int) {
                self.cached_fonts.appendAssumeCapacity(null);
            }
        }

        // If we have it, return the cached attr dict.
        if (self.cached_fonts.items[index_int]) |cached| return cached;

        // Font descriptor, font
        try self.cf_release_pool.ensureUnusedCapacity(self.alloc, 2);

        const run_font = font: {
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
            grid.lock.lockShared();
            defer grid.lock.unlockShared();

            const face = try grid.resolver.collection.getFace(index);
            const original = face.font;

            const attrs = if (face.quirks_disable_default_font_features)
                self.features_no_default
            else
                self.features;

            const desc = try macos.text.FontDescriptor.createWithAttributes(attrs);
            self.cf_release_pool.appendAssumeCapacity(desc);

            const copied = try original.copyWithAttributes(0, null, desc);
            errdefer copied.release();

            break :font copied;
        };
        self.cf_release_pool.appendAssumeCapacity(run_font);

        // Get our font and use that get the attributes to set for the
        // attributed string so the whole string uses the same font.
        const attr_dict = dict: {
            var keys = [_]?*const anyopaque{
                macos.text.StringAttribute.font.key(),
                macos.text.StringAttribute.writing_direction.key(),
            };
            var values = [_]?*const anyopaque{
                run_font,
                self.writing_direction,
            };
            break :dict try macos.foundation.Dictionary.create(&keys, &values);
        };

        self.cached_fonts.items[index_int] = attr_dict;
        return attr_dict;
    }

    /// The hooks for RunIterator.
    pub const RunIteratorHook = struct {
        shaper: *Shaper,

        pub fn prepare(self: *RunIteratorHook) !void {
            try self.shaper.run_state.reset();
            // log.warn("----------- run reset -------------", .{});
        }

        pub fn addCodepoint(self: RunIteratorHook, cp: u32, cluster: u32) !void {
            const state = &self.shaper.run_state;

            // Build our UTF-16 string for CoreText
            try state.unichars.ensureUnusedCapacity(self.shaper.alloc, 2);

            state.unichars.appendNTimesAssumeCapacity(0, 2);

            const pair = macos.foundation.stringGetSurrogatePairForLongCharacter(
                cp,
                state.unichars.items[state.unichars.items.len - 2 ..][0..2],
            );
            if (!pair) {
                state.unichars.items.len -= 1;
            }

            // Build our reverse lookup table for codepoints to clusters
            try state.codepoints.append(self.shaper.alloc, .{
                .codepoint = cp,
                .cluster = cluster,
            });
            // log.warn("run cp={X}", .{cp});

            // If the UTF-16 codepoint is a pair then we need to insert
            // a dummy entry so that the CTRunGetStringIndices() function
            // maps correctly.
            if (pair) try state.codepoints.append(self.shaper.alloc, .{
                .codepoint = 0,
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
        while (try it.next(alloc)) |_| count += 1;
        try testing.expectEqual(@as(usize, 3), count);
    }

    // Bad ligatures
    for (&[_][]const u8{ "fl", "fi", "st" }) |bad| {
        // Make a screen with some data
        var screen = try terminal.Screen.init(alloc, 5, 3, 0);
        defer screen.deinit();
        try screen.testWriteString(bad);

        // Get our run iterator
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .screen = &screen,
            .row = screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
        });
        var count: usize = 0;
        while (try it.next(alloc)) |_| count += 1;
        try testing.expectEqual(@as(usize, 2), count);
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

// https://github.com/mitchellh/ghostty/issues/1708
test "shape left-replaced lig in last run" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaperWithFont(alloc, .geist_mono);
    defer testdata.deinit();

    {
        var screen = try terminal.Screen.init(alloc, 5, 3, 0);
        defer screen.deinit();
        try screen.testWriteString("!==");

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

// https://github.com/mitchellh/ghostty/issues/1708
test "shape left-replaced lig in early run" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaperWithFont(alloc, .geist_mono);
    defer testdata.deinit();

    {
        var screen = try terminal.Screen.init(alloc, 5, 3, 0);
        defer screen.deinit();
        try screen.testWriteString("!==X");

        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .screen = &screen,
            .row = screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
        });

        const run = (try it.next(alloc)).?;

        try testing.expectEqual(@as(usize, 4), run.cells);

        const cells = try shaper.shape(run);
        try testing.expectEqual(@as(usize, 2), cells.len);
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
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .screen = &screen,
            .row = screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
        });

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
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .screen = &screen,
            .row = screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
        });
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

    // Changing bg color should NOT split
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

test "shape high plane sprite font codepoint" {
    // While creating runs, the CoreText shaper uses `0` codepoints to
    // pad its codepoint list to account for high plane characters which
    // use two UTF-16 code units. This is so that, after shaping, the string
    // indices can be used to find the originating codepoint / cluster.
    //
    // This is a problem for special (sprite) fonts, which need to be "shaped"
    // by simply returning the input codepoints verbatim. We include logic to
    // skip `0` codepoints when constructing the shaped run for sprite fonts,
    // this test verifies that it works correctly.

    const testing = std.testing;
    const alloc = testing.allocator;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    var screen = try terminal.Screen.init(alloc, 10, 3, 0);
    defer screen.deinit();

    // U+1FB70: Vertical One Eighth Block-2
    try screen.testWriteString("\u{1FB70}");

    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .screen = &screen,
        .row = screen.pages.pin(.{ .screen = .{ .y = 0 } }).?,
    });
    // We should get one run
    const run = (try it.next(alloc)).?;
    // The run state should have the UTF-16 encoding of the character.
    try testing.expectEqualSlices(
        u16,
        &.{ 0xD83E, 0xDF70 },
        shaper.run_state.unichars.items,
    );
    // The codepoint list should be padded.
    try testing.expectEqualSlices(
        Shaper.Codepoint,
        &.{
            .{ .codepoint = 0x1FB70, .cluster = 0 },
            .{ .codepoint = 0, .cluster = 0 },
        },
        shaper.run_state.codepoints.items,
    );
    // And when shape it
    const cells = try shaper.shape(run);
    // we should have
    // - 1 cell
    try testing.expectEqual(1, run.cells);
    // - at position 0
    try testing.expectEqual(0, run.offset);
    // - with 1 glyph in it
    try testing.expectEqual(1, cells.len);
    // - at position 0
    try testing.expectEqual(0, cells[0].x);
    // - the glyph index should be equal to the codepoint
    try testing.expectEqual(0x1FB70, cells[0].glyph_index);
    // - it should be a sprite font
    try testing.expect(run.font_index.special() != null);
    // And we should get a null run after that
    try testing.expectEqual(null, try it.next(alloc));
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
    code_new_roman,
    geist_mono,
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
    const testEmoji = font.embedded.emoji;
    const testEmojiText = font.embedded.emoji_text;
    const testFont = switch (font_req) {
        .code_new_roman => font.embedded.code_new_roman,
        .inconsolata => font.embedded.inconsolata,
        .geist_mono => font.embedded.geist_mono,
        .jetbrains_mono => font.embedded.jetbrains_mono,
        .monaspace_neon => font.embedded.monaspace_neon,
        .nerd_font => font.embedded.test_nerd_font,
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

    if (font.options.backend != .coretext) {
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
