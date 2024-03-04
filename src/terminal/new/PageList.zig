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
const Capacity = pagepkg.Capacity;
const Page = pagepkg.Page;
const Row = pagepkg.Row;

const log = std.log.scoped(.page_list);

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
const NodePool = std.heap.MemoryPool(List.Node);

const std_capacity = pagepkg.std_capacity;

/// The memory pool we use for page memory buffers. We use a separate pool
/// so we can allocate these with a page allocator. We have to use a page
/// allocator because we need memory that is zero-initialized and page-aligned.
const PagePool = std.heap.MemoryPoolAligned(
    [Page.layout(std_capacity).total_size]u8,
    std.mem.page_size,
);

/// The pool of memory used for a pagelist. This can be shared between
/// multiple pagelists but it is not threadsafe.
pub const MemoryPool = struct {
    nodes: NodePool,
    pages: PagePool,

    pub const ResetMode = std.heap.ArenaAllocator.ResetMode;

    pub fn init(
        gen_alloc: Allocator,
        page_alloc: Allocator,
        preheat: usize,
    ) !MemoryPool {
        var pool = try NodePool.initPreheated(gen_alloc, preheat);
        errdefer pool.deinit();
        var page_pool = try PagePool.initPreheated(page_alloc, preheat);
        errdefer page_pool.deinit();
        return .{ .nodes = pool, .pages = page_pool };
    }

    pub fn deinit(self: *MemoryPool) void {
        self.pages.deinit();
        self.nodes.deinit();
    }

    pub fn reset(self: *MemoryPool, mode: ResetMode) void {
        _ = self.pages.reset(mode);
        _ = self.nodes.reset(mode);
    }
};

/// The memory pool we get page nodes, pages from.
pool: MemoryPool,
pool_owned: bool,

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
    var pool = try MemoryPool.init(alloc, std.heap.page_allocator, page_preheat);

    var page = try pool.nodes.create();
    const page_buf = try pool.pages.create();
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
        .cols = cols,
        .rows = rows,
        .pool = pool,
        .pool_owned = true,
        .pages = page_list,
        .page_size = page_size,
        .max_size = max_size_actual,
        .viewport = .{ .active = {} },
    };
}

/// Deinit the pagelist. If you own the memory pool (used clonePool) then
/// this will reset the pool and retain capacity.
pub fn deinit(self: *PageList) void {
    // Deallocate all the pages. We don't need to deallocate the list or
    // nodes because they all reside in the pool.
    if (self.pool_owned) {
        self.pool.deinit();
    } else {
        self.pool.reset(.{ .retain_capacity = {} });
    }
}

/// Clone this pagelist from the top to bottom (inclusive).
///
/// The viewport is always moved to the top-left.
///
/// The cloned pagelist must contain at least enough rows for the active
/// area. If the region specified has less rows than the active area then
/// rows will be added to the bottom of the region to make up the difference.
pub fn clone(
    self: *const PageList,
    alloc: Allocator,
    top: point.Point,
    bot: ?point.Point,
) !PageList {
    // First, count our pages so our preheat is exactly what we need.
    var it = self.pageIterator(top, bot);
    const page_count: usize = page_count: {
        var count: usize = 0;
        while (it.next()) |_| count += 1;
        break :page_count count;
    };

    // Setup our pools
    var pool = try MemoryPool.init(alloc, std.heap.page_allocator, page_count);
    errdefer pool.deinit();

    var result = try self.clonePool(&pool, top, bot);
    result.pool_owned = true;
    return result;
}

/// Like clone, but specify your own memory pool. This is advanced but
/// lets you avoid expensive syscalls to allocate memory.
pub fn clonePool(
    self: *const PageList,
    pool: *MemoryPool,
    top: point.Point,
    bot: ?point.Point,
) !PageList {
    var it = self.pageIterator(top, bot);

    // Copy our pages
    var page_list: List = .{};
    var total_rows: usize = 0;
    var page_count: usize = 0;
    while (it.next()) |chunk| {
        // Clone the page
        const page = try pool.nodes.create();
        const page_buf = try pool.pages.create();
        page.* = .{ .data = chunk.page.data.cloneBuf(page_buf) };
        page_list.append(page);
        page_count += 1;

        // If this is a full page then we're done.
        if (chunk.fullPage()) {
            total_rows += page.data.size.rows;
            continue;
        }

        // If this is just a shortened chunk off the end we can just
        // shorten the size. We don't worry about clearing memory here because
        // as the page grows the memory will be reclaimable because the data
        // is still valid.
        if (chunk.start == 0) {
            page.data.size.rows = @intCast(chunk.end);
            total_rows += chunk.end;
            continue;
        }

        // Kind of slow, we want to shift the rows up in the page up to
        // end and then resize down.
        const rows = page.data.rows.ptr(page.data.memory);
        const len = chunk.end - chunk.start;
        for (0..len) |i| {
            const src: *Row = &rows[i + chunk.start];
            const dst: *Row = &rows[i];
            const old_dst = dst.*;
            dst.* = src.*;
            src.* = old_dst;
        }
        page.data.size.rows = @intCast(len);
        total_rows += len;
    }

    var result: PageList = .{
        .pool = pool.*,
        .pool_owned = false,
        .pages = page_list,
        .page_size = PagePool.item_size * page_count,
        .max_size = self.max_size,
        .cols = self.cols,
        .rows = self.rows,
        .viewport = .{ .top = {} },
    };

    // We always need to have enough rows for our viewport because this is
    // a pagelist invariant that other code relies on.
    if (total_rows < self.rows) {
        const len = self.rows - total_rows;
        for (0..len) |_| {
            _ = try result.grow();

            // Clear the row. This is not very fast but in reality right
            // now we rarely clone less than the active area and if we do
            // the area is by definition very small.
            const last = result.pages.last.?;
            const row = &last.data.rows.ptr(last.data.memory)[last.data.size.rows - 1];
            last.data.clearCells(row, 0, result.cols);
        }
    }

    return result;
}

/// Returns the viewport for the given offset, prefering to pin to
/// "active" if the offset is within the active area.
fn viewportForOffset(self: *const PageList, offset: RowOffset) Viewport {
    // If the offset is on the active page, then we pin to active
    // if our row idx is beyond the active row idx.
    const active = self.getTopLeft(.active);
    if (offset.page == active.page) {
        if (offset.row_offset >= active.row_offset) {
            return .{ .active = {} };
        }
    } else {
        var page_ = active.page.next;
        while (page_) |page| {
            // This loop is pretty fast because the active area is
            // never that large so this is at most one, two pages for
            // reasonable terminals (including very large real world
            // ones).

            // A page forward in the active area is our page, so we're
            // definitely in the active area.
            if (page == offset.page) return .{ .active = {} };
            page_ = page.next;
        }
    }

    return .{ .exact = offset };
}

/// Resize options
pub const Resize = struct {
    /// The new cols/cells of the screen.
    cols: ?size.CellCountInt = null,
    rows: ?size.CellCountInt = null,

    /// Whether to reflow the text. If this is false then the text will
    /// be truncated if the new size is smaller than the old size.
    reflow: bool = true,

    /// Set this to a cursor position and the resize will retain the
    /// cursor position and update this so that the cursor remains over
    /// the same original cell in the reflowed environment.
    cursor: ?*Cursor = null,

    pub const Cursor = struct {
        x: size.CellCountInt,
        y: size.CellCountInt,

        /// The row offset of the cursor. This is assumed to be correct
        /// if set. If this is not set, then the row offset will be
        /// calculated from the x/y. Calculating the row offset is expensive
        /// so if you have it, you should set it.
        offset: ?RowOffset = null,
    };
};

/// Resize
/// TODO: docs
pub fn resize(self: *PageList, opts: Resize) !void {
    if (!opts.reflow) return try self.resizeWithoutReflow(opts);

    // On reflow, the main thing that causes reflow is column changes. If
    // only rows change, reflow is impossible. So we change our behavior based
    // on the change of columns.
    const cols = opts.cols orelse self.cols;
    switch (std.math.order(cols, self.cols)) {
        .eq => try self.resizeWithoutReflow(opts),

        .gt => {
            // We grow rows after cols so that we can do our unwrapping/reflow
            // before we do a no-reflow grow.
            try self.resizeCols(cols, opts.cursor);
            try self.resizeWithoutReflow(opts);
        },

        .lt => {
            // We first change our row count so that we have the proper amount
            // we can use when shrinking our cols.
            try self.resizeWithoutReflow(opts: {
                var copy = opts;
                copy.cols = self.cols;
                break :opts copy;
            });

            try self.resizeCols(cols, opts.cursor);
        },
    }
}

