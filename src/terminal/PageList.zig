//! Maintains a linked list of pages to make up a terminal screen
//! and provides higher level operations on top of those pages to
//! make it slightly easier to work with.
const PageList = @This();

const std = @import("std");
const build_config = @import("../build_config.zig");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const fastmem = @import("../fastmem.zig");
const DoublyLinkedList = @import("../datastruct/main.zig").IntrusiveDoublyLinkedList;
const color = @import("color.zig");
const kitty = @import("kitty.zig");
const point = @import("point.zig");
const pagepkg = @import("page.zig");
const stylepkg = @import("style.zig");
const size = @import("size.zig");
const Selection = @import("Selection.zig");
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
pub const List = DoublyLinkedList(Node);

/// A single node within the PageList linked list.
///
/// This isn't pub because you can access the type via List.Node.
const Node = struct {
    prev: ?*Node = null,
    next: ?*Node = null,
    data: Page,
};

/// The memory pool we get page nodes from.
const NodePool = std.heap.MemoryPool(List.Node);

const std_capacity = pagepkg.std_capacity;
const std_size = Page.layout(std_capacity).total_size;

/// The memory pool we use for page memory buffers. We use a separate pool
/// so we can allocate these with a page allocator. We have to use a page
/// allocator because we need memory that is zero-initialized and page-aligned.
const PagePool = std.heap.MemoryPoolAligned(
    [std_size]u8,
    std.mem.page_size,
);

/// List of pins, known as "tracked" pins. These are pins that are kept
/// up to date automatically through page-modifying operations.
const PinSet = std.AutoArrayHashMapUnmanaged(*Pin, void);
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
        var node_pool = try NodePool.initPreheated(gen_alloc, preheat);
        errdefer node_pool.deinit();
        var page_pool = try PagePool.initPreheated(page_alloc, preheat);
        errdefer page_pool.deinit();
        var pin_pool = try PinPool.initPreheated(gen_alloc, 8);
        errdefer pin_pool.deinit();
        return .{
            .alloc = gen_alloc,
            .nodes = node_pool,
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
explicit_max_size: usize,

/// This is the minimum max size that we will respect due to the rows/cols
/// of the PageList. We must always be able to fit at least the active area
/// and at least two pages for our algorithms.
min_max_size: usize,

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

/// Returns the minimum valid "max size" for a given number of rows and cols
/// such that we can fit the active area AND at least two pages. Note we
/// need the two pages for algorithms to work properly (such as grow) but
/// we don't need to fit double the active area.
///
/// This min size may not be totally correct in the case that a large
/// number of other dimensions makes our row size in a page very small.
/// But this gives us a nice fast heuristic for determining min/max size.
/// Therefore, if the page size is violated you should always also verify
/// that we have enough space for the active area.
fn minMaxSize(cols: size.CellCountInt, rows: size.CellCountInt) !usize {
    // Get our capacity to fit our rows. If the cols are too big, it may
    // force less rows than we want meaning we need more than one page to
    // represent a viewport.
    const cap = try std_capacity.adjust(.{ .cols = cols });

    // Calculate the number of standard sized pages we need to represent
    // an active area.
    const pages_exact = if (cap.rows >= rows) 1 else try std.math.divCeil(
        usize,
        rows,
        cap.rows,
    );

    // We always need at least one page extra so that we
    // can fit partial pages to spread our active area across two pages.
    // Even for caps that can't fit all rows in a single page, we add one
    // because the most extra space we need at any given time is only
    // the partial amount of one page.
    const pages = pages_exact + 1;
    assert(pages >= 2);

    // log.debug("minMaxSize cols={} rows={} cap={} pages={}", .{
    //     cols,
    //     rows,
    //     cap,
    //     pages,
    // });

    return PagePool.item_size * pages;
}

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
    const page_list, const page_size = try initPages(&pool, cols, rows);

    // Get our minimum max size, see doc comments for more details.
    const min_max_size = try minMaxSize(cols, rows);

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
        .explicit_max_size = max_size orelse std.math.maxInt(usize),
        .min_max_size = min_max_size,
        .tracked_pins = tracked_pins,
        .viewport = .{ .active = {} },
        .viewport_pin = viewport_pin,
    };
}

fn initPages(
    pool: *MemoryPool,
    cols: size.CellCountInt,
    rows: size.CellCountInt,
) !struct { List, usize } {
    var page_list: List = .{};
    var page_size: usize = 0;

    // Add pages as needed to create our initial viewport.
    const cap = try std_capacity.adjust(.{ .cols = cols });
    var rem = rows;
    while (rem > 0) {
        const node = try pool.nodes.create();
        const page_buf = try pool.pages.create();
        // no errdefer because the pool deinit will clean these up

        // In runtime safety modes we have to memset because the Zig allocator
        // interface will always memset to 0xAA for undefined. In non-safe modes
        // we use a page allocator and the OS guarantees zeroed memory.
        if (comptime std.debug.runtime_safety) @memset(page_buf, 0);

        // Initialize the first set of pages to contain our viewport so that
        // the top of the first page is always the active area.
        node.* = .{
            .data = Page.initBuf(
                OffsetBuf.init(page_buf),
                Page.layout(cap),
            ),
        };
        node.data.size.rows = @min(rem, node.data.capacity.rows);
        rem -= node.data.size.rows;

        // Add the page to the list
        page_list.append(node);
        page_size += page_buf.len;
    }

    assert(page_list.first != null);

    return .{ page_list, page_size };
}

/// Deinit the pagelist. If you own the memory pool (used clonePool) then
/// this will reset the pool and retain capacity.
pub fn deinit(self: *PageList) void {
    // Always deallocate our hashmap.
    self.tracked_pins.deinit(self.pool.alloc);

    // Go through our linked list and deallocate all pages that are
    // not standard size.
    const page_alloc = self.pool.pages.arena.child_allocator;
    var it = self.pages.first;
    while (it) |node| : (it = node.next) {
        if (node.data.memory.len > std_size) {
            page_alloc.free(node.data.memory);
        }
    }

    // Deallocate all the pages. We don't need to deallocate the list or
    // nodes because they all reside in the pool.
    if (self.pool_owned) {
        self.pool.deinit();
    } else {
        self.pool.reset(.{ .retain_capacity = {} });
    }
}

/// Reset the PageList back to an empty state. This is similar to
/// deinit and reinit but it importantly preserves the pointer
/// stability of tracked pins (they're moved to the top-left since
/// all contents are cleared).
///
/// This can't fail because we always retain at least enough allocated
/// memory to fit the active area.
pub fn reset(self: *PageList) void {
    // We need enough pages/nodes to keep our active area. This should
    // never fail since we by definition have allocated a page already
    // that fits our size but I'm not confident to make that assertion.
    const cap = std_capacity.adjust(
        .{ .cols = self.cols },
    ) catch @panic("reset: std_capacity.adjust failed");
    assert(cap.rows > 0); // adjust should never return 0 rows

    // The number of pages we need is the number of rows in the active
    // area divided by the row capacity of a page.
    const page_count = std.math.divCeil(
        usize,
        self.rows,
        cap.rows,
    ) catch unreachable;

    // Before resetting our pools we need to free any pages that
    // are non-standard size since those were allocated outside
    // the pool.
    {
        const page_alloc = self.pool.pages.arena.child_allocator;
        var it = self.pages.first;
        while (it) |node| : (it = node.next) {
            if (node.data.memory.len > std_size) {
                page_alloc.free(node.data.memory);
            }
        }
    }

    // Reset our pools to free as much memory as possible while retaining
    // the capacity for at least the minimum number of pages we need.
    // The return value is whether memory was reclaimed or not, but in
    // either case the pool is left in a valid state.
    _ = self.pool.pages.reset(.{
        .retain_with_limit = page_count * PagePool.item_size,
    });
    _ = self.pool.nodes.reset(.{
        .retain_with_limit = page_count * NodePool.item_size,
    });

    // Our page pool relies on mmap to zero our page memory. Since we're
    // retaining a certain amount of memory, it won't use mmap and won't
    // be zeroed. This block zeroes out all the memory in the pool arena.
    {
        // Note: we only have to do this for the page pool because the
        // nodes are always fully overwritten on each allocation.
        const page_arena = &self.pool.pages.arena;
        var it = page_arena.state.buffer_list.first;
        while (it) |node| : (it = node.next) {
            // The fully allocated buffer
            const alloc_buf = @as([*]u8, @ptrCast(node))[0..node.data];

            // The buffer minus our header
            const BufNode = @TypeOf(page_arena.state.buffer_list).Node;
            const data_buf = alloc_buf[@sizeOf(BufNode)..];
            @memset(data_buf, 0);
        }
    }

    // Initialize our pages. This should not be able to fail since
    // we retained the capacity for the minimum number of pages we need.
    self.pages, self.page_size = initPages(
        &self.pool,
        self.cols,
        self.rows,
    ) catch @panic("initPages failed");

    // Update all our tracked pins to point to our first page top-left
    {
        var it = self.tracked_pins.iterator();
        while (it.next()) |entry| {
            const p: *Pin = entry.key_ptr.*;
            p.node = self.pages.first.?;
            p.x = 0;
            p.y = 0;
        }
    }

    // Move our viewport back to the active area since everything is gone.
    self.viewport = .active;
}

pub const Clone = struct {
    /// The top and bottom (inclusive) points of the region to clone.
    /// The x coordinate is ignored; the full row is always cloned.
    top: point.Point,
    bot: ?point.Point = null,

    /// The allocator source for the clone operation. If this is alloc
    /// then the cloned pagelist will own and dealloc the memory on deinit.
    /// If this is pool then the caller owns the memory.
    memory: union(enum) {
        alloc: Allocator,
        pool: *MemoryPool,
    },

    // If this is non-null then cloning will attempt to remap the tracked
    // pins into the new cloned area and will keep track of the old to
    // new mapping in this map. If this is null, the cloned pagelist will
    // not retain any previously tracked pins except those required for
    // internal operations.
    //
    // Any pins not present in the map were not remapped.
    tracked_pins: ?*TrackedPinsRemap = null,

    pub const TrackedPinsRemap = std.AutoHashMap(*Pin, *Pin);
};

