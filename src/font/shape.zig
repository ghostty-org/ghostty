const std = @import("std");
const bidi = @import("../bidi/types.zig");
const options = @import("main.zig").options;
const run = @import("shaper/run.zig");
const feature = @import("shaper/feature.zig");
const configpkg = @import("../config.zig");
const terminal = @import("../terminal/main.zig");
const SharedGrid = @import("main.zig").SharedGrid;
pub const noop = @import("shaper/noop.zig");
pub const harfbuzz = @import("shaper/harfbuzz.zig");
pub const coretext = @import("shaper/coretext.zig");
pub const web_canvas = @import("shaper/web_canvas.zig");
pub const Cache = @import("shaper/Cache.zig");
pub const TextRun = run.TextRun;

/// The direction a text run is shaped in. This is the bidi vocabulary
/// type rather than a font-local one, because it always originates from
/// bidi resolution and re-declaring it would invite the two to drift.
pub const Direction = bidi.Direction;

/// The resolved bidi embedding level of a text run.
pub const Level = bidi.Level;
pub const RunIterator = run.RunIterator;
pub const Feature = feature.Feature;
pub const FeatureList = feature.FeatureList;
pub const default_features = feature.default_features;

/// Shaper implementation for our compile options.
pub const Shaper = switch (options.backend) {
    .freetype,
    .freetype_windows,
    .fontconfig_freetype,
    .coretext_freetype,
    .coretext_harfbuzz,
    => harfbuzz.Shaper,

    // Note that coretext_freetype cannot use the coretext
    // shaper because the coretext shaper requests CoreText
    // font faces.
    .coretext => coretext.Shaper,

    .coretext_noshape => noop.Shaper,

    .web_canvas => web_canvas.Shaper,
};

/// A cell is a single glyph within a terminal that should be rendered
/// for a shaping call. Not all terminal cells may be present; only
/// cells that have a glyph that needs to be rendered.
pub const Cell = struct {
    /// The X position of this shaper cell relative to the offset of the
    /// run. Because runs are always within a single row, it is expected
    /// that the caller can reconstruct the full position of the cell by
    /// using the known Y position of the cell and adding the X position
    /// to the run offset.
    x: u16,

    /// An additional offset to apply to the rendering.
    x_offset: i16 = 0,
    y_offset: i16 = 0,

    /// The glyph index for this cell. The font index to use alongside
    /// this cell is available in the text run. This glyph index is only
    /// valid for a given GroupCache and FontIndex that was used to create
    /// the runs.
    glyph_index: u32,
};

/// Build the logical-to-visual cell offset map for a right-to-left run.
///
/// Rule L2 of UAX #9 reverses a right-to-left run's cells, so the
/// logically first cell is displayed rightmost. `Cell.x` is a visual
/// offset relative to the run, so it needs that reversal applied.
///
/// Cells are not all one column wide, which is what makes this more than
/// a subtraction. A cell occupying logical columns [c, c+w) must occupy
/// visual columns [cells-c-w, cells-c), so the visual offset of a cell is
/// `cells - c - w` rather than `cells - 1 - c`. Widths are recovered from
/// the gaps between consecutive cluster values, since the run iterator
/// skips spacer cells and therefore leaves a gap of exactly the cell's
/// width.
///
/// `entries` is the shaper's record of the codepoints it fed the shaping
/// engine, in logical order, each with a `.cluster` field giving its
/// logical cell offset within the run. It lives here rather than in a
/// shaper because the arithmetic is about terminal cells, not about
/// HarfBuzz or CoreText, and both backends need exactly the same answer.
pub fn buildVisualMap(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u16),
    entries: anytype,
    cells: u16,
) std.mem.Allocator.Error!void {
    out.clearRetainingCapacity();
    try out.resize(alloc, cells);
    @memset(out.items, 0);

    // Cluster values are non-decreasing and equal for the codepoints of
    // one grapheme, because they are assigned in logical cell order.
    var i: usize = 0;
    while (i < entries.len) {
        const cluster = entries[i].cluster;

        var j = i + 1;
        while (j < entries.len and entries[j].cluster == cluster) j += 1;

        const next: u32 = if (j < entries.len) entries[j].cluster else cells;
        const width = next - cluster;

        // A run always covers the cells its clusters address, so this
        // cannot underflow unless the run and the shaping buffer
        // disagree about the run's extent.
        std.debug.assert(cluster + width <= cells);
        out.items[@intCast(cluster)] = @intCast(cells - cluster - width);

        i = j;
    }
}

/// Options for shapers.
pub const Options = struct {
    /// Font features to use when shaping.
    ///
    /// Note: eventually, this will move to font.Face probably as we may
    /// want to support per-face feature configuration. For now, we only
    /// support applying features globally.
    features: []const []const u8 = &.{},
};

