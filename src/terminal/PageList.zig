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

/// List of pins, known as "tracked" pins. These are pins that are kept
/// up to date automatically through page-modifying operations.
const PinSet = std.AutoHashMapUnmanaged(*Pin, void);
const PinPool = std.heap.MemoryPool(Pin);

/// The pool of memory used for a pagelist. This can be shared between
/// multiple pagelists but it is not threadsafe.
pub const MemoryPool = struct {
    alloc: Allocator,
    nodes: NodePool,
    pages: PagePool,
    pins: PinPool,

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
        var pin_pool = try PinPool.initPreheated(gen_alloc, 8);
        errdefer pin_pool.deinit();
        return .{
            .alloc = gen_alloc,
            .nodes = pool,
            .pages = page_pool,
            .pins = pin_pool,
        };
    }

    pub fn deinit(self: *MemoryPool) void {
        self.pages.deinit();
        self.nodes.deinit();
        self.pins.deinit();
    }

    pub fn reset(self: *MemoryPool, mode: ResetMode) void {
        _ = self.pages.reset(mode);
        _ = self.nodes.reset(mode);
        _ = self.pins.reset(mode);
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

/// The list of tracked pins. These are kept up to date automatically.
tracked_pins: PinSet,

/// The top-left of certain parts of the screen that are frequently
/// accessed so we don't have to traverse the linked list to find them.
///
/// For other tags, don't need this:
///   - screen: pages.first
///   - history: active row minus one
///
viewport: Viewport,

/// The pin used for when the viewport scrolls. This is always pre-allocated
/// so that scrolling doesn't have a failable memory allocation. This should
/// never be access directly; use `viewport`.
viewport_pin: *Pin,

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

    /// The viewport is pinned to a tracked pin. The tracked pin is ALWAYS
    /// s.viewport_pin hence this has no value. We force that value to prevent
    /// allocations.
    pin,
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
    errdefer pool.deinit();

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

    // We always track our viewport pin to ensure this is never an allocation
    const viewport_pin = try pool.pins.create();
    var tracked_pins: PinSet = .{};
    errdefer tracked_pins.deinit(pool.alloc);
    try tracked_pins.putNoClobber(pool.alloc, viewport_pin, {});

    return .{
        .cols = cols,
        .rows = rows,
        .pool = pool,
        .pool_owned = true,
        .pages = page_list,
        .page_size = page_size,
        .max_size = max_size_actual,
        .tracked_pins = tracked_pins,
        .viewport = .{ .active = {} },
        .viewport_pin = viewport_pin,
    };
}

