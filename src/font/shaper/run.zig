const std = @import("std");
const assert = @import("../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const font = @import("../main.zig");
const shape = @import("../shape.zig");
const terminal = @import("../../terminal/main.zig");
const unicode = @import("../../unicode/main.zig");
const autoHash = std.hash.autoHash;
const Hasher = std.hash.Wyhash;

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

    /// The direction to shape this run in.
    ///
    /// Runs never span a change of direction, because rule L2 of UAX #9
    /// reverses maximal ranges of equal embedding level, which makes such
    /// a range contiguous in both logical and visual order. That is what
    /// lets a shaper treat a run as a plain logical substring plus a
    /// direction.
    direction: shape.Direction = .ltr,

    /// The resolved bidi embedding level of this run. Even levels are
    /// left-to-right and odd levels right-to-left, so this always agrees
    /// with `direction`; it is kept because later phases need the level
    /// itself, not just its parity.
    level: shape.Level = 0,

    /// Fold a run's direction and embedding level into its content hash.
    ///
    /// This is a separate, separately tested function because of one
    /// specific failure it exists to prevent. `shaper.Cache` keys purely
    /// on `hash` and never compares the underlying run, so two runs over
    /// identical codepoints shaped in opposite directions must not
    /// produce the same hash. If they did, the cache would hand one run's
    /// shaped cells to the other and the text would render backwards, but
    /// only when the cache happened to be warm. That is the kind of
    /// intermittent, ordering-dependent bug that survives to a release.
    pub fn foldDirection(
        content_hash: u64,
        direction: shape.Direction,
        level: shape.Level,
    ) u64 {
        var hasher = Hasher.init(content_hash);
        autoHash(&hasher, direction);
        autoHash(&hasher, level);
        return hasher.final();
    }
};

/// Rule L4 of UAX #9: the codepoint to actually display for `cp` at
/// embedding level `level`.
///
/// A character is depicted by a mirrored glyph when the resolved
/// direction is right-to-left and it has Bidi_Mirrored set. Parentheses
/// and brackets are the everyday case: an opening parenthesis in
/// right-to-left text must be drawn as a closing one so that the pair
/// still visually encloses what is between them.
///
/// Substituting the codepoint is the only mirroring available to us, so
/// characters that are mirrored but have no designated mirroring glyph
/// (U+2202 PARTIAL DIFFERENTIAL, for instance) are left alone and the
/// font is relied on. This matches what the property tables can express.
///
/// Sprite glyphs need no exclusion here even though the RFC calls for
/// one. No codepoint Ghostty draws itself, box drawing, blocks, braille,
/// Powerline separators, or the legacy computing symbols, is mirrored;
/// a test below asserts that and will fail if a future sprite range
/// overlaps the mirrored set.
pub fn mirroredCodepoint(cp: u32, level: shape.Level) u32 {
    // Even levels are left-to-right, where L4 does not apply.
    if (level & 1 == 0) return cp;
    if (cp > std.math.maxInt(u21)) return cp;
    return unicode.bidiMirroringGlyph(@intCast(cp)) orelse cp;
}

