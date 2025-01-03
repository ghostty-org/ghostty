const std = @import("std");
const c = @import("c.zig").c;

const Window = @import("Window.zig");
const adwaita = @import("adwaita.zig");

const AdwHeaderBar = if (adwaita.versionAtLeast(0, 0, 0)) c.AdwHeaderBar else void;

pub const HeaderBar = union(enum) {
    adw: *AdwHeaderBar,
    gtk: *c.GtkHeaderBar,

    pub fn init(window: *Window) HeaderBar {
        if ((comptime adwaita.versionAtLeast(1, 4, 0)) and
            adwaita.enabled(&window.app.config))
        {
            return initAdw(window);
        }

        return initGtk();
    }

    fn initAdw(window: *Window) HeaderBar {
        const headerbar = c.adw_header_bar_new();
        c.adw_header_bar_set_title_widget(@ptrCast(headerbar), @ptrCast(c.adw_window_title_new(c.gtk_window_get_title(window.window) orelse "Ghostty", null)));
        return .{ .adw = @ptrCast(headerbar) };
    }

    fn initGtk() HeaderBar {
        const headerbar = c.gtk_header_bar_new();
        return .{ .gtk = @ptrCast(headerbar) };
    }

    pub fn setVisible(self: HeaderBar, visible: bool) void {
        c.gtk_widget_set_visible(self.asWidget(), @intFromBool(visible));
    }

    pub fn asWidget(self: HeaderBar) *c.GtkWidget {
        return switch (self) {
            .adw => |headerbar| @ptrCast(@alignCast(headerbar)),
            .gtk => |headerbar| @ptrCast(@alignCast(headerbar)),
        };
    }

    pub fn packEnd(self: HeaderBar, widget: *c.GtkWidget) void {
        switch (self) {
            .adw => |headerbar| if (comptime adwaita.versionAtLeast(0, 0, 0)) {
                c.adw_header_bar_pack_end(
                    @ptrCast(@alignCast(headerbar)),
                    widget,
                );
            },
            .gtk => |headerbar| c.gtk_header_bar_pack_end(
                @ptrCast(@alignCast(headerbar)),
                widget,
            ),
        }
    }

    pub fn packStart(self: HeaderBar, widget: *c.GtkWidget) void {
        switch (self) {
            .adw => |headerbar| if (comptime adwaita.versionAtLeast(0, 0, 0)) {
                c.adw_header_bar_pack_start(
                    @ptrCast(@alignCast(headerbar)),
                    widget,
                );
            },
            .gtk => |headerbar| c.gtk_header_bar_pack_start(
                @ptrCast(@alignCast(headerbar)),
                widget,
            ),
        }
    }

    pub fn setTitle(self: HeaderBar, title: [:0]const u8) void {
        switch (self) {
            .adw => |headerbar| if (comptime adwaita.versionAtLeast(0, 0, 0)) {
                const window_title: *c.AdwWindowTitle = @ptrCast(c.adw_header_bar_get_title_widget(@ptrCast(headerbar)));
                c.adw_window_title_set_title(window_title, title);
            },
            // The title is owned by the window when not using Adwaita
            .gtk => unreachable,
        }
    }

    pub fn setSubtitle(self: HeaderBar, subtitle: [:0]const u8) void {
        switch (self) {
            .adw => |headerbar| if (comptime adwaita.versionAtLeast(0, 0, 0)) {
                const window_title: *c.AdwWindowTitle = @ptrCast(c.adw_header_bar_get_title_widget(@ptrCast(headerbar)));
                c.adw_window_title_set_subtitle(window_title, subtitle);
            },
            // There is no subtitle unless Adwaita is used
            .gtk => unreachable,
        }
    }
};