/// Deinit the pagelist. If you own the memory pool (used clonePool) then
/// this will reset the pool and retain capacity.
pub fn deinit(self: *PageList) void {
    // Always deallocate our hashmap.
    self.tracked_pins.deinit(self.pool.alloc);

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
    var it = self.pageIterator(.right_down, top, bot);
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
    var it = self.pageIterator(.right_down, top, bot);

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

    // Our viewport pin is always undefined since our viewport in a clones
    // goes back to the top
    const viewport_pin = try pool.pins.create();
    errdefer pool.pins.destroy(viewport_pin);

    var result: PageList = .{
        .pool = pool.*,
        .pool_owned = false,
        .pages = page_list,
        .page_size = PagePool.item_size * page_count,
        .max_size = self.max_size,
        .cols = self.cols,
        .rows = self.rows,
        .tracked_pins = .{}, // TODO
        .viewport = .{ .top = {} },
        .viewport_pin = viewport_pin,
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

/// Resize options
pub const Resize = struct {
    /// The new cols/cells of the screen.
    cols: ?size.CellCountInt = null,
    rows: ?size.CellCountInt = null,

    /// Whether to reflow the text. If this is false then the text will
    /// be truncated if the new size is smaller than the old size.
    reflow: bool = true,

    /// Set this to the current cursor position in the active area. Some
    /// resize/reflow behavior depends on the cursor position.
    cursor: ?Cursor = null,

    pub const Cursor = struct {
        x: size.CellCountInt,
        y: size.CellCountInt,
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
    cursor: ?Resize.Cursor,
) !void {
    assert(cols != self.cols);

    // Our new capacity, ensure we can fit the cols
    const cap = try std_capacity.adjust(.{ .cols = cols });

    // If we have a cursor position (x,y), then we try under any col resizing
    // to keep the same number remaining active rows beneath it. This is a
    // very special case if you can imagine clearing the screen (i.e.
    // scrollClear), having an empty active area, and then resizing to less
    // cols then we don't want the active area to "jump" to the bottom and
    // pull down scrollback.
    const preserved_cursor: ?struct {
        tracked_pin: *Pin,
        remaining_rows: usize,
    } = if (cursor) |c| cursor: {
        const p = self.pin(.{ .active = .{
            .x = c.x,
            .y = c.y,
        } }) orelse break :cursor null;

        break :cursor .{
            .tracked_pin = try self.trackPin(p),
            .remaining_rows = self.rows - c.y - 1,
        };
    } else null;
    defer if (preserved_cursor) |c| self.untrackPin(c.tracked_pin);

    // Go page by page and shrink the columns on a per-page basis.
    var it = self.pageIterator(.right_down, .{ .screen = .{} }, null);
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
                try self.resizeWithoutReflowGrowCols(cap, chunk);
                continue;
            }
        }

        // Note: we can do a fast-path here if all of our rows in this
        // page already fit within the new capacity. In that case we can
        // do a non-reflow resize.
        try self.reflowPage(cap, chunk.page);
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

    // See preserved_cursor setup for why.
    if (preserved_cursor) |c| cursor: {
        const active_pt = self.pointFromPin(
            .active,
            c.tracked_pin.*,
        ) orelse break :cursor;

        // We need to determine how many rows we wrapped from the original
        // and subtract that from the remaining rows we expect because if
        // we wrap down we don't want to push our original row contents into
        // the scrollback.
        const wrapped = wrapped: {
            var wrapped: usize = 0;

            var row_it = c.tracked_pin.rowIterator(.left_up, null);
            _ = row_it.next(); // skip ourselves
            while (row_it.next()) |next| {
                const row = next.rowAndCell().row;
                if (!row.wrap) break;
                wrapped += 1;
            }

            break :wrapped wrapped;
        };

        // If we wrapped more than we expect, do nothing.
        if (wrapped >= c.remaining_rows) break :cursor;
        const desired = c.remaining_rows - wrapped;
        const current = self.rows - (active_pt.active.y + 1);
        if (current >= desired) break :cursor;
        for (0..desired - current) |_| _ = try self.grow();
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
            const cols_len = cols_len: {
                var cols_len = src_cursor.page.size.cols - trailing_empty;
                if (cols_len > 0) break :cols_len cols_len;

                // If a tracked pin is in this row then we need to keep it
                // even if it is empty, because it is somehow meaningful
                // (usually the screen cursor), but we do trim the cells
                // down to the desired size.
                //
                // The reason we do this logic is because if you do a scroll
                // clear (i.e. move all active into scrollback and reset
                // the screen), the cursor is on the top line again with
                // an empty active. If you resize to a smaller col size we
                // don't want to "pull down" all the scrollback again. The
                // user expects we just shrink the active area.
                var it = self.tracked_pins.keyIterator();
                while (it.next()) |p_ptr| {
                    const p = p_ptr.*;
                    if (&p.page.data != src_cursor.page or
                        p.y != src_cursor.y) continue;

                    // If our tracked pin is outside our resized cols, we
                    // trim it to the last col, we don't want to wrap blanks.
                    if (p.x >= cap.cols) p.x = cap.cols - 1;

                    // We increase our col len to at least include this pin
                    cols_len = @max(cols_len, p.x + 1);
                }

                if (cols_len == 0) {
                    // If the row is empty, we don't copy it. We count it as a
                    // blank line and continue to the next row.
                    blank_lines += 1;
                    continue;
                }

                break :cols_len cols_len;
            };

            // We have data, if we have blank lines we need to create them first.
            for (0..blank_lines) |_| {
                // TODO: cursor in here
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

                // If we have a wide char at the end of our page we need
                // to insert a spacer head and wrap.
                if (cap.cols > 1 and
                    src_cursor.page_cell.wide == .wide and
                    dst_cursor.x == cap.cols - 1)
                {
                    self.reflowUpdateCursor(&src_cursor, &dst_cursor, dst_node);

                    dst_cursor.page_cell.* = .{
                        .content_tag = .codepoint,
                        .content = .{ .codepoint = 0 },
                        .wide = .spacer_head,
                    };
                    dst_cursor.cursorForward();
                }

                // If we have a spacer head and we're not at the end then
                // we want to unwrap it and eliminate the head.
                if (cap.cols > 1 and
                    src_cursor.page_cell.wide == .spacer_head and
                    dst_cursor.x != cap.cols - 1)
                {
                    self.reflowUpdateCursor(&src_cursor, &dst_cursor, dst_node);
                    src_cursor.cursorForward();
                    continue;
                }

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
                        dst_cursor.page_row.styled = true;
                    }
                }

                // If our original cursor was on this page, this x/y then
                // we need to update to the new location.
                self.reflowUpdateCursor(&src_cursor, &dst_cursor, dst_node);

                // Move both our cursors forward
                src_cursor.cursorForward();
                dst_cursor.cursorForward();
            } else cursor: {
                // We made it through all our source columns. As a final edge
                // case, if our cursor is in one of the blanks, we update it
                // to the edge of this page.

                // If we have no trailing empty cells, it can't be in the blanks.
                if (trailing_empty == 0) break :cursor;

                // Update all our tracked pins
                var it = self.tracked_pins.keyIterator();
                while (it.next()) |p_ptr| {
                    const p = p_ptr.*;
                    if (&p.page.data != src_cursor.page or
                        p.y != src_cursor.y or
                        p.x < cols_len) continue;

                    p.page = dst_node;
                    p.y = dst_cursor.y;
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

/// This updates the cursor offset if the cursor is exactly on the cell
/// we're currently reflowing. This can then be fixed up later to an exact
/// x/y (see resizeCols).
fn reflowUpdateCursor(
    self: *const PageList,
    src_cursor: *const ReflowCursor,
    dst_cursor: *const ReflowCursor,
    dst_node: *List.Node,
) void {
    // Update all our tracked pins
    var it = self.tracked_pins.keyIterator();
    while (it.next()) |p_ptr| {
        const p = p_ptr.*;
        if (&p.page.data != src_cursor.page or
            p.y != src_cursor.y or
            p.x != src_cursor.x) continue;

        p.page = dst_node;
        p.x = dst_cursor.x;
        p.y = dst_cursor.y;
    }
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
                _ = self.trimTrailingBlankRows(self.rows - rows);

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
                var it = self.pageIterator(.right_down, .{ .screen = .{} }, null);
                while (it.next()) |chunk| {
                    const page = &chunk.page.data;
                    const rows = page.rows.ptr(page.memory);
                    for (0..page.size.rows) |i| {
                        const row = &rows[i];
                        page.clearCells(row, cols, self.cols);
                    }

                    page.size.cols = cols;
                }

                // Update all our tracked pins. If they have an X
                // beyond the edge, clamp it.
                var pin_it = self.tracked_pins.keyIterator();
                while (pin_it.next()) |p_ptr| {
                    const p = p_ptr.*;
                    if (p.x >= cols) p.x = cols - 1;
                }

                self.cols = cols;
            },

            // Make our columns larger. This is a bit more complicated because
            // pages may not have the capacity for this. If they don't have
            // the capacity we need to allocate a new page and copy the data.
            .gt => {
                const cap = try std_capacity.adjust(.{ .cols = cols });

                var it = self.pageIterator(.right_down, .{ .screen = .{} }, null);
                while (it.next()) |chunk| {
                    try self.resizeWithoutReflowGrowCols(cap, chunk);
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

        // Update our tracked pins that pointed to this previous page.
        var pin_it = self.tracked_pins.keyIterator();
        while (pin_it.next()) |p_ptr| {
            const p = p_ptr.*;
            if (p.page != chunk.page or
                p.y < y_start or
                p.y >= y_end) continue;
            p.page = new_page;
            p.y -= y_start;
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
            const p: Pin = if (n < 0) switch (top.upOverflow(@intCast(-n))) {
                .offset => |v| v,
                .overflow => |v| v.end,
            } else switch (top.downOverflow(@intCast(n))) {
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
            if (self.pinIsActive(p)) {
                self.viewport = .{ .active = {} };
                return;
            }

            // Pin is not active so we need to track it.
            self.viewport_pin.* = p;
            self.viewport = .{ .pin = {} };
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
    var it = self.pageIterator(.right_down, tl_pt, bl_pt);
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

        // Update any tracked pins to shift their y. If it was in the erased
        // row then we move it to the top of this page.
        var pin_it = self.tracked_pins.keyIterator();
        while (pin_it.next()) |p_ptr| {
            const p = p_ptr.*;
            if (p.page != chunk.page) continue;
            if (p.y >= chunk.end) {
                p.y -= chunk.end;
            } else {
                p.y = 0;
                p.x = 0;
            }
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

    // If we have a pinned viewport, we need to adjust for active area.
    switch (self.viewport) {
        .active => {},

        // For pin, we check if our pin is now in the active area and if so
        // we move our viewport back to the active area.
        .pin => if (self.pinIsActive(self.viewport_pin.*)) {
            self.viewport = .{ .active = {} };
        },

        // For top, we move back to active if our erasing moved our
        // top page into the active area.
        .top => if (self.pinIsActive(.{ .page = self.pages.first.? })) {
            self.viewport = .{ .active = {} };
        },
    }
}

/// Erase a single page, freeing all its resources. The page can be
/// anywhere in the linked list but must NOT be the final page in the
/// entire list (i.e. must not make the list empty).
fn erasePage(self: *PageList, page: *List.Node) void {
    assert(page.next != null or page.prev != null);

    // Update any tracked pins to move to the next page.
    var it = self.tracked_pins.keyIterator();
    while (it.next()) |p_ptr| {
        const p = p_ptr.*;
        if (p.page != page) continue;
        p.page = page.next orelse page.prev orelse unreachable;
        p.y = 0;
        p.x = 0;
    }

    // Remove the page from the linked list
    self.pages.remove(page);
    self.destroyPage(page);
}

/// Returns the pin for the given point. The pin is NOT tracked so it
/// is only valid as long as the pagelist isn't modified.
pub fn pin(self: *const PageList, pt: point.Point) ?Pin {
    var p = self.getTopLeft(pt).down(pt.coord().y) orelse return null;
    p.x = pt.coord().x;
    return p;
}

/// Convert the given pin to a tracked pin. A tracked pin will always be
/// automatically updated as the pagelist is modified. If the point the
/// pin points to is removed completely, the tracked pin will be updated
/// to the top-left of the screen.
pub fn trackPin(self: *PageList, p: Pin) !*Pin {
    // TODO: assert pin is valid

    // Create our tracked pin
    const tracked = try self.pool.pins.create();
    errdefer self.pool.pins.destroy(tracked);
    tracked.* = p;

    // Add it to the tracked list
    try self.tracked_pins.putNoClobber(self.pool.alloc, tracked, {});
    errdefer _ = self.tracked_pins.remove(tracked);

    return tracked;
}

/// Untrack a previously tracked pin. This will deallocate the pin.
pub fn untrackPin(self: *PageList, p: *Pin) void {
    assert(p != self.viewport_pin);
    if (self.tracked_pins.remove(p)) {
        self.pool.pins.destroy(p);
    }
}

pub fn countTrackedPins(self: *const PageList) usize {
    return self.tracked_pins.count();
}

/// Returns the viewport for the given pin, prefering to pin to
/// "active" if the pin is within the active area.
fn pinIsActive(self: *const PageList, p: Pin) bool {
    // If the pin is in the active page, then we can quickly determine
    // if we're beyond the end.
    const active = self.getTopLeft(.active);
    if (p.page == active.page) return p.y >= active.y;

    var page_ = active.page.next;
    while (page_) |page| {
        // This loop is pretty fast because the active area is
        // never that large so this is at most one, two pages for
        // reasonable terminals (including very large real world
        // ones).

        // A page forward in the active area is our page, so we're
        // definitely in the active area.
        if (page == p.page) return true;
        page_ = page.next;
    }

    return false;
}

/// Convert a pin to a point in the given context. If the pin can't fit
/// within the given tag (i.e. its in the history but you requested active),
/// then this will return null.
///
/// Note that this can be a very expensive operation depending on the tag and
/// the location of the pin. This works by traversing the linked list of pages
/// in the tagged region.
///
/// Therefore, this is recommended only very rarely.
pub fn pointFromPin(self: *const PageList, tag: point.Tag, p: Pin) ?point.Point {
    const tl = self.getTopLeft(tag);

    // Count our first page which is special because it may be partial.
    var coord: point.Point.Coordinate = .{ .x = p.x };
    if (p.page == tl.page) {
        // If our top-left is after our y then we're outside the range.
        if (tl.y > p.y) return null;
        coord.y = p.y - tl.y;
    } else {
        coord.y += tl.page.data.size.rows - tl.y - 1;
        var page_ = tl.page.next;
        while (page_) |page| : (page_ = page.next) {
            if (page == p.page) {
                coord.y += p.y;
                break;
            }

            coord.y += page.data.size.rows;
        } else {
            // We never saw our page, meaning we're outside the range.
            return null;
        }
    }

    return switch (tag) {
        inline else => |comptime_tag| @unionInit(
            point.Point,
            @tagName(comptime_tag),
            coord,
        ),
    };
}

/// Get the cell at the given point, or null if the cell does not
/// exist or is out of bounds.
///
/// Warning: this is slow and should not be used in performance critical paths
pub fn getCell(self: *const PageList, pt: point.Point) ?Cell {
    const pt_pin = self.pin(pt) orelse return null;
    const rac = pt_pin.page.data.getRowAndCell(pt_pin.x, pt_pin.y);
    return .{
        .page = pt_pin.page,
        .row = rac.row,
        .cell = rac.cell,
        .row_idx = pt_pin.y,
        .col_idx = pt_pin.x,
    };
}

/// Direction that iterators can move.
pub const Direction = enum { left_up, right_down };

pub const CellIterator = struct {
    row_it: RowIterator,
    cell: ?Pin = null,

    pub fn next(self: *CellIterator) ?Pin {
        const cell = self.cell orelse return null;

        switch (self.row_it.page_it.direction) {
            .right_down => {
                if (cell.x + 1 < cell.page.data.size.cols) {
                    // We still have cells in this row, increase x.
                    var copy = cell;
                    copy.x += 1;
                    self.cell = copy;
                } else {
                    // We need to move to the next row.
                    self.cell = self.row_it.next();
                }
            },

            .left_up => {
                if (cell.x > 0) {
                    // We still have cells in this row, decrease x.
                    var copy = cell;
                    copy.x -= 1;
                    self.cell = copy;
                } else {
                    // We need to move to the previous row and last col
                    if (self.row_it.next()) |next_cell| {
                        var copy = next_cell;
                        copy.x = next_cell.page.data.size.cols - 1;
                        self.cell = copy;
                    } else {
                        self.cell = null;
                    }
                }
            },
        }

        return cell;
    }
};

pub fn cellIterator(
    self: *const PageList,
    direction: Direction,
    tl_pt: point.Point,
    bl_pt: ?point.Point,
) CellIterator {
    const tl_pin = self.pin(tl_pt).?;
    const bl_pin = if (bl_pt) |pt|
        self.pin(pt).?
    else
        self.getBottomRight(tl_pt) orelse
            return .{ .row_it = undefined };

    return switch (direction) {
        .right_down => tl_pin.cellIterator(.right_down, bl_pin),
        .left_up => bl_pin.cellIterator(.left_up, tl_pin),
    };
}

pub const RowIterator = struct {
    page_it: PageIterator,
    chunk: ?PageIterator.Chunk = null,
    offset: usize = 0,

    pub fn next(self: *RowIterator) ?Pin {
        const chunk = self.chunk orelse return null;
        const row: Pin = .{ .page = chunk.page, .y = self.offset };

        switch (self.page_it.direction) {
            .right_down => {
                // Increase our offset in the chunk
                self.offset += 1;

                // If we are beyond the chunk end, we need to move to the next chunk.
                if (self.offset >= chunk.end) {
                    self.chunk = self.page_it.next();
                    if (self.chunk) |c| self.offset = c.start;
                }
            },

            .left_up => {
                // If we are at the start of the chunk, we need to move to the
                // previous chunk.
                if (self.offset == 0) {
                    self.chunk = self.page_it.next();
                    if (self.chunk) |c| self.offset = c.end - 1;
                } else {
                    self.offset -= 1;
                }
            },
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
    direction: Direction,
    tl_pt: point.Point,
    bl_pt: ?point.Point,
) RowIterator {
    const tl_pin = self.pin(tl_pt).?;
    const bl_pin = if (bl_pt) |pt|
        self.pin(pt).?
    else
        self.getBottomRight(tl_pt) orelse
            return .{ .page_it = undefined };

    return switch (direction) {
        .right_down => tl_pin.rowIterator(.right_down, bl_pin),
        .left_up => bl_pin.rowIterator(.left_up, tl_pin),
    };
}

pub const PageIterator = struct {
    row: ?Pin = null,
    limit: Limit = .none,
    direction: Direction = .right_down,

    const Limit = union(enum) {
        none,
        count: usize,
        row: Pin,
    };

    pub fn next(self: *PageIterator) ?Chunk {
        return switch (self.direction) {
            .left_up => self.nextUp(),
            .right_down => self.nextDown(),
        };
    }

    fn nextDown(self: *PageIterator) ?Chunk {
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
                    .start = row.y,
                    .end = row.page.data.size.rows,
                };
            },

            .count => |*limit| count: {
                assert(limit.* > 0); // should be handled already
                const len = @min(row.page.data.size.rows - row.y, limit.*);
                if (len > limit.*) {
                    self.row = row.down(len);
                    limit.* -= len;
                } else {
                    self.row = null;
                }

                break :count .{
                    .page = row.page,
                    .start = row.y,
                    .end = row.y + len,
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
                        .start = row.y,
                        .end = row.page.data.size.rows,
                    };
                }

                // If this is the same page then we only consume up to
                // the limit row.
                self.row = null;
                if (row.y > limit_row.y) return null;
                break :row .{
                    .page = row.page,
                    .start = row.y,
                    .end = limit_row.y + 1,
                };
            },
        };
    }

    fn nextUp(self: *PageIterator) ?Chunk {
        // Get our current row location
        const row = self.row orelse return null;

        return switch (self.limit) {
            .none => none: {
                // If we have no limit, then we consume this entire page. Our
                // next row is the next page.
                self.row = next: {
                    const next_page = row.page.prev orelse break :next null;
                    break :next .{
                        .page = next_page,
                        .y = next_page.data.size.rows - 1,
                    };
                };

                break :none .{
                    .page = row.page,
                    .start = 0,
                    .end = row.y + 1,
                };
            },

            .count => |*limit| count: {
                assert(limit.* > 0); // should be handled already
                const len = @min(row.y, limit.*);
                if (len > limit.*) {
                    self.row = row.up(len);
                    limit.* -= len;
                } else {
                    self.row = null;
                }

                break :count .{
                    .page = row.page,
                    .start = row.y - len,
                    .end = row.y - 1,
                };
            },

            .row => |limit_row| row: {
                // If this is not the same page as our limit then we
                // can consume the entire page.
                if (limit_row.page != row.page) {
                    self.row = next: {
                        const next_page = row.page.prev orelse break :next null;
                        break :next .{
                            .page = next_page,
                            .y = next_page.data.size.rows - 1,
                        };
                    };

                    break :row .{
                        .page = row.page,
                        .start = 0,
                        .end = row.y + 1,
                    };
                }

                // If this is the same page then we only consume up to
                // the limit row.
                self.row = null;
                if (row.y < limit_row.y) return null;
                break :row .{
                    .page = row.page,
                    .start = limit_row.y,
                    .end = row.y + 1,
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
///
/// If direction is left_up, iteration will go from bl_pt to tl_pt. If
/// direction is right_down, iteration will go from tl_pt to bl_pt.
/// Both inclusive.
pub fn pageIterator(
    self: *const PageList,
    direction: Direction,
    tl_pt: point.Point,
    bl_pt: ?point.Point,
) PageIterator {
    const tl_pin = self.pin(tl_pt).?;
    const bl_pin = if (bl_pt) |pt|
        self.pin(pt).?
    else
        self.getBottomRight(tl_pt) orelse return .{ .row = null };

    if (comptime std.debug.runtime_safety) {
        assert(tl_pin.eql(bl_pin) or tl_pin.before(bl_pin));
    }

    return switch (direction) {
        .right_down => tl_pin.pageIterator(.right_down, bl_pin),
        .left_up => bl_pin.pageIterator(.left_up, tl_pin),
    };
}

/// Get the top-left of the screen for the given tag.
fn getTopLeft(self: *const PageList, tag: point.Tag) Pin {
    return switch (tag) {
        // The full screen or history is always just the first page.
        .screen, .history => .{ .page = self.pages.first.? },

        .viewport => switch (self.viewport) {
            .active => self.getTopLeft(.active),
            .top => self.getTopLeft(.screen),
            .pin => self.viewport_pin.*,
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
                .y = page.data.size.rows - rem,
            };
        },
    };
}

/// Returns the bottom right of the screen for the given tag. This can
/// return null because it is possible that a tag is not in the screen
/// (e.g. history does not yet exist).
fn getBottomRight(self: *const PageList, tag: point.Tag) ?Pin {
    return switch (tag) {
        .screen, .active => last: {
            const page = self.pages.last.?;
            break :last .{
                .page = page,
                .y = page.data.size.rows - 1,
                .x = page.data.size.cols - 1,
            };
        },

        .viewport => viewport: {
            const tl = self.getTopLeft(.viewport);
            break :viewport tl.down(self.rows - 1).?;
        },

        .history => active: {
            const tl = self.getTopLeft(.active);
            break :active tl.up(1);
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

/// The total number of pages in this list.
fn totalPages(self: *const PageList) usize {
    var pages: usize = 0;
    var page = self.pages.first;
    while (page) |p| {
        pages += 1;
        page = p.next;
    }

    return pages;
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

/// Represents an exact x/y coordinate within the screen. This is called
/// a "pin" because it is a fixed point within the pagelist direct to
/// a specific page pointer and memory offset. The benefit is that this
/// point remains valid even through scrolling without any additional work.
///
/// A downside is that  the pin is only valid until the pagelist is modified
/// in a way that may invalid page pointers or shuffle rows, such as resizing,
/// erasing rows, etc.
///
/// A pin can also be "tracked" which means that it will be updated as the
/// PageList is modified.
///
/// The PageList maintains a list of active pin references and keeps them
/// all up to date as the pagelist is modified. This isn't cheap so callers
/// should limit the number of active pins as much as possible.
pub const Pin = struct {
    page: *List.Node,
    y: usize = 0,
    x: usize = 0,

    pub fn rowAndCell(self: Pin) struct {
        row: *pagepkg.Row,
        cell: *pagepkg.Cell,
    } {
        const rac = self.page.data.getRowAndCell(self.x, self.y);
        return .{ .row = rac.row, .cell = rac.cell };
    }

    pub const CellSubset = enum { all, left, right };

    /// Returns the cells for the row that this pin is on. The subset determines
    /// what subset of the cells are returned. The "left/right" subsets are
    /// inclusive of the x coordinate of the pin.
    pub fn cells(self: Pin, subset: CellSubset) []pagepkg.Cell {
        const rac = self.rowAndCell();
        const all = self.page.data.getCells(rac.row);
        return switch (subset) {
            .all => all,
            .left => all[0 .. self.x + 1],
            .right => all[self.x..],
        };
    }

    /// Returns the grapheme codepoints for the given cell. These are only
    /// the EXTRA codepoints and not the first codepoint.
    pub fn grapheme(self: Pin, cell: *pagepkg.Cell) ?[]u21 {
        return self.page.data.lookupGrapheme(cell);
    }

    /// Returns the style for the given cell in this pin.
    pub fn style(self: Pin, cell: *pagepkg.Cell) stylepkg.Style {
        if (cell.style_id == stylepkg.default_id) return .{};
        return self.page.data.styles.lookupId(
            self.page.data.memory,
            cell.style_id,
        ).?.*;
    }

    /// Iterators. These are the same as PageList iterator funcs but operate
    /// on pins rather than points. This is MUCH more efficient than calling
    /// pointFromPin and building up the iterator from points.
    ///
    /// The limit pin is inclusive.
    pub fn pageIterator(
        self: Pin,
        direction: Direction,
        limit: ?Pin,
    ) PageIterator {
        return .{
            .row = self,
            .limit = if (limit) |p| .{ .row = p } else .{ .none = {} },
            .direction = direction,
        };
    }

    pub fn rowIterator(
        self: Pin,
        direction: Direction,
        limit: ?Pin,
    ) RowIterator {
        var page_it = self.pageIterator(direction, limit);
        const chunk = page_it.next() orelse return .{ .page_it = page_it };
        return .{
            .page_it = page_it,
            .chunk = chunk,
            .offset = switch (direction) {
                .right_down => chunk.start,
                .left_up => chunk.end - 1,
            },
        };
    }

    pub fn cellIterator(
        self: Pin,
        direction: Direction,
        limit: ?Pin,
    ) CellIterator {
        var row_it = self.rowIterator(direction, limit);
        var cell = row_it.next() orelse return .{ .row_it = row_it };
        cell.x = self.x;
        return .{ .row_it = row_it, .cell = cell };
    }

    /// Returns true if this pin is between the top and bottom, inclusive.
    //
    // Note: this is primarily unit tested as part of the Kitty
    // graphics deletion code.
    pub fn isBetween(self: Pin, top: Pin, bottom: Pin) bool {
        if (comptime std.debug.runtime_safety) {
            if (top.page == bottom.page) {
                // If top is bottom, must be ordered.
                assert(top.y <= bottom.y);
                if (top.y == bottom.y) {
                    assert(top.x <= bottom.x);
                }
            } else {
                // If top is not bottom, top must be before bottom.
                var page = top.page.next;
                while (page) |p| : (page = p.next) {
                    if (p == bottom.page) break;
                } else assert(false);
            }
        }

        if (self.page == top.page) {
            if (self.y < top.y) return false;
            if (self.y > top.y) {
                return if (self.page == bottom.page)
                    self.y <= bottom.y
                else
                    true;
            }
            return self.x >= top.x;
        }
        if (self.page == bottom.page) {
            if (self.y > bottom.y) return false;
            if (self.y < bottom.y) return true;
            return self.x <= bottom.x;
        }

        var page = top.page.next;
        while (page) |p| : (page = p.next) {
            if (p == bottom.page) break;
            if (p == self.page) return true;
        }

        return false;
    }

    /// Returns true if self is before other. This is very expensive since
    /// it requires traversing the linked list of pages. This should not
    /// be called in performance critical paths.
    pub fn before(self: Pin, other: Pin) bool {
        if (self.page == other.page) {
            if (self.y < other.y) return true;
            if (self.y > other.y) return false;
            return self.x < other.x;
        }

        var page = self.page.next;
        while (page) |p| : (page = p.next) {
            if (p == other.page) return true;
        }

        return false;
    }

    pub fn eql(self: Pin, other: Pin) bool {
        return self.page == other.page and
            self.y == other.y and
            self.x == other.x;
    }

    /// Move the pin down a certain number of rows, or return null if
    /// the pin goes beyond the end of the screen.
    pub fn down(self: Pin, n: usize) ?Pin {
        return switch (self.downOverflow(n)) {
            .offset => |v| v,
            .overflow => null,
        };
    }

    /// Move the pin up a certain number of rows, or return null if
    /// the pin goes beyond the start of the screen.
    pub fn up(self: Pin, n: usize) ?Pin {
        return switch (self.upOverflow(n)) {
            .offset => |v| v,
            .overflow => null,
        };
    }

    /// Move the offset down n rows. If the offset goes beyond the
    /// end of the screen, return the overflow amount.
    pub fn downOverflow(self: Pin, n: usize) union(enum) {
        offset: Pin,
        overflow: struct {
            end: Pin,
            remaining: usize,
        },
    } {
        // Index fits within this page
        const rows = self.page.data.size.rows - (self.y + 1);
        if (n <= rows) return .{ .offset = .{
            .page = self.page,
            .y = n + self.y,
            .x = self.x,
        } };

        // Need to traverse page links to find the page
        var page: *List.Node = self.page;
        var n_left: usize = n - rows;
        while (true) {
            page = page.next orelse return .{ .overflow = .{
                .end = .{
                    .page = page,
                    .y = page.data.size.rows - 1,
                    .x = self.x,
                },
                .remaining = n_left,
            } };
            if (n_left <= page.data.size.rows) return .{ .offset = .{
                .page = page,
                .y = n_left - 1,
                .x = self.x,
            } };
            n_left -= page.data.size.rows;
        }
    }

    /// Move the offset up n rows. If the offset goes beyond the
    /// start of the screen, return the overflow amount.
    pub fn upOverflow(self: Pin, n: usize) union(enum) {
        offset: Pin,
        overflow: struct {
            end: Pin,
            remaining: usize,
        },
    } {
        // Index fits within this page
        if (n <= self.y) return .{ .offset = .{
            .page = self.page,
            .y = self.y - n,
            .x = self.x,
        } };

        // Need to traverse page links to find the page
        var page: *List.Node = self.page;
        var n_left: usize = n - self.y;
        while (true) {
            page = page.prev orelse return .{ .overflow = .{
                .end = .{ .page = page, .y = 0, .x = self.x },
                .remaining = n_left,
            } };
            if (n_left <= page.data.size.rows) return .{ .offset = .{
                .page = page,
                .y = page.data.size.rows - n_left,
                .x = self.x,
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
    try testing.expectEqual(Pin{
        .page = s.pages.first.?,
        .y = 0,
        .x = 0,
    }, s.getTopLeft(.active));
}

test "PageList pointFromPin active no history" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();

    {
        try testing.expectEqual(point.Point{
            .active = .{
                .y = 0,
                .x = 0,
            },
        }, s.pointFromPin(.active, .{
            .page = s.pages.first.?,
            .y = 0,
            .x = 0,
        }).?);
    }
    {
        try testing.expectEqual(point.Point{
            .active = .{
                .y = 2,
                .x = 4,
            },
        }, s.pointFromPin(.active, .{
            .page = s.pages.first.?,
            .y = 2,
            .x = 4,
        }).?);
    }
}

test "PageList pointFromPin active with history" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();
    try s.growRows(30);

    {
        try testing.expectEqual(point.Point{
            .active = .{
                .y = 0,
                .x = 2,
            },
        }, s.pointFromPin(.active, .{
            .page = s.pages.first.?,
            .y = 30,
            .x = 2,
        }).?);
    }

    // In history, invalid
    {
        try testing.expect(s.pointFromPin(.active, .{
            .page = s.pages.first.?,
            .y = 21,
            .x = 2,
        }) == null);
    }
}

test "PageList pointFromPin active from prior page" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();
    const page = &s.pages.last.?.data;
    for (0..page.capacity.rows * 5) |_| {
        _ = try s.grow();
    }

    {
        try testing.expectEqual(point.Point{
            .active = .{
                .y = 0,
                .x = 2,
            },
        }, s.pointFromPin(.active, .{
            .page = s.pages.last.?,
            .y = 0,
            .x = 2,
        }).?);
    }

    // Prior page
    {
        try testing.expect(s.pointFromPin(.active, .{
            .page = s.pages.first.?,
            .y = 0,
            .x = 0,
        }) == null);
    }
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
    var it = s.pageIterator(.right_down, .{ .active = .{} }, null);
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
    var it = s.pageIterator(.right_down, .{ .active = .{} }, null);
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
    var it = s.pageIterator(.right_down, .{ .history = .{} }, null);
    {
        const active_tl = s.getTopLeft(.active);
        const chunk = it.next().?;
        try testing.expect(chunk.page == s.pages.first.?);
        const start: usize = 0;
        try testing.expectEqual(start, chunk.start);
        try testing.expectEqual(active_tl.y, chunk.end);
    }
    try testing.expect(it.next() == null);
}

test "PageList pageIterator reverse single page" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();

    // The viewport should be within a single page
    try testing.expect(s.pages.first.?.next == null);

    // Iterate the active area
    var it = s.pageIterator(.left_up, .{ .active = .{} }, null);
    {
        const chunk = it.next().?;
        try testing.expect(chunk.page == s.pages.first.?);
        try testing.expectEqual(@as(usize, 0), chunk.start);
        try testing.expectEqual(@as(usize, s.rows), chunk.end);
    }

    // Should only have one chunk
    try testing.expect(it.next() == null);
}

test "PageList pageIterator reverse two pages" {
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
    var it = s.pageIterator(.left_up, .{ .active = .{} }, null);
    var count: usize = 0;
    {
        const chunk = it.next().?;
        try testing.expect(chunk.page == s.pages.last.?);
        const start: usize = 0;
        try testing.expectEqual(start, chunk.start);
        try testing.expectEqual(start + 1, chunk.end);
        count += chunk.end - chunk.start;
    }
    {
        const chunk = it.next().?;
        try testing.expect(chunk.page == s.pages.first.?);
        const start = chunk.page.data.size.rows - s.rows + 1;
        try testing.expectEqual(start, chunk.start);
        try testing.expectEqual(chunk.page.data.size.rows, chunk.end);
        count += chunk.end - chunk.start;
    }
    try testing.expect(it.next() == null);
    try testing.expectEqual(s.rows, count);
}

test "PageList pageIterator reverse history two pages" {
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
    var it = s.pageIterator(.left_up, .{ .history = .{} }, null);
    {
        const active_tl = s.getTopLeft(.active);
        const chunk = it.next().?;
        try testing.expect(chunk.page == s.pages.first.?);
        const start: usize = 0;
        try testing.expectEqual(start, chunk.start);
        try testing.expectEqual(active_tl.y, chunk.end);
    }
    try testing.expect(it.next() == null);
}

test "PageList cellIterator" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 2, 2, 0);
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

    var it = s.cellIterator(.right_down, .{ .screen = .{} }, null);
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pointFromPin(.screen, p).?);
    }
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pointFromPin(.screen, p).?);
    }
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 1,
        } }, s.pointFromPin(.screen, p).?);
    }
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 1,
        } }, s.pointFromPin(.screen, p).?);
    }
    try testing.expect(it.next() == null);
}

