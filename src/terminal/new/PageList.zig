//! Maintains a linked list of pages to make up a terminal screen
//! and provides higher level operations on top of those pages to
//! make it slightly easier to work with.
const PageList = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const point = @import("point.zig");
const pagepkg = @import("page.zig");
const stylepkg = @import("style.zig");
const size = @import("size.zig");
const OffsetBuf = size.OffsetBuf;
const Page = pagepkg.Page;
const Row = pagepkg.Row;

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

/// Byte size of the total amount of allocated pages. Note this does
/// not include the total allocated amount in the pool which may be more
/// than this due to preheating.
page_size: usize,

/// Maximum size of the page allocation in bytes. This only includes pages
/// that are used ONLY for scrollback. If the active area is still partially
/// in a page that also includes scrollback, then that page is not included.
max_size: usize,

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

    /// The viewport is pinned to the top of the screen, or the farthest
    /// back in the scrollback history.
    top,

    /// The viewport is pinned to an exact row offset. If this page is
    /// deleted (i.e. due to pruning scrollback), then the viewport will
    /// stick to the top.
    exact: RowOffset,
};

/// Initialize the page. The top of the first page in the list is always the
/// top of the active area of the screen (important knowledge for quickly
/// setting up cursors in Screen).
///
/// max_size is the maximum number of bytes that will be allocated for
/// pages. If this is smaller than the bytes required to show the viewport
/// then max_size will be ignored and the viewport will be shown, but no
/// scrollback will be created. max_size is always rounded down to the nearest
/// terminal page size (not virtual memory page), otherwise we would always
/// slightly exceed max_size in the limits.
///
/// If max_size is null then there is no defined limit and the screen will
/// grow forever. In reality, the limit is set to the byte limit that your
/// computer can address in memory. If you somehow require more than that
/// (due to disk paging) then please contribute that yourself and perhaps
/// search deep within yourself to find out why you need that.
pub fn init(
    alloc: Allocator,
    cols: size.CellCountInt,
    rows: size.CellCountInt,
    max_size: ?usize,
) !PageList {
    // The screen starts with a single page that is the entire viewport,
    // and we'll split it thereafter if it gets too large and add more as
    // necessary.
    var pool = try Pool.initPreheated(alloc, page_preheat);
    errdefer pool.deinit();

    var page_pool = try PagePool.initPreheated(std.heap.page_allocator, page_preheat);
    errdefer page_pool.deinit();

    var page = try pool.create();
    const page_buf = try page_pool.create();
    // no errdefer because the pool deinit will clean these up

    // In runtime safety modes we have to memset because the Zig allocator
    // interface will always memset to 0xAA for undefined. In non-safe modes
    // we use a page allocator and the OS guarantees zeroed memory.
    if (comptime std.debug.runtime_safety) @memset(page_buf, 0);

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
    const page_size = page_buf.len;

    // The max size has to be adjusted to at least fit one viewport.
    // We use item_size*2 because the active area can always span two
    // pages as we scroll, otherwise we'd have to constantly copy in the
    // small limit case.
    const max_size_actual = @max(
        max_size orelse std.math.maxInt(usize),
        PagePool.item_size * 2,
    );

    return .{
        .alloc = alloc,
        .cols = cols,
        .rows = rows,
        .pool = pool,
        .page_pool = page_pool,
        .pages = page_list,
        .page_size = page_size,
        .max_size = max_size_actual,
        .viewport = .{ .active = {} },
    };
}

pub fn deinit(self: *PageList) void {
    // Deallocate all the pages. We don't need to deallocate the list or
    // nodes because they all reside in the pool.
    self.page_pool.deinit();
    self.pool.deinit();
}

/// Scroll options.
pub const Scroll = union(enum) {
    /// Scroll to the active area. This is also sometimes referred to as
    /// the "bottom" of the screen. This makes it so that the end of the
    /// screen is fully visible since the active area is the bottom
    /// rows/cols of the screen.
    active,

    /// Scroll to the top of the screen, which is the farthest back in
    /// the scrollback history.
    top,

    /// Scroll up (negative) or down (positive) by the given number of
    /// rows. This is clamped to the "top" and "active" top left.
    delta_row: isize,
};

