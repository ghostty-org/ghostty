const std = @import("std");
const build_options = @import("build_options");

const gdk = @import("gdk");
const glib = @import("glib");
const gtk = @import("gtk");

const input = @import("../../input.zig");
const winproto = @import("winproto.zig");

/// Returns a GTK accelerator string from a trigger.
pub fn accelFromTrigger(buf: []u8, trigger: input.Binding.Trigger) !?[:0]const u8 {
    var buf_stream = std.io.fixedBufferStream(buf);
    const writer = buf_stream.writer();

    // Modifiers
    if (trigger.mods.shift) try writer.writeAll("<Shift>");
    if (trigger.mods.ctrl) try writer.writeAll("<Ctrl>");
    if (trigger.mods.alt) try writer.writeAll("<Alt>");
    if (trigger.mods.super) try writer.writeAll("<Super>");

    // Write our key
    switch (trigger.key) {
        .physical, .translated => |k| {
            const keyval = keyvalFromKey(k) orelse return null;
            try writer.writeAll(std.mem.span(gdk.keyvalName(keyval) orelse return null));
        },

        .unicode => |cp| {
            if (gdk.keyvalName(cp)) |name| {
                try writer.writeAll(std.mem.span(name));
            } else {
                try writer.print("{u}", .{cp});
            }
        },
    }

    // We need to make the string null terminated.
    try writer.writeByte(0);
    const slice = buf_stream.getWritten();
    return slice[0 .. slice.len - 1 :0];
}

pub fn translateMods(state: gdk.ModifierType) input.Mods {
    return .{
        .shift = state.shift_mask,
        .ctrl = state.control_mask,
        .alt = state.alt_mask,
        .super = state.super_mask,
        // Lock is dependent on the X settings but we just assume caps lock.
        .caps_lock = state.lock_mask,
    };
}

// Get the unshifted unicode value of the keyval. This is used
// by the Kitty keyboard protocol.
pub fn keyvalUnicodeUnshifted(
    widget: *gtk.Widget,
    event: *gdk.KeyEvent,
    keycode: u32,
) u21 {
    const display = widget.getDisplay();

    // We need to get the currently active keyboard layout so we know
    // what group to look at.
    const layout = event.getLayout();

    // Get all the possible keyboard mappings for this keycode. A keycode is the
    // physical key pressed.
    var keys: [*]gdk.KeymapKey = undefined;
    var keyvals: [*]c_uint = undefined;
    var n_entries: c_int = 0;
    if (display.mapKeycode(keycode, &keys, &keyvals, &n_entries) == 0) return 0;

    defer glib.free(keys);
    defer glib.free(keyvals);

    // debugging:
    // std.log.debug("layout={}", .{layout});
    // for (0..@intCast(n_entries)) |i| {
    //     std.log.debug("keymap key={} codepoint={x}", .{
    //         keys[i],
    //         gdk.keyvalToUnicode(keyvals[i]),
    //     });
    // }

    for (0..@intCast(n_entries)) |i| {
        if (keys[i].f_group == layout and
            keys[i].f_level == 0)
        {
            return std.math.cast(
                u21,
                gdk.keyvalToUnicode(keyvals[i]),
            ) orelse 0;
        }
    }

    return 0;
}

/// Returns the mods to use a key event from a GTK event.
/// This requires a lot of context because the GdkEvent
/// doesn't contain enough on its own.
pub fn eventMods(
    event: *gdk.Event,
    physical_key: input.Key,
    gtk_mods: gdk.ModifierType,
    action: input.Action,
    app_winproto: *winproto.App,
) input.Mods {
    const device = event.getDevice();

    var mods = app_winproto.eventMods(device, gtk_mods);
    mods.num_lock = if (device) |d| d.getNumLockState() != 0 else false;

    // We use the physical key to determine sided modifiers. As
    // far as I can tell there's no other way to reliably determine
    // this.
    //
    // We also set the main modifier to true if either side is true,
    // since on both X11/Wayland, GTK doesn't set the main modifier
    // if only the modifier key is pressed, but our core logic
    // relies on it.
    switch (physical_key) {
        .left_shift => {
            mods.shift = action != .release;
            mods.sides.shift = .left;
        },

        .right_shift => {
            mods.shift = action != .release;
            mods.sides.shift = .right;
        },

        .left_control => {
            mods.ctrl = action != .release;
            mods.sides.ctrl = .left;
        },

        .right_control => {
            mods.ctrl = action != .release;
            mods.sides.ctrl = .right;
        },

        .left_alt => {
            mods.alt = action != .release;
            mods.sides.alt = .left;
        },

        .right_alt => {
            mods.alt = action != .release;
            mods.sides.alt = .right;
        },

        .left_super => {
            mods.super = action != .release;
            mods.sides.super = .left;
        },

        .right_super => {
            mods.super = action != .release;
            mods.sides.super = .right;
        },

        else => {},
    }

    return mods;
}