/// Clone this pagelist from the top to bottom (inclusive).
///
/// The viewport is always moved to the active area.
///
/// The cloned pagelist must contain at least enough rows for the active
/// area. If the region specified has less rows than the active area then
/// rows will be added to the bottom of the region to make up the difference.
pub fn clone(
    self: *const PageList,
    opts: Clone,
) !PageList {
    var it = self.pageIterator(.right_down, opts.top, opts.bot);

    // Setup our own memory pool if we have to.
    var owned_pool: ?MemoryPool = switch (opts.memory) {
        .pool => null,
        .alloc => |alloc| alloc: {
            // First, count our pages so our preheat is exactly what we need.
            var it_copy = it;
            const page_count: usize = page_count: {
                var count: usize = 0;
                while (it_copy.next()) |_| count += 1;
                break :page_count count;
            };

            // Setup our pools
            break :alloc try MemoryPool.init(
                alloc,
                std.heap.page_allocator,
                page_count,
            );
        },
    };
    errdefer if (owned_pool) |*pool| pool.deinit();

    // Create our memory pool we use
    const pool: *MemoryPool = switch (opts.memory) {
        .pool => |v| v,
        .alloc => &owned_pool.?,
    };

    // Our viewport pin is always undefined since our viewport in a clones
    // goes back to the top
    const viewport_pin = try pool.pins.create();
    var tracked_pins: PinSet = .{};
    errdefer tracked_pins.deinit(pool.alloc);
    try tracked_pins.putNoClobber(pool.alloc, viewport_pin, {});

    // Our list of pages
    var page_list: List = .{};
    errdefer {
        const page_alloc = pool.pages.arena.child_allocator;
        var page_it = page_list.first;
        while (page_it) |node| : (page_it = node.next) {
            if (node.data.memory.len > std_size) {
                page_alloc.free(node.data.memory);
            }
        }
    }

    // Copy our pages
    var total_rows: usize = 0;
    var page_size: usize = 0;
    while (it.next()) |chunk| {
        // Clone the page. We have to use createPageExt here because
        // we don't know if the source page has a standard size.
        const node = try createPageExt(
            pool,
            chunk.node.data.capacity,
            &page_size,
        );
        assert(node.data.capacity.rows >= chunk.end - chunk.start);
        defer node.data.assertIntegrity();
        node.data.size.rows = chunk.end - chunk.start;
        node.data.size.cols = chunk.node.data.size.cols;
        try node.data.cloneFrom(
            &chunk.node.data,
            chunk.start,
            chunk.end,
        );

        page_list.append(node);

        total_rows += node.data.size.rows;

        // Remap our tracked pins by changing the page and
        // offsetting the Y position based on the chunk start.
        if (opts.tracked_pins) |remap| {
            const pin_keys = self.tracked_pins.keys();
            for (pin_keys) |p| {
                // We're only interested in pins that were within the chunk.
                if (p.node != chunk.node or
                    p.y < chunk.start or
                    p.y >= chunk.end) continue;
                const new_p = try pool.pins.create();
                new_p.* = p.*;
                new_p.node = node;
                new_p.y -= chunk.start;
                try remap.putNoClobber(p, new_p);
                try tracked_pins.putNoClobber(pool.alloc, new_p, {});
            }
        }
    }

    var result: PageList = .{
        .pool = pool.*,
        .pool_owned = switch (opts.memory) {
            .pool => false,
            .alloc => true,
        },
        .pages = page_list,
        .page_size = page_size,
        .explicit_max_size = self.explicit_max_size,
        .min_max_size = self.min_max_size,
        .cols = self.cols,
        .rows = self.rows,
        .tracked_pins = tracked_pins,
        .viewport = .{ .active = {} },
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
    if (comptime std.debug.runtime_safety) {
        // Resize does not work with 0 values, this should be protected
        // upstream
        if (opts.cols) |v| assert(v > 0);
        if (opts.rows) |v| assert(v > 0);
    }

    if (!opts.reflow) return try self.resizeWithoutReflow(opts);

    // Recalculate our minimum max size. This allows grow to work properly
    // when increasing beyond our initial minimum max size or explicit max
    // size to fit the active area.
    const old_min_max_size = self.min_max_size;
    self.min_max_size = try minMaxSize(
        opts.cols orelse self.cols,
        opts.rows orelse self.rows,
    );
    errdefer self.min_max_size = old_min_max_size;

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

    // Update our cols. We have to do this early because grow() that we
    // may call below relies on this to calculate the proper page size.
    self.cols = cols;

    // If we have a cursor position (x,y), then we try under any col resizing
    // to keep the same number remaining active rows beneath it. This is a
    // very special case if you can imagine clearing the screen (i.e.
    // scrollClear), having an empty active area, and then resizing to less
    // cols then we don't want the active area to "jump" to the bottom and
    // pull down scrollback.
    const preserved_cursor: ?struct {
        tracked_pin: *Pin,
        remaining_rows: usize,
        wrapped_rows: usize,
    } = if (cursor) |c| cursor: {
        const p = self.pin(.{ .active = .{
            .x = c.x,
            .y = c.y,
        } }) orelse break :cursor null;

        const active_pin = self.pin(.{ .active = .{} });

        // We count how many wraps the cursor had before it to begin with
        // so that we can offset any additional wraps to avoid pushing the
        // original row contents in to the scrollback.
        const wrapped = wrapped: {
            var wrapped: usize = 0;

            var row_it = p.rowIterator(.left_up, active_pin);
            while (row_it.next()) |next| {
                const row = next.rowAndCell().row;
                if (row.wrap_continuation) wrapped += 1;
            }

            break :wrapped wrapped;
        };

        break :cursor .{
            .tracked_pin = try self.trackPin(p),
            .remaining_rows = self.rows - c.y - 1,
            .wrapped_rows = wrapped,
        };
    } else null;
    defer if (preserved_cursor) |c| self.untrackPin(c.tracked_pin);

    const first = self.pages.first.?;
    var it = self.rowIterator(.right_down, .{ .screen = .{} }, null);

    const dst_node = try self.createPage(try first.data.capacity.adjust(.{ .cols = cols }));
    dst_node.data.size.rows = 1;

    // Set our new page as the only page. This orphans the existing pages
    // in the list, but that's fine since we're gonna delete them anyway.
    self.pages.first = dst_node;
    self.pages.last = dst_node;

    var dst_cursor = ReflowCursor.init(dst_node);

    // Reflow all our rows.
    while (it.next()) |row| {
        try dst_cursor.reflowRow(self, row);

        // Once we're done reflowing a page, destroy it.
        if (row.y == row.node.data.size.rows - 1) {
            self.destroyNode(row.node);
        }
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

        const active_pin = self.pin(.{ .active = .{} });

        // We need to determine how many rows we wrapped from the original
        // and subtract that from the remaining rows we expect because if
        // we wrap down we don't want to push our original row contents into
        // the scrollback.
        const wrapped = wrapped: {
            var wrapped: usize = 0;

            var row_it = c.tracked_pin.rowIterator(.left_up, active_pin);
            while (row_it.next()) |next| {
                const row = next.rowAndCell().row;
                if (row.wrap_continuation) wrapped += 1;
            }

            break :wrapped wrapped;
        };

        const current = self.rows - active_pt.active.y - 1;

        var req_rows = c.remaining_rows;
        req_rows -|= wrapped -| c.wrapped_rows;
        req_rows -|= current;

        while (req_rows > 0) {
            _ = try self.grow();
            req_rows -= 1;
        }
    }
}

// We use a cursor to track where we are in the src/dst. This is very
// similar to Screen.Cursor, so see that for docs on individual fields.
// We don't use a Screen because we don't need all the same data and we
// do our best to optimize having direct access to the page memory.
const ReflowCursor = struct {
    x: size.CellCountInt,
    y: size.CellCountInt,
    pending_wrap: bool,
    node: *List.Node,
    page: *pagepkg.Page,
    page_row: *pagepkg.Row,
    page_cell: *pagepkg.Cell,
    new_rows: usize,

    fn init(node: *List.Node) ReflowCursor {
        const page = &node.data;
        const rows = page.rows.ptr(page.memory);
        return .{
            .x = 0,
            .y = 0,
            .pending_wrap = false,
            .node = node,
            .page = page,
            .page_row = &rows[0],
            .page_cell = &rows[0].cells.ptr(page.memory)[0],
            .new_rows = 0,
        };
    }

    /// Reflow the provided row in to this cursor.
    fn reflowRow(
        self: *ReflowCursor,
        list: *PageList,
        row: Pin,
    ) !void {
        const src_page: *Page = &row.node.data;
        const src_row = row.rowAndCell().row;
        const src_y = row.y;

        // Inherit increased styles or grapheme bytes from
        // the src page we're reflowing from for new pages.
        const cap = try src_page.capacity.adjust(.{ .cols = self.page.size.cols });

        const cells = src_row.cells.ptr(src_page.memory)[0..src_page.size.cols];

        var cols_len = src_page.size.cols;

        // If the row is wrapped, all empty cells are meaningful.
        if (!src_row.wrap) {
            while (cols_len > 0) {
                if (!cells[cols_len - 1].isEmpty()) break;
                cols_len -= 1;
            }

            // If the row has a semantic prompt then the blank row is meaningful
            // so we just consider pretend the first cell of the row isn't empty.
            if (cols_len == 0 and src_row.semantic_prompt != .unknown) cols_len = 1;
        }

        // Handle tracked pin adjustments.
        {
            const pin_keys = list.tracked_pins.keys();
            for (pin_keys) |p| {
                if (&p.node.data != src_page or
                    p.y != src_y) continue;

                // If this pin is in the blanks on the right and past the end
                // of the dst col width then we move it to the end of the dst
                // col width instead.
                if (p.x >= cols_len) {
                    p.x = @min(p.x, cap.cols - 1 - self.x);
                }

                // We increase our col len to at least include this pin.
                // This ensures that blank rows with pins are processed,
                // so that the pins can be properly remapped.
                cols_len = @max(cols_len, p.x + 1);
            }
        }

        // Defer processing of blank rows so that blank rows
        // at the end of the page list are never written.
        if (cols_len == 0) {
            // If this blank row was a wrap continuation somehow
            // then we won't need to write it since it should be
            // a part of the previously written row.
            if (!src_row.wrap_continuation) {
                self.new_rows += 1;
            }
            return;
        }

        // Our row isn't blank, write any new rows we deferred.
        while (self.new_rows > 0) {
            self.new_rows -= 1;
            try self.cursorScrollOrNewPage(list, cap);
        }

        self.copyRowMetadata(src_row);

        var x: usize = 0;
        while (x < cols_len) {
            if (self.pending_wrap) {
                self.page_row.wrap = true;
                try self.cursorScrollOrNewPage(list, cap);
                self.copyRowMetadata(src_row);
                self.page_row.wrap_continuation = true;
            }

            // Move any tracked pins from the source.
            {
                const pin_keys = list.tracked_pins.keys();
                for (pin_keys) |p| {
                    if (&p.node.data != src_page or
                        p.y != src_y or
                        p.x != x) continue;

                    p.node = self.node;
                    p.x = self.x;
                    p.y = self.y;
                }
            }

            const cell = &cells[x];
            x += 1;

            // std.log.warn("\nsrc_y={} src_x={} dst_y={} dst_x={} dst_cols={} cp={} wide={}", .{
            //     src_y,
            //     x,
            //     self.y,
            //     self.x,
            //     self.page.size.cols,
            //     cell.content.codepoint,
            //     cell.wide,
            // });

            // Copy cell contents.
            switch (cell.content_tag) {
                .codepoint,
                .codepoint_grapheme,
                => switch (cell.wide) {
                    .narrow => self.page_cell.* = cell.*,

                    .wide => if (self.page.size.cols > 1) {
                        if (self.x == self.page.size.cols - 1) {
                            // If there's a wide character in the last column of
                            // the reflowed page then we need to insert a spacer
                            // head and wrap before handling it.
                            self.page_cell.* = .{
                                .content_tag = .codepoint,
                                .content = .{ .codepoint = 0 },
                                .wide = .spacer_head,
                            };

                            // Decrement the source position so that when we
                            // loop we'll process this source cell again.
                            x -= 1;
                        } else {
                            self.page_cell.* = cell.*;
                        }
                    } else {
                        // Edge case, when resizing to 1 column, wide
                        // characters are just destroyed and replaced
                        // with empty narrow cells.
                        self.page_cell.content.codepoint = 0;
                        self.page_cell.wide = .narrow;
                        self.cursorForward();
                        // Skip spacer tail so it doesn't cause a wrap.
                        x += 1;
                        continue;
                    },

                    .spacer_tail => if (self.page.size.cols > 1) {
                        self.page_cell.* = cell.*;
                    } else {
                        // Edge case, when resizing to 1 column, wide
                        // characters are just destroyed and replaced
                        // with empty narrow cells, so we should just
                        // discard any spacer tails.
                        continue;
                    },

                    .spacer_head => {
                        // Spacer heads should be ignored. If we need a
                        // spacer head in our reflowed page, it is added
                        // when processing the wide cell it belongs to.
                        continue;
                    },
                },

                .bg_color_palette,
                .bg_color_rgb,
                => {
                    // These are guaranteed to have no style or grapheme
                    // data associated with them so we can fast path them.
                    self.page_cell.* = cell.*;
                    self.cursorForward();
                    continue;
                },
            }

            // These will create issues by trying to clone managed memory that
            // isn't set if the current dst row needs to be moved to a new page.
            // They'll be fixed once we do properly copy the relevant memory.
            self.page_cell.content_tag = .codepoint;
            self.page_cell.hyperlink = false;
            self.page_cell.style_id = stylepkg.default_id;

            // Copy grapheme data.
            if (cell.content_tag == .codepoint_grapheme) {
                // Copy the graphemes
                const cps = src_page.lookupGrapheme(cell).?;

                // If our page can't support an additional cell with
                // graphemes then we create a new page for this row.
                if (self.page.graphemeCount() >= self.page.graphemeCapacity()) {
                    try self.moveLastRowToNewPage(list, cap);
                } else {
                    // Attempt to allocate the space that would be required for
                    // these graphemes, and if it's not available, create a new
                    // page for this row.
                    if (self.page.grapheme_alloc.alloc(
                        u21,
                        self.page.memory,
                        cps.len,
                    )) |slice| {
                        self.page.grapheme_alloc.free(self.page.memory, slice);
                    } else |_| {
                        try self.moveLastRowToNewPage(list, cap);
                    }
                }

                // This shouldn't fail since we made sure we have space above.
                try self.page.setGraphemes(self.page_row, self.page_cell, cps);
            }

            // Copy hyperlink data.
            if (cell.hyperlink) {
                const src_id = src_page.lookupHyperlink(cell).?;
                const src_link = src_page.hyperlink_set.get(src_page.memory, src_id);

                // If our page can't support an additional cell with
                // a hyperlink ID then we create a new page for this row.
                if (self.page.hyperlinkCount() >= self.page.hyperlinkCapacity()) {
                    try self.moveLastRowToNewPage(list, cap);
                }

                const dst_id = self.page.hyperlink_set.addWithIdContext(
                    self.page.memory,
                    try src_link.dupe(src_page, self.page),
                    src_id,
                    .{ .page = self.page },
                ) catch id: {
                    // We have no space for this link,
                    // so make a new page for this row.
                    try self.moveLastRowToNewPage(list, cap);

                    break :id try self.page.hyperlink_set.addContext(
                        self.page.memory,
                        try src_link.dupe(src_page, self.page),
                        .{ .page = self.page },
                    );
                } orelse src_id;

                // We expect this to succeed due to the
                // hyperlinkCapacity check we did before.
                try self.page.setHyperlink(
                    self.page_row,
                    self.page_cell,
                    dst_id,
                );
            }

            // Copy style data.
            if (cell.hasStyling()) {
                const style = src_page.styles.get(
                    src_page.memory,
                    cell.style_id,
                ).*;

                const id = self.page.styles.addWithId(
                    self.page.memory,
                    style,
                    cell.style_id,
                ) catch id: {
                    // We have no space for this style,
                    // so make a new page for this row.
                    try self.moveLastRowToNewPage(list, cap);

                    break :id try self.page.styles.add(
                        self.page.memory,
                        style,
                    );
                } orelse cell.style_id;

                self.page_row.styled = true;

                self.page_cell.style_id = id;
            }

            // Copy Kitty virtual placeholder status
            if (cell.codepoint() == kitty.graphics.unicode.placeholder) {
                self.page_row.kitty_virtual_placeholder = true;
            }

            self.cursorForward();
        }

        // If the source row isn't wrapped then we should scroll afterwards.
        if (!src_row.wrap) {
            self.new_rows += 1;
        }
    }

    /// Create a new page in the provided list with the provided
    /// capacity then clone the row currently being worked on to
    /// it and delete it from the old page. Places cursor in the
    /// same position it was in in the old row in the new one.
    ///
    /// Asserts that the cursor is on the final row of the page.
    ///
    /// Expects that the provided capacity is sufficient to copy
    /// the row.
    ///
    /// If this is the only row in the page, the page is removed
    /// from the list after cloning the row.
    fn moveLastRowToNewPage(
        self: *ReflowCursor,
        list: *PageList,
        cap: Capacity,
    ) !void {
        assert(self.y == self.page.size.rows - 1);
        assert(!self.pending_wrap);

        const old_node = self.node;
        const old_page = self.page;
        const old_row = self.page_row;
        const old_x = self.x;

        try self.cursorNewPage(list, cap);

        // Restore the x position of the cursor.
        self.cursorAbsolute(old_x, 0);

        // We expect to have enough capacity to clone the row.
        try self.page.cloneRowFrom(old_page, self.page_row, old_row);

        // Clear the row from the old page and truncate it.
        old_page.clearCells(old_row, 0, self.page.size.cols);
        old_page.size.rows -= 1;

        // If that was the last row in that page
        // then we should remove it from the list.
        if (old_page.size.rows == 0) {
            list.pages.remove(old_node);
            list.destroyNode(old_node);
        }
    }

    /// True if this cursor is at the bottom of the page by capacity,
    /// i.e. we can't scroll anymore.
    fn bottom(self: *const ReflowCursor) bool {
        return self.y == self.page.capacity.rows - 1;
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

    fn cursorDown(self: *ReflowCursor) void {
        assert(self.y + 1 < self.page.size.rows);
        self.cursorAbsolute(self.x, self.y + 1);
    }

    /// Create a new row and move the cursor down.
    ///
    /// Asserts that the cursor is on the bottom row of the
    /// page and that there is capacity to add a new one.
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

    /// Create a new page in the provided list with the provided
    /// capacity and one row and move the cursor in to it at 0,0
    fn cursorNewPage(
        self: *ReflowCursor,
        list: *PageList,
        cap: Capacity,
    ) !void {
        // Remember our new row count so we can restore it
        // after reinitializing our cursor on the new page.
        const new_rows = self.new_rows;

        const node = try list.createPage(cap);
        node.data.size.rows = 1;
        list.pages.insertAfter(self.node, node);

        self.* = ReflowCursor.init(node);

        self.new_rows = new_rows;
    }

    /// Performs `cursorScroll` or `cursorNewPage` as necessary
    /// depending on if the cursor is currently at the bottom.
    fn cursorScrollOrNewPage(
        self: *ReflowCursor,
        list: *PageList,
        cap: Capacity,
    ) !void {
        if (self.bottom()) {
            try self.cursorNewPage(list, cap);
        } else {
            self.cursorScroll();
        }
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

fn resizeWithoutReflow(self: *PageList, opts: Resize) !void {
    // We only set the new min_max_size if we're not reflowing. If we are
    // reflowing, then resize handles this for us.
    const old_min_max_size = self.min_max_size;
    self.min_max_size = if (!opts.reflow) try minMaxSize(
        opts.cols orelse self.cols,
        opts.rows orelse self.rows,
    ) else old_min_max_size;
    errdefer self.min_max_size = old_min_max_size;

    // Important! We have to do cols first because cols may cause us to
    // destroy pages if we're increasing cols which will free up page_size
    // so that when we call grow() in the row mods, we won't prune.
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
                    const page = &chunk.node.data;
                    defer page.assertIntegrity();
                    const rows = page.rows.ptr(page.memory);
                    for (0..page.size.rows) |i| {
                        const row = &rows[i];
                        page.clearCells(row, cols, self.cols);
                    }

                    page.size.cols = cols;
                }

                // Update all our tracked pins. If they have an X
                // beyond the edge, clamp it.
                const pin_keys = self.tracked_pins.keys();
                for (pin_keys) |p| {
                    if (p.x >= cols) p.x = cols - 1;
                }

                self.cols = cols;
            },

            // Make our columns larger. This is a bit more complicated because
            // pages may not have the capacity for this. If they don't have
            // the capacity we need to allocate a new page and copy the data.
            .gt => {
                // See the comment in the while loop when setting self.cols
                const old_cols = self.cols;

                var it = self.pageIterator(.right_down, .{ .screen = .{} }, null);
                while (it.next()) |chunk| {
                    // We need to restore our old cols after we resize because
                    // we have an assertion on this and we want to be able to
                    // call this method multiple times.
                    self.cols = old_cols;
                    try self.resizeWithoutReflowGrowCols(cols, chunk);
                }

                self.cols = cols;
            },
        }
    }

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
                    const delta = rows - self.rows;
                    self.rows = rows;
                    for (0..delta) |_| _ = try self.grow();
                    break :gt;
                }

                // This must be set BEFORE any calls to grow() so that
                // grow() doesn't prune pages that we need for the active
                // area.
                self.rows = rows;

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
            },
        }

        if (build_config.slow_runtime_safety) {
            assert(self.totalRows() >= self.rows);
        }
    }
}

