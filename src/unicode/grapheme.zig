const std = @import("std");
const table = @import("props_table.zig").table;
const uucode = @import("uucode");

/// Width change requested by a codepoint that continues a grapheme cluster.
pub const GraphemeWidthEffect = enum {
    /// Do not append the codepoint to the cluster and leave break state as it
    /// was before seeing it.
    ignore,

    /// Append the codepoint but leave the current cluster width unchanged.
    no_change,

    /// Make the cluster occupy two terminal cells.
    wide,

    /// Make the cluster occupy one terminal cell.
    narrow,
};

/// Result of measuring the first grapheme cluster in a codepoint slice.
pub const GraphemeWidth = struct {
    /// Number of codepoints consumed from the input slice.
    len: usize,

    /// Display width in terminal cells.
    width: u2,
};

/// Determines if there is a grapheme break between two codepoints. This
/// must be called sequentially maintaining the state between calls.
///
/// This function does NOT work with control characters. Control characters,
/// line feeds, and carriage returns are expected to be filtered out before
/// calling this function. This is because this function is tuned for
/// Ghostty.
pub fn graphemeBreak(cp1: u21, cp2: u21, state: *uucode.grapheme.BreakState) bool {
    const value = Precompute.data[
        (Precompute.Key{
            .gb1 = table.get(cp1).grapheme_break,
            .gb2 = table.get(cp2).grapheme_break,
            .state = state.*,
        }).index()
    ];
    state.* = value.state;
    return value.result;
}

/// Returns the width effect of appending cp after prev within a grapheme.
///
/// This is the shared width-decision kernel for the streaming terminal
/// printer and for graphemeWidth. It assumes graphemeBreak has already said
/// there is no break between prev and cp; it does not perform segmentation.
///
/// The .ignore result is important for invalid emoji variation selectors. The
/// terminal does not store those selectors in the cell, so callers must also
/// restore their grapheme break state and leave prev unchanged when they see
/// .ignore.
pub inline fn graphemeWidthEffect(prev: u21, cp: u21) GraphemeWidthEffect {
    // Emoji variation selectors modify the width of a valid base:
    // VS16 makes the grapheme wide and VS15 makes it narrow. Check that
    // prev forms a valid variation sequence in emoji-variation-sequences.txt;
    // if it does not, ignore the selector entirely.
    if (cp == 0xFE0F or cp == 0xFE0E) {
        const prev_props = table.get(prev);
        if (!prev_props.emoji_vs_base) return .ignore;

        return switch (cp) {
            0xFE0F => .wide,
            0xFE0E => .narrow,
            else => unreachable,
        };
    }

    // If a code point contributes to the width of a grapheme, the whole
    // grapheme is at least width 2 because the first code point must be at
    // least width 1 to start. Prepend code points could effectively mean
    // the first code point should be width 0, but we don't handle that yet.
    if (!table.get(cp).width_zero_in_grapheme) return .wide;

    return .no_change;
}

