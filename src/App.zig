//! App is the primary GUI application for ghostty. This builds the window,
//! sets up the renderer, etc. The primary run loop is started by calling
//! the "run" function.
const App = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const build_config = @import("build_config.zig");
const apprt = @import("apprt.zig");
const Surface = @import("Surface.zig");
const tracy = @import("tracy");
const input = @import("input.zig");
const Config = @import("config.zig").Config;
const BlockingQueue = @import("./blocking_queue.zig").BlockingQueue;
const renderer = @import("renderer.zig");
const font = @import("font/main.zig");
const internal_os = @import("os/main.zig");
const macos = @import("macos");
const objc = @import("objc");

const log = std.log.scoped(.app);

const SurfaceList = std.ArrayListUnmanaged(*apprt.Surface);

/// General purpose allocator
alloc: Allocator,

/// The list of surfaces that are currently active.
surfaces: SurfaceList,

/// The last focused surface. This surface may not be valid;
/// you must always call hasSurface to validate it.
focused_surface: ?*Surface = null,

/// The mailbox that can be used to send this thread messages. Note
/// this is a blocking queue so if it is full you will get errors (or block).
mailbox: Mailbox.Queue,

/// Set to true once we're quitting. This never goes false again.
quit: bool,

/// The set of font GroupCache instances shared by surfaces with the
/// same font configuration.
font_grid_set: font.SharedGridSet,

// Used to rate limit desktop notifications. Some platforms (notably macOS) will
// run out of resources if desktop notifications are sent too fast and the OS
// will kill Ghostty.
last_notification_time: ?std.time.Instant = null,
last_notification_digest: u64 = 0,

/// Initialize the main app instance. This creates the main window, sets
/// up the renderer state, compiles the shaders, etc. This is the primary
/// "startup" logic.
pub fn create(
    alloc: Allocator,
) !*App {
    var app = try alloc.create(App);
    errdefer alloc.destroy(app);

    var font_grid_set = try font.SharedGridSet.init(alloc);
    errdefer font_grid_set.deinit();

    app.* = .{
        .alloc = alloc,
        .surfaces = .{},
        .mailbox = .{},
        .quit = false,
        .font_grid_set = font_grid_set,
    };
    errdefer app.surfaces.deinit(alloc);

    return app;
}

pub fn destroy(self: *App) void {
    // Clean up all our surfaces
    for (self.surfaces.items) |surface| surface.deinit();
    self.surfaces.deinit(self.alloc);

    // Clean up our font group cache
    // We should have zero items in the grid set at this point because
    // destroy only gets called when the app is shutting down and this
    // should gracefully close all surfaces.
    assert(self.font_grid_set.count() == 0);
    self.font_grid_set.deinit();

    self.alloc.destroy(self);
}

/// Tick ticks the app loop. This will drain our mailbox and process those
/// events. This should be called by the application runtime on every loop
/// tick.
///
/// This returns whether the app should quit or not.
pub fn tick(self: *App, rt_app: *apprt.App) !bool {
    // If any surfaces are closing, destroy them
    var i: usize = 0;
    while (i < self.surfaces.items.len) {
        const surface = self.surfaces.items[i];
        if (surface.shouldClose()) {
            surface.close(false);
            continue;
        }

        i += 1;
    }

    // Drain our mailbox
    try self.drainMailbox(rt_app);

    // No matter what, we reset the quit flag after a tick. If the apprt
    // doesn't want to quit, then we can't force it to.
    defer self.quit = false;

    // We quit if our quit flag is on
    return self.quit;
}

/// Update the configuration associated with the app. This can only be
/// called from the main thread. The caller owns the config memory. The
/// memory can be freed immediately when this returns.
pub fn updateConfig(self: *App, config: *const Config) !void {
    // Go through and update all of the surface configurations.
    for (self.surfaces.items) |surface| {
        try surface.core_surface.handleMessage(.{ .change_config = config });
    }
}

