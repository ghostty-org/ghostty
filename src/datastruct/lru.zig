const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

/// Create a HashMap for a key type that can be automatically hashed.
/// If you want finer-grained control, use HashMap directly.
pub fn AutoHashMap(comptime K: type, comptime V: type) type {
    return HashMap(
        K,
        V,
        std.hash_map.AutoContext(K),
        std.hash_map.default_max_load_percentage,
    );
}

/// HashMap implementation that supports least-recently-used eviction.
///
/// Beware of the Zig bug where a hashmap gets slower over time
/// (https://github.com/ziglang/zig/issues/17851). This LRU uses a hashmap
/// and evictions will cause this issue to appear. Callers should keep
/// track of eviction counts and periodically reinitialize the LRU to
/// avoid this issue. The LRU itself can't do this because it doesn't
/// know how to free values.
///
/// Note: This is a really elementary CS101 version of an LRU right now.
/// This is done initially to get something working. Once we have it working,
/// we can benchmark and improve if this ends up being a source of slowness.
pub fn HashMap(
    comptime K: type,
    comptime V: type,
    comptime Context: type,
    comptime max_load_percentage: u64,
) type {
    return struct {
        const Self = @This();
        const Queue = std.DoublyLinkedList;
        const Map = std.HashMapUnmanaged(
            K,
            *Entry,
            Context,
            max_load_percentage,
        );

        /// Map to maintain our entries.
        map: Map,

        /// Queue to maintain LRU order.
        queue: Queue,

        /// The capacity of our map. If this capacity is reached, cache
        /// misses will begin evicting entries.
        capacity: Map.Size,

        const Entry = struct {
            data: KV,
            node: Queue.Node,

            fn fromNode(node: *Queue.Node) *Entry {
                return @fieldParentPtr("node", node);
            }
        };

        pub const KV = struct {
            key: K,
            value: V,
        };

        /// The result of a getOrPut operation.
        pub const GetOrPutResult = struct {
            /// The entry that was retrieved. If found_existing is false,
            /// then this is a pointer to allocated space to store a V.
            /// If found_existing is true, the pointer value is valid, but
            /// can be overwritten.
            value_ptr: *V,

            /// Whether an existing value was found or not.
            found_existing: bool,

            /// If another entry had to be evicted to make space for this
            /// put operation, then this is the value that was evicted.
            evicted: ?KV,
        };

        pub fn init(capacity: Map.Size) Self {
            return .{
                .map = .{},
                .queue = .{},
                .capacity = capacity,
            };
        }

        pub fn deinit(self: *Self, alloc: Allocator) void {
            // Important: use our queue as a source of truth for dealloc
            // because we might keep items in the queue around that aren't
            // present in our LRU anymore to prevent future allocations.
            var it = self.queue.first;
            while (it) |node| {
                it = node.next;
                alloc.destroy(Entry.fromNode(node));
            }

            self.map.deinit(alloc);
            self.* = undefined;
        }

        /// Get or put a value for a key. See GetOrPutResult on how to check
        /// if an existing value was found, if an existing value was evicted,
        /// etc.
        pub fn getOrPut(self: *Self, allocator: Allocator, key: K) Allocator.Error!GetOrPutResult {
            if (@sizeOf(Context) != 0)
                @compileError("Cannot infer context " ++ @typeName(Context) ++ ", call getOrPutContext instead.");
            return self.getOrPutContext(allocator, key, undefined);
        }

        /// See getOrPut
        pub fn getOrPutContext(
            self: *Self,
            alloc: Allocator,
            key: K,
            ctx: Context,
        ) Allocator.Error!GetOrPutResult {
            const map_gop = try self.map.getOrPutContext(alloc, key, ctx);
            if (map_gop.found_existing) {
                // Move to end to mark as most recently used
                self.queue.remove(&map_gop.value_ptr.*.node);
                self.queue.append(&map_gop.value_ptr.*.node);

                return GetOrPutResult{
                    .found_existing = true,
                    .value_ptr = &map_gop.value_ptr.*.data.value,
                    .evicted = null,
                };
            }
            errdefer _ = self.map.remove(key);

            // We're evicting if our map insertion increased our capacity.
            const evict = self.map.count() > self.capacity;

            // Get our entry. If we're not evicting then we allocate a new
            // entry. If we are evicting then we avoid allocation by just
            // reusing the entry we would've evicted.
            const entry: *Entry = if (!evict) try alloc.create(Entry) else entry: {
                // Our first node is the least recently used.
                const least_used_node = self.queue.popFirst().?;
                const least_used_entry: *Entry = .fromNode(least_used_node);

                // Remove the least used from the map
                _ = self.map.remove(least_used_entry.data.key);

                break :entry least_used_entry;
            };
            errdefer if (!evict) alloc.destroy(entry);

            // Store our entry in the map.
            map_gop.value_ptr.* = entry;

            // Mark the entry as most recently used
            self.queue.append(&entry.node);

            // Set our key
            entry.data.key = key;

            return .{
                .found_existing = map_gop.found_existing,
                .value_ptr = &entry.data.value,
                .evicted = if (!evict) null else entry.data,
            };
        }

        /// Get a value for a key.
        pub fn get(self: *const Self, key: K) ?V {
            if (@sizeOf(Context) != 0) {
                @compileError("getContext must be used.");
            }
            return self.getContext(key, undefined);
        }

        /// See get
        pub fn getContext(self: *const Self, key: K, ctx: Context) ?V {
            const node = self.map.getContext(key, ctx) orelse return null;
            return node.data.value;
        }

        /// Resize the LRU. If this shrinks the LRU then LRU items will be
        /// deallocated. The deallocated items are returned in the slice. This
        /// slice must be freed by the caller.
        pub fn resize(self: *Self, alloc: Allocator, capacity: Map.Size) Allocator.Error!?[]V {
            // Fastest
            if (capacity >= self.capacity) {
                self.capacity = capacity;
                return null;
            }

            // If we're shrinking but we're smaller than the new capacity,
            // then we don't have to do anything.
            if (self.map.count() <= capacity) {
                self.capacity = capacity;
                return null;
            }

            // We're shrinking and we have more items than the new capacity
            const delta = self.map.count() - capacity;
            var evicted = try alloc.alloc(V, delta);

            var i: Map.Size = 0;
            while (i < delta) : (i += 1) {
                const node = self.queue.popFirst().?;
                const entry: *Entry = .fromNode(node);
                evicted[i] = entry.data.value;
                self.queue.remove(node);
                _ = self.map.remove(entry.data.key);
                alloc.destroy(entry);
            }

            self.capacity = capacity;
            assert(self.map.count() == capacity);

            return evicted;
        }
    };
}

