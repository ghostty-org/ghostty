const std = @import("std");
const assert = @import("../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const harfbuzz = @import("harfbuzz");
const font = @import("../main.zig");
const terminal = @import("../../terminal/main.zig");
const unicode = @import("../../unicode/main.zig");
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
const global = @import("../../global.zig");

const log = std.log.scoped(.font_shaper);

/// Shaper that uses Harfbuzz.
pub const Shaper = struct {
    /// The allocated used for the feature list, cell buf, and codepoints.
    alloc: Allocator,

    /// The buffer used for text shaping. We reuse it across multiple shaping
    /// calls to prevent allocations.
    hb_buf: harfbuzz.Buffer,

    /// The shared memory used for shaping results.
    cell_buf: CellBuf,

    /// The features to use for shaping.
    hb_feats: []harfbuzz.Feature,

    /// The codepoints added to the buffer before shaping. We need to keep
    /// these separately because after shaping, HarfBuzz replaces codepoints
    /// with glyph indices in the buffer.
    codepoints: std.ArrayList(Codepoint) = .empty,

    /// For a right-to-left run, maps a logical cell offset within the run
    /// to its visual cell offset. Empty for left-to-right runs, where the
    /// two are the same. Rebuilt per shape call. See `buildVisualMap`.
    visual_map: std.ArrayList(u16) = .empty,

    const Codepoint = struct {
        cluster: u32,
        codepoint: u32,
    };

    const CellBuf = std.ArrayListUnmanaged(font.shape.Cell);

    const RunOffset = struct {
        cluster: u32 = 0,
        x: i32 = 0,
        y: i32 = 0,
    };

    const CellOffset = struct {
        cluster: u32 = 0,
        x: i32 = 0,
    };

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
            .cell_buf = .empty,
            .hb_feats = hb_feats,
        };
    }

    pub fn deinit(self: *Shaper) void {
        self.hb_buf.destroy();
        self.cell_buf.deinit(self.alloc);
        self.alloc.free(self.hb_feats);
        self.codepoints.deinit(self.alloc);
        self.visual_map.deinit(self.alloc);
    }

    pub fn endFrame(self: *const Shaper) void {
        _ = self;
    }

    /// Returns an iterator that returns one text run at a time for the
    /// given terminal row. Note that text runs are only valid one at a time
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
        const rtl = run.direction == .rtl;

        // Force the buffer to the run's resolved direction. `finalize`
        // already ran `guessSegmentProperties` to infer script and
        // language; the direction it inferred from the script is only a
        // guess, whereas the run's direction comes from bidi resolution
        // and is authoritative. A run never spans a direction change, so
        // one direction for the whole buffer is always correct.
        //
        // Codepoints were added in logical order and must stay that way:
        // HarfBuzz decides Arabic joining forms from logical neighbours
        // and emits the glyphs in visual order itself. Handing it
        // pre-reversed text produces the wrong contextual forms.
        self.hb_buf.setDirection(if (rtl) .rtl else .ltr);

        // We only do shaping if the font is not a special-case. For special-case
        // fonts, the codepoint == glyph_index so we don't need to run any shaping.
        if (run.font_index.special() == null) {
            // We have to lock the grid to get the face and unfortunately
            // freetype faces (typically used with harfbuzz) are not thread
            // safe so this has to be an exclusive lock.
            run.grid.lock.lockUncancelable(global.io());
            defer run.grid.lock.unlock(global.io());

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

        // For a right-to-left run we need to know where each logical cell
        // lands visually, because `Cell.x` is a visual offset.
        if (rtl) try self.buildVisualMap(run);

        // This keeps track of the current x and y offsets (sum of advances)
        // and the furthest cluster we've seen so far in the direction the
        // glyphs are being emitted: the largest for a left-to-right run,
        // the smallest for a right-to-left one, since HarfBuzz emits
        // glyphs in visual order and RTL clusters therefore descend.
        var run_offset: RunOffset = .{
            .cluster = if (rtl) std.math.maxInt(u32) else 0,
        };

        // This keeps track of the cell starting x and cluster.
        var cell_offset: CellOffset = .{};

        // Convert all our info/pos to cells and set it.
        self.cell_buf.clearRetainingCapacity();
        for (info, pos) |info_v, pos_v| {
            // info_v.cluster is the index into our codepoints array. We use it
            // to get the original cluster.
            const index = info_v.cluster;
            // Our cluster is also our cell X position. If the cluster changes
            // then we need to reset our current cell offsets.
            const cluster = self.codepoints.items[index].cluster;
            if (cell_offset.cluster != cluster) {
                // Whether this glyph comes after one from the current or a
                // later cluster, i.e. whether glyphs are arriving out of
                // cluster order. Clusters ascend for a left-to-right run
                // and descend for a right-to-left one, so the comparison
                // flips with the direction.
                const is_after_glyph_from_current_or_next_clusters = if (rtl)
                    cluster >= run_offset.cluster
                else
                    cluster <= run_offset.cluster;

                // Whether this is the first codepoint of its cluster in
                // the order the glyphs are being emitted. HarfBuzz
                // reverses the whole buffer for a right-to-left run, which
                // reverses the order within a cluster too, so the search
                // runs forward through the logically ordered codepoints
                // instead of backward.
                const is_first_codepoint_in_cluster = blk: {
                    if (rtl) {
                        var i = index + 1;
                        while (i < self.codepoints.items.len) : (i += 1) {
                            break :blk self.codepoints.items[i].cluster != cluster;
                        }
                        break :blk true;
                    }

                    var i = index;
                    while (i > 0) {
                        i -= 1;
                        const codepoint = self.codepoints.items[i];
                        break :blk codepoint.cluster != cluster;
                    } else break :blk true;
                };

                // We need to reset the `cell_offset` at the start of a new
                // cluster, but we do that conditionally if the codepoint
                // `is_first_codepoint_in_cluster` and the cluster is not
                // `is_after_glyph_from_current_or_next_clusters`, which is
                // a heuristic to detect ligatures and avoid positioning
                // glyphs that mark ligatures incorrectly. The idea is that
                // if the first codepoint in a cluster doesn't appear in
                // the stream, it's very likely that it combined with
                // codepoints from a previous cluster into a ligature.
                // Then, the subsequent codepoints are very likely marking
                // glyphs that are placed relative to that ligature, so if
                // we were to reset the `cell_offset` to align it with the
                // grid, the positions would be off. The
                // `!is_after_glyph_from_current_or_next_clusters` check is
                // needed in case these marking glyphs come from a later
                // cluster but are rendered first (see the Chakma and
                // Bengali tests). In that case when we get to the
                // codepoint that `is_first_codepoint_in_cluster`, but in a
                // cluster that
                // `is_after_glyph_from_current_or_next_clusters`, we don't
                // want to reset to the grid and cause the positions to be
                // off. (Note that we could go back and align the cells to
                // the grid starting from the one from the cluster that
                // rendered out of order, but that is more complicated so
                // we don't do that for now. Also, it's TBD if there are
                // exceptions to this heuristic for detecting ligatures,
                // but using the logging below seems to show it works
                // well.)
                if (is_first_codepoint_in_cluster and
                    !is_after_glyph_from_current_or_next_clusters)
                {
                    cell_offset = .{
                        .cluster = cluster,
                        .x = run_offset.x,
                    };
                }
            }

            // Under both FreeType and CoreText the harfbuzz scale is
            // in 26.6 fixed point units, so we round to the nearest
            // whole value here.
            const x_offset = run_offset.x - cell_offset.x + ((pos_v.x_offset + 0b100_000) >> 6);
            const y_offset = run_offset.y + ((pos_v.y_offset + 0b100_000) >> 6);

            // For debugging positions, turn this on:
            //try self.debugPositions(run_offset, cell_offset, pos_v, index);

            try self.cell_buf.append(self.alloc, .{
                // `Cell.x` is a visual offset within the run, because the
                // renderer walks visual columns and requires it to ascend.
                // For a left-to-right run the logical cluster already is
                // that offset; for a right-to-left one it has to be
                // mapped. See `buildVisualMap`.
                .x = if (rtl)
                    self.visual_map.items[@intCast(cell_offset.cluster)]
                else
                    @intCast(cell_offset.cluster),
                .x_offset = @intCast(x_offset),
                .y_offset = @intCast(y_offset),
                .glyph_index = info_v.codepoint,
            });

            // Add our advances to keep track of our run offsets.
            // Advances apply to the NEXT cell.
            // Under both FreeType and CoreText the harfbuzz scale is
            // in 26.6 fixed point units, so we round to the nearest
            // whole value here.
            run_offset.x += (pos_v.x_advance + 0b100_000) >> 6;
            run_offset.y += (pos_v.y_advance + 0b100_000) >> 6;
            run_offset.cluster = if (rtl)
                @min(run_offset.cluster, cluster)
            else
                @max(run_offset.cluster, cluster);

            // const i = self.cell_buf.items.len - 1;
            // log.warn("i={} info={} pos={} cell={}", .{ i, info_v, pos_v, self.cell_buf.items[i] });
        }
        //log.warn("----------------", .{});

        return self.cell_buf.items;
    }

    /// Build the logical-to-visual cell offset map for a right-to-left run.
    ///
    /// Rule L2 of UAX #9 reverses a right-to-left run's cells, so the
    /// logically first cell is displayed rightmost. `Cell.x` is a visual
    /// offset relative to the run, so it needs that reversal applied.
    ///
    /// Cells are not all one column wide, which is what makes this more
    /// than a subtraction. A cell occupying logical columns [c, c+w) must
    /// occupy visual columns [cells-c-w, cells-c), so the visual offset of
    /// a cell is `cells - c - w` rather than `cells - 1 - c`. Widths are
    /// recovered from the gaps between consecutive cluster values, since
    /// the run iterator skips spacer cells and therefore leaves a gap of
    /// exactly the cell's width.
    fn buildVisualMap(
        self: *Shaper,
        run: font.shape.TextRun,
    ) Allocator.Error!void {
        self.visual_map.clearRetainingCapacity();
        try self.visual_map.resize(self.alloc, run.cells);
        @memset(self.visual_map.items, 0);

        // Codepoints are in logical order, so cluster values here are
        // non-decreasing and equal for the codepoints of one grapheme.
        const cps = self.codepoints.items;
        var i: usize = 0;
        while (i < cps.len) {
            const cluster = cps[i].cluster;

            var j = i + 1;
            while (j < cps.len and cps[j].cluster == cluster) j += 1;

            const next: u32 = if (j < cps.len) cps[j].cluster else run.cells;
            const width = next - cluster;

            // A run always covers the cells its clusters address, so this
            // cannot underflow unless the run and the buffer disagree.
            assert(cluster + width <= run.cells);
            self.visual_map.items[@intCast(cluster)] =
                @intCast(run.cells - cluster - width);

            i = j;
        }
    }

    /// The hooks for RunIterator.
    pub const RunIteratorHook = struct {
        shaper: *Shaper,

        pub fn prepare(self: RunIteratorHook) void {
            // Reset the buffer for our current run
            self.shaper.hb_buf.reset();
            self.shaper.hb_buf.setContentType(.unicode);

            // We set the cluster level to `characters` to give us the most
            // granularity, matching the CoreText shaper, and allowing us
            // to use our same ligature detection heuristics.
            self.shaper.hb_buf.setClusterLevel(.characters);

            self.shaper.codepoints.clearRetainingCapacity();

            // Direction is deliberately left unset here. `finalize` calls
            // `guessSegmentProperties`, which infers the script from the
            // buffer contents, and `shape` then forces the direction from
            // the run. Setting it here would only stop the guess from
            // running and would be overridden anyway.
        }

        pub fn addCodepoint(self: RunIteratorHook, cp: u32, cluster: u32) !void {
            // log.warn("cluster={} cp={x}", .{ cluster, cp });
            // We pass the index into codepoints as the cluster value to HarfBuzz.
            // After shaping, we use info.cluster to get back the index, which
            // lets us look up the original cluster value from codepoints.
            const index: u32 = @intCast(self.shaper.codepoints.items.len);
            self.shaper.hb_buf.add(cp, index);
            try self.shaper.codepoints.append(self.shaper.alloc, .{
                .cluster = cluster,
                .codepoint = cp,
            });
        }

        pub fn finalize(self: RunIteratorHook) void {
            // Infers script and language from the buffer contents. It also
            // infers direction, but only because direction is still unset
            // at this point; `shape` overrides it with the run's resolved
            // direction, which is the authoritative value.
            self.shaper.hb_buf.guessSegmentProperties();
        }
    };

    fn debugPositions(
        self: *Shaper,
        run_offset: RunOffset,
        cell_offset: CellOffset,
        pos_v: harfbuzz.GlyphPosition,
        index: u32,
    ) !void {
        const x_offset = run_offset.x - cell_offset.x + ((pos_v.x_offset + 0b100_000) >> 6);
        const y_offset = run_offset.y + ((pos_v.y_offset + 0b100_000) >> 6);
        const advance_x_offset = run_offset.x - cell_offset.x;
        const advance_y_offset = run_offset.y;
        const x_offset_diff = x_offset - advance_x_offset;
        const y_offset_diff = y_offset - advance_y_offset;
        const positions_differ = @abs(x_offset_diff) > 0 or @abs(y_offset_diff) > 0;
        const y_offset_differs = run_offset.y != 0;
        const cluster = self.codepoints.items[index].cluster;
        const cluster_differs = cluster != cell_offset.cluster;

        // To debug every loop, flip this to true:
        const extra_debugging = false;

        const is_previous_codepoint_prepend = if (cluster_differs or
            extra_debugging)
        blk: {
            var i = index;
            while (i > 0) {
                i -= 1;
                const codepoint = self.codepoints.items[i];
                break :blk unicode.table.get(@intCast(codepoint.codepoint)).grapheme_boundary_class == .prepend;
            }
            break :blk false;
        } else false;

        const formatted_cps: ?[]u8 = if (positions_differ or
            y_offset_differs or
            cluster_differs or
            extra_debugging)
        blk: {
            var allocating = std.Io.Writer.Allocating.init(self.alloc);
            defer allocating.deinit();
            const writer = &allocating.writer;
            const codepoints = self.codepoints.items;
            var last_cluster: ?u32 = null;
            for (codepoints, 0..) |cp, i| {
                if (@as(i32, @intCast(cp.cluster)) >= @as(i32, @intCast(cell_offset.cluster)) - 1 and
                    cp.cluster <= cluster + 1)
                {
                    if (last_cluster) |last| {
                        if (cp.cluster != last) {
                            try writer.writeAll(" ");
                        }
                    }
                    if (i == index) {
                        try writer.writeAll("▸");
                    }
                    // Using Python syntax for easier debugging
                    if (cp.codepoint > 0xFFFF) {
                        try writer.print("\\U{x:0>8}", .{cp.codepoint});
                    } else {
                        try writer.print("\\u{x:0>4}", .{cp.codepoint});
                    }
                    last_cluster = cp.cluster;
                }
            }
            try writer.writeAll(" → ");
            for (codepoints) |cp| {
                if (@as(i32, @intCast(cp.cluster)) >= @as(i32, @intCast(cell_offset.cluster)) - 1 and
                    cp.cluster <= cluster + 1)
                {
                    try writer.print("{u}", .{@as(u21, @intCast(cp.codepoint))});
                }
            }
            break :blk try allocating.toOwnedSlice();
        } else null;
        defer if (formatted_cps) |cps| self.alloc.free(cps);

        if (extra_debugging) {
            log.warn("extra debugging of positions index={d} cell_offset.cluster={d} cluster={d} run_offset.cluster={d} diff={d} pos=({d},{d}) run_offset=({d},{d}) cell_offset.x={d} is_prev_prepend={} cps = {s}", .{
                index,
                cell_offset.cluster,
                cluster,
                run_offset.cluster,
                @as(isize, @intCast(cluster)) - @as(isize, @intCast(cell_offset.cluster)),
                x_offset,
                y_offset,
                run_offset.x,
                run_offset.y,
                cell_offset.x,
                is_previous_codepoint_prepend,
                formatted_cps.?,
            });
        }

        if (positions_differ) {
            log.warn("position differs from advance: cluster={d} pos=({d},{d}) adv=({d},{d}) diff=({d},{d}) cps = {s}", .{
                cluster,
                x_offset,
                y_offset,
                advance_x_offset,
                advance_y_offset,
                x_offset_diff,
                y_offset_diff,
                formatted_cps.?,
            });
        }

        if (y_offset_differs) {
            log.warn("run_offset.y differs from zero: cluster={d} pos=({d},{d}) run_offset=({d},{d}) cell_offset.x={d} cps = {s}", .{
                cluster,
                x_offset,
                y_offset,
                run_offset.x,
                run_offset.y,
                cell_offset.x,
                formatted_cps.?,
            });
        }

        if (cluster_differs) {
            log.warn("cell_offset.cluster differs from cluster (potential ligature detected) cell_offset.cluster={d} cluster={d} run_offset.cluster={d} diff={d} pos=({d},{d}) run_offset=({d},{d}) cell_offset.x={d} is_prev_prepend={} cps = {s}", .{
                cell_offset.cluster,
                cluster,
                run_offset.cluster,
                @as(isize, @intCast(cluster)) - @as(isize, @intCast(cell_offset.cluster)),
                x_offset,
                y_offset,
                run_offset.x,
                run_offset.y,
                cell_offset.x,
                is_previous_codepoint_prepend,
                formatted_cps.?,
            });
        }
    }
};

