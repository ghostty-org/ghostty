/// Input handling for Win32, including keyboard and mouse events.
const std = @import("std");
const apprt = @import("../../apprt.zig");
const c = @import("c.zig");
const input = @import("../../input.zig");
const Surface = @import("Surface.zig");

const log = std.log.scoped(.win32_input);

// Virtual key codes
const VK_BACK = 0x08;
const VK_TAB = 0x09;
const VK_RETURN = 0x0D;
const VK_SHIFT = 0x10;
const VK_CONTROL = 0x11;
const VK_MENU = 0x12; // Alt key
const VK_PAUSE = 0x13;
const VK_CAPITAL = 0x14; // Caps Lock
const VK_ESCAPE = 0x1B;
const VK_SPACE = 0x20;
const VK_PRIOR = 0x21; // Page Up
const VK_NEXT = 0x22; // Page Down
const VK_END = 0x23;
const VK_HOME = 0x24;
const VK_LEFT = 0x25;
const VK_UP = 0x26;
const VK_RIGHT = 0x27;
const VK_DOWN = 0x28;
const VK_SNAPSHOT = 0x2C; // Print Screen
const VK_INSERT = 0x2D;
const VK_DELETE = 0x2E;
const VK_0 = 0x30;
const VK_1 = 0x31;
const VK_2 = 0x32;
const VK_3 = 0x33;
const VK_4 = 0x34;
const VK_5 = 0x35;
const VK_6 = 0x36;
const VK_7 = 0x37;
const VK_8 = 0x38;
const VK_9 = 0x39;
const VK_A = 0x41;
const VK_B = 0x42;
const VK_C = 0x43;
const VK_D = 0x44;
const VK_E = 0x45;
const VK_F = 0x46;
const VK_G = 0x47;
const VK_H = 0x48;
const VK_I = 0x49;
const VK_J = 0x4A;
const VK_K = 0x4B;
const VK_L = 0x4C;
const VK_M = 0x4D;
const VK_N = 0x4E;
const VK_O = 0x4F;
const VK_P = 0x50;
const VK_Q = 0x51;
const VK_R = 0x52;
const VK_S = 0x53;
const VK_T = 0x54;
const VK_U = 0x55;
const VK_V = 0x56;
const VK_W = 0x57;
const VK_X = 0x58;
const VK_Y = 0x59;
const VK_Z = 0x5A;
const VK_LWIN = 0x5B; // Left Windows key
const VK_RWIN = 0x5C; // Right Windows key
const VK_APPS = 0x5D; // Applications/Menu key
const VK_SLEEP = 0x5F;
const VK_NUMPAD0 = 0x60;
const VK_NUMPAD1 = 0x61;
const VK_NUMPAD2 = 0x62;
const VK_NUMPAD3 = 0x63;
const VK_NUMPAD4 = 0x64;
const VK_NUMPAD5 = 0x65;
const VK_NUMPAD6 = 0x66;
const VK_NUMPAD7 = 0x67;
const VK_NUMPAD8 = 0x68;
const VK_NUMPAD9 = 0x69;
const VK_MULTIPLY = 0x6A;
const VK_ADD = 0x6B;
const VK_SEPARATOR = 0x6C;
const VK_SUBTRACT = 0x6D;
const VK_DECIMAL = 0x6E;
const VK_DIVIDE = 0x6F;
const VK_F1 = 0x70;
const VK_F2 = 0x71;
const VK_F3 = 0x72;
const VK_F4 = 0x73;
const VK_F5 = 0x74;
const VK_F6 = 0x75;
const VK_F7 = 0x76;
const VK_F8 = 0x77;
const VK_F9 = 0x78;
const VK_F10 = 0x79;
const VK_F11 = 0x7A;
const VK_F12 = 0x7B;
const VK_F13 = 0x7C;
const VK_F14 = 0x7D;
const VK_F15 = 0x7E;
const VK_F16 = 0x7F;
const VK_F17 = 0x80;
const VK_F18 = 0x81;
const VK_F19 = 0x82;
const VK_F20 = 0x83;
const VK_F21 = 0x84;
const VK_F22 = 0x85;
const VK_F23 = 0x86;
const VK_F24 = 0x87;
const VK_NUMLOCK = 0x90;
const VK_SCROLL = 0x91; // Scroll Lock
const VK_LSHIFT = 0xA0;
const VK_RSHIFT = 0xA1;
const VK_LCONTROL = 0xA2;
const VK_RCONTROL = 0xA3;
const VK_LMENU = 0xA4; // Left Alt
const VK_RMENU = 0xA5; // Right Alt
const VK_OEM_1 = 0xBA; // ;: on US keyboard
const VK_OEM_PLUS = 0xBB; // =+
const VK_OEM_COMMA = 0xBC; // ,<
const VK_OEM_MINUS = 0xBD; // -_
const VK_OEM_PERIOD = 0xBE; // .>
const VK_OEM_2 = 0xBF; // /? on US keyboard
const VK_OEM_3 = 0xC0; // `~ on US keyboard
const VK_OEM_4 = 0xDB; // [{
const VK_OEM_5 = 0xDC; // \| on US keyboard
const VK_OEM_6 = 0xDD; // ]}
const VK_OEM_7 = 0xDE; // '" on US keyboard
const VK_OEM_102 = 0xE2; // <> or \| on RT 102-key keyboard

