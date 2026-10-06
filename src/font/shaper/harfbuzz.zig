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

    /// Scratch space for glyph advances when laying out RTL runs.
    rtl_advances: std.ArrayList(i32) = .empty,

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
        self.rtl_advances.deinit(self.alloc);
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

        // The width of a grid cell, used for aligning RTL ligatures.
        const cell_width: i32 = @intCast(run.grid.metrics.cell_width);

        // If our buffer is empty, we short-circuit the rest of the work
        // return nothing.
        if (self.hb_buf.getLength() == 0) return self.cell_buf.items[0..0];
        const info = self.hb_buf.getGlyphInfos();
        const pos = self.hb_buf.getGlyphPositions() orelse return error.HarfbuzzFailed;

        // This is perhaps not true somewhere, but we currently assume it is true.
        // If it isn't true, I'd like to catch it and learn more.
        assert(info.len == pos.len);

        // This keeps track of the current x and y offsets (sum of advances)
        // and the furthest cluster we've seen so far (max).
        var run_offset: RunOffset = .{};

        // This keeps track of the cell starting x and cluster.
        var cell_offset: CellOffset = .{};

        // RTL runs are laid out separately, see shapeRtl.
        if (self.hb_buf.getDirection() == .rtl) {
            return try self.shapeRtl(run, info, pos, cell_width);
        }

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
                const is_after_glyph_from_current_or_next_clusters =
                    cluster <= run_offset.cluster;

                const is_first_codepoint_in_cluster = blk: {
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
                .x = @intCast(cell_offset.cluster),
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
            run_offset.cluster = @max(run_offset.cluster, cluster);

            // const i = self.cell_buf.items.len - 1;
            // log.warn("i={} info={} pos={} cell={}", .{ i, info_v, pos_v, self.cell_buf.items[i] });
        }
        //log.warn("----------------", .{});

        return self.cell_buf.items;
    }

    /// Convert the shaped glyphs of an RTL run into cells.
    ///
    /// RTL runs have their codepoints in logical order but their clusters
    /// are visual positions (see RunIterator), so HarfBuzz's visual-order
    /// output has (mostly) increasing clusters.
    ///
    /// Unlike LTR runs, we don't snap each cluster to its grid cell.
    /// Connected scripts such as Arabic rely on glyphs being placed exactly
    /// where the font positions them so that letters join, and fonts use
    /// tricks that don't map 1:1 to cells: a lam-alef may be a zero-width
    /// alef piece drawn over the lam's cell, or a wide final letter may be
    /// preceded by an empty spacer glyph. So we lay out the glyphs using
    /// their pen positions, as the font intends, and right-align the run
    /// within its cells since RTL text starts on the right. Each glyph is
    /// still attributed to the cell of its cluster for coloring.
    fn shapeRtl(
        self: *Shaper,
        run: font.shape.TextRun,
        info: []const harfbuzz.GlyphInfo,
        pos: []const harfbuzz.GlyphPosition,
        cell_width: i32,
    ) ![]const font.shape.Cell {
        // Under both FreeType and CoreText the harfbuzz scale is
        // in 26.6 fixed point units, so we round to the nearest
        // whole value.
        const round = struct {
            fn round(v: i32) i32 {
                return (v + 0b100_000) >> 6;
            }
        }.round;

        self.cell_buf.clearRetainingCapacity();

        // The advance of each glyph.
        try self.rtl_advances.resize(self.alloc, pos.len);
        const advances = self.rtl_advances.items;
        for (pos, advances) |p, *adv| adv.* = round(p.x_advance);

        // Some fonts draw a glyph wider than its cell by preceding it with
        // an empty spacer glyph in the same cluster (i.e. Cascadia Code
        // draws a final beh as a swash that extends into the cell to its
        // left). This makes the run wider than its cells, so we cap the
        // advance of each cluster to the width of its cells by shifting
        // the whole cluster left by the excess. The cluster keeps its
        // internal layout (marks stay on their base) and still joins with
        // the glyph to its right, and overlaps the cell to its left, which
        // is how it is designed. We store the shift (as a negative value)
        // in place of the advance of the glyph before the cluster, or as
        // the initial pen position for the first cluster.
        var initial_shift: i32 = 0;
        {
            var i: usize = 0;
            while (i < info.len) {
                const cluster = self.codepoints.items[info[i].cluster].cluster;
                var end = i;
                var sum: i32 = 0;
                while (end < info.len and
                    self.codepoints.items[info[end].cluster].cluster == cluster) : (end += 1)
                {
                    sum += advances[end];
                }

                // The width of the cluster is the distance to the next
                // cluster in the run (wide characters span two cells).
                const next: u32 = next: {
                    var next: u32 = run.cells;
                    for (self.codepoints.items) |cp| {
                        if (cp.cluster > cluster) next = @min(next, cp.cluster);
                    }
                    break :next next;
                };
                const allowed: i32 = @as(i32, @intCast(next -| cluster)) * cell_width;

                const excess = sum - allowed;
                if (excess > 0) {
                    if (i == 0) initial_shift -= excess else advances[i - 1] -= excess;
                }

                i = end;
            }
        }

        // The total advance of the run, used to right-align it.
        var total: i32 = initial_shift;
        for (advances) |adv| total += adv;

        var pen_x: i32 = @as(i32, run.cells) * cell_width - total + initial_shift;
        var pen_y: i32 = 0;

        // The cell the glyph is attributed to. X values must never
        // decrease, so glyphs that come visually after a glyph from a
        // later cell (i.e. marks) stay attributed to that later cell.
        var cell: u32 = 0;

        for (info, pos, advances) |info_v, pos_v, advance| {
            const cluster = self.codepoints.items[info_v.cluster].cluster;
            cell = @max(cell, cluster);

            const cell_x: i32 = @as(i32, @intCast(cell)) * cell_width;
            try self.cell_buf.append(self.alloc, .{
                .x = @intCast(cell),
                .x_offset = @intCast(pen_x - cell_x + round(pos_v.x_offset)),
                .y_offset = @intCast(pen_y + round(pos_v.y_offset)),
                .glyph_index = info_v.codepoint,
            });

            pen_x += advance;
            pen_y += round(pos_v.y_advance);
        }

        return self.cell_buf.items;
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

            // Runs are LTR by default. Bidi reordering happens before
            // shaping (cells are given to us in visual order) so the run
            // iterator explicitly sets RTL for right-to-left runs. We never
            // let HarfBuzz guess the direction because our renderers assume
            // a strictly increasing X value.
            self.shaper.hb_buf.setDirection(.ltr);
        }

        /// Set the direction of the current run. For RTL runs, the
        /// codepoints are added in logical order but their clusters are
        /// their visual positions, so the shaped output (which HarfBuzz
        /// produces in visual order) still has increasing X values.
        pub fn setDirection(self: RunIteratorHook, dir: enum { ltr, rtl }) void {
            self.shaper.hb_buf.setDirection(switch (dir) {
                .ltr => .ltr,
                .rtl => .rtl,
            });
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

// Our renderers assume that cells are in strict LTR order. Without
// bidi levels (i.e. bidi disabled), RTL text must be forced to LTR
// for rendering. This test ensures that we are correctly forcing RTL
// text to be LTR in that case.
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

// When bidi reordering is enabled, the renderer gives us cells in
// visual order along with their embedding levels. RTL runs must be
// shaped in logical order (so Arabic letters join correctly) but
// produce cells in visual order with strictly increasing x.
test "shape arabic RTL run with bidi levels" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var testdata = try testShaperWithFont(alloc, .arabic);
    defer testdata.deinit();
    var shaper = &testdata.shaper;

    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 1 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();

    // The logical text is "بيت" (beh, yeh, teh). We provide it in visual
    // order (reversed) with RTL levels, as the renderer would.
    s.nextSlice("تيب");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    const levels = [_]u8{1} ** 10;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
        .bidi_levels = &levels,
    });
    const run = (try it.next(alloc)).?;
    try testing.expectEqual(@as(u16, 3), run.cells);
    const cells = try shaper.shape(run);
    try testing.expectEqual(@as(usize, 3), cells.len);

    // Cells must be in visual order with strictly increasing x, and the
    // letters must be joined in logical order: teh final on the left,
    // yeh medial, and beh initial on the right. These glyph IDs are from
    // KawkabMono-Regular.
    const expected = [_]u32{
        876, // uniFE96 teh final
        1047, // uniFEF4 yeh medial
        870, // uniFE91 beh initial
    };
    for (cells, 0..) |cell, i| {
        try testing.expectEqual(@as(u16, @intCast(i)), cell.x);
        try testing.expectEqual(expected[i], cell.glyph_index);
    }
    try testing.expect(try it.next(alloc) == null);
}

