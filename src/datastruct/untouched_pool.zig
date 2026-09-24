const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

/// A fixed-size item pool whose bookkeeping never touches item memory.
///
/// std.heap.MemoryPool keeps its free list inside the items intrusively,
/// meaning it has to touch allocated item memory. For memory that is
/// demand-paged, that write forces the OS to create a physical page
/// for nothing (to mark it free!).
///
/// This pool keeps the free list in a separate array allocated from a
/// general-purpose allocator and allocates every item individually from
/// the item allocator with the requested alignment. The pool never reads
/// or writes an item until it is needed.
///
/// Contracts:
///
///   - The pool never zeroes. Callers that need zeroed items must use an
///     item allocator that returns zeroed memory and must zero (or
///     decommit) an item before destroy().
///   - destroy() never allocates and never fails: create() reserves a
///     free-list slot for every live item before allocating a new one.
///   - The pool tracks free items only. Every item must be returned with
///     destroy() or release() before reset() or deinit(), or it leaks.
///     This is asserted in safe builds.
///
/// The tradeoff is that this isn't as fast as std.heap.MemoryPool, its
/// not as cache friendly. But benchmarks show that the cost is minimal
/// and if the tradeoff of not touching the memory is important, then
/// this pays off.
pub fn UntouchedPool(comptime Item: type, comptime alignment: Alignment) type {
    return struct {
        const Self = @This();

        pub const item_size = @sizeOf(Item);
        pub const item_alignment: Alignment = alignment.max(.of(Item));
        pub const ItemPtr = *align(item_alignment.toByteUnits()) Item;
        pub const ResetMode = std.heap.ArenaAllocator.ResetMode;

        /// The allocator items are allocated from.
        allocator: Allocator,

        /// The general-purpose allocator for the free list.
        gpa: Allocator,

        /// Free items. The most recently destroyed item is handed out first.
        free: std.ArrayList(ItemPtr),

        /// Number of items currently allocated from the item allocator,
        /// free or in use. `free.capacity >= live` always holds so that
        /// destroy() never has to grow the free list.
        live: usize,

        /// Create a pool with `preheat` items already allocated.
        pub fn initCapacity(
            gpa: Allocator,
            item_alloc: Allocator,
            preheat: usize,
        ) Allocator.Error!Self {
            var self: Self = .{
                .allocator = item_alloc,
                .gpa = gpa,
                .free = .empty,
                .live = 0,
            };
            errdefer self.deinit();

            try self.free.ensureTotalCapacityPrecise(gpa, preheat);
            for (0..preheat) |_| {
                const item = try self.allocItem();
                self.free.appendAssumeCapacity(item);
            }

            return self;
        }

        /// Free all items and the free list. Every item must have been
        /// returned with destroy() or release().
        pub fn deinit(self: *Self) void {
            assert(self.live == self.free.items.len);
            for (self.free.items) |item| self.allocator.free(bytes(item));
            self.free.deinit(self.gpa);
            self.* = undefined;
        }

        /// Free items so that the retained free items fit `mode`. Every
        /// item must have been returned with destroy() or release().
        ///
        /// This mirrors std.heap.MemoryPool.reset; it always succeeds
        /// (returns true) because nothing is reallocated.
        pub fn reset(self: *Self, mode: ResetMode) bool {
            assert(self.live == self.free.items.len);
            const retain_bytes: usize = switch (mode) {
                .free_all => 0,
                .retain_capacity => return true,
                .retain_with_limit => |limit| limit,
            };

            const retain_items = retain_bytes / item_size;
            while (self.free.items.len > retain_items) {
                const item = self.free.pop().?;
                self.allocator.free(bytes(item));
                self.live -= 1;
            }

            return true;
        }

        /// Get an item. This pops a free item without touching it or,
        /// when none is free, allocates a new one from the item
        /// allocator.
        pub fn create(self: *Self) Allocator.Error!ItemPtr {
            if (self.free.pop()) |item| return item;

            // Reserve the free-list slot for the new item before
            // allocating it so that destroy() can never fail.
            try self.free.ensureTotalCapacity(self.gpa, self.live + 1);
            return try self.allocItem();
        }

        /// Return an item to the free list for reuse. The item is not
        /// modified or zeroed so it is up to the caller.
        pub fn destroy(self: *Self, item: ItemPtr) void {
            assert(self.free.items.len < self.live);
            self.free.appendAssumeCapacity(item);
        }

        /// Return an item straight to the item allocator instead of the
        /// free list. This is for teardown paths that would otherwise
        /// have to zero an item only for it to be freed moments later.
        pub fn release(self: *Self, item: ItemPtr) void {
            assert(self.free.items.len < self.live);
            self.allocator.free(bytes(item));
            self.live -= 1;
        }

        fn allocItem(self: *Self) Allocator.Error!ItemPtr {
            assert(self.free.capacity > self.live);
            const memory = try self.allocator.alignedAlloc(
                u8,
                item_alignment,
                item_size,
            );
            self.live += 1;
            return @ptrCast(memory.ptr);
        }

        fn bytes(item: ItemPtr) []align(item_alignment.toByteUnits()) u8 {
            return std.mem.asBytes(item);
        }
    };
}

