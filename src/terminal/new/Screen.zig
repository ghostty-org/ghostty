const Screen = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const unicode = @import("../../unicode/main.zig");
const PageList = @import("PageList.zig");
const pagepkg = @import("page.zig");
const point = @import("point.zig");
const size = @import("size.zig");
const style = @import("style.zig");
const Page = pagepkg.Page;

/// The general purpose allocator to use for all memory allocations.
/// Unfortunately some screen operations do require allocation.
alloc: Allocator,

/// The list of pages in the screen.
pages: PageList,

/// The current cursor position
cursor: Cursor,

/// The cursor position.
const Cursor = struct {
    // The x/y position within the viewport.
    x: size.CellCountInt,
    y: size.CellCountInt,

    /// The "last column flag (LCF)" as its called. If this is set then the
    /// next character print will force a soft-wrap.
    pending_wrap: bool = false,

    /// The currently active style. The style is page-specific so when
    /// we change pages we need to ensure that we update that page with
    /// our style when used.
    style_id: style.Id = style.default_id,
    style_ref: ?*size.CellCountInt = null,

    /// The pointers into the page list where the cursor is currently
    /// located. This makes it faster to move the cursor.
    page_offset: PageList.RowOffset,
    page_row: *pagepkg.Row,
    page_cell: *pagepkg.Cell,
};

/// Initialize a new screen.
pub fn init(
    alloc: Allocator,
    cols: size.CellCountInt,
    rows: size.CellCountInt,
    max_scrollback: usize,
) !Screen {
    // Initialize our backing pages.
    var pages = try PageList.init(alloc, cols, rows, max_scrollback);
    errdefer pages.deinit();

    // The active area is guaranteed to be allocated and the first
    // page in the list after init. This lets us quickly setup the cursor.
    // This is MUCH faster than pages.rowOffset.
    const page_offset: PageList.RowOffset = .{
        .page = pages.pages.first.?,
        .row_offset = 0,
    };
    const page_rac = page_offset.rowAndCell(0);

    return .{
        .alloc = alloc,
        .pages = pages,
        .cursor = .{
            .x = 0,
            .y = 0,
            .page_offset = page_offset,
            .page_row = page_rac.row,
            .page_cell = page_rac.cell,
        },
    };
}

pub fn deinit(self: *Screen) void {
    self.pages.deinit();
}

pub fn cursorCellRight(self: *Screen) *pagepkg.Cell {
    assert(self.cursor.x + 1 < self.pages.cols);
    const cell: [*]pagepkg.Cell = @ptrCast(self.cursor.page_cell);
    return @ptrCast(cell + 1);
}

pub fn cursorCellLeft(self: *Screen) *pagepkg.Cell {
    assert(self.cursor.x > 0);
    const cell: [*]pagepkg.Cell = @ptrCast(self.cursor.page_cell);
    return @ptrCast(cell - 1);
}

pub fn cursorCellEndOfPrev(self: *Screen) *pagepkg.Cell {
    assert(self.cursor.y > 0);

    const page_offset = self.cursor.page_offset.backward(1).?;
    const page_rac = page_offset.rowAndCell(self.pages.cols - 1);
    return page_rac.cell;
}

/// Move the cursor right. This is a specialized function that is very fast
/// if the caller can guarantee we have space to move right (no wrapping).
pub fn cursorRight(self: *Screen, n: size.CellCountInt) void {
    assert(self.cursor.x + n < self.pages.cols);

    const cell: [*]pagepkg.Cell = @ptrCast(self.cursor.page_cell);
    self.cursor.page_cell = @ptrCast(cell + n);
    self.cursor.x += n;
}

/// Move the cursor left.
pub fn cursorLeft(self: *Screen, n: size.CellCountInt) void {
    assert(self.cursor.x >= n);

    const cell: [*]pagepkg.Cell = @ptrCast(self.cursor.page_cell);
    self.cursor.page_cell = @ptrCast(cell - n);
    self.cursor.x -= n;
}

/// Move the cursor up.
///
/// Precondition: The cursor is not at the top of the screen.
pub fn cursorUp(self: *Screen) void {
    assert(self.cursor.y > 0);

    const page_offset = self.cursor.page_offset.backward(1).?;
    const page_rac = page_offset.rowAndCell(self.cursor.x);
    self.cursor.page_offset = page_offset;
    self.cursor.page_row = page_rac.row;
    self.cursor.page_cell = page_rac.cell;
    self.cursor.y -= 1;
}

/// Move the cursor down.
///
/// Precondition: The cursor is not at the bottom of the screen.
pub fn cursorDown(self: *Screen) void {
    assert(self.cursor.y + 1 < self.pages.rows);

    // We move the offset into our page list to the next row and then
    // get the pointers to the row/cell and set all the cursor state up.
    const page_offset = self.cursor.page_offset.forward(1).?;
    const page_rac = page_offset.rowAndCell(0);
    self.cursor.page_offset = page_offset;
    self.cursor.page_row = page_rac.row;
    self.cursor.page_cell = page_rac.cell;

    // Y of course increases
    self.cursor.y += 1;
}

