//! Maintains a linked list of pages to make up a terminal screen
//! and provides higher level operations on top of those pages to
//! make it slightly easier to work with.
const PageList = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const point = @import("point.zig");
const pagepkg = @import("page.zig");
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

/// The list of pages in the screen. These are expected to be in order
/// where the first page is the topmost page (scrollback) and the last is
/// the bottommost page (the current active page).
const List = std.DoublyLinkedList(Page);

/// The memory pool we get page nodes from.
const Pool = std.heap.MemoryPool(List.Node);

/// The allocator to use for pages.
alloc: Allocator,

/// The memory pool we get page nodes for the linked list from.
pool: Pool,

/// The list of pages in the screen.
pages: List,

/// The top-left of certain parts of the screen that are frequently
/// accessed so we don't have to traverse the linked list to find them.
///
/// For other tags, don't need this:
///   - screen: pages.first
///   - history: active row minus one
///
viewport: RowOffset,
active: RowOffset,

/// The current desired screen dimensions. I say "desired" because individual
/// pages may still be a different size and not yet reflowed since we lazily
/// reflow text.
cols: usize,
rows: usize,

pub fn init(
    alloc: Allocator,
    cols: usize,
    rows: usize,
    max_scrollback: usize,
) !PageList {
    _ = max_scrollback;

    // The screen starts with a single page that is the entire viewport,
    // and we'll split it thereafter if it gets too large and add more as
    // necessary.
    var pool = try Pool.initPreheated(alloc, page_preheat);
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

    var page_list: List = .{};
    page_list.prepend(page);

    return .{
        .alloc = alloc,
        .cols = cols,
        .rows = rows,
        .pool = pool,
        .pages = page_list,
        .viewport = .{ .page = page },
        .active = .{ .page = page },
    };
}

pub fn deinit(self: *PageList) void {
    // Deallocate all the pages. We don't need to deallocate the list or
    // nodes because they all reside in the pool.
    while (self.pages.popFirst()) |node| node.data.deinit(self.alloc);
    self.pool.deinit();
}

/// Get the top-left of the screen for the given tag.
pub fn rowOffset(self: *const PageList, pt: point.Point) RowOffset {
    // TODO: assert the point is valid

    // This should never return null because we assert the point is valid.
    return (switch (pt) {
        .active => |v| self.active.forward(v.y),
        .viewport => |v| self.viewport.forward(v.y),
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
        .viewport => self.viewport,
        .screen, .history => .{ .page = self.pages.first.? },
    };
}

/// Represents some y coordinate within the screen. Since pages can
/// be split at any row boundary, getting some Y-coordinate within
/// any part of the screen may map to a different page and row offset
/// than the original y-coordinate. This struct represents that mapping.
pub const RowOffset = struct {
    page: *List.Node,
    row_offset: usize = 0,

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
    fn forward(self: RowOffset, idx: usize) ?RowOffset {
        // Index fits within this page
        var rows = self.page.data.capacity.rows - self.row_offset;
        if (idx < rows) return .{
            .page = self.page,
            .row_offset = idx + self.row_offset,
        };

        // Need to traverse page links to find the page
        var page: *List.Node = self.page;
        var idx_left: usize = idx;
        while (idx_left >= rows) {
            idx_left -= rows;
            page = page.next orelse return null;
            rows = page.data.capacity.rows;
        }

        return .{ .page = page, .row_offset = idx_left };
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
}