/// Resize the pagelist with reflow by adding or removing columns.
fn resizeCols(
    self: *PageList,
    cols: size.CellCountInt,
    cursor: ?*Resize.Cursor,
) !void {
    assert(cols != self.cols);

    // Our new capacity, ensure we can fit the cols
    const cap = try std_capacity.adjust(.{ .cols = cols });

    // If we are given a cursor, we need to calculate the row offset.
    if (cursor) |c| {
        if (c.offset == null) {
            const tl = self.getTopLeft(.active);
            c.offset = tl.forward(c.y) orelse fail: {
                // This should never happen, but its not critical enough to
                // set an assertion and fail the program. The caller should ALWAYS
                // input a valid x/y..
                log.err("cursor offset not found, resize will set wrong cursor", .{});
                break :fail null;
            };
        }
    }

    // Go page by page and shrink the columns on a per-page basis.
    var it = self.pageIterator(.{ .screen = .{} }, null);
    while (it.next()) |chunk| {
        // Fast-path: none of our rows are wrapped. In this case we can
        // treat this like a no-reflow resize. This only applies if we
        // are growing columns.
        if (cols > self.cols) {
            const page = &chunk.page.data;
            const rows = page.rows.ptr(page.memory)[0..page.size.rows];
            const wrapped = wrapped: for (rows) |row| {
                assert(!row.wrap_continuation); // TODO
                if (row.wrap) break :wrapped true;
            } else false;
            if (!wrapped) {
                try self.resizeWithoutReflowGrowCols(cap, chunk, cursor);
                continue;
            }
        }

        // Note: we can do a fast-path here if all of our rows in this
        // page already fit within the new capacity. In that case we can
        // do a non-reflow resize.
        try self.reflowPage(cap, chunk.page, cursor);
    }

    // If our total rows is less than our active rows, we need to grow.
    // This can happen if you're growing columns such that enough active
    // rows unwrap that we no longer have enough.
    var node_it = self.pages.first;
    var total: usize = 0;
    while (node_it) |node| : (node_it = node.next) {
        total += node.data.size.rows;
        if (total >= self.rows) break;
    } else {
        for (total..self.rows) |_| _ = try self.grow();
    }

    // If we have a cursor, we need to update the correct y value. I'm
    // not at all happy about this, I wish we could do this in a more
    // efficient way as we resize the pages. But at the time of typing this
    // I can't think of a way and I'd rather get things working. Someone please
    // help!
    //
    // The challenge is that as rows are unwrapped, we want to preserve the
    // cursor. So for examle if you have "A\nB" where AB is soft-wrapped and
    // the cursor is on 'B' (x=0, y=1) and you grow the columns, we want
    // the cursor to remain on B (x=1, y=0) as it grows.
    //
    // The easy thing to do would be to count how many rows we unwrapped
    // and then subtract that from the original y. That's how I started. The
    // challenge is that if we unwrap with scrollback, our scrollback is
    // "pulled down" so that the original (x=0,y=0) line is now pushed down.
    // Detecting this while resizing seems non-obvious. This is a tested case
    // so if you change this logic, you should see failures or passes if it
    // works.
    //
    // The approach I take instead is if we have a cursor offset, I work
    // backwards to find the offset we marked while reflowing and update
    // the y from that. This is _not terrible_ because active areas are
    // generally small and this is a more or less linear search. Its just
    // kind of clunky.
    if (cursor) |c| cursor: {
        const offset = c.offset orelse break :cursor;
        var active_it = self.rowIterator(.{ .active = .{} }, null);
        var y: size.CellCountInt = 0;
        while (active_it.next()) |it_offset| {
            if (it_offset.page == offset.page and
                it_offset.row_offset == offset.row_offset)
            {
                c.y = y;
                break :cursor;
            }

            y += 1;
        } else {
            // Cursor moved off the screen into the scrollback.
            c.x = 0;
            c.y = 0;
        }
    }

    // Update our cols
    self.cols = cols;
}

// We use a cursor to track where we are in the src/dst. This is very
// similar to Screen.Cursor, so see that for docs on individual fields.
// We don't use a Screen because we don't need all the same data and we
// do our best to optimize having direct access to the page memory.
const ReflowCursor = struct {
    x: size.CellCountInt,
    y: size.CellCountInt,
    pending_wrap: bool,
    page: *pagepkg.Page,
    page_row: *pagepkg.Row,
    page_cell: *pagepkg.Cell,

    fn init(page: *pagepkg.Page) ReflowCursor {
        const rows = page.rows.ptr(page.memory);
        return .{
            .x = 0,
            .y = 0,
            .pending_wrap = false,
            .page = page,
            .page_row = &rows[0],
            .page_cell = &rows[0].cells.ptr(page.memory)[0],
        };
    }

    fn cursorForward(self: *ReflowCursor) void {
        if (self.x == self.page.size.cols - 1) {
            self.pending_wrap = true;
        } else {
            const cell: [*]pagepkg.Cell = @ptrCast(self.page_cell);
            self.page_cell = @ptrCast(cell + 1);
            self.x += 1;
        }
    }

    fn cursorScroll(self: *ReflowCursor) void {
        // Scrolling requires that we're on the bottom of our page.
        // We also assert that we have capacity because reflow always
        // works within the capacity of the page.
        assert(self.y == self.page.size.rows - 1);
        assert(self.page.size.rows < self.page.capacity.rows);

        // Increase our page size
        self.page.size.rows += 1;

        // With the increased page size, safely move down a row.
        const rows: [*]pagepkg.Row = @ptrCast(self.page_row);
        const row: *pagepkg.Row = @ptrCast(rows + 1);
        self.page_row = row;
        self.page_cell = &row.cells.ptr(self.page.memory)[0];
        self.pending_wrap = false;
        self.x = 0;
        self.y += 1;
    }

    fn cursorAbsolute(
        self: *ReflowCursor,
        x: size.CellCountInt,
        y: size.CellCountInt,
    ) void {
        assert(x < self.page.size.cols);
        assert(y < self.page.size.rows);

        const rows: [*]pagepkg.Row = @ptrCast(self.page_row);
        const row: *pagepkg.Row = switch (std.math.order(y, self.y)) {
            .eq => self.page_row,
            .lt => @ptrCast(rows - (self.y - y)),
            .gt => @ptrCast(rows + (y - self.y)),
        };
        self.page_row = row;
        self.page_cell = &row.cells.ptr(self.page.memory)[x];
        self.pending_wrap = false;
        self.x = x;
        self.y = y;
    }

    fn countTrailingEmptyCells(self: *const ReflowCursor) usize {
        // If the row is wrapped, all empty cells are meaningful.
        if (self.page_row.wrap) return 0;

        const cells: [*]pagepkg.Cell = @ptrCast(self.page_cell);
        const len: usize = self.page.size.cols - self.x;
        for (0..len) |i| {
            const rev_i = len - i - 1;
            if (!cells[rev_i].isEmpty()) return i;
        }

        // If the row has a semantic prompt then the blank row is meaningful
        // so we always return all but one so that the row is drawn.
        if (self.page_row.semantic_prompt != .unknown) return len - 1;

        return len;
    }

    fn copyRowMetadata(self: *ReflowCursor, other: *const Row) void {
        self.page_row.semantic_prompt = other.semantic_prompt;
    }
};

