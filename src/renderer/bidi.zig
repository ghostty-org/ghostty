//! Per-row bidi resolution results and the cache that holds them.
//!
//! This is the layer between `src/bidi`, which knows nothing about
//! terminals, and the renderer, which thinks in grid columns. It does two
//! things: adapt a row of cells into the flat codepoint array the resolver
//! wants, and expand the resolver's per-element answer back out into
//! per-column maps.
//!
//! ## Elements are not columns
//!
//! A double-width cell occupies two columns but is one character. Feeding
//! the resolver one entry per column would let rule L2 reverse a wide
//! cell's two halves against each other, putting the spacer before the
//! head. So the resolver sees one element per *cell*, and the permutation
//! it returns is expanded back to columns afterwards, keeping the columns
//! within a cell in order.
//!
//! ## Nothing here is consumed yet
//!
//! The renderer populates this cache but still renders from logical
//! order. Wiring it into run iteration is a separate change, which means
//! the adapter and the cache lifecycle can be reviewed and measured on
//! their own.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const bidi = @import("../bidi/main.zig");
const terminal = @import("../terminal/main.zig");
const point = @import("../terminal/point.zig");

const LogicalCol = point.LogicalCol;
const VisualCol = point.VisualCol;

const log = std.log.scoped(.renderer_bidi);

/// The resolved bidi state for a single row, in grid columns.
///
/// All slices are column-indexed and `cols` long, except `runs`. They are
/// owned by the `BidiCache` that produced this value and live until that
/// cache is reset.
pub const RowBidi = struct {
    /// Content hash of the row this was resolved from.
    hash: u64,

    /// The resolved paragraph direction.
    direction: bidi.Direction,

    /// The number of columns covered.
    cols: u16,

    /// True when visual order equals logical order.
    ///
    /// The maps below are empty in that case rather than holding a
    /// trivial 0..n mapping. A row of plain left-to-right text is the
    /// overwhelmingly common case and it costs no allocation at all.
    identity: bool,

    /// Visual column to logical column. Empty when `identity`.
    v2l: []const u16,

    /// Logical column to visual column. Empty when `identity`.
    l2v: []const u16,

    /// Resolved embedding level per logical column. Empty when
    /// `identity`.
    levels: []const bidi.Level,

    /// Level runs in visual order, in columns. Always populated.
    runs: []const bidi.LevelRun,

    /// The logical column displayed at the given visual column.
    pub inline fn logicalCol(self: *const RowBidi, v: VisualCol) LogicalCol {
        const i = v.int();
        assert(i < self.cols);
        return .from(if (self.identity) i else self.v2l[i]);
    }

    /// The visual column at which the given logical column is displayed.
    pub inline fn visualCol(self: *const RowBidi, l: LogicalCol) VisualCol {
        const i = l.int();
        assert(i < self.cols);
        return .from(if (self.identity) i else self.l2v[i]);
    }

    /// The resolved embedding level of the given logical column.
    pub inline fn level(self: *const RowBidi, l: LogicalCol) bidi.Level {
        const i = l.int();
        assert(i < self.cols);
        return if (self.identity) 0 else self.levels[i];
    }

    /// An identity result for a row that needs no reordering.
    pub fn identityFor(cols: u16, runs: []const bidi.LevelRun) RowBidi {
        return .{
            .hash = 0,
            .direction = .ltr,
            .cols = cols,
            .identity = true,
            .v2l = &.{},
            .l2v = &.{},
            .levels = &.{},
            .runs = runs,
        };
    }
};

