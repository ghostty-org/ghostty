/// This is the main entrypoint to the apprt for Ghostty. Ghostty will
/// initialize this in main to start the application..
const App = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const adw = @import("adw");
const gio = @import("gio");
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const internal_os = @import("../../os/main.zig");
const Config = configpkg.Config;
const CoreApp = @import("../../App.zig");

const Application = @import("class/application.zig").Application;
const Surface = @import("Surface.zig");
const gtk_version = @import("gtk_version.zig");
const adw_version = @import("adw_version.zig");
const ipcNewWindow = @import("ipc/new_window.zig").newWindow;

const log = std.log.scoped(.gtk);

/// This is detected by the Renderer, in which case it sends a `redraw_surface`
/// message so that we can call `drawFrame` ourselves from the app thread,
/// because GTK's `GLArea` does not support drawing from a different thread.
pub const must_draw_from_app_thread = true;

/// GTK application ID
pub const application_id = switch (builtin.mode) {
    .Debug, .ReleaseSafe => "com.mitchellh.ghostty-debug",
    .ReleaseFast, .ReleaseSmall => "com.mitchellh.ghostty",
};

/// GTK object path
pub const object_path = switch (builtin.mode) {
    .Debug, .ReleaseSafe => "/com/mitchellh/ghostty_debug",
    .ReleaseFast, .ReleaseSmall => "/com/mitchellh/ghostty",
};

/// The GObject Application instance
app: *Application,

pub fn init(
    self: *App,
    core_app: *CoreApp,

    // Required by the apprt interface but we don't use it.
    opts: struct {},
) !void {
    _ = opts;

    const app: *Application = try .new(self, core_app);
    errdefer app.unref();
    self.* = .{ .app = app };
    return;
}

pub fn run(self: *App) !void {
    try self.app.run();
}

pub fn terminate(self: *App) void {
    // We force deinitialize the app. We don't unref because other things
    // tend to have a reference at this point, so this just forces the
    // disposal now.
    self.app.deinit();
}

/// Called by CoreApp to wake up the event loop.
pub fn wakeup(self: *App) void {
    self.app.wakeup();
}

pub fn performAction(
    self: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    return try self.app.performAction(target, action, value);
}

/// Send the given IPC to a running Ghostty. Returns `true` if the action was
/// able to be performed, `false` otherwise.
///
/// Note that this is a static function. Since this is called from a CLI app (or
/// some other process that is not Ghostty) there is no full-featured apprt App
/// to use.
pub fn performIpc(
    alloc: Allocator,
    target: apprt.ipc.Target,
    comptime action: apprt.ipc.Action.Key,
    value: apprt.ipc.Action.Value(action),
) !bool {
    switch (action) {
        .new_window => return try ipcNewWindow(alloc, target, value),
    }
}

/// Redraw the inspector for the given surface.
pub fn redrawInspector(_: *App, surface: *Surface) void {
    surface.redrawInspector();
}