test "run iterator" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    {
        // Make a screen with some data
        var t = try terminal.Terminal.init(io, alloc, .{ .cols = 5, .rows = 3 });
        defer t.deinit(alloc);

        var s = t.vtStream();
        defer s.deinit();
        s.nextSlice("ABCD");

        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &t);

        // Get our run iterator
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
        });
        var count: usize = 0;
        while (try it.next(alloc)) |_| count += 1;
        try testing.expectEqual(@as(usize, 1), count);
    }

    // Spaces should be part of a run
    {
        var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 3 });
        defer t.deinit(alloc);

        var s = t.vtStream();
        defer s.deinit();
        s.nextSlice("ABCD   EFG");

        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &t);

        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
        });
        var count: usize = 0;
        while (try it.next(alloc)) |_| count += 1;
        try testing.expectEqual(@as(usize, 1), count);
    }

    {
        // Make a screen with some data
        var t = try terminal.Terminal.init(io, alloc, .{ .cols = 5, .rows = 3 });
        defer t.deinit(alloc);

        var s = t.vtStream();
        defer s.deinit();
        s.nextSlice("A😃D");

        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &t);

        // Get our run iterator
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
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
    const io = testing.io;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    {
        // Make a screen with some data
        var t = try terminal.Terminal.init(io, alloc, .{ .cols = 5, .rows = 3 });
        defer t.deinit(alloc);

        var s = t.vtStream();
        defer s.deinit();
        // Set red background and write A
        s.nextSlice("\x1b[48;2;255;0;0mA");

        // Get our first row
        {
            const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 1 } }).?;
            const cell = list_cell.cell;
            cell.* = .{
                .content_tag = .bg_color_rgb,
                .content = .{ .color_rgb = .{ .r = 0xFF, .g = 0, .b = 0 } },
            };
        }
        {
            const list_cell = t.screens.active.pages.getCell(.{ .active = .{ .x = 2 } }).?;
            const cell = list_cell.cell;
            cell.* = .{
                .content_tag = .bg_color_rgb,
                .content = .{ .color_rgb = .{ .r = 0xFF, .g = 0, .b = 0 } },
            };
        }

        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &t);

        // Get our run iterator
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
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
    const io = testing.io;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;
    buf_idx += try std.unicode.utf8Encode(0x1F44D, buf[buf_idx..]); // Thumbs up plain
    buf_idx += try std.unicode.utf8Encode(0x1F44D, buf[buf_idx..]); // Thumbs up plain
    buf_idx += try std.unicode.utf8Encode(0x1F3FD, buf[buf_idx..]); // Medium skin tone

    // Make a screen with some data
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice(buf[0..buf_idx]);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Get our run iterator
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
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
    const io = testing.io;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    {
        var t = try terminal.Terminal.init(io, alloc, .{ .cols = 5, .rows = 3 });
        defer t.deinit(alloc);

        var s = t.vtStream();
        defer s.deinit();
        s.nextSlice(">=");

        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &t);

        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
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
        var t = try terminal.Terminal.init(io, alloc, .{ .cols = 5, .rows = 3 });
        defer t.deinit(alloc);

        var s = t.vtStream();
        defer s.deinit();
        s.nextSlice("===");

        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &t);

        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
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
    const io = testing.io;

    var testdata = try testShaperWithFont(alloc, .monaspace_neon);
    defer testdata.deinit();

    {
        var t = try terminal.Terminal.init(io, alloc, .{ .cols = 5, .rows = 3 });
        defer t.deinit(alloc);

        var s = t.vtStream();
        defer s.deinit();
        s.nextSlice("===");

        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &t);

        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
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
    const io = testing.io;

    var testdata = try testShaperWithFont(alloc, .arabic);
    defer testdata.deinit();

    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 120, .rows = 30 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice(@embedFile("testdata/arabic.txt"));

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
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
    const io = testing.io;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    {
        var t = try terminal.Terminal.init(io, alloc, .{ .cols = 5, .rows = 3 });
        defer t.deinit(alloc);

        var s = t.vtStream();
        defer s.deinit();
        s.nextSlice("👍");

        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &t);

        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
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
    const io = testing.io;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    // Make a screen and add a long emoji sequence to it.
    var t = try terminal.Terminal.init(
        io,
        alloc,
        .{ .cols = 30, .rows = 3 },
    );
    defer t.deinit(alloc);

    var page = t.screens.active.pages.pages.first.?.page();
    var row = page.getRow(1);
    const cell = &row.cells.ptr(page.memory)[0];
    cell.* = .{
        .content_tag = .codepoint,
        .content = .{ .codepoint = @bitCast(@as(u24, 0x1F9D4)) }, // Person with beard
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

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Get our run iterator
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(1).cells.slice(),
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
    const io = testing.io;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;
    buf_idx += try std.unicode.utf8Encode(0x270C, buf[buf_idx..]); // Victory sign (default text)
    buf_idx += try std.unicode.utf8Encode(0xFE0E, buf[buf_idx..]); // ZWJ to force text

    // Make a screen with some data
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice(buf[0..buf_idx]);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Get our run iterator
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
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
    const io = testing.io;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;
    buf_idx += try std.unicode.utf8Encode(0x270C, buf[buf_idx..]); // Victory sign (default text)
    buf_idx += try std.unicode.utf8Encode(0xFE0F, buf[buf_idx..]); // ZWJ to force color

    // Make a screen with some data
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice(buf[0..buf_idx]);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Get our run iterator
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
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
    const io = testing.io;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    // Make a screen with some data
    var t = try terminal.Terminal.init(
        io,
        alloc,
        .{ .cols = 30, .rows = 3 },
    );
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("A");
    s.nextSlice("\x1b[5C");
    s.nextSlice("B");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Get our run iterator
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
    });
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;

        const cells = try shaper.shape(run);
        try testing.expectEqual(@as(usize, 1), count);
        try testing.expectEqual(@as(usize, 7), cells.len);
    }
}