test "PageList cellIterator reverse" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 2, 2, 0);
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

    var it = s.cellIterator(.left_up, .{ .screen = .{} }, null);
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 1,
        } }, s.pointFromPin(.screen, p).?);
    }
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 1,
        } }, s.pointFromPin(.screen, p).?);
    }
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pointFromPin(.screen, p).?);
    }
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pointFromPin(.screen, p).?);
    }
    try testing.expect(it.next() == null);
}

test "PageList erase" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();
    try testing.expectEqual(@as(usize, 1), s.totalPages());

    // Grow so we take up at least 5 pages.
    const page = &s.pages.last.?.data;
    for (0..page.capacity.rows * 5) |_| {
        _ = try s.grow();
    }
    try testing.expectEqual(@as(usize, 6), s.totalPages());

    // Our total rows should be large
    try testing.expect(s.totalRows() > s.rows);

    // Erase the entire history, we should be back to just our active set.
    s.eraseRows(.{ .history = .{} }, null);
    try testing.expectEqual(s.rows, s.totalRows());

    // We should be back to just one page
    try testing.expectEqual(@as(usize, 1), s.totalPages());
    try testing.expect(s.pages.first == s.pages.last);
}

test "PageList erase row with tracked pin resets to top-left" {
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

    // Put a tracked pin in the history
    const p = try s.trackPin(s.pin(.{ .history = .{} }).?);
    defer s.untrackPin(p);

    // Erase the entire history, we should be back to just our active set.
    s.eraseRows(.{ .history = .{} }, null);
    try testing.expectEqual(s.rows, s.totalRows());

    // Our pin should move to the first page
    try testing.expectEqual(s.pages.first.?, p.page);
    try testing.expectEqual(@as(usize, 0), p.y);
    try testing.expectEqual(@as(usize, 0), p.x);
}

