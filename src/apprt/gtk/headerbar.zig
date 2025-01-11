const std = @import("std");
const c = @import("c.zig").c;

const Window = @import("Window.zig");
const adwaita = @import("adwaita.zig");

const HeaderBarAdw = @import("headerbar_adw.zig");
const HeaderBarGtk = @import("headerbar_gtk.zig");

pub const HeaderBar = union(enum) {
    adw: HeaderBarAdw,
    gtk: HeaderBarGtk,

    pub fn init(self: *HeaderBar) void {
        const window: *Window = @fieldParentPtr("headerbar", self);
        if ((comptime adwaita.versionAtLeast(1, 4, 0)) and adwaita.enabled(&window.app.config)) {
            HeaderBarAdw.init(self);
        } else {
            HeaderBarGtk.init(self);
        }

        if (!window.app.config.@"gtk-titlebar" or !window.app.config.@"window-decoration")
            self.setVisible(false);
    }

    pub fn setVisible(self: HeaderBar, visible: bool) void {
        switch (self) {
            inline else => |v| v.setVisible(visible),
        }
    }

    pub fn asWidget(self: HeaderBar) *c.GtkWidget {
        return switch (self) {
            inline else => |v| v.asWidget(),
        };
    }

    pub fn packEnd(self: HeaderBar, widget: *c.GtkWidget) void {
        switch (self) {
            inline else => |v| v.packEnd(widget),
        }
    }

    pub fn packStart(self: HeaderBar, widget: *c.GtkWidget) void {
        switch (self) {
            inline else => |v| v.packStart(widget),
        }
    }

    pub fn setTitle(self: HeaderBar, title: [:0]const u8) void {
        switch (self) {
            inline else => |v| v.setTitle(title),
        }
    }

    pub fn setSubtitle(self: HeaderBar, subtitle: [:0]const u8) void {
        switch (self) {
            inline else => |v| v.setSubtitle(subtitle),
        }
    }
};
