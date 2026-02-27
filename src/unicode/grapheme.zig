const std = @import("std");
const table = @import("props_table.zig").table;
const uucode = @import("uucode");

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
