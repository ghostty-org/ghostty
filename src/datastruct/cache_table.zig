const fastmem = @import("../fastmem.zig");

const std = @import("std");
const assert = std.debug.assert;

/// An associative data structure used for efficiently storing and
/// retrieving values which are able to be recomputed if necessary.
///
/// This structure is effectively a hash table with fixed-sized buckets.
///
/// When inserting an item in to a full bucket, the least recently used
/// item is replaced.
///
/// To achieve this, when an item is accessed, it's moved to the end of
/// the bucket, and the rest of the items are moved over to fill the gap.
///
/// This should provide very good query performance and keep frequently
/// accessed items cached indefinitely.
///
/// Parameters:
///
/// `Context`
///   A type containing methods to define CacheTable behaviors.
///   - `fn hash(*Context, K) u64`    - Return a hash for a key.
///   - `fn eql(*Context, K, K) bool` - Check two keys for equality.
///
///   - `fn evicted(*Context, K, V) void` - [OPTIONAL] Eviction callback.
///     If present, called whenever an item is evicted from the cache.
///
/// `bucket_count`
///   Should ideally be close to the median number of important items that
///   you expect to be cached at any given point. This is required to be a
///   power of 2 since performance suffers if it's not and there's no good
///   reason to allow it to be anything else.
///
/// `bucket_size`
///   should be larger if you expect a large number of unimportant items to
///   enter the cache at a time. Having larger buckets will avoid important
///   items being dropped from the cache prematurely.
///
pub fn CacheTable(
    comptime K: type,
    comptime V: type,
    comptime Context: type,
    comptime bucket_count: usize,
    comptime bucket_size: u8,
) type {
    return struct {
        const Self = @This();

        const KV = struct {
            key: K,
            value: V,
        };

        comptime {
            assert(std.math.isPowerOfTwo(bucket_count));
            assert(bucket_count <= std.math.maxInt(usize));
        }

        /// `bucket_count` buckets containing `bucket_size` KV pairs each.
        ///
        /// We don't need to initialize this memory because we don't use it
        /// unless it's within a bucket's stored length, which will guarantee
        /// that we put actual items there.
        buckets: [bucket_count][bucket_size]KV = undefined,

        /// We use this array to keep track of how many slots in each bucket
        /// have actual items in them. Once all the buckets fill up this will
        /// become a pointless check, but hopefully branch prediction picks
        /// up on it at that point. The memory cost isn't too bad since it's
        /// just bytes, so should be a fraction the size of the main table.
        lengths: [bucket_count]u8 = @splat(0),

        /// An instance of the context structure.
        /// Must be initialized before calling any operations.
        context: Context,

        /// Adds an item to the cache table. If an old value was removed to
        /// make room then it is returned in a struct with its key and value.
        pub fn put(self: *Self, key: K, value: V) ?KV {
            const kv: KV = .{ .key = key, .value = value };
            const idx: usize = @intCast(self.context.hash(key) % bucket_count);

            // If we have space available in the bucket then we just append
            if (self.lengths[idx] < bucket_size) {
                self.buckets[idx][self.lengths[idx]] = kv;
                self.lengths[idx] += 1;
                return null;
            }
            assert(self.lengths[idx] == bucket_size);

            // Append our new item and return the oldest
            const evicted = fastmem.rotateIn(KV, &self.buckets[idx], kv);

            // The Context is allowed to register an eviction hook.
            if (comptime @hasDecl(Context, "evicted")) self.context.evicted(
                evicted.key,
                evicted.value,
            );

            return evicted;
        }

        /// Retrieves an item from the cache table.
        ///
        /// Returns null if no item is found with the provided key.
        pub fn get(self: *Self, key: K) ?V {
            const idx: usize = @intCast(self.context.hash(key) % bucket_count);
            const len = self.lengths[idx];
            var i: usize = len;
            while (i > 0) {
                i -= 1;
                if (self.context.eql(key, self.buckets[idx][i].key)) {
                    defer fastmem.rotateOnce(KV, self.buckets[idx][i..len]);
                    return self.buckets[idx][i].value;
                }
            }

            return null;
        }

        /// Removes all items from the cache table.
        ///
        /// If your `Context` has an `evicted` method,
        /// it will be called with all removed items.
        pub fn clear(self: *Self) void {
            if (comptime @hasDecl(Context, "evicted")) {
                for (self.buckets, self.lengths) |b, l| {
                    for (b[0..l]) |kv| {
                        self.context.evicted(kv.key, kv.value);
                    }
                }
            }

            @memset(&self.lengths, 0);
        }
    };
}

/// Creates a Context automatically for the given key type. This uses the
/// same logic as std.hash_map.AutoContext today since the API matches.
fn AutoContext(comptime K: type) type {
    return std.hash_map.AutoContext(K);
}

test CacheTable {
    const testing = std.testing;

    // Construct a table that purposely has a predictable hash so we can
    // test all edge cases.
    const T = CacheTable(u32, u32, struct {
        pub fn hash(self: *const @This(), key: u32) u64 {
            _ = self;
            return @intCast(key);
        }

        pub fn eql(self: *const @This(), a: u32, b: u32) bool {
            _ = self;
            return a == b;
        }
    }, 2, 2);
    var t: T = .{ .context = .{} };

    // Fill the table
    try testing.expect(t.put(0, 0) == null);
    try testing.expect(t.put(1, 0) == null);
    try testing.expect(t.put(2, 0) == null);
    try testing.expect(t.put(3, 0) == null);

    // It should now be full, so any insert should evict the oldest item.
    // NOTE: For the sake of this test, we're assuming that the first item
    // is evicted but we don't need to promise this.
    try testing.expectEqual(T.KV{
        .key = 0,
        .value = 0,
    }, t.put(4, 0).?);

    // The first item should now be gone
    try testing.expect(t.get(0) == null);
}