test "shape arabic RTL run with combining marks" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var testdata = try testShaperWithFont(alloc, .arabic);
    defer testdata.deinit();
    var shaper = &testdata.shaper;

    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 1 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();

    // Logical "بَيت" (beh + fatha, yeh, teh) in visual order. The fatha
    // is part of the beh's grapheme so it is in the rightmost cell.
    s.nextSlice("تيب\u{064E}");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    const levels = [_]u8{1} ** 10;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
        .bidi_levels = &levels,
    });
    const run = (try it.next(alloc)).?;
    try testing.expectEqual(@as(u16, 3), run.cells);
    const cells = try shaper.shape(run);
    try testing.expectEqual(@as(usize, 4), cells.len);

    // X must never decrease, and the mark must be in the last cell.
    var x: u16 = 0;
    for (cells) |cell| {
        try testing.expect(cell.x >= x);
        x = cell.x;
    }
    var last_cell_glyphs: usize = 0;
    for (cells) |cell| {
        if (cell.x == 2) last_cell_glyphs += 1;
    }
    try testing.expectEqual(@as(usize, 2), last_cell_glyphs);
}

test "shape arabic RTL run with lam-alef ligature" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var testdata = try testShaperWithFont(alloc, .arabic);
    defer testdata.deinit();
    var shaper = &testdata.shaper;

    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 1 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();

    // Logical "سلام" (seen, lam, alef, meem) in visual order. Lam and
    // alef form a single ligature glyph.
    s.nextSlice("مالس");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    const levels = [_]u8{1} ** 10;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
        .bidi_levels = &levels,
    });
    const run = (try it.next(alloc)).?;
    try testing.expectEqual(@as(u16, 4), run.cells);
    const cells = try shaper.shape(run);
    try testing.expectEqual(@as(usize, 3), cells.len);

    // The ligature in this font is a single cell wide, so the run is
    // three cells wide but occupies four. RTL runs are right-aligned so
    // the seen and ligature are in their cells (x=3 and the lam's x=2)
    // and the meem, attributed to x=0, is drawn one cell to the right
    // so that it joins the ligature. The empty space is on the left.
    const cell_width: i16 = @intCast(testdata.grid.metrics.cell_width);
    try testing.expectEqual(@as(u16, 0), cells[0].x);
    try testing.expectEqual(cell_width, cells[0].x_offset);
    try testing.expectEqual(@as(u16, 2), cells[1].x);
    try testing.expectEqual(@as(i16, 0), cells[1].x_offset);
    try testing.expectEqual(@as(u16, 3), cells[2].x);
    try testing.expectEqual(@as(i16, 0), cells[2].x_offset);
}