/// Reflow the given page into the new capacity. The new capacity can have
/// any number of columns and rows. This will create as many pages as
/// necessary to fit the reflowed text and will remove the old page.
///
/// Note a couple edge cases:
///
///   1. If the first set of rows of this page are a wrap continuation, then
///      we will reflow the continuation rows but will not traverse back to
///      find the initial wrap.
///
///   2. If the last row is wrapped then we will traverse forward to reflow
///      all the continuation rows.
///
/// As a result of the above edge cases, the pagelist may end up removing
/// an indefinite number of pages. In the most pathological cases (the screen
/// is one giant wrapped line), this can be a very expensive operation. That
/// doesn't really happen in typical terminal usage so its not a case we
/// optimize for today. Contributions welcome to optimize this.
///
/// Conceptually, this is a simple process: we're effectively traversing
/// the old page and rewriting into the new page as if it were a text editor.
/// But, due to the edge cases, cursor tracking, and attempts at efficiency,
/// the code can be convoluted so this is going to be a heavily commented
/// function.
fn reflowPage(
    self: *PageList,
    cap: Capacity,
    node: *List.Node,
    cursor: ?*Resize.Cursor,
) !void {
    // The cursor tracks where we are in the source page.
    var src_cursor = ReflowCursor.init(&node.data);

    // This is used to count blank lines so that we don't copy those.
    var blank_lines: usize = 0;

    // Our new capacity when growing columns may also shrink rows. So we
    // need to do a loop in order to potentially make multiple pages.
    while (true) {
        // Create our new page and our cursor restarts at 0,0 in the new page.
        // The new page always starts with a size of 1 because we know we have
        // at least one row to copy from the src.
        const dst_node = try self.createPage(cap);
        dst_node.data.size.rows = 1;
        var dst_cursor = ReflowCursor.init(&dst_node.data);
        dst_cursor.copyRowMetadata(src_cursor.page_row);

        // Copy some initial metadata about the row
        //dst_cursor.page_row.semantic_prompt = src_cursor.page_row.semantic_prompt;

        // Our new page goes before our src node. This will append it to any
        // previous pages we've created.
        self.pages.insertBefore(node, dst_node);

        // Continue traversing the source until we're out of space in our
        // destination or we've copied all our intended rows.
        for (src_cursor.y..src_cursor.page.size.rows) |src_y| {
            const prev_wrap = src_cursor.page_row.wrap;
            src_cursor.cursorAbsolute(0, @intCast(src_y));

            // Trim trailing empty cells if the row is not wrapped. If the
            // row is wrapped then we don't trim trailing empty cells because
            // the empty cells can be meaningful.
            const trailing_empty = src_cursor.countTrailingEmptyCells();
            const cols_len = src_cursor.page.size.cols - trailing_empty;

            if (cols_len == 0) {
                // If the row is empty, we don't copy it. We count it as a
                // blank line and continue to the next row.
                blank_lines += 1;
                continue;
            }

            // We have data, if we have blank lines we need to create them first.
            for (0..blank_lines) |_| {
                dst_cursor.cursorScroll();
            }

            if (src_y > 0) {
                // We're done with this row, if this row isn't wrapped, we can
                // move our destination cursor to the next row.
                //
                // The blank_lines == 0 condition is because if we were prefixed
                // with blank lines, we handled the scroll already above.
                if (!prev_wrap and blank_lines == 0) {
                    dst_cursor.cursorScroll();
                }

                dst_cursor.copyRowMetadata(src_cursor.page_row);
            }

            // Reset our blank line count since handled it all above.
            blank_lines = 0;

            for (src_cursor.x..cols_len) |src_x| {
                assert(src_cursor.x == src_x);

                // std.log.warn("src_y={} src_x={} dst_y={} dst_x={} cp={u}", .{
                //     src_cursor.y,
                //     src_cursor.x,
                //     dst_cursor.y,
                //     dst_cursor.x,
                //     src_cursor.page_cell.content.codepoint,
                // });

                if (dst_cursor.pending_wrap) {
                    dst_cursor.page_row.wrap = true;
                    dst_cursor.cursorScroll();
                    dst_cursor.page_row.wrap_continuation = true;
                    dst_cursor.copyRowMetadata(src_cursor.page_row);
                }

                // A rare edge case. If we're resizing down to 1 column
                // and the source is a non-narrow character, we reset the
                // cell to a narrow blank and we skip to the next cell.
                if (cap.cols == 1 and src_cursor.page_cell.wide != .narrow) {
                    switch (src_cursor.page_cell.wide) {
                        .narrow => unreachable,

                        // Wide char, we delete it, reset it to narrow,
                        // and skip forward.
                        .wide => {
                            dst_cursor.page_cell.content.codepoint = 0;
                            dst_cursor.page_cell.wide = .narrow;
                            src_cursor.cursorForward();
                            continue;
                        },

                        // Skip spacer tails since we should've already
                        // handled them in the previous cell.
                        .spacer_tail => {},

                        // TODO: test?
                        .spacer_head => {},
                    }
                } else {
                    switch (src_cursor.page_cell.content_tag) {
                        // These are guaranteed to have no styling data and no
                        // graphemes, a fast path.
                        .bg_color_palette,
                        .bg_color_rgb,
                        => {
                            assert(!src_cursor.page_cell.hasStyling());
                            assert(!src_cursor.page_cell.hasGrapheme());
                            dst_cursor.page_cell.* = src_cursor.page_cell.*;
                        },

                        .codepoint => {
                            dst_cursor.page_cell.* = src_cursor.page_cell.*;
                        },

                        .codepoint_grapheme => {
                            // We copy the cell like normal but we have to reset the
                            // tag because this is used for fast-path detection in
                            // appendGrapheme.
                            dst_cursor.page_cell.* = src_cursor.page_cell.*;
                            dst_cursor.page_cell.content_tag = .codepoint;

                            // Copy the graphemes
                            const src_cps = src_cursor.page.lookupGrapheme(src_cursor.page_cell).?;
                            for (src_cps) |cp| {
                                try dst_cursor.page.appendGrapheme(
                                    dst_cursor.page_row,
                                    dst_cursor.page_cell,
                                    cp,
                                );
                            }
                        },
                    }

                    // If the source cell has a style, we need to copy it.
                    if (src_cursor.page_cell.style_id != stylepkg.default_id) {
                        const src_style = src_cursor.page.styles.lookupId(
                            src_cursor.page.memory,
                            src_cursor.page_cell.style_id,
                        ).?.*;

                        const dst_md = try dst_cursor.page.styles.upsert(
                            dst_cursor.page.memory,
                            src_style,
                        );
                        dst_md.ref += 1;
                        dst_cursor.page_cell.style_id = dst_md.id;
                    }
                }

                // If our original cursor was on this page, this x/y then
                // we need to update to the new location.
                if (cursor) |c| cursor: {
                    const offset = c.offset orelse break :cursor;
                    if (&offset.page.data == src_cursor.page and
                        offset.row_offset == src_cursor.y and
                        c.x == src_cursor.x)
                    {
                        // std.log.warn("c.x={} c.y={} dst_x={} dst_y={} src_y={}", .{
                        //     c.x,
                        //     c.y,
                        //     dst_cursor.x,
                        //     dst_cursor.y,
                        //     src_cursor.y,
                        // });

                        // Column always matches our dst x
                        c.x = dst_cursor.x;

                        // Our y is more complicated. The cursor y is the active
                        // area y, not the row offset. Our cursors are row offsets.
                        // Instead of calculating the active area coord, we can
                        // better calculate the CHANGE in coordinate by subtracting
                        // our dst from src which will calculate how many rows
                        // we unwrapped to get here.
                        //
                        // Note this doesn't handle when we pull down scrollback.
                        // See the cursor updates in resizeGrowCols for that.
                        //c.y -|= src_cursor.y - dst_cursor.y;

                        c.offset = .{
                            .page = dst_node,
                            .row_offset = dst_cursor.y,
                        };
                    }
                }

                // Move both our cursors forward
                src_cursor.cursorForward();
                dst_cursor.cursorForward();
            } else cursor: {
                // We made it through all our source columns. As a final edge
                // case, if our cursor is in one of the blanks, we update it
                // to the edge of this page.

                // If we have no trailing empty cells, it can't be in the blanks.
                if (trailing_empty == 0) break :cursor;

                // If we have no cursor, nothing to update.
                const c = cursor orelse break :cursor;
                const offset = c.offset orelse break :cursor;

                // If our cursor is on this page, and our x is greater than
                // our end, we update to the edge.
                if (&offset.page.data == src_cursor.page and
                    offset.row_offset == src_cursor.y and
                    c.x >= cols_len)
                {
                    c.offset = .{
                        .page = dst_node,
                        .row_offset = dst_cursor.y,
                    };
                }
            }
        } else {
            // We made it through all our source rows, we're done.
            break;
        }
    }

    // Finally, remove the old page.
    self.pages.remove(node);
    self.destroyPage(node);
}

fn resizeWithoutReflow(self: *PageList, opts: Resize) !void {
    if (opts.rows) |rows| {
        switch (std.math.order(rows, self.rows)) {
            .eq => {},

            // Making rows smaller, we simply change our rows value. Changing
            // the row size doesn't affect anything else since max size and
            // so on are all byte-based.
            .lt => {
                // If our rows are shrinking, we prefer to trim trailing
                // blank lines from the active area instead of creating
                // history if we can.
                //
                // This matches macOS Terminal.app behavior. I chose to match that
                // behavior because it seemed fine in an ocean of differing behavior
                // between terminal apps. I'm completely open to changing it as long
                // as resize behavior isn't regressed in a user-hostile way.
                const trimmed = self.trimTrailingBlankRows(self.rows - rows);

                // If we have a cursor, we want to preserve the y value as
                // best we can. We need to subtract the number of rows that
                // moved into the scrollback.
                if (opts.cursor) |cursor| {
                    const scrollback = self.rows - rows - trimmed;
                    cursor.y -|= scrollback;
                }

                // If we didn't trim enough, just modify our row count and this
                // will create additional history.
                self.rows = rows;
            },

            // Making rows larger we adjust our row count, and then grow
            // to the row count.
            .gt => gt: {
                // If our rows increased and our cursor is NOT at the bottom,
                // we want to try to preserve the y value of the old cursor.
                // In other words, we don't want to "pull down" scrollback.
                // This is purely a UX feature.
                if (opts.cursor) |cursor| cursor: {
                    if (cursor.y >= self.rows - 1) break :cursor;

                    // Cursor is not at the bottom, so we just grow our
                    // rows and we're done. Cursor does NOT change for this
                    // since we're not pulling down scrollback.
                    for (0..rows - self.rows) |_| _ = try self.grow();
                    self.rows = rows;
                    break :gt;
                }

                // Cursor is at the bottom or we don't care about cursors.
                // In this case, if we have enough rows in our pages, we
                // just update our rows and we're done. This effectively
                // "pulls down" scrollback.
                //
                // If we don't have enough scrollback, we add the difference,
                // to the active area.
                var count: usize = 0;
                var page = self.pages.first;
                while (page) |p| : (page = p.next) {
                    count += p.data.size.rows;
                    if (count >= rows) break;
                } else {
                    assert(count < rows);
                    for (count..rows) |_| _ = try self.grow();
                }

                // Update our cursor. W
                if (opts.cursor) |cursor| {
                    const grow_len: size.CellCountInt = @intCast(rows -| count);
                    cursor.y += rows - self.rows - grow_len;
                }

                self.rows = rows;
            },
        }
    }

    if (opts.cols) |cols| {
        switch (std.math.order(cols, self.cols)) {
            .eq => {},

            // Making our columns smaller. We always have space for this
            // in existing pages so we need to go through the pages,
            // resize the columns, and clear any cells that are beyond
            // the new size.
            .lt => {
                var it = self.pageIterator(.{ .screen = .{} }, null);
                while (it.next()) |chunk| {
                    const page = &chunk.page.data;
                    const rows = page.rows.ptr(page.memory);
                    for (0..page.size.rows) |i| {
                        const row = &rows[i];
                        page.clearCells(row, cols, self.cols);
                    }

                    page.size.cols = cols;
                }

                if (opts.cursor) |cursor| {
                    // If our cursor is off the edge we trimmed, update to edge
                    if (cursor.x >= cols) cursor.x = cols - 1;
                }

                self.cols = cols;
            },

            // Make our columns larger. This is a bit more complicated because
            // pages may not have the capacity for this. If they don't have
            // the capacity we need to allocate a new page and copy the data.
            .gt => {
                const cap = try std_capacity.adjust(.{ .cols = cols });

                var it = self.pageIterator(.{ .screen = .{} }, null);
                while (it.next()) |chunk| {
                    try self.resizeWithoutReflowGrowCols(cap, chunk, opts.cursor);
                }

                self.cols = cols;
            },
        }
    }
}