test "PageList erase row with tracked pin shifts" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();

    // Put a tracked pin in the history
    const p = try s.trackPin(s.pin(.{ .active = .{ .y = 4, .x = 2 } }).?);
    defer s.untrackPin(p);

    // Erase only a few rows in our active
    s.eraseRows(.{ .active = .{} }, .{ .active = .{ .y = 3 } });
    try testing.expectEqual(s.rows, s.totalRows());

    // Our pin should move to the first page
    try testing.expectEqual(s.pages.first.?, p.page);
    try testing.expectEqual(@as(usize, 0), p.y);
    try testing.expectEqual(@as(usize, 2), p.x);
}

test "PageList erase row with tracked pin is erased" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();

    // Put a tracked pin in the history
    const p = try s.trackPin(s.pin(.{ .active = .{ .y = 2, .x = 2 } }).?);
    defer s.untrackPin(p);

    // Erase the entire history, we should be back to just our active set.
    s.eraseRows(.{ .active = .{} }, .{ .active = .{ .y = 3 } });
    try testing.expectEqual(s.rows, s.totalRows());

    // Our pin should move to the first page
    try testing.expectEqual(s.pages.first.?, p.page);
    try testing.expectEqual(@as(usize, 0), p.y);
    try testing.expectEqual(@as(usize, 0), p.x);
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
    try testing.expect(s.viewport == .pin);
    try testing.expect(s.viewport_pin.page == s.pages.first.?);

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
    try testing.expect(s.viewport == .pin);
    try testing.expect(s.viewport_pin.page == s.pages.first.?);

    // Erase the entire history, we should be back to just our active set.
    s.eraseRows(.{ .history = .{} }, .{ .history = .{ .y = 2 } });
    try testing.expect(s.viewport == .pin);
    try testing.expect(s.viewport_pin.page == s.pages.first.?);
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

    // Put a tracked pin in the history
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 0, .y = 2 } }).?);
    defer s.untrackPin(p);

    // Resize
    try s.resize(.{ .rows = 10, .reflow = false });
    try testing.expectEqual(@as(usize, 10), s.rows);
    try testing.expectEqual(@as(usize, 10), s.totalRows());

    // Our cursor should not move because we have no scrollback so
    // we just grew.
    try testing.expectEqual(point.Point{ .active = .{
        .x = 0,
        .y = 2,
    } }, s.pointFromPin(.active, p.*).?);

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

    // Put a tracked pin in the history
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 0, .y = 2 } }).?);
    defer s.untrackPin(p);

    // Resize
    try s.resize(.{ .rows = 5, .reflow = false });
    try testing.expectEqual(@as(usize, 5), s.rows);
    try testing.expectEqual(@as(usize, 53), s.totalRows());

    // Our cursor should move since it's in the scrollback
    try testing.expectEqual(point.Point{ .active = .{
        .x = 0,
        .y = 4,
    } }, s.pointFromPin(.active, p.*).?);

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