/// RunIterator is an iterator that yields text runs.
pub const RunIterator = struct {
    hooks: font.Shaper.RunIteratorHook,
    opts: shape.RunOptions,
    i: usize = 0,

    /// The resolved bidi embedding level of the run currently being
    /// built, set at the start of each `next` call. Rule L4 consults it
    /// to decide whether a character is displayed mirrored.
    level: shape.Level = 0,

    pub fn next(self: *RunIterator, alloc: Allocator) !?TextRun {
        const slice = &self.opts.cells;
        const cells: []const terminal.page.Cell = slice.items(.raw);
        const graphemes: []const []const u21 = slice.items(.grapheme);
        const styles: []const terminal.Style = slice.items(.style);

        // Trim the right side of a row that might be empty
        const max: usize = max: {
            for (0..cells.len) |i| {
                const rev_i = cells.len - i - 1;
                if (!cells[rev_i].isEmpty()) break :max rev_i + 1;
            }

            break :max 0;
        };

        // Invisible cells don't have any glyphs rendered,
        // so we explicitly skip them in the shaping process.
        while (self.i < max and
            (cells[self.i].hasStyling() and
                styles[self.i].flags.invisible)) self.i += 1;

        // We're over at the max
        if (self.i >= max) return null;

        // Runs are always left-to-right at level zero for now. Bidi
        // resolution is not yet wired into the run iterator, so this is
        // the only direction any run can have. It is decided here rather
        // than at the end because the codepoints emitted below depend on
        // it: rule L4 mirrors certain characters at odd levels.
        const direction: shape.Direction = .ltr;
        const level: shape.Level = 0;
        self.level = level;

        // Track the font for our current run
        var current_font: font.Collection.Index = .{};

        // Allow the hook to prepare
        self.hooks.prepare();

        // Initialize our hash for this run.
        var hasher = Hasher.init(0);

        // Let's get our style that we'll expect for the run.
        const style: terminal.Style = if (cells[self.i].hasStyling()) styles[self.i] else .{};

        // Go through cell by cell and accumulate while we build our run.
        var j: usize = self.i;
        while (j < max) : (j += 1) {
            // Use relative cluster positions (offset from run start) to make
            // the shaping cache position-independent. This ensures that runs
            // with identical content but different starting positions in the
            // row produce the same hash, enabling cache reuse.
            const cluster = j - self.i;
            const cell: *const terminal.page.Cell = &cells[j];

            // If we're at a selection boundary then we break the run
            // here, so that a run is never partly selected.
            if (j > self.i and
                self.opts.selection.isBoundary(@intCast(j))) break;

            // If we're a spacer, then we ignore it
            switch (cell.wide) {
                .narrow, .wide => {},
                .spacer_head, .spacer_tail => continue,
            }

            // If our cell attributes are changing, then we split the run.
            // This prevents a single glyph for ">=" to be rendered with
            // one color when the two components have different styling.
            if (j > self.i) style: {
                const prev_cell = cells[j - 1];

                // If the prev cell and this cell are both plain
                // codepoints then we check if they are commonly "bad"
                // ligatures and spit the run if they are.
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
                if (prev_cell.style_id == cell.style_id) break :style;

                // The style is different. We allow differing background
                // styles but any other change results in a new run.
                const c1 = comparableStyle(style);
                const c2 = comparableStyle(if (cell.hasStyling()) styles[j] else .{});
                if (!c1.eql(c2)) break;
            }

            // Text runs break when font styles change so we need to get
            // the proper style.
            const font_style: font.Style = style: {
                if (style.flags.bold) {
                    if (style.flags.italic) break :style .bold_italic;
                    break :style .bold;
                }

                if (style.flags.italic) break :style .italic;
                break :style .regular;
            };

            // Determine the presentation format for this glyph.
            const presentation: ?font.Presentation = if (cell.hasGrapheme()) p: {
                // We only check the FIRST codepoint because I believe the
                // presentation format must be directly adjacent to the codepoint.
                const cps = graphemes[j];
                assert(cps.len > 0);
                if (cps[0] == 0xFE0E) break :p .text;
                if (cps[0] == 0xFE0F) break :p .emoji;
                break :p null;
            } else emoji: {
                // If we're not a grapheme, our individual char could be
                // an emoji so we want to check if we expect emoji presentation.
                // The font grid indexForCodepoint we use below will do this
                // automatically.
                break :emoji null;
            };

            // If our cursor is on this line then we break the run around the
            // cursor. This means that any row with a cursor has at least
            // three breaks: before, exactly the cursor, and after.
            //
            // We do not break a cell that is exactly the grapheme. If there
            // are cells following that contain joiners, we allow those to
            // break. This creates an effect where hovering over an emoji
            // such as a skin-tone emoji is fine, but hovering over the
            // joiners will show the joiners allowing you to modify the
            // emoji.
            if (!cell.hasGrapheme()) {
                if (self.opts.cursor_x) |cursor_x| {
                    // Exactly: self.i is the cursor and we iterated once. This
                    // means that we started exactly at the cursor and did at
                    // exactly one iteration. Why exactly one? Because we may
                    // start at our cursor but do many if our cursor is exactly
                    // on an emoji.
                    if (self.i == cursor_x and j == self.i + 1) break;

                    // Before: up to and not including the cursor. This means
                    // that we started before the cursor (self.i < cursor_x)
                    // and j is now at the cursor meaning we haven't yet processed
                    // the cursor.
                    if (self.i < cursor_x and j == cursor_x) {
                        assert(j > 0);
                        break;
                    }

                    // After: after the cursor. We don't need to do anything
                    // special, we just let the run complete.
                }
            }

            // We need to find a font that supports this character. If
            // there are additional zero-width codepoints (to form a single
            // grapheme, i.e. combining characters), we need to find a font
            // that supports all of them.
            const font_info: struct {
                idx: font.Collection.Index,
                fallback: ?u32 = null,
            } = font_info: {
                // If we find a font that supports this entire grapheme
                // then we use that.
                if (try self.indexForCell(
                    alloc,
                    cell,
                    graphemes[j],
                    font_style,
                    presentation,
                )) |idx| break :font_info .{ .idx = idx };

                // Otherwise we need a fallback character. Prefer the
                // official replacement character.
                if (try self.opts.grid.getIndex(
                    alloc,
                    0xFFFD, // replacement char
                    font_style,
                    presentation,
                )) |idx| break :font_info .{ .idx = idx, .fallback = 0xFFFD };

                // Fallback to space
                if (try self.opts.grid.getIndex(
                    alloc,
                    ' ',
                    font_style,
                    presentation,
                )) |idx| break :font_info .{ .idx = idx, .fallback = ' ' };

                // We can't render at all. This is a bug, we should always
                // have a font that can render a space.
                unreachable;
            };

            //log.warn("char={x} info={}", .{ cell.char, font_info });
            if (j == self.i) current_font = font_info.idx;

            // If our fonts are not equal, then we're done with our run.
            if (font_info.idx != current_font) break;

            // If we're a fallback character, add that and continue; we
            // don't want to add the entire grapheme.
            if (font_info.fallback) |cp| {
                try self.addCodepoint(&hasher, cp, @intCast(cluster));
                continue;
            }

            // If we're a Kitty unicode placeholder then we add a blank.
            if (cell.codepoint() == terminal.kitty.graphics.unicode.placeholder) {
                try self.addCodepoint(&hasher, ' ', @intCast(cluster));
                continue;
            }

            // Add all the codepoints for our grapheme
            try self.addCodepoint(
                &hasher,
                if (cell.codepoint() == 0) ' ' else cell.codepoint(),
                @intCast(cluster),
            );
            if (cell.hasGrapheme()) {
                for (graphemes[j]) |cp| {
                    // Do not send presentation modifiers
                    if (cp == 0xFE0E or cp == 0xFE0F) continue;
                    try self.addCodepoint(&hasher, cp, @intCast(cluster));
                }
            }
        }

        // Finalize our buffer
        self.hooks.finalize();

        // Add our length to the hash as an additional mechanism to avoid collisions
        autoHash(&hasher, j - self.i);

        // Add our font index
        autoHash(&hasher, current_font);

        // Move our cursor. Must defer since we use self.i below.
        defer self.i = j;

        return .{
            .hash = TextRun.foldDirection(hasher.final(), direction, level),
            .offset = @intCast(self.i),
            .cells = @intCast(j - self.i),
            .grid = self.opts.grid,
            .font_index = current_font,
            .direction = direction,
            .level = level,
        };
    }

    fn addCodepoint(self: *RunIterator, hasher: anytype, cp: u32, cluster: u32) !void {
        // Rule L4. Note the font for this cell was chosen from the
        // original codepoint, not the mirrored one. In practice a font
        // covering one half of a mirrored pair covers the other, and
        // resolving the font from the original keeps run splitting
        // independent of direction.
        const display_cp = mirroredCodepoint(cp, self.level);

        // The hash covers what is actually shaped, so a mirrored run and
        // an unmirrored one over the same source text cannot collide in
        // the shaper cache.
        autoHash(hasher, display_cp);
        autoHash(hasher, cluster);
        try self.hooks.addCodepoint(display_cp, cluster);
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
};

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

test "TextRun: direction and level are folded into the hash" {
    const testing = std.testing;

    // This is the test the whole phase exists for. `shaper.Cache` looks
    // up shaped cells by `TextRun.hash` alone and never compares the run
    // itself, so a run's direction and embedding level must reach the
    // hash. If they do not, an RTL run over the same codepoints as an
    // earlier LTR run gets that run's cells straight out of the cache and
    // renders backwards.
    const base: u64 = 0x1234_5678_9ABC_DEF0;

    const ltr0 = TextRun.foldDirection(base, .ltr, 0);
    const rtl1 = TextRun.foldDirection(base, .rtl, 1);
    const ltr2 = TextRun.foldDirection(base, .ltr, 2);
    const rtl3 = TextRun.foldDirection(base, .rtl, 3);

    // Same content, opposite direction: must differ.
    try testing.expect(ltr0 != rtl1);

    // Same content and direction, different level: must also differ.
    // Levels matter beyond their parity because a level change splits a
    // run even when the direction is unchanged.
    try testing.expect(ltr0 != ltr2);
    try testing.expect(rtl1 != rtl3);

    // All four distinct.
    const all = [_]u64{ ltr0, rtl1, ltr2, rtl3 };
    for (all, 0..) |a, i| {
        for (all[i + 1 ..]) |b| try testing.expect(a != b);
    }

    // And the fold must be deterministic, or the cache would miss every
    // time rather than hit wrongly.
    try testing.expectEqual(ltr0, TextRun.foldDirection(base, .ltr, 0));

    // Different content with the same direction must still differ.
    try testing.expect(ltr0 != TextRun.foldDirection(base +% 1, .ltr, 0));
}

test "TextRun: adding direction and level did not change the layout class" {
    const testing = std.testing;

    // The run is copied around per frame and lives in a cache keyed by
    // hash. Growing it, or worse changing its alignment, would be a
    // silent per-frame cost. Both new fields fit in existing padding.
    try testing.expectEqual(@as(usize, 8), @alignOf(TextRun));
    try testing.expect(@sizeOf(TextRun) <= 24);

    // The defaults keep the phase inert: anything that builds a run
    // without mentioning bidi gets exactly the previous behavior.
    const r: TextRun = .{
        .hash = 0,
        .offset = 0,
        .cells = 0,
        .grid = undefined,
        .font_index = .{},
    };
    try testing.expectEqual(shape.Direction.ltr, r.direction);
    try testing.expectEqual(@as(shape.Level, 0), r.level);
}

test "mirroredCodepoint: applies only at odd levels" {
    const testing = std.testing;

    // Rule L4 applies at right-to-left (odd) levels only.
    try testing.expectEqual(@as(u32, ')'), mirroredCodepoint('(', 1));
    try testing.expectEqual(@as(u32, '('), mirroredCodepoint(')', 1));
    try testing.expectEqual(@as(u32, '>'), mirroredCodepoint('<', 1));
    try testing.expectEqual(@as(u32, ']'), mirroredCodepoint('[', 1));
    try testing.expectEqual(@as(u32, '}'), mirroredCodepoint('{', 1));

    // Higher odd levels mirror too; higher even levels do not.
    try testing.expectEqual(@as(u32, ')'), mirroredCodepoint('(', 3));
    try testing.expectEqual(@as(u32, ')'), mirroredCodepoint('(', 125));
    try testing.expectEqual(@as(u32, '('), mirroredCodepoint('(', 0));
    try testing.expectEqual(@as(u32, '('), mirroredCodepoint('(', 2));
    try testing.expectEqual(@as(u32, '('), mirroredCodepoint('(', 124));
}

test "mirroredCodepoint: leaves unmirrored characters alone" {
    const testing = std.testing;

    for ([_]u32{ 'a', 'Z', '0', ' ', '.', 0x05D0, 0x0627, 0x4E00, 0x1F600 }) |cp| {
        try testing.expectEqual(cp, mirroredCodepoint(cp, 0));
        try testing.expectEqual(cp, mirroredCodepoint(cp, 1));
    }

    // Mirrored but with no designated mirroring glyph. Bidi_Mirrored is a
    // strict superset of Bidi_Mirroring_Glyph, and a codepoint
    // substitution cannot express the difference, so these pass through.
    try testing.expect(unicode.isBidiMirrored(0x2202));
    try testing.expectEqual(@as(u32, 0x2202), mirroredCodepoint(0x2202, 1));

    // Out of Unicode range values are returned untouched rather than
    // being fed to the table lookup.
    try testing.expectEqual(
        @as(u32, std.math.maxInt(u32)),
        mirroredCodepoint(std.math.maxInt(u32), 1),
    );
}

test "mirroredCodepoint: is an involution at odd levels" {
    const testing = std.testing;

    // Mirroring twice returns the original. If this failed, text that
    // crossed a direction boundary twice would not round trip.
    for (0..std.math.maxInt(u21) + 1) |i| {
        const cp: u32 = @intCast(i);
        const m = mirroredCodepoint(cp, 1);
        if (m == cp) continue;
        try testing.expectEqual(cp, mirroredCodepoint(m, 1));
    }
}

test "mirroredCodepoint: no sprite glyph is ever mirrored" {
    const testing = std.testing;

    // The RFC calls for excluding the glyphs Ghostty draws itself, box
    // drawing, blocks, braille, Powerline separators and the legacy
    // computing symbols, from mirroring. No such exclusion exists in
    // `mirroredCodepoint`, because none is needed: not one of those
    // codepoints has Bidi_Mirrored set.
    //
    // That is a fact about the Unicode data rather than about this code,
    // so it is asserted rather than assumed. Adding a sprite range that
    // overlaps the mirrored set will fail here, which is the point.
    const face: font.SpriteFace = .{ .metrics = undefined };

    var checked: usize = 0;
    for (0..std.math.maxInt(u21) + 1) |i| {
        const cp: u32 = @intCast(i);
        if (mirroredCodepoint(cp, 1) == cp) continue;
        checked += 1;

        if (face.hasCodepoint(cp, null)) {
            std.log.warn(
                "codepoint U+{X} is both mirrored and drawn as a sprite",
                .{cp},
            );
            try testing.expect(false);
        }
    }

    // Guard against the loop above silently checking nothing.
    try testing.expect(checked > 400);
}
