const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const font = @import("../font/main.zig");
const terminal = @import("../terminal/main.zig");
const renderer = @import("../renderer.zig");
const shaderpkg = renderer.Renderer.API.shaders;
const ArrayListCollection = @import("../datastruct/array_list_collection.zig").ArrayListCollection;
const symbols = @import("../unicode/symbols_table.zig").table;

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
        // We have size.rows + 2 lists because indexes 0 and size.rows - 1 are
        // used for special lists containing the cursor cell which need to
        // be first and last in the buffer, respectively.
        var fg_rows = try ArrayListCollection(shaderpkg.CellText).init(
            alloc,
            size.rows + 2,
            size.columns * 3,
        );
        errdefer fg_rows.deinit(alloc);

        alloc.free(self.bg_cells);
        self.fg_rows.deinit(alloc);

        self.bg_cells = bg_cells;
        self.fg_rows = fg_rows;

        // We don't need 3*cols worth of cells for the cursor lists, so we can
        // replace them with smaller lists. This is technically a tiny bit of
        // extra work but resize is not a hot function so it's worth it to not
        // waste the memory.
        self.fg_rows.lists[0].deinit(alloc);
        self.fg_rows.lists[0] = try std.ArrayListUnmanaged(
            shaderpkg.CellText,
        ).initCapacity(alloc, 1);

        self.fg_rows.lists[size.rows + 1].deinit(alloc);
        self.fg_rows.lists[size.rows + 1] = try std.ArrayListUnmanaged(
            shaderpkg.CellText,
        ).initCapacity(alloc, 1);
    }

    /// Reset the cell contents to an empty state without resizing.
    pub fn reset(self: *Contents) void {
        @memset(self.bg_cells, .{ 0, 0, 0, 0 });
        self.fg_rows.reset();
    }

    /// Set the cursor value. If the value is null then the cursor is hidden.
    pub fn setCursor(
        self: *Contents,
        v: ?shaderpkg.CellText,
        cursor_style: ?renderer.CursorStyle,
    ) void {
        if (self.size.rows == 0) return;
        self.fg_rows.lists[0].clearRetainingCapacity();
        self.fg_rows.lists[self.size.rows + 1].clearRetainingCapacity();

        const cell = v orelse return;
        const style = cursor_style orelse return;

        switch (style) {
            // Block cursors should be drawn first
            .block => self.fg_rows.lists[0].appendAssumeCapacity(cell),
            // Other cursor styles should be drawn last
            .block_hollow, .bar, .underline, .lock => self.fg_rows.lists[self.size.rows + 1].appendAssumeCapacity(cell),
        }
    }

    /// Returns the current cursor glyph if present, checking both cursor lists.
    pub fn getCursorGlyph(self: *Contents) ?shaderpkg.CellText {
        if (self.size.rows == 0) return null;
        if (self.fg_rows.lists[0].items.len > 0) {
            return self.fg_rows.lists[0].items[0];
        }
        if (self.fg_rows.lists[self.size.rows + 1].items.len > 0) {
            return self.fg_rows.lists[self.size.rows + 1].items[0];
        }
        return null;
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

/// Returns true of the codepoint is a "symbol-like" character, which
/// for now we define as anything in a private use area, and anything
/// in several unicode blocks:
/// - Arrows
/// - Dingbats
/// - Emoticons
/// - Miscellaneous Symbols
/// - Enclosed Alphanumerics
/// - Enclosed Alphanumeric Supplement
/// - Miscellaneous Symbols and Pictographs
/// - Transport and Map Symbols
///
/// In the future it may be prudent to expand this to encompass more
/// symbol-like characters, and/or exclude some PUA sections.
pub fn isSymbol(cp: u21) bool {
    return symbols.get(cp);
}

/// Returns the appropriate `constraint_width` for
/// the provided cell when rendering its glyph(s).
pub fn constraintWidth(
    raw_slice: []const terminal.page.Cell,
    x: usize,
    cols: usize,
) u2 {
    const cell = raw_slice[x];
    const cp = cell.codepoint();

    const grid_width = cell.gridWidth();

    // If the grid width of the cell is 2, the constraint
    // width will always be 2, so we can just return early.
    if (grid_width > 1) return grid_width;

    // We allow "symbol-like" glyphs to extend to 2 cells wide if there's
    // space, and if the previous glyph wasn't also a symbol. So if this
    // codepoint isn't a symbol then we can return the grid width.
    if (!isSymbol(cp)) return grid_width;

    // If we are at the end of the screen it must be constrained to one cell.
    if (x == cols - 1) return 1;

    // If we have a previous cell and it was a symbol then we need
    // to also constrain. This is so that multiple PUA glyphs align.
    // This does not apply if the previous symbol is a graphics
    // element such as a block element or Powerline glyph.
    if (x > 0) {
        const prev_cp = raw_slice[x - 1].codepoint();
        if (isSymbol(prev_cp) and !isGraphicsElement(prev_cp)) {
            return 1;
        }
    }

    // If the next cell is whitespace, then we
    // allow the glyph to be up to two cells wide.
    const next_cp = raw_slice[x + 1].codepoint();
    if (next_cp == 0 or isSpace(next_cp)) return 2;

    // Otherwise, this has to be 1 cell wide.
    return 1;
}

/// Whether min contrast should be disabled for a given glyph. True
/// for graphics elements such as blocks and Powerline glyphs.
pub fn noMinContrast(cp: u21) bool {
    return isGraphicsElement(cp);
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

/// Returns true if the codepoint is used for terminal graphics, such
/// as box drawing characters, block elements, and Powerline glyphs.
fn isGraphicsElement(char: u21) bool {
    return isBoxDrawing(char) or isBlockElement(char) or isLegacyComputing(char) or isPowerline(char);
}

// Returns true if the codepoint is a box drawing character.
fn isBoxDrawing(char: u21) bool {
    return switch (char) {
        0x2500...0x257F => true,
        else => false,
    };
}

// Returns true if the codepoint is a block element.
fn isBlockElement(char: u21) bool {
    return switch (char) {
        0x2580...0x259F => true,
        else => false,
    };
}

// Returns true if the codepoint is in a Symbols for Legacy
// Computing block, including supplements.
fn isLegacyComputing(char: u21) bool {
    return switch (char) {
        0x1FB00...0x1FBFF => true,
        0x1CC00...0x1CEBF => true, // Supplement introduced in Unicode 16.0
        else => false,
    };
}

// Returns true if the codepoint is a part of the Powerline range.
fn isPowerline(char: u21) bool {
    return switch (char) {
        0xE0B0...0xE0D7 => true,
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
        .atlas = .grayscale,
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

    // Add a block cursor.
    const cursor_cell: shaderpkg.CellText = .{
        .atlas = .grayscale,
        .bools = .{ .is_cursor_glyph = true },
        .grid_pos = .{ 2, 3 },
        .color = .{ 0, 0, 0, 1 },
    };
    c.setCursor(cursor_cell, .block);
    try testing.expectEqual(cursor_cell, c.fg_rows.lists[0].items[0]);
    try testing.expectEqual(cursor_cell, c.getCursorGlyph().?);

    // And remove it.
    c.setCursor(null, null);
    try testing.expectEqual(0, c.fg_rows.lists[0].items.len);
    try testing.expect(c.getCursorGlyph() == null);

    // Add a hollow cursor.
    c.setCursor(cursor_cell, .block_hollow);
    try testing.expectEqual(cursor_cell, c.fg_rows.lists[rows + 1].items[0]);
    try testing.expectEqual(cursor_cell, c.getCursorGlyph().?);
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
        .atlas = .grayscale,
        .grid_pos = .{ 4, 1 },
        .color = .{ 0, 0, 0, 1 },
    };
    c.bgCell(1, 4).* = bg_cell_1;
    try c.add(alloc, .text, fg_cell_1);
    // bg and fg cells in row 2
    const bg_cell_2: shaderpkg.CellBg = .{ 0, 0, 0, 1 };
    const fg_cell_2: shaderpkg.CellText = .{
        .atlas = .grayscale,
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
        .atlas = .grayscale,
        .grid_pos = .{ 4, 1 },
        .color = .{ 0, 0, 0, 1 },
    };
    c.bgCell(1, 4).* = bg_cell_1;
    try c.add(alloc, .text, fg_cell_1);
    // bg and fg cells in row 2
    const bg_cell_2: shaderpkg.CellBg = .{ 0, 0, 0, 1 };
    const fg_cell_2: shaderpkg.CellText = .{
        .atlas = .grayscale,
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

test "Contents with zero-sized screen" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c: Contents = .{};
    defer c.deinit(alloc);

    c.setCursor(null, null);
    try testing.expect(c.getCursorGlyph() == null);
}

test "Cell constraint widths" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: terminal.Terminal = try .init(alloc, .{
        .cols = 4,
        .rows = 1,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);

    // for each case, the numbers in the comment denote expected
    // constraint widths for the symbol-containing cells

    // symbol->nothing: 2
    {
        t.fullReset();
        try s.nextSlice("");
        try state.update(alloc, &t);
        try testing.expectEqual(2, constraintWidth(
            state.row_data.get(0).cells.items(.raw),
            0,
            state.cols,
        ));
    }

    // symbol->character: 1
    {
        t.fullReset();
        try s.nextSlice("z");
        try state.update(alloc, &t);
        try testing.expectEqual(1, constraintWidth(
            state.row_data.get(0).cells.items(.raw),
            0,
            state.cols,
        ));
    }

    // symbol->space: 2
    {
        t.fullReset();
        try s.nextSlice(" z");
        try state.update(alloc, &t);
        try testing.expectEqual(2, constraintWidth(
            state.row_data.get(0).cells.items(.raw),
            0,
            state.cols,
        ));
    }
    // symbol->no-break space: 1
    {
        t.fullReset();
        try s.nextSlice("\u{00a0}z");
        try state.update(alloc, &t);
        try testing.expectEqual(1, constraintWidth(
            state.row_data.get(0).cells.items(.raw),
            0,
            state.cols,
        ));
    }

    // symbol->end of row: 1
    {
        t.fullReset();
        try s.nextSlice("   ");
        try state.update(alloc, &t);
        try testing.expectEqual(1, constraintWidth(
            state.row_data.get(0).cells.items(.raw),
            3,
            state.cols,
        ));
    }

    // character->symbol: 2
    {
        t.fullReset();
        try s.nextSlice("z");
        try state.update(alloc, &t);
        try testing.expectEqual(2, constraintWidth(
            state.row_data.get(0).cells.items(.raw),
            1,
            state.cols,
        ));
    }

    // symbol->symbol: 1,1
    {
        t.fullReset();
        try s.nextSlice("");
        try state.update(alloc, &t);
        try testing.expectEqual(1, constraintWidth(
            state.row_data.get(0).cells.items(.raw),
            0,
            state.cols,
        ));
        try testing.expectEqual(1, constraintWidth(
            state.row_data.get(0).cells.items(.raw),
            1,
            state.cols,
        ));
    }

    // symbol->space->symbol: 2,2
    {
        t.fullReset();
        try s.nextSlice(" ");
        try state.update(alloc, &t);
        try testing.expectEqual(2, constraintWidth(
            state.row_data.get(0).cells.items(.raw),
            0,
            state.cols,
        ));
        try testing.expectEqual(2, constraintWidth(
            state.row_data.get(0).cells.items(.raw),
            2,
            state.cols,
        ));
    }

    // symbol->powerline: 1  (dedicated test because powerline is special-cased in cellpkg)
    {
        t.fullReset();
        try s.nextSlice("");
        try state.update(alloc, &t);
        try testing.expectEqual(1, constraintWidth(
            state.row_data.get(0).cells.items(.raw),
            0,
            state.cols,
        ));
    }

    // powerline->symbol: 2  (dedicated test because powerline is special-cased in cellpkg)
    {
        t.fullReset();
        try s.nextSlice("");
        try state.update(alloc, &t);
        try testing.expectEqual(2, constraintWidth(
            state.row_data.get(0).cells.items(.raw),
            1,
            state.cols,
        ));
    }

    // powerline->nothing: 2  (dedicated test because powerline is special-cased in cellpkg)
    {
        t.fullReset();
        try s.nextSlice("");
        try state.update(alloc, &t);
        try testing.expectEqual(2, constraintWidth(
            state.row_data.get(0).cells.items(.raw),
            0,
            state.cols,
        ));
    }

    // powerline->space: 2  (dedicated test because powerline is special-cased in cellpkg)
    {
        t.fullReset();
        try s.nextSlice(" z");
        try state.update(alloc, &t);
        try testing.expectEqual(2, constraintWidth(
            state.row_data.get(0).cells.items(.raw),
            0,
            state.cols,
        ));
    }
}
