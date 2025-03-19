const HeaderBar = @This();

const std = @import("std");

const adw = @import("adw");
const gtk = @import("gtk");

const Window = @import("Window.zig");

/// the Adwaita headerbar widget
headerbar: *adw.HeaderBar,

/// the Window that we belong to
window: *Window,

/// the Adwaita window title widget
title: *adw.WindowTitle,

pub fn init(self: *HeaderBar, window: *Window) void {
    self.* = .{
        .headerbar = adw.HeaderBar.new(),
        .window = window,
        .title = adw.WindowTitle.new(
            window.window.as(gtk.Window).getTitle() orelse "Ghostty",
            "",
        ),
    };
    self.headerbar.setTitleWidget(self.title.as(gtk.Widget));
}

pub fn setVisible(self: *const HeaderBar, visible: bool) void {
    self.headerbar.as(gtk.Widget).setVisible(@intFromBool(visible));
}

pub fn asWidget(self: *const HeaderBar) *gtk.Widget {
    return self.headerbar.as(gtk.Widget);
}

pub fn packEnd(self: *const HeaderBar, widget: *gtk.Widget) void {
    self.headerbar.packEnd(widget);
}

pub fn packStart(self: *const HeaderBar, widget: *gtk.Widget) void {
    self.headerbar.packStart(widget);
}

pub fn setTitle(self: *const HeaderBar, title: [:0]const u8) void {
    self.window.window.as(gtk.Window).setTitle(title);
    self.title.setTitle(title);
}

pub fn setSubtitle(self: *const HeaderBar, subtitle: [:0]const u8) void {
    self.title.setSubtitle(subtitle);
}
