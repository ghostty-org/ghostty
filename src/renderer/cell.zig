const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const ziglyph = @import("ziglyph");
const font = @import("../font/main.zig");
const terminal = @import("../terminal/main.zig");
const renderer = @import("../renderer.zig");
const shaderpkg = renderer.Renderer.API.shaders;
const ArrayListCollection = @import("../datastruct/array_list_collection.zig").ArrayListCollection;

/// The possible cell content keys that exist.
pub const Key = enum {
    bg,
    text,
    underline,
    strikethrough,
    overline,

    /// Returns the GPU vertex type for this key.
    pub fn CellType(self: Key) type {
        return switch (self) {
            .bg => shaderpkg.CellBg,

            .text,
            .underline,
            .strikethrough,
            .overline,
            => shaderpkg.CellText,
        };
    }
};

/// The contents of all the cells in the terminal.
///
/// The goal of this data structure is to allow for efficient row-wise
/// clearing of data from the GPU buffers, to allow for row-wise dirty
/// tracking to eliminate the overhead of rebuilding the GPU buffers
/// each frame.
///
/// Must be initialized by resizing before calling any operations.
pub const Contents = struct {
    size: renderer.GridSize = .{ .rows = 0, .columns = 0 },

    /// Flat array containing cell background colors for the terminal grid.
    ///
    /// Indexed as `bg_cells[row * size.columns + col]`.
    ///
    /// Prefer accessing with `Contents.bgCell(row, col).*` instead
    /// of directly indexing in order to avoid integer size bugs.
    bg_cells: []shaderpkg.CellBg = undefined,

    /// The ArrayListCollection which holds all of the foreground cells. When
    /// sized with Contents.resize the individual ArrayLists are given enough
    /// room that they can hold a single row with #cols glyphs, underlines, and
    /// strikethroughs; however, appendAssumeCapacity MUST NOT be used since
    /// it is possible to exceed this with combining glyphs that add a glyph
    /// but take up no column since they combine with the previous one, as
    /// well as with fonts that perform multi-substitutions for glyphs, which
    /// can result in a similar situation where multiple glyphs reside in the
    /// same column.
    ///
    /// Allocations should nevertheless be exceedingly rare since hitting the
    /// initial capacity of a list would require a row filled with underlined
    /// struck through characters, at least one of which is a multi-glyph
    /// composite.
    ///
    /// Rows are indexed as Contents.fg_rows[y + 1], because the first list in
    /// the collection is reserved for the cursor, which must be the first item
    /// in the buffer.
    ///
    /// Must be initialized by calling resize on the Contents struct before
    /// calling any operations.
    fg_rows: ArrayListCollection(shaderpkg.CellText) = .{ .lists = &.{} },

    pub fn deinit(self: *Contents, alloc: Allocator) void {
        alloc.free(self.bg_cells);
        self.fg_rows.deinit(alloc);
    }

    /// Resize the cell contents for the given grid size. This will
    /// always invalidate the entire cell contents.
    pub fn resize(
        self: *Contents,
        alloc: Allocator,
        size: renderer.GridSize,
    ) Allocator.Error!void {
        self.size = size;

        const cell_count = @as(usize, size.columns) * @as(usize, size.rows);

        const bg_cells = try alloc.alloc(shaderpkg.CellBg, cell_count);
        errdefer alloc.free(bg_cells);

        @memset(bg_cells, .{ 0, 0, 0, 0 });

        // The foreground lists can hold 3 types of items:
        // - Glyphs
        // - Underlines
        // - Strikethroughs
        // So we give them an initial capacity of size.columns * 3, which will
        // avoid any further allocations in the vast majority of cases. Sadly
        // we can not assume capacity though, since with combining glyphs that
        // form a single grapheme, and multi-substitutions in fonts, the number
        // of glyphs in a row is theoretically unlimited.
        //
        // We have size.rows + 1 lists because index 0 is used for a special
        // list containing the cursor cell which needs to be first in the buffer.
        var fg_rows = try ArrayListCollection(shaderpkg.CellText).init(
            alloc,
            size.rows + 1,
            size.columns * 3,
        );
        errdefer fg_rows.deinit(alloc);

        alloc.free(self.bg_cells);
        self.fg_rows.deinit(alloc);

        self.bg_cells = bg_cells;
        self.fg_rows = fg_rows;

        // We don't need 3*cols worth of cells for the cursor list, so we can
        // replace it with a smaller list. This is technically a tiny bit of
        // extra work but resize is not a hot function so it's worth it to not
        // waste the memory.
        self.fg_rows.lists[0].deinit(alloc);
        self.fg_rows.lists[0] = try std.ArrayListUnmanaged(
            shaderpkg.CellText,
        ).initCapacity(alloc, 1);
    }

    /// Reset the cell contents to an empty state without resizing.
    pub fn reset(self: *Contents) void {
        @memset(self.bg_cells, .{ 0, 0, 0, 0 });
        self.fg_rows.reset();
    }

    /// Set the cursor value. If the value is null then the cursor is hidden.
    pub fn setCursor(self: *Contents, v: ?shaderpkg.CellText) void {
        self.fg_rows.lists[0].clearRetainingCapacity();

        if (v) |cell| {
            self.fg_rows.lists[0].appendAssumeCapacity(cell);
        }
    }

    /// Access a background cell. Prefer this function over direct indexing
    /// of `bg_cells` in order to avoid integer size bugs causing overflows.
    pub inline fn bgCell(
        self: *Contents,
        row: usize,
        col: usize,
    ) *shaderpkg.CellBg {
        return &self.bg_cells[row * self.size.columns + col];
    }

    /// Add a cell to the appropriate list. Adding the same cell twice will
    /// result in duplication in the vertex buffer. The caller should clear
    /// the corresponding row with Contents.clear to remove old cells first.
    pub fn add(
        self: *Contents,
        alloc: Allocator,
        comptime key: Key,
        cell: key.CellType(),
    ) Allocator.Error!void {
        const y = cell.grid_pos[1];

        assert(y < self.size.rows);

        switch (key) {
            .bg => comptime unreachable,

            .text,
            .underline,
            .strikethrough,
            .overline,
            // We have a special list containing the cursor cell at the start
            // of our fg row collection, so we need to add 1 to the y to get
            // the correct index.
            => try self.fg_rows.lists[y + 1].append(alloc, cell),
        }
    }

    /// Clear all of the cell contents for a given row.
    pub fn clear(self: *Contents, y: terminal.size.CellCountInt) void {
        assert(y < self.size.rows);

        @memset(self.bg_cells[@as(usize, y) * self.size.columns ..][0..self.size.columns], .{ 0, 0, 0, 0 });

        // We have a special list containing the cursor cell at the start
        // of our fg row collection, so we need to add 1 to the y to get
        // the correct index.
        self.fg_rows.lists[y + 1].clearRetainingCapacity();
    }
};

