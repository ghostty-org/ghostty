const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

/// A memory pool of wasm-page-multiple-sized items backed directly by
/// wasm linear memory, for wasm targets only.
///
/// This is necessary for two reasons: the std.heap.MemoryPool grows 1.5x
/// at each growth point. The backing allocator for that is usually a GPA
/// which is the BrkAllocator for wasm. This grows by power-of-two
/// big-allocation slots. If you pair these together you get a massive
/// permanent linear memory growth. Native (non-wasm) targets don't care
/// because unused virtual mappings are effectively free, but this isn't
/// exactly true for Wasm runtimes.
///
/// This pool instead grows exactly @sizeOf(Item) bytes of fresh linear
/// memory per item with memory.grow (which also guarantees wasm-page
/// alignment and zeroing) and recycles freed items through a free list
/// that is container-level, i.e. shared by every pool of the same Item
/// type in the module instance. Every freed item is immediately
/// reusable by every pool, and each item costs exactly @sizeOf(Item)
/// reserved bytes, ever.
///
/// The "shared by every pool of the same Item type" is really important:
/// the normal Ghostty memory pool is per-terminal. This one is per-module.
/// The Ghostty wasm modules are not multi-threaded so this doesn't require
/// any synchronization. But this means that all terminals share one pool
/// so memory doesn't balloon like crazy that way either.
///
/// Requirements on Item:
///
///   - @sizeOf(Item) must be a nonzero multiple of the wasm page size
///     (64KiB), since memory.grow allocates in whole pages. This is
///     also what makes the pool exact-fit: any other size would strand
///     the remainder of the last page.
///   - Natural alignment must be at most the wasm page size.
///
/// Free-list items are dirty except that their first pointer-size bytes
/// hold the intrusive free-list node, exactly like the std MemoryPool.
/// Callers that need zeroed items must zero them (fresh items from
/// memory.grow are zero by the wasm spec; recycled items retain
/// whatever the caller left, so zero either on destroy or on create).
///
/// The API mirrors the native page pool (datastruct.UntouchedPool:
/// initCapacity/deinit/reset/create/destroy plus the allocator field),
/// so PageList can swap them at comptime.
pub fn WasmPagePool(comptime Item: type) type {
    return struct {
        const Self = @This();

        comptime {
            if (builtin.target.cpu.arch.isWasm()) {
                // The shared free list (and wasm's single linear
                // memory) requires a single-threaded target.
                assert(builtin.single_threaded);
                // Items are whole wasm pages
                assert(item_size > 0);
                assert(item_size % std.heap.page_size_min == 0);
                assert(@alignOf(Item) <= std.heap.page_size_min);
                // Free items store the intrusive node in their bytes.
                assert(item_size >= @sizeOf(std.SinglyLinkedList.Node));
            }
        }

        /// The allocator this managed pool was initialized with,
        /// carried for interface compatibility with the std managed
        /// memory pools. Pool items never come from it (they come
        /// from memory.grow), but callers may use it for related
        /// allocations that don't fit the pool.
        allocator: Allocator,

        pub const item_size = @sizeOf(Item);
        pub const ItemPtr = *align(std.heap.page_size_min) Item;

        /// Freed items, shared by every pool of this Item type in the
        /// module instance.
        var free_list: std.SinglyLinkedList = .{};

        pub fn initCapacity(
            gpa: Allocator,
            allocator: Allocator,
            preheat: usize,
        ) Allocator.Error!Self {
            // The free list is intrusive so we never allocate from the
            // general purpose allocator.
            _ = gpa;

            // Preheating is intentionally a no-op: item creation is a
            // cheap memory.grow or free-list pop. And we want to avoid
            // the preallocation mem cost.
            _ = preheat;
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            // Items are global to the instance and outlive the pool so
            // other pools can reuse them. Callers must destroy() any
            // items they still hold before deinit or they leak.
            self.* = undefined;
        }

        pub fn reset(
            self: *Self,
            mode: std.heap.ArenaAllocator.ResetMode,
        ) bool {
            // There is nothing to trim: linear memory cannot shrink,
            // so retaining every freed item for reuse is always the
            // right policy on wasm. As with deinit, live items must be
            // destroyed by the caller first.
            _ = self;
            _ = mode;
            return true;
        }

        pub fn create(self: *Self) Allocator.Error!ItemPtr {
            _ = self;

            // If we have a free item, use it.
            if (free_list.popFirst()) |node| return @ptrCast(@alignCast(node));

            // Grow linear memory by exactly one item.
            const pages = comptime item_size / std.heap.page_size_min;
            const page_index = @wasmMemoryGrow(0, pages);
            if (page_index == -1) return error.OutOfMemory;
            return @ptrFromInt(@as(usize, @intCast(page_index)) * std.heap.page_size_min);
        }

        pub fn destroy(self: *Self, ptr: ItemPtr) void {
            _ = self;
            const node: *std.SinglyLinkedList.Node = @ptrCast(ptr);
            node.* = .{};
            free_list.prepend(node);
        }
    };
}

test WasmPagePool {
    if (!comptime builtin.target.cpu.arch.isWasm()) return error.SkipZigTest;

    const testing = std.testing;
    const Pool = WasmPagePool([64 * 1024]u8);
    var pool: Pool = try .initCapacity(testing.allocator, testing.allocator, 0);
    defer pool.deinit();

    const a = try pool.create();
    const b = try pool.create();
    try testing.expect(a != b);

    // Freed items are recycled, most recent first.
    pool.destroy(b);
    try testing.expectEqual(b, try pool.create());

    // The free list is shared across pools of the same Item type.
    var pool2: Pool = try .initCapacity(testing.allocator, testing.allocator, 0);
    defer pool2.deinit();
    pool.destroy(a);
    try testing.expectEqual(a, try pool2.create());

    pool.destroy(a);
    pool.destroy(b);
}