fn resizeWithoutReflowGrowCols(
    self: *PageList,
    cols: size.CellCountInt,
    chunk: PageIterator.Chunk,
) !void {
    assert(cols > self.cols);
    const page = &chunk.node.data;
    const cap = try page.capacity.adjust(.{ .cols = cols });

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
    const prev = chunk.node.prev;
    errdefer {
        var current = chunk.node.prev;
        while (current) |p| {
            if (current == prev) break;
            current = p.prev;
            self.pages.remove(p);
            self.destroyNode(p);
        }
    }

    // Keeps track of all our copied rows. Assertions at the end is that
    // we copied exactly our page size.
    var copied: size.CellCountInt = 0;

    // This function has an unfortunate side effect in that it causes memory
    // fragmentation on rows if the columns are increasing in a way that
    // shrinks capacity rows. If we have pages that don't divide evenly then
    // we end up creating a final page that is not using its full capacity.
    // If this chunk isn't the last chunk in the page list, then we've created
    // a page where we'll never reclaim that capacity. This makes our max size
    // calculation incorrect since we'll throw away data even though we have
    // excess capacity. To avoid this, we try to fill our previous page
    // first if it has capacity.
    //
    // This can fail for many reasons (can't fit styles/graphemes, etc.) so
    // if it fails then we give up and drop back into creating new pages.
    if (prev) |prev_node| prev: {
        const prev_page = &prev_node.data;

        // We only want scenarios where we have excess capacity.
        if (prev_page.size.rows >= prev_page.capacity.rows) break :prev;

        // We can copy as much as we can to fill the capacity or our
        // current page size.
        const len = @min(
            prev_page.capacity.rows - prev_page.size.rows,
            page.size.rows,
        );

        const src_rows = page.rows.ptr(page.memory)[0..len];
        const dst_rows = prev_page.rows.ptr(prev_page.memory)[prev_page.size.rows..];
        for (dst_rows, src_rows) |*dst_row, *src_row| {
            prev_page.size.rows += 1;
            copied += 1;
            prev_page.cloneRowFrom(
                page,
                dst_row,
                src_row,
            ) catch {
                // If an error happens, we undo our row copy and break out
                // into creating a new page.
                prev_page.size.rows -= 1;
                copied -= 1;
                break :prev;
            };
        }

        assert(copied == len);
        assert(prev_page.size.rows <= prev_page.capacity.rows);
    }

    // We need to loop because our col growth may force us
    // to split pages.
    while (copied < page.size.rows) {
        const new_node = try self.createPage(cap);
        defer new_node.data.assertIntegrity();

        // The length we can copy into the new page is at most the number
        // of rows in our cap. But if we can finish our source page we use that.
        const len = @min(cap.rows, page.size.rows - copied);

        // Perform the copy
        const y_start = copied;
        const y_end = copied + len;
        const src_rows = page.rows.ptr(page.memory)[y_start..y_end];
        const dst_rows = new_node.data.rows.ptr(new_node.data.memory)[0..len];
        for (dst_rows, src_rows) |*dst_row, *src_row| {
            new_node.data.size.rows += 1;
            errdefer new_node.data.size.rows -= 1;
            try new_node.data.cloneRowFrom(
                page,
                dst_row,
                src_row,
            );
        }
        copied = y_end;

        // Insert our new page
        self.pages.insertBefore(chunk.node, new_node);

        // Update our tracked pins that pointed to this previous page.
        const pin_keys = self.tracked_pins.keys();
        for (pin_keys) |p| {
            if (p.node != chunk.node or
                p.y < y_start or
                p.y >= y_end) continue;
            p.node = new_node;
            p.y -= y_start;
        }
    }
    assert(copied == page.size.rows);

    // Remove the old page.
    // Deallocate the old page.
    self.pages.remove(chunk.node);
    self.destroyNode(chunk.node);
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
    const bl_pin = self.getBottomRight(.screen).?;
    var it = bl_pin.rowIterator(.left_up, null);
    while (it.next()) |row_pin| {
        const cells = row_pin.cells(.all);

        // If the row has any text then we're done.
        if (pagepkg.Cell.hasTextAny(cells)) return trimmed;

        // If our tracked pins are in this row then we cannot trim it
        // because it implies some sort of importance. If we trimmed this
        // we'd invalidate this pin, as well.
        const pin_keys = self.tracked_pins.keys();
        for (pin_keys) |p| {
            if (p.node != row_pin.node or
                p.y != row_pin.y) continue;
            return trimmed;
        }

        // No text, we can trim this row. Because it has
        // no text we can also be sure it has no styling
        // so we don't need to worry about memory.
        row_pin.node.data.size.rows -= 1;
        if (row_pin.node.data.size.rows == 0) {
            self.erasePage(row_pin.node);
        } else {
            row_pin.node.data.assertIntegrity();
        }

        trimmed += 1;
        if (trimmed >= max) return trimmed;
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

    /// Jump forwards (positive) or backwards (negative) a set number of
    /// prompts. If the absolute value is greater than the number of prompts
    /// in either direction, jump to the furthest prompt in that direction.
    delta_prompt: isize,

    /// Scroll directly to a specific pin in the page. This will be set
    /// as the top left of the viewport (ignoring the pin x value).
    pin: Pin,
};

/// Scroll the viewport. This will never create new scrollback, allocate
/// pages, etc. This can only be used to move the viewport within the
/// previously allocated pages.
pub fn scroll(self: *PageList, behavior: Scroll) void {
    switch (behavior) {
        .active => self.viewport = .{ .active = {} },
        .top => self.viewport = .{ .top = {} },
        .pin => |p| {
            if (self.pinIsActive(p)) {
                self.viewport = .{ .active = {} };
                return;
            }

            self.viewport_pin.* = p;
            self.viewport = .{ .pin = {} };
        },
        .delta_prompt => |n| self.scrollPrompt(n),
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

/// Jump the viewport forwards (positive) or backwards (negative) a set number of
/// prompts (delta).
fn scrollPrompt(self: *PageList, delta: isize) void {
    // If we aren't jumping any prompts then we don't need to do anything.
    if (delta == 0) return;
    const delta_start: usize = @intCast(if (delta > 0) delta else -delta);
    var delta_rem: usize = delta_start;

    // Iterate and count the number of prompts we see.
    const viewport_pin = self.getTopLeft(.viewport);
    var it = viewport_pin.rowIterator(if (delta > 0) .right_down else .left_up, null);
    _ = it.next(); // skip our own row
    var prompt_pin: ?Pin = null;
    while (it.next()) |next| {
        const row = next.rowAndCell().row;
        switch (row.semantic_prompt) {
            .command, .unknown => {},
            .prompt, .prompt_continuation, .input => {
                delta_rem -= 1;
                prompt_pin = next;
            },
        }

        if (delta_rem == 0) break;
    }

    // If we found a prompt, we move to it. If the prompt is in the active
    // area we keep our viewport as active because we can't scroll DOWN
    // into the active area. Otherwise, we scroll up to the pin.
    if (prompt_pin) |p| {
        if (self.pinIsActive(p)) {
            self.viewport = .{ .active = {} };
        } else {
            self.viewport_pin.* = p;
            self.viewport = .{ .pin = {} };
        }
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

/// Returns the actual max size. This may be greater than the explicit
/// value if the explicit value is less than the min_max_size.
///
/// This value is a HEURISTIC. You cannot assert on this value. We may
/// exceed this value if required to fit the active area. This may be
/// required in some cases if the active area has a large number of
/// graphemes, styles, etc.
pub fn maxSize(self: *const PageList) usize {
    return @max(self.explicit_max_size, self.min_max_size);
}

/// Returns true if we need to grow into our active area.
fn growRequiredForActive(self: *const PageList) bool {
    var rows: usize = 0;
    var page = self.pages.last;
    while (page) |p| : (page = p.prev) {
        rows += p.data.size.rows;
        if (rows >= self.rows) return false;
    }

    return true;
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
        last.data.assertIntegrity();
        return null;
    }

    // Slower path: we have no space, we need to allocate a new page.

    // If allocation would exceed our max size, we prune the first page.
    // We don't need to reallocate because we can simply reuse that first
    // page.
    //
    // We only take this path if we have more than one page since pruning
    // reuses the popped page. It is possible to have a single page and
    // exceed the max size if that page was adjusted to be larger after
    // initial allocation.
    if (self.pages.first != null and
        self.pages.first != self.pages.last and
        self.page_size + PagePool.item_size > self.maxSize())
    prune: {
        // If we need to add more memory to ensure our active area is
        // satisfied then we do not prune.
        if (self.growRequiredForActive()) break :prune;

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

        // Update any tracked pins that point to this page to point to the
        // new first page to the top-left.
        const pin_keys = self.tracked_pins.keys();
        for (pin_keys) |p| {
            if (p.node != first) continue;
            p.node = self.pages.first.?;
            p.y = 0;
            p.x = 0;
        }

        // In this case we do NOT need to update page_size because
        // we're reusing an existing page so nothing has changed.

        first.data.assertIntegrity();
        return first;
    }

    // We need to allocate a new memory buffer.
    const next_node = try self.createPage(try std_capacity.adjust(.{ .cols = self.cols }));
    // we don't errdefer this because we've added it to the linked
    // list and its fine to have dangling unused pages.
    self.pages.append(next_node);
    next_node.data.size.rows = 1;

    // We should never be more than our max size here because we've
    // verified the case above.
    next_node.data.assertIntegrity();

    return next_node;
}

/// Adjust the capacity of the given page in the list.
pub const AdjustCapacity = struct {
    /// Adjust the number of styles in the page. This may be
    /// rounded up if necessary to fit alignment requirements,
    /// but it will never be rounded down.
    styles: ?usize = null,

    /// Adjust the number of available grapheme bytes in the page.
    grapheme_bytes: ?usize = null,

    /// Adjust the number of available hyperlink bytes in the page.
    hyperlink_bytes: ?usize = null,

    /// Adjust the number of available string bytes in the page.
    string_bytes: ?usize = null,
};

pub const AdjustCapacityError = Allocator.Error || Page.CloneFromError;

/// Adjust the capcaity of the given page in the list. This should
/// be used in cases where OutOfMemory is returned by some operation
/// i.e to increase style counts, grapheme counts, etc.
///
/// Adjustment works by increasing the capacity of the desired
/// dimension to a certain amount and increases the memory allocation
/// requirement for the backing memory of the page. We currently
/// never split pages or anything like that. Because increased allocation
/// has to happen outside our memory pool, its generally much slower
/// so pages should be sized to be large enough to handle all but
/// exceptional cases.
///
/// This can currently only INCREASE capacity size. It cannot
/// decrease capacity size. This limitation is only because we haven't
/// yet needed that use case. If we ever do, this can be added. Currently
/// any requests to decrease will be ignored.
pub fn adjustCapacity(
    self: *PageList,
    node: *List.Node,
    adjustment: AdjustCapacity,
) AdjustCapacityError!*List.Node {
    const page: *Page = &node.data;

    // We always start with the base capacity of the existing page. This
    // ensures we never shrink from what we need.
    var cap = page.capacity;

    // All ceilPowerOfTwo is unreachable because we're always same or less
    // bit width so maxInt is always possible.
    if (adjustment.styles) |v| {
        comptime assert(@bitSizeOf(@TypeOf(v)) <= @bitSizeOf(usize));
        const aligned = std.math.ceilPowerOfTwo(usize, v) catch unreachable;
        cap.styles = @max(cap.styles, aligned);
    }
    if (adjustment.grapheme_bytes) |v| {
        comptime assert(@bitSizeOf(@TypeOf(v)) <= @bitSizeOf(usize));
        const aligned = std.math.ceilPowerOfTwo(usize, v) catch unreachable;
        cap.grapheme_bytes = @max(cap.grapheme_bytes, aligned);
    }
    if (adjustment.hyperlink_bytes) |v| {
        comptime assert(@bitSizeOf(@TypeOf(v)) <= @bitSizeOf(usize));
        const aligned = std.math.ceilPowerOfTwo(usize, v) catch unreachable;
        cap.hyperlink_bytes = @max(cap.hyperlink_bytes, aligned);
    }
    if (adjustment.string_bytes) |v| {
        comptime assert(@bitSizeOf(@TypeOf(v)) <= @bitSizeOf(usize));
        const aligned = std.math.ceilPowerOfTwo(usize, v) catch unreachable;
        cap.string_bytes = @max(cap.string_bytes, aligned);
    }

    log.info("adjusting page capacity={}", .{cap});

    // Create our new page and clone the old page into it.
    const new_node = try self.createPage(cap);
    errdefer self.destroyNode(new_node);
    const new_page: *Page = &new_node.data;
    assert(new_page.capacity.rows >= page.capacity.rows);
    new_page.size.rows = page.size.rows;
    try new_page.cloneFrom(page, 0, page.size.rows);

    // Fix up all our tracked pins to point to the new page.
    const pin_keys = self.tracked_pins.keys();
    for (pin_keys) |p| {
        if (p.node != node) continue;
        p.node = new_node;
    }

    // Insert this page and destroy the old page
    self.pages.insertBefore(node, new_node);
    self.pages.remove(node);
    self.destroyNode(node);

    new_page.assertIntegrity();
    return new_node;
}

/// Create a new page node. This does not add it to the list and this
/// does not do any memory size accounting with max_size/page_size.
fn createPage(
    self: *PageList,
    cap: Capacity,
) Allocator.Error!*List.Node {
    // log.debug("create page cap={}", .{cap});
    return try createPageExt(&self.pool, cap, &self.page_size);
}

fn createPageExt(
    pool: *MemoryPool,
    cap: Capacity,
    total_size: ?*usize,
) Allocator.Error!*List.Node {
    var page = try pool.nodes.create();
    errdefer pool.nodes.destroy(page);

    const layout = Page.layout(cap);
    const pooled = layout.total_size <= std_size;
    const page_alloc = pool.pages.arena.child_allocator;

    // Our page buffer comes from our standard memory pool if it
    // is within our standard size since this is what the pool
    // dispenses. Otherwise, we use the heap allocator to allocate.
    const page_buf = if (pooled)
        try pool.pages.create()
    else
        try page_alloc.alignedAlloc(
            u8,
            std.mem.page_size,
            layout.total_size,
        );
    errdefer if (pooled)
        pool.pages.destroy(page_buf)
    else
        page_alloc.free(page_buf);

    // Required only with runtime safety because allocators initialize
    // to undefined, 0xAA.
    if (comptime std.debug.runtime_safety) @memset(page_buf, 0);

    page.* = .{ .data = Page.initBuf(OffsetBuf.init(page_buf), layout) };
    page.data.size.rows = 0;

    if (total_size) |v| {
        // Accumulate page size now. We don't assert or check max size
        // because we may exceed it here temporarily as we are allocating
        // pages before destroy.
        v.* += page_buf.len;
    }

    return page;
}

/// Destroy the memory of the given node in the PageList linked list
/// and return it to the pool. The node is assumed to already be removed
/// from the linked list.
fn destroyNode(self: *PageList, node: *List.Node) void {
    destroyNodeExt(&self.pool, node, &self.page_size);
}

fn destroyNodeExt(
    pool: *MemoryPool,
    node: *List.Node,
    total_size: ?*usize,
) void {
    const page: *Page = &node.data;

    // Update our accounting for page size
    if (total_size) |v| v.* -= page.memory.len;

    if (page.memory.len <= std_size) {
        // Reset the memory to zero so it can be reused
        @memset(page.memory, 0);
        pool.pages.destroy(@ptrCast(page.memory.ptr));
    } else {
        const page_alloc = pool.pages.arena.child_allocator;
        page_alloc.free(page.memory);
    }

    pool.nodes.destroy(node);
}

/// Fast-path function to erase exactly 1 row. Erasing means that the row
/// is completely REMOVED, not just cleared. All rows following the removed
/// row will be shifted up by 1 to fill the empty space.
///
/// Unlike eraseRows, eraseRow does not change the size of any pages. The
/// caller is responsible for adjusting the row count of the final page if
/// that behavior is required.
pub fn eraseRow(
    self: *PageList,
    pt: point.Point,
) !void {
    const pn = self.pin(pt).?;

    var node = pn.node;
    var rows = node.data.rows.ptr(node.data.memory.ptr);

    // In order to move the following rows up we rotate the rows array by 1.
    // The rotate operation turns e.g. [ 0 1 2 3 ] in to [ 1 2 3 0 ], which
    // works perfectly to move all of our elements where they belong.
    fastmem.rotateOnce(Row, rows[pn.y..node.data.size.rows]);

    // We adjust the tracked pins in this page, moving up any that were below
    // the removed row.
    {
        const pin_keys = self.tracked_pins.keys();
        for (pin_keys) |p| {
            if (p.node == node and p.y > pn.y) p.y -= 1;
        }
    }

    {
        // Set all the rows as dirty in this page
        var dirty = node.data.dirtyBitSet();
        dirty.setRangeValue(.{ .start = pn.y, .end = node.data.size.rows }, true);
    }

    // We iterate through all of the following pages in order to move their
    // rows up by 1 as well.
    while (node.next) |next| {
        const next_rows = next.data.rows.ptr(next.data.memory.ptr);

        // We take the top row of the page and clone it in to the bottom
        // row of the previous page, which gets rid of the top row that was
        // rotated down in the previous page, and accounts for the row in
        // this page that will be rotated down as well.
        //
        //  rotate -> clone --> rotate -> result
        //    0 -.      1         1         1
        //    1  |      2         2         2
        //    2  |      3         3         3
        //    3 <'      0 <.      4         4
        //   ---       --- |     ---       ---  <- page boundary
        //    4         4 -'      4 -.      5
        //    5         5         5  |      6
        //    6         6         6  |      7
        //    7         7         7 <'      4
        try node.data.cloneRowFrom(
            &next.data,
            &rows[node.data.size.rows - 1],
            &next_rows[0],
        );

        node = next;
        rows = next_rows;

        fastmem.rotateOnce(Row, rows[0..node.data.size.rows]);

        // Set all the rows as dirty
        var dirty = node.data.dirtyBitSet();
        dirty.setRangeValue(.{ .start = 0, .end = node.data.size.rows }, true);

        // Our tracked pins for this page need to be updated.
        // If the pin is in row 0 that means the corresponding row has
        // been moved to the previous page. Otherwise, move it up by 1.
        const pin_keys = self.tracked_pins.keys();
        for (pin_keys) |p| {
            if (p.node != node) continue;
            if (p.y == 0) {
                p.node = node.prev.?;
                p.y = p.node.data.size.rows - 1;
                continue;
            }
            p.y -= 1;
        }
    }

    // Clear the final row which was rotated from the top of the page.
    node.data.clearCells(&rows[node.data.size.rows - 1], 0, node.data.size.cols);
}

/// A variant of eraseRow that shifts only a bounded number of following
/// rows up, filling the space they leave behind with blank rows.
///
/// `limit` is exclusive of the erased row. A limit of 1 will erase the target
/// row and shift the row below in to its position, leaving a blank row below.
pub fn eraseRowBounded(
    self: *PageList,
    pt: point.Point,
    limit: usize,
) !void {
    // This function has a lot of repeated code in it because it is a hot path.
    //
    // To get a better idea of what's happening, read eraseRow first for more
    // in-depth explanatory comments. To avoid repetition, the only comments for
    // this function are for where it differs from eraseRow.

    const pn = self.pin(pt).?;

    var node: *List.Node = pn.node;
    var rows = node.data.rows.ptr(node.data.memory.ptr);

    // If the row limit is less than the remaining rows before the end of the
    // page, then we clear the row, rotate it to the end of the boundary limit
    // and update our pins.
    if (node.data.size.rows - pn.y > limit) {
        node.data.clearCells(&rows[pn.y], 0, node.data.size.cols);
        fastmem.rotateOnce(Row, rows[pn.y..][0 .. limit + 1]);

        // Set all the rows as dirty
        var dirty = node.data.dirtyBitSet();
        dirty.setRangeValue(.{ .start = pn.y, .end = pn.y + limit }, true);

        // Update pins in the shifted region.
        const pin_keys = self.tracked_pins.keys();
        for (pin_keys) |p| {
            if (p.node == node and
                p.y >= pn.y and
                p.y <= pn.y + limit)
            {
                if (p.y == 0) {
                    p.x = 0;
                } else {
                    p.y -= 1;
                }
            }
        }

        return;
    }

    fastmem.rotateOnce(Row, rows[pn.y..node.data.size.rows]);

    // All the rows in the page are dirty below the erased row.
    {
        var dirty = node.data.dirtyBitSet();
        dirty.setRangeValue(.{ .start = pn.y, .end = node.data.size.rows }, true);
    }

    // We need to keep track of how many rows we've shifted so that we can
    // determine at what point we need to do a partial shift on subsequent
    // pages.
    var shifted: usize = node.data.size.rows - pn.y;

    // Update tracked pins.
    {
        const pin_keys = self.tracked_pins.keys();
        for (pin_keys) |p| {
            if (p.node == node and p.y >= pn.y) {
                if (p.y == 0) {
                    p.x = 0;
                } else {
                    p.y -= 1;
                }
            }
        }
    }

    while (node.next) |next| {
        const next_rows = next.data.rows.ptr(next.data.memory.ptr);

        try node.data.cloneRowFrom(
            &next.data,
            &rows[node.data.size.rows - 1],
            &next_rows[0],
        );

        node = next;
        rows = next_rows;

        // We check to see if this page contains enough rows to satisfy the
        // specified limit, accounting for rows we've already shifted in prior
        // pages.
        //
        // The logic here is very similar to the one before the loop.
        const shifted_limit = limit - shifted;
        if (node.data.size.rows > shifted_limit) {
            node.data.clearCells(&rows[0], 0, node.data.size.cols);
            fastmem.rotateOnce(Row, rows[0 .. shifted_limit + 1]);

            // Set all the rows as dirty
            var dirty = node.data.dirtyBitSet();
            dirty.setRangeValue(.{ .start = 0, .end = shifted_limit }, true);

            // Update pins in the shifted region.
            const pin_keys = self.tracked_pins.keys();
            for (pin_keys) |p| {
                if (p.node != node or p.y > shifted_limit) continue;
                if (p.y == 0) {
                    p.node = node.prev.?;
                    p.y = p.node.data.size.rows - 1;
                    continue;
                }
                p.y -= 1;
            }

            return;
        }

        fastmem.rotateOnce(Row, rows[0..node.data.size.rows]);

        // Set all the rows as dirty
        var dirty = node.data.dirtyBitSet();
        dirty.setRangeValue(.{ .start = 0, .end = node.data.size.rows }, true);

        // Account for the rows shifted in this node.
        shifted += node.data.size.rows;

        // Update tracked pins.
        const pin_keys = self.tracked_pins.keys();
        for (pin_keys) |p| {
            if (p.node != node) continue;
            if (p.y == 0) {
                p.node = node.prev.?;
                p.y = p.node.data.size.rows - 1;
                continue;
            }
            p.y -= 1;
        }
    }

    // We reached the end of the page list before the limit, so we clear
    // the final row since it was rotated down from the top of this page.
    node.data.clearCells(&rows[node.data.size.rows - 1], 0, node.data.size.cols);
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
            // A rare special case is that we're deleting everything
            // in our linked list. erasePage requires at least one other
            // page so to handle this we reinit this page, set it to zero
            // size which will let us grow our active area back.
            if (chunk.node.next == null and chunk.node.prev == null) {
                const page = &chunk.node.data;
                erased += page.size.rows;
                page.reinit();
                page.size.rows = 0;
                break;
            }

            self.erasePage(chunk.node);
            erased += chunk.node.data.size.rows;
            continue;
        }

        // We are modifying our chunk so make sure it is in a good state.
        defer chunk.node.data.assertIntegrity();

        // The chunk is not a full page so we need to move the rows.
        // This is a cheap operation because we're just moving cell offsets,
        // not the actual cell contents.
        assert(chunk.start == 0);
        const rows = chunk.node.data.rows.ptr(chunk.node.data.memory);
        const scroll_amount = chunk.node.data.size.rows - chunk.end;
        for (0..scroll_amount) |i| {
            const src: *Row = &rows[i + chunk.end];
            const dst: *Row = &rows[i];
            const old_dst = dst.*;
            dst.* = src.*;
            src.* = old_dst;
        }

        // Clear our remaining cells that we didn't shift or swapped
        // in case we grow back into them.
        for (scroll_amount..chunk.node.data.size.rows) |i| {
            const row: *Row = &rows[i];
            chunk.node.data.clearCells(
                row,
                0,
                chunk.node.data.size.cols,
            );
        }

        // Update any tracked pins to shift their y. If it was in the erased
        // row then we move it to the top of this page.
        const pin_keys = self.tracked_pins.keys();
        for (pin_keys) |p| {
            if (p.node != chunk.node) continue;
            if (p.y >= chunk.end) {
                p.y -= chunk.end;
            } else {
                p.y = 0;
                p.x = 0;
            }
        }

        // Our new size is the amount we scrolled
        chunk.node.data.size.rows = @intCast(scroll_amount);
        erased += chunk.end;

        // Set all the rows as dirty
        var dirty = chunk.node.data.dirtyBitSet();
        dirty.setRangeValue(.{ .start = 0, .end = chunk.node.data.size.rows }, true);
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
        .top => if (self.pinIsActive(.{ .node = self.pages.first.? })) {
            self.viewport = .{ .active = {} };
        },
    }
}

/// Erase a single page, freeing all its resources. The page can be
/// anywhere in the linked list but must NOT be the final page in the
/// entire list (i.e. must not make the list empty).
fn erasePage(self: *PageList, node: *List.Node) void {
    assert(node.next != null or node.prev != null);

    // Update any tracked pins to move to the next page.
    const pin_keys = self.tracked_pins.keys();
    for (pin_keys) |p| {
        if (p.node != node) continue;
        p.node = node.next orelse node.prev orelse unreachable;
        p.y = 0;
        p.x = 0;
    }

    // Remove the page from the linked list
    self.pages.remove(node);
    self.destroyNode(node);
}

/// Returns the pin for the given point. The pin is NOT tracked so it
/// is only valid as long as the pagelist isn't modified.
///
/// This will return null if the point is out of bounds. The caller
/// should clamp the point to the bounds of the coordinate space if
/// necessary.
pub fn pin(self: *const PageList, pt: point.Point) ?Pin {
    // getTopLeft is much more expensive than checking the cols bounds
    // so we do this first.
    const x = pt.coord().x;
    if (x >= self.cols) return null;

    // Grab the top left and move to the point.
    var p = self.getTopLeft(pt).down(pt.coord().y) orelse return null;
    p.x = x;
    return p;
}

/// Convert the given pin to a tracked pin. A tracked pin will always be
/// automatically updated as the pagelist is modified. If the point the
/// pin points to is removed completely, the tracked pin will be updated
/// to the top-left of the screen.
pub fn trackPin(self: *PageList, p: Pin) Allocator.Error!*Pin {
    if (build_config.slow_runtime_safety) assert(self.pinIsValid(p));

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
    if (self.tracked_pins.swapRemove(p)) {
        self.pool.pins.destroy(p);
    }
}

pub fn countTrackedPins(self: *const PageList) usize {
    return self.tracked_pins.count();
}

/// Checks if a pin is valid for this pagelist. This is a very slow and
/// expensive operation since we traverse the entire linked list in the
/// worst case. Only for runtime safety/debug.
pub fn pinIsValid(self: *const PageList, p: Pin) bool {
    // This is very slow so we want to ensure we only ever
    // call this during slow runtime safety builds.
    comptime assert(build_config.slow_runtime_safety);

    var it = self.pages.first;
    while (it) |node| : (it = node.next) {
        if (node != p.node) continue;
        return p.y < node.data.size.rows and
            p.x < node.data.size.cols;
    }

    return false;
}

/// Returns the viewport for the given pin, preferring to pin to
/// "active" if the pin is within the active area.
fn pinIsActive(self: *const PageList, p: Pin) bool {
    // If the pin is in the active page, then we can quickly determine
    // if we're beyond the end.
    const active = self.getTopLeft(.active);
    if (p.node == active.node) return p.y >= active.y;

    var node_ = active.node.next;
    while (node_) |node| {
        // This loop is pretty fast because the active area is
        // never that large so this is at most one, two nodes for
        // reasonable terminals (including very large real world
        // ones).

        // A node forward in the active area is our node, so we're
        // definitely in the active area.
        if (node == p.node) return true;
        node_ = node.next;
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
    var coord: point.Coordinate = .{ .x = p.x };
    if (p.node == tl.node) {
        // If our top-left is after our y then we're outside the range.
        if (tl.y > p.y) return null;
        coord.y = p.y - tl.y;
    } else {
        coord.y += tl.node.data.size.rows - tl.y;
        var node_ = tl.node.next;
        while (node_) |node| : (node_ = node.next) {
            if (node == p.node) {
                coord.y += p.y;
                break;
            }

            coord.y += node.data.size.rows;
        } else {
            // We never saw our node, meaning we're outside the range.
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
    const rac = pt_pin.node.data.getRowAndCell(pt_pin.x, pt_pin.y);
    return .{
        .node = pt_pin.node,
        .row = rac.row,
        .cell = rac.cell,
        .row_idx = pt_pin.y,
        .col_idx = pt_pin.x,
    };
}

pub const EncodeUtf8Options = struct {
    /// The start and end points of the dump, both inclusive. The x will
    /// be ignored and the full row will always be dumped.
    tl: Pin,
    br: ?Pin = null,

    /// If true, this will unwrap soft-wrapped lines. If false, this will
    /// dump the screen as it is visually seen in a rendered window.
    unwrap: bool = true,

    /// See Page.EncodeUtf8Options.
    cell_map: ?*Page.CellMap = null,
};

/// Encode the pagelist to utf8 to the given writer.
///
/// The writer should be buffered; this function does not attempt to
/// efficiently write and often writes one byte at a time.
///
/// Note: this is tested using Screen.dumpString. This is a function that
/// predates this and is a thin wrapper around it so the tests all live there.
pub fn encodeUtf8(
    self: *const PageList,
    writer: anytype,
    opts: EncodeUtf8Options,
) anyerror!void {
    // We don't currently use self at all. There is an argument that this
    // function should live on Pin instead but there is some future we might
    // need state on here so... letting it go.
    _ = self;

    var page_opts: Page.EncodeUtf8Options = .{
        .unwrap = opts.unwrap,
        .cell_map = opts.cell_map,
    };
    var iter = opts.tl.pageIterator(.right_down, opts.br);
    while (iter.next()) |chunk| {
        const page: *const Page = &chunk.node.data;
        page_opts.start_y = chunk.start;
        page_opts.end_y = chunk.end;
        page_opts.preceding = try page.encodeUtf8(writer, page_opts);
    }
}

/// Log a debug diagram of the page list to the provided writer.
///
/// EXAMPLE:
///
///      +-----+ = PAGE 0
///  ... |     |
///   50 | foo |
///  ... |     |
///     +--------+ ACTIVE
///  124 |     | | 0
///  125 |Text | | 1
///      :  ^  : : = PIN 0
///  126 |Wrap…  | 2
///      +-----+ :
///      +-----+ : = PAGE 1
///    0 …ed   | | 3
///    1 | etc.| | 4
///      +-----+ :
///     +--------+
pub fn diagram(self: *const PageList, writer: anytype) !void {
    const active_pin = self.getTopLeft(.active);

    var active = false;
    var active_index: usize = 0;

    var page_index: usize = 0;
    var cols: usize = 0;

    var it = self.pageIterator(.right_down, .{ .screen = .{} }, null);
    while (it.next()) |chunk| : (page_index += 1) {
        cols = chunk.node.data.size.cols;

        // Whether we've just skipped some number of rows and drawn
        // an ellipsis row (this is reset when a row is not skipped).
        var skipped = false;

        for (0..chunk.node.data.size.rows) |y| {
            // Active header
            if (!active and
                chunk.node == active_pin.node and
                active_pin.y == y)
            {
                active = true;
                try writer.writeAll("     +-");
                try writer.writeByteNTimes('-', cols);
                try writer.writeAll("--+ ACTIVE");
                try writer.writeByte('\n');
            }

            // Page header
            if (y == 0) {
                try writer.writeAll("      +");
                try writer.writeByteNTimes('-', cols);
                try writer.writeByte('+');
                if (active) try writer.writeAll(" :");
                try writer.print(" = PAGE {}", .{page_index});
                try writer.writeByte('\n');
            }

            // Row contents
            {
                const row = chunk.node.data.getRow(y);
                const cells = chunk.node.data.getCells(row)[0..cols];

                var row_has_content = false;

                for (cells) |cell| {
                    if (cell.hasText()) {
                        row_has_content = true;
                        break;
                    }
                }

                // We don't want to print this row's contents
                // unless it has text or is in the active area.
                if (!active and !row_has_content) {
                    // If we haven't, draw an ellipsis row.
                    if (!skipped) {
                        try writer.writeAll("  ... :");
                        try writer.writeByteNTimes(' ', cols);
                        try writer.writeByte(':');
                        if (active) try writer.writeAll(" :");
                        try writer.writeByte('\n');
                    }
                    skipped = true;
                    continue;
                }

                skipped = false;

                // Left pad row number to 5 wide
                const y_digits = if (y == 0) 0 else std.math.log10_int(y);
                try writer.writeByteNTimes(' ', 4 - y_digits);
                try writer.print("{} ", .{y});

                // Left edge or wrap continuation marker
                try writer.writeAll(if (row.wrap_continuation) "…" else "|");

                // Row text
                if (row_has_content) {
                    for (cells) |*cell| {
                        // Skip spacer tails, since wide cells are, well, wide.
                        if (cell.wide == .spacer_tail) continue;

                        // Write non-printing bytes as base36, for convenience.
                        if (cell.codepoint() < ' ') {
                            try writer.writeByte("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"[cell.codepoint()]);
                            continue;
                        }
                        try writer.print("{u}", .{cell.codepoint()});
                        if (cell.hasGrapheme()) {
                            const grapheme = chunk.node.data.lookupGrapheme(cell).?;
                            for (grapheme) |cp| {
                                try writer.print("{u}", .{cp});
                            }
                        }
                    }
                } else {
                    try writer.writeByteNTimes(' ', cols);
                }

                // Right edge or wrap marker
                try writer.writeAll(if (row.wrap) "…" else "|");
                if (active) {
                    try writer.print(" | {}", .{active_index});
                    active_index += 1;
                }

                try writer.writeByte('\n');
            }

            // Tracked pin marker(s)
            pins: {
                // If we have more than 16 tracked pins in a row, oh well,
                // don't wanna bother making this function allocating.
                var pin_buf: [16]*Pin = undefined;
                var pin_count: usize = 0;
                const pin_keys = self.tracked_pins.keys();
                for (pin_keys) |p| {
                    if (p.node != chunk.node) continue;
                    if (p.y != y) continue;
                    pin_buf[pin_count] = p;
                    pin_count += 1;
                    if (pin_count >= pin_buf.len) return error.TooManyTrackedPinsInRow;
                }

                if (pin_count == 0) break :pins;

                const pins = pin_buf[0..pin_count];
                std.mem.sort(
                    *Pin,
                    pins,
                    {},
                    struct {
                        fn lt(_: void, a: *Pin, b: *Pin) bool {
                            return a.x < b.x;
                        }
                    }.lt,
                );

                try writer.writeAll("      :");
                var x: usize = 0;

                for (pins) |p| {
                    if (x > p.x) continue;
                    try writer.writeByteNTimes(' ', p.x - x);
                    try writer.writeByte('^');
                    x = p.x + 1;
                }

                try writer.writeByteNTimes(' ', cols - x);
                try writer.writeByte(':');

                if (active) try writer.writeAll(" :");

                try writer.print(" = PIN{s}", .{if (pin_count > 1) "S" else ""});

                x = pins[0].x;
                for (pins, 0..) |p, i| {
                    if (p.x != x) try writer.writeByte(',');
                    try writer.print(" {}", .{i});
                }

                try writer.writeByte('\n');
            }
        }

        // Page footer
        {
            try writer.writeAll("      +");
            try writer.writeByteNTimes('-', cols);
            try writer.writeByte('+');
            if (active) try writer.writeAll(" :");
            try writer.writeByte('\n');
        }
    }

    // Active footer
    {
        try writer.writeAll("     +-");
        try writer.writeByteNTimes('-', cols);
        try writer.writeAll("--+");
        try writer.writeByte('\n');
    }
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
                if (cell.x + 1 < cell.node.data.size.cols) {
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
                        copy.x = next_cell.node.data.size.cols - 1;
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
    offset: size.CellCountInt = 0,

    pub fn next(self: *RowIterator) ?Pin {
        const chunk = self.chunk orelse return null;
        const row: Pin = .{ .node = chunk.node, .y = self.offset };

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
                    // If we're at the start of the chunk and its a non-zero
                    // offset then we've reached a limit.
                    if (self.offset == chunk.start) {
                        self.chunk = null;
                    } else {
                        self.offset -= 1;
                    }
                }
            },
        }

        return row;
    }
};

/// Create an iterator that can be used to iterate all the rows in
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
                    const next_page = row.node.next orelse break :next null;
                    break :next .{ .node = next_page };
                };

                break :none .{
                    .node = row.node,
                    .start = row.y,
                    .end = row.node.data.size.rows,
                };
            },

            .count => |*limit| count: {
                assert(limit.* > 0); // should be handled already
                const len = @min(row.node.data.size.rows - row.y, limit.*);
                if (len > limit.*) {
                    self.row = row.down(len);
                    limit.* -= len;
                } else {
                    self.row = null;
                }

                break :count .{
                    .node = row.node,
                    .start = row.y,
                    .end = row.y + len,
                };
            },

            .row => |limit_row| row: {
                // If this is not the same page as our limit then we
                // can consume the entire page.
                if (limit_row.node != row.node) {
                    self.row = next: {
                        const next_page = row.node.next orelse break :next null;
                        break :next .{ .node = next_page };
                    };

                    break :row .{
                        .node = row.node,
                        .start = row.y,
                        .end = row.node.data.size.rows,
                    };
                }

                // If this is the same page then we only consume up to
                // the limit row.
                self.row = null;
                if (row.y > limit_row.y) return null;
                break :row .{
                    .node = row.node,
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
                    const next_page = row.node.prev orelse break :next null;
                    break :next .{
                        .node = next_page,
                        .y = next_page.data.size.rows - 1,
                    };
                };

                break :none .{
                    .node = row.node,
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
                    .node = row.node,
                    .start = row.y - len,
                    .end = row.y - 1,
                };
            },

            .row => |limit_row| row: {
                // If this is not the same page as our limit then we
                // can consume the entire page.
                if (limit_row.node != row.node) {
                    self.row = next: {
                        const next_page = row.node.prev orelse break :next null;
                        break :next .{
                            .node = next_page,
                            .y = next_page.data.size.rows - 1,
                        };
                    };

                    break :row .{
                        .node = row.node,
                        .start = 0,
                        .end = row.y + 1,
                    };
                }

                // If this is the same page then we only consume up to
                // the limit row.
                self.row = null;
                if (row.y < limit_row.y) return null;
                break :row .{
                    .node = row.node,
                    .start = limit_row.y,
                    .end = row.y + 1,
                };
            },
        };
    }

    pub const Chunk = struct {
        node: *List.Node,
        start: size.CellCountInt,
        end: size.CellCountInt,

        pub fn rows(self: Chunk) []Row {
            const rows_ptr = self.node.data.rows.ptr(self.node.data.memory);
            return rows_ptr[self.start..self.end];
        }

        /// Returns true if this chunk represents every row in the page.
        pub fn fullPage(self: Chunk) bool {
            return self.start == 0 and self.end == self.node.data.size.rows;
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

    if (build_config.slow_runtime_safety) {
        assert(tl_pin.eql(bl_pin) or tl_pin.before(bl_pin));
    }

    return switch (direction) {
        .right_down => tl_pin.pageIterator(.right_down, bl_pin),
        .left_up => bl_pin.pageIterator(.left_up, tl_pin),
    };
}

/// Get the top-left of the screen for the given tag.
pub fn getTopLeft(self: *const PageList, tag: point.Tag) Pin {
    return switch (tag) {
        // The full screen or history is always just the first page.
        .screen, .history => .{ .node = self.pages.first.? },

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
            var rem = self.rows;
            var it = self.pages.last;
            while (it) |node| : (it = node.prev) {
                if (rem <= node.data.size.rows) break :active .{
                    .node = node,
                    .y = node.data.size.rows - rem,
                };

                rem -= node.data.size.rows;
            }

            unreachable; // assertion: we always have enough rows for active
        },
    };
}

