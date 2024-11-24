/// Configuration errors window.
const ConfigErrors = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const configpkg = @import("../../config.zig");
const Config = configpkg.Config;

const App = @import("App.zig");
const View = @import("View.zig");
const c = @import("c.zig").c;

const log = std.log.scoped(.gtk);

app: *App,
window: *c.GtkWindow,
view: PrimaryView,

pub fn create(app: *App) !void {
    if (app.config_errors_window != null) return error.InvalidOperation;

    const alloc = app.core_app.alloc;
    const self = try alloc.create(ConfigErrors);
    errdefer alloc.destroy(self);
    try self.init(app);

    app.config_errors_window = self;
}

pub fn update(self: *ConfigErrors) void {
    if (self.app.config._diagnostics.empty()) {
        c.gtk_window_destroy(@ptrCast(self.window));
        return;
    }

    self.view.update(&self.app.config);
    _ = c.gtk_window_present(self.window);
    _ = c.gtk_widget_grab_focus(@ptrCast(self.window));
}

/// Not public because this should be called by the GTK lifecycle.
fn destroy(self: *ConfigErrors) void {
    const alloc = self.app.core_app.alloc;
    self.app.config_errors_window = null;
    alloc.destroy(self);
}

fn init(self: *ConfigErrors, app: *App) !void {
    // Create the window
    const window = c.gtk_window_new();
    const gtk_window: *c.GtkWindow = @ptrCast(window);
    errdefer c.gtk_window_destroy(gtk_window);
    c.gtk_window_set_title(gtk_window, "Configuration Errors");
    c.gtk_window_set_default_size(gtk_window, 600, 275);
    c.gtk_window_set_resizable(gtk_window, 0);
    c.gtk_window_set_icon_name(gtk_window, "com.mitchellh.ghostty");
    _ = c.g_signal_connect_data(window, "destroy", c.G_CALLBACK(&gtkDestroy), self, null, c.G_CONNECT_DEFAULT);

    // Set some state
    self.* = .{
        .app = app,
        .window = gtk_window,
        .view = undefined,
    };

    // Show the window
    const view = try PrimaryView.init(self);
    self.view = view;
    c.gtk_window_set_child(@ptrCast(window), view.root);
    c.gtk_widget_show(window);
}

fn gtkDestroy(_: *c.GtkWidget, ud: ?*anyopaque) callconv(.C) void {
    const self = userdataSelf(ud.?);
    self.destroy();
}

fn userdataSelf(ud: *anyopaque) *ConfigErrors {
    return @ptrCast(@alignCast(ud));
}

const PrimaryView = struct {
    root: *c.GtkWidget,
    text: *c.GtkTextView,

    pub fn init(root: *ConfigErrors) !PrimaryView {
        // All our widgets
        const label = c.gtk_label_new(
            "One or more configuration errors were found while loading " ++
                "the configuration. Please review the errors below and reload " ++
                "your configuration or ignore the erroneous lines.",
        );
        const buf = contentsBuffer(&root.app.config);
        defer c.g_object_unref(buf);
        const buttons = try ButtonsView.init(root);
        const text_scroll = c.gtk_scrolled_window_new();
        errdefer c.g_object_unref(text_scroll);
        const text = c.gtk_text_view_new_with_buffer(buf);
        errdefer c.g_object_unref(text);
        c.gtk_scrolled_window_set_child(@ptrCast(text_scroll), text);

        // Create our view
        const view = try View.init(&.{
            .{ .name = "label", .widget = label },
            .{ .name = "text", .widget = text_scroll },
            .{ .name = "buttons", .widget = buttons.root },
        }, &vfl);
        errdefer view.deinit();

        // We can do additional settings once the layout is setup
        c.gtk_label_set_wrap(@ptrCast(label), 1);
        c.gtk_text_view_set_editable(@ptrCast(text), 0);
        c.gtk_text_view_set_cursor_visible(@ptrCast(text), 0);
        c.gtk_text_view_set_top_margin(@ptrCast(text), 8);
        c.gtk_text_view_set_bottom_margin(@ptrCast(text), 8);
        c.gtk_text_view_set_left_margin(@ptrCast(text), 8);
        c.gtk_text_view_set_right_margin(@ptrCast(text), 8);

        return .{ .root = view.root, .text = @ptrCast(text) };
    }

    pub fn update(self: *PrimaryView, config: *const Config) void {
        const buf = contentsBuffer(config);
        defer c.g_object_unref(buf);
        c.gtk_text_view_set_buffer(@ptrCast(self.text), buf);
    }

    /// Returns the GtkTextBuffer for the config errors that we want to show.
    fn contentsBuffer(config: *const Config) *c.GtkTextBuffer {
        const buf = c.gtk_text_buffer_new(null);
        errdefer c.g_object_unref(buf);

        var msg_buf: [4096]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&msg_buf);

        for (config._diagnostics.items()) |diag| {
            fbs.reset();
            diag.write(fbs.writer()) catch |err| {
                log.warn(
                    "error writing diagnostic to buffer err={}",
                    .{err},
                );
                continue;
            };

            const msg = fbs.getWritten();
            c.gtk_text_buffer_insert_at_cursor(buf, msg.ptr, @intCast(msg.len));
            c.gtk_text_buffer_insert_at_cursor(buf, "\n", -1);
        }

        return buf;
    }

    const vfl = [_][*:0]const u8{
        "H:|-8-[label]-8-|",
        "H:|[text]|",
        "H:|[buttons]|",
        "V:|[label(<=80)][text(>=100)]-[buttons]-|",
    };
};

const ButtonsView = struct {
    root: *c.GtkWidget,

    pub fn init(root: *ConfigErrors) !ButtonsView {
        const ignore_button = c.gtk_button_new_with_label("Ignore");
        errdefer c.g_object_unref(ignore_button);

        const reload_button = c.gtk_button_new_with_label("Reload Configuration");
        errdefer c.g_object_unref(reload_button);

        // Create our view
        const view = try View.init(&.{
            .{ .name = "ignore", .widget = ignore_button },
            .{ .name = "reload", .widget = reload_button },
        }, &vfl);

        // Signals
        _ = c.g_signal_connect_data(
            ignore_button,
            "clicked",
            c.G_CALLBACK(&gtkIgnoreClick),
            root,
            null,
            c.G_CONNECT_DEFAULT,
        );
        _ = c.g_signal_connect_data(
            reload_button,
            "clicked",
            c.G_CALLBACK(&gtkReloadClick),
            root,
            null,
            c.G_CONNECT_DEFAULT,
        );

        return .{ .root = view.root };
    }

    fn gtkIgnoreClick(_: *c.GtkWidget, ud: ?*anyopaque) callconv(.C) void {
        const self: *ConfigErrors = @ptrCast(@alignCast(ud));
        c.gtk_window_destroy(@ptrCast(self.window));
    }

    fn gtkReloadClick(_: *c.GtkWidget, ud: ?*anyopaque) callconv(.C) void {
        const self: *ConfigErrors = @ptrCast(@alignCast(ud));
        self.app.reloadConfig(.app, .{}) catch |err| {
            log.warn("error reloading config error={}", .{err});
            return;
        };
    }

    const vfl = [_][*:0]const u8{
        "H:[ignore]-8-[reload]-8-|",
    };
};