test "getOrPut" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const Map = AutoHashMap(u32, u8);
    var m = Map.init(2);
    defer m.deinit(alloc);

    // Insert cap values, should be hits
    {
        const gop = try m.getOrPut(alloc, 1);
        try testing.expect(!gop.found_existing);
        try testing.expect(gop.evicted == null);
        gop.value_ptr.* = 1;
    }
    {
        const gop = try m.getOrPut(alloc, 2);
        try testing.expect(!gop.found_existing);
        try testing.expect(gop.evicted == null);
        gop.value_ptr.* = 2;
    }

    // 1 is LRU
    try testing.expect((try m.getOrPut(alloc, 1)).found_existing);
    try testing.expect((try m.getOrPut(alloc, 2)).found_existing);

    // Next should evict
    {
        const gop = try m.getOrPut(alloc, 3);
        try testing.expect(!gop.found_existing);
        try testing.expect(gop.evicted != null);
        try testing.expect(gop.evicted.?.value == 1);
        gop.value_ptr.* = 3;
    }

    // Currently: 2 is LRU, let's make 3 LRU
    try testing.expect((try m.getOrPut(alloc, 2)).found_existing);

    // Next should evict
    {
        const gop = try m.getOrPut(alloc, 4);
        try testing.expect(!gop.found_existing);
        try testing.expect(gop.evicted != null);
        try testing.expect(gop.evicted.?.value == 3);
        gop.value_ptr.* = 4;
    }
}

test "get" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const Map = AutoHashMap(u32, u8);
    var m = Map.init(2);
    defer m.deinit(alloc);

    // Insert cap values, should be hits
    {
        const gop = try m.getOrPut(alloc, 1);
        try testing.expect(!gop.found_existing);
        try testing.expect(gop.evicted == null);
        gop.value_ptr.* = 1;
    }

    try testing.expect(m.get(1) != null);
    try testing.expect(m.get(1).? == 1);
    try testing.expect(m.get(2) == null);
}

test "resize shrink without removal" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const Map = AutoHashMap(u32, u8);
    var m = Map.init(2);
    defer m.deinit(alloc);

    // Insert cap values, LRU is 1
    {
        const gop = try m.getOrPut(alloc, 1);
        try testing.expect(!gop.found_existing);
        try testing.expect(gop.evicted == null);
        gop.value_ptr.* = 1;
    }

    // Shrink
    const evicted = try m.resize(alloc, 1);
    try testing.expect(evicted == null);
    {
        const gop = try m.getOrPut(alloc, 1);
        try testing.expect(gop.found_existing);
    }
}

test "resize shrink and remove" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const Map = AutoHashMap(u32, u8);
    var m = Map.init(2);
    defer m.deinit(alloc);

    // Insert cap values, LRU is 1
    {
        const gop = try m.getOrPut(alloc, 1);
        try testing.expect(!gop.found_existing);
        try testing.expect(gop.evicted == null);
        gop.value_ptr.* = 1;
    }
    {
        const gop = try m.getOrPut(alloc, 2);
        try testing.expect(!gop.found_existing);
        try testing.expect(gop.evicted == null);
        gop.value_ptr.* = 2;
    }

    // Shrink
    const evicted = try m.resize(alloc, 1);
    defer alloc.free(evicted.?);
    try testing.expectEqual(@as(usize, 1), evicted.?.len);
    {
        const gop = try m.getOrPut(alloc, 1);
        try testing.expect(!gop.found_existing);
        try testing.expect(gop.evicted.?.value == 2);
        gop.value_ptr.* = 1;
    }
}
