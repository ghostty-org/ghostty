//! Keep track of the location of tabstops.
//!
//! This is implemented as a bit set. There is a preallocation segment that
//! is used for almost all screen sizes. Then there is a dynamically allocated
//! segment if the screen is larger than the preallocation amount.
//!
//! In reality, tabstops don't need to be the most performant in any metric.
//! This implementation tries to balance denser memory usage (by using a bitset)
//! and minimizing unnecessary allocations.
const Tabstops = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const assert = std.debug.assert;
const fastmem = @import("../fastmem.zig");

/// Unit is the type we use per tabstop unit (see file docs).
const Unit = u8;
const unit_bits = @bitSizeOf(Unit);

/// The number of columns we preallocate for. This is kind of high which
/// costs us some memory, but this is more columns than my 6k monitor at
/// 12-point font size, so this should prevent allocation in almost all
/// real world scenarios for the price of wasting at most
/// (columns / sizeOf(Unit)) bytes.
const prealloc_columns = 512;

/// The number of entries we need for our preallocation.
const prealloc_count = prealloc_columns / unit_bits;

/// We precompute all the possible masks since we never use a huge bit size.
const masks = blk: {
    var res: [unit_bits]Unit = undefined;
    for (res, 0..) |_, i| {
        res[i] = @shlExact(@as(Unit, 1), @as(u3, @intCast(i)));
    }

    break :blk res;
};

/// The number of columns this tabstop is set to manage. Use resize()
/// to change this number.
cols: usize = 0,

/// Preallocated tab stops.
prealloc_stops: [prealloc_count]Unit = @splat(0),

/// Dynamically expanded stops above prealloc stops.
dynamic_stops: []Unit = &[0]Unit{},

/// Returns the entry in the stops array that would contain this column.
inline fn entry(col: usize) usize {
    return col / unit_bits;
}

inline fn index(col: usize) usize {
    return @mod(col, unit_bits);
}

pub fn init(alloc: Allocator, cols: usize, interval: usize) !Tabstops {
    var res: Tabstops = .{};
    try res.resize(alloc, cols);
    res.reset(interval);
    return res;
}

pub fn deinit(self: *Tabstops, alloc: Allocator) void {
    if (self.dynamic_stops.len > 0) alloc.free(self.dynamic_stops);
    self.* = undefined;
}

/// Set the tabstop at a certain column. The columns are 0-indexed.
pub fn set(self: *Tabstops, col: usize) void {
    const i = entry(col);
    const idx = index(col);
    if (i < prealloc_count) {
        self.prealloc_stops[i] |= masks[idx];
        return;
    }

    const dynamic_i = i - prealloc_count;
    assert(dynamic_i < self.dynamic_stops.len);
    self.dynamic_stops[dynamic_i] |= masks[idx];
}

/// Unset the tabstop at a certain column. The columns are 0-indexed.
pub fn unset(self: *Tabstops, col: usize) void {
    const i = entry(col);
    const idx = index(col);
    if (i < prealloc_count) {
        self.prealloc_stops[i] ^= masks[idx];
        return;
    }

    const dynamic_i = i - prealloc_count;
    assert(dynamic_i < self.dynamic_stops.len);
    self.dynamic_stops[dynamic_i] ^= masks[idx];
}

/// Get the value of a tabstop at a specific column. The columns are 0-indexed.
pub fn get(self: Tabstops, col: usize) bool {
    const i = entry(col);
    const idx = index(col);
    const mask = masks[idx];
    const unit = if (i < prealloc_count)
        self.prealloc_stops[i]
    else unit: {
        const dynamic_i = i - prealloc_count;
        assert(dynamic_i < self.dynamic_stops.len);
        break :unit self.dynamic_stops[dynamic_i];
    };

    return unit & mask == mask;
}

/// Resize this to support up to cols columns.
// TODO: needs interval to set new tabstops
pub fn resize(self: *Tabstops, alloc: Allocator, cols: usize) !void {
    // Set our new value
    self.cols = cols;

    // Do nothing if it fits.
    if (cols <= prealloc_columns) return;

    // What we need in the dynamic size
    const size = cols - prealloc_columns;
    if (size < self.dynamic_stops.len) return;

    // Note: we can probably try to realloc here but I'm not sure it matters.
    const new = try alloc.alloc(Unit, size);
    if (self.dynamic_stops.len > 0) {
        fastmem.copy(Unit, new, self.dynamic_stops);
        alloc.free(self.dynamic_stops);
    }

    self.dynamic_stops = new;
}

/// Return the maximum number of columns this can support currently.
pub fn capacity(self: Tabstops) usize {
    return (prealloc_count + self.dynamic_stops.len) * unit_bits;
}

/// Unset all tabstops and then reset the initial tabstops to the given
/// interval. An interval of 0 sets no tabstops.
pub fn reset(self: *Tabstops, interval: usize) void {
    @memset(&self.prealloc_stops, 0);
    @memset(self.dynamic_stops, 0);

    if (interval > 0) {
        var i: usize = interval;
        while (i < self.cols - 1) : (i += interval) {
            self.set(i);
        }
    }
}

test "Tabstops: basic" {
    var t: Tabstops = .{};
    defer t.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), entry(4));
    try testing.expectEqual(@as(usize, 1), entry(8));
    try testing.expectEqual(@as(usize, 0), index(0));
    try testing.expectEqual(@as(usize, 1), index(1));
    try testing.expectEqual(@as(usize, 1), index(9));

    try testing.expectEqual(@as(Unit, 0b00001000), masks[3]);
    try testing.expectEqual(@as(Unit, 0b00010000), masks[4]);

    try testing.expect(!t.get(4));
    t.set(4);
    try testing.expect(t.get(4));
    try testing.expect(!t.get(3));

    t.reset(0);
    try testing.expect(!t.get(4));

    t.set(4);
    try testing.expect(t.get(4));
    t.unset(4);
    try testing.expect(!t.get(4));
}

test "Tabstops: dynamic allocations" {
    var t: Tabstops = .{};
    defer t.deinit(testing.allocator);

    // Grow the capacity by 2.
    const cap = t.capacity();
    try t.resize(testing.allocator, cap * 2);

    // Set something that was out of range of the first
    t.set(cap + 5);
    try testing.expect(t.get(cap + 5));
    try testing.expect(!t.get(cap + 4));

    // Prealloc still works
    try testing.expect(!t.get(5));
}

test "Tabstops: interval" {
    var t: Tabstops = try init(testing.allocator, 80, 4);
    defer t.deinit(testing.allocator);
    try testing.expect(!t.get(0));
    try testing.expect(t.get(4));
    try testing.expect(!t.get(5));
    try testing.expect(t.get(8));
}

test "Tabstops: count on 80" {
    // https://superuser.com/questions/710019/why-there-are-11-tabstops-on-a-80-column-console

    var t: Tabstops = try init(testing.allocator, 80, 8);
    defer t.deinit(testing.allocator);

    // Count the tabstops
    const count: usize = count: {
        var v: usize = 0;
        var i: usize = 0;
        while (i < 80) : (i += 1) {
            if (t.get(i)) {
                v += 1;
            }
        }

        break :count v;
    };

    try testing.expectEqual(@as(usize, 9), count);
}
