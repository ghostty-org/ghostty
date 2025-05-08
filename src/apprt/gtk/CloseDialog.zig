const CloseDialog = @This();
const std = @import("std");

const gobject = @import("gobject");
const gio = @import("gio");
const adw = @import("adw");
const gtk = @import("gtk");

const i18n = @import("../../os/main.zig").i18n;
const App = @import("App.zig");
const Window = @import("Window.zig");
const Tab = @import("Tab.zig");
const Surface = @import("Surface.zig");
const adwaita = @import("adw_version.zig");

const log = std.log.scoped(.close_dialog);

// We don't fall back to the GTK Message/AlertDialogs since
// we don't plan to support libadw < 1.2 as of time of writing
// TODO: Switch to just adw.AlertDialog when we drop Debian 12 support
const DialogType = if (adwaita.supportsDialogs()) adw.AlertDialog else adw.MessageDialog;

/// Open the dialog when the user requests to close a window/tab/split/etc.
/// but there's still one or more running processes inside the target that
/// cannot be closed automatically. We then ask the user whether they want
/// to terminate existing processes.
pub fn show(target: Target) !void {
    // If we don't have a possible window to ask the user,
    // in most situations (e.g. when a split isn't attached to a window)
    // we should just close unconditionally.
    const dialog_window = target.dialogWindow() orelse {
        target.close();
        return;
    };

    const dialog = switch (DialogType) {
        adw.AlertDialog => adw.AlertDialog.new(target.title(), target.body()),
        adw.MessageDialog => adw.MessageDialog.new(dialog_window, target.title(), target.body()),
        else => unreachable,
    };

    // AlertDialog and MessageDialog have essentially the same API,
    // so we can cheat a little here
    dialog.addResponse("cancel", i18n._("Cancel"));
    dialog.setCloseResponse("cancel");

    dialog.addResponse("close", i18n._("Close"));
    dialog.setResponseAppearance("close", .destructive);

    // Need a stable pointer
    const target_ptr = try target.allocator().create(Target);
    target_ptr.* = target;

    _ = DialogType.signals.response.connect(dialog, *Target, responseCallback, target_ptr, .{});

    switch (DialogType) {
        adw.AlertDialog => dialog.as(adw.Dialog).present(dialog_window.as(gtk.Widget)),
        adw.MessageDialog => dialog.as(gtk.Window).present(),
        else => unreachable,
    }
}

fn responseCallback(
    _: *DialogType,
    response: [*:0]const u8,
    target: *Target,
) callconv(.c) void {
    const alloc = target.allocator();
    defer alloc.destroy(target);

    if (std.mem.orderZ(u8, response, "close") == .eq) target.close();
}

/// The target of a close dialog.
///
/// This is here so that we can consolidate all logic related to
/// prompting the user and closing windows/tabs/surfaces/etc.
/// together into one struct that is the sole source of truth.
pub const Target = union(enum) {
    app: *App,
    window: *Window,
    tab: *Tab,
    surface: *Surface,

    pub fn title(self: Target) [*:0]const u8 {
        return switch (self) {
            .app => i18n._("Quit Ghostty?"),
            .window => i18n._("Close Window?"),
            .tab => i18n._("Close Tab?"),
            .surface => i18n._("Close Split?"),
        };
    }

    pub fn body(self: Target) [*:0]const u8 {
        return switch (self) {
            .app => i18n._("All terminal sessions will be terminated."),
            .window => i18n._("All terminal sessions in this window will be terminated."),
            .tab => i18n._("All terminal sessions in this tab will be terminated."),
            .surface => i18n._("The currently running process in this split will be terminated."),
        };
    }

    pub fn dialogWindow(self: Target) ?*gtk.Window {
        return switch (self) {
            .app => {
                // Find the currently focused window. We don't store this
                // anywhere inside the App structure for some reason, so
                // we have to query every single open window and see which
                // one is active (focused and receiving keyboard input)
                const list = gtk.Window.listToplevels();
                defer list.free();

                const focused = list.findCustom(null, findActiveWindow);
                return @ptrCast(@alignCast(focused.f_data));
            },
            .window => |v| v.window.as(gtk.Window),
            .tab => |v| v.window.window.as(gtk.Window),
            .surface => |v| {
                const window_ = v.container.window() orelse return null;
                return window_.window.as(gtk.Window);
            },
        };
    }

    fn allocator(self: Target) std.mem.Allocator {
        return switch (self) {
            .app => |v| v.core_app.alloc,
            .window => |v| v.app.core_app.alloc,
            .tab => |v| v.window.app.core_app.alloc,
            .surface => |v| v.app.core_app.alloc,
        };
    }

    fn close(self: Target) void {
        switch (self) {
            .app => |v| v.quitNow(),
            .window => |v| v.window.as(gtk.Window).destroy(),
            .tab => |v| v.remove(),
            .surface => |v| v.container.remove(),
        }
    }
};

fn findActiveWindow(data: ?*const anyopaque, _: ?*const anyopaque) callconv(.c) c_int {
    const window: *gtk.Window = @ptrCast(@alignCast(@constCast(data orelse return -1)));

    // Confusingly, `isActive` returns 1 when active,
    // but we want to return 0 to indicate equality.
    // Abusing integers to be enums and booleans is a terrible idea, C.
    return if (window.isActive() != 0) 0 else -1;
}