/// Add an initialized surface. This is really only for the runtime
/// implementations to call and should NOT be called by general app users.
/// The surface must be from the pool.
pub fn addSurface(self: *App, rt_surface: *apprt.Surface) !void {
    try self.surfaces.append(self.alloc, rt_surface);

    // Since we have non-zero surfaces, we can cancel the quit timer.
    // It is up to the apprt if there is a quit timer at all and if it
    // should be canceled.
    if (@hasDecl(apprt.App, "cancelQuitTimer")) rt_surface.app.cancelQuitTimer();
}

/// Delete the surface from the known surface list. This will NOT call the
/// destructor or free the memory.
pub fn deleteSurface(self: *App, rt_surface: *apprt.Surface) void {
    // If this surface is the focused surface then we need to clear it.
    // There was a bug where we relied on hasSurface to return false and
    // just let focused surface be but the allocator was reusing addresses
    // after free and giving false positives, so we must clear it.
    if (self.focused_surface) |focused| {
        if (focused == &rt_surface.core_surface) {
            self.focused_surface = null;
        }
    }

    var i: usize = 0;
    while (i < self.surfaces.items.len) {
        if (self.surfaces.items[i] == rt_surface) {
            _ = self.surfaces.swapRemove(i);
            continue;
        }

        i += 1;
    }

    // If we have no surfaces, we can start the quit timer. It is up to the
    // apprt to determine if this is necessary.
    if (@hasDecl(apprt.App, "startQuitTimer") and
        self.surfaces.items.len == 0) rt_surface.app.startQuitTimer();
}

/// The last focused surface. This is only valid while on the main thread
/// before tick is called.
pub fn focusedSurface(self: *const App) ?*Surface {
    const surface = self.focused_surface orelse return null;
    if (!self.hasSurface(surface)) return null;
    return surface;
}

/// Returns true if confirmation is needed to quit the app. It is up to
/// the apprt to call this.
pub fn needsConfirmQuit(self: *const App) bool {
    for (self.surfaces.items) |v| {
        if (v.core_surface.needsConfirmQuit()) return true;
    }

    return false;
}

/// Drain the mailbox.
fn drainMailbox(self: *App, rt_app: *apprt.App) !void {
    while (self.mailbox.pop()) |message| {
        log.debug("mailbox message={s}", .{@tagName(message)});
        switch (message) {
            .reload_config => try self.reloadConfig(rt_app),
            .open_config => try self.openConfig(rt_app),
            .new_window => |msg| try self.newWindow(rt_app, msg),
            .close => |surface| try self.closeSurface(surface),
            .quit => try self.setQuit(),
            .surface_message => |msg| try self.surfaceMessage(msg.surface, msg.message),
            .redraw_surface => |surface| try self.redrawSurface(rt_app, surface),
            .redraw_inspector => |surface| try self.redrawInspector(rt_app, surface),
        }
    }
}

pub fn openConfig(self: *App, rt_app: *apprt.App) !void {
    _ = self;
    log.debug("opening configuration", .{});
    try rt_app.openConfig();
}

pub fn reloadConfig(self: *App, rt_app: *apprt.App) !void {
    log.debug("reloading configuration", .{});
    if (try rt_app.reloadConfig()) |new| {
        log.debug("new configuration received, applying", .{});
        try self.updateConfig(new);
    }
}

pub fn closeSurface(self: *App, surface: *Surface) !void {
    if (!self.hasSurface(surface)) return;
    surface.close();
}

pub fn focusSurface(self: *App, surface: *Surface) void {
    if (!self.hasSurface(surface)) return;
    self.focused_surface = surface;
}

fn redrawSurface(self: *App, rt_app: *apprt.App, surface: *apprt.Surface) !void {
    if (!self.hasSurface(&surface.core_surface)) return;
    rt_app.redrawSurface(surface);
}