fn resizeWithoutReflowGrowCols(
    self: *PageList,
    cap: Capacity,
    chunk: PageIterator.Chunk,
    cursor: ?*Resize.Cursor,
) !void {
    assert(cap.cols > self.cols);
    const page = &chunk.page.data;

    // Update our col count
    const old_cols = self.cols;
    self.cols = cap.cols;
    errdefer self.cols = old_cols;

    // Unlikely fast path: we have capacity in the page. This
    // is only true if we resized to less cols earlier.
    if (page.capacity.cols >= cap.cols) {
        page.size.cols = cap.cols;
        return;
    }

    // Likely slow path: we don't have capacity, so we need
    // to allocate a page, and copy the old data into it.

    // On error, we need to undo all the pages we've added.
    const prev = chunk.page.prev;
    errdefer {
        var current = chunk.page.prev;
        while (current) |p| {
            if (current == prev) break;
            current = p.prev;
            self.pages.remove(p);
            self.destroyPage(p);
        }
    }

    // We need to loop because our col growth may force us
    // to split pages.
    var copied: usize = 0;
    while (copied < page.size.rows) {
        const new_page = try self.createPage(cap);

        // The length we can copy into the new page is at most the number
        // of rows in our cap. But if we can finish our source page we use that.
        const len = @min(cap.rows, page.size.rows - copied);
        new_page.data.size.rows = len;

        // The range of rows we're copying from the old page.
        const y_start = copied;
        const y_end = copied + len;
        try new_page.data.cloneFrom(page, y_start, y_end);
        copied += len;

        // Insert our new page
        self.pages.insertBefore(chunk.page, new_page);

        // If we have a cursor, we need to update the row offset if it
        // matches what we just copied.
        if (cursor) |c| cursor: {
            const offset = c.offset orelse break :cursor;
            if (offset.page == chunk.page and
                offset.row_offset >= y_start and
                offset.row_offset < y_end)
            {
                c.offset = .{
                    .page = new_page,
                    .row_offset = offset.row_offset - y_start,
                };
            }
        }
    }
    assert(copied == page.size.rows);

    // Remove the old page.
    // Deallocate the old page.
    self.pages.remove(chunk.page);
    self.destroyPage(chunk.page);
}

/// Returns the number of trailing blank lines, not to exceed max. Max
/// is used to limit our traversal in the case of large scrollback.
fn trailingBlankLines(
    self: *const PageList,
    max: size.CellCountInt,
) size.CellCountInt {
    var count: size.CellCountInt = 0;

    // Go through our pages backwards since we're counting trailing blanks.
    var it = self.pages.last;
    while (it) |page| : (it = page.prev) {
        const len = page.data.size.rows;
        const rows = page.data.rows.ptr(page.data.memory)[0..len];
        for (0..len) |i| {
            const rev_i = len - i - 1;
            const cells = rows[rev_i].cells.ptr(page.data.memory)[0..page.data.size.cols];

            // If the row has any text then we're done.
            if (pagepkg.Cell.hasTextAny(cells)) return count;

            // Inc count, if we're beyond max then we're done.
            count += 1;
            if (count >= max) return count;
        }
    }

    return count;
}

/// Trims up to max trailing blank rows from the pagelist and returns the
/// number of rows trimmed. A blank row is any row with no text (but may
/// have styling).
fn trimTrailingBlankRows(
    self: *PageList,
    max: size.CellCountInt,
) size.CellCountInt {
    var trimmed: size.CellCountInt = 0;
    var it = self.pages.last;
    while (it) |page| : (it = page.prev) {
        const len = page.data.size.rows;
        const rows_slice = page.data.rows.ptr(page.data.memory)[0..len];
        for (0..len) |i| {
            const rev_i = len - i - 1;
            const row = &rows_slice[rev_i];
            const cells = row.cells.ptr(page.data.memory)[0..page.data.size.cols];

            // If the row has any text then we're done.
            if (pagepkg.Cell.hasTextAny(cells)) return trimmed;

            // No text, we can trim this row. Because it has
            // no text we can also be sure it has no styling
            // so we don't need to worry about memory.
            page.data.size.rows -= 1;
            trimmed += 1;
            if (trimmed >= max) return trimmed;
        }
    }

    return trimmed;
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
            } else switch (top.forwardOverflow(@intCast(n))) {
                .offset => |v| v,
                .overflow => |v| v.end,
            };

            // If we are still within the active area, then we pin the
            // viewport to active. This isn't EXACTLY the same behavior as
            // other scrolling because normally when you scroll the viewport
            // is pinned to _that row_ even if new scrollback is created.
            // But in a terminal when you get to the bottom and back into the
            // active area, you usually expect that the viewport will now
            // follow the active area.
            self.viewport = self.viewportForOffset(offset);
        },
    }
}

/// Clear the screen by scrolling written contents up into the scrollback.
/// This will not update the viewport.
pub fn scrollClear(self: *PageList) !void {
    // Go through the active area backwards to find the first non-empty
    // row. We use this to determine how many rows to scroll up.
    const non_empty: usize = non_empty: {
        var page = self.pages.last.?;
        var n: usize = 0;
        while (true) {
            const rows: [*]Row = page.data.rows.ptr(page.data.memory);
            for (0..page.data.size.rows) |i| {
                const rev_i = page.data.size.rows - i - 1;
                const row = rows[rev_i];
                const cells = row.cells.ptr(page.data.memory)[0..self.cols];
                for (cells) |cell| {
                    if (!cell.isEmpty()) break :non_empty self.rows - n;
                }

                n += 1;
                if (n > self.rows) break :non_empty 0;
            }

            page = page.prev orelse break :non_empty 0;
        }
    };

    // Scroll
    for (0..non_empty) |_| _ = try self.grow();
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
    const next_page = try self.createPage(try std_capacity.adjust(.{ .cols = self.cols }));
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
fn createPage(self: *PageList, cap: Capacity) !*List.Node {
    var page = try self.pool.nodes.create();
    errdefer self.pool.nodes.destroy(page);

    const page_buf = try self.pool.pages.create();
    errdefer self.pool.pages.destroy(page_buf);
    if (comptime std.debug.runtime_safety) @memset(page_buf, 0);

    page.* = .{
        .data = Page.initBuf(
            OffsetBuf.init(page_buf),
            Page.layout(cap),
        ),
    };
    page.data.size.rows = 0;

    return page;
}

/// Destroy the memory of the given page and return it to the pool. The
/// page is assumed to already be removed from the linked list.
fn destroyPage(self: *PageList, page: *List.Node) void {
    @memset(page.data.memory, 0);
    self.pool.pages.destroy(@ptrCast(page.data.memory.ptr));
    self.pool.nodes.destroy(page);
}

/// Erase the rows from the given top to bottom (inclusive). Erasing
/// the rows doesn't clear them but actually physically REMOVES the rows.
/// If the top or bottom point is in the middle of a page, the other
/// contents in the page will be preserved but the page itself will be
/// underutilized (size < capacity).
pub fn eraseRows(
    self: *PageList,
    tl_pt: point.Point,
    bl_pt: ?point.Point,
) void {
    // The count of rows that was erased.
    var erased: usize = 0;

    // A pageIterator iterates one page at a time from the back forward.
    // "back" here is in terms of scrollback, but actually the front of the
    // linked list.
    var it = self.pageIterator(tl_pt, bl_pt);
    while (it.next()) |chunk| {
        // If the chunk is a full page, deinit thit page and remove it from
        // the linked list.
        if (chunk.fullPage()) {
            self.erasePage(chunk.page);
            erased += chunk.page.data.size.rows;
            continue;
        }

        // The chunk is not a full page so we need to move the rows.
        // This is a cheap operation because we're just moving cell offsets,
        // not the actual cell contents.
        assert(chunk.start == 0);
        const rows = chunk.page.data.rows.ptr(chunk.page.data.memory);
        const scroll_amount = chunk.page.data.size.rows - chunk.end;
        for (0..scroll_amount) |i| {
            const src: *Row = &rows[i + chunk.end];
            const dst: *Row = &rows[i];
            const old_dst = dst.*;
            dst.* = src.*;
            src.* = old_dst;
        }

        // We don't even bother deleting the data in the swapped rows
        // because erasing in this way yields a page that likely will never
        // be written to again (its in the past) or it will grow and the
        // terminal erase will automatically erase the data.

        // If our viewport is on this page and the offset is beyond
        // our new end, shift it.
        switch (self.viewport) {
            .top, .active => {},
            .exact => |*offset| exact: {
                if (offset.page != chunk.page) break :exact;
                offset.row_offset -|= scroll_amount;
            },
        }

        // Our new size is the amount we scrolled
        chunk.page.data.size.rows = @intCast(scroll_amount);
        erased += chunk.end;
    }

    // If we deleted active, we need to regrow because one of our invariants
    // is that we always have full active space.
    if (tl_pt == .active) {
        for (0..erased) |_| _ = self.grow() catch |err| {
            // If this fails its a pretty big issue actually... but I don't
            // want to turn this function into an error-returning function
            // because erasing active is so rare and even if it happens failing
            // is even more rare...
            log.err("failed to regrow active area after erase err={}", .{err});
            return;
        };
    }

    // If we have an exact viewport, we need to adjust for active area.
    switch (self.viewport) {
        .active => {},

        .exact => |offset| self.viewport = self.viewportForOffset(offset),

        // For top, we move back to active if our erasing moved our
        // top page into the active area.
        .top => {
            const vp = self.viewportForOffset(.{
                .page = self.pages.first.?,
                .row_offset = 0,
            });
            if (vp == .active) self.viewport = vp;
        },
    }
}

/// Erase a single page, freeing all its resources. The page can be
/// anywhere in the linked list.
fn erasePage(self: *PageList, page: *List.Node) void {
    // If our viewport is pinned to this page, then we need to update it.
    switch (self.viewport) {
        .top, .active => {},
        .exact => |*offset| {
            if (offset.page == page) {
                if (page.next) |next| {
                    offset.page = next;
                } else {
                    self.viewport = .{ .active = {} };
                }
            }
        },
    }

    // Remove the page from the linked list
    self.pages.remove(page);
    self.destroyPage(page);
}

/// Get the top-left of the screen for the given tag.
pub fn rowOffset(self: *const PageList, pt: point.Point) RowOffset {
    // TODO: assert the point is valid
    return self.getTopLeft(pt).forward(pt.coord().y).?;
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
    page_it: PageIterator,
    chunk: ?PageIterator.Chunk = null,
    offset: usize = 0,

    pub fn next(self: *RowIterator) ?RowOffset {
        const chunk = self.chunk orelse return null;
        const row: RowOffset = .{ .page = chunk.page, .row_offset = self.offset };

        // Increase our offset in the chunk
        self.offset += 1;

        // If we are beyond the chunk end, we need to move to the next chunk.
        if (self.offset >= chunk.end) {
            self.chunk = self.page_it.next();
            if (self.chunk) |c| self.offset = c.start;
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
    bl_pt: ?point.Point,
) RowIterator {
    var page_it = self.pageIterator(tl_pt, bl_pt);
    const chunk = page_it.next() orelse return .{ .page_it = page_it };
    return .{ .page_it = page_it, .chunk = chunk, .offset = chunk.start };
}

pub const PageIterator = struct {
    row: ?RowOffset = null,
    limit: Limit = .none,

    const Limit = union(enum) {
        none,
        count: usize,
        row: RowOffset,
    };

    pub fn next(self: *PageIterator) ?Chunk {
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

        /// Returns true if this chunk represents every row in the page.
        pub fn fullPage(self: Chunk) bool {
            return self.start == 0 and self.end == self.page.data.size.rows;
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
pub fn pageIterator(
    self: *const PageList,
    tl_pt: point.Point,
    bl_pt: ?point.Point,
) PageIterator {
    // TODO: bl_pt assertions

    const tl = self.getTopLeft(tl_pt);
    const limit: PageIterator.Limit = limit: {
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
            .history => history: {
                const active_tl = self.getTopLeft(.active);
                const history_bot = active_tl.backward(1) orelse
                    return .{ .row = null };
                break :history .{ .row = history_bot };
            },
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

test "PageList scroll delta row back without space preserves active" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();
    s.scroll(.{ .delta_row = -1 });

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, pt);
    }

    try testing.expect(s.viewport == .active);
}

test "PageList scroll clear" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();

    {
        const cell = s.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
        cell.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = 'A' },
        };
    }
    {
        const cell = s.getCell(.{ .active = .{ .x = 0, .y = 1 } }).?;
        cell.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = 'A' },
        };
    }

    try s.scrollClear();

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 2,
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

test "PageList pageIterator single page" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();

    // The viewport should be within a single page
    try testing.expect(s.pages.first.?.next == null);

    // Iterate the active area
    var it = s.pageIterator(.{ .active = .{} }, null);
    {
        const chunk = it.next().?;
        try testing.expect(chunk.page == s.pages.first.?);
        try testing.expectEqual(@as(usize, 0), chunk.start);
        try testing.expectEqual(@as(usize, s.rows), chunk.end);
    }

    // Should only have one chunk
    try testing.expect(it.next() == null);
}

