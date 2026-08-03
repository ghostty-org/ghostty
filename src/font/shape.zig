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

/// Options for runIterator.
pub const RunOptions = struct {
    /// The font state for the terminal screen. This is mutable because
    /// cached values may be updated during shaping.
    grid: *SharedGrid,

    /// The cells for the row to shape.
    cells: std.MultiArrayList(terminal.RenderState.Cell).Slice = .empty,

    /// The x boundaries of the selection in this row.
    selection: ?[2]u16 = null,

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

test {
    _ = Cache;
    _ = Shaper;

    // The run iterator had no tests before, so nothing referenced it here
    // and its test block was never collected.
    _ = run;

    // Always test noop
    _ = noop;
}
