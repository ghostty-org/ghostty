const std = @import("std");
const assert = @import("../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const font = @import("../main.zig");
const shape = @import("../shape.zig");
const terminal = @import("../../terminal/main.zig");
const itijah = @import("itijah");
const autoHash = std.hash.autoHash;
const Hasher = std.hash.Wyhash;
const VisualRun = itijah.VisualRun;

/// Classify a codepoint by bidi strength.
/// Returns null for neutrals (spaces/punctuation).
fn codepointIsRtl(cp: u32) ?bool {
    return switch (itijah.unicode.bidiClass(@intCast(cp))) {
        .right_to_left, .right_to_left_arabic => true,
        .left_to_right, .european_number, .arabic_number => false,
        else => null,
    };
}

/// A single text run. A text run is only valid for one Shaper instance and
/// until the next run is created. A text run never goes across multiple
/// rows in a terminal, so it is guaranteed to always be one line.
pub const TextRun = struct {
    /// A unique hash for this run. This can be used to cache the shaping
    /// results. We don't provide a means to compare actual values if the
    /// hash is the same, so we should continue to improve this hash to
    /// lower the chance of hash collisions if they become a problem. If
    /// there are hash collisions, it would result in rendering issues but
    /// the core data would be correct.
    ///
    /// The hash is position-independent within the row by using relative
    /// cluster positions. This allows identical runs in different positions
    /// to share the same cache entry, improving cache efficiency.
    hash: u64,

    /// The offset in the row where this run started. This is added to the
    /// X position of the final shaped cells to get the absolute position
    /// in the row where they belong.
    offset: u16,

    /// The total number of cells produced by this run.
    cells: u16,

    /// The font grid that built this run.
    grid: *font.SharedGrid,

    /// The font index to use for the glyphs of this run.
    font_index: font.Collection.Index,

    /// Whether this run is RTL according to visual runs from the bidi resolver.
    rtl: bool = false,
};

/// RunIterator is an iterator that yields text runs.
pub const RunIterator = struct {
    hooks: font.Shaper.RunIteratorHook,
    opts: shape.RunOptions,
    // Visual cursor within the trimmed row.
    i: usize = 0,
    // Cached row layout derived once per iterator.
    // visual_runs is a slice owned by the scratch buffer from bidiLayoutScratch();
    // it remains valid as long as the scratch is not reused (i.e. within a single frame).
    layout_ready: bool = false,
    max: usize = 0,
    visual_runs: []const VisualRun = &.{},

    pub fn next(self: *RunIterator, alloc: Allocator) !?TextRun {
        const slice = &self.opts.cells;
        const cells: []const terminal.page.Cell = slice.items(.raw);
        const graphemes: []const []const u21 = slice.items(.grapheme);
        const styles: []const terminal.Style = slice.items(.style);

        if (!self.layout_ready) try self.resolveRowLayout(alloc, cells);
        if (self.max == 0) return null;

        // We're over at the max.
        if (self.i >= self.max) return null;

        // Invisible cells don't have any glyphs rendered, so we skip them.
        while (self.i < self.max) {
            const vr = findVisualRun(self.visual_runs, self.i) orelse break;
            const logical_i: usize = @intCast(itijah.logicalIndexForVisual(vr, @intCast(self.i)));
            if (!(cells[logical_i].hasStyling() and styles[logical_i].flags.invisible)) break;
            self.i += 1;
        }
        if (self.i >= self.max) return null;

        while (self.i < self.max) {
            const bidi_run = findVisualRun(self.visual_runs, self.i) orelse return null;
            const bidi_run_start: usize = @intCast(bidi_run.visual_start);
            const bidi_run_end: usize = bidi_run_start + @as(usize, @intCast(bidi_run.len));
            assert(self.i >= bidi_run_start and self.i < bidi_run_end);

            // Track the font for our current run.
            var current_font: font.Collection.Index = .{};
            var have_font = false;

            const rtl = bidi_run.is_rtl;

            // Style is anchored to the first visual cell in this candidate run.
            const start_logical: usize = @intCast(itijah.logicalIndexForVisual(
                bidi_run,
                @intCast(self.i),
            ));
            const style: terminal.Style = if (cells[start_logical].hasStyling())
                styles[start_logical]
            else
                .{};
            const run_font_style = fontStyleForStyle(style);

            // Find the run boundary in visual order.
            var j: usize = self.i;
            while (j < bidi_run_end) : (j += 1) {
                const logical_j: usize = @intCast(itijah.logicalIndexForVisual(
                    bidi_run,
                    @intCast(j),
                ));
                const cell: *const terminal.page.Cell = &cells[logical_j];

                // If we have a selection and we're at a boundary point, then
                // we break the run here.
                if (self.opts.selection) |bounds| {
                    if (j > self.i) {
                        if (bounds[0] > 0 and j == bounds[0]) break;
                        if (bounds[1] > 0 and j == bounds[1] + 1) break;
                    }
                }

                // If we're a spacer, then we ignore it.
                switch (cell.wide) {
                    .narrow, .wide => {},
                    .spacer_head, .spacer_tail => continue,
                }

                // If our cell attributes are changing, then we split the run.
                // This prevents a single glyph for ">=" to be rendered with
                // one color when the two components have different styling.
                if (j > self.i) style_change: {
                    const prev_logical: usize = @intCast(itijah.logicalIndexForVisual(
                        bidi_run,
                        @intCast(j - 1),
                    ));
                    const prev_cell = cells[prev_logical];

                    // If the prev cell and this cell are both plain
                    // codepoints then we check if they are commonly "bad"
                    // ligatures and split the run if they are.
                    if (prev_cell.content_tag == .codepoint and
                        cell.content_tag == .codepoint)
                    {
                        const prev_cp = prev_cell.codepoint();
                        switch (prev_cp) {
                            // fl, fi
                            'f' => {
                                const cp = cell.codepoint();
                                if (cp == 'l' or cp == 'i') break;
                            },

                            // st
                            's' => {
                                const cp = cell.codepoint();
                                if (cp == 't') break;
                            },

                            else => {},
                        }
                    }

                    // If the style is exactly the change then fast path out.
                    if (prev_cell.style_id == cell.style_id) break :style_change;

                    // The style is different. We allow differing background
                    // styles but any other change results in a new run.
                    const c1 = comparableStyle(style);
                    const c2 = comparableStyle(if (cell.hasStyling()) styles[logical_j] else .{});
                    if (!c1.eql(c2)) break;
                }

                // Determine the presentation format for this glyph.
                const presentation = presentationForCell(cell, graphemes[logical_j]);

                // If our cursor is on this line then we break the run around
                // the cursor.
                if (!cell.hasGrapheme()) {
                    if (self.opts.cursor_x) |cursor_x| {
                        if (self.i == cursor_x and j == self.i + 1) break;
                        if (self.i < cursor_x and j == cursor_x) {
                            assert(j > 0);
                            break;
                        }
                    }
                }

                const font_info = try self.resolveFontInfo(
                    alloc,
                    cell,
                    graphemes[logical_j],
                    run_font_style,
                    presentation,
                );

                if (!have_font) {
                    current_font = font_info.idx;
                    have_font = true;
                }

                // If our fonts are not equal, then we're done with our run —
                // UNLESS the codepoint is neutral (space, punctuation) and
                // the current run's font also supports it.
                if (font_info.idx != current_font) {
                    const cp = cell.codepoint();
                    const is_neutral_in_current_font = cp != 0 and
                        codepointIsRtl(cp) == null and
                        self.opts.grid.hasCodepoint(current_font, cp, presentation);
                    if (!is_neutral_in_current_font) break;
                }
            }

            // Defensive: ensure forward progress.
            if (j == self.i) {
                self.i += 1;
                continue;
            }

            // A run with only spacer cells can occur in edge cases; skip it.
            if (!have_font) {
                self.i = j;
                continue;
            }

            const logical_range = itijah.logicalRangeForVisualSlice(
                bidi_run,
                @intCast(self.i),
                @intCast(j),
            );
            const logical_start: usize = @intCast(logical_range.start);
            const logical_end: usize = @intCast(logical_range.end);

            // Prepare the shaping backend and build the run contents in LOGICAL
            // order for shaping correctness.
            self.hooks.prepare();
            defer self.hooks.finalize();

            var hasher = Hasher.init(0);
            for (logical_start..logical_end) |logical_j| {
                const visual_idx = itijah.visualIndexForLogical(bidi_run, @intCast(logical_j));
                const cluster: u32 = visual_idx - @as(u32, @intCast(self.i));
                const cell: *const terminal.page.Cell = &cells[logical_j];

                switch (cell.wide) {
                    .narrow, .wide => {},
                    .spacer_head, .spacer_tail => continue,
                }

                const presentation = presentationForCell(cell, graphemes[logical_j]);

                const font_info = try self.resolveFontInfo(
                    alloc,
                    cell,
                    graphemes[logical_j],
                    run_font_style,
                    presentation,
                );

                if (font_info.idx != current_font) {
                    const cp = cell.codepoint();
                    const is_neutral_in_current_font = cp != 0 and
                        codepointIsRtl(cp) == null and
                        self.opts.grid.hasCodepoint(current_font, cp, presentation);
                    if (!is_neutral_in_current_font) continue;
                }

                // If we're a fallback character and that fallback is in the
                // current run font, add it directly.
                if (font_info.fallback) |cp| {
                    // Only use fallback glyph if it comes from the run font.
                    if (font_info.idx == current_font) {
                        try self.addCodepoint(&hasher, cp, cluster);
                        continue;
                    }
                }

                // If we're a Kitty unicode placeholder then we add a blank.
                if (cell.codepoint() == terminal.kitty.graphics.unicode.placeholder) {
                    try self.addCodepoint(&hasher, ' ', cluster);
                    continue;
                }

                // Add all the codepoints for our grapheme.
                try self.addCodepoint(
                    &hasher,
                    if (cell.codepoint() == 0) ' ' else cell.codepoint(),
                    cluster,
                );
                if (cell.hasGrapheme()) {
                    for (graphemes[logical_j]) |cp| {
                        // Do not send presentation modifiers.
                        if (cp == 0xFE0E or cp == 0xFE0F) continue;
                        try self.addCodepoint(&hasher, cp, cluster);
                    }
                }
            }

            // Add our length to the hash as an additional mechanism to avoid collisions.
            autoHash(&hasher, j - self.i);
            autoHash(&hasher, current_font);
            autoHash(&hasher, rtl);

            const run_offset = self.i;
            self.i = j;

            return .{
                .hash = hasher.final(),
                .offset = @intCast(run_offset),
                .cells = @intCast(j - run_offset),
                .grid = self.opts.grid,
                .font_index = current_font,
                .rtl = rtl,
            };
        }

        return null;
    }

    fn resolveRowLayout(
        self: *RunIterator,
        alloc: Allocator,
        cells: []const terminal.page.Cell,
    ) !void {
        self.layout_ready = true;
        self.max = max: {
            for (0..cells.len) |i| {
                const rev_i = cells.len - i - 1;
                if (!cells[rev_i].isEmpty()) break :max rev_i + 1;
            }
            break :max 0;
        };

        if (self.max == 0) {
            self.visual_runs = &.{};
            return;
        }

        // Build bidi inputs from logical cells and derive visual runs in a
        // paragraph that is always anchored LTR (terminal line model).
        var bidi_codepoints = try alloc.alloc(u21, self.max);
        defer alloc.free(bidi_codepoints);
        for (cells[0..self.max], 0..) |cell, i| {
            bidi_codepoints[i] = bidiCodepoint(cell);
        }

        const layout = try itijah.resolveVisualLayoutScratch(
            alloc,
            self.hooks.bidiLayoutScratch(),
            bidi_codepoints,
            .{ .base_dir = .ltr },
        );
        self.visual_runs = layout.runs;
    }

    fn addCodepoint(self: *RunIterator, hasher: anytype, cp: u32, cluster: u32) !void {
        autoHash(hasher, cp);
        autoHash(hasher, cluster);
        try self.hooks.addCodepoint(cp, cluster);
    }

    /// Find a font index that supports the grapheme for the given cell,
    /// or null if no such font exists.
    ///
    /// This is used to find a font that supports the entire grapheme.
    /// We look for fonts that support each individual codepoint and then
    /// find the common font amongst all candidates.
    fn indexForCell(
        self: *RunIterator,
        alloc: Allocator,
        cell: *const terminal.Cell,
        graphemes: []const u21,
        style: font.Style,
        presentation: ?font.Presentation,
    ) !?font.Collection.Index {
        if (cell.isEmpty() or
            cell.codepoint() == 0 or
            cell.codepoint() == terminal.kitty.graphics.unicode.placeholder)
        {
            return try self.opts.grid.getIndex(
                alloc,
                ' ',
                style,
                presentation,
            );
        }

        // Get the font index for the primary codepoint.
        const primary_cp: u32 = cell.codepoint();
        const primary = try self.opts.grid.getIndex(
            alloc,
            primary_cp,
            style,
            presentation,
        ) orelse return null;

        // Easy, and common: we aren't a multi-codepoint grapheme, so
        // we just return whatever index for the cell codepoint.
        if (!cell.hasGrapheme()) return primary;

        // If this is a grapheme, we need to find a font that supports
        // all of the codepoints in the grapheme.
        var candidates: std.ArrayList(font.Collection.Index) = try .initCapacity(
            alloc,
            graphemes.len + 1,
        );
        defer candidates.deinit(alloc);
        candidates.appendAssumeCapacity(primary);

        for (graphemes) |cp| {
            // Ignore Emoji ZWJs
            if (cp == 0xFE0E or cp == 0xFE0F or cp == 0x200D) continue;

            // Find a font that supports this codepoint. If none support this
            // then the whole grapheme can't be rendered so we return null.
            //
            // We explicitly do not require the additional grapheme components
            // to support the base presentation, since it is common for emoji
            // fonts to support the base emoji with emoji presentation but not
            // certain ZWJ-combined characters like the male and female signs.
            const idx = try self.opts.grid.getIndex(
                alloc,
                cp,
                style,
                null,
            ) orelse return null;
            candidates.appendAssumeCapacity(idx);
        }

        // We need to find a candidate that has ALL of our codepoints
        for (candidates.items) |idx| {
            if (!self.opts.grid.hasCodepoint(idx, primary_cp, presentation)) continue;
            for (graphemes) |cp| {
                // Ignore Emoji ZWJs
                if (cp == 0xFE0E or cp == 0xFE0F or cp == 0x200D) continue;
                if (!self.opts.grid.hasCodepoint(idx, cp, null)) break;
            } else {
                // If the while completed, then we have a candidate that
                // supports all of our codepoints.
                return idx;
            }
        }

        return null;
    }

    const FontInfo = struct {
        idx: font.Collection.Index,
        fallback: ?u32 = null,
    };

    /// Resolve which font to use for a cell, falling back to the replacement
    /// character or space if the cell's glyph is unavailable.
    fn resolveFontInfo(
        self: *RunIterator,
        alloc: Allocator,
        cell: *const terminal.Cell,
        graphemes: []const u21,
        style: font.Style,
        presentation: ?font.Presentation,
    ) !FontInfo {
        if (try self.indexForCell(alloc, cell, graphemes, style, presentation)) |idx|
            return .{ .idx = idx };

        // Prefer the official replacement character.
        if (try self.opts.grid.getIndex(alloc, 0xFFFD, style, presentation)) |idx|
            return .{ .idx = idx, .fallback = 0xFFFD };

        // Fallback to space.
        if (try self.opts.grid.getIndex(alloc, ' ', style, presentation)) |idx|
            return .{ .idx = idx, .fallback = ' ' };

        // We can't render at all. This is a bug, we should always
        // have a font that can render a space.
        unreachable;
    }
};

fn bidiCodepoint(cell: terminal.page.Cell) u21 {
    const cp = cell.codepoint();
    return @intCast(if (cp == 0) ' ' else cp);
}

fn fontStyleForStyle(style: terminal.Style) font.Style {
    if (style.flags.bold and style.flags.italic) return .bold_italic;
    if (style.flags.bold) return .bold;
    if (style.flags.italic) return .italic;
    return .regular;
}

fn presentationForCell(cell: *const terminal.page.Cell, grapheme: []const u21) ?font.Presentation {
    if (!cell.hasGrapheme() or grapheme.len == 0) return null;

    // Presentation modifiers apply only when directly adjacent to the base.
    return switch (grapheme[0]) {
        0xFE0E => .text,
        0xFE0F => .emoji,
        else => null,
    };
}

fn findVisualRun(visual_runs: []const VisualRun, visual_index: usize) ?VisualRun {
    for (visual_runs) |run| {
        const start: usize = @intCast(run.visual_start);
        const end: usize = @intCast(run.visualEnd());
        if (visual_index >= start and visual_index < end) return run;
    }

    return null;
}

/// Returns a style that when compared must be identical for a run to
/// continue.
fn comparableStyle(style: terminal.Style) terminal.Style {
    var s = style;

    // We allow background colors to differ because we'll just paint the
    // cell background whatever the style is, and wherever the glyph
    // lands on top of it will be the color of the glyph.
    s.bg_color = .none;

    return s;
}