/// Measures the first grapheme cluster in cps using the same segmentation and
/// width rules as Terminal.print with mode 2027.
///
/// This is not a streaming API: cps must contain a complete first grapheme
/// cluster or the logical end of the string. If bytes/codepoints arrive in
/// chunks, keep buffering when this consumes all available codepoints and more
/// input may still arrive.
///
/// For codepoint types wider than u21, values greater than U+10FFFF are
/// accepted so FFI-facing callers can use u32 input without trapping. An
/// invalid value consumes one codepoint at width 1 when it starts the slice,
/// and terminates the current cluster when it appears later. For u21 callers
/// these checks are comptime-dead.
pub fn graphemeWidth(comptime T: type, cps: []const T) GraphemeWidth {
    const check_invalid = comptime @bitSizeOf(T) > @bitSizeOf(u21);

    if (cps.len == 0) return .{ .len = 0, .width = 0 };

    // The C API accepts u32 codepoints, so it can receive values outside
    // Unicode's range. Guard before narrowing to u21; native u21 callers
    // skip this path at comptime.
    if (check_invalid and invalidCodepoint(cps[0])) return .{ .len = 1, .width = 1 };

    var len: usize = 1;
    var width = table.get(@as(u21, @intCast(cps[0]))).width;
    var prev: u21 = @intCast(cps[0]);
    var state: uucode.grapheme.BreakState = .default;

    while (len < cps.len) : (len += 1) {
        // Treat invalid u32 input as a boundary so a valid prefix cluster can
        // still be returned without attempting to narrow the invalid value.
        if (check_invalid and invalidCodepoint(cps[len])) break;

        const cp: u21 = @intCast(cps[len]);
        const state_before = state;
        if (graphemeBreak(prev, cp, &state)) break;

        switch (graphemeWidthEffect(prev, cp)) {
            .ignore => state = state_before,
            .no_change => prev = cp,
            .wide => {
                width = 2;
                prev = cp;
            },
            .narrow => {
                width = 1;
                prev = cp;
            },
        }
    }

    return .{ .len = len, .width = width };
}

inline fn invalidCodepoint(cp: anytype) bool {
    return cp > 0x10FFFF;
}

/// This is all the structures and data for the precomputed lookup table
/// for all possible permutations of state and grapheme break properties.
/// Precomputation requires 2^13 keys of 4 bit values so the whole table is
/// 8KB.
const Precompute = struct {
    const Key = packed struct(u13) {
        state: uucode.grapheme.BreakState,
        gb1: uucode.x.types.GraphemeBreakNoControl,
        gb2: uucode.x.types.GraphemeBreakNoControl,

        fn index(self: Key) usize {
            return @intCast(@as(u13, @bitCast(self)));
        }
    };

    const Value = packed struct(u4) {
        result: bool,
        state: uucode.grapheme.BreakState,
    };

    const data = precompute: {
        var result: [std.math.maxInt(u13) + 1]Value = undefined;

        const max_state_int = blk: {
            var max: usize = 0;
            for (@typeInfo(uucode.grapheme.BreakState).@"enum".fields) |field| {
                if (field.value > max) max = field.value;
            }
            break :blk max;
        };

        @setEvalBranchQuota(10_000);
        const info = @typeInfo(uucode.x.types.GraphemeBreakNoControl).@"enum";
        for (0..max_state_int + 1) |state_int| {
            for (info.fields) |field1| {
                for (info.fields) |field2| {
                    var state: uucode.grapheme.BreakState = @enumFromInt(state_int);

                    const key: Key = .{
                        .gb1 = @field(uucode.x.types.GraphemeBreakNoControl, field1.name),
                        .gb2 = @field(uucode.x.types.GraphemeBreakNoControl, field2.name),
                        .state = state,
                    };
                    const v = uucode.x.grapheme.computeGraphemeBreakNoControl(
                        key.gb1,
                        key.gb2,
                        &state,
                    );
                    result[key.index()] = .{ .result = v, .state = state };
                }
            }
        }

        std.debug.assert(@sizeOf(@TypeOf(result)) == 8192);
        break :precompute result;
    };
};

/// If you build this file as a binary, we will verify the grapheme break
/// implementation. This iterates over billions of codepoints so it is
/// SLOW. It's not meant to be run in CI, but it's useful for debugging.
/// TODO: this is hard to build with newer zig build, so
/// https://github.com/ghostty-org/ghostty/pull/7806 took the approach of
/// adding a `-Demit-unicode-test` option for `zig build`, but that
/// hasn't been done here.
pub fn main() !void {
    // Set the min and max to control the test range.
    const min = 0;
    const max = uucode.config.max_code_point + 1;

    var state: uucode.grapheme.BreakState = .default;
    var uu_state: uucode.grapheme.BreakState = .default;
    for (min..max) |cp1| {
        if (cp1 % 1000 == 0) std.log.warn("progress cp1={}", .{cp1});

        if (cp1 == '\r' or cp1 == '\n' or
            uucode.get(.grapheme_break, @intCast(cp1)) == .control) continue;

        for (min..max) |cp2| {
            if (cp2 == '\r' or cp2 == '\n' or
                uucode.get(.grapheme_break, @intCast(cp1)) == .control) continue;

            const gb = graphemeBreak(@intCast(cp1), @intCast(cp2), &state);
            const uu_gb = uucode.grapheme.isBreak(@intCast(cp1), @intCast(cp2), &uu_state);
            if (gb != uu_gb) {
                std.log.warn("cp1={x} cp2={x} gb={} state={} uu_gb={} uu_state={}", .{
                    cp1,
                    cp2,
                    gb,
                    state,
                    uu_gb,
                    uu_state,
                });
            }
        }
    }
}