/// A cache of resolved rows, keyed by row content.
///
/// Keying on content rather than on row position means a stale entry is
/// never *wrong*, only wasteful, and that a row keeps its entry when the
/// screen scrolls. Identical rows share one entry.
pub const BidiCache = struct {
    /// Hash to resolved row.
    entries: std.AutoHashMapUnmanaged(u64, RowBidi) = .empty,

    /// Backing storage for the column maps. Freed all at once on reset
    /// rather than per entry, since entries are never removed
    /// individually.
    arena: std.heap.ArenaAllocator,

    /// Bumped on every reset. Only used for logging and tests; the map
    /// and arena are cleared outright.
    generation: u32 = 0,

    /// Scratch buffers reused across resolves so that a steady state
    /// costs no allocation beyond new cache entries.
    scratch: Scratch = .{},

    /// The bidi resolver. Owned here so its internal buffers stay warm.
    resolver: bidi.Resolver = .empty,

    /// The most entries we hold before dropping everything and starting
    /// over. A terminal screen is at most a few hundred rows and many
    /// repeat, so this is generous; the point is only to stop unbounded
    /// growth over a long session.
    pub const max_entries: u32 = 1024;

    const Scratch = struct {
        /// One codepoint per non-spacer cell, in logical order.
        codepoints: std.ArrayList(u21) = .empty,

        /// The logical column each element starts at.
        cols: std.ArrayList(u16) = .empty,

        /// The column width of each element.
        widths: std.ArrayList(u8) = .empty,

        fn deinit(self: *Scratch, alloc: Allocator) void {
            self.codepoints.deinit(alloc);
            self.cols.deinit(alloc);
            self.widths.deinit(alloc);
        }

        fn clear(self: *Scratch) void {
            self.codepoints.clearRetainingCapacity();
            self.cols.clearRetainingCapacity();
            self.widths.clearRetainingCapacity();
        }
    };

    pub fn init(alloc: Allocator) BidiCache {
        return .{ .arena = .init(alloc) };
    }

    pub fn deinit(self: *BidiCache, alloc: Allocator) void {
        self.entries.deinit(alloc);
        self.scratch.deinit(alloc);
        self.resolver.deinit(alloc);
        self.arena.deinit();
        self.* = undefined;
    }

    /// Drop every entry and release their storage.
    ///
    /// Called when something invalidates the whole cache: a resize, a
    /// font change, or a config reload that touches bidi. Entries keyed
    /// by content would survive those correctly, but the memory would
    /// not be worth keeping for rows that no longer exist.
    pub fn reset(self: *BidiCache) void {
        self.entries.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
        self.generation +%= 1;
    }

    /// Resolve a row, returning a cached entry when the content matches
    /// one already held.
    ///
    /// The returned pointer is valid until the next `reset`. It is
    /// invalidated by further `resolve` calls only if they cause the
    /// entry map to grow, so callers should not hold it across rows.
    pub fn resolve(
        self: *BidiCache,
        alloc: Allocator,
        cells: std.MultiArrayList(terminal.RenderState.Cell).Slice,
        cols: u16,
    ) Allocator.Error!RowBidi {
        const hash = hashRow(cells, cols);
        if (self.entries.get(hash)) |cached| return cached;

        // Dropping everything at the bound is crude but correct, and it
        // keeps entry storage in one arena rather than needing per-entry
        // frees. Rows are re-resolved on the next frame that draws them.
        if (self.entries.count() >= max_entries) {
            log.debug("bidi cache full, resetting generation={}", .{self.generation});
            self.reset();
        }

        const row = try self.resolveUncached(alloc, cells, cols, hash);
        try self.entries.put(alloc, hash, row);
        return row;
    }

    fn resolveUncached(
        self: *BidiCache,
        alloc: Allocator,
        cells: std.MultiArrayList(terminal.RenderState.Cell).Slice,
        cols: u16,
        hash: u64,
    ) Allocator.Error!RowBidi {
        self.scratch.clear();
        try self.buildElements(alloc, cells, cols);

        const result = try self.resolver.resolve(
            alloc,
            self.scratch.codepoints.items,
            .{},
        );

        // The common case: nothing to reorder, so nothing is stored.
        if (result.identity) {
            var row: RowBidi = .identityFor(cols, &.{});
            row.hash = hash;
            row.runs = try self.storeIdentityRun(cols);
            return row;
        }

        return try self.expand(result, cols, hash);
    }

    /// Collect one element per non-spacer cell.
    fn buildElements(
        self: *BidiCache,
        alloc: Allocator,
        cells: std.MultiArrayList(terminal.RenderState.Cell).Slice,
        cols: u16,
    ) Allocator.Error!void {
        const raw = cells.items(.raw);
        const graphemes = cells.items(.grapheme);

        var x: u16 = 0;
        while (x < cols and x < raw.len) : (x += 1) {
            const cell = raw[x];

            // A spacer belongs to the cell before it and contributes no
            // element of its own; its width is accounted for there.
            switch (cell.wide) {
                .spacer_head, .spacer_tail => continue,
                .narrow, .wide => {},
            }

            // The base codepoint decides the character's bidi class.
            // Combining marks in a grapheme are all Nonspacing_Mark and
            // would resolve to the base's level anyway, so feeding only
            // the base keeps one element per cell without changing the
            // answer.
            const cp: u21 = cp: {
                if (cell.hasGrapheme()) {
                    const cps = graphemes[x];
                    if (cps.len > 0) break :cp cell.codepoint();
                }
                if (cell.isEmpty()) break :cp ' ';
                break :cp cell.codepoint();
            };

            try self.scratch.codepoints.append(alloc, cp);
            try self.scratch.cols.append(alloc, x);
            try self.scratch.widths.append(alloc, if (cell.wide == .wide) 2 else 1);
        }

        // Widen the last element to cover any trailing spacer so the
        // widths sum to the column count.
        if (self.scratch.widths.items.len > 0) {
            const last = self.scratch.widths.items.len - 1;
            const start = self.scratch.cols.items[last];
            const covered = start + self.scratch.widths.items[last];
            if (covered < cols) {
                self.scratch.widths.items[last] = @intCast(cols - start);
            }
        }
    }

    /// Expand a per-element result into per-column maps.
    fn expand(
        self: *BidiCache,
        result: bidi.Result,
        cols: u16,
        hash: u64,
    ) Allocator.Error!RowBidi {
        const arena = self.arena.allocator();

        const v2l = try arena.alloc(u16, cols);
        const l2v = try arena.alloc(u16, cols);
        const levels = try arena.alloc(bidi.Level, cols);

        const starts = self.scratch.cols.items;
        const widths = self.scratch.widths.items;

        // Walk the elements in visual order, laying each one's columns
        // down left to right. The columns within one element keep their
        // order, which is what stops a wide cell's halves from swapping.
        var runs: std.ArrayList(bidi.LevelRun) = .empty;
        errdefer runs.deinit(arena);

        var vis: u16 = 0;
        var run_start: u16 = 0;
        var run_level: ?bidi.Level = null;
        var run_log_min: u16 = 0;

        for (0..result.len) |v| {
            const l = result.logicalIndex(v);
            const lvl = result.level(l);
            const start = starts[l];
            const width = widths[l];

            if (run_level) |cur| {
                if (cur != lvl) {
                    try runs.append(arena, .{
                        .visual_start = run_start,
                        .len = vis - run_start,
                        .logical_start = run_log_min,
                        .level = cur,
                    });
                    run_start = vis;
                    run_level = lvl;
                    run_log_min = start;
                }
            } else {
                run_level = lvl;
                run_start = vis;
                run_log_min = start;
            }
            run_log_min = @min(run_log_min, start);

            for (0..width) |k| {
                const lc: u16 = start + @as(u16, @intCast(k));
                const vc: u16 = vis + @as(u16, @intCast(k));
                assert(lc < cols);
                assert(vc < cols);
                v2l[vc] = lc;
                l2v[lc] = vc;
                levels[lc] = lvl;
            }

            vis += width;
        }

        if (run_level) |cur| try runs.append(arena, .{
            .visual_start = run_start,
            .len = vis - run_start,
            .logical_start = run_log_min,
            .level = cur,
        });

        // Any columns the elements did not cover (a row shorter than the
        // grid) map to themselves at the paragraph level.
        while (vis < cols) : (vis += 1) {
            v2l[vis] = vis;
            l2v[vis] = vis;
            levels[vis] = 0;
        }

        return .{
            .hash = hash,
            .direction = result.direction,
            .cols = cols,
            .identity = false,
            .v2l = v2l,
            .l2v = l2v,
            .levels = levels,
            .runs = try runs.toOwnedSlice(arena),
        };
    }

    fn storeIdentityRun(
        self: *BidiCache,
        cols: u16,
    ) Allocator.Error![]const bidi.LevelRun {
        if (cols == 0) return &.{};
        const arena = self.arena.allocator();
        const runs = try arena.alloc(bidi.LevelRun, 1);
        runs[0] = .{
            .visual_start = 0,
            .len = cols,
            .logical_start = 0,
            .level = 0,
        };
        return runs;
    }
};