/// Maps a Windows virtual key code to a Ghostty input.Key.
pub fn virtualKeyToKey(vk: c_int) input.Key {
    return switch (vk) {
        // Writing system keys
        VK_OEM_3 => .backquote,
        VK_OEM_5 => .backslash,
        VK_OEM_4 => .bracket_left,
        VK_OEM_6 => .bracket_right,
        VK_OEM_COMMA => .comma,
        VK_0 => .digit_0,
        VK_1 => .digit_1,
        VK_2 => .digit_2,
        VK_3 => .digit_3,
        VK_4 => .digit_4,
        VK_5 => .digit_5,
        VK_6 => .digit_6,
        VK_7 => .digit_7,
        VK_8 => .digit_8,
        VK_9 => .digit_9,
        VK_OEM_PLUS => .equal,
        VK_OEM_102 => .intl_backslash,
        VK_A => .key_a,
        VK_B => .key_b,
        VK_C => .key_c,
        VK_D => .key_d,
        VK_E => .key_e,
        VK_F => .key_f,
        VK_G => .key_g,
        VK_H => .key_h,
        VK_I => .key_i,
        VK_J => .key_j,
        VK_K => .key_k,
        VK_L => .key_l,
        VK_M => .key_m,
        VK_N => .key_n,
        VK_O => .key_o,
        VK_P => .key_p,
        VK_Q => .key_q,
        VK_R => .key_r,
        VK_S => .key_s,
        VK_T => .key_t,
        VK_U => .key_u,
        VK_V => .key_v,
        VK_W => .key_w,
        VK_X => .key_x,
        VK_Y => .key_y,
        VK_Z => .key_z,
        VK_OEM_MINUS => .minus,
        VK_OEM_PERIOD => .period,
        VK_OEM_7 => .quote,
        VK_OEM_1 => .semicolon,
        VK_OEM_2 => .slash,

        // Functional keys
        VK_LMENU => .alt_left,
        VK_RMENU => .alt_right,
        VK_BACK => .backspace,
        VK_CAPITAL => .caps_lock,
        VK_APPS => .context_menu,
        VK_LCONTROL => .control_left,
        VK_RCONTROL => .control_right,
        VK_RETURN => .enter,
        VK_LWIN => .meta_left,
        VK_RWIN => .meta_right,
        VK_LSHIFT => .shift_left,
        VK_RSHIFT => .shift_right,
        VK_SPACE => .space,
        VK_TAB => .tab,

        // Control pad section
        VK_DELETE => .delete,
        VK_END => .end,
        VK_HOME => .home,
        VK_INSERT => .insert,
        VK_NEXT => .page_down,
        VK_PRIOR => .page_up,

        // Arrow pad section
        VK_DOWN => .arrow_down,
        VK_LEFT => .arrow_left,
        VK_RIGHT => .arrow_right,
        VK_UP => .arrow_up,

        // Numpad section
        VK_NUMLOCK => .num_lock,
        VK_NUMPAD0 => .numpad_0,
        VK_NUMPAD1 => .numpad_1,
        VK_NUMPAD2 => .numpad_2,
        VK_NUMPAD3 => .numpad_3,
        VK_NUMPAD4 => .numpad_4,
        VK_NUMPAD5 => .numpad_5,
        VK_NUMPAD6 => .numpad_6,
        VK_NUMPAD7 => .numpad_7,
        VK_NUMPAD8 => .numpad_8,
        VK_NUMPAD9 => .numpad_9,
        VK_ADD => .numpad_add,
        VK_DECIMAL => .numpad_decimal,
        VK_DIVIDE => .numpad_divide,
        VK_MULTIPLY => .numpad_multiply,
        VK_SUBTRACT => .numpad_subtract,
        VK_SEPARATOR => .numpad_separator,

        // Function section
        VK_ESCAPE => .escape,
        VK_F1 => .f1,
        VK_F2 => .f2,
        VK_F3 => .f3,
        VK_F4 => .f4,
        VK_F5 => .f5,
        VK_F6 => .f6,
        VK_F7 => .f7,
        VK_F8 => .f8,
        VK_F9 => .f9,
        VK_F10 => .f10,
        VK_F11 => .f11,
        VK_F12 => .f12,
        VK_F13 => .f13,
        VK_F14 => .f14,
        VK_F15 => .f15,
        VK_F16 => .f16,
        VK_F17 => .f17,
        VK_F18 => .f18,
        VK_F19 => .f19,
        VK_F20 => .f20,
        VK_F21 => .f21,
        VK_F22 => .f22,
        VK_F23 => .f23,
        VK_F24 => .f24,

        VK_SNAPSHOT => .print_screen,
        VK_SCROLL => .scroll_lock,
        VK_PAUSE => .pause,

        else => .unidentified,
    };
}

