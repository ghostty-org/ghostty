const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

const level_mod = @import("level.zig");
const BidiLevel = level_mod.BidiLevel;
const types = @import("types.zig");
const unicode = @import("../data/unicode.zig");
const BidiClass = unicode.BidiClass;
const mirroring = @import("../data/mirroring.zig");

const visual_inplace_threshold: u32 = 2048;
const compact_map_min_len: u32 = 8192;

pub const ReorderScratch = struct {
    visual: std.ArrayList(u21) = .empty,
    map16: std.ArrayList(u16) = .empty,
    map32: std.ArrayList(u32) = .empty,

    pub fn deinit(self: *ReorderScratch, allocator: Allocator) void {
        self.visual.deinit(allocator);
        self.map16.deinit(allocator);
        self.map32.deinit(allocator);
    }
};

pub const ReorderLineScratch = struct {
    visual: std.ArrayList(u21) = .empty,
    l_to_v: std.ArrayList(u32) = .empty,
    v_to_l: std.ArrayList(u32) = .empty,

    pub fn deinit(self: *ReorderLineScratch, allocator: Allocator) void {
        self.visual.deinit(allocator);
        self.l_to_v.deinit(allocator);
        self.v_to_l.deinit(allocator);
    }
};

pub const VisualRunsScratch = struct {
    v_to_l: std.ArrayList(u32) = .empty,
    runs: std.ArrayList(types.VisualRun) = .empty,

    pub fn deinit(self: *VisualRunsScratch, allocator: Allocator) void {
        self.v_to_l.deinit(allocator);
        self.runs.deinit(allocator);
    }
};

pub const LogToVisScratch = struct {
    v_to_l: std.ArrayList(u32) = .empty,
    l_to_v: std.ArrayList(u32) = .empty,

    pub fn deinit(self: *LogToVisScratch, allocator: Allocator) void {
        self.v_to_l.deinit(allocator);
        self.l_to_v.deinit(allocator);
    }
};

const LevelExtents = struct {
    max_level: BidiLevel,
    min_odd: BidiLevel,
};

/// Reorder a line of codepoints from logical to visual order.
/// Implements Rules L1 (part 4), L2. L3/L4 are Phase 2.
pub fn reorderLine(
    allocator: Allocator,
    codepoints: []const u21,
    levels: []const BidiLevel,
    base_level: BidiLevel,
) !types.ReorderResult {
    const len: u32 = @intCast(codepoints.len);
    std.debug.assert(codepoints.len == levels.len);

    if (len == 0) {
        const visual = try allocator.alloc(u21, 0);
        errdefer allocator.free(visual);
        const l_to_v = try allocator.alloc(u32, 0);
        errdefer allocator.free(l_to_v);
        const v_to_l = try allocator.alloc(u32, 0);
        return .{
            .visual = visual,
            .l_to_v = l_to_v,
            .v_to_l = v_to_l,
            .max_level = base_level,
        };
    }

    // Build index map
    const map = try allocator.alloc(u32, len);
    errdefer allocator.free(map);
    initIdentityMap(map);

    const extents = levelExtents(levels, base_level);

    // L2: Reverse subsequences at each level from max down to min odd
    applyL2(map, levels, len, extents.min_odd, extents.max_level);

    // Build visual string
    const visual = try allocator.alloc(u21, len);
    errdefer allocator.free(visual);
    for (0..len) |i| {
        visual[i] = codepoints[map[i]];
    }

    // Build reverse map (v_to_l is already `map`, build l_to_v)
    const l_to_v = try allocator.alloc(u32, len);
    errdefer allocator.free(l_to_v);
    fillLToVFromVToL(l_to_v, map);

    return .{
        .visual = visual,
        .l_to_v = l_to_v,
        .v_to_l = map,
        .max_level = extents.max_level,
    };
}

