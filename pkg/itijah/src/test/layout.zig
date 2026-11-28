const std = @import("std");
const testing = std.testing;
const itijah = @import("../lib.zig");

fn assertLayoutInvariants(
    levels: []const itijah.BidiLevel,
    runs: []const itijah.VisualRun,
    l_to_v: []const u32,
    v_to_l: []const u32,
) !void {
    try testing.expectEqual(levels.len, l_to_v.len);
    try testing.expectEqual(levels.len, v_to_l.len);

    for (0..levels.len) |i| {
        const logical: u32 = @intCast(i);
        try testing.expectEqual(logical, v_to_l[l_to_v[i]]);
        try testing.expectEqual(logical, l_to_v[v_to_l[i]]);
    }

    var visual_cursor: u32 = 0;
    for (runs) |run| {
        try testing.expectEqual(visual_cursor, run.visual_start);
        try testing.expect(run.logical_start + run.len <= levels.len);
        visual_cursor += run.len;

        for (run.logical_start..run.logicalEnd()) |logical_idx_usize| {
            const logical_idx: u32 = @intCast(logical_idx_usize);
            const visual_idx = itijah.visualIndexForLogical(run, logical_idx);
            try testing.expectEqual(visual_idx, l_to_v[logical_idx]);
            try testing.expectEqual(logical_idx, itijah.logicalIndexForVisual(run, visual_idx));
            try testing.expectEqual(visual_idx - run.visual_start, itijah.clusterForLogical(run, logical_idx));
        }

        for (run.visual_start..run.visualEnd()) |visual_idx_usize| {
            const visual_idx: u32 = @intCast(visual_idx_usize);
            const logical_idx = itijah.logicalIndexForVisual(run, visual_idx);
            try testing.expectEqual(visual_idx, l_to_v[logical_idx]);
        }

        if (run.len > 1) {
            const slice_start = run.visual_start + 1;
            const slice_end = run.visualEnd();
            const logical_range = itijah.logicalRangeForVisualSlice(run, slice_start, slice_end);
            try testing.expect(logical_range.start <= logical_range.end);
            try testing.expect(logical_range.end <= levels.len);
        }
    }

    try testing.expectEqual(@as(u32, @intCast(levels.len)), visual_cursor);
}

fn runLayoutCase(cps: []const u21, opts: itijah.LayoutOptions) !void {
    const gpa = testing.allocator;

    var owned = try itijah.resolveVisualLayout(gpa, cps, opts);
    defer owned.deinit(gpa);
    try assertLayoutInvariants(owned.levels, owned.runs, owned.l_to_v, owned.v_to_l);

    var scratch = itijah.VisualLayoutScratch{};
    defer scratch.deinit(gpa);

    const view = try itijah.resolveVisualLayoutScratch(gpa, &scratch, cps, opts);
    try testing.expectEqualSlices(itijah.BidiLevel, owned.levels, view.levels);
    try testing.expectEqualSlices(itijah.VisualRun, owned.runs, view.runs);
    try testing.expectEqualSlices(u32, owned.l_to_v, view.l_to_v);
    try testing.expectEqualSlices(u32, owned.v_to_l, view.v_to_l);
    try testing.expectEqual(owned.base_level, view.base_level);
    try assertLayoutInvariants(view.levels, view.runs, view.l_to_v, view.v_to_l);
}

test "visual layout mixed LTR and RTL with neutrals" {
    const cps = [_]u21{ 'H', 'e', 'l', 'l', 'o', ' ', 0x0645, 0x0631, 0x062D, 0x0628, 0x0627 };
    try runLayoutCase(&cps, .{});
}

test "visual layout RTL plus Arabic digits and spaces" {
    const cps = [_]u21{ 0x0645, ' ', 0x0665, 0x0663 };
    try runLayoutCase(&cps, .{});
}

test "visual layout RTL word punctuation LTR word" {
    const cps = [_]u21{ 0x0645, 0x0631, 0x062D, 0x0628, 0x0627, '!', ' ', 'W', 'o', 'r', 'l', 'd' };
    try runLayoutCase(&cps, .{});
}

test "visual layout pure LTR" {
    const cps = [_]u21{ 'H', 'e', 'l', 'l', 'o', ' ', '1', '2', '3' };
    try runLayoutCase(&cps, .{});
}

test "visual layout pure RTL" {
    const cps = [_]u21{ 0x05D0, 0x05D1, 0x05D2, 0x05D3 };
    try runLayoutCase(&cps, .{});
}

test "visual layout empty input" {
    try runLayoutCase(&[_]u21{}, .{});
}

test "visual layout empty auto_rtl uses resolved RTL base level" {
    const gpa = testing.allocator;
    var owned = try itijah.resolveVisualLayout(gpa, &[_]u21{}, .{ .base_dir = .auto_rtl });
    defer owned.deinit(gpa);
    try testing.expectEqual(@as(itijah.BidiLevel, 1), owned.base_level);

    var scratch = itijah.VisualLayoutScratch{};
    defer scratch.deinit(gpa);
    const view = try itijah.resolveVisualLayoutScratch(gpa, &scratch, &[_]u21{}, .{ .base_dir = .auto_rtl });
    try testing.expectEqual(@as(itijah.BidiLevel, 1), view.base_level);
}

test "visual layout respects base_dir option" {
    const cps = [_]u21{ 0x05D0, 0x05D1, ' ', 'A', 'B' };
    try runLayoutCase(&cps, .{ .base_dir = .ltr });
    try runLayoutCase(&cps, .{ .base_dir = .rtl });
}

test "visual layout scratch leak test many calls then deinit" {
    const gpa = testing.allocator;
    var scratch = itijah.VisualLayoutScratch{};
    defer scratch.deinit(gpa);

    const cps_a = [_]u21{ 'A', ' ', 0x05D0, 0x05D1, ' ', 'B' };
    const cps_b = [_]u21{ 0x0645, 0x0631, 0x062D, 0x0628, 0x0627, ' ', 0x0661, 0x0662, 0x0663 };

    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const cps = if (i % 2 == 0) &cps_a else &cps_b;
        const view = try itijah.resolveVisualLayoutScratch(gpa, &scratch, cps, .{});
        try assertLayoutInvariants(view.levels, view.runs, view.l_to_v, view.v_to_l);
    }
}
