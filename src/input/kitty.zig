const std = @import("std");
const key = @import("key.zig");

/// A single entry in the kitty keymap data. There are only ~100 entries
/// so the recommendation is to just use a linear search to find the entry
/// for a given key.
pub const Entry = struct {
    key: key.Key,
    code: u21,
    final: u8,
    modifier: bool,
};

/// The full list of entries for the current platform.
pub const entries: []const Entry = entries: {
    var result: [raw_entries.len]Entry = undefined;
    for (raw_entries, 0..) |raw, i| {
        result[i] = .{
            .key = raw[0],
            .code = raw[1],
            .final = raw[2],
            .modifier = raw[3],
        };
    }

    const final = result;
    break :entries &final;
};

/// Raw entry is the tuple form of an entry for easy human management.
/// This should never be used in a real program so it is not pub. For
/// real programs, use `entries` which has properly typed, structured data.
const RawEntry = struct { key.Key, u21, u8, bool };

/// The raw data for how to map keys to Kitty data. Based on the information:
/// https://sw.kovidgoyal.net/kitty/keyboard-protocol/#functional-key-definitions
/// And the exact table is ported from Foot:
/// https://codeberg.org/dnkl/foot/src/branch/master/kitty-keymap.h
///
/// Note that we currently don't support all the same keysyms as Kitty,
/// but we can add them as we add support.
///
/// These are stored in order of the above Kitty link, so it is easy to
/// find the entry for a given key.
const raw_entries: []const RawEntry = &.{
    .{ .escape, 27, 'u', false },
    .{ .enter, 13, 'u', false },
    .{ .tab, 9, 'u', false },
    .{ .backspace, 127, 'u', false },
    .{ .insert, 2, '~', false },
    .{ .delete, 3, '~', false },
    .{ .arrow_left, 1, 'D', false },
    .{ .arrow_right, 1, 'C', false },
    .{ .arrow_up, 1, 'A', false },
    .{ .arrow_down, 1, 'B', false },
    .{ .page_up, 5, '~', false },
    .{ .page_down, 6, '~', false },
    .{ .home, 1, 'H', false },
    .{ .end, 1, 'F', false },
    .{ .caps_lock, 57358, 'u', true },
    .{ .scroll_lock, 57359, 'u', false },
    .{ .num_lock, 57360, 'u', true },
    .{ .print_screen, 57361, 'u', false },
    .{ .pause, 57362, 'u', false },

    .{ .f1, 1, 'P', false },
    .{ .f2, 1, 'Q', false },
    .{ .f3, 13, '~', false },
    .{ .f4, 1, 'S', false },
    .{ .f5, 15, '~', false },
    .{ .f6, 17, '~', false },
    .{ .f7, 18, '~', false },
    .{ .f8, 19, '~', false },
    .{ .f9, 20, '~', false },
    .{ .f10, 21, '~', false },
    .{ .f11, 23, '~', false },
    .{ .f12, 24, '~', false },
    .{ .f13, 57376, 'u', false },
    .{ .f14, 57377, 'u', false },
    .{ .f15, 57378, 'u', false },
    .{ .f16, 57379, 'u', false },
    .{ .f17, 57380, 'u', false },
    .{ .f18, 57381, 'u', false },
    .{ .f19, 57382, 'u', false },
    .{ .f20, 57383, 'u', false },
    .{ .f21, 57384, 'u', false },
    .{ .f22, 57385, 'u', false },
    .{ .f23, 57386, 'u', false },
    .{ .f24, 57387, 'u', false },
    .{ .f25, 57388, 'u', false },

    .{ .numpad_0, 57399, 'u', false },
    .{ .numpad_1, 57400, 'u', false },
    .{ .numpad_2, 57401, 'u', false },
    .{ .numpad_3, 57402, 'u', false },
    .{ .numpad_4, 57403, 'u', false },
    .{ .numpad_5, 57404, 'u', false },
    .{ .numpad_6, 57405, 'u', false },
    .{ .numpad_7, 57406, 'u', false },
    .{ .numpad_8, 57407, 'u', false },
    .{ .numpad_9, 57408, 'u', false },
    .{ .numpad_decimal, 57409, 'u', false },
    .{ .numpad_divide, 57410, 'u', false },
    .{ .numpad_multiply, 57411, 'u', false },
    .{ .numpad_subtract, 57412, 'u', false },
    .{ .numpad_add, 57413, 'u', false },
    .{ .numpad_enter, 57414, 'u', false },
    .{ .numpad_equal, 57415, 'u', false },
    .{ .numpad_separator, 57416, 'u', false },
    .{ .numpad_left, 57417, 'u', false },
    .{ .numpad_right, 57418, 'u', false },
    .{ .numpad_up, 57419, 'u', false },
    .{ .numpad_down, 57420, 'u', false },
    .{ .numpad_page_up, 57421, 'u', false },
    .{ .numpad_page_down, 57422, 'u', false },
    .{ .numpad_home, 57423, 'u', false },
    .{ .numpad_end, 57424, 'u', false },
    .{ .numpad_insert, 57425, 'u', false },
    .{ .numpad_delete, 57426, 'u', false },
    .{ .numpad_begin, 57427, 'u', false },

    .{ .shift_left, 57441, 'u', true },
    .{ .shift_right, 57447, 'u', true },
    .{ .control_left, 57442, 'u', true },
    .{ .control_right, 57448, 'u', true },
    .{ .meta_left, 57444, 'u', true },
    .{ .meta_right, 57450, 'u', true },
    .{ .alt_left, 57443, 'u', true },
    .{ .alt_right, 57449, 'u', true },
};

test {
    // To force comptime to test it
    _ = entries;
}
