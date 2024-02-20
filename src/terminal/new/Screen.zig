const Screen = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const unicode = @import("../../unicode/main.zig");
const PageList = @import("PageList.zig");
const pagepkg = @import("page.zig");
const point = @import("point.zig");
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
    x: usize,
    y: usize,

    /// The "last column flag (LCF)" as its called. If this is set then the
    /// next character print will force a soft-wrap.
    pending_wrap: bool = false,

    /// The pointers into the page list where the cursor is currently
    /// located. This makes it faster to move the cursor.
    page_offset: PageList.RowOffset,
    page_row: *pagepkg.Row,
    page_cell: *pagepkg.Cell,
};

/// Initialize a new screen.
pub fn init(
    alloc: Allocator,
    cols: usize,
    rows: usize,
    max_scrollback: usize,
) !Screen {
    // Initialize our backing pages. This will initialize the viewport.
    var pages = try PageList.init(alloc, cols, rows, max_scrollback);
    errdefer pages.deinit();

    // The viewport is guaranteed to exist, so grab it so we can setup
    // our initial cursor.
    const page_offset = pages.rowOffset(.{ .active = .{ .x = 0, .y = 0 } });
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

        if (blank_rows > 0) {
            for (0..blank_rows) |_| try writer.writeByte('\n');
            blank_rows = 0;
        }

        // TODO: handle wrap
        blank_rows += 1;

        for (cells) |cell| {
            // TODO: handle blanks between chars
            if (cell.codepoint == 0) break;
            try writer.print("{u}", .{cell.codepoint});
        }
    }
}

fn dumpStringAlloc(
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
    //try testing.expectEqualStrings("hello, world", str);
}
