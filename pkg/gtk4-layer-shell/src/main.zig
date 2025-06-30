const std = @import("std");

const c = @cImport({
    @cInclude("gtk4-layer-shell.h");
});
const gtk = @import("gtk");

pub const ShellLayer = enum(c_uint) {
    background = c.GTK_LAYER_SHELL_LAYER_BACKGROUND,
    bottom = c.GTK_LAYER_SHELL_LAYER_BOTTOM,
    top = c.GTK_LAYER_SHELL_LAYER_TOP,
    overlay = c.GTK_LAYER_SHELL_LAYER_OVERLAY,
};

pub const ShellEdge = enum(c_uint) {
    left = c.GTK_LAYER_SHELL_EDGE_LEFT,
    right = c.GTK_LAYER_SHELL_EDGE_RIGHT,
    top = c.GTK_LAYER_SHELL_EDGE_TOP,
    bottom = c.GTK_LAYER_SHELL_EDGE_BOTTOM,
};

pub const KeyboardMode = enum(c_uint) {
    none = c.GTK_LAYER_SHELL_KEYBOARD_MODE_NONE,
    exclusive = c.GTK_LAYER_SHELL_KEYBOARD_MODE_EXCLUSIVE,
    on_demand = c.GTK_LAYER_SHELL_KEYBOARD_MODE_ON_DEMAND,
};

pub fn isSupported() bool {
    return c.gtk_layer_is_supported() != 0;
}

pub fn getProtocolVersion() c_uint {
    return c.gtk_layer_get_protocol_version();
}

pub fn getLibraryVersion() std.SemanticVersion {
    return .{
        .major = c.gtk_layer_get_major_version(),
        .minor = c.gtk_layer_get_minor_version(),
        .patch = c.gtk_layer_get_micro_version(),
    };
}

pub fn initForWindow(window: *gtk.Window) void {
    c.gtk_layer_init_for_window(@ptrCast(window));
}

pub fn setLayer(window: *gtk.Window, layer: ShellLayer) void {
    c.gtk_layer_set_layer(@ptrCast(window), @intFromEnum(layer));
}

pub fn setAnchor(window: *gtk.Window, edge: ShellEdge, anchor_to_edge: bool) void {
    c.gtk_layer_set_anchor(@ptrCast(window), @intFromEnum(edge), @intFromBool(anchor_to_edge));
}

pub fn setMargin(window: *gtk.Window, edge: ShellEdge, margin_size: c_int) void {
    c.gtk_layer_set_margin(@ptrCast(window), @intFromEnum(edge), margin_size);
}

pub fn setKeyboardMode(window: *gtk.Window, mode: KeyboardMode) void {
    c.gtk_layer_set_keyboard_mode(@ptrCast(window), @intFromEnum(mode));
}

pub fn setNamespace(window: *gtk.Window, name: [:0]const u8) void {
    c.gtk_layer_set_namespace(@ptrCast(window), name.ptr);
}