test "shape Combining characters" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;
    buf_idx += try std.unicode.utf8Encode('n', buf[buf_idx..]); // Combining
    buf_idx += try std.unicode.utf8Encode(0x0308, buf[buf_idx..]); // Combining
    buf_idx += try std.unicode.utf8Encode(0x0308, buf[buf_idx..]);
    buf_idx += try std.unicode.utf8Encode('a', buf[buf_idx..]);

    // Make a screen with some data
    var t = try terminal.Terminal.init(
        io,
        alloc,
        .{ .cols = 30, .rows = 3 },
    );
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice(buf[0..buf_idx]);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Get our run iterator
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
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

// This test exists because the string it uses causes HarfBuzz to output a
// non-monotonic run with our cluster level set to `characters`, which we need
// to handle by tracking the max cluster for the run.
test "shape Devanagari string" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    // We need a font that supports devanagari for this to work, if we can't
    // find Arial Unicode MS, which is a system font on macOS, we just skip
    // the test.
    var testdata = testShaperWithDiscoveredFont(
        alloc,
        "Arial Unicode MS",
    ) catch return error.SkipZigTest;
    defer testdata.deinit();

    // Make a screen with some data
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 30, .rows = 3 });
    defer t.deinit(alloc);

    // Disable grapheme clustering
    t.modes.set(.grapheme_cluster, false);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("अपार्टमेंट");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Get our run iterator
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
    });

    const run = try it.next(alloc);
    try testing.expect(run != null);
    const cells = try shaper.shape(run.?);

    try testing.expectEqual(@as(usize, 8), cells.len);
    try testing.expectEqual(@as(u16, 0), cells[0].x);
    try testing.expectEqual(@as(u16, 1), cells[1].x);
    try testing.expectEqual(@as(u16, 2), cells[2].x);
    try testing.expectEqual(@as(u16, 4), cells[3].x);
    try testing.expectEqual(@as(u16, 4), cells[4].x);
    try testing.expectEqual(@as(u16, 5), cells[5].x);
    try testing.expectEqual(@as(u16, 5), cells[6].x);
    try testing.expectEqual(@as(u16, 6), cells[7].x);

    try testing.expect(try it.next(alloc) == null);
}