test "PageList resize (no reflow) less rows cursor on bottom" {
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

    // Put a tracked pin in the history
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 0, .y = 9 } }).?);
    defer s.untrackPin(p);
    {
        const cursor = s.pointFromPin(.active, p.*).?.active;
        const get = s.getCell(.{ .active = .{
            .x = cursor.x,
            .y = cursor.y,
        } }).?;
        try testing.expectEqual(@as(u21, 9), get.cell.content.codepoint);
    }

    // Resize
    try s.resize(.{ .rows = 5, .reflow = false });
    try testing.expectEqual(@as(usize, 5), s.rows);
    try testing.expectEqual(@as(usize, 10), s.totalRows());

    // Our cursor should move since it's in the scrollback
    try testing.expectEqual(point.Point{ .active = .{
        .x = 0,
        .y = 4,
    } }, s.pointFromPin(.active, p.*).?);

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

    // Put a tracked pin in the history
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 0, .y = 2 } }).?);
    defer s.untrackPin(p);
    {
        const cursor = s.pointFromPin(.active, p.*).?.active;
        const get = s.getCell(.{ .active = .{
            .x = cursor.x,
            .y = cursor.y,
        } }).?;
        try testing.expectEqual(@as(u21, 2), get.cell.content.codepoint);
    }

    // Resize
    try s.resize(.{ .rows = 5, .reflow = false });
    try testing.expectEqual(@as(usize, 5), s.rows);
    try testing.expectEqual(@as(usize, 10), s.totalRows());

    // Our cursor should move since it's in the scrollback
    try testing.expect(s.pointFromPin(.active, p.*) == null);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 0,
        .y = 2,
    } }, s.pointFromPin(.screen, p.*).?);

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

    // Put a tracked pin in the history
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 0, .y = 0 } }).?);
    defer s.untrackPin(p);
    {
        const cursor = s.pointFromPin(.active, p.*).?.active;
        const get = s.getCell(.{ .active = .{
            .x = cursor.x,
            .y = cursor.y,
        } }).?;
        try testing.expectEqual(@as(u21, 'A'), get.cell.content.codepoint);
    }

    // Resize
    try s.resize(.{ .rows = 2, .reflow = false });
    try testing.expectEqual(@as(usize, 2), s.rows);
    try testing.expectEqual(@as(usize, 2), s.totalRows());

    // Our cursor should not move since we trimmed
    try testing.expectEqual(point.Point{ .active = .{
        .x = 0,
        .y = 0,
    } }, s.pointFromPin(.active, p.*).?);

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

    var it = s.rowIterator(.right_down, .{ .screen = .{} }, null);
    while (it.next()) |offset| {
        const rac = offset.rowAndCell();
        const cells = offset.page.data.getCells(rac.row);
        try testing.expectEqual(@as(usize, 5), cells.len);
    }
}

