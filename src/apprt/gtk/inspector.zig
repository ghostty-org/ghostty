const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const build_config = @import("../../build_config.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");
const TerminalWindow = @import("Window.zig");
const ImguiWidget = @import("ImguiWidget.zig");
const c = @import("c.zig").c;
const CoreInspector = @import("../../inspector/main.zig").Inspector;

const log = std.log.scoped(.inspector);

/// Inspector is the primary stateful object that represents a terminal
/// inspector. An inspector is 1:1 with a Surface and is owned by a Surface.
/// Closing a surface must close its inspector.
pub const Inspector = struct {
    /// The surface that owns this inspector.
    surface: *Surface,

    /// The current state of where this inspector is rendered. The Inspector
    /// is the state of the inspector but this is the state of the GUI.
    location: LocationState,

    /// This is true if we want to destroy this inspector as soon as the
    /// location is closed. For example: set this to true, request the
    /// window be closed, let GTK do its cleanup, then note this to destroy
    /// the inner state.
    destroy_on_close: bool = true,

    /// Location where the inspector will be launched.
    pub const Location = union(LocationKey) {
        hidden: void,
        window: void,
    };

    /// The internal state for each possible location.
    const LocationState = union(LocationKey) {
        hidden: void,
        window: Window,
    };

    const LocationKey = enum {
        /// No GUI, but load the inspector state.
        hidden,

        /// A dedicated window for the inspector.
        window,
    };

    /// Create an inspector for the given surface in the given location.
    pub fn create(surface: *Surface, location: Location) !*Inspector {
        const alloc = surface.app.core_app.alloc;
        var ptr = try alloc.create(Inspector);
        errdefer alloc.destroy(ptr);
        try ptr.init(surface, location);
        return ptr;
    }

    /// Destroy all memory associated with this inspector. You generally
    /// should NOT call this publicly and should call `close` instead to
    /// use the GTK lifecycle.
    pub fn destroy(self: *Inspector) void {
        assert(self.location == .hidden);
        const alloc = self.allocator();
        self.surface.inspector = null;
        self.deinit();
        alloc.destroy(self);
    }

    fn init(self: *Inspector, surface: *Surface, location: Location) !void {
        self.* = .{
            .surface = surface,
            .location = undefined,
        };

        // Activate the inspector. If it doesn't work we ignore the error
        // because we can just show an error in the inspector window.
        self.surface.core_surface.activateInspector() catch |err| {
            log.err("failed to activate inspector err={}", .{err});
        };

        switch (location) {
            .hidden => self.location = .{ .hidden = {} },
            .window => try self.initWindow(),
        }
    }

    fn deinit(self: *Inspector) void {
        self.surface.core_surface.deactivateInspector();
    }

    /// Request the inspector is closed.
    pub fn close(self: *Inspector) void {
        switch (self.location) {
            .hidden => self.locationDidClose(),
            .window => |v| v.close(),
        }
    }

    fn locationDidClose(self: *Inspector) void {
        self.location = .{ .hidden = {} };
        if (self.destroy_on_close) self.destroy();
    }

    pub fn queueRender(self: *const Inspector) void {
        switch (self.location) {
            .hidden => {},
            .window => |v| v.imgui_widget.queueRender(),
        }
    }

    fn allocator(self: *const Inspector) Allocator {
        return self.surface.app.core_app.alloc;
    }

    fn initWindow(self: *Inspector) !void {
        self.location = .{ .window = undefined };
        try self.location.window.init(self);
    }
};

/// A dedicated window to hold an inspector instance.
const Window = struct {
    inspector: *Inspector,
    window: *c.GtkWindow,
    imgui_widget: ImguiWidget,

    pub fn init(self: *Window, inspector: *Inspector) !void {
        // Initialize to undefined
        self.* = .{
            .inspector = inspector,
            .window = undefined,
            .imgui_widget = undefined,
        };

        // Create the window
        const window = c.gtk_application_window_new(inspector.surface.app.app);
        const gtk_window: *c.GtkWindow = @ptrCast(window);
        errdefer c.gtk_window_destroy(gtk_window);
        self.window = gtk_window;
        c.gtk_window_set_title(gtk_window, "Ghostty: Terminal Inspector");
        c.gtk_window_set_default_size(gtk_window, 1000, 600);
        c.gtk_window_set_icon_name(gtk_window, build_config.bundle_id);

        // Initialize our imgui widget
        try self.imgui_widget.init();
        errdefer self.imgui_widget.deinit();
        self.imgui_widget.render_callback = &imguiRender;
        self.imgui_widget.render_userdata = self;
        CoreInspector.setup();

        // Signals
        _ = c.g_signal_connect_data(window, "destroy", c.G_CALLBACK(&gtkDestroy), self, null, c.G_CONNECT_DEFAULT);

        // Show the window
        c.gtk_window_set_child(gtk_window, @ptrCast(self.imgui_widget.gl_area));
        c.gtk_widget_show(window);
    }

    pub fn deinit(self: *Window) void {
        self.inspector.locationDidClose();
    }

    pub fn close(self: *const Window) void {
        c.gtk_window_destroy(self.window);
    }

    fn imguiRender(ud: ?*anyopaque) void {
        const self: *Window = @ptrCast(@alignCast(ud orelse return));
        const surface = &self.inspector.surface.core_surface;
        const inspector = surface.inspector orelse return;
        inspector.render();
    }

    /// "destroy" signal for the window
    fn gtkDestroy(v: *c.GtkWidget, ud: ?*anyopaque) callconv(.C) void {
        _ = v;
        log.debug("window destroy", .{});

        const self: *Window = @ptrCast(@alignCast(ud.?));
        self.deinit();
    }
};