/// The selected column ranges within a single row, in visual columns.
///
/// A selection is stored logically and is always logically contiguous,
/// but a logically contiguous range is not necessarily contiguous on
/// screen: a selection that spans a change of direction appears as
/// several separate stretches. So a row can carry more than one segment
/// and the run iterator has to break at every segment edge, or a run
/// would end up partly selected and be shaped and coloured as a unit.
pub const SelectionSegments = struct {
    pub const Segment = struct {
        start: u16,
        end: u16,
    };

    /// Almost every row has at most one segment. A row crossing several
    /// direction changes can have a few; beyond this bound the extra
    /// edges are dropped, which costs a missing run break rather than
    /// correctness, and is not reachable by any realistic selection.
    pub const max = 8;

    buf: [max]Segment = undefined,
    len: usize = 0,

    pub const empty: SelectionSegments = .{};

    /// A single segment, which is what a row without any direction
    /// change always produces.
    pub fn one(seg: Segment) SelectionSegments {
        var self: SelectionSegments = .empty;
        self.append(seg);
        return self;
    }

    pub fn append(self: *SelectionSegments, seg: Segment) void {
        if (self.len >= max) return;
        self.buf[self.len] = seg;
        self.len += 1;
    }

    pub fn slice(self: *const SelectionSegments) []const Segment {
        return self.buf[0..self.len];
    }

    /// Whether column `x` is the first column of a run that must be
    /// split off from the preceding one, because the selection starts or
    /// ends there.
    pub fn isBoundary(self: *const SelectionSegments, x: u16) bool {
        for (self.slice()) |seg| {
            if (seg.start > 0 and x == seg.start) return true;
            if (seg.end > 0 and x == seg.end + 1) return true;
        }
        return false;
    }
};

/// Options for runIterator.
pub const RunOptions = struct {
    /// The font state for the terminal screen. This is mutable because
    /// cached values may be updated during shaping.
    grid: *SharedGrid,

    /// The cells for the row to shape.
    cells: std.MultiArrayList(terminal.RenderState.Cell).Slice = .empty,

    /// The selected column ranges in this row. See `SelectionSegments`.
    selection: SelectionSegments = .empty,

    /// Visual column to logical column for this row.
    ///
    /// Empty means visual order equals logical order, which is the case
    /// whenever bidi is disabled and for any row with no right-to-left
    /// content. The run iterator then reduces exactly to walking logical
    /// columns, which is what it did before bidi existed.
    ///
    /// These are plain slices rather than the renderer's `RowBidi` so
    /// that the font package does not depend on the renderer. The caller
    /// fills them from whatever it resolved.
    v2l: []const u16 = &.{},

    /// Resolved embedding level per logical column. Empty means every
    /// column is at level zero.
    levels: []const Level = &.{},

    /// The cursor position within this row. This is used to break shaping
    /// on cursor boundaries. This can be disabled by setting this to
    /// null.
    cursor_x: ?usize = null,

    /// Apply the font break configuration to the run.
    pub fn applyBreakConfig(
        self: *RunOptions,
        config: configpkg.FontShapingBreak,
    ) void {
        if (!config.cursor) self.cursor_x = null;
    }
};

test "SelectionSegments: single segment matches the old behavior" {
    const testing = std.testing;

    // The bounds checks deliberately keep the original semantics,
    // including treating a zero start or end as "no boundary here", so
    // that a row with one selected range breaks runs exactly where it
    // used to.
    const one: SelectionSegments = .one(.{ .start = 2, .end = 5 });
    try testing.expectEqual(@as(usize, 1), one.slice().len);
    try testing.expect(one.isBoundary(2));
    try testing.expect(one.isBoundary(6));
    try testing.expect(!one.isBoundary(3));
    try testing.expect(!one.isBoundary(5));
    try testing.expect(!one.isBoundary(7));

    // A selection starting at column zero has no left boundary to break
    // on, because there is nothing before it in the row.
    const from_zero: SelectionSegments = .one(.{ .start = 0, .end = 3 });
    try testing.expect(!from_zero.isBoundary(0));
    try testing.expect(from_zero.isBoundary(4));
}

test "SelectionSegments: several segments each break runs" {
    const testing = std.testing;

    // What a logically contiguous selection looks like once it has been
    // mapped through a row that changes direction partway.
    var segs: SelectionSegments = .empty;
    segs.append(.{ .start = 1, .end = 2 });
    segs.append(.{ .start = 6, .end = 8 });

    try testing.expectEqual(@as(usize, 2), segs.slice().len);
    for ([_]u16{ 1, 3, 6, 9 }) |x| try testing.expect(segs.isBoundary(x));
    for ([_]u16{ 0, 2, 4, 5, 7, 8, 10 }) |x| try testing.expect(!segs.isBoundary(x));
}

test "SelectionSegments: empty never breaks, overflow is dropped" {
    const testing = std.testing;

    const none: SelectionSegments = .empty;
    try testing.expectEqual(@as(usize, 0), none.slice().len);
    for (0..16) |x| try testing.expect(!none.isBoundary(@intCast(x)));

    // Past the bound the extra edges are dropped rather than corrupting
    // memory. This costs a run break, not correctness, and no realistic
    // selection reaches it.
    var full: SelectionSegments = .empty;
    for (0..SelectionSegments.max + 4) |i| {
        full.append(.{ .start = @intCast(i * 2 + 1), .end = @intCast(i * 2 + 1) });
    }
    try testing.expectEqual(@as(usize, SelectionSegments.max), full.slice().len);
}

test {
    _ = Cache;
    _ = Shaper;

    // The run iterator had no tests before, so nothing referenced it here
    // and its test block was never collected.
    _ = run;

    // Always test noop
    _ = noop;
}