test "PageList resize (no reflow) less cols pin in trimmed cols" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 10, 0);
    defer s.deinit();

    // Put a tracked pin in the history
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 8, .y = 2 } }).?);
    defer s.untrackPin(p);

    // Resize
    try s.resize(.{ .cols = 5, .reflow = false });
    try testing.expectEqual(@as(usize, 5), s.cols);
    try testing.expectEqual(@as(usize, 10), s.totalRows());

    var it = s.rowIterator(.right_down, .{ .screen = .{} }, null);
    while (it.next()) |offset| {
        const rac = offset.rowAndCell();
        const cells = offset.page.data.getCells(rac.row);
        try testing.expectEqual(@as(usize, 5), cells.len);
    }

    try testing.expectEqual(point.Point{ .active = .{
        .x = 4,
        .y = 2,
    } }, s.pointFromPin(.active, p.*).?);
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

    var it = s.pageIterator(.right_down, .{ .screen = .{} }, null);
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

    var it = s.rowIterator(.right_down, .{ .screen = .{} }, null);
    while (it.next()) |offset| {
        const rac = offset.rowAndCell();
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

    var it = s.rowIterator(.right_down, .{ .screen = .{} }, null);
    while (it.next()) |offset| {
        const rac = offset.rowAndCell();
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

    var it = s.rowIterator(.right_down, .{ .screen = .{} }, null);
    while (it.next()) |offset| {
        const rac = offset.rowAndCell();
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

    var it = s.rowIterator(.right_down, .{ .screen = .{} }, null);
    while (it.next()) |offset| {
        const rac = offset.rowAndCell();
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

    var it = s.rowIterator(.right_down, .{ .screen = .{} }, null);
    while (it.next()) |offset| {
        const rac = offset.rowAndCell();
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
    var it = s.rowIterator(.right_down, .{ .screen = .{} }, null);
    while (it.next()) |offset| {
        const rac = offset.rowAndCell();
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

    // Put a tracked pin in the history
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 0, .y = s.rows - 2 } }).?);
    defer s.untrackPin(p);
    const original_cursor = s.pointFromPin(.active, p.*).?.active;
    {
        const get = s.getCell(.{ .active = .{
            .x = original_cursor.x,
            .y = original_cursor.y,
        } }).?;
        try testing.expectEqual(@as(u21, 3), get.cell.content.codepoint);
    }

    // Resize
    try s.resizeWithoutReflow(.{
        .rows = 10,
        .reflow = false,
        .cursor = .{ .x = 0, .y = s.rows - 2 },
    });
    try testing.expectEqual(@as(usize, 5), s.cols);
    try testing.expectEqual(@as(usize, 10), s.rows);

    // Our cursor should not change
    try testing.expectEqual(original_cursor, s.pointFromPin(.active, p.*).?.active);

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

    var it = s.rowIterator(.right_down, .{ .screen = .{} }, null);
    while (it.next()) |offset| {
        const rac = offset.rowAndCell();
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

    var it = s.rowIterator(.right_down, .{ .screen = .{} }, null);
    {
        // First row should be unwrapped
        const offset = it.next().?;
        const rac = offset.rowAndCell();
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

    // Put a tracked pin in the history
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 1, .y = 1 } }).?);
    defer s.untrackPin(p);

    // Resize
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, 4), s.totalRows());

    // Our cursor should move to the first row
    try testing.expectEqual(point.Point{ .active = .{
        .x = 3,
        .y = 0,
    } }, s.pointFromPin(.active, p.*).?);
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

    // Put a tracked pin in the history
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 1, .y = 0 } }).?);
    defer s.untrackPin(p);

    // Resize
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, 4), s.totalRows());

    // Our cursor should move to the first row
    try testing.expectEqual(point.Point{ .active = .{
        .x = 1,
        .y = 0,
    } }, s.pointFromPin(.active, p.*).?);
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

    // Put a tracked pin in the history
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 1, .y = 2 } }).?);
    defer s.untrackPin(p);

    // Resize
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, 4), s.totalRows());

    // Our cursor should move to the first row
    try testing.expectEqual(point.Point{ .active = .{
        .x = 1,
        .y = 1,
    } }, s.pointFromPin(.active, p.*).?);
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

