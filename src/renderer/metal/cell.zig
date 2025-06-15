const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const renderer = @import("../../renderer.zig");
const terminal = @import("../../terminal/main.zig");
const mtl_shaders = @import("shaders.zig");

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
            .bg => mtl_shaders.CellBg,

            .text,
            .underline,
            .strikethrough,
            .overline,
            => mtl_shaders.CellText,
        };
    }
};

/// A pool of ArrayLists with methods for bulk operations.
fn ArrayListPool(comptime T: type) type {
    return struct {
        const Self = ArrayListPool(T);
        const ArrayListT = std.ArrayListUnmanaged(T);

        // An array containing the lists that belong to this pool.
        lists: []ArrayListT = &[_]ArrayListT{},

        // The pool will be initialized with empty ArrayLists.
        pub fn init(alloc: Allocator, list_count: usize, initial_capacity: usize) !Self {
            const self: Self = .{
                .lists = try alloc.alloc(ArrayListT, list_count),
            };

            for (self.lists) |*list| {
                list.* = try .initCapacity(alloc, initial_capacity);
            }

            return self;
        }

        pub fn deinit(self: *Self, alloc: Allocator) void {
            for (self.lists) |*list| {
                list.deinit(alloc);
            }
            alloc.free(self.lists);
        }

        /// Clear all lists in the pool.
        pub fn reset(self: *Self) void {
            for (self.lists) |*list| {
                list.clearRetainingCapacity();
            }
        }
    };
}

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
    bg_cells: []mtl_shaders.CellBg = undefined,

    /// The ArrayListPool which holds all of the foreground cells. When sized
    /// with Contents.resize the individual ArrayLists are given enough room
    /// that they can hold a single row with #cols glyphs, underlines, and
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
    /// the pool is reserved for the cursor, which must be the first item in
    /// the buffer.
    ///
    /// Must be initialized by calling resize on the Contents struct before
    /// calling any operations.
    fg_rows: ArrayListPool(mtl_shaders.CellText) = .{},

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
    ) !void {
        self.size = size;

        const cell_count = @as(usize, size.columns) * @as(usize, size.rows);

        const bg_cells = try alloc.alloc(mtl_shaders.CellBg, cell_count);
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
        var fg_rows = try ArrayListPool(mtl_shaders.CellText).init(alloc, size.rows + 1, size.columns * 3);
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
        self.fg_rows.lists[0] = try std.ArrayListUnmanaged(mtl_shaders.CellText).initCapacity(alloc, 1);
    }

    /// Reset the cell contents to an empty state without resizing.
    pub fn reset(self: *Contents) void {
        @memset(self.bg_cells, .{ 0, 0, 0, 0 });
        self.fg_rows.reset();
    }

    /// Set the cursor value. If the value is null then the cursor is hidden.
    pub fn setCursor(self: *Contents, v: ?mtl_shaders.CellText) void {
        self.fg_rows.lists[0].clearRetainingCapacity();

        if (v) |cell| {
            self.fg_rows.lists[0].appendAssumeCapacity(cell);
        }
    }

    /// Access a background cell. Prefer this function over direct indexing
    /// of `bg_cells` in order to avoid integer size bugs causing overflows.
    pub inline fn bgCell(self: *Contents, row: usize, col: usize) *mtl_shaders.CellBg {
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
    ) !void {
        const y = cell.grid_pos[1];

        assert(y < self.size.rows);

        switch (key) {
            .bg => comptime unreachable,

            .text,
            .underline,
            .strikethrough,
            .overline,
            // We have a special list containing the cursor cell at the start
            // of our fg row pool, so we need to add 1 to the y to get the
            // correct index.
            => try self.fg_rows.lists[y + 1].append(alloc, cell),
        }
    }

    /// Clear all of the cell contents for a given row.
    pub fn clear(self: *Contents, y: terminal.size.CellCountInt) void {
        assert(y < self.size.rows);

        @memset(self.bg_cells[@as(usize, y) * self.size.columns ..][0..self.size.columns], .{ 0, 0, 0, 0 });

        // We have a special list containing the cursor cell at the start
        // of our fg row pool, so we need to add 1 to the y to get the
        // correct index.
        self.fg_rows.lists[y + 1].clearRetainingCapacity();
    }
};

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
    const bg_cell: mtl_shaders.CellBg = .{ 0, 0, 0, 1 };
    const fg_cell: mtl_shaders.CellText = .{
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
    const cursor_cell: mtl_shaders.CellText = .{
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
    const bg_cell_1: mtl_shaders.CellBg = .{ 0, 0, 0, 1 };
    const fg_cell_1: mtl_shaders.CellText = .{
        .mode = .fg,
        .grid_pos = .{ 4, 1 },
        .color = .{ 0, 0, 0, 1 },
    };
    c.bgCell(1, 4).* = bg_cell_1;
    try c.add(alloc, .text, fg_cell_1);
    // bg and fg cells in row 2
    const bg_cell_2: mtl_shaders.CellBg = .{ 0, 0, 0, 1 };
    const fg_cell_2: mtl_shaders.CellText = .{
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
    const bg_cell_1: mtl_shaders.CellBg = .{ 0, 0, 0, 1 };
    const fg_cell_1: mtl_shaders.CellText = .{
        .mode = .fg,
        .grid_pos = .{ 4, 1 },
        .color = .{ 0, 0, 0, 1 },
    };
    c.bgCell(1, 4).* = bg_cell_1;
    try c.add(alloc, .text, fg_cell_1);
    // bg and fg cells in row 2
    const bg_cell_2: mtl_shaders.CellBg = .{ 0, 0, 0, 1 };
    const fg_cell_2: mtl_shaders.CellText = .{
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
