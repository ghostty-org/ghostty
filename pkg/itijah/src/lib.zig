//! itijah (اتجاه) — Zig-native Unicode Bidirectional Algorithm (UAX #9)
//!
//! Codepoint-based API inspired by FriBidi's design, implemented idiomatically in Zig.

const std = @import("std");
const Allocator = std.mem.Allocator;

// Core modules
pub const level = @import("core/level.zig");
pub const types = @import("core/types.zig");
pub const embedding = @import("core/embedding.zig");
pub const reorder = @import("core/reorder.zig");

// Data modules
pub const unicode = @import("data/unicode.zig");
pub const mirroring = @import("data/mirroring.zig");

// Shaping modules (Phase 2 stubs)
pub const joining = @import("shaping/joining.zig");
pub const shaping = @import("shaping/shaping.zig");

// Re-export primary types
pub const BidiLevel = level.BidiLevel;
pub const ParDirection = types.ParDirection;
pub const EmbeddingResult = types.EmbeddingResult;
pub const EmbeddingScratchView = types.EmbeddingScratchView;
pub const ReorderResult = types.ReorderResult;
pub const ReorderResultScratchView = types.ReorderResultScratchView;
pub const VisualRun = types.VisualRun;
pub const LogicalRange = types.LogicalRange;
pub const VisualLayout = types.VisualLayout;
pub const VisualLayoutScratchView = types.VisualLayoutScratchView;
pub const LayoutOptions = types.LayoutOptions;
pub const EmbeddingScratch = embedding.EmbeddingScratch;
pub const ReorderScratch = reorder.ReorderScratch;
pub const ReorderLineScratch = reorder.ReorderLineScratch;
pub const VisualRunsScratch = reorder.VisualRunsScratch;
pub const LogToVisScratch = reorder.LogToVisScratch;
pub const ReorderFlags = types.ReorderFlags;
pub const ShapeFlags = types.ShapeFlags;
pub const BidiClass = unicode.BidiClass;

pub const VisualLayoutScratch = struct {
    embedding: EmbeddingScratch = .{},
    log_to_vis: LogToVisScratch = .{},
    visual_runs: VisualRunsScratch = .{},
    levels: std.ArrayList(BidiLevel) = .empty,
    v_to_l: std.ArrayList(u32) = .empty,

    pub fn deinit(self: *VisualLayoutScratch, allocator: Allocator) void {
        self.embedding.deinit(allocator);
        self.log_to_vis.deinit(allocator);
        self.visual_runs.deinit(allocator);
        self.levels.deinit(allocator);
        self.v_to_l.deinit(allocator);
    }
};

/// Get paragraph embedding levels for a sequence of codepoints.
/// Implements UAX #9 Rules P2-P3, X1-X8, W1-W7, N0-N2, I1-I2, L1.
///
/// `par_dir` is input/output: if auto_ltr or auto_rtl, the resolved direction
/// is written back after paragraph direction detection (P2-P3).
pub fn getParEmbeddingLevels(
    allocator: Allocator,
    codepoints: []const u21,
    par_dir: *ParDirection,
) !EmbeddingResult {
    return embedding.getParEmbeddingLevels(allocator, codepoints, par_dir);
}

/// Get paragraph embedding levels for a sequence of codepoints with reusable scratch buffers.
///
/// Returned levels are scratch-owned and remain valid until the next call that mutates
/// the same scratch object.
pub fn getParEmbeddingLevelsScratchView(
    allocator: Allocator,
    scratch: *EmbeddingScratch,
    codepoints: []const u21,
    par_dir: *ParDirection,
) !EmbeddingScratchView {
    return embedding.getParEmbeddingLevelsScratchView(allocator, scratch, codepoints, par_dir);
}

/// Return true if `codepoints` contains a strong RTL bidi class (`R` or `AL`).
///
/// This is a cheap preflight helper for callers that want to skip full bidi
/// processing on rows with no RTL text. It does not classify explicit controls,
/// isolates, or Arabic numbers as strong RTL.
pub fn hasStrongRtl(codepoints: []const u21) bool {
    return embedding.hasStrongRtl(codepoints);
}

/// Reorder a line of codepoints from logical to visual order.
/// Implements Rules L1.4, L2. Returns visual string and index maps.
///
/// L3 (NSM reordering) and L4 (mirroring) are deferred to Phase 2.
pub fn reorderLine(
    allocator: Allocator,
    codepoints: []const u21,
    levels: []const BidiLevel,
    base_level: BidiLevel,
) !ReorderResult {
    return reorder.reorderLine(allocator, codepoints, levels, base_level);
}