/// Returns an input key from a keyval or null if we don't have a mapping.
pub fn keyFromKeyval(keyval: c_uint) ?input.Key {
    for (keymap) |entry| {
        if (entry[0] == keyval) return entry[1];
    }

    return null;
}

/// Returns a keyval from an input key or null if we don't have a mapping.
pub fn keyvalFromKey(key: input.Key) ?c_uint {
    switch (key) {
        inline else => |key_comptime| {
            return comptime value: {
                @setEvalBranchQuota(10_000);
                for (keymap) |entry| {
                    if (entry[1] == key_comptime) break :value entry[0];
                }

                break :value null;
            };
        },
    }
}

test "accelFromTrigger" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;

    try testing.expectEqualStrings("<Super>q", (try accelFromTrigger(&buf, .{
        .mods = .{ .super = true },
        .key = .{ .translated = .q },
    })).?);

    try testing.expectEqualStrings("<Shift><Ctrl><Alt><Super>backslash", (try accelFromTrigger(&buf, .{
        .mods = .{ .ctrl = true, .alt = true, .super = true, .shift = true },
        .key = .{ .unicode = 92 },
    })).?);
}

/// A raw entry in the keymap. Our keymap contains mappings between
/// GDK keys and our own key enum.
const RawEntry = struct { c_uint, input.Key };