// This test fails on Linux if you have the "Noto Sans Tai Tham" font installed
// locally. Disabling this test until it can be fixed.
test "shape Tai Tham vowels (position differs from advance)" {
    return error.SkipZigTest;
    // // Note that while this test was necessary for CoreText, the old logic was
    // // working for HarfBuzz. Still we keep it to ensure it has the correct
    // // behavior.
    // const testing = std.testing;
    // const alloc = testing.allocator;
    // const io = testing.io;

    // // We need a font that supports Tai Tham for this to work, if we can't find
    // // Noto Sans Tai Tham, which is a system font on macOS, we just skip the
    // // test.
    // var testdata = testShaperWithDiscoveredFont(
    //     alloc,
    //     "Noto Sans Tai Tham",
    // ) catch return error.SkipZigTest;
    // defer testdata.deinit();

    // var buf: [32]u8 = undefined;
    // var buf_idx: usize = 0;
    // buf_idx += try std.unicode.utf8Encode(0x1a2F, buf[buf_idx..]); // ᨯ
    // buf_idx += try std.unicode.utf8Encode(0x1a70, buf[buf_idx..]); //  ᩰ

    // // Make a screen with some data
    // var t = try terminal.Terminal.init(io, alloc, .{ .cols = 30, .rows = 3 });
    // defer t.deinit(alloc);

    // // Enable grapheme clustering
    // t.modes.set(.grapheme_cluster, true);

    // var s = t.vtStream();
    // defer s.deinit();
    // s.nextSlice(buf[0..buf_idx]);

    // var state: terminal.RenderState = .empty;
    // defer state.deinit(alloc);
    // try state.update(alloc, &t);

    // // Get our run iterator
    // var shaper = &testdata.shaper;
    // var it = shaper.runIterator(.{
    //     .grid = testdata.grid,
    //     .cells = state.row_data.get(0).cells.slice(),
    // });
    // var count: usize = 0;
    // while (try it.next(alloc)) |run| {
    //     count += 1;

    //     const cells = try shaper.shape(run);
    //     try testing.expectEqual(@as(usize, 2), cells.len);
    //     try testing.expectEqual(@as(u16, 0), cells[0].x);
    //     try testing.expectEqual(@as(u16, 0), cells[1].x);

    //     // The first glyph renders in the next cell. We expect the x_offset
    //     // to equal the cell width. However, with FreeType the cell_width is
    //     // computed from ASCII glyphs, and Noto Sans Tai Tham only has the
    //     // space character in ASCII (with a 3px advance), so the cell_width
    //     // metric doesn't match the actual Tai Tham glyph positioning.
    //     const expected_x_offset: i16 = if (comptime font.options.backend.hasFreetype()) 7 else @intCast(run.grid.metrics.cell_width);
    //     try testing.expectEqual(expected_x_offset, cells[0].x_offset);
    //     try testing.expectEqual(@as(i16, 0), cells[1].x_offset);
    // }
    // try testing.expectEqual(@as(usize, 1), count);
}

test "shape Tibetan characters" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    // We need a font that has multiple glyphs for this codepoint to reproduce
    // the old broken behavior, and Noto Serif Tibetan is one of them. It's not
    // a default Mac font, and if we can't find it we just skip the test.
    var testdata = testShaperWithDiscoveredFont(
        alloc,
        "Noto Serif Tibetan",
    ) catch return error.SkipZigTest;
    defer testdata.deinit();

    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;
    buf_idx += try std.unicode.utf8Encode(0x0f00, buf[buf_idx..]); // ༀ

    // Make a screen with some data
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 30, .rows = 3 });
    defer t.deinit(alloc);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice(buf[0..buf_idx]);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Get our run iterator
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
    });
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;

        const cells = try shaper.shape(run);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u16, 0), cells[0].x);
        try testing.expectEqual(@as(u16, 0), cells[1].x);

        // The second glyph renders at the correct location
        try testing.expect(cells[1].x_offset < 2);
    }
    try testing.expectEqual(@as(usize, 1), count);
}