/// Returns true if a codepoint for a cell is a covering character. A covering
/// character is a character that covers the entire cell. This is used to
/// make window-padding-color=extend work better. See #2099.
pub fn isCovering(cp: u21) bool {
    return switch (cp) {
        // U+2588 FULL BLOCK
        0x2588 => true,

        else => false,
    };
}

pub const FgMode = enum {
    /// Normal non-colored text rendering. The text can leave the cell
    /// size if it is larger than the cell to allow for ligatures.
    normal,

    /// Colored text rendering, specifically Emoji.
    color,

    /// Similar to normal but the text must be constrained to the cell
    /// size. If a glyph is larger than the cell then it must be resized
    /// to fit.
    constrained,

    /// Similar to normal, but the text consists of Powerline glyphs and is
    /// optionally exempt from padding color extension and minimum contrast requirements.
    powerline,
};

/// Returns the appropriate foreground mode for the given cell. This is
/// meant to be called from the typical updateCell function within a
/// renderer.
pub fn fgMode(
    presentation: font.Presentation,
    cell_pin: terminal.Pin,
) FgMode {
    return switch (presentation) {
        // Emoji is always full size and color.
        .emoji => .color,

        // If it is text it is slightly more complex. If we are a codepoint
        // in the private use area and we are at the end or the next cell
        // is not empty, we need to constrain rendering.
        //
        // We do this specifically so that Nerd Fonts can render their
        // icons without overlapping with subsequent characters. But if
        // the subsequent character is empty, then we allow it to use
        // the full glyph size. See #1071.
        .text => text: {
            const cell = cell_pin.rowAndCell().cell;
            const cp = cell.codepoint();

            if (!ziglyph.general_category.isPrivateUse(cp) and
                !ziglyph.blocks.isDingbats(cp))
            {
                break :text .normal;
            }

            // Special-case Powerline glyphs. They exhibit box drawing behavior
            // and should not be constrained. They have their own special category
            // though because they're used for other logic (i.e. disabling
            // min contrast).
            if (isPowerline(cp)) {
                break :text .powerline;
            }

            // If we are at the end of the screen its definitely constrained
            if (cell_pin.x == cell_pin.node.data.size.cols - 1) break :text .constrained;

            // If we have a previous cell and it was PUA then we need to
            // also constrain. This is so that multiple PUA glyphs align.
            // As an exception, we ignore powerline glyphs since they are
            // used for box drawing and we consider them whitespace.
            if (cell_pin.x > 0) prev: {
                const prev_cp = prev_cp: {
                    var copy = cell_pin;
                    copy.x -= 1;
                    const prev_cell = copy.rowAndCell().cell;
                    break :prev_cp prev_cell.codepoint();
                };

                // Powerline is whitespace
                if (isPowerline(prev_cp)) break :prev;

                if (ziglyph.general_category.isPrivateUse(prev_cp)) {
                    break :text .constrained;
                }
            }

            // If the next cell is empty, then we allow it to use the
            // full glyph size.
            const next_cp = next_cp: {
                var copy = cell_pin;
                copy.x += 1;
                const next_cell = copy.rowAndCell().cell;
                break :next_cp next_cell.codepoint();
            };
            if (next_cp == 0 or
                isSpace(next_cp) or
                isPowerline(next_cp))
            {
                break :text .normal;
            }

            // Must be constrained
            break :text .constrained;
        },
    };
}

