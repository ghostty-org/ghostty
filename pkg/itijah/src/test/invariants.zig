const std = @import("std");
const testing = std.testing;
const itijah = @import("../lib.zig");
const BidiLevel = itijah.BidiLevel;
const ParDirection = itijah.ParDirection;

test "deterministic output" {
    const gpa = testing.allocator;
    const input = [_]u21{ 'H', 'e', 'l', 'l', 'o', ' ', 0x05D0, 0x05D1 };

    var dir1: ParDirection = .auto_ltr;
    var r1 = try itijah.getParEmbeddingLevels(gpa, &input, &dir1);
    defer r1.deinit(gpa);

    var dir2: ParDirection = .auto_ltr;
    var r2 = try itijah.getParEmbeddingLevels(gpa, &input, &dir2);
    defer r2.deinit(gpa);

    try testing.expectEqualSlices(BidiLevel, r1.levels, r2.levels);
    try testing.expectEqual(r1.resolved_par_dir, r2.resolved_par_dir);
}

test "level bounds" {
    const gpa = testing.allocator;

    // Deeply nested embeddings should not exceed max level
    var deep_input: [256]u21 = undefined;
    for (0..128) |i| deep_input[i] = 0x202A; // LRE
    for (128..256) |i| deep_input[i] = 0x202C; // PDF

    var dir: ParDirection = .ltr;
    var result = try itijah.getParEmbeddingLevels(gpa, &deep_input, &dir);
    defer result.deinit(gpa);

    for (result.levels) |l| {
        try testing.expect(l <= 126);
    }
}

test "empty input" {
    const gpa = testing.allocator;
    var dir: ParDirection = .auto_ltr;
    var result = try itijah.getParEmbeddingLevels(gpa, &[_]u21{}, &dir);
    defer result.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), result.levels.len);
}

test "single character" {
    const gpa = testing.allocator;

    // Single LTR
    {
        var dir: ParDirection = .auto_ltr;
        var result = try itijah.getParEmbeddingLevels(gpa, &[_]u21{'A'}, &dir);
        defer result.deinit(gpa);
        try testing.expectEqual(@as(BidiLevel, 0), result.levels[0]);
    }

    // Single RTL
    {
        var dir: ParDirection = .auto_ltr;
        var result = try itijah.getParEmbeddingLevels(gpa, &[_]u21{0x05D0}, &dir);
        defer result.deinit(gpa);
        try testing.expectEqual(@as(BidiLevel, 1), result.levels[0]);
    }
}

test "reorder round-trip: v_to_l and l_to_v are inverses" {
    const gpa = testing.allocator;
    const input = [_]u21{ 'A', 'B', 0x05D0, 0x05D1, 'C' };
    const levels = [_]BidiLevel{ 0, 0, 1, 1, 0 };

    var result = try itijah.reorderLine(gpa, &input, &levels, 0);
    defer result.deinit(gpa);

    // v_to_l[l_to_v[i]] == i for all i
    for (0..input.len) |i| {
        const vi: u32 = @intCast(i);
        try testing.expectEqual(vi, result.v_to_l[result.l_to_v[i]]);
    }
}

test "memory leak: repeated alloc/dealloc" {
    const gpa = testing.allocator;

    for (0..100) |_| {
        var dir: ParDirection = .auto_ltr;
        const input = [_]u21{ 'A', 0x05D0, 'B', 0x05D1, ' ', '!', 0x0627 };
        var result = try itijah.getParEmbeddingLevels(gpa, &input, &dir);
        result.deinit(gpa);
    }
}

test "forced LTR direction ignores strong RTL" {
    const gpa = testing.allocator;
    var dir: ParDirection = .ltr;
    const input = [_]u21{ 0x05D0, 0x05D1, 0x05D2 };
    var result = try itijah.getParEmbeddingLevels(gpa, &input, &dir);
    defer result.deinit(gpa);

    try testing.expectEqual(ParDirection.ltr, result.resolved_par_dir);
    // RTL chars in LTR paragraph get level 1
    for (result.levels) |l| {
        try testing.expectEqual(@as(BidiLevel, 1), l);
    }
}

test "forced RTL direction ignores strong LTR" {
    const gpa = testing.allocator;
    var dir: ParDirection = .rtl;
    const input = [_]u21{ 'A', 'B', 'C' };
    var result = try itijah.getParEmbeddingLevels(gpa, &input, &dir);
    defer result.deinit(gpa);

    try testing.expectEqual(ParDirection.rtl, result.resolved_par_dir);
    // LTR chars in RTL paragraph get level 2
    for (result.levels) |l| {
        try testing.expectEqual(@as(BidiLevel, 2), l);
    }
}

test "numbers in RTL context" {
    const gpa = testing.allocator;
    var dir: ParDirection = .rtl;
    // Hebrew + digits
    const input = [_]u21{ 0x05D0, '1', '2', '3', 0x05D1 };
    var result = try itijah.getParEmbeddingLevels(gpa, &input, &dir);
    defer result.deinit(gpa);

    try testing.expectEqual(@as(BidiLevel, 1), result.levels[0]); // R
    try testing.expectEqual(@as(BidiLevel, 2), result.levels[1]); // EN -> level 2 in RTL
    try testing.expectEqual(@as(BidiLevel, 1), result.levels[4]); // R
}
