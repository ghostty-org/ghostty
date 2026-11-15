const std = @import("std");

// The following are taken from the Zig std library. We need to copy these
// because `EnumIndexer()` needs to have a larger `@setEvalBranchQuota` set
// to handle larger enums.
//
// https://codeberg.org/ziglang/zig/src/tag/0.17.0/lib/std/enums.zig

/// A set of enum elements, backed by a bitfield.  If the enum
/// is exhaustive but not dense, a mapping will be constructed from enum values
/// to dense indices.  This type does no dynamic allocation and
/// can be copied by value.
pub fn EnumSet(comptime E: type) type {
    return struct {
        const Self = @This();

        /// The indexing rules for converting between keys and indices.
        pub const Indexer = EnumIndexer(E);
        /// The element type for this set.
        pub const Key = Indexer.Key;

        const BitSet = std.bit_set.Static(Indexer.count);

        /// The maximum number of items in this set.
        pub const len = Indexer.count;

        bits: BitSet = .empty,

        /// Initializes the set using a struct of bools
        pub fn init(init_values: std.enums.EnumFieldStruct(E, bool, false)) Self {
            @setEvalBranchQuota(2 * @typeInfo(E).@"enum".field_names.len);
            var result: Self = .{};
            if (@typeInfo(E).@"enum".mode == .exhaustive) {
                inline for (0..Self.len) |i| {
                    const key = comptime Indexer.keyForIndex(i);
                    const tag = @tagName(key);
                    if (@field(init_values, tag)) {
                        result.bits.set(i);
                    }
                }
            } else {
                inline for (@typeInfo(E).@"enum".field_names) |field_name| {
                    const key = @field(E, field_name);
                    if (@field(init_values, field_name)) {
                        const i = comptime Indexer.indexOf(key);
                        result.bits.set(i);
                    }
                }
            }
            return result;
        }

        /// A set containing no keys.
        pub const empty: Self = .{ .bits = .empty };

        /// A set containing all possible keys.
        pub const full: Self = .{ .bits = .full };

        /// Returns a set containing multiple keys.
        pub fn initMany(keys: []const Key) Self {
            var set: Self = .empty;
            for (keys) |key| set.insert(key);
            return set;
        }

        /// Returns a set containing a single key.
        pub fn initOne(key: Key) Self {
            return initMany(&[_]Key{key});
        }

        /// Returns the number of keys in the set.
        pub fn count(self: Self) usize {
            return self.bits.count();
        }

        /// Checks if a key is in the set.
        pub fn contains(self: Self, key: Key) bool {
            return self.bits.isSet(Indexer.indexOf(key));
        }

        /// Puts a key in the set.
        pub fn insert(self: *Self, key: Key) void {
            self.bits.set(Indexer.indexOf(key));
        }

        /// Removes a key from the set.
        pub fn remove(self: *Self, key: Key) void {
            self.bits.unset(Indexer.indexOf(key));
        }

        /// Changes the presence of a key in the set to match the passed bool.
        pub fn setPresent(self: *Self, key: Key, present: bool) void {
            self.bits.setValue(Indexer.indexOf(key), present);
        }

        /// Toggles the presence of a key in the set.  If the key is in
        /// the set, removes it.  Otherwise adds it.
        pub fn toggle(self: *Self, key: Key) void {
            self.bits.toggle(Indexer.indexOf(key));
        }

        /// Toggles the presence of all keys in the passed set.
        pub fn toggleSet(self: *Self, other: Self) void {
            self.bits.toggleSet(other.bits);
        }

        /// Toggles all possible keys in the set.
        pub fn toggleAll(self: *Self) void {
            self.bits.toggleAll();
        }

        /// Adds all keys in the passed set to this set.
        pub fn setUnion(self: *Self, other: Self) void {
            self.bits.setUnion(other.bits);
        }

        /// Removes all keys which are not in the passed set.
        pub fn setIntersection(self: *Self, other: Self) void {
            self.bits.setIntersection(other.bits);
        }

        /// Returns true iff both sets have the same keys.
        pub fn eql(self: Self, other: Self) bool {
            return self.bits.eql(other.bits);
        }

        /// Returns true iff all the keys in this set are
        /// in the other set. The other set may have keys
        /// not found in this set.
        pub fn subsetOf(self: Self, other: Self) bool {
            return self.bits.subsetOf(other.bits);
        }

        /// Returns true iff this set contains all the keys
        /// in the other set. This set may have keys not
        /// found in the other set.
        pub fn supersetOf(self: Self, other: Self) bool {
            return self.bits.supersetOf(other.bits);
        }

        /// Returns a set with all the keys not in this set.
        pub fn complement(self: Self) Self {
            return .{ .bits = self.bits.complement() };
        }

        /// Returns a set with keys that are in either this
        /// set or the other set.
        pub fn unionWith(self: Self, other: Self) Self {
            return .{ .bits = self.bits.unionWith(other.bits) };
        }

        /// Returns a set with keys that are in both this
        /// set and the other set.
        pub fn intersectWith(self: Self, other: Self) Self {
            return .{ .bits = self.bits.intersectWith(other.bits) };
        }

        /// Returns a set with keys that are in either this
        /// set or the other set, but not both.
        pub fn xorWith(self: Self, other: Self) Self {
            return .{ .bits = self.bits.xorWith(other.bits) };
        }

        /// Returns a set with keys that are in this set
        /// except for keys in the other set.
        pub fn differenceWith(self: Self, other: Self) Self {
            return .{ .bits = self.bits.differenceWith(other.bits) };
        }

        /// Returns an iterator over this set, which iterates in
        /// index order.  Modifications to the set during iteration
        /// may or may not be observed by the iterator, but will
        /// not invalidate it.
        pub fn iterator(self: *const Self) Iterator {
            return .{ .inner = self.bits.iterator(.{}) };
        }

        pub const Iterator = struct {
            inner: BitSet.Iterator(.{}),

            pub fn next(self: *Iterator) ?Key {
                return if (self.inner.next()) |index|
                    Indexer.keyForIndex(index)
                else
                    null;
            }
        };
    };
}