test "PageList pageIterator two pages" {
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
    var it = s.pageIterator(.{ .active = .{} }, null);
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

test "PageList pageIterator history two pages" {
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
    var it = s.pageIterator(.{ .history = .{} }, null);
    {
        const active_tl = s.getTopLeft(.active);
        const chunk = it.next().?;
        try testing.expect(chunk.page == s.pages.first.?);
        const start: usize = 0;
        try testing.expectEqual(start, chunk.start);
        try testing.expectEqual(active_tl.row_offset, chunk.end);
    }
    try testing.expect(it.next() == null);
}

test "PageList erase" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();

    // Grow so we take up at least 5 pages.
    const page = &s.pages.last.?.data;
    for (0..page.capacity.rows * 5) |_| {
        _ = try s.grow();
    }

    // Our total rows should be large
    try testing.expect(s.totalRows() > s.rows);

    // Erase the entire history, we should be back to just our active set.
    s.eraseRows(.{ .history = .{} }, null);
    try testing.expectEqual(s.rows, s.totalRows());
}

test "PageList erase resets viewport to active if moves within active" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();

    // Grow so we take up at least 5 pages.
    const page = &s.pages.last.?.data;
    for (0..page.capacity.rows * 5) |_| {
        _ = try s.grow();
    }

    // Move our viewport to the top
    s.scroll(.{ .delta_row = -@as(isize, @intCast(s.totalRows())) });
    try testing.expect(s.viewport.exact.page == s.pages.first.?);

    // Erase the entire history, we should be back to just our active set.
    s.eraseRows(.{ .history = .{} }, null);
    try testing.expect(s.viewport == .active);
}

test "PageList erase resets viewport if inside erased page but not active" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();

    // Grow so we take up at least 5 pages.
    const page = &s.pages.last.?.data;
    for (0..page.capacity.rows * 5) |_| {
        _ = try s.grow();
    }

    // Move our viewport to the top
    s.scroll(.{ .delta_row = -@as(isize, @intCast(s.totalRows())) });
    try testing.expect(s.viewport.exact.page == s.pages.first.?);

    // Erase the entire history, we should be back to just our active set.
    s.eraseRows(.{ .history = .{} }, .{ .history = .{ .y = 2 } });
    try testing.expect(s.viewport.exact.page == s.pages.first.?);
}

test "PageList erase resets viewport to active if top is inside active" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();

    // Grow so we take up at least 5 pages.
    const page = &s.pages.last.?.data;
    for (0..page.capacity.rows * 5) |_| {
        _ = try s.grow();
    }

    // Move our viewport to the top
    s.scroll(.{ .top = {} });

    // Erase the entire history, we should be back to just our active set.
    s.eraseRows(.{ .history = .{} }, null);
    try testing.expect(s.viewport == .active);
}

test "PageList erase active regrows automatically" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();
    try testing.expect(s.totalRows() == s.rows);
    s.eraseRows(.{ .active = .{} }, .{ .active = .{ .y = 10 } });
    try testing.expect(s.totalRows() == s.rows);
}

test "PageList clone" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();
    try testing.expectEqual(@as(usize, s.rows), s.totalRows());

    var s2 = try s.clone(alloc, .{ .screen = .{} }, null);
    defer s2.deinit();
    try testing.expectEqual(@as(usize, s.rows), s2.totalRows());
}

test "PageList clone partial trimmed right" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 20, null);
    defer s.deinit();
    try testing.expectEqual(@as(usize, s.rows), s.totalRows());
    try s.growRows(30);

    var s2 = try s.clone(
        alloc,
        .{ .screen = .{} },
        .{ .screen = .{ .y = 39 } },
    );
    defer s2.deinit();
    try testing.expectEqual(@as(usize, 40), s2.totalRows());
}

test "PageList clone partial trimmed left" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 20, null);
    defer s.deinit();
    try testing.expectEqual(@as(usize, s.rows), s.totalRows());
    try s.growRows(30);

    var s2 = try s.clone(
        alloc,
        .{ .screen = .{ .y = 10 } },
        null,
    );
    defer s2.deinit();
    try testing.expectEqual(@as(usize, 40), s2.totalRows());
}

test "PageList clone partial trimmed both" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 20, null);
    defer s.deinit();
    try testing.expectEqual(@as(usize, s.rows), s.totalRows());
    try s.growRows(30);

    var s2 = try s.clone(
        alloc,
        .{ .screen = .{ .y = 10 } },
        .{ .screen = .{ .y = 35 } },
    );
    defer s2.deinit();
    try testing.expectEqual(@as(usize, 26), s2.totalRows());
}

test "PageList clone less than active" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();
    try testing.expectEqual(@as(usize, s.rows), s.totalRows());

    var s2 = try s.clone(
        alloc,
        .{ .active = .{ .y = 5 } },
        null,
    );
    defer s2.deinit();
    try testing.expectEqual(@as(usize, s.rows), s2.totalRows());
}

test "PageList resize (no reflow) more rows" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 3, 0);
    defer s.deinit();
    try testing.expectEqual(@as(usize, 3), s.totalRows());

    // Cursor is at the bottom
    var cursor: Resize.Cursor = .{ .x = 0, .y = 2 };

    // Resize
    try s.resize(.{ .rows = 10, .reflow = false, .cursor = &cursor });
    try testing.expectEqual(@as(usize, 10), s.rows);
    try testing.expectEqual(@as(usize, 10), s.totalRows());

    // Our cursor should not move because we have no scrollback so
    // we just grew.
    try testing.expectEqual(@as(size.CellCountInt, 0), cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 2), cursor.y);

    {
        const pt = s.getCell(.{ .active = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, pt);
    }
}

test "PageList resize (no reflow) more rows with history" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 3, null);
    defer s.deinit();
    try s.growRows(50);
    {
        const pt = s.getCell(.{ .active = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 50,
        } }, pt);
    }

    // Cursor is at the bottom
    var cursor: Resize.Cursor = .{ .x = 0, .y = 2 };

    // Resize
    try s.resize(.{ .rows = 5, .reflow = false, .cursor = &cursor });
    try testing.expectEqual(@as(usize, 5), s.rows);
    try testing.expectEqual(@as(usize, 53), s.totalRows());

    // Our cursor should move since it's in the scrollback
    try testing.expectEqual(@as(size.CellCountInt, 0), cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 4), cursor.y);

    {
        const pt = s.getCell(.{ .active = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 48,
        } }, pt);
    }
}

