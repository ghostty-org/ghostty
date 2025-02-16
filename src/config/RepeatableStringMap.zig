/// RepeatableStringMap is a key/value that can be repeated to accumulate a
/// string map. This isn't called "StringMap" because I find that sometimes
/// leads to confusion that it _accepts_ a map such as JSON dict.
const RepeatableStringMap = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;

const formatterpkg = @import("formatter.zig");

const Map = std.ArrayHashMapUnmanaged(
    [:0]const u8,
    [:0]const u8,
    std.array_hash_map.StringContext,
    true,
);

// Allocator for the list is the arena for the parent config.
map: Map = .{},

pub fn parseCLI(
    self: *RepeatableStringMap,
    alloc: Allocator,
    input: ?[]const u8,
) !void {
    const value = input orelse return error.ValueRequired;

    // Empty value resets the list. We don't need to free our values because
    // the allocator used is always an arena.
    if (value.len == 0) {
        self.map.clearRetainingCapacity();
        return;
    }

    const index = std.mem.indexOfScalar(
        u8,
        value,
        '=',
    ) orelse return error.ValueRequired;

    const key = std.mem.trim(u8, value[0..index], &std.ascii.whitespace);
    const val = std.mem.trim(u8, value[index + 1 ..], &std.ascii.whitespace);

    const key_copy = try alloc.dupeZ(u8, key);
    errdefer alloc.free(key_copy);

    // Empty value removes the key from the map.
    if (val.len == 0) {
        _ = self.map.orderedRemove(key_copy);
        alloc.free(key_copy);
        return;
    }

    const val_copy = try alloc.dupeZ(u8, val);
    errdefer alloc.free(val_copy);

    try self.map.put(alloc, key_copy, val_copy);
}

/// Deep copy of the struct. Required by Config.
pub fn clone(
    self: *const RepeatableStringMap,
    alloc: Allocator,
) Allocator.Error!RepeatableStringMap {
    var map: Map = .{};
    try map.ensureTotalCapacity(alloc, self.map.count());

    errdefer {
        var it = map.iterator();
        while (it.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            alloc.free(entry.value_ptr.*);
        }
        map.deinit(alloc);
    }

    var it = self.map.iterator();
    while (it.next()) |entry| {
        const key = try alloc.dupeZ(u8, entry.key_ptr.*);
        const value = try alloc.dupeZ(u8, entry.value_ptr.*);
        map.putAssumeCapacity(key, value);
    }

    return .{ .map = map };
}

/// The number of items in the map
pub fn count(self: RepeatableStringMap) usize {
    return self.map.count();
}

/// Iterator over the entries in the map.
pub fn iterator(self: RepeatableStringMap) Map.Iterator {
    return self.map.iterator();
}

/// Compare if two of our value are requal. Required by Config.
pub fn equal(self: RepeatableStringMap, other: RepeatableStringMap) bool {
    if (self.map.count() != other.map.count()) return false;
    var it = self.map.iterator();
    while (it.next()) |entry| {
        const value = other.map.get(entry.key_ptr.*) orelse return false;
        if (!std.mem.eql(u8, entry.value_ptr.*, value)) return false;
    } else return true;
}

/// Used by formatter
pub fn formatEntry(self: RepeatableStringMap, formatter: anytype) !void {
    // If no items, we want to render an empty field.
    if (self.map.count() == 0) {
        try formatter.formatEntry(void, {});
        return;
    }

    var it = self.map.iterator();
    while (it.next()) |entry| {
        var buf: [256]u8 = undefined;
        const value = std.fmt.bufPrint(&buf, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* }) catch |err| switch (err) {
            error.NoSpaceLeft => return error.OutOfMemory,
        };
        try formatter.formatEntry([]const u8, value);
    }
}

test "RepeatableStringMap: parseCLI" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var map: RepeatableStringMap = .{};

    try testing.expectError(error.ValueRequired, map.parseCLI(alloc, "A"));

    try map.parseCLI(alloc, "A=B");
    try map.parseCLI(alloc, "B=C");
    try testing.expectEqual(@as(usize, 2), map.count());

    try map.parseCLI(alloc, "");
    try testing.expectEqual(@as(usize, 0), map.count());

    try map.parseCLI(alloc, "A=B");
    try testing.expectEqual(@as(usize, 1), map.count());
    try map.parseCLI(alloc, "A=C");
    try testing.expectEqual(@as(usize, 1), map.count());
}

test "RepeatableStringMap: formatConfig empty" {
    const testing = std.testing;
    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();

    var list: RepeatableStringMap = .{};
    try list.formatEntry(formatterpkg.entryFormatter("a", buf.writer()));
    try std.testing.expectEqualSlices(u8, "a = \n", buf.items);
}

test "RepeatableStringMap: formatConfig single item" {
    const testing = std.testing;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    {
        var buf = std.ArrayList(u8).init(testing.allocator);
        defer buf.deinit();
        var map: RepeatableStringMap = .{};
        try map.parseCLI(alloc, "A=B");
        try map.formatEntry(formatterpkg.entryFormatter("a", buf.writer()));
        try std.testing.expectEqualSlices(u8, "a = A=B\n", buf.items);
    }
    {
        var buf = std.ArrayList(u8).init(testing.allocator);
        defer buf.deinit();
        var map: RepeatableStringMap = .{};
        try map.parseCLI(alloc, " A = B ");
        try map.formatEntry(formatterpkg.entryFormatter("a", buf.writer()));
        try std.testing.expectEqualSlices(u8, "a = A=B\n", buf.items);
    }
}

test "RepeatableStringMap: formatConfig multiple items" {
    const testing = std.testing;

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    {
        var buf = std.ArrayList(u8).init(testing.allocator);
        defer buf.deinit();
        var list: RepeatableStringMap = .{};
        try list.parseCLI(alloc, "A=B");
        try list.parseCLI(alloc, "B = C");
        try list.formatEntry(formatterpkg.entryFormatter("a", buf.writer()));
        try std.testing.expectEqualSlices(u8, "a = A=B\na = B=C\n", buf.items);
    }
}
