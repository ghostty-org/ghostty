const Screen = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
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

/// The cursor position.
const Cursor = struct {
    // The x/y position within the viewport.
    x: usize = 0,
    y: usize = 0,

    // The page that the cursor is on and the offset into that page that
    // the current y exists.
    page: *PageList.Node,
    page_row: usize,
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

    return .{
        .alloc = alloc,
        .page_pool = pool,
        .pages = page_list,
        .viewport = page,
        .viewport_row = 0,
    };
}

pub fn deinit(self: *Screen) void {
    // Deallocate all the pages. We don't need to deallocate the list or
    // nodes because they all reside in the pool.
    while (self.pages.popFirst()) |node| node.data.deinit(self.alloc);
    self.page_pool.deinit();
}

test {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try Screen.init(alloc, 80, 24, 1000);
    defer s.deinit();
}