/// Reorder a line using reusable scratch buffers.
///
/// Returned slices are owned by `scratch` and remain valid until the next call that
/// mutates the same scratch object.
pub fn reorderLineScratch(
    allocator: Allocator,
    scratch: *ReorderLineScratch,
    codepoints: []const u21,
    levels: []const BidiLevel,
    base_level: BidiLevel,
) !types.ReorderResultScratchView {
    const len: u32 = @intCast(codepoints.len);
    std.debug.assert(codepoints.len == levels.len);

    try scratch.visual.ensureTotalCapacity(allocator, len);
    scratch.visual.items.len = len;
    try scratch.l_to_v.ensureTotalCapacity(allocator, len);
    scratch.l_to_v.items.len = len;
    try scratch.v_to_l.ensureTotalCapacity(allocator, len);
    scratch.v_to_l.items.len = len;

    const visual = scratch.visual.items;
    const l_to_v = scratch.l_to_v.items;
    const v_to_l = scratch.v_to_l.items;

    const extents = levelExtents(levels, base_level);
    if (len > 0) {
        initIdentityMap(v_to_l);
        applyL2(v_to_l, levels, len, extents.min_odd, extents.max_level);

        for (0..len) |i| {
            visual[i] = codepoints[v_to_l[i]];
        }
        fillLToVFromVToL(l_to_v, v_to_l);
    }

    return .{
        .visual = visual,
        .l_to_v = l_to_v,
        .v_to_l = v_to_l,
        .max_level = extents.max_level,
    };
}

/// Reorder a line and return only the visual codepoints.
/// Uses less memory than `reorderLine` because it does not build index maps.
pub fn reorderVisualOnly(
    allocator: Allocator,
    codepoints: []const u21,
    levels: []const BidiLevel,
    base_level: BidiLevel,
) ![]u21 {
    const len: u32 = @intCast(codepoints.len);
    std.debug.assert(codepoints.len == levels.len);

    const visual = try allocator.alloc(u21, len);
    errdefer allocator.free(visual);
    if (len == 0) return visual;

    const extents = levelExtents(levels, base_level);

    if (extents.min_odd > extents.max_level) {
        @memcpy(visual, codepoints);
        return visual;
    }

    if (len <= visual_inplace_threshold) {
        @memcpy(visual, codepoints);
        applyL2Visual(visual, levels, len, extents.min_odd, extents.max_level);
        return visual;
    }

    if (len >= compact_map_min_len and len <= std.math.maxInt(u16)) {
        const map = try allocator.alloc(u16, len);
        defer allocator.free(map);
        initIdentityMap(map);
        applyL2(map, levels, len, extents.min_odd, extents.max_level);
        for (0..len) |i| {
            visual[i] = codepoints[map[i]];
        }
    } else {
        const map = try allocator.alloc(u32, len);
        defer allocator.free(map);
        initIdentityMap(map);
        applyL2(map, levels, len, extents.min_odd, extents.max_level);
        for (0..len) |i| {
            visual[i] = codepoints[map[i]];
        }
    }

    return visual;
}

/// Reorder a line and return only the visual codepoints using reusable scratch memory.
///
/// Returned slice is owned by `scratch` and remains valid until the next call that
/// mutates the same scratch object.
pub fn reorderVisualOnlyScratch(
    allocator: Allocator,
    scratch: *ReorderScratch,
    codepoints: []const u21,
    levels: []const BidiLevel,
    base_level: BidiLevel,
) ![]const u21 {
    const len: u32 = @intCast(codepoints.len);
    std.debug.assert(codepoints.len == levels.len);

    try scratch.visual.ensureTotalCapacity(allocator, len);
    scratch.visual.items.len = len;
    const visual = scratch.visual.items;
    if (len == 0) return visual;

    const extents = levelExtents(levels, base_level);

    if (extents.min_odd > extents.max_level) {
        @memcpy(visual, codepoints);
        return visual;
    }

    // For medium sizes, reverse visual output in-place to avoid map setup/allocation.
    // For very large lines, map+gather is typically faster despite higher memory writes.
    if (len <= visual_inplace_threshold) {
        @memcpy(visual, codepoints);
        applyL2Visual(visual, levels, len, extents.min_odd, extents.max_level);
        return visual;
    }

    if (len >= compact_map_min_len and len <= std.math.maxInt(u16)) {
        try scratch.map16.ensureTotalCapacity(allocator, len);
        scratch.map16.items.len = len;
        const map = scratch.map16.items;
        initIdentityMap(map);
        applyL2(map, levels, len, extents.min_odd, extents.max_level);
        for (0..len) |i| {
            visual[i] = codepoints[map[i]];
        }
    } else {
        try scratch.map32.ensureTotalCapacity(allocator, len);
        scratch.map32.items.len = len;
        const map = scratch.map32.items;
        initIdentityMap(map);
        applyL2(map, levels, len, extents.min_odd, extents.max_level);
        for (0..len) |i| {
            visual[i] = codepoints[map[i]];
        }
    }
    return visual;
}