test "PageList resize reflow more cols unwrap wide spacer head" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 2, 2, 0);
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = &s.pages.first.?.data;

        {
            const rac = page.getRowAndCell(0, 0);
            rac.row.wrap = true;
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 'x' },
            };
        }
        {
            const rac = page.getRowAndCell(1, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = ' ' },
                .wide = .spacer_head,
            };
        }
        {
            const rac = page.getRowAndCell(0, 1);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = '😀' },
                .wide = .wide,
            };
        }
        {
            const rac = page.getRowAndCell(1, 1);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = ' ' },
                .wide = .spacer_tail,
            };
        }
    }

    // Resize
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, 2), s.totalRows());

    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = &s.pages.first.?.data;

        {
            const rac = page.getRowAndCell(0, 0);
            try testing.expectEqual(@as(u21, 'x'), rac.cell.content.codepoint);
            try testing.expectEqual(pagepkg.Cell.Wide.narrow, rac.cell.wide);
            try testing.expect(!rac.row.wrap);
        }
        {
            const rac = page.getRowAndCell(1, 0);
            try testing.expectEqual(@as(u21, '😀'), rac.cell.content.codepoint);
            try testing.expectEqual(pagepkg.Cell.Wide.wide, rac.cell.wide);
        }
        {
            const rac = page.getRowAndCell(2, 0);
            try testing.expectEqual(@as(u21, ' '), rac.cell.content.codepoint);
            try testing.expectEqual(pagepkg.Cell.Wide.spacer_tail, rac.cell.wide);
        }
    }
}

