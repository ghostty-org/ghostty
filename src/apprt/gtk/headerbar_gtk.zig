const HeaderBarGtk = @This();

const std = @import("std");
const c = @import("c.zig").c;

const Window = @import("Window.zig");
const adwaita = @import("adwaita.zig");

const HeaderBar = @import("headerbar.zig").HeaderBar;

/// the window that this headarbar is attached to
window: *Window,
/// the GTK headerbar widget
headerbar: *c.GtkHeaderBar,

pub fn init(headerbar: *HeaderBar) void {
    const window: *Window = @fieldParentPtr("headerbar", headerbar);
    headerbar.* = .{
        .gtk = .{
            .window = window,
            .headerbar = @ptrCast(c.gtk_header_bar_new()),
        },
    };
}

pub fn setVisible(self: HeaderBarGtk, visible: bool) void {
    c.gtk_widget_set_visible(self.asWidget(), @intFromBool(visible));
}

pub fn asWidget(self: HeaderBarGtk) *c.GtkWidget {
    return @ptrCast(@alignCast(self.headerbar));
}

pub fn packEnd(self: HeaderBarGtk, widget: *c.GtkWidget) void {
    c.gtk_header_bar_pack_end(
        @ptrCast(@alignCast(self.headerbar)),
        widget,
    );
}

pub fn packStart(self: HeaderBarGtk, widget: *c.GtkWidget) void {
    c.gtk_header_bar_pack_start(
        @ptrCast(@alignCast(self.headerbar)),
        widget,
    );
}

pub fn setTitle(self: HeaderBarGtk, title: [:0]const u8) void {
    c.gtk_window_set_title(self.window.window, title);
}

pub fn setSubtitle(_: HeaderBarGtk, _: [:0]const u8) void {}