/// Returns the bottom right of the screen for the given tag. This can
/// return null because it is possible that a tag is not in the screen
/// (e.g. history does not yet exist).
pub fn getBottomRight(self: *const PageList, tag: point.Tag) ?Pin {
    return switch (tag) {
        .screen, .active => last: {
            const node = self.pages.last.?;
            break :last .{
                .node = node,
                .y = node.data.size.rows - 1,
                .x = node.data.size.cols - 1,
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
    var node_ = self.pages.first;
    while (node_) |node| {
        rows += node.data.size.rows;
        node_ = node.next;
    }

    return rows;
}

/// The total number of pages in this list.
fn totalPages(self: *const PageList) usize {
    var pages: usize = 0;
    var node_ = self.pages.first;
    while (node_) |node| {
        pages += 1;
        node_ = node.next;
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

/// Clear all dirty bits on all pages. This is not efficient since it
/// traverses the entire list of pages. This is used for testing/debugging.
pub fn clearDirty(self: *PageList) void {
    var page = self.pages.first;
    while (page) |p| {
        var set = p.data.dirtyBitSet();
        set.unsetAll();
        page = p.next;
    }
}

/// Returns true if the point is dirty, used for testing.
pub fn isDirty(self: *const PageList, pt: point.Point) bool {
    return self.getCell(pt).?.isDirty();
}

/// Mark a point as dirty, used for testing.
fn markDirty(self: *PageList, pt: point.Point) void {
    self.pin(pt).?.markDirty();
}

/// Represents an exact x/y coordinate within the screen. This is called
/// a "pin" because it is a fixed point within the pagelist direct to
/// a specific page pointer and memory offset. The benefit is that this
/// point remains valid even through scrolling without any additional work.
///
/// A downside is that  the pin is only valid until the pagelist is modified
/// in a way that may invalidate page pointers or shuffle rows, such as resizing,
/// erasing rows, etc.
///
/// A pin can also be "tracked" which means that it will be updated as the
/// PageList is modified.
///
/// The PageList maintains a list of active pin references and keeps them
/// all up to date as the pagelist is modified. This isn't cheap so callers
/// should limit the number of active pins as much as possible.
pub const Pin = struct {
    node: *List.Node,
    y: size.CellCountInt = 0,
    x: size.CellCountInt = 0,

    pub fn rowAndCell(self: Pin) struct {
        row: *pagepkg.Row,
        cell: *pagepkg.Cell,
    } {
        const rac = self.node.data.getRowAndCell(self.x, self.y);
        return .{ .row = rac.row, .cell = rac.cell };
    }

    pub const CellSubset = enum { all, left, right };

    /// Returns the cells for the row that this pin is on. The subset determines
    /// what subset of the cells are returned. The "left/right" subsets are
    /// inclusive of the x coordinate of the pin.
    pub fn cells(self: Pin, subset: CellSubset) []pagepkg.Cell {
        const rac = self.rowAndCell();
        const all = self.node.data.getCells(rac.row);
        return switch (subset) {
            .all => all,
            .left => all[0 .. self.x + 1],
            .right => all[self.x..],
        };
    }

    /// Returns the grapheme codepoints for the given cell. These are only
    /// the EXTRA codepoints and not the first codepoint.
    pub fn grapheme(self: Pin, cell: *const pagepkg.Cell) ?[]u21 {
        return self.node.data.lookupGrapheme(cell);
    }

    /// Returns the style for the given cell in this pin.
    pub fn style(self: Pin, cell: *const pagepkg.Cell) stylepkg.Style {
        if (cell.style_id == stylepkg.default_id) return .{};
        return self.node.data.styles.get(
            self.node.data.memory,
            cell.style_id,
        ).*;
    }

    /// Check if this pin is dirty.
    pub fn isDirty(self: Pin) bool {
        return self.node.data.isRowDirty(self.y);
    }

    /// Mark this pin location as dirty.
    pub fn markDirty(self: Pin) void {
        var set = self.node.data.dirtyBitSet();
        set.set(self.y);
    }

    /// Returns true if the row of this pin should never have its background
    /// color extended for filling padding space in the renderer. This is
    /// a set of heuristics that help making our padding look better.
    pub fn neverExtendBg(
        self: Pin,
        palette: *const color.Palette,
        default_background: color.RGB,
    ) bool {
        // Any semantic prompts should not have their background extended
        // because prompts often contain special formatting (such as
        // powerline) that looks bad when extended.
        const rac = self.rowAndCell();
        switch (rac.row.semantic_prompt) {
            .prompt, .prompt_continuation, .input => return true,
            .unknown, .command => {},
        }

        for (self.cells(.all)) |*cell| {
            // If any cell has a default background color then we don't
            // extend because the default background color probably looks
            // good enough as an extension.
            switch (cell.content_tag) {
                // If it is a background color cell, we check the color.
                .bg_color_palette, .bg_color_rgb => {
                    const s = self.style(cell);
                    const bg = s.bg(cell, palette) orelse return true;
                    if (bg.eql(default_background)) return true;
                },

                // If its a codepoint cell we can check the style.
                .codepoint, .codepoint_grapheme => {
                    // For codepoint containing, we also never extend bg
                    // if any cell has a powerline glyph because these are
                    // perfect-fit.
                    switch (cell.codepoint()) {
                        // Powerline
                        0xE0B0...0xE0C8,
                        0xE0CA,
                        0xE0CC...0xE0D2,
                        0xE0D4,
                        => return true,

                        else => {},
                    }

                    // Never extend a cell that has a default background.
                    // A default background is applied if there is no background
                    // on the style or the explicitly set background
                    // matches our default background.
                    const s = self.style(cell);
                    const bg = s.bg(cell, palette) orelse return true;
                    if (bg.eql(default_background)) return true;
                },
            }
        }

        return false;
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
        if (build_config.slow_runtime_safety) {
            if (limit) |l| {
                // Check the order according to the iteration direction.
                switch (direction) {
                    .right_down => assert(self.eql(l) or self.before(l)),
                    .left_up => assert(self.eql(l) or l.before(self)),
                }
            }
        }

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
        if (build_config.slow_runtime_safety) {
            if (top.node == bottom.node) {
                // If top is bottom, must be ordered.
                assert(top.y <= bottom.y);
                if (top.y == bottom.y) {
                    assert(top.x <= bottom.x);
                }
            } else {
                // If top is not bottom, top must be before bottom.
                var node_ = top.node.next;
                while (node_) |node| : (node_ = node.next) {
                    if (node == bottom.node) break;
                } else assert(false);
            }
        }

        if (self.node == top.node) {
            // If our pin is the top page and our y is less than the top y
            // then we can't possibly be between the top and bottom.
            if (self.y < top.y) return false;

            // If our y is after the top y but we're on the same page
            // then we're between the top and bottom if our y is less
            // than or equal to the bottom y if its the same page. If the
            // bottom is another page then it means that the range is
            // at least the full top page and since we're the same page
            // we're in the range.
            if (self.y > top.y) {
                return if (self.node == bottom.node)
                    self.y <= bottom.y
                else
                    true;
            }

            // Otherwise our y is the same as the top y, so we need to
            // check the x coordinate.
            assert(self.y == top.y);
            if (self.x < top.x) return false;
        }
        if (self.node == bottom.node) {
            // Our page is the bottom page so we're between the top and
            // bottom if our y is less than the bottom y.
            if (self.y > bottom.y) return false;
            if (self.y < bottom.y) return true;

            // If our y is the same, then we're between if we're before
            // or equal to the bottom x.
            assert(self.y == bottom.y);
            return self.x <= bottom.x;
        }

        // Our page isn't the top or bottom so we need to check if
        // our page is somewhere between the top and bottom.

        // Since our loop starts at top.page.next we need to check that
        // top != bottom because if they're the same then we can't possibly
        // be between them.
        if (top.node == bottom.node) return false;
        var node_ = top.node.next;
        while (node_) |node| : (node_ = node.next) {
            if (node == bottom.node) break;
            if (node == self.node) return true;
        }

        return false;
    }

    /// Returns true if self is before other. This is very expensive since
    /// it requires traversing the linked list of pages. This should not
    /// be called in performance critical paths.
    pub fn before(self: Pin, other: Pin) bool {
        if (self.node == other.node) {
            if (self.y < other.y) return true;
            if (self.y > other.y) return false;
            return self.x < other.x;
        }

        var node_ = self.node.next;
        while (node_) |node| : (node_ = node.next) {
            if (node == other.node) return true;
        }

        return false;
    }

    pub fn eql(self: Pin, other: Pin) bool {
        return self.node == other.node and
            self.y == other.y and
            self.x == other.x;
    }

    /// Move the pin left n columns. n must fit within the size.
    pub fn left(self: Pin, n: usize) Pin {
        assert(n <= self.x);
        var result = self;
        result.x -= std.math.cast(size.CellCountInt, n) orelse result.x;
        return result;
    }

    /// Move the pin right n columns. n must fit within the size.
    pub fn right(self: Pin, n: usize) Pin {
        assert(self.x + n < self.node.data.size.cols);
        var result = self;
        result.x +|= std.math.cast(size.CellCountInt, n) orelse
            std.math.maxInt(size.CellCountInt);
        return result;
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
        const rows = self.node.data.size.rows - (self.y + 1);
        if (n <= rows) return .{ .offset = .{
            .node = self.node,
            .y = std.math.cast(size.CellCountInt, self.y + n) orelse
                std.math.maxInt(size.CellCountInt),
            .x = self.x,
        } };

        // Need to traverse page links to find the page
        var node: *List.Node = self.node;
        var n_left: usize = n - rows;
        while (true) {
            node = node.next orelse return .{ .overflow = .{
                .end = .{
                    .node = node,
                    .y = node.data.size.rows - 1,
                    .x = self.x,
                },
                .remaining = n_left,
            } };
            if (n_left <= node.data.size.rows) return .{ .offset = .{
                .node = node,
                .y = std.math.cast(size.CellCountInt, n_left - 1) orelse
                    std.math.maxInt(size.CellCountInt),
                .x = self.x,
            } };
            n_left -= node.data.size.rows;
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
            .node = self.node,
            .y = std.math.cast(size.CellCountInt, self.y - n) orelse
                std.math.maxInt(size.CellCountInt),
            .x = self.x,
        } };

        // Need to traverse page links to find the page
        var node: *List.Node = self.node;
        var n_left: usize = n - self.y;
        while (true) {
            node = node.prev orelse return .{ .overflow = .{
                .end = .{ .node = node, .y = 0, .x = self.x },
                .remaining = n_left,
            } };
            if (n_left <= node.data.size.rows) return .{ .offset = .{
                .node = node,
                .y = std.math.cast(size.CellCountInt, node.data.size.rows - n_left) orelse
                    std.math.maxInt(size.CellCountInt),
                .x = self.x,
            } };
            n_left -= node.data.size.rows;
        }
    }
};

const Cell = struct {
    node: *List.Node,
    row: *pagepkg.Row,
    cell: *pagepkg.Cell,
    row_idx: size.CellCountInt,
    col_idx: size.CellCountInt,

    /// Returns true if this cell is marked as dirty.
    ///
    /// This is not very performant this is primarily used for assertions
    /// and testing.
    pub fn isDirty(self: Cell) bool {
        return self.node.data.isRowDirty(self.row_idx);
    }

    /// Get the cell style.
    ///
    /// Not meant for non-test usage since this is inefficient.
    pub fn style(self: Cell) stylepkg.Style {
        if (self.cell.style_id == stylepkg.default_id) return .{};
        return self.node.data.styles.get(
            self.node.data.memory,
            self.cell.style_id,
        ).*;
    }

    /// Gets the screen point for the given cell.
    ///
    /// This is REALLY expensive/slow so it isn't pub. This was built
    /// for debugging and tests. If you have a need for this outside of
    /// this file then consider a different approach and ask yourself very
    /// carefully if you really need this.
    pub fn screenPoint(self: Cell) point.Point {
        var y: size.CellCountInt = self.row_idx;
        var node_ = self.node;
        while (node_.prev) |node| {
            y += node.data.size.rows;
            node_ = node;
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
        .node = s.pages.first.?,
        .y = 0,
        .x = 0,
    }, s.getTopLeft(.active));
}

test "PageList init rows across two pages" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Find a cap that makes it so that rows don't fit on one page.
    const rows = 100;
    const cap = cap: {
        var cap = try std_capacity.adjust(.{ .cols = 50 });
        while (cap.rows >= rows) cap = try std_capacity.adjust(.{
            .cols = cap.cols + 50,
        });

        break :cap cap;
    };

    // Init
    var s = try init(alloc, cap.cols, rows, null);
    defer s.deinit();
    try testing.expect(s.viewport == .active);
    try testing.expect(s.pages.first != null);
    try testing.expectEqual(@as(usize, s.rows), s.totalRows());
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
            .node = s.pages.first.?,
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
            .node = s.pages.first.?,
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
            .node = s.pages.first.?,
            .y = 30,
            .x = 2,
        }).?);
    }

    // In history, invalid
    {
        try testing.expect(s.pointFromPin(.active, .{
            .node = s.pages.first.?,
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
    // Grow so we take up at least 5 pages.
    const page = &s.pages.last.?.data;
    var cur_page = s.pages.last.?;
    cur_page.data.pauseIntegrityChecks(true);
    for (0..page.capacity.rows * 5) |_| {
        if (try s.grow()) |new_page| {
            cur_page.data.pauseIntegrityChecks(false);
            cur_page = new_page;
            cur_page.data.pauseIntegrityChecks(true);
        }
    }
    cur_page.data.pauseIntegrityChecks(false);

    {
        try testing.expectEqual(point.Point{
            .active = .{
                .y = 0,
                .x = 2,
            },
        }, s.pointFromPin(.active, .{
            .node = s.pages.last.?,
            .y = 0,
            .x = 2,
        }).?);
    }

    // Prior page
    {
        try testing.expect(s.pointFromPin(.active, .{
            .node = s.pages.first.?,
            .y = 0,
            .x = 0,
        }) == null);
    }
}

test "PageList pointFromPin traverse pages" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();

    // Grow so we take up at least 2 pages.
    const page = &s.pages.last.?.data;
    var cur_page = s.pages.last.?;
    cur_page.data.pauseIntegrityChecks(true);
    for (0..page.capacity.rows * 2) |_| {
        if (try s.grow()) |new_page| {
            cur_page.data.pauseIntegrityChecks(false);
            cur_page = new_page;
            cur_page.data.pauseIntegrityChecks(true);
        }
    }
    cur_page.data.pauseIntegrityChecks(false);

    {
        const pages = s.totalPages();
        const page_cap = page.capacity.rows;
        const expected_y = page_cap * (pages - 2) + 5;

        try testing.expectEqual(point.Point{
            .screen = .{
                .y = @intCast(expected_y),
                .x = 2,
            },
        }, s.pointFromPin(.screen, .{
            .node = s.pages.last.?.prev.?,
            .y = 5,
            .x = 2,
        }).?);
    }

    // Prior page
    {
        try testing.expect(s.pointFromPin(.active, .{
            .node = s.pages.first.?,
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

test "PageList grow allows exceeding max size for active area" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Setup our initial page so that we fully take up one page.
    const cap = try std_capacity.adjust(.{ .cols = 5 });
    var s = try init(alloc, 5, cap.rows, 0);
    defer s.deinit();
    try testing.expectEqual(@as(usize, s.rows), s.totalRows());

    // Grow once because we guarantee at least two pages of
    // capacity so we want to get to that.
    _ = try s.grow();
    const start_pages = s.totalPages();
    try testing.expect(start_pages >= 2);

    // Surgically modify our pages so that they have a smaller size.
    {
        var it = s.pages.first;
        while (it) |page| : (it = page.next) {
            page.data.size.rows = 1;
            page.data.capacity.rows = 1;
        }
    }

    // Grow our row and ensure we don't prune pages because we need
    // enough for the active area.
    _ = try s.grow();
    try testing.expectEqual(start_pages + 1, s.totalPages());
}

test "PageList grow prune required with a single page" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, 0);
    defer s.deinit();

    // This block is all test setup. There is nothing required about this
    // behavior during a refactor. This is setting up a scenario that is
    // possible to trigger a bug (#2280).
    {
        // Adjust our capacity until our page is larger than the standard size.
        // This is important because it triggers a scenario where our calculated
        // minSize() which is supposed to accommodate 2 pages is no longer true.
        var cap = std_capacity;
        while (true) {
            cap.grapheme_bytes *= 2;
            const layout = Page.layout(cap);
            if (layout.total_size > std_size) break;
        }

        // Adjust to that capacity. After we should still have one page.
        _ = try s.adjustCapacity(
            s.pages.first.?,
            .{ .grapheme_bytes = cap.grapheme_bytes },
        );
        try testing.expect(s.pages.first != null);
        try testing.expect(s.pages.first == s.pages.last);
    }

    // Figure out the remaining number of rows. This is the amount that
    // can be added to the current page before we need to allocate a new
    // page.
    const rem = rem: {
        const page = s.pages.first.?;
        break :rem page.data.capacity.rows - page.data.size.rows;
    };
    for (0..rem) |_| try testing.expect(try s.grow() == null);

    // The next one we add will trigger a new page.
    const new = try s.grow();
    try testing.expect(new != null);
    try testing.expect(new != s.pages.first);
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

test "PageList: jump zero" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, null);
    defer s.deinit();
    try s.growRows(3);
    try testing.expect(s.pages.first == s.pages.last);
    const page = &s.pages.first.?.data;
    {
        const rac = page.getRowAndCell(0, 1);
        rac.row.semantic_prompt = .prompt;
    }
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;
    }

    s.scroll(.{ .delta_prompt = 0 });
    try testing.expect(s.viewport == .active);
}

test "Screen: jump to prompt" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, null);
    defer s.deinit();
    try s.growRows(3);
    try testing.expect(s.pages.first == s.pages.last);
    const page = &s.pages.first.?.data;
    {
        const rac = page.getRowAndCell(0, 1);
        rac.row.semantic_prompt = .prompt;
    }
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;
    }

    // Jump back
    {
        s.scroll(.{ .delta_prompt = -1 });
        try testing.expect(s.viewport == .pin);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 1,
        } }, s.pointFromPin(.screen, s.pin(.{ .viewport = .{} }).?).?);
    }
    {
        s.scroll(.{ .delta_prompt = -1 });
        try testing.expect(s.viewport == .pin);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 1,
        } }, s.pointFromPin(.screen, s.pin(.{ .viewport = .{} }).?).?);
    }

    // Jump forward
    {
        s.scroll(.{ .delta_prompt = 1 });
        try testing.expect(s.viewport == .active);
    }
    {
        s.scroll(.{ .delta_prompt = 1 });
        try testing.expect(s.viewport == .active);
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
        try testing.expect(cell.node == new);
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

    // Create a tracked pin in the first page
    const p = try s.trackPin(s.pin(.{ .screen = .{} }).?);
    defer s.untrackPin(p);
    try testing.expect(p.node == s.pages.first.?);

    // Next should create a new page, but it should reuse our first
    // page since we're at max size.
    const new = (try s.grow()).?;
    try testing.expect(s.pages.last.? == new);
    try testing.expectEqual(s.page_size, old_page_size);

    // Our first should now be page2 and our last should be page1
    try testing.expectEqual(page2_node, s.pages.first.?);
    try testing.expectEqual(page1_node, s.pages.last.?);

    // Our tracked pin should point to the top-left of the first page
    try testing.expect(p.node == s.pages.first.?);
    try testing.expect(p.x == 0);
    try testing.expect(p.y == 0);
}