/// Hash a row's content for cache lookup.
///
/// Only what bidi resolution actually depends on is hashed: the
/// codepoints and the cell widths. Styles are deliberately excluded, so
/// two rows with the same text in different colours share one entry.
pub fn hashRow(
    cells: std.MultiArrayList(terminal.RenderState.Cell).Slice,
    cols: u16,
) u64 {
    var hasher = std.hash.Wyhash.init(0);
    const raw = cells.items(.raw);
    const graphemes = cells.items(.grapheme);

    std.hash.autoHash(&hasher, cols);

    var x: u16 = 0;
    while (x < cols and x < raw.len) : (x += 1) {
        const cell = raw[x];
        std.hash.autoHash(&hasher, cell.wide);
        std.hash.autoHash(&hasher, cell.codepoint());
        if (cell.hasGrapheme()) {
            for (graphemes[x]) |cp| std.hash.autoHash(&hasher, cp);
        }
    }

    return hasher.final();
}

const testing = std.testing;

/// Build a RenderState for a single row of the given text.
const TestRow = struct {
    t: terminal.Terminal,
    state: terminal.RenderState,

    fn init(alloc: Allocator, cols: u16, str: []const u8) !TestRow {
        var t = try terminal.Terminal.init(testing.io, alloc, .{
            .cols = cols,
            .rows = 3,
        });
        errdefer t.deinit(alloc);

        var s = t.vtStream();
        defer s.deinit();
        s.nextSlice(str);

        var state: terminal.RenderState = .empty;
        errdefer state.deinit(alloc);
        try state.update(alloc, &t);

        return .{ .t = t, .state = state };
    }

    fn deinit(self: *TestRow, alloc: Allocator) void {
        self.state.deinit(alloc);
        self.t.deinit(alloc);
    }

    fn cells(self: *TestRow) std.MultiArrayList(terminal.RenderState.Cell).Slice {
        return self.state.row_data.get(0).cells.slice();
    }
};