test "PageList resize (no reflow) less rows" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 10, 0);
    defer s.deinit();
    try testing.expectEqual(@as(usize, 10), s.totalRows());

    // This is required for our writing below to work
    try testing.expect(s.pages.first == s.pages.last);
    const page = &s.pages.first.?.data;

    // Write into all rows so we don't get trim behavior
    for (0..s.rows) |y| {
        const rac = page.getRowAndCell(0, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = 'A' },
        };
    }

    // Resize
    try s.resize(.{ .rows = 5, .reflow = false });
    try testing.expectEqual(@as(usize, 5), s.rows);
    try testing.expectEqual(@as(usize, 10), s.totalRows());
    {
        const pt = s.getCell(.{ .active = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 5,
        } }, pt);
    }
}

test "PageList resize (no reflow) less rows cursor in scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 10, 0);
    defer s.deinit();
    try testing.expectEqual(@as(usize, 10), s.totalRows());

    // This is required for our writing below to work
    try testing.expect(s.pages.first == s.pages.last);
    const page = &s.pages.first.?.data;

    // Write into all rows so we don't get trim behavior
    for (0..s.rows) |y| {
        const rac = page.getRowAndCell(0, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = @intCast(y) },
        };
    }

    // Let's say our cursor is in the scrollback
    var cursor: Resize.Cursor = .{ .x = 0, .y = 2 };
    {
        const get = s.getCell(.{ .active = .{
            .x = cursor.x,
            .y = cursor.y,
        } }).?;
        try testing.expectEqual(@as(u21, 2), get.cell.content.codepoint);
    }

    // Resize
    try s.resize(.{ .rows = 5, .reflow = false, .cursor = &cursor });
    try testing.expectEqual(@as(usize, 5), s.rows);
    try testing.expectEqual(@as(usize, 10), s.totalRows());

    // Our cursor should move since it's in the scrollback
    try testing.expectEqual(@as(size.CellCountInt, 0), cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 0), cursor.y);

    {
        const pt = s.getCell(.{ .active = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 5,
        } }, pt);
    }
}

test "PageList resize (no reflow) less rows trims blank lines" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 5, 0);
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = &s.pages.first.?.data;

    // Write codepoint into first line
    {
        const rac = page.getRowAndCell(0, 0);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = 'A' },
        };
    }

    // Fill remaining lines with a background color
    for (1..s.rows) |y| {
        const rac = page.getRowAndCell(0, y);
        rac.cell.* = .{
            .content_tag = .bg_color_rgb,
            .content = .{ .color_rgb = .{ .r = 0xFF, .g = 0, .b = 0 } },
        };
    }

    // Let's say our cursor is at the top
    var cursor: Resize.Cursor = .{ .x = 0, .y = 0 };
    {
        const get = s.getCell(.{ .active = .{
            .x = cursor.x,
            .y = cursor.y,
        } }).?;
        try testing.expectEqual(@as(u21, 'A'), get.cell.content.codepoint);
    }

    // Resize
    try s.resize(.{ .rows = 2, .reflow = false, .cursor = &cursor });
    try testing.expectEqual(@as(usize, 2), s.rows);
    try testing.expectEqual(@as(usize, 2), s.totalRows());

    // Our cursor should not move since we trimmed
    try testing.expectEqual(@as(size.CellCountInt, 0), cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 0), cursor.y);

    {
        const pt = s.getCell(.{ .active = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, pt);
    }
}

test "PageList resize (no reflow) more rows extends blank lines" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 3, 0);
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = &s.pages.first.?.data;

    // Write codepoint into first line
    {
        const rac = page.getRowAndCell(0, 0);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = 'A' },
        };
    }

    // Fill remaining lines with a background color
    for (1..s.rows) |y| {
        const rac = page.getRowAndCell(0, y);
        rac.cell.* = .{
            .content_tag = .bg_color_rgb,
            .content = .{ .color_rgb = .{ .r = 0xFF, .g = 0, .b = 0 } },
        };
    }

    // Resize
    try s.resize(.{ .rows = 7, .reflow = false });
    try testing.expectEqual(@as(usize, 7), s.rows);
    try testing.expectEqual(@as(usize, 7), s.totalRows());
    {
        const pt = s.getCell(.{ .active = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, pt);
    }
}

test "PageList resize (no reflow) less cols" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 10, 0);
    defer s.deinit();

    // Resize
    try s.resize(.{ .cols = 5, .reflow = false });
    try testing.expectEqual(@as(usize, 5), s.cols);
    try testing.expectEqual(@as(usize, 10), s.totalRows());

    var it = s.rowIterator(.{ .screen = .{} }, null);
    while (it.next()) |offset| {
        const rac = offset.rowAndCell(0);
        const cells = offset.page.data.getCells(rac.row);
        try testing.expectEqual(@as(usize, 5), cells.len);
    }
}

test "PageList resize (no reflow) less cols clears graphemes" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 10, 0);
    defer s.deinit();

    // Add a grapheme.
    const page = &s.pages.first.?.data;
    {
        const rac = page.getRowAndCell(9, 0);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = 'A' },
        };
        try page.appendGrapheme(rac.row, rac.cell, 'A');
    }
    try testing.expectEqual(@as(usize, 1), page.graphemeCount());

    // Resize
    try s.resize(.{ .cols = 5, .reflow = false });
    try testing.expectEqual(@as(usize, 5), s.cols);
    try testing.expectEqual(@as(usize, 10), s.totalRows());

    var it = s.pageIterator(.{ .screen = .{} }, null);
    while (it.next()) |chunk| {
        try testing.expectEqual(@as(usize, 0), chunk.page.data.graphemeCount());
    }
}

test "PageList resize (no reflow) more cols" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, 0);
    defer s.deinit();

    // Resize
    try s.resize(.{ .cols = 10, .reflow = false });
    try testing.expectEqual(@as(usize, 10), s.cols);
    try testing.expectEqual(@as(usize, 3), s.totalRows());

    var it = s.rowIterator(.{ .screen = .{} }, null);
    while (it.next()) |offset| {
        const rac = offset.rowAndCell(0);
        const cells = offset.page.data.getCells(rac.row);
        try testing.expectEqual(@as(usize, 10), cells.len);
    }
}

test "PageList resize (no reflow) less cols then more cols" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, 0);
    defer s.deinit();

    // Resize less
    try s.resize(.{ .cols = 2, .reflow = false });
    try testing.expectEqual(@as(usize, 2), s.cols);

    // Resize
    try s.resize(.{ .cols = 5, .reflow = false });
    try testing.expectEqual(@as(usize, 5), s.cols);
    try testing.expectEqual(@as(usize, 3), s.totalRows());

    var it = s.rowIterator(.{ .screen = .{} }, null);
    while (it.next()) |offset| {
        const rac = offset.rowAndCell(0);
        const cells = offset.page.data.getCells(rac.row);
        try testing.expectEqual(@as(usize, 5), cells.len);
    }
}

test "PageList resize (no reflow) less rows and cols" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 10, 0);
    defer s.deinit();

    // Resize less
    try s.resize(.{ .cols = 5, .rows = 7, .reflow = false });
    try testing.expectEqual(@as(usize, 5), s.cols);
    try testing.expectEqual(@as(usize, 7), s.rows);

    var it = s.rowIterator(.{ .screen = .{} }, null);
    while (it.next()) |offset| {
        const rac = offset.rowAndCell(0);
        const cells = offset.page.data.getCells(rac.row);
        try testing.expectEqual(@as(usize, 5), cells.len);
    }
}

test "PageList resize (no reflow) more rows and less cols" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 10, 0);
    defer s.deinit();

    // Resize less
    try s.resize(.{ .cols = 5, .rows = 20, .reflow = false });
    try testing.expectEqual(@as(usize, 5), s.cols);
    try testing.expectEqual(@as(usize, 20), s.rows);
    try testing.expectEqual(@as(usize, 20), s.totalRows());

    var it = s.rowIterator(.{ .screen = .{} }, null);
    while (it.next()) |offset| {
        const rac = offset.rowAndCell(0);
        const cells = offset.page.data.getCells(rac.row);
        try testing.expectEqual(@as(usize, 5), cells.len);
    }
}

test "PageList resize (no reflow) empty screen" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 5, 0);
    defer s.deinit();

    // Resize
    try s.resize(.{ .cols = 10, .rows = 10, .reflow = false });
    try testing.expectEqual(@as(usize, 10), s.cols);
    try testing.expectEqual(@as(usize, 10), s.rows);
    try testing.expectEqual(@as(usize, 10), s.totalRows());

    var it = s.rowIterator(.{ .screen = .{} }, null);
    while (it.next()) |offset| {
        const rac = offset.rowAndCell(0);
        const cells = offset.page.data.getCells(rac.row);
        try testing.expectEqual(@as(usize, 10), cells.len);
    }
}

test "PageList resize (no reflow) more cols forces smaller cap" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // We want a cap that forces us to have less rows
    const cap = try std_capacity.adjust(.{ .cols = 100 });
    const cap2 = try std_capacity.adjust(.{ .cols = 500 });
    try testing.expectEqual(@as(size.CellCountInt, 500), cap2.cols);
    try testing.expect(cap2.rows < cap.rows);

    // Create initial cap, fits in one page
    var s = try init(alloc, cap.cols, cap.rows, null);
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = &s.pages.first.?.data;
    for (0..s.rows) |y| {
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 'A' },
            };
        }
    }

    // Resize to our large cap
    const rows = s.totalRows();
    try s.resize(.{ .cols = cap2.cols, .reflow = false });

    // Our total rows should be the same, and contents should be the same.
    try testing.expectEqual(rows, s.totalRows());
    var it = s.rowIterator(.{ .screen = .{} }, null);
    while (it.next()) |offset| {
        const rac = offset.rowAndCell(0);
        const cells = offset.page.data.getCells(rac.row);
        try testing.expectEqual(@as(usize, cap2.cols), cells.len);
        try testing.expectEqual(@as(u21, 'A'), cells[0].content.codepoint);
    }
}