/// Build logical-to-visual index map from embedding levels.
pub fn logToVisMap(
    allocator: Allocator,
    levels: []const BidiLevel,
    base_level: BidiLevel,
) ![]u32 {
    const len: u32 = @intCast(levels.len);
    if (len == 0) return try allocator.alloc(u32, 0);

    const map = try allocator.alloc(u32, len);
    errdefer allocator.free(map);
    initIdentityMap(map);
    const extents = levelExtents(levels, base_level);
    applyL2(map, levels, len, extents.min_odd, extents.max_level);

    // Convert v_to_l to l_to_v
    const l_to_v = try allocator.alloc(u32, len);
    fillLToVFromVToL(l_to_v, map);
    allocator.free(map);

    return l_to_v;
}

/// Build logical-to-visual index map from embedding levels using reusable scratch buffers.
///
/// Returned slice is owned by `scratch` and remains valid until the next call that
/// mutates the same scratch object.
pub fn logToVisScratch(
    allocator: Allocator,
    scratch: *LogToVisScratch,
    levels: []const BidiLevel,
    base_level: BidiLevel,
) ![]u32 {
    const len: u32 = @intCast(levels.len);
    try scratch.v_to_l.ensureTotalCapacity(allocator, len);
    scratch.v_to_l.items.len = len;
    try scratch.l_to_v.ensureTotalCapacity(allocator, len);
    scratch.l_to_v.items.len = len;

    const v_to_l = scratch.v_to_l.items;
    const l_to_v = scratch.l_to_v.items;

    if (len > 0) {
        initIdentityMap(v_to_l);
        const extents = levelExtents(levels, base_level);
        applyL2(v_to_l, levels, len, extents.min_odd, extents.max_level);
        fillLToVFromVToL(l_to_v, v_to_l);
    }

    return l_to_v;
}

/// Derive visual runs in visual order from embedding levels.
///
/// Each run maps to a contiguous logical slice `[logical_start .. logical_start + len)`.
/// The returned runs are ordered by visual position and carry `is_rtl` for shaping/layout.
pub fn visualRuns(
    allocator: Allocator,
    levels: []const BidiLevel,
    base_level: BidiLevel,
) ![]types.VisualRun {
    const len: u32 = @intCast(levels.len);
    if (len == 0) return try allocator.alloc(types.VisualRun, 0);

    const v_to_l = try allocator.alloc(u32, len);
    defer allocator.free(v_to_l);
    initIdentityMap(v_to_l);
    const extents = levelExtents(levels, base_level);
    applyL2(v_to_l, levels, len, extents.min_odd, extents.max_level);

    var runs = std.ArrayList(types.VisualRun).empty;
    errdefer runs.deinit(allocator);
    try buildVisualRunsFromVToL(allocator, &runs, v_to_l, levels);

    return try runs.toOwnedSlice(allocator);
}

/// Derive visual runs in visual order from embedding levels using reusable scratch buffers.
///
/// Returned slice is owned by `scratch` and remains valid until the next call that
/// mutates the same scratch object.
pub fn visualRunsScratch(
    allocator: Allocator,
    scratch: *VisualRunsScratch,
    levels: []const BidiLevel,
    base_level: BidiLevel,
) ![]types.VisualRun {
    const len: u32 = @intCast(levels.len);

    try scratch.v_to_l.ensureTotalCapacity(allocator, len);
    scratch.v_to_l.items.len = len;
    scratch.runs.clearRetainingCapacity();

    if (len == 0) {
        return scratch.runs.items;
    }

    const v_to_l = scratch.v_to_l.items;
    initIdentityMap(v_to_l);
    const extents = levelExtents(levels, base_level);
    applyL2(v_to_l, levels, len, extents.min_odd, extents.max_level);

    try buildVisualRunsFromVToL(allocator, &scratch.runs, v_to_l, levels);
    return scratch.runs.items;
}