/// Scroll the viewport. This will never create new scrollback, allocate
/// pages, etc. This can only be used to move the viewport within the
/// previously allocated pages.
pub fn scroll(self: *PageList, behavior: Scroll) void {
    switch (behavior) {
        .active => self.viewport = .{ .active = {} },
        .top => self.viewport = .{ .top = {} },
        .delta_row => |n| {
            if (n == 0) return;

            const top = self.getTopLeft(.viewport);
            const offset: RowOffset = if (n < 0) switch (top.backwardOverflow(@intCast(-n))) {
                .offset => |v| v,
                .overflow => |v| v.end,
            } else forward: {
                // Not super happy with the logic to scroll forward. I think
                // this is pretty slow, but it is human-driven (scrolling
                // this way) so hyper speed isn't strictly necessary. Still,
                // it feels bad.

                const forward_offset = switch (top.forwardOverflow(@intCast(n))) {
                    .offset => |v| v,
                    .overflow => |v| v.end,
                };

                var final_offset: ?RowOffset = forward_offset;

                // Ensure we have at least rows rows in the viewport. There
                // is probably a smarter way to do this.
                var page = self.pages.last.?;
                var rem = self.rows;
                while (rem > page.data.size.rows) {
                    rem -= page.data.size.rows;

                    // If we see our forward page here then we know its
                    // beyond the active area and we can set final null.
                    if (page == forward_offset.page) final_offset = null;

                    page = page.prev.?; // assertion: we always have enough rows for active
                }
                const active_offset = .{ .page = page, .row_offset = page.data.size.rows - rem };

                // If we have a final still and we're on the same page
                // but the active area is before the forward area, then
                // we can use the active area.
                if (final_offset != null and
                    active_offset.page == forward_offset.page and
                    forward_offset.row_offset > active_offset.row_offset)
                {
                    final_offset = active_offset;
                }

                break :forward final_offset orelse active_offset;
            };

            self.viewport = .{ .exact = offset };
        },
    }
}

/// Grow the active area by exactly one row.
///
/// This may allocate, but also may not if our current page has more
/// capacity we can use. This will prune scrollback if necessary to
/// adhere to max_size.
///
/// This returns the newly allocated page node if there is one.
pub fn grow(self: *PageList) !?*List.Node {
    const last = self.pages.last.?;
    if (last.data.capacity.rows > last.data.size.rows) {
        // Fast path: we have capacity in the last page.
        last.data.size.rows += 1;
        return null;
    }

    // Slower path: we have no space, we need to allocate a new page.

    // If allocation would exceed our max size, we prune the first page.
    // We don't need to reallocate because we can simply reuse that first
    // page.
    if (self.page_size + PagePool.item_size > self.max_size) {
        const layout = Page.layout(try std_capacity.adjust(.{ .cols = self.cols }));

        // Get our first page and reset it to prepare for reuse.
        const first = self.pages.popFirst().?;
        assert(first != last);
        const buf = first.data.memory;
        @memset(buf, 0);

        // Initialize our new page and reinsert it as the last
        first.data = Page.initBuf(OffsetBuf.init(buf), layout);
        first.data.size.rows = 1;
        self.pages.insertAfter(last, first);

        // In this case we do NOT need to update page_size because
        // we're reusing an existing page so nothing has changed.

        return first;
    }

    // We need to allocate a new memory buffer.
    const next_page = try self.createPage();
    // we don't errdefer this because we've added it to the linked
    // list and its fine to have dangling unused pages.
    self.pages.append(next_page);
    next_page.data.size.rows = 1;

    // Accounting
    self.page_size += PagePool.item_size;
    assert(self.page_size <= self.max_size);

    return next_page;
}

/// Create a new page node. This does not add it to the list and this
/// does not do any memory size accounting with max_size/page_size.
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

