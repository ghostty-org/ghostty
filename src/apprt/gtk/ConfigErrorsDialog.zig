/// Configuration errors window.
const ConfigErrorsDialog = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const gobject = @import("gobject");
const gio = @import("gio");
const gtk = @import("gtk");
const adw = @import("adw");

const build_config = @import("../../build_config.zig");
const configpkg = @import("../../config.zig");
const Config = configpkg.Config;

const App = @import("App.zig");
const Window = @import("Window.zig");
const Builder = @import("Builder.zig");
const adw_version = @import("adw_version.zig");

const log = std.log.scoped(.gtk);

const DialogType = if (adw_version.supportsDialogs()) adw.AlertDialog else adw.MessageDialog;

builder: Builder,
dialog: *DialogType,
error_message: *gtk.TextBuffer,

pub fn maybePresent(app: *App, window: ?*Window) void {
    if (app.config._diagnostics.empty()) return;

    var builder = switch (DialogType) {
        adw.AlertDialog => Builder.init("config-errors-dialog", 1, 5),
        adw.MessageDialog => Builder.init("config-errors-dialog", 1, 2),
        else => unreachable,
    };
    defer builder.deinit();

    const dialog = builder.getObject(DialogType, "config_errors_dialog").?;
    const error_message = builder.getObject(gtk.TextBuffer, "error_message").?;

    var msg_buf: [4095:0]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&msg_buf);

    for (app.config._diagnostics.items()) |diag| {
        fbs.reset();
        diag.write(fbs.writer()) catch |err| {
            log.warn(
                "error writing diagnostic to buffer err={}",
                .{err},
            );
            continue;
        };

        error_message.insertAtCursor(&msg_buf, @intCast(fbs.pos));
        error_message.insertAtCursor("\n", 1);
    }

    _ = DialogType.signals.response.connect(dialog, *App, onResponse, app, .{});

    const parent = if (window) |w| w.window.as(gtk.Widget) else null;

    switch (DialogType) {
        adw.AlertDialog => dialog.as(adw.Dialog).present(parent),
        adw.MessageDialog => dialog.as(gtk.Window).present(),
        else => unreachable,
    }
}

fn onResponse(_: *DialogType, response: [*:0]const u8, app: *App) callconv(.C) void {
    if (std.mem.orderZ(u8, response, "reload") == .eq) {
        app.reloadConfig(.app, .{}) catch |err| {
            log.warn("error reloading config error={}", .{err});
            return;
        };
    }
}
