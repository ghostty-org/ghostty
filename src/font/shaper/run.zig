const std = @import("std");
const assert = @import("../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const font = @import("../main.zig");
const shape = @import("../shape.zig");
const terminal = @import("../../terminal/main.zig");
const itijah = @import("itijah");
const uucode = @import("uucode");
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
    // visual_runs is a slice owned by the shaper's Scratch;
    // it remains valid as long as the scratch is not reused (i.e. within a single frame).
    layout_ready: bool = false,
    visual_runs: []const VisualRun = &.{},

    /// The end of the cells to shape. Trailing blank cells are skipped even
    /// with a background color, since the renderer draws backgrounds itself.
    max: usize,

    pub fn init(
        hooks: font.Shaper.RunIteratorHook,
        opts: shape.RunOptions,
    ) RunIterator {
        const cells = opts.cells.items(.raw);
        var max = cells.len;
        // A spacer head is only ever in the last column and has nothing to
        // shape, but isBlank keeps it because isEmpty counts it as content.
        if (max > 0 and cells[max - 1].wide == .spacer_head) max -= 1;
        while (max > 0 and cells[max - 1].isBlank()) max -= 1;
        return .{ .hooks = hooks, .opts = opts, .max = max };
    }

    /// Buffers the shaper keeps for the iterator and reuses across rows.
    pub const Scratch = struct {
        layout: itijah.VisualLayoutScratch = .{},
        fonts: std.ArrayList(FontInfo) = .empty,
        ltr_run: [1]VisualRun = undefined,
        runs: std.ArrayList(VisualRun) = .empty,
        codepoints: std.ArrayList(u21) = .empty,

        pub fn deinit(self: *Scratch, alloc: Allocator) void {
            self.layout.deinit(alloc);
            self.fonts.deinit(alloc);
            self.runs.deinit(alloc);
            self.codepoints.deinit(alloc);
        }
    };

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

            const resolved_fonts = &self.hooks.scratch().fonts;
            try resolved_fonts.resize(alloc, self.max);

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
                    if (!rtl and j > self.i) {
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
                // Inside an RTL run the cursor column is logical, and splitting
                // there would break Arabic-script joining, so we don't.
                if (!rtl and !cell.hasGrapheme()) {
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
                resolved_fonts.items[j] = font_info;

                if (!have_font) {
                    current_font = font_info.idx;
                    have_font = true;
                }

                // If our fonts are not equal, then we're done with our run —
                // UNLESS the codepoint is neutral (space, punctuation) and
                // the current run's font also supports it.
                if (font_info.idx != current_font) {
                    const cp = cell.codepoint();
                    const is_neutral_in_current_font = rtl and cp != 0 and
                        codepointIsRtl(cp) == null and
                        self.opts.grid.hasCodepoint(current_font, cp, presentation);
                    if (!is_neutral_in_current_font) {
                        // Reversed, a wide cell's spacer tail sits on its
                        // left; start the next run there so the glyph keeps
                        // both of its cells.
                        if (rtl and cell.wide == .wide and j - 1 > self.i and
                            cells[@intCast(itijah.logicalIndexForVisual(bidi_run, @intCast(j - 1)))].wide == .spacer_tail)
                        {
                            j -= 1;
                        }
                        break;
                    }
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
                const cell: *const terminal.page.Cell = &cells[logical_j];
                // Reversed, a wide cell's spacer tail lands on its left, so
                // the glyph starts there and covers both cells.
                const cluster: u32 = visual_idx - @as(u32, @intCast(self.i)) -
                    @intFromBool(rtl and cell.wide == .wide and visual_idx > self.i);

                switch (cell.wide) {
                    .narrow, .wide => {},
                    .spacer_head, .spacer_tail => continue,
                }

                const presentation = presentationForCell(cell, graphemes[logical_j]);
                const font_info = resolved_fonts.items[visual_idx];

                if (font_info.idx != current_font) {
                    const cp = cell.codepoint();
                    const is_neutral_in_current_font = rtl and cp != 0 and
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

        if (self.max == 0) {
            self.visual_runs = &.{};
            return;
        }

        const scratch = self.hooks.scratch();
        if (!needsBidi(cells[0..self.max])) {
            scratch.ltr_run = .{.{
                .visual_start = 0,
                .logical_start = 0,
                .len = @intCast(self.max),
                .is_rtl = false,
            }};
            self.visual_runs = &scratch.ltr_run;
            return;
        }

        // Build bidi inputs from logical cells. Each stretch between vertical
        // borders (tmux/vim splits, TUI tables) is its own paragraph, so RTL
        // text never swaps across a border.
        scratch.codepoints.clearRetainingCapacity();
        try scratch.codepoints.ensureTotalCapacity(alloc, self.max);
        for (cells[0..self.max]) |cell| scratch.codepoints.appendAssumeCapacity(bidiCodepoint(cell));
        const codepoints = scratch.codepoints.items;

        scratch.runs.clearRetainingCapacity();
        var start: usize = 0;
        while (start < self.max) {
            var end = start;
            while (end < self.max and !isSegmentBorder(codepoints[end])) end += 1;

            // Spaces at a segment's edges stay put, next to their border.
            var a = start;
            while (a < end and codepoints[a] == ' ') a += 1;
            var b = end;
            while (b > a and codepoints[b - 1] == ' ') b -= 1;
            if (a > start) try appendIdentityRun(alloc, scratch, start, a);
            if (b > a) try self.appendSegmentRuns(alloc, codepoints[a..b], a);
            if (end > b) try appendIdentityRun(alloc, scratch, b, end);
            if (end < self.max) try scratch.runs.append(alloc, .{
                .visual_start = @intCast(end),
                .logical_start = @intCast(end),
                .len = 1,
                .is_rtl = false,
            });
            start = end + 1;
        }
        self.visual_runs = scratch.runs.items;
    }

    fn appendIdentityRun(alloc: Allocator, scratch: *Scratch, start: usize, end: usize) !void {
        try scratch.runs.append(alloc, .{
            .visual_start = @intCast(start),
            .logical_start = @intCast(start),
            .len = @intCast(end - start),
            .is_rtl = false,
        });
    }

    fn appendSegmentRuns(
        self: *RunIterator,
        alloc: Allocator,
        codepoints: []const u21,
        offset: usize,
    ) !void {
        const scratch = self.hooks.scratch();
        const layout = try itijah.resolveVisualLayoutScratch(
            alloc,
            &scratch.layout,
            codepoints,
            .{
                .base_dir = switch (self.opts.bidi_direction) {
                    // Take the direction from the first strong letter (UAX #9
                    // P2), so a Farsi sentence keeps its trailing punctuation at
                    // its end; text with no strong letter stays LTR.
                    .auto => .auto_ltr,
                    .ltr => .ltr,
                },
            },
        );
        try scratch.runs.ensureUnusedCapacity(alloc, layout.runs.len);
        for (layout.runs) |run| {
            var r = run;
            r.visual_start += @intCast(offset);
            r.logical_start += @intCast(offset);
            scratch.runs.appendAssumeCapacity(r);
        }
    }

    /// Logical column drawn at visual column `visual`.
    pub fn logicalIndex(self: *const RunIterator, visual: usize) usize {
        const vr = findVisualRun(self.visual_runs, visual) orelse return visual;
        return @intCast(itijah.logicalIndexForVisual(vr, @intCast(visual)));
    }

    /// Visual column where logical column `logical` is drawn.
    pub fn visualIndex(self: *RunIterator, alloc: Allocator, logical: usize) !usize {
        if (!self.layout_ready) try self.resolveRowLayout(alloc, self.opts.cells.items(.raw));
        for (self.visual_runs) |run| {
            if (logical >= run.logical_start and logical < run.logicalEnd())
                return @intCast(itijah.visualIndexForLogical(run, @intCast(logical)));
        }
        return logical;
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
    ///
    /// Emoji presentation implied by a skin tone modifier is only a
    /// preference: if no font supports it, we search again without one.
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

        // Try the primary font followed by the font selected for each
        // additional codepoint until one supports the entire grapheme.
        var search_presentation = presentation;
        var search_primary = primary;
        search: while (true) {
            candidate: for (0..graphemes.len + 1) |i| {
                const idx = if (i == 0) search_primary else idx: {
                    const cp = graphemes[i - 1];

                    // Ignore Emoji ZWJs
                    if (cp == 0xFE0E or cp == 0xFE0F or cp == 0x200D or cp == 0x200C) continue :candidate;

                    // We explicitly do not require the additional grapheme components
                    // to support the base presentation, since it is common for emoji
                    // fonts to support the base emoji with emoji presentation but not
                    // certain ZWJ-combined characters like the male and female signs.
                    break :idx try self.opts.grid.getIndex(
                        alloc,
                        cp,
                        style,
                        null,
                    ) orelse return null;
                };

                if (!self.opts.grid.hasCodepoint(idx, primary_cp, search_presentation)) continue;
                for (graphemes) |cp| {
                    // Ignore Emoji ZWJs
                    if (cp == 0xFE0E or cp == 0xFE0F or cp == 0x200D or cp == 0x200C) continue;
                    if (!self.opts.grid.hasCodepoint(idx, cp, null)) continue :candidate;
                }
                return idx;
            }

            // Retry a modifier's implied emoji presentation with no
            // preference. This is a loop, not a second call, so that
            // indexForCell stays inlined into next.
            if (search_presentation != .emoji or graphemes[0] == 0xFE0F) return null;
            search_presentation = null;
            search_primary = try self.opts.grid.getIndex(
                alloc,
                primary_cp,
                style,
                null,
            ) orelse return null;
            continue :search;
        }
    }

    pub const FontInfo = struct {
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

/// The bidi classes that can lift a cell above level 0 in an LTR paragraph
/// (strong RTL, Arabic numbers, explicit embeddings, overrides and
/// isolates) never occur below the Hebrew block.
const first_rtl_capable_codepoint = 0x0590;

fn needsBidi(cells: []const terminal.page.Cell) bool {
    for (cells) |cell| {
        const cp = bidiCodepoint(cell);
        if (cp < first_rtl_capable_codepoint) continue;
        switch (uucode.get(.bidi_class, cp)) {
            .right_to_left,
            .right_to_left_arabic,
            .arabic_number,
            .left_to_right_embedding,
            .right_to_left_embedding,
            .left_to_right_override,
            .right_to_left_override,
            .left_to_right_isolate,
            .right_to_left_isolate,
            .first_strong_isolate,
            => return true,
            else => {},
        }
    }
    return false;
}

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
        // A skin tone modifier implies emoji presentation for its
        // base (UTS #51, section 2.4).
        0x1F3FB...0x1F3FF => .emoji,
        else => null,
    };
}

/// Box-drawing verticals that split a row into panes or table columns.
fn isSegmentBorder(cp: u21) bool {
    return switch (cp) {
        0x2502, 0x2503, 0x2506, 0x2507, 0x250A, 0x250B, 0x2551, 0x23B8, 0x23B9 => true,
        else => false,
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

fn testCells(comptime str: []const u8) [std.unicode.utf8CountCodepoints(str) catch unreachable]terminal.page.Cell {
    @setEvalBranchQuota(10_000);
    var cells: [std.unicode.utf8CountCodepoints(str) catch unreachable]terminal.page.Cell = undefined;
    var it = (std.unicode.Utf8View.init(str) catch unreachable).iterator();
    var i: usize = 0;
    while (it.nextCodepoint()) |cp| : (i += 1) cells[i] = .init(cp);
    return cells;
}

test "needsBidi agrees with UAX #9 for rows without RTL content" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var scratch: itijah.VisualLayoutScratch = .{};
    defer scratch.deinit(alloc);

    // Rows that reach past U+0590 without any RTL content must still
    // resolve to a single LTR run covering the whole row.
    inline for (.{
        "plain ASCII: git log --oneline -5",
        "╭─ box drawing ─╮ │ ✻ Claude Code │",
        "漢字かなカナ 한국어 français ẞ",
        "emoji 🌍👍🏽 and symbols ← → ✓ ★",
    }) |str| {
        const cells = testCells(str);
        try testing.expect(!needsBidi(&cells));

        var cps: [cells.len]u21 = undefined;
        for (cells, &cps) |cell, *cp| cp.* = bidiCodepoint(cell);
        const layout = try itijah.resolveVisualLayoutScratch(alloc, &scratch, &cps, .{ .base_dir = .ltr });
        try testing.expectEqual(@as(usize, 1), layout.runs.len);
        try testing.expect(!layout.runs[0].is_rtl);
        try testing.expectEqual(@as(u32, cells.len), layout.runs[0].len);
    }
}

test "needsBidi detects RTL content" {
    const testing = std.testing;

    inline for (.{
        "Persian: سلام دنیا",
        "Hebrew: שלום",
        "Arabic-Indic digits: ١٢٣",
        "RLI isolate: \u{2067}x\u{2069}",
        "RLM mark: a\u{200F}b",
    }) |str| {
        const cells = testCells(str);
        try testing.expect(needsBidi(&cells));
    }

    // Persian digits are European numbers (EN), so alone they stay LTR.
    const digits = testCells("order ۱۴۰۵");
    try testing.expect(!needsBidi(&digits));
}

test "run iterator: row erased with background" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 5, .rows = 3 });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b[48;2;255;0;0m\x1b[2K");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // The hooks and grid are only used once there is something to shape.
    const it: RunIterator = .init(undefined, .{
        .grid = undefined,
        .cells = state.row_data.get(0).cells.slice(),
    });
    try testing.expectEqual(0, it.max);
}

test "run iterator: row erased with background before a spacer head" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 5, .rows = 3 });
    defer t.deinit(alloc);

    // Erase the row with a background, then print a wide character in the
    // last column so it wraps and leaves a spacer head behind.
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice("\x1b[48;2;255;0;0m\x1b[2K\x1b[1;5H橋");

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    const cells = state.row_data.get(0).cells.slice();
    try testing.expectEqual(.spacer_head, cells.items(.raw)[4].wide);

    const it: RunIterator = .init(undefined, .{
        .grid = undefined,
        .cells = cells,
    });
    try testing.expectEqual(0, it.max);
}