/// Move the cursor to some absolute position.
pub fn cursorHorizontalAbsolute(self: *Screen, x: size.CellCountInt) void {
    assert(x < self.pages.cols);

    const page_rac = self.cursor.page_offset.rowAndCell(x);
    self.cursor.page_cell = page_rac.cell;
    self.cursor.x = x;
}

/// Scroll the active area and keep the cursor at the bottom of the screen.
/// This is a very specialized function but it keeps it fast.
pub fn cursorDownScroll(self: *Screen) !void {
    assert(self.cursor.y == self.pages.rows - 1);

    // If we have cap space in our current cursor page then we can take
    // a fast path: update the size, recalculate the row/cell cursor pointers.
    const cursor_page = self.cursor.page_offset.page;
    if (cursor_page.data.capacity.rows > cursor_page.data.size.rows) {
        cursor_page.data.size.rows += 1;

        const page_offset = self.cursor.page_offset.forward(1).?;
        const page_rac = page_offset.rowAndCell(self.cursor.x);
        self.cursor.page_offset = page_offset;
        self.cursor.page_row = page_rac.row;
        self.cursor.page_cell = page_rac.cell;
        return;
    }

    // No space, we need to allocate a new page and move the cursor to it.

    const new_page = try self.pages.grow();
    assert(new_page.data.size.rows == 0);
    new_page.data.size.rows = 1;
    const page_offset: PageList.RowOffset = .{
        .page = new_page,
        .row_offset = 0,
    };
    const page_rac = page_offset.rowAndCell(self.cursor.x);
    self.cursor.page_offset = page_offset;
    self.cursor.page_row = page_rac.row;
    self.cursor.page_cell = page_rac.cell;
}

/// Dump the screen to a string. The writer given should be buffered;
/// this function does not attempt to efficiently write and generally writes
/// one byte at a time.
pub fn dumpString(
    self: *const Screen,
    writer: anytype,
    tl: point.Point,
) !void {
    var blank_rows: usize = 0;

    var iter = self.pages.rowIterator(tl);
    while (iter.next()) |row_offset| {
        const rac = row_offset.rowAndCell(0);
        const cells = cells: {
            const cells: [*]pagepkg.Cell = @ptrCast(rac.cell);
            break :cells cells[0..self.pages.cols];
        };

        if (!pagepkg.Cell.hasText(cells)) {
            blank_rows += 1;
            continue;
        }
        if (blank_rows > 0) {
            for (0..blank_rows) |_| try writer.writeByte('\n');
            blank_rows = 0;
        }

        // TODO: handle wrap
        blank_rows += 1;

        var blank_cells: usize = 0;
        for (cells) |cell| {
            // Skip spacers
            switch (cell.wide) {
                .narrow, .wide => {},
                .spacer_head, .spacer_tail => continue,
            }

            // If we have a zero value, then we accumulate a counter. We
            // only want to turn zero values into spaces if we have a non-zero
            // char sometime later.
            if (cell.codepoint == 0) {
                blank_cells += 1;
                continue;
            }
            if (blank_cells > 0) {
                for (0..blank_cells) |_| try writer.writeByte(' ');
                blank_cells = 0;
            }

            try writer.print("{u}", .{cell.codepoint});
        }
    }
}

pub fn dumpStringAlloc(
    self: *const Screen,
    alloc: Allocator,
    tl: point.Point,
) ![]const u8 {
    var builder = std.ArrayList(u8).init(alloc);
    defer builder.deinit();
    try self.dumpString(builder.writer(), tl);
    return try builder.toOwnedSlice();
}

fn testWriteString(self: *Screen, text: []const u8) !void {
    const view = try std.unicode.Utf8View.init(text);
    var iter = view.iterator();
    while (iter.nextCodepoint()) |c| {
        if (self.cursor.x == self.pages.cols) {
            @panic("wrap not implemented");
        }

        const width: usize = if (c <= 0xFF) 1 else @intCast(unicode.table.get(c).width);
        if (width == 0) {
            @panic("zero-width todo");
        }

        assert(width == 1 or width == 2);
        switch (width) {
            1 => {
                self.cursor.page_cell.codepoint = c;
                self.cursor.x += 1;
                if (self.cursor.x < self.pages.cols) {
                    const cell: [*]pagepkg.Cell = @ptrCast(self.cursor.page_cell);
                    self.cursor.page_cell = @ptrCast(cell + 1);
                } else {
                    @panic("wrap not implemented");
                }
            },

            2 => @panic("todo double-width"),
            else => unreachable,
        }
    }
}

test "Screen read and write" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, 80, 24, 1000);
    defer s.deinit();

    try s.testWriteString("hello, world");
    const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
    defer alloc.free(str);
    try testing.expectEqualStrings("hello, world", str);
}
