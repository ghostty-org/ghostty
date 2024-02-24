//! Maintains a linked list of pages to make up a terminal screen
//! and provides higher level operations on top of those pages to
//! make it slightly easier to work with.
const PageList = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const point = @import("point.zig");
const pagepkg = @import("page.zig");
const size = @import("size.zig");
const OffsetBuf = size.OffsetBuf;
const Page = pagepkg.Page;

/// The number of PageList.Nodes we preheat the pool with. A node is
/// a very small struct so we can afford to preheat many, but the exact
/// number is uncertain. Any number too large is wasting memory, any number
/// too small will cause the pool to have to allocate more memory later.
/// This should be set to some reasonable minimum that we expect a terminal
/// window to scroll into quickly.
const page_preheat = 4;

/// The list of pages in the screen. These are expected to be in order
/// where the first page is the topmost page (scrollback) and the last is
/// the bottommost page (the current active page).
const List = std.DoublyLinkedList(Page);

/// The memory pool we get page nodes from.
const Pool = std.heap.MemoryPool(List.Node);

const std_capacity = pagepkg.std_capacity;

/// The memory pool we use for page memory buffers. We use a separate pool
/// so we can allocate these with a page allocator. We have to use a page
/// allocator because we need memory that is zero-initialized and page-aligned.
const PagePool = std.heap.MemoryPoolAligned(
    [Page.layout(std_capacity).total_size]u8,
    std.mem.page_size,
);

/// The allocator to use for pages.
alloc: Allocator,

/// The memory pool we get page nodes for the linked list from.
pool: Pool,

page_pool: PagePool,

/// The list of pages in the screen.
pages: List,

/// The top-left of certain parts of the screen that are frequently
/// accessed so we don't have to traverse the linked list to find them.
///
/// For other tags, don't need this:
///   - screen: pages.first
///   - history: active row minus one
///
viewport: Viewport,

/// The current desired screen dimensions. I say "desired" because individual
/// pages may still be a different size and not yet reflowed since we lazily
/// reflow text.
cols: size.CellCountInt,
rows: size.CellCountInt,

/// The viewport location.
pub const Viewport = union(enum) {
    /// The viewport is pinned to the active area. By using a specific marker
    /// for this instead of tracking the row offset, we eliminate a number of
    /// memory writes making scrolling faster.
    active,
};

/// Initialize the page. The top of the first page in the list is always the
/// top of the active area of the screen (important knowledge for quickly
/// setting up cursors in Screen).
pub fn init(
    alloc: Allocator,
    cols: size.CellCountInt,
    rows: size.CellCountInt,
    max_scrollback: usize,
) !PageList {
    _ = max_scrollback;

    // The screen starts with a single page that is the entire viewport,
    // and we'll split it thereafter if it gets too large and add more as
    // necessary.
    var pool = try Pool.initPreheated(alloc, page_preheat);
    errdefer pool.deinit();

    var page_pool = try PagePool.initPreheated(std.heap.page_allocator, page_preheat);
    errdefer page_pool.deinit();

    var page = try pool.create();
    const page_buf = try page_pool.create();
    if (comptime std.debug.runtime_safety) @memset(page_buf, 0);
    // no errdefer because the pool deinit will clean these up

    // Initialize the first set of pages to contain our viewport so that
    // the top of the first page is always the active area.
    page.* = .{
        .data = Page.initBuf(
            OffsetBuf.init(page_buf),
            Page.layout(try std_capacity.adjust(.{ .cols = cols })),
        ),
    };
    assert(page.data.capacity.rows >= rows); // todo: handle this
    page.data.size.rows = rows;

    var page_list: List = .{};
    page_list.prepend(page);

    return .{
        .alloc = alloc,
        .cols = cols,
        .rows = rows,
        .pool = pool,
        .page_pool = page_pool,
        .pages = page_list,
        .viewport = .{ .active = {} },
    };
}

