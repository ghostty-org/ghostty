const RenameTabAdw = @This();

const std = @import("std");
const assert = std.debug.assert;

const c = @import("c.zig").c;
const Builder = @import("Builder.zig");
const Tab = @import("Tab.zig");
const NotebookAdw = @import("notebook_adw.zig").NotebookAdw;

const log = std.log.scoped(.gtk_rename_tab);

tab: ?*Tab = null,
dialog: ?*c.AdwDialog = null,
title: ?*c.AdwEntryRow = null,

pub fn init(self: *RenameTabAdw) void {
    self.* = .{};
}

pub fn deinit(self: *RenameTabAdw) void {
    if (self.dialog) |dialog| {
        _ = c.adw_dialog_close(dialog);
    }
}

pub fn show(self: *RenameTabAdw, tab: *Tab) void {
    if (self.tab) |old_tab| {
        if (old_tab == tab) {
            if (self.dialog) |dialog| {
                c.gtk_window_present(@ptrCast(@alignCast(dialog)));
                return;
            }
        }
    }

    if (self.dialog) |dialog| {
        _ = c.adw_dialog_close(dialog);
    }

    self.* = .{};

    assert(tab.window.notebook == .adw);

    const builder = Builder.init("window-adw-rename-tab");
    defer builder.deinit();

    const dialog = builder.getObject(c.AdwDialog, "rename-tab");

    const title = builder.getObject(c.AdwEntryRow, "title");

    if (tab.manual_title) |manual_label| {
        var value: c.GValue = std.mem.zeroes(c.GValue);
        defer c.g_value_unset(&value);
        _ = c.g_value_init(&value, c.G_TYPE_STRING);
        c.g_value_set_string(&value, manual_label.ptr);
        c.g_object_set_property(@ptrCast(@alignCast(title)), "text", &value);
    }

    self.* = .{
        .tab = tab,
        .dialog = dialog,
        .title = title,
    };

    _ = c.g_signal_connect_data(dialog, "closed", c.G_CALLBACK(&adwDialogClosed), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(title, "apply", c.G_CALLBACK(&adwEntryRowApply), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(title, "entry-activated", c.G_CALLBACK(&adwEntryRowApply), self, null, c.G_CONNECT_DEFAULT);

    c.adw_dialog_present(dialog, @ptrCast(@alignCast(tab.box)));
}

fn adwDialogClosed(dialog: *c.AdwDialog, ud: ?*anyopaque) callconv(.C) void {
    const self: *RenameTabAdw = @ptrCast(@alignCast(ud orelse return));

    assert(dialog == self.dialog);

    if (self.tab) |tab| {
        tab.window.focusCurrentTab();
    }

    self.* = .{};
}

fn adwEntryRowApply(
    _: *c.GObject,
    ud: ?*anyopaque,
) callconv(.C) void {
    const self: *RenameTabAdw = @ptrCast(@alignCast(ud orelse return));
    const tab = self.tab orelse return;
    const title = self.title orelse return;

    var value: c.GValue = std.mem.zeroes(c.GValue);
    defer c.g_value_unset(&value);
    _ = c.g_value_init(&value, c.G_TYPE_STRING);
    c.g_object_get_property(@ptrCast(@alignCast(title)), "text", &value);

    const text = c.g_value_get_string(&value);

    tab.setManualTitle(std.mem.span(text));

    _ = c.adw_dialog_close(self.dialog);
}

fn adwEntryRowEntryActivated(
    _: *c.GObject,
    ud: ?*anyopaque,
) callconv(.C) void {
    const self: *RenameTabAdw = @ptrCast(@alignCast(ud orelse return));
    const tab = self.tab orelse return;
    const title = self.title orelse return;

    var value: c.GValue = std.mem.zeroes(c.GValue);
    defer c.g_value_unset(&value);
    _ = c.g_value_init(&value, c.G_TYPE_STRING);

    c.g_object_get_property(@ptrCast(@alignCast(title)), "text", &value);

    const text = c.g_value_get_string(&value);

    tab.setManualTitle(std.mem.span(text));

    _ = c.adw_dialog_close(self.dialog);
}