// This test fails on Linux if you have the "Noto Sans Tai Tham" font installed
// locally. Disabling this test until it can be fixed.
test "shape Tai Tham letters (run_offset.y differs from zero)" {
    return error.SkipZigTest;
    // const testing = std.testing;
    // const alloc = testing.allocator;
    // const io = testing.io;

    // // We need a font that supports Tai Tham for this to work, if we can't find
    // // Noto Sans Tai Tham, which is a system font on macOS, we just skip the
    // // test.
    // var testdata = testShaperWithDiscoveredFont(
    //     alloc,
    //     "Noto Sans Tai Tham",
    // ) catch return error.SkipZigTest;
    // defer testdata.deinit();

    // var buf: [32]u8 = undefined;
    // var buf_idx: usize = 0;

    // // First grapheme cluster:
    // buf_idx += try std.unicode.utf8Encode(0x1a49, buf[buf_idx..]); // HA
    // buf_idx += try std.unicode.utf8Encode(0x1a60, buf[buf_idx..]); // SAKOT
    // // Second grapheme cluster, combining with the first in a ligature:
    // buf_idx += try std.unicode.utf8Encode(0x1a3f, buf[buf_idx..]); // YA
    // buf_idx += try std.unicode.utf8Encode(0x1a69, buf[buf_idx..]); // U

    // // Make a screen with some data
    // var t = try terminal.Terminal.init(io, alloc, .{ .cols = 30, .rows = 3 });
    // defer t.deinit(alloc);

    // // Enable grapheme clustering
    // t.modes.set(.grapheme_cluster, true);

    // var s = t.vtStream();
    // defer s.deinit();
    // s.nextSlice(buf[0..buf_idx]);

    // var state: terminal.RenderState = .empty;
    // defer state.deinit(alloc);
    // try state.update(alloc, &t);

    // // Get our run iterator
    // var shaper = &testdata.shaper;
    // var it = shaper.runIterator(.{
    //     .grid = testdata.grid,
    //     .cells = state.row_data.get(0).cells.slice(),
    // });
    // var count: usize = 0;
    // while (try it.next(alloc)) |run| {
    //     count += 1;

    //     const cells = try shaper.shape(run);
    //     try testing.expectEqual(@as(usize, 3), cells.len);
    //     try testing.expectEqual(@as(u16, 0), cells[0].x);
    //     try testing.expectEqual(@as(u16, 0), cells[1].x);
    //     try testing.expectEqual(@as(u16, 0), cells[2].x); // U from second grapheme

    //     // The U glyph renders at a y below zero
    //     try testing.expectEqual(@as(i16, -3), cells[2].y_offset);
    // }
    // try testing.expectEqual(@as(usize, 1), count);
}

// This test fails on Linux if you have the "Noto Sans Javanese" font installed
// locally. Disabling this test until it can be fixed.
test "shape Javanese ligatures" {
    return error.SkipZigTest;
    // const testing = std.testing;
    // const alloc = testing.allocator;
    // const io = testing.io;

    // // We need a font that supports Javanese for this to work, if we can't find
    // // Noto Sans Javanese Regular, which is a system font on macOS, we just
    // // skip the test.
    // var testdata = testShaperWithDiscoveredFont(
    //     alloc,
    //     "Noto Sans Javanese",
    // ) catch return error.SkipZigTest;
    // defer testdata.deinit();

    // var buf: [32]u8 = undefined;
    // var buf_idx: usize = 0;

    // // First grapheme cluster:
    // buf_idx += try std.unicode.utf8Encode(0xa9a4, buf[buf_idx..]); // NA
    // buf_idx += try std.unicode.utf8Encode(0xa9c0, buf[buf_idx..]); // PANGKON
    // // Second grapheme cluster, combining with the first in a ligature:
    // buf_idx += try std.unicode.utf8Encode(0xa9b2, buf[buf_idx..]); // HA
    // buf_idx += try std.unicode.utf8Encode(0xa9b8, buf[buf_idx..]); // Vowel sign SUKU

    // // Make a screen with some data
    // var t = try terminal.Terminal.init(io, alloc, .{ .cols = 30, .rows = 3 });
    // defer t.deinit(alloc);

    // // Enable grapheme clustering
    // t.modes.set(.grapheme_cluster, true);

    // var s = t.vtStream();
    // defer s.deinit();
    // s.nextSlice(buf[0..buf_idx]);

    // var state: terminal.RenderState = .empty;
    // defer state.deinit(alloc);
    // try state.update(alloc, &t);

    // // Get our run iterator
    // var shaper = &testdata.shaper;
    // var it = shaper.runIterator(.{
    //     .grid = testdata.grid,
    //     .cells = state.row_data.get(0).cells.slice(),
    // });
    // var count: usize = 0;
    // while (try it.next(alloc)) |run| {
    //     count += 1;

    //     const cells = try shaper.shape(run);
    //     const cell_width = run.grid.metrics.cell_width;
    //     try testing.expectEqual(@as(usize, 3), cells.len);
    //     try testing.expectEqual(@as(u16, 0), cells[0].x);
    //     try testing.expectEqual(@as(u16, 0), cells[1].x);
    //     try testing.expectEqual(@as(u16, 0), cells[2].x);

    //     // The vowel sign SUKU renders with correct x_offset
    //     try testing.expect(cells[2].x_offset > 3 * cell_width);
    // }
    // try testing.expectEqual(@as(usize, 1), count);
}

