/// Clipboard Confirmation Window
const ClipboardConfirmation = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const gtk = @import("gtk");
const adw = @import("adw");
const gobject = @import("gobject");
const gio = @import("gio");

const apprt = @import("../../apprt.zig");
const CoreSurface = @import("../../Surface.zig");
const App = @import("App.zig");
const Builder = @import("Builder.zig");
const adw_version = @import("adw_version.zig");

const log = std.log.scoped(.gtk);

const DialogType = if (adw_version.atLeast(1, 5, 0)) adw.AlertDialog else adw.MessageDialog;

app: *App,
dialog: *DialogType,
data: [:0]u8,
core_surface: *CoreSurface,
pending_req: apprt.ClipboardRequest,
text_view: *gtk.TextView,
text_view_scroll: *gtk.ScrolledWindow,
reveal_button: *gtk.Button,
hide_button: *gtk.Button,

pub fn create(
    app: *App,
    data: []const u8,
    core_surface: *CoreSurface,
    request: apprt.ClipboardRequest,
    is_secure_input: bool,
) !void {
    if (app.clipboard_confirmation_window != null) return error.WindowAlreadyExists;

    const alloc = app.core_app.alloc;
    const self = try alloc.create(ClipboardConfirmation);
    errdefer alloc.destroy(self);

    try self.init(
        app,
        data,
        core_surface,
        request,
        is_secure_input,
    );

    app.clipboard_confirmation_window = self;
}

/// Not public because this should be called by the GTK lifecycle.
fn destroy(self: *ClipboardConfirmation) void {
    const alloc = self.app.core_app.alloc;
    self.app.clipboard_confirmation_window = null;
    alloc.free(self.data);
    alloc.destroy(self);
}

fn init(
    self: *ClipboardConfirmation,
    app: *App,
    data: []const u8,
    core_surface: *CoreSurface,
    request: apprt.ClipboardRequest,
    is_secure_input: bool,
) !void {
    var builder = switch (DialogType) {
        adw.AlertDialog => switch (request) {
            .osc_52_read => Builder.init("ccw-osc-52-read", 1, 5, .blp),
            .osc_52_write => Builder.init("ccw-osc-52-write", 1, 5, .blp),
            .paste => Builder.init("ccw-paste", 1, 5, .blp),
        },
        adw.MessageDialog => switch (request) {
            .osc_52_read => Builder.init("ccw-osc-52-read", 1, 2, .ui),
            .osc_52_write => Builder.init("ccw-osc-52-write", 1, 2, .ui),
            .paste => Builder.init("ccw-paste", 1, 2, .ui),
        },
        else => unreachable,
    };
    defer builder.deinit();

    const dialog = builder.getObject(DialogType, "clipboard_confirmation_window").?;
    const text_view = builder.getObject(gtk.TextView, "text_view").?;
    const reveal_button = builder.getObject(gtk.Button, "reveal_button").?;
    const hide_button = builder.getObject(gtk.Button, "hide_button").?;
    const text_view_scroll = builder.getObject(gtk.ScrolledWindow, "text_view_scroll").?;

    const copy = try app.core_app.alloc.dupeZ(u8, data);
    errdefer app.core_app.alloc.free(copy);
    self.* = .{
        .app = app,
        .dialog = dialog,
        .data = copy,
        .core_surface = core_surface,
        .pending_req = request,
        .text_view = text_view,
        .text_view_scroll = text_view_scroll,
        .reveal_button = reveal_button,
        .hide_button = hide_button,
    };

    const buffer = gtk.TextBuffer.new(null);
    errdefer buffer.unref();
    buffer.insertAtCursor(copy.ptr, @intCast(copy.len));
    text_view.setBuffer(buffer);

    if (is_secure_input) {
        text_view_scroll.as(gtk.Widget).setSensitive(@intFromBool(false));
        self.text_view.as(gtk.Widget).addCssClass("blurred");

        self.reveal_button.as(gtk.Widget).setVisible(@intFromBool(true));

        _ = gtk.Button.signals.clicked.connect(
            reveal_button,
            *ClipboardConfirmation,
            gtkRevealButtonClicked,
            self,
            .{},
        );
        _ = gtk.Button.signals.clicked.connect(
            hide_button,
            *ClipboardConfirmation,
            gtkHideButtonClicked,
            self,
            .{},
        );
    }

    switch (DialogType) {
        adw.AlertDialog => {
            const parent: ?*gtk.Widget = widget: {
                const window = core_surface.rt_surface.container.window() orelse break :widget null;
                break :widget @ptrCast(@alignCast(window.window));
            };

            dialog.choose(parent, null, gtkChoose, self);
        },
        adw.MessageDialog => {
            if (adw_version.atLeast(1, 3, 0)) {
                dialog.choose(null, gtkChoose, self);
            } else {
                _ = adw.MessageDialog.signals.response.connect(
                    dialog,
                    *ClipboardConfirmation,
                    gtkResponse,
                    self,
                    .{},
                );
                dialog.as(gtk.Widget).show();
            }
        },
        else => unreachable,
    }
}

fn gtkChoose(dialog_: ?*gobject.Object, result: *gio.AsyncResult, ud: ?*anyopaque) callconv(.C) void {
    const dialog = gobject.ext.cast(DialogType, dialog_.?).?;
    const self: *ClipboardConfirmation = @ptrCast(@alignCast(ud.?));
    const response = dialog.chooseFinish(result);
    if (std.mem.orderZ(u8, response, "ok") == .eq) {
        self.core_surface.completeClipboardRequest(
            self.pending_req,
            self.data,
            true,
        ) catch |err| {
            log.err("Failed to requeue clipboard request: {}", .{err});
        };
    }
    self.destroy();
}

fn gtkResponse(_: *DialogType, response: [*:0]u8, self: *ClipboardConfirmation) callconv(.C) void {
    if (std.mem.orderZ(u8, response, "ok") == .eq) {
        self.core_surface.completeClipboardRequest(
            self.pending_req,
            self.data,
            true,
        ) catch |err| {
            log.err("Failed to requeue clipboard request: {}", .{err});
        };
    }
    self.destroy();
}

fn gtkRevealButtonClicked(_: *gtk.Button, self: *ClipboardConfirmation) callconv(.C) void {
    self.text_view_scroll.as(gtk.Widget).setSensitive(@intFromBool(true));
    self.text_view.as(gtk.Widget).removeCssClass("blurred");

    self.hide_button.as(gtk.Widget).setVisible(@intFromBool(true));
    self.reveal_button.as(gtk.Widget).setVisible(@intFromBool(false));
}

fn gtkHideButtonClicked(_: *gtk.Button, self: *ClipboardConfirmation) callconv(.C) void {
    self.text_view_scroll.as(gtk.Widget).setSensitive(@intFromBool(false));
    self.text_view.as(gtk.Widget).addCssClass("blurred");

    self.hide_button.as(gtk.Widget).setVisible(@intFromBool(false));
    self.reveal_button.as(gtk.Widget).setVisible(@intFromBool(true));
}