/// Remove bidi control marks from a codepoint array.
///
/// If `levels` is provided, this function compacts it in-place so `levels[0..new_len]`
/// stays aligned with the returned codepoint order.
pub fn removeBidiMarks(
    allocator: Allocator,
    codepoints: []const u21,
    levels: ?[]BidiLevel,
) !types.RemoveBidiMarksResult {
    const out = try allocator.alloc(u21, codepoints.len);
    errdefer allocator.free(out);

    var j: u32 = 0;
    for (codepoints, 0..) |cp, i| {
        if (!unicode.isBidiControl(cp)) {
            out[j] = cp;
            if (levels) |lvls| {
                lvls[j] = lvls[i];
            }
            j += 1;
        }
    }

    return .{ .result = out, .new_len = j };
}

fn initIdentityMap(map: anytype) void {
    const T = std.meta.Elem(@TypeOf(map));
    for (0..map.len) |i| {
        map[i] = @as(T, @intCast(i));
    }
}

fn fillLToVFromVToL(l_to_v: []u32, v_to_l: []const u32) void {
    std.debug.assert(l_to_v.len == v_to_l.len);
    for (v_to_l, 0..) |logical_idx, visual_idx| {
        l_to_v[logical_idx] = @intCast(visual_idx);
    }
}

fn levelExtents(levels: []const BidiLevel, base_level: BidiLevel) LevelExtents {
    var max_level: BidiLevel = base_level;
    var min_odd: BidiLevel = level_mod.max_resolved_level + 1;
    for (levels) |l| {
        if (l > max_level) max_level = l;
        if (level_mod.isRtl(l) and l < min_odd) min_odd = l;
    }
    return .{
        .max_level = max_level,
        .min_odd = min_odd,
    };
}

fn buildVisualRunsFromVToL(
    allocator: Allocator,
    runs: *std.ArrayList(types.VisualRun),
    v_to_l: []const u32,
    levels: []const BidiLevel,
) !void {
    const len: u32 = @intCast(v_to_l.len);
    try runs.ensureTotalCapacity(allocator, len);

    var visual_idx: u32 = 0;
    while (visual_idx < len) {
        const visual_start = visual_idx;
        const first_logical = v_to_l[visual_idx];
        const rtl = level_mod.isRtl(levels[first_logical]);
        const step: i64 = if (rtl) -1 else 1;
        var prev_logical: i64 = @intCast(first_logical);

        visual_idx += 1;
        while (visual_idx < len) : (visual_idx += 1) {
            const logical = v_to_l[visual_idx];
            if (level_mod.isRtl(levels[logical]) != rtl) break;

            const logical_i64: i64 = @intCast(logical);
            if (logical_i64 != prev_logical + step) break;
            prev_logical = logical_i64;
        }

        const run_len = visual_idx - visual_start;
        const logical_start = if (rtl) v_to_l[visual_idx - 1] else first_logical;
        try runs.append(allocator, .{
            .visual_start = visual_start,
            .logical_start = logical_start,
            .len = run_len,
            .is_rtl = rtl,
        });
    }
}

fn applyL2(
    map: anytype,
    levels: []const BidiLevel,
    len: u32,
    min_odd_level: BidiLevel,
    max_level: BidiLevel,
) void {
    const T = std.meta.Elem(@TypeOf(map));
    if (min_odd_level > max_level) return;

    var lev: BidiLevel = max_level;
    while (lev >= min_odd_level) : (lev -= 1) {
        var i: u32 = 0;
        while (i < len) {
            if (levels[i] >= lev) {
                var end = i + 1;
                while (end < len and levels[end] >= lev) end += 1;
                reverseSlice(T, map[i..end]);
                i = end;
            } else {
                i += 1;
            }
        }
        if (lev == 0) break;
    }
}

fn applyL2Visual(
    visual: []u21,
    levels: []const BidiLevel,
    len: u32,
    min_odd_level: BidiLevel,
    max_level: BidiLevel,
) void {
    var lev: BidiLevel = max_level;
    while (lev >= min_odd_level) : (lev -= 1) {
        var i: u32 = 0;
        while (i < len) {
            if (levels[i] >= lev) {
                var end = i + 1;
                while (end < len and levels[end] >= lev) end += 1;
                reverseSlice(u21, visual[i..end]);
                i = end;
            } else {
                i += 1;
            }
        }
        if (lev == 0) break;
    }
}

fn reverseSlice(comptime T: type, slice: []T) void {
    std.mem.reverse(T, slice);
}