test "shape Chakma vowel sign with ligature (vowel sign renders first)" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    // We need a font that supports Chakma for this to work, if we can't find
    // Noto Sans Chakma Regular, which is a system font on macOS, we just skip
    // the test.
    var testdata = testShaperWithDiscoveredFont(
        alloc,
        "Noto Sans Chakma",
    ) catch return error.SkipZigTest;
    defer testdata.deinit();

    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;

    // First grapheme cluster:
    buf_idx += try std.unicode.utf8Encode(0x1111d, buf[buf_idx..]); // BAA
    // Second grapheme cluster:
    buf_idx += try std.unicode.utf8Encode(0x11116, buf[buf_idx..]); // TAA
    buf_idx += try std.unicode.utf8Encode(0x11133, buf[buf_idx..]); // Virama
    // Third grapheme cluster, combining with the second in a ligature:
    buf_idx += try std.unicode.utf8Encode(0x11120, buf[buf_idx..]); // YYAA
    buf_idx += try std.unicode.utf8Encode(0x1112c, buf[buf_idx..]); // Vowel Sign U

    // Make a screen with some data
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 30, .rows = 3 });
    defer t.deinit(alloc);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice(buf[0..buf_idx]);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Get our run iterator
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
    });
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;

        const cells = try shaper.shape(run);
        try testing.expectEqual(@as(usize, 4), cells.len);
        try testing.expectEqual(@as(u16, 0), cells[0].x);
        // See the giant "We need to reset the `cell_offset`" comment, but here
        // we should technically have the rest of these be `x` of 1, but that
        // would require going back in the stream to adjust past cells, and
        // we don't take on that complexity.
        try testing.expectEqual(@as(u16, 0), cells[1].x);
        try testing.expectEqual(@as(u16, 0), cells[2].x);
        try testing.expectEqual(@as(u16, 0), cells[3].x);

        // The vowel sign U renders before the TAA:
        try testing.expect(cells[1].x_offset < cells[2].x_offset);
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "shape Bengali ligatures with out of order vowels" {
    // Whereas this test in CoreText had everything shaping into one giant
    // ligature, HarfBuzz splits it into a few clusters. It still looks okay
    // (see #10332).

    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    // We need a font that supports Bengali for this to work, if we can't find
    // Arial Unicode MS, which is a system font on macOS, we just skip the
    // test.
    var testdata = testShaperWithDiscoveredFont(
        alloc,
        "Arial Unicode MS",
    ) catch return error.SkipZigTest;
    defer testdata.deinit();

    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;

    // First grapheme cluster:
    buf_idx += try std.unicode.utf8Encode(0x09b0, buf[buf_idx..]); // RA
    buf_idx += try std.unicode.utf8Encode(0x09be, buf[buf_idx..]); // Vowel sign AA
    // Second grapheme cluster:
    buf_idx += try std.unicode.utf8Encode(0x09b7, buf[buf_idx..]); // SSA
    buf_idx += try std.unicode.utf8Encode(0x09cd, buf[buf_idx..]); // Virama
    // Third grapheme cluster:
    buf_idx += try std.unicode.utf8Encode(0x099f, buf[buf_idx..]); // TTA
    buf_idx += try std.unicode.utf8Encode(0x09cd, buf[buf_idx..]); // Virama
    // Fourth grapheme cluster:
    buf_idx += try std.unicode.utf8Encode(0x09b0, buf[buf_idx..]); // RA
    buf_idx += try std.unicode.utf8Encode(0x09c7, buf[buf_idx..]); // Vowel sign E

    // Make a screen with some data
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 30, .rows = 3 });
    defer t.deinit(alloc);

    // Enable grapheme clustering
    t.modes.set(.grapheme_cluster, true);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice(buf[0..buf_idx]);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Get our run iterator
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
    });
    var count: usize = 0;
    while (try it.next(alloc)) |run| {
        count += 1;

        const cells = try shaper.shape(run);
        try testing.expectEqual(@as(usize, 8), cells.len);
        try testing.expectEqual(@as(u16, 0), cells[0].x);
        try testing.expectEqual(@as(u16, 0), cells[1].x);

        // Whereas CoreText puts everything all into the first cell (see the
        // corresponding test), HarfBuzz splits into two clusters.
        try testing.expectEqual(@as(u16, 2), cells[2].x);
        try testing.expectEqual(@as(u16, 2), cells[3].x);
        try testing.expectEqual(@as(u16, 2), cells[4].x);
        try testing.expectEqual(@as(u16, 2), cells[5].x);
        try testing.expectEqual(@as(u16, 2), cells[6].x);
        try testing.expectEqual(@as(u16, 2), cells[7].x);

        // The vowel sign E renders before the SSA:
        try testing.expect(cells[2].x_offset < cells[3].x_offset);
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "shape box glyphs" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    var buf: [32]u8 = undefined;
    var buf_idx: usize = 0;
    buf_idx += try std.unicode.utf8Encode(0x2500, buf[buf_idx..]); // horiz line
    buf_idx += try std.unicode.utf8Encode(0x2501, buf[buf_idx..]); //

    // Make a screen with some data
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice(buf[0..buf_idx]);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Get our run iterator
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
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
    const io = testing.io;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    // Make a screen with some data
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("a1b2c3d4e5");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Full line selection
    {
        // Get our run iterator
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
            .selection = .{ 0, 9 },
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
            .cells = state.row_data.get(0).cells.slice(),
            .selection = .{ 2, 9 },
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
            .cells = state.row_data.get(0).cells.slice(),
            .selection = .{ 0, 3 },
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
            .cells = state.row_data.get(0).cells.slice(),
            .selection = .{ 1, 3 },
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
            .cells = state.row_data.get(0).cells.slice(),
            .selection = .{ 1, 1 },
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
    const io = testing.io;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    // Make a screen with some data
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 3 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("a1b2c3d4e5");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // No cursor is full line
    {
        // Get our run iterator
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
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
                .cells = state.row_data.get(0).cells.slice(),
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
                .cells = state.row_data.get(0).cells.slice(),
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
                .cells = state.row_data.get(0).cells.slice(),
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
                .cells = state.row_data.get(0).cells.slice(),
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
                .cells = state.row_data.get(0).cells.slice(),
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
                .cells = state.row_data.get(0).cells.slice(),
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
    const io = testing.io;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    // Make a screen with some data
    var t = try terminal.Terminal.init(
        io,
        alloc,
        .{ .cols = 3, .rows = 10 },
    );
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("👍🏼");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // No cursor is full line
    {
        // Get our run iterator
        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
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
            .cells = state.row_data.get(0).cells.slice(),
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
            .cells = state.row_data.get(0).cells.slice(),
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
            .cells = state.row_data.get(0).cells.slice(),
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
            .cells = state.row_data.get(0).cells.slice(),
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
    const io = testing.io;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    // Plain >= should shape into 1 run
    {
        var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 3 });
        defer t.deinit(alloc);

        var s = t.vtStream();
        defer s.deinit();
        s.nextSlice(">=");

        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &t);

        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
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
        var t = try terminal.Terminal.init(io, alloc, .{ .cols = 3, .rows = 10 });
        defer t.deinit(alloc);

        var s = t.vtStream();
        defer s.deinit();
        s.nextSlice(">");
        s.nextSlice("\x1b[1m");
        s.nextSlice("=");

        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &t);

        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
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
        var t = try terminal.Terminal.init(io, alloc, .{ .cols = 3, .rows = 10 });
        defer t.deinit(alloc);

        var s = t.vtStream();
        defer s.deinit();
        // RGB 1, 2, 3
        s.nextSlice("\x1b[38;2;1;2;3m");
        s.nextSlice(">");
        // RGB 3, 2, 1
        s.nextSlice("\x1b[38;2;3;2;1m");
        s.nextSlice("=");

        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &t);

        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
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
        var t = try terminal.Terminal.init(io, alloc, .{ .cols = 3, .rows = 10 });
        defer t.deinit(alloc);

        var s = t.vtStream();
        defer s.deinit();
        // RGB 1, 2, 3 bg
        s.nextSlice("\x1b[48;2;1;2;3m");
        s.nextSlice(">");
        // RGB 3, 2, 1 bg
        s.nextSlice("\x1b[48;2;3;2;1m");
        s.nextSlice("=");

        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &t);

        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
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
        var t = try terminal.Terminal.init(io, alloc, .{ .cols = 3, .rows = 10 });
        defer t.deinit(alloc);

        var s = t.vtStream();
        defer s.deinit();
        // RGB 1, 2, 3 bg
        s.nextSlice("\x1b[48;2;1;2;3m");
        s.nextSlice(">");
        s.nextSlice("=");

        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);
        try state.update(alloc, &t);

        var shaper = &testdata.shaper;
        var it = shaper.runIterator(.{
            .grid = testdata.grid,
            .cells = state.row_data.get(0).cells.slice(),
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
    _ = try c.add(alloc, try .init(
        lib,
        testFont,
        .{ .size = .{ .points = 12 } },
    ), .{
        .style = .regular,
        .fallback = false,
        .size_adjustment = .none,
    });

    if (comptime !font.options.backend.hasCoretext()) {
        // Coretext doesn't support Noto's format
        _ = try c.add(alloc, try .init(
            lib,
            testEmoji,
            .{ .size = .{ .points = 12 } },
        ), .{
            .style = .regular,
            .fallback = false,
            .size_adjustment = .none,
        });
    } else {
        // On CoreText we want to load Apple Emoji, we should have it.
        var disco = font.Discover.init(lib);
        defer disco.deinit();
        var disco_it = try disco.discover(alloc, .{
            .family = "Apple Color Emoji",
            .size = 12,
            .monospace = false,
        });
        defer disco_it.deinit();
        var face = (try disco_it.next()).?;
        errdefer face.deinit();
        _ = try c.addDeferred(alloc, face, .{
            .style = .regular,
            .fallback = false,
            .size_adjustment = .none,
        });
    }
    _ = try c.add(alloc, try .init(
        lib,
        testEmojiText,
        .{ .size = .{ .points = 12 } },
    ), .{
        .style = .regular,
        .fallback = false,
        .size_adjustment = .none,
    });

    const grid_ptr = try alloc.create(SharedGrid);
    errdefer alloc.destroy(grid_ptr);
    grid_ptr.* = try .init(alloc, .{ .collection = c });
    errdefer grid_ptr.*.deinit(alloc);

    var shaper = try Shaper.init(alloc, .{
        // Some of our tests rely on dlig being enabled by default
        .features = &.{"dlig"},
    });
    errdefer shaper.deinit();

    return TestShaper{
        .alloc = alloc,
        .shaper = shaper,
        .grid = grid_ptr,
        .lib = lib,
    };
}

fn testShaperWithDiscoveredFont(alloc: Allocator, font_req: [:0]const u8) !TestShaper {
    if (font.Discover == void) return error.SkipZigTest;
    var lib = try Library.init(alloc);
    errdefer lib.deinit();

    var c = Collection.init();
    c.load_options = .{ .library = lib };

    // Discover and add our font to the collection.
    {
        var disco = font.Discover.init(lib);
        defer disco.deinit();
        var disco_it = try disco.discover(alloc, .{
            .family = font_req,
            .size = 12,
            .monospace = false,
        });
        defer disco_it.deinit();
        var face: font.DeferredFace = (try disco_it.next()) orelse return error.FontNotFound;
        errdefer face.deinit();

        // Check which font was discovered - skip if it doesn't match the request
        var name_buf: [256]u8 = undefined;
        const face_name = face.name(&name_buf) catch "(unknown)";
        if (std.mem.indexOf(u8, face_name, font_req) == null) {
            return error.SkipZigTest;
        }

        _ = try c.add(
            alloc,
            try face.load(lib, .{ .size = .{ .points = 12 } }),
            .{
                .style = .regular,
                .fallback = false,
                .size_adjustment = .none,
            },
        );
    }

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

/// Shape a single-run string with the Arabic test font, returning the run
/// and its shaped cells. `direction` overrides the run's direction, which
/// is how these tests exercise RTL before the run iterator produces it.
fn testShapeRtl(
    alloc: Allocator,
    testdata: *TestShaper,
    str: []const u8,
    direction: font.shape.Direction,
    t: *terminal.Terminal,
    state: *terminal.RenderState,
) !struct { run: font.shape.TextRun, cells: []const font.shape.Cell } {
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice(str);
    try state.update(alloc, t);

    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
    });

    var run = (try it.next(alloc)).?;
    run.direction = direction;
    run.level = if (direction == .rtl) 1 else 0;
    const cells = try shaper.shape(run);
    return .{ .run = run, .cells = cells };
}