pub fn deinit(self: *PageList) void {
    // Deallocate all the pages. We don't need to deallocate the list or
    // nodes because they all reside in the pool.
    self.page_pool.deinit();
    self.pool.deinit();
}

pub fn grow(self: *PageList) !*List.Node {
    const next_page = try self.createPage();
    // we don't errdefer this because we've added it to the linked
    // list and its fine to have dangling unused pages.
    self.pages.append(next_page);
    return next_page;
}

/// Create a new page node. This does not add it to the list.
fn createPage(self: *PageList) !*List.Node {
    var page = try self.pool.create();
    errdefer self.pool.destroy(page);

    const page_buf = try self.page_pool.create();
    errdefer self.page_pool.destroy(page_buf);
    if (comptime std.debug.runtime_safety) @memset(page_buf, 0);

    page.* = .{
        .data = Page.initBuf(
            OffsetBuf.init(page_buf),
            Page.layout(try std_capacity.adjust(.{ .cols = self.cols })),
        ),
    };
    page.data.size.rows = 0;

    return page;
}

/// Get the top-left of the screen for the given tag.
pub fn rowOffset(self: *const PageList, pt: point.Point) RowOffset {
    // TODO: assert the point is valid

    // This should never return null because we assert the point is valid.
    return (switch (pt) {
        .active => |v| self.active.forward(v.y),
        .viewport => |v| switch (self.viewport) {
            .active => self.active.forward(v.y),
        },
        .screen, .history => |v| offset: {
            const tl: RowOffset = .{ .page = self.pages.first.? };
            break :offset tl.forward(v.y);
        },
    }).?;
}

/// Get the cell at the given point, or null if the cell does not
/// exist or is out of bounds.
///
/// Warning: this is slow and should not be used in performance critical paths
pub fn getCell(self: *const PageList, pt: point.Point) ?Cell {
    const row = self.getTopLeft(pt).forward(pt.coord().y) orelse return null;
    const rac = row.page.data.getRowAndCell(pt.coord().x, row.row_offset);
    return .{
        .page = row.page,
        .row = rac.row,
        .cell = rac.cell,
        .row_idx = row.row_offset,
        .col_idx = pt.coord().x,
    };
}

pub const RowIterator = struct {
    row: ?RowOffset = null,
    limit: ?usize = null,

    pub fn next(self: *RowIterator) ?RowOffset {
        const row = self.row orelse return null;
        self.row = row.forward(1);
        if (self.limit) |*limit| {
            limit.* -= 1;
            if (limit.* == 0) self.row = null;
        }

        return row;
    }
};

/// Create an interator that can be used to iterate all the rows in
/// a region of the screen from the given top-left. The tag of the
/// top-left point will also determine the end of the iteration,
/// so convert from one reference point to another to change the
/// iteration bounds.
pub fn rowIterator(
    self: *const PageList,
    tl_pt: point.Point,
) RowIterator {
    const tl = self.getTopLeft(tl_pt);

    // TODO: limits
    return .{ .row = tl.forward(tl_pt.coord().y) };
}

/// Get the top-left of the screen for the given tag.
fn getTopLeft(self: *const PageList, tag: point.Tag) RowOffset {
    return switch (tag) {
        // The full screen or history is always just the first page.
        .screen, .history => .{ .page = self.pages.first.? },

        .viewport => switch (self.viewport) {
            // If the viewport is in the active area then its the same as active.
            .active => self.getTopLeft(.active),
        },

        // The active area is calculated backwards from the last page.
        // This makes getting the active top left slower but makes scrolling
        // much faster because we don't need to update the top left. Under
        // heavy load this makes a measurable difference.
        .active => active: {
            var page = self.pages.last.?;
            var rem = self.rows;
            while (rem > page.data.size.rows) {
                rem -= page.data.size.rows;
                page = page.prev.?; // assertion: we always have enough rows for active
            }

            break :active .{
                .page = page,
                .row_offset = page.data.size.rows - rem,
            };
        },
    };
}