test "PageList resize reflow more cols unwrap still requires wide spacer head" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 2, 2, 0);
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = &s.pages.first.?.data;

        {
            const rac = page.getRowAndCell(0, 0);
            rac.row.wrap = true;
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 'x' },
            };
        }
        {
            const rac = page.getRowAndCell(1, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 'x' },
            };
        }
        {
            const rac = page.getRowAndCell(0, 1);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = '😀' },
                .wide = .wide,
            };
        }
        {
            const rac = page.getRowAndCell(1, 1);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = ' ' },
                .wide = .spacer_tail,
            };
        }
    }

    // Resize
    try s.resize(.{ .cols = 3, .reflow = true });
    try testing.expectEqual(@as(usize, 3), s.cols);
    try testing.expectEqual(@as(usize, 2), s.totalRows());

    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = &s.pages.first.?.data;

        {
            const rac = page.getRowAndCell(0, 0);
            try testing.expectEqual(@as(u21, 'x'), rac.cell.content.codepoint);
            try testing.expectEqual(pagepkg.Cell.Wide.narrow, rac.cell.wide);
            try testing.expect(rac.row.wrap);
        }
        {
            const rac = page.getRowAndCell(1, 0);
            try testing.expectEqual(@as(u21, 'x'), rac.cell.content.codepoint);
            try testing.expectEqual(pagepkg.Cell.Wide.narrow, rac.cell.wide);
        }
        {
            const rac = page.getRowAndCell(2, 0);
            try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint);
            try testing.expectEqual(pagepkg.Cell.Wide.spacer_head, rac.cell.wide);
        }
        {
            const rac = page.getRowAndCell(0, 1);
            try testing.expectEqual(@as(u21, '😀'), rac.cell.content.codepoint);
            try testing.expectEqual(pagepkg.Cell.Wide.wide, rac.cell.wide);
        }
        {
            const rac = page.getRowAndCell(1, 1);
            try testing.expectEqual(@as(u21, ' '), rac.cell.content.codepoint);
            try testing.expectEqual(pagepkg.Cell.Wide.spacer_tail, rac.cell.wide);
        }
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

    var it = s.rowIterator(.right_down, .{ .screen = .{} }, null);
    while (it.next()) |offset| {
        for (0..4) |x| {
            var offset_copy = offset;
            offset_copy.x = x;
            const rac = offset_copy.rowAndCell();
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

    var it = s.rowIterator(.right_down, .{ .screen = .{} }, null);
    {
        // First row should be wrapped
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.page.data.getCells(rac.row);
        try testing.expect(rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.page.data.getCells(rac.row);
        try testing.expect(!rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 2), cells[0].content.codepoint);
    }
    {
        // First row should be wrapped
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.page.data.getCells(rac.row);
        try testing.expect(rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
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
    var it = s.rowIterator(.right_down, .{ .screen = .{} }, null);
    {
        // First row should be wrapped
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.page.data.getCells(rac.row);
        try testing.expect(rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.page.data.getCells(rac.row);
        try testing.expect(!rac.row.wrap);
        try testing.expect(rac.row.grapheme);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 2), cells[0].content.codepoint);

        const cps = page.lookupGrapheme(rac.cell).?;
        try testing.expectEqual(@as(usize, 1), cps.len);
        try testing.expectEqual(@as(u21, 'A'), cps[0]);
    }
    {
        // First row should be wrapped
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.page.data.getCells(rac.row);
        try testing.expect(rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.page.data.getCells(rac.row);
        try testing.expect(!rac.row.wrap);
        try testing.expect(rac.row.grapheme);
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

    // Put a tracked pin in the history
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 2, .y = 1 } }).?);
    defer s.untrackPin(p);

    // Resize
    try s.resize(.{ .cols = 2, .reflow = true });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 4), s.totalRows());

    // Our cursor should move to the first row
    try testing.expectEqual(point.Point{ .active = .{
        .x = 0,
        .y = 1,
    } }, s.pointFromPin(.active, p.*).?);
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

    // Put a tracked pin in the history
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 2, .y = 0 } }).?);
    defer s.untrackPin(p);

    // Resize
    try s.resize(.{ .cols = 2, .reflow = true });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 4), s.totalRows());

    // Our cursor should move to the first row
    try testing.expect(s.pointFromPin(.active, p.*) == null);
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

    // Put a tracked pin in the history
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 1, .y = 0 } }).?);
    defer s.untrackPin(p);

    // Resize
    try s.resize(.{ .cols = 2, .reflow = true });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 2), s.totalRows());

    // Our cursor should move to the first row
    try testing.expectEqual(point.Point{ .active = .{
        .x = 1,
        .y = 0,
    } }, s.pointFromPin(.active, p.*).?);
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

    // Put a tracked pin in the history
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 2, .y = 0 } }).?);
    defer s.untrackPin(p);

    // Resize
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, 2), s.totalRows());

    // Our cursor should not move
    try testing.expectEqual(point.Point{ .active = .{
        .x = 2,
        .y = 0,
    } }, s.pointFromPin(.active, p.*).?);
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

    // Put a tracked pin in the history
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 3, .y = 0 } }).?);
    defer s.untrackPin(p);

    // Resize
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, 2), s.totalRows());

    // Our cursor should move to the first row
    try testing.expectEqual(point.Point{ .active = .{
        .x = 3,
        .y = 0,
    } }, s.pointFromPin(.active, p.*).?);
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

    var it = s.rowIterator(.right_down, .{ .active = .{} }, null);
    {
        // First row should be wrapped
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.page.data.getCells(rac.row);
        try testing.expect(rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
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

    var it = s.rowIterator(.right_down, .{ .active = .{} }, null);
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        try testing.expect(!rac.row.wrap);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.page.data.getCells(rac.row);
        try testing.expect(rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.page.data.getCells(rac.row);
        try testing.expect(!rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 2), cells[0].content.codepoint);
    }
}

test "PageList resize reflow less cols cursor not on last line preserves location" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 5, 1);
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

    // Grow blank rows to push our rows back into scrollback
    try s.growRows(5);
    try testing.expectEqual(@as(usize, 10), s.totalRows());

    // Put a tracked pin in the history
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 0, .y = 0 } }).?);
    defer s.untrackPin(p);

    // Resize
    try s.resize(.{
        .cols = 4,
        .reflow = true,

        // Important: not on last row
        .cursor = .{ .x = 1, .y = 1 },
    });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, 10), s.totalRows());

    // Our cursor should move to the first row
    try testing.expectEqual(point.Point{ .active = .{
        .x = 0,
        .y = 0,
    } }, s.pointFromPin(.active, p.*).?);
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

    var it = s.rowIterator(.right_down, .{ .active = .{} }, null);
    while (it.next()) |offset| {
        for (0..s.cols - 1) |x| {
            var offset_copy = offset;
            offset_copy.x = x;
            const rac = offset_copy.rowAndCell();
            const style_id = rac.cell.style_id;
            try testing.expect(style_id != 0);

            const style = offset.page.data.styles.lookupId(
                offset.page.data.memory,
                style_id,
            ).?;
            try testing.expect(style.flags.bold);

            const row = rac.row;
            try testing.expect(row.styled);
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

test "PageList resize reflow less cols to wrap a wide char" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 1, 0);
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = &s.pages.first.?.data;

        {
            const rac = page.getRowAndCell(0, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 'x' },
            };
        }
        {
            const rac = page.getRowAndCell(1, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = '😀' },
                .wide = .wide,
            };
        }
        {
            const rac = page.getRowAndCell(2, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = ' ' },
                .wide = .spacer_tail,
            };
        }
    }

    // Resize
    try s.resize(.{ .cols = 2, .reflow = true });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 2), s.totalRows());

    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = &s.pages.first.?.data;

        {
            const rac = page.getRowAndCell(0, 0);
            try testing.expectEqual(@as(u21, 'x'), rac.cell.content.codepoint);
            try testing.expectEqual(pagepkg.Cell.Wide.narrow, rac.cell.wide);
            try testing.expect(rac.row.wrap);
        }
        {
            const rac = page.getRowAndCell(1, 0);
            try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint);
            try testing.expectEqual(pagepkg.Cell.Wide.spacer_head, rac.cell.wide);
        }
        {
            const rac = page.getRowAndCell(0, 1);
            try testing.expectEqual(@as(u21, '😀'), rac.cell.content.codepoint);
            try testing.expectEqual(pagepkg.Cell.Wide.wide, rac.cell.wide);
        }
        {
            const rac = page.getRowAndCell(1, 1);
            try testing.expectEqual(@as(u21, ' '), rac.cell.content.codepoint);
            try testing.expectEqual(pagepkg.Cell.Wide.spacer_tail, rac.cell.wide);
        }
    }
}