test "shape rtl: visual x ascends and stays in range" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var testdata = try testShaperWithFont(alloc, .arabic);
    defer testdata.deinit();

    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 120, .rows = 30 });
    defer t.deinit(alloc);
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);

    const r = try testShapeRtl(
        alloc,
        &testdata,
        @embedFile("testdata/arabic.txt"),
        .rtl,
        &t,
        &state,
    );

    // The renderer walks visual columns and matches shaped cells against
    // them in lockstep, asserting x never moves backwards. That invariant
    // has to survive right-to-left runs, which is the whole reason the
    // cluster mapping had to be re-derived rather than just letting
    // HarfBuzz emit RTL clusters as they come.
    try testing.expect(r.cells.len > 0);
    var x: u16 = 0;
    for (r.cells) |cell| {
        try testing.expect(cell.x >= x);
        try testing.expect(cell.x < r.run.cells);
        x = cell.x;
    }
}

test "shape rtl: reorders and reshapes relative to ltr" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var testdata = try testShaperWithFont(alloc, .arabic);
    defer testdata.deinit();

    // Beh followed by meem. An asymmetric word matters here: three of the
    // same letter happens to produce the same (x, glyph) pairs either way
    // by coincidence, which would make this test pass while proving
    // nothing.
    const str = "\u{0628}\u{0645}";

    var ltr: [2]u32 = undefined;
    {
        var t = try terminal.Terminal.init(io, alloc, .{ .cols = 20, .rows = 3 });
        defer t.deinit(alloc);
        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);

        const r = try testShapeRtl(alloc, &testdata, str, .ltr, &t, &state);
        try testing.expectEqual(@as(usize, 2), r.cells.len);
        for (r.cells, 0..) |c, i| {
            try testing.expectEqual(@as(u16, @intCast(i)), c.x);
            ltr[i] = c.glyph_index;
        }
    }

    {
        var t = try terminal.Terminal.init(io, alloc, .{ .cols = 20, .rows = 3 });
        defer t.deinit(alloc);
        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);

        const r = try testShapeRtl(alloc, &testdata, str, .rtl, &t, &state);
        try testing.expectEqual(@as(usize, 2), r.cells.len);

        // Every visual position shows a different glyph than it did
        // left-to-right. Two things changed at once, and both matter:
        // the cells were reordered, so the logically first letter is now
        // rightmost, and HarfBuzz picked different contextual forms
        // because joining depends on the direction the run is shaped in.
        // Forcing Arabic to left-to-right, as the shaper did before this,
        // therefore did not merely reverse the word: it also rendered
        // every letter in the wrong joining form.
        for (r.cells, 0..) |c, i| {
            try testing.expectEqual(@as(u16, @intCast(i)), c.x);
            try testing.expect(c.glyph_index != ltr[i]);
        }
    }
}

test "shape rtl: arabic contextual joining forms" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var testdata = try testShaperWithFont(alloc, .arabic);
    defer testdata.deinit();

    // A run of three identical letters exercises all four joining forms:
    // the word gives initial, medial, and final, and the same letter
    // alone gives isolated. If direction or buffer order were wrong,
    // HarfBuzz would pick the wrong forms and these would collide.
    var joined: [3]u32 = undefined;
    {
        var t = try terminal.Terminal.init(io, alloc, .{ .cols = 20, .rows = 3 });
        defer t.deinit(alloc);
        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);

        const r = try testShapeRtl(
            alloc,
            &testdata,
            "\u{0628}\u{0628}\u{0628}",
            .rtl,
            &t,
            &state,
        );
        try testing.expectEqual(@as(usize, 3), r.cells.len);
        for (r.cells, 0..) |c, i| joined[i] = c.glyph_index;
    }

    var isolated: u32 = undefined;
    {
        var t = try terminal.Terminal.init(io, alloc, .{ .cols = 20, .rows = 3 });
        defer t.deinit(alloc);
        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);

        const r = try testShapeRtl(alloc, &testdata, "\u{0628}", .rtl, &t, &state);
        try testing.expectEqual(@as(usize, 1), r.cells.len);
        isolated = r.cells[0].glyph_index;
    }

    // All four forms must be distinct glyphs. Unjoined Arabic renders as
    // a row of isolated letters, which is legible but wrong, and is
    // exactly what a run that was split per cell would produce.
    try testing.expect(joined[0] != joined[1]);
    try testing.expect(joined[1] != joined[2]);
    try testing.expect(joined[0] != joined[2]);
    for (joined) |g| try testing.expect(g != isolated);
}

test "shape rtl: lam-alef ligature" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var testdata = try testShaperWithFont(alloc, .arabic);
    defer testdata.deinit();

    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 20, .rows = 3 });
    defer t.deinit(alloc);
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);

    // Lam followed by alef is a mandatory ligature: two codepoints, two
    // terminal cells, but a single glyph. The glyph belongs to the lam's
    // cluster, which is logically first and therefore rightmost, so it
    // lands at the higher visual offset. The other cell is left empty,
    // which is the known cell-grid limitation noted in the RFC rather
    // than a mapping bug.
    const r = try testShapeRtl(
        alloc,
        &testdata,
        "\u{0644}\u{0627}",
        .rtl,
        &t,
        &state,
    );

    try testing.expectEqual(@as(u16, 2), r.run.cells);
    try testing.expectEqual(@as(usize, 1), r.cells.len);
    try testing.expectEqual(@as(u16, 1), r.cells[0].x);
}

