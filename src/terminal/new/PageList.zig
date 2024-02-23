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

/// The default number of unique styles per page we expect. It is currently
/// "32" because anecdotally amongst a handful of beta testers, no one
/// under normal terminal use ever used more than 32 unique styles in a
/// single page. We found outliers but it was rare enough that we could
/// allocate those when necessary.
const page_default_styles = 32;

/// Minimum rows we ever initialize a page with. This is wasted memory if
/// too large, but saves us from allocating too many pages when a terminal
/// is small. It also lets us scroll more before we have to allocate more.
/// Tne number 100 is arbitrary. I'm open to changing it if we find a
/// better number.
const page_min_rows: size.CellCountInt = 100;

/// The list of pages in the screen. These are expected to be in order
/// where the first page is the topmost page (scrollback) and the last is
/// the bottommost page (the current active page).
const List = std.DoublyLinkedList(Page);

/// The memory pool we get page nodes from.
const Pool = std.heap.MemoryPool(List.Node);

const std_capacity = pagepkg.std_capacity;
const std_layout = Page.layout(std_capacity);
const PagePool = std.heap.MemoryPoolAligned([std_layout.total_size]u8, std.mem.page_size);

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
active: RowOffset,

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
    // no errdefer because the pool deinit will clean up the page
    const page_buf = try page_pool.create();
    if (comptime std.debug.runtime_safety) @memset(page_buf, 0);

    page.* = .{
        .data = Page.initBuf(
            OffsetBuf.init(page_buf),
            Page.layout(try std_capacity.adjust(.{ .cols = cols })),
        ),
    };
    errdefer page.data.deinit(alloc);
    page.data.size.rows = rows;

    var page_list: List = .{};
    page_list.prepend(page);

    // for (0..1) |_| {
    //     const p = try pool.create();
    //     p.* = .{
    //         .data = try Page.init(alloc, .{
    //             .cols = cols,
    //             .rows = @max(rows, page_min_rows),
    //             .styles = page_default_styles,
    //         }),
    //     };
    //     p.data.size.rows = 0;
    //     page_list.append(p);
    // }

    return .{
        .alloc = alloc,
        .cols = cols,
        .rows = rows,
        .pool = pool,
        .page_pool = page_pool,
        .pages = page_list,
        .viewport = .{ .active = {} },
        .active = .{ .page = page },
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
pub fn getCell(self: *const PageList, pt: point.Point) ?Cell {
    const row = self.getTopLeft(pt).forward(pt.y) orelse return null;
    const rac = row.page.data.getRowAndCell(row.row_offset, pt.x);
    return .{
        .page = row.page,
        .row = rac.row,
        .cell = rac.cell,
        .row_idx = row.row_offset,
        .col_idx = pt.x,
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
        .active => self.active,
        .screen, .history => .{ .page = self.pages.first.? },
        .viewport => switch (self.viewport) {
            .active => self.active,
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

    // Viewport is setup
    try testing.expect(s.viewport == .active);
    try testing.expect(s.active.page == s.pages.first);
    try testing.expect(s.active.page.next == null);
    try testing.expect(s.active.row_offset == 0);
    try testing.expect(s.active.page.data.size.cols == 80);
    try testing.expect(s.active.page.data.size.rows == 24);
}