test "PageList adjustCapacity to increase styles" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 2, 2, 0);
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = &s.pages.first.?.data;

        // Write all our data so we can assert its the same after
        for (0..s.rows) |y| {
            for (0..s.cols) |x| {
                const rac = page.getRowAndCell(x, y);
                rac.cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = @intCast(x) },
                };
            }
        }
    }

    // Increase our styles
    _ = try s.adjustCapacity(
        s.pages.first.?,
        .{ .styles = std_capacity.styles * 2 },
    );

    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = &s.pages.first.?.data;
        for (0..s.rows) |y| {
            for (0..s.cols) |x| {
                const rac = page.getRowAndCell(x, y);
                try testing.expectEqual(
                    @as(u21, @intCast(x)),
                    rac.cell.content.codepoint,
                );
            }
        }
    }
}

test "PageList adjustCapacity to increase graphemes" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 2, 2, 0);
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = &s.pages.first.?.data;

        // Write all our data so we can assert its the same after
        for (0..s.rows) |y| {
            for (0..s.cols) |x| {
                const rac = page.getRowAndCell(x, y);
                rac.cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = @intCast(x) },
                };
            }
        }
    }

    // Increase our graphemes
    _ = try s.adjustCapacity(
        s.pages.first.?,
        .{ .grapheme_bytes = std_capacity.grapheme_bytes * 2 },
    );

    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = &s.pages.first.?.data;
        for (0..s.rows) |y| {
            for (0..s.cols) |x| {
                const rac = page.getRowAndCell(x, y);
                try testing.expectEqual(
                    @as(u21, @intCast(x)),
                    rac.cell.content.codepoint,
                );
            }
        }
    }
}