// Some general spaces, others intentionally kept
// to force the font to render as a fixed width.
fn isSpace(char: u21) bool {
    return switch (char) {
        0x0020, // SPACE
        0x2002, // EN SPACE
        => true,
        else => false,
    };
}

// Returns true if the codepoint is a part of the Powerline range.
fn isPowerline(char: u21) bool {
    return switch (char) {
        0xE0B0...0xE0C8, 0xE0CA, 0xE0CC...0xE0D2, 0xE0D4 => true,
        else => false,
    };
}

test Contents {
    const testing = std.testing;
    const alloc = testing.allocator;

    const rows = 10;
    const cols = 10;

    var c: Contents = .{};
    try c.resize(alloc, .{ .rows = rows, .columns = cols });
    defer c.deinit(alloc);

    // We should start off empty after resizing.
    for (0..rows) |y| {
        try testing.expect(c.fg_rows.lists[y + 1].items.len == 0);
        for (0..cols) |x| {
            try testing.expectEqual(.{ 0, 0, 0, 0 }, c.bgCell(y, x).*);
        }
    }
    // And the cursor row should have a capacity of 1 and also be empty.
    try testing.expect(c.fg_rows.lists[0].capacity == 1);
    try testing.expect(c.fg_rows.lists[0].items.len == 0);

    // Add some contents.
    const bg_cell: shaderpkg.CellBg = .{ 0, 0, 0, 1 };
    const fg_cell: shaderpkg.CellText = .{
        .mode = .fg,
        .grid_pos = .{ 4, 1 },
        .color = .{ 0, 0, 0, 1 },
    };
    c.bgCell(1, 4).* = bg_cell;
    try c.add(alloc, .text, fg_cell);
    try testing.expectEqual(bg_cell, c.bgCell(1, 4).*);
    // The fg row index is offset by 1 because of the cursor list.
    try testing.expectEqual(fg_cell, c.fg_rows.lists[2].items[0]);

    // And we should be able to clear it.
    c.clear(1);
    for (0..rows) |y| {
        try testing.expect(c.fg_rows.lists[y + 1].items.len == 0);
        for (0..cols) |x| {
            try testing.expectEqual(.{ 0, 0, 0, 0 }, c.bgCell(y, x).*);
        }
    }

    // Add a cursor.
    const cursor_cell: shaderpkg.CellText = .{
        .mode = .cursor,
        .grid_pos = .{ 2, 3 },
        .color = .{ 0, 0, 0, 1 },
    };
    c.setCursor(cursor_cell);
    try testing.expectEqual(cursor_cell, c.fg_rows.lists[0].items[0]);

    // And remove it.
    c.setCursor(null);
    try testing.expectEqual(0, c.fg_rows.lists[0].items.len);
}