pub const RowChunkIterator = struct {
    row: ?RowOffset = null,
    limit: Limit = .none,

    const Limit = union(enum) {
        none,
        count: usize,
        row: RowOffset,
    };

    pub fn next(self: *RowChunkIterator) ?Chunk {
        // Get our current row location
        const row = self.row orelse return null;

        return switch (self.limit) {
            .none => none: {
                // If we have no limit, then we consume this entire page. Our
                // next row is the next page.
                self.row = next: {
                    const next_page = row.page.next orelse break :next null;
                    break :next .{ .page = next_page };
                };

                break :none .{
                    .page = row.page,
                    .start = row.row_offset,
                    .end = row.page.data.size.rows,
                };
            },

            .count => |*limit| count: {
                assert(limit.* > 0); // should be handled already
                const len = @min(row.page.data.size.rows - row.row_offset, limit.*);
                if (len > limit.*) {
                    self.row = row.forward(len);
                    limit.* -= len;
                } else {
                    self.row = null;
                }

                break :count .{
                    .page = row.page,
                    .start = row.row_offset,
                    .end = row.row_offset + len,
                };
            },

            .row => |limit_row| row: {
                // If this is not the same page as our limit then we
                // can consume the entire page.
                if (limit_row.page != row.page) {
                    self.row = next: {
                        const next_page = row.page.next orelse break :next null;
                        break :next .{ .page = next_page };
                    };

                    break :row .{
                        .page = row.page,
                        .start = row.row_offset,
                        .end = row.page.data.size.rows,
                    };
                }

                // If this is the same page then we only consume up to
                // the limit row.
                self.row = null;
                if (row.row_offset > limit_row.row_offset) return null;
                break :row .{
                    .page = row.page,
                    .start = row.row_offset,
                    .end = limit_row.row_offset + 1,
                };
            },
        };
    }

    pub const Chunk = struct {
        page: *List.Node,
        start: usize,
        end: usize,

        pub fn rows(self: Chunk) []Row {
            const rows_ptr = self.page.data.rows.ptr(self.page.data.memory);
            return rows_ptr[self.start..self.end];
        }
    };
};

/// Return an iterator that iterates through the rows in the tagged area
/// of the point. The iterator returns row "chunks", which are the largest
/// contiguous set of rows in a single backing page for a given portion of
/// the point region.
///
/// This is a more efficient way to iterate through the data in a region,
/// since you can do simple pointer math and so on.
///
/// If bl_pt is non-null, iteration will stop at the bottom left point
/// (inclusive). If bl_pt is null, the entire region specified by the point
/// tag will be iterated over. tl_pt and bl_pt must be the same tag, and
/// bl_pt must be greater than or equal to tl_pt.
pub fn rowChunkIterator(
    self: *const PageList,
    tl_pt: point.Point,
    bl_pt: ?point.Point,
) RowChunkIterator {
    // TODO: bl_pt assertions

    const tl = self.getTopLeft(tl_pt);
    const limit: RowChunkIterator.Limit = limit: {
        if (bl_pt) |pt| {
            const bl = self.getTopLeft(pt);
            break :limit .{ .row = bl.forward(pt.coord().y).? };
        }

        break :limit switch (tl_pt) {
            // These always go to the end of the screen.
            .screen, .active => .{ .none = {} },

            // Viewport always is rows long
            .viewport => .{ .count = self.rows },

            // History goes to the top of the active area. This is more expensive
            // to calculate but also more rare of a thing to iterate over.
            .history => .{ .row = self.getTopLeft(.active) },
        };
    };

    return .{ .row = tl.forward(tl_pt.coord().y), .limit = limit };
}

