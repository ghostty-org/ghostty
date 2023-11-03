/// App is the entrypoint for the application. This is called after all
/// of the runtime-agnostic initialization is complete and we're ready
/// to start.
///
/// There is only ever one App instance per process. This is because most
/// application frameworks also have this restriction so it simplifies
/// the assumptions.
///
/// In GTK, the App contains the primary GApplication and GMainContext
/// (event loop) along with any global app state.
const App = @This();

const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const configpkg = @import("../../config.zig");
const input = @import("../../input.zig");
const internal_os = @import("../../os/main.zig");
const Config = configpkg.Config;
const CoreApp = @import("../../App.zig");
const CoreSurface = @import("../../Surface.zig");

const Surface = @import("Surface.zig");
const Window = @import("Window.zig");
const ConfigErrorsWindow = @import("ConfigErrorsWindow.zig");
const c = @import("c.zig");
const inspector = @import("inspector.zig");
const key = @import("key.zig");

const log = std.log.scoped(.gtk);

pub const Options = struct {};

core_app: *CoreApp,
config: Config,

app: *c.GtkApplication,
ctx: *c.GMainContext,

/// The "none" cursor. We use one that is shared across the entire app.
cursor_none: ?*c.GdkCursor,

/// The shared application menu.
menu: ?*c.GMenu = null,

/// The configuration errors window, if it is currently open.
config_errors_window: ?*ConfigErrorsWindow = null,

/// This is set to false when the main loop should exit.
running: bool = true,

pub fn init(core_app: *CoreApp, opts: Options) !App {
    _ = opts;

    // Initialize libadwaita
    c.adw_init();

    // Load our configuration
    var config = try Config.load(core_app.alloc);
    errdefer config.deinit();

    // If we had configuration errors, then log them.
    if (!config._errors.empty()) {
        for (config._errors.list.items) |err| {
            log.warn("configuration error: {s}", .{err.message});
        }
    }

    // Set the style based on our configuration file
    c.adw_style_manager_set_color_scheme(
        c.adw_style_manager_get_default(),
        switch (config.@"window-theme") {
            .system => c.ADW_COLOR_SCHEME_PREFER_LIGHT,
            .dark => c.ADW_COLOR_SCHEME_FORCE_DARK,
            .light => c.ADW_COLOR_SCHEME_FORCE_LIGHT,
        },
    );

    // The "none" cursor is used for hiding the cursor
    const cursor_none = c.gdk_cursor_new_from_name("none", null);
    errdefer if (cursor_none) |cursor| c.g_object_unref(cursor);

    const single_instance = switch (config.@"gtk-single-instance") {
        .true => true,
        .false => false,
        .desktop => internal_os.launchedFromDesktop(),
    };

    // Setup the flags for our application.
    const app_flags: c.GApplicationFlags = app_flags: {
        var flags: c.GApplicationFlags = c.G_APPLICATION_DEFAULT_FLAGS;
        if (!single_instance) flags |= c.G_APPLICATION_NON_UNIQUE;
        break :app_flags flags;
    };

    // Our app ID determines uniqueness and maps to our desktop file.
    // We append "-debug" to the ID if we're in debug mode so that we
    // can develop Ghostty in Ghostty.
    const app_id: [:0]const u8 = comptime app_id: {
        var id = "com.mitchellh.ghostty";
        break :app_id if (builtin.mode == .Debug) id ++ "-debug" else id;
    };

    // Create our GTK Application which encapsulates our process.
    log.debug("creating GTK application id={s} single-instance={}", .{
        app_id,
        single_instance,
    });
    const app = @as(?*c.GtkApplication, @ptrCast(c.gtk_application_new(
        app_id.ptr,
        app_flags,
    ))) orelse return error.GtkInitFailed;
    errdefer c.g_object_unref(app);
    _ = c.g_signal_connect_data(
        app,
        "activate",
        c.G_CALLBACK(&gtkActivate),
        core_app,
        null,
        c.G_CONNECT_DEFAULT,
    );

    // We don't use g_application_run, we want to manually control the
    // loop so we have to do the same things the run function does:
    // https://github.com/GNOME/glib/blob/a8e8b742e7926e33eb635a8edceac74cf239d6ed/gio/gapplication.c#L2533
    const ctx = c.g_main_context_default() orelse return error.GtkContextFailed;
    if (c.g_main_context_acquire(ctx) == 0) return error.GtkContextAcquireFailed;
    errdefer c.g_main_context_release(ctx);

    const gapp = @as(*c.GApplication, @ptrCast(app));
    var err_: ?*c.GError = null;
    if (c.g_application_register(
        gapp,
        null,
        @ptrCast(&err_),
    ) == 0) {
        if (err_) |err| {
            log.warn("error registering application: {s}", .{err.message});
            c.g_error_free(err);
        }
        return error.GtkApplicationRegisterFailed;
    }

    // This just calls the "activate" signal but its part of the normal
    // startup routine so we just call it:
    // https://gitlab.gnome.org/GNOME/glib/-/blob/bd2ccc2f69ecfd78ca3f34ab59e42e2b462bad65/gio/gapplication.c#L2302
    c.g_application_activate(gapp);

    return .{
        .core_app = core_app,
        .app = app,
        .config = config,
        .ctx = ctx,
        .cursor_none = cursor_none,

        // If we are NOT the primary instance, then we never want to run.
        // This means that another instance of the GTK app is running and
        // our "activate" call above will open a window.
        .running = c.g_application_get_is_remote(gapp) == 0,
    };
}

