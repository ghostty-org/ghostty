const Screen = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const unicode = @import("../../unicode/main.zig");
const pagepkg = @import("page.zig");
const Page = pagepkg.Page;

// Some magic constants we use that could be tweaked...

/// The number of PageList.Nodes we preheat the pool with. A node is
/// a very small struct so we can afford to preheat many, but the exact
/// number is uncertain. Any number too large is wasting memory, any number
/// too small will cause the pool to have to allocate more memory later.
/// This should be set to some reasonable minimum that we expect a terminal
/// window to scroll into quickly.
const page_preheat = 4;

/// The default number of unique styles per page we expect. It is currently
/// "32" because anecdotally amongst a handful of beta testers, no one
/// under normal terminal use ever used more than 32 unique styles in a
/// single page. We found outliers but it was rare enough that we could
/// allocate those when necessary.
const page_default_styles = 32;

/// The list of pages in the screen. These are expected to be in order
/// where the first page is the topmost page (scrollback) and the last is
/// the bottommost page (the current active page).
const PageList = std.DoublyLinkedList(Page);

/// The memory pool we get page nodes from.
const PagePool = std.heap.MemoryPool(PageList.Node);

/// The general purpose allocator to use for all memory allocations.
/// Unfortunately some screen operations do require allocation.
alloc: Allocator,

/// The memory pool we get page nodes for the linked list from.
page_pool: PagePool,

/// The list of pages in the screen.
pages: PageList,

/// The page that contains the top of the current viewport and the row
/// within that page that is the top of the viewport (0-indexed).
viewport: *PageList.Node,
viewport_row: usize,

/// The current cursor position
cursor: Cursor,

/// The current desired screen dimensions. I say "desired" because individual
/// pages may still be a different size and not yet reflowed since we lazily
/// reflow text.
cols: usize,
rows: usize,

/// The cursor position.
const Cursor = struct {
    // The x/y position within the viewport.
    x: usize,
    y: usize,

    /// The "last column flag (LCF)" as its called. If this is set then the
    /// next character print will force a soft-wrap.
    pending_wrap: bool = false,

    // The page that the cursor is on and the offset into that page that
    // the current y exists.
    page: *PageList.Node,
    page_row: usize,
    page_row_ptr: *pagepkg.Row,
    page_cell_ptr: *pagepkg.Cell,
};

/// Initialize a new screen.
pub fn init(
    alloc: Allocator,
    cols: usize,
    rows: usize,
    max_scrollback: usize,
) !Screen {
    _ = max_scrollback;

    // The screen starts with a single page that is the entire viewport,
    // and we'll split it thereafter if it gets too large and add more as
    // necessary.
    var pool = try PagePool.initPreheated(alloc, page_preheat);
    errdefer pool.deinit();

    var page = try pool.create();
    // no errdefer because the pool deinit will clean up the page

    page.* = .{
        .data = try Page.init(alloc, .{
            .cols = cols,
            .rows = rows,
            .styles = page_default_styles,
        }),
    };
    errdefer page.data.deinit(alloc);

    var page_list: PageList = .{};
    page_list.prepend(page);

    const cursor_row_ptr, const cursor_cell_ptr = ptr: {
        const rac = page.data.getRowAndCell(0, 0);
        break :ptr .{ rac.row, rac.cell };
    };

    return .{
        .alloc = alloc,
        .cols = cols,
        .rows = rows,
        .page_pool = pool,
        .pages = page_list,
        .viewport = page,
        .viewport_row = 0,
        .cursor = .{
            .x = 0,
            .y = 0,
            .page = page,
            .page_row = 0,
            .page_row_ptr = cursor_row_ptr,
            .page_cell_ptr = cursor_cell_ptr,
        },
    };
}

pub fn deinit(self: *Screen) void {
    // Deallocate all the pages. We don't need to deallocate the list or
    // nodes because they all reside in the pool.
    while (self.pages.popFirst()) |node| node.data.deinit(self.alloc);
    self.page_pool.deinit();
}

fn testWriteString(self: *Screen, text: []const u8) !void {
    const view = try std.unicode.Utf8View.init(text);
    var iter = view.iterator();
    while (iter.nextCodepoint()) |c| {
        if (self.cursor.x == self.cols) {
            @panic("wrap not implemented");
        }

        const width: usize = if (c <= 0xFF) 1 else @intCast(unicode.table.get(c).width);
        if (width == 0) {
            @panic("zero-width todo");
        }

        assert(width == 1 or width == 2);
        switch (width) {
            1 => {
                self.cursor.page_cell_ptr.codepoint = c;
                self.cursor.x += 1;
                if (self.cursor.x < self.cols) {
                    const cell_ptr: [*]pagepkg.Cell = @ptrCast(self.cursor.page_cell_ptr);
                    self.cursor.page_cell_ptr = @ptrCast(cell_ptr + 1);
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
}
