//! Maintains a linked list of pages to make up a terminal screen
//! and provides higher level operations on top of those pages to
//! make it slightly easier to work with.
const PageList = @This();

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("terminal_options");
const Allocator = std.mem.Allocator;
const assert = @import("../quirks.zig").inlineAssert;
const fastmem = @import("../fastmem.zig");
const tripwire = @import("../tripwire.zig");
const DoublyLinkedList = @import("../datastruct/main.zig").IntrusiveDoublyLinkedList;
const color = @import("color.zig");
const compression = @import("compress.zig");
const highlight = @import("highlight.zig");
const kitty = @import("kitty.zig");
const terminal_mem = @import("mem.zig");
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
pub const List = DoublyLinkedList(Node);

/// A single node within the PageList linked list.
///
/// This isn't pub because you can access the type via List.Node.
const Node = struct {
    prev: ?*Node = null,
    next: ?*Node = null,
    data: Data,
    serial: u64,

    /// How the backing memory of the embedded Page was allocated. Pool-owned
    /// memory is always a full standard-size item from the memory
    /// pool, regardless of the page layout size. Heap-owned memory
    /// is allocated directly with the page allocator and is exactly
    /// `Page.memory.len` bytes.
    ///
    /// This must never be inferred from the memory length: heap-owned
    /// pages can be smaller than the standard size (e.g. compacted
    /// pages), and returning one to the pool would corrupt it.
    ///
    /// This has no default on purpose so that every construction site
    /// is forced to make an explicit decision.
    owned: Owned,

    /// The physical representation of the page contents.
    ///
    /// Both states retain the same `Page.memory` virtual mapping and the same
    /// `Page` metadata. A resident page can access the mapping directly since
    /// it is, well, resident.
    ///
    /// A compressed page owns an encoded copy while the physical memory
    /// behind the raw mapping is discarded. HOWEVER, we retain the
    /// virtual allocation so that restoration is infallible.
    const Data = union(enum) {
        resident: Page,
        compressed: compression.Page,
    };

    const Owned = enum { pool, heap };

    /// The backing-memory representation currently stored by this node.
    pub const Storage = enum { resident, compressed };

    /// Return the terminal page stored in this node.
    ///
    /// WARNING: This will DECOMPRESS compressed pages! Only use this if
    /// you need access to the underlying memory. If you only need access to
    /// metadata (row, col counts etc) then use the other metadata functions.
    pub inline fn page(self: *Node) *Page {
        return switch (self.data) {
            .resident => |*page_| page_,
            .compressed => self.restore(.preserve),
        };
    }

    /// Return the terminal page only when its raw memory is resident.
    ///
    /// Unlike `page`, this never restores a compressed node. This is useful
    /// for diagnostics which can display node metadata without touching the
    /// discarded mapping, but may inspect page contents when they are already
    /// available.
    pub inline fn pageIfResident(self: *Node) ?*Page {
        return switch (self.data) {
            .resident => |*page_| page_,
            .compressed => null,
        };
    }

    /// Read-only page with full memory access that doesn't change
    /// this node's storage state: if a node is compressed it remains
    /// compressed.
    ///
    /// Resident pages are borrowed directly. So they're basically free.
    ///
    /// Compressed pages are decoded into an independently owned Page
    /// by the caller so callers can inspect their contents. Because resident
    /// pages are still borrowed, you have to continue to have exclusive
    /// access to the PageList during this operation.
    pub const PreservedPage = union(enum) {
        borrowed: *const Page,
        owned: struct {
            page: Page,
            alloc: Allocator,
        },

        /// Return the read-only page represented by this value.
        pub fn page(self: *const PreservedPage) *const Page {
            return switch (self.*) {
                .borrowed => |page_| page_,
                .owned => |*owned| &owned.page,
            };
        }

        /// Release storage owned by this preserved page.
        pub fn deinit(self: *PreservedPage) void {
            switch (self.*) {
                .borrowed => {},
                // The clone buffer came from the caller's allocator rather
                // than Page's OS allocator, so it must not use Page.deinit.
                .owned => |*owned| owned.alloc.free(owned.page.memory),
            }
            self.* = undefined;
        }
    };

    /// Return read-only page contents without changing this node's storage.
    ///
    /// `alloc` is unused for a resident node. A compressed node uses it for an
    /// exact-sized, page-aligned decode buffer owned by the returned value.
    ///
    /// The caller must call `PreservedPage.deinit` when finished. See
    /// `PreservedPage` for the synchronization required by its borrowed
    /// resident representation.
    pub fn pagePreservingState(
        self: *const Node,
        alloc: Allocator,
    ) Allocator.Error!PreservedPage {
        return switch (self.data) {
            .resident => |*page_| .{ .borrowed = page_ },
            .compressed => |*compressed| owned: {
                const memory = try alloc.alignedAlloc(
                    u8,
                    .fromByteUnits(std.heap.page_size_min),
                    compressed.page.memory.len,
                );

                const page_ = compressed.cloneBuf(memory) catch |err| {
                    // The encoded data was produced by our codec and remains
                    // immutable while compressed. Failure is internal
                    // corruption, matching the normal restoration boundary.
                    switch (err) {
                        error.TruncatedInput,
                        error.InvalidOffset,
                        error.OutputTooSmall,
                        error.OutputSizeMismatch,
                        => {},
                    }

                    alloc.free(memory);
                    log.err("failed to clone compressed page err={}", .{err});
                    @panic("failed to clone compressed terminal page");
                };

                break :owned .{ .owned = .{
                    .page = page_,
                    .alloc = alloc,
                } };
            },
        };
    }

    /// Return the node's backing-memory representation without restoring it.
    pub inline fn storage(self: *const Node) Storage {
        return switch (self.data) {
            .resident => .resident,
            .compressed => .compressed,
        };
    }

    /// Return a page which the caller knows is already resident.
    ///
    /// This avoids the representation check in hot paths which already hold
    /// live pointers into the page mapping. Such pointers are only valid while
    /// the page is resident. Prefer `page` unless the caller can establish
    /// that invariant independently.
    pub inline fn pageAssumeResident(self: *Node) *Page {
        return &self.data.resident;
    }

    /// Return the number of populated rows without accessing page memory.
    pub inline fn rows(self: *const Node) size.CellCountInt {
        return self.metadata().size.rows;
    }

    /// Return the current column count without accessing page memory.
    pub inline fn cols(self: *const Node) size.CellCountInt {
        return self.metadata().size.cols;
    }

    /// Return the page capacity without accessing page memory.
    pub inline fn capacity(self: *const Node) Capacity {
        return self.metadata().capacity;
    }

    /// Return the embedded Page metadata without restoring its memory.
    inline fn metadata(self: *const Node) *const Page {
        return switch (self.data) {
            .resident => |*page_| page_,
            .compressed => |*page_| &page_.page,
        };
    }

    const RestoreMode = enum {
        /// Decode the compressed representation back into the raw mapping.
        preserve,

        /// Discard the compressed representation without decoding it. The
        /// caller must not read the page contents before overwriting them.
        discard,
    };

    /// Restore this node to the resident representation.
    ///
    /// Preserve mode reconstructs the page contents and is used by `page`.
    /// Discard mode skips decoding for callers which will overwrite or destroy
    /// the page. Both modes recommit the retained mapping, free the encoded
    /// allocation, and leave the node in a valid resident state.
    noinline fn restore(self: *Node, comptime mode: RestoreMode) *Page {
        const compressed = switch (self.data) {
            .resident => |*page_| return page_,
            .compressed => |*page_| page_,
        };

        // Decommit only discarded the physical pages. Recommit prepares the
        // still-reserved mapping for decoding or reuse by the caller.
        terminal_mem.recommit(compressed.page.memory);

        const restored = switch (mode) {
            .preserve => compressed.restore() catch |err| {
                // Compressed nodes retain the immutable encoding and exact
                // output mapping used to create them. Any decode error is an
                // internal codec bug or memory corruption. Keep this switch
                // exhaustive so new decoder errors require classification.
                switch (err) {
                    error.TruncatedInput,
                    error.InvalidOffset,
                    error.OutputTooSmall,
                    error.OutputSizeMismatch,
                    => {},
                }

                log.err("failed to restore compressed page err={}", .{err});
                @panic("failed to restore compressed terminal page");
            },

            .discard => compressed.page,
        };

        // Remove our compressed data
        compressed.deinit();

        // We're now a resident, non-compressed node.
        self.data = .{ .resident = restored };
        return &self.data.resident;
    }

    inline fn isCompressed(self: *const Node) bool {
        return switch (self.data) {
            .resident => false,
            .compressed => true,
        };
    }
};

/// The memory pool we get page nodes from.
const NodePool = std.heap.MemoryPool(List.Node);

/// The standard page capacity that we use as a starting point for
/// all pages. This is chosen as a sane default that fits most terminal
/// usage to support using our pool.
const std_capacity = pagepkg.std_capacity;

/// The byte size required for a standard page.
const std_size = Page.layout(std_capacity).total_size;

/// The memory pool we use for page memory buffers. We use a separate pool
/// so we can allocate these with a page allocator. We have to use a page
/// allocator because we need memory that is zero-initialized and page-aligned.
const PagePool = std.heap.MemoryPoolAligned(
    [std_size]u8,
    .fromByteUnits(std.heap.page_size_min),
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
    ) Allocator.Error!MemoryPool {
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

/// The list of pages in the screen.
pages: List,

/// The next globally unique reference generation for this PageList. A
/// generation is assigned whenever a page is allocated, reused as new, or
/// changed in place such that existing page coordinates are no longer stable.
///
/// The serial number can be used to detect whether the page is identical
/// to the page that was originally referenced by a pointer. Since we reuse
/// and pool memory, pointer stability is not guaranteed, but the serial
/// will always be different for different page generations.
///
/// Developer note: we never do overflow checking on this. If we created
/// a new page every second it'd take 584 billion years to overflow. We're
/// going to risk it.
page_serial: u64,

/// The first serial in the current whole-list validity epoch. Only `reset`
/// advances this value, immediately before rebuilding every page. It is not
/// the generation of the first page or the exact minimum live generation.
/// Page generations are not monotonic in list order: replacement and split
/// operations can put a fresh generation before older live pages.
///
/// A generation below this epoch is definitely invalid, allowing O(1)
/// rejection in `nodeIsValid` and bulk removal of pre-reset search results.
/// A generation at or above it is only potentially valid and must still be
/// checked against the live list before its coordinates are used.
page_serial_epoch: u64,

/// Byte size of the raw backing mappings owned by active page nodes. This is
/// logical scrollback accounting and does not change while a mapping is
/// decommitted. It excludes encoded storage and unused preheated pool items.
page_size: usize,

/// Continuation state for incremental page compression. This allows
/// compress(.incremental) to work. More details on all that there and
/// in the state struct.
page_compression: IncrementalCompressionState = .{},

/// Maximum size of the page allocation in bytes. This only includes pages
/// that are used ONLY for scrollback. If the active area is still partially
/// in a page that also includes scrollback, then that page is not included.
explicit_max_size: usize,

/// This is the minimum max size that we will respect due to the rows/cols
/// of the PageList. We must always be able to fit at least the active area
/// and at least two pages for our algorithms.
min_max_size: usize,

/// The total number of rows represented by this PageList. This is used
/// specifically for scrollbar information so we can have the total size.
total_rows: usize,

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

/// The row offset from the top that the viewport pin is at. We
/// store the offset from the top because it doesn't change while more
/// data is printed to the terminal.
///
/// This is null when it isn't calculated. It is calculated on demand
/// when the viewportRowOffset function is called, because it is only
/// required for certain operations such as rendering the scrollbar.
///
/// In order to make this more efficient, in many places where the value
/// would be invalidated, we update it in-place instead. This is key to
/// keeping our performance decent in normal cases since recalculating
/// this from scratch, depending on the size of the scrollback and position
/// of the pin, can be very expensive.
///
/// This is only valid if viewport is `pin`. Every other offset is
/// self-evident or quick to calculate.
viewport_pin_row_offset: ?usize,

/// The current desired screen dimensions. I say "desired" because individual
/// pages may still be a different size and not yet reflowed since we lazily
/// reflow text.
cols: size.CellCountInt,
rows: size.CellCountInt,

/// If this is true then verifyIntegrity will do nothing. This is
/// only present with runtime safety enabled.
pause_integrity_checks: if (build_options.slow_runtime_safety) usize else void =
    if (build_options.slow_runtime_safety) 0 else {},

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
fn minMaxSize(cols: size.CellCountInt, rows: size.CellCountInt) usize {
    // Invariant required to ensure our divCeil below cannot overflow.
    comptime {
        const max_rows = std.math.maxInt(size.CellCountInt);
        _ = std.math.divCeil(usize, max_rows, 1) catch unreachable;
    }

    // Get our capacity to fit our rows. If the cols are too big, it may
    // force less rows than we want meaning we need more than one page to
    // represent a viewport.
    const cap = initialCapacity(cols);

    // Calculate the number of standard sized pages we need to represent
    // an active area.
    const pages_exact = if (cap.rows >= rows) 1 else std.math.divCeil(
        usize,
        rows,
        cap.rows,
    ) catch {
        // Not possible:
        // - initialCapacity guarantees at least 1 row
        // - numerator/denominator can't overflow because of comptime check above
        unreachable;
    };

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

/// Calculates the initial capacity for a new page for a given column
/// count. This will attempt to fit within std_size at all times so we
/// can use our memory pool, but if cols is too big, this will return a
/// larger capacity.
///
/// The returned capacity is always guaranteed to layout properly (not
/// overflow). We are able to support capacities up to the maximum int
/// value of cols, so this will never overflow.
fn initialCapacity(cols: size.CellCountInt) Capacity {
    // This is an important invariant that ensures that this function
    // can never return an error. We verify here that our standard capacity
    // when increased to maximum possible columns can always support at
    // least one row in memory.
    //
    // IF THIS EVER FAILS: We probably need to modify our logic below
    // to reduce other elements of the capacity (styles, graphemes, etc.).
    // But, instead, I recommend taking a step back and re-evaluating
    // life choices.
    comptime {
        var cap = std_capacity;
        cap.cols = std.math.maxInt(size.CellCountInt);
        const layout = Page.layout(cap);
        assert(layout.total_size <= size.max_page_size);
    }

    if (std_capacity.adjust(
        .{ .cols = cols },
    )) |cap| {
        // If we can adjust our standard capacity, we fit within the
        // standard size and we're good!
        return cap;
    } else |err| {
        // Ensure our error set doesn't change.
        comptime assert(@TypeOf(err) == error{OutOfMemory});
    }

    // This code path means that our standard capacity can't even
    // accommodate our column count! The only solution is to increase
    // our capacity and go non-standard.
    var cap: Capacity = std_capacity;
    cap.cols = cols;
    return cap;
}

/// This is the page allocator we'll use for all our underlying
/// VM page allocations.
inline fn pageAllocator() Allocator {
    // In tests we use our testing allocator so we can detect leaks.
    if (builtin.is_test) return std.testing.allocator;

    // On non-macOS we use our standard Zig page allocator.
    if (!builtin.target.os.tag.isDarwin()) return std.heap.page_allocator;

    // On macOS we want to tag our memory so we can assign it to our
    // core terminal usage.
    const mach = @import("../os/mach.zig");
    return mach.taggedPageAllocator(.application_specific_1);
}

const init_tw = tripwire.module(enum {
    init_memory_pool,
    init_pages,
    viewport_pin,
    viewport_pin_track,
}, init);

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
) Allocator.Error!PageList {
    const tw = init_tw;

    // The screen starts with a single page that is the entire viewport,
    // and we'll split it thereafter if it gets too large and add more as
    // necessary.
    try tw.check(.init_memory_pool);
    var pool = try MemoryPool.init(
        alloc,
        pageAllocator(),
        page_preheat,
    );
    errdefer pool.deinit();

    try tw.check(.init_pages);
    var page_serial: u64 = 0;
    const page_list, const page_size = try initPages(
        &pool,
        &page_serial,
        cols,
        rows,
    );

    // Get our minimum max size, see doc comments for more details.
    const min_max_size = minMaxSize(cols, rows);

    // We always track our viewport pin to ensure this is never an allocation
    try tw.check(.viewport_pin);
    const viewport_pin = try pool.pins.create();
    viewport_pin.* = .{ .node = page_list.first.? };
    var tracked_pins: PinSet = .{};
    errdefer tracked_pins.deinit(pool.alloc);

    try tw.check(.viewport_pin_track);
    try tracked_pins.putNoClobber(pool.alloc, viewport_pin, {});

    errdefer comptime unreachable;
    const result: PageList = .{
        .cols = cols,
        .rows = rows,
        .pool = pool,
        .pages = page_list,
        .page_serial = page_serial,
        .page_serial_epoch = 0,
        .page_size = page_size,
        .explicit_max_size = max_size orelse std.math.maxInt(usize),
        .min_max_size = min_max_size,
        .total_rows = rows,
        .tracked_pins = tracked_pins,
        .viewport = .{ .active = {} },
        .viewport_pin = viewport_pin,
        .viewport_pin_row_offset = null,
    };
    result.assertIntegrity();
    return result;
}

const initPages_tw = tripwire.module(enum {
    page_node,
    page_buf_std,
    page_buf_non_std,
}, initPages);

fn initPages(
    pool: *MemoryPool,
    serial: *u64,
    cols: size.CellCountInt,
    rows: size.CellCountInt,
) Allocator.Error!struct { List, usize } {
    const tw = initPages_tw;

    var page_list: List = .{};
    var page_size: usize = 0;

    // Add pages as needed to create our initial viewport.
    const cap = initialCapacity(cols);
    const layout = Page.layout(cap);
    const pooled = layout.total_size <= std_size;
    const page_alloc = pool.pages.arena.child_allocator;

    // Guaranteed by comptime checks in initialCapacity but
    // redundant here for safety.
    assert(layout.total_size <= size.max_page_size);

    // If we have an error, we need to clean up our heap-owned pages
    // since they're not in the pool.
    errdefer {
        var it = page_list.first;
        while (it) |node| : (it = node.next) {
            switch (node.owned) {
                .pool => {},
                .heap => page_alloc.free(node.page().memory),
            }
        }
    }

    var rem = rows;
    while (rem > 0) {
        try tw.check(.page_node);
        const node = try pool.nodes.create();
        errdefer pool.nodes.destroy(node);

        const page_buf = if (pooled) buf: {
            try tw.check(.page_buf_std);
            const buf = try pool.pages.create();
            terminal_mem.recommit(buf);
            break :buf buf;
        } else buf: {
            try tw.check(.page_buf_non_std);
            break :buf try page_alloc.alignedAlloc(
                u8,
                .fromByteUnits(std.heap.page_size_min),
                layout.total_size,
            );
        };
        errdefer if (pooled)
            pool.pages.destroy(page_buf)
        else
            page_alloc.free(page_buf);

        // In runtime safety modes we have to memset because the Zig allocator
        // interface will always memset to 0xAA for undefined. On freestanding
        // (WASM), the WasmAllocator reuses freed slots without zeroing since
        // only fresh memory.grow pages are guaranteed zero by the WASM spec.
        // On native, the OS page allocator (mmap) returns zeroed pages.
        if (comptime std.debug.runtime_safety or builtin.os.tag == .freestanding)
            @memset(page_buf, 0);

        // Initialize the first set of pages to contain our viewport so that
        // the top of the first page is always the active area.
        node.* = .{
            .data = .{ .resident = .initBuf(.init(page_buf), layout) },
            .serial = serial.*,
            .owned = if (pooled) .pool else .heap,
        };
        node.page().size.rows = @min(rem, node.capacity().rows);
        rem -= node.rows();

        // Add the page to the list
        page_list.append(node);
        page_size += page_buf.len;
        errdefer comptime unreachable;

        // Increment our serial
        serial.* += 1;
    }

    assert(page_list.first != null);

    return .{ page_list, page_size };
}

/// Assert that the PageList is in a valid state. This is a no-op in
/// release builds.
pub inline fn assertIntegrity(self: *const PageList) void {
    if (comptime !build_options.slow_runtime_safety) return;

    self.verifyIntegrity() catch |err| {
        log.err("PageList integrity check failed: {}", .{err});
        @panic("PageList integrity check failed");
    };
}

/// Pause or resume integrity checks. This is useful when you're doing
/// a multi-step operation that temporarily leaves the PageList in an
/// inconsistent state.
pub inline fn pauseIntegrityChecks(self: *PageList, pause: bool) void {
    if (comptime !build_options.slow_runtime_safety) return;
    if (pause) {
        self.pause_integrity_checks += 1;
    } else {
        self.pause_integrity_checks -= 1;
    }
}

const IntegrityError = error{
    PageSerialInvalid,
    TotalRowsMismatch,
    TrackedPinInvalid,
    ViewportPinOffsetMismatch,
    ViewportPinInsufficientRows,
};

/// Verify the integrity of the PageList. This is expensive and should
/// only be called in debug/test builds.
fn verifyIntegrity(self: *const PageList) IntegrityError!void {
    if (comptime !build_options.slow_runtime_safety) return;
    if (self.pause_integrity_checks > 0) return;

    // Our viewport pin should never be garbage
    assert(!self.viewport_pin.garbage);

    // Grab our total rows
    var actual_total: usize = 0;
    {
        var node_ = self.pages.first;
        while (node_) |node| {
            actual_total += node.rows();
            node_ = node.next;

            // Every live node must belong to the current validity epoch.
            if (node.serial < self.page_serial_epoch) {
                log.warn(
                    "PageList integrity violation: page serial predates epoch serial={} epoch={}",
                    .{ node.serial, self.page_serial_epoch },
                );
                return IntegrityError.PageSerialInvalid;
            }
        }
    }

    // Verify that our cached total_rows matches the actual row count
    if (actual_total != self.total_rows) {
        log.warn(
            "PageList integrity violation: total_rows mismatch cached={} actual={}",
            .{ self.total_rows, actual_total },
        );
        return IntegrityError.TotalRowsMismatch;
    }

    // Verify that all our tracked pins point to valid pages.
    for (self.tracked_pins.keys()) |p| {
        if (!self.pinIsValid(p.*)) return error.TrackedPinInvalid;
    }

    if (self.viewport == .pin) {
        // Verify that our viewport pin row offset is correct.
        const actual_offset: usize = offset: {
            var offset: usize = 0;
            var node = self.pages.last;
            while (node) |n| : (node = n.prev) {
                offset += n.rows();
                if (n == self.viewport_pin.node) {
                    offset -= self.viewport_pin.y;
                    break :offset self.total_rows - offset;
                }
            }

            log.warn(
                "PageList integrity violation: viewport pin not in list",
                .{},
            );
            return error.ViewportPinOffsetMismatch;
        };

        if (self.viewport_pin_row_offset) |cached_offset| {
            if (cached_offset != actual_offset) {
                log.warn(
                    "PageList integrity violation: viewport pin offset mismatch cached={} actual={}",
                    .{ cached_offset, actual_offset },
                );
                return error.ViewportPinOffsetMismatch;
            }
        }

        // Ensure our viewport has enough rows.
        const rows = self.total_rows - actual_offset;
        if (rows < self.rows) {
            log.warn(
                "PageList integrity violation: viewport pin rows too small rows={} needed={}",
                .{ rows, self.rows },
            );
            return error.ViewportPinInsufficientRows;
        }
    }
}

/// Deinit the pagelist, freeing all page memory and the memory pool.
pub fn deinit(self: *PageList) void {
    // Verify integrity before cleanup
    self.assertIntegrity();

    // Always deallocate our hashmap.
    self.tracked_pins.deinit(self.pool.alloc);

    // Go through our linked list and deallocate all pages that are
    // heap-owned (not in the pool).
    const page_alloc = self.pool.pages.arena.child_allocator;
    var it = self.pages.first;
    while (it) |node| : (it = node.next) {
        const page = node.restore(.discard);
        switch (node.owned) {
            .pool => {},
            .heap => page_alloc.free(page.memory),
        }
    }

    // Deallocate all the pages. We don't need to deallocate the list or
    // nodes because they all reside in the pool.
    self.pool.deinit();
}

/// Reset the PageList back to an empty state. This is similar to
/// deinit and reinit but it importantly preserves the pointer
/// stability of tracked pins (they're moved to the top-left since
/// all contents are cleared).
///
/// This can't fail because we always retain at least enough allocated
/// memory to fit the active area.
pub fn reset(self: *PageList) void {
    defer self.assertIntegrity();

    // Reset discards all scrollback, so there is nothing left to compress.
    self.page_compression.reset();

    // Begin a new whole-list validity epoch before rebuilding from the pools.
    // Every old reference now has a serial below the epoch and can be rejected
    // in O(1), even if the node pool later reuses its pointer address.
    self.page_serial_epoch = self.page_serial;

    // We need enough pages/nodes to keep our active area. This should
    // never fail since we by definition have allocated a page already
    // that fits our size but I'm not confident to make that assertion.
    const cap = initialCapacity(self.cols);
    assert(cap.rows > 0);

    // The number of pages we need is the number of rows in the active
    // area divided by the row capacity of a page.
    const page_count = std.math.divCeil(
        usize,
        self.rows,
        cap.rows,
    ) catch unreachable;

    // Before resetting our pools we need to free any pages that
    // are heap-owned since those were allocated outside the pool.
    {
        const page_alloc = self.pool.pages.arena.child_allocator;
        var it = self.pages.first;
        while (it) |node| : (it = node.next) {
            const page = node.restore(.discard);
            switch (node.owned) {
                .pool => {},
                .heap => page_alloc.free(page.memory),
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
            // WARN: Since HeapAllocator's BufNode is not public API,
            // we have to hardcode its layout here. We do a comptime assert
            // on Zig version to verify we check it on every bump.
            const BufNode = struct {
                data: usize,
                node: std.SinglyLinkedList.Node,
            };
            const buf_node: *BufNode = @fieldParentPtr("node", node);

            // The fully allocated buffer
            const alloc_buf = @as([*]u8, @ptrCast(buf_node))[0..buf_node.data];
            // The buffer minus our header
            const data_buf = alloc_buf[@sizeOf(BufNode)..];
            @memset(data_buf, 0);
        }
    }

    // Initialize our pages. This should not be able to fail since
    // we retained the capacity for the minimum number of pages we need.
    self.pages, self.page_size = initPages(
        &self.pool,
        &self.page_serial,
        self.cols,
        self.rows,
    ) catch @panic("initPages failed");

    // Our total rows always goes back to the default
    self.total_rows = self.rows;

    // Update all our tracked pins to point to our first page top-left
    // and mark them as garbage, because it got mangled in a way where
    // semantically it really doesn't make sense.
    {
        var it = self.tracked_pins.iterator();
        while (it.next()) |entry| {
            const p: *Pin = entry.key_ptr.*;
            p.node = self.pages.first.?;
            p.x = 0;
            p.y = 0;
            p.garbage = true;
        }

        // Our viewport pin is never garbage
        self.viewport_pin.garbage = false;
    }

    // Move our viewport back to the active area since everything is gone.
    self.viewport = .active;
}

pub const Clone = struct {
    /// The top and bottom (inclusive) points of the region to clone.
    /// The x coordinate is ignored; the full row is always cloned.
    top: point.Point,
    bot: ?point.Point = null,

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
    alloc: Allocator,
    opts: Clone,
) !PageList {
    var it = self.pageIterator(
        .right_down,
        opts.top,
        opts.bot,
    );

    // First, count our pages so our preheat is exactly what we need.
    var it_copy = it;
    const page_count: usize = page_count: {
        var count: usize = 0;
        while (it_copy.next()) |_| count += 1;
        break :page_count count;
    };

    // Setup our pool
    var pool: MemoryPool = try .init(
        alloc,
        pageAllocator(),
        page_count,
    );
    errdefer pool.deinit();

    // Create our viewport. In a clone, the viewport always goes
    // to the top.
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
            switch (node.owned) {
                .pool => {},
                .heap => page_alloc.free(node.page().memory),
            }
        }
    }

    // Copy our pages
    var page_serial: u64 = 0;
    var total_rows: usize = 0;
    var page_size: usize = 0;
    while (it.next()) |chunk| {
        // Clone the page. We have to use createPageExt here because
        // we don't know if the source page has a standard size.
        const node = try createPageExt(
            &pool,
            .{ .cap = chunk.node.capacity() },
            &page_serial,
            &page_size,
        );
        const dst_page = node.page();
        const src_page = chunk.node.page();
        assert(node.capacity().rows >= chunk.end - chunk.start);
        defer dst_page.assertIntegrity();
        dst_page.size.rows = chunk.end - chunk.start;
        dst_page.size.cols = chunk.node.cols();
        try dst_page.cloneFrom(
            src_page,
            chunk.start,
            chunk.end,
        );

        dst_page.dirty = src_page.dirty;

        page_list.append(node);

        total_rows += node.rows();

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

    // Initialize our viewport pin to point to the first cloned page
    // so it points to valid memory.
    viewport_pin.* = .{ .node = page_list.first.? };

    var result: PageList = .{
        .pool = pool,
        .pages = page_list,
        .page_serial = page_serial,
        .page_serial_epoch = 0,
        .page_size = page_size,
        .explicit_max_size = self.explicit_max_size,
        .min_max_size = self.min_max_size,
        .cols = self.cols,
        .rows = self.rows,
        .total_rows = total_rows,
        .tracked_pins = tracked_pins,
        .viewport = .{ .active = {} },
        .viewport_pin = viewport_pin,
        .viewport_pin_row_offset = null,
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
            const page = last.page();
            const row = &page.rows.ptr(page.memory)[last.rows() - 1];
            page.clearCells(row, 0, result.cols);
        }

        // Update our total rows to be our row size.
        result.total_rows = result.rows;
    }

    result.assertIntegrity();
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

        /// When set, this pin preserves right-side blank cells up to the cursor
        /// during reflow.
        pin: ?*Pin = null,
    };
};

/// Resize
/// TODO: docs
pub fn resize(self: *PageList, opts: Resize) Allocator.Error!void {
    defer self.assertIntegrity();

    // Resizing forces all nodes to be decompressed today so we need to
    // reschedule compression.
    // TODO(mitchellh): Deferred reflow on non-viewport/non-active pages.
    self.page_compression.reset();
    self.page_compression.markActivity();

    if (comptime std.debug.runtime_safety) {
        // Resize does not work with 0 values, this should be protected
        // upstream
        if (opts.cols) |v| assert(v > 0);
        if (opts.rows) |v| assert(v > 0);
    }

    // Resizing (especially with reflow) can cause our row offset to
    // become invalid. Rather than do something fancy like we do other
    // places and try to update it in place, we just invalidate it because
    // its too easy to get the logic wrong in here.
    self.viewport_pin_row_offset = null;

    if (!opts.reflow) return try self.resizeWithoutReflow(opts);

    // Recalculate our minimum max size. This allows grow to work properly
    // when increasing beyond our initial minimum max size or explicit max
    // size to fit the active area.
    const old_min_max_size = self.min_max_size;
    self.min_max_size = minMaxSize(
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

    // Various resize operations can change our total row count such
    // that our viewport pin is now in the active area and has insufficient
    // space. We need to check for this case and fix it up.
    switch (self.viewport) {
        .pin => if (self.pinIsActive(self.viewport_pin.*)) {
            self.viewport = .active;
        },
        .active, .top => {},
    }
}

/// Resize the pagelist with reflow by adding or removing columns.
fn resizeCols(
    self: *PageList,
    cols: size.CellCountInt,
    cursor: ?Resize.Cursor,
) Allocator.Error!void {
    assert(cols != self.cols);

    // If we have a cursor position (x,y), then we try under any col resizing
    // to keep the same number remaining active rows beneath it. This is a
    // very special case if you can imagine clearing the screen (i.e.
    // scrollClear), having an empty active area, and then resizing to less
    // cols then we don't want the active area to "jump" to the bottom and
    // pull down scrollback.
    const preserved_cursor: ?struct {
        tracked_pin: *Pin,
        untrack: bool,
        remaining_rows: usize,
        wrapped_rows: usize,
    } = if (cursor) |c| cursor: {
        const p = if (c.pin) |cursor_pin| cursor_pin.* else self.pin(.{ .active = .{
            .x = c.x,
            .y = c.y,
        } }) orelse break :cursor null;

        const active_pin = self.pin(.{ .active = .{} });

        // We count how many wraps the cursor had before it to begin with
        // so that we can offset any additional wraps to avoid pushing the
        // original row contents in to the scrollback.
        const wrapped = wrapped: {
            var wrapped: usize = 0;

            // If shrinking rows (in the .lt branch of resize, rows shrink
            // before we get here) pushed the cursor pin above the new active
            // area, there are no rows to count and iterating .left_up toward
            // the active-area top would be an invalid (reversed) range. The
            // preserved-cursor growth below already no-ops for a cursor that
            // isn't in the active area, so we just count zero here.
            if (active_pin) |ap| {
                if (p.before(ap)) break :wrapped 0;
            }

            var row_it = p.rowIterator(.left_up, active_pin);
            while (row_it.next()) |next| {
                const row = next.rowAndCell().row;
                if (row.wrap_continuation) wrapped += 1;
            }

            break :wrapped wrapped;
        };

        break :cursor .{
            .tracked_pin = c.pin orelse try self.trackPin(p),
            .untrack = c.pin == null,
            .remaining_rows = self.rows -| (c.y + 1),
            .wrapped_rows = wrapped,
        };
    } else null;
    defer if (preserved_cursor) |c| {
        if (c.untrack) self.untrackPin(c.tracked_pin);
    };

    // Update our cols. We have to do this early because grow() that we
    // may call below relies on this to calculate the proper page size, but
    // after preserved_cursor so that the cursor pin can resolve coordinates in
    // the old active coordinate space.
    self.cols = cols;

    // Create the first node that contains our reflow.
    const first_rewritten_node = node: {
        const page = self.pages.first.?.page();
        const cap = page.capacity.adjust(
            .{ .cols = cols },
        ) catch |err| err: {
            comptime assert(@TypeOf(err) == error{OutOfMemory});

            // We verify all maxed out page layouts work.
            var cap = page.capacity;
            cap.cols = cols;

            // We're growing columns so we can only get less rows so use
            // the lesser of our capacity and size so we minimize wasted
            // rows.
            cap.rows = @min(page.size.rows, cap.rows);
            break :err cap;
        };

        const node = try self.createPage(.{ .cap = cap });
        node.page().size.rows = 1;
        break :node node;
    };

    // We need to grab our rowIterator now before we rewrite our
    // linked list below.
    var it = self.rowIterator(
        .right_down,
        .{ .screen = .{} },
        null,
    );
    errdefer {
        // If an error occurs, we're in a pretty disastrous broken state,
        // but we should still try to clean up our leaked memory. Free
        // any of the remaining orphaned pages from before. If we reflowed
        // successfully this will be null.
        var node_: ?*Node = if (it.chunk) |chunk| chunk.node else null;
        while (node_) |node| {
            node_ = node.next;
            self.destroyNode(node);
        }
    }

    // Set our new page as the only page. This orphans the existing pages
    // in the list, but that's fine since we're gonna delete them anyway.
    self.pages.first = first_rewritten_node;
    self.pages.last = first_rewritten_node;

    // Reflow all our rows.
    {
        var reflow_cursor: ReflowCursor = .init(first_rewritten_node);
        while (it.next()) |row| {
            try reflow_cursor.reflowRow(
                self,
                row,
                if (preserved_cursor) |c| c.tracked_pin else null,
            );

            // Once we're done reflowing a page, destroy it immediately.
            // This frees memory and makes it more likely in memory
            // constrained environments that the next reflow will work.
            if (row.y == row.node.rows() - 1) {
                self.destroyNode(row.node);
            }
        }

        // At the end of the reflow, setup our total row cache
        // log.warn("total old={} new={}", .{ self.total_rows, reflow_cursor.total_rows });
        self.total_rows = reflow_cursor.total_rows;
    }

    // If our total rows is less than our active rows, we need to grow.
    // This can happen if you're growing columns such that enough active
    // rows unwrap that we no longer have enough.
    var node_it = self.pages.first;
    var total: usize = 0;
    while (node_it) |node| : (node_it = node.next) {
        total += node.rows();
        if (total >= self.rows) break;
    } else {
        for (total..self.rows) |_| _ = try self.grow();
    }

    // Reflow can unwrap enough rows that a history viewport pin lands in the
    // active area before we do any preserved-cursor growth below. Switch back
    // to the active viewport now so intermediate grow() integrity checks stay
    // valid.
    switch (self.viewport) {
        .active, .top => {},
        .pin => if (self.pinIsActive(self.viewport_pin.*)) {
            self.viewport = .active;
        },
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

        const current = self.rows -| (active_pt.active.y + 1);

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

    /// This is the final row count of the reflowed pages.
    total_rows: usize,

    fn init(node: *List.Node) ReflowCursor {
        const page = node.page();
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

            // Initially whatever size our input node is.
            .total_rows = node.rows(),
        };
    }

    /// Reflow the provided row in to this cursor.
    fn reflowRow(
        self: *ReflowCursor,
        list: *PageList,
        row: Pin,
        cursor_pin: ?*Pin,
    ) Allocator.Error!void {
        const src_page: *Page = row.node.page();
        const src_row = row.rowAndCell().row;
        const src_y = row.y;
        const cells = src_row.cells.ptr(src_page.memory)[0..src_page.size.cols];

        // Calculate the columns in this row. First up we trim non-semantic
        // rightmost blanks.
        var cols_len = src_page.size.cols;
        if (!src_row.wrap) {
            while (cols_len > 0) {
                if (!cells[cols_len - 1].isEmpty()) break;
                cols_len -= 1;
            }

            // If the row has a semantic prompt then the blank row is meaningful
            // so we just consider pretend the first cell of the row isn't empty.
            if (cols_len == 0 and src_row.semantic_prompt != .none) cols_len = 1;
        }

        // Handle tracked pin adjustments.
        {
            const pin_keys = list.tracked_pins.keys();
            for (pin_keys) |p| {
                if (p.node.page() != src_page or
                    p.y != src_y) continue;

                if (cursor_pin != null and p == cursor_pin.?) continue;

                // If this pin is in the blanks on the right and past the end
                // of the dst col width then we move it to the end of the dst
                // col width instead.
                if (p.x >= cols_len) p.x = @min(
                    p.x,
                    self.page.size.cols - 1 - self.x,
                );

                // We increase our col len to at least include this pin.
                // This ensures that blank rows with pins are processed,
                // so that the pins can be properly remapped.
                cols_len = @max(cols_len, p.x + 1);
            }
        }

        // If the cursor is after blanks on the right, those cells are still
        // before the next write and must reflow with it.
        if (cursor_pin) |p| {
            if (p.node.page() == src_page and p.y == src_y) {
                cols_len = @max(cols_len, p.x + 1);
            }
        }

        // Defer processing of blank rows so that blank rows
        // at the end of the page list are never written.
        if (cols_len == 0) {
            // If this blank row was a wrap continuation somehow
            // then we won't need to write it since it should be
            // a part of the previously written row.
            if (!src_row.wrap_continuation) self.new_rows += 1;
            return;
        }

        // Inherit increased styles or grapheme bytes from the src page
        // we're reflowing from for new pages.
        const cap = src_page.capacity.adjust(
            .{ .cols = self.page.size.cols },
        ) catch |err| err: {
            comptime assert(@TypeOf(err) == error{OutOfMemory});

            var cap = src_page.capacity;
            cap.cols = self.page.size.cols;
            // We're already a non-standard page. We don't want to
            // inherit a massive set of rows, so cap it at our std size.
            cap.rows = @min(src_page.size.rows, std_capacity.rows);
            break :err cap;
        };

        // Our row isn't blank, write any new rows we deferred.
        while (self.new_rows > 0) {
            try self.cursorScrollOrNewPage(list, cap);
            self.new_rows -= 1;
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
                    if (p.node.page() != src_page or
                        p.y != src_y or
                        p.x != x) continue;

                    p.node = self.node;
                    p.x = self.x;
                    p.y = self.y;
                }
            }

            if (self.writeCell(
                list,
                &cells[x],
                src_page,
            )) |result| switch (result) {
                // Wrote the cell, move to the next.
                .success => x += 1,

                // Wrote the cell but request to skip the next so skip it.
                // This is used for things like spacers.
                .skip_next => {
                    // Remap any tracked pins at the skipped position (x+1)
                    // since we won't process that cell in the loop.
                    const pin_keys = list.tracked_pins.keys();
                    for (pin_keys) |p| {
                        if (p.node.page() != src_page or
                            p.y != src_y or
                            p.x != x + 1) continue;

                        p.node = self.node;
                        p.x = self.x;
                        p.y = self.y;
                    }

                    x += 2;
                },

                // Didn't write the cell, repeat writing this same cell.
                .repeat => {},
            } else |err| switch (err) {
                // System out of memory, we can't fix this.
                error.OutOfMemory => return error.OutOfMemory,

                // We reached the capacity of a single page and can't
                // add any more of some type of managed memory. When this
                // happens we split out the current row we're working on
                // into a new page and continue from there.
                error.OutOfSpace => if (self.y == 0) {
                    // If we're already on the first-row, we can't split
                    // any further, so we just ignore bad cells and take
                    // corrupted (but valid) cell contents.
                    log.warn("reflowRow OutOfSpace on first row, discarding cell managed memory", .{});
                    x += 1;
                    self.cursorForward();
                } else {
                    // Move our last row to a new page.
                    try self.moveLastRowToNewPage(list, cap);

                    // Do NOT increment x so that we retry writing
                    // the same existing cell.
                },
            }
        }

        // If the source row isn't wrapped then we should scroll afterwards.
        if (!src_row.wrap) {
            self.new_rows += 1;
        }
    }

    /// Write a cell. On error, this will not unwrite the cell but
    /// the cell may be incomplete (but valid). For example, if the source
    /// cell is styled and we failed to allocate space for styles, the
    /// written cell may not be styled but it is valid.
    ///
    /// The key failure to recognize for callers is when we can't increase
    /// capacity in our destination page. In this case, the caller may want
    /// to split the page at this row, rewrite the row into a new page
    /// and continue from there.
    ///
    /// But this function guarantees the terminal/page will be in a
    /// coherent state even on error.
    fn writeCell(
        self: *ReflowCursor,
        list: *PageList,
        cell: *const pagepkg.Cell,
        src_page: *const Page,
    ) IncreaseCapacityError!enum {
        success,
        repeat,
        skip_next,
    } {
        // Initialize self.page_cell with basic, unmanaged memory contents.
        {
            // This must not fail because we want to make sure we atomically
            // setup our page cell to be valid.
            errdefer comptime unreachable;

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

                            // Move to the next row (this sets pending wrap
                            // which will cause us to wrap on the next
                            // iteration).
                            self.cursorForward();

                            // Decrement the source position so that when we
                            // loop we'll process this source cell again,
                            // since we can't copy it into a spacer head.
                            return .repeat;
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
                        return .skip_next;
                    },

                    .spacer_tail => if (self.page.size.cols > 1) {
                        self.page_cell.* = cell.*;
                    } else {
                        // Edge case, when resizing to 1 column, wide
                        // characters are just destroyed and replaced
                        // with empty narrow cells, so we should just
                        // discard any spacer tails.
                        return .success;
                    },

                    .spacer_head => {
                        // Spacer heads should be ignored. If we need a
                        // spacer head in our reflowed page, it is added
                        // when processing the wide cell it belongs to.
                        return .success;
                    },
                },

                .bg_color_palette,
                .bg_color_rgb,
                => {
                    // These are guaranteed to have no style or grapheme
                    // data associated with them so we can fast path them.
                    self.page_cell.* = cell.*;
                    self.cursorForward();
                    return .success;
                },
            }

            // These will create issues by trying to clone managed memory that
            // isn't set if the current dst row needs to be moved to a new page.
            // They'll be fixed once we do properly copy the relevant memory.
            self.page_cell.content_tag = .codepoint;
            self.page_cell.hyperlink = false;
            self.page_cell.style_id = stylepkg.default_id;

            if (comptime build_options.kitty_graphics) {
                // Copy Kitty virtual placeholder status
                if (cell.codepoint() == kitty.graphics.unicode.placeholder) {
                    self.page_row.kitty_virtual_placeholder = true;
                }
            }
        }

        // std.log.warn("\nsrc_y={} src_x={} dst_y={} dst_x={} dst_cols={} cp={X} wide={} page_cell_wide={}", .{
        //     src_y,
        //     x,
        //     self.y,
        //     self.x,
        //     self.page.size.cols,
        //     cell.content.codepoint,
        //     cell.wide,
        //     self.page_cell.wide,
        // });

        // From this point on we're moving on to failable, managed memory.
        // If we reach an error, we do the minimal cleanup necessary to
        // not leave dangling memory but otherwise we gracefully degrade
        // into some functional but not strictly correct cell.

        // Copy grapheme data.
        if (cell.content_tag == .codepoint_grapheme) {
            // Copy the graphemes
            const cps = src_page.lookupGrapheme(cell).?;

            // If our page can't support an additional cell
            // with graphemes then we increase capacity.
            if (self.page.graphemeCount() >= self.page.graphemeCapacity()) {
                try self.increaseCapacity(
                    list,
                    .grapheme_bytes,
                );
            }

            // Attempt to allocate the space that would be required
            // for these graphemes, and if it's not available, then
            // increase capacity. Keep trying until we succeed.
            while (true) {
                if (self.page.grapheme_alloc.alloc(
                    u21,
                    self.page.memory,
                    cps.len,
                )) |slice| {
                    self.page.grapheme_alloc.free(
                        self.page.memory,
                        slice,
                    );
                    break;
                } else |_| {
                    // Grow our capacity until we can fit the extra bytes.
                    try self.increaseCapacity(list, .grapheme_bytes);
                }
            }

            self.page.setGraphemes(
                self.page_row,
                self.page_cell,
                cps,
            ) catch |err| {
                // This shouldn't fail since we made sure we have space
                // above. There is no reasonable behavior we can take here
                // so we have a warn level log. This is ALMOST non-recoverable,
                // though we choose to recover by corrupting the cell
                // to a non-grapheme codepoint.
                log.err("setGraphemes failed after capacity increase err={}", .{err});
                if (comptime std.debug.runtime_safety) {
                    // Force a crash with safe builds.
                    unreachable;
                }

                // Unsafe builds we throw away grapheme data!
                self.page_cell.content_tag = .codepoint;
                self.page_cell.content = .{ .codepoint = 0xFFFD };
            };
        }

        // Copy hyperlink data.
        if (cell.hyperlink) hyperlink: {
            const src_id = src_page.lookupHyperlink(cell).?;
            const src_link = src_page.hyperlink_set.get(src_page.memory, src_id);

            // If our page can't support an additional cell
            // with a hyperlink then we increase capacity.
            if (self.page.hyperlinkCount() >= self.page.hyperlinkCapacity()) {
                try self.increaseCapacity(list, .hyperlink_bytes);
            }

            // Ensure that the string alloc has sufficient capacity
            // to dupe the link (and the ID if it's not implicit).
            const additional_required_string_capacity =
                src_link.uri.len +
                switch (src_link.id) {
                    .explicit => |v| v.len,
                    .implicit => 0,
                };
            // Keep trying until we have enough capacity.
            while (true) {
                if (self.page.string_alloc.alloc(
                    u8,
                    self.page.memory,
                    additional_required_string_capacity,
                )) |slice| {
                    // We have enough capacity, free the test alloc.
                    self.page.string_alloc.free(
                        self.page.memory,
                        slice,
                    );
                    break;
                } else |_| {
                    // Grow our capacity until we can fit the extra bytes.
                    try self.increaseCapacity(
                        list,
                        .string_bytes,
                    );
                }
            }

            const dst_link = src_link.dupe(
                src_page,
                self.page,
            ) catch |err| {
                // This shouldn't fail since we did a capacity
                // check above.
                log.err("link dupe failed with capacity check err={}", .{err});
                if (comptime std.debug.runtime_safety) {
                    // Force a crash with safe builds.
                    unreachable;
                }

                break :hyperlink;
            };

            const dst_id = self.page.hyperlink_set.addWithIdContext(
                self.page.memory,
                dst_link,
                src_id,
                .{ .page = self.page },
            ) catch |err| id: {
                // Always free our original link in case the increaseCap
                // call fails so we aren't leaking memory.
                dst_link.free(self.page);

                // If the add failed then either the set needs to grow
                // or it needs to be rehashed. Either one of those can
                // be accomplished by increasing capacity, either with
                // no actual change or with an increased hyperlink cap.
                try self.increaseCapacity(list, switch (err) {
                    error.OutOfMemory => .hyperlink_bytes,
                    error.NeedsRehash => null,
                });

                // We need to recreate the link into the new page.
                const dst_link2 = src_link.dupe(
                    src_page,
                    self.page,
                ) catch |err2| {
                    // This shouldn't fail since we did a capacity
                    // check above.
                    log.err("link dupe failed with capacity check err={}", .{err2});
                    if (comptime std.debug.runtime_safety) {
                        // Force a crash with safe builds.
                        unreachable;
                    }

                    break :hyperlink;
                };

                // We assume this one will succeed. We dupe the link
                // again, and don't have to worry about the other one
                // because increasing the capacity naturally clears up
                // any managed memory not associated with a cell yet.
                break :id self.page.hyperlink_set.addWithIdContext(
                    self.page.memory,
                    dst_link2,
                    src_id,
                    .{ .page = self.page },
                ) catch |err2| {
                    // This shouldn't happen since we increased capacity
                    // above so we handle it like the other similar
                    // cases and log it, crash in safe builds, and
                    // remove the hyperlink in unsafe builds.
                    log.err(
                        "addWithIdContext failed after capacity increase err={}",
                        .{err2},
                    );
                    if (comptime std.debug.runtime_safety) {
                        // Force a crash with safe builds.
                        unreachable;
                    }

                    dst_link2.free(self.page);
                    break :hyperlink;
                };
            } orelse src_id;

            // We expect this to succeed due to the hyperlinkCapacity
            // check we did before. If it doesn't succeed let's
            // log it, crash (in safe builds), and clear our state.
            self.page.setHyperlink(
                self.page_row,
                self.page_cell,
                dst_id,
            ) catch |err| {
                log.err(
                    "setHyperlink failed after capacity increase err={}",
                    .{err},
                );
                if (comptime std.debug.runtime_safety) {
                    // Force a crash with safe builds.
                    unreachable;
                }

                // Unsafe builds we throw away hyperlink data!
                self.page.hyperlink_set.release(self.page.memory, dst_id);
                self.page_cell.hyperlink = false;
                break :hyperlink;
            };
        }

        // Copy style data.
        if (cell.hasStyling()) style: {
            const style = src_page.styles.get(
                src_page.memory,
                cell.style_id,
            ).*;

            const id = self.page.styles.addWithId(
                self.page.memory,
                style,
                cell.style_id,
            ) catch |err| id: {
                // If the add failed then either the set needs to grow
                // or it needs to be rehashed. Either one of those can
                // be accomplished by increasing capacity, either with
                // no actual change or with an increased style cap.
                try self.increaseCapacity(list, switch (err) {
                    error.OutOfMemory => .styles,
                    error.NeedsRehash => null,
                });

                // We assume this one will succeed.
                break :id self.page.styles.addWithId(
                    self.page.memory,
                    style,
                    cell.style_id,
                ) catch |err2| {
                    // Should not fail since we just modified capacity
                    // above. Log it, crash in safe builds, clear style
                    // in unsafe builds.
                    log.err(
                        "addWithId failed after capacity increase err={}",
                        .{err2},
                    );
                    if (comptime std.debug.runtime_safety) {
                        // Force a crash with safe builds.
                        unreachable;
                    }

                    self.page_cell.style_id = stylepkg.default_id;
                    break :style;
                };
            } orelse cell.style_id;

            self.page_row.styled = true;
            self.page_cell.style_id = id;
        }

        self.cursorForward();
        return .success;
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
    ) Allocator.Error!void {
        assert(self.y == self.page.size.rows - 1);
        assert(!self.pending_wrap);

        const old_node = self.node;
        const old_page = self.page;
        const old_row = self.page_row;
        const old_x = self.x;

        // Our total row count never changes, because we're removing one
        // row from the last page and moving it into a new page.
        const old_total_rows = self.total_rows;
        defer self.total_rows = old_total_rows;

        try self.cursorNewPage(list, cap);
        assert(self.node != old_node);
        assert(self.y == 0);

        // We have no cleanup for our old state from here on out. No failures!
        errdefer comptime unreachable;

        // Restore the x position of the cursor.
        self.cursorAbsolute(old_x, 0);

        // Copy our old data. This should NOT fail because we have the
        // capacity of the old page which already fits the data we requested.
        self.page.cloneRowFrom(
            old_page,
            self.page_row,
            old_row,
        ) catch |err| {
            log.err(
                "error cloning single row for moveLastRowToNewPage err={}",
                .{err},
            );
            @panic("unexpected copy row failure");
        };

        // Move any tracked pins from that last row into this new node.
        {
            const pin_keys = list.tracked_pins.keys();
            for (pin_keys) |p| {
                if (p.node.page() != old_page or
                    p.y != old_page.size.rows - 1) continue;

                p.node = self.node;
                p.y = self.y;
                // p.x remains the same since we're copying the row as-is
            }
        }

        // Clear the row from the old page and truncate it.
        old_page.clearCells(old_row, 0, old_page.size.cols);
        old_page.size.rows -= 1;

        // If that was the last row in that page
        // then we should remove it from the list.
        if (old_page.size.rows == 0) {
            list.pages.remove(old_node);
            list.destroyNode(old_node);
        }
    }

    /// Increase the capacity of the current page.
    fn increaseCapacity(
        self: *ReflowCursor,
        list: *PageList,
        adjustment: ?IncreaseCapacity,
    ) IncreaseCapacityError!void {
        const old_x = self.x;
        const old_y = self.y;
        const old_total_rows = self.total_rows;

        const node = node: {
            // Pause integrity checks because the total row count won't
            // be correct during a reflow.
            list.pauseIntegrityChecks(true);
            defer list.pauseIntegrityChecks(false);
            break :node try list.increaseCapacity(
                self.node,
                adjustment,
            );
        };
        // We must not fail after this, we've modified our self.node
        // and we need to fix it up.
        errdefer comptime unreachable;

        self.* = .init(node);
        self.cursorAbsolute(old_x, old_y);
        self.total_rows = old_total_rows;
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
    ) Allocator.Error!void {
        // Remember our new row count so we can restore it
        // after reinitializing our cursor on the new page.
        const new_rows = self.new_rows;

        const node = try list.createPage(.{ .cap = cap });
        errdefer comptime unreachable;
        node.page().size.rows = 1;
        list.pages.insertAfter(self.node, node);

        self.* = .init(node);
        self.new_rows = new_rows;
    }

    /// Performs `cursorScroll` or `cursorNewPage` as necessary
    /// depending on if the cursor is currently at the bottom.
    fn cursorScrollOrNewPage(
        self: *ReflowCursor,
        list: *PageList,
        cap: Capacity,
    ) Allocator.Error!void {
        // The functions below may overwrite self so we need to cache
        // our total rows. We add one because no matter what when this
        // returns we'll have one more row added.
        const new_total_rows: usize = self.total_rows + 1;
        defer self.total_rows = new_total_rows;

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
        if (self.page_row.semantic_prompt != .none) return len - 1;

        return len;
    }

    fn copyRowMetadata(self: *ReflowCursor, other: *const Row) void {
        self.page_row.semantic_prompt = other.semantic_prompt;
    }
};

fn resizeWithoutReflow(self: *PageList, opts: Resize) Allocator.Error!void {
    // We only set the new min_max_size if we're not reflowing. If we are
    // reflowing, then resize handles this for us.
    const old_min_max_size = self.min_max_size;
    self.min_max_size = if (!opts.reflow) minMaxSize(
        opts.cols orelse self.cols,
        opts.rows orelse self.rows,
    ) else old_min_max_size;
    errdefer self.min_max_size = old_min_max_size;

    // Important! We have to do cols first because cols may cause us to
    // destroy pages if we're increasing cols which will free up page_size
    // so that when we call grow() in the row mods, we won't prune.
    if (opts.cols) |cols| {
        // Any column change without reflow should not result in row counts
        // changing.
        const old_total_rows = self.total_rows;
        defer assert(self.total_rows == old_total_rows);

        switch (std.math.order(cols, self.cols)) {
            .eq => {},

            // Making our columns smaller. We always have space for this
            // in existing pages so we need to go through the pages,
            // resize the columns, and clear any cells that are beyond
            // the new size.
            .lt => {
                var it = self.pageIterator(.right_down, .{ .screen = .{} }, null);
                while (it.next()) |chunk| {
                    const page = chunk.node.page();
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
                const trimmed = self.trimTrailingBlankRows(self.rows - rows);

                // Account for our trimmed rows in the total row cache
                self.total_rows -= trimmed;

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
                // This traversal intentionally reads only node metadata. A
                // compressed history page pulled into the active area remains
                // compressed until a renderer or other content consumer goes
                // through `Node.page`, which restores it transparently.
                //
                // If we don't have enough scrollback, we add the difference,
                // to the active area.
                var count: usize = 0;
                var page = self.pages.first;
                while (page) |p| : (page = p.next) {
                    count += p.rows();
                    if (count >= rows) break;
                } else {
                    assert(count < rows);
                    for (count..rows) |_| _ = try self.grow();
                }

                // Make sure that the viewport pin isn't below the active
                // area, since that will lead to all sorts of problems.
                switch (self.viewport) {
                    .pin => if (self.pinIsActive(self.viewport_pin.*)) {
                        self.viewport = .active;
                    },
                    .active, .top => {},
                }
            },
        }

        if (build_options.slow_runtime_safety) {
            // We never have less rows than our active screen has.
            assert(self.totalRows() >= self.rows);
        }
    }
}

fn resizeWithoutReflowGrowCols(
    self: *PageList,
    cols: size.CellCountInt,
    chunk: PageIterator.Chunk,
) Allocator.Error!void {
    assert(cols > self.cols);
    const page = chunk.node.page();

    // Update our col count
    const old_cols = self.cols;
    self.cols = cols;
    errdefer self.cols = old_cols;

    // Unlikely fast path: we have capacity in the page. This
    // is only true if we resized to less cols earlier.
    if (page.capacity.cols >= cols) fast: {
        // If any row has a spacer head at the old last column, it will
        // be invalid at the new (wider) size. Fall through to the slow
        // path which handles spacer heads correctly via cloneRowFrom.
        const rows = page.rows.ptr(page.memory)[0..page.size.rows];
        for (rows) |*row| {
            const cells = page.getCells(row);
            if (cells[old_cols - 1].wide == .spacer_head) break :fast;
        }

        page.size.cols = cols;
        return;
    }

    // Likely slow path: we don't have capacity, so we need
    // to allocate a page, and copy the old data into it.

    // Try to fit our new column size into our existing page capacity.
    // If that doesn't work then use a non-standard page with the
    // given columns.
    const cap = page.capacity.adjust(
        .{ .cols = cols },
    ) catch |err| err: {
        comptime assert(@TypeOf(err) == error{OutOfMemory});

        // We verify all maxed out page layouts don't overflow,
        var cap = page.capacity;
        cap.cols = cols;

        // We're growing columns so we can only get less rows so use
        // the lesser of our capacity and size so we minimize wasted
        // rows.
        cap.rows = @min(page.size.rows, cap.rows);
        break :err cap;
    };

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
        const prev_page = prev_node.page();

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

        // Remap any tracked pins that pointed to rows we just copied to prev.
        const pin_keys = self.tracked_pins.keys();
        for (pin_keys) |p| {
            if (p.node != chunk.node or p.y >= len) continue;
            p.node = prev_node;
            p.y += prev_page.size.rows - len;
        }
    }

    // If we have an error, we clear the rows we just added to our prev page.
    const prev_copied = copied;
    errdefer if (prev_copied > 0) {
        const prev_page = prev.?.page();
        const prev_size = prev_page.size.rows - prev_copied;
        const prev_rows = prev_page.rows.ptr(prev_page.memory)[prev_size..prev_page.size.rows];
        for (prev_rows) |*row| prev_page.clearCells(
            row,
            0,
            prev_page.size.cols,
        );
        prev_page.size.rows = prev_size;
    };

    // We delete any of the nodes we added.
    errdefer {
        var it = chunk.node.prev;
        while (it) |node| {
            if (node == prev) break;
            it = node.prev;
            self.pages.remove(node);
            self.destroyNode(node);
        }
    }

    // We need to loop because our col growth may force us
    // to split pages.
    while (copied < page.size.rows) {
        const new_node = try self.createPage(.{ .cap = cap });
        const new_page = new_node.page();
        defer new_page.assertIntegrity();

        // The length we can copy into the new page is at most the number
        // of rows in our cap. But if we can finish our source page we use that.
        const len = @min(cap.rows, page.size.rows - copied);

        // Perform the copy
        const y_start = copied;
        const src_rows = page.rows.ptr(page.memory)[y_start .. copied + len];
        const dst_rows = new_page.rows.ptr(new_page.memory)[0..len];
        for (dst_rows, src_rows) |*dst_row, *src_row| {
            new_page.size.rows += 1;
            if (new_page.cloneRowFrom(
                page,
                dst_row,
                src_row,
            )) |_| {
                copied += 1;
            } else |err| {
                // I don't THINK this should be possible, because while our
                // row count may diminish due to the adjustment, our
                // prior capacity should have been sufficient to hold all the
                // managed memory.
                log.warn(
                    "unexpected cloneRowFrom failure during resizeWithoutReflowGrowCols: {}",
                    .{err},
                );

                // We can actually safely handle this though by exiting
                // this loop early and cutting our copy short.
                new_page.size.rows -= 1;
                break;
            }
        }
        const y_end = copied;

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

    // Our prior errdeferes are invalid after this point so ensure
    // we don't have any more errors.
    errdefer comptime unreachable;

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
    while (it) |node| : (it = node.prev) {
        const page = node.page();
        const len = node.rows();
        const rows = page.rows.ptr(page.memory)[0..len];
        for (0..len) |i| {
            const rev_i = len - i - 1;
            const cells = rows[rev_i].cells.ptr(page.memory)[0..node.cols()];

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
///
/// IMPORTANT: This function does NOT update `total_rows`. It returns the
/// number of rows trimmed, and the caller is responsible for decrementing
/// `total_rows` by this amount.
fn trimTrailingBlankRows(
    self: *PageList,
    max: size.CellCountInt,
) size.CellCountInt {
    var trimmed: size.CellCountInt = 0;
    var invalidated_node: ?*List.Node = null;
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
        if (row_pin.node.rows() > 1 and invalidated_node != row_pin.node) {
            // Shrinking a retained page changes its valid row-coordinate range.
            self.invalidateNodeLayout(row_pin.node);
            invalidated_node = row_pin.node;
        }
        row_pin.node.page().size.rows -= 1;
        if (row_pin.node.page().size.rows == 0) {
            self.erasePage(row_pin.node);
        } else {
            row_pin.node.page().assertIntegrity();
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

    /// Scroll to the given absolute row from the top. A value of zero
    /// is the top row. This row will be the first visible row in the viewport.
    /// Scrolling into or below the active area will clamp to the active area.
    row: usize,

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
    defer self.assertIntegrity();

    // Special case no-scrollback mode to never allow scrolling.
    if (self.explicit_max_size == 0) {
        self.viewport = .active;
        return;
    }

    // Moving the viewport changes which historical pages are visible. Restart
    // traversal so pages which leave the viewport are reconsidered after the
    // renderer's idle delay. False positives from clamped scrolling are cheap.
    defer {
        self.page_compression.reset();
        self.page_compression.markActivity();
    }

    switch (behavior) {
        .active => self.viewport = .active,
        .top => self.viewport = .top,
        .pin => |p| {
            if (self.pinIsActive(p)) {
                self.viewport = .active;
                return;
            } else if (self.pinIsTop(p)) {
                self.viewport = .top;
                return;
            }

            self.viewport_pin.* = p;
            self.viewport = .pin;
            self.viewport_pin_row_offset = null; // invalidate cache
        },
        .row => |n| row: {
            // If we're at the top, pin the top.
            if (n == 0) {
                self.viewport = .top;
                break :row;
            }

            // If we're below the top of the active area, pin the active area.
            if (n >= self.total_rows - self.rows) {
                self.viewport = .active;
                break :row;
            }

            // See if there are any other faster paths we can take.
            switch (self.viewport) {
                .top, .active => {},
                .pin => if (self.viewport_pin_row_offset) |*v| {
                    // If we have a pin and we already calculated a row offset,
                    // then we can efficiently calculate the delta and move
                    // that much from that pin.
                    const delta: isize = delta: {
                        const n_isize: isize = @intCast(n);
                        const v_isize: isize = @intCast(v.*);
                        break :delta n_isize - v_isize;
                    };
                    self.scroll(.{ .delta_row = delta });
                    return;
                },
            }

            // We have an accurate row offset so store it to prevent
            // calculating this again.
            self.viewport_pin_row_offset = n;
            self.viewport = .pin;

            // Slow path, we've just got to traverse the linked list and
            // get to our row. As a slight speedup, let's pick the traversal
            // that's likely faster based on our absolute row and total rows.
            const midpoint = self.total_rows / 2;
            if (n < midpoint) {
                // Iterate forward from the first node.
                var node_it = self.pages.first;
                var rem: usize = n;
                while (node_it) |node| : (node_it = node.next) {
                    if (rem < node.rows()) {
                        self.viewport_pin.* = .{
                            .node = node,
                            .y = std.math.cast(size.CellCountInt, rem) orelse {
                                self.viewport = .active;
                                break :row;
                            },
                        };
                        break :row;
                    }

                    rem -= node.rows();
                }
            } else {
                // Iterate backwards from the last node.
                var node_it = self.pages.last;
                var rem: usize = self.total_rows - n;
                while (node_it) |node| : (node_it = node.prev) {
                    if (rem <= node.rows()) {
                        self.viewport_pin.* = .{
                            .node = node,
                            .y = std.math.cast(size.CellCountInt, node.rows() - rem) orelse {
                                self.viewport = .active;
                                break :row;
                            },
                        };
                        break :row;
                    }

                    rem -= node.rows();
                }
            }

            // If we reached here, then we couldn't find the offset.
            // This feels impossible? Just clamp to active, screw it lol.
            self.viewport = .active;
        },
        .delta_prompt => |n| self.scrollPrompt(n),
        .delta_row => |n| delta_row: {
            const amount: usize = @abs(n);

            switch (self.viewport) {
                // If we're at the top and we're scrolling backwards,
                // we don't have to do anything, because there's nowhere to go.
                .top => if (n <= 0) break :delta_row,

                // If we're at active and we're scrolling forwards, we don't
                // have to do anything because it'll result in staying in
                // the active.
                .active => if (n >= 0) break :delta_row,

                // If we're already a pin type, then we can fast-path our
                // delta by simply moving the pin. This has the added benefit
                // that we can update our row offset cache efficiently, too.
                .pin => switch (std.math.order(n, 0)) {
                    .eq => break :delta_row,

                    .lt => switch (self.viewport_pin.upOverflow(amount)) {
                        .offset => |new_pin| {
                            self.viewport_pin.* = new_pin;
                            if (self.viewport_pin_row_offset) |*v| {
                                v.* -= amount;
                            }
                            break :delta_row;
                        },

                        // If we overflow up we're at the top.
                        .overflow => {
                            self.viewport = .top;
                            break :delta_row;
                        },
                    },

                    .gt => switch (self.viewport_pin.downOverflow(amount)) {
                        // If we offset its a valid pin but we still have to
                        // check if we're in the active area.
                        .offset => |new_pin| {
                            if (self.pinIsActive(new_pin)) {
                                self.viewport = .active;
                            } else {
                                self.viewport_pin.* = new_pin;
                                if (self.viewport_pin_row_offset) |*v| {
                                    v.* += amount;
                                }
                            }
                            break :delta_row;
                        },

                        // If we overflow down we're at active.
                        .overflow => {
                            self.viewport = .active;
                            break :delta_row;
                        },
                    },
                },
            }

            // Slow path: we have to calculate the new pin by moving
            // from our viewport.
            const top = self.getTopLeft(.viewport);
            const p: Pin = if (n < 0) switch (top.upOverflow(amount)) {
                .offset => |v| v,
                .overflow => |v| v.end,
            } else switch (top.downOverflow(amount)) {
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
                self.viewport = .active;
                return;
            }

            // If we're at the top, then just set the top. This is a lot
            // more efficient everywhere. We must check this after the
            // active check above because we prefer active if they overlap.
            if (self.pinIsTop(p)) {
                self.viewport = .top;
                return;
            }

            // Pin is not active so we need to track it.
            self.viewport_pin.* = p;
            self.viewport = .pin;
            self.viewport_pin_row_offset = null; // invalidate cache
        },
    }
}

/// Jump the viewport forwards (positive) or backwards (negative) a set number of
/// prompts (delta).
fn scrollPrompt(self: *PageList, delta: isize) void {
    // If we aren't jumping any prompts then we don't need to do anything.
    if (delta == 0) return;
    const delta_start: usize = @abs(delta);
    var delta_rem: usize = delta_start;

    // We start at the row before or after our viewport depending on the
    // delta so that we don't land back on our current viewport.
    const start_pin = start: {
        const tl = self.getTopLeft(.viewport);

        // If we're moving up we can just move the viewport up because
        // promptIterator handles jumpting to the start of prompts.
        if (delta <= 0) break :start tl.up(1) orelse return;

        // If we're moving down and we're presently at some kind of
        // prompt, we need to skip all the continuation lines because
        // promptIterator can't know if we're cutoff or continuing.
        var adjusted: Pin = tl.down(1) orelse return;
        if (tl.rowAndCell().row.semantic_prompt != .none) skip: {
            while (adjusted.rowAndCell().row.semantic_prompt == .prompt_continuation) {
                adjusted = adjusted.down(1) orelse break :skip;
            }
        }

        break :start adjusted;
    };

    // Go through prompts delta times
    var it = start_pin.promptIterator(
        if (delta > 0) .right_down else .left_up,
        null,
    );
    var prompt_pin: ?Pin = null;
    while (it.next()) |next| {
        prompt_pin = next;
        delta_rem -= 1;
        if (delta_rem == 0) break;
    }

    // If we found a prompt, we move to it. If the prompt is in the active
    // area we keep our viewport as active because we can't scroll DOWN
    // into the active area. Otherwise, we scroll up to the pin.
    if (prompt_pin) |p| {
        if (self.pinIsActive(p)) {
            self.viewport = .active;
        } else {
            self.viewport_pin.* = p;
            self.viewport = .pin;
            self.viewport_pin_row_offset = null; // invalidate cache
        }
    }
}

/// Clear the screen by scrolling written contents up into the scrollback.
/// This will not update the viewport.
pub fn scrollClear(self: *PageList) Allocator.Error!void {
    defer self.assertIntegrity();

    // Go through the active area backwards to find the first non-empty
    // row. We use this to determine how many rows to scroll up.
    const non_empty: usize = non_empty: {
        var page = self.pages.last.?;
        var n: usize = 0;
        while (true) {
            const current_page = page.page();
            const rows: [*]Row = current_page.rows.ptr(current_page.memory);
            for (0..page.rows()) |i| {
                const rev_i = page.rows() - i - 1;
                const row = rows[rev_i];
                const cells = row.cells.ptr(current_page.memory)[0..self.cols];
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

/// Give a live node a new generation before changing its coordinate layout in
/// place.
///
/// This must be called when a node remains at the same address and stays in the
/// list, but a mutation changes which logical row a `(node, y)` coordinate
/// identifies or whether that coordinate is still in range. Examples include
/// rotating rows after an erase, truncating a page's row range, reinitializing
/// the sole remaining page, or shortening the source page of a split. Without
/// a new generation, a cached pointer, serial, and coordinate could still pass
/// `nodeIsValid` while referring to a different row than it originally did.
/// Screen and Terminal fast paths which manipulate Page rows directly must use
/// this because they bypass PageList's own row-mutation helpers.
///
/// The caller must pass a node which is currently live in this PageList. Call
/// this at the point the operation commits to changing the layout and before
/// the first such change. When an operation is intended to be atomic, finish
/// its failable preparation first so a failed operation does not needlessly
/// invalidate references. One call per affected node is sufficient when an
/// operation performs several layout changes without exposing intermediate
/// references.
///
/// This helper is only needed for in-place changes. Removing or replacing a
/// node already invalidates old references through the live-list check in
/// `nodeIsValid`, and newly allocated or reused nodes receive a fresh serial as
/// part of their initialization. Ordinary cell or style changes which preserve
/// the meaning of page coordinates do not require a new generation solely for
/// that reason.
///
/// The only state changed here is `node.serial` and the next-generation counter
/// `page_serial`. Consequently, every previously captured pointer-plus-serial
/// pair for this node becomes invalid while new references can capture the new
/// generation. This does not advance `page_serial_epoch`: only `reset` starts a
/// new whole-list validity epoch.
///
/// This also does not mutate the page, update tracked pins or viewport state,
/// adjust row or memory accounting, mark cells dirty, or notify incremental
/// compression. The surrounding operation remains responsible for all such
/// bookkeeping required by its layout change.
pub fn invalidateNodeLayout(self: *PageList, node: *List.Node) void {
    node.serial = self.page_serial;
    self.page_serial += 1;
}

/// Compact a page to use the minimum required memory for the contents
/// it stores. Returns the new node pointer if compaction occurred, or null
/// if the page was already compact or compaction would not provide any
/// savings.
///
/// The compacted page is always an exact-size heap allocation, never
/// a pool item, since a pool item always retains a full std_size
/// buffer regardless of the page layout. Note that this means that
/// when compacting a pool-owned node, the freed pool item is returned
/// to the pool free list, so the memory savings are only fully
/// realized once the pool itself is reset or freed.
///
/// If this returns OOM, the PageList is left unchanged and no dangling
/// memory references exist. It is safe to ignore the error and continue using
/// the uncompacted page.
pub fn compact(self: *PageList, node: *List.Node) Allocator.Error!?*List.Node {
    defer self.assertIntegrity();
    const page: *Page = node.page();

    // We should never have empty rows in our pagelist anyways...
    assert(page.size.rows > 0);

    // Compute the minimum capacity required for this page's content
    const req_cap = page.exactRowCapacity(0, page.size.rows);
    const new_size = Page.layout(req_cap).total_size;

    // The memory this node currently retains. A pool-owned node always
    // retains a full pool item no matter its layout size.
    const old_size: usize = switch (node.owned) {
        .pool => PagePool.item_size,
        .heap => page.memory.len,
    };
    if (new_size >= old_size) return null;

    // Create the new smaller page
    const new_node = try self.createPage(.{
        .cap = req_cap,
        .exact_size = true,
    });
    errdefer self.destroyNode(new_node);
    const new_page: *Page = new_node.page();
    new_page.size = page.size;
    new_page.dirty = page.dirty;
    new_page.cloneFrom(
        page,
        0,
        page.size.rows,
    ) catch |err| {
        // cloneFrom should not fail when compacting since req_cap is
        // computed to exactly fit the source content and our expectation
        // of exactRowCapacity ensures it can fit all the requested
        // data.
        log.err("compact clone failed err={}", .{err});

        // In this case, let's gracefully degrade by pretending we
        // didn't need to compact.
        self.destroyNode(new_node);
        return null;
    };

    // Fix up all tracked pins to point to the new page
    const pin_keys = self.tracked_pins.keys();
    for (pin_keys) |p| {
        if (p.node != node) continue;
        p.node = new_node;
    }

    // Insert the new page and destroy the old one
    self.pages.insertBefore(node, new_node);
    self.pages.remove(node);
    self.destroyNode(node);
    self.page_compression.markActivity();

    new_page.assertIntegrity();
    return new_node;
}

pub const SplitError = error{
    // Allocator OOM
    OutOfMemory,
    // Page can't be split further because it is already a single row.
    OutOfSpace,
};

/// Split the given node in the PageList at the given pin.
///
/// The row at the pin and after will be moved into a new page with
/// the same capacity as the original page. Alternatively, you can "split
/// above" by splitting the row following the desired split row.
///
/// Since the split happens below the pin, the pin remains valid.
pub fn split(
    self: *PageList,
    p: Pin,
) SplitError!void {
    if (build_options.slow_runtime_safety) assert(self.pinIsValid(p));

    // Ran into a bug that I can only explain via aliasing. If a tracked
    // pin is passed in, its possible Zig will alias the memory and then
    // when we modify it later it updates our p here. Copying the node
    // fixes this.
    const original_node = p.node;
    const page: *Page = original_node.page();

    // A page that is already 1 row can't be split. In the future we can
    // theoretically maybe split by soft-wrapping multiple pages but that
    // seems crazy and the rest of our PageList can't handle heterogeneously
    // sized pages today.
    if (page.size.rows <= 1) return error.OutOfSpace;

    // Splitting at row 0 is a no-op since there's nothing before the split point.
    if (p.y == 0) return;

    // At this point we're doing actual modification so make sure
    // on the return that we're good.
    defer self.assertIntegrity();

    // Create a new node with the same capacity of managed memory.
    const target = try self.createPage(.{ .cap = page.capacity });
    errdefer self.destroyNode(target);

    // Determine how many rows we're copying
    const y_start = p.y;
    const y_end = page.size.rows;
    target.page().size.rows = y_end - y_start;
    assert(target.rows() <= target.capacity().rows);

    // Copy our old data. This should NOT fail because we have the
    // capacity of the old page which already fits the data we requested.
    target.page().cloneFrom(page, y_start, y_end) catch |err| {
        log.err(
            "error cloning rows for split err={}",
            .{err},
        );

        // Rather than crash, we return an OutOfSpace to show that
        // we couldn't split and let our callers gracefully handle it.
        // Realistically though... this should not happen.
        return error.OutOfSpace;
    };

    // From this point forward there is no going back. We have no
    // error handling. It is possible but we haven't written it.
    errdefer comptime unreachable;

    // Failable split work is complete; shortening the source changes its row range.
    self.invalidateNodeLayout(original_node);
    self.page_compression.markActivity();

    // Move any tracked pins from the copied rows
    for (self.tracked_pins.keys()) |tracked| {
        if (tracked.node.page() != page or
            tracked.y < p.y) continue;

        tracked.node = target;
        tracked.y -= p.y;
        // p.x remains the same since we're copying the row as-is
    }

    // Clear our rows
    for (page.rows.ptr(page.memory)[y_start..y_end]) |*row| {
        page.clearCells(
            row,
            0,
            page.size.cols,
        );
    }
    page.size.rows -= y_end - y_start;

    self.pages.insertAfter(original_node, target);
}

/// This represents the state necessary to render a scrollbar for this
/// PageList. It has the total size, the offset, and the size of the viewport.
pub const Scrollbar = struct {
    /// Total size of the scrollable area.
    total: usize,

    /// The offset into the total area that the viewport is at. This is
    /// guaranteed to be less than or equal to total. This includes the
    /// visible row.
    offset: usize,

    /// The length of the visible area. This is including the offset row.
    len: usize,

    /// A zero-sized scrollable region.
    pub const zero: Scrollbar = .{
        .total = 0,
        .offset = 0,
        .len = 0,
    };

    // Sync with: ghostty_action_scrollbar_s
    pub const C = extern struct {
        total: u64,
        offset: u64,
        len: u64,
    };

    pub fn cval(self: Scrollbar) C {
        return .{
            .total = @intCast(self.total),
            .offset = @intCast(self.offset),
            .len = @intCast(self.len),
        };
    }

    /// Comparison for scrollbars.
    pub fn eql(self: Scrollbar, other: Scrollbar) bool {
        return self.total == other.total and
            self.offset == other.offset and
            self.len == other.len;
    }
};

/// Return the scrollbar state for this PageList.
///
/// This is amortized O(1): the total is maintained incrementally and
/// the viewport offset is cached. The first call after the viewport
/// moves to an arbitrary pin (e.g. scrolling to a selection) may cost
/// O(pages) to compute the offset, after which it is cached again.
/// See viewportRowOffset for more details.
pub fn scrollbar(self: *PageList) Scrollbar {
    // If we have no scrollback, special case no scrollbar.
    // We need to do this because the way PageList works is that
    // it always has SOME extra space (due to the way we allocate by page).
    // So even with no scrollback we have some growth. It is architecturally
    // much simpler to just hide that for no-scrollback cases.
    if (self.explicit_max_size == 0) return .{
        .total = self.rows,
        .offset = 0,
        .len = self.rows,
    };

    return .{
        .total = self.total_rows,
        .offset = self.viewportRowOffset(),
        .len = self.rows, // Length is always rows
    };
}

/// Returns the offset of the current viewport from the top of the
/// screen.
///
/// This is potentially expensive to calculate because if the viewport
/// is a pin and the pin is near the beginning of the scrollback, we
/// will traverse a lot of linked list nodes.
///
/// The result is cached so repeated calls are cheap.
fn viewportRowOffset(self: *PageList) usize {
    return switch (self.viewport) {
        .top => 0,
        .active => self.total_rows - self.rows,
        .pin => pin: {
            // We assert integrity on this code path because it verifies
            // that the cached value is correct.
            defer self.assertIntegrity();

            // Return cached value if available
            if (self.viewport_pin_row_offset) |cached| break :pin cached;

            // Traverse from the end and count rows until we reach the
            // viewport pin. We count backwards because most of the time
            // a user is scrolling near the active area.
            const top_offset: usize = offset: {
                var offset: usize = 0;
                var node = self.pages.last;
                while (node) |n| : (node = n.prev) {
                    offset += n.rows();
                    if (n == self.viewport_pin.node) {
                        assert(n.rows() > self.viewport_pin.y);
                        offset -= self.viewport_pin.y;
                        break :offset self.total_rows - offset;
                    }
                }

                // Invalid pins are not possible.
                unreachable;
            };

            // The offset is from the bottom and our cached value and this
            // function returns from the top, so we need to invert it.
            self.viewport_pin_row_offset = top_offset;
            break :pin top_offset;
        },
    };
}

/// This fixes up the viewport data when rows are removed from the
/// PageList. This will update a viewport to `active` if row removal
/// puts the viewport into the active area, to `top` if the viewport
/// is now at row 0, and updates any row offset caches as necessary.
///
/// This is unit tested transitively through other tests such as
/// eraseRows.
fn fixupViewport(
    self: *PageList,
    removed: usize,
) void {
    switch (self.viewport) {
        .active => {},

        // For pin, we check if our pin is now in the active area and if so
        // we move our viewport back to the active area.
        .pin => if (self.pinIsActive(self.viewport_pin.*)) {
            self.viewport = .active;
        } else if (self.viewport_pin_row_offset) |*v| {
            // If we have a cached row offset, we need to update it
            // to account for the erased rows.
            if (v.* < removed) {
                self.viewport = .top;
            } else {
                v.* -= removed;
            }
        },

        // For top, we move back to active if our erasing moved our
        // top page into the active area.
        .top => if (self.pinIsActive(.{ .node = self.pages.first.? })) {
            self.viewport = .active;
        },
    }
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

/// Grow the active area by exactly one row.
///
/// This may allocate, but also may not if our current page has more
/// capacity we can use. This will prune scrollback if necessary to
/// adhere to max_size.
///
/// This returns the newly allocated page node if there is one.
pub fn grow(self: *PageList) Allocator.Error!?*List.Node {
    defer self.assertIntegrity();

    // Growing can move a complete page behind the active boundary.
    self.page_compression.markActivity();

    const last = self.pages.last.?;
    if (last.capacity().rows > last.rows()) {
        // Fast path: we have capacity in the last page.
        const page = last.page();
        page.size.rows += 1;
        page.assertIntegrity();

        // Increase our total rows by one
        self.total_rows += 1;

        return null;
    }

    // Slower path: we have no space, we need to allocate a new page.

    // Get the layout first so our failable work is done early.
    // We'll need this for both paths.
    const cap = initialCapacity(self.cols);

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
        const first = self.pages.popFirst().?;
        assert(first != last);

        // Decrease our total row count from the pruned page
        self.total_rows -= first.rows();

        // If our total row count is now less than our required
        // rows then we can't prune. The "+ 1" is because we'll add one
        // more row below.
        if (self.total_rows + 1 < self.rows) {
            self.pages.prepend(first);
            assert(self.pages.first == first);
            self.total_rows += first.rows();
            break :prune;
        }

        // If we have a pin viewport cache then we need to update it.
        if (self.viewport == .pin) viewport: {
            if (self.viewport_pin_row_offset) |*v| {
                // If our offset is less than the number of rows in the
                // pruned page, then we are now at the top.
                if (v.* < first.rows()) {
                    self.viewport = .top;
                    break :viewport;
                }

                // Otherwise, our viewport pin is below what we pruned
                // so we just decrement our offset.
                v.* -= first.rows();
            }
        }

        // Update any tracked pins that point to this page to point to the
        // new first page to the top-left, and mark them as garbage.
        const pin_keys = self.tracked_pins.keys();
        for (pin_keys) |p| {
            if (p.node != first) continue;
            p.node = self.pages.first.?;
            p.y = 0;
            p.x = 0;
            p.garbage = true;
        }
        self.viewport_pin.garbage = false;

        switch (first.owned) {
            // Pool-owned pages are reused below.
            .pool => {},

            // Heap-owned pages can't be reused because they may be
            // any size (larger or smaller than a standard page), so
            // just destroy them.
            .heap => {
                self.destroyNode(first);
                break :prune;
            },
        }

        // Reset our memory
        const buf = first.restore(.discard).memory;
        @memset(buf, 0);
        assert(buf.len <= std_size);

        // Initialize our new page and reinsert it as the last
        first.data = .{ .resident = .initBuf(.init(buf), Page.layout(cap)) };
        const page = first.page();
        page.size.rows = 1;
        self.pages.insertAfter(last, first);
        self.total_rows += 1;

        // Reusing the node gives it a fresh generation. Do not begin a new
        // page_serial_epoch here: generations are not monotonic in list order,
        // so older live successors may have lower generations. The epoch only
        // advances when reset invalidates the entire list.
        first.serial = self.page_serial;
        self.page_serial += 1;

        // In this case we do NOT need to update page_size because
        // we're reusing an existing page so nothing has changed.

        page.assertIntegrity();
        return first;
    }

    // We need to allocate a new memory buffer.
    const next_node = try self.createPage(.{ .cap = cap });
    // we don't errdefer this because we've added it to the linked
    // list and its fine to have dangling unused pages.
    self.pages.append(next_node);
    const page = next_node.page();
    page.size.rows = 1;

    // We should never be more than our max size here because we've
    // verified the case above.
    page.assertIntegrity();

    // Record the increased row count
    self.total_rows += 1;

    return next_node;
}

/// Possible dimensions to increase capacity for.
pub const IncreaseCapacity = enum {
    styles,
    grapheme_bytes,
    hyperlink_bytes,
    string_bytes,
};

pub const IncreaseCapacityError = error{
    // An actual system OOM trying to allocate memory.
    OutOfMemory,

    // The existing page is already at max capacity for the given
    // adjustment. The caller must create a new page, remove data from
    // the old page, etc. (up to the caller).
    OutOfSpace,
};

/// Increase the capacity of the given page node in the given direction.
/// This will always allocate a new node and remove the old node, so the
/// existing node pointer will be invalid after this call. The newly created
/// node on success is returned.
///
/// The increase amount is at the control of the PageList implementation,
/// but is guaranteed to always increase by at least one unit in the
/// given dimension. Practically, we'll always increase by much more
/// (we currently double every time) but callers shouldn't depend on that.
/// The only guarantee is some amount of growth.
///
/// Adjustment can be null if you want to recreate, reclone the page
/// with the same capacity. This is a special case used for rehashing since
/// the logic is otherwise the same. In this case, OutOfMemory is the
/// only possible error.
pub fn increaseCapacity(
    self: *PageList,
    node: *List.Node,
    adjustment: ?IncreaseCapacity,
) IncreaseCapacityError!*List.Node {
    defer self.assertIntegrity();
    const page: *Page = node.page();

    // Apply our adjustment
    var cap = page.capacity;
    if (adjustment) |v| switch (v) {
        inline else => |tag| {
            const field_name = @tagName(tag);
            const Int = @FieldType(Capacity, field_name);
            const old = @field(cap, field_name);

            const new: Int = new: {
                // A dimension can be zero for pages with exact
                // capacities (see compact). Doubling zero stays zero,
                // which would break our guarantee that we always
                // increase by at least one unit and turn caller retry
                // loops into infinite loops. Jump straight to the
                // standard default instead: it is what all standard
                // pages start with, so retrying callers are guaranteed
                // enough room for their pending allocation.
                if (old == 0) {
                    const default: Capacity = .{ .cols = 0, .rows = 0 };
                    break :new @field(default, field_name);
                }

                // We use checked math to prevent overflow. If there is
                // an overflow it means we're out of space in this
                // dimension, since pages can take up to their maxInt
                // capacity in any category.
                break :new std.math.mul(
                    Int,
                    old,
                    2,
                ) catch |err| overflow: {
                    comptime assert(@TypeOf(err) == error{Overflow});
                    // Our final doubling would overflow since maxInt is
                    // 2^N - 1 for an unsignged int of N bits. So, if we overflow
                    // and we haven't used all the bits, use all the bits.
                    if (old < std.math.maxInt(Int)) break :overflow std.math.maxInt(Int);
                    return error.OutOfSpace;
                };
            };
            @field(cap, field_name) = new;

            // If our capacity exceeds the maximum page size, treat it
            // as an OutOfSpace because things like page splitting will
            // help.
            const layout = Page.layout(cap);
            if (layout.total_size > size.max_page_size) {
                return error.OutOfSpace;
            }
        },
    };

    log.info("adjusting page capacity={}", .{cap});

    // Create our new page and clone the old page into it.
    const new_node = try self.createPage(.{ .cap = cap });
    errdefer self.destroyNode(new_node);
    const new_page: *Page = new_node.page();
    assert(new_page.capacity.rows >= page.capacity.rows);
    assert(new_page.capacity.cols >= page.capacity.cols);
    new_page.size.rows = page.size.rows;
    new_page.size.cols = page.size.cols;
    new_page.cloneFrom(
        page,
        0,
        page.size.rows,
    ) catch |err| {
        // cloneFrom only errors if there isn't capacity for the data
        // from the source page but we're only increasing capacity so
        // this should never be possible. If it happens, we should crash
        // because we're in no man's land and can't safely recover.
        log.err("increaseCapacity clone failed err={}", .{err});
        @panic("unexpected clone failure");
    };

    // Preserve page-level dirty flag (cloneFrom only copies row data)
    new_page.dirty = page.dirty;

    // Must not fail after this because the operations we do after this
    // can't be recovered.
    errdefer comptime unreachable;

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
    self.page_compression.markActivity();

    new_page.assertIntegrity();
    return new_node;
}

/// Options for createPage and createPageExt.
const CreatePage = struct {
    /// The capacity to allocate the page with.
    cap: Capacity,

    /// Force the page backing memory to be an exact-size heap
    /// allocation even if it would fit within a standard-size pool
    /// item. This is used when compacting pages to their minimum
    /// size, since a pool item always retains a full std_size buffer
    /// regardless of the page layout.
    exact_size: bool = false,
};

/// Create a new page node. This does not add it to the list and this
/// does not do any memory size accounting with max_size/page_size.
inline fn createPage(
    self: *PageList,
    opts: CreatePage,
) Allocator.Error!*List.Node {
    // log.debug("create page cap={}", .{opts.cap});
    return try createPageExt(
        &self.pool,
        opts,
        &self.page_serial,
        &self.page_size,
    );
}

inline fn createPageExt(
    pool: *MemoryPool,
    opts: CreatePage,
    serial: *u64,
    total_size: ?*usize,
) Allocator.Error!*List.Node {
    var page = try pool.nodes.create();
    errdefer pool.nodes.destroy(page);

    const layout = Page.layout(opts.cap);
    const pooled = !opts.exact_size and layout.total_size <= std_size;
    const page_alloc = pool.pages.arena.child_allocator;

    // It would be better to encode this into the Zig error handling
    // system but that is a big undertaking and we only have a few
    // centralized call sites so it is handled on its own currently.
    assert(layout.total_size <= size.max_page_size);

    // Our page buffer comes from our standard memory pool if it
    // is within our standard size since this is what the pool
    // dispenses. Otherwise, we use the heap allocator to allocate.
    const page_buf = if (pooled) buf: {
        const buf = try pool.pages.create();
        terminal_mem.recommit(buf);
        break :buf buf;
    } else try page_alloc.alignedAlloc(
        u8,
        .fromByteUnits(std.heap.page_size_min),
        layout.total_size,
    );
    errdefer if (pooled)
        pool.pages.destroy(page_buf)
    else
        page_alloc.free(page_buf);

    // In runtime safety modes, allocators fill with 0xAA. On freestanding
    // (WASM), the WasmAllocator reuses freed slots without zeroing.
    //
    // Otherwise, we rely on pool item buffers being zeroed: fresh items
    // come from the OS page allocator (zeroed pages) and destroyNodeExt
    // zeroes buffers before returning them to the pool. The one
    // exception is the first pointer-size bytes, which hold the pool's
    // free list node while a buffer is in the free list; initBuf below
    // always overwrites those since the page rows start at offset 0
    // (comptime-asserted in Page).
    if (comptime std.debug.runtime_safety or builtin.os.tag == .freestanding)
        @memset(page_buf, 0);

    page.* = .{
        .data = .{ .resident = .initBuf(.init(page_buf), layout) },
        .serial = serial.*,
        .owned = if (pooled) .pool else .heap,
    };
    page.page().size.rows = 0;
    serial.* += 1;

    if (total_size) |v| {
        // Accumulate page size now. We don't assert or check max size
        // because we may exceed it here temporarily as we are allocating
        // pages before destroy.
        v.* += page_buf.len;
    }

    return page;
}

/// Temporary output memory used while creating a compressed page.
///
/// Standard-sized output borrows a page-pool item so repeated compression can
/// reuse the same virtual mapping. Oversized pages use a temporary allocation
/// from the page allocator and release it immediately after compression.
const CompressionScratch = union(enum) {
    pooled: *align(std.heap.page_size_min) [std_size]u8,
    allocated: []align(std.heap.page_size_min) u8,

    fn init(
        pool: *MemoryPool,
        required: usize,
        raw_len: usize,
    ) Allocator.Error!CompressionScratch {
        assert(required <= raw_len);

        if (required <= std_size) {
            const memory = try pool.pages.create();
            terminal_mem.recommit(memory);
            return .{ .pooled = memory };
        }

        const page_alloc = pool.pages.arena.child_allocator;
        return .{ .allocated = try page_alloc.alignedAlloc(
            u8,
            .fromByteUnits(std.heap.page_size_min),
            raw_len,
        ) };
    }

    fn bytes(self: *CompressionScratch) []u8 {
        return switch (self.*) {
            .pooled => |memory| memory,
            .allocated => |memory| memory,
        };
    }

    fn deinit(self: *CompressionScratch, pool: *MemoryPool) void {
        switch (self.*) {
            .pooled => |memory| {
                _ = terminal_mem.decommit(.zero, memory, memory.len);
                pool.pages.destroy(memory);
            },
            .allocated => |memory| {
                const page_alloc = pool.pages.arena.child_allocator;
                page_alloc.free(memory);
            },
        }
    }
};

/// PageList-owned state for incremental compression.
///
/// The position is stored as a page serial rather than a node pointer so it
/// remains safe when PageList operations destroy, replace, or reuse nodes
/// between steps. It also records the first serial which was unallocated at
/// the prior step so new nodes before a valid marker restart safely. If the
/// exact serial no longer exists in the cold prefix, the next step also
/// restarts at the first page.
///
/// A completed pass is followed by another pass from the oldest cold page.
/// Compression becomes idle only when that verification pass compresses no
/// pages. This converges after pages are restored between incremental steps
/// without requiring consumers to maintain a separate attempt cursor.
const IncrementalCompressionState = struct {
    flags: packed struct {
        /// Set after any page is compressed during the current traversal.
        /// We always run incremental compression until we get a fully
        /// no-compression pass (the verification pass). This lets us
        /// recompress decompressed pages due to search, scrolling, etc.
        did_compress: bool = false,

        /// Set after a traversal first reaches the active boundary. When this
        /// verification traversal reaches the boundary, `did_compress`
        /// determines whether to restart once more or finish the pass.
        verifying: bool = false,
    } = .{},

    /// Changes whenever PageList activity may affect compression work.
    /// Callers use this value (via Terminal.compressionActivity) to
    /// determine whether to recompress.
    ///
    /// The directionality of this doesn't matter. We overflow and
    /// wrap when maxxed. The comparison of this value to your saved
    /// value is all that matters. There is a possible edge case where you
    /// don't compress, a full wraparound happens, and you get the same value,
    /// but its so unlikely.
    ///
    /// This is 48-bits so that 16-bits can be reserved for Terminal to
    /// add extra state.
    activity_serial: u48 = 0,

    /// Serial of the last page inspected by the traversal. This is
    /// intentionally an implementation detail and is reset by PageList
    /// operations which restart traversal progress.
    last_serial: ?u64 = null,

    /// First node serial which had not been allocated at the prior step. A
    /// node at or above this value before the saved marker requires a restart.
    next_serial: u64 = 0,

    /// Record activity without disturbing valid traversal progress.
    fn markActivity(self: *IncrementalCompressionState) void {
        self.activity_serial +%= 1;
    }

    /// Discard traversal progress without changing the activity token.
    fn reset(self: *IncrementalCompressionState) void {
        const activity_serial: u48 = self.activity_serial;
        self.* = .{ .activity_serial = activity_serial };
    }
};

/// Result of one incremental compression step.
pub const IncrementalCompressionResult = enum {
    /// Strict retained-mapping reclamation is unavailable on this target.
    unsupported,

    /// More cold pages or a verification pass remain after this invocation's
    /// candidate-bounded work.
    pending,

    /// A complete verification pass compressed zero pages.
    complete,
};

/// Iterate complete historical pages which do not intersect the viewport.
///
/// All boundaries come from PageList pins and Page metadata. Advancing this
/// iterator never restores a compressed page or reads its backing memory.
const CompressionIterator = struct {
    current: *List.Node,
    active: *List.Node,
    viewport_first: *List.Node,
    viewport_last: *List.Node,

    fn init(self: *const PageList) CompressionIterator {
        return .{
            .current = self.pages.first.?,
            .active = self.getTopLeft(.active).node,
            .viewport_first = self.getTopLeft(.viewport).node,
            .viewport_last = self.getBottomRight(.viewport).?.node,
        };
    }

    fn next(self: *CompressionIterator) ?*List.Node {
        while (self.current != self.active) {
            // The viewport is a contiguous node range. Once traversal reaches
            // its first node, advance through the complete visible range and
            // resume at the next offscreen page.
            if (self.current == self.viewport_first) {
                while (self.current != self.active and
                    self.current != self.viewport_last)
                {
                    self.current = self.current.next.?;
                }

                if (self.current == self.active) return null;
                self.current = self.current.next.?;
                continue;
            }

            const node = self.current;
            self.current = node.next.?;
            return node;
        }

        return null;
    }

    fn done(self: *const CompressionIterator) bool {
        return self.current == self.active;
    }
};

/// Bound candidate inspection independently from compression work. Skipping
/// an already-compressed page is cheap, but still counts toward this limit.
const incremental_compression_max_inspected = 8;

/// Failure injection for the final reclamation step. The operating-system
/// failure path cannot otherwise be exercised by tests because terminal_mem
/// deliberately simulates successful decommit in test builds.
const compressPage_tw = tripwire.module(
    enum { decommit },
    error{DecommitFailed},
);

/// Compress eligible nodes, saving a significant amount of memory.
///
/// Eligible nodes are complete pages before the active boundary which do not
/// intersect the viewport. The boundary page is excluded because it may
/// contain both scrollback and active rows; visible pages remain resident for
/// immediate redraw and scrolling.
///
/// Compression requires a system that supports reclaiming physical memory for
/// virtual allocations while retaining their address ranges.
///
/// Compression is SLOW (relatively), so incremental compression during idle
/// periods is recommended. Incremental mode performs one bounded step and its
/// result specifies whether to continue immediately. Drain mode performs
/// incremental steps until the pass and its verification pass finish. Full
/// mode visits every currently eligible node once without using incremental
/// state.
///
/// PageList tracks mutations which require a later incremental pass in its
/// compression state. On supported targets, full compression returns
/// `complete`, indicating that it has no continuation to schedule rather than
/// that every page was compressed.
pub fn compress(
    self: *PageList,
    mode: enum { incremental, drain, full },
) IncrementalCompressionResult {
    return switch (mode) {
        .incremental => self.compressIncremental(),
        .drain => while (true) switch (self.compressIncremental()) {
            .pending => continue,
            .complete => break .complete,
            .unsupported => break .unsupported,
        },
        .full => full: {
            // Match incremental mode's unsupported result. Full compression
            // has no useful work to perform without strict reclamation.
            if (!terminal_mem.canReclaim(.strict)) {
                self.page_compression.reset();
                break :full .unsupported;
            }

            self.compressFull();

            // Full compression has no continuation. Discard any partial
            // incremental cursor so later activity starts at the oldest page.
            self.page_compression.reset();

            break :full .complete;
        },
    };
}

/// Perform one candidate-bounded incremental cold-history compression step.
fn compressIncremental(self: *PageList) IncrementalCompressionResult {
    const state = &self.page_compression;

    // If we can't reclaim virtual memory, compression is unsupported.
    if (!terminal_mem.canReclaim(.strict)) {
        state.reset();
        return .unsupported;
    }

    // Find the node following the exact continuation marker within the cold
    // prefix. A missing marker means the list changed between steps, so begin
    // again at the current first page. This lookup does not touch page memory.
    var it: CompressionIterator = .init(self);
    if (state.last_serial) |last_serial| continuation: {
        while (it.next()) |node| {
            // A newly allocated or replacement node appeared before the
            // marker. Restart immediately so that node cannot be skipped.
            if (node.serial >= state.next_serial) break;

            // Not a match? Keep looking
            if (node.serial != last_serial) continue;

            // Match! The iterator already points to the next offscreen node.
            break :continuation;
        }

        // Not found or otherwise invalid. Reset
        state.last_serial = null;
        it = .init(self);
    }

    // Keep track of our next_serial
    state.next_serial = self.page_serial;

    // We cap the number of pages we look at to do our best to
    // time-bound the incremental compression.
    var inspected_pages: usize = 0;
    while (inspected_pages < incremental_compression_max_inspected) {
        const node = it.next() orelse break;

        state.last_serial = node.serial;
        inspected_pages += 1;

        // If this page is already compressed, ignore it.
        if (node.isCompressed()) continue;

        // Compression is substantially more expensive even if it fails.
        // So we just try it.
        if (self.compressPage(node)) state.flags.did_compress = true;
        break;
    }

    // If we didn't reach our active node, then we still have work to do.
    if (!it.done()) return .pending;

    // We reached our active node. So we're done, except that we always
    // do one pass after the first success so we can recompress nodes that
    // were possibly decompressed (e.g. by search, inspector, whatever).
    if (!state.flags.verifying or state.flags.did_compress) {
        const activity_serial: u48 = state.activity_serial;
        state.* = .{
            .flags = .{ .verifying = true },
            .activity_serial = activity_serial,
        };
        return .pending;
    }

    // Leave the state fresh while idle so later activity naturally begins at
    // the oldest cold page, including pages restored after this pass.
    state.reset();
    return .complete;
}

/// Compress every fully historical resident page which is currently cold.
fn compressFull(self: *PageList) void {
    var it: CompressionIterator = .init(self);
    while (it.next()) |node| {

        // Don't restore an already-compressed page just to recompress it.
        if (node.isCompressed()) continue;

        // Failure leaves this node resident and unchanged.
        _ = self.compressPage(node);
    }
}

/// Attempt to compress one resident page while retaining its raw mapping.
///
/// Compression is opportunistic: every failure leaves the page resident and
/// usable. Candidate selection and retry policy belong to `compress`; this
/// primitive only performs one state transition.
fn compressPage(self: *PageList, node: *List.Node) bool {
    // Recompression requires first restoring the raw page and is a policy
    // decision, so this primitive only accepts resident nodes.
    if (node.isCompressed()) return false;

    const page = node.page();

    // The scratch size is capped just below the representation's break-even
    // point. Codec limits and pages too small to cover the compressed-state
    // overhead simply make this page ineligible for compression.
    const required = compression.Page.requiredScratch(page.memory.len) catch |err|
        switch (err) {
            error.InputTooLarge,
            error.OutputTooSmall,
            => return false,
        };
    if (required == 0) return false;

    // Build the compressed candidate without changing the node. This scope is
    // intentional: its defer releases the borrowed or temporary scratch before
    // we attempt to discard the source mapping below. Only the candidate's
    // exact-sized encoded allocation survives the scope.
    const candidate = candidate: {
        var scratch = CompressionScratch.init(
            &self.pool,
            required,
            page.memory.len,
        ) catch |err| switch (err) {
            error.OutOfMemory => return false,
        };
        defer scratch.deinit(&self.pool);

        var table: compression.lz4.HashTable = undefined;
        break :candidate compression.Page.init(
            self.pool.alloc,
            page,
            scratch.bytes()[0..required],
            &table,
        ) catch |err| switch (err) {
            error.OutOfMemory,
            error.InputTooLarge,
            error.OutputTooSmall,
            => return false,
        };
    };

    // Null means compression crossed the break-even point. The node and its
    // resident mapping are still untouched in this case.
    var compressed = candidate orelse return false;

    // Strict decommit is the final fallible step. It either discards the whole
    // raw mapping or leaves it untouched, so failure can safely free the
    // candidate and preserve the resident node exactly as it was.
    const decommit_allowed: bool = allowed: {
        compressPage_tw.check(.decommit) catch |err| switch (err) {
            error.DecommitFailed => break :allowed false,
        };
        break :allowed true;
    };
    if (!decommit_allowed or !terminal_mem.decommit(
        .strict,
        compressed.page.memory,
        compressed.page.memory.len,
    )) {
        compressed.deinit();
        return false;
    }

    // Publish the new state only after both the encoded allocation and the
    // retained-mapping decommit have succeeded.
    node.data = .{ .compressed = compressed };
    return true;
}

/// Destroy the memory of the given node in the PageList linked list
/// and return it to the pool. The node is assumed to already be removed
/// from the linked list.
///
/// IMPORTANT: This function does NOT update `total_rows`. The caller is
/// responsible for accounting for the removed rows. This function only
/// updates `page_size` (byte accounting), not row accounting.
fn destroyNode(self: *PageList, node: *List.Node) void {
    destroyNodeExt(&self.pool, node, &self.page_size);
}

fn destroyNodeExt(
    pool: *MemoryPool,
    node: *List.Node,
    total_size: ?*usize,
) void {
    const page = node.restore(.discard);

    // Update our accounting for page size. This must mirror what was
    // added at creation time: a pool-owned page always accounts for a
    // full pool item even if its layout is smaller, while a heap-owned
    // page accounts for its exact memory length.
    if (total_size) |v| v.* -= switch (node.owned) {
        .pool => PagePool.item_size,
        .heap => page.memory.len,
    };

    switch (node.owned) {
        .pool => {
            assert(page.memory.len <= std_size);

            // Reset the memory to zero (and decommit it, where
            // supported) so it can be reused.
            const item: *align(std.heap.page_size_min) [std_size]u8 =
                @ptrCast(@alignCast(page.memory.ptr));
            _ = terminal_mem.decommit(.zero, item, page.memory.len);
            pool.pages.destroy(item);
        },

        .heap => {
            const page_alloc = pool.pages.arena.child_allocator;
            page_alloc.free(page.memory);
        },
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
    defer self.assertIntegrity();
    const pn = self.pin(pt).?;

    var node = pn.node;
    var page = node.page();
    var rows = page.rows.ptr(page.memory.ptr);

    // Erasing history may restore compressed pages. Mark unconditionally
    // because incrementing the activity token is cheaper than locating the
    // active boundary.
    self.page_compression.markActivity();

    // In order to move the following rows up we rotate the rows array by 1.
    // The rotate operation turns e.g. [ 0 1 2 3 ] in to [ 1 2 3 0 ], which
    // works perfectly to move all of our elements where they belong.
    // Rotating rows changes which logical row cached coordinates identify.
    self.invalidateNodeLayout(node);
    fastmem.rotateOnce(Row, rows[pn.y..node.rows()]);

    // We adjust the tracked pins in this page, moving up any that were below
    // the removed row.
    {
        const pin_keys = self.tracked_pins.keys();
        for (pin_keys) |p| {
            if (p.node == node and p.y > pn.y) p.y -= 1;
        }
    }

    // If we have a pinned viewport, we need to adjust for active area.
    self.fixupViewport(1);

    // Mark the whole page as dirty.
    //
    // Technically we only need to mark rows from the erased row to the end
    // of the page as dirty, but that's slower and this is a hot function.
    page.dirty = true;

    // We iterate through all of the following pages in order to move their
    // rows up by 1 as well.
    while (node.next) |next| {
        const next_page = next.page();
        const next_rows = next_page.rows.ptr(next_page.memory.ptr);

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
        try page.cloneRowFrom(
            next_page,
            &rows[node.rows() - 1],
            &next_rows[0],
        );

        node = next;
        page = next_page;
        rows = next_rows;

        // Rotating this page moves every cached row coordinate up by one.
        self.invalidateNodeLayout(node);
        fastmem.rotateOnce(Row, rows[0..node.rows()]);

        // Mark the whole page as dirty.
        page.dirty = true;

        // Our tracked pins for this page need to be updated.
        // If the pin is in row 0 that means the corresponding row has
        // been moved to the previous page. Otherwise, move it up by 1.
        const pin_keys = self.tracked_pins.keys();
        for (pin_keys) |p| {
            if (p.node != node) continue;
            if (p.y == 0) {
                p.node = node.prev.?;
                p.y = p.node.rows() - 1;
                continue;
            }
            p.y -= 1;
        }
    }

    // Clear the final row which was rotated from the top of the page.
    page.clearCells(&rows[node.rows() - 1], 0, node.cols());
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
    defer self.assertIntegrity();

    // This function has a lot of repeated code in it because it is a hot path.
    //
    // To get a better idea of what's happening, read eraseRow first for more
    // in-depth explanatory comments. To avoid repetition, the only comments for
    // this function are for where it differs from eraseRow.

    const pn = self.pin(pt).?;

    var node: *List.Node = pn.node;
    var page = node.page();
    var rows = page.rows.ptr(page.memory.ptr);

    // Erasing history may restore compressed pages. Mark unconditionally
    // because incrementing the activity token is cheaper than locating the
    // active boundary.
    self.page_compression.markActivity();

    // If the row limit is less than the remaining rows before the end of the
    // page, then we clear the row, rotate it to the end of the boundary limit
    // and update our pins.
    if (node.rows() - pn.y > limit) {
        // Rotating this bounded region changes its cached row coordinates.
        self.invalidateNodeLayout(node);
        page.clearCells(&rows[pn.y], 0, node.cols());
        fastmem.rotateOnce(Row, rows[pn.y..][0 .. limit + 1]);

        // Mark the whole page as dirty.
        //
        // Technically we only need to mark from the erased row to the
        // limit but this is a hot function, so we want to minimize work.
        page.dirty = true;

        // If our viewport is a pin and our pin is within the erased
        // region we need to maybe shift our cache up. We do this here instead
        // of in the pin loop below because its unlikely to be true and we
        // don't want to run the conditional N times.
        if (self.viewport == .pin) viewport: {
            if (self.viewport_pin_row_offset) |*v| {
                const p = self.viewport_pin;
                if (p.node != node or
                    p.y < pn.y or
                    p.y > pn.y + limit or
                    p.y == 0) break :viewport;
                v.* -= 1;
            }
        }

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

    // Rotating this suffix changes which logical row its coordinates identify.
    self.invalidateNodeLayout(node);
    fastmem.rotateOnce(Row, rows[pn.y..node.rows()]);

    // Mark the whole page as dirty.
    //
    // Technically we only need to mark rows from the erased row to the end
    // of the page as dirty, but that's slower and this is a hot function.
    page.dirty = true;

    // We need to keep track of how many rows we've shifted so that we can
    // determine at what point we need to do a partial shift on subsequent
    // pages.
    var shifted: usize = node.rows() - pn.y;

    // Update tracked pins.
    {
        // See the other places we do something similar in this function
        // for a detailed explanation.
        if (self.viewport == .pin) viewport: {
            if (self.viewport_pin_row_offset) |*v| {
                const p = self.viewport_pin;
                if (p.node != node or
                    p.y < pn.y or
                    p.y == 0) break :viewport;
                v.* -= 1;
            }
        }

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
        const next_page = next.page();
        const next_rows = next_page.rows.ptr(next_page.memory.ptr);

        try page.cloneRowFrom(
            next_page,
            &rows[node.rows() - 1],
            &next_rows[0],
        );

        node = next;
        page = next_page;
        rows = next_rows;

        // We check to see if this page contains enough rows to satisfy the
        // specified limit, accounting for rows we've already shifted in prior
        // pages.
        //
        // The logic here is very similar to the one before the loop.
        const shifted_limit = limit - shifted;
        if (node.rows() > shifted_limit) {
            // Rotating this bounded prefix changes its cached row coordinates.
            self.invalidateNodeLayout(node);
            page.clearCells(&rows[0], 0, node.cols());
            fastmem.rotateOnce(Row, rows[0 .. shifted_limit + 1]);

            // Mark the whole page as dirty.
            //
            // Technically we only need to mark from the erased row to the
            // limit but this is a hot function, so we want to minimize work.
            page.dirty = true;

            // See the other places we do something similar in this function
            // for a detailed explanation.
            if (self.viewport == .pin) viewport: {
                if (self.viewport_pin_row_offset) |*v| {
                    const p = self.viewport_pin;
                    if (p.node != node or
                        p.y > shifted_limit) break :viewport;
                    v.* -= 1;
                }
            }

            // Update pins in the shifted region.
            const pin_keys = self.tracked_pins.keys();
            for (pin_keys) |p| {
                if (p.node != node or p.y > shifted_limit) continue;
                if (p.y == 0) {
                    p.node = node.prev.?;
                    p.y = p.node.rows() - 1;
                    continue;
                }
                p.y -= 1;
            }

            return;
        }

        // Rotating the whole page moves every cached row coordinate up by one.
        self.invalidateNodeLayout(node);
        fastmem.rotateOnce(Row, rows[0..node.rows()]);

        // Mark the whole page as dirty.
        page.dirty = true;

        // Account for the rows shifted in this node.
        shifted += node.rows();

        // See the other places we do something similar in this function
        // for a detailed explanation.
        if (self.viewport == .pin) viewport: {
            if (self.viewport_pin_row_offset) |*v| {
                const p = self.viewport_pin;
                if (p.node != node) break :viewport;
                v.* -= 1;
            }
        }

        // Update tracked pins.
        const pin_keys = self.tracked_pins.keys();
        for (pin_keys) |p| {
            if (p.node != node) continue;
            if (p.y == 0) {
                p.node = node.prev.?;
                p.y = p.node.rows() - 1;
                continue;
            }
            p.y -= 1;
        }
    }

    // We reached the end of the page list before the limit, so we clear
    // the final row since it was rotated down from the top of this page.
    page.clearCells(&rows[node.rows() - 1], 0, node.cols());
}

/// Erase all history rows, optionally up to a bottom-left bound.
/// This always starts from the beginning of the history area.
pub fn eraseHistory(
    self: *PageList,
    bl_pt: ?point.Point,
) void {
    self.eraseRows(.{ .history = .{} }, bl_pt);
}

/// Erase active area rows, from the top of the active area to the
/// given row (inclusive).
pub fn eraseActive(
    self: *PageList,
    y: size.CellCountInt,
) void {
    assert(y < self.rows);
    self.eraseRows(.{ .active = .{} }, .{ .active = .{ .y = y } });
}

/// Erase rows from tl_pt to bl_pt (inclusive), physically removing
/// them rather than just clearing their contents. If a point falls
/// in the middle of a page, remaining rows in that page are shifted
/// and the page becomes underutilized (size < capacity).
///
/// Callers must ensure that the erased range only removes pages from
/// the front or back of the linked list, never the middle. The pin and row
/// accounting in this operation is only defined for those boundary ranges.
/// Use the public eraseHistory/eraseActive wrappers which enforce this.
fn eraseRows(
    self: *PageList,
    tl_pt: point.Point,
    bl_pt: ?point.Point,
) void {
    defer self.assertIntegrity();
    self.page_compression.markActivity();

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
                // Reinitializing the sole page invalidates every coordinate in it.
                self.invalidateNodeLayout(chunk.node);
                const page = chunk.node.page();
                erased += page.size.rows;
                page.reinit();
                page.size.rows = 0;
                break;
            }

            erased += chunk.node.rows();
            self.erasePage(chunk.node);
            continue;
        }

        // Moving the retained suffix changes every captured row coordinate.
        self.invalidateNodeLayout(chunk.node);

        // We are modifying our chunk so make sure it is in a good state.
        const page = chunk.node.page();
        defer page.assertIntegrity();

        // The chunk is not a full page so we need to move the rows.
        // This is a cheap operation because we're just moving cell offsets,
        // not the actual cell contents.
        assert(chunk.start == 0);
        const rows = page.rows.ptr(page.memory);
        const scroll_amount = chunk.node.rows() - chunk.end;
        for (0..scroll_amount) |i| {
            const src: *Row = &rows[i + chunk.end];
            const dst: *Row = &rows[i];
            const old_dst = dst.*;
            dst.* = src.*;
            src.* = old_dst;

            // Mark the moved row as dirty.
            dst.dirty = true;
        }

        // Clear our remaining cells that we didn't shift or swapped
        // in case we grow back into them.
        for (scroll_amount..chunk.node.rows()) |i| {
            const row: *Row = &rows[i];
            page.clearCells(
                row,
                0,
                chunk.node.cols(),
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
        page.size.rows = @intCast(scroll_amount);
        erased += chunk.end;
    }

    // Update our total row count
    self.total_rows -= erased;

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
    self.fixupViewport(erased);
}

/// Erase a single page, freeing all its resources. The page must be
/// at the front or back of the linked list (not the middle) and must
/// NOT be the final page in the entire list (i.e. must not make the
/// list empty).
///
/// IMPORTANT: This function does NOT update `total_rows`. The caller is
/// responsible for accounting for the removed rows before or after calling
/// this function.
fn erasePage(self: *PageList, node: *List.Node) void {
    // Must not be the final page.
    assert(node.next != null or node.prev != null);

    // We only support erasing from the front or back, never the middle. The
    // public erase operations maintain this contract by construction.
    assert(node.prev == null or node.next == null);

    // Update any tracked pins to move to the previous or next page.
    const pin_keys = self.tracked_pins.keys();
    for (pin_keys) |p| {
        if (p.node != node) continue;
        p.node = node.prev orelse node.next orelse unreachable;
        p.y = 0;
        p.x = 0;

        // This doesn't get marked garbage because the tracked pin
        // movement is sensical.
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
    // Incomplete reflow can leave a page narrower than the desired width.
    // Never manufacture an out-of-bounds pin for that page.
    if (x >= p.node.cols()) return null;
    p.x = x;
    return p;
}

/// Convert the given pin to a tracked pin. A tracked pin will always be
/// automatically updated as the pagelist is modified. If the point the
/// pin points to is removed completely, the tracked pin will be updated
/// to the top-left of the screen.
pub fn trackPin(self: *PageList, p: Pin) Allocator.Error!*Pin {
    if (build_options.slow_runtime_safety) assert(self.pinIsValid(p));

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

/// Returns the tracked pins for this pagelist. The slice is owned by the
/// pagelist and is only valid until the pagelist is modified.
pub fn trackedPins(self: *const PageList) []const *Pin {
    return self.tracked_pins.keys();
}

/// Checks if a pin is valid for this pagelist. This is a very slow and
/// expensive operation since we traverse the entire linked list in the
/// worst case. Only for runtime safety/debug.
pub fn pinIsValid(self: *const PageList, p: Pin) bool {
    // This is very slow so we want to ensure we only ever
    // call this during slow runtime safety builds.
    comptime assert(build_options.slow_runtime_safety);

    var it = self.pages.first;
    while (it) |node| : (it = node.next) {
        if (node != p.node) continue;
        return p.y < node.rows() and
            p.x < node.cols();
    }

    return false;
}

/// Returns whether a node pointer and serial still identify the same page in
/// this list. The node pointer is only compared and is safe even if the node
/// has been destroyed or reused since the serial was captured.
pub fn nodeIsValid(
    self: *const PageList,
    target: *List.Node,
    serial: u64,
) bool {
    // Reset invalidates the whole prior epoch, so reject those generations
    // without scanning the live list.
    if (serial < self.page_serial_epoch) return false;

    var it = self.pages.first;
    while (it) |node| : (it = node.next) {
        if (node == target) return node.serial == serial;
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

/// Returns true if the pin is at the top of the scrollback area.
fn pinIsTop(self: *const PageList, p: Pin) bool {
    return p.y == 0 and p.node == self.pages.first.?;
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
        coord.y = std.math.add(
            u32,
            coord.y,
            tl.node.rows() - tl.y,
        ) catch return null;
        var node_ = tl.node.next;
        while (node_) |node| : (node_ = node.next) {
            if (node == p.node) {
                coord.y = std.math.add(u32, coord.y, p.y) catch return null;
                break;
            }

            coord.y = std.math.add(
                u32,
                coord.y,
                node.rows(),
            ) catch return null;
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
    const rac = pt_pin.node.page().getRowAndCell(pt_pin.x, pt_pin.y);
    return .{
        .node = pt_pin.node,
        .row = rac.row,
        .cell = rac.cell,
        .row_idx = pt_pin.y,
        .col_idx = pt_pin.x,
    };
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
pub fn diagram(
    self: *const PageList,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    const active_pin = self.getTopLeft(.active);

    var active = false;
    var active_index: usize = 0;

    var page_index: usize = 0;
    var cols: usize = 0;

    var it = self.pageIterator(.right_down, .{ .screen = .{} }, null);
    while (it.next()) |chunk| : (page_index += 1) {
        cols = chunk.node.cols();

        // Whether we've just skipped some number of rows and drawn
        // an ellipsis row (this is reset when a row is not skipped).
        var skipped = false;

        for (0..chunk.node.rows()) |y| {
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
                const row = chunk.node.page().getRow(y);
                const cells = chunk.node.page().getCells(row)[0..cols];

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
                            const grapheme = chunk.node.page().lookupGrapheme(cell).?;
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

/// Returns the boundaries of the given semantic content type for
/// the prompt at the given pin. The pin row MUST be the first row
/// of a prompt, otherwise the results may be nonsense.
///
/// To get prompt pins, use promptIterator. Warning that if there are
/// no semantic prompts ever present, promptIterator will iterate the
/// entire PageList. Downstream callers should keep track of a flag if
/// they've ever seen semantic prompt operations to prevent this performance
/// case.
///
/// Note that some semantic content type such as "input" is usually
/// nested within prompt boundaries, so the returned boundaries may include
/// prompt text.
pub fn highlightSemanticContent(
    self: *const PageList,
    at: Pin,
    content: pagepkg.Cell.SemanticContent,
) ?highlight.Untracked {
    // Performance note: we can do this more efficiently in a single
    // forward-pass. Semantic content operations aren't usually fast path
    // but if someone wants to optimize them someday that's great.

    const end: Pin = end: {
        // Safety assertion, our starting point should be a prompt row.
        // so the first returned prompt should be ourselves.
        var it = at.promptIterator(.right_down, null);
        assert(it.next().?.y == at.y);

        // Our end is the end of the line just before the next prompt
        // line, which should exist since we verified we have at least
        // two prompts here.
        if (it.next()) |next| next: {
            var prev = next.up(1) orelse break :next;
            prev.x = prev.node.cols() - 1;
            break :end prev;
        }

        // Didn't find any further prompt so the end of our zone is
        // the end of the screen.
        break :end self.getBottomRight(.screen).?;
    };

    switch (content) {
        // For the prompt, we select all the way up to command output.
        // We include all the input lines, too.
        .prompt => {
            var result: highlight.Untracked = .{
                .start = at.left(at.x),
                .end = at,
            };

            var it = at.cellIterator(.right_down, end);
            while (it.next()) |p| {
                switch (p.rowAndCell().cell.semantic_content) {
                    .prompt, .input => result.end = p,
                    .output => break,
                }
            }

            return result;
        },

        // For input, we include the start of the input to the end of
        // the input, which may include all the prompts in the middle, too.
        .input => {
            var result: highlight.Untracked = .{
                .start = undefined,
                .end = undefined,
            };

            // Find the start
            var it = at.cellIterator(.right_down, end);
            while (it.next()) |p| {
                switch (p.rowAndCell().cell.semantic_content) {
                    .prompt => {},
                    .input => {
                        result.start = p;
                        result.end = p;
                        break;
                    },
                    .output => return null,
                }
            } else {
                // No input found
                return null;
            }

            // Find the end
            while (it.next()) |p| {
                switch (p.rowAndCell().cell.semantic_content) {
                    // Prompts can be nested in our input for continuation
                    .prompt => {},

                    // Output means we're done
                    .output => break,

                    .input => result.end = p,
                }
            }

            return result;
        },

        .output => {
            var result: highlight.Untracked = .{
                .start = undefined,
                .end = undefined,
            };

            // Find the start
            var it = at.cellIterator(.right_down, end);
            while (it.next()) |p| {
                const cell = p.rowAndCell().cell;
                switch (cell.semantic_content) {
                    .prompt, .input => {},
                    .output => {
                        // Skip empty cells - they default to .output but aren't real output
                        if (!cell.hasText()) continue;
                        result.start = p;
                        result.end = p;
                        break;
                    },
                }
            } else {
                // No output found
                return null;
            }

            // Find the end
            while (it.next()) |p| {
                const cell = p.rowAndCell().cell;
                switch (cell.semantic_content) {
                    .prompt, .input => break,
                    .output => {
                        // Only extend to cells with actual text
                        if (cell.hasText()) result.end = p;
                    },
                }
            }

            return result;
        },
    }
}

/// Direction that iterators can move.
pub const Direction = enum { left_up, right_down };

pub const PromptIterator = struct {
    /// The pin that we are currently at. Also the starting pin when
    /// initializing.
    current: ?Pin,

    /// The pin to end at or null if we end when we can't traverse
    /// anymore.
    limit: ?Pin,

    /// The direction to do the traversal.
    direction: Direction,

    pub const empty: PromptIterator = .{
        .current = null,
        .limit = null,
        .direction = .left_up,
    };

    /// Return the next pin that represents the first row in a prompt.
    /// From here, you can find the prompt input, command output, etc.
    pub fn next(self: *PromptIterator) ?Pin {
        switch (self.direction) {
            .left_up => return self.nextLeftUp(),
            .right_down => return self.nextRightDown(),
        }
    }

    pub fn nextRightDown(self: *PromptIterator) ?Pin {
        // Start at our current pin. If we have no current it means
        // we reached the end and we're done.
        const start: Pin = self.current orelse return null;

        // We need to traverse downwards and look for prompts.
        var current: ?Pin = start;
        while (current) |p| : (current = p.down(1)) {
            // Check our limit.
            const at_limit = if (self.limit) |limit| limit.eql(p) else false;

            const rac = p.rowAndCell();
            switch (rac.row.semantic_prompt) {
                // This row isn't a prompt. Keep looking.
                .none => if (at_limit) break,

                // This is a prompt line or continuation line. In either
                // case we consider the first line the prompt, and then
                // skip over any remaining prompt lines. This handles the
                // case where scrollback pruned the prompt.
                .prompt, .prompt_continuation => {
                    // If we're at our limit just return this prompt.
                    if (at_limit) {
                        self.current = null;
                        return p.left(p.x);
                    }

                    // Skip over any continuation lines that follow this prompt,
                    // up to our limit.
                    var end_pin = p;
                    while (end_pin.down(1)) |next_pin| : (end_pin = next_pin) {
                        switch (next_pin.rowAndCell().row.semantic_prompt) {
                            .prompt_continuation => if (self.limit) |limit| {
                                if (limit.eql(next_pin)) break;
                            },

                            .prompt, .none => {
                                self.current = next_pin;
                                return p.left(p.x);
                            },
                        }
                    }

                    self.current = null;
                    return p.left(p.x);
                },
            }
        }

        self.current = null;
        return null;
    }

    pub fn nextLeftUp(self: *PromptIterator) ?Pin {
        // Start at our current pin. If we have no current it means
        // we reached the end and we're done.
        const start: Pin = self.current orelse return null;

        // We need to traverse upwards and look for prompts.
        var current: ?Pin = start;
        while (current) |p| : (current = p.up(1)) {
            // Check our limit.
            const at_limit = if (self.limit) |limit| limit.eql(p) else false;

            const rac = p.rowAndCell();
            switch (rac.row.semantic_prompt) {
                // This row isn't a prompt. Keep looking.
                .none => if (at_limit) break,

                // This is a prompt line.
                .prompt => {
                    self.current = if (at_limit) null else p.up(1);
                    return p.left(p.x);
                },

                // If this is a prompt continuation, then we continue
                // looking for the start of the prompt OR a non-prompt
                // line, whichever is first. The non-prompt line is to handle
                // poorly behaved programs or scrollback that's been cut-off.
                .prompt_continuation => {
                    // If we're at our limit just return this continuation as prompt.
                    if (at_limit) {
                        self.current = null;
                        return p.left(p.x);
                    }

                    var end_pin = p;
                    while (end_pin.up(1)) |prior| : (end_pin = prior) {
                        if (self.limit) |limit| {
                            if (limit.eql(prior)) break;
                        }

                        switch (prior.rowAndCell().row.semantic_prompt) {
                            // No prompt. That means our last pin is good!
                            .none => {
                                self.current = prior;
                                return end_pin.left(end_pin.x);
                            },

                            // Prompt continuation, keep looking.
                            .prompt_continuation => {},

                            // Prompt! Found it!
                            .prompt => {
                                self.current = prior.up(1);
                                return prior.left(prior.x);
                            },
                        }
                    }

                    // No prior rows, trimmed scrollback probably.
                    self.current = null;
                    return p.left(p.x);
                },
            }
        }

        self.current = null;
        return null;
    }
};

pub fn promptIterator(
    self: *const PageList,
    direction: Direction,
    tl_pt: point.Point,
    bl_pt: ?point.Point,
) PromptIterator {
    const tl_pin = self.pin(tl_pt).?;
    const bl_pin = if (bl_pt) |pt|
        self.pin(pt).?
    else
        self.getBottomRight(tl_pt) orelse return .empty;

    return switch (direction) {
        .right_down => tl_pin.promptIterator(.right_down, bl_pin),
        .left_up => bl_pin.promptIterator(.left_up, tl_pin),
    };
}

pub const CellIterator = struct {
    row_it: RowIterator,
    cell: ?Pin = null,

    pub fn next(self: *CellIterator) ?Pin {
        const cell = self.cell orelse return null;

        switch (self.row_it.page_it.direction) {
            .right_down => {
                if (cell.x + 1 < cell.node.cols()) {
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
                        copy.x = next_cell.node.cols() - 1;
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
                    .end = row.node.rows(),
                };
            },

            .count => |*limit| count: {
                assert(limit.* > 0); // should be handled already
                const available: usize = row.node.rows() - row.y;
                const len = @min(available, limit.*);
                limit.* -= len;
                self.row = if (limit.* > 0) row.down(len) else null;

                break :count .{
                    .node = row.node,
                    .start = row.y,
                    .end = @intCast(@as(usize, row.y) + len),
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
                        .end = row.node.rows(),
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
                        .y = next_page.rows() - 1,
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
                const available: usize = @as(usize, row.y) + 1;
                const len = @min(available, limit.*);
                limit.* -= len;
                self.row = if (limit.* > 0) row.up(len) else null;

                break :count .{
                    .node = row.node,
                    .start = @intCast(available - len),
                    .end = @intCast(available),
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
                            .y = next_page.rows() - 1,
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

        /// Start y index (inclusive) of this chunk in the page.
        start: size.CellCountInt,

        /// End y index (exclusive) of this chunk in the page.
        end: size.CellCountInt,

        pub fn rows(self: Chunk) []Row {
            const page = self.node.page();
            const rows_ptr = page.rows.ptr(page.memory);
            return rows_ptr[self.start..self.end];
        }

        /// Returns true if this chunk represents every row in the page.
        pub fn fullPage(self: Chunk) bool {
            return self.start == 0 and self.end == self.node.rows();
        }

        /// Returns true if this chunk overlaps with the given other chunk
        /// in any way.
        pub fn overlaps(self: Chunk, other: Chunk) bool {
            if (self.node != other.node) return false;
            if (self.end <= other.start) return false;
            if (self.start >= other.end) return false;
            return true;
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

    if (build_options.slow_runtime_safety) {
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
                if (rem <= node.rows()) break :active .{
                    .node = node,
                    .y = node.rows() - rem,
                };

                rem -= node.rows();
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
                .y = node.rows() - 1,
                .x = node.cols() - 1,
            };
        },

        .viewport => viewport: {
            var br = self.getTopLeft(.viewport);
            br = br.down(self.rows - 1).?;
            br.x = br.node.cols() - 1;
            break :viewport br;
        },

        .history => active: {
            var br = self.getTopLeft(.active);
            br = br.up(1) orelse return null;
            br.x = br.node.cols() - 1;
            break :active br;
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
        rows += node.rows();
        node_ = node.next;
    }

    return rows;
}

/// The total number of pages in this list. This should only be used
/// for tests since it is O(N) over the list of pages.
pub fn totalPages(self: *const PageList) usize {
    var pages: usize = 0;
    var node_ = self.pages.first;
    while (node_) |node| {
        pages += 1;
        node_ = node.next;
    }

    return pages;
}

/// Snapshot of the storage used by page nodes in this list.
///
/// The raw byte counts describe page backing mappings only. They exclude
/// nodes, allocator metadata, unused preheated pool items, and the small
/// representation values stored in each node. A compressed page retains its
/// raw mapping as virtual address space, but its bytes are counted as
/// decommitted because strict reclamation succeeded before the state was
/// published.
pub const MemoryStats = struct {
    /// Pages whose raw backing mappings are resident.
    resident_pages: usize = 0,

    /// Pages represented by encoded storage and a decommitted raw mapping.
    compressed_pages: usize = 0,

    /// Logical bytes in every raw page mapping.
    raw_bytes: usize = 0,

    /// Raw mapping bytes which remain resident.
    resident_raw_bytes: usize = 0,

    /// Raw mapping bytes discarded for compressed pages.
    decommitted_raw_bytes: usize = 0,

    /// Raw allocation bytes which remain physically resident.
    ///
    /// This can exceed `resident_raw_bytes` because a pool-owned page uses
    /// only part of a standard pool item. Compressing such a page decommits
    /// its initialized range, but the unused tail of the item stays resident.
    resident_backing_bytes: usize = 0,

    /// Exact encoded allocations retained for compressed pages.
    encoded_bytes: usize = 0,

    /// Estimate resident page backing storage after compression.
    pub fn estimatedResidentBytes(self: MemoryStats) usize {
        return self.resident_backing_bytes + self.encoded_bytes;
    }

    /// Estimate physical bytes avoided by compressed page backing storage.
    pub fn estimatedSavings(self: MemoryStats) usize {
        return self.decommitted_raw_bytes -| self.encoded_bytes;
    }
};

/// Return a metadata-only snapshot of page backing storage.
///
/// This never restores compressed pages. It is intended for diagnostics and
/// other infrequent reporting because it traverses the complete page list.
pub fn memoryStats(self: *const PageList) MemoryStats {
    var result: MemoryStats = .{};
    var current = self.pages.first;
    while (current) |node| : (current = node.next) {
        const raw_len = node.metadata().memory.len;
        const backing_len = switch (node.owned) {
            .pool => PagePool.item_size,
            .heap => raw_len,
        };
        assert(backing_len >= raw_len);
        result.raw_bytes += raw_len;

        switch (node.data) {
            .resident => {
                result.resident_pages += 1;
                result.resident_raw_bytes += raw_len;
                result.resident_backing_bytes += backing_len;
            },

            .compressed => |compressed| {
                result.compressed_pages += 1;
                result.decommitted_raw_bytes += raw_len;
                // Strict reclamation covers only Page.memory. A standard pool
                // item can have an unused tail which remains resident.
                result.resident_backing_bytes += backing_len - raw_len;
                result.encoded_bytes += compressed.encoded.len;
            },
        }
    }

    return result;
}

/// Grow the number of rows available in the page list by n.
/// This is only used for testing so it isn't optimized in any way.
fn growRows(self: *PageList, n: usize) Allocator.Error!void {
    for (0..n) |_| _ = try self.grow();
}

/// Clear all dirty bits on all pages. This is not efficient since it
/// traverses the entire list of pages. This is used for testing/debugging.
pub fn clearDirty(self: *PageList) void {
    var page = self.pages.first;
    while (page) |p| : (page = p.next) {
        const current_page = p.page();
        current_page.dirty = false;
        for (current_page.rows.ptr(current_page.memory)[0..p.rows()]) |*row| {
            row.dirty = false;
        }
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

    /// This is flipped to true for tracked pins that were tracking
    /// a page that got pruned for any reason and where the tracked pin
    /// couldn't be moved to a sensical location. Users of the tracked
    /// pin could use this data and make their own determination of
    /// semantics.
    garbage: bool = false,

    pub inline fn rowAndCell(self: Pin) struct {
        row: *pagepkg.Row,
        cell: *pagepkg.Cell,
    } {
        const rac = self.node.page().getRowAndCell(self.x, self.y);
        return .{ .row = rac.row, .cell = rac.cell };
    }

    pub const CellSubset = enum { all, left, right };

    /// Returns the cells for the row that this pin is on. The subset determines
    /// what subset of the cells are returned. The "left/right" subsets are
    /// inclusive of the x coordinate of the pin.
    pub inline fn cells(self: Pin, subset: CellSubset) []pagepkg.Cell {
        const page = self.node.page();
        const rac = page.getRowAndCell(self.x, self.y);
        const all = page.getCells(rac.row);
        return switch (subset) {
            .all => all,
            .left => all[0 .. self.x + 1],
            .right => all[self.x..],
        };
    }

    /// Returns the grapheme codepoints for the given cell. These are only
    /// the EXTRA codepoints and not the first codepoint.
    pub inline fn grapheme(self: Pin, cell: *const pagepkg.Cell) ?[]u21 {
        return self.node.page().lookupGrapheme(cell);
    }

    /// Returns the style for the given cell in this pin.
    pub inline fn style(self: Pin, cell: *const pagepkg.Cell) stylepkg.Style {
        if (cell.style_id == stylepkg.default_id) return .{};
        const page = self.node.page();
        return page.styles.get(
            page.memory,
            cell.style_id,
        ).*;
    }

    /// Check if this pin is dirty.
    pub inline fn isDirty(self: Pin) bool {
        const page = self.node.page();
        return page.dirty or page.getRowAndCell(self.x, self.y).row.dirty;
    }

    /// Mark this pin location as dirty.
    pub inline fn markDirty(self: Pin) void {
        self.rowAndCell().row.dirty = true;
    }

    /// Iterators. These are the same as PageList iterator funcs but operate
    /// on pins rather than points. This is MUCH more efficient than calling
    /// pointFromPin and building up the iterator from points.
    ///
    /// The limit pin is inclusive.
    pub inline fn pageIterator(
        self: Pin,
        direction: Direction,
        limit: ?Pin,
    ) PageIterator {
        if (build_options.slow_runtime_safety) {
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

    pub inline fn rowIterator(
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

    pub inline fn cellIterator(
        self: Pin,
        direction: Direction,
        limit: ?Pin,
    ) CellIterator {
        var row_it = self.rowIterator(direction, limit);
        var cell = row_it.next() orelse return .{ .row_it = row_it };
        cell.x = self.x;
        return .{ .row_it = row_it, .cell = cell };
    }

    pub inline fn promptIterator(
        self: Pin,
        direction: Direction,
        limit: ?Pin,
    ) PromptIterator {
        return .{
            .current = self,
            .limit = limit,
            .direction = direction,
        };
    }

    /// Returns true if this pin is between the top and bottom, inclusive.
    //
    // Note: this is primarily unit tested as part of the Kitty
    // graphics deletion code.
    pub fn isBetween(self: Pin, top: Pin, bottom: Pin) bool {
        if (build_options.slow_runtime_safety) {
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

    pub inline fn eql(self: Pin, other: Pin) bool {
        return self.node == other.node and
            self.y == other.y and
            self.x == other.x;
    }

    /// Move the pin left n columns. n must fit within the size.
    pub inline fn left(self: Pin, n: usize) Pin {
        assert(n <= self.x);
        var result = self;
        result.x -= std.math.cast(size.CellCountInt, n) orelse result.x;
        return result;
    }

    /// Move the pin right n columns. n must fit within the size.
    pub inline fn right(self: Pin, n: usize) Pin {
        assert(self.x + n < self.node.cols());
        var result = self;
        result.x +|= std.math.cast(size.CellCountInt, n) orelse
            std.math.maxInt(size.CellCountInt);
        return result;
    }

    /// Move the pin left n columns, stopping at the start of the row.
    pub inline fn leftClamp(self: Pin, n: size.CellCountInt) Pin {
        var result = self;
        result.x -|= n;
        return result;
    }

    /// Move the pin right n columns, stopping at the end of the row.
    pub inline fn rightClamp(self: Pin, n: size.CellCountInt) Pin {
        var result = self;
        result.x = @min(self.x +| n, self.node.cols() - 1);
        return result;
    }

    /// Move the pin left n cells, wrapping to the previous row as needed.
    ///
    /// If the offset goes beyond the top of the screen, returns null.
    ///
    /// TODO: Unit tests.
    pub fn leftWrap(self: Pin, n: usize) ?Pin {
        var result = self;
        var remaining = n;
        while (remaining > result.x) {
            remaining -= @as(usize, result.x) + 1;
            result = result.up(1) orelse return null;
            // Crossing a row boundary lands on that destination row's final
            // cell, whose width may differ from ours during reflow.
            result.x = result.node.cols() - 1;
        }

        result.x -= @intCast(remaining);
        return result;
    }

    /// Move the pin right n cells, wrapping to the next row as needed.
    ///
    /// If the offset goes beyond the bottom of the screen, returns null.
    ///
    /// TODO: Unit tests.
    pub fn rightWrap(self: Pin, n: usize) ?Pin {
        var result = self;
        var remaining = n;
        while (true) {
            const row_remaining = result.node.cols() - result.x - 1;
            if (remaining <= row_remaining) {
                result.x += @intCast(remaining);
                return result;
            }

            remaining -= @as(usize, row_remaining) + 1;
            result = result.down(1) orelse return null;
            result.x = 0;
        }
    }

    /// Move the pin down a certain number of rows, or return null if
    /// the pin goes beyond the end of the screen.
    pub inline fn down(self: Pin, n: usize) ?Pin {
        return switch (self.downOverflow(n)) {
            .offset => |v| v,
            .overflow => null,
        };
    }

    /// Move the pin up a certain number of rows, or return null if
    /// the pin goes beyond the start of the screen.
    pub inline fn up(self: Pin, n: usize) ?Pin {
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
        const rows = self.node.rows() - (self.y + 1);
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
                    .y = node.rows() - 1,
                    .x = @min(self.x, node.cols() - 1),
                },
                .remaining = n_left,
            } };
            if (n_left <= node.rows()) return .{ .offset = .{
                .node = node,
                .y = std.math.cast(size.CellCountInt, n_left - 1) orelse
                    std.math.maxInt(size.CellCountInt),
                .x = @min(self.x, node.cols() - 1),
            } };
            n_left -= node.rows();
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
                .end = .{
                    .node = node,
                    .y = 0,
                    .x = @min(self.x, node.cols() - 1),
                },
                .remaining = n_left,
            } };
            if (n_left <= node.rows()) return .{ .offset = .{
                .node = node,
                .y = std.math.cast(size.CellCountInt, node.rows() - n_left) orelse
                    std.math.maxInt(size.CellCountInt),
                .x = @min(self.x, node.cols() - 1),
            } };
            n_left -= node.rows();
        }
    }
};

fn mixedWidthPinListForTest(alloc: Allocator) !PageList {
    var result = try init(alloc, 2, 1, null);
    errdefer result.deinit();

    // This deliberately constructs a layout that normal PageList operations
    // do not expose yet. Keep integrity checks paused through deinit so the
    // fixture can exercise mixed-width traversal in isolation.
    result.pauseIntegrityChecks(true);

    inline for (.{ 4, 3 }) |cols| {
        const node = try result.createPage(.{ .cap = .{
            .cols = cols,
            .rows = 1,
        } });
        node.page().size.rows = 1;
        result.pages.append(node);
        result.total_rows += 1;
    }

    // Desired geometry is wider than the first and last stored pages.
    result.cols = 4;
    return result;
}

test "PageList Pin row movement clamps across mixed-width pages" {
    const testing = std.testing;

    var s = try mixedWidthPinListForTest(testing.allocator);
    defer s.deinit();

    const first = s.pages.first.?;
    const second = first.next.?;
    const third = second.next.?;

    try testing.expect((Pin{ .node = third, .x = 2 }).eql(
        (Pin{ .node = second, .x = 3 }).down(1).?,
    ));
    try testing.expect((Pin{ .node = first, .x = 1 }).eql(
        (Pin{ .node = second, .x = 3 }).up(1).?,
    ));

    switch ((Pin{ .node = second, .x = 3 }).downOverflow(10)) {
        .offset => try testing.expect(false),
        .overflow => |overflow| try testing.expect(
            (Pin{ .node = third, .x = 2 }).eql(overflow.end),
        ),
    }
    switch ((Pin{ .node = second, .x = 3 }).upOverflow(10)) {
        .offset => try testing.expect(false),
        .overflow => |overflow| try testing.expect(
            (Pin{ .node = first, .x = 1 }).eql(overflow.end),
        ),
    }
}

test "PageList Pin wrapping crosses mixed-width pages" {
    const testing = std.testing;

    var s = try mixedWidthPinListForTest(testing.allocator);
    defer s.deinit();

    const first = s.pages.first.?;
    const second = first.next.?;
    const third = second.next.?;

    try testing.expect((Pin{ .node = third, .x = 2 }).eql(
        (Pin{ .node = first, .x = 1 }).rightWrap(7).?,
    ));
    try testing.expect((Pin{ .node = second, .x = 0 }).eql(
        (Pin{ .node = third, .x = 2 }).leftWrap(6).?,
    ));
    try testing.expect((Pin{ .node = first }).leftWrap(1) == null);
    try testing.expect((Pin{ .node = third, .x = 2 }).rightWrap(1) == null);
}

test "PageList Pin rejects columns beyond mixed-width page bounds" {
    const testing = std.testing;

    var s = try mixedWidthPinListForTest(testing.allocator);
    defer s.deinit();

    try testing.expect(s.pin(.{ .screen = .{ .x = 1, .y = 0 } }) != null);
    try testing.expect(s.pin(.{ .screen = .{ .x = 2, .y = 0 } }) == null);
    try testing.expect(s.pin(.{ .screen = .{ .x = 3, .y = 1 } }) != null);
    try testing.expect(s.pin(.{ .screen = .{ .x = 3, .y = 2 } }) == null);
}

pub const Cell = struct {
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
        return self.node.page().dirty or self.row.dirty;
    }

    /// Get the cell style.
    ///
    /// Not meant for non-test usage since this is inefficient.
    pub fn style(self: Cell) stylepkg.Style {
        if (self.cell.style_id == stylepkg.default_id) return .{};
        const page = self.node.page();
        return page.styles.get(
            page.memory,
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
        var y: u32 = self.row_idx;
        var node_ = self.node;
        while (node_.prev) |node| {
            y += node.rows();
            node_ = node;
        }

        return .{ .screen = .{
            .x = self.col_idx,
            .y = y,
        } };
    }
};

/// Grow a test PageList until it contains at least `count` complete history
/// pages. The production cold-page boundary is intentionally reused here so
/// tests do not duplicate the row-to-page arithmetic.
fn growColdPagesForTest(self: *PageList, count: usize) !void {
    while (true) {
        const active_node = self.getTopLeft(.active).node;
        var cold_count: usize = 0;
        var current = self.pages.first;
        while (current) |node| : (current = node.next) {
            if (node == active_node) break;
            cold_count += 1;
        }

        if (cold_count >= count) return;
        _ = try self.grow();
    }
}

/// Fill the current tail page to capacity without allocating a successor.
/// Capturing the tail before the loop makes this stop at the allocation
/// boundary needed by bounded-pruning tests.
fn fillLastPageForTest(self: *PageList) !void {
    const last = self.pages.last.?;
    while (last.rows() < last.capacity().rows) _ = try self.grow();
}

/// Verify every live page belongs to the current validity epoch, has an
/// allocated generation below the next serial, and validates through the same
/// pointer-plus-generation lookup used by external references.
fn expectLivePageSerialsValidForTest(self: *const PageList) !void {
    const testing = std.testing;
    var node = self.pages.first;
    while (node) |live| : (node = live.next) {
        try testing.expect(live.serial >= self.page_serial_epoch);
        try testing.expect(live.serial < self.page_serial);
        try testing.expect(self.nodeIsValid(live, live.serial));
    }
}

test "PageList Pin rightWrap exact row multiple" {
    const testing = std.testing;

    var s = try init(testing.allocator, 10, 3, null);
    defer s.deinit();

    const start = s.pin(.{ .active = .{ .x = 5, .y = 0 } }).?;
    const wrapped = start.rightWrap(14).?;
    _ = wrapped.rowAndCell();

    try testing.expectEqual(
        point.Point{ .active = .{ .x = 9, .y = 1 } },
        s.pointFromPin(.active, wrapped),
    );
}

test "PageList Pin leftWrap exact row multiple" {
    const testing = std.testing;

    var s = try init(testing.allocator, 10, 3, null);
    defer s.deinit();

    const start = s.pin(.{ .active = .{ .x = 5, .y = 2 } }).?;
    const wrapped = start.leftWrap(15).?;
    _ = wrapped.rowAndCell();

    try testing.expectEqual(
        point.Point{ .active = .{ .x = 0, .y = 1 } },
        s.pointFromPin(.active, wrapped),
    );
}

test "PageList Pin rightWrap maximum distance" {
    const testing = std.testing;

    var s = try init(testing.allocator, 1, 3, null);
    defer s.deinit();

    const start = s.pin(.{ .active = .{ .y = 0 } }).?;
    try testing.expectEqual(null, start.rightWrap(std.math.maxInt(usize)));
}

test "PageList Pin leftWrap maximum distance" {
    const testing = std.testing;

    var s = try init(testing.allocator, 1, 3, null);
    defer s.deinit();

    const start = s.pin(.{ .active = .{ .y = 2 } }).?;
    try testing.expectEqual(null, start.leftWrap(std.math.maxInt(usize)));
}

test "PageList incremental compression skips visible history" {
    const testing = std.testing;

    var s = try init(testing.allocator, 80, 24, null);
    defer s.deinit();
    try s.growColdPagesForTest(3);

    const initial_activity = s.page_compression.activity_serial;
    try testing.expect(initial_activity > 0);

    s.scroll(.top);
    const top_activity = s.page_compression.activity_serial;
    try testing.expect(top_activity != initial_activity);
    try testing.expectEqual(
        IncrementalCompressionResult.complete,
        s.compress(.drain),
    );

    const first = s.pages.first.?;
    const second = first.next.?;
    try testing.expectEqual(first, s.getTopLeft(.viewport).node);
    try testing.expectEqual(first, s.getBottomRight(.viewport).?.node);
    try testing.expect(!first.isCompressed());

    var eligible: CompressionIterator = .init(&s);
    var compressed_pages: usize = 0;
    while (eligible.next()) |node| {
        compressed_pages += 1;
        try testing.expect(node.isCompressed());
    }
    try testing.expect(compressed_pages > 0);

    // Move the viewport to the start of the second page. Rendering it restores
    // that page, while the first page which just left view becomes eligible.
    s.scroll(.{ .row = first.rows() });
    try testing.expectEqual(second, s.getTopLeft(.viewport).node);
    _ = second.page();
    try testing.expect(!second.isCompressed());
    _ = s.compress(.drain);
    try testing.expect(first.isCompressed());
    try testing.expect(!second.isCompressed());

    // Returning to the active area makes every complete historical page
    // eligible again, including the page which was just visible.
    s.scroll(.active);
    _ = s.compress(.drain);
    try testing.expect(second.isCompressed());
    try testing.expect(!s.page_compression.flags.did_compress);
    try testing.expect(!s.page_compression.flags.verifying);
    try testing.expectEqual(@as(?u64, null), s.page_compression.last_serial);
    try testing.expectEqual(@as(u64, 0), s.page_compression.next_serial);
}

test "PageList owns incremental compression state" {
    const testing = std.testing;

    var s = try init(testing.allocator, 80, 24, null);
    defer s.deinit();

    const state: IncrementalCompressionState = .{
        .flags = .{
            .did_compress = true,
            .verifying = true,
        },
        .activity_serial = 42,
        .last_serial = 42,
        .next_serial = 43,
    };

    s.page_compression = state;
    s.scroll(.top);
    try testing.expectEqual(
        IncrementalCompressionState{ .activity_serial = 43 },
        s.page_compression,
    );

    // Every scroll restarts traversal, even if clamping leaves the viewport in
    // the same place. Missing an eligible page is worse than a no-op pass.
    s.page_compression = state;
    s.scroll(.top);
    try testing.expectEqual(
        IncrementalCompressionState{ .activity_serial = 43 },
        s.page_compression,
    );

    s.page_compression = state;
    s.scroll(.active);
    try testing.expectEqual(
        IncrementalCompressionState{ .activity_serial = 43 },
        s.page_compression,
    );

    s.page_compression = state;
    try s.resize(.{ .cols = 80, .rows = 24 });
    try testing.expectEqual(
        IncrementalCompressionState{ .activity_serial = 43 },
        s.page_compression,
    );

    s.page_compression = state;
    s.reset();
    try testing.expectEqual(
        IncrementalCompressionState{ .activity_serial = 42 },
        s.page_compression,
    );

    s.page_compression = state;
    try testing.expectEqual(
        IncrementalCompressionResult.complete,
        s.compress(.full),
    );
    try testing.expectEqual(
        IncrementalCompressionState{ .activity_serial = 42 },
        s.page_compression,
    );

    s.page_compression = state;
    var cloned = try s.clone(testing.allocator, .{
        .top = .{ .active = .{} },
    });
    defer cloned.deinit();
    try testing.expectEqual(
        IncrementalCompressionState{},
        cloned.page_compression,
    );
}

test "PageList replacements preserve compression continuation and mark activity" {
    const testing = std.testing;

    var s = try init(testing.allocator, 80, 24, null);
    defer s.deinit();

    const state: IncrementalCompressionState = .{
        .flags = .{ .verifying = true },
        .activity_serial = 42,
        .last_serial = 7,
        .next_serial = 8,
    };
    const expected: IncrementalCompressionState = .{
        .flags = .{ .verifying = true },
        .activity_serial = 43,
        .last_serial = 7,
        .next_serial = 8,
    };

    s.page_compression = state;
    const replacement = try s.increaseCapacity(s.pages.first.?, null);
    try testing.expectEqual(expected, s.page_compression);

    s.page_compression = state;
    _ = (try s.compact(replacement)).?;
    try testing.expectEqual(expected, s.page_compression);
}

test "PageList incremental compression bounds inspected pages" {
    const testing = std.testing;

    var s = try init(testing.allocator, 80, 24, null);
    defer s.deinit();
    try s.growColdPagesForTest(incremental_compression_max_inspected + 1);

    // Precompress every candidate so the incremental pass exercises its
    // metadata-only skip budget without stopping at a resident attempt.
    _ = s.compress(.full);
    s.page_compression.reset();
    s.page_compression.markActivity();
    try testing.expectEqual(
        incremental_compression_max_inspected + 1,
        s.memoryStats().compressed_pages,
    );

    var expected_last = s.pages.first.?;
    for (1..incremental_compression_max_inspected) |_|
        expected_last = expected_last.next.?;

    const first = s.compress(.incremental);
    try testing.expectEqual(IncrementalCompressionResult.pending, first);
    try testing.expectEqual(
        expected_last.serial,
        s.page_compression.last_serial.?,
    );

    const second = s.compress(.incremental);
    try testing.expectEqual(IncrementalCompressionResult.pending, second);
    try testing.expect(s.page_compression.flags.verifying);
    try testing.expect(s.page_compression.last_serial == null);

    // The verification pass is bounded independently, too.
    try testing.expectEqual(
        IncrementalCompressionResult.pending,
        s.compress(.incremental),
    );
    try testing.expectEqual(
        IncrementalCompressionResult.complete,
        s.compress(.incremental),
    );
}

test "PageList incremental compression advances after failure" {
    const testing = std.testing;

    var s = try init(testing.allocator, 80, 24, null);
    defer s.deinit();
    try s.growColdPagesForTest(2);

    const first = s.pages.first.?;
    const second = first.next.?;
    var prng = std.Random.DefaultPrng.init(0x494E_4352_5041_5353);
    prng.random().bytes(first.page().memory);

    const failed = s.compress(.incremental);
    try testing.expectEqual(IncrementalCompressionResult.pending, failed);
    try testing.expect(!first.isCompressed());

    // The unsuccessful first page does not stall the pass. The next step
    // continues at the following serial and compresses that page.
    const continued = s.compress(.incremental);
    try testing.expectEqual(IncrementalCompressionResult.pending, continued);
    try testing.expect(second.isCompressed());
}

test "PageList incremental compression advances after allocation failure" {
    const testing = std.testing;

    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const alloc = failing.allocator();
    var s = try init(alloc, 80, 24, null);
    defer s.deinit();
    try s.growColdPagesForTest(2);
    const first = s.pages.first.?;
    const second = first.next.?;

    // Pool preheating supplies compression scratch. Failing the allocator's
    // next request therefore rejects the exact encoded allocation while the
    // source page and pass remain valid.
    failing.fail_index = failing.alloc_index;
    const failed = s.compress(.incremental);
    try testing.expect(failing.has_induced_failure);
    try testing.expectEqual(IncrementalCompressionResult.pending, failed);
    try testing.expect(!first.isCompressed());

    // Allow allocations again. The pass must continue with the following page
    // rather than retrying the failed candidate.
    failing.fail_index = std.math.maxInt(usize);
    const continued = s.compress(.incremental);
    try testing.expectEqual(IncrementalCompressionResult.pending, continued);
    try testing.expect(second.isCompressed());
}

test "PageList incremental compression advances after decommit failure" {
    const testing = std.testing;
    const tw = compressPage_tw;
    defer tw.end(.reset) catch unreachable;

    var s = try init(testing.allocator, 80, 24, null);
    defer s.deinit();
    try s.growColdPagesForTest(2);

    tw.errorAlways(.decommit, error.DecommitFailed);
    const failed = s.compress(.incremental);
    try testing.expectEqual(IncrementalCompressionResult.pending, failed);
    try testing.expect(!s.pages.first.?.isCompressed());
    try tw.end(.reset);

    // The failed candidate remains resident and the pass continues at the
    // next serial once reclamation is available again.
    const continued = s.compress(.incremental);
    try testing.expectEqual(IncrementalCompressionResult.pending, continued);
    try testing.expect(s.pages.first.?.next.?.isCompressed());
}

test "PageList incremental compression restarts after replacement" {
    const testing = std.testing;

    var s = try init(testing.allocator, 80, 24, null);
    defer s.deinit();
    try s.growColdPagesForTest(1);

    const initial = s.compress(.incremental);
    try testing.expectEqual(IncrementalCompressionResult.pending, initial);
    try testing.expect(s.pages.first.?.isCompressed());

    const old = s.pages.first.?;
    const old_serial = old.serial;
    var replacement = old;
    while (replacement.page().memory.len <= std_size) {
        replacement = try s.increaseCapacity(
            replacement,
            .grapheme_bytes,
        );
    }
    try testing.expect(replacement.serial != old_serial);
    try testing.expect(replacement.page().memory.len > std_size);
    try testing.expect(!replacement.isCompressed());

    // The exact continuation serial disappeared with the old node. The pass
    // restarts at the first page and considers the oversized replacement.
    const restarted = s.compress(.incremental);
    try testing.expectEqual(IncrementalCompressionResult.pending, restarted);
    try testing.expect(replacement.isCompressed());
}

test "PageList incremental compression restarts after reset" {
    const testing = std.testing;

    var s = try init(testing.allocator, 80, 24, null);
    defer s.deinit();
    try s.growColdPagesForTest(1);

    const initial = s.compress(.incremental);
    try testing.expectEqual(IncrementalCompressionResult.pending, initial);
    try testing.expect(s.pages.first.?.isCompressed());

    // Reset replaces every page and clears the PageList-owned traversal.
    s.reset();
    try s.growColdPagesForTest(1);
    const restarted = s.compress(.incremental);
    try testing.expectEqual(IncrementalCompressionResult.pending, restarted);
    try testing.expect(s.pages.first.?.isCompressed());
}

test "PageList incremental compression restarts after active boundary resize" {
    const testing = std.testing;

    var s = try init(testing.allocator, 80, 24, null);
    defer s.deinit();
    try s.growColdPagesForTest(1);

    const initial = s.compress(.incremental);
    try testing.expectEqual(IncrementalCompressionResult.pending, initial);
    try testing.expect(s.pages.first.?.isCompressed());

    const first = s.pages.first.?;
    const all_rows: size.CellCountInt = @intCast(s.total_rows);
    try s.resize(.{ .rows = all_rows });
    try testing.expectEqual(first, s.getTopLeft(.active).node);

    // Restore the page while it is active. Resize reset the traversal, and
    // active contents remain ineligible.
    _ = first.page();
    const active = s.compress(.incremental);
    try testing.expectEqual(IncrementalCompressionResult.pending, active);
    try testing.expectEqual(
        IncrementalCompressionResult.complete,
        s.compress(.incremental),
    );

    // Shrinking the active area makes the page fully historical again. The
    // resize reset the PageList-owned cursor, so the next step can reclaim it.
    try s.resize(.{ .rows = 24 });
    try s.growColdPagesForTest(1);
    try testing.expectEqual(
        IncrementalCompressionResult.pending,
        s.compress(.incremental),
    );
    try testing.expect(first.isCompressed());
}

test "PageList incremental compression restarts after prune reuse" {
    const testing = std.testing;

    var s = try init(
        testing.allocator,
        80,
        24,
        2 * PagePool.item_size,
    );
    defer s.deinit();
    try s.growColdPagesForTest(1);

    const initial = s.compress(.incremental);
    try testing.expectEqual(IncrementalCompressionResult.pending, initial);
    try testing.expect(s.pages.first.?.isCompressed());

    const reused = s.pages.first.?;
    const old_serial = reused.serial;
    while (s.pages.last.?.rows() < s.pages.last.?.capacity().rows) {
        _ = try s.grow();
    }
    try testing.expectEqual(reused, (try s.grow()).?);
    try testing.expect(reused.serial != old_serial);

    // Make the remaining old page fully historical. The continuation serial
    // disappeared when its node was recycled, so the pass safely restarts.
    try s.growColdPagesForTest(1);
    _ = s.compress(.incremental);
    try testing.expectEqual(@as(usize, 1), s.memoryStats().compressed_pages);
}

test "PageList bounded pruning after partial erase preserves live serials" {
    const testing = std.testing;

    var s = try init(
        testing.allocator,
        80,
        24,
        2 * PagePool.item_size,
    );
    defer s.deinit();

    while (s.totalPages() < 2) _ = try s.grow();
    const first = s.pages.first.?;
    const old_serial = first.serial;
    const old_rows = first.rows();

    s.eraseHistory(.{ .history = .{ .y = 0 } });
    try testing.expectEqual(first, s.pages.first.?);
    try testing.expectEqual(old_rows - 1, first.rows());
    try testing.expect(!s.nodeIsValid(first, old_serial));

    try s.fillLastPageForTest();
    _ = try s.grow();
    try s.expectLivePageSerialsValidForTest();
}

test "PageList partial erase restarts compression before continuation" {
    const testing = std.testing;

    var s = try init(testing.allocator, 80, 24, null);
    defer s.deinit();
    try s.growColdPagesForTest(incremental_compression_max_inspected + 1);
    _ = s.compress(.full);

    const first = s.pages.first.?;
    try testing.expect(first.isCompressed());

    var marker = first;
    for (1..incremental_compression_max_inspected) |_| marker = marker.next.?;
    s.page_compression = .{
        .flags = .{ .verifying = true },
        .last_serial = marker.serial,
        .next_serial = s.page_serial,
    };

    const activity = s.page_compression.activity_serial;
    s.eraseHistory(.{ .history = .{ .y = 0 } });
    try testing.expect(!first.isCompressed());
    try testing.expect(activity != s.page_compression.activity_serial);

    // The changed generation is before the saved marker, so continuation must
    // restart and recompress it instead of reporting verification complete.
    try testing.expectEqual(
        IncrementalCompressionResult.pending,
        s.compress(.incremental),
    );
    try testing.expect(first.isCompressed());
}

test "PageList bounded pruning after split invalidation preserves live serials" {
    const testing = std.testing;

    var s = try init(
        testing.allocator,
        80,
        24,
        2 * PagePool.item_size,
    );
    defer s.deinit();

    while (s.totalPages() < 2) _ = try s.grow();
    const first = s.pages.first.?;
    const old_serial = first.serial;
    const activity = s.page_compression.activity_serial;

    try s.split(.{
        .node = first,
        .y = first.rows() / 2,
        .x = 0,
    });
    try testing.expect(!s.nodeIsValid(first, old_serial));
    try testing.expect(activity != s.page_compression.activity_serial);

    try s.fillLastPageForTest();
    _ = try s.grow();
    try s.expectLivePageSerialsValidForTest();
}

test "PageList repeated bounded pruning after split preserves live serials" {
    const testing = std.testing;

    var s = try init(
        testing.allocator,
        80,
        24,
        3 * PagePool.item_size,
    );
    defer s.deinit();

    const epoch = s.page_serial_epoch;
    while (s.totalPages() < 3) _ = try s.grow();
    const first = s.pages.first.?;
    try s.split(.{
        .node = first,
        .y = first.rows() / 2,
        .x = 0,
    });

    // The split target has a fresh serial but precedes older successor pages.
    // Prune both the old source and then that target while verifying ordinary
    // list mutation does not advance the whole-list validity epoch.
    for (0..2) |_| {
        while (s.pages.last.?.rows() < s.pages.last.?.capacity().rows) {
            _ = try s.grow();
        }
        _ = try s.grow();

        // Ordinary pruning invalidates one generation at a time through live
        // list validation; only reset may begin a new whole-list epoch.
        try testing.expectEqual(epoch, s.page_serial_epoch);
        try s.expectLivePageSerialsValidForTest();
    }
}

test "PageList bounded pruning after front replacement preserves live serials" {
    const testing = std.testing;

    var s = try init(
        testing.allocator,
        80,
        24,
        2 * PagePool.item_size,
    );
    defer s.deinit();

    while (s.totalPages() < 2) _ = try s.grow();
    const old = s.pages.first.?;
    const old_serial = old.serial;
    const replacement = try s.increaseCapacity(old, null);
    try testing.expect(replacement != old);
    try testing.expect(!s.nodeIsValid(old, old_serial));

    try s.fillLastPageForTest();
    _ = try s.grow();

    try s.expectLivePageSerialsValidForTest();
}

test "PageList bounded pruning after middle replacement preserves live serials" {
    const testing = std.testing;

    var s = try init(
        testing.allocator,
        80,
        24,
        3 * PagePool.item_size,
    );
    defer s.deinit();

    while (s.totalPages() < 3) _ = try s.grow();
    const old = s.pages.first.?.next.?;
    const old_serial = old.serial;
    const replacement = try s.increaseCapacity(old, null);
    try testing.expect(replacement != old);
    try testing.expect(!s.nodeIsValid(old, old_serial));

    // Prune the original first page and then the fresh middle replacement.
    for (0..2) |_| {
        try s.fillLastPageForTest();
        _ = try s.grow();
        try s.expectLivePageSerialsValidForTest();
    }
}

test "PageList incremental compression restarts after earlier replacement" {
    const testing = std.testing;

    var s = try init(testing.allocator, 80, 24, null);
    defer s.deinit();
    try s.growColdPagesForTest(3);

    _ = s.compress(.incremental);
    _ = s.compress(.incremental);
    try testing.expect(s.pages.first.?.isCompressed());
    try testing.expect(s.pages.first.?.next.?.isCompressed());

    // Replace a page before the still-valid continuation marker. The list's
    // allocation serial changes even though the marker itself remains, so the
    // next step must restart and inspect the replacement.
    const old_first = s.pages.first.?;
    const old_serial = old_first.serial;
    const replacement = try s.increaseCapacity(
        old_first,
        .grapheme_bytes,
    );
    try testing.expect(replacement.serial != old_serial);
    try testing.expect(!replacement.isCompressed());

    _ = s.compress(.incremental);
    try testing.expect(replacement.isCompressed());
}

test "PageList incremental compression keeps progress after tail growth" {
    const testing = std.testing;

    var s = try init(testing.allocator, 80, 24, null);
    defer s.deinit();
    try s.growColdPagesForTest(incremental_compression_max_inspected + 1);
    _ = s.compress(.full);
    s.page_compression.reset();
    s.page_compression.markActivity();

    var expected_last = s.pages.first.?;
    for (1..incremental_compression_max_inspected) |_|
        expected_last = expected_last.next.?;

    const first = s.compress(.incremental);
    try testing.expectEqual(IncrementalCompressionResult.pending, first);
    try testing.expectEqual(
        expected_last.serial,
        s.page_compression.last_serial.?,
    );

    // Allocate a new page at the active tail between steps. It is after the
    // continuation marker and must not restart progress through cold history.
    const next_serial = s.page_serial;
    while (s.page_serial == next_serial) _ = try s.grow();
    const continued = s.compress(.incremental);
    try testing.expectEqual(IncrementalCompressionResult.pending, continued);
    try testing.expect(s.page_compression.flags.verifying);
}

test "PageList memory stats do not restore compressed pages" {
    const testing = std.testing;

    var s = try init(testing.allocator, 80, 24, null);
    defer s.deinit();
    try s.growColdPagesForTest(2);

    const before = s.memoryStats();
    try testing.expectEqual(s.totalPages(), before.resident_pages);
    try testing.expectEqual(@as(usize, 0), before.compressed_pages);
    try testing.expectEqual(s.page_size, before.raw_bytes);
    try testing.expectEqual(before.raw_bytes, before.resident_raw_bytes);
    try testing.expectEqual(@as(usize, 0), before.decommitted_raw_bytes);
    try testing.expectEqual(s.page_size, before.resident_backing_bytes);
    try testing.expectEqual(@as(usize, 0), before.encoded_bytes);
    try testing.expectEqual(
        before.resident_backing_bytes,
        before.estimatedResidentBytes(),
    );
    try testing.expectEqual(@as(usize, 0), before.estimatedSavings());

    _ = s.compress(.full);
    const first = s.pages.first.?;
    try testing.expectEqual(Node.Storage.compressed, first.storage());
    try testing.expect(first.pageIfResident() == null);

    const after = s.memoryStats();
    try testing.expect(first.isCompressed());
    try testing.expectEqual(s.totalPages(), after.resident_pages + after.compressed_pages);
    try testing.expectEqual(@as(usize, 2), after.compressed_pages);
    try testing.expectEqual(s.page_size, after.raw_bytes);
    try testing.expectEqual(
        after.raw_bytes,
        after.resident_raw_bytes + after.decommitted_raw_bytes,
    );
    try testing.expectEqual(
        after.resident_backing_bytes + after.encoded_bytes,
        after.estimatedResidentBytes(),
    );
    try testing.expectEqual(
        after.decommitted_raw_bytes - after.encoded_bytes,
        after.estimatedSavings(),
    );

    const first_raw_len = first.metadata().memory.len;
    const first_encoded_len = first.data.compressed.encoded.len;
    _ = first.page();
    try testing.expectEqual(Node.Storage.resident, first.storage());
    try testing.expect(first.pageIfResident() != null);

    const restored = s.memoryStats();
    try testing.expectEqual(after.resident_pages + 1, restored.resident_pages);
    try testing.expectEqual(after.compressed_pages - 1, restored.compressed_pages);
    try testing.expectEqual(after.raw_bytes, restored.raw_bytes);
    try testing.expectEqual(
        after.resident_raw_bytes + first_raw_len,
        restored.resident_raw_bytes,
    );
    try testing.expectEqual(
        after.decommitted_raw_bytes - first_raw_len,
        restored.decommitted_raw_bytes,
    );
    try testing.expectEqual(
        after.resident_backing_bytes + first_raw_len,
        restored.resident_backing_bytes,
    );
    try testing.expectEqual(
        after.encoded_bytes - first_encoded_len,
        restored.encoded_bytes,
    );
}

test "PageList preserved page keeps compressed storage" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();

    const node = s.pages.first.?;
    const resident = node.page();
    resident.dirty = true;
    resident.getRowAndCell(3, 2).cell.* = .init('X');

    // Resident nodes can be borrowed without allocating an unnecessary copy.
    {
        var failing = testing.FailingAllocator.init(alloc, .{
            .fail_index = 0,
        });
        var preserved = try node.pagePreservingState(failing.allocator());
        defer preserved.deinit();
        switch (preserved) {
            .borrowed => |page_| try testing.expectEqual(resident, page_),
            .owned => try testing.expect(false),
        }
        try testing.expect(!failing.has_induced_failure);
    }

    const expected = try alloc.dupe(u8, resident.memory);
    defer alloc.free(expected);
    const retained_ptr = resident.memory.ptr;

    try testing.expect(s.compressPage(node));
    const stats = s.memoryStats();
    const expected_encoded = try alloc.dupe(u8, node.data.compressed.encoded);
    defer alloc.free(expected_encoded);

    // Test decommit simulates physical reclamation by clearing the retained
    // mapping. A preserved page must decode elsewhere rather than restoring
    // it.
    try testing.expect(std.mem.allEqual(u8, node.metadata().memory, 0));

    // Preserved-page allocation is opportunistic for callers. Failure leaves
    // the node and its compressed representation untouched.
    var failing = testing.FailingAllocator.init(alloc, .{
        .fail_index = 0,
    });
    try testing.expectError(
        error.OutOfMemory,
        node.pagePreservingState(failing.allocator()),
    );
    try testing.expectEqual(Node.Storage.compressed, node.storage());
    try testing.expectEqual(stats, s.memoryStats());

    var preserved = try node.pagePreservingState(alloc);
    defer preserved.deinit();
    switch (preserved) {
        .borrowed => try testing.expect(false),
        .owned => {},
    }
    const page_ = preserved.page();

    try testing.expect(page_.memory.ptr != retained_ptr);
    try testing.expectEqualSlices(u8, expected, page_.memory);
    try testing.expect(page_.dirty);
    try testing.expectEqual(
        @as(u21, 'X'),
        page_.getRowAndCell(3, 2).cell.content.codepoint,
    );

    // The node still owns the same compressed representation, and neither its
    // storage accounting nor its discarded raw mapping changed while cloning.
    try testing.expectEqual(Node.Storage.compressed, node.storage());
    try testing.expectEqual(stats, s.memoryStats());
    try testing.expectEqual(retained_ptr, node.metadata().memory.ptr);
    try testing.expect(std.mem.allEqual(u8, node.metadata().memory, 0));
    try testing.expectEqualSlices(
        u8,
        expected_encoded,
        node.data.compressed.encoded,
    );
}

test "PageList memory stats include unused pool backing" {
    const testing = std.testing;

    var s = try init(testing.allocator, 80, 24, null);
    defer s.deinit();

    // Pool allocation ownership is based on the requested layout fitting in a
    // standard item. The Page itself exposes only the initialized prefix.
    const node = try s.createPage(.{ .cap = .{ .cols = 1, .rows = 1 } });
    try testing.expectEqual(Node.Owned.pool, node.owned);
    try testing.expect(node.page().memory.len < PagePool.item_size);
    node.page().size.rows = 1;
    s.pages.append(node);
    s.total_rows += 1;

    const raw_len = node.metadata().memory.len;
    const before = s.memoryStats();
    try testing.expect(before.raw_bytes < s.page_size);
    try testing.expectEqual(before.raw_bytes, before.resident_raw_bytes);
    try testing.expectEqual(s.page_size, before.resident_backing_bytes);
    try testing.expectEqual(s.page_size, before.estimatedResidentBytes());

    try testing.expect(s.compressPage(node));
    const encoded_len = node.data.compressed.encoded.len;
    const compressed = s.memoryStats();
    try testing.expectEqual(before.raw_bytes, compressed.raw_bytes);
    try testing.expectEqual(
        before.resident_raw_bytes - raw_len,
        compressed.resident_raw_bytes,
    );
    try testing.expectEqual(raw_len, compressed.decommitted_raw_bytes);
    try testing.expectEqual(
        before.resident_backing_bytes - raw_len,
        compressed.resident_backing_bytes,
    );
    try testing.expectEqual(encoded_len, compressed.encoded_bytes);
    try testing.expectEqual(
        before.estimatedResidentBytes() - raw_len + encoded_len,
        compressed.estimatedResidentBytes(),
    );
}

test "PageList does not compress the mixed history and active page" {
    const testing = std.testing;

    var s = try init(testing.allocator, 80, 24, null);
    defer s.deinit();

    // One additional row creates history, but the history and all active rows
    // still share the first page. The active boundary therefore has a
    // historical prefix and must remain resident as one indivisible mapping.
    _ = try s.grow();
    const active = s.getTopLeft(.active);
    try testing.expectEqual(s.pages.first.?, active.node);
    try testing.expect(active.y > 0);

    _ = s.compress(.full);
    try testing.expect(!s.pages.first.?.isCompressed());
}

test "PageList compresses only complete cold history pages" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // More active rows than one page at these dimensions can hold ensures the
    // active area spans multiple nodes when the pass chooses its boundary.
    const active_rows = initialCapacity(80).rows + 1;
    var s = try init(alloc, 80, active_rows, null);
    defer s.deinit();
    try s.growColdPagesForTest(2);

    // Move the active top into the boundary page so it has both a historical
    // prefix and active rows while the active area still spans later pages.
    _ = try s.grow();

    const active = s.getTopLeft(.active);
    const active_node = active.node;
    try testing.expect(active.y > 0);
    try testing.expect(active_node != s.pages.last.?);

    var expected_compressed: usize = 0;
    var expected_raw_bytes: usize = 0;
    var current = s.pages.first;
    while (current) |node| : (current = node.next) {
        if (node == active_node) break;
        expected_compressed += 1;
        expected_raw_bytes += node.metadata().memory.len;
    }
    try testing.expectEqual(@as(usize, 2), expected_compressed);

    const first = s.pages.first.?;
    first.page().getRowAndCell(0, 0).cell.* = .init('X');
    const expected = try alloc.dupe(u8, first.page().memory);
    defer alloc.free(expected);
    const first_memory = first.page().memory.ptr;
    const page_size = s.page_size;

    _ = s.compress(.full);
    const memory = s.memoryStats();
    try testing.expectEqual(expected_compressed, memory.compressed_pages);
    try testing.expectEqual(expected_raw_bytes, memory.decommitted_raw_bytes);
    try testing.expect(memory.encoded_bytes < memory.decommitted_raw_bytes);
    try testing.expectEqual(page_size, s.page_size);

    current = s.pages.first;
    var actual_encoded_bytes: usize = 0;
    while (current) |node| : (current = node.next) {
        if (node == active_node) break;
        try testing.expect(node.isCompressed());
        actual_encoded_bytes += node.data.compressed.encoded.len;
    }
    try testing.expectEqual(actual_encoded_bytes, memory.encoded_bytes);
    current = active_node;
    while (current) |node| : (current = node.next) {
        try testing.expect(!node.isCompressed());
    }

    // Restoring the oldest page preserves both the mapping identity and all
    // of its bytes even though the pass discarded its physical pages.
    try testing.expectEqual(first_memory, first.metadata().memory.ptr);
    try testing.expectEqualSlices(u8, expected, first.page().memory);
    try testing.expectEqual(first_memory, first.page().memory.ptr);
}

test "PageList lazily restores compressed history made active by resize" {
    const testing = std.testing;

    var s = try init(testing.allocator, 80, 24, null);
    defer s.deinit();
    try s.growColdPagesForTest(1);

    const first = s.pages.first.?;
    first.page().getRowAndCell(0, 0).cell.* = .init('X');
    const memory_ptr = first.page().memory.ptr;
    const memory_len = first.page().memory.len;
    const page_size = s.page_size;

    _ = s.compress(.full);
    try testing.expect(first.isCompressed());

    // Pull all scrollback into the active area by making the viewport as tall
    // as the complete screen. A row-only resize needs only page metadata, so
    // the newly active page can remain compressed until its contents are used.
    const all_rows: size.CellCountInt = @intCast(s.total_rows);
    try s.resize(.{ .rows = all_rows });
    const active = s.getTopLeft(.active);
    try testing.expectEqual(first, active.node);
    try testing.expectEqual(@as(size.CellCountInt, 0), active.y);
    try testing.expect(first.isCompressed());
    try testing.expectEqual(page_size, s.page_size);

    // The compression pass must not reconsider the node now that it is active.
    // Content access follows the normal page boundary, which recommits and
    // restores the retained mapping before returning the cell.
    _ = s.compress(.full);
    try testing.expect(first.isCompressed());
    const cell = s.getCell(.{ .active = .{} }).?;
    try testing.expectEqual(@as(u21, 'X'), cell.cell.content.codepoint);
    try testing.expect(!first.isCompressed());
    try testing.expectEqual(memory_ptr, first.page().memory.ptr);
    try testing.expectEqual(memory_len, first.page().memory.len);
    try testing.expectEqual(page_size, s.page_size);
}

test "PageList full and incremental compression skip a spanning viewport" {
    const testing = std.testing;

    var full = try init(testing.allocator, 80, 24, null);
    defer full.deinit();
    try full.growColdPagesForTest(3);

    var incremental = try init(testing.allocator, 80, 24, null);
    defer incremental.deinit();
    try incremental.growColdPagesForTest(3);

    // Start near the end of the first page so the viewport intersects both
    // the first and second historical page mappings.
    const first = full.pages.first.?;
    const overlap_rows: usize = full.rows / 2;
    const viewport_row: usize = first.rows() - overlap_rows;
    full.scroll(.{ .row = viewport_row });
    incremental.scroll(.{ .row = viewport_row });
    try testing.expect(
        full.getTopLeft(.viewport).node !=
            full.getBottomRight(.viewport).?.node,
    );
    const second = first.next.?;
    try testing.expectEqual(first, full.getTopLeft(.viewport).node);
    try testing.expectEqual(second, full.getBottomRight(.viewport).?.node);

    _ = full.compress(.full);
    _ = incremental.compress(.drain);
    try testing.expectEqual(full.memoryStats(), incremental.memoryStats());
    try testing.expect(!first.isCompressed());
    try testing.expect(!second.isCompressed());

    const full_active = full.getTopLeft(.active).node;
    const incremental_active = incremental.getTopLeft(.active).node;
    var full_node = full.pages.first.?;
    var incremental_node = incremental.pages.first.?;
    while (full_node != full_active) {
        try testing.expectEqual(
            full_node.isCompressed(),
            incremental_node.isCompressed(),
        );

        full_node = full_node.next.?;
        incremental_node = incremental_node.next.?;
    }
    try testing.expectEqual(incremental_active, incremental_node);

    var eligible: CompressionIterator = .init(&full);
    var compressed_pages: usize = 0;
    while (eligible.next()) |node| {
        compressed_pages += 1;
        try testing.expect(node.isCompressed());
    }
    try testing.expect(compressed_pages > 0);
}

test "PageList cold compression continues after an incompressible page" {
    const testing = std.testing;

    var s = try init(testing.allocator, 80, 24, null);
    defer s.deinit();
    try s.growColdPagesForTest(2);

    const first = s.pages.first.?;
    const second = first.next.?;
    var prng = std.Random.DefaultPrng.init(0x434F_4C44_5041_4745);
    prng.random().bytes(first.page().memory);

    const page_size = s.page_size;
    _ = s.compress(.full);
    const memory = s.memoryStats();
    try testing.expectEqual(@as(usize, 1), memory.compressed_pages);
    try testing.expect(!first.isCompressed());
    try testing.expect(second.isCompressed());
    try testing.expectEqual(
        second.metadata().memory.len,
        memory.decommitted_raw_bytes,
    );
    try testing.expect(memory.encoded_bytes < memory.decommitted_raw_bytes);
    try testing.expectEqual(page_size, s.page_size);

    // Failed resident candidates are deliberately retried on later passes,
    // while the successful page remains compressed and is skipped.
    _ = s.compress(.full);
    try testing.expectEqual(memory, s.memoryStats());
}

test "PageList compression restores through page access" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();

    const node = s.pages.first.?;
    const page = node.page();
    page.dirty = true;
    page.getRowAndCell(3, 2).cell.* = .init('X');

    const expected = try alloc.dupe(u8, page.memory);
    defer alloc.free(expected);
    const memory_ptr = page.memory.ptr;
    const memory_len = page.memory.len;
    const page_size = s.page_size;

    try testing.expect(s.compressPage(node));
    try testing.expect(node.isCompressed());
    try testing.expectEqual(@as(size.CellCountInt, 24), node.rows());
    try testing.expectEqual(@as(size.CellCountInt, 80), node.cols());
    try testing.expectEqual(memory_ptr, node.metadata().memory.ptr);
    try testing.expectEqual(memory_len, node.metadata().memory.len);
    try testing.expectEqual(page_size, s.page_size);

    // Pin access restores the page without changing its retained mapping.
    const page_pin: Pin = .{ .node = node, .x = 3, .y = 2 };
    try testing.expectEqual(
        @as(u21, 'X'),
        page_pin.rowAndCell().cell.content.codepoint,
    );
    try testing.expect(!node.isCompressed());
    try testing.expectEqual(memory_ptr, node.page().memory.ptr);
    try testing.expectEqualSlices(u8, expected, node.page().memory);
    try testing.expect(node.page().dirty);

    // Recompressing exercises reuse of the page-pool scratch item. Page
    // iterator chunks also restore before exposing row memory.
    try testing.expect(s.compressPage(node));
    var page_it = (Pin{ .node = node }).pageIterator(.right_down, null);
    const chunk = page_it.next().?;
    try testing.expectEqual(node.rows(), chunk.rows().len);
    try testing.expect(!node.isCompressed());
    try testing.expectEqualSlices(u8, expected, node.page().memory);

    // Read-only PageList operations restore through the same boundary.
    try testing.expect(s.compressPage(node));
    var cloned = try s.clone(alloc, .{
        .top = .{ .screen = .{} },
    });
    defer cloned.deinit();
    try testing.expect(!node.isCompressed());
    try testing.expectEqual(
        @as(u21, 'X'),
        cloned.pages.first.?.page().getRowAndCell(3, 2).cell.content.codepoint,
    );
}

test "PageList compression uses temporary scratch for oversized pages" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();

    var node = s.pages.first.?;
    while (node.page().memory.len <= std_size) {
        node = try s.increaseCapacity(node, .grapheme_bytes);
    }

    const expected = try alloc.dupe(u8, node.page().memory);
    defer alloc.free(expected);
    const memory_ptr = node.page().memory.ptr;
    const memory_len = node.page().memory.len;
    const page_size = s.page_size;

    try testing.expect(s.compressPage(node));
    try testing.expect(node.isCompressed());
    try testing.expectEqual(page_size, s.page_size);
    try testing.expectEqual(memory_ptr, node.metadata().memory.ptr);
    try testing.expectEqual(memory_len, node.metadata().memory.len);

    try testing.expectEqualSlices(u8, expected, node.page().memory);
    try testing.expect(!node.isCompressed());
    try testing.expectEqual(memory_ptr, node.page().memory.ptr);
}

test "PageList compression leaves incompressible pages resident" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();

    const node = s.pages.first.?;
    const original = try alloc.dupe(u8, node.page().memory);
    defer alloc.free(original);
    defer @memcpy(node.page().memory, original);

    var prng = std.Random.DefaultPrng.init(0x5041_4745_4C49_5354);
    prng.random().bytes(node.page().memory);
    const page_size = s.page_size;

    try testing.expect(!s.compressPage(node));
    try testing.expect(!node.isCompressed());
    try testing.expectEqual(page_size, s.page_size);
}

test "PageList reset discards malformed compressed data" {
    const testing = std.testing;

    var s = try init(testing.allocator, 80, 24, null);
    defer s.deinit();

    const node = s.pages.first.?;
    try testing.expect(s.compressPage(node));
    @memset(node.data.compressed.encoded, 0xFF);

    s.reset();
    try testing.expect(!s.pages.first.?.isCompressed());
    try testing.expectEqual(@as(usize, 1), s.totalPages());
}

test "PageList deinit discards malformed compressed data" {
    const testing = std.testing;

    var s = try init(testing.allocator, 80, 24, null);
    const node = s.pages.first.?;
    try testing.expect(s.compressPage(node));
    @memset(node.data.compressed.encoded, 0xFF);

    s.deinit();
}

test "PageList prune reuses malformed compressed page memory" {
    const testing = std.testing;

    var s = try init(
        testing.allocator,
        80,
        24,
        2 * PagePool.item_size,
    );
    defer s.deinit();

    // Allocate the second page so the first one can be pruned and reused.
    while (s.pages.first == s.pages.last) _ = try s.grow();
    const first = s.pages.first.?;
    try testing.expect(s.compressPage(first));
    @memset(first.data.compressed.encoded, 0xFF);

    var reused = false;
    const growth_limit = @as(usize, s.pages.last.?.capacity().rows) + 1;
    for (0..growth_limit) |_| {
        if (try s.grow()) |new_node| {
            if (new_node == first) {
                reused = true;
                break;
            }
        }
    }

    try testing.expect(reused);
    try testing.expectEqual(first, s.pages.last.?);
    try testing.expect(!first.isCompressed());
    try testing.expectEqual(@as(size.CellCountInt, 1), first.rows());
    first.page().assertIntegrity();
}

test "PageList" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();
    try testing.expect(s.viewport == .active);
    try testing.expect(s.pages.first != null);
    try testing.expectEqual(@as(usize, s.rows), s.totalRows());

    // Initial total rows should be our row count
    try testing.expectEqual(s.rows, s.total_rows);

    // Our viewport pin must be defined. It isn't used until the
    // viewport is a pin but it prevents undefined access on clone.
    try testing.expect(s.viewport_pin.node == s.pages.first.?);

    // Active area should be the top
    try testing.expectEqual(Pin{
        .node = s.pages.first.?,
        .y = 0,
        .x = 0,
    }, s.getTopLeft(.active));

    // Scrollbar should be where we expect it
    try testing.expectEqual(Scrollbar{
        .total = s.rows,
        .offset = 0,
        .len = s.rows,
    }, s.scrollbar());
}

test "PageList init error" {
    // Test every failure point in `init` and ensure that we don't
    // leak memory (testing.allocator verifies) since we're exiting early.
    for (std.meta.tags(init_tw.FailPoint)) |tag| {
        const tw = init_tw;
        defer tw.end(.reset) catch unreachable;
        tw.errorAlways(tag, error.OutOfMemory);
        try std.testing.expectError(
            error.OutOfMemory,
            init(
                std.testing.allocator,
                80,
                24,
                null,
            ),
        );
    }

    // init calls initPages transitively, so let's check that if
    // any failures happen in initPages, we also don't leak memory.
    for (std.meta.tags(initPages_tw.FailPoint)) |tag| {
        const tw = initPages_tw;
        defer tw.end(.reset) catch unreachable;
        tw.errorAlways(tag, error.OutOfMemory);

        const cols: size.CellCountInt = if (tag == .page_buf_std) 80 else std_capacity.maxCols().? + 1;
        try std.testing.expectError(
            error.OutOfMemory,
            init(
                std.testing.allocator,
                cols,
                24,
                null,
            ),
        );
    }

    // Try non-standard pages since they don't go in our pool.
    for ([_]initPages_tw.FailPoint{
        .page_buf_non_std,
    }) |tag| {
        const tw = initPages_tw;
        defer tw.end(.reset) catch unreachable;
        tw.errorAfter(tag, error.OutOfMemory, 1);
        try std.testing.expectError(
            error.OutOfMemory,
            init(
                std.testing.allocator,
                std_capacity.maxCols().? + 1,
                std_capacity.rows + 1,
                null,
            ),
        );
    }
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

    // Initial total rows should be our row count
    try testing.expectEqual(s.rows, s.total_rows);

    // Scrollbar should be where we expect it
    try testing.expectEqual(Scrollbar{
        .total = s.rows,
        .offset = 0,
        .len = s.rows,
    }, s.scrollbar());
}

test "PageList init more than max cols" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Initialize with more columns than we can fit in our standard
    // capacity. This is going to force us to go to a non-standard page
    // immediately.
    var s = try init(
        alloc,
        std_capacity.maxCols().? + 1,
        80,
        null,
    );
    defer s.deinit();
    try testing.expect(s.viewport == .active);
    try testing.expectEqual(@as(usize, s.rows), s.totalRows());

    // We expect a single, non-standard page
    try testing.expect(s.pages.first != null);
    try testing.expect(s.pages.first.?.page().memory.len > std_size);

    // Initial total rows should be our row count
    try testing.expectEqual(s.rows, s.total_rows);

    // Scrollbar should be where we expect it
    try testing.expectEqual(Scrollbar{
        .total = s.rows,
        .offset = 0,
        .len = s.rows,
    }, s.scrollbar());
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
    const page = s.pages.last.?.page();
    var cur_page = s.pages.last.?;
    cur_page.page().pauseIntegrityChecks(true);
    for (0..page.capacity.rows * 5) |_| {
        if (try s.grow()) |new_page| {
            cur_page.page().pauseIntegrityChecks(false);
            cur_page = new_page;
            cur_page.page().pauseIntegrityChecks(true);
        }
    }
    cur_page.page().pauseIntegrityChecks(false);

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
    const page = s.pages.last.?.page();
    var cur_page = s.pages.last.?;
    cur_page.page().pauseIntegrityChecks(true);
    for (0..page.capacity.rows * 2) |_| {
        if (try s.grow()) |new_page| {
            cur_page.page().pauseIntegrityChecks(false);
            cur_page = new_page;
            cur_page.page().pauseIntegrityChecks(true);
        }
    }
    cur_page.page().pauseIntegrityChecks(false);

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

test "PageList pointFromPin rejects overflowing screen coordinate" {
    const testing = std.testing;

    // Use maximum-height metadata-only pages to model a valid scrollback just
    // beyond the u32 coordinate range without allocating their backing cells.
    const page_count = 65_539;
    const rows_per_page = std.math.maxInt(size.CellCountInt);
    const nodes = try testing.allocator.alloc(Node, page_count);
    defer testing.allocator.free(nodes);

    for (nodes, 0..) |*node, i| {
        node.* = .{
            .prev = if (i > 0) &nodes[i - 1] else null,
            .next = if (i + 1 < nodes.len) &nodes[i + 1] else null,
            .data = .{ .resident = undefined },
            .serial = @intCast(i),
            .owned = .heap,
        };
        node.data.resident.size = .{
            .cols = 1,
            .rows = rows_per_page,
        };
    }

    var s: PageList = undefined;
    s.pages = .{
        .first = &nodes[0],
        .last = &nodes[nodes.len - 1],
    };

    try testing.expect(s.pointFromPin(.screen, .{
        .node = &nodes[nodes.len - 1],
        .y = 0,
        .x = 0,
    }) == null);
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

    // Scrollbar should be in the active area
    try testing.expectEqual(Scrollbar{
        .total = s.totalRows(),
        .offset = 10,
        .len = s.rows,
    }, s.scrollbar());
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
            page.page().size.rows = 1;
            page.page().capacity.rows = 1;
        }

        // Avoid integrity check failures
        s.total_rows = s.totalRows();
    }

    // Grow our row and ensure we don't prune pages because we need
    // enough for the active area.
    _ = try s.grow();
    try testing.expectEqual(start_pages + 1, s.totalPages());
}

test "PageList grow prune required with a single page" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Need scrollback > 0 to have a scrollbar to test
    var s = try init(alloc, 80, 24, null);
    defer s.deinit();

    // This block is all test setup. There is nothing required about this
    // behavior during a refactor. This is setting up a scenario that is
    // possible to trigger a bug (#2280).
    {
        // Increase our capacity until our page is larger than the standard size.
        // This is important because it triggers a scenario where our calculated
        // minSize() which is supposed to accommodate 2 pages is no longer true.
        while (true) {
            const layout = Page.layout(s.pages.first.?.capacity());
            if (layout.total_size > std_size) break;
            _ = try s.increaseCapacity(s.pages.first.?, .grapheme_bytes);
        }
        try testing.expect(s.pages.first != null);
        try testing.expect(s.pages.first == s.pages.last);
    }

    // Figure out the remaining number of rows. This is the amount that
    // can be added to the current page before we need to allocate a new
    // page.
    const rem = rem: {
        const page = s.pages.first.?;
        break :rem page.capacity().rows - page.rows();
    };
    for (0..rem) |_| try testing.expect(try s.grow() == null);

    // The next one we add will trigger a new page.
    const new = try s.grow();
    try testing.expect(new != null);
    try testing.expect(new != s.pages.first);

    // Scrollbar should be in the active area
    try testing.expectEqual(Scrollbar{
        .total = s.totalRows(),
        .offset = s.total_rows - s.rows,
        .len = s.rows,
    }, s.scrollbar());
}

test "PageList scrollbar with max_size 0 after grow" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, 0);
    defer s.deinit();

    // Grow some rows (simulates normal terminal output)
    try s.growRows(10);

    const sb = s.scrollbar();

    // With no scrollback (max_size = 0), total should equal rows
    try testing.expectEqual(s.rows, sb.total);

    // With no scrollback, offset should be 0 (nowhere to scroll back to)
    try testing.expectEqual(@as(usize, 0), sb.offset);
}

test "PageList scroll with max_size 0 no history" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, 0);
    defer s.deinit();

    try s.growRows(10);

    // Remember initial viewport position
    const pt_before = s.getCell(.{ .viewport = .{} }).?.screenPoint();

    // Try to scroll backwards into "history" - should be no-op
    s.scroll(.{ .delta_row = -5 });
    try testing.expect(s.viewport == .active);

    // Scroll to top - should also be no-op with no scrollback
    s.scroll(.{ .top = {} });
    const pt_after = s.getCell(.{ .viewport = .{} }).?.screenPoint();
    try testing.expectEqual(pt_before, pt_after);
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

    try testing.expectEqual(Scrollbar{
        .total = s.totalRows(),
        .offset = 0,
        .len = s.rows,
    }, s.scrollbar());

    try s.growRows(10);
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, pt);
    }

    try testing.expectEqual(Scrollbar{
        .total = s.totalRows(),
        .offset = 0,
        .len = s.rows,
    }, s.scrollbar());

    s.scroll(.{ .active = {} });
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 20,
        } }, pt);
    }

    try testing.expectEqual(Scrollbar{
        .total = s.totalRows(),
        .offset = s.total_rows - s.rows,
        .len = s.rows,
    }, s.scrollbar());
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

    try testing.expectEqual(Scrollbar{
        .total = s.totalRows(),
        .offset = s.total_rows - s.rows - 1,
        .len = s.rows,
    }, s.scrollbar());

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

    try testing.expectEqual(Scrollbar{
        .total = s.totalRows(),
        .offset = s.total_rows - s.rows - 11,
        .len = s.rows,
    }, s.scrollbar());

    s.scroll(.{ .delta_row = -1 });

    try testing.expectEqual(Scrollbar{
        .total = s.totalRows(),
        .offset = s.total_rows - s.rows - 12,
        .len = s.rows,
    }, s.scrollbar());
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

    try testing.expectEqual(Scrollbar{
        .total = s.totalRows(),
        .offset = 0,
        .len = s.rows,
    }, s.scrollbar());

    try s.growRows(10);
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, pt);
    }

    try testing.expectEqual(Scrollbar{
        .total = s.totalRows(),
        .offset = 0,
        .len = s.rows,
    }, s.scrollbar());
}

test "PageList scroll minimum row delta" {
    const testing = std.testing;

    var s = try init(testing.allocator, 10, 3, null);
    defer s.deinit();

    // Create one row of history so scrolling all the way back has an
    // observable result.
    try s.growRows(1);
    s.scroll(.{ .delta_row = std.math.minInt(isize) });

    try testing.expectEqual(Viewport.top, s.viewport);
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

    try testing.expectEqual(Scrollbar{
        .total = s.totalRows(),
        .offset = 2,
        .len = s.rows,
    }, s.scrollbar());

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

    try testing.expectEqual(Scrollbar{
        .total = s.totalRows(),
        .offset = 2,
        .len = s.rows,
    }, s.scrollbar());
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

    try testing.expectEqual(Scrollbar{
        .total = s.totalRows(),
        .offset = s.total_rows - s.rows,
        .len = s.rows,
    }, s.scrollbar());
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

    try testing.expectEqual(Scrollbar{
        .total = s.totalRows(),
        .offset = s.total_rows - s.rows,
        .len = s.rows,
    }, s.scrollbar());
}

test "PageList scroll to pin" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();
    try s.growRows(10);

    s.scroll(.{ .pin = s.pin(.{ .screen = .{
        .y = 4,
        .x = 2,
    } }).? });

    try testing.expectEqual(Scrollbar{
        .total = s.totalRows(),
        .offset = 4,
        .len = s.rows,
    }, s.scrollbar());

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 4,
        } }, pt);
    }

    s.scroll(.{ .pin = s.pin(.{ .screen = .{
        .y = 5,
        .x = 2,
    } }).? });

    try testing.expectEqual(Scrollbar{
        .total = s.totalRows(),
        .offset = 5,
        .len = s.rows,
    }, s.scrollbar());

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 5,
        } }, pt);
    }
}

test "PageList scroll to pin in active" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();
    try s.growRows(10);

    s.scroll(.{ .pin = s.pin(.{ .screen = .{
        .y = 30,
        .x = 2,
    } }).? });

    try testing.expectEqual(Scrollbar{
        .total = s.totalRows(),
        .offset = s.total_rows - s.rows,
        .len = s.rows,
    }, s.scrollbar());

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 10,
        } }, pt);
    }
}

test "PageList scroll to pin at top" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();
    try s.growRows(10);

    s.scroll(.{ .pin = s.pin(.{ .screen = .{
        .y = 0,
        .x = 2,
    } }).? });

    try testing.expect(s.viewport == .top);

    try testing.expectEqual(Scrollbar{
        .total = s.totalRows(),
        .offset = 0,
        .len = s.rows,
    }, s.scrollbar());

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, pt);
    }
}

test "PageList scroll to row 0" {
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

    s.scroll(.{ .row = 0 });
    try testing.expect(s.viewport == .top);

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, pt);
    }

    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = 0,
        .len = s.rows,
    }, s.scrollbar());

    try s.growRows(10);
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, pt);
    }

    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = 0,
        .len = s.rows,
    }, s.scrollbar());
}

test "PageList scroll to row in scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();
    try s.growRows(20);

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 20,
        } }, pt);
    }

    s.scroll(.{ .row = 5 });
    try testing.expect(s.viewport == .pin);
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = 5,
        .len = s.rows,
    }, s.scrollbar());

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 5,
        } }, pt);
    }

    try s.growRows(10);
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 5,
        } }, pt);
    }

    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = 5,
        .len = s.rows,
    }, s.scrollbar());
}

test "PageList scroll to row in middle" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();
    try s.growRows(50);

    const total = s.total_rows;
    const midpoint = total / 2;
    s.scroll(.{ .row = midpoint });

    try testing.expect(s.viewport == .pin);
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = midpoint,
        .len = s.rows,
    }, s.scrollbar());

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = @as(size.CellCountInt, @intCast(midpoint)),
        } }, pt);
    }

    try s.growRows(10);
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = @as(size.CellCountInt, @intCast(midpoint)),
        } }, pt);
    }

    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = midpoint,
        .len = s.rows,
    }, s.scrollbar());
}

test "PageList scroll to row at active boundary" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();
    try s.growRows(20);

    const active_start = s.total_rows - s.rows;

    s.scroll(.{ .row = active_start });

    try testing.expect(s.viewport == .active);

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = @as(size.CellCountInt, @intCast(active_start)),
        } }, pt);
    }

    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = s.total_rows - s.rows,
        .len = s.rows,
    }, s.scrollbar());

    try s.growRows(10);

    try testing.expect(s.viewport == .active);

    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = s.total_rows - s.rows,
        .len = s.rows,
    }, s.scrollbar());
}

test "PageList scroll to row beyond active" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();
    try s.growRows(10);

    s.scroll(.{ .row = 1000 });

    try testing.expect(s.viewport == .active);

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 10,
        } }, pt);
    }

    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = s.total_rows - s.rows,
        .len = s.rows,
    }, s.scrollbar());
}

test "PageList scroll to row without scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();

    s.scroll(.{ .row = 5 });

    try testing.expect(s.viewport == .active);

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, pt);
    }

    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = s.total_rows - s.rows,
        .len = s.rows,
    }, s.scrollbar());
}

test "PageList scroll to row then delta" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();
    try s.growRows(30);

    s.scroll(.{ .row = 10 });

    try testing.expect(s.viewport == .pin);

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 10,
        } }, pt);
    }

    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = 10,
        .len = s.rows,
    }, s.scrollbar());

    s.scroll(.{ .delta_row = 5 });

    try testing.expect(s.viewport == .pin);

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 15,
        } }, pt);
    }

    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = 15,
        .len = s.rows,
    }, s.scrollbar());

    s.scroll(.{ .delta_row = -3 });

    try testing.expect(s.viewport == .pin);

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 12,
        } }, pt);
    }

    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = 12,
        .len = s.rows,
    }, s.scrollbar());
}

test "PageList scroll to row with cache fast path down" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();
    try s.growRows(50);

    s.scroll(.{ .row = 10 });

    try testing.expect(s.viewport == .pin);
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = 10,
        .len = s.rows,
    }, s.scrollbar());

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 10,
        } }, pt);
    }

    // Verify cache is populated
    try testing.expect(s.viewport_pin_row_offset != null);
    try testing.expectEqual(@as(usize, 10), s.viewport_pin_row_offset.?);

    // Now scroll to a different row - this should use the fast path
    s.scroll(.{ .row = 20 });

    try testing.expect(s.viewport == .pin);
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = 20,
        .len = s.rows,
    }, s.scrollbar());

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 20,
        } }, pt);
    }

    try s.growRows(10);
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 20,
        } }, pt);
    }

    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = 20,
        .len = s.rows,
    }, s.scrollbar());
}

test "PageList scroll to row with cache fast path up" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();
    try s.growRows(50);

    s.scroll(.{ .row = 30 });

    try testing.expect(s.viewport == .pin);
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = 30,
        .len = s.rows,
    }, s.scrollbar());

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 30,
        } }, pt);
    }

    // Verify cache is populated
    try testing.expect(s.viewport_pin_row_offset != null);
    try testing.expectEqual(@as(usize, 30), s.viewport_pin_row_offset.?);

    // Now scroll up to a different row - this should use the fast path
    s.scroll(.{ .row = 15 });

    try testing.expect(s.viewport == .pin);
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = 15,
        .len = s.rows,
    }, s.scrollbar());

    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 15,
        } }, pt);
    }

    try s.growRows(10);
    {
        const pt = s.getCell(.{ .viewport = .{} }).?.screenPoint();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 15,
        } }, pt);
    }

    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = 15,
        .len = s.rows,
    }, s.scrollbar());
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

test "PageList: jump zero prompts" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, null);
    defer s.deinit();
    try s.growRows(3);
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
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

    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = s.total_rows - s.rows,
        .len = s.rows,
    }, s.scrollbar());
}

test "PageList: jump minimum prompt delta" {
    const testing = std.testing;

    var s = try init(testing.allocator, 10, 3, null);
    defer s.deinit();

    s.scroll(.{ .delta_prompt = std.math.minInt(isize) });
    try testing.expectEqual(Viewport.active, s.viewport);
}

test "Screen: jump back one prompt" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, null);
    defer s.deinit();
    try s.growRows(3);
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
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

        try testing.expectEqual(Scrollbar{
            .total = s.total_rows,
            .offset = 1,
            .len = s.rows,
        }, s.scrollbar());
    }
    {
        s.scroll(.{ .delta_prompt = -1 });
        try testing.expect(s.viewport == .pin);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 1,
        } }, s.pointFromPin(.screen, s.pin(.{ .viewport = .{} }).?).?);

        try testing.expectEqual(Scrollbar{
            .total = s.total_rows,
            .offset = 1,
            .len = s.rows,
        }, s.scrollbar());
    }

    // Jump forward
    {
        s.scroll(.{ .delta_prompt = 1 });
        try testing.expect(s.viewport == .active);
        try testing.expectEqual(Scrollbar{
            .total = s.total_rows,
            .offset = s.total_rows - s.rows,
            .len = s.rows,
        }, s.scrollbar());
    }
    {
        s.scroll(.{ .delta_prompt = 1 });
        try testing.expect(s.viewport == .active);
        try testing.expectEqual(Scrollbar{
            .total = s.total_rows,
            .offset = s.total_rows - s.rows,
            .len = s.rows,
        }, s.scrollbar());
    }
}

test "Screen: jump forward prompt skips multiline continuation" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 3, null);
    defer s.deinit();
    try s.growRows(7);

    // Multiline prompt on rows 1-3.
    {
        const p = s.pin(.{ .screen = .{ .y = 1 } }).?;
        p.rowAndCell().row.semantic_prompt = .prompt;
    }
    {
        const p = s.pin(.{ .screen = .{ .y = 2 } }).?;
        p.rowAndCell().row.semantic_prompt = .prompt_continuation;
    }
    {
        const p = s.pin(.{ .screen = .{ .y = 3 } }).?;
        p.rowAndCell().row.semantic_prompt = .prompt_continuation;
    }

    // Next prompt after command output.
    {
        const p = s.pin(.{ .screen = .{ .y = 6 } }).?;
        p.rowAndCell().row.semantic_prompt = .prompt;
    }

    // Starting at the first prompt line should jump to the next prompt,
    // not to continuation lines.
    s.scroll(.{ .row = 1 });
    s.scroll(.{ .delta_prompt = 1 });
    try testing.expect(s.viewport == .pin);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 0,
        .y = 6,
    } }, s.pointFromPin(.screen, s.pin(.{ .viewport = .{} }).?).?);

    // Starting in the middle of continuation lines should also jump to
    // the next prompt.
    s.scroll(.{ .row = 2 });
    s.scroll(.{ .delta_prompt = 1 });
    try testing.expect(s.viewport == .pin);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 0,
        .y = 6,
    } }, s.pointFromPin(.screen, s.pin(.{ .viewport = .{} }).?).?);
}

test "PageList grow fit in capacity" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();

    // So we know we're using capacity to grow
    const last = s.pages.last.?.page();
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
    const last = s.pages.last.?.page();
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

test "PageList Cell screenPoint supports long scrollback" {
    const testing = std.testing;

    // A modest number of full-size page nodes is enough to exceed the u16
    // row range without allocating any page backing memory. screenPoint only
    // reads the linked metadata while calculating the absolute coordinate.
    const page_count = 307;
    const rows_per_page = std_capacity.rows;
    const nodes = try testing.allocator.alloc(Node, page_count);
    defer testing.allocator.free(nodes);

    for (nodes, 0..) |*node, i| {
        node.* = .{
            .prev = if (i > 0) &nodes[i - 1] else null,
            .next = if (i + 1 < nodes.len) &nodes[i + 1] else null,
            .data = .{ .resident = undefined },
            .serial = @intCast(i),
            .owned = .heap,
        };
        node.data.resident.size = .{
            .cols = 1,
            .rows = rows_per_page,
        };
    }

    const expected_y: u32 = (page_count - 1) * @as(u32, rows_per_page);
    try testing.expect(expected_y > std.math.maxInt(size.CellCountInt));

    const cell: Cell = .{
        .node = &nodes[nodes.len - 1],
        .row = undefined,
        .cell = undefined,
        .row_idx = 0,
        .col_idx = 0,
    };
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 0,
        .y = expected_y,
    } }, cell.screenPoint());
}

test "PageList grow prune scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Use std_size to limit scrollback so pruning is triggered.
    var s = try init(alloc, 80, 24, std_size);
    defer s.deinit();

    // Grow to capacity
    const page1_node = s.pages.last.?;
    const page1 = page1_node.page();
    for (0..page1.capacity.rows - page1.size.rows) |_| {
        try testing.expect(try s.grow() == null);
    }

    // Grow and allocate one more page. Then fill that page up.
    const page2_node = (try s.grow()).?;
    const page2 = page2_node.page();
    for (0..page2.capacity.rows - page2.size.rows) |_| {
        try testing.expect(try s.grow() == null);
    }

    // Get our page size
    const old_page_size = s.page_size;

    // Create a tracked pin in the first page
    const p = try s.trackPin(s.pin(.{ .screen = .{} }).?);
    defer s.untrackPin(p);
    try testing.expect(p.node == s.pages.first.?);

    // Scroll back to create a pinned viewport (not active)
    const pin_y = page1.capacity.rows / 2;
    s.scroll(.{ .pin = s.pin(.{ .screen = .{ .y = pin_y } }).? });
    try testing.expect(s.viewport == .pin);

    // Get the scrollbar state to populate the cache
    const scrollbar_before = s.scrollbar();
    try testing.expectEqual(pin_y, scrollbar_before.offset);

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
    try testing.expect(p.garbage);

    // Verify the viewport offset cache was invalidated. After pruning,
    // the offset should have changed because we removed rows from
    // the beginning.
    {
        const scrollbar_after = s.scrollbar();
        const rows_pruned = page1.capacity.rows;
        const expected_offset = if (pin_y >= rows_pruned)
            pin_y - rows_pruned
        else
            0;
        try testing.expectEqual(expected_offset, scrollbar_after.offset);
    }
}

test "PageList grow prune scrollback with viewport pin not in pruned page" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Use std_size to limit scrollback so pruning is triggered.
    var s = try init(alloc, 80, 24, std_size);
    defer s.deinit();

    // Grow to capacity of first page
    const page1_node = s.pages.last.?;
    const page1 = page1_node.page();
    for (0..page1.capacity.rows - page1.size.rows) |_| {
        try testing.expect(try s.grow() == null);
    }

    // Grow and allocate second page, then fill it up
    const page2_node = (try s.grow()).?;
    const page2 = page2_node.page();
    for (0..page2.capacity.rows - page2.size.rows) |_| {
        try testing.expect(try s.grow() == null);
    }

    // Get our page size
    const old_page_size = s.page_size;

    // Scroll back to create a pinned viewport in page2 (NOT page1)
    // This is the key difference from the previous test - the viewport
    // pin is NOT in the page that will be pruned.
    const pin_y = page1.capacity.rows + 5;
    s.scroll(.{ .pin = s.pin(.{ .screen = .{ .y = pin_y } }).? });
    try testing.expect(s.viewport == .pin);
    try testing.expect(s.viewport_pin.node == page2_node);

    // Get the scrollbar state to populate the cache
    const scrollbar_before = s.scrollbar();
    try testing.expectEqual(pin_y, scrollbar_before.offset);

    // Next grow will trigger pruning of the first page.
    // The viewport_pin.node is page2, not page1, so it won't be moved
    // by the pin update loop, but the cached offset still needs to be
    // invalidated because rows were removed from the beginning.
    const new = (try s.grow()).?;
    try testing.expect(s.pages.last.? == new);
    try testing.expectEqual(s.page_size, old_page_size);

    // Our first should now be page2 (page1 was pruned)
    try testing.expectEqual(page2_node, s.pages.first.?);

    // The viewport pin should still be on page2, unchanged
    try testing.expect(s.viewport_pin.node == page2_node);

    // Verify the viewport offset cache was invalidated/updated.
    // After pruning, the offset should have decreased by the number
    // of rows that were pruned.
    const scrollbar_after = s.scrollbar();
    const rows_pruned = page1.capacity.rows;
    const expected_offset = pin_y - rows_pruned;
    try testing.expectEqual(expected_offset, scrollbar_after.offset);
}

test "PageList eraseRows invalidates viewport offset cache" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();

    // Grow so we take up several pages worth of history
    const page = s.pages.last.?.page();
    {
        var cur_page = s.pages.last.?;
        for (0..page.capacity.rows * 3) |_| {
            if (try s.grow()) |new_page| cur_page = new_page;
        }
    }

    // Scroll back to create a pinned viewport somewhere in the middle
    // of the scrollback
    const pin_y = page.capacity.rows;
    s.scroll(.{ .pin = s.pin(.{ .screen = .{ .y = pin_y } }).? });
    try testing.expect(s.viewport == .pin);
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = pin_y,
        .len = s.rows,
    }, s.scrollbar());

    // Erase some history rows BEFORE the viewport pin.
    // This removes rows from before our pin, which changes its absolute
    // offset from the top, but the cache is not invalidated.
    const rows_to_erase = page.capacity.rows / 2;
    s.eraseHistory(.{ .history = .{ .y = rows_to_erase - 1 } });

    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = pin_y - rows_to_erase,
        .len = s.rows,
    }, s.scrollbar());
}

test "PageList eraseRow invalidates viewport offset cache" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();

    // Grow so we take up several pages worth of history
    const page = s.pages.last.?.page();
    {
        var cur_page = s.pages.last.?;
        for (0..page.capacity.rows * 3) |_| {
            if (try s.grow()) |new_page| cur_page = new_page;
        }
    }

    // Scroll back to create a pinned viewport somewhere in the middle
    // of the scrollback
    const pin_y = page.capacity.rows;
    s.scroll(.{ .pin = s.pin(.{ .screen = .{ .y = pin_y } }).? });
    try testing.expect(s.viewport == .pin);
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = pin_y,
        .len = s.rows,
    }, s.scrollbar());

    // Erase a single row from the history BEFORE the viewport pin.
    // This removes one row from before our pin, which changes its absolute
    // offset from the top by 1, but the cache is not invalidated.
    try s.eraseRow(.{ .history = .{ .y = 0 } });

    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = pin_y - 1,
        .len = s.rows,
    }, s.scrollbar());
}

test "PageList eraseRowBounded invalidates viewport offset cache" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();

    // Grow so we take up several pages worth of history
    const page = s.pages.last.?.page();
    {
        var cur_page = s.pages.last.?;
        for (0..page.capacity.rows * 3) |_| {
            if (try s.grow()) |new_page| cur_page = new_page;
        }
    }

    // Scroll back to create a pinned viewport somewhere in the middle
    // of the scrollback
    const pin_y: u16 = 4;
    s.scroll(.{ .pin = s.pin(.{ .screen = .{ .y = pin_y } }).? });
    try testing.expect(s.viewport == .pin);
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = pin_y,
        .len = s.rows,
    }, s.scrollbar());

    // Erase a row from the history BEFORE the viewport pin with a bounded
    // shift. This removes one row from before our pin, which changes its
    // absolute offset from the top by 1, but the cache is not invalidated.
    try s.eraseRowBounded(.{ .history = .{ .y = 0 } }, 10);

    // Verify the scrollbar reflects the change (offset decreased by 1)
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = pin_y - 1,
        .len = s.rows,
    }, s.scrollbar());
}

test "PageList row erasure renews affected page generations" {
    const testing = std.testing;

    var s = try init(testing.allocator, 80, 24, null);
    defer s.deinit();
    while (s.totalPages() < 2) _ = try s.grow();

    const first = s.pages.first.?;
    const second = first.next.?;
    var first_serial = first.serial;
    var second_serial = second.serial;
    var activity = s.page_compression.activity_serial;

    try s.eraseRow(.{ .history = .{ .y = 0 } });
    try testing.expect(!s.nodeIsValid(first, first_serial));
    try testing.expect(!s.nodeIsValid(second, second_serial));
    try testing.expect(activity != s.page_compression.activity_serial);

    first_serial = first.serial;
    second_serial = second.serial;
    activity = s.page_compression.activity_serial;
    try s.eraseRowBounded(
        .{ .history = .{ .y = 0 } },
        first.rows() + 1,
    );
    try testing.expect(!s.nodeIsValid(first, first_serial));
    try testing.expect(!s.nodeIsValid(second, second_serial));
    try testing.expect(activity != s.page_compression.activity_serial);
}

test "PageList trailing row truncation renews page generation" {
    const testing = std.testing;

    var s = try init(testing.allocator, 80, 24, null);
    defer s.deinit();

    const node = s.pages.last.?;
    const old_serial = node.serial;
    const trimmed = s.trimTrailingBlankRows(1);
    s.total_rows -= trimmed;
    try testing.expectEqual(@as(size.CellCountInt, 1), trimmed);
    try testing.expect(!s.nodeIsValid(node, old_serial));

    _ = try s.grow();
    try s.expectLivePageSerialsValidForTest();
}

test "PageList eraseRowBounded multi-page invalidates viewport offset cache" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();

    // Grow so we take up several pages worth of history
    const page = s.pages.last.?.page();
    {
        var cur_page = s.pages.last.?;
        for (0..page.capacity.rows * 3) |_| {
            if (try s.grow()) |new_page| cur_page = new_page;
        }
    }

    // Scroll back to create a pinned viewport somewhere in the middle
    // of the scrollback, after the first page
    const pin_y = page.capacity.rows + 1;
    s.scroll(.{ .pin = s.pin(.{ .screen = .{ .y = pin_y } }).? });
    try testing.expect(s.viewport == .pin);
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = pin_y,
        .len = s.rows,
    }, s.scrollbar());

    // Erase a row from the beginning of history with a limit that spans
    // across multiple pages. This ensures we hit the code path where
    // eraseRowBounded finds the limit boundary in a subsequent page.
    const limit = page.capacity.rows + 10;
    try s.eraseRowBounded(.{ .history = .{ .y = 0 } }, limit);

    // Verify the scrollbar reflects the change (offset decreased by 1)
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = pin_y - 1,
        .len = s.rows,
    }, s.scrollbar());
}

test "PageList eraseRowBounded full page shift invalidates viewport offset cache" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();

    // Grow so we take up several pages worth of history
    const page = s.pages.last.?.page();
    {
        var cur_page = s.pages.last.?;
        for (0..page.capacity.rows * 4) |_| {
            if (try s.grow()) |new_page| cur_page = new_page;
        }
    }

    // Scroll back to create a pinned viewport somewhere well beyond
    // the first two pages
    const pin_y = 5;
    s.scroll(.{ .pin = s.pin(.{ .screen = .{ .y = pin_y } }).? });
    try testing.expect(s.viewport == .pin);
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = pin_y,
        .len = s.rows,
    }, s.scrollbar());

    // Erase a row from the beginning of history with a limit that is
    // larger than multiple full pages. This ensures we hit the code path
    // where eraseRowBounded continues looping through entire pages,
    // rotating all rows in each page until it reaches the limit or
    // runs out of pages.
    const limit = page.capacity.rows * 2 + 10;
    try s.eraseRowBounded(.{ .history = .{ .y = 0 } }, limit);

    // Verify the scrollbar reflects the change (offset decreased by 1)
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = pin_y - 1,
        .len = s.rows,
    }, s.scrollbar());
}

test "PageList eraseRowBounded exhausts pages invalidates viewport offset cache" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();

    // Grow so we take up several pages worth of history
    const page = s.pages.last.?.page();
    {
        var cur_page = s.pages.last.?;
        for (0..page.capacity.rows * 3) |_| {
            if (try s.grow()) |new_page| cur_page = new_page;
        }
    }

    // Our total rows should include history
    const total_rows_before = s.totalRows();
    try testing.expect(total_rows_before > s.rows);

    // Scroll back to create a pinned viewport somewhere in the history,
    // well after the erase will complete
    const pin_y = page.capacity.rows * 2 + 10;
    s.scroll(.{ .pin = s.pin(.{ .screen = .{ .y = pin_y } }).? });
    try testing.expect(s.viewport == .pin);
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = pin_y,
        .len = s.rows,
    }, s.scrollbar());

    // Erase a row from the beginning of history with a limit that is
    // LARGER than all remaining pages combined. This ensures we exhaust
    // all pages in the while loop and reach the cleanup code after the loop.
    const limit = total_rows_before * 2;
    try s.eraseRowBounded(.{ .history = .{ .y = 0 } }, limit);

    // Verify the scrollbar reflects the change (offset decreased by 1)
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = pin_y - 1,
        .len = s.rows,
    }, s.scrollbar());
}

test "PageList increaseCapacity to increase styles" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 2, 2, 0);
    defer s.deinit();

    const original_styles_cap = s.pages.first.?.capacity().styles;

    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

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
    _ = try s.increaseCapacity(s.pages.first.?, .styles);

    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

        // Verify capacity doubled
        try testing.expectEqual(
            original_styles_cap * 2,
            page.capacity.styles,
        );

        // Verify data preserved
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

test "PageList increaseCapacity to increase graphemes" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 2, 2, 0);
    defer s.deinit();

    const original_cap = s.pages.first.?.capacity().grapheme_bytes;

    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

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

    _ = try s.increaseCapacity(s.pages.first.?, .grapheme_bytes);

    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

        try testing.expectEqual(original_cap * 2, page.capacity.grapheme_bytes);

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

test "PageList increaseCapacity to increase hyperlinks" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 2, 2, 0);
    defer s.deinit();

    const original_cap = s.pages.first.?.capacity().hyperlink_bytes;

    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

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

    _ = try s.increaseCapacity(s.pages.first.?, .hyperlink_bytes);

    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

        try testing.expectEqual(original_cap * 2, page.capacity.hyperlink_bytes);

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

test "PageList increaseCapacity to increase string_bytes" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 2, 2, 0);
    defer s.deinit();

    const original_cap = s.pages.first.?.capacity().string_bytes;

    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

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

    _ = try s.increaseCapacity(s.pages.first.?, .string_bytes);

    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

        try testing.expectEqual(original_cap * 2, page.capacity.string_bytes);

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

test "PageList increaseCapacity tracked pins" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 2, 2, 0);
    defer s.deinit();

    // Create a tracked pin on the first page
    const tracked = try s.trackPin(s.pin(.{ .active = .{ .x = 1, .y = 1 } }).?);
    defer s.untrackPin(tracked);

    const old_node = s.pages.first.?;
    try testing.expectEqual(old_node, tracked.node);

    // Increase capacity
    const new_node = try s.increaseCapacity(s.pages.first.?, .styles);

    // Pin should now point to the new node
    try testing.expectEqual(new_node, tracked.node);
    try testing.expectEqual(@as(size.CellCountInt, 1), tracked.x);
    try testing.expectEqual(@as(size.CellCountInt, 1), tracked.y);
}

test "PageList increaseCapacity returns OutOfSpace at max capacity" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 2, 2, 0);
    defer s.deinit();

    // Keep increasing styles capacity until we get OutOfSpace
    const max_styles = std.math.maxInt(size.StyleCountInt);
    while (true) {
        _ = s.increaseCapacity(
            s.pages.first.?,
            .styles,
        ) catch |err| {
            // Before OutOfSpace, we should have reached maxInt
            try testing.expectEqual(error.OutOfSpace, err);
            try testing.expectEqual(max_styles, s.pages.first.?.capacity().styles);
            break;
        };
    }
}

test "PageList increaseCapacity after col shrink" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 2, 0);
    defer s.deinit();

    // Shrink columns
    try s.resize(.{ .cols = 5, .reflow = false });
    try testing.expectEqual(5, s.cols);

    {
        const page = s.pages.first.?.page();
        try testing.expectEqual(5, page.size.cols);
        try testing.expect(page.capacity.cols >= 10);
    }

    // Increase capacity
    _ = try s.increaseCapacity(s.pages.first.?, .styles);

    {
        const page = s.pages.first.?.page();
        // size.cols should still be 5, not reverted to capacity.cols
        try testing.expectEqual(5, page.size.cols);
        try testing.expectEqual(5, s.cols);
    }
}

test "PageList increaseCapacity multi-page" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();

    // Grow to create a second page
    const page1_node = s.pages.last.?;
    page1_node.page().pauseIntegrityChecks(true);
    for (0..page1_node.capacity().rows - page1_node.rows()) |_| {
        try testing.expect(try s.grow() == null);
    }
    page1_node.page().pauseIntegrityChecks(false);
    try testing.expect(try s.grow() != null);

    // Now we have two pages
    try testing.expect(s.pages.first != s.pages.last);
    const page2_node = s.pages.last.?;

    const page1_styles_cap = s.pages.first.?.capacity().styles;
    const page2_styles_cap = page2_node.capacity().styles;

    // Increase capacity on the first page only
    _ = try s.increaseCapacity(s.pages.first.?, .styles);

    // First page capacity should be doubled
    try testing.expectEqual(
        page1_styles_cap * 2,
        s.pages.first.?.capacity().styles,
    );

    // Second page should be unchanged
    try testing.expectEqual(
        page2_styles_cap,
        s.pages.last.?.capacity().styles,
    );
}

test "PageList increaseCapacity preserves dirty flag" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 2, 4, 0);
    defer s.deinit();

    // Set page dirty flag and mark some rows as dirty
    const page = s.pages.first.?.page();
    page.dirty = true;

    const rows = page.rows.ptr(page.memory);
    rows[0].dirty = true;
    rows[1].dirty = false;
    rows[2].dirty = true;
    rows[3].dirty = false;

    // Increase capacity
    const new_node = try s.increaseCapacity(s.pages.first.?, .styles);

    // The page dirty flag should be preserved
    try testing.expect(new_node.page().dirty);

    // Row dirty flags should be preserved
    const new_rows = new_node.page().rows.ptr(new_node.page().memory);
    try testing.expect(new_rows[0].dirty);
    try testing.expect(!new_rows[1].dirty);
    try testing.expect(new_rows[2].dirty);
    try testing.expect(!new_rows[3].dirty);
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
    const page1 = page1_node.page();
    page1_node.page().pauseIntegrityChecks(true);
    for (0..page1.capacity.rows - page1.size.rows) |_| {
        try testing.expect(try s.grow() == null);
    }
    page1_node.page().pauseIntegrityChecks(false);
    try testing.expect(try s.grow() != null);

    // Iterate the active area
    var it = s.pageIterator(.right_down, .{ .active = .{} }, null);
    {
        const chunk = it.next().?;
        try testing.expect(chunk.node == s.pages.first.?);
        const start = chunk.node.rows() - s.rows + 1;
        try testing.expectEqual(start, chunk.start);
        try testing.expectEqual(chunk.node.rows(), chunk.end);
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
    const page1 = page1_node.page();
    page1_node.page().pauseIntegrityChecks(true);
    for (0..page1.capacity.rows - page1.size.rows) |_| {
        try testing.expect(try s.grow() == null);
    }
    page1_node.page().pauseIntegrityChecks(false);
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
    const page1 = page1_node.page();
    page1_node.page().pauseIntegrityChecks(true);
    for (0..page1.capacity.rows - page1.size.rows) |_| {
        try testing.expect(try s.grow() == null);
    }
    page1_node.page().pauseIntegrityChecks(false);
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
        const start = chunk.node.rows() - s.rows + 1;
        try testing.expectEqual(start, chunk.start);
        try testing.expectEqual(chunk.node.rows(), chunk.end);
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
    const page1 = page1_node.page();
    page1_node.page().pauseIntegrityChecks(true);
    for (0..page1.capacity.rows - page1.size.rows) |_| {
        try testing.expect(try s.grow() == null);
    }
    page1_node.page().pauseIntegrityChecks(false);
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

test "PageList PageIterator reverse count includes row zero" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 2, 2, null);
    defer s.deinit();

    var it: PageIterator = .{
        .row = s.getTopLeft(.screen),
        .limit = .{ .count = 1 },
        .direction = .left_up,
    };
    const chunk = it.next().?;
    try testing.expectEqual(@as(size.CellCountInt, 0), chunk.start);
    try testing.expectEqual(@as(size.CellCountInt, 1), chunk.end);
    try testing.expect(it.next() == null);
}

test "PageList PageIterator count crosses page boundaries" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();

    const first = s.pages.first.?;
    first.page().pauseIntegrityChecks(true);
    while (first.rows() < first.capacity().rows) _ = try s.grow();
    first.page().pauseIntegrityChecks(false);
    const second = (try s.grow()).?;

    var down: PageIterator = .{
        .row = .{ .node = first, .y = first.rows() - 1 },
        .limit = .{ .count = 2 },
        .direction = .right_down,
    };
    {
        const chunk = down.next().?;
        try testing.expectEqual(first, chunk.node);
        try testing.expectEqual(first.rows() - 1, chunk.start);
        try testing.expectEqual(first.rows(), chunk.end);
    }
    {
        const chunk = down.next().?;
        try testing.expectEqual(second, chunk.node);
        try testing.expectEqual(@as(size.CellCountInt, 0), chunk.start);
        try testing.expectEqual(@as(size.CellCountInt, 1), chunk.end);
    }
    try testing.expect(down.next() == null);

    var up: PageIterator = .{
        .row = .{ .node = second },
        .limit = .{ .count = 2 },
        .direction = .left_up,
    };
    {
        const chunk = up.next().?;
        try testing.expectEqual(second, chunk.node);
        try testing.expectEqual(@as(size.CellCountInt, 0), chunk.start);
        try testing.expectEqual(@as(size.CellCountInt, 1), chunk.end);
    }
    {
        const chunk = up.next().?;
        try testing.expectEqual(first, chunk.node);
        try testing.expectEqual(first.rows() - 1, chunk.start);
        try testing.expectEqual(first.rows(), chunk.end);
    }
    try testing.expect(up.next() == null);
}

test "PageList cellIterator" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 2, 2, 0);
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
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
    const page = s.pages.first.?.page();
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

test "PageList promptIterator left_up" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 2, 20, 0);
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    // Normal prompt
    {
        const rac = page.getRowAndCell(0, 3);
        rac.row.semantic_prompt = .prompt;
    }
    // Continuation
    {
        const rac = page.getRowAndCell(0, 6);
        rac.row.semantic_prompt = .prompt;
    }
    {
        const rac = page.getRowAndCell(0, 7);
        rac.row.semantic_prompt = .prompt_continuation;
    }
    {
        const rac = page.getRowAndCell(0, 8);
        rac.row.semantic_prompt = .prompt_continuation;
    }
    // Broken continuation that has non-prompts in between
    {
        const rac = page.getRowAndCell(0, 12);
        rac.row.semantic_prompt = .prompt_continuation;
    }

    var it = s.promptIterator(.left_up, .{ .screen = .{} }, null);
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 12,
        } }, s.pointFromPin(.screen, p).?);
    }
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 6,
        } }, s.pointFromPin(.screen, p).?);
    }
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 3,
        } }, s.pointFromPin(.screen, p).?);
    }
    try testing.expect(it.next() == null);
}

test "PageList promptIterator right_down" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 2, 20, 0);
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();
    // Normal prompt
    {
        const rac = page.getRowAndCell(0, 3);
        rac.row.semantic_prompt = .prompt;
    }
    // Continuation (prompt on row 6, continuation on rows 7-8)
    {
        const rac = page.getRowAndCell(0, 6);
        rac.row.semantic_prompt = .prompt;
    }
    {
        const rac = page.getRowAndCell(0, 7);
        rac.row.semantic_prompt = .prompt_continuation;
    }
    {
        const rac = page.getRowAndCell(0, 8);
        rac.row.semantic_prompt = .prompt_continuation;
    }
    // Broken continuation that has non-prompts in between (orphaned continuation at row 12)
    {
        const rac = page.getRowAndCell(0, 12);
        rac.row.semantic_prompt = .prompt_continuation;
    }

    var it = s.promptIterator(.right_down, .{ .screen = .{} }, null);
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 3,
        } }, s.pointFromPin(.screen, p).?);
    }
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 6,
        } }, s.pointFromPin(.screen, p).?);
    }
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 12,
        } }, s.pointFromPin(.screen, p).?);
    }
    try testing.expect(it.next() == null);
}

test "PageList promptIterator right_down continuation at start" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 2, 20, 0);
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Prompt continuation at row 0 (no prior rows - simulates trimmed scrollback)
    {
        const rac = page.getRowAndCell(0, 0);
        rac.row.semantic_prompt = .prompt_continuation;
    }
    {
        const rac = page.getRowAndCell(0, 1);
        rac.row.semantic_prompt = .prompt_continuation;
    }
    // Normal prompt later
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;
    }

    var it = s.promptIterator(.right_down, .{ .screen = .{} }, null);
    {
        // Should return the first continuation line since there's no prior prompt
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 0,
        } }, s.pointFromPin(.screen, p).?);
    }
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 5,
        } }, s.pointFromPin(.screen, p).?);
    }
    try testing.expect(it.next() == null);
}

test "PageList promptIterator right_down with prompt before continuation" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 2, 20, 0);
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Prompt on row 2, continuation on rows 3-4
    // Starting iteration from row 3 should still find the prompt at row 2
    {
        const rac = page.getRowAndCell(0, 2);
        rac.row.semantic_prompt = .prompt;
    }
    {
        const rac = page.getRowAndCell(0, 3);
        rac.row.semantic_prompt = .prompt_continuation;
    }
    {
        const rac = page.getRowAndCell(0, 4);
        rac.row.semantic_prompt = .prompt_continuation;
    }

    // Start iteration from row 3 (middle of the continuation)
    // Since we start on a continuation line, we treat it as the prompt start
    // (handles case where scrollback pruned the actual prompt)
    var it = s.promptIterator(.right_down, .{ .screen = .{ .y = 3 } }, null);
    {
        const p = it.next().?;
        // Returns row 3 since that's the first prompt-related line we encounter
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 3,
        } }, s.pointFromPin(.screen, p).?);
    }
    try testing.expect(it.next() == null);
}

test "PageList promptIterator right_down limit inclusive" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 2, 20, 0);
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Prompt on row 5
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;
    }
    // Prompt on row 10
    {
        const rac = page.getRowAndCell(0, 10);
        rac.row.semantic_prompt = .prompt;
    }

    // Iterate with limit at row 5 (the prompt row) - should include it
    var it = s.promptIterator(.right_down, .{ .screen = .{} }, .{ .screen = .{ .y = 5 } });
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 5,
        } }, s.pointFromPin(.screen, p).?);
    }
    try testing.expect(it.next() == null);
}

test "PageList promptIterator left_up limit inclusive" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 2, 20, 0);
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Prompt on row 5
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;
    }
    // Prompt on row 10
    {
        const rac = page.getRowAndCell(0, 10);
        rac.row.semantic_prompt = .prompt;
    }

    // Iterate with limit at row 10 (the prompt row) - should include it
    // tl_pt is the limit (upper bound), bl_pt is the start point for left_up
    var it = s.promptIterator(.left_up, .{ .screen = .{ .y = 10 } }, .{ .screen = .{ .y = 15 } });
    {
        const p = it.next().?;
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 0,
            .y = 10,
        } }, s.pointFromPin(.screen, p).?);
    }
    try testing.expect(it.next() == null);
}

test "PageList highlightSemanticContent prompt" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 20, 0);
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Prompt on row 5
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;

        // Start the prompt for the first 5 cols
        for (0..5) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 'A' },
                .semantic_content = .prompt,
            };
        }

        // Next 3 let's make input
        for (5..8) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 'B' },
                .semantic_content = .input,
            };
        }
    }
    // Prompt on row 10
    {
        const rac = page.getRowAndCell(0, 10);
        rac.row.semantic_prompt = .prompt;
    }

    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 2, .y = 5 } }).?,
        .prompt,
    ).?;
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 0,
        .y = 5,
    } }, s.pointFromPin(.screen, hl.start).?);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 7,
        .y = 5,
    } }, s.pointFromPin(.screen, hl.end).?);
}

test "PageList highlightSemanticContent prompt with output" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 20, 0);
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Prompt on row 5
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;

        // First 3 cols are prompt
        for (0..3) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = '$' },
                .semantic_content = .prompt,
            };
        }

        // Next 4 are input
        for (3..7) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 'l' },
                .semantic_content = .input,
            };
        }

        // Rest is output (shouldn't be included in prompt highlight)
        for (7..10) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 'o' },
                .semantic_content = .output,
            };
        }
    }
    // Prompt on row 10
    {
        const rac = page.getRowAndCell(0, 10);
        rac.row.semantic_prompt = .prompt;
    }

    // Highlighting from prompt should include prompt and input, but stop at output
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 0, .y = 5 } }).?,
        .prompt,
    ).?;
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 0,
        .y = 5,
    } }, s.pointFromPin(.screen, hl.start).?);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 6,
        .y = 5,
    } }, s.pointFromPin(.screen, hl.end).?);
}

test "PageList highlightSemanticContent prompt multiline" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 20, 0);
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Prompt starts on row 5
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;

        // First row is all prompt
        for (0..10) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = '$' },
                .semantic_content = .prompt,
            };
        }
    }
    // Row 6 continues with input
    {
        for (0..5) |x| {
            const cell = page.getRowAndCell(x, 6).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 'c' },
                .semantic_content = .input,
            };
        }
    }
    // Prompt on row 10
    {
        const rac = page.getRowAndCell(0, 10);
        rac.row.semantic_prompt = .prompt;
    }

    // Highlighting should span both rows
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 2, .y = 5 } }).?,
        .prompt,
    ).?;
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 0,
        .y = 5,
    } }, s.pointFromPin(.screen, hl.start).?);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 4,
        .y = 6,
    } }, s.pointFromPin(.screen, hl.end).?);
}

test "PageList highlightSemanticContent prompt only" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 20, 0);
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Prompt on row 5 with only prompt content (no input)
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;

        for (0..5) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = '$' },
                .semantic_content = .prompt,
            };
        }
    }
    // Prompt on row 10
    {
        const rac = page.getRowAndCell(0, 10);
        rac.row.semantic_prompt = .prompt;
    }

    // Highlighting should only include the prompt cells
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 0, .y = 5 } }).?,
        .prompt,
    ).?;
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 0,
        .y = 5,
    } }, s.pointFromPin(.screen, hl.start).?);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 4,
        .y = 5,
    } }, s.pointFromPin(.screen, hl.end).?);
}

test "PageList highlightSemanticContent prompt to end of screen" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 20, 0);
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Single prompt on row 15, no following prompt
    {
        const rac = page.getRowAndCell(0, 15);
        rac.row.semantic_prompt = .prompt;

        for (0..3) |x| {
            const cell = page.getRowAndCell(x, 15).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = '$' },
                .semantic_content = .prompt,
            };
        }

        for (3..8) |x| {
            const cell = page.getRowAndCell(x, 15).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 'c' },
                .semantic_content = .input,
            };
        }
    }

    // Highlighting should include prompt and input up to column 7
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 0, .y = 15 } }).?,
        .prompt,
    ).?;
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 0,
        .y = 15,
    } }, s.pointFromPin(.screen, hl.start).?);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 7,
        .y = 15,
    } }, s.pointFromPin(.screen, hl.end).?);
}

test "PageList highlightSemanticContent input basic" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 20, 0);
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Prompt on row 5
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;

        // First 3 cols are prompt
        for (0..3) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = '$' },
                .semantic_content = .prompt,
            };
        }

        // Next 5 are input
        for (3..8) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 'l' },
                .semantic_content = .input,
            };
        }
    }
    // Prompt on row 10
    {
        const rac = page.getRowAndCell(0, 10);
        rac.row.semantic_prompt = .prompt;
    }

    // Highlighting input should only include input cells
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 0, .y = 5 } }).?,
        .input,
    ).?;
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 3,
        .y = 5,
    } }, s.pointFromPin(.screen, hl.start).?);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 7,
        .y = 5,
    } }, s.pointFromPin(.screen, hl.end).?);
}

test "PageList highlightSemanticContent input with output" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 20, 0);
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Prompt on row 5
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;

        // First 2 cols are prompt
        for (0..2) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = '$' },
                .semantic_content = .prompt,
            };
        }

        // Next 3 are input
        for (2..5) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 'c' },
                .semantic_content = .input,
            };
        }

        // Rest is output
        for (5..10) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 'o' },
                .semantic_content = .output,
            };
        }
    }
    // Prompt on row 10
    {
        const rac = page.getRowAndCell(0, 10);
        rac.row.semantic_prompt = .prompt;
    }

    // Highlighting input should stop at output
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 0, .y = 5 } }).?,
        .input,
    ).?;
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 2,
        .y = 5,
    } }, s.pointFromPin(.screen, hl.start).?);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 4,
        .y = 5,
    } }, s.pointFromPin(.screen, hl.end).?);
}

test "PageList highlightSemanticContent input multiline with continuation" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 20, 0);
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Prompt on row 5
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;

        // First 2 cols are prompt
        for (0..2) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = '$' },
                .semantic_content = .prompt,
            };
        }

        // Rest is input
        for (2..10) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 'c' },
                .semantic_content = .input,
            };
        }
    }
    // Row 6 has continuation prompt then more input
    {
        // Continuation prompt
        for (0..2) |x| {
            const cell = page.getRowAndCell(x, 6).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = '>' },
                .semantic_content = .prompt,
            };
        }

        // More input
        for (2..6) |x| {
            const cell = page.getRowAndCell(x, 6).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 'd' },
                .semantic_content = .input,
            };
        }
    }
    // Prompt on row 10
    {
        const rac = page.getRowAndCell(0, 10);
        rac.row.semantic_prompt = .prompt;
    }

    // Highlighting input should span both rows, skipping continuation prompts
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 0, .y = 5 } }).?,
        .input,
    ).?;
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 2,
        .y = 5,
    } }, s.pointFromPin(.screen, hl.start).?);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 5,
        .y = 6,
    } }, s.pointFromPin(.screen, hl.end).?);
}

test "PageList highlightSemanticContent input no input returns null" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 20, 0);
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Prompt on row 5 with only prompt, then immediately output
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;

        // First 3 cols are prompt
        for (0..3) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = '$' },
                .semantic_content = .prompt,
            };
        }

        // Rest is output (no input!)
        for (3..10) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 'o' },
                .semantic_content = .output,
            };
        }
    }
    // Prompt on row 10
    {
        const rac = page.getRowAndCell(0, 10);
        rac.row.semantic_prompt = .prompt;
    }

    // Highlighting input should return null when there's no input
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 0, .y = 5 } }).?,
        .input,
    );
    try testing.expect(hl == null);
}

test "PageList highlightSemanticContent input to end of screen" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 20, 0);
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Single prompt on row 15, no following prompt
    {
        const rac = page.getRowAndCell(0, 15);
        rac.row.semantic_prompt = .prompt;

        for (0..2) |x| {
            const cell = page.getRowAndCell(x, 15).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = '$' },
                .semantic_content = .prompt,
            };
        }

        for (2..7) |x| {
            const cell = page.getRowAndCell(x, 15).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 'c' },
                .semantic_content = .input,
            };
        }
    }

    // Highlighting input with no following prompt
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 0, .y = 15 } }).?,
        .input,
    ).?;
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 2,
        .y = 15,
    } }, s.pointFromPin(.screen, hl.start).?);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 6,
        .y = 15,
    } }, s.pointFromPin(.screen, hl.end).?);
}

test "PageList highlightSemanticContent input prompt only returns null" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 20, 0);
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Prompt on row 5 with only prompt content, no input or output
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;

        // All cells are prompt
        for (0..10) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = '$' },
                .semantic_content = .prompt,
            };
        }
    }
    // Mark rows 6-9 as prompt to ensure no input before next prompt
    {
        for (6..10) |y| {
            for (0..10) |x| {
                const cell = page.getRowAndCell(x, y).cell;
                cell.semantic_content = .prompt;
            }
        }
    }
    // Prompt on row 10
    {
        const rac = page.getRowAndCell(0, 10);
        rac.row.semantic_prompt = .prompt;
    }

    // Highlighting input should return null when there's only prompts
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 0, .y = 5 } }).?,
        .input,
    );
    try testing.expect(hl == null);
}

test "PageList highlightSemanticContent output basic" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 20, 0);
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Prompt on row 5
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;

        // First 2 cols are prompt
        for (0..2) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = '$' },
                .semantic_content = .prompt,
            };
        }

        // Next 3 are input
        for (2..5) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 'l' },
                .semantic_content = .input,
            };
        }

        // Cols 5-7 are output
        for (5..8) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 'o' },
                .semantic_content = .output,
            };
        }

        // Mark remaining cells as prompt to bound the output
        for (8..10) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.semantic_content = .prompt;
        }
    }
    // Prompt on row 10
    {
        const rac = page.getRowAndCell(0, 10);
        rac.row.semantic_prompt = .prompt;
    }

    // Highlighting output should only include output cells
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 0, .y = 5 } }).?,
        .output,
    ).?;
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 5,
        .y = 5,
    } }, s.pointFromPin(.screen, hl.start).?);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 7,
        .y = 5,
    } }, s.pointFromPin(.screen, hl.end).?);
}

test "PageList highlightSemanticContent output multiline" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 20, 0);
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Prompt on row 5
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;

        // First 2 cols are prompt
        for (0..2) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = '$' },
                .semantic_content = .prompt,
            };
        }

        // Next 2 are input
        for (2..4) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 'l' },
                .semantic_content = .input,
            };
        }

        // Rest of row 5 is output
        for (4..10) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 'o' },
                .semantic_content = .output,
            };
        }
    }
    // Row 6 is all output
    {
        for (0..10) |x| {
            const cell = page.getRowAndCell(x, 6).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 'o' },
                .semantic_content = .output,
            };
        }
    }
    // Row 7 has partial output then input to bound it
    {
        for (0..5) |x| {
            const cell = page.getRowAndCell(x, 7).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 'o' },
                .semantic_content = .output,
            };
        }
        for (5..10) |x| {
            const cell = page.getRowAndCell(x, 7).cell;
            cell.semantic_content = .input;
        }
    }
    // Prompt on row 10
    {
        const rac = page.getRowAndCell(0, 10);
        rac.row.semantic_prompt = .prompt;
    }

    // Highlighting output should span multiple rows
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 0, .y = 5 } }).?,
        .output,
    ).?;
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 4,
        .y = 5,
    } }, s.pointFromPin(.screen, hl.start).?);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 4,
        .y = 7,
    } }, s.pointFromPin(.screen, hl.end).?);
}

test "PageList highlightSemanticContent output stops at next prompt" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 20, 0);
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Prompt on row 5
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;

        // First 2 cols are prompt
        for (0..2) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = '$' },
                .semantic_content = .prompt,
            };
        }

        // Next 2 are input
        for (2..4) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 'l' },
                .semantic_content = .input,
            };
        }

        // Rest is output
        for (4..10) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 'o' },
                .semantic_content = .output,
            };
        }
    }
    // Row 6 has output then prompt starts
    {
        for (0..3) |x| {
            const cell = page.getRowAndCell(x, 6).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 'o' },
                .semantic_content = .output,
            };
        }
        // Next prompt marker on same row
        for (3..6) |x| {
            const cell = page.getRowAndCell(x, 6).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = '$' },
                .semantic_content = .prompt,
            };
        }
    }
    // Prompt on row 10
    {
        const rac = page.getRowAndCell(0, 10);
        rac.row.semantic_prompt = .prompt;
    }

    // Highlighting output should stop before prompt/input
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 0, .y = 5 } }).?,
        .output,
    ).?;
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 4,
        .y = 5,
    } }, s.pointFromPin(.screen, hl.start).?);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 2,
        .y = 6,
    } }, s.pointFromPin(.screen, hl.end).?);
}

test "PageList highlightSemanticContent output to end of screen" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 20, 0);
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Single prompt on row 15, no following prompt
    {
        const rac = page.getRowAndCell(0, 15);
        rac.row.semantic_prompt = .prompt;

        for (0..2) |x| {
            const cell = page.getRowAndCell(x, 15).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = '$' },
                .semantic_content = .prompt,
            };
        }

        for (2..4) |x| {
            const cell = page.getRowAndCell(x, 15).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 'c' },
                .semantic_content = .input,
            };
        }

        for (4..10) |x| {
            const cell = page.getRowAndCell(x, 15).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 'o' },
                .semantic_content = .output,
            };
        }
    }
    // Row 16 has output then prompt to bound it
    {
        for (0..8) |x| {
            const cell = page.getRowAndCell(x, 16).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 'o' },
                .semantic_content = .output,
            };
        }
        for (8..10) |x| {
            const cell = page.getRowAndCell(x, 16).cell;
            cell.semantic_content = .prompt;
        }
    }

    // Highlighting output with no following prompt
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 0, .y = 15 } }).?,
        .output,
    ).?;
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 4,
        .y = 15,
    } }, s.pointFromPin(.screen, hl.start).?);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 7,
        .y = 16,
    } }, s.pointFromPin(.screen, hl.end).?);
}

test "PageList highlightSemanticContent output no output returns null" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 20, 0);
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Prompt on row 5 with only prompt and input, no output
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;

        // First 3 cols are prompt
        for (0..3) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = '$' },
                .semantic_content = .prompt,
            };
        }

        // Rest is input (must explicitly mark all cells to avoid default .output)
        for (3..10) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 'c' },
                .semantic_content = .input,
            };
        }
    }
    // Mark rows 6-9 as input to ensure no output between prompts
    {
        for (6..10) |y| {
            for (0..10) |x| {
                const cell = page.getRowAndCell(x, y).cell;
                cell.semantic_content = .input;
            }
        }
    }
    // Prompt on row 10 (no output between prompts)
    {
        const rac = page.getRowAndCell(0, 10);
        rac.row.semantic_prompt = .prompt;
    }

    // Highlighting output should return null when there's no output
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 0, .y = 5 } }).?,
        .output,
    );
    try testing.expect(hl == null);
}

test "PageList highlightSemanticContent output skips empty cells" {
    // Tests that empty cells with default .output semantic content are
    // not selected as output. This can happen when a prompt/input line
    // doesn't fill the entire row - trailing cells have default .output.
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 20, 0);
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);
    const page = s.pages.first.?.page();

    // Prompt on row 5 - only fills first 3 cells, rest are empty with default .output
    {
        const rac = page.getRowAndCell(0, 5);
        rac.row.semantic_prompt = .prompt;

        // First 3 cols are prompt with text
        for (0..3) |x| {
            const cell = page.getRowAndCell(x, 5).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = '$' },
                .semantic_content = .prompt,
            };
        }
        // Cells 3-9 are empty (codepoint = 0) with default .output semantic content
        // This simulates what happens when a short prompt is written
    }

    // Row 6 has input (short, doesn't fill line)
    {
        for (0..4) |x| {
            const cell = page.getRowAndCell(x, 6).cell;
            cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 'l' },
                .semantic_content = .input,
            };
        }
        // Cells 4-9 are empty with default .output
    }

    // Row 7-8 have actual output with text
    {
        for (7..9) |y| {
            for (0..5) |x| {
                const cell = page.getRowAndCell(x, y).cell;
                cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = 'o' },
                    .semantic_content = .output,
                };
            }
        }
    }

    // Prompt on row 10
    {
        const rac = page.getRowAndCell(0, 10);
        rac.row.semantic_prompt = .prompt;
    }

    // Highlighting output should skip empty cells on rows 5-6 and find
    // the actual output starting at row 7
    const hl = s.highlightSemanticContent(
        s.pin(.{ .screen = .{ .x = 0, .y = 5 } }).?,
        .output,
    ).?;
    // Output should start at row 7, not row 5 (where empty cells have default .output)
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 0,
        .y = 7,
    } }, s.pointFromPin(.screen, hl.start).?);
    try testing.expectEqual(point.Point{ .screen = .{
        .x = 4,
        .y = 8,
    } }, s.pointFromPin(.screen, hl.end).?);
}

test "PageList erase" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();
    try testing.expectEqual(@as(usize, 1), s.totalPages());

    // Grow so we take up at least 5 pages.
    const page = s.pages.last.?.page();
    var cur_page = s.pages.last.?;
    cur_page.page().pauseIntegrityChecks(true);
    for (0..page.capacity.rows * 5) |_| {
        if (try s.grow()) |new_page| {
            cur_page.page().pauseIntegrityChecks(false);
            cur_page = new_page;
            cur_page.page().pauseIntegrityChecks(true);
        }
    }
    cur_page.page().pauseIntegrityChecks(false);
    try testing.expectEqual(@as(usize, 6), s.totalPages());

    // Our total rows should be large
    try testing.expect(s.total_rows > s.rows);

    // Erase the entire history, we should be back to just our active set.
    s.eraseHistory(null);
    try testing.expectEqual(s.rows, s.total_rows);

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
    const page = s.pages.last.?.page();
    var cur_page = s.pages.last.?;
    cur_page.page().pauseIntegrityChecks(true);
    for (0..page.capacity.rows * 5) |_| {
        if (try s.grow()) |new_page| {
            cur_page.page().pauseIntegrityChecks(false);
            cur_page = new_page;
            cur_page.page().pauseIntegrityChecks(true);
        }
    }
    cur_page.page().pauseIntegrityChecks(false);
    try testing.expect(s.page_size > start_size);

    // Erase the entire history, we should be back to just our active set.
    s.eraseHistory(null);
    try testing.expectEqual(start_size, s.page_size);
}

test "PageList erase row with tracked pin resets to top-left" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();

    // Grow so we take up at least 5 pages.
    const page = s.pages.last.?.page();
    var cur_page = s.pages.last.?;
    cur_page.page().pauseIntegrityChecks(true);
    for (0..page.capacity.rows * 5) |_| {
        if (try s.grow()) |new_page| {
            cur_page.page().pauseIntegrityChecks(false);
            cur_page = new_page;
            cur_page.page().pauseIntegrityChecks(true);
        }
    }
    cur_page.page().pauseIntegrityChecks(false);

    // Our total rows should be large
    try testing.expect(s.total_rows > s.rows);

    // Put a tracked pin in the history
    const p = try s.trackPin(s.pin(.{ .history = .{} }).?);
    defer s.untrackPin(p);

    // Erase the entire history, we should be back to just our active set.
    s.eraseHistory(null);
    try testing.expectEqual(s.rows, s.total_rows);

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
    s.eraseActive(3);
    try testing.expectEqual(s.rows, s.total_rows);

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
    s.eraseActive(3);
    try testing.expectEqual(s.rows, s.total_rows);

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
    const page = s.pages.last.?.page();
    var cur_page = s.pages.last.?;
    cur_page.page().pauseIntegrityChecks(true);
    for (0..page.capacity.rows * 5) |_| {
        if (try s.grow()) |new_page| {
            cur_page.page().pauseIntegrityChecks(false);
            cur_page = new_page;
            cur_page.page().pauseIntegrityChecks(true);
        }
    }
    cur_page.page().pauseIntegrityChecks(false);

    // Move our viewport to the top
    s.scroll(.{ .delta_row = -@as(isize, @intCast(s.total_rows)) });
    try testing.expect(s.viewport == .top);

    // Erase the entire history, we should be back to just our active set.
    s.eraseHistory(null);
    try testing.expect(s.viewport == .active);
}

test "PageList erase resets viewport if inside erased page but not active" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();

    // Grow so we take up at least 5 pages.
    const page = s.pages.last.?.page();
    var cur_page = s.pages.last.?;
    cur_page.page().pauseIntegrityChecks(true);
    for (0..page.capacity.rows * 5) |_| {
        if (try s.grow()) |new_page| {
            cur_page.page().pauseIntegrityChecks(false);
            cur_page = new_page;
            cur_page.page().pauseIntegrityChecks(true);
        }
    }
    cur_page.page().pauseIntegrityChecks(false);

    // Move our viewport to the top
    s.scroll(.{ .delta_row = -@as(isize, @intCast(s.total_rows)) });
    try testing.expect(s.viewport == .top);

    // Erase the entire history, we should be back to just our active set.
    s.eraseHistory(.{ .history = .{ .y = 2 } });
    try testing.expect(s.viewport == .top);
}

test "PageList erase resets viewport to active if top is inside active" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();

    // Grow so we take up at least 5 pages.
    const page = s.pages.last.?.page();
    var cur_page = s.pages.last.?;
    cur_page.page().pauseIntegrityChecks(true);
    for (0..page.capacity.rows * 5) |_| {
        if (try s.grow()) |new_page| {
            cur_page.page().pauseIntegrityChecks(false);
            cur_page = new_page;
            cur_page.page().pauseIntegrityChecks(true);
        }
    }
    cur_page.page().pauseIntegrityChecks(false);

    // Move our viewport to the top
    s.scroll(.{ .top = {} });

    // Erase the entire history, we should be back to just our active set.
    s.eraseHistory(null);
    try testing.expect(s.viewport == .active);
}

test "PageList erase active regrows automatically" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();
    try testing.expect(s.totalRows() == s.rows);
    s.eraseActive(10);
    try testing.expect(s.totalRows() == s.rows);
}

test "PageList erase a one-row active" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 1, null);
    defer s.deinit();
    try testing.expectEqual(@as(usize, 1), s.totalPages());

    // Write our letter
    const page = s.pages.first.?.page();
    for (0..s.rows) |y| {
        const rac = page.getRowAndCell(0, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = 'A' },
        };
    }

    s.eraseActive(0);
    try testing.expectEqual(s.rows, s.total_rows);

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
    try testing.expect(s.isDirty(.{ .active = .{ .x = 0, .y = 5 } }));
    try testing.expect(s.isDirty(.{ .active = .{ .x = 0, .y = 6 } }));
    try testing.expect(s.isDirty(.{ .active = .{ .x = 0, .y = 7 } }));

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
        const page = s.pages.last.?.page();
        page.pauseIntegrityChecks(true);
        for (0..page.capacity.rows - page.size.rows) |_| _ = try s.grow();
        page.pauseIntegrityChecks(false);
        try s.growRows(5);
        try testing.expectEqual(@as(usize, 2), s.totalPages());
        try testing.expectEqual(@as(usize, 5), s.pages.last.?.rows());
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
        try testing.expectEqual(@as(usize, p_first.node.rows() - 1), p_first.y);
        try testing.expectEqual(@as(usize, 0), p_first.x);

        try testing.expectEqual(s.pages.last.?.prev.?, p_first_out.node);
        try testing.expectEqual(@as(usize, p_first_out.node.rows() - 2), p_first_out.y);
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
    for (4..8) |y| try testing.expect(s.isDirty(.{ .active = .{
        .x = 0,
        .y = @intCast(y),
    } }));

    // In page in first page is shifted
    try testing.expectEqual(s.pages.last.?.prev.?, p_first.node);
    try testing.expectEqual(@as(usize, p_first.node.rows() - 2), p_first.y);
    try testing.expectEqual(@as(usize, 0), p_first.x);

    // Out page in first page should not be shifted
    try testing.expectEqual(s.pages.last.?.prev.?, p_first_out.node);
    try testing.expectEqual(@as(usize, p_first_out.node.rows() - 2), p_first_out.y);
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

    var s2 = try s.clone(alloc, .{
        .top = .{ .screen = .{} },
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

    var s2 = try s.clone(alloc, .{
        .top = .{ .screen = .{} },
        .bot = .{ .screen = .{ .y = 39 } },
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

    var s2 = try s.clone(alloc, .{
        .top = .{ .screen = .{ .y = 10 } },
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
        const page = s.pages.first.?.page();

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

    var s2 = try s.clone(alloc, .{
        .top = .{ .screen = .{ .y = 10 } },
    });
    defer s2.deinit();
    try testing.expectEqual(@as(usize, 40), s2.totalRows());

    {
        try testing.expect(s2.pages.first == s2.pages.last);
        const page = s2.pages.first.?.page();
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

    var s2 = try s.clone(alloc, .{
        .top = .{ .screen = .{ .y = 10 } },
        .bot = .{ .screen = .{ .y = 35 } },
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

    var s2 = try s.clone(alloc, .{
        .top = .{ .active = .{ .y = 5 } },
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
    var s2 = try s.clone(alloc, .{
        .top = .{ .active = .{ .y = 5 } },
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
    var s2 = try s.clone(alloc, .{
        .top = .{ .active = .{ .y = 5 } },
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

    var s2 = try s.clone(alloc, .{
        .top = .{ .screen = .{} },
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
    const page = s.pages.first.?.page();

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
    const page = s.pages.first.?.page();

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
    const page = s.pages.first.?.page();

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
    const page = s.pages.first.?.page();

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
    const page = s.pages.first.?.page();

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
    const page = s.pages.first.?.page();

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
    const page = s.pages.first.?.page();

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
    const page = s.pages.first.?.page();

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

test "PageList resize (no reflow) more rows contains viewport" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // When the rows are increased we need to make sure that the viewport
    // doesn't end up below the active area if it's currently in pin mode.

    var s = try init(alloc, 5, 5, 1);
    defer s.deinit();
    try testing.expect(s.pages.first == s.pages.last);

    // Make it so we have scrollback
    _ = try s.grow();

    try testing.expectEqual(@as(usize, 5), s.rows);
    try testing.expectEqual(@as(usize, 6), s.totalRows());

    // Set viewport above active by scrolling up one.
    s.scroll(.{ .delta_row = -1 });
    // The viewport should be a pin now.
    try testing.expectEqual(Viewport.top, s.viewport);

    // Resize
    try s.resize(.{ .rows = 7, .reflow = false });
    try testing.expectEqual(@as(usize, 7), s.rows);
    try testing.expectEqual(@as(usize, 7), s.totalRows());

    // Question: maybe the viewport should actually be in the active
    // here and not pinned to the top.
    try testing.expectEqual(Viewport.top, s.viewport);
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
        const cells = offset.node.page().getCells(rac.row);
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
        const cells = offset.node.page().getCells(rac.row);
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
    const page = s.pages.first.?.page();
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
        try testing.expectEqual(@as(usize, 0), chunk.node.page().graphemeCount());
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
        const cells = offset.node.page().getCells(rac.row);
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
        const page = s.pages.first.?.page();

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
        const page = s.pages.first.?.page();

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

// Regression test for fuzz crash. When we shrink cols and then
// grow back, the page retains capacity from the original size so the grow
// takes the fast path (just bumps page.size.cols). If any row has a
// spacer_head at the old last column, that cell is no longer at the end
// of the wider row, violating page integrity.
test "PageList resize (no reflow) grow cols fast path with spacer head" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 3, 0);
    defer s.deinit();

    // Shrink to 5 cols. The page keeps capacity for 10 cols.
    try s.resize(.{ .cols = 5, .reflow = false });
    try testing.expectEqual(@as(usize, 5), s.cols);

    // Place a spacer_head at the last column (col 4) on two rows
    // to simulate a wide character that didn't fit at the right edge.
    {
        const page = s.pages.first.?.page();

        // Row 0: 'x' at col 0..3, spacer_head at col 4, wrap = true
        {
            const rac = page.getRowAndCell(0, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 'x' },
            };
        }
        {
            const rac = page.getRowAndCell(4, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 0 },
                .wide = .spacer_head,
            };
            rac.row.wrap = true;
        }

        // Row 1: spacer_head at col 4, wrap = true
        {
            const rac = page.getRowAndCell(4, 1);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 0 },
                .wide = .spacer_head,
            };
            rac.row.wrap = true;
        }
    }

    // Grow back to 10 cols. This must not leave stale spacer_head
    // cells at col 4 (which is no longer the last column).
    try s.resize(.{ .cols = 10, .reflow = false });
    try testing.expectEqual(@as(usize, 10), s.cols);

    // Verify the old spacer_head positions are now narrow.
    {
        const page = s.pages.first.?.page();
        {
            const rac = page.getRowAndCell(4, 0);
            try testing.expectEqual(pagepkg.Cell.Wide.narrow, rac.cell.wide);
            try testing.expect(!rac.row.wrap);
        }
        {
            const rac = page.getRowAndCell(4, 1);
            try testing.expectEqual(pagepkg.Cell.Wide.narrow, rac.cell.wide);
            try testing.expect(!rac.row.wrap);
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
            try testing.expectEqual(page.capacity().rows, page.rows());
        }
    }

    // Now we need to resize again to a col size that further shrinks
    // our last capacity.
    {
        const page = s.pages.first.?.page();
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
            try testing.expectEqual(page.capacity().rows, page.rows());
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
        const cells = offset.node.page().getCells(rac.row);
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
        const cells = offset.node.page().getCells(rac.row);
        try testing.expectEqual(@as(usize, 5), cells.len);
    }
}

test "PageList resize less rows and cols cursor at bottom" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, 0);
    defer s.deinit();

    const cursor_pin = try s.trackPin(s.pin(.{ .active = .{
        .x = 0,
        .y = s.rows - 1,
    } }).?);
    defer s.untrackPin(cursor_pin);

    // Shrink both axes such that the original cursor.y is strictly past the
    // new row count, so resizeWithoutReflow leaves self.rows < c.y + 1.
    try s.resize(.{
        .cols = 79,
        .rows = 20,
        .reflow = true,
        .cursor = .{ .x = 0, .y = 23, .pin = cursor_pin },
    });
    try testing.expectEqual(@as(usize, 79), s.cols);
    try testing.expectEqual(@as(usize, 20), s.rows);

    // remaining_rows saturates to 0, so the cursor lands on the new bottom row.
    try testing.expectEqual(point.Point{ .active = .{
        .x = 0,
        .y = s.rows - 1,
    } }, s.pointFromPin(.active, cursor_pin.*).?);
}

test "PageList resize less rows and cols cursor near top pushed to scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();

    // Fill every active row with non-blank content so that shrinking rows
    // can't trim trailing blank lines and instead pushes the top rows into
    // scrollback.
    {
        var it = s.rowIterator(.right_down, .{ .active = .{} }, null);
        while (it.next()) |p| {
            const rac = p.rowAndCell();
            const cells = p.node.page().getCells(rac.row);
            for (cells, 0..) |*cell, x| cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = @intCast('A' + (x % 26)) },
            };
        }
    }

    // Cursor near the top of the active area. After we shrink rows the active
    // area top moves down past this pin, so it ends up in scrollback.
    const cursor_pin = try s.trackPin(s.pin(.{ .active = .{
        .x = 0,
        .y = 0,
    } }).?);
    defer s.untrackPin(cursor_pin);

    // Shrink both axes with reflow. resizeWithoutReflow shrinks self.rows
    // first, leaving the cursor pin above the new active area, then resizeCols
    // walks .left_up from the cursor pin toward the active-area top.
    try s.resize(.{
        .cols = 79,
        .rows = 20,
        .reflow = true,
        .cursor = .{ .x = 0, .y = 0, .pin = cursor_pin },
    });
    try testing.expectEqual(@as(usize, 79), s.cols);
    try testing.expectEqual(@as(usize, 20), s.rows);

    // The active area is anchored to the bottom, so shrinking rows pushed the
    // top-of-screen cursor into scrollback: it no longer resolves to an
    // active-area coordinate, but it remains a valid screen pin.
    try testing.expect(s.pointFromPin(.active, cursor_pin.*) == null);
    try testing.expect(s.pointFromPin(.screen, cursor_pin.*) != null);

    // Integrity must hold after the resize.
    s.assertIntegrity();
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
        const cells = offset.node.page().getCells(rac.row);
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
        const cells = offset.node.page().getCells(rac.row);
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
    const page = s.pages.first.?.page();
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
        const cells = offset.node.page().getCells(rac.row);
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
    const page = s.pages.first.?.page();
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
    const page = s.pages.first.?.page();
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
        const cells = offset.node.page().getCells(rac.row);
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
    const page = s.pages.first.?.page();
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
        const cells = offset.node.page().getCells(rac.row);
        try testing.expect(!rac.row.wrap);
        try testing.expectEqual(@as(usize, 4), cells.len);
        try testing.expectEqual(@as(u21, 'A'), cells[0].content.codepoint);
        try testing.expectEqual(@as(u21, 'A'), cells[2].content.codepoint);
    }
}

test "PageList resize reflow invalidates viewport offset cache" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 2, 4, null);
    defer s.deinit();
    try s.growRows(20);

    const page = s.pages.last.?.page();
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

    // Scroll to a pinned viewport in history
    const pin_y = 10;
    s.scroll(.{ .pin = s.pin(.{ .screen = .{ .y = pin_y } }).? });
    try testing.expect(s.viewport == .pin);
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = pin_y,
        .len = s.rows,
    }, s.scrollbar());

    // Resize with reflow - unwrapping rows changes total_rows
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);

    // Verify scrollbar cache was invalidated during reflow
    try testing.expectEqual(Scrollbar{
        .total = s.total_rows,
        .offset = 5,
        .len = s.rows,
    }, s.scrollbar());
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
        const page = s.pages.first.?.page();
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
            try testing.expectEqual(newcap.cols, page.capacity().cols);
            try testing.expectEqual(newcap.rows, page.capacity().rows);
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
        const page = s.pages.first.?.page();
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
        const page = s.pages.first.?.page();
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
        const page2 = s.pages.last.?.page();
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
        const page = s.pages.first.?.page();
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
        const page = s.pages.first.?.page();
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
        const page2 = s.pages.last.?.page();
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
        const page = s.pages.first.?.page();
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
        const page = s.pages.first.?.page();
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
        const page2 = s.pages.last.?.page();
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
    const page = s.pages.first.?.page();
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
    const page = s.pages.first.?.page();
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
    const page = s.pages.first.?.page();
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
        const page = s.pages.first.?.page();
        const rac = page.getRowAndCell(0, 1);
        rac.row.semantic_prompt = .prompt;
    }

    // Resize
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expectEqual(@as(usize, 4), s.totalRows());

    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
        const rac = page.getRowAndCell(0, 1);
        try testing.expect(rac.row.semantic_prompt == .prompt);
    }
}

test "PageList resize reflow exceeds hyperlink memory forcing capacity increase" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 2, 10, 0);
    defer s.deinit();
    try testing.expectEqual(@as(usize, 1), s.totalPages());

    // Grow to the capacity of the first page and add
    // one more row so that we have two pages total.
    {
        const page = s.pages.first.?.page();
        page.pauseIntegrityChecks(true);
        for (page.size.rows..page.capacity.rows) |_| {
            _ = try s.grow();
        }
        page.pauseIntegrityChecks(false);
        try testing.expectEqual(@as(usize, 1), s.totalPages());
        try s.growRows(1);
        try testing.expectEqual(@as(usize, 2), s.totalPages());

        // We now have two pages.
        try std.testing.expect(s.pages.first.? != s.pages.last.?);
        try std.testing.expectEqual(s.pages.last.?, s.pages.first.?.next);
    }

    // We use almost all string alloc capacity with a hyperlink in the final
    // row of the first page, and do the same on the first row of the second
    // page. We also mark the row as wrapped so that when we resize with more
    // cols the row unwraps and we have a single row that requires almost two
    // times the base string alloc capacity.
    //
    // This forces the reflow to increase capacity.
    //
    //  +--+ = PAGE 0
    //  :  :
    //  | X… <- where X is hyperlinked with almost all string cap.
    //  +--+
    //  +--+ = PAGE 1
    //  …X | <- X here also almost hits string cap with a hyperlink.
    //  +--+

    // Almost hit string alloc cap in bottom right of first page.
    // Mark the final row as wrapped.
    {
        const page = s.pages.first.?.page();
        const id = try page.insertHyperlink(.{
            .id = .{ .implicit = 0 },
            .uri = "a" ** (pagepkg.string_bytes_default - 1),
        });
        const rac = page.getRowAndCell(page.size.cols - 1, page.size.rows - 1);
        rac.row.wrap = true;
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = 'X' },
        };
        try page.setHyperlink(rac.row, rac.cell, id);
        try std.testing.expectError(
            error.StringsOutOfMemory,
            page.insertHyperlink(.{
                .id = .{ .implicit = 1 },
                .uri = "AAAAAAAAAAAAAAAAAAAAAAAAAA",
            }),
        );
    }

    // Almost hit string alloc cap in top left of second page.
    // Mark the first row as a wrap continuation.
    {
        const page = s.pages.last.?.page();
        const id = try page.insertHyperlink(.{
            .id = .{ .implicit = 1 },
            .uri = "a" ** (pagepkg.string_bytes_default - 1),
        });
        const rac = page.getRowAndCell(0, 0);
        rac.row.wrap_continuation = true;
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = 'X' },
        };
        try page.setHyperlink(rac.row, rac.cell, id);
        try std.testing.expectError(
            error.StringsOutOfMemory,
            page.insertHyperlink(.{
                .id = .{ .implicit = 2 },
                .uri = "AAAAAAAAAAAAAAAAAAAAAAAAAA",
            }),
        );
    }

    // Resize to 1 column wider, unwrapping the row.
    try s.resize(.{ .cols = s.cols + 1, .reflow = true });
}

test "PageList resize reflow exceeds grapheme memory forcing capacity increase" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 2, 10, 0);
    defer s.deinit();
    try testing.expectEqual(@as(usize, 1), s.totalPages());

    // Grow to the capacity of the first page and add
    // one more row so that we have two pages total.
    {
        const page = s.pages.first.?.page();
        page.pauseIntegrityChecks(true);
        for (page.size.rows..page.capacity.rows) |_| {
            _ = try s.grow();
        }
        page.pauseIntegrityChecks(false);
        try testing.expectEqual(@as(usize, 1), s.totalPages());
        try s.growRows(1);
        try testing.expectEqual(@as(usize, 2), s.totalPages());

        // We now have two pages.
        try std.testing.expect(s.pages.first.? != s.pages.last.?);
        try std.testing.expectEqual(s.pages.last.?, s.pages.first.?.next);
    }

    // We use almost all grapheme alloc capacity with a grapheme in the final
    // row of the first page, and do the same on the first row of the second
    // page. We also mark the row as wrapped so that when we resize with more
    // cols the row unwraps and we have a single row that requires almost two
    // times the base grapheme alloc capacity.
    //
    // This forces the reflow to increase capacity.
    //
    //  +--+ = PAGE 0
    //  :  :
    //  | X… <- where X is a grapheme which uses almost all the capacity.
    //  +--+
    //  +--+ = PAGE 1
    //  …X | <- X here also almost hits grapheme cap.
    //  +--+

    // Almost hit grapheme alloc cap in bottom right of first page.
    // Mark the final row as wrapped.
    {
        const page = s.pages.first.?.page();
        const rac = page.getRowAndCell(page.size.cols - 1, page.size.rows - 1);
        rac.row.wrap = true;
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = 'X' },
        };
        try page.setGraphemes(
            rac.row,
            rac.cell,
            &@as(
                [
                    @divFloor(
                        pagepkg.grapheme_bytes_default - 1,
                        @sizeOf(u21),
                    )
                ]u21,
                @splat('a'),
            ),
        );
        try std.testing.expectError(
            error.OutOfMemory,
            page.grapheme_alloc.alloc(
                u21,
                page.memory,
                16,
            ),
        );
    }

    // Almost hit grapheme alloc cap in top left of second page.
    // Mark the first row as a wrap continuation.
    {
        const page = s.pages.last.?.page();
        const rac = page.getRowAndCell(0, 0);
        rac.row.wrap = true;
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = 'X' },
        };
        try page.setGraphemes(
            rac.row,
            rac.cell,
            &@as(
                [
                    @divFloor(
                        pagepkg.grapheme_bytes_default - 1,
                        @sizeOf(u21),
                    )
                ]u21,
                @splat('a'),
            ),
        );
        try std.testing.expectError(
            error.OutOfMemory,
            page.grapheme_alloc.alloc(
                u21,
                page.memory,
                16,
            ),
        );
    }

    // Resize to 1 column wider, unwrapping the row.
    try s.resize(.{ .cols = s.cols + 1, .reflow = true });
}

test "PageList resize reflow exceeds style memory forcing capacity increase" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, pagepkg.std_capacity.styles - 1, 10, 0);
    defer s.deinit();
    try testing.expectEqual(@as(usize, 1), s.totalPages());

    // Grow to the capacity of the first page and add
    // one more row so that we have two pages total.
    {
        const page = s.pages.first.?.page();
        page.pauseIntegrityChecks(true);
        for (page.size.rows..page.capacity.rows) |_| {
            _ = try s.grow();
        }
        page.pauseIntegrityChecks(false);
        try testing.expectEqual(@as(usize, 1), s.totalPages());
        try s.growRows(1);
        try testing.expectEqual(@as(usize, 2), s.totalPages());

        // We now have two pages.
        try std.testing.expect(s.pages.first.? != s.pages.last.?);
        try std.testing.expectEqual(s.pages.last.?, s.pages.first.?.next);
    }

    // Give each cell in the final row of the first page a unique style.
    // Mark the final row as wrapped.
    {
        const page = s.pages.first.?.page();
        for (0..s.cols) |x| {
            const id = page.styles.add(
                page.memory,
                .{
                    .bg_color = .{ .rgb = .{
                        .r = @truncate(x),
                        .g = @truncate(x >> 8),
                        .b = @truncate(x >> 16),
                    } },
                },
            ) catch break;

            const rac = page.getRowAndCell(x, page.size.rows - 1);
            rac.row.wrap = true;
            rac.row.styled = true;
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 'X' },
                .style_id = id,
            };
        }
    }

    // Do the same for the first row of the second page.
    // Mark the first row as a wrap continuation.
    {
        const page = s.pages.last.?.page();
        for (0..s.cols) |x| {
            const id = page.styles.add(
                page.memory,
                .{
                    .fg_color = .{ .rgb = .{
                        .r = @truncate(x),
                        .g = @truncate(x >> 8),
                        .b = @truncate(x >> 16),
                    } },
                },
            ) catch break;

            const rac = page.getRowAndCell(x, 0);
            rac.row.wrap_continuation = true;
            rac.row.styled = true;
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 'X' },
                .style_id = id,
            };
        }
    }

    // Resize to twice as wide, fully unwrapping the row.
    try s.resize(.{ .cols = s.cols * 2, .reflow = true });
}

test "PageList resize reflow more cols unwrap wide spacer head" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 2, 2, 0);
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

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
        const page = s.pages.first.?.page();

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
        const page = s.pages.first.?.page();

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
        const page = s.pages.first.?.page();

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
        const page = s.pages.first.?.page();

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
        const page = s.pages.first.?.page();

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
        const page = s.pages.first.?.page();
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
        const page = s.pages.first.?.page();
        const rac = page.getRowAndCell(0, 0);
        rac.row.semantic_prompt = .prompt;
    }

    // Resize
    try s.resize(.{ .cols = 2, .reflow = true });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 4), s.totalRows());

    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
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
        const page = s.pages.first.?.page();
        const rac = page.getRowAndCell(0, 0);
        rac.row.semantic_prompt = .prompt;
    }

    // Resize
    try s.resize(.{ .cols = 2, .reflow = true });
    try testing.expectEqual(@as(usize, 2), s.cols);
    try testing.expectEqual(@as(usize, 4), s.totalRows());

    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();
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
    const page = s.pages.first.?.page();
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
            const cells = offset.node.page().getCells(rac.row);
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
    const page = s.pages.first.?.page();
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
        const cells = offset.node.page().getCells(rac.row);
        try testing.expect(rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expect(!rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 2), cells[0].content.codepoint);
    }
    {
        // First row should be wrapped
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expect(rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
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
        const page = s.pages.first.?.page();
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
    const page = s.pages.first.?.page();
    var it = s.rowIterator(.right_down, .{ .screen = .{} }, null);
    {
        // First row should be wrapped
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expect(rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
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
        const cells = offset.node.page().getCells(rac.row);
        try testing.expect(rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
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
    const page = s.pages.first.?.page();
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
        const page = s.pages.first.?.page();

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
        const page = s.pages.first.?.page();

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
    const page = s.pages.first.?.page();
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
    const page = s.pages.first.?.page();
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
    const page = s.pages.first.?.page();
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
    const page = s.pages.first.?.page();
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
    const page = s.pages.first.?.page();
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
    const page = s.pages.first.?.page();
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
        const cells = offset.node.page().getCells(rac.row);
        try testing.expect(rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
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
    const page = s.pages.first.?.page();
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
        const cells = offset.node.page().getCells(rac.row);
        try testing.expect(rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
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
    const page = s.pages.first.?.page();
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
        const cells = offset.node.page().getCells(rac.row);
        try testing.expect(!rac.row.wrap);
        try testing.expectEqual(@as(usize, 2), cells.len);
        try testing.expectEqual(@as(u21, 'A'), cells[0].content.codepoint);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
        try testing.expectEqual(@as(u21, 0), cells[0].content.codepoint);
    }
    {
        const offset = it.next().?;
        const rac = offset.rowAndCell();
        const cells = offset.node.page().getCells(rac.row);
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
    const page = s.pages.first.?.page();
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
        const page = s.pages.first.?.page();

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

            const style = offset.node.page().styles.get(
                offset.node.page().memory,
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
        const page = s.pages.first.?.page();

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
        const page = s.pages.first.?.page();

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
        const page = s.pages.first.?.page();

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
        const page = s.pages.first.?.page();

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

test "PageList resize reflow less cols to wrap a multi-codepoint grapheme with a spacer head" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 4, 2, 0);
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

        // We want to make the screen look like this:
        //
        // 👨‍👨‍👦‍👦👨‍👨‍👦‍👦

        // First family emoji at (0, 0)
        {
            const rac = page.getRowAndCell(0, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 0x1F468 }, // First codepoint of the grapheme
                .wide = .wide,
            };
            try page.setGraphemes(rac.row, rac.cell, &.{
                0x200D, 0x1F468,
                0x200D, 0x1F466,
                0x200D, 0x1F466,
            });
        }
        {
            const rac = page.getRowAndCell(1, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 0 },
                .wide = .spacer_tail,
            };
        }
        // Second family emoji at (2, 0)
        {
            const rac = page.getRowAndCell(2, 0);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 0x1F468 }, // First codepoint of the grapheme
                .wide = .wide,
            };
            try page.setGraphemes(rac.row, rac.cell, &.{
                0x200D, 0x1F468,
                0x200D, 0x1F466,
                0x200D, 0x1F466,
            });
        }
        {
            const rac = page.getRowAndCell(3, 0);
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
        const page = s.pages.first.?.page();

        {
            const rac = page.getRowAndCell(0, 0);
            try testing.expectEqual(@as(u21, 0x1F468), rac.cell.content.codepoint);
            try testing.expectEqual(pagepkg.Cell.Wide.wide, rac.cell.wide);

            const cps = page.lookupGrapheme(rac.cell).?;
            try testing.expectEqual(@as(usize, 6), cps.len);
            try testing.expectEqual(@as(u21, 0x200D), cps[0]);
            try testing.expectEqual(@as(u21, 0x1F468), cps[1]);
            try testing.expectEqual(@as(u21, 0x200D), cps[2]);
            try testing.expectEqual(@as(u21, 0x1F466), cps[3]);
            try testing.expectEqual(@as(u21, 0x200D), cps[4]);
            try testing.expectEqual(@as(u21, 0x1F466), cps[5]);

            // Row should be wrapped
            try testing.expect(rac.row.wrap);
        }
        {
            const rac = page.getRowAndCell(1, 0);
            try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint);
            try testing.expectEqual(pagepkg.Cell.Wide.spacer_tail, rac.cell.wide);
        }
        {
            const rac = page.getRowAndCell(2, 0);
            try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint);
            try testing.expectEqual(pagepkg.Cell.Wide.spacer_head, rac.cell.wide);
        }

        {
            const rac = page.getRowAndCell(0, 0);
            try testing.expectEqual(@as(u21, 0x1F468), rac.cell.content.codepoint);
            try testing.expectEqual(pagepkg.Cell.Wide.wide, rac.cell.wide);

            const cps = page.lookupGrapheme(rac.cell).?;
            try testing.expectEqual(@as(usize, 6), cps.len);
            try testing.expectEqual(@as(u21, 0x200D), cps[0]);
            try testing.expectEqual(@as(u21, 0x1F468), cps[1]);
            try testing.expectEqual(@as(u21, 0x200D), cps[2]);
            try testing.expectEqual(@as(u21, 0x1F466), cps[3]);
            try testing.expectEqual(@as(u21, 0x200D), cps[4]);
            try testing.expectEqual(@as(u21, 0x1F466), cps[5]);
        }
        {
            const rac = page.getRowAndCell(1, 1);
            try testing.expectEqual(@as(u21, 0), rac.cell.content.codepoint);
            try testing.expectEqual(pagepkg.Cell.Wide.spacer_tail, rac.cell.wide);
        }
    }
}

test "PageList resize reflow less cols copy kitty placeholder" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 4, 2, 0);
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

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
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 4, 2, 0);
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

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
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 4, 2, 0);
    defer s.deinit();
    {
        try testing.expect(s.pages.first == s.pages.last);
        const page = s.pages.first.?.page();

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

test "PageList reset invalidates stale untracked refs even if node memory is reused" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();

    var stale_nodes: [page_preheat * 4]*List.Node = undefined;
    var stale_serials: [stale_nodes.len]u64 = undefined;
    var stale_len: usize = 0;
    var reused: ?struct { *List.Node, u64 } = null;

    while (stale_len < stale_nodes.len and reused == null) {
        const old_node = s.pages.first.?;
        const old_serial = old_node.serial;
        try testing.expect(old_serial >= s.page_serial_epoch);
        try testing.expect(old_serial < s.page_serial);
        stale_nodes[stale_len] = old_node;
        stale_serials[stale_len] = old_serial;
        stale_len += 1;

        s.reset();

        const new_node = s.pages.first.?;
        for (stale_nodes[0..stale_len], stale_serials[0..stale_len]) |node, serial| {
            if (node == new_node) {
                reused = .{ node, serial };
                break;
            }
        }
    }

    try testing.expect(reused != null);
    const old_node, const old_serial = reused.?;
    const new_node = s.pages.first.?;
    const new_serial = new_node.serial;

    // Reset advances the epoch before rebuilding from the node pool. Reject
    // the stale generation before inspecting its pointer, even when that exact
    // address now belongs to a new live generation.
    try testing.expectEqual(old_node, new_node);
    try testing.expect(old_serial < s.page_serial_epoch);
    try testing.expect(!s.nodeIsValid(old_node, old_serial));
    try testing.expect(s.nodeIsValid(new_node, new_serial));
    try testing.expect(new_serial >= s.page_serial_epoch);
    try testing.expect(new_serial < s.page_serial);
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

test "PageList reset moves tracked pins and marks them as garbage" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();

    // Create a tracked pin into the active area
    const p = try s.trackPin(s.pin(.{ .active = .{
        .x = 42,
        .y = 12,
    } }).?);
    defer s.untrackPin(p);

    s.reset();

    // Our added pin should now be garbage
    try testing.expect(p.garbage);

    // Viewport pin should not be garbage because it makes sense.
    try testing.expect(!s.viewport_pin.garbage);
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

test "PageList resize reflow grapheme map capacity exceeded" {
    // This test verifies that when reflowing content with many graphemes,
    // the grapheme map capacity is correctly increased when needed.
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 4, 10, 0);
    defer s.deinit();
    try testing.expectEqual(@as(usize, 1), s.totalPages());

    // Get the grapheme capacity from the page. We need more than this many
    // graphemes in a single destination page to trigger capacity increase
    // during reflow. Since each source page can only hold this many graphemes,
    // we create two source pages with graphemes that will merge into one
    // destination page.
    const grapheme_capacity = s.pages.first.?.page().graphemeCapacity();
    // Use slightly more than half the capacity per page, so combined they
    // exceed the capacity of a single destination page.
    const graphemes_per_page = grapheme_capacity / 2 + grapheme_capacity / 4;

    // Grow to the capacity of the first page and add more rows
    // so that we have two pages total.
    {
        const page = s.pages.first.?.page();
        page.pauseIntegrityChecks(true);
        for (page.size.rows..page.capacity.rows) |_| {
            _ = try s.grow();
        }
        page.pauseIntegrityChecks(false);
        try testing.expectEqual(@as(usize, 1), s.totalPages());
        try s.growRows(graphemes_per_page);
        try testing.expectEqual(@as(usize, 2), s.totalPages());

        // We now have two pages.
        try testing.expect(s.pages.first.? != s.pages.last.?);
        try testing.expectEqual(s.pages.last.?, s.pages.first.?.next);
    }

    // Add graphemes to both pages. We add graphemes to rows at the END of the
    // first page, and graphemes to rows at the START of the second page.
    // When reflowing to 2 columns, these rows will wrap and stay together
    // on the same destination page, requiring capacity increase.

    // Add graphemes to the end of the first page (last rows)
    {
        const page = s.pages.first.?.page();
        const start_row = page.size.rows - graphemes_per_page;
        for (0..graphemes_per_page) |i| {
            const y = start_row + i;
            const rac = page.getRowAndCell(0, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 'A' },
            };
            try page.appendGrapheme(rac.row, rac.cell, @as(u21, @intCast(0x0301)));
        }
    }

    // Add graphemes to the beginning of the second page
    {
        const page = s.pages.last.?.page();
        const count = @min(graphemes_per_page, page.size.rows);
        for (0..count) |y| {
            const rac = page.getRowAndCell(0, y);
            rac.cell.* = .{
                .content_tag = .codepoint,
                .content = .{ .codepoint = 'B' },
            };
            try page.appendGrapheme(rac.row, rac.cell, @as(u21, @intCast(0x0302)));
        }
    }

    // Resize to fewer columns to trigger reflow.
    // The graphemes from both pages will be copied to destination pages.
    // They will all end up in a contiguous region of the destination.
    // If the bug exists (hyperlink_bytes increased instead of grapheme_bytes),
    // this will fail with GraphemeMapOutOfMemory when we exceed capacity.
    try s.resize(.{ .cols = 2, .reflow = true });

    // Verify the resize succeeded
    try testing.expectEqual(@as(usize, 2), s.cols);
}

test "PageList resize grow cols with unwrap fixes viewport pin" {
    // Regression test: after resize/reflow, the viewport pin can end up at a
    // position where pin.y + rows > total_rows, causing getBottomRight to panic.

    // The plan is to pin viewport in history, then grow columns to unwrap rows.
    // The unwrap reduces total_rows, but the tracked pin moves to a position
    // that no longer has enough rows below it for the viewport height.
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 2, 10, null);
    defer s.deinit();

    // Make sure we have some history, in this case we have 30 rows of history
    try s.growRows(30);
    try testing.expectEqual(@as(usize, 40), s.totalRows());

    // Fill all rows with wrapped content (pairs that unwrap when cols increase)
    var it = s.pageIterator(.right_down, .{ .screen = .{} }, null);
    while (it.next()) |chunk| {
        const page = chunk.node.page();
        for (chunk.start..chunk.end) |y| {
            const rac = page.getRowAndCell(0, y);
            if (y % 2 == 0) {
                rac.row.wrap = true;
            } else {
                rac.row.wrap_continuation = true;
            }
            for (0..s.cols) |x| {
                page.getRowAndCell(x, y).cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = 'A' },
                };
            }
        }
    }

    // Pin viewport at row 28 (in history, 2 rows before active area at row 30).
    // After unwrap: row 28 -> row 14, total_rows 40 -> 20, active starts at 10.
    // Pin at 14 needs rows 14-23, but only 0-19 exist -> overflow.
    s.scroll(.{ .pin = s.pin(.{ .screen = .{ .y = 28 } }).? });
    try testing.expect(s.viewport == .pin);
    try testing.expect(s.getBottomRight(.viewport) != null);

    // Resize with reflow: unwraps rows, reducing total_rows
    try s.resize(.{ .cols = 4, .reflow = true });
    try testing.expectEqual(@as(usize, 4), s.cols);
    try testing.expect(s.totalRows() < 40);

    // Used to panic here, so test that we can get the bottom right.
    const br_after = s.getBottomRight(.viewport);
    try testing.expect(br_after != null);
}

test "PageList grow reuses non-standard page without leak" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Create a PageList with 3 * std_size max so we can fit multiple pages
    // but will still trigger reuse.
    var s = try init(alloc, 80, 24, 3 * std_size);
    defer s.deinit();

    // Increase the first page capacity to make it non-standard (larger than std_size).
    while (s.pages.first.?.page().memory.len <= std_size) {
        _ = try s.increaseCapacity(s.pages.first.?, .grapheme_bytes);
    }

    // The first page should now have non-standard memory size.
    try testing.expect(s.pages.first.?.page().memory.len > std_size);

    // First, fill up the first page's capacity
    const first_page = s.pages.first.?;
    while (first_page.rows() < first_page.capacity().rows) {
        _ = try s.grow();
    }

    // Now grow to create a second page
    _ = try s.grow();
    try testing.expect(s.pages.first != s.pages.last);

    // Continue growing until we exceed max_size AND the last page is full
    while (s.page_size + PagePool.item_size <= s.maxSize() or
        s.pages.last.?.rows() < s.pages.last.?.capacity().rows)
    {
        _ = try s.grow();
    }

    // The first page should still be non-standard
    try testing.expect(s.pages.first.?.page().memory.len > std_size);

    // Verify we have enough rows for active area (so prune path isn't skipped)
    try testing.expect(s.totalRows() >= s.rows);

    // Verify last page is full (so grow will need to allocate/reuse)
    try testing.expect(s.pages.last.?.page().size.rows == s.pages.last.?.capacity().rows);

    // Remember the first page memory pointer before the reuse attempt
    const first_page_ptr = s.pages.first.?;
    const first_page_mem_ptr = s.pages.first.?.page().memory.ptr;

    // Create a tracked pin pointing to the non-standard first page
    const tracked_pin = try s.trackPin(.{ .node = first_page_ptr, .x = 0, .y = 0 });
    defer s.untrackPin(tracked_pin);

    // Now grow one more time to trigger the reuse path. Since the first page
    // is non-standard, it should be destroyed (not reused). The testing
    // allocator will detect a leak if destroyNode doesn't properly free
    // the non-standard memory.
    _ = try s.grow();

    // After grow, check if the first page is a different one
    // (meaning the non-standard page was pruned, not reused at the end)
    // The original first page should no longer be the first page
    try testing.expect(s.pages.first.? != first_page_ptr);

    // If the non-standard page was properly destroyed and not reused,
    // the last page should not have the same memory pointer
    try testing.expect(s.pages.last.?.page().memory.ptr != first_page_mem_ptr);

    // The tracked pin should have been moved to the new first page and marked as garbage
    try testing.expectEqual(s.pages.first.?, tracked_pin.node);
    try testing.expectEqual(0, tracked_pin.x);
    try testing.expectEqual(0, tracked_pin.y);
    try testing.expect(tracked_pin.garbage);
}

test "PageList grow non-standard page prune protection" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // This test specifically verifies the fix for the bug where pruning a
    // non-standard page would cause totalRows() < self.rows.
    //
    // Bug trigger conditions (all must be true simultaneously):
    // 1. first page is non-standard (memory.len > std_size)
    // 2. page_size + PagePool.item_size > maxSize() (triggers prune consideration)
    // 3. pages.first != pages.last (have multiple pages)
    // 4. total_rows >= self.rows (have enough rows for active area)
    // 5. total_rows - first.size.rows + 1 < self.rows (prune would lose too many)

    // This is kind of magic and likely depends on std_size.
    const rows_count = 600;
    var s = try init(alloc, 80, rows_count, std_size);
    defer s.deinit();

    // Make the first page non-standard
    while (s.pages.first.?.page().memory.len <= std_size) {
        _ = try s.increaseCapacity(
            s.pages.first.?,
            .grapheme_bytes,
        );
    }
    try testing.expect(s.pages.first.?.page().memory.len > std_size);

    const first_page_node = s.pages.first.?;
    const first_page_cap = first_page_node.capacity().rows;

    // Fill first page to capacity
    while (first_page_node.rows() < first_page_cap) _ = try s.grow();

    // Grow until we have a second page (first page fills up first)
    var second_node: ?*List.Node = null;
    while (s.pages.first == s.pages.last) second_node = try s.grow();
    try testing.expect(s.pages.first != s.pages.last);

    // Fill the second page to capacity so that the next grow() triggers prune
    const last_node = s.pages.last.?;
    const second_cap = last_node.capacity().rows;
    while (last_node.rows() < second_cap) _ = try s.grow();

    // Now the last page is full. The next grow must either:
    // 1. Prune the first page and reuse it, OR
    // 2. Allocate a new page
    const total = s.totalRows();
    const would_remain = total - first_page_cap + 1;

    // Verify the bug condition is present: pruning first page would leave < rows
    try testing.expect(would_remain < s.rows);

    // Verify prune path conditions are met
    try testing.expect(s.pages.first != s.pages.last);
    try testing.expect(s.page_size + PagePool.item_size > s.maxSize());
    try testing.expect(s.totalRows() >= s.rows);

    // Verify last page is at capacity (so grow must prune or allocate new)
    try testing.expectEqual(second_cap, last_node.rows());

    // The next grow should trigger prune consideration.
    // Without the fix, this would destroy the non-standard first page,
    // leaving only second_cap + 1 rows, which is < self.rows.
    _ = try s.grow();

    // Verify the invariant holds - the fix prevents the destructive prune
    try testing.expect(s.totalRows() >= s.rows);
}

test "PageList resize (no reflow) more cols remaps pins in backfill path" {
    // Regression test: when resizeWithoutReflowGrowCols copies rows to a previous
    // page with spare capacity, tracked pins in those rows must be remapped.
    // Without the fix, pins become dangling pointers when the original page is destroyed.
    const testing = std.testing;
    const alloc = testing.allocator;

    const cols: size.CellCountInt = 5;
    const cap = try std_capacity.adjust(.{ .cols = cols });
    var s = try init(alloc, cols, cap.rows, null);
    defer s.deinit();

    // Grow until we have two pages.
    while (s.pages.first == s.pages.last) {
        _ = try s.grow();
    }
    const first_page = s.pages.first.?;
    const second_page = s.pages.last.?;
    try testing.expect(first_page != second_page);

    // Trim a history row so the first page has spare capacity.
    // This triggers the backfill path in resizeWithoutReflowGrowCols.
    s.eraseHistory(.{ .history = .{ .y = 0 } });
    try testing.expect(first_page.rows() < first_page.capacity().rows);

    // Ensure the resize takes the slow path (new capacity > current capacity).
    const new_cols: size.CellCountInt = cols + 1;
    const adjusted = try second_page.capacity().adjust(.{ .cols = new_cols });
    try testing.expect(second_page.capacity().cols < adjusted.cols);

    // Track a pin in row 0 of the second page. This row will be copied
    // to the first page during backfill and the pin must be remapped.
    const tracked = try s.trackPin(.{ .node = second_page, .x = 0, .y = 0 });
    defer s.untrackPin(tracked);

    // Write a marker character to the tracked cell so we can verify
    // the pin points to the correct cell after resize.
    const marker: u21 = 'X';
    tracked.rowAndCell().cell.* = .{
        .content_tag = .codepoint,
        .content = .{ .codepoint = marker },
    };

    try s.resize(.{ .cols = new_cols, .reflow = false });

    // Verify the pin points to a valid node still in the page list.
    var found = false;
    var it = s.pages.first;
    while (it) |node| : (it = node.next) {
        if (node == tracked.node) {
            found = true;
            break;
        }
    }
    try testing.expect(found);
    try testing.expect(tracked.y < tracked.node.rows());

    // Verify the pin still points to the cell with our marker content.
    const cell = tracked.rowAndCell().cell;
    try testing.expectEqual(.codepoint, cell.content_tag);
    try testing.expectEqual(marker, cell.content.codepoint);
}

test "PageList compact pool page produces exact-size heap page" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, 0);
    defer s.deinit();

    // A freshly created page is pool-owned at std_size.
    const node = s.pages.first.?;
    try testing.expectEqual(.pool, node.owned);
    try testing.expect(node.page().memory.len <= std_size);
    const original_size = node.page().size;

    // Compacting it should produce a much smaller exact-size heap page.
    const new_node = (try s.compact(node)).?;
    try testing.expectEqual(.heap, new_node.owned);
    try testing.expect(new_node.page().memory.len < std_size);
    try testing.expectEqual(original_size.rows, new_node.rows());
    try testing.expectEqual(original_size.cols, new_node.cols());
    try testing.expectEqual(new_node, s.pages.first.?);

    // Our page size accounting should exactly match the compacted
    // page since it is the only page in the list.
    try testing.expectEqual(new_node.page().memory.len, s.page_size);

    // Compacting again should be a no-op since it is already exact.
    try testing.expectEqual(null, try s.compact(new_node));
}

test "PageList compact then grow allocates new page" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();

    // Compact the only page. It now has no spare row capacity.
    const node = (try s.compact(s.pages.first.?)).?;
    try testing.expectEqual(node.rows(), node.capacity().rows);

    // Growing must allocate a fresh standard page from the pool,
    // exercising that a compacted page remains a valid live page.
    _ = try s.grow();
    try testing.expect(s.pages.first != s.pages.last);
    try testing.expectEqual(.pool, s.pages.last.?.owned);
    try testing.expectEqual(@as(usize, 25), s.totalRows());
}

test "PageList compact then reset frees heap pages" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, 0);
    defer s.deinit();

    // Compact the only page so the list contains a sub-std_size
    // heap-owned page.
    const node = (try s.compact(s.pages.first.?)).?;
    try testing.expectEqual(.heap, node.owned);
    try testing.expect(node.page().memory.len < std_size);

    // Reset must free the heap page (testing allocator catches leaks
    // and invalid frees) and rebuild from the pool.
    s.reset();
    try testing.expectEqual(.pool, s.pages.first.?.owned);
    try testing.expectEqual(@as(usize, s.rows), s.totalRows());
}

test "PageList compact then clone" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();

    // Write a marker so we can verify contents survive.
    {
        const node = s.pages.first.?;
        const rac = node.page().getRowAndCell(1, 2);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = 'X' },
        };
    }

    // Compact so the source list contains a sub-std_size heap page.
    const node = (try s.compact(s.pages.first.?)).?;
    try testing.expectEqual(.heap, node.owned);
    try testing.expect(node.page().memory.len < std_size);

    var s2 = try s.clone(alloc, .{
        .top = .{ .screen = .{} },
    });
    defer s2.deinit();
    try testing.expectEqual(@as(usize, s.rows), s2.totalRows());

    // Verify the marker survived the clone.
    {
        const node2 = s2.pages.first.?;
        const rac = node2.page().getRowAndCell(1, 2);
        try testing.expectEqual(@as(u21, 'X'), rac.cell.content.codepoint);
    }
}

test "PageList compact oversized page" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();

    // Grow until we have multiple pages
    const page1_node = s.pages.first.?;
    page1_node.page().pauseIntegrityChecks(true);
    for (0..page1_node.capacity().rows - page1_node.rows()) |_| {
        _ = try s.grow();
    }
    page1_node.page().pauseIntegrityChecks(false);
    _ = try s.grow();
    try testing.expect(s.pages.first != s.pages.last);

    var node = s.pages.first.?;

    // Write content to verify it's preserved
    {
        const page = node.page();
        for (0..page.size.rows) |y| {
            for (0..s.cols) |x| {
                const rac = page.getRowAndCell(x, y);
                rac.cell.* = .{
                    .content_tag = .codepoint,
                    .content = .{ .codepoint = @intCast(x + y * s.cols) },
                };
            }
        }
    }

    // Create a tracked pin on this page
    const tracked = try s.trackPin(.{ .node = node, .x = 5, .y = 10 });
    defer s.untrackPin(tracked);

    // Make the page oversized
    while (node.page().memory.len <= std_size) {
        node = try s.increaseCapacity(node, .grapheme_bytes);
    }
    try testing.expect(node.page().memory.len > std_size);
    const oversized_len = node.page().memory.len;
    const original_size = node.page().size;
    const second_node = node.next.?;

    // Set dirty flag after increaseCapacity
    node.page().dirty = true;

    // Compact the page
    const new_node = try s.compact(node);
    try testing.expect(new_node != null);

    // Verify memory is smaller
    try testing.expect(new_node.?.page().memory.len < oversized_len);

    // Verify size preserved
    try testing.expectEqual(original_size.rows, new_node.?.rows());
    try testing.expectEqual(original_size.cols, new_node.?.cols());

    // Verify dirty flag preserved
    try testing.expect(new_node.?.page().dirty);

    // Verify linked list integrity
    try testing.expectEqual(new_node.?, s.pages.first.?);
    try testing.expectEqual(null, new_node.?.prev);
    try testing.expectEqual(second_node, new_node.?.next);
    try testing.expectEqual(new_node.?, second_node.prev);

    // Verify pin updated correctly
    try testing.expectEqual(new_node.?, tracked.node);
    try testing.expectEqual(@as(size.CellCountInt, 5), tracked.x);
    try testing.expectEqual(@as(size.CellCountInt, 10), tracked.y);

    // Verify content preserved
    const page = new_node.?.page();
    for (0..page.size.rows) |y| {
        for (0..s.cols) |x| {
            const rac = page.getRowAndCell(x, y);
            try testing.expectEqual(
                @as(u21, @intCast(x + y * s.cols)),
                rac.cell.content.codepoint,
            );
        }
    }
}

test "PageList destroyed pool page reuse is zeroed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, null);
    defer s.deinit();

    // Create a page and scribble over its entire backing memory,
    // then destroy it so the buffer returns to the pool free list.
    const node = try s.createPage(.{ .cap = initialCapacity(80) });
    node.page().size.rows = 1;
    const mem_ptr = node.page().memory.ptr;
    @memset(node.page().memory, 0xAA);
    s.destroyNode(node);

    // Reusing the buffer must produce a fully valid, zeroed page.
    const node2 = try s.createPage(.{ .cap = initialCapacity(80) });
    try testing.expectEqual(mem_ptr, node2.page().memory.ptr);
    node2.page().size.rows = node2.capacity().rows;

    const cells_len = @as(usize, node2.capacity().cols) *
        @as(usize, node2.capacity().rows);
    const cells = node2.page().cells.ptr(node2.page().memory)[0..cells_len];
    try testing.expect(std.mem.allEqual(
        u64,
        @as([]const u64, @ptrCast(cells)),
        0,
    ));
    node2.page().assertIntegrity();
    s.destroyNode(node2);
}

test "PageList increaseCapacity from zero-capacity dimensions" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, 0);
    defer s.deinit();

    // Compact the only page. A plain page has no styled, grapheme,
    // or hyperlink content so the exact capacity is zero in every
    // managed dimension.
    var node = (try s.compact(s.pages.first.?)).?;
    try testing.expectEqual(0, node.capacity().styles);
    try testing.expectEqual(0, node.capacity().grapheme_bytes);
    try testing.expectEqual(0, node.capacity().string_bytes);
    try testing.expectEqual(0, node.capacity().hyperlink_bytes);

    // Increasing each dimension from zero must actually grow it.
    // Regression: 0 * 2 == 0 used to "succeed" without growing,
    // which turned caller retry loops into infinite loops.
    node = try s.increaseCapacity(node, .styles);
    try testing.expect(node.capacity().styles > 0);
    node = try s.increaseCapacity(node, .grapheme_bytes);
    try testing.expect(node.capacity().grapheme_bytes > 0);
    node = try s.increaseCapacity(node, .string_bytes);
    try testing.expect(node.capacity().string_bytes > 0);
    node = try s.increaseCapacity(node, .hyperlink_bytes);
    try testing.expect(node.capacity().hyperlink_bytes > 0);

    // Increasing a non-zero dimension still doubles.
    const styles = node.capacity().styles;
    node = try s.increaseCapacity(node, .styles);
    try testing.expectEqual(styles * 2, node.capacity().styles);
}

test "PageList compact after increaseCapacity" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 80, 24, 0);
    defer s.deinit();

    var node = s.pages.first.?;

    // Grow the page capacity. The content is unchanged, so compaction
    // should always shrink it back down to an exact-size heap page.
    node = try s.increaseCapacity(node, .grapheme_bytes);
    const grown_len = node.page().memory.len;

    const new_node = (try s.compact(node)).?;
    try testing.expectEqual(.heap, new_node.owned);
    try testing.expect(new_node.page().memory.len < grown_len);
    try testing.expect(new_node.page().memory.len < std_size);
}

test "PageList split at middle row" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 10, 0);
    defer s.deinit();

    const page = s.pages.first.?.page();

    // Write content to rows: row 0 gets codepoint 0, row 1 gets 1, etc.
    for (0..page.size.rows) |y| {
        const rac = page.getRowAndCell(0, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = @intCast(y) },
        };
    }

    // Split at row 5 (middle)
    const split_pin: Pin = .{ .node = s.pages.first.?, .y = 5, .x = 0 };
    try s.split(split_pin);

    // Verify two pages exist
    try testing.expect(s.pages.first != null);
    try testing.expect(s.pages.first.?.next != null);

    const first_page = s.pages.first.?.page();
    const second_page = s.pages.first.?.next.?.page();

    // First page should have rows 0-4 (5 rows)
    try testing.expectEqual(@as(usize, 5), first_page.size.rows);
    // Second page should have rows 5-9 (5 rows)
    try testing.expectEqual(@as(usize, 5), second_page.size.rows);

    // Verify content in first page is preserved (rows 0-4 have codepoints 0-4)
    for (0..5) |y| {
        const rac = first_page.getRowAndCell(0, y);
        try testing.expectEqual(@as(u21, @intCast(y)), rac.cell.content.codepoint);
    }

    // Verify content in second page (original rows 5-9, now at y=0-4)
    for (0..5) |y| {
        const rac = second_page.getRowAndCell(0, y);
        try testing.expectEqual(@as(u21, @intCast(y + 5)), rac.cell.content.codepoint);
    }
}

test "PageList split at row 0 is no-op" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 10, 0);
    defer s.deinit();

    const page = s.pages.first.?.page();

    // Write content to all rows
    for (0..page.size.rows) |y| {
        const rac = page.getRowAndCell(0, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = @intCast(y) },
        };
    }

    // Split at row 0 should be a no-op
    const split_pin: Pin = .{ .node = s.pages.first.?, .y = 0, .x = 0 };
    try s.split(split_pin);

    // Verify only one page exists (no split occurred)
    try testing.expect(s.pages.first != null);
    try testing.expect(s.pages.first.?.next == null);

    // Verify all content is still in the original page
    try testing.expectEqual(@as(usize, 10), page.size.rows);
    for (0..10) |y| {
        const rac = page.getRowAndCell(0, y);
        try testing.expectEqual(@as(u21, @intCast(y)), rac.cell.content.codepoint);
    }
}

test "PageList split at last row" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 10, 0);
    defer s.deinit();

    const page = s.pages.first.?.page();

    // Write content to all rows
    for (0..page.size.rows) |y| {
        const rac = page.getRowAndCell(0, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = @intCast(y) },
        };
    }

    // Split at last row (row 9)
    const split_pin: Pin = .{ .node = s.pages.first.?, .y = 9, .x = 0 };
    try s.split(split_pin);

    // Verify two pages exist
    try testing.expect(s.pages.first != null);
    try testing.expect(s.pages.first.?.next != null);

    const first_page = s.pages.first.?.page();
    const second_page = s.pages.first.?.next.?.page();

    // First page should have 9 rows
    try testing.expectEqual(@as(usize, 9), first_page.size.rows);
    // Second page should have 1 row
    try testing.expectEqual(@as(usize, 1), second_page.size.rows);

    // Verify content in second page (original row 9, now at y=0)
    const rac = second_page.getRowAndCell(0, 0);
    try testing.expectEqual(@as(u21, 9), rac.cell.content.codepoint);
}

test "PageList split single row page returns OutOfSpace" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Initialize with 1 row
    var s = try init(alloc, 10, 1, 0);
    defer s.deinit();

    const split_pin: Pin = .{ .node = s.pages.first.?, .y = 0, .x = 0 };
    const result = s.split(split_pin);

    try testing.expectError(error.OutOfSpace, result);
}

test "PageList split moves tracked pins" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 10, 0);
    defer s.deinit();

    // Track a pin at row 7
    const tracked = try s.trackPin(.{ .node = s.pages.first.?, .y = 7, .x = 3 });
    defer s.untrackPin(tracked);

    // Split at row 5
    const split_pin: Pin = .{ .node = s.pages.first.?, .y = 5, .x = 0 };
    try s.split(split_pin);

    // The tracked pin should now be in the second page
    try testing.expect(tracked.node == s.pages.first.?.next.?);
    // y should be adjusted: was 7, split at 5, so new y = 7 - 5 = 2
    try testing.expectEqual(@as(usize, 2), tracked.y);
    // x should remain unchanged
    try testing.expectEqual(@as(usize, 3), tracked.x);
}

test "PageList split tracked pin before split point unchanged" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 10, 0);
    defer s.deinit();

    const original_node = s.pages.first.?;

    // Track a pin at row 2 (before the split point)
    const tracked = try s.trackPin(.{ .node = original_node, .y = 2, .x = 5 });
    defer s.untrackPin(tracked);

    // Split at row 5
    const split_pin: Pin = .{ .node = original_node, .y = 5, .x = 0 };
    try s.split(split_pin);

    // The tracked pin should remain in the original page
    try testing.expect(tracked.node == s.pages.first.?);
    // y and x should be unchanged
    try testing.expectEqual(@as(usize, 2), tracked.y);
    try testing.expectEqual(@as(usize, 5), tracked.x);
}

test "PageList split tracked pin at split point moves to new page" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 10, 0);
    defer s.deinit();

    const original_node = s.pages.first.?;

    // Track a pin at the exact split point (row 5)
    const tracked = try s.trackPin(.{ .node = original_node, .y = 5, .x = 4 });
    defer s.untrackPin(tracked);

    // Split at row 5
    const split_pin: Pin = .{ .node = original_node, .y = 5, .x = 0 };
    try s.split(split_pin);

    // The tracked pin should be in the new page
    try testing.expect(tracked.node == s.pages.first.?.next.?);
    // y should be 0 since it was at the split point: 5 - 5 = 0
    try testing.expectEqual(@as(usize, 0), tracked.y);
    // x should remain unchanged
    try testing.expectEqual(@as(usize, 4), tracked.x);
}

test "PageList split multiple tracked pins across regions" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 10, 0);
    defer s.deinit();

    const original_node = s.pages.first.?;

    // Track multiple pins in different regions
    const pin_before = try s.trackPin(.{ .node = original_node, .y = 1, .x = 0 });
    defer s.untrackPin(pin_before);
    const pin_at_split = try s.trackPin(.{ .node = original_node, .y = 5, .x = 2 });
    defer s.untrackPin(pin_at_split);
    const pin_after1 = try s.trackPin(.{ .node = original_node, .y = 7, .x = 3 });
    defer s.untrackPin(pin_after1);
    const pin_after2 = try s.trackPin(.{ .node = original_node, .y = 9, .x = 8 });
    defer s.untrackPin(pin_after2);

    // Split at row 5
    const split_pin: Pin = .{ .node = original_node, .y = 5, .x = 0 };
    try s.split(split_pin);

    const first_page = s.pages.first.?;
    const second_page = first_page.next.?;

    // Pin before split point stays in original page
    try testing.expect(pin_before.node == first_page);
    try testing.expectEqual(@as(usize, 1), pin_before.y);
    try testing.expectEqual(@as(usize, 0), pin_before.x);

    // Pin at split point moves to new page with y=0
    try testing.expect(pin_at_split.node == second_page);
    try testing.expectEqual(@as(usize, 0), pin_at_split.y);
    try testing.expectEqual(@as(usize, 2), pin_at_split.x);

    // Pins after split point move to new page with adjusted y
    try testing.expect(pin_after1.node == second_page);
    try testing.expectEqual(@as(usize, 2), pin_after1.y); // 7 - 5 = 2
    try testing.expectEqual(@as(usize, 3), pin_after1.x);

    try testing.expect(pin_after2.node == second_page);
    try testing.expectEqual(@as(usize, 4), pin_after2.y); // 9 - 5 = 4
    try testing.expectEqual(@as(usize, 8), pin_after2.x);
}

test "PageList split tracked viewport_pin in split region moves correctly" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 10, 0);
    defer s.deinit();

    const original_node = s.pages.first.?;

    // Set viewport_pin to row 7 (after split point)
    s.viewport_pin.node = original_node;
    s.viewport_pin.y = 7;
    s.viewport_pin.x = 6;

    // Split at row 5
    const split_pin: Pin = .{ .node = original_node, .y = 5, .x = 0 };
    try s.split(split_pin);

    // viewport_pin should be in the new page
    try testing.expect(s.viewport_pin.node == s.pages.first.?.next.?);
    // y should be adjusted: 7 - 5 = 2
    try testing.expectEqual(@as(usize, 2), s.viewport_pin.y);
    // x should remain unchanged
    try testing.expectEqual(@as(usize, 6), s.viewport_pin.x);
}

test "PageList split middle page preserves linked list order" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Create a single page with 12 rows
    var s = try init(alloc, 10, 12, 0);
    defer s.deinit();

    // Split at row 4 to create: page1 (rows 0-3), page2 (rows 4-11)
    const first_node = s.pages.first.?;
    const split_pin1: Pin = .{ .node = first_node, .y = 4, .x = 0 };
    try s.split(split_pin1);

    // Now we have 2 pages
    const page1 = s.pages.first.?;
    const page2 = s.pages.first.?.next.?;
    try testing.expectEqual(@as(usize, 4), page1.rows());
    try testing.expectEqual(@as(usize, 8), page2.rows());

    // Split page2 at row 4 to create: page1 -> page2 (rows 0-3) -> page3 (rows 4-7)
    const split_pin2: Pin = .{ .node = page2, .y = 4, .x = 0 };
    try s.split(split_pin2);

    // Now we have 3 pages
    const first = s.pages.first.?;
    const middle = first.next.?;
    const last = middle.next.?;

    // Verify linked list order: first -> middle -> last
    try testing.expectEqual(page1, first);
    try testing.expectEqual(page2, middle);
    try testing.expectEqual(s.pages.last.?, last);

    // Verify prev pointers
    try testing.expect(first.prev == null);
    try testing.expectEqual(first, middle.prev.?);
    try testing.expectEqual(middle, last.prev.?);

    // Verify next pointers
    try testing.expectEqual(middle, first.next.?);
    try testing.expectEqual(last, middle.next.?);
    try testing.expect(last.next == null);

    // Verify row counts
    try testing.expectEqual(@as(usize, 4), first.rows());
    try testing.expectEqual(@as(usize, 4), middle.rows());
    try testing.expectEqual(@as(usize, 4), last.rows());
}

test "PageList split last page makes new page the last" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Create a single page with 10 rows
    var s = try init(alloc, 10, 10, 0);
    defer s.deinit();

    // Split to create 2 pages first
    const first_node = s.pages.first.?;
    const split_pin1: Pin = .{ .node = first_node, .y = 5, .x = 0 };
    try s.split(split_pin1);

    // Now split the last page
    const last_before_split = s.pages.last.?;
    try testing.expectEqual(@as(usize, 5), last_before_split.rows());

    const split_pin2: Pin = .{ .node = last_before_split, .y = 2, .x = 0 };
    try s.split(split_pin2);

    // The new page should be the new last
    const new_last = s.pages.last.?;
    try testing.expect(new_last != last_before_split);
    try testing.expectEqual(last_before_split, new_last.prev.?);
    try testing.expect(new_last.next == null);

    // Verify row counts: original last has 2 rows, new last has 3 rows
    try testing.expectEqual(@as(usize, 2), last_before_split.rows());
    try testing.expectEqual(@as(usize, 3), new_last.rows());
}

test "PageList split first page keeps original as first" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Create 2 pages by splitting
    var s = try init(alloc, 10, 10, 0);
    defer s.deinit();

    const original_first = s.pages.first.?;
    const split_pin1: Pin = .{ .node = original_first, .y = 5, .x = 0 };
    try s.split(split_pin1);

    // Get second page (created by first split)
    const second_page = s.pages.first.?.next.?;

    // Now split the first page again
    const split_pin2: Pin = .{ .node = s.pages.first.?, .y = 2, .x = 0 };
    try s.split(split_pin2);

    // Original first should still be first
    try testing.expectEqual(original_first, s.pages.first.?);
    try testing.expect(s.pages.first.?.prev == null);

    // New page should be inserted between first and second
    const inserted = s.pages.first.?.next.?;
    try testing.expect(inserted != second_page);
    try testing.expectEqual(second_page, inserted.next.?);

    // Verify row counts: first has 2, inserted has 3, second has 5
    try testing.expectEqual(@as(usize, 2), s.pages.first.?.rows());
    try testing.expectEqual(@as(usize, 3), inserted.rows());
    try testing.expectEqual(@as(usize, 5), second_page.rows());
}

test "PageList split preserves wrap flags" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 10, 0);
    defer s.deinit();

    const page = s.pages.first.?.page();

    // Set wrap flags on rows that will be in the second page after split
    // Row 5: wrap = true (this is the start of a wrapped line)
    // Row 6: wrap_continuation = true (this continues the wrap)
    // Row 7: wrap = true, wrap_continuation = true (wrapped and continues)
    {
        const rac5 = page.getRowAndCell(0, 5);
        rac5.row.wrap = true;

        const rac6 = page.getRowAndCell(0, 6);
        rac6.row.wrap_continuation = true;

        const rac7 = page.getRowAndCell(0, 7);
        rac7.row.wrap = true;
        rac7.row.wrap_continuation = true;
    }

    // Split at row 5
    const split_pin: Pin = .{ .node = s.pages.first.?, .y = 5, .x = 0 };
    try s.split(split_pin);

    const second_page = s.pages.first.?.next.?.page();

    // Verify wrap flags are preserved in new page
    // Original row 5 is now row 0 in second page
    {
        const rac0 = second_page.getRowAndCell(0, 0);
        try testing.expect(rac0.row.wrap);
        try testing.expect(!rac0.row.wrap_continuation);
    }

    // Original row 6 is now row 1 in second page
    {
        const rac1 = second_page.getRowAndCell(0, 1);
        try testing.expect(!rac1.row.wrap);
        try testing.expect(rac1.row.wrap_continuation);
    }

    // Original row 7 is now row 2 in second page
    {
        const rac2 = second_page.getRowAndCell(0, 2);
        try testing.expect(rac2.row.wrap);
        try testing.expect(rac2.row.wrap_continuation);
    }
}

test "PageList split preserves styled cells" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 10, 0);
    defer s.deinit();

    const page = s.pages.first.?.page();

    // Create a style and apply it to cells in rows 5-7 (which will be in the second page)
    const style: stylepkg.Style = .{ .flags = .{ .bold = true } };
    const style_id = try page.styles.add(page.memory, style);

    for (5..8) |y| {
        const rac = page.getRowAndCell(0, y);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = 'S' },
            .style_id = style_id,
        };
        rac.row.styled = true;
        page.styles.use(page.memory, style_id);
    }
    // Release the extra ref from add
    page.styles.release(page.memory, style_id);

    // Split at row 5
    const split_pin: Pin = .{ .node = s.pages.first.?, .y = 5, .x = 0 };
    try s.split(split_pin);

    const first_page = s.pages.first.?.page();
    const second_page = s.pages.first.?.next.?.page();

    // First page should have no styles (all styled rows moved to second page)
    try testing.expectEqual(@as(usize, 0), first_page.styles.count());

    // Second page should have exactly 1 style (the bold style, used by 3 cells)
    try testing.expectEqual(@as(usize, 1), second_page.styles.count());

    // Verify styled cells are preserved in new page
    for (0..3) |y| {
        const rac = second_page.getRowAndCell(0, y);
        try testing.expectEqual(@as(u21, 'S'), rac.cell.content.codepoint);
        try testing.expect(rac.cell.style_id != 0);

        const got_style = second_page.styles.get(second_page.memory, rac.cell.style_id);
        try testing.expect(got_style.flags.bold);
        try testing.expect(rac.row.styled);
    }
}

test "PageList split preserves grapheme clusters" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 10, 0);
    defer s.deinit();

    const page = s.pages.first.?.page();

    // Add a grapheme cluster to row 6 (will be row 1 in second page after split at 5)
    {
        const rac = page.getRowAndCell(0, 6);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = 0x1F468 }, // Man emoji
        };
        try page.setGraphemes(rac.row, rac.cell, &.{
            0x200D, // ZWJ
            0x1F469, // Woman emoji
        });
    }

    // Split at row 5
    const split_pin: Pin = .{ .node = s.pages.first.?, .y = 5, .x = 0 };
    try s.split(split_pin);

    const first_page = s.pages.first.?.page();
    const second_page = s.pages.first.?.next.?.page();

    // First page should have no graphemes (the grapheme row moved to second page)
    try testing.expectEqual(@as(usize, 0), first_page.graphemeCount());

    // Second page should have exactly 1 grapheme
    try testing.expectEqual(@as(usize, 1), second_page.graphemeCount());

    // Verify grapheme is preserved in new page (original row 6 is now row 1)
    {
        const rac = second_page.getRowAndCell(0, 1);
        try testing.expectEqual(@as(u21, 0x1F468), rac.cell.content.codepoint);
        try testing.expect(rac.row.grapheme);

        const cps = second_page.lookupGrapheme(rac.cell).?;
        try testing.expectEqual(@as(usize, 2), cps.len);
        try testing.expectEqual(@as(u21, 0x200D), cps[0]);
        try testing.expectEqual(@as(u21, 0x1F469), cps[1]);
    }
}

test "PageList split preserves hyperlinks" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 10, 10, 0);
    defer s.deinit();

    const page = s.pages.first.?.page();

    // Add a hyperlink to row 7 (will be row 2 in second page after split at 5)
    const hyperlink_id = try page.insertHyperlink(.{
        .id = .{ .implicit = 0 },
        .uri = "https://example.com",
    });
    {
        const rac = page.getRowAndCell(0, 7);
        rac.cell.* = .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = 'L' },
        };
        try page.setHyperlink(rac.row, rac.cell, hyperlink_id);
    }

    // Split at row 5
    const split_pin: Pin = .{ .node = s.pages.first.?, .y = 5, .x = 0 };
    try s.split(split_pin);

    const first_page = s.pages.first.?.page();
    const second_page = s.pages.first.?.next.?.page();

    // First page should have no hyperlinks (the hyperlink row moved to second page)
    try testing.expectEqual(@as(usize, 0), first_page.hyperlink_set.count());

    // Second page should have exactly 1 hyperlink
    try testing.expectEqual(@as(usize, 1), second_page.hyperlink_set.count());

    // Verify hyperlink is preserved in new page (original row 7 is now row 2)
    {
        const rac = second_page.getRowAndCell(0, 2);
        try testing.expectEqual(@as(u21, 'L'), rac.cell.content.codepoint);
        try testing.expect(rac.cell.hyperlink);

        const link_id = second_page.lookupHyperlink(rac.cell).?;
        const link = second_page.hyperlink_set.get(second_page.memory, link_id);
        try testing.expectEqualStrings("https://example.com", link.uri.slice(second_page.memory));
    }
}