/// Translates Windows modifier key state into Ghostty modifiers.
pub fn translateMods() input.Mods {
    const GetKeyState = struct {
        extern "user32" fn GetKeyState(nVirtKey: c_int) callconv(c.WINAPI) c_short;
    }.GetKeyState;

    return .{
        .shift = GetKeyState(VK_SHIFT) < 0,
        .ctrl = GetKeyState(VK_CONTROL) < 0,
        .alt = GetKeyState(VK_MENU) < 0,
        .super = GetKeyState(VK_LWIN) < 0 or GetKeyState(VK_RWIN) < 0,
        .caps_lock = (GetKeyState(VK_CAPITAL) & 1) != 0,
        .num_lock = (GetKeyState(VK_NUMLOCK) & 1) != 0,
    };
}

/// Compute which modifiers were consumed by the keyboard layout to produce
/// the given character. For example, Shift+2 → '@' means shift was consumed.
/// AltGr (Ctrl+Alt on Windows) producing a character means ctrl+alt were consumed.
fn computeConsumedMods(mods: input.Mods, char_code: u21, unshifted_codepoint: u21) input.Mods {
    var consumed: input.Mods = .{};

    // If shift is held and the character differs from the unshifted codepoint,
    // then shift was consumed by the layout to produce this character.
    if (mods.shift and unshifted_codepoint > 0 and char_code != unshifted_codepoint) {
        consumed.shift = true;
    }

    // AltGr on Windows is represented as Ctrl+Alt. If both are held and we
    // got a printable character, they were consumed by the layout.
    if (mods.ctrl and mods.alt and char_code >= 0x20) {
        consumed.ctrl = true;
        consumed.alt = true;
    }

    return consumed;
}

/// Flush any pending key event that wasn't consumed by a WM_CHAR.
/// Called before processing new WM_KEYDOWN or at other appropriate points.
pub fn flushPendingKey(surface: *Surface) !void {
    if (surface.pending_key) |key_event| {
        if (!surface.pending_key_consumed) {
            // Fire the pending key with no text (non-character key like arrows, F-keys)
            if (surface.core_surface) |cs| {
                _ = try cs.keyCallback(key_event);
            }
        }
        surface.pending_key = null;
        surface.pending_key_consumed = false;
    }
}

