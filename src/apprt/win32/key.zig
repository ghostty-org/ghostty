//! Translation from Windows virtual-key codes to Ghostty's physical keys.
const std = @import("std");
const input = @import("../../input.zig");

const Key = input.Key;

/// Map a virtual-key code from WM_KEYDOWN to a physical key. `extended` is
/// bit 24 of the message's lParam and tells the left and right copies of
/// Enter, Ctrl and Alt apart. `scan_code` separates the two shift keys.
pub fn fromVirtualKey(vk: u32, extended: bool, scan_code: u32) Key {
    return switch (vk) {
        'A'...'Z' => letter(vk),
        '0'...'9' => digit(vk),
        0x08 => .backspace,
        0x09 => .tab,
        0x0D => if (extended) .numpad_enter else .enter,
        0x10 => if (scan_code == 0x36) .shift_right else .shift_left,
        0x11 => if (extended) .control_right else .control_left,
        0x12 => if (extended) .alt_right else .alt_left,
        0x13 => .pause,
        0x14 => .caps_lock,
        0x1B => .escape,
        0x20 => .space,
        0x21 => .page_up,
        0x22 => .page_down,
        0x23 => .end,
        0x24 => .home,
        0x25 => .arrow_left,
        0x26 => .arrow_up,
        0x27 => .arrow_right,
        0x28 => .arrow_down,
        0x2C => .print_screen,
        0x2D => .insert,
        0x2E => .delete,
        0x5B => .meta_left,
        0x5C => .meta_right,
        0x5D => .context_menu,
        0x60...0x69 => numpad(vk),
        0x6A => .numpad_multiply,
        0x6B => .numpad_add,
        0x6C => .numpad_separator,
        0x6D => .numpad_subtract,
        0x6E => .numpad_decimal,
        0x6F => .numpad_divide,
        0x70...0x87 => function(vk),
        0x90 => .num_lock,
        0x91 => .scroll_lock,
        0xBA => .semicolon,
        0xBB => .equal,
        0xBC => .comma,
        0xBD => .minus,
        0xBE => .period,
        0xBF => .slash,
        0xC0 => .backquote,
        0xDB => .bracket_left,
        0xDC => .backslash,
        0xDD => .bracket_right,
        0xDE => .quote,
        0xE2 => .intl_backslash,
        else => .unidentified,
    };
}

fn letter(vk: u32) Key {
    const letters = [_]Key{
        .key_a, .key_b, .key_c, .key_d, .key_e, .key_f, .key_g,
        .key_h, .key_i, .key_j, .key_k, .key_l, .key_m, .key_n,
        .key_o, .key_p, .key_q, .key_r, .key_s, .key_t, .key_u,
        .key_v, .key_w, .key_x, .key_y, .key_z,
    };
    return letters[vk - 'A'];
}

fn digit(vk: u32) Key {
    const digits = [_]Key{
        .digit_0, .digit_1, .digit_2, .digit_3, .digit_4,
        .digit_5, .digit_6, .digit_7, .digit_8, .digit_9,
    };
    return digits[vk - '0'];
}

fn numpad(vk: u32) Key {
    const keys = [_]Key{
        .numpad_0, .numpad_1, .numpad_2, .numpad_3, .numpad_4,
        .numpad_5, .numpad_6, .numpad_7, .numpad_8, .numpad_9,
    };
    return keys[vk - 0x60];
}

fn function(vk: u32) Key {
    const keys = [_]Key{
        .f1,  .f2,  .f3,  .f4,  .f5,  .f6,  .f7,  .f8,
        .f9,  .f10, .f11, .f12, .f13, .f14, .f15, .f16,
        .f17, .f18, .f19, .f20, .f21, .f22, .f23, .f24,
    };
    return keys[vk - 0x70];
}

test "letters, digits and function keys" {
    try std.testing.expectEqual(Key.key_a, fromVirtualKey('A', false, 0));
    try std.testing.expectEqual(Key.key_z, fromVirtualKey('Z', false, 0));
    try std.testing.expectEqual(Key.digit_7, fromVirtualKey('7', false, 0));
    try std.testing.expectEqual(Key.f1, fromVirtualKey(0x70, false, 0));
    try std.testing.expectEqual(Key.f24, fromVirtualKey(0x87, false, 0));
}

test "left and right variants" {
    try std.testing.expectEqual(Key.enter, fromVirtualKey(0x0D, false, 0));
    try std.testing.expectEqual(Key.numpad_enter, fromVirtualKey(0x0D, true, 0));
    try std.testing.expectEqual(Key.shift_left, fromVirtualKey(0x10, false, 0x2A));
    try std.testing.expectEqual(Key.shift_right, fromVirtualKey(0x10, false, 0x36));
    try std.testing.expectEqual(Key.alt_right, fromVirtualKey(0x12, true, 0));
}

test "unknown keys are unidentified" {
    try std.testing.expectEqual(Key.unidentified, fromVirtualKey(0xFF, false, 0));
}

/// The virtual-key code that produces a physical key, for registering
/// keyboard shortcuts with Windows. This is the reverse of `fromVirtualKey`.
pub fn virtualKeyOf(key: Key) ?u32 {
    var vk: u32 = 1;
    while (vk < 256) : (vk += 1) {
        if (fromVirtualKey(vk, false, 0) == key) return vk;
    }
    return null;
}

test "virtualKeyOf reverses the mapping" {
    try std.testing.expectEqual(@as(?u32, 'A'), virtualKeyOf(.key_a));
    try std.testing.expectEqual(@as(?u32, 0x70), virtualKeyOf(.f1));
    try std.testing.expectEqual(@as(?u32, 0xC0), virtualKeyOf(.backquote));
    try std.testing.expectEqual(@as(?u32, null), virtualKeyOf(.media_play_pause));
}
