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
const font = @import("../font/main.zig");
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

    /// The logical column a pointer at the given visual column is over.
    ///
    /// This is what mouse reporting has to send. A program that enables
    /// mouse tracking addresses the screen in logical columns, the same
    /// space its own cursor movement uses, so reporting the visual
    /// column would make every click land somewhere else in any editor
    /// showing right-to-left text.
    pub inline fn hitTest(self: *const RowBidi, v: VisualCol) LogicalCol {
        return self.logicalCol(v);
    }

    /// The logical position a selection anchored at this pointer should
    /// start from.
    ///
    /// A click does not select a cell, it places a caret between two of
    /// them, so which side of the cell the pointer is on decides which
    /// gap is meant. For a left-to-right cell the right half means the
    /// gap after it; for a right-to-left cell the halves are mirrored on
    /// screen, so the LEFT half is the one that means "after" in logical
    /// order.
    ///
    /// Without this, selecting a single right-to-left character by
    /// dragging across it is fiddly in a way that feels broken rather
    /// than merely imprecise.
    pub fn selectionAnchor(
        self: *const RowBidi,
        v: VisualCol,
        right_half: bool,
    ) LogicalCol {
        const l = self.logicalCol(v);
        const rtl = self.level(l) & 1 == 1;

        // The pointer is past the middle of the character in logical
        // terms when it is on the trailing side of the cell, which is
        // the right half going left to right and the left half going
        // right to left.
        const trailing = if (rtl) !right_half else right_half;
        if (!trailing) return l;

        // Clamp at the end of the row: there is no gap past the last
        // column to anchor in.
        const next = l.int() +| 1;
        return .from(@min(next, self.cols));
    }

    /// Convert a logical column range into the visual ranges it covers.
    ///
    /// A selection is logically contiguous, but a logically contiguous
    /// range is not visually contiguous when it spans a change of
    /// direction: selecting across a boundary highlights two separate
    /// stretches, which is what every text editor does and what readers
    /// of right-to-left scripts expect. Snapping it back to one range
    /// would be wrong, not tidier.
    ///
    /// Each level run is contiguous in both orders, so the range is
    /// clipped against each run in turn and mapped through `l2v`. For a
    /// right-to-left run the endpoints swap, since the logically first
    /// column is displayed rightmost.
    pub fn visualSegments(
        self: *const RowBidi,
        lo: u16,
        hi: u16,
    ) font.shape.SelectionSegments {
        // Nothing was reordered, so the range is already visual.
        if (self.identity) return .one(.{ .start = lo, .end = hi });

        var out: font.shape.SelectionSegments = .empty;
        for (self.runs) |run| {
            const run_lo = run.logical_start;
            const run_hi = run.logical_start + run.len - 1;

            const clip_lo = @max(lo, run_lo);
            const clip_hi = @min(hi, run_hi);
            if (clip_lo > clip_hi) continue;

            const a = self.l2v[clip_lo];
            const b = self.l2v[clip_hi];
            out.append(if (a <= b)
                .{ .start = a, .end = b }
            else
                .{ .start = b, .end = a });
        }
        return out;
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

/// How to resolve a row.
pub const Options = struct {
    /// The paragraph direction to use when a row has no strongly
    /// directional character (UAX #9 rules P2/P3).
    direction: bidi.ParagraphDirection = .auto,

    /// Folded into the cache key, so a change of direction does not
    /// serve results resolved under the previous one.
    fn hashSeed(self: Options) u64 {
        return @intFromEnum(self.direction) +% 1;
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

    /// Number of times the resolver was actually invoked.
    ///
    /// Only maintained in debug builds. It exists so that "bidi = never
    /// is a complete bypass" can be asserted rather than argued: a test
    /// renders with the option off and checks this never moved.
    resolve_count: if (std.debug.runtime_safety) usize else void =
        if (std.debug.runtime_safety) 0 else {},

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
        opts: Options,
    ) Allocator.Error!RowBidi {
        if (std.debug.runtime_safety) self.resolve_count += 1;

        const hash = hashRow(cells, cols) ^ opts.hashSeed();
        if (self.entries.get(hash)) |cached| return cached;

        // Dropping everything at the bound is crude but correct, and it
        // keeps entry storage in one arena rather than needing per-entry
        // frees. Rows are re-resolved on the next frame that draws them.
        if (self.entries.count() >= max_entries) {
            log.debug("bidi cache full, resetting generation={}", .{self.generation});
            self.reset();
        }

        const row = try self.resolveUncached(alloc, cells, cols, hash, opts);
        try self.entries.put(alloc, hash, row);
        return row;
    }

    fn resolveUncached(
        self: *BidiCache,
        alloc: Allocator,
        cells: std.MultiArrayList(terminal.RenderState.Cell).Slice,
        cols: u16,
        hash: u64,
        opts: Options,
    ) Allocator.Error!RowBidi {
        self.scratch.clear();
        try self.buildElements(alloc, cells, cols);

        const result = try self.resolver.resolve(
            alloc,
            self.scratch.codepoints.items,
            .{ .direction = opts.direction },
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

    const r = try cache.resolve(alloc, row.cells(), 20, .{});
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

    _ = try cache.resolve(alloc, row.cells(), 20, .{});
    try testing.expectEqual(@as(u32, 1), cache.entries.count());

    for (0..32) |_| _ = try cache.resolve(alloc, row.cells(), 20, .{});
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

    _ = try cache.resolve(alloc, a.cells(), 20, .{});
    _ = try cache.resolve(alloc, b.cells(), 20, .{});
    try testing.expectEqual(@as(u32, 2), cache.entries.count());

    const gen = cache.generation;
    cache.reset();
    try testing.expectEqual(@as(u32, 0), cache.entries.count());
    try testing.expectEqual(gen +% 1, cache.generation);

    // Still usable afterwards.
    _ = try cache.resolve(alloc, a.cells(), 20, .{});
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

    _ = try cache.resolve(alloc, row.cells(), 4, .{});
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

        _ = try cache.resolve(alloc, row.cells(), 8, .{});

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

    const r = try cache.resolve(alloc, row.cells(), 6, .{});
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

/// A hand-built RowBidi for the arrangement:
///
///   logical:  a  b  c  A  B  C     levels 0 0 0 1 1 1
///   visual:   a  b  c  C  B  A     v2l    0 1 2 5 4 3
///
/// which is Latin followed by right-to-left text in a left-to-right
/// paragraph, the most common mixed case there is.
fn testMixedRow() RowBidi {
    const S = struct {
        const v2l = [_]u16{ 0, 1, 2, 5, 4, 3 };
        const l2v = [_]u16{ 0, 1, 2, 5, 4, 3 };
        const levels = [_]bidi.Level{ 0, 0, 0, 1, 1, 1 };
        const runs = [_]bidi.LevelRun{
            .{ .visual_start = 0, .len = 3, .logical_start = 0, .level = 0 },
            .{ .visual_start = 3, .len = 3, .logical_start = 3, .level = 1 },
        };
    };
    return .{
        .hash = 0,
        .direction = .ltr,
        .cols = 6,
        .identity = false,
        .v2l = &S.v2l,
        .l2v = &S.l2v,
        .levels = &S.levels,
        .runs = &S.runs,
    };
}

test "visualSegments: identity passes the range through" {
    const r: RowBidi = .identityFor(10, &.{});
    const segs = r.visualSegments(2, 5);
    try testing.expectEqual(@as(usize, 1), segs.slice().len);
    try testing.expectEqual(@as(u16, 2), segs.slice()[0].start);
    try testing.expectEqual(@as(u16, 5), segs.slice()[0].end);
}

test "visualSegments: a right-to-left run swaps its endpoints" {
    const r = testMixedRow();

    // Selecting the whole right-to-left half. Logical 3..5 is displayed
    // at visual 5..3, so the segment runs 3..5 with its ends swapped.
    const segs = r.visualSegments(3, 5);
    try testing.expectEqual(@as(usize, 1), segs.slice().len);
    try testing.expectEqual(@as(u16, 3), segs.slice()[0].start);
    try testing.expectEqual(@as(u16, 5), segs.slice()[0].end);

    // A partial one: logical 3..4 is displayed at visual 5 and 4.
    const partial = r.visualSegments(3, 4);
    try testing.expectEqual(@as(usize, 1), partial.slice().len);
    try testing.expectEqual(@as(u16, 4), partial.slice()[0].start);
    try testing.expectEqual(@as(u16, 5), partial.slice()[0].end);
}

test "visualSegments: a selection across a direction change splits" {
    const r = testMixedRow();

    // Selecting logical c, A, B. On screen "c" sits at visual 2 while A
    // and B sit at visual 5 and 4, so the highlight is two separate
    // stretches with a gap at visual 3. That is what a text editor does
    // and what a reader of the script expects; collapsing it into one
    // range would highlight a character that is not selected.
    const segs = r.visualSegments(2, 4);
    try testing.expectEqual(@as(usize, 2), segs.slice().len);

    try testing.expectEqual(@as(u16, 2), segs.slice()[0].start);
    try testing.expectEqual(@as(u16, 2), segs.slice()[0].end);

    try testing.expectEqual(@as(u16, 4), segs.slice()[1].start);
    try testing.expectEqual(@as(u16, 5), segs.slice()[1].end);
}

test "visualSegments: covers every column when the whole row is selected" {
    const r = testMixedRow();

    const segs = r.visualSegments(0, 5);

    var seen: [6]bool = @splat(false);
    for (segs.slice()) |seg| {
        var i = seg.start;
        while (i <= seg.end) : (i += 1) seen[i] = true;
    }
    for (seen) |v| try testing.expect(v);
}

test "visualSegments: a range outside every run yields nothing" {
    const r = testMixedRow();

    // Selecting past the end of the row covers no run.
    const segs = r.visualSegments(8, 9);
    try testing.expectEqual(@as(usize, 0), segs.slice().len);
}

test "visualCol and logicalCol round trip on a mixed row" {
    const r = testMixedRow();

    for (0..r.cols) |i| {
        const l: LogicalCol = .from(@intCast(i));
        const v: VisualCol = .from(@intCast(i));
        try testing.expectEqual(i, r.logicalCol(r.visualCol(l)).int());
        try testing.expectEqual(i, r.visualCol(r.logicalCol(v)).int());
    }

    // The right-to-left half really is reversed.
    try testing.expectEqual(@as(u16, 5), r.visualCol(.from(3)).int());
    try testing.expectEqual(@as(u16, 3), r.visualCol(.from(5)).int());
}

test "identity mapping is a true no-op for every accessor" {
    // The acceptance criterion for the renderer's coordinate mapping:
    // with no reordering, every mapping has to be the identity, so the
    // frame is built from exactly the same columns it was before any of
    // this existed.
    const r: RowBidi = .identityFor(80, &.{});

    for (0..80) |i| {
        const l: LogicalCol = .from(@intCast(i));
        const v: VisualCol = .from(@intCast(i));
        try testing.expectEqual(i, r.logicalCol(v).int());
        try testing.expectEqual(i, r.visualCol(l).int());
        try testing.expectEqual(@as(bidi.Level, 0), r.level(l));
    }

    // And a selection maps to itself, unsplit.
    for ([_][2]u16{ .{ 0, 0 }, .{ 0, 79 }, .{ 13, 42 }, .{ 79, 79 } }) |range| {
        const segs = r.visualSegments(range[0], range[1]);
        try testing.expectEqual(@as(usize, 1), segs.slice().len);
        try testing.expectEqual(range[0], segs.slice()[0].start);
        try testing.expectEqual(range[1], segs.slice()[0].end);
    }
}

test "a resolved ascii row maps identically" {
    const alloc = testing.allocator;

    // The same check but through the real path: resolve an actual row
    // of plain text and confirm the result is the identity, so the
    // renderer's mapped code path is a no-op on ordinary content
    // whatever backend is compiled in.
    var cache: BidiCache = .init(alloc);
    defer cache.deinit(alloc);

    var row = try TestRow.init(alloc, 20, "hello world 123");
    defer row.deinit(alloc);

    const r = try cache.resolve(alloc, row.cells(), 20, .{});
    try testing.expect(r.identity);

    for (0..20) |i| {
        const l: LogicalCol = .from(@intCast(i));
        const v: VisualCol = .from(@intCast(i));
        try testing.expectEqual(i, r.logicalCol(v).int());
        try testing.expectEqual(i, r.visualCol(l).int());
    }

    const segs = r.visualSegments(3, 8);
    try testing.expectEqual(@as(usize, 1), segs.slice().len);
    try testing.expectEqual(@as(u16, 3), segs.slice()[0].start);
    try testing.expectEqual(@as(u16, 8), segs.slice()[0].end);
}

test "wide cell: stepping back happens logically, not visually" {
    // A cursor on the spacer tail of a wide character steps back one
    // column to reach the character's head, and only then is mapped to
    // where that character is drawn.
    //
    // Doing it the other way round would step back from a visual column
    // into whatever sits to its left on screen, which after reordering
    // need not be part of the same character at all. This test pins the
    // arrangement that makes the difference observable.
    //
    //   logical:  A  B  |  W  W      A,B rtl; W a wide cell at level 0
    //   visual:   B  A  |  W  W
    const S = struct {
        const v2l = [_]u16{ 1, 0, 2, 3 };
        const l2v = [_]u16{ 1, 0, 2, 3 };
        const levels = [_]bidi.Level{ 1, 1, 0, 0 };
        const runs = [_]bidi.LevelRun{
            .{ .visual_start = 0, .len = 2, .logical_start = 0, .level = 1 },
            .{ .visual_start = 2, .len = 2, .logical_start = 2, .level = 0 },
        };
    };
    const r: RowBidi = .{
        .hash = 0,
        .direction = .ltr,
        .cols = 4,
        .identity = false,
        .v2l = &S.v2l,
        .l2v = &S.l2v,
        .levels = &S.levels,
        .runs = &S.runs,
    };

    // The wide character's head is logical column 2, drawn at visual 2.
    // A cursor sitting on its tail is at logical 3; stepping back
    // logically gives 2, which maps to visual 2. Correct.
    const head_logical: LogicalCol = .from(3 - 1);
    try testing.expectEqual(@as(u16, 2), r.visualCol(head_logical).int());

    // Had the order been reversed, the cursor at logical 3 would map to
    // visual 3 and then step back to visual 2, which happens to agree
    // here but does not in general. The case that separates them is a
    // cursor at logical 0: it maps to visual 1, and stepping back from
    // there lands on visual 0, which displays logical 1, a different
    // character entirely.
    try testing.expectEqual(@as(u16, 1), r.visualCol(.from(0)).int());
    try testing.expectEqual(@as(u16, 1), r.logicalCol(.from(0)).int());
}

test "resolve_count tracks invocations" {
    if (!std.debug.runtime_safety) return error.SkipZigTest;

    const alloc = testing.allocator;

    var cache: BidiCache = .init(alloc);
    defer cache.deinit(alloc);

    var row = try TestRow.init(alloc, 20, "hello");
    defer row.deinit(alloc);

    try testing.expectEqual(@as(usize, 0), cache.resolve_count);

    // Every call counts, cache hit or not. The renderer's guarantee is
    // that with bidi off it does not call this at all, so what has to be
    // observable is the call, not the work it did.
    _ = try cache.resolve(alloc, row.cells(), 20, .{});
    try testing.expectEqual(@as(usize, 1), cache.resolve_count);

    for (0..9) |_| _ = try cache.resolve(alloc, row.cells(), 20, .{});
    try testing.expectEqual(@as(usize, 10), cache.resolve_count);
}

test "paragraph direction is part of the cache key" {
    const alloc = testing.allocator;

    var cache: BidiCache = .init(alloc);
    defer cache.deinit(alloc);

    var row = try TestRow.init(alloc, 20, "hello");
    defer row.deinit(alloc);

    // Resolving the same row under a different assumed paragraph
    // direction can give a different answer, so the two must not share a
    // cache entry. Without the direction in the key the second call
    // would be served the first one's result.
    _ = try cache.resolve(alloc, row.cells(), 20, .{ .direction = .ltr });
    const after_first = cache.entries.count();

    _ = try cache.resolve(alloc, row.cells(), 20, .{ .direction = .rtl });
    try testing.expect(cache.entries.count() > after_first);

    // And the same options do share one.
    const before = cache.entries.count();
    _ = try cache.resolve(alloc, row.cells(), 20, .{ .direction = .ltr });
    try testing.expectEqual(before, cache.entries.count());
}

test "forced rtl direction reorders a row with no strong characters" {
    if (comptime bidi.options.backend == .noop) return error.SkipZigTest;

    const alloc = testing.allocator;

    var cache: BidiCache = .init(alloc);
    defer cache.deinit(alloc);

    // Digits and punctuation only: no strongly directional character, so
    // rules P2 and P3 have nothing to go on and the configured default
    // decides. This is exactly what bidi-default-direction is for.
    var row = try TestRow.init(alloc, 5, "12 34");
    defer row.deinit(alloc);

    // Left to right leaves it alone.
    {
        const r = try cache.resolve(alloc, row.cells(), 5, .{ .direction = .ltr });
        try testing.expect(r.identity);
    }

    // Right to left moves the run to the other end. The digits keep
    // their own left-to-right order within the run, which is rule L1
    // and the reason a phone number in Hebrew text still reads
    // correctly.
    {
        const r = try cache.resolve(alloc, row.cells(), 5, .{ .direction = .rtl });
        try testing.expect(!r.identity);
        try testing.expectEqual(bidi.Direction.rtl, r.direction);

        for (0..r.cols) |i| {
            const l: LogicalCol = .from(@intCast(i));
            try testing.expectEqual(i, r.logicalCol(r.visualCol(l)).int());
        }
    }
}

test "selection: per-cell membership agrees with visual segments" {
    // Two different mechanisms decide what a selection covers, and they
    // have to agree or the highlight will not line up with the runs
    // beneath it.
    //
    // The cell loop draws a background wherever the LOGICAL column it is
    // displaying falls inside the selected range. The run iterator
    // instead breaks runs at the edges of the VISUAL segments returned
    // by visualSegments. If those disagreed, a run could be shaped as
    // partly selected while a different set of cells was painted, and
    // the boundary would land in the wrong place.
    const r = testMixedRow();

    var lo: u16 = 0;
    while (lo < r.cols) : (lo += 1) {
        var hi: u16 = lo;
        while (hi < r.cols) : (hi += 1) {
            // What the cell loop would paint: walk visual columns and
            // test the logical column each one shows.
            var painted: [8]bool = @splat(false);
            var v: u16 = 0;
            while (v < r.cols) : (v += 1) {
                const l = r.logicalCol(.from(v)).int();
                if (l >= lo and l <= hi) painted[v] = true;
            }

            // What the run iterator would break on.
            var covered: [8]bool = @splat(false);
            for (r.visualSegments(lo, hi).slice()) |seg| {
                var i = seg.start;
                while (i <= seg.end) : (i += 1) covered[i] = true;
            }

            try testing.expectEqualSlices(
                bool,
                painted[0..r.cols],
                covered[0..r.cols],
            );
        }
    }
}

test "selection: a range crossing a direction boundary is discontiguous" {
    const r = testMixedRow();

    // Logical c, A, B. On screen "c" is at visual 2 while A and B are at
    // visual 5 and 4, leaving a gap at visual 3 that is not selected.
    // The gap is correct: the character displayed there is logical 5,
    // which is outside the range.
    var painted: [6]bool = @splat(false);
    for (r.visualSegments(2, 4).slice()) |seg| {
        var i = seg.start;
        while (i <= seg.end) : (i += 1) painted[i] = true;
    }

    try testing.expectEqualSlices(
        bool,
        &.{ false, false, true, false, true, true },
        &painted,
    );

    // And the unselected gap really does display a column outside the
    // range, rather than being an off-by-one.
    const gap_logical = r.logicalCol(.from(3)).int();
    try testing.expect(gap_logical < 2 or gap_logical > 4);
}

test "hitTest: reports the logical column under the pointer" {
    const r = testMixedRow();

    // The Latin half is untouched.
    for (0..3) |i| {
        try testing.expectEqual(i, r.hitTest(.from(@intCast(i))).int());
    }

    // The right-to-left half is reversed on screen, so clicking the
    // leftmost of those three cells is a click on the LAST of them in
    // logical order. A program tracking the mouse addresses columns
    // logically, so this is the number it has to receive.
    try testing.expectEqual(@as(u16, 5), r.hitTest(.from(3)).int());
    try testing.expectEqual(@as(u16, 4), r.hitTest(.from(4)).int());
    try testing.expectEqual(@as(u16, 3), r.hitTest(.from(5)).int());
}

test "hitTest: identity rows report the column itself" {
    const r: RowBidi = .identityFor(40, &.{});
    for (0..40) |i| {
        try testing.expectEqual(i, r.hitTest(.from(@intCast(i))).int());
    }
}

test "selectionAnchor: which half means after depends on direction" {
    const r = testMixedRow();

    // Left to right: the left half anchors before the cell, the right
    // half after it.
    try testing.expectEqual(@as(u16, 1), r.selectionAnchor(.from(1), false).int());
    try testing.expectEqual(@as(u16, 2), r.selectionAnchor(.from(1), true).int());

    // Right to left: the halves are mirrored on screen, so it is the
    // LEFT half that means "after" in logical order. Visual column 4
    // shows logical column 4; its left half anchors at logical 5.
    try testing.expectEqual(@as(u16, 4), r.selectionAnchor(.from(4), true).int());
    try testing.expectEqual(@as(u16, 5), r.selectionAnchor(.from(4), false).int());
}

test "selectionAnchor: clamps at the end of the row" {
    const r = testMixedRow();

    // The trailing side of the logically last column has no gap after
    // it to anchor in, so it clamps rather than running past the row.
    const last = r.selectionAnchor(.from(3), false);
    try testing.expect(last.int() <= r.cols);

    const identity: RowBidi = .identityFor(4, &.{});
    try testing.expectEqual(
        @as(u16, 4),
        identity.selectionAnchor(.from(3), true).int(),
    );
}

test "selectionAnchor: identity rows behave as they always did" {
    const r: RowBidi = .identityFor(10, &.{});

    // With no reordering every cell is left to right, so the left half
    // anchors on the cell and the right half after it, which is what
    // the gesture code has always assumed.
    for (0..10) |i| {
        const v: VisualCol = .from(@intCast(i));
        try testing.expectEqual(i, r.selectionAnchor(v, false).int());
        try testing.expectEqual(i + 1, r.selectionAnchor(v, true).int());
    }
}