pub const std_options = struct {
    pub const log_level: std.log.Level = .info;
};

test "grapheme break: emoji modifier" {
    const testing = std.testing;

    // Emoji and modifier
    {
        var state: uucode.grapheme.BreakState = .default;
        try testing.expect(!graphemeBreak(0x261D, 0x1F3FF, &state));
    }

    // Non-emoji and emoji modifier
    {
        var state: uucode.grapheme.BreakState = .default;
        try testing.expect(graphemeBreak(0x22, 0x1F3FF, &state));
    }
}

test "long emoji zwj sequences" {
    var state: uucode.grapheme.BreakState = .default;
    // 👩‍👩‍👧‍👦 (family: woman, woman, girl, boy)
    var it = uucode.utf8.Iterator.init("\u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}_");
    var cp1 = it.next() orelse unreachable;
    var cp2 = it.next() orelse unreachable;
    try std.testing.expect(cp1 == 0x1F469); // 👩
    try std.testing.expect(!graphemeBreak(cp1, cp2, &state));

    cp1 = cp2;
    cp2 = it.next() orelse unreachable;
    try std.testing.expect(cp1 == 0x200D);
    try std.testing.expect(!graphemeBreak(cp1, cp2, &state));

    cp1 = cp2;
    cp2 = it.next() orelse unreachable;
    try std.testing.expect(cp1 == 0x1F469); // 👩
    try std.testing.expect(!graphemeBreak(cp1, cp2, &state));

    cp1 = cp2;
    cp2 = it.next() orelse unreachable;
    try std.testing.expect(cp1 == 0x200D);
    try std.testing.expect(!graphemeBreak(cp1, cp2, &state));

    cp1 = cp2;
    cp2 = it.next() orelse unreachable;
    try std.testing.expect(cp1 == 0x1F467); // 👧
    try std.testing.expect(!graphemeBreak(cp1, cp2, &state));

    cp1 = cp2;
    cp2 = it.next() orelse unreachable;
    try std.testing.expect(cp1 == 0x200D);
    try std.testing.expect(!graphemeBreak(cp1, cp2, &state));

    cp1 = cp2;
    cp2 = it.next() orelse unreachable;
    try std.testing.expect(cp1 == 0x1F466); // 👦
    try std.testing.expect(graphemeBreak(cp1, cp2, &state)); // break
}