const keymap: []const RawEntry = &.{
    .{ gdk.KEY_a, .a },
    .{ gdk.KEY_b, .b },
    .{ gdk.KEY_c, .c },
    .{ gdk.KEY_d, .d },
    .{ gdk.KEY_e, .e },
    .{ gdk.KEY_f, .f },
    .{ gdk.KEY_g, .g },
    .{ gdk.KEY_h, .h },
    .{ gdk.KEY_i, .i },
    .{ gdk.KEY_j, .j },
    .{ gdk.KEY_k, .k },
    .{ gdk.KEY_l, .l },
    .{ gdk.KEY_m, .m },
    .{ gdk.KEY_n, .n },
    .{ gdk.KEY_o, .o },
    .{ gdk.KEY_p, .p },
    .{ gdk.KEY_q, .q },
    .{ gdk.KEY_r, .r },
    .{ gdk.KEY_s, .s },
    .{ gdk.KEY_t, .t },
    .{ gdk.KEY_u, .u },
    .{ gdk.KEY_v, .v },
    .{ gdk.KEY_w, .w },
    .{ gdk.KEY_x, .x },
    .{ gdk.KEY_y, .y },
    .{ gdk.KEY_z, .z },

    .{ gdk.KEY_0, .zero },
    .{ gdk.KEY_1, .one },
    .{ gdk.KEY_2, .two },
    .{ gdk.KEY_3, .three },
    .{ gdk.KEY_4, .four },
    .{ gdk.KEY_5, .five },
    .{ gdk.KEY_6, .six },
    .{ gdk.KEY_7, .seven },
    .{ gdk.KEY_8, .eight },
    .{ gdk.KEY_9, .nine },

    .{ gdk.KEY_semicolon, .semicolon },
    .{ gdk.KEY_space, .space },
    .{ gdk.KEY_apostrophe, .apostrophe },
    .{ gdk.KEY_comma, .comma },
    .{ gdk.KEY_grave, .grave_accent },
    .{ gdk.KEY_period, .period },
    .{ gdk.KEY_slash, .slash },
    .{ gdk.KEY_minus, .minus },
    .{ gdk.KEY_equal, .equal },
    .{ gdk.KEY_bracketleft, .left_bracket },
    .{ gdk.KEY_bracketright, .right_bracket },
    .{ gdk.KEY_backslash, .backslash },

    .{ gdk.KEY_Up, .up },
    .{ gdk.KEY_Down, .down },
    .{ gdk.KEY_Right, .right },
    .{ gdk.KEY_Left, .left },
    .{ gdk.KEY_Home, .home },
    .{ gdk.KEY_End, .end },
    .{ gdk.KEY_Insert, .insert },
    .{ gdk.KEY_Delete, .delete },
    .{ gdk.KEY_Caps_Lock, .caps_lock },
    .{ gdk.KEY_Scroll_Lock, .scroll_lock },
    .{ gdk.KEY_Num_Lock, .num_lock },
    .{ gdk.KEY_Page_Up, .page_up },
    .{ gdk.KEY_Page_Down, .page_down },
    .{ gdk.KEY_Escape, .escape },
    .{ gdk.KEY_Return, .enter },
    .{ gdk.KEY_Tab, .tab },
    .{ gdk.KEY_BackSpace, .backspace },
    .{ gdk.KEY_Print, .print_screen },
    .{ gdk.KEY_Pause, .pause },

    .{ gdk.KEY_F1, .f1 },
    .{ gdk.KEY_F2, .f2 },
    .{ gdk.KEY_F3, .f3 },
    .{ gdk.KEY_F4, .f4 },
    .{ gdk.KEY_F5, .f5 },
    .{ gdk.KEY_F6, .f6 },
    .{ gdk.KEY_F7, .f7 },
    .{ gdk.KEY_F8, .f8 },
    .{ gdk.KEY_F9, .f9 },
    .{ gdk.KEY_F10, .f10 },
    .{ gdk.KEY_F11, .f11 },
    .{ gdk.KEY_F12, .f12 },
    .{ gdk.KEY_F13, .f13 },
    .{ gdk.KEY_F14, .f14 },
    .{ gdk.KEY_F15, .f15 },
    .{ gdk.KEY_F16, .f16 },
    .{ gdk.KEY_F17, .f17 },
    .{ gdk.KEY_F18, .f18 },
    .{ gdk.KEY_F19, .f19 },
    .{ gdk.KEY_F20, .f20 },
    .{ gdk.KEY_F21, .f21 },
    .{ gdk.KEY_F22, .f22 },
    .{ gdk.KEY_F23, .f23 },
    .{ gdk.KEY_F24, .f24 },
    .{ gdk.KEY_F25, .f25 },

    .{ gdk.KEY_KP_0, .kp_0 },
    .{ gdk.KEY_KP_1, .kp_1 },
    .{ gdk.KEY_KP_2, .kp_2 },
    .{ gdk.KEY_KP_3, .kp_3 },
    .{ gdk.KEY_KP_4, .kp_4 },
    .{ gdk.KEY_KP_5, .kp_5 },
    .{ gdk.KEY_KP_6, .kp_6 },
    .{ gdk.KEY_KP_7, .kp_7 },
    .{ gdk.KEY_KP_8, .kp_8 },
    .{ gdk.KEY_KP_9, .kp_9 },
    .{ gdk.KEY_KP_Decimal, .kp_decimal },
    .{ gdk.KEY_KP_Divide, .kp_divide },
    .{ gdk.KEY_KP_Multiply, .kp_multiply },
    .{ gdk.KEY_KP_Subtract, .kp_subtract },
    .{ gdk.KEY_KP_Add, .kp_add },
    .{ gdk.KEY_KP_Enter, .kp_enter },
    .{ gdk.KEY_KP_Equal, .kp_equal },

    .{ gdk.KEY_KP_Separator, .kp_separator },
    .{ gdk.KEY_KP_Left, .kp_left },
    .{ gdk.KEY_KP_Right, .kp_right },
    .{ gdk.KEY_KP_Up, .kp_up },
    .{ gdk.KEY_KP_Down, .kp_down },
    .{ gdk.KEY_KP_Page_Up, .kp_page_up },
    .{ gdk.KEY_KP_Page_Down, .kp_page_down },
    .{ gdk.KEY_KP_Home, .kp_home },
    .{ gdk.KEY_KP_End, .kp_end },
    .{ gdk.KEY_KP_Insert, .kp_insert },
    .{ gdk.KEY_KP_Delete, .kp_delete },
    .{ gdk.KEY_KP_Begin, .kp_begin },

    .{ gdk.KEY_Shift_L, .left_shift },
    .{ gdk.KEY_Control_L, .left_control },
    .{ gdk.KEY_Alt_L, .left_alt },
    .{ gdk.KEY_Super_L, .left_super },
    .{ gdk.KEY_Shift_R, .right_shift },
    .{ gdk.KEY_Control_R, .right_control },
    .{ gdk.KEY_Alt_R, .right_alt },
    .{ gdk.KEY_Super_R, .right_super },

    // TODO: media keys
};
