const std = @import("std");
const build_options = @import("terminal_options");
const lib = @import("../lib/main.zig");
const lib_target: lib.Target = if (build_options.c_abi) .c else .zig;

/// The event types that can be reported for mouse-related activities.
/// These are all mutually exclusive (hence in a single enum).
pub const Event = lib.Enum(lib_target, &.{
    "none",
    "x10", // 9
    "normal", // 1000
    "button", // 1002
    "any", // 1003
});

/// Returns true if this event sends motion events.
pub fn eventSendsMotion(event: Event) bool {
    return event == .button or event == .any;
}

/// The format of mouse events when enabled.
/// These are all mutually exclusive (hence in a single enum).
pub const Format = lib.Enum(lib_target, &.{
    "x10",
    "utf8", // 1005
    "sgr", // 1006
    "urxvt", // 1015
    "sgr_pixels", // 1016
});

/// The possible cursor shapes. Not all app runtimes support these shapes.
/// The shapes are always based on the W3C supported cursor styles so we
/// can have a cross platform list.
//
// Must be kept in sync with ghostty_cursor_shape_e
pub const Shape = enum(c_int) {
    default,
    context_menu,
    help,
    pointer,
    progress,
    wait,
    cell,
    crosshair,
    text,
    vertical_text,
    alias,
    copy,
    move,
    no_drop,
    not_allowed,
    grab,
    grabbing,
    all_scroll,
    col_resize,
    row_resize,
    n_resize,
    e_resize,
    s_resize,
    w_resize,
    ne_resize,
    nw_resize,
    se_resize,
    sw_resize,
    ew_resize,
    ns_resize,
    nesw_resize,
    nwse_resize,
    zoom_in,
    zoom_out,

    /// Build cursor shape from string or null if its unknown.
    pub fn fromString(v: []const u8) ?Shape {
        return string_map.get(v);
    }

    /// Make this a valid gobject if we're in a GTK environment.
    pub const getGObjectType = gtk: {
        switch (build_options.artifact) {
            .ghostty => {},
            .lib => break :gtk void,
        }

        break :gtk switch (@import("../build_config.zig").app_runtime) {
            .gtk => @import("gobject").ext.defineEnum(
                Shape,
                .{ .name = "GhosttyMouseShape" },
            ),

            .none => void,
        };
    };

    test "ghostty.h MouseShape" {
        try lib.checkGhosttyHEnum(Shape, "GHOSTTY_MOUSE_SHAPE_");
    }
};

const string_map = std.StaticStringMap(Shape).initComptime(.{
    // W3C
    .{ "default", .default },
    .{ "context-menu", .context_menu },
    .{ "help", .help },
    .{ "pointer", .pointer },
    .{ "progress", .progress },
    .{ "wait", .wait },
    .{ "cell", .cell },
    .{ "crosshair", .crosshair },
    .{ "text", .text },
    .{ "vertical-text", .vertical_text },
    .{ "alias", .alias },
    .{ "copy", .copy },
    .{ "move", .move },
    .{ "no-drop", .no_drop },
    .{ "not-allowed", .not_allowed },
    .{ "grab", .grab },
    .{ "grabbing", .grabbing },
    .{ "all-scroll", .all_scroll },
    .{ "col-resize", .col_resize },
    .{ "row-resize", .row_resize },
    .{ "n-resize", .n_resize },
    .{ "e-resize", .e_resize },
    .{ "s-resize", .s_resize },
    .{ "w-resize", .w_resize },
    .{ "ne-resize", .ne_resize },
    .{ "nw-resize", .nw_resize },
    .{ "se-resize", .se_resize },
    .{ "sw-resize", .sw_resize },
    .{ "ew-resize", .ew_resize },
    .{ "ns-resize", .ns_resize },
    .{ "nesw-resize", .nesw_resize },
    .{ "nwse-resize", .nwse_resize },
    .{ "zoom-in", .zoom_in },
    .{ "zoom-out", .zoom_out },

    // xterm/foot
    .{ "left_ptr", .default },
    .{ "question_arrow", .help },
    .{ "hand", .pointer },
    .{ "left_ptr_watch", .progress },
    .{ "watch", .wait },
    .{ "cross", .crosshair },
    .{ "xterm", .text },
    .{ "dnd-link", .alias },
    .{ "dnd-copy", .copy },
    .{ "dnd-move", .move },
    .{ "dnd-no-drop", .no_drop },
    .{ "crossed_circle", .not_allowed },
    .{ "hand1", .grab },
    .{ "right_side", .e_resize },
    .{ "top_side", .n_resize },
    .{ "top_right_corner", .ne_resize },
    .{ "top_left_corner", .nw_resize },
    .{ "bottom_side", .s_resize },
    .{ "bottom_right_corner", .se_resize },
    .{ "bottom_left_corner", .sw_resize },
    .{ "left_side", .w_resize },
    .{ "fleur", .all_scroll },
});

test "cursor shape from string" {
    const testing = std.testing;
    try testing.expectEqual(Shape.default, Shape.fromString("default").?);
}

test {
    _ = std.testing.refAllDeclsRecursive(@This());
}