test "PageList resize (no reflow) more rows adds blank rows if cursor at bottom" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, null);
    defer s.deinit();

    // Grow to 5 total rows, simulating 3 active + 2 scrollback
    try s.growRows(2);
    try testing.expect(s.pages.first == s.pages.last);
    const page = &s.pages.first.?.data;
    for (0..s.totalRows()) |y| {
        const rac = page.getRowAndCell(0, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = @intCast(y) },
        };
    }

    // Active should be on row 3
    {
        const pt = s.getCell(.{ .active = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 2,
        } }, pt);
    }

    // Let's say our cursor is at the bottom
    var cursor: Resize.Cursor = .{ .x = 0, .y = s.rows - 2 };
    {
        const get = s.getCell(.{ .active = .{
            .x = cursor.x,
            .y = cursor.y,
        } }).?;
        try testing.expectEqual(@as(u21, 3), get.cell.content.codepoint);
    }

    // Resize
    const original_cursor = cursor;
    try s.resizeWithoutReflow(.{ .rows = 10, .reflow = false, .cursor = &cursor });
    try testing.expectEqual(@as(usize, 5), s.cols);
    try testing.expectEqual(@as(usize, 10), s.rows);

    // Our cursor should not change
    try testing.expectEqual(original_cursor, cursor);

    // 12 because we have our 10 rows in the active + 2 in the scrollback
    // because we're preserving the cursor.
    try testing.expectEqual(@as(usize, 12), s.totalRows());

    // Active should be at the same place it was.
    {
        const pt = s.getCell(.{ .active = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 2,
        } }, pt);
    }

    // Go through our active, we should get only 3,4,5
    for (0..3) |y| {
        const get = s.getCell(.{ .active = .{ .y = y } }).?;
        const expected: u21 = @intCast(y + 2);
        try testing.expectEqual(expected, get.cell.content.codepoint);
    }
}

test "PageList resize reflow more cols no wrapped rows" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, 0);
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = &s.pages.first.?.data;
    for (0..s.rows) |y| {
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 'A' },
            };
        }
    }

    // Resize
    try s.resize(.{ .cols = 10, .reflow = true });
    try testing.expectEqual(@as(usize, 10), s.cols);
    try testing.expectEqual(@as(usize, 3), s.totalRows());

    var it = s.rowIterator(.{ .screen = .{} }, null);
    while (it.next()) |offset| {
        const rac = offset.rowAndCell(0);
        const cells = offset.page.data.getCells(rac.row);
        try testing.expectEqual(@as(usize, 10), cells.len);
        try testing.expectEqual(@as(u21, 'A'), cells[0].content.codepoint);
    }
}

test "PageList resize reflow more cols wrapped rows" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 2, 4, 0);
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = &s.pages.first.?.data;
    for (0..s.rows) |y| {
        if (y % 2 == 0) {
            const rac = page.getRowAndCell(0, y);
            rac.row.wrap = true;
        } else {
            const rac = page.getRowAndCell(0, y);
            rac.row.wrap_continuation = true;
        }

        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 'A' },
            };
        }
    }

    // Resize
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, 4), s.totalRows());

    // Active should still be on top
    {
        const pt = s.getCell(.{ .active = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, pt);
    }

    var it = s.rowIterator(.{ .screen = .{} }, null);
    {
        // First row should be unwrapped
        const offset = it.next().?;
        const rac = offset.rowAndCell(0);
        const cells = offset.page.data.getCells(rac.row);
        try testing.expect(!rac.row.wrap);
        try testing.expectEqual(@as(usize, 4), cells.len);
        try testing.expectEqual(@as(u21, 'A'), cells[0].content.codepoint);
        try testing.expectEqual(@as(u21, 'A'), cells[2].content.codepoint);
    }
}

test "PageList resize reflow more cols cursor in wrapped row" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 2, 4, 0);
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = &s.pages.first.?.data;
    {
        {
            const rac = page.getRowAndCell(0, 0);
            rac.row.wrap = true;
        }
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = @intCast(x) },
            };
        }
    }
    {
        {
            const rac = page.getRowAndCell(0, 1);
            rac.row.wrap_continuation = true;
        }
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, 1);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = @intCast(x) },
            };
        }
    }

    // Set our cursor to be in the wrapped row
    var cursor: Resize.Cursor = .{ .x = 1, .y = 1 };

    // Resize
    try s.resize(.{ .cols = 4, .reflow = true, .cursor = &cursor });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, 4), s.totalRows());

    // Our cursor should move to the first row
    try testing.expectEqual(@as(size.CellCountInt, 3), cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 0), cursor.y);
}

test "PageList resize reflow more cols cursor in not wrapped row" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 2, 4, 0);
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = &s.pages.first.?.data;
    {
        {
            const rac = page.getRowAndCell(0, 0);
            rac.row.wrap = true;
        }
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = @intCast(x) },
            };
        }
    }
    {
        {
            const rac = page.getRowAndCell(0, 1);
            rac.row.wrap_continuation = true;
        }
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, 1);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = @intCast(x) },
            };
        }
    }

    // Set our cursor to be in the wrapped row
    var cursor: Resize.Cursor = .{ .x = 1, .y = 0 };

    // Resize
    try s.resize(.{ .cols = 4, .reflow = true, .cursor = &cursor });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, 4), s.totalRows());

    // Our cursor should move to the first row
    try testing.expectEqual(@as(size.CellCountInt, 1), cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 0), cursor.y);
}

test "PageList resize reflow more cols cursor in wrapped row that isn't unwrapped" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 2, 4, 0);
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = &s.pages.first.?.data;
    {
        {
            const rac = page.getRowAndCell(0, 0);
            rac.row.wrap = true;
        }
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = @intCast(x) },
            };
        }
    }
    {
        {
            const rac = page.getRowAndCell(0, 1);
            rac.row.wrap = true;
            rac.row.wrap_continuation = true;
        }
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, 1);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = @intCast(x) },
            };
        }
    }
    {
        {
            const rac = page.getRowAndCell(0, 2);
            rac.row.wrap_continuation = true;
        }
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, 2);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = @intCast(x) },
            };
        }
    }

    // Set our cursor to be in the wrapped row
    var cursor: Resize.Cursor = .{ .x = 1, .y = 2 };

    // Resize
    try s.resize(.{ .cols = 4, .reflow = true, .cursor = &cursor });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, 4), s.totalRows());

    // Our cursor should move to the first row
    try testing.expectEqual(@as(size.CellCountInt, 1), cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 1), cursor.y);
}

test "PageList resize reflow more cols no reflow preserves semantic prompt" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 2, 4, 0);
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = &s.pages.first.?.data;
        const rac = page.getRowAndCell(0, 1);
        rac.row.semantic_prompt = .prompt;
    }

    // Resize
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, 4), s.totalRows());

    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = &s.pages.first.?.data;
        const rac = page.getRowAndCell(0, 1);
        try testing.expect(rac.row.semantic_prompt == .prompt);
    }
}

test "PageList resize reflow less cols no reflow preserves semantic prompt" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 4, 4, 0);
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = &s.pages.first.?.data;
        {
            const rac = page.getRowAndCell(0, 1);
            rac.row.semantic_prompt = .prompt;
        }
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, 1);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = @intCast(x) },
            };
        }
    }

    // Resize
    try s.resize(.{ .cols = 2, .reflow = true });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 4), s.totalRows());

    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = &s.pages.first.?.data;
        {
            const rac = page.getRowAndCell(0, 1);
            try testing.expect(rac.row.wrap);
            try testing.expect(rac.row.semantic_prompt == .prompt);
        }
        {
            const rac = page.getRowAndCell(0, 2);
            try testing.expect(rac.row.semantic_prompt == .prompt);
        }
    }
}

test "PageList resize reflow less cols no reflow preserves semantic prompt on first line" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 4, 4, 0);
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = &s.pages.first.?.data;
        const rac = page.getRowAndCell(0, 0);
        rac.row.semantic_prompt = .prompt;
    }

    // Resize
    try s.resize(.{ .cols = 2, .reflow = true });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 4), s.totalRows());

    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = &s.pages.first.?.data;
        const rac = page.getRowAndCell(0, 0);
        try testing.expect(rac.row.semantic_prompt == .prompt);
    }
}

test "PageList resize reflow less cols wrap preserves semantic prompt" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 4, 4, 0);
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = &s.pages.first.?.data;
        const rac = page.getRowAndCell(0, 0);
        rac.row.semantic_prompt = .prompt;
    }

    // Resize
    try s.resize(.{ .cols = 2, .reflow = true });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 4), s.totalRows());

    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = &s.pages.first.?.data;
        const rac = page.getRowAndCell(0, 0);
        try testing.expect(rac.row.semantic_prompt == .prompt);
    }
}

test "PageList resize reflow less cols no wrapped rows" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 3, 0);
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = &s.pages.first.?.data;
    for (0..s.rows) |y| {
        const end = 4;
        assert(end < s.cols);
        for (0..4) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = @intCast(x) },
            };
        }
    }

    // Resize
    try s.resize(.{ .cols = 5, .reflow = true });
    try testing.expectEqual(@as(usize, 5), s.cols);
    try testing.expectEqual(@as(usize, 3), s.totalRows());

    var it = s.rowIterator(.{ .screen = .{} }, null);
    while (it.next()) |offset| {
        for (0..4) |x| {
            const rac = offset.rowAndCell(x);
            const cells = offset.page.data.getCells(rac.row);
            try testing.expectEqual(@as(usize, 5), cells.len);
            try testing.expectEqual(@as(u21, @intCast(x)), cells[x].content.codepoint);
        }
    }
}

