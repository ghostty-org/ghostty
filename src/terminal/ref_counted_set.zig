const std = @import("std");
const assert = std.debug.assert;

const size = @import("size.zig");
const Offset = size.Offset;
const OffsetBuf = size.OffsetBuf;

const fastmem = @import("../fastmem.zig");

/// A reference counted set.
///
/// This set is created with some capacity in mind. You can determine
/// the exact memory requirement of a given capacity by calling `layout`
/// and checking the total size.
///
/// When the set exceeds capacity, an `OutOfMemory` or `NeedsRehash` error
/// is returned from any memory-using methods. The caller is responsible
/// for determining a path forward.
///
/// This set is reference counted. Each item in the set has an associated
/// reference count. The caller is responsible for calling release for an
/// item when it is no longer being used. Items with 0 references will be
/// kept until another item is written to their bucket. This allows items
/// to be resurrected if they are re-added before they get overwritten.
///
/// The backing data structure of this set is an open addressed hash table
/// with linear probing and Robin Hood hashing, and a flat array of items.
///
/// The table maps values to item IDs, which are indices in the item array
/// which contain the item's value and its reference count. Item IDs can be
/// used to efficiently access an item and update its reference count after
/// it has been added to the table, to avoid having to use the hash map to
/// look the value back up.
///
/// ID 0 is reserved and will never be assigned.
///
/// Parameters:
///
/// `Context`
///   A type containing methods to define behaviors.
///
///   - `fn hash(*Context, T) u64`    - Return a hash for an item.
///
///   - `fn eql(*Context, T, T) bool` - Check two items for equality.
///     The first of the two items passed in is guaranteed to be from
///     a value passed in to an `add` or `lookup` function, the second
///     is guaranteed to be a value already resident in the set.
///
///   - `fn deleted(*Context, T) void` - [OPTIONAL] Deletion callback.
///     If present, called whenever an item is finally deleted.
///     Useful if the item has memory that needs to be freed.
///
pub fn RefCountedSet(
    comptime T: type,
    comptime IdT: type,
    comptime RefCountInt: type,
    comptime ContextT: type,
) type {
    return struct {
        const Self = @This();

        pub const base_align = @max(
            @alignOf(Context),
            @alignOf(Layout),
            @alignOf(Item),
            @alignOf(Id),
        );

        /// Set item
        pub const Item = struct {
            /// The value this item represents.
            value: T = undefined,

            /// Metadata for this item.
            meta: Metadata = .{},

            pub const Metadata = struct {
                /// The bucket in the hash table where this item
                /// is referenced.
                bucket: Id = std.math.maxInt(Id),

                /// The length of the probe sequence between this
                /// item's starting bucket and the bucket it's in,
                /// used for Robin Hood hashing.
                psl: Id = 0,

                /// The reference count for this item.
                ref: RefCountInt = 0,
            };
        };

        // Re-export these types so they can be referenced by the caller.
        pub const Id = IdT;
        pub const Context = ContextT;

        /// A hash table of item indices
        table: Offset(Id),

        /// By keeping track of the max probe sequence length
        /// we can bail out early when looking up values that
        /// aren't present.
        max_psl: Id = 0,

        /// We keep track of how many items have a PSL of any
        /// given length, so that we can shrink max_psl when
        /// we delete items.
        ///
        /// A probe sequence of length 32 or more is astronomically
        /// unlikely. Roughly a (1/table_cap)^32 -- with any normal
        /// table capacity that is so unlikely that it's not worth
        /// handling.
        ///
        /// However, that assumes a uniform hash function, which
        /// is not guaranteed and can be subverted with a crafted
        /// input. We handle this gracefully by returning an error
        /// anywhere where we're about to insert if there's any
        /// item with a PSL in the last slot of the stats array.
        psl_stats: [32]Id = @splat(0),

        /// The backing store of items
        items: Offset(Item),

        /// The number of living items currently stored in the set.
        living: usize = 0,

        /// The next index to store an item at.
        /// Id 0 is reserved for unused items.
        next_id: Id = 1,

        layout: Layout,

        /// An instance of the context structure.
        context: Context,

        pub const Layout = struct {
            cap: usize,
            table_cap: usize,
            table_mask: Id,
            table_start: usize,
            items_start: usize,
            total_size: usize,

            /// Returns the memory layout for the given base offset and
            /// desired capacity. The layout can be used by the caller to
            /// determine how much memory to allocate, and the layout must
            /// be used to initialize the set so that the set knows all
            /// the offsets for the various buffers.
            ///
            /// The capacity passed for cap will be used for the hash table,
            /// which has a load factor of `0.8125` (13/16), so the number of
            /// items which can actually be stored in the set will be smaller.
            ///
            /// The laid out capacity will be at least `cap`, but may be higher,
            /// since it is rounded up to the next power of 2 for efficiency.
            ///
            /// The returned layout `cap` property will be 1 more than the number
            /// of items that the set can actually store, since ID 0 is reserved.
            pub fn init(cap: usize) Layout {
                // Experimentally, this load factor works quite well.
                const load_factor = 0.8125;

                assert(cap <= @as(usize, @intCast(std.math.maxInt(Id))) + 1);

                // Zero-cap set is valid, return special case
                if (cap == 0) return .{
                    .cap = 0,
                    .table_cap = 0,
                    .table_mask = 0,
                    .table_start = 0,
                    .items_start = 0,
                    .total_size = 0,
                };

                const table_cap: usize = std.math.ceilPowerOfTwoAssert(usize, cap);
                const items_cap: usize = @intFromFloat(load_factor * @as(f64, @floatFromInt(table_cap)));

                const table_mask: Id = @intCast((@as(usize, 1) << std.math.log2_int(usize, table_cap)) - 1);

                const table_start = 0;
                const table_end = table_start + table_cap * @sizeOf(Id);

                const items_start = std.mem.alignForward(usize, table_end, @alignOf(Item));
                const items_end = items_start + items_cap * @sizeOf(Item);

                const total_size = items_end;

                return .{
                    .cap = items_cap,
                    .table_cap = table_cap,
                    .table_mask = table_mask,
                    .table_start = table_start,
                    .items_start = items_start,
                    .total_size = total_size,
                };
            }
        };

        pub fn init(base: OffsetBuf, l: Layout, context: Context) Self {
            const table = base.member(Id, l.table_start);
            const items = base.member(Item, l.items_start);

            @memset(table.ptr(base)[0..l.table_cap], 0);
            @memset(items.ptr(base)[0..l.cap], .{});

            return .{
                .table = table,
                .items = items,
                .layout = l,
                .context = context,
            };
        }

        /// Possible errors for `add` and `addWithId`.
        pub const AddError = error{
            /// There is not enough memory to add a new item.
            /// Remove items or grow and reinitialize.
            OutOfMemory,

            /// The set needs to be rehashed, as there are many dead
            /// items with lower IDs which are inaccessible for re-use.
            NeedsRehash,
        };

        /// Add an item to the set if not present and increment its ref count.
        ///
        /// Returns the item's ID.
        ///
        /// If the set has no more room, then an OutOfMemory error is returned.
        pub fn add(self: *Self, base: anytype, value: T) AddError!Id {
            return try self.addContext(base, value, self.context);
        }
        pub fn addContext(self: *Self, base: anytype, value: T, ctx: Context) AddError!Id {
            const items = self.items.ptr(base);

            // Trim dead items from the end of the list.
            while (self.next_id > 1 and items[self.next_id - 1].meta.ref == 0) {
                self.next_id -= 1;
                self.deleteItem(base, self.next_id, ctx);
            }

            // If the item already exists, return it.
            if (self.lookupContext(base, value, ctx)) |id| {
                // Notify the context that the value is "deleted" because
                // we're reusing the existing value in the set. This allows
                // callers to clean up any resources associated with the value.
                if (comptime @hasDecl(Context, "deleted")) ctx.deleted(value);

                items[id].meta.ref += 1;
                return id;
            }

            // While it should be statistically impossible to exceed the
            // bounds of `psl_stats`, the hash function is not perfect and
            // in such a case we want to remain stable. If we're about to
            // insert an item and there's something with a PSL of `len - 1`,
            // we may end up with a PSL of `len` which would exceed the bounds.
            // In such a case, we claim to be out of memory.
            if (self.psl_stats[self.psl_stats.len - 1] > 0) {
                return AddError.OutOfMemory;
            }

            // If the item doesn't exist, we need an available ID.
            if (self.next_id >= self.layout.cap) {
                // Arbitrarily chosen, threshold for rehashing.
                // If less than 90% of currently allocated IDs
                // correspond to living items, we should rehash.
                // Otherwise, claim we're out of memory because
                // we assume that we'll end up running out of
                // memory or rehashing again very soon if we
                // rehash with only a few IDs left.
                const rehash_threshold = 0.9;
                if (self.living < @as(Id, @intFromFloat(@as(f64, @floatFromInt(self.layout.cap)) * rehash_threshold))) {
                    return AddError.NeedsRehash;
                }

                // If we don't have at least 10% dead items then
                // we claim we're out of memory.
                return AddError.OutOfMemory;
            }

            const id = self.insert(base, value, self.next_id, ctx);
            items[id].meta.ref += 1;
            assert(items[id].meta.ref == 1);
            self.living += 1;

            // Its possible insert returns a different ID by reusing a
            // dead item so we only need to update next id if we used it.
            if (id == self.next_id) self.next_id += 1;

            return id;
        }

        /// Add an item to the set if not present and increment its
        /// ref count. If possible, use the provided ID.
        ///
        /// Returns the item's ID, or null if the provided ID was used.
        ///
        /// If the set has no more room, then an OutOfMemory error is returned.
        pub fn addWithId(self: *Self, base: anytype, value: T, id: Id) AddError!?Id {
            return try self.addWithIdContext(base, value, id, self.context);
        }
        pub fn addWithIdContext(self: *Self, base: anytype, value: T, id: Id, ctx: Context) AddError!?Id {
            const items = self.items.ptr(base);

            assert(id > 0);

            if (id < self.next_id) {
                if (items[id].meta.ref == 0) {
                    // See comment in `addContext` for details.
                    if (self.psl_stats[self.psl_stats.len - 1] > 0) {
                        return AddError.OutOfMemory;
                    }

                    self.deleteItem(base, id, ctx);

                    const added_id = self.upsert(base, value, id, ctx);

                    items[added_id].meta.ref += 1;

                    self.living += 1;

                    return if (added_id == id) null else added_id;
                } else if (ctx.eql(value, items[id].value)) {
                    // Notify the context that the value is "deleted" because
                    // we're reusing the existing value in the set. This allows
                    // callers to clean up any resources associated with the value.
                    if (comptime @hasDecl(Context, "deleted")) ctx.deleted(value);

                    items[id].meta.ref += 1;

                    return null;
                }
            }

            return try self.addContext(base, value, ctx);
        }

        /// Increment an item's reference count by 1.
        ///
        /// Asserts that the item's reference count is greater than 0.
        pub fn use(self: *const Self, base: anytype, id: Id) void {
            assert(id > 0);
            assert(id < self.layout.cap);

            const items = self.items.ptr(base);
            const item = &items[id];

            // If `use` is being called on an item with 0 references, then
            // either someone forgot to call it before, released too early
            // or lied about releasing. In any case something is wrong and
            // shouldn't be allowed.
            assert(item.meta.ref > 0);

            item.meta.ref += 1;
        }

        /// Increment an item's reference count by a specified number.
        ///
        /// Asserts that the item's reference count is greater than 0.
        pub fn useMultiple(self: *const Self, base: anytype, id: Id, n: RefCountInt) void {
            assert(id > 0);
            assert(id < self.layout.cap);

            const items = self.items.ptr(base);
            const item = &items[id];

            // If `use` is being called on an item with 0 references, then
            // either someone forgot to call it before, released too early
            // or lied about releasing. In any case something is wrong and
            // shouldn't be allowed.
            assert(item.meta.ref > 0);

            item.meta.ref += n;
        }

        /// Get an item by its ID without incrementing its reference count.
        ///
        /// Asserts that the item's reference count is greater than 0.
        pub fn get(self: *const Self, base: anytype, id: Id) *T {
            assert(id > 0);
            assert(id < self.layout.cap);

            const items = self.items.ptr(base);
            const item = &items[id];

            assert(item.meta.ref > 0);

            return @ptrCast(&item.value);
        }

        /// Releases a reference to an item by its ID.
        ///
        /// Asserts that the item's reference count is greater than 0.
        pub fn release(self: *Self, base: anytype, id: Id) void {
            assert(id > 0);
            assert(id < self.layout.cap);

            const items = self.items.ptr(base);
            const item = &items[id];

            assert(item.meta.ref > 0);
            item.meta.ref -= 1;
            if (item.meta.ref == 0) self.living -= 1;
        }

        /// Release a specified number of references to an item by its ID.
        ///
        /// Asserts that the item's reference count is at least `n`.
        pub fn releaseMultiple(self: *Self, base: anytype, id: Id, n: Id) void {
            assert(id > 0);
            assert(id < self.layout.cap);

            const items = self.items.ptr(base);
            const item = &items[id];

            assert(item.meta.ref >= n);
            item.meta.ref -= n;

            if (item.meta.ref == 0) {
                self.living -= 1;
            }
        }

        /// Get the ref count for an item by its ID.
        pub fn refCount(self: *const Self, base: anytype, id: Id) RefCountInt {
            assert(id > 0);
            assert(id < self.layout.cap);

            const items = self.items.ptr(base);
            const item = &items[id];
            return item.meta.ref;
        }

        /// Get the current number of non-dead items in the set.
        pub fn count(self: *const Self) usize {
            return self.living;
        }

        /// Delete an item, removing any references from
        /// the table, and freeing its ID to be re-used.
        fn deleteItem(self: *Self, base: anytype, id: Id, ctx: Context) void {
            const table = self.table.ptr(base);
            const items = self.items.ptr(base);

            const item = items[id];

            if (item.meta.bucket > self.layout.table_cap) return;

            assert(table[item.meta.bucket] == id);

            if (comptime @hasDecl(Context, "deleted")) {
                // Inform the context struct that we're
                // deleting the dead item's value for good.
                ctx.deleted(item.value);
            }

            self.psl_stats[item.meta.psl] -= 1;
            table[item.meta.bucket] = 0;
            items[id] = .{};

            var p: Id = item.meta.bucket;
            var n: Id = (p +% 1) & self.layout.table_mask;

            while (table[n] != 0 and items[table[n]].meta.psl > 0) {
                items[table[n]].meta.bucket = p;
                self.psl_stats[items[table[n]].meta.psl] -= 1;
                items[table[n]].meta.psl -= 1;
                self.psl_stats[items[table[n]].meta.psl] += 1;
                table[p] = table[n];
                p = n;
                n = (p +% 1) & self.layout.table_mask;
            }

            while (self.max_psl > 0 and self.psl_stats[self.max_psl] == 0) {
                self.max_psl -= 1;
            }

            table[p] = 0;

            self.assertIntegrity(base, ctx);
        }

        /// Find an item in the table and return its ID.
        /// If the item does not exist in the table, null is returned.
        pub fn lookup(self: *const Self, base: anytype, value: T) ?Id {
            return self.lookupContext(base, value, self.context);
        }
        pub fn lookupContext(self: *const Self, base: anytype, value: T, ctx: Context) ?Id {
            const table = self.table.ptr(base);
            const items = self.items.ptr(base);

            const hash: u64 = ctx.hash(value);

            for (0..self.max_psl + 1) |i| {
                const p: usize = @intCast((hash +% i) & self.layout.table_mask);
                const id = table[p];

                // Empty bucket, our item cannot have probed to
                // any point after this, meaning it's not present.
                if (id == 0) {
                    return null;
                }

                const item = items[id];

                // An item with a shorter probe sequence length would never
                // end up in the middle of another sequence, since it would
                // be swapped out if inserted before the new sequence, and
                // would not be swapped in if inserted afterwards.
                //
                // As such, our item cannot be present.
                if (item.meta.psl < i) {
                    return null;
                }

                // We don't bother checking dead items.
                if (item.meta.ref == 0) {
                    continue;
                }

                // If the item is a part of the same probe sequence,
                // we check if it matches the value we're looking for.
                if (item.meta.psl == i and
                    ctx.eql(value, item.value))
                {
                    return id;
                }
            }

            return null;
        }

        /// Find the provided value in the hash table, or add a new item
        /// for it if not present. If a new item is added, `new_id` will
        /// be used as the ID. If an existing item is found, the `new_id`
        /// is ignored and the existing item's ID is returned.
        fn upsert(self: *Self, base: anytype, value: T, new_id: Id, ctx: Context) Id {
            // If the item already exists, return it.
            if (self.lookupContext(base, value, ctx)) |id| {
                // Notify the context that the value is "deleted" because
                // we're reusing the existing value in the set. This allows
                // callers to clean up any resources associated with the value.
                if (comptime @hasDecl(Context, "deleted")) ctx.deleted(value);

                return id;
            }

            return self.insert(base, value, new_id, ctx);
        }

        /// Insert the given value into the hash table with the given ID.
        /// asserts that the value is not already present in the table.
        fn insert(self: *Self, base: anytype, value: T, new_id: Id, ctx: Context) Id {
            assert(self.lookupContext(base, value, ctx) == null);

            const table = self.table.ptr(base);
            const items = self.items.ptr(base);

            // The new item that we'll put in to the table.
            var new_item: Item = .{
                .value = value,
                .meta = .{ .psl = 0, .ref = 0 },
            };

            const hash: u64 = ctx.hash(value);

            var held_id: Id = new_id;
            var held_item: *Item = &new_item;

            var chosen_id: Id = new_id;

            for (0..self.layout.table_cap - 1) |i| {
                const p: Id = @intCast((hash +% i) & self.layout.table_mask);
                const id = table[p];

                // Empty bucket, put our held item in to it and break.
                if (id == 0) {
                    table[p] = held_id;
                    held_item.meta.bucket = p;
                    self.psl_stats[held_item.meta.psl] += 1;
                    self.max_psl = @max(self.max_psl, held_item.meta.psl);
                    break;
                }

                const item = &items[id];

                // If there's a dead item then we resurrect it
                // for our value so that we can re-use its ID,
                // unless its ID is greater than the one we're
                // given (i.e. prefer smaller IDs).
                if (item.meta.ref == 0) {
                    if (comptime @hasDecl(Context, "deleted")) {
                        // Inform the context struct that we're
                        // deleting the dead item's value for good.
                        ctx.deleted(item.value);
                    }

                    // Reap the dead item.
                    self.psl_stats[item.meta.psl] -= 1;
                    item.* = .{};

                    // Only resurrect this item if it has a
                    // smaller id than the one we were given.
                    if (id < new_id) chosen_id = id;

                    // Put the currently held item in to the
                    // bucket of the item that we just reaped.
                    table[p] = held_id;
                    held_item.meta.bucket = p;
                    self.psl_stats[held_item.meta.psl] += 1;
                    self.max_psl = @max(self.max_psl, held_item.meta.psl);

                    break;
                }

                // If this item has a lower PSL, or has equal PSL and lower ref
                // count, then we swap it out with our held item. By doing this,
                // items with high reference counts are prioritized for earlier
                // placement. The assumption is that an item which has a higher
                // reference count will be accessed more frequently, so we want
                // to minimize the time it takes to find it.
                if (item.meta.psl < held_item.meta.psl or
                    item.meta.psl == held_item.meta.psl and
                        item.meta.ref < held_item.meta.ref)
                {
                    // Put our held item in the bucket.
                    table[p] = held_id;
                    held_item.meta.bucket = p;
                    self.psl_stats[held_item.meta.psl] += 1;
                    self.max_psl = @max(self.max_psl, held_item.meta.psl);

                    // Pick up the item that has a lower PSL.
                    held_id = id;
                    held_item = item;
                    self.psl_stats[item.meta.psl] -= 1;
                }

                // Advance to the next probe position for our held item.
                held_item.meta.psl += 1;
            }

            // Our chosen ID may have changed if we decided
            // to re-use a dead item's ID, so we make sure
            // the chosen bucket contains the correct ID.
            table[new_item.meta.bucket] = chosen_id;

            // Finally place our new item in to our array.
            items[chosen_id] = new_item;

            self.assertIntegrity(base, ctx);

            return chosen_id;
        }

        fn assertIntegrity(
            self: *const Self,
            base: anytype,
            ctx: Context,
        ) void {
            // Disabled because this is excessively slow, only enable
            // if debugging a RefCountedSet issue or modifying its logic.
            if (false and std.debug.runtime_safety) {
                const table = self.table.ptr(base);
                const items = self.items.ptr(base);

                var psl_stats: [32]Id = @splat(0);

                for (items[0..self.layout.cap], 0..) |item, id| {
                    if (item.meta.bucket < std.math.maxInt(Id)) {
                        assert(table[item.meta.bucket] == id);
                        psl_stats[item.meta.psl] += 1;
                    }
                }

                std.testing.expectEqualSlices(Id, &psl_stats, &self.psl_stats) catch assert(false);

                assert(std.mem.eql(Id, &psl_stats, &self.psl_stats));

                psl_stats = @splat(0);

                for (table[0..self.layout.table_cap], 0..) |id, bucket| {
                    const item = items[id];
                    if (item.meta.bucket < std.math.maxInt(Id)) {
                        assert(item.meta.bucket == bucket);

                        const hash: u64 = ctx.hash(item.value);
                        const p: usize = @intCast((hash +% item.meta.psl) & self.layout.table_mask);
                        assert(p == bucket);

                        psl_stats[item.meta.psl] += 1;
                    }
                }

                std.testing.expectEqualSlices(Id, &psl_stats, &self.psl_stats) catch assert(false);
            }
        }
    };
}