/// Get the top-left of the screen for the given tag.
fn getTopLeft(self: *const PageList, tag: point.Tag) RowOffset {
    return switch (tag) {
        // The full screen or history is always just the first page.
        .screen, .history => .{ .page = self.pages.first.? },

        .viewport => switch (self.viewport) {
            .active => self.getTopLeft(.active),
            .top => self.getTopLeft(.screen),
            .exact => |v| v,
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

/// The total rows in the screen. This is the actual row count currently
/// and not a capacity or maximum.
///
/// This is very slow, it traverses the full list of pages to count the
/// rows, so it is not pub. This is only used for testing/debugging.
fn totalRows(self: *const PageList) usize {
    var rows: usize = 0;
    var page = self.pages.first;
    while (page) |p| {
        rows += p.data.size.rows;
        page = p.next;
    }

    return rows;
}

/// Grow the number of rows available in the page list by n.
/// This is only used for testing so it isn't optimized.
fn growRows(self: *PageList, n: usize) !void {
    var page = self.pages.last.?;
    var n_rem: usize = n;
    if (page.data.size.rows < page.data.capacity.rows) {
        const add = @min(n_rem, page.data.capacity.rows - page.data.size.rows);
        page.data.size.rows += add;
        if (n_rem == add) return;
        n_rem -= add;
    }

    while (n_rem > 0) {
        page = (try self.grow()).?;
        const add = @min(n_rem, page.data.capacity.rows);
        page.data.size.rows = add;
        n_rem -= add;
    }
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
        if (n <= self.row_offset) return .{ .offset = .{
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

    /// Get the cell style.
    ///
    /// Not meant for non-test usage since this is inefficient.
    pub fn style(self: Cell) stylepkg.Style {
        if (self.cell.style_id == stylepkg.default_id) return .{};
        return self.page.data.styles.lookupId(
            self.page.data.memory,
            self.cell.style_id,
        ).?.*;
    }

    /// Gets the screen point for the given cell.
    ///
    /// This is REALLY expensive/slow so it isn't pub. This was built
    /// for debugging and tests. If you have a need for this outside of
    /// this file then consider a different approach and ask yourself very
    /// carefully if you really need this.
    pub fn screenPoint(self: Cell) point.Point {
        var y: usize = self.row_idx;
        var page = self.page;
        while (page.prev) |prev| {
            y += prev.data.size.rows;
            page = prev;
        }

        return .{ .screen = .{
            .x = self.col_idx,
            .y = y,
        } };
    }
};

test "PageList" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();
    try testing.expect(s.viewport == .active);
    try testing.expect(s.pages.first != null);
    try testing.expectEqual(@as(usize, s.rows), s.totalRows());

    // Active area should be the top
    try testing.expectEqual(RowOffset{
        .page = s.pages.first.?,
        .row_offset = 0,
    }, s.getTopLeft(.active));
}

test "PageList active after grow" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();
    try testing.expectEqual(@as(usize, s.rows), s.totalRows());

    try s.growRows(10);
    try testing.expectEqual(@as(usize, s.rows + 10), s.totalRows());

    // Make sure all points make sense
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 10,
        } }, pt);
    }
    {
        const pt = s.getCell(.{ .screen = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, pt);
    }
    {
        const pt = s.getCell(.{ .active = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 10,
        } }, pt);
    }
}

test "PageList scroll top" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();
    try s.growRows(10);

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 10,
        } }, pt);
    }

    s.scroll(.{ .top = {} });

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, pt);
    }

    try s.growRows(10);
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, pt);
    }

    s.scroll(.{ .active = {} });
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 20,
        } }, pt);
    }
}

test "PageList scroll delta row back" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();
    try s.growRows(10);

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 10,
        } }, pt);
    }

    s.scroll(.{ .delta_row = -1 });

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 9,
        } }, pt);
    }

    try s.growRows(10);
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 9,
        } }, pt);
    }
}

test "PageList scroll delta row back overflow" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();
    try s.growRows(10);

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 10,
        } }, pt);
    }

    s.scroll(.{ .delta_row = -100 });

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, pt);
    }

    try s.growRows(10);
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, pt);
    }
}

test "PageList scroll delta row forward" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();
    try s.growRows(10);

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 10,
        } }, pt);
    }

    s.scroll(.{ .top = {} });
    s.scroll(.{ .delta_row = 2 });

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 2,
        } }, pt);
    }

    try s.growRows(10);
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 2,
        } }, pt);
    }
}

test "PageList scroll delta row forward into active" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();

    s.scroll(.{ .delta_row = 2 });

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, pt);
    }
}

test "PageList grow fit in capacity" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();

    // So we know we're using capacity to grow
    const last = &s.pages.last.?.data;
    try testing.expect(last.size.rows < last.capacity.rows);

    // Grow
    try testing.expect(try s.grow() == null);
    {
        const pt = s.getCell(.{ .active = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 1,
        } }, pt);
    }
}