/// Test item: one minimum OS page, page-aligned, like a terminal page.
const TestPool = UntouchedPool(
    [std.heap.page_size_min]u8,
    .fromByteUnits(std.heap.page_size_min),
);

test "UntouchedPool: create, destroy, reuse" {
    const testing = std.testing;
    var pool: TestPool = try .initCapacity(testing.allocator, testing.allocator, 0);
    defer pool.deinit();

    const a = try pool.create();
    const b = try pool.create();
    const c = try pool.create();
    try testing.expect(a != b);
    try testing.expect(a != c);
    try testing.expect(b != c);

    // Freed items are recycled, most recent first.
    pool.destroy(a);
    pool.destroy(b);
    try testing.expectEqual(b, try pool.create());
    try testing.expectEqual(a, try pool.create());

    pool.destroy(a);
    pool.destroy(b);
    pool.destroy(c);
}

test "UntouchedPool: create and destroy never touch items" {
    const testing = std.testing;
    const preheat = 4;

    // Back the item allocator with memory we can inspect.
    const backing = try testing.allocator.alignedAlloc(
        u8,
        .fromByteUnits(std.heap.page_size_min),
        preheat * TestPool.item_size,
    );
    defer testing.allocator.free(backing);
    var fba: std.heap.FixedBufferAllocator = .init(backing);

    var pool: TestPool = try .initCapacity(
        testing.allocator,
        fba.allocator(),
        preheat,
    );
    defer pool.deinit();
    try testing.expectEqual(preheat * TestPool.item_size, fba.end_index);

    // Lay the sentinel down after preheat: allocation itself may write
    // (the Allocator interface fills fresh memory with undefined in
    // safe builds, which valgrind also tracks). The sentinel must differ
    // from Zig's 0xAA undefined pattern so that any write is visible.
    const sentinel: u8 = 0x5A;
    @memset(backing, sentinel);

    // Every preheated item comes out untouched and without allocating.
    var items: [preheat]TestPool.ItemPtr = undefined;
    for (&items) |*item| {
        item.* = try pool.create();
        try testing.expectEqual(preheat * TestPool.item_size, fba.end_index);
        try testing.expect(std.mem.allEqual(u8, item.*, sentinel));
    }

    // Destroying and re-creating doesn't touch them either.
    for (items) |item| pool.destroy(item);
    try testing.expect(std.mem.allEqual(u8, backing, sentinel));
    for (&items) |*item| {
        item.* = try pool.create();
        try testing.expect(std.mem.allEqual(u8, item.*, sentinel));
    }
    for (items) |item| pool.destroy(item);
}

test "UntouchedPool: destroy never allocates from the general allocator" {
    const testing = std.testing;

    // A general allocator that fails every allocation: after create has
    // reserved the free-list slot, destroy must not need it.
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{
        .fail_index = 0,
    });

    var pool: TestPool = try .initCapacity(testing.allocator, testing.allocator, 0);
    defer pool.deinit();

    // The pool grows the free list through its own gpa, so swap in the
    // failing one only around destroy.
    var items: [64]TestPool.ItemPtr = undefined;
    for (&items) |*item| item.* = try pool.create();
    const gpa = pool.gpa;
    pool.gpa = failing.allocator();
    for (items) |item| pool.destroy(item);
    pool.gpa = gpa;
    try testing.expectEqual(items.len, pool.free.items.len);
}

test "UntouchedPool: reset retains at most the limit" {
    const testing = std.testing;
    var pool: TestPool = try .initCapacity(testing.allocator, testing.allocator, 4);
    defer pool.deinit();

    // Free everything above the limit
    try testing.expect(pool.reset(.{ .retain_with_limit = 2 * TestPool.item_size }));
    try testing.expectEqual(2, pool.free.items.len);
    try testing.expectEqual(2, pool.live);

    // retain_capacity keeps everything
    try testing.expect(pool.reset(.retain_capacity));
    try testing.expectEqual(2, pool.free.items.len);

    // Retained items are handed out without allocating; new items
    // beyond them are allocated as needed.
    const a = try pool.create();
    const b = try pool.create();
    try testing.expectEqual(2, pool.live);
    const c = try pool.create();
    try testing.expectEqual(3, pool.live);
    pool.destroy(a);
    pool.destroy(b);
    pool.destroy(c);

    try testing.expect(pool.reset(.free_all));
    try testing.expectEqual(0, pool.free.items.len);
    try testing.expectEqual(0, pool.live);
}

test "UntouchedPool: release frees immediately" {
    const testing = std.testing;
    var pool: TestPool = try .initCapacity(testing.allocator, testing.allocator, 1);
    defer pool.deinit();

    const a = try pool.create();
    const b = try pool.create();
    try testing.expectEqual(2, pool.live);
    pool.release(a);
    try testing.expectEqual(1, pool.live);
    try testing.expectEqual(0, pool.free.items.len);
    pool.destroy(b);
    try testing.expectEqual(1, pool.free.items.len);
}
