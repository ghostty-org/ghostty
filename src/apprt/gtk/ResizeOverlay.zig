const ResizeOverlay = @This();

const std = @import("std");
const c = @import("c.zig").c;
const configpkg = @import("../../config.zig");
const Surface = @import("Surface.zig");

const log = std.log.scoped(.gtk);

/// Back reference to the surface we belong to
surface: ?*Surface = null,

/// If non-null this is the widget on the overlay that shows the size of the
/// surface when it is resized.
widget: ?*c.GtkWidget = null,

/// If non-null this is a timer for dismissing the resize overlay.
timer: ?c.guint = null,

/// If non-null this is a timer for dismissing the resize overlay.
idler: ?c.guint = null,

/// If true, the next resize event will be the first one.
first: bool = true,

/// Initialize the ResizeOverlay. This doesn't do anything more than save a
/// pointer to the surface that we are a part of as all of the widget creation
/// is done later.
pub fn init(surface: *Surface) ResizeOverlay {
    return .{
        .surface = surface,
    };
}

/// De-initialize the ResizeOverlay. This removes any pending idlers/timers that
/// may not have fired yet.
pub fn deinit(self: *ResizeOverlay) void {
    if (self.idler) |idler| {
        if (c.g_source_remove(idler) == c.FALSE) {
            log.warn("unable to remove resize overlay idler", .{});
        }
        self.idler = null;
    }

    if (self.timer) |timer| {
        if (c.g_source_remove(timer) == c.FALSE) {
            log.warn("unable to remove resize overlay timer", .{});
        }
        self.timer = null;
    }
}

/// If we're configured to do so, update the text in the resize overlay widget
/// and make it visible. Schedule a timer to hide the widget after the delay
/// expires.
///
/// If we're not configured to show the overlay, do nothing.
pub fn maybeShow(self: *ResizeOverlay) void {
    const surface = self.surface orelse {
        log.err("resize overlay configured without a surface", .{});
        return;
    };

    switch (surface.app.config.@"resize-overlay") {
        .never => return,
        .always => {},
        .@"after-first" => if (self.first) {
            self.first = false;
            return;
        },
    }

    self.first = false;

    // When updating a widget, wait until GTK is "idle", i.e. not in the middle
    // of doing any other updates. Since we are called in the middle of resizing
    // GTK is doing a lot of work rearranging all of the widgets. Not doing this
    // results in a lot of warnings from GTK and _horrible_ flickering of the
    // resize overlay.
    if (self.idler != null) return;
    self.idler = c.g_idle_add(gtkUpdate, @ptrCast(self));
}

/// Actually update the overlay widget. This should only be called from a GTK
/// idle handler.
fn gtkUpdate(ud: ?*anyopaque) callconv(.C) c.gboolean {
    const self: *ResizeOverlay = @ptrCast(@alignCast(ud));

    // No matter what our idler is complete with this callback
    self.idler = null;

    const surface = self.surface orelse {
        log.err("resize overlay configured without a surface", .{});
        return c.FALSE;
    };

    const grid_size = surface.core_surface.size.grid();
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrintZ(
        &buf,
        "{d}c ⨯ {d}r",
        .{
            grid_size.columns,
            grid_size.rows,
        },
    ) catch |err| {
        log.err("unable to format text: {}", .{err});
        return c.FALSE;
    };

    if (self.widget) |widget| {
        // The resize overlay widget already exists, just update it.
        c.gtk_label_set_text(@ptrCast(widget), text.ptr);
        setPosition(widget, &surface.app.config);
        show(widget);
    } else {
        // Create the resize overlay widget.
        const widget = c.gtk_label_new(text.ptr);

        c.gtk_widget_add_css_class(widget, "view");
        c.gtk_widget_add_css_class(widget, "size-overlay");
        c.gtk_widget_set_focusable(widget, c.FALSE);
        c.gtk_widget_set_can_target(widget, c.FALSE);
        c.gtk_label_set_justify(@ptrCast(widget), c.GTK_JUSTIFY_CENTER);
        c.gtk_label_set_selectable(@ptrCast(widget), c.FALSE);
        setPosition(widget, &surface.app.config);

        c.gtk_overlay_add_overlay(surface.overlay, widget);

        self.widget = widget;
    }

    if (self.timer) |timer| {
        if (c.g_source_remove(timer) == c.FALSE) {
            log.warn("unable to remove size overlay timer", .{});
        }
    }
    self.timer = c.g_timeout_add(
        surface.app.config.@"resize-overlay-duration".asMilliseconds(),
        gtkTimerExpired,
        @ptrCast(self),
    );

    return c.FALSE;
}

// This should only be called from a GTK idle handler or timer.
fn show(widget: *c.GtkWidget) void {
    // The CSS class is used only by libadwaita.
    c.gtk_widget_remove_css_class(@ptrCast(widget), "hidden");
    // Set the visibility for non-libadwaita usage.
    c.gtk_widget_set_visible(@ptrCast(widget), 1);
}

// This should only be called from a GTK idle handler or timer.
fn hide(widget: *c.GtkWidget) void {
    // The CSS class is used only by libadwaita.
    c.gtk_widget_add_css_class(widget, "hidden");
    // Set the visibility for non-libadwaita usage.
    c.gtk_widget_set_visible(widget, c.FALSE);
}

/// Update the position of the resize overlay widget. It might seem excessive to
/// do this often, but it should make hot config reloading of the position work.
/// This should only be called from a GTK idle handler.
fn setPosition(widget: *c.GtkWidget, config: *configpkg.Config) void {
    c.gtk_widget_set_halign(
        @ptrCast(widget),
        switch (config.@"resize-overlay-position") {
            .center, .@"top-center", .@"bottom-center" => c.GTK_ALIGN_CENTER,
            .@"top-left", .@"bottom-left" => c.GTK_ALIGN_START,
            .@"top-right", .@"bottom-right" => c.GTK_ALIGN_END,
        },
    );
    c.gtk_widget_set_valign(
        @ptrCast(widget),
        switch (config.@"resize-overlay-position") {
            .center => c.GTK_ALIGN_CENTER,
            .@"top-left", .@"top-center", .@"top-right" => c.GTK_ALIGN_START,
            .@"bottom-left", .@"bottom-center", .@"bottom-right" => c.GTK_ALIGN_END,
        },
    );
}

/// If this fires, it means that the delay period has expired and the resize
/// overlay widget should be hidden.
fn gtkTimerExpired(ud: ?*anyopaque) callconv(.C) c.gboolean {
    const self: *ResizeOverlay = @ptrCast(@alignCast(ud));
    self.timer = null;
    if (self.widget) |widget| hide(widget);
    return c.FALSE;
}
