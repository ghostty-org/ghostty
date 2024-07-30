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
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const input = @import("../../input.zig");
const internal_os = @import("../../os/main.zig");
const Config = configpkg.Config;
const CoreApp = @import("../../App.zig");
const CoreSurface = @import("../../Surface.zig");

const build_options = @import("build_options");

const cgroup = @import("cgroup.zig");
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");
const ConfigErrorsWindow = @import("ConfigErrorsWindow.zig");
const ClipboardConfirmationWindow = @import("ClipboardConfirmationWindow.zig");
const c = @import("c.zig");
const inspector = @import("inspector.zig");
const key = @import("key.zig");
const x11 = @import("x11.zig");

const testing = std.testing;

const log = std.log.scoped(.gtk);

pub const Options = struct {};

core_app: *CoreApp,
config: Config,

app: *c.GtkApplication,
ctx: *c.GMainContext,

/// True if the app was launched with single instance mode.
single_instance: bool,

/// The "none" cursor. We use one that is shared across the entire app.
cursor_none: ?*c.GdkCursor,

/// The shared application menu.
menu: ?*c.GMenu = null,

/// The shared context menu.
context_menu: ?*c.GMenu = null,

/// The configuration errors window, if it is currently open.
config_errors_window: ?*ConfigErrorsWindow = null,

/// The clipboard confirmation window, if it is currently open.
clipboard_confirmation_window: ?*ClipboardConfirmationWindow = null,

/// This is set to false when the main loop should exit.
running: bool = true,

/// Xkb state (X11 only). Will be null on Wayland.
x11_xkb: ?x11.Xkb = null,

/// The base path of the transient cgroup used to put all surfaces
/// into their own cgroup. This is only set if cgroups are enabled
/// and initialization was successful.
transient_cgroup_base: ?[]const u8 = null,

/// CSS Provider for any styles based on ghostty configuration values
css_provider: *c.GtkCssProvider,