/// Reorder a line with reusable scratch buffers.
///
/// Returned slices are owned by `scratch` and remain valid until the next call that
/// mutates the same scratch object.
pub fn reorderLineScratch(
    allocator: Allocator,
    scratch: *ReorderLineScratch,
    codepoints: []const u21,
    levels: []const BidiLevel,
    base_level: BidiLevel,
) !ReorderResultScratchView {
    return reorder.reorderLineScratch(allocator, scratch, codepoints, levels, base_level);
}

/// Reorder a line and return only visual codepoints.
pub fn reorderVisualOnly(
    allocator: Allocator,
    codepoints: []const u21,
    levels: []const BidiLevel,
    base_level: BidiLevel,
) ![]u21 {
    return reorder.reorderVisualOnly(allocator, codepoints, levels, base_level);
}

/// Reorder a line and return only visual codepoints with reusable scratch buffers.
///
/// Returned slice is scratch-owned and remains valid until the next call that mutates
/// the same scratch object.
pub fn reorderVisualOnlyScratch(
    allocator: Allocator,
    scratch: *ReorderScratch,
    codepoints: []const u21,
    levels: []const BidiLevel,
    base_level: BidiLevel,
) ![]const u21 {
    return reorder.reorderVisualOnlyScratch(allocator, scratch, codepoints, levels, base_level);
}

/// Build a logical-to-visual index map from embedding levels.
pub fn logToVis(
    allocator: Allocator,
    levels: []const BidiLevel,
    base_level: BidiLevel,
) ![]u32 {
    return reorder.logToVisMap(allocator, levels, base_level);
}

/// Build a logical-to-visual index map with reusable scratch buffers.
///
/// Returned slice is owned by `scratch` and remains valid until the next call that
/// mutates the same scratch object.
pub fn logToVisScratch(
    allocator: Allocator,
    scratch: *LogToVisScratch,
    levels: []const BidiLevel,
    base_level: BidiLevel,
) ![]u32 {
    return reorder.logToVisScratch(allocator, scratch, levels, base_level);
}

/// Derive visual runs in visual order from embedding levels.
pub fn getVisualRuns(
    allocator: Allocator,
    levels: []const BidiLevel,
    base_level: BidiLevel,
) ![]VisualRun {
    return reorder.visualRuns(allocator, levels, base_level);
}

/// Derive visual runs with reusable scratch buffers.
///
/// Returned slice is owned by `scratch` and remains valid until the next call that
/// mutates the same scratch object.
pub fn getVisualRunsScratch(
    allocator: Allocator,
    scratch: *VisualRunsScratch,
    levels: []const BidiLevel,
    base_level: BidiLevel,
) ![]VisualRun {
    return reorder.visualRunsScratch(allocator, scratch, levels, base_level);
}

/// Resolve terminal-oriented visual layout for a single line.
///
/// This composes embedding-level resolution + visual runs + index maps.
/// Rows are line-scoped; no paragraph alignment behavior is applied.
pub fn resolveVisualLayout(
    allocator: Allocator,
    codepoints: []const u21,
    opts: LayoutOptions,
) !VisualLayout {
    var dir = opts.base_dir;
    var emb = try getParEmbeddingLevels(allocator, codepoints, &dir);
    errdefer emb.deinit(allocator);

    const base_level = dir.toLevel();
    const l_to_v = try logToVis(allocator, emb.levels, base_level);
    errdefer allocator.free(l_to_v);

    const v_to_l = try allocator.alloc(u32, l_to_v.len);
    errdefer allocator.free(v_to_l);
    for (l_to_v, 0..) |visual_idx, logical_idx| {
        v_to_l[visual_idx] = @intCast(logical_idx);
    }

    const runs = try getVisualRuns(allocator, emb.levels, base_level);
    errdefer allocator.free(runs);

    return .{
        .levels = emb.levels,
        .runs = runs,
        .l_to_v = l_to_v,
        .v_to_l = v_to_l,
        .base_level = base_level,
    };
}

/// Resolve terminal-oriented visual layout with reusable scratch buffers.
///
/// Returned slices are scratch-owned and remain valid until the next call that
/// mutates the same scratch object.
pub fn resolveVisualLayoutScratch(
    allocator: Allocator,
    scratch: *VisualLayoutScratch,
    codepoints: []const u21,
    opts: LayoutOptions,
) !VisualLayoutScratchView {
    var dir = opts.base_dir;
    const emb = try getParEmbeddingLevelsScratchView(allocator, &scratch.embedding, codepoints, &dir);

    const base_level = dir.toLevel();
    const l_to_v = try logToVisScratch(
        allocator,
        &scratch.log_to_vis,
        emb.levels,
        base_level,
    );
    try scratch.v_to_l.ensureTotalCapacity(allocator, l_to_v.len);
    scratch.v_to_l.items.len = l_to_v.len;
    const v_to_l = scratch.v_to_l.items;
    for (l_to_v, 0..) |visual_idx, logical_idx| {
        v_to_l[visual_idx] = @intCast(logical_idx);
    }

    const runs = try getVisualRunsScratch(allocator, &scratch.visual_runs, emb.levels, base_level);

    return .{
        .levels = emb.levels,
        .runs = runs,
        .l_to_v = l_to_v,
        .v_to_l = v_to_l,
        .base_level = base_level,
    };
}

