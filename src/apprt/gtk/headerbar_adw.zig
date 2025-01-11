const HeaderBarAdw = @This();

const std = @import("std");
const c = @import("c.zig").c;

const Window = @import("Window.zig");
const adwaita = @import("adwaita.zig");

const HeaderBar = @import("headerbar.zig").HeaderBar;

const AdwHeaderBar = if (adwaita.versionAtLeast(0, 0, 0)) c.AdwHeaderBar else anyopaque;
const AdwWindowTitle = if (adwaita.versionAtLeast(0, 0, 0)) c.AdwWindowTitle else anyopaque;

/// the window that this headerbar is attached to
window: *Window,
/// the Adwaita headerbar widget
headerbar: *AdwHeaderBar,
/// the Adwaita window title widget
title: *AdwWindowTitle,

pub fn init(headerbar: *HeaderBar) void {
    if (!adwaita.versionAtLeast(0, 0, 0)) return;

    const window: *Window = @fieldParentPtr("headerbar", headerbar);
    headerbar.* = .{
        .adw = .{
            .window = window,
            .headerbar = @ptrCast(@alignCast(c.adw_header_bar_new())),
            .title = @ptrCast(@alignCast(c.adw_window_title_new(
                c.gtk_window_get_title(window.window) orelse "Ghostty",
                null,
            ))),
        },
    };
    c.adw_header_bar_set_title_widget(
        headerbar.adw.headerbar,
        @ptrCast(@alignCast(headerbar.adw.title)),
    );
}

pub fn setVisible(self: HeaderBarAdw, visible: bool) void {
    c.gtk_widget_set_visible(self.asWidget(), @intFromBool(visible));
}

pub fn asWidget(self: HeaderBarAdw) *c.GtkWidget {
    return @ptrCast(@alignCast(self.headerbar));
}

pub fn packEnd(self: HeaderBarAdw, widget: *c.GtkWidget) void {
    if (comptime adwaita.versionAtLeast(0, 0, 0)) {
        c.adw_header_bar_pack_end(
            @ptrCast(@alignCast(self.headerbar)),
            widget,
        );
    }
}

pub fn packStart(self: HeaderBarAdw, widget: *c.GtkWidget) void {
    if (comptime adwaita.versionAtLeast(0, 0, 0)) {
        c.adw_header_bar_pack_start(
            @ptrCast(@alignCast(self.headerbar)),
            widget,
        );
    }
}

pub fn setTitle(self: HeaderBarAdw, title: [:0]const u8) void {
    if (comptime adwaita.versionAtLeast(0, 0, 0)) {
        c.adw_window_title_set_title(self.title, title);
    }
}

pub fn setSubtitle(self: HeaderBarAdw, subtitle: [:0]const u8) void {
    if (comptime adwaita.versionAtLeast(0, 0, 0)) {
        c.adw_window_title_set_subtitle(self.title, subtitle);
    }
}
