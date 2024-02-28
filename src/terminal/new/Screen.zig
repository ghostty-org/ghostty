const Screen = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const ansi = @import("../ansi.zig");
const sgr = @import("../sgr.zig");
const unicode = @import("../../unicode/main.zig");
const PageList = @import("PageList.zig");
const pagepkg = @import("page.zig");
const point = @import("point.zig");
const size = @import("size.zig");
const style = @import("style.zig");
const Page = pagepkg.Page;
const Row = pagepkg.Row;
const Cell = pagepkg.Cell;

/// The general purpose allocator to use for all memory allocations.
/// Unfortunately some screen operations do require allocation.
alloc: Allocator,

/// The list of pages in the screen.
pages: PageList,

/// The current cursor position
cursor: Cursor,

/// The saved cursor
saved_cursor: ?SavedCursor = null,

/// The current or most recent protected mode. Once a protection mode is
/// set, this will never become "off" again until the screen is reset.
/// The current state of whether protection attributes should be set is
/// set on the Cell pen; this is only used to determine the most recent
/// protection mode since some sequences such as ECH depend on this.
protected_mode: ansi.ProtectedMode = .off,

/// The cursor position.
pub const Cursor = struct {
    // The x/y position within the viewport.
    x: size.CellCountInt,
    y: size.CellCountInt,

    /// The "last column flag (LCF)" as its called. If this is set then the
    /// next character print will force a soft-wrap.
    pending_wrap: bool = false,

    /// The protected mode state of the cursor. If this is true then
    /// all new characters printed will have the protected state set.
    protected: bool = false,

    /// The currently active style. This is the concrete style value
    /// that should be kept up to date. The style ID to use for cell writing
    /// is below.
    style: style.Style = .{},

    /// The currently active style ID. The style is page-specific so when
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

/// Saved cursor state.
pub const SavedCursor = struct {
    x: size.CellCountInt,
    y: size.CellCountInt,
    style: style.Style,
    protected: bool,
    pending_wrap: bool,
    origin: bool,
    // TODO
    //charset: CharsetState,
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

pub fn cursorCellRight(self: *Screen, n: size.CellCountInt) *pagepkg.Cell {
    assert(self.cursor.x + n < self.pages.cols);
    const cell: [*]pagepkg.Cell = @ptrCast(self.cursor.page_cell);
    return @ptrCast(cell + n);
}

pub fn cursorCellLeft(self: *Screen, n: size.CellCountInt) *pagepkg.Cell {
    assert(self.cursor.x >= n);
    const cell: [*]pagepkg.Cell = @ptrCast(self.cursor.page_cell);
    return @ptrCast(cell - n);
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
pub fn cursorUp(self: *Screen, n: size.CellCountInt) void {
    assert(self.cursor.y >= n);

    const page_offset = self.cursor.page_offset.backward(n).?;
    const page_rac = page_offset.rowAndCell(self.cursor.x);
    self.cursor.page_offset = page_offset;
    self.cursor.page_row = page_rac.row;
    self.cursor.page_cell = page_rac.cell;
    self.cursor.y -= n;
}

pub fn cursorRowUp(self: *Screen, n: size.CellCountInt) *pagepkg.Row {
    assert(self.cursor.y >= n);

    const page_offset = self.cursor.page_offset.backward(n).?;
    const page_rac = page_offset.rowAndCell(self.cursor.x);
    return page_rac.row;
}

/// Move the cursor down.
///
/// Precondition: The cursor is not at the bottom of the screen.
pub fn cursorDown(self: *Screen, n: size.CellCountInt) void {
    assert(self.cursor.y + n < self.pages.rows);

    // We move the offset into our page list to the next row and then
    // get the pointers to the row/cell and set all the cursor state up.
    const page_offset = self.cursor.page_offset.forward(n).?;
    const page_rac = page_offset.rowAndCell(self.cursor.x);
    self.cursor.page_offset = page_offset;
    self.cursor.page_row = page_rac.row;
    self.cursor.page_cell = page_rac.cell;

    // Y of course increases
    self.cursor.y += n;
}

/// Move the cursor to some absolute horizontal position.
pub fn cursorHorizontalAbsolute(self: *Screen, x: size.CellCountInt) void {
    assert(x < self.pages.cols);

    const page_rac = self.cursor.page_offset.rowAndCell(x);
    self.cursor.page_cell = page_rac.cell;
    self.cursor.x = x;
}

/// Move the cursor to some absolute position.
pub fn cursorAbsolute(self: *Screen, x: size.CellCountInt, y: size.CellCountInt) void {
    assert(x < self.pages.cols);
    assert(y < self.pages.rows);

    const page_offset = if (y < self.cursor.y)
        self.cursor.page_offset.backward(self.cursor.y - y).?
    else if (y > self.cursor.y)
        self.cursor.page_offset.forward(y - self.cursor.y).?
    else
        self.cursor.page_offset;
    const page_rac = page_offset.rowAndCell(x);
    self.cursor.page_offset = page_offset;
    self.cursor.page_row = page_rac.row;
    self.cursor.page_cell = page_rac.cell;
    self.cursor.x = x;
    self.cursor.y = y;
}

/// Scroll the active area and keep the cursor at the bottom of the screen.
/// This is a very specialized function but it keeps it fast.
pub fn cursorDownScroll(self: *Screen) !void {
    assert(self.cursor.y == self.pages.rows - 1);

    // Grow our pages by one row. The PageList will handle if we need to
    // allocate, prune scrollback, whatever.
    _ = try self.pages.grow();
    const page_offset = self.cursor.page_offset.forward(1).?;
    const page_rac = page_offset.rowAndCell(self.cursor.x);
    self.cursor.page_offset = page_offset;
    self.cursor.page_row = page_rac.row;
    self.cursor.page_cell = page_rac.cell;

    // The newly created line needs to be styled according to the bg color
    // if it is set.
    if (self.cursor.style_id != style.default_id) {
        if (self.cursor.style.bgCell()) |blank_cell| {
            const cell_current: [*]pagepkg.Cell = @ptrCast(self.cursor.page_cell);
            const cells = cell_current - self.cursor.x;
            @memset(cells[0..self.pages.cols], blank_cell);
        }
    }
}

/// Move the cursor down if we're not at the bottom of the screen. Otherwise
/// scroll. Currently only used for testing.
fn cursorDownOrScroll(self: *Screen) !void {
    if (self.cursor.y + 1 < self.pages.rows) {
        self.cursorDown(1);
    } else {
        try self.cursorDownScroll();
    }
}

/// Options for scrolling the viewport of the terminal grid. The reason
/// we have this in addition to PageList.Scroll is because we have additional
/// scroll behaviors that are not part of the PageList.Scroll enum.
pub const Scroll = union(enum) {
    /// For all of these, see PageList.Scroll.
    active,
    top,
    delta_row: isize,
};

/// Scroll the viewport of the terminal grid.
pub fn scroll(self: *Screen, behavior: Scroll) void {
    switch (behavior) {
        .active => self.pages.scroll(.{ .active = {} }),
        .top => self.pages.scroll(.{ .top = {} }),
        .delta_row => |v| self.pages.scroll(.{ .delta_row = v }),
    }
}

// Erase the region specified by tl and bl, inclusive. Erased cells are
// colored with the current style background color. This will erase all
// cells in the rows.
//
// If protected is true, the protected flag will be respected and only
// unprotected cells will be erased. Otherwise, all cells will be erased.
pub fn eraseRows(
    self: *Screen,
    tl: point.Point,
    bl: ?point.Point,
    protected: bool,
) void {
    var it = self.pages.rowChunkIterator(tl, bl);
    while (it.next()) |chunk| {
        for (chunk.rows()) |*row| {
            const cells_offset = row.cells;
            const cells_multi: [*]Cell = row.cells.ptr(chunk.page.data.memory);
            const cells = cells_multi[0..self.pages.cols];

            // Erase all cells
            if (protected) {
                self.eraseUnprotectedCells(&chunk.page.data, row, cells);
            } else {
                self.eraseCells(&chunk.page.data, row, cells);
            }

            // Reset our row to point to the proper memory but everything
            // else is zeroed.
            row.* = .{ .cells = cells_offset };
        }
    }
}

/// Erase the cells with the blank cell. This takes care to handle
/// cleaning up graphemes and styles.
pub fn eraseCells(
    self: *Screen,
    page: *Page,
    row: *Row,
    cells: []Cell,
) void {
    // If this row has graphemes, then we need go through a slow path
    // and delete the cell graphemes.
    if (row.grapheme) {
        for (cells) |*cell| {
            if (cell.hasGrapheme()) page.clearGrapheme(row, cell);
        }
    }

    if (row.styled) {
        for (cells) |*cell| {
            if (cell.style_id == style.default_id) continue;

            // Fast-path, the style ID matches, in this case we just update
            // our own ref and continue. We never delete because our style
            // is still active.
            if (cell.style_id == self.cursor.style_id) {
                self.cursor.style_ref.?.* -= 1;
                continue;
            }

            // Slow path: we need to lookup this style so we can decrement
            // the ref count. Since we've already loaded everything, we also
            // just go ahead and GC it if it reaches zero, too.
            if (page.styles.lookupId(page.memory, cell.style_id)) |prev_style| {
                // Below upsert can't fail because it should already be present
                const md = page.styles.upsert(page.memory, prev_style.*) catch unreachable;
                assert(md.ref > 0);
                md.ref -= 1;
                if (md.ref == 0) page.styles.remove(page.memory, cell.style_id);
            }
        }

        // If we have no left/right scroll region we can be sure that
        // the row is no longer styled.
        if (cells.len == self.pages.cols) row.styled = false;
    }

    @memset(cells, self.blankCell());
}

/// Erase cells but only if they are not protected.
pub fn eraseUnprotectedCells(
    self: *Screen,
    page: *Page,
    row: *Row,
    cells: []Cell,
) void {
    for (cells) |*cell| {
        if (cell.protected) continue;
        const cell_multi: [*]Cell = @ptrCast(cell);
        self.eraseCells(page, row, cell_multi[0..1]);
    }
}

/// Returns the blank cell to use when doing terminal operations that
/// require preserving the bg color.
fn blankCell(self: *const Screen) Cell {
    if (self.cursor.style_id == style.default_id) return .{};
    return self.cursor.style.bgCell() orelse .{};
}

/// Set a style attribute for the current cursor.
///
/// This can cause a page split if the current page cannot fit this style.
/// This is the only scenario an error return is possible.
pub fn setAttribute(self: *Screen, attr: sgr.Attribute) !void {
    switch (attr) {
        .unset => {
            self.cursor.style = .{};
        },

        .bold => {
            self.cursor.style.flags.bold = true;
        },

        .reset_bold => {
            // Bold and faint share the same SGR code for this
            self.cursor.style.flags.bold = false;
            self.cursor.style.flags.faint = false;
        },

        .italic => {
            self.cursor.style.flags.italic = true;
        },

        .reset_italic => {
            self.cursor.style.flags.italic = false;
        },

        .faint => {
            self.cursor.style.flags.faint = true;
        },

        .underline => |v| {
            self.cursor.style.flags.underline = v;
        },

        .reset_underline => {
            self.cursor.style.flags.underline = .none;
        },

        .underline_color => |rgb| {
            self.cursor.style.underline_color = .{ .rgb = .{
                .r = rgb.r,
                .g = rgb.g,
                .b = rgb.b,
            } };
        },

        .@"256_underline_color" => |idx| {
            self.cursor.style.underline_color = .{ .palette = idx };
        },

        .reset_underline_color => {
            self.cursor.style.underline_color = .none;
        },

        .blink => {
            self.cursor.style.flags.blink = true;
        },

        .reset_blink => {
            self.cursor.style.flags.blink = false;
        },

        .inverse => {
            self.cursor.style.flags.inverse = true;
        },

        .reset_inverse => {
            self.cursor.style.flags.inverse = false;
        },

        .invisible => {
            self.cursor.style.flags.invisible = true;
        },

        .reset_invisible => {
            self.cursor.style.flags.invisible = false;
        },

        .strikethrough => {
            self.cursor.style.flags.strikethrough = true;
        },

        .reset_strikethrough => {
            self.cursor.style.flags.strikethrough = false;
        },

        .direct_color_fg => |rgb| {
            self.cursor.style.fg_color = .{
                .rgb = .{
                    .r = rgb.r,
                    .g = rgb.g,
                    .b = rgb.b,
                },
            };
        },

        .direct_color_bg => |rgb| {
            self.cursor.style.bg_color = .{
                .rgb = .{
                    .r = rgb.r,
                    .g = rgb.g,
                    .b = rgb.b,
                },
            };
        },

        .@"8_fg" => |n| {
            self.cursor.style.fg_color = .{ .palette = @intFromEnum(n) };
        },

        .@"8_bg" => |n| {
            self.cursor.style.bg_color = .{ .palette = @intFromEnum(n) };
        },

        .reset_fg => self.cursor.style.fg_color = .none,

        .reset_bg => self.cursor.style.bg_color = .none,

        .@"8_bright_fg" => |n| {
            self.cursor.style.fg_color = .{ .palette = @intFromEnum(n) };
        },

        .@"8_bright_bg" => |n| {
            self.cursor.style.bg_color = .{ .palette = @intFromEnum(n) };
        },

        .@"256_fg" => |idx| {
            self.cursor.style.fg_color = .{ .palette = idx };
        },

        .@"256_bg" => |idx| {
            self.cursor.style.bg_color = .{ .palette = idx };
        },

        .unknown => return,
    }

    try self.manualStyleUpdate();
}

/// Call this whenever you manually change the cursor style.
pub fn manualStyleUpdate(self: *Screen) !void {
    var page = &self.cursor.page_offset.page.data;

    // Remove our previous style if is unused.
    if (self.cursor.style_ref) |ref| {
        if (ref.* == 0) {
            page.styles.remove(page.memory, self.cursor.style_id);
        }
    }

    // If our new style is the default, just reset to that
    if (self.cursor.style.default()) {
        self.cursor.style_id = 0;
        self.cursor.style_ref = null;
        return;
    }

    // After setting the style, we need to update our style map.
    // Note that we COULD lazily do this in print. We should look into
    // if that makes a meaningful difference. Our priority is to keep print
    // fast because setting a ton of styles that do nothing is uncommon
    // and weird.
    const md = try page.styles.upsert(page.memory, self.cursor.style);
    self.cursor.style_id = md.id;
    self.cursor.style_ref = &md.ref;
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

        if (!pagepkg.Cell.hasTextAny(cells)) {
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
        for (cells) |*cell| {
            // Skip spacers
            switch (cell.wide) {
                .narrow, .wide => {},
                .spacer_head, .spacer_tail => continue,
            }

            // If we have a zero value, then we accumulate a counter. We
            // only want to turn zero values into spaces if we have a non-zero
            // char sometime later.
            if (!cell.hasText()) {
                blank_cells += 1;
                continue;
            }
            if (blank_cells > 0) {
                for (0..blank_cells) |_| try writer.writeByte(' ');
                blank_cells = 0;
            }

            switch (cell.content_tag) {
                .codepoint => {
                    try writer.print("{u}", .{cell.content.codepoint});
                },

                .codepoint_grapheme => {
                    try writer.print("{u}", .{cell.content.codepoint});
                    const cps = row_offset.page.data.lookupGrapheme(cell).?;
                    for (cps) |cp| {
                        try writer.print("{u}", .{cp});
                    }
                },

                else => unreachable,
            }
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

/// This is basically a really jank version of Terminal.printString. We
/// have to reimplement it here because we want a way to print to the screen
/// to test it but don't want all the features of Terminal.
fn testWriteString(self: *Screen, text: []const u8) !void {
    const view = try std.unicode.Utf8View.init(text);
    var iter = view.iterator();
    while (iter.nextCodepoint()) |c| {
        // Explicit newline forces a new row
        if (c == '\n') {
            try self.cursorDownOrScroll();
            self.cursorHorizontalAbsolute(0);
            continue;
        }

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
                self.cursor.page_cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = c },
                    .style_id = self.cursor.style_id,
                };

                // If we have a ref-counted style, increase.
                if (self.cursor.style_ref) |ref| {
                    ref.* += 1;
                    self.cursor.page_row.styled = true;
                }

                if (self.cursor.x + 1 < self.pages.cols) {
                    self.cursorRight(1);
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
    try testing.expectEqual(@as(style.Id, 0), s.cursor.style_id);

    try s.testWriteString("hello, world");
    const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
    defer alloc.free(str);
    try testing.expectEqualStrings("hello, world", str);
}

test "Screen read and write newline" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, 80, 24, 1000);
    defer s.deinit();
    try testing.expectEqual(@as(style.Id, 0), s.cursor.style_id);

    try s.testWriteString("hello\nworld");
    const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
    defer alloc.free(str);
    try testing.expectEqualStrings("hello\nworld", str);
}

test "Screen style basics" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, 80, 24, 1000);
    defer s.deinit();
    const page = s.cursor.page_offset.page.data;
    try testing.expectEqual(@as(usize, 0), page.styles.count(page.memory));

    // Set a new style
    try s.setAttribute(.{ .bold = {} });
    try testing.expect(s.cursor.style_id != 0);
    try testing.expectEqual(@as(usize, 1), page.styles.count(page.memory));
    try testing.expect(s.cursor.style.flags.bold);

    // Set another style, we should still only have one since it was unused
    try s.setAttribute(.{ .italic = {} });
    try testing.expect(s.cursor.style_id != 0);
    try testing.expectEqual(@as(usize, 1), page.styles.count(page.memory));
    try testing.expect(s.cursor.style.flags.italic);
}

test "Screen style reset to default" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, 80, 24, 1000);
    defer s.deinit();
    const page = s.cursor.page_offset.page.data;
    try testing.expectEqual(@as(usize, 0), page.styles.count(page.memory));

    // Set a new style
    try s.setAttribute(.{ .bold = {} });
    try testing.expect(s.cursor.style_id != 0);
    try testing.expectEqual(@as(usize, 1), page.styles.count(page.memory));

    // Reset to default
    try s.setAttribute(.{ .reset_bold = {} });
    try testing.expect(s.cursor.style_id == 0);
    try testing.expectEqual(@as(usize, 0), page.styles.count(page.memory));
}