test "PageList adjustCapacity to increase hyperlinks" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 2, 2, 0);
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = &s.pages.first.?.data;

        // Write all our data so we can assert its the same after
        for (0..s.rows) |y| {
            for (0..s.cols) |x| {
                const rac = page.getRowAndCell(x, y);
                rac.cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = @intCast(x) },
                };
            }
        }
    }

    // Increase our graphemes
    _ = try s.adjustCapacity(
        s.pages.first.?,
        .{ .hyperlink_bytes = @max(std_capacity.hyperlink_bytes * 2, 2048) },
    );

    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = &s.pages.first.?.data;
        for (0..s.rows) |y| {
            for (0..s.cols) |x| {
                const rac = page.getRowAndCell(x, y);
                try testing.expectEqual(
                    @as(u21, @intCast(x)),
                    rac.cell.content.codepoint,
                );
            }
        }
    }
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
        try testing.expect(chunk.node == s.pages.first.?);
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
    page1_node.data.pauseIntegrityChecks(true);
    for (0..page1.capacity.rows - page1.size.rows) |_| {
        try testing.expect(try s.grow() == null);
    }
    page1_node.data.pauseIntegrityChecks(false);
    try testing.expect(try s.grow() != null);

    // Iterate the active area
    var it = s.pageIterator(.right_down, .{ .active = .{} }, null);
    {
        const chunk = it.next().?;
        try testing.expect(chunk.node == s.pages.first.?);
        const start = chunk.node.data.size.rows - s.rows + 1;
        try testing.expectEqual(start, chunk.start);
        try testing.expectEqual(chunk.node.data.size.rows, chunk.end);
    }
    {
        const chunk = it.next().?;
        try testing.expect(chunk.node == s.pages.last.?);
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
    page1_node.data.pauseIntegrityChecks(true);
    for (0..page1.capacity.rows - page1.size.rows) |_| {
        try testing.expect(try s.grow() == null);
    }
    page1_node.data.pauseIntegrityChecks(false);
    try testing.expect(try s.grow() != null);

    // Iterate the active area
    var it = s.pageIterator(.right_down, .{ .history = .{} }, null);
    {
        const active_tl = s.getTopLeft(.active);
        const chunk = it.next().?;
        try testing.expect(chunk.node == s.pages.first.?);
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
        try testing.expect(chunk.node == s.pages.first.?);
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
    page1_node.data.pauseIntegrityChecks(true);
    for (0..page1.capacity.rows - page1.size.rows) |_| {
        try testing.expect(try s.grow() == null);
    }
    page1_node.data.pauseIntegrityChecks(false);
    try testing.expect(try s.grow() != null);

    // Iterate the active area
    var it = s.pageIterator(.left_up, .{ .active = .{} }, null);
    var count: usize = 0;
    {
        const chunk = it.next().?;
        try testing.expect(chunk.node == s.pages.last.?);
        const start: usize = 0;
        try testing.expectEqual(start, chunk.start);
        try testing.expectEqual(start + 1, chunk.end);
        count += chunk.end - chunk.start;
    }
    {
        const chunk = it.next().?;
        try testing.expect(chunk.node == s.pages.first.?);
        const start = chunk.node.data.size.rows - s.rows + 1;
        try testing.expectEqual(start, chunk.start);
        try testing.expectEqual(chunk.node.data.size.rows, chunk.end);
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
    page1_node.data.pauseIntegrityChecks(true);
    for (0..page1.capacity.rows - page1.size.rows) |_| {
        try testing.expect(try s.grow() == null);
    }
    page1_node.data.pauseIntegrityChecks(false);
    try testing.expect(try s.grow() != null);

    // Iterate the active area
    var it = s.pageIterator(.left_up, .{ .history = .{} }, null);
    {
        const active_tl = s.getTopLeft(.active);
        const chunk = it.next().?;
        try testing.expect(chunk.node == s.pages.first.?);
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
    var cur_page = s.pages.last.?;
    cur_page.data.pauseIntegrityChecks(true);
    for (0..page.capacity.rows * 5) |_| {
        if (try s.grow()) |new_page| {
            cur_page.data.pauseIntegrityChecks(false);
            cur_page = new_page;
            cur_page.data.pauseIntegrityChecks(true);
        }
    }
    cur_page.data.pauseIntegrityChecks(false);
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

test "PageList erase reaccounts page size" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();
    const start_size = s.page_size;

    // Grow so we take up at least 5 pages.
    const page = &s.pages.last.?.data;
    var cur_page = s.pages.last.?;
    cur_page.data.pauseIntegrityChecks(true);
    for (0..page.capacity.rows * 5) |_| {
        if (try s.grow()) |new_page| {
            cur_page.data.pauseIntegrityChecks(false);
            cur_page = new_page;
            cur_page.data.pauseIntegrityChecks(true);
        }
    }
    cur_page.data.pauseIntegrityChecks(false);
    try testing.expect(s.page_size > start_size);

    // Erase the entire history, we should be back to just our active set.
    s.eraseRows(.{ .history = .{} }, null);
    try testing.expectEqual(start_size, s.page_size);
}

test "PageList erase row with tracked pin resets to top-left" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();

    // Grow so we take up at least 5 pages.
    const page = &s.pages.last.?.data;
    var cur_page = s.pages.last.?;
    cur_page.data.pauseIntegrityChecks(true);
    for (0..page.capacity.rows * 5) |_| {
        if (try s.grow()) |new_page| {
            cur_page.data.pauseIntegrityChecks(false);
            cur_page = new_page;
            cur_page.data.pauseIntegrityChecks(true);
        }
    }
    cur_page.data.pauseIntegrityChecks(false);

    // Our total rows should be large
    try testing.expect(s.totalRows() > s.rows);

    // Put a tracked pin in the history
    const p = try s.trackPin(s.pin(.{ .history = .{} }).?);
    defer s.untrackPin(p);

    // Erase the entire history, we should be back to just our active set.
    s.eraseRows(.{ .history = .{} }, null);
    try testing.expectEqual(s.rows, s.totalRows());

    // Our pin should move to the first page
    try testing.expectEqual(s.pages.first.?, p.node);
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
    try testing.expectEqual(s.pages.first.?, p.node);
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
    try testing.expectEqual(s.pages.first.?, p.node);
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
    var cur_page = s.pages.last.?;
    cur_page.data.pauseIntegrityChecks(true);
    for (0..page.capacity.rows * 5) |_| {
        if (try s.grow()) |new_page| {
            cur_page.data.pauseIntegrityChecks(false);
            cur_page = new_page;
            cur_page.data.pauseIntegrityChecks(true);
        }
    }
    cur_page.data.pauseIntegrityChecks(false);

    // Move our viewport to the top
    s.scroll(.{ .delta_row = -@as(isize, @intCast(s.totalRows())) });
    try testing.expect(s.viewport == .pin);
    try testing.expect(s.viewport_pin.node == s.pages.first.?);

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
    var cur_page = s.pages.last.?;
    cur_page.data.pauseIntegrityChecks(true);
    for (0..page.capacity.rows * 5) |_| {
        if (try s.grow()) |new_page| {
            cur_page.data.pauseIntegrityChecks(false);
            cur_page = new_page;
            cur_page.data.pauseIntegrityChecks(true);
        }
    }
    cur_page.data.pauseIntegrityChecks(false);

    // Move our viewport to the top
    s.scroll(.{ .delta_row = -@as(isize, @intCast(s.totalRows())) });
    try testing.expect(s.viewport == .pin);
    try testing.expect(s.viewport_pin.node == s.pages.first.?);

    // Erase the entire history, we should be back to just our active set.
    s.eraseRows(.{ .history = .{} }, .{ .history = .{ .y = 2 } });
    try testing.expect(s.viewport == .pin);
    try testing.expect(s.viewport_pin.node == s.pages.first.?);
}

test "PageList erase resets viewport to active if top is inside active" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();

    // Grow so we take up at least 5 pages.
    const page = &s.pages.last.?.data;
    var cur_page = s.pages.last.?;
    cur_page.data.pauseIntegrityChecks(true);
    for (0..page.capacity.rows * 5) |_| {
        if (try s.grow()) |new_page| {
            cur_page.data.pauseIntegrityChecks(false);
            cur_page = new_page;
            cur_page.data.pauseIntegrityChecks(true);
        }
    }
    cur_page.data.pauseIntegrityChecks(false);

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

test "PageList erase a one-row active" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 1, null);
    defer s.deinit();
    try testing.expectEqual(@as(usize, 1), s.totalPages());

    // Write our letter
    const page = &s.pages.first.?.data;
    for (0..s.rows) |y| {
        const rac = page.getRowAndCell(0, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = 'A' },
        };
    }

    s.eraseRows(.{ .active = .{} }, .{ .active = .{} });
    try testing.expectEqual(s.rows, s.totalRows());

    // The row should be empty
    {
        const get = s.getCell(.{ .active = .{ .x = 0, .y = 0 } }).?;
        try testing.expectEqual(@as(u21, 0), get.cell.content.codepoint);
    }
}

test "PageList eraseRowBounded less than full row" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 10, null);
    defer s.deinit();

    // Pins
    const p_top = try s.trackPin(s.pin(.{ .active = .{ .y = 5, .x = 0 } }).?);
    defer s.untrackPin(p_top);
    const p_bot = try s.trackPin(s.pin(.{ .active = .{ .y = 8, .x = 0 } }).?);
    defer s.untrackPin(p_bot);
    const p_out = try s.trackPin(s.pin(.{ .active = .{ .y = 9, .x = 0 } }).?);
    defer s.untrackPin(p_out);

    // Erase only a few rows in our active
    try s.eraseRowBounded(.{ .active = .{ .y = 5 } }, 3);
    try testing.expectEqual(s.rows, s.totalRows());

    // The erased rows should be dirty
    try testing.expect(!s.isDirty(.{ .active = .{ .x = 0, .y = 4 } }));
    try testing.expect(s.isDirty(.{ .active = .{ .x = 0, .y = 5 } }));
    try testing.expect(s.isDirty(.{ .active = .{ .x = 0, .y = 6 } }));
    try testing.expect(s.isDirty(.{ .active = .{ .x = 0, .y = 7 } }));
    try testing.expect(!s.isDirty(.{ .active = .{ .x = 0, .y = 8 } }));

    try testing.expectEqual(s.pages.first.?, p_top.node);
    try testing.expectEqual(@as(usize, 4), p_top.y);
    try testing.expectEqual(@as(usize, 0), p_top.x);

    try testing.expectEqual(s.pages.first.?, p_bot.node);
    try testing.expectEqual(@as(usize, 7), p_bot.y);
    try testing.expectEqual(@as(usize, 0), p_bot.x);

    try testing.expectEqual(s.pages.first.?, p_out.node);
    try testing.expectEqual(@as(usize, 9), p_out.y);
    try testing.expectEqual(@as(usize, 0), p_out.x);
}

test "PageList eraseRowBounded with pin at top" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 10, null);
    defer s.deinit();

    // Pins
    const p_top = try s.trackPin(s.pin(.{ .active = .{ .y = 0, .x = 5 } }).?);
    defer s.untrackPin(p_top);

    // Erase only a few rows in our active
    try s.eraseRowBounded(.{ .active = .{ .y = 0 } }, 3);
    try testing.expectEqual(s.rows, s.totalRows());

    // The erased rows should be dirty
    try testing.expect(s.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(s.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(s.isDirty(.{ .active = .{ .x = 0, .y = 2 } }));
    try testing.expect(!s.isDirty(.{ .active = .{ .x = 0, .y = 3 } }));

    try testing.expectEqual(s.pages.first.?, p_top.node);
    try testing.expectEqual(@as(usize, 0), p_top.y);
    try testing.expectEqual(@as(usize, 0), p_top.x);
}

test "PageList eraseRowBounded full rows single page" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 10, null);
    defer s.deinit();

    // Pins
    const p_in = try s.trackPin(s.pin(.{ .active = .{ .y = 7, .x = 0 } }).?);
    defer s.untrackPin(p_in);
    const p_out = try s.trackPin(s.pin(.{ .active = .{ .y = 9, .x = 0 } }).?);
    defer s.untrackPin(p_out);

    // Erase only a few rows in our active
    try s.eraseRowBounded(.{ .active = .{ .y = 5 } }, 10);
    try testing.expectEqual(s.rows, s.totalRows());

    // The erased rows should be dirty
    try testing.expect(!s.isDirty(.{ .active = .{ .x = 0, .y = 4 } }));
    for (5..10) |y| try testing.expect(s.isDirty(.{ .active = .{
        .x = 0,
        .y = @intCast(y),
    } }));

    // Our pin should move to the first page
    try testing.expectEqual(s.pages.first.?, p_in.node);
    try testing.expectEqual(@as(usize, 6), p_in.y);
    try testing.expectEqual(@as(usize, 0), p_in.x);

    try testing.expectEqual(s.pages.first.?, p_out.node);
    try testing.expectEqual(@as(usize, 8), p_out.y);
    try testing.expectEqual(@as(usize, 0), p_out.x);
}

test "PageList eraseRowBounded full rows two pages" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 10, null);
    defer s.deinit();

    // Grow to two pages so our active area straddles
    {
        const page = &s.pages.last.?.data;
        page.pauseIntegrityChecks(true);
        for (0..page.capacity.rows - page.size.rows) |_| _ = try s.grow();
        page.pauseIntegrityChecks(false);
        try s.growRows(5);
        try testing.expectEqual(@as(usize, 2), s.totalPages());
        try testing.expectEqual(@as(usize, 5), s.pages.last.?.data.size.rows);
    }

    // Pins
    const p_first = try s.trackPin(s.pin(.{ .active = .{ .y = 4, .x = 0 } }).?);
    defer s.untrackPin(p_first);
    const p_first_out = try s.trackPin(s.pin(.{ .active = .{ .y = 3, .x = 0 } }).?);
    defer s.untrackPin(p_first_out);
    const p_in = try s.trackPin(s.pin(.{ .active = .{ .y = 8, .x = 0 } }).?);
    defer s.untrackPin(p_in);
    const p_out = try s.trackPin(s.pin(.{ .active = .{ .y = 9, .x = 0 } }).?);
    defer s.untrackPin(p_out);

    {
        try testing.expectEqual(s.pages.last.?.prev.?, p_first.node);
        try testing.expectEqual(@as(usize, p_first.node.data.size.rows - 1), p_first.y);
        try testing.expectEqual(@as(usize, 0), p_first.x);

        try testing.expectEqual(s.pages.last.?.prev.?, p_first_out.node);
        try testing.expectEqual(@as(usize, p_first_out.node.data.size.rows - 2), p_first_out.y);
        try testing.expectEqual(@as(usize, 0), p_first_out.x);

        try testing.expectEqual(s.pages.last.?, p_in.node);
        try testing.expectEqual(@as(usize, 3), p_in.y);
        try testing.expectEqual(@as(usize, 0), p_in.x);

        try testing.expectEqual(s.pages.last.?, p_out.node);
        try testing.expectEqual(@as(usize, 4), p_out.y);
        try testing.expectEqual(@as(usize, 0), p_out.x);
    }

    // Erase only a few rows in our active
    try s.eraseRowBounded(.{ .active = .{ .y = 4 } }, 4);

    // The erased rows should be dirty
    try testing.expect(!s.isDirty(.{ .active = .{ .x = 0, .y = 3 } }));
    for (4..8) |y| try testing.expect(s.isDirty(.{ .active = .{
        .x = 0,
        .y = @intCast(y),
    } }));

    // In page in first page is shifted
    try testing.expectEqual(s.pages.last.?.prev.?, p_first.node);
    try testing.expectEqual(@as(usize, p_first.node.data.size.rows - 2), p_first.y);
    try testing.expectEqual(@as(usize, 0), p_first.x);

    // Out page in first page should not be shifted
    try testing.expectEqual(s.pages.last.?.prev.?, p_first_out.node);
    try testing.expectEqual(@as(usize, p_first_out.node.data.size.rows - 2), p_first_out.y);
    try testing.expectEqual(@as(usize, 0), p_first_out.x);

    // In page is shifted
    try testing.expectEqual(s.pages.last.?, p_in.node);
    try testing.expectEqual(@as(usize, 2), p_in.y);
    try testing.expectEqual(@as(usize, 0), p_in.x);

    // Out page is not shifted
    try testing.expectEqual(s.pages.last.?, p_out.node);
    try testing.expectEqual(@as(usize, 4), p_out.y);
    try testing.expectEqual(@as(usize, 0), p_out.x);
}