fn reorderLineEmptyAllocProbe(allocator: Allocator) !void {
    const cps = [_]u21{};
    const levels = [_]BidiLevel{};
    var result = try reorderLine(allocator, &cps, &levels, 0);
    defer result.deinit(allocator);
}

const CountingAllocator = struct {
    parent: Allocator,
    alloc_count: usize = 0,

    fn init(parent: Allocator) CountingAllocator {
        return .{ .parent = parent };
    }

    fn allocator(self: *CountingAllocator) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.parent.rawAlloc(len, alignment, ret_addr);
        if (ptr != null) self.alloc_count += 1;
        return ptr;
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ok = self.parent.rawResize(buf, alignment, new_len, ret_addr);
        if (ok and new_len > buf.len) self.alloc_count += 1;
        return ok;
    }

    fn remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.parent.rawRemap(buf, alignment, new_len, ret_addr);
        if (ptr != null and new_len > buf.len) self.alloc_count += 1;
        return ptr;
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.parent.rawFree(buf, alignment, ret_addr);
    }
};

test "allocation failure safety: reorderLine empty input" {
    const testing = std.testing;
    try testing.checkAllAllocationFailures(testing.allocator, reorderLineEmptyAllocProbe, .{});
}

test "reorderLineScratch matches owned API and reuses capacity" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var counter = CountingAllocator.init(gpa);
    const alloc = counter.allocator();

    var scratch = ReorderLineScratch{};
    defer scratch.deinit(alloc);

    const cps_big = [_]u21{
        'H', 'e', 'l', 'l',    'o',    ' ', 0x0645, 0x0631, 0x062D, 0x0628, 0x0627, ' ', '1', '2', '3', ' ',
        'A', 'B', ' ', 0x05D0, 0x05D1, ' ', 'Z',    '!',
    };
    const lv_big = [_]BidiLevel{
        0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 0, 0, 0, 1, 1, 0, 0, 0,
    };
    var expected_big = try reorderLine(gpa, &cps_big, &lv_big, 0);
    defer expected_big.deinit(gpa);
    const got_big = try reorderLineScratch(alloc, &scratch, &cps_big, &lv_big, 0);
    try testing.expectEqualSlices(u21, expected_big.visual, got_big.visual);
    try testing.expectEqualSlices(u32, expected_big.l_to_v, got_big.l_to_v);
    try testing.expectEqualSlices(u32, expected_big.v_to_l, got_big.v_to_l);
    try testing.expectEqual(expected_big.max_level, got_big.max_level);

    const alloc_before_second = counter.alloc_count;

    const cps_small = [_]u21{ 'A', ' ', 0x05D0, 0x05D1, ' ', 'B' };
    const lv_small = [_]BidiLevel{ 0, 0, 1, 1, 0, 0 };
    var expected_small = try reorderLine(gpa, &cps_small, &lv_small, 0);
    defer expected_small.deinit(gpa);
    const got_small = try reorderLineScratch(alloc, &scratch, &cps_small, &lv_small, 0);

    try testing.expectEqual(@as(usize, 0), counter.alloc_count - alloc_before_second);
    try testing.expectEqualSlices(u21, expected_small.visual, got_small.visual);
    try testing.expectEqualSlices(u32, expected_small.l_to_v, got_small.l_to_v);
    try testing.expectEqualSlices(u32, expected_small.v_to_l, got_small.v_to_l);
}

test "visualRunsScratch matches owned API and reuses capacity" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var counter = CountingAllocator.init(gpa);
    const alloc = counter.allocator();

    var scratch = VisualRunsScratch{};
    defer scratch.deinit(alloc);

    const lv_big = [_]BidiLevel{ 0, 0, 1, 1, 2, 2, 1, 1, 0, 0, 1, 1, 0 };
    const expected_big = try visualRuns(gpa, &lv_big, 0);
    defer gpa.free(expected_big);
    const got_big = try visualRunsScratch(alloc, &scratch, &lv_big, 0);
    try testing.expectEqualSlices(types.VisualRun, expected_big, got_big);

    const alloc_before_second = counter.alloc_count;

    const lv_small = [_]BidiLevel{ 1, 1, 2, 2, 1, 1 };
    const expected_small = try visualRuns(gpa, &lv_small, 1);
    defer gpa.free(expected_small);
    const got_small = try visualRunsScratch(alloc, &scratch, &lv_small, 1);

    try testing.expectEqual(@as(usize, 0), counter.alloc_count - alloc_before_second);
    try testing.expectEqualSlices(types.VisualRun, expected_small, got_small);
}