test "PageList resize reflow less cols wrapped rows" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 4, 2, null);
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = &s.pages.first.?.data;
    for (0..s.rows) |y| {
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = @intCast(x) },
            };
        }
    }

    // Resize
    try s.resize(.{ .cols = 2, .reflow = true });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 4), s.totalRows());

    // Active moves due to scrollback
    {
        const pt = s.getCell(.{ .active = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 2,
        } }, pt);
    }

    var it = s.rowIterator(.{ .screen = .{} }, null);
    {
        // First row should be wrapped
        const offset = it.next().?;
        const rac = offset.rowAndCell(0);
        const cells = offset.page.data.getCells(rac.row);
        try testing.expect(rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell(0);
        const cells = offset.page.data.getCells(rac.row);
        try testing.expect(!rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 2), cells[0].content.codepoint);
    }
    {
        // First row should be wrapped
        const offset = it.next().?;
        const rac = offset.rowAndCell(0);
        const cells = offset.page.data.getCells(rac.row);
        try testing.expect(rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell(0);
        const cells = offset.page.data.getCells(rac.row);
        try testing.expect(!rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 2), cells[0].content.codepoint);
    }
}

test "PageList resize reflow less cols wrapped rows with graphemes" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 4, 2, null);
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = &s.pages.first.?.data;
        for (0..s.rows) |y| {
            for (0..s.cols) |x| {
                const rac = page.getRowAndCell(x, y);
                rac.cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = @intCast(x) },
                };
            }

            const rac = page.getRowAndCell(2, y);
            try page.appendGrapheme(rac.row, rac.cell, 'A');
        }
    }

    // Resize
    try s.resize(.{ .cols = 2, .reflow = true });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 4), s.totalRows());

    // Active moves due to scrollback
    {
        const pt = s.getCell(.{ .active = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 2,
        } }, pt);
    }

    try testing.expect(s.pages.first == s.pages.last);
    const page = &s.pages.first.?.data;
    var it = s.rowIterator(.{ .screen = .{} }, null);
    {
        // First row should be wrapped
        const offset = it.next().?;
        const rac = offset.rowAndCell(0);
        const cells = offset.page.data.getCells(rac.row);
        try testing.expect(rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell(0);
        const cells = offset.page.data.getCells(rac.row);
        try testing.expect(!rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 2), cells[0].content.codepoint);

        const cps = page.lookupGrapheme(rac.cell).?;
        try testing.expectEqual(@as(usize, 1), cps.len);
        try testing.expectEqual(@as(u21, 'A'), cps[0]);
    }
    {
        // First row should be wrapped
        const offset = it.next().?;
        const rac = offset.rowAndCell(0);
        const cells = offset.page.data.getCells(rac.row);
        try testing.expect(rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell(0);
        const cells = offset.page.data.getCells(rac.row);
        try testing.expect(!rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 2), cells[0].content.codepoint);

        const cps = page.lookupGrapheme(rac.cell).?;
        try testing.expectEqual(@as(usize, 1), cps.len);
        try testing.expectEqual(@as(u21, 'A'), cps[0]);
    }
}
test "PageList resize reflow less cols cursor in wrapped row" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 4, 2, null);
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = &s.pages.first.?.data;
    for (0..s.rows) |y| {
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = @intCast(x) },
            };
        }
    }

    // Set our cursor to be in the wrapped row
    var cursor: Resize.Cursor = .{ .x = 2, .y = 1 };

    // Resize
    try s.resize(.{ .cols = 2, .reflow = true, .cursor = &cursor });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 4), s.totalRows());

    // Our cursor should move to the first row
    try testing.expectEqual(@as(size.CellCountInt, 0), cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 1), cursor.y);
}

test "PageList resize reflow less cols cursor goes to scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 4, 2, null);
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = &s.pages.first.?.data;
    for (0..s.rows) |y| {
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = @intCast(x) },
            };
        }
    }

    // Set our cursor to be in the wrapped row
    var cursor: Resize.Cursor = .{ .x = 2, .y = 0 };

    // Resize
    try s.resize(.{ .cols = 2, .reflow = true, .cursor = &cursor });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 4), s.totalRows());

    // Our cursor should move to the first row
    try testing.expectEqual(@as(size.CellCountInt, 0), cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 0), cursor.y);
}

test "PageList resize reflow less cols cursor in unchanged row" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 4, 2, null);
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = &s.pages.first.?.data;
    for (0..s.rows) |y| {
        for (0..2) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = @intCast(x) },
            };
        }
    }

    // Set our cursor to be in the wrapped row
    var cursor: Resize.Cursor = .{ .x = 1, .y = 0 };

    // Resize
    try s.resize(.{ .cols = 2, .reflow = true, .cursor = &cursor });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 2), s.totalRows());

    // Our cursor should move to the first row
    try testing.expectEqual(@as(size.CellCountInt, 1), cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 0), cursor.y);
}

test "PageList resize reflow less cols cursor in blank cell" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 6, 2, null);
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = &s.pages.first.?.data;
    for (0..s.rows) |y| {
        for (0..2) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = @intCast(x) },
            };
        }
    }

    // Set our cursor to be in a blank cell
    var cursor: Resize.Cursor = .{ .x = 2, .y = 0 };

    // Resize
    try s.resize(.{ .cols = 4, .reflow = true, .cursor = &cursor });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, 2), s.totalRows());

    // Our cursor should move to the first row
    try testing.expectEqual(@as(size.CellCountInt, 2), cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 0), cursor.y);
}

test "PageList resize reflow less cols cursor in final blank cell" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 6, 2, null);
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = &s.pages.first.?.data;
    for (0..s.rows) |y| {
        for (0..2) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = @intCast(x) },
            };
        }
    }

    // Set our cursor to be in the final cell of our resized
    var cursor: Resize.Cursor = .{ .x = 3, .y = 0 };

    // Resize
    try s.resize(.{ .cols = 4, .reflow = true, .cursor = &cursor });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, 2), s.totalRows());

    // Our cursor should move to the first row
    try testing.expectEqual(@as(size.CellCountInt, 3), cursor.x);
    try testing.expectEqual(@as(size.CellCountInt, 0), cursor.y);
}

test "PageList resize reflow less cols blank lines" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 4, 3, 0);
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = &s.pages.first.?.data;
    for (0..1) |y| {
        for (0..4) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = @intCast(x) },
            };
        }
    }

    // Resize
    try s.resize(.{ .cols = 2, .reflow = true });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 3), s.totalRows());

    var it = s.rowIterator(.{ .active = .{} }, null);
    {
        // First row should be wrapped
        const offset = it.next().?;
        const rac = offset.rowAndCell(0);
        const cells = offset.page.data.getCells(rac.row);
        try testing.expect(rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell(0);
        const cells = offset.page.data.getCells(rac.row);
        try testing.expect(!rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 2), cells[0].content.codepoint);
    }
}

test "PageList resize reflow less cols blank lines between" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 4, 3, 0);
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = &s.pages.first.?.data;
    {
        for (0..4) |x| {
            const rac = page.getRowAndCell(x, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = @intCast(x) },
            };
        }
    }
    {
        for (0..4) |x| {
            const rac = page.getRowAndCell(x, 2);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = @intCast(x) },
            };
        }
    }

    // Resize
    try s.resize(.{ .cols = 2, .reflow = true });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 4), s.totalRows());

    var it = s.rowIterator(.{ .active = .{} }, null);
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell(0);
        try testing.expect(!rac.row.wrap);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell(0);
        const cells = offset.page.data.getCells(rac.row);
        try testing.expect(rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell(0);
        const cells = offset.page.data.getCells(rac.row);
        try testing.expect(!rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 2), cells[0].content.codepoint);
    }
}

test "PageList resize reflow less cols copy style" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 4, 2, 0);
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = &s.pages.first.?.data;

        // Create a style
        const style: stylepkg.Style = .{ .flags = .{ .bold = true } };
        const style_md = try page.styles.upsert(page.memory, style);

        for (0..s.cols - 1) |x| {
            const rac = page.getRowAndCell(x, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = @intCast(x) },
                .style_id = style_md.id,
            };

            style_md.ref += 1;
        }
    }

    // Resize
    try s.resize(.{ .cols = 2, .reflow = true });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 2), s.totalRows());

    var it = s.rowIterator(.{ .active = .{} }, null);
    while (it.next()) |offset| {
        for (0..s.cols - 1) |x| {
            const rac = offset.rowAndCell(x);
            const style_id = rac.cell.style_id;
            try testing.expect(style_id != 0);

            const style = offset.page.data.styles.lookupId(
                offset.page.data.memory,
                style_id,
            ).?;
            try testing.expect(style.flags.bold);
        }
    }
}

test "PageList resize reflow less cols to eliminate a wide char" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 2, 1, 0);
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = &s.pages.first.?.data;

        {
            const rac = page.getRowAndCell(0, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = '😀' },
                .wide = .wide,
            };
        }
        {
            const rac = page.getRowAndCell(1, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = ' ' },
                .wide = .spacer_tail,
            };
        }
    }

    // Resize
    try s.resize(.{ .cols = 1, .reflow = true });
    try testing.expectEqual(@as(usize, 1), s.cols);
    try testing.expectEqual(@as(usize, 1), s.totalRows());

    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = &s.pages.first.?.data;

        {
            const rac = page.getRowAndCell(0, 0);
            try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint);
            try testing.expectEqual(pagepkg.Cell.Wide.narrow, rac.cell.wide);
        }
    }
}