pub fn logicalIndexForVisual(run: VisualRun, visual_index: u32) u32 {
    return types.logicalIndexForVisual(run, visual_index);
}

pub fn visualIndexForLogical(run: VisualRun, logical_index: u32) u32 {
    return types.visualIndexForLogical(run, logical_index);
}

pub fn logicalRangeForVisualSlice(
    run: VisualRun,
    visual_start: u32,
    visual_end: u32,
) LogicalRange {
    return types.logicalRangeForVisualSlice(run, visual_start, visual_end);
}

pub fn clusterForLogical(run: VisualRun, logical_index: u32) u32 {
    return types.clusterForLogical(run, logical_index);
}

/// Remove bidi control marks (LRM, RLM, ALM, LRE, RLE, PDF, LRO, RLO, LRI, RLI, FSI, PDI)
/// from a codepoint array.
///
/// If `levels` is provided, it is compacted in-place to match the filtered output order.
pub const RemoveBidiMarksResult = types.RemoveBidiMarksResult;

pub fn removeBidiMarks(
    allocator: Allocator,
    codepoints: []const u21,
    levels: ?[]BidiLevel,
) !RemoveBidiMarksResult {
    return reorder.removeBidiMarks(allocator, codepoints, levels);
}

/// Apply Arabic joining algorithm (Rules R1-R7).
/// Phase 2 stub — returns error.NotImplemented.
pub fn joinArabic(
    bidi_types: []const BidiClass,
    embedding_levels: []const BidiLevel,
    ar_props: []joining.ArabicProp,
) !void {
    return joining.joinArabic(bidi_types, embedding_levels, ar_props);
}

/// Apply shaping: mirroring (L4) and Arabic presentation forms.
/// Phase 2 stub — returns error.NotImplemented.
pub fn shape(
    codepoints: []u21,
    embedding_levels: []const BidiLevel,
    arabic_props: ?[]const joining.ArabicProp,
    flags: ShapeFlags,
) !void {
    return shaping.shape(codepoints, embedding_levels, arabic_props, flags);
}

// Tests
test {
    _ = level;
    _ = types;
    _ = embedding;
    _ = reorder;
    _ = unicode;
    _ = mirroring;
    _ = @import("test/conformance.zig");
    _ = @import("test/parity.zig");
    _ = @import("test/invariants.zig");
    _ = @import("test/layout.zig");
}

test "end-to-end: pure LTR" {
    const gpa = std.testing.allocator;
    var dir: ParDirection = .auto_ltr;
    const input = [_]u21{ 'H', 'e', 'l', 'l', 'o' };

    var emb = try getParEmbeddingLevels(gpa, &input, &dir);
    defer emb.deinit(gpa);

    try std.testing.expectEqual(ParDirection.ltr, emb.resolved_par_dir);

    var vis = try reorderLine(gpa, &input, emb.levels, 0);
    defer vis.deinit(gpa);

    try std.testing.expectEqualSlices(u21, &input, vis.visual);
}

test "end-to-end: pure RTL" {
    const gpa = std.testing.allocator;
    var dir: ParDirection = .auto_ltr;
    const input = [_]u21{ 0x05D0, 0x05D1, 0x05D2 };

    var emb = try getParEmbeddingLevels(gpa, &input, &dir);
    defer emb.deinit(gpa);

    try std.testing.expectEqual(ParDirection.rtl, emb.resolved_par_dir);

    var vis = try reorderLine(gpa, &input, emb.levels, 1);
    defer vis.deinit(gpa);

    try std.testing.expectEqual(@as(u21, 0x05D2), vis.visual[0]);
    try std.testing.expectEqual(@as(u21, 0x05D0), vis.visual[2]);
}