test "logToVisScratch matches owned API and reuses capacity" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var counter = CountingAllocator.init(gpa);
    const alloc = counter.allocator();

    var scratch = LogToVisScratch{};
    defer scratch.deinit(alloc);

    const lv_big = [_]BidiLevel{ 0, 0, 1, 1, 2, 2, 1, 1, 0, 0 };
    const expected_big = try logToVisMap(gpa, &lv_big, 0);
    defer gpa.free(expected_big);
    const got_big = try logToVisScratch(alloc, &scratch, &lv_big, 0);
    try testing.expectEqualSlices(u32, expected_big, got_big);

    const alloc_before_second = counter.alloc_count;

    const lv_small = [_]BidiLevel{ 1, 1, 0, 0 };
    const expected_small = try logToVisMap(gpa, &lv_small, 0);
    defer gpa.free(expected_small);
    const got_small = try logToVisScratch(alloc, &scratch, &lv_small, 0);

    try testing.expectEqual(@as(usize, 0), counter.alloc_count - alloc_before_second);
    try testing.expectEqualSlices(u32, expected_small, got_small);
}

test "reorder pure LTR" {
    const testing = std.testing;
    const gpa = testing.allocator;

    const cps = [_]u21{ 'H', 'e', 'l', 'l', 'o' };
    const levels = [_]BidiLevel{ 0, 0, 0, 0, 0 };
    var result = try reorderLine(gpa, &cps, &levels, 0);
    defer result.deinit(gpa);

    try testing.expectEqualSlices(u21, &cps, result.visual);
}

test "reorder pure RTL" {
    const testing = std.testing;
    const gpa = testing.allocator;

    const cps = [_]u21{ 0x05D0, 0x05D1, 0x05D2 };
    const levels = [_]BidiLevel{ 1, 1, 1 };
    var result = try reorderLine(gpa, &cps, &levels, 1);
    defer result.deinit(gpa);

    // RTL should reverse
    try testing.expectEqual(@as(u21, 0x05D2), result.visual[0]);
    try testing.expectEqual(@as(u21, 0x05D1), result.visual[1]);
    try testing.expectEqual(@as(u21, 0x05D0), result.visual[2]);
}

test "reorder mixed LTR-RTL" {
    const testing = std.testing;
    const gpa = testing.allocator;

    // "Hello אבג"
    const cps = [_]u21{ 'H', 'e', 'l', 'l', 'o', ' ', 0x05D0, 0x05D1, 0x05D2 };
    const levels = [_]BidiLevel{ 0, 0, 0, 0, 0, 0, 1, 1, 1 };
    var result = try reorderLine(gpa, &cps, &levels, 0);
    defer result.deinit(gpa);

    // LTR part stays, RTL part reverses
    try testing.expectEqual(@as(u21, 'H'), result.visual[0]);
    try testing.expectEqual(@as(u21, 'o'), result.visual[4]);
    try testing.expectEqual(@as(u21, 0x05D2), result.visual[6]);
    try testing.expectEqual(@as(u21, 0x05D0), result.visual[8]);
}

test "reorder visual only" {
    const testing = std.testing;
    const gpa = testing.allocator;

    const cps = [_]u21{ 'H', 'i', ' ', 0x05D0, 0x05D1 };
    const levels = [_]BidiLevel{ 0, 0, 0, 1, 1 };
    const visual = try reorderVisualOnly(gpa, &cps, &levels, 0);
    defer gpa.free(visual);

    try testing.expectEqual(@as(u21, 'H'), visual[0]);
    try testing.expectEqual(@as(u21, 0x05D1), visual[3]);
    try testing.expectEqual(@as(u21, 0x05D0), visual[4]);
}