test "shape bidi rows produce monotonic cells" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    const BidiReorder = @import("../../renderer/bidi.zig");

    var testdata = try testShaperWithFont(alloc, .arabic);
    defer testdata.deinit();
    var shaper = &testdata.shaper;

    const lines = [_][]const u8{
        "مشتری ان",
        "یی ییی ی کی گی",
        "پچژگک ببب ههه ععع غغغ",
        "لا لأ لإ لآ سلام الله",
        "می\u{200C}خواهم نمی\u{200C}دانم",
        "بَیتُ الْكِتابِ",
        "کـــتاب ۱۲۳۴ ١٢٣٤",
        "«سلام»، چطوری؟ خوبم؛",
        "ئ ؤ إ أ آ ة ى ي",
        "فارسی English عربی",
        "> echo \"مشتری ان\"",
        "کتاب\u{200C}ها (۲۰ عدد) - قیمت: 15,000 تومان",
        "العربية: مرحبا بكم في المكتبة",
    };

    for (lines) |line| {
        for ([_]@import("../../config.zig").Config.Bidi{ .ltr, .rtl, .auto }) |mode| {
            var t = try terminal.Terminal.init(io, alloc, .{ .cols = 60, .rows = 1 });
            defer t.deinit(alloc);
            var s = t.vtStream();
            defer s.deinit();
            s.nextSlice(line);

            var state: terminal.RenderState = .empty;
            defer state.deinit(alloc);
            try state.update(alloc, &t);

            var r: BidiReorder = .{};
            defer r.deinit(alloc);
            const cells = state.row_data.get(0).cells.slice();
            const reordered = try r.reorder(alloc, mode, cells);

            var it = shaper.runIterator(.{
                .grid = testdata.grid,
                .cells = if (reordered) r.cells.slice() else cells,
                .bidi_levels = if (reordered) r.levels.items else null,
            });
            while (try it.next(alloc)) |run| {
                const shaped = try shaper.shape(run);
                var x: u16 = 0;
                for (shaped) |cell| {
                    if (cell.x < x or cell.x >= run.cells) {
                        std.log.err("non-monotonic line={s} mode={} run_offset={} cells={} x={} prev={}", .{
                            line, mode, run.offset, run.cells, cell.x, x,
                        });
                        return error.TestUnexpectedResult;
                    }
                    x = cell.x;
                }
            }
        }
    }
}