test "end-to-end: mixed LTR + RTL" {
    const gpa = std.testing.allocator;
    var dir: ParDirection = .auto_ltr;
    // "AB אב CD"
    const input = [_]u21{ 'A', 'B', ' ', 0x05D0, 0x05D1, ' ', 'C', 'D' };

    var emb = try getParEmbeddingLevels(gpa, &input, &dir);
    defer emb.deinit(gpa);

    try std.testing.expectEqual(ParDirection.ltr, emb.resolved_par_dir);
    try std.testing.expectEqual(@as(BidiLevel, 0), emb.levels[0]); // A
    try std.testing.expectEqual(@as(BidiLevel, 1), emb.levels[3]); // Alef
    try std.testing.expectEqual(@as(BidiLevel, 1), emb.levels[4]); // Bet
    try std.testing.expectEqual(@as(BidiLevel, 0), emb.levels[6]); // C

    var vis = try reorderLine(gpa, &input, emb.levels, 0);
    defer vis.deinit(gpa);

    // "AB " stays, "אב" reverses to "בא", " CD" stays
    try std.testing.expectEqual(@as(u21, 'A'), vis.visual[0]);
    try std.testing.expectEqual(@as(u21, 'B'), vis.visual[1]);
    try std.testing.expectEqual(@as(u21, 0x05D1), vis.visual[3]);
    try std.testing.expectEqual(@as(u21, 0x05D0), vis.visual[4]);
    try std.testing.expectEqual(@as(u21, 'D'), vis.visual[7]);
}

test "end-to-end: LTR with trailing digits after RTL word" {
    const gpa = std.testing.allocator;
    var dir: ParDirection = .auto_ltr;
    // "hello, مرحبا 123"
    const input = [_]u21{
        'h',    'e',    'l',    'l',    'o',    ',', ' ',
        0x0645, 0x0631, 0x062D, 0x0628, 0x0627, ' ', '1',
        '2',    '3',
    };

    var emb = try getParEmbeddingLevels(gpa, &input, &dir);
    defer emb.deinit(gpa);

    try std.testing.expectEqual(ParDirection.ltr, emb.resolved_par_dir);

    var vis = try reorderLine(gpa, &input, emb.levels, dir.toLevel());
    defer vis.deinit(gpa);

    // Visual order should place digits to the left of the RTL word in an LTR paragraph.
    // Expected: "hello, 123 ابحرم"
    const expected = [_]u21{
        'h',    'e',    'l', 'l', 'o',    ',',    ' ',
        '1',    '2',    '3', ' ', 0x0627, 0x0628, 0x062D,
        0x0631, 0x0645,
    };
    try std.testing.expectEqualSlices(u21, &expected, vis.visual);
}

test "end-to-end: RTL letter space digits reorder visually" {
    const gpa = std.testing.allocator;
    var dir: ParDirection = .auto_ltr;
    // ['م', ' ', '5', '3'] should display as ['5', '3', ' ', 'م'].
    const input = [_]u21{ 0x0645, ' ', '5', '3' };

    var emb = try getParEmbeddingLevels(gpa, &input, &dir);
    defer emb.deinit(gpa);

    try std.testing.expectEqual(ParDirection.rtl, emb.resolved_par_dir);

    var vis = try reorderLine(gpa, &input, emb.levels, dir.toLevel());
    defer vis.deinit(gpa);

    const expected = [_]u21{ '5', '3', ' ', 0x0645 };
    try std.testing.expectEqualSlices(u21, &expected, vis.visual);
}

test "end-to-end: RTL letters around digits keep number run order" {
    const gpa = std.testing.allocator;
    var dir: ParDirection = .auto_ltr;
    // ['م', ' ', '5', '3', ' ', 'م']
    const input = [_]u21{ 0x0645, ' ', '5', '3', ' ', 0x0645 };

    var emb = try getParEmbeddingLevels(gpa, &input, &dir);
    defer emb.deinit(gpa);

    try std.testing.expectEqual(ParDirection.rtl, emb.resolved_par_dir);

    var vis = try reorderLine(gpa, &input, emb.levels, dir.toLevel());
    defer vis.deinit(gpa);

    const expected = [_]u21{ 0x0645, ' ', '5', '3', ' ', 0x0645 };
    try std.testing.expectEqualSlices(u21, &expected, vis.visual);
}

test "removeBidiMarks" {
    const gpa = std.testing.allocator;
    const input = [_]u21{ 'A', 0x200E, 'B', 0x202A, 'C' };
    const result = try removeBidiMarks(gpa, &input, null);
    defer gpa.free(result.result);

    try std.testing.expectEqual(@as(u32, 3), result.new_len);
    try std.testing.expectEqual(@as(u21, 'A'), result.result[0]);
    try std.testing.expectEqual(@as(u21, 'B'), result.result[1]);
    try std.testing.expectEqual(@as(u21, 'C'), result.result[2]);
}

test "stubs return NotImplemented" {
    var props = [_]joining.ArabicProp{0};
    try std.testing.expectError(error.NotImplemented, joinArabic(&.{}, &.{}, &props));

    var cps = [_]u21{'A'};
    try std.testing.expectError(error.NotImplemented, shape(&cps, &.{}, null, .{}));
}
