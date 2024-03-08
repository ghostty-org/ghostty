const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const font = @import("../main.zig");
const shape = @import("../shape.zig");
const terminal = @import("../../terminal/main.zig").new;

/// A single text run. A text run is only valid for one Shaper instance and
/// until the next run is created. A text run never goes across multiple
/// rows in a terminal, so it is guaranteed to always be one line.
pub const TextRun = struct {
    /// The offset in the row where this run started
    offset: u16,

    /// The total number of cells produced by this run.
    cells: u16,

    /// The font group that built this run.
    group: *font.GroupCache,

    /// The font index to use for the glyphs of this run.
    font_index: font.Group.FontIndex,
};

/// RunIterator is an iterator that yields text runs.
pub const RunIterator = struct {
    hooks: font.Shaper.RunIteratorHook,
    group: *font.GroupCache,
    screen: *const terminal.Screen,
    row: terminal.Pin,
    selection: ?terminal.Selection = null,
    cursor_x: ?usize = null,
    i: usize = 0,

    pub fn next(self: *RunIterator, alloc: Allocator) !?TextRun {
        const cells = self.row.cells(.all);

        // Trim the right side of a row that might be empty
        const max: usize = max: {
            for (0..cells.len) |i| {
                const rev_i = cells.len - i - 1;
                if (!cells[rev_i].isEmpty()) break :max rev_i + 1;
            }

            break :max 0;
        };

        // We're over at the max
        if (self.i >= max) return null;

        // Track the font for our current run
        var current_font: font.Group.FontIndex = .{};

        // Allow the hook to prepare
        try self.hooks.prepare();

        // Let's get our style that we'll expect for the run.
        const style = self.row.style(&cells[0]);

        // Go through cell by cell and accumulate while we build our run.
        var j: usize = self.i;
        while (j < max) : (j += 1) {
            const cluster = j;
            const cell = &cells[j];

            // If we have a selection and we're at a boundary point, then
            // we break the run here.
            if (self.selection) |unordered_sel| {
                if (j > self.i) {
                    const sel = unordered_sel.ordered(self.screen, .forward);
                    const start_x = sel.start().x;
                    const end_x = sel.end().x;

                    if (start_x > 0 and
                        j == start_x) break;

                    if (end_x > 0 and
                        j == end_x + 1) break;
                }
            }

            // If we're a spacer, then we ignore it
            switch (cell.wide) {
                .narrow, .wide => {},
                .spacer_head, .spacer_tail => continue,
            }

            // If our cell attributes are changing, then we split the run.
            // This prevents a single glyph for ">=" to be rendered with
            // one color when the two components have different styling.
            if (j > self.i) {
                const prev_cell = cells[j - 1];
                if (prev_cell.style_id != cell.style_id) break;
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
                const cps = self.row.grapheme(cell) orelse break :p null;
                assert(cps.len > 0);
                if (cps[0] == 0xFE0E) break :p .text;
                if (cps[0] == 0xFE0F) break :p .emoji;
                break :p null;
            } else emoji: {
                // If we're not a grapheme, our individual char could be
                // an emoji so we want to check if we expect emoji presentation.
                // The font group indexForCodepoint we use below will do this
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
                if (self.cursor_x) |cursor_x| {
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
                idx: font.Group.FontIndex,
                fallback: ?u32 = null,
            } = font_info: {
                // If we find a font that supports this entire grapheme
                // then we use that.
                if (try self.indexForCell(
                    alloc,
                    cell,
                    font_style,
                    presentation,
                )) |idx| break :font_info .{ .idx = idx };

                // Otherwise we need a fallback character. Prefer the
                // official replacement character.
                if (try self.group.indexForCodepoint(
                    alloc,
                    0xFFFD, // replacement char
                    font_style,
                    presentation,
                )) |idx| break :font_info .{ .idx = idx, .fallback = 0xFFFD };

                // Fallback to space
                if (try self.group.indexForCodepoint(
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
            if (font_info.idx.int() != current_font.int()) break;

            // If we're a fallback character, add that and continue; we
            // don't want to add the entire grapheme.
            if (font_info.fallback) |cp| {
                try self.hooks.addCodepoint(cp, @intCast(cluster));
                continue;
            }

            // Add all the codepoints for our grapheme
            try self.hooks.addCodepoint(
                if (cell.codepoint() == 0) ' ' else cell.codepoint(),
                @intCast(cluster),
            );
            if (cell.hasGrapheme()) {
                const cps = self.row.grapheme(cell).?;
                for (cps) |cp| {
                    // Do not send presentation modifiers
                    if (cp == 0xFE0E or cp == 0xFE0F) continue;
                    try self.hooks.addCodepoint(cp, @intCast(cluster));
                }
            }
        }

        // Finalize our buffer
        try self.hooks.finalize();

        // Move our cursor. Must defer since we use self.i below.
        defer self.i = j;

        return TextRun{
            .offset = @intCast(self.i),
            .cells = @intCast(j - self.i),
            .group = self.group,
            .font_index = current_font,
        };
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
        cell: *terminal.Cell,
        style: font.Style,
        presentation: ?font.Presentation,
    ) !?font.Group.FontIndex {
        // Get the font index for the primary codepoint.
        const primary_cp: u32 = if (cell.isEmpty() or cell.codepoint() == 0) ' ' else cell.codepoint();
        const primary = try self.group.indexForCodepoint(
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
        const cps = self.row.grapheme(cell) orelse return primary;
        var candidates = try std.ArrayList(font.Group.FontIndex).initCapacity(alloc, cps.len + 1);
        defer candidates.deinit();
        candidates.appendAssumeCapacity(primary);

        for (cps) |cp| {
            // Ignore Emoji ZWJs
            if (cp == 0xFE0E or cp == 0xFE0F or cp == 0x200D) continue;

            // Find a font that supports this codepoint. If none support this
            // then the whole grapheme can't be rendered so we return null.
            const idx = try self.group.indexForCodepoint(
                alloc,
                cp,
                style,
                presentation,
            ) orelse return null;
            candidates.appendAssumeCapacity(idx);
        }

        // We need to find a candidate that has ALL of our codepoints
        for (candidates.items) |idx| {
            if (!self.group.group.hasCodepoint(idx, primary_cp, presentation)) continue;
            for (cps) |cp| {
                // Ignore Emoji ZWJs
                if (cp == 0xFE0E or cp == 0xFE0F or cp == 0x200D) continue;
                if (!self.group.group.hasCodepoint(idx, cp, presentation)) break;
            } else {
                // If the while completed, then we have a candidate that
                // supports all of our codepoints.
                return idx;
            }
        }

        return null;
    }
};
