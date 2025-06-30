const builtin = @import("builtin");
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
pub const RunIterator = run.RunIterator;
pub const Feature = feature.Feature;
pub const FeatureList = feature.FeatureList;
pub const default_features = feature.default_features;

/// Shaper implementation for our compile options.
pub const Shaper = switch (options.backend) {
    .freetype,
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

/// A cell is a single single within a terminal that should be rendered
/// for a shaping call. Note all terminal cells may be present; only
/// cells that have a glyph that needs to be rendered.
pub const Cell = struct {
    /// The column that this cell occupies. Since a set of shaper cells is
    /// always on the same line, only the X is stored. It is expected the
    /// caller has access to the original screen cell.
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

    /// The terminal screen to shape.
    screen: *const terminal.Screen,

    /// The row within the screen to shape. This row must exist within
    /// screen; it is not validated.
    row: terminal.Pin,

    /// The selection boundaries. This is used to break shaping on
    /// selection boundaries. This can be disabled by setting this to
    /// null.
    selection: ?terminal.Selection = null,

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

    // Always test noop
    _ = noop;
}
