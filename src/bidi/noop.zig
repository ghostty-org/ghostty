//! The identity bidi backend.
//!
//! This resolves every paragraph to left-to-right with visual order equal
//! to logical order. It is what Ghostty ships with until the rendering
//! pipeline that consumes real bidi results exists, and it remains the
//! escape hatch for builds that want bidi compiled out entirely.
//!
//! It is not a stub: it implements the full `Resolver` API and produces
//! well-formed results, so every consumer can be written and tested against
//! it before a real backend arrives.

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");

const Level = types.Level;
const LevelRun = types.LevelRun;
const Options = types.Options;
const Result = types.Result;

pub const Resolver = struct {
    /// The single synthesized level run. Kept in the resolver rather than
    /// returned by value so that `Result.runs` has the same lifetime rules
    /// for every backend.
    runs: std.ArrayList(LevelRun) = .empty,

    pub const empty: Resolver = .{};

    pub fn deinit(self: *Resolver, alloc: Allocator) void {
        self.runs.deinit(alloc);
        self.* = undefined;
    }

    /// Resolve one paragraph.
    ///
    /// The returned slices borrow this resolver's buffers and are valid
    /// until the next call. `opts` is accepted for API parity and ignored:
    /// a backend that performs no reordering has no meaningful response to
    /// a forced paragraph direction, and pretending otherwise would report
    /// a direction inconsistent with the identity mapping it returns.
    pub fn resolve(
        self: *Resolver,
        alloc: Allocator,
        codepoints: []const u21,
        opts: Options,
    ) Allocator.Error!Result {
        _ = opts;

        std.debug.assert(codepoints.len <= std.math.maxInt(u16));
        if (codepoints.len == 0) return .empty;

        // Retains capacity, so this is allocation-free after the first
        // call for any row length seen so far.
        self.runs.clearRetainingCapacity();
        try self.runs.append(alloc, .{
            .visual_start = 0,
            .len = @intCast(codepoints.len),
            .logical_start = 0,
            .level = 0,
        });

        return .{
            .direction = .ltr,
            .len = codepoints.len,
            .identity = true,
            .levels = &.{},
            .v2l = &.{},
            .l2v = &.{},
            .runs = self.runs.items,
        };
    }
};

test "noop: empty input" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var r: Resolver = .empty;
    defer r.deinit(alloc);

    const result = try r.resolve(alloc, &.{}, .{});
    try testing.expectEqual(@as(usize, 0), result.len);
    try testing.expect(result.identity);
    try testing.expectEqual(@as(usize, 0), result.runs.len);
}

test "noop: ascii resolves to identity" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var r: Resolver = .empty;
    defer r.deinit(alloc);

    const cps = [_]u21{ 'h', 'e', 'l', 'l', 'o' };
    const result = try r.resolve(alloc, &cps, .{});

    try testing.expectEqual(types.Direction.ltr, result.direction);
    try testing.expectEqual(@as(usize, 5), result.len);
    try testing.expect(result.identity);
    try testing.expectEqual(@as(usize, 0), result.levels.len);
    try testing.expectEqual(@as(usize, 0), result.v2l.len);
    try testing.expectEqual(@as(usize, 0), result.l2v.len);

    for (0..5) |i| {
        try testing.expectEqual(i, result.logicalIndex(i));
        try testing.expectEqual(i, result.visualIndex(i));
        try testing.expectEqual(@as(Level, 0), result.level(i));
    }
}

test "noop: rtl input still resolves to identity" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var r: Resolver = .empty;
    defer r.deinit(alloc);

    // Hebrew alef-bet-gimel. A real backend reverses these; noop must not,
    // because "no reordering" is exactly its contract.
    const cps = [_]u21{ 0x05D0, 0x05D1, 0x05D2 };
    const result = try r.resolve(alloc, &cps, .{});

    try testing.expect(result.identity);
    try testing.expectEqual(types.Direction.ltr, result.direction);
    for (0..3) |i| try testing.expectEqual(i, result.logicalIndex(i));
}

test "noop: forced direction is ignored" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var r: Resolver = .empty;
    defer r.deinit(alloc);

    const cps = [_]u21{ 'a', 'b' };
    const result = try r.resolve(alloc, &cps, .{ .direction = .rtl });

    // Reporting .rtl here would contradict the identity mapping we return.
    try testing.expectEqual(types.Direction.ltr, result.direction);
    try testing.expect(result.identity);
}

test "noop: produces exactly one level run" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var r: Resolver = .empty;
    defer r.deinit(alloc);

    const cps = [_]u21{ 'a', 'b', 'c', 'd' };
    const result = try r.resolve(alloc, &cps, .{});

    try testing.expectEqual(@as(usize, 1), result.runs.len);
    const run = result.runs[0];
    try testing.expectEqual(@as(u16, 0), run.visual_start);
    try testing.expectEqual(@as(u16, 4), run.len);
    try testing.expectEqual(@as(u16, 0), run.logical_start);
    try testing.expectEqual(@as(Level, 0), run.level);
    try testing.expectEqual(types.Direction.ltr, run.direction());
}

test "noop: steady state performs no allocations" {
    const testing = std.testing;

    var counting: std.testing.FailingAllocator = .init(testing.allocator, .{
        .fail_index = std.math.maxInt(usize),
    });
    const alloc = counting.allocator();

    var r: Resolver = .empty;
    defer r.deinit(alloc);

    const cps = [_]u21{ 'a', 'b', 'c' };

    // Warm up: this one is allowed to allocate the run buffer.
    _ = try r.resolve(alloc, &cps, .{});
    const after_warmup = counting.allocations;

    // Every subsequent call must reuse the retained capacity.
    for (0..64) |_| _ = try r.resolve(alloc, &cps, .{});
    try testing.expectEqual(after_warmup, counting.allocations);
}
