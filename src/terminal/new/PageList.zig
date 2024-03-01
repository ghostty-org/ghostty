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
};

/// Resize
/// TODO: docs
pub fn resize(self: *PageList, opts: Resize) !void {
    if (!opts.reflow) return try self.resizeWithoutReflow(opts);
    @panic("TODO: resize with text reflow");
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

fn resizeWithoutReflow(self: *PageList, opts: Resize) !void {
    assert(!opts.reflow);

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
                self.rows = rows;

                // Perform a quick count to make sure we have at least
                // the number of rows we need. This should be fast because
                // we only need to count up to "rows"
                var count: usize = 0;
                var page = self.pages.first;
                while (page) |p| : (page = p.next) {
                    count += p.data.size.rows;
                    if (count >= rows) break :gt;
                }

                assert(count < rows);
                for (count..rows) |_| _ = try self.grow();
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

                self.cols = cols;
            },

            // Make our columns larger. This is a bit more complicated because
            // pages may not have the capacity for this. If they don't have
            // the capacity we need to allocate a new page and copy the data.
            .gt => {
                const cap = try std_capacity.adjust(.{ .cols = cols });

                var it = self.pageIterator(.{ .screen = .{} }, null);
                while (it.next()) |chunk| {
                    const page = &chunk.page.data;

                    // Unlikely fast path: we have capacity in the page. This
                    // is only true if we resized to less cols earlier.
                    if (page.capacity.cols >= cols) {
                        page.size.cols = cols;
                        continue;
                    }

                    // Likely slow path: we don't have capacity, so we need
                    // to allocate a page, and copy the old data into it.
                    // TODO: handle capacity can't fit rows for cols
                    const new_page = try self.createPage(cap);
                    errdefer self.destroyPage(new_page);
                    new_page.data.size.rows = page.size.rows;
                    try new_page.data.cloneFrom(page, 0, page.size.rows);

                    // Insert our new page before the old page.
                    // Remove the old page.
                    // Deallocate the old page.
                    self.pages.insertBefore(chunk.page, new_page);
                    self.pages.remove(chunk.page);
                    self.destroyPage(chunk.page);
                }

                self.cols = cols;
            },
        }
    }
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

    // Resize
    try s.resize(.{ .rows = 10, .reflow = false });
    try testing.expectEqual(@as(usize, 10), s.rows);
    try testing.expectEqual(@as(usize, 10), s.totalRows());

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

    // Resize
    try s.resize(.{ .rows = 5, .reflow = false });
    try testing.expectEqual(@as(usize, 5), s.rows);
    try testing.expectEqual(@as(usize, 53), s.totalRows());
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

    // Resize
    try s.resize(.{ .rows = 2, .reflow = false });
    try testing.expectEqual(@as(usize, 2), s.rows);
    try testing.expectEqual(@as(usize, 2), s.totalRows());
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