test "hashRow: same text hashes the same regardless of position in time" {
    const alloc = testing.allocator;

    var a = try TestRow.init(alloc, 20, "hello");
    defer a.deinit(alloc);
    var b = try TestRow.init(alloc, 20, "hello");
    defer b.deinit(alloc);
    var c = try TestRow.init(alloc, 20, "world");
    defer c.deinit(alloc);

    try testing.expectEqual(hashRow(a.cells(), 20), hashRow(b.cells(), 20));
    try testing.expect(hashRow(a.cells(), 20) != hashRow(c.cells(), 20));
}

test "hashRow: styles do not affect the hash" {
    const alloc = testing.allocator;

    // Bidi resolution depends on codepoints and cell widths, not on
    // colour or weight, so two rows with the same text in different
    // styles must share a cache entry.
    var plain = try TestRow.init(alloc, 20, "hello");
    defer plain.deinit(alloc);
    var bold = try TestRow.init(alloc, 20, "\x1b[1;31mhello\x1b[0m");
    defer bold.deinit(alloc);

    try testing.expectEqual(hashRow(plain.cells(), 20), hashRow(bold.cells(), 20));
}

test "BidiCache: ascii resolves to identity and allocates nothing per row" {
    const alloc = testing.allocator;

    var cache: BidiCache = .init(alloc);
    defer cache.deinit(alloc);

    var row = try TestRow.init(alloc, 20, "hello world");
    defer row.deinit(alloc);

    const r = try cache.resolve(alloc, row.cells(), 20);
    try testing.expect(r.identity);
    try testing.expectEqual(@as(u16, 20), r.cols);

    // The identity case stores no column maps at all. That is the
    // property the whole design leans on: a row of plain left-to-right
    // text costs nothing but a hash.
    try testing.expectEqual(@as(usize, 0), r.v2l.len);
    try testing.expectEqual(@as(usize, 0), r.l2v.len);
    try testing.expectEqual(@as(usize, 0), r.levels.len);

    // The accessors still answer correctly.
    for (0..20) |i| {
        const l: LogicalCol = .from(@intCast(i));
        const v: VisualCol = .from(@intCast(i));
        try testing.expectEqual(i, r.logicalCol(v).int());
        try testing.expectEqual(i, r.visualCol(l).int());
        try testing.expectEqual(@as(bidi.Level, 0), r.level(l));
    }
}

test "BidiCache: repeated resolves of the same row hit the cache" {
    const alloc = testing.allocator;

    var cache: BidiCache = .init(alloc);
    defer cache.deinit(alloc);

    var row = try TestRow.init(alloc, 20, "hello");
    defer row.deinit(alloc);

    _ = try cache.resolve(alloc, row.cells(), 20);
    try testing.expectEqual(@as(u32, 1), cache.entries.count());

    for (0..32) |_| _ = try cache.resolve(alloc, row.cells(), 20);
    try testing.expectEqual(@as(u32, 1), cache.entries.count());
}