test "Contents clear retains other content" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const rows = 10;
    const cols = 10;

    var c: Contents = .{};
    try c.resize(alloc, .{ .rows = rows, .columns = cols });
    defer c.deinit(alloc);

    // Set some contents
    // bg and fg cells in row 1
    const bg_cell_1: shaderpkg.CellBg = .{ 0, 0, 0, 1 };
    const fg_cell_1: shaderpkg.CellText = .{
        .mode = .fg,
        .grid_pos = .{ 4, 1 },
        .color = .{ 0, 0, 0, 1 },
    };
    c.bgCell(1, 4).* = bg_cell_1;
    try c.add(alloc, .text, fg_cell_1);
    // bg and fg cells in row 2
    const bg_cell_2: shaderpkg.CellBg = .{ 0, 0, 0, 1 };
    const fg_cell_2: shaderpkg.CellText = .{
        .mode = .fg,
        .grid_pos = .{ 4, 2 },
        .color = .{ 0, 0, 0, 1 },
    };
    c.bgCell(2, 4).* = bg_cell_2;
    try c.add(alloc, .text, fg_cell_2);

    // Clear row 1, this should leave row 2 untouched
    c.clear(1);

    // Row 2 should still contain its cells.
    try testing.expectEqual(bg_cell_2, c.bgCell(2, 4).*);
    // Fg row index is +1 because of cursor list at start
    try testing.expectEqual(fg_cell_2, c.fg_rows.lists[3].items[0]);
}

test "Contents clear last added content" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const rows = 10;
    const cols = 10;

    var c: Contents = .{};
    try c.resize(alloc, .{ .rows = rows, .columns = cols });
    defer c.deinit(alloc);

    // Set some contents
    // bg and fg cells in row 1
    const bg_cell_1: shaderpkg.CellBg = .{ 0, 0, 0, 1 };
    const fg_cell_1: shaderpkg.CellText = .{
        .mode = .fg,
        .grid_pos = .{ 4, 1 },
        .color = .{ 0, 0, 0, 1 },
    };
    c.bgCell(1, 4).* = bg_cell_1;
    try c.add(alloc, .text, fg_cell_1);
    // bg and fg cells in row 2
    const bg_cell_2: shaderpkg.CellBg = .{ 0, 0, 0, 1 };
    const fg_cell_2: shaderpkg.CellText = .{
        .mode = .fg,
        .grid_pos = .{ 4, 2 },
        .color = .{ 0, 0, 0, 1 },
    };
    c.bgCell(2, 4).* = bg_cell_2;
    try c.add(alloc, .text, fg_cell_2);

    // Clear row 2, this should leave row 1 untouched
    c.clear(2);

    // Row 1 should still contain its cells.
    try testing.expectEqual(bg_cell_1, c.bgCell(1, 4).*);
    // Fg row index is +1 because of cursor list at start
    try testing.expectEqual(fg_cell_1, c.fg_rows.lists[2].items[0]);
}