fn redrawInspector(self: *App, rt_app: *apprt.App, surface: *apprt.Surface) !void {
    if (!self.hasSurface(&surface.core_surface)) return;
    rt_app.redrawInspector(surface);
}

/// Create a new window
pub fn newWindow(self: *App, rt_app: *apprt.App, msg: Message.NewWindow) !void {
    if (!@hasDecl(apprt.App, "newWindow")) {
        log.warn("newWindow is not supported by this runtime", .{});
        return;
    }

    const parent = if (msg.parent) |parent| parent: {
        break :parent if (self.hasSurface(parent))
            parent
        else
            null;
    } else null;

    try rt_app.newWindow(.{ .parent = parent, .config = msg.config });
}

/// Start quitting
pub fn setQuit(self: *App) !void {
    if (self.quit) return;
    self.quit = true;
}

/// Handle a window message
fn surfaceMessage(self: *App, surface: *Surface, msg: apprt.surface.Message) !void {
    // We want to ensure our window is still active. Window messages
    // are quite rare and we normally don't have many windows so we do
    // a simple linear search here.
    if (self.hasSurface(surface)) {
        try surface.handleMessage(msg);
    }

    // Window was not found, it probably quit before we handled the message.
    // Not a problem.
}

fn hasSurface(self: *const App, surface: *const Surface) bool {
    for (self.surfaces.items) |v| {
        if (&v.core_surface == surface) return true;
    }

    return false;
}

/// The message types that can be sent to the app thread.
pub const Message = union(enum) {
    /// Reload the configuration for the entire app and propagate it to
    /// all the active surfaces.
    reload_config: void,

    // Open the configuration file
    open_config: void,

    /// Create a new terminal window.
    new_window: NewWindow,

    /// Close a surface. This notifies the runtime that a surface
    /// should close.
    close: *Surface,

    /// Quit
    quit: void,

    /// A message for a specific surface.
    surface_message: struct {
        surface: *Surface,
        message: apprt.surface.Message,
    },

    /// Redraw a surface. This only has an effect for runtimes that
    /// use single-threaded draws. To redraw a surface for all runtimes,
    /// wake up the renderer thread. The renderer thread will send this
    /// message if it needs to.
    redraw_surface: *apprt.Surface,

    /// Redraw the inspector. This is called whenever some non-OS event
    /// causes the inspector to need to be redrawn.
    redraw_inspector: *apprt.Surface,

    const NewWindow = struct {
        /// The parent surface
        parent: ?*Surface = null,

        /// Custom configuration to use for the new window.
        config: ?*Config = null,
    };
};

/// Mailbox is the way that other threads send the app thread messages.
pub const Mailbox = struct {
    /// The type used for sending messages to the app thread.
    pub const Queue = BlockingQueue(Message, 64);

    rt_app: *apprt.App,
    mailbox: *Queue,

    /// Send a message to the surface.
    pub fn push(self: Mailbox, msg: Message, timeout: Queue.Timeout) Queue.Size {
        const result = self.mailbox.push(msg, timeout);

        // Wake up our app loop
        self.rt_app.wakeup();

        return result;
    }
};

// Wasm API.
pub const Wasm = if (!builtin.target.isWasm()) struct {} else struct {
    const wasm = @import("os/wasm.zig");
    const alloc = wasm.alloc;

    // export fn app_new(config: *Config) ?*App {
    //     return app_new_(config) catch |err| { log.err("error initializing app err={}", .{err});
    //         return null;
    //     };
    // }
    //
    // fn app_new_(config: *Config) !*App {
    //     const app = try App.create(alloc, config);
    //     errdefer app.destroy();
    //
    //     const result = try alloc.create(App);
    //     result.* = app;
    //     return result;
    // }
    //
    // export fn app_free(ptr: ?*App) void {
    //     if (ptr) |v| {
    //         v.destroy();
    //         alloc.destroy(v);
    //     }
    // }
};