// Terminate the application. The application will not be restarted after
// this so all global state can be cleaned up.
pub fn terminate(self: *App) void {
    c.g_settings_sync();
    while (c.g_main_context_iteration(self.ctx, 0) != 0) {}
    c.g_main_context_release(self.ctx);
    c.g_object_unref(self.app);

    if (self.cursor_none) |cursor| c.g_object_unref(cursor);
    if (self.menu) |menu| c.g_object_unref(menu);

    self.config.deinit();
}

/// Reload the configuration. This should return the new configuration.
/// The old value can be freed immediately at this point assuming a
/// successful return.
///
/// The returned pointer value is only valid for a stable self pointer.
pub fn reloadConfig(self: *App) !?*const Config {
    // Load our configuration
    var config = try Config.load(self.core_app.alloc);
    errdefer config.deinit();

    // Update the existing config, be sure to clean up the old one.
    self.config.deinit();
    self.config = config;
    self.syncConfigChanges() catch |err| {
        log.warn("error handling configuration changes err={}", .{err});
    };

    return &self.config;
}

/// Call this anytime the configuration changes.
fn syncConfigChanges(self: *App) !void {
    try self.updateConfigErrors();
    try self.syncActionAccelerators();
}

/// This should be called whenever the configuration changes to update
/// the state of our config errors window. This will show the window if
/// there are new configuration errors and hide the window if the errors
/// are resolved.
fn updateConfigErrors(self: *App) !void {
    if (!self.config._errors.empty()) {
        if (self.config_errors_window == null) {
            try ConfigErrorsWindow.create(self);
            assert(self.config_errors_window != null);
        }
    }

    if (self.config_errors_window) |window| {
        window.update();
    }
}

fn syncActionAccelerators(self: *App) !void {
    try self.syncActionAccelerator("app.quit", .{ .quit = {} });
    try self.syncActionAccelerator("app.reload_config", .{ .reload_config = {} });
    try self.syncActionAccelerator("app.toggle_inspector", .{ .inspector = .toggle });
    try self.syncActionAccelerator("win.close", .{ .close_surface = {} });
    try self.syncActionAccelerator("win.new_window", .{ .new_window = {} });
    try self.syncActionAccelerator("win.new_tab", .{ .new_tab = {} });
}

