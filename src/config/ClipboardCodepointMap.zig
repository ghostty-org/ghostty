/// ClipboardCodepointMap is a map of codepoints to replacement values
/// for clipboard operations. When copying text to clipboard, matching
/// codepoints will be replaced with their mapped values.
const ClipboardCodepointMap = @This();

const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;

// To ease our usage later, we map it directly to formatter entries.
pub const Entry = @import("../terminal/formatter.zig").CodepointMap;
pub const Replacement = Entry.Replacement;

/// The list of entries. We use a multiarraylist for cache-friendly lookups.
///
/// Note: we do a linear search because we expect to always have very
/// few entries, so the overhead of a binary search is not worth it.
list: std.MultiArrayList(Entry) = .{},

pub fn deinit(self: *ClipboardCodepointMap, alloc: Allocator) void {
    self.list.deinit(alloc);
}

/// Deep copy of the struct. The given allocator is expected to
/// be an arena allocator of some sort since the struct itself
/// doesn't support fine-grained deallocation of fields.
pub fn clone(self: *const ClipboardCodepointMap, alloc: Allocator) !ClipboardCodepointMap {
    var list = try self.list.clone(alloc);
    for (list.items(.replacement)) |*r| switch (r.*) {
        .string => |s| r.string = try alloc.dupe(u8, s),
        .codepoint => {}, // no allocation needed
    };

    return .{ .list = list };
}

/// Add an entry to the map.
///
/// For conflicting codepoints, entries added later take priority over
/// entries added earlier.
pub fn add(self: *ClipboardCodepointMap, alloc: Allocator, entry: Entry) !void {
    assert(entry.range[0] <= entry.range[1]);
    try self.list.append(alloc, entry);
}