/// Represents some y coordinate within the screen. Since pages can
/// be split at any row boundary, getting some Y-coordinate within
/// any part of the screen may map to a different page and row offset
/// than the original y-coordinate. This struct represents that mapping.
pub const RowOffset = struct {
    page: *List.Node,
    row_offset: usize = 0,

    pub fn eql(self: RowOffset, other: RowOffset) bool {
        return self.page == other.page and self.row_offset == other.row_offset;
    }

    pub fn rowAndCell(self: RowOffset, x: usize) struct {
        row: *pagepkg.Row,
        cell: *pagepkg.Cell,
    } {
        const rac = self.page.data.getRowAndCell(x, self.row_offset);
        return .{ .row = rac.row, .cell = rac.cell };
    }

    /// Get the row at the given row index from this Topleft. This
    /// may require traversing into the next page if the row index
    /// is greater than the number of rows in this page.
    ///
    /// This will return null if the row index is out of bounds.
    pub fn forward(self: RowOffset, idx: usize) ?RowOffset {
        return switch (self.forwardOverflow(idx)) {
            .offset => |v| v,
            .overflow => null,
        };
    }

    /// TODO: docs
    pub fn backward(self: RowOffset, idx: usize) ?RowOffset {
        return switch (self.backwardOverflow(idx)) {
            .offset => |v| v,
            .overflow => null,
        };
    }

    /// Move the offset forward n rows. If the offset goes beyond the
    /// end of the screen, return the overflow amount.
    fn forwardOverflow(self: RowOffset, n: usize) union(enum) {
        offset: RowOffset,
        overflow: struct {
            end: RowOffset,
            remaining: usize,
        },
    } {
        // Index fits within this page
        const rows = self.page.data.size.rows - (self.row_offset + 1);
        if (n <= rows) return .{ .offset = .{
            .page = self.page,
            .row_offset = n + self.row_offset,
        } };

        // Need to traverse page links to find the page
        var page: *List.Node = self.page;
        var n_left: usize = n - rows;
        while (true) {
            page = page.next orelse return .{ .overflow = .{
                .end = .{ .page = page, .row_offset = page.data.size.rows - 1 },
                .remaining = n_left,
            } };
            if (n_left <= page.data.size.rows) return .{ .offset = .{
                .page = page,
                .row_offset = n_left - 1,
            } };
            n_left -= page.data.size.rows;
        }
    }

    /// Move the offset backward n rows. If the offset goes beyond the
    /// start of the screen, return the overflow amount.
    fn backwardOverflow(self: RowOffset, n: usize) union(enum) {
        offset: RowOffset,
        overflow: struct {
            end: RowOffset,
            remaining: usize,
        },
    } {
        // Index fits within this page
        if (n >= self.row_offset) return .{ .offset = .{
            .page = self.page,
            .row_offset = self.row_offset - n,
        } };

        // Need to traverse page links to find the page
        var page: *List.Node = self.page;
        var n_left: usize = n - self.row_offset;
        while (true) {
            page = page.prev orelse return .{ .overflow = .{
                .end = .{ .page = page, .row_offset = 0 },
                .remaining = n_left,
            } };
            if (n_left <= page.data.size.rows) return .{ .offset = .{
                .page = page,
                .row_offset = page.data.size.rows - n_left,
            } };
            n_left -= page.data.size.rows;
        }
    }
};

const Cell = struct {
    page: *List.Node,
    row: *pagepkg.Row,
    cell: *pagepkg.Cell,
    row_idx: usize,
    col_idx: usize,
};

test "PageList" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, 1000);
    defer s.deinit();
    try testing.expect(s.viewport == .active);
    try testing.expect(s.pages.first != null);

    // Active area should be the top
    try testing.expectEqual(RowOffset{
        .page = s.pages.first.?,
        .row_offset = 0,
    }, s.getTopLeft(.active));
}