/// Handles a keyboard event (WM_KEYDOWN, WM_KEYUP, WM_SYSKEYDOWN, WM_SYSKEYUP).
pub fn handleKeyEvent(
    surface: *Surface,
    msg: u32,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
) !void {
    const core_surface = surface.core_surface orelse return;

    const raw_vk: c_int = @intCast(wparam);
    const scan_code: u32 = @truncate((@as(usize, @bitCast(lparam)) >> 16) & 0xFF);
    const extended: bool = ((@as(usize, @bitCast(lparam)) >> 24) & 1) != 0;

    // Resolve generic modifier VK codes to left/right variants.
    // WM_KEYDOWN sends VK_SHIFT (0x10), not VK_LSHIFT/VK_RSHIFT.
    // Without this, modifier keys map to .unidentified.
    const vk: c_int = switch (raw_vk) {
        VK_SHIFT => @intCast(c.MapVirtualKeyW(scan_code, c.MAPVK_VSC_TO_VK_EX)),
        VK_CONTROL => if (extended) VK_RCONTROL else VK_LCONTROL,
        VK_MENU => if (extended) VK_RMENU else VK_LMENU,
        else => raw_vk,
    };

    // Map VK to Ghostty key, with special handling for numpad enter
    const key: input.Key = if (raw_vk == VK_RETURN and extended)
        .numpad_enter
    else
        virtualKeyToKey(vk);

    // Determine action (press or release)
    const action: input.Action = switch (msg) {
        c.WM_KEYDOWN, c.WM_SYSKEYDOWN => blk: {
            // Detect repeat: bit 30 of lparam is 1 if key was already down
            const repeat = (lparam >> 30) & 1;
            break :blk if (repeat != 0) .repeat else .press;
        },
        c.WM_KEYUP, c.WM_SYSKEYUP => .release,
        else => return,
    };

    // Get modifiers
    var mods = translateMods();

    // Adjust modifiers for the key being pressed/released
    switch (key) {
        .shift_left, .shift_right => mods.shift = (action != .release),
        .control_left, .control_right => mods.ctrl = (action != .release),
        .alt_left, .alt_right => mods.alt = (action != .release),
        .meta_left, .meta_right => mods.super = (action != .release),
        else => {},
    }

    // Set sided modifiers
    switch (key) {
        .shift_left => mods.sides.shift = .left,
        .shift_right => mods.sides.shift = .right,
        .control_left => mods.sides.ctrl = .left,
        .control_right => mods.sides.ctrl = .right,
        .alt_left => mods.sides.alt = .left,
        .alt_right => mods.sides.alt = .right,
        .meta_left => mods.sides.super = .left,
        .meta_right => mods.sides.super = .right,
        else => {},
    }

    // Get unshifted codepoint via MapVirtualKeyW
    const unshifted_codepoint: u21 = blk: {
        const mapped = c.MapVirtualKeyW(@intCast(@as(u32, @bitCast(vk))), c.MAPVK_VK_TO_CHAR);
        // Bit 31 is set for dead keys - mask it off
        break :blk @intCast(mapped & 0x7FFFFFFF);
    };

    // Create key event
    const key_event = input.KeyEvent{
        .action = action,
        .key = key,
        .mods = mods,
        .consumed_mods = .{},
        .composing = false,
        .utf8 = "",
        .unshifted_codepoint = unshifted_codepoint,
    };

    // For key up events, fire immediately (no text expected)
    if (action == .release) {
        // Flush any pending key first
        try flushPendingKey(surface);
        _ = try core_surface.keyCallback(key_event);
        return;
    }

    // For key down/repeat: flush any previous pending key, then store this one.
    // TranslateMessage in the message loop will generate WM_CHAR if applicable.
    try flushPendingKey(surface);
    surface.pending_key = key_event;
    surface.pending_key_consumed = false;
}

/// Handles a character input event (WM_CHAR).
pub fn handleCharEvent(
    surface: *Surface,
    wparam: c.WPARAM,
) !void {
    const core_surface = surface.core_surface orelse return;

    const char_code: u21 = @intCast(wparam & 0x1FFFFF);

    // Skip control characters that we don't want as text (e.g. backspace, tab, escape, enter)
    // These are handled by the key event directly
    if (char_code < 0x20 and char_code != 0) return;

    // Convert to UTF-8
    var utf8_buf: [4]u8 = undefined;
    const utf8_len = std.unicode.utf8Encode(char_code, &utf8_buf) catch return;

    if (surface.pending_key) |*pending| {
        // Fill in the text on the pending key event and fire it
        pending.utf8 = utf8_buf[0..utf8_len];

        // Compute consumed modifiers: modifiers that were used by the keyboard
        // layout to produce the character (e.g., shift+2 → '@' means shift is
        // consumed). Without this, the kitty keyboard protocol would encode
        // shift+2 as a modified key rather than plain '@'.
        pending.consumed_mods = computeConsumedMods(pending.mods, char_code, pending.unshifted_codepoint);

        _ = try core_surface.keyCallback(pending.*);
        surface.pending_key_consumed = true;
    } else {
        // Standalone WM_CHAR (e.g., from IME)
        const mods = translateMods();
        const key_event = input.KeyEvent{
            .action = .press,
            .key = .unidentified,
            .mods = mods,
            .consumed_mods = .{},
            .composing = false,
            .utf8 = utf8_buf[0..utf8_len],
            .unshifted_codepoint = 0,
        };
        _ = try core_surface.keyCallback(key_event);
    }
}

/// Handles WM_DEADCHAR - marks the next key as composing.
pub fn handleDeadCharEvent(
    surface: *Surface,
) !void {
    // If there's a pending key, mark it as composing and fire it
    if (surface.pending_key) |*pending| {
        pending.composing = true;
        if (surface.core_surface) |cs| {
            _ = try cs.keyCallback(pending.*);
        }
        surface.pending_key_consumed = true;
    }
}