pub fn init(core_app: *CoreApp, opts: Options) !App {
    _ = opts;

    // We need to export GDK_DEBUG to run on Wayland after GTK 4.14.
    // Older versions of GTK do not support these values so it is safe
    // to always set this. Forwards versions are uncertain so we'll have to
    // reassess...
    //
    // Upstream issue: https://gitlab.gnome.org/GNOME/gtk/-/issues/6589
    _ = internal_os.setenv("GDK_DEBUG", "opengl,gl-disable-gles");

    // We need to export GSK_RENDERER to opengl because GTK uses ngl by default after 4.14
    _ = internal_os.setenv("GSK_RENDERER", "opengl");

    // Load our configuration
    var config = try Config.load(core_app.alloc);
    errdefer config.deinit();

    // If we had configuration errors, then log them.
    if (!config._errors.empty()) {
        for (config._errors.list.items) |err| {
            log.warn("configuration error: {s}", .{err.message});
        }
    }

    // The "none" cursor is used for hiding the cursor
    const cursor_none = c.gdk_cursor_new_from_name("none", null);
    errdefer if (cursor_none) |cursor| c.g_object_unref(cursor);

    const single_instance = switch (config.@"gtk-single-instance") {
        .true => true,
        .false => false,
        .detect => internal_os.launchedFromDesktop() or internal_os.launchedByDBusActivation() or internal_os.launchedBySystemd(),
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
    const app_id: [:0]const u8 = app_id: {
        if (config.class) |class| {
            if (isValidAppId(class)) {
                break :app_id class;
            } else {
                log.warn("invalid 'class' in config, ignoring", .{});
            }
        }

        const default_id = "com.mitchellh.ghostty";
        break :app_id if (builtin.mode == .Debug) default_id ++ "-debug" else default_id;
    };

    // Create our GTK Application which encapsulates our process.
    const app: *c.GtkApplication = app: {
        const adwaita = build_options.libadwaita and config.@"gtk-adwaita";

        log.debug("creating GTK application id={s} single-instance={} adwaita={}", .{
            app_id,
            single_instance,
            adwaita,
        });

        // If not libadwaita, create a standard GTK application.
        if (!adwaita) break :app @as(?*c.GtkApplication, @ptrCast(c.gtk_application_new(
            app_id.ptr,
            app_flags,
        ))) orelse return error.GtkInitFailed;

        // Use libadwaita if requested. Using an AdwApplication lets us use
        // Adwaita widgets and access things such as the color scheme.
        const adw_app = @as(?*c.AdwApplication, @ptrCast(c.adw_application_new(
            app_id.ptr,
            app_flags,
        ))) orelse return error.GtkInitFailed;

        const style_manager = c.adw_application_get_style_manager(adw_app);
        c.adw_style_manager_set_color_scheme(
            style_manager,
            switch (config.@"window-theme") {
                .auto => auto: {
                    const lum = config.background.toTerminalRGB().perceivedLuminance();
                    break :auto if (lum > 0.5)
                        c.ADW_COLOR_SCHEME_PREFER_LIGHT
                    else
                        c.ADW_COLOR_SCHEME_PREFER_DARK;
                },

                .system => c.ADW_COLOR_SCHEME_PREFER_LIGHT,
                .dark => c.ADW_COLOR_SCHEME_FORCE_DARK,
                .light => c.ADW_COLOR_SCHEME_FORCE_LIGHT,
            },
        );

        break :app @ptrCast(adw_app);
    };
    errdefer c.g_object_unref(app);

    const gapp = @as(*c.GApplication, @ptrCast(app));

    // force the resource path to a known value so that it doesn't depend on
    // the app id and load in compiled resources
    c.g_application_set_resource_base_path(gapp, "/com/mitchellh/ghostty");
    c.g_resources_register(c.ghostty_get_resource());

    // The `activate` signal is used when Ghostty is first launched and when a
    // secondary Ghostty is launched and requests a new window.
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

    // Perform all X11 initialization. This ultimately returns the X11
    // keyboard state but the block does more than that (i.e. setting up
    // WM_CLASS).
    const x11_xkb: ?x11.Xkb = x11_xkb: {
        const display = c.gdk_display_get_default();
        if (!x11.is_display(display)) break :x11_xkb null;

        // Set the X11 window class property (WM_CLASS) if are are on an X11
        // display.
        //
        // Note that we also set the program name here using g_set_prgname.
        // This is how the instance name field for WM_CLASS is derived when
        // calling gdk_x11_display_set_program_class; there does not seem to be
        // a way to set it directly. It does not look like this is being set by
        // our other app initialization routines currently, but since we're
        // currently deriving its value from x11-instance-name effectively, I
        // feel like gating it behind an X11 check is better intent.
        //
        // This makes the property show up like so when using xprop:
        //
        //     WM_CLASS(STRING) = "ghostty", "com.mitchellh.ghostty"
        //
        // Append "-debug" on both when using the debug build.
        //
        const prgname = if (config.@"x11-instance-name") |pn|
            pn
        else if (builtin.mode == .Debug)
            "ghostty-debug"
        else
            "ghostty";
        c.g_set_prgname(prgname);
        c.gdk_x11_display_set_program_class(display, app_id);

        // Set up Xkb
        break :x11_xkb try x11.Xkb.init(display);
    };

    // This just calls the `activate` signal but its part of the normal startup
    // routine so we just call it, but only if we were not launched by D-Bus
    // activation or systemd.  D-Bus activation will send it's own `activate`
    // signal later.
    // https://gitlab.gnome.org/GNOME/glib/-/blob/bd2ccc2f69ecfd78ca3f34ab59e42e2b462bad65/gio/gapplication.c#L2302
    if (!internal_os.launchedByDBusActivation() and !internal_os.launchedBySystemd())
        c.g_application_activate(gapp);

    // Register for dbus events
    if (c.g_application_get_dbus_connection(gapp)) |dbus_connection| {
        _ = c.g_dbus_connection_signal_subscribe(
            dbus_connection,
            null,
            "org.freedesktop.portal.Settings",
            "SettingChanged",
            "/org/freedesktop/portal/desktop",
            "org.freedesktop.appearance",
            c.G_DBUS_SIGNAL_FLAGS_MATCH_ARG0_NAMESPACE,
            &gtkNotifyColorScheme,
            core_app,
            null,
        );
    }

    const css_provider = c.gtk_css_provider_new();
    try loadRuntimeCss(&config, css_provider);

    // Run a small no-op function every 500 milliseconds so that we don't get
    // stuck in g_main_context_iteration forever if there are no open surfaces.
    _ = c.g_timeout_add(500, gtkTimeout, null);

    return .{
        .core_app = core_app,
        .app = app,
        .config = config,
        .ctx = ctx,
        .cursor_none = cursor_none,
        .x11_xkb = x11_xkb,
        .single_instance = single_instance,
        // If we are NOT the primary instance, then we never want to run.
        // This means that another instance of the GTK app is running and
        // our "activate" call above will open a window.
        .running = c.g_application_get_is_remote(gapp) == 0,
        .css_provider = css_provider,
    };
}

// This timeout function is run periodically so that we don't get stuck in
// g_main_context_iteration forever if there are no open surfaces.
pub fn gtkTimeout(_: ?*anyopaque) callconv(.C) c.gboolean {
    return 1;
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
    if (self.context_menu) |context_menu| c.g_object_unref(context_menu);
    if (self.transient_cgroup_base) |path| self.core_app.alloc.free(path);

    self.config.deinit();
}

/// Open the configuration in the system editor.
pub fn openConfig(self: *App) !void {
    try configpkg.edit.open(self.core_app.alloc);
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
    try loadRuntimeCss(&self.config, self.css_provider);
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
    try self.syncActionAccelerator("app.open_config", .{ .open_config = {} });
    try self.syncActionAccelerator("app.reload_config", .{ .reload_config = {} });
    try self.syncActionAccelerator("win.toggle_inspector", .{ .inspector = .toggle });
    try self.syncActionAccelerator("win.close", .{ .close_surface = {} });
    try self.syncActionAccelerator("win.new_window", .{ .new_window = {} });
    try self.syncActionAccelerator("win.new_tab", .{ .new_tab = {} });
    try self.syncActionAccelerator("win.split_right", .{ .new_split = .right });
    try self.syncActionAccelerator("win.split_down", .{ .new_split = .down });
    try self.syncActionAccelerator("win.copy", .{ .copy_to_clipboard = {} });
    try self.syncActionAccelerator("win.paste", .{ .paste_from_clipboard = {} });
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

fn loadRuntimeCss(config: *const Config, provider: *c.GtkCssProvider) !void {
    const fill: Config.Color = config.@"unfocused-split-fill" orelse config.background;
    const fmt =
        \\widget.unfocused-split {{
        \\ opacity: {d:.2};
        \\ background-color: rgb({d},{d},{d});
        \\}}
    ;
    // The length required is always less than the length of the pre-formatted string:
    // -> '{d:.2}' gets replaced with max 4 bytes (0.00)
    // -> each {d} could be replaced with max 3 bytes
    var css_buf: [fmt.len]u8 = undefined;

    const css = try std.fmt.bufPrintZ(
        &css_buf,
        fmt,
        .{
            config.@"unfocused-split-opacity",
            fill.r,
            fill.g,
            fill.b,
        },
    );
    // Clears any previously loaded CSS from this provider
    c.gtk_css_provider_load_from_data(provider, css, @intCast(css.len));
}

/// Called by CoreApp to wake up the event loop.
pub fn wakeup(self: App) void {
    _ = self;
    c.g_main_context_wakeup(null);
}

/// Run the event loop. This doesn't return until the app exits.
pub fn run(self: *App) !void {
    // Running will be false when we're not the primary instance and should
    // exit (GTK single instance mode). If we're not running, we're done
    // right away.
    if (!self.running) return;

    // If we are running, then we proceed to setup our app.

    // Setup our cgroup configurations for our surfaces.
    if (switch (self.config.@"linux-cgroup") {
        .never => false,
        .always => true,
        .@"single-instance" => self.single_instance,
    }) cgroup: {
        const path = cgroup.init(self) catch |err| {
            // If we can't initialize cgroups then that's okay. We
            // want to continue to run so we just won't isolate surfaces.
            // NOTE(mitchellh): do we want a config to force it?
            log.warn(
                "failed to initialize cgroups, terminals will not be isolated err={}",
                .{err},
            );

            // If we have hard fail enabled then we exit now.
            if (self.config.@"linux-cgroup-hard-fail") {
                log.err("linux-cgroup-hard-fail enabled, exiting", .{});
                return error.CgroupInitFailed;
            }

            break :cgroup;
        };

        log.info("cgroup isolation enabled base={s}", .{path});
        self.transient_cgroup_base = path;
    } else log.debug("cgroup isoation disabled config={}", .{self.config.@"linux-cgroup"});

    // The last instant that one or more surfaces were open
    var last_one = try std.time.Instant.now();

    // If we're not remote, then we also setup our actions and menus.
    self.initActions();
    self.initMenu();
    self.initContextMenu();

    // On startup, we want to check for configuration errors right away
    // so we can show our error window. We also need to setup other initial
    // state.
    self.syncConfigChanges() catch |err| {
        log.warn("error handling configuration changes err={}", .{err});
    };

    while (self.running) {
        _ = c.g_main_context_iteration(self.ctx, 1);

        // Tick the terminal app and see if we should quit.
        const should_quit = try self.core_app.tick(self);

        // If there are one or more surfaces open, update the timer.
        if (self.core_app.surfaces.items.len > 0) last_one = try std.time.Instant.now();

        const q = q: {
            // If we've been told by GTK that we should quit, do so regardless
            // of any other setting.
            if (should_quit) break :q true;

            // If there are no surfaces check to see if we should stay in the
            // background or not.
            if (self.core_app.surfaces.items.len == 0) {
                switch (self.config.@"quit-after-last-window-closed") {
                    .always => break :q true,
                    .never => break :q false,
                    .@"after-timeout" => {

                        // If the background timeout is not null, check to see
                        // if the timeout has elapsed.
                        if (self.config.@"quit-after-last-window-closed-delay".duration) |duration| {
                            const now = try std.time.Instant.now();

                            if (now.since(last_one) > duration)
                                // The timeout has elapsed, quit.
                                break :q true;

                            // Not enough time has elapsed, don't quit.
                            break :q false;
                        }

                        // `background-timeout` is null, don't quit.
                        break :q false;
                    },
                }
            }

            break :q false;
        };

        if (q) self.quit();
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
fn quitNow(_: *App) void {
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

/// This is called by the `activate` signal. This is sent on program startup and
/// also when a secondary instance launches and requests a new window.
fn gtkActivate(_: *c.GtkApplication, ud: ?*anyopaque) callconv(.C) void {
    log.info("received activate signal", .{});

    const core_app: *CoreApp = @ptrCast(@alignCast(ud orelse return));

    // Queue a new window
    _ = core_app.mailbox.push(.{
        .new_window = .{},
    }, .{ .forever = {} });
}

/// Call a D-Bus method to determine the current color scheme. If there
/// is any error at any point we'll log the error and return "light"
pub fn getColorScheme(self: *App) apprt.ColorScheme {
    const dbus_connection = c.g_application_get_dbus_connection(@ptrCast(self.app));

    var err: ?*c.GError = null;
    defer if (err) |e| c.g_error_free(e);

    const value = c.g_dbus_connection_call_sync(
        dbus_connection,
        "org.freedesktop.portal.Desktop",
        "/org/freedesktop/portal/desktop",
        "org.freedesktop.portal.Settings",
        "ReadOne",
        c.g_variant_new("(ss)", "org.freedesktop.appearance", "color-scheme"),
        c.G_VARIANT_TYPE("(v)"),
        c.G_DBUS_CALL_FLAGS_NONE,
        -1,
        null,
        &err,
    ) orelse {
        if (err) |e| log.err("unable to get current color scheme: {s}", .{e.message});
        return .light;
    };
    defer c.g_variant_unref(value);

    if (c.g_variant_is_of_type(value, c.G_VARIANT_TYPE("(v)")) == 1) {
        var inner: ?*c.GVariant = null;
        c.g_variant_get(value, "(v)", &inner);
        defer c.g_variant_unref(inner);
        if (c.g_variant_is_of_type(inner, c.G_VARIANT_TYPE("u")) == 1) {
            return if (c.g_variant_get_uint32(inner) == 1) .dark else .light;
        }
    }

    return .light;
}

/// This will be called by D-Bus when the style changes between light & dark.
fn gtkNotifyColorScheme(
    _: ?*c.GDBusConnection,
    _: [*c]const u8,
    _: [*c]const u8,
    _: [*c]const u8,
    _: [*c]const u8,
    parameters: ?*c.GVariant,
    user_data: ?*anyopaque,
) callconv(.C) void {
    const core_app: *CoreApp = @ptrCast(@alignCast(user_data orelse {
        log.err("style change notification: userdata is null", .{});
        return;
    }));

    if (c.g_variant_is_of_type(parameters, c.G_VARIANT_TYPE("(ssv)")) != 1) {
        log.err("unexpected parameter type: {s}", .{c.g_variant_get_type_string(parameters)});
        return;
    }

    var namespace: [*c]u8 = undefined;
    var setting: [*c]u8 = undefined;
    var value: *c.GVariant = undefined;
    c.g_variant_get(parameters, "(ssv)", &namespace, &setting, &value);
    defer c.g_free(namespace);
    defer c.g_free(setting);
    defer c.g_variant_unref(value);

    // ignore any setting changes that we aren't interested in
    if (!std.mem.eql(u8, "org.freedesktop.appearance", std.mem.span(namespace))) return;
    if (!std.mem.eql(u8, "color-scheme", std.mem.span(setting))) return;

    if (c.g_variant_is_of_type(value, c.G_VARIANT_TYPE("u")) != 1) {
        log.err("unexpected value type: {s}", .{c.g_variant_get_type_string(value)});
        return;
    }

    const color_scheme: apprt.ColorScheme = if (c.g_variant_get_uint32(value) == 1)
        .dark
    else
        .light;

    for (core_app.surfaces.items) |surface| {
        surface.core_surface.colorSchemeCallback(color_scheme) catch |err| {
            log.err("unable to tell surface about color scheme change: {}", .{err});
        };
    }
}

fn gtkActionOpenConfig(
    _: *c.GSimpleAction,
    _: *c.GVariant,
    ud: ?*anyopaque,
) callconv(.C) void {
    const self: *App = @ptrCast(@alignCast(ud orelse return));
    _ = self.core_app.mailbox.push(.{
        .open_config = {},
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
    log.info("gtk quit action received", .{});

    const self: *App = @ptrCast(@alignCast(ud orelse return));
    self.core_app.setQuit() catch |err| {
        log.warn("error setting quit err={}", .{err});
        return;
    };
}

fn gtkActionNewWindow(
    _: *c.GSimpleAction,
    _: *c.GVariant,
    ud: ?*anyopaque,
) callconv(.C) void {
    log.info("received new window action", .{});
    const self: *App = @ptrCast(@alignCast(ud orelse return));
    _ = self.core_app.mailbox.push(.{
        .new_window = .{},
    }, .{ .forever = {} });
}

/// This is called to setup the action map that this application supports.
/// This should be called only once on startup.
fn initActions(self: *App) void {
    const actions = .{
        .{ "quit", &gtkActionQuit },
        .{ "open_config", &gtkActionOpenConfig },
        .{ "reload_config", &gtkActionReloadConfig },
        .{ "new_window", &gtkActionNewWindow },
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
        c.g_menu_append(section, "Split Right", "win.split_right");
        c.g_menu_append(section, "Split Down", "win.split_down");
        c.g_menu_append(section, "Close Window", "win.close");
    }

    {
        const section = c.g_menu_new();
        defer c.g_object_unref(section);
        c.g_menu_append_section(menu, null, @ptrCast(@alignCast(section)));
        c.g_menu_append(section, "Terminal Inspector", "win.toggle_inspector");
        c.g_menu_append(section, "Open Configuration", "app.open_config");
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

fn initContextMenu(self: *App) void {
    const menu = c.g_menu_new();
    errdefer c.g_object_unref(menu);

    createContextMenuCopyPasteSection(menu, false);

    {
        const section = c.g_menu_new();
        defer c.g_object_unref(section);
        c.g_menu_append_section(menu, null, @ptrCast(@alignCast(section)));
        c.g_menu_append(section, "Split Right", "win.split_right");
        c.g_menu_append(section, "Split Down", "win.split_down");
    }

    {
        const section = c.g_menu_new();
        defer c.g_object_unref(section);
        c.g_menu_append_section(menu, null, @ptrCast(@alignCast(section)));
        c.g_menu_append(section, "Terminal Inspector", "win.toggle_inspector");
    }

    self.context_menu = menu;
}

fn createContextMenuCopyPasteSection(menu: ?*c.GMenu, has_selection: bool) void {
    const section = c.g_menu_new();
    defer c.g_object_unref(section);
    c.g_menu_prepend_section(menu, null, @ptrCast(@alignCast(section)));
    // FIXME: Feels really hackish, but disabling sensitivity on this doesn't seems to work(?)
    c.g_menu_append(section, "Copy", if (has_selection) "win.copy" else "noop");
    c.g_menu_append(section, "Paste", "win.paste");
}

pub fn refreshContextMenu(self: *App, has_selection: bool) void {
    c.g_menu_remove(self.context_menu, 0);
    createContextMenuCopyPasteSection(self.context_menu, has_selection);
}

fn isValidAppId(app_id: [:0]const u8) bool {
    if (app_id.len > 255 or app_id.len == 0) return false;
    if (app_id[0] == '.') return false;
    if (app_id[app_id.len - 1] == '.') return false;

    var hasDot = false;
    for (app_id) |char| {
        switch (char) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-' => {},
            '.' => hasDot = true,
            else => return false,
        }
    }
    if (!hasDot) return false;

    return true;
}

test "isValidAppId" {
    try testing.expect(isValidAppId("foo.bar"));
    try testing.expect(isValidAppId("foo.bar.baz"));
    try testing.expect(!isValidAppId("foo"));
    try testing.expect(!isValidAppId("foo.bar?"));
    try testing.expect(!isValidAppId("foo."));
    try testing.expect(!isValidAppId(".foo"));
    try testing.expect(!isValidAppId(""));
    try testing.expect(!isValidAppId("foo" ** 86));
}
