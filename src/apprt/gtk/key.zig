const std = @import("std");
const build_options = @import("build_options");
const input = @import("../../input.zig");
const c = @import("c.zig").c;
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
            try writer.writeAll(std.mem.sliceTo(c.gdk_keyval_name(keyval), 0));
        },

        .unicode => |cp| {
            if (c.gdk_keyval_name(cp)) |name| {
                try writer.writeAll(std.mem.sliceTo(name, 0));
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

pub fn translateMods(state: c.GdkModifierType) input.Mods {
    var mods: input.Mods = .{};
    if (state & c.GDK_SHIFT_MASK != 0) mods.shift = true;
    if (state & c.GDK_CONTROL_MASK != 0) mods.ctrl = true;
    if (state & c.GDK_ALT_MASK != 0) mods.alt = true;
    if (state & c.GDK_SUPER_MASK != 0) mods.super = true;

    // Lock is dependent on the X settings but we just assume caps lock.
    if (state & c.GDK_LOCK_MASK != 0) mods.caps_lock = true;
    return mods;
}

// Get the unshifted unicode value of the keyval. This is used
// by the Kitty keyboard protocol.
pub fn keyvalUnicodeUnshifted(
    widget: *c.GtkWidget,
    event: *c.GdkEvent,
    keycode: c.guint,
) u21 {
    const display = c.gtk_widget_get_display(widget);

    // We need to get the currently active keyboard layout so we know
    // what group to look at.
    const layout = c.gdk_key_event_get_layout(@ptrCast(event));

    // Get all the possible keyboard mappings for this keycode. A keycode
    // is the physical key pressed.
    var keys: [*]c.GdkKeymapKey = undefined;
    var keyvals: [*]c.guint = undefined;
    var n_keys: c_int = 0;
    if (c.gdk_display_map_keycode(
        display,
        keycode,
        @ptrCast(&keys),
        @ptrCast(&keyvals),
        &n_keys,
    ) == 0) return 0;

    defer c.g_free(keys);
    defer c.g_free(keyvals);

    // debugging:
    // log.debug("layout={}", .{layout});
    // for (0..@intCast(n_keys)) |i| {
    //     log.debug("keymap key={} codepoint={x}", .{
    //         keys[i],
    //         c.gdk_keyval_to_unicode(keyvals[i]),
    //     });
    // }

    for (0..@intCast(n_keys)) |i| {
        if (keys[i].group == layout and
            keys[i].level == 0)
        {
            return std.math.cast(
                u21,
                c.gdk_keyval_to_unicode(keyvals[i]),
            ) orelse 0;
        }
    }

    return 0;
}

/// Returns the mods to use a key event from a GTK event.
/// This requires a lot of context because the GdkEvent
/// doesn't contain enough on its own.
pub fn eventMods(
    event: *c.GdkEvent,
    physical_key: input.Key,
    gtk_mods: c.GdkModifierType,
    action: input.Action,
    app_winproto: *winproto.App,
) input.Mods {
    const device = c.gdk_event_get_device(event);

    var mods = app_winproto.eventMods(device, gtk_mods);
    mods.num_lock = c.gdk_device_get_num_lock_state(device) == 1;

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
pub fn keyFromKeyval(keyval: c.guint) ?input.Key {
    for (keymap) |entry| {
        if (entry[0] == keyval) return entry[1];
    }

    return null;
}

/// Returns a keyval from an input key or null if we don't have a mapping.
pub fn keyvalFromKey(key: input.Key) ?c.guint {
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
const RawEntry = struct { c.guint, input.Key };

const keymap: []const RawEntry = &.{
    .{ c.GDK_KEY_a, .a },
    .{ c.GDK_KEY_b, .b },
    .{ c.GDK_KEY_c, .c },
    .{ c.GDK_KEY_d, .d },
    .{ c.GDK_KEY_e, .e },
    .{ c.GDK_KEY_f, .f },
    .{ c.GDK_KEY_g, .g },
    .{ c.GDK_KEY_h, .h },
    .{ c.GDK_KEY_i, .i },
    .{ c.GDK_KEY_j, .j },
    .{ c.GDK_KEY_k, .k },
    .{ c.GDK_KEY_l, .l },
    .{ c.GDK_KEY_m, .m },
    .{ c.GDK_KEY_n, .n },
    .{ c.GDK_KEY_o, .o },
    .{ c.GDK_KEY_p, .p },
    .{ c.GDK_KEY_q, .q },
    .{ c.GDK_KEY_r, .r },
    .{ c.GDK_KEY_s, .s },
    .{ c.GDK_KEY_t, .t },
    .{ c.GDK_KEY_u, .u },
    .{ c.GDK_KEY_v, .v },
    .{ c.GDK_KEY_w, .w },
    .{ c.GDK_KEY_x, .x },
    .{ c.GDK_KEY_y, .y },
    .{ c.GDK_KEY_z, .z },

    .{ c.GDK_KEY_0, .zero },
    .{ c.GDK_KEY_1, .one },
    .{ c.GDK_KEY_2, .two },
    .{ c.GDK_KEY_3, .three },
    .{ c.GDK_KEY_4, .four },
    .{ c.GDK_KEY_5, .five },
    .{ c.GDK_KEY_6, .six },
    .{ c.GDK_KEY_7, .seven },
    .{ c.GDK_KEY_8, .eight },
    .{ c.GDK_KEY_9, .nine },

    .{ c.GDK_KEY_semicolon, .semicolon },
    .{ c.GDK_KEY_space, .space },
    .{ c.GDK_KEY_apostrophe, .apostrophe },
    .{ c.GDK_KEY_comma, .comma },
    .{ c.GDK_KEY_grave, .grave_accent },
    .{ c.GDK_KEY_period, .period },
    .{ c.GDK_KEY_slash, .slash },
    .{ c.GDK_KEY_minus, .minus },
    .{ c.GDK_KEY_equal, .equal },
    .{ c.GDK_KEY_bracketleft, .left_bracket },
    .{ c.GDK_KEY_bracketright, .right_bracket },
    .{ c.GDK_KEY_backslash, .backslash },

    .{ c.GDK_KEY_Up, .up },
    .{ c.GDK_KEY_Down, .down },
    .{ c.GDK_KEY_Right, .right },
    .{ c.GDK_KEY_Left, .left },
    .{ c.GDK_KEY_Home, .home },
    .{ c.GDK_KEY_End, .end },
    .{ c.GDK_KEY_Insert, .insert },
    .{ c.GDK_KEY_Delete, .delete },
    .{ c.GDK_KEY_Caps_Lock, .caps_lock },
    .{ c.GDK_KEY_Scroll_Lock, .scroll_lock },
    .{ c.GDK_KEY_Num_Lock, .num_lock },
    .{ c.GDK_KEY_Page_Up, .page_up },
    .{ c.GDK_KEY_Page_Down, .page_down },
    .{ c.GDK_KEY_Escape, .escape },
    .{ c.GDK_KEY_Return, .enter },
    .{ c.GDK_KEY_Tab, .tab },
    .{ c.GDK_KEY_BackSpace, .backspace },
    .{ c.GDK_KEY_Print, .print_screen },
    .{ c.GDK_KEY_Pause, .pause },

    .{ c.GDK_KEY_F1, .f1 },
    .{ c.GDK_KEY_F2, .f2 },
    .{ c.GDK_KEY_F3, .f3 },
    .{ c.GDK_KEY_F4, .f4 },
    .{ c.GDK_KEY_F5, .f5 },
    .{ c.GDK_KEY_F6, .f6 },
    .{ c.GDK_KEY_F7, .f7 },
    .{ c.GDK_KEY_F8, .f8 },
    .{ c.GDK_KEY_F9, .f9 },
    .{ c.GDK_KEY_F10, .f10 },
    .{ c.GDK_KEY_F11, .f11 },
    .{ c.GDK_KEY_F12, .f12 },
    .{ c.GDK_KEY_F13, .f13 },
    .{ c.GDK_KEY_F14, .f14 },
    .{ c.GDK_KEY_F15, .f15 },
    .{ c.GDK_KEY_F16, .f16 },
    .{ c.GDK_KEY_F17, .f17 },
    .{ c.GDK_KEY_F18, .f18 },
    .{ c.GDK_KEY_F19, .f19 },
    .{ c.GDK_KEY_F20, .f20 },
    .{ c.GDK_KEY_F21, .f21 },
    .{ c.GDK_KEY_F22, .f22 },
    .{ c.GDK_KEY_F23, .f23 },
    .{ c.GDK_KEY_F24, .f24 },
    .{ c.GDK_KEY_F25, .f25 },

    .{ c.GDK_KEY_KP_0, .kp_0 },
    .{ c.GDK_KEY_KP_1, .kp_1 },
    .{ c.GDK_KEY_KP_2, .kp_2 },
    .{ c.GDK_KEY_KP_3, .kp_3 },
    .{ c.GDK_KEY_KP_4, .kp_4 },
    .{ c.GDK_KEY_KP_5, .kp_5 },
    .{ c.GDK_KEY_KP_6, .kp_6 },
    .{ c.GDK_KEY_KP_7, .kp_7 },
    .{ c.GDK_KEY_KP_8, .kp_8 },
    .{ c.GDK_KEY_KP_9, .kp_9 },
    .{ c.GDK_KEY_KP_Decimal, .kp_decimal },
    .{ c.GDK_KEY_KP_Divide, .kp_divide },
    .{ c.GDK_KEY_KP_Multiply, .kp_multiply },
    .{ c.GDK_KEY_KP_Subtract, .kp_subtract },
    .{ c.GDK_KEY_KP_Add, .kp_add },
    .{ c.GDK_KEY_KP_Enter, .kp_enter },
    .{ c.GDK_KEY_KP_Equal, .kp_equal },

    .{ c.GDK_KEY_KP_Separator, .kp_separator },
    .{ c.GDK_KEY_KP_Left, .kp_left },
    .{ c.GDK_KEY_KP_Right, .kp_right },
    .{ c.GDK_KEY_KP_Up, .kp_up },
    .{ c.GDK_KEY_KP_Down, .kp_down },
    .{ c.GDK_KEY_KP_Page_Up, .kp_page_up },
    .{ c.GDK_KEY_KP_Page_Down, .kp_page_down },
    .{ c.GDK_KEY_KP_Home, .kp_home },
    .{ c.GDK_KEY_KP_End, .kp_end },
    .{ c.GDK_KEY_KP_Insert, .kp_insert },
    .{ c.GDK_KEY_KP_Delete, .kp_delete },
    .{ c.GDK_KEY_KP_Begin, .kp_begin },

    .{ c.GDK_KEY_Shift_L, .left_shift },
    .{ c.GDK_KEY_Control_L, .left_control },
    .{ c.GDK_KEY_Alt_L, .left_alt },
    .{ c.GDK_KEY_Super_L, .left_super },
    .{ c.GDK_KEY_Shift_R, .right_shift },
    .{ c.GDK_KEY_Control_R, .right_control },
    .{ c.GDK_KEY_Alt_R, .right_alt },
    .{ c.GDK_KEY_Super_R, .right_super },

    // TODO: media keys
};