/// Handles mouse button events (WM_LBUTTONDOWN, WM_RBUTTONDOWN, etc.).
pub fn handleMouseButton(
    surface: *Surface,
    msg: u32,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
) !void {
    const core_surface = surface.core_surface orelse return;

    const x = c.GET_X_LPARAM(lparam);
    const y = c.GET_Y_LPARAM(lparam);

    const button_action = switch (msg) {
        c.WM_LBUTTONDOWN => .{ input.MouseButtonState.press, input.MouseButton.left },
        c.WM_LBUTTONUP => .{ input.MouseButtonState.release, input.MouseButton.left },
        c.WM_RBUTTONDOWN => .{ input.MouseButtonState.press, input.MouseButton.right },
        c.WM_RBUTTONUP => .{ input.MouseButtonState.release, input.MouseButton.right },
        c.WM_MBUTTONDOWN => .{ input.MouseButtonState.press, input.MouseButton.middle },
        c.WM_MBUTTONUP => .{ input.MouseButtonState.release, input.MouseButton.middle },
        c.WM_XBUTTONDOWN => .{
            input.MouseButtonState.press,
            xbuttonToButton(wparam),
        },
        c.WM_XBUTTONUP => .{
            input.MouseButtonState.release,
            xbuttonToButton(wparam),
        },
        else => return,
    };

    const action: input.MouseButtonState = button_action[0];
    const button: input.MouseButton = button_action[1];

    // Capture/release mouse on press/release
    switch (action) {
        .press => _ = c.SetCapture(surface.hwnd),
        .release => _ = c.ReleaseCapture(),
    }

    // Update cursor position first
    const pos = apprt.CursorPos{
        .x = @floatFromInt(x),
        .y = @floatFromInt(y),
    };
    try core_surface.cursorPosCallback(pos, translateMods());

    // Send mouse button event
    _ = try core_surface.mouseButtonCallback(action, button, translateMods());
}

fn xbuttonToButton(wparam: c.WPARAM) input.MouseButton {
    const xbutton = c.GET_XBUTTON_WPARAM(wparam);
    return switch (xbutton) {
        c.XBUTTON1 => .four,
        c.XBUTTON2 => .five,
        else => .unknown,
    };
}

/// Handles mouse movement (WM_MOUSEMOVE).
pub fn handleMouseMove(
    surface: *Surface,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
) !void {
    _ = wparam;
    const core_surface = surface.core_surface orelse return;

    const x = c.GET_X_LPARAM(lparam);
    const y = c.GET_Y_LPARAM(lparam);

    // Request WM_MOUSELEAVE tracking on first move
    if (!surface.tracking_mouse) {
        var tme = c.TRACKMOUSEEVENT{
            .cbSize = @sizeOf(c.TRACKMOUSEEVENT),
            .dwFlags = c.TME_LEAVE,
            .hwndTrack = surface.hwnd,
            .dwHoverTime = 0,
        };
        _ = c.TrackMouseEvent(&tme);
        surface.tracking_mouse = true;
    }

    const pos = apprt.CursorPos{
        .x = @floatFromInt(x),
        .y = @floatFromInt(y),
    };
    try core_surface.cursorPosCallback(pos, translateMods());
}

/// Handles mouse wheel events (WM_MOUSEWHEEL).
pub fn handleMouseWheel(
    surface: *Surface,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
) !void {
    _ = lparam;
    const core_surface = surface.core_surface orelse return;

    const delta = c.GET_WHEEL_DELTA_WPARAM(wparam);
    const yoff: f64 = @as(f64, @floatFromInt(delta)) / 120.0;
    try core_surface.scrollCallback(0, yoff, .{});
}

/// Handles horizontal mouse wheel events (WM_MOUSEHWHEEL).
pub fn handleMouseHWheel(
    surface: *Surface,
    wparam: c.WPARAM,
    lparam: c.LPARAM,
) !void {
    _ = lparam;
    const core_surface = surface.core_surface orelse return;

    const delta = c.GET_WHEEL_DELTA_WPARAM(wparam);
    const xoff: f64 = @as(f64, @floatFromInt(delta)) / 120.0;
    try core_surface.scrollCallback(xoff, 0, .{});
}

/// Handles mouse leave events (WM_MOUSELEAVE).
pub fn handleMouseLeave(
    surface: *Surface,
) !void {
    const core_surface = surface.core_surface orelse return;
    surface.tracking_mouse = false;
    try core_surface.cursorPosCallback(.{ .x = -1, .y = -1 }, null);
}