test "PageList grow allocate" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();

    // Grow to capacity
    const last_node = s.pages.last.?;
    const last = &s.pages.last.?.data;
    for (0..last.capacity.rows - last.size.rows) |_| {
        try testing.expect(try s.grow() == null);
    }

    // Grow, should allocate
    const new = (try s.grow()).?;
    try testing.expect(s.pages.last.? == new);
    try testing.expect(last_node.next.? == new);
    {
        const cell = s.getCell(.{ .active = .{ .y = s.rows - 1 } }).?;
        try testing.expect(cell.page == new);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = last.capacity.rows,
        } }, cell.screenPoint());
    }
}

test "PageList grow prune scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Zero here forces minimum max size to effectively two pages.
    var s = try init(alloc, 80, 24, 0);
    defer s.deinit();

    // Grow to capacity
    const page1_node = s.pages.last.?;
    const page1 = page1_node.data;
    for (0..page1.capacity.rows - page1.size.rows) |_| {
        try testing.expect(try s.grow() == null);
    }

    // Grow and allocate one more page. Then fill that page up.
    const page2_node = (try s.grow()).?;
    const page2 = page2_node.data;
    for (0..page2.capacity.rows - page2.size.rows) |_| {
        try testing.expect(try s.grow() == null);
    }

    // Get our page size
    const old_page_size = s.page_size;

    // Next should create a new page, but it should reuse our first
    // page since we're at max size.
    const new = (try s.grow()).?;
    try testing.expect(s.pages.last.? == new);
    try testing.expectEqual(s.page_size, old_page_size);

    // Our first should now be page2 and our last should be page1
    try testing.expectEqual(page2_node, s.pages.first.?);
    try testing.expectEqual(page1_node, s.pages.last.?);
}

test "PageList rowChunkIterator single page" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();

    // The viewport should be within a single page
    try testing.expect(s.pages.first.?.next == null);

    // Iterate the active area
    var it = s.rowChunkIterator(.{ .active = .{} }, null);
    {
        const chunk = it.next().?;
        try testing.expect(chunk.page == s.pages.first.?);
        try testing.expectEqual(@as(usize, 0), chunk.start);
        try testing.expectEqual(@as(usize, s.rows), chunk.end);
    }

    // Should only have one chunk
    try testing.expect(it.next() == null);
}

test "PageList rowChunkIterator two pages" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();

    // Grow to capacity
    const page1_node = s.pages.last.?;
    const page1 = page1_node.data;
    for (0..page1.capacity.rows - page1.size.rows) |_| {
        try testing.expect(try s.grow() == null);
    }
    try testing.expect(try s.grow() != null);

    // Iterate the active area
    var it = s.rowChunkIterator(.{ .active = .{} }, null);
    {
        const chunk = it.next().?;
        try testing.expect(chunk.page == s.pages.first.?);
        const start = chunk.page.data.size.rows - s.rows + 1;
        try testing.expectEqual(start, chunk.start);
        try testing.expectEqual(chunk.page.data.size.rows, chunk.end);
    }
    {
        const chunk = it.next().?;
        try testing.expect(chunk.page == s.pages.last.?);
        const start: usize = 0;
        try testing.expectEqual(start, chunk.start);
        try testing.expectEqual(start + 1, chunk.end);
    }
    try testing.expect(it.next() == null);
}

test "PageList rowChunkIterator history two pages" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();

    // Grow to capacity
    const page1_node = s.pages.last.?;
    const page1 = page1_node.data;
    for (0..page1.capacity.rows - page1.size.rows) |_| {
        try testing.expect(try s.grow() == null);
    }
    try testing.expect(try s.grow() != null);

    // Iterate the active area
    var it = s.rowChunkIterator(.{ .history = .{} }, null);
    {
        const active_tl = s.getTopLeft(.active);
        const chunk = it.next().?;
        try testing.expect(chunk.page == s.pages.first.?);
        const start: usize = 0;
        try testing.expectEqual(start, chunk.start);
        try testing.expectEqual(active_tl.row_offset + 1, chunk.end);
    }
    try testing.expect(it.next() == null);
}
