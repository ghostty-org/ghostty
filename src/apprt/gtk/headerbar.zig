const HeaderBar = @This();

const std = @import("std");
const c = @import("c.zig").c;

const Window = @import("Window.zig");

/// the Adwaita headerbar widget
headerbar: *c.AdwHeaderBar,

/// the Adwaita window title widget
title: *c.AdwWindowTitle,

pub fn init(self: *HeaderBar) void {
    const window: *Window = @fieldParentPtr("headerbar", self);
    self.* = .{
        .headerbar = @ptrCast(@alignCast(c.adw_header_bar_new())),
        .title = @ptrCast(@alignCast(c.adw_window_title_new(
            c.gtk_window_get_title(window.window) orelse "Ghostty",
            null,
        ))),
    };
    c.adw_header_bar_set_title_widget(
        self.headerbar,
        @ptrCast(@alignCast(self.title)),
    );
}

pub fn setVisible(self: *const HeaderBar, visible: bool) void {
    c.gtk_widget_set_visible(self.asWidget(), @intFromBool(visible));
}

pub fn asWidget(self: *const HeaderBar) *c.GtkWidget {
    return @ptrCast(@alignCast(self.headerbar));
}

pub fn packEnd(self: *const HeaderBar, widget: *c.GtkWidget) void {
    c.adw_header_bar_pack_end(
        @ptrCast(@alignCast(self.headerbar)),
        widget,
    );
}

pub fn packStart(self: *const HeaderBar, widget: *c.GtkWidget) void {
    c.adw_header_bar_pack_start(
        @ptrCast(@alignCast(self.headerbar)),
        widget,
    );
}

pub fn setTitle(self: *const HeaderBar, title: [:0]const u8) void {
    const window: *const Window = @fieldParentPtr("headerbar", self);
    c.gtk_window_set_title(window.window, title);
    c.adw_window_title_set_title(self.title, title);
}

pub fn setSubtitle(self: *const HeaderBar, subtitle: [:0]const u8) void {
    c.adw_window_title_set_subtitle(self.title, subtitle);
}
