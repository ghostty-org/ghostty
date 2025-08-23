//! Structure for managing GUI progress bar for a surface.
const ProgressBar = @This();

const std = @import("std");

const glib = @import("glib");
const gtk = @import("gtk");

const Surface = @import("./Surface.zig");
const terminal = @import("../../terminal/main.zig");

const log = std.log.scoped(.gtk_progress_bar);

/// The surface that we belong to.
surface: *Surface,

/// Widget for showing progress bar.
progress_bar: ?*gtk.ProgressBar = null,

/// Timer used to remove the progress bar if we have not received an update from
/// the TUI in a while.
progress_bar_timer: ?c_uint = null,

pub fn init(surface: *Surface) ProgressBar {
    return .{
        .surface = surface,
    };
}

pub fn deinit(self: *ProgressBar) void {
    self.stopProgressBarTimer();
}

/// Show (or update if it already exists) a GUI progress bar.
pub fn handleProgressReport(self: *ProgressBar, value: terminal.osc.Command.ProgressReport) error{}!bool {
    // Remove the progress bar.
    if (value.state == .remove) {
        self.stopProgressBarTimer();
        self.removeProgressBar();

        return true;
    }

    const progress_bar = self.addProgressBar();
    self.startProgressBarTimer();

    switch (value.state) {
        // already handled above
        .remove => unreachable,

        // Set the progress bar to a fixed value if one was provided, otherwise pulse.
        // Remove the `error` CSS class so that the progress bar shows as normal.
        .set => {
            progress_bar.as(gtk.Widget).removeCssClass("error");
            if (value.progress) |progress| {
                progress_bar.setFraction(computeFraction(progress));
            } else {
                progress_bar.pulse();
            }
        },

        // Set the progress bar to a fixed value if one was provided, otherwise pulse.
        // Set the `error` CSS class so that the progress bar shows as an error color.
        .@"error" => {
            progress_bar.as(gtk.Widget).addCssClass("error");
            if (value.progress) |progress| {
                progress_bar.setFraction(computeFraction(progress));
            } else {
                progress_bar.pulse();
            }
        },

        // The state of progress is unknown, so pulse the progress bar to
        // indicate that things are still happening.
        .indeterminate => {
            progress_bar.pulse();
        },

        // If a progress value was provided, set the progress bar to that value.
        // Don't pulse the progress bar as that would indicate that things were
        // happening. Otherwise this is mainly used to keep the progress bar on
        // screen instead of timing out.
        .pause => {
            if (value.progress) |progress| {
                progress_bar.setFraction(computeFraction(progress));
            }
        },
    }

    return true;
}

/// Compute a fraction [0.0, 1.0] from the supplied progress, which is clamped
/// to [0, 100].
fn computeFraction(progress: u8) f64 {
    return @as(f64, @floatFromInt(std.math.clamp(progress, 0, 100))) / 100.0;
}

test "computeFraction" {
    try std.testing.expectEqual(1.0, computeFraction(100));
    try std.testing.expectEqual(1.0, computeFraction(255));
    try std.testing.expectEqual(0.0, computeFraction(0));
    try std.testing.expectEqual(0.5, computeFraction(50));
}

/// Add a progress bar to our overlay.
fn addProgressBar(self: *ProgressBar) *gtk.ProgressBar {
    if (self.progress_bar) |progress_bar| return progress_bar;

    const progress_bar = gtk.ProgressBar.new();
    self.progress_bar = progress_bar;

    const progress_bar_widget = progress_bar.as(gtk.Widget);
    progress_bar_widget.setHalign(.fill);
    progress_bar_widget.setValign(.start);
    progress_bar_widget.addCssClass("osd");

    self.surface.overlay.addOverlay(progress_bar_widget);

    return progress_bar;
}

/// Remove the progress bar from our overlay.
fn removeProgressBar(self: *ProgressBar) void {
    if (self.progress_bar) |progress_bar| {
        const progress_bar_widget = progress_bar.as(gtk.Widget);
        self.surface.overlay.removeOverlay(progress_bar_widget);
        self.progress_bar = null;
    }
}

/// Start a timer that will remove the progress bar if the TUI forgets to remove
/// it.
fn startProgressBarTimer(self: *ProgressBar) void {
    const progress_bar_timeout_seconds = 15;

    // Remove an old timer that hasn't fired yet.
    self.stopProgressBarTimer();

    self.progress_bar_timer = glib.timeoutAdd(
        progress_bar_timeout_seconds * std.time.ms_per_s,
        handleProgressBarTimeout,
        self,
    );
}

/// Stop any existing timer for removing the progress bar.
fn stopProgressBarTimer(self: *ProgressBar) void {
    if (self.progress_bar_timer) |timer| {
        if (glib.Source.remove(timer) == 0) {
            log.warn("unable to remove progress bar timer", .{});
        }
        self.progress_bar_timer = null;
    }
}

/// The progress bar hasn't been updated by the TUI recently, remove it.
fn handleProgressBarTimeout(ud: ?*anyopaque) callconv(.c) c_int {
    const self: *ProgressBar = @ptrCast(@alignCast(ud.?));

    self.progress_bar_timer = null;
    self.removeProgressBar();

    return @intFromBool(glib.SOURCE_REMOVE);
}