test "PageList clone" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();
    try testing.expectEqual(@as(usize, s.rows), s.totalRows());

    var s2 = try s.clone(.{
        .top = .{ .screen = .{} },
        .memory = .{ .alloc = alloc },
    });
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

    var s2 = try s.clone(.{
        .top = .{ .screen = .{} },
        .bot = .{ .screen = .{ .y = 39 } },
        .memory = .{ .alloc = alloc },
    });
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

    var s2 = try s.clone(.{
        .top = .{ .screen = .{ .y = 10 } },
        .memory = .{ .alloc = alloc },
    });
    defer s2.deinit();
    try testing.expectEqual(@as(usize, 40), s2.totalRows());
}

test "PageList clone partial trimmed left reclaims styles" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 20, null);
    defer s.deinit();
    try testing.expectEqual(@as(usize, s.rows), s.totalRows());
    try s.growRows(30);

    // Style the rows we're trimming
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = &s.pages.first.?.data;

        const style: stylepkg.Style = .{ .flags = .{ .bold = true } };
        const style_id = try page.styles.add(page.memory, style);

        var it = s.rowIterator(.left_up, .{ .screen = .{} }, .{ .screen = .{ .y = 9 } });
        while (it.next()) |p| {
            const rac = p.rowAndCell();
            rac.row.styled = true;
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 'A' },
                .style_id = style_id,
            };
            page.styles.use(page.memory, style_id);
        }

        // We're over-counted by 1 because `add` implies `use`.
        page.styles.release(page.memory, style_id);

        // Expect to have one style
        try testing.expectEqual(1, page.styles.count());
    }

    var s2 = try s.clone(.{
        .top = .{ .screen = .{ .y = 10 } },
        .memory = .{ .alloc = alloc },
    });
    defer s2.deinit();
    try testing.expectEqual(@as(usize, 40), s2.totalRows());

    {
        try testing.expect(s2.pages.first == s2.pages.last);
        const page = &s2.pages.first.?.data;
        try testing.expectEqual(0, page.styles.count());
    }
}

test "PageList clone partial trimmed both" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 20, null);
    defer s.deinit();
    try testing.expectEqual(@as(usize, s.rows), s.totalRows());
    try s.growRows(30);

    var s2 = try s.clone(.{
        .top = .{ .screen = .{ .y = 10 } },
        .bot = .{ .screen = .{ .y = 35 } },
        .memory = .{ .alloc = alloc },
    });
    defer s2.deinit();
    try testing.expectEqual(@as(usize, 26), s2.totalRows());
}

test "PageList clone less than active" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();
    try testing.expectEqual(@as(usize, s.rows), s.totalRows());

    var s2 = try s.clone(.{
        .top = .{ .active = .{ .y = 5 } },
        .memory = .{ .alloc = alloc },
    });
    defer s2.deinit();
    try testing.expectEqual(@as(usize, s.rows), s2.totalRows());
}

test "PageList clone remap tracked pin" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();
    try testing.expectEqual(@as(usize, s.rows), s.totalRows());

    // Put a tracked pin in the screen
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 0, .y = 6 } }).?);
    defer s.untrackPin(p);

    var pin_remap = Clone.TrackedPinsRemap.init(alloc);
    defer pin_remap.deinit();
    var s2 = try s.clone(.{
        .top = .{ .active = .{ .y = 5 } },
        .memory = .{ .alloc = alloc },
        .tracked_pins = &pin_remap,
    });
    defer s2.deinit();

    // We should be able to find our tracked pin
    const p2 = pin_remap.get(p).?;
    try testing.expectEqual(
        point.Point{ .active = .{ .x = 0, .y = 1 } },
        s2.pointFromPin(.active, p2.*).?,
    );
}

test "PageList clone remap tracked pin not in cloned area" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();
    try testing.expectEqual(@as(usize, s.rows), s.totalRows());

    // Put a tracked pin in the screen
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 0, .y = 3 } }).?);
    defer s.untrackPin(p);

    var pin_remap = Clone.TrackedPinsRemap.init(alloc);
    defer pin_remap.deinit();
    var s2 = try s.clone(.{
        .top = .{ .active = .{ .y = 5 } },
        .memory = .{ .alloc = alloc },
        .tracked_pins = &pin_remap,
    });
    defer s2.deinit();

    // We should be able to find our tracked pin
    try testing.expect(pin_remap.get(p) == null);
}

test "PageList clone full dirty" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();
    try testing.expectEqual(@as(usize, s.rows), s.totalRows());

    // Mark a row as dirty
    s.markDirty(.{ .active = .{ .x = 0, .y = 0 } });
    s.markDirty(.{ .active = .{ .x = 0, .y = 12 } });
    s.markDirty(.{ .active = .{ .x = 0, .y = 23 } });

    var s2 = try s.clone(.{
        .top = .{ .screen = .{} },
        .memory = .{ .alloc = alloc },
    });
    defer s2.deinit();
    try testing.expectEqual(@as(usize, s.rows), s2.totalRows());

    // Should still be dirty
    try testing.expect(s2.isDirty(.{ .active = .{ .x = 0, .y = 0 } }));
    try testing.expect(!s2.isDirty(.{ .active = .{ .x = 0, .y = 1 } }));
    try testing.expect(s2.isDirty(.{ .active = .{ .x = 0, .y = 12 } }));
    try testing.expect(!s2.isDirty(.{ .active = .{ .x = 0, .y = 14 } }));
    try testing.expect(s2.isDirty(.{ .active = .{ .x = 0, .y = 23 } }));
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

test "PageList resize (no reflow) one rows" {
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
    try s.resize(.{ .rows = 1, .reflow = false });
    try testing.expectEqual(@as(usize, 1), s.rows);
    try testing.expectEqual(@as(usize, 10), s.totalRows());
    {
        const pt = s.getCell(.{ .active = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 9,
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

test "PageList resize (no reflow) less rows trims blank lines cursor in blank line" {
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

    // Put a tracked pin in a blank line
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 0, .y = 3 } }).?);
    defer s.untrackPin(p);

    // Resize
    try s.resize(.{ .rows = 2, .reflow = false });
    try testing.expectEqual(@as(usize, 2), s.rows);
    try testing.expectEqual(@as(usize, 4), s.totalRows());

    // Our cursor should not move since we trimmed
    try testing.expectEqual(point.Point{ .active = .{
        .x = 0,
        .y = 1,
    } }, s.pointFromPin(.active, p.*).?);
}

test "PageList resize (no reflow) less rows trims blank lines erases pages" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 100, 5, 0);
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = &s.pages.first.?.data;

    // Resize to take up two pages
    {
        const rows = page.capacity.rows + 10;
        try s.resize(.{ .rows = rows, .reflow = false });
        try testing.expectEqual(@as(usize, 2), s.totalPages());
    }

    // Write codepoint into first line
    {
        const rac = page.getRowAndCell(0, 0);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = 'A' },
        };
    }

    // Resize down. Every row except the first is blank so we
    // should erase the second page.
    try s.resize(.{ .rows = 5, .reflow = false });
    try testing.expectEqual(@as(usize, 5), s.rows);
    try testing.expectEqual(@as(usize, 5), s.totalRows());
    try testing.expectEqual(@as(usize, 1), s.totalPages());
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
        const cells = offset.node.data.getCells(rac.row);
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
        const cells = offset.node.data.getCells(rac.row);
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
        try testing.expectEqual(@as(usize, 0), chunk.node.data.graphemeCount());
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
        const cells = offset.node.data.getCells(rac.row);
        try testing.expectEqual(@as(usize, 10), cells.len);
    }
}

test "PageList resize (no reflow) more cols with spacer head" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 2, 3, 0);
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
                .content = .{ .codepoint = 0 },
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
                .content = .{ .codepoint = 0 },
                .wide = .spacer_tail,
            };
        }
    }

    // Resize
    try s.resize(.{ .cols = 3, .reflow = false });
    try testing.expectEqual(@as(usize, 3), s.cols);
    try testing.expectEqual(@as(usize, 3), s.totalRows());

    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = &s.pages.first.?.data;

        {
            const rac = page.getRowAndCell(0, 0);
            try testing.expectEqual(@as(u21, 'x'), rac.cell.content.codepoint);
            try testing.expectEqual(pagepkg.Cell.Wide.narrow, rac.cell.wide);
            // try testing.expect(!rac.row.wrap);
        }
        {
            const rac = page.getRowAndCell(1, 0);
            try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint);
            try testing.expectEqual(pagepkg.Cell.Wide.narrow, rac.cell.wide);
        }
        {
            const rac = page.getRowAndCell(2, 0);
            try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint);
            try testing.expectEqual(pagepkg.Cell.Wide.narrow, rac.cell.wide);
        }
    }
}

// This test is a bit convoluted so I want to explain: what we are trying
// to verify here is that when we increase cols such that our rows per page
// shrinks, we don't fragment our rows across many pages because this ends
// up wasting a lot of memory.
//
// This is particularly important for alternate screen buffers where we
// don't have scrollback so our max size is very small. If we don't do this,
// we end up pruning our pages and that causes resizes to fail!
test "PageList resize (no reflow) more cols forces less rows per page" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // This test requires initially that our rows fit into one page.
    const cols: size.CellCountInt = 5;
    const rows: size.CellCountInt = 150;
    try testing.expect((try std_capacity.adjust(.{ .cols = cols })).rows >= rows);
    var s = try init(alloc, cols, rows, 0);
    defer s.deinit();

    // Then we need to resize our cols so that our rows per page shrinks.
    // This will force our resize to split our rows across two pages.
    {
        const new_cols = new_cols: {
            var new_cols: size.CellCountInt = 50;
            var cap = try std_capacity.adjust(.{ .cols = new_cols });
            while (cap.rows >= rows) {
                new_cols += 50;
                cap = try std_capacity.adjust(.{ .cols = new_cols });
            }

            break :new_cols new_cols;
        };
        try s.resize(.{ .cols = new_cols, .reflow = false });
        try testing.expectEqual(@as(usize, new_cols), s.cols);
        try testing.expectEqual(@as(usize, rows), s.totalRows());
    }

    // Every page except the last should be full
    {
        var it = s.pages.first;
        while (it) |page| : (it = page.next) {
            if (page == s.pages.last.?) break;
            try testing.expectEqual(page.data.capacity.rows, page.data.size.rows);
        }
    }

    // Now we need to resize again to a col size that further shrinks
    // our last capacity.
    {
        const page = &s.pages.first.?.data;
        try testing.expect(page.size.rows == page.capacity.rows);
        const new_cols = new_cols: {
            var new_cols = page.size.cols + 50;
            var cap = try std_capacity.adjust(.{ .cols = new_cols });
            while (cap.rows >= page.size.rows) {
                new_cols += 50;
                cap = try std_capacity.adjust(.{ .cols = new_cols });
            }

            break :new_cols new_cols;
        };

        try s.resize(.{ .cols = new_cols, .reflow = false });
        try testing.expectEqual(@as(usize, new_cols), s.cols);
        try testing.expectEqual(@as(usize, rows), s.totalRows());
    }

    // Every page except the last should be full
    {
        var it = s.pages.first;
        while (it) |page| : (it = page.next) {
            if (page == s.pages.last.?) break;
            try testing.expectEqual(page.data.capacity.rows, page.data.size.rows);
        }
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
        const cells = offset.node.data.getCells(rac.row);
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
        const cells = offset.node.data.getCells(rac.row);
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
        const cells = offset.node.data.getCells(rac.row);
        try testing.expectEqual(@as(usize, 5), cells.len);
    }
}

test "PageList resize more rows and cols doesn't fit in single std page" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 10, 0);
    defer s.deinit();

    // Resize to a size that requires more than one page to fit our rows.
    const new_cols = 600;
    const new_rows = 600;
    const cap = try std_capacity.adjust(.{ .cols = new_cols });
    try testing.expect(cap.rows < new_rows);

    try s.resize(.{ .cols = new_cols, .rows = new_rows, .reflow = true });
    try testing.expectEqual(@as(usize, new_cols), s.cols);
    try testing.expectEqual(@as(usize, new_rows), s.rows);
    try testing.expectEqual(@as(usize, new_rows), s.totalRows());
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
        const cells = offset.node.data.getCells(rac.row);
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
        const cells = offset.node.data.getCells(rac.row);
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
        const get = s.getCell(.{ .active = .{ .y = @intCast(y) } }).?;
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
        const cells = offset.node.data.getCells(rac.row);
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
        const cells = offset.node.data.getCells(rac.row);
        try testing.expect(!rac.row.wrap);
        try testing.expectEqual(@as(usize, 4), cells.len);
        try testing.expectEqual(@as(u21, 'A'), cells[0].content.codepoint);
        try testing.expectEqual(@as(u21, 'A'), cells[2].content.codepoint);
    }
}

test "PageList resize reflow more cols creates multiple pages" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // We want a wide viewport so our row limit is rather small. This will
    // force the reflow below to create multiple pages, which we assert.
    const cap = cap: {
        var current: size.CellCountInt = 100;
        while (true) : (current += 100) {
            const cap = try std_capacity.adjust(.{ .cols = current });
            if (cap.rows < 100) break :cap cap;
        }
        unreachable;
    };

    var s = try init(alloc, cap.cols, cap.rows, null);
    defer s.deinit();

    // Wrap every other row so every line is wrapped for reflow
    {
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

            const rac = page.getRowAndCell(0, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 'A' },
            };
        }
    }

    // Resize
    const newcap = try cap.adjust(.{ .cols = cap.cols + 100 });
    try testing.expect(newcap.rows < cap.rows);
    try s.resize(.{ .cols = newcap.cols, .reflow = true });
    try testing.expectEqual(@as(usize, newcap.cols), s.cols);
    try testing.expectEqual(@as(usize, cap.rows), s.totalRows());

    {
        var count: usize = 0;
        var it = s.pages.first;
        while (it) |page| : (it = page.next) {
            count += 1;

            // All pages should have the new capacity
            try testing.expectEqual(newcap.cols, page.data.capacity.cols);
            try testing.expectEqual(newcap.rows, page.data.capacity.rows);
        }

        // We should have more than one page, meaning we created at least
        // one page. This is the critical aspect of this test so if this
        // ever goes false we need to adjust this test.
        try testing.expect(count > 1);
    }
}

test "PageList resize reflow more cols wrap across page boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 2, 10, 0);
    defer s.deinit();
    try testing.expectEqual(@as(usize, 1), s.totalPages());

    // Grow to the capacity of the first page.
    {
        const page = &s.pages.first.?.data;
        page.pauseIntegrityChecks(true);
        for (page.size.rows..page.capacity.rows) |_| {
            _ = try s.grow();
        }
        page.pauseIntegrityChecks(false);
        try testing.expectEqual(@as(usize, 1), s.totalPages());
        try s.growRows(1);
        try testing.expectEqual(@as(usize, 2), s.totalPages());
    }

    // At this point, we have some rows on the first page, and some on the second.
    // We can now wrap across the boundary condition.
    {
        const page = &s.pages.first.?.data;
        const y = page.size.rows - 1;
        {
            const rac = page.getRowAndCell(0, y);
            rac.row.wrap = true;
        }
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = @intCast(x) },
            };
        }
    }
    {
        const page2 = &s.pages.last.?.data;
        const y = 0;
        {
            const rac = page2.getRowAndCell(0, y);
            rac.row.wrap_continuation = true;
        }
        for (0..s.cols) |x| {
            const rac = page2.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = @intCast(x) },
            };
        }
    }

    // PageList.diagram ->
    //
    //       +--+ = PAGE 0
    //   ... :  :
    //      +-----+ ACTIVE
    // 15744 |  | | 0
    // 15745 |  | | 1
    // 15746 |  | | 2
    // 15747 |  | | 3
    // 15748 |  | | 4
    // 15749 |  | | 5
    // 15750 |  | | 6
    // 15751 |  | | 7
    // 15752 |01… | 8
    //       +--+ :
    //       +--+ : = PAGE 1
    //     0 …01| | 9
    //       +--+ :
    //      +-----+

    // We expect one fewer rows since we unwrapped a row.
    const end_rows = s.totalRows() - 1;

    // Resize
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, end_rows), s.totalRows());

    // PageList.diagram ->
    //
    //      +----+ = PAGE 0
    //  ... :    :
    //      +----+
    //      +----+ = PAGE 1
    //  ... :    :
    //     +-------+ ACTIVE
    // 6272 |    | | 0
    // 6273 |    | | 1
    // 6274 |    | | 2
    // 6275 |    | | 3
    // 6276 |    | | 4
    // 6277 |    | | 5
    // 6278 |    | | 6
    // 6279 |    | | 7
    // 6280 |    | | 8
    // 6281 |0101| | 9
    //      +----+ :
    //     +-------+

    {
        // PAGE 1 ROW 6280, ACTIVE 8
        const p = s.pin(.{ .active = .{ .y = 8 } }).?;
        const row = p.rowAndCell().row;
        try testing.expect(!row.wrap);
        try testing.expect(!row.wrap_continuation);

        const cells = p.cells(.all);
        try testing.expect(!cells[0].hasText());
        try testing.expect(!cells[1].hasText());
        try testing.expect(!cells[2].hasText());
        try testing.expect(!cells[3].hasText());
    }
    {
        // PAGE 1 ROW 6281, ACTIVE 9
        const p = s.pin(.{ .active = .{ .y = 9 } }).?;
        const row = p.rowAndCell().row;
        try testing.expect(!row.wrap);
        try testing.expect(!row.wrap_continuation);

        const cells = p.cells(.all);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint);
        try testing.expectEqual(@as(u21, 1), cells[1].content.codepoint);
        try testing.expectEqual(@as(u21, 0), cells[2].content.codepoint);
        try testing.expectEqual(@as(u21, 1), cells[3].content.codepoint);
    }
}

