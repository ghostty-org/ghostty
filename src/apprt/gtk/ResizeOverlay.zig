const ResizeOverlay = @This();

const std = @import("std");

const glib = @import("glib");
const gtk = @import("gtk");

const configpkg = @import("../../config.zig");
const Surface = @import("Surface.zig");

const log = std.log.scoped(.gtk);

/// local copy of configuration data
const DerivedConfig = struct {
    resize_overlay: configpkg.Config.ResizeOverlay,
    resize_overlay_position: configpkg.Config.ResizeOverlayPosition,
    resize_overlay_duration: configpkg.Config.Duration,

    pub fn init(config: *const configpkg.Config) DerivedConfig {
        return .{
            .resize_overlay = config.@"resize-overlay",
            .resize_overlay_position = config.@"resize-overlay-position",
            .resize_overlay_duration = config.@"resize-overlay-duration",
        };
    }
};

/// the surface that we are attached to
surface: *Surface,

/// a copy of the configuration that we need to operate
config: DerivedConfig,

/// If non-null this is the widget on the overlay that shows the size of the
/// surface when it is resized.
label: ?*gtk.Label = null,

/// If non-null this is a timer for dismissing the resize overlay.
timer: ?c_uint = null,

/// If non-null this is a timer for dismissing the resize overlay.
idler: ?c_uint = null,

/// If true, the next resize event will be the first one.
first: bool = true,

/// Initialize the ResizeOverlay. This doesn't do anything more than save a
/// pointer to the surface that we are a part of as all of the widget creation
/// is done later.
pub fn init(self: *ResizeOverlay, surface: *Surface, config: *const configpkg.Config) void {
    self.* = .{
        .surface = surface,
        .config = .init(config),
    };
}

pub fn updateConfig(self: *ResizeOverlay, config: *const configpkg.Config) void {
    self.config = .init(config);
}

/// De-initialize the ResizeOverlay. This removes any pending idlers/timers that
/// may not have fired yet.
pub fn deinit(self: *ResizeOverlay) void {
    if (self.idler) |idler| {
        if (glib.Source.remove(idler) == 0) {
            log.warn("unable to remove resize overlay idler", .{});
        }
        self.idler = null;
    }

    if (self.timer) |timer| {
        if (glib.Source.remove(timer) == 0) {
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
    switch (self.config.resize_overlay) {
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
    self.idler = glib.idleAdd(gtkUpdate, self);
}

/// Actually update the overlay widget. This should only be called from a GTK
/// idle handler.
fn gtkUpdate(ud: ?*anyopaque) callconv(.c) c_int {
    const self: *ResizeOverlay = @ptrCast(@alignCast(ud orelse return 0));

    // No matter what our idler is complete with this callback
    self.idler = null;

    const grid_size = self.surface.core_surface.size.grid();
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrintZ(
        &buf,
        "{d} x {d}",
        .{
            grid_size.columns,
            grid_size.rows,
        },
    ) catch |err| {
        log.err("unable to format text: {}", .{err});
        return 0;
    };

    if (self.label) |label| {
        // The resize overlay widget already exists, just update it.
        label.setText(text.ptr);
        setPosition(label, &self.config);
        show(label);
    } else {
        // Create the resize overlay widget.
        const label = gtk.Label.new(text.ptr);
        label.setJustify(gtk.Justification.center);
        label.setSelectable(0);
        setPosition(label, &self.config);

        const widget = label.as(gtk.Widget);
        widget.addCssClass("view");
        widget.addCssClass("size-overlay");
        widget.setFocusable(0);
        widget.setCanTarget(0);

        const overlay: *gtk.Overlay = @ptrCast(@alignCast(self.surface.overlay));
        overlay.addOverlay(widget);

        self.label = label;
    }

    if (self.timer) |timer| {
        if (glib.Source.remove(timer) == 0) {
            log.warn("unable to remove size overlay timer", .{});
        }
    }

    self.timer = glib.timeoutAdd(
        self.surface.app.config.@"resize-overlay-duration".asMilliseconds(),
        gtkTimerExpired,
        self,
    );

    return 0;
}

// This should only be called from a GTK idle handler or timer.
fn show(label: *gtk.Label) void {
    const widget = label.as(gtk.Widget);
    widget.removeCssClass("hidden");
}

// This should only be called from a GTK idle handler or timer.
fn hide(label: *gtk.Label) void {
    const widget = label.as(gtk.Widget);
    widget.addCssClass("hidden");
}

/// Update the position of the resize overlay widget. It might seem excessive to
/// do this often, but it should make hot config reloading of the position work.
/// This should only be called from a GTK idle handler.
fn setPosition(label: *gtk.Label, config: *DerivedConfig) void {
    const widget = label.as(gtk.Widget);
    widget.setHalign(
        switch (config.resize_overlay_position) {
            .center, .@"top-center", .@"bottom-center" => gtk.Align.center,
            .@"top-left", .@"bottom-left" => gtk.Align.start,
            .@"top-right", .@"bottom-right" => gtk.Align.end,
        },
    );
    widget.setValign(
        switch (config.resize_overlay_position) {
            .center => gtk.Align.center,
            .@"top-left", .@"top-center", .@"top-right" => gtk.Align.start,
            .@"bottom-left", .@"bottom-center", .@"bottom-right" => gtk.Align.end,
        },
    );
}

/// If this fires, it means that the delay period has expired and the resize
/// overlay widget should be hidden.
fn gtkTimerExpired(ud: ?*anyopaque) callconv(.c) c_int {
    const self: *ResizeOverlay = @ptrCast(@alignCast(ud orelse return 0));
    self.timer = null;
    if (self.label) |label| hide(label);
    return 0;
}