test "reorder visual only scratch reuse" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var counter = CountingAllocator.init(gpa);
    const alloc = counter.allocator();

    var scratch = ReorderScratch{};
    defer scratch.deinit(alloc);

    const cps1 = [_]u21{ 'A', ' ', 0x05D0, 0x05D1 };
    const lv1 = [_]BidiLevel{ 0, 0, 1, 1 };
    const vis1 = try reorderVisualOnlyScratch(alloc, &scratch, &cps1, &lv1, 0);
    try testing.expectEqual(@as(u21, 0x05D1), vis1[2]);
    try testing.expectEqual(@as(u21, 0x05D0), vis1[3]);

    const alloc_before_second = counter.alloc_count;

    const cps2 = [_]u21{ 'X', 'Y', 'Z' };
    const lv2 = [_]BidiLevel{ 0, 0, 0 };
    const vis2 = try reorderVisualOnlyScratch(alloc, &scratch, &cps2, &lv2, 0);
    try testing.expectEqual(@as(usize, 0), counter.alloc_count - alloc_before_second);
    try testing.expectEqualSlices(u21, &cps2, vis2);
}

test "visual runs pure LTR" {
    const testing = std.testing;
    const gpa = testing.allocator;

    const levels = [_]BidiLevel{ 0, 0, 0, 0 };
    const runs = try visualRuns(gpa, &levels, 0);
    defer gpa.free(runs);

    try testing.expectEqual(@as(usize, 1), runs.len);
    try testing.expectEqual(@as(u32, 0), runs[0].visual_start);
    try testing.expectEqual(@as(u32, 0), runs[0].logical_start);
    try testing.expectEqual(@as(u32, 4), runs[0].len);
    try testing.expect(!runs[0].is_rtl);
}

test "visual runs split embedded LTR digits inside RTL" {
    const testing = std.testing;
    const gpa = testing.allocator;

    // RTL letters, then LTR digits (level 2), then RTL letters.
    const levels = [_]BidiLevel{ 1, 1, 2, 2, 1, 1 };
    const runs = try visualRuns(gpa, &levels, 1);
    defer gpa.free(runs);

    try testing.expectEqual(@as(usize, 3), runs.len);

    try testing.expectEqual(@as(u32, 0), runs[0].visual_start);
    try testing.expectEqual(@as(u32, 4), runs[0].logical_start);
    try testing.expectEqual(@as(u32, 2), runs[0].len);
    try testing.expect(runs[0].is_rtl);

    try testing.expectEqual(@as(u32, 2), runs[1].visual_start);
    try testing.expectEqual(@as(u32, 2), runs[1].logical_start);
    try testing.expectEqual(@as(u32, 2), runs[1].len);
    try testing.expect(!runs[1].is_rtl);

    try testing.expectEqual(@as(u32, 4), runs[2].visual_start);
    try testing.expectEqual(@as(u32, 0), runs[2].logical_start);
    try testing.expectEqual(@as(u32, 2), runs[2].len);
    try testing.expect(runs[2].is_rtl);
}

test "visual runs reconstruct reorder v_to_l map" {
    const testing = std.testing;
    const gpa = testing.allocator;

    const cps = [_]u21{ 'a', 'b', 0x05D0, 0x05D1, '5', '4', 'c', 0x05D2 };
    const levels = [_]BidiLevel{ 0, 0, 1, 1, 2, 2, 0, 1 };

    var reordered = try reorderLine(gpa, &cps, &levels, 0);
    defer reordered.deinit(gpa);

    const runs = try visualRuns(gpa, &levels, 0);
    defer gpa.free(runs);

    var rebuilt = std.ArrayList(u32).empty;
    defer rebuilt.deinit(gpa);
    try rebuilt.ensureTotalCapacity(gpa, reordered.v_to_l.len);

    for (runs) |run| {
        if (run.is_rtl) {
            var i = run.len;
            while (i > 0) {
                i -= 1;
                try rebuilt.append(gpa, run.logical_start + i);
            }
        } else {
            for (0..run.len) |i| {
                try rebuilt.append(gpa, run.logical_start + @as(u32, @intCast(i)));
            }
        }
    }

    try testing.expectEqualSlices(u32, reordered.v_to_l, rebuilt.items);
}

test "remove bidi marks" {
    const testing = std.testing;
    const gpa = testing.allocator;

    const cps = [_]u21{ 'A', 0x200E, 'B', 0x200F, 'C' };
    const result = try removeBidiMarks(gpa, &cps, null);
    defer gpa.free(result.result);

    try testing.expectEqual(@as(u32, 3), result.new_len);
    try testing.expectEqual(@as(u21, 'A'), result.result[0]);
    try testing.expectEqual(@as(u21, 'B'), result.result[1]);
    try testing.expectEqual(@as(u21, 'C'), result.result[2]);
}