fn syncActionAccelerator(
    self: *App,
    gtk_action: [:0]const u8,
    action: input.Binding.Action,
) !void {
    // Reset it initially
    const zero = [_]?[*:0]const u8{null};
    c.gtk_application_set_accels_for_action(@ptrCast(self.app), gtk_action.ptr, &zero);

    const trigger = self.config.keybind.set.getTrigger(action) orelse return;
    var buf: [256]u8 = undefined;
    const accel = try key.accelFromTrigger(&buf, trigger) orelse return;
    const accels = [_]?[*:0]const u8{ accel, null };

    c.gtk_application_set_accels_for_action(
        @ptrCast(self.app),
        gtk_action.ptr,
        &accels,
    );
}

/// Called by CoreApp to wake up the event loop.
pub fn wakeup(self: App) void {
    _ = self;
    c.g_main_context_wakeup(null);
}

/// Run the event loop. This doesn't return until the app exits.
pub fn run(self: *App) !void {
    if (!self.running) return;

    // If we're not remote, then we also setup our actions and menus.
    self.initActions();
    self.initMenu();

    // On startup, we want to check for configuration errors right away
    // so we can show our error window. We also need to setup other initial
    // state.
    self.syncConfigChanges() catch |err| {
        log.warn("error handling configuration changes err={}", .{err});
    };

    while (self.running) {
        _ = c.g_main_context_iteration(self.ctx, 1);

        // Tick the terminal app
        const should_quit = try self.core_app.tick(self);
        if (should_quit) self.quit();
    }
}

/// Close the given surface.
pub fn redrawSurface(self: *App, surface: *Surface) void {
    _ = self;
    surface.redraw();
}

/// Redraw the inspector for the given surface.
pub fn redrawInspector(self: *App, surface: *Surface) void {
    _ = self;
    surface.queueInspectorRender();
}

/// Called by CoreApp to create a new window with a new surface.
pub fn newWindow(self: *App, parent_: ?*CoreSurface) !void {
    const alloc = self.core_app.alloc;

    // Allocate a fixed pointer for our window. We try to minimize
    // allocations but windows and other GUI requirements are so minimal
    // compared to the steady-state terminal operation so we use heap
    // allocation for this.
    //
    // The allocation is owned by the GtkWindow created. It will be
    // freed when the window is closed.
    var window = try Window.create(alloc, self);

    // Add our initial tab
    try window.newTab(parent_);
}

fn quit(self: *App) void {
    // If we have no toplevel windows, then we're done.
    const list = c.gtk_window_list_toplevels();
    if (list == null) {
        self.running = false;
        return;
    }
    c.g_list_free(list);

    // If the app says we don't need to confirm, then we can quit now.
    if (!self.core_app.needsConfirmQuit()) {
        self.quitNow();
        return;
    }

    // If we have windows, then we want to confirm that we want to exit.
    const alert = c.gtk_message_dialog_new(
        null,
        c.GTK_DIALOG_MODAL,
        c.GTK_MESSAGE_QUESTION,
        c.GTK_BUTTONS_YES_NO,
        "Quit Ghostty?",
    );
    c.gtk_message_dialog_format_secondary_text(
        @ptrCast(alert),
        "All active terminal sessions will be terminated.",
    );

    // We want the "yes" to appear destructive.
    const yes_widget = c.gtk_dialog_get_widget_for_response(
        @ptrCast(alert),
        c.GTK_RESPONSE_YES,
    );
    c.gtk_widget_add_css_class(yes_widget, "destructive-action");

    // We want the "no" to be the default action
    c.gtk_dialog_set_default_response(
        @ptrCast(alert),
        c.GTK_RESPONSE_NO,
    );

    _ = c.g_signal_connect_data(
        alert,
        "response",
        c.G_CALLBACK(&gtkQuitConfirmation),
        self,
        null,
        c.G_CONNECT_DEFAULT,
    );

    c.gtk_widget_show(alert);
}