test "run iterator does not break RTL runs at the cursor" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 1 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("ABCDEF");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    const levels = [_]u8{ 0, 0, 1, 1, 1, 1, 0, 0, 0, 0 };
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
        .bidi_levels = &levels,
        .cursor_x = 3,
    });

    const expected = [_][2]u16{ .{ 0, 2 }, .{ 2, 4 } };
    var count: usize = 0;
    while (try it.next(alloc)) |run| : (count += 1) {
        try testing.expectEqual(expected[count][0], run.offset);
        try testing.expectEqual(expected[count][1], run.cells);
        _ = try shaper.shape(run);
    }
    try testing.expectEqual(@as(usize, 2), count);
}

test "run iterator breaks on bidi direction change" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 1 });
    defer t.deinit(alloc);
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("ABCDEF");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    const levels = [_]u8{ 0, 0, 1, 1, 0, 0, 0, 0, 0, 0 };
    var shaper = &testdata.shaper;
    var it = shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
        .bidi_levels = &levels,
    });

    const expected = [_][2]u16{ .{ 0, 2 }, .{ 2, 2 }, .{ 4, 2 } };
    var count: usize = 0;
    while (try it.next(alloc)) |run| : (count += 1) {
        try testing.expectEqual(expected[count][0], run.offset);
        try testing.expectEqual(expected[count][1], run.cells);
        const cells = try shaper.shape(run);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u16, 0), cells[0].x);
        try testing.expectEqual(@as(u16, 1), cells[1].x);
    }
    try testing.expectEqual(@as(usize, 3), count);
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

test "shaper selects font for entire grapheme" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var testdata = try testShaper(alloc);
    defer testdata.deinit();

    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 5, .rows = 3 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("#\u{20E3}"); // Combining enclosing keycap

    const primary = (try testdata.grid.getIndex(alloc, '#', .regular, null)).?;
    try testing.expect(testdata.grid.hasCodepoint(primary, '#', null));
    try testing.expect(!testdata.grid.hasCodepoint(primary, 0x20E3, null));

    const additional = (try testdata.grid.getIndex(alloc, 0x20E3, .regular, null)).?;
    try testing.expect(testdata.grid.hasCodepoint(additional, '#', null));
    try testing.expect(testdata.grid.hasCodepoint(additional, 0x20E3, null));

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    var it = testdata.shaper.runIterator(.{
        .grid = testdata.grid,
        .cells = state.row_data.get(0).cells.slice(),
    });
    const run = (try it.next(alloc)).?;
    try testing.expectEqual(additional, run.font_index);
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