test "shape rtl: marks share the cell of their base" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var testdata = try testShaperWithFont(alloc, .arabic);
    defer testdata.deinit();

    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 20, .rows = 3 });
    defer t.deinit(alloc);
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);

    // Beh with fatha above it. The mark is non-spacing, so it occupies no
    // column of its own and must land on the same cell as its base.
    // HarfBuzz reverses the whole buffer for a right-to-left run, which
    // reverses the order within a cluster too, so the mark arrives before
    // its base; the cluster bookkeeping has to cope with that.
    const r = try testShapeRtl(
        alloc,
        &testdata,
        "\u{0628}\u{064E}",
        .rtl,
        &t,
        &state,
    );

    try testing.expectEqual(@as(u16, 1), r.run.cells);
    try testing.expectEqual(@as(usize, 2), r.cells.len);
    for (r.cells) |c| try testing.expectEqual(@as(u16, 0), c.x);

    // The two glyphs are different: one is the letter, one is the mark.
    try testing.expect(r.cells[0].glyph_index != r.cells[1].glyph_index);
}

test "shape rtl: zwnj breaks cursive joining" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var testdata = try testShaperWithFont(alloc, .arabic);
    defer testdata.deinit();

    // Two beh separated by a zero width non-joiner, the construction
    // Persian uses inside compound words. The letters must not join, so
    // the isolated form appears where a joined form otherwise would.
    //
    // Note this exercises less than it looks. The test font does not
    // cover U+200C, so the run iterator's font fallback replaces the
    // grapheme containing it, and the shaper never sees the ZWNJ itself.
    // What is verified is the observable outcome: no cursive joining.
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 20, .rows = 3 });
    defer t.deinit(alloc);
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);

    // The shaper reuses one cell buffer, so the result of the first call
    // has to be copied out before the second call overwrites it.
    var glyphs: [8]u32 = undefined;
    var xs: [8]u16 = undefined;
    var len: usize = 0;
    {
        const r = try testShapeRtl(
            alloc,
            &testdata,
            "\u{0628}\u{200C}\u{0628}",
            .rtl,
            &t,
            &state,
        );
        len = r.cells.len;
        for (r.cells, 0..) |c, i| {
            glyphs[i] = c.glyph_index;
            xs[i] = c.x;
            try testing.expect(c.x < r.run.cells);
        }
    }

    var isolated: u32 = undefined;
    {
        var t2 = try terminal.Terminal.init(io, alloc, .{ .cols = 20, .rows = 3 });
        defer t2.deinit(alloc);
        var state2: terminal.RenderState = .empty;
        defer state2.deinit(alloc);
        const iso = try testShapeRtl(alloc, &testdata, "\u{0628}", .rtl, &t2, &state2);
        isolated = iso.cells[0].glyph_index;
    }

    var saw_isolated = false;
    for (glyphs[0..len], xs[0..len]) |g, x| {
        _ = x;
        if (g == isolated) saw_isolated = true;
    }
    try testing.expect(saw_isolated);
}

test "shape rtl: visual map accounts for wide cells" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 20, .rows = 3 });
    defer t.deinit(alloc);
    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);

    // Two double-width characters, so the run is four columns wide but
    // only two of them start a cell. Reversing a run is not simply
    // `cells - 1 - c`: a cell occupying logical columns [c, c+w) has to
    // land on visual columns [cells-c-w, cells-c), or wide characters end
    // up shifted one column from where they belong.
    const r = try testShapeRtl(alloc, &testdata, "👍👍", .rtl, &t, &state);

    try testing.expectEqual(@as(u16, 4), r.run.cells);

    // Logical cell 0 is two columns wide, so it occupies visual columns
    // 2 and 3, and logical cell 2 occupies visual columns 0 and 1.
    const map = testdata.shaper.visual_map.items;
    try testing.expectEqual(@as(usize, 4), map.len);
    try testing.expectEqual(@as(u16, 2), map[0]);
    try testing.expectEqual(@as(u16, 0), map[2]);

    // And the emitted cells still ascend.
    var x: u16 = 0;
    for (r.cells) |cell| {
        try testing.expect(cell.x >= x);
        try testing.expect(cell.x < r.run.cells);
        x = cell.x;
    }
}

/// The cases covered by the golden vectors in `testdata/rtl_shaping.txt`.
const rtl_golden_cases = [_]struct { name: []const u8, str: []const u8 }{
    .{ .name = "arabic beh x3 (initial/medial/final)", .str = "\u{0628}\u{0628}\u{0628}" },
    .{ .name = "arabic beh isolated", .str = "\u{0628}" },
    .{ .name = "arabic beh+meem", .str = "\u{0628}\u{0645}" },
    .{ .name = "arabic lam-alef ligature", .str = "\u{0644}\u{0627}" },
    .{ .name = "arabic tatweel", .str = "\u{0628}\u{0640}\u{0645}" },
    .{ .name = "arabic fatha", .str = "\u{0628}\u{064E}" },
    .{ .name = "arabic shadda+kasra", .str = "\u{0628}\u{0651}\u{0650}" },
    // A mark on a cell other than the first. This is the only case that
    // reaches the direction-dependent "first codepoint in cluster"
    // search, because a multi-codepoint cluster at offset zero never
    // triggers a cell reset.
    .{ .name = "arabic mark on second letter", .str = "\u{0628}\u{0628}\u{064E}" },
    .{ .name = "arabic marks on both letters", .str = "\u{0628}\u{064E}\u{0628}\u{0650}" },
    .{ .name = "persian peh-cheh-jeh", .str = "\u{067E}\u{0686}\u{0698}" },
    .{ .name = "persian gaf+farsi yeh", .str = "\u{06AF}\u{06CC}" },
    .{ .name = "persian zwnj compound", .str = "\u{0645}\u{06CC}\u{200C}\u{0631}" },
};

fn rtlGoldenDump(
    alloc: Allocator,
    writer: *std.Io.Writer,
) !void {
    const io = std.testing.io;

    try writer.writeAll(
        \\# Golden shaping vectors for right-to-left runs.
        \\#
        \\# Generated from KawkabMono-Regular (src/font/res) via the
        \\# "shape rtl: golden vectors" test. Regenerate by making that
        \\# test print its dump rather than compare it.
        \\#
        \\# These lock in mark placement, which is where a regression in
        \\# the cluster-to-cell mapping shows up as text that still looks
        \\# plausible. "arabic shadda+kasra" is the most sensitive case:
        \\# three glyphs on one cell, each with its own offset.
        \\#
        \\# Glyph ids are specific to this font. Changing the font
        \\# invalidates the file.
        \\
        \\
    );

    var testdata = try testShaperWithFont(alloc, .arabic);
    defer testdata.deinit();

    for (rtl_golden_cases) |case| {
        var t = try terminal.Terminal.init(io, alloc, .{ .cols = 20, .rows = 3 });
        defer t.deinit(alloc);
        var state: terminal.RenderState = .empty;
        defer state.deinit(alloc);

        const r = try testShapeRtl(alloc, &testdata, case.str, .rtl, &t, &state);

        try writer.print("{s}\n  cells={d} glyphs={d}\n", .{
            case.name,
            r.run.cells,
            r.cells.len,
        });
        for (r.cells) |c| {
            try writer.print("  x={d} xoff={d} yoff={d} gid={d}\n", .{
                c.x,
                c.x_offset,
                c.y_offset,
                c.glyph_index,
            });
        }
    }
}

test "shape rtl: golden vectors" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Regression vectors for right-to-left shaping. The relational tests
    // above prove the behavior is right; these prove it stays that way.
    // Mark placement in particular has no cheap invariant to assert, and
    // a mispositioned tashkeel or niqqud is invisible to a reviewer who
    // does not read the script, so the exact offsets are pinned here.
    var buf: [16384]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try rtlGoldenDump(alloc, &w);

    const expected = @embedFile("testdata/rtl_shaping.txt");
    if (!std.mem.eql(u8, expected, w.buffered())) {
        std.debug.print(
            "\ngolden mismatch. actual output:\n{s}\n",
            .{w.buffered()},
        );
        return error.TestExpectedEqual;
    }
}