/// This immediately destroys all windows, forcing the application to quit.
fn quitNow(self: *App) void {
    _ = self;
    const list = c.gtk_window_list_toplevels();
    defer c.g_list_free(list);
    c.g_list_foreach(list, struct {
        fn callback(data: c.gpointer, _: c.gpointer) callconv(.C) void {
            const ptr = data orelse return;
            const widget: *c.GtkWidget = @ptrCast(@alignCast(ptr));
            const window: *c.GtkWindow = @ptrCast(widget);
            c.gtk_window_destroy(window);
        }
    }.callback, null);
}

fn gtkQuitConfirmation(
    alert: *c.GtkMessageDialog,
    response: c.gint,
    ud: ?*anyopaque,
) callconv(.C) void {
    const self: *App = @ptrCast(@alignCast(ud orelse return));

    // Close the alert window
    c.gtk_window_destroy(@ptrCast(alert));

    // If we didn't confirm then we're done
    if (response != c.GTK_RESPONSE_YES) return;

    // Force close all open windows
    self.quitNow();
}

/// This is called by the "activate" signal. This is sent on program
/// startup and also when a secondary instance launches and requests
/// a new window.
fn gtkActivate(app: *c.GtkApplication, ud: ?*anyopaque) callconv(.C) void {
    _ = app;

    const core_app: *CoreApp = @ptrCast(@alignCast(ud orelse return));

    // Queue a new window
    _ = core_app.mailbox.push(.{
        .new_window = .{},
    }, .{ .forever = {} });
}

fn gtkActionReloadConfig(
    _: *c.GSimpleAction,
    _: *c.GVariant,
    ud: ?*anyopaque,
) callconv(.C) void {
    const self: *App = @ptrCast(@alignCast(ud orelse return));
    _ = self.core_app.mailbox.push(.{
        .reload_config = {},
    }, .{ .forever = {} });
}

fn gtkActionQuit(
    _: *c.GSimpleAction,
    _: *c.GVariant,
    ud: ?*anyopaque,
) callconv(.C) void {
    const self: *App = @ptrCast(@alignCast(ud orelse return));
    self.core_app.setQuit() catch |err| {
        log.warn("error setting quit err={}", .{err});
        return;
    };
}

/// This is called to setup the action map that this application supports.
/// This should be called only once on startup.
fn initActions(self: *App) void {
    const actions = .{
        .{ "quit", &gtkActionQuit },
        .{ "reload_config", &gtkActionReloadConfig },
    };

    inline for (actions) |entry| {
        const action = c.g_simple_action_new(entry[0], null);
        defer c.g_object_unref(action);
        _ = c.g_signal_connect_data(
            action,
            "activate",
            c.G_CALLBACK(entry[1]),
            self,
            null,
            c.G_CONNECT_DEFAULT,
        );
        c.g_action_map_add_action(@ptrCast(self.app), @ptrCast(action));
    }
}

/// This sets the self.menu property to the application menu that can be
/// shared by all application windows.
fn initMenu(self: *App) void {
    const menu = c.g_menu_new();
    errdefer c.g_object_unref(menu);

    {
        const section = c.g_menu_new();
        defer c.g_object_unref(section);
        c.g_menu_append_section(menu, null, @ptrCast(@alignCast(section)));
        c.g_menu_append(section, "New Window", "win.new_window");
        c.g_menu_append(section, "New Tab", "win.new_tab");
        c.g_menu_append(section, "Close Window", "win.close");
    }

    {
        const section = c.g_menu_new();
        defer c.g_object_unref(section);
        c.g_menu_append_section(menu, null, @ptrCast(@alignCast(section)));
        c.g_menu_append(section, "Terminal Inspector", "win.toggle_inspector");
        c.g_menu_append(section, "Reload Configuration", "app.reload_config");
        c.g_menu_append(section, "About Ghostty", "win.about");
    }

    // {
    //     const section = c.g_menu_new();
    //     defer c.g_object_unref(section);
    //     c.g_menu_append_submenu(menu, "File", @ptrCast(@alignCast(section)));
    // }

    self.menu = menu;
}