test "BidiCache: reset drops entries and bumps the generation" {
    const alloc = testing.allocator;

    var cache: BidiCache = .init(alloc);
    defer cache.deinit(alloc);

    var a = try TestRow.init(alloc, 20, "one");
    defer a.deinit(alloc);
    var b = try TestRow.init(alloc, 20, "two");
    defer b.deinit(alloc);

    _ = try cache.resolve(alloc, a.cells(), 20);
    _ = try cache.resolve(alloc, b.cells(), 20);
    try testing.expectEqual(@as(u32, 2), cache.entries.count());

    const gen = cache.generation;
    cache.reset();
    try testing.expectEqual(@as(u32, 0), cache.entries.count());
    try testing.expectEqual(gen +% 1, cache.generation);

    // Still usable afterwards.
    _ = try cache.resolve(alloc, a.cells(), 20);
    try testing.expectEqual(@as(u32, 1), cache.entries.count());
}

test "BidiCache: elements are per cell, not per column" {
    const alloc = testing.allocator;

    var cache: BidiCache = .init(alloc);
    defer cache.deinit(alloc);

    // Two double-width characters fill four columns but are two
    // characters. Feeding the resolver one element per column would let
    // rule L2 reverse a wide cell's own halves.
    var row = try TestRow.init(alloc, 4, "\u{4E00}\u{4E8C}");
    defer row.deinit(alloc);

    _ = try cache.resolve(alloc, row.cells(), 4);
    try testing.expectEqual(@as(usize, 2), cache.scratch.codepoints.items.len);
    try testing.expectEqualSlices(u16, &.{ 0, 2 }, cache.scratch.cols.items);
    try testing.expectEqualSlices(u8, &.{ 2, 2 }, cache.scratch.widths.items);
}

test "BidiCache: element widths always cover the row" {
    const alloc = testing.allocator;

    var cache: BidiCache = .init(alloc);
    defer cache.deinit(alloc);

    // Whatever the content, the element widths have to sum to the column
    // count or the expansion below would leave holes in the maps.
    inline for (.{
        "hello",
        "\u{4E00}\u{4E8C}",
        "a\u{4E00}b",
        "\u{05D0}\u{05D1}",
        "",
    }) |str| {
        var row = try TestRow.init(alloc, 8, str);
        defer row.deinit(alloc);

        _ = try cache.resolve(alloc, row.cells(), 8);

        var sum: usize = 0;
        for (cache.scratch.widths.items) |w| sum += w;
        if (cache.scratch.widths.items.len > 0) {
            try testing.expectEqual(@as(usize, 8), sum);
        }
    }
}

test "BidiCache: reordering keeps wide cells intact" {
    // Reordering only happens with a real backend. Under the default
    // noop build there is nothing to check, and skipping is honest:
    // the assertions below are meaningless without a resolver.
    if (comptime bidi.options.backend == .noop) return error.SkipZigTest;

    const alloc = testing.allocator;

    var cache: BidiCache = .init(alloc);
    defer cache.deinit(alloc);

    // Hebrew followed by a double-width ideograph, which reorders.
    var row = try TestRow.init(alloc, 6, "\u{05D0}\u{05D1}\u{4E00}");
    defer row.deinit(alloc);

    const r = try cache.resolve(alloc, row.cells(), 6);
    try testing.expect(!r.identity);

    // The two permutations must be mutual inverses over every column.
    for (0..r.cols) |i| {
        const l: LogicalCol = .from(@intCast(i));
        const v: VisualCol = .from(@intCast(i));
        try testing.expectEqual(i, r.logicalCol(r.visualCol(l)).int());
        try testing.expectEqual(i, r.visualCol(r.logicalCol(v)).int());
    }

    // The wide cell's two columns stay adjacent and in order, whatever
    // the reordering did with the cell as a whole.
    const head_logical: LogicalCol = .from(2);
    const tail_logical: LogicalCol = .from(3);
    const head_visual = r.visualCol(head_logical).int();
    const tail_visual = r.visualCol(tail_logical).int();
    try testing.expectEqual(head_visual + 1, tail_visual);

    // Level runs cover every column exactly once, in visual order.
    var covered: usize = 0;
    var expect_start: u16 = 0;
    for (r.runs) |run| {
        try testing.expectEqual(expect_start, run.visual_start);
        covered += run.len;
        expect_start += run.len;
    }
    try testing.expectEqual(@as(usize, r.cols), covered);
}
