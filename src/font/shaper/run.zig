const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const font = @import("../main.zig");
const shape = @import("../shape.zig");
const terminal = @import("../../terminal/main.zig");
const trace = @import("tracy").trace;

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
    row: terminal.Screen.Row,
    selection: ?terminal.Selection = null,
    i: usize = 0,

    pub fn next(self: *RunIterator, alloc: Allocator) !?TextRun {
        const tracy = trace(@src());
        defer tracy.end();

        // Trim the right side of a row that might be empty
        const max: usize = max: {
            var j: usize = self.row.lenCells();
            while (j > 0) : (j -= 1) if (!self.row.getCell(j - 1).empty()) break;
            break :max j;
        };

        // We're over at the max
        if (self.i >= max) return null;

        // Track the font for our curent run
        var current_font: font.Group.FontIndex = .{};

        // Allow the hook to prepare
        try self.hooks.prepare();

        // Go through cell by cell and accumulate while we build our run.
        var j: usize = self.i;
        while (j < max) : (j += 1) {
            const cluster = j;
            const cell = self.row.getCell(j);

            // If we have a selection and we're at a boundary point, then
            // we break the run here.
            if (self.selection) |unordered_sel| {
                if (j > self.i) {
                    const sel = unordered_sel.ordered(.forward);
                    if (sel.start.x > 0 and j == sel.start.x) break;
                    if (sel.end.x > 0 and j == sel.end.x + 1) break;
                }
            }

            // If we're a spacer, then we ignore it
            if (cell.attrs.wide_spacer_tail) continue;

            // Text runs break when font styles change so we need to get
            // the proper style.
            const style: font.Style = style: {
                if (cell.attrs.bold) {
                    if (cell.attrs.italic) break :style .bold_italic;
                    break :style .bold;
                }

                if (cell.attrs.italic) break :style .italic;
                break :style .regular;
            };

            // Determine the presentation format for this glyph.
            const presentation: ?font.Presentation = if (cell.attrs.grapheme) p: {
                // We only check the FIRST codepoint because I believe the
                // presentation format must be directly adjacent to the codepoint.
                var it = self.row.codepointIterator(j);
                if (it.next()) |cp| {
                    if (cp == 0xFE0E) break :p font.Presentation.text;
                    if (cp == 0xFE0F) break :p font.Presentation.emoji;
                }

                break :p null;
            } else null;

            // Determine the font for this cell. We'll use fallbacks
            // manually here to try replacement chars and then a space
            // for unknown glyphs.
            const font_idx_opt = (try self.group.indexForCodepoint(
                alloc,
                if (cell.empty() or cell.char == 0) ' ' else cell.char,
                style,
                presentation,
            )) orelse (try self.group.indexForCodepoint(
                alloc,
                0xFFFD,
                style,
                .text,
            )) orelse
                try self.group.indexForCodepoint(alloc, ' ', style, .text);
            const font_idx = font_idx_opt.?;
            //log.warn("char={x} idx={}", .{ cell.char, font_idx });
            if (j == self.i) current_font = font_idx;

            // If our fonts are not equal, then we're done with our run.
            if (font_idx.int() != current_font.int()) break;

            // Continue with our run
            try self.hooks.addCodepoint(cell.char, @intCast(cluster));

            // If this cell is part of a grapheme cluster, add all the grapheme
            // data points.
            if (cell.attrs.grapheme) {
                var it = self.row.codepointIterator(j);
                while (it.next()) |cp| {
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
};