test "Screen style reset with unset" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, 80, 24, 1000);
    defer s.deinit();
    const page = s.cursor.page_offset.page.data;
    try testing.expectEqual(@as(usize, 0), page.styles.count(page.memory));

    // Set a new style
    try s.setAttribute(.{ .bold = {} });
    try testing.expect(s.cursor.style_id != 0);
    try testing.expectEqual(@as(usize, 1), page.styles.count(page.memory));

    // Reset to default
    try s.setAttribute(.{ .unset = {} });
    try testing.expect(s.cursor.style_id == 0);
    try testing.expectEqual(@as(usize, 0), page.styles.count(page.memory));
}

test "Screen eraseRows active one line" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, 80, 24, 1000);
    defer s.deinit();

    try s.testWriteString("hello, world");
    s.eraseRows(.{ .active = .{} }, null, false);
    const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
    defer alloc.free(str);
    try testing.expectEqualStrings("", str);
}

test "Screen eraseRows active multi line" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, 80, 24, 1000);
    defer s.deinit();

    try s.testWriteString("hello\nworld");
    s.eraseRows(.{ .active = .{} }, null, false);
    const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
    defer alloc.free(str);
    try testing.expectEqualStrings("", str);
}

test "Screen eraseRows active styled line" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, 80, 24, 1000);
    defer s.deinit();

    try s.setAttribute(.{ .bold = {} });
    try s.testWriteString("hello world");
    try s.setAttribute(.{ .unset = {} });

    // We should have one style
    const page = s.cursor.page_offset.page.data;
    try testing.expectEqual(@as(usize, 1), page.styles.count(page.memory));

    s.eraseRows(.{ .active = .{} }, null, false);

    // We should have none because active cleared it
    try testing.expectEqual(@as(usize, 0), page.styles.count(page.memory));

    const str = try s.dumpStringAlloc(alloc, .{ .screen = .{} });
    defer alloc.free(str);
    try testing.expectEqualStrings("", str);
}
