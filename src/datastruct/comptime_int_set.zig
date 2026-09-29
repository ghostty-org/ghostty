const std = @import("std");
const assert = std.debug.assert;

/// A fixed set of integers that is known at compile time and can be
/// searched quickly at runtime.
///
/// Use this when you have a table of integer IDs defined at comptime and
/// need to find which entry a runtime value belongs to. The common way to
/// write that is a loop over the table:
///
///     inline for (entries, 0..) |entry, i| {
///         if (entry.id == id) return i;
///     }
///     return null;
///
/// That loop compiles to one comparison per entry. Entries near the end
/// of the table, and values that aren't in the table at all, pay for every
/// comparison before them. This type sorts the keys at comptime and does
/// a binary search instead, so every lookup costs about log2(N)
/// comparisons no matter which key is looked up. The search has a fixed
/// number of steps and no loop, which lets the compiler emit it without
/// branches.
///
/// `indexOf` returns the position of the key in the `keys` slice you
/// passed in, not its position in the sorted order. This means you can
/// use the result to index any other table that is in the same order as
/// `keys`:
///
///     const Entry = struct { id: u16, name: []const u8 };
///     const entries = [_]Entry{
///         .{ .id = 2026, .name = "synchronized_output" },
///         .{ .id = 25, .name = "cursor_visible" },
///         .{ .id = 1049, .name = "alt_screen" },
///     };
///
///     const Ids = ComptimeIntSet(u16, &.{ 2026, 25, 1049 });
///
///     fn nameOf(id: u16) ?[]const u8 {
///         const i = Ids.indexOf(id) orelse return null;
///         return entries[i].name;
///     }
///
/// `T` must be an integer type. Keys can be in any order but must be
/// unique. Duplicate keys are a compile error.
///
/// For a handful of keys a plain loop or `switch` is just as fast and
/// simpler. This is worth reaching for when the table has dozens of
/// entries and the lookup is on a hot path.
pub fn ComptimeIntSet(comptime T: type, comptime keys: []const T) type {
    comptime assert(@typeInfo(T) == .int);

    return struct {
        /// The number of keys in the set.
        pub const len = keys.len;

        /// The type returned by `indexOf`. This is the smallest unsigned
        /// integer that can hold every valid index into `keys`.
        pub const Index = std.math.IntFittingRange(0, @max(len, 1) - 1);

        const Table = struct {
            /// The keys in ascending order.
            sorted: [len]T,

            /// For each sorted key, its index in the original `keys`
            /// slice. That is, `sorted[i] == keys[original[i]]`.
            original: [len]Index,
        };

        const table: Table = table: {
            // Sorting at comptime needs more than the default quota.
            @setEvalBranchQuota(100 * (len + 1) * (len + 1));

            var order: [len]Index = undefined;
            for (&order, 0..) |*v, i| v.* = i;
            std.mem.sortUnstable(Index, &order, {}, struct {
                fn lessThan(_: void, a: Index, b: Index) bool {
                    return keys[a] < keys[b];
                }
            }.lessThan);

            var result: Table = undefined;
            for (order, 0..) |orig, i| {
                result.sorted[i] = keys[orig];
                result.original[i] = orig;
                if (i > 0 and result.sorted[i - 1] == result.sorted[i]) {
                    @compileError("ComptimeIntSet keys must be unique");
                }
            }

            break :table result;
        };

        /// Returns the index of `key` in the original `keys` slice, or
        /// null if `key` is not in the set.
        pub inline fn indexOf(key: T) ?Index {
            if (comptime len == 0) return null;

            // Binary search for the last sorted key that is <= `key`.
            // Each step halves the range that is left. `n` is comptime
            // known, so this unrolls into a fixed number of steps.
            var base: usize = 0;
            comptime var n: usize = len;
            inline while (n > 1) {
                const half = comptime n / 2;
                base = if (table.sorted[base + half] <= key) base + half else base;
                n -= half;
            }

            if (table.sorted[base] != key) return null;
            return table.original[base];
        }

        /// Returns true if `key` is in the set.
        pub inline fn contains(key: T) bool {
            return indexOf(key) != null;
        }
    };
}

test "ComptimeIntSet: empty" {
    const testing = std.testing;
    const Set = ComptimeIntSet(u16, &.{});
    try testing.expect(Set.indexOf(0) == null);
    try testing.expect(!Set.contains(1));
}

test "ComptimeIntSet: single" {
    const testing = std.testing;
    const Set = ComptimeIntSet(u16, &.{42});
    try testing.expectEqual(0, Set.indexOf(42).?);
    try testing.expect(Set.indexOf(41) == null);
    try testing.expect(Set.indexOf(43) == null);
}

test "ComptimeIntSet: unsorted keys return original index" {
    const testing = std.testing;
    const keys: []const u16 = &.{ 2026, 4, 1049, 25, 1, 65535, 0 };
    const Set = ComptimeIntSet(u16, keys);
    for (keys, 0..) |key, i| try testing.expectEqual(i, Set.indexOf(key).?);
}

test "ComptimeIntSet: exhaustive against linear scan" {
    const testing = std.testing;

    // The search unrolls differently for each length, so test every
    // length from 0 up past a few powers of two.
    inline for (0..20) |n| {
        const keys = comptime keys: {
            var result: [n]u8 = undefined;
            for (&result, 0..) |*v, i| v.* = @intCast((i * 37 + 11) % 251);
            break :keys result;
        };
        const Set = ComptimeIntSet(u8, &keys);

        for (0..256) |v| {
            const expected: ?usize = for (keys, 0..) |key, i| {
                if (key == v) break i;
            } else null;
            const actual: ?usize = if (Set.indexOf(@intCast(v))) |i| i else null;
            try testing.expectEqual(expected, actual);
        }
    }
}

test "ComptimeIntSet: signed" {
    const testing = std.testing;
    const Set = ComptimeIntSet(i8, &.{ 5, -3, 0, -128, 127 });
    try testing.expectEqual(1, Set.indexOf(-3).?);
    try testing.expectEqual(3, Set.indexOf(-128).?);
    try testing.expectEqual(4, Set.indexOf(127).?);
    try testing.expect(Set.indexOf(-4) == null);
}