test "grapheme width: variation selectors" {
    const testing = std.testing;

    try testing.expectEqual(GraphemeWidthEffect.wide, graphemeWidthEffect(0x2764, 0xFE0F));
    try testing.expectEqual(GraphemeWidthEffect.narrow, graphemeWidthEffect(0x23, 0xFE0E));
    try testing.expectEqual(GraphemeWidthEffect.ignore, graphemeWidthEffect('x', 0xFE0F));

    try testing.expectEqual(GraphemeWidth{ .len = 2, .width = 2 }, graphemeWidth(u21, &.{ 0x2764, 0xFE0F }));
    try testing.expectEqual(GraphemeWidth{ .len = 2, .width = 2 }, graphemeWidth(u21, &.{ 0x23, 0xFE0F }));
    try testing.expectEqual(GraphemeWidth{ .len = 2, .width = 1 }, graphemeWidth(u21, &.{ 'x', 0xFE0F }));
    try testing.expectEqual(GraphemeWidth{ .len = 3, .width = 1 }, graphemeWidth(u21, &.{ 'x', 0xFE0F, 0xFE0F }));
    try testing.expectEqual(GraphemeWidth{ .len = 2, .width = 1 }, graphemeWidth(u21, &.{ 0x23, 0xFE0E }));
    try testing.expectEqual(GraphemeWidth{ .len = 2, .width = 1 }, graphemeWidth(u21, &.{ 0x231A, 0xFE0E }));
    try testing.expectEqual(GraphemeWidth{ .len = 3, .width = 1 }, graphemeWidth(u21, &.{ 0x231A, 0xFE0E, 0xFE0F }));
    try testing.expectEqual(GraphemeWidth{ .len = 4, .width = 2 }, graphemeWidth(u21, &.{ 0x1F3F4, 0x200D, 0x2620, 0xFE0F }));
}

test "grapheme width: emoji sequences" {
    const testing = std.testing;

    try testing.expectEqual(GraphemeWidth{ .len = 5, .width = 2 }, graphemeWidth(u21, &.{ 0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F467 }));
    try testing.expectEqual(GraphemeWidth{ .len = 3, .width = 2 }, graphemeWidth(u21, &.{ 0x23, 0xFE0F, 0x20E3 }));
    try testing.expectEqual(GraphemeWidth{ .len = 2, .width = 1 }, graphemeWidth(u21, &.{ '1', 0x20E3 }));
    try testing.expectEqual(GraphemeWidth{ .len = 2, .width = 2 }, graphemeWidth(u21, &.{ 0x1F44B, 0x1F3FF }));
}

test "grapheme width: spacing marks can widen narrow clusters" {
    const testing = std.testing;

    var mark: ?u21 = null;
    for (0..0x110000) |cp_usize| {
        const cp: u21 = @intCast(cp_usize);
        const props = table.get(cp);
        if (props.width != 1 or props.width_zero_in_grapheme) continue;

        var state: uucode.grapheme.BreakState = .default;
        if (!graphemeBreak('a', cp, &state)) {
            mark = cp;
            break;
        }
    }

    try testing.expect(mark != null);
    const cp = mark.?;
    try testing.expectEqual(@as(u2, 1), table.get(cp).width);
    try testing.expect(!table.get(cp).width_zero_in_grapheme);
    try testing.expectEqual(GraphemeWidth{ .len = 2, .width = 2 }, graphemeWidth(u21, &.{ 'a', cp }));
}

test "grapheme width: segmentation" {
    const testing = std.testing;

    try testing.expectEqual(GraphemeWidth{ .len = 1, .width = 1 }, graphemeWidth(u21, &.{'a'}));
    try testing.expectEqual(GraphemeWidth{ .len = 1, .width = 1 }, graphemeWidth(u21, &.{ 'a', 'b' }));
    try testing.expectEqual(GraphemeWidth{ .len = 2, .width = 2 }, graphemeWidth(u21, &.{ 0x1F1E6, 0x1F1E7, 0x1F1E8 }));
    try testing.expectEqual(GraphemeWidth{ .len = 1, .width = 2 }, graphemeWidth(u21, &.{0x1F1E8}));
    try testing.expectEqual(GraphemeWidth{ .len = 0, .width = 0 }, graphemeWidth(u21, &.{}));
    try testing.expectEqual(GraphemeWidth{ .len = 2, .width = 0 }, graphemeWidth(u21, &.{ 0x0301, 0x0302 }));
}

test "grapheme width: u32 invalid codepoints stand alone" {
    const testing = std.testing;

    try testing.expectEqual(GraphemeWidth{ .len = 1, .width = 1 }, graphemeWidth(u32, &.{ 0x110000, 0x0301 }));
    try testing.expectEqual(GraphemeWidth{ .len = 1, .width = 1 }, graphemeWidth(u32, &.{ 'a', 0x110000 }));
}
