//! This structure caches the shaped cells for a given text run.
//!
//! At one point, shaping was the most expensive part of rendering text
//! (accounting for 96% of frame time on my machine). To speed it up, this
//! was introduced so that shaping results can be cached depending on the
//! run.
//!
//! The cache key is the text run. The text run builds its own hash value
//! based on the font, style, codepoint, etc. This just utilizes the hash that
//! the text run provides.
pub const Cache = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const font = @import("../main.zig");
const CacheTable = @import("../../datastruct/main.zig").CacheTable;

const log = std.log.scoped(.font_shaper_cache);

/// Context for cache table.
const CellCacheTableContext = struct {
    pub fn hash(self: *const CellCacheTableContext, key: u64) u64 {
        _ = self;
        return key;
    }
    pub fn eql(self: *const CellCacheTableContext, a: u64, b: u64) bool {
        _ = self;
        return a == b;
    }
};

/// Cache table for run hash -> shaped cells.
const CellCacheTable = CacheTable(
    u64,
    []font.shape.Cell,
    CellCacheTableContext,

    // Capacity is slightly arbitrary. These numbers are guesses.
    //
    // I'd expect then an average of 256 frequently cached runs is a
    // safe guess most terminal screens.
    256,
    // 8 items per bucket to give decent resilliency to important runs.
    8,
);

/// The cache table of shaped cells.
map: CellCacheTable,

pub fn init() Cache {
    return .{ .map = .{ .context = .{} } };
}

pub fn deinit(self: *Cache, alloc: Allocator) void {
    self.clear(alloc);
}

/// Get the shaped cells for the given text run,
/// or null if they are not in the cache.
pub fn get(self: *Cache, run: font.shape.TextRun) ?[]const font.shape.Cell {
    return self.map.get(run.hash);
}

/// Insert the shaped cells for the given text run into the cache.
///
/// The cells will be duplicated.
pub fn put(
    self: *Cache,
    alloc: Allocator,
    run: font.shape.TextRun,
    cells: []const font.shape.Cell,
) Allocator.Error!void {
    const copy = try alloc.dupe(font.shape.Cell, cells);
    const evicted = self.map.put(run.hash, copy);
    if (evicted) |kv| {
        alloc.free(kv.value);
    }
}

fn clear(self: *Cache, alloc: Allocator) void {
    for (self.map.buckets, self.map.lengths) |b, l| {
        for (b[0..l]) |kv| {
            alloc.free(kv.value);
        }
    }
    self.map.clear();
}

test Cache {
    const testing = std.testing;
    const alloc = testing.allocator;

    var c = Cache.init();
    defer c.deinit(alloc);

    var run: font.shape.TextRun = undefined;
    run.hash = 1;
    try testing.expect(c.get(run) == null);
    try c.put(alloc, run, &.{
        .{ .x = 0, .glyph_index = 0 },
        .{ .x = 1, .glyph_index = 1 },
    });

    const actual = c.get(run).?;
    try testing.expect(actual.len == 2);
}