/// Increment this value when adding APIs that add single backwards branches.
const eval_branch_quota_cushion = 10;

fn EnumIndexer(comptime E: type) type {
    // n^2 for `std.mem.sortUnstable` call below: it is n log n on average,
    // but falls back to insertion sort on short ranges.
    const fields_len = @typeInfo(E).@"enum".field_names.len;
    @setEvalBranchQuota(@max(1000, 3 * fields_len * fields_len) + eval_branch_quota_cushion);

    if (@typeInfo(E).@"enum".mode == .nonexhaustive) {
        const BackingInt = @typeInfo(E).@"enum".tag_type;
        if (@bitSizeOf(BackingInt) > @bitSizeOf(usize))
            @compileError("Cannot create an enum indexer for a given non-exhaustive enum, tag_type is larger than usize.");

        return struct {
            pub const Key: type = E;

            const backing_int_sign = @typeInfo(BackingInt).int.signedness;
            const min_value = std.math.minInt(BackingInt);
            const max_value = std.math.maxInt(BackingInt);

            const RangeType = @Int(.unsigned, @bitSizeOf(BackingInt));
            pub const count: comptime_int = std.math.maxInt(RangeType) + 1;

            pub fn indexOf(e: E) usize {
                if (backing_int_sign == .unsigned)
                    return @backingInt(e);

                return if (@backingInt(e) < 0)
                    @intCast(@backingInt(e) - min_value)
                else
                    @as(RangeType, -min_value) + @as(RangeType, @intCast(@backingInt(e)));
            }
            pub fn keyForIndex(i: usize) E {
                if (backing_int_sign == .unsigned)
                    return @fromBackingInt(@intCast(i));

                return @fromBackingInt(@intCast(@as(@Int(.signed, @bitSizeOf(RangeType) + 1), @intCast(i)) + min_value));
            }
        };
    }

    if (fields_len == 0) {
        return struct {
            pub const Key = E;
            pub const count: comptime_int = 0;
            pub fn indexOf(e: E) usize {
                _ = e;
                unreachable;
            }
            pub fn keyForIndex(i: usize) E {
                _ = i;
                unreachable;
            }
        };
    }

    var field_values = @typeInfo(E).@"enum".field_values[0..fields_len].*;

    std.mem.sortUnstable(comptime_int, &field_values, {}, struct {
        fn lessThan(_: void, a: comptime_int, b: comptime_int) bool {
            return a < b;
        }
    }.lessThan);

    const min = field_values[0];
    const max = field_values[fields_len - 1];
    if (max - min == field_values.len - 1) {
        return struct {
            pub const Key = E;
            pub const count: comptime_int = fields_len;
            pub fn indexOf(e: E) usize {
                return @as(usize, @intCast(@backingInt(e) - min));
            }
            pub fn keyForIndex(i: usize) E {
                // TODO fix addition semantics.  This calculation
                // gives up some safety to avoid artificially limiting
                // the range of signed enum values to max_isize.
                const enum_value = if (min < 0) @as(isize, @bitCast(i)) +% min else i + min;
                return @as(E, @fromBackingInt(@intCast(@as(@typeInfo(E).@"enum".tag_type, @intCast(enum_value)))));
            }
        };
    }

    const keys = valuesFromFields(E, &field_values);

    return struct {
        pub const Key = E;
        pub const count: comptime_int = fields_len;
        pub fn indexOf(e: E) usize {
            for (keys, 0..) |k, i| {
                if (k == e) return i;
            }
            unreachable;
        }
        pub fn keyForIndex(i: usize) E {
            return keys[i];
        }
    };
}

/// Looks up the supplied field values in the given enum type.
/// The result array is in the same order as the input.
inline fn valuesFromFields(comptime E: type, comptime field_values: []const comptime_int) []const E {
    comptime {
        @setEvalBranchQuota(@typeInfo(E).@"enum".field_names.len + eval_branch_quota_cushion);
        var result: [field_values.len]E = undefined;
        for (&result, field_values) |*r, f_value| {
            r.* = @fromBackingInt(@intCast(f_value));
        }
        const final = result;
        return &final;
    }
}
