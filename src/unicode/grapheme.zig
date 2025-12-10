const std = @import("std");
const table = @import("props_table.zig").table;
const GraphemeBoundaryClass = @import("props.zig").GraphemeBoundaryClass;

/// Determines if there is a grapheme break between two codepoints. This
/// must be called sequentially maintaining the state between calls.
///
/// This function does NOT work with control characters. Control characters,
/// line feeds, and carriage returns are expected to be filtered out before
/// calling this function. This is because this function is tuned for
/// Ghostty.
pub fn graphemeBreak(cp1: u21, cp2: u21, state: *BreakState) bool {
    const value = Precompute.data[
        (Precompute.Key{
            .gbc1 = table.get(cp1).grapheme_boundary_class,
            .gbc2 = table.get(cp2).grapheme_boundary_class,
            .state = state.*,
        }).index()
    ];
    state.* = value.state;
    return value.result;
}

/// The state that must be maintained between calls to `graphemeBreak`.
pub const BreakState = packed struct(u2) {
    extended_pictographic: bool = false,
    regional_indicator: bool = false,
};

/// This is all the structures and data for the precomputed lookup table
/// for all possible permutations of state and grapheme boundary classes.
/// Precomputation only requires 2^10 keys of 3 bit values so the whole
/// table is less than 1KB.
const Precompute = struct {
    const Key = packed struct(u10) {
        state: BreakState,
        gbc1: GraphemeBoundaryClass,
        gbc2: GraphemeBoundaryClass,

        fn index(self: Key) usize {
            return @intCast(@as(u10, @bitCast(self)));
        }
    };

    const Value = packed struct(u3) {
        result: bool,
        state: BreakState,
    };

    const data = precompute: {
        var result: [std.math.maxInt(u10)]Value = undefined;

        @setEvalBranchQuota(3_000);
        const info = @typeInfo(GraphemeBoundaryClass).@"enum";
        for (0..std.math.maxInt(u2) + 1) |state_init| {
            for (info.fields) |field1| {
                for (info.fields) |field2| {
                    var state: BreakState = @bitCast(@as(u2, @intCast(state_init)));
                    const key: Key = .{
                        .gbc1 = @field(GraphemeBoundaryClass, field1.name),
                        .gbc2 = @field(GraphemeBoundaryClass, field2.name),
                        .state = state,
                    };
                    const v = graphemeBreakClass(key.gbc1, key.gbc2, &state);
                    result[key.index()] = .{ .result = v, .state = state };
                }
            }
        }

        break :precompute result;
    };
};

/// This is the algorithm from utf8proc. We only use this offline for
/// precomputing the lookup table.
fn graphemeBreakClass(
    gbc1: GraphemeBoundaryClass,
    gbc2: GraphemeBoundaryClass,
    state: *BreakState,
) bool {
    // GB11: Emoji Extend* ZWJ x Emoji
    if (!state.extended_pictographic and gbc1.isExtendedPictographic()) {
        state.extended_pictographic = true;
    }

    // These two properties are ignored because they're not relevant to
    // Ghostty -- they're filtered out before checking grapheme boundaries.
    // GB3: CR x LF
    // GB4: Control

    // GB6: Hangul L x (L|V|LV|VT)
    if (gbc1 == .L) {
        if (gbc2 == .L or
            gbc2 == .V or
            gbc2 == .LV or
            gbc2 == .LVT) return false;
    }

    // GB7: Hangul (LV | V) x (V | T)
    if (gbc1 == .LV or gbc1 == .V) {
        if (gbc2 == .V or
            gbc2 == .T) return false;
    }

    // GB8: Hangul (LVT | T) x T
    if (gbc1 == .LVT or gbc1 == .T) {
        if (gbc2 == .T) return false;
    }

    // GB9b: x (Extend | ZWJ)
    if (gbc2 == .extend or gbc2 == .zwj) return false;

    // GB9a: x Spacing
    if (gbc2 == .spacing_mark) return false;

    // GB9b: Prepend x
    if (gbc1 == .prepend) return false;

    // GB12, GB13: RI x RI
    if (gbc1 == .regional_indicator and gbc2 == .regional_indicator) {
        if (state.regional_indicator) {
            state.regional_indicator = false;
            return true;
        } else {
            state.regional_indicator = true;
            return false;
        }
    }

    // GB11: Emoji Extend* ZWJ x Emoji
    if (state.extended_pictographic and
        gbc1 == .zwj and
        gbc2.isExtendedPictographic())
    {
        state.extended_pictographic = false;
        return false;
    }

    // UTS #51. This isn't covered by UAX #29 as far as I can tell (but
    // I'm probably wrong). This is a special case for emoji modifiers
    // which only do not break if they're next to a base.
    //
    // emoji_modifier_sequence := emoji_modifier_base emoji_modifier
    if (gbc2 == .emoji_modifier and gbc1 == .extended_pictographic_base) {
        return false;
    }

    return true;
}

/// If you build this file as a binary, we will verify the grapheme break
/// implementation. This iterates over billions of codepoints so it is
/// SLOW. It's not meant to be run in CI, but it's useful for debugging.
/// TODO: this is hard to build with newer zig build, so
/// https://github.com/ghostty-org/ghostty/pull/7806 took the approach of
/// adding a `-Demit-unicode-test` option for `zig build`, but that
/// hasn't been done here.
pub fn main() !void {
    const uucode = @import("uucode");

    // Set the min and max to control the test range.
    const min = 0;
    const max = uucode.config.max_code_point + 1;

    var state: BreakState = .{};
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
        var state: BreakState = .{};
        try testing.expect(!graphemeBreak(0x261D, 0x1F3FF, &state));
    }

    // Non-emoji and emoji modifier
    {
        var state: BreakState = .{};
        try testing.expect(graphemeBreak(0x22, 0x1F3FF, &state));
    }
}