test "PageList resize reflow more cols wrap across page boundary cursor in second page" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 2, 10, 0);
    defer s.deinit();
    try testing.expectEqual(@as(usize, 1), s.totalPages());

    // Grow to the capacity of the first page.
    {
        const page = &s.pages.first.?.data;
        page.pauseIntegrityChecks(true);
        for (page.size.rows..page.capacity.rows) |_| {
            _ = try s.grow();
        }
        page.pauseIntegrityChecks(false);
        try testing.expectEqual(@as(usize, 1), s.totalPages());
        try s.growRows(1);
        try testing.expectEqual(@as(usize, 2), s.totalPages());
    }

    // At this point, we have some rows on the first page, and some on the second.
    // We can now wrap across the boundary condition.
    {
        const page = &s.pages.first.?.data;
        const y = page.size.rows - 1;
        {
            const rac = page.getRowAndCell(0, y);
            rac.row.wrap = true;
        }
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = @intCast(x) },
            };
        }
    }
    {
        const page2 = &s.pages.last.?.data;
        const y = 0;
        {
            const rac = page2.getRowAndCell(0, y);
            rac.row.wrap_continuation = true;
        }
        for (0..s.cols) |x| {
            const rac = page2.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = @intCast(x) },
            };
        }
    }

    // Put a tracked pin in wrapped row on the last page
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 1, .y = 9 } }).?);
    defer s.untrackPin(p);
    try testing.expect(p.node == s.pages.last.?);

    // We expect one fewer rows since we unwrapped a row.
    const end_rows = s.totalRows() - 1;

    // Resize
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, end_rows), s.totalRows());

    // Our cursor should move to the first row
    try testing.expectEqual(point.Point{ .active = .{
        .x = 3,
        .y = 9,
    } }, s.pointFromPin(.active, p.*).?);

    {
        const p2 = s.pin(.{ .active = .{ .y = 9 } }).?;
        const row = p2.rowAndCell().row;
        try testing.expect(!row.wrap);

        const cells = p2.cells(.all);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint);
        try testing.expectEqual(@as(u21, 1), cells[1].content.codepoint);
        try testing.expectEqual(@as(u21, 0), cells[2].content.codepoint);
        try testing.expectEqual(@as(u21, 1), cells[3].content.codepoint);
    }
}

test "PageList resize reflow less cols wrap across page boundary cursor in second page" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 10, null);
    defer s.deinit();
    try testing.expectEqual(@as(usize, 1), s.totalPages());

    // Grow to the capacity of the first page.
    {
        const page = &s.pages.first.?.data;
        page.pauseIntegrityChecks(true);
        for (page.size.rows..page.capacity.rows) |_| {
            _ = try s.grow();
        }
        page.pauseIntegrityChecks(false);
        try testing.expectEqual(@as(usize, 1), s.totalPages());
        try s.growRows(5);
        try testing.expectEqual(@as(usize, 2), s.totalPages());
    }

    // At this point, we have some rows on the first page, and some on the second.
    // We can now wrap across the boundary condition.
    {
        const page = &s.pages.first.?.data;
        const y = page.size.rows - 1;
        {
            const rac = page.getRowAndCell(0, y);
            rac.row.wrap = true;
        }
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = @intCast(x) },
            };
        }
    }
    {
        const page2 = &s.pages.last.?.data;
        const y = 0;
        {
            const rac = page2.getRowAndCell(0, y);
            rac.row.wrap_continuation = true;
        }
        for (0..s.cols) |x| {
            const rac = page2.getRowAndCell(x, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = @intCast(x) },
            };
        }
    }

    // Put a tracked pin in wrapped row on the last page
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 2, .y = 5 } }).?);
    defer s.untrackPin(p);
    try testing.expect(p.node == s.pages.last.?);
    try testing.expect(p.y == 0);

    // PageList.diagram ->
    //
    //      +-----+ = PAGE 0
    //  ... :     :
    //     +--------+ ACTIVE
    // 7892 |     | | 0
    // 7893 |     | | 1
    // 7894 |     | | 2
    // 7895 |     | | 3
    // 7896 |01234… | 4
    //      +-----+ :
    //      +-----+ : = PAGE 1
    //    0 …01234| | 5
    //      :  ^  : : = PIN 0
    //    1 |     | | 6
    //    2 |     | | 7
    //    3 |     | | 8
    //    4 |     | | 9
    //      +-----+ :
    //     +--------+

    // Resize
    try s.resize(.{
        .cols = 4,
        .reflow = true,
        .cursor = .{ .x = 2, .y = 5 },
    });
    try testing.expectEqual(@as(usize, 4), s.cols);

    // PageList.diagram ->
    //
    //      +----+ = PAGE 0
    //  ... :    :
    //     +-------+ ACTIVE
    // 7892 |    | | 0
    // 7893 |    | | 1
    // 7894 |    | | 2
    // 7895 |    | | 3
    // 7896 |0123… | 4
    // 7897 …4012… | 5
    //      :   ^: : = PIN 0
    // 7898 …3400| | 6
    // 7899 |    | | 7
    // 7900 |    | | 8
    // 7901 |    | | 9
    //      +----+ :
    //     +-------+

    // Our cursor should remain on the same cell
    try testing.expectEqual(point.Point{ .active = .{
        .x = 3,
        .y = 5,
    } }, s.pointFromPin(.active, p.*).?);

    {
        // PAGE 0 ROW 7895, ACTIVE 3
        const p2 = s.pin(.{ .active = .{ .y = 3 } }).?;
        const row = p2.rowAndCell().row;
        try testing.expect(!row.wrap);
        try testing.expect(!row.wrap_continuation);

        const cells = p2.cells(.all);
        try testing.expect(!cells[0].hasText());
        try testing.expect(!cells[1].hasText());
        try testing.expect(!cells[2].hasText());
        try testing.expect(!cells[3].hasText());
    }
    {
        // PAGE 0 ROW 7896, ACTIVE 4
        const p2 = s.pin(.{ .active = .{ .y = 4 } }).?;
        const row = p2.rowAndCell().row;
        try testing.expect(row.wrap);
        try testing.expect(!row.wrap_continuation);

        const cells = p2.cells(.all);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint);
        try testing.expectEqual(@as(u21, 1), cells[1].content.codepoint);
        try testing.expectEqual(@as(u21, 2), cells[2].content.codepoint);
        try testing.expectEqual(@as(u21, 3), cells[3].content.codepoint);
    }
    {
        // PAGE 0 ROW 7897, ACTIVE 5
        const p2 = s.pin(.{ .active = .{ .y = 5 } }).?;
        const row = p2.rowAndCell().row;
        try testing.expect(row.wrap);
        try testing.expect(row.wrap_continuation);

        const cells = p2.cells(.all);
        try testing.expectEqual(@as(u21, 4), cells[0].content.codepoint);
        try testing.expectEqual(@as(u21, 0), cells[1].content.codepoint);
        try testing.expectEqual(@as(u21, 1), cells[2].content.codepoint);
        try testing.expectEqual(@as(u21, 2), cells[3].content.codepoint);
    }
    {
        // PAGE 0 ROW 7898, ACTIVE 6
        const p2 = s.pin(.{ .active = .{ .y = 6 } }).?;
        const row = p2.rowAndCell().row;
        try testing.expect(!row.wrap);
        try testing.expect(row.wrap_continuation);

        const cells = p2.cells(.all);
        try testing.expectEqual(@as(u21, 3), cells[0].content.codepoint);
        try testing.expectEqual(@as(u21, 4), cells[1].content.codepoint);
    }
    {
        // PAGE 0 ROW 7899, ACTIVE 7
        const p2 = s.pin(.{ .active = .{ .y = 7 } }).?;
        const row = p2.rowAndCell().row;
        try testing.expect(!row.wrap);
        try testing.expect(!row.wrap_continuation);

        const cells = p2.cells(.all);
        try testing.expect(!cells[0].hasText());
        try testing.expect(!cells[1].hasText());
        try testing.expect(!cells[2].hasText());
        try testing.expect(!cells[3].hasText());
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
                .content = .{ .codepoint = 0 },
                .wide = .spacer_head,
            };
        }
        {
            const rac = page.getRowAndCell(0, 1);
            rac.row.wrap_continuation = true;
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
                .content = .{ .codepoint = 0 },
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
            try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint);
            try testing.expectEqual(pagepkg.Cell.Wide.spacer_tail, rac.cell.wide);
        }
    }
}

test "PageList resize reflow more cols unwrap wide spacer head across two rows" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 2, 3, 0);
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
            rac.row.wrap_continuation = true;
            rac.row.wrap = true;
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 'x' },
            };
        }
        {
            const rac = page.getRowAndCell(1, 1);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 0 },
                .wide = .spacer_head,
            };
        }
        {
            const rac = page.getRowAndCell(0, 2);
            rac.row.wrap_continuation = true;
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = '😀' },
                .wide = .wide,
            };
        }
        {
            const rac = page.getRowAndCell(1, 2);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 0 },
                .wide = .spacer_tail,
            };
        }
    }

    // Resize
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, 3), s.totalRows());

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
            try testing.expectEqual(@as(u21, 'x'), rac.cell.content.codepoint);
            try testing.expectEqual(pagepkg.Cell.Wide.narrow, rac.cell.wide);
        }
        {
            const rac = page.getRowAndCell(3, 0);
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
            try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint);
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
            rac.row.wrap_continuation = true;
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
                .content = .{ .codepoint = 0 },
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
            try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint);
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
        {
            const p = s.pin(.{ .active = .{ .y = 1 } }).?;
            const rac = p.rowAndCell();
            try testing.expect(rac.row.wrap);
            try testing.expect(rac.row.semantic_prompt == .prompt);
        }
        {
            const p = s.pin(.{ .active = .{ .y = 2 } }).?;
            const rac = p.rowAndCell();
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
            offset_copy.x = @intCast(x);
            const rac = offset_copy.rowAndCell();
            const cells = offset.node.data.getCells(rac.row);
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
        const cells = offset.node.data.getCells(rac.row);
        try testing.expect(rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.data.getCells(rac.row);
        try testing.expect(!rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 2), cells[0].content.codepoint);
    }
    {
        // First row should be wrapped
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.data.getCells(rac.row);
        try testing.expect(rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.data.getCells(rac.row);
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
        const cells = offset.node.data.getCells(rac.row);
        try testing.expect(rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.data.getCells(rac.row);
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
        const cells = offset.node.data.getCells(rac.row);
        try testing.expect(rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.data.getCells(rac.row);
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

test "PageList resize reflow less cols wraps spacer head" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 4, 3, 0);
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
            const rac = page.getRowAndCell(2, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 'x' },
            };
        }
        {
            const rac = page.getRowAndCell(3, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 0 },
                .wide = .spacer_head,
            };
        }
        {
            const rac = page.getRowAndCell(0, 1);
            rac.row.wrap_continuation = true;
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
                .content = .{ .codepoint = 0 },
                .wide = .spacer_tail,
            };
        }
    }

    // Resize
    try s.resize(.{ .cols = 3, .reflow = true });
    try testing.expectEqual(@as(usize, 3), s.cols);
    try testing.expectEqual(@as(usize, 3), s.totalRows());

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
            try testing.expectEqual(@as(u21, 'x'), rac.cell.content.codepoint);
            try testing.expectEqual(pagepkg.Cell.Wide.narrow, rac.cell.wide);
        }
        {
            const rac = page.getRowAndCell(0, 1);
            try testing.expectEqual(@as(u21, '😀'), rac.cell.content.codepoint);
            try testing.expectEqual(pagepkg.Cell.Wide.wide, rac.cell.wide);
        }
        {
            const rac = page.getRowAndCell(1, 1);
            try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint);
            try testing.expectEqual(pagepkg.Cell.Wide.spacer_tail, rac.cell.wide);
        }
    }
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

test "PageList resize reflow less cols cursor in wrapped blank cell" {
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
    const p = try s.trackPin(s.pin(.{ .active = .{ .x = 5, .y = 0 } }).?);
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
        const cells = offset.node.data.getCells(rac.row);
        try testing.expect(rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.data.getCells(rac.row);
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
    try testing.expectEqual(@as(usize, 5), s.totalRows());

    var it = s.rowIterator(.right_down, .{ .active = .{} }, null);
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        try testing.expect(!rac.row.wrap);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.data.getCells(rac.row);
        try testing.expect(rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.data.getCells(rac.row);
        try testing.expect(!rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 2), cells[0].content.codepoint);
    }
}

test "PageList resize reflow less cols blank lines between no scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, 0);
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = &s.pages.first.?.data;
    {
        const rac = page.getRowAndCell(0, 0);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = 'A' },
        };
    }
    {
        const rac = page.getRowAndCell(0, 2);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = 'C' },
        };
    }

    // Resize
    try s.resize(.{ .cols = 2, .reflow = true });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 3), s.totalRows());

    var it = s.rowIterator(.right_down, .{ .active = .{} }, null);
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.data.getCells(rac.row);
        try testing.expect(!rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 'A'), cells[0].content.codepoint);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.data.getCells(rac.row);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.data.getCells(rac.row);
        try testing.expect(!rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 'C'), cells[0].content.codepoint);
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
        const style_id = try page.styles.add(page.memory, style);

        for (0..s.cols - 1) |x| {
            const rac = page.getRowAndCell(x, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = @intCast(x) },
                .style_id = style_id,
            };
            page.styles.use(page.memory, style_id);
        }

        // We're over-counted by 1 because `add` implies `use`.
        page.styles.release(page.memory, style_id);
    }

    // Resize
    try s.resize(.{ .cols = 2, .reflow = true });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 2), s.totalRows());

    var it = s.rowIterator(.right_down, .{ .active = .{} }, null);
    while (it.next()) |offset| {
        for (0..s.cols - 1) |x| {
            var offset_copy = offset;
            offset_copy.x = @intCast(x);
            const rac = offset_copy.rowAndCell();
            const style_id = rac.cell.style_id;
            try testing.expect(style_id != 0);

            const style = offset.node.data.styles.get(
                offset.node.data.memory,
                style_id,
            );
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
                .content = .{ .codepoint = 0 },
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
                .content = .{ .codepoint = 0 },
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
            try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint);
            try testing.expectEqual(pagepkg.Cell.Wide.spacer_tail, rac.cell.wide);
        }
    }
}

test "PageList resize reflow less cols copy kitty placeholder" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 4, 2, 0);
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = &s.pages.first.?.data;

        // Write unicode placeholders
        for (0..s.cols - 1) |x| {
            const rac = page.getRowAndCell(x, 0);
            rac.row.kitty_virtual_placeholder = true;
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = kitty.graphics.unicode.placeholder },
            };
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
            offset_copy.x = @intCast(x);
            const rac = offset_copy.rowAndCell();

            const row = rac.row;
            try testing.expect(row.kitty_virtual_placeholder);
        }
    }
}

test "PageList resize reflow more cols clears kitty placeholder" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 4, 2, 0);
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = &s.pages.first.?.data;

        // Write unicode placeholders
        for (0..s.cols - 1) |x| {
            const rac = page.getRowAndCell(x, 0);
            rac.row.kitty_virtual_placeholder = true;
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = kitty.graphics.unicode.placeholder },
            };
        }
    }

    // Resize smaller then larger
    try s.resize(.{ .cols = 2, .reflow = true });
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, 2), s.totalRows());

    var it = s.rowIterator(.right_down, .{ .active = .{} }, null);
    {
        const row = it.next().?;
        const rac = row.rowAndCell();
        try testing.expect(rac.row.kitty_virtual_placeholder);
    }
    {
        const row = it.next().?;
        const rac = row.rowAndCell();
        try testing.expect(!rac.row.kitty_virtual_placeholder);
    }
    try testing.expect(it.next() == null);
}

test "PageList resize reflow wrap moves kitty placeholder" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 4, 2, 0);
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = &s.pages.first.?.data;

        // Write unicode placeholders
        for (2..s.cols - 1) |x| {
            const rac = page.getRowAndCell(x, 0);
            rac.row.kitty_virtual_placeholder = true;
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = kitty.graphics.unicode.placeholder },
            };
        }
    }

    try s.resize(.{ .cols = 2, .reflow = true });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 2), s.totalRows());

    var it = s.rowIterator(.right_down, .{ .active = .{} }, null);
    {
        const row = it.next().?;
        const rac = row.rowAndCell();
        try testing.expect(!rac.row.kitty_virtual_placeholder);
    }
    {
        const row = it.next().?;
        const rac = row.rowAndCell();
        try testing.expect(rac.row.kitty_virtual_placeholder);
    }
    try testing.expect(it.next() == null);
}

test "PageList reset" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();
    s.reset();
    try testing.expect(s.viewport == .active);
    try testing.expect(s.pages.first != null);
    try testing.expectEqual(@as(usize, s.rows), s.totalRows());

    // Active area should be the top
    try testing.expectEqual(Pin{
        .node = s.pages.first.?,
        .y = 0,
        .x = 0,
    }, s.getTopLeft(.active));
}

test "PageList reset across two pages" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Find a cap that makes it so that rows don't fit on one page.
    const rows = 100;
    const cap = cap: {
        var cap = try std_capacity.adjust(.{ .cols = 50 });
        while (cap.rows >= rows) cap = try std_capacity.adjust(.{
            .cols = cap.cols + 50,
        });

        break :cap cap;
    };

    // Init
    var s = try init(alloc, cap.cols, rows, null);
    defer s.deinit();
    s.reset();
    try testing.expect(s.viewport == .active);
    try testing.expect(s.pages.first != null);
    try testing.expectEqual(@as(usize, s.rows), s.totalRows());
}

test "PageList clears history" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();
    try s.growRows(30);
    s.reset();
    try testing.expect(s.viewport == .active);
    try testing.expect(s.pages.first != null);
    try testing.expectEqual(@as(usize, s.rows), s.totalRows());

    // Active area should be the top
    try testing.expectEqual(Pin{
        .node = s.pages.first.?,
        .y = 0,
        .x = 0,
    }, s.getTopLeft(.active));
}
