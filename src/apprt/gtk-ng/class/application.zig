const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const build_config = @import("../../../build_config.zig");
const i18n = @import("../../../os/main.zig").i18n;
const apprt = @import("../../../apprt.zig");
const cgroup = @import("../cgroup.zig");
const CoreApp = @import("../../../App.zig");
const configpkg = @import("../../../config.zig");
const internal_os = @import("../../../os/main.zig");
const systemd = @import("../../../os/systemd.zig");
const terminal = @import("../../../terminal/main.zig");
const xev = @import("../../../global.zig").xev;
const CoreConfig = configpkg.Config;
const CoreSurface = @import("../../../Surface.zig");

const adw_version = @import("../adw_version.zig");
const gtk_version = @import("../gtk_version.zig");
const winprotopkg = @import("../winproto.zig");
const ApprtApp = @import("../App.zig");
const Common = @import("../class.zig").Common;
const WeakRef = @import("../weak_ref.zig").WeakRef;
const Config = @import("config.zig").Config;
const Surface = @import("surface.zig").Surface;
const Window = @import("window.zig").Window;
const CloseConfirmationDialog = @import("close_confirmation_dialog.zig").CloseConfirmationDialog;
const ConfigErrorsDialog = @import("config_errors_dialog.zig").ConfigErrorsDialog;

const log = std.log.scoped(.gtk_ghostty_application);

/// The primary entrypoint for the Ghostty GTK application.
///
/// This requires a `ghostty.App` and `ghostty.Config` and takes
/// care of the rest. Call `run` to run the application to completion.
pub const Application = extern struct {
    /// This type creates a new GObject class. Since the Application is
    /// the primary entrypoint I'm going to use this as a place to document
    /// how this all works and where you can find resources for it, but
    /// this applies to any other GObject class within this apprt.
    ///
    /// The various fields (parent_instance) and constants (Parent,
    /// getGObjectType, etc.) are mandatory "interfaces" for zig-gobject
    /// to create a GObject class.
    ///
    /// I found these to be the best resources:
    ///
    ///   * https://github.com/ianprime0509/zig-gobject/blob/d7f1edaf50193d49b56c60568dfaa9f23195565b/extensions/gobject2.zig
    ///   * https://github.com/ianprime0509/zig-gobject/blob/d7f1edaf50193d49b56c60568dfaa9f23195565b/example/src/custom_class.zig
    ///
    const Self = @This();

    parent_instance: Parent,
    pub const Parent = adw.Application;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyApplication",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        pub const config = struct {
            pub const name = "config";
            const impl = gobject.ext.defineProperty(
                "config",
                Self,
                ?*Config,
                .{
                    .nick = "Config",
                    .blurb = "The current active configuration for the application.",
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?*Config,
                        .{
                            .getter = Self.getConfig,
                            .getter_transfer = .full,
                        },
                    ),
                },
            );
        };
    };

    const Private = struct {
        /// The apprt App. This is annoying that we need this it'd be
        /// nicer to just make THIS the apprt app but the current libghostty
        /// API doesn't allow that.
        rt_app: *ApprtApp,

        /// The libghostty App instance.
        core_app: *CoreApp,

        /// The configuration for the application.
        config: *Config,

        /// State and logic for the underlying windowing protocol.
        winproto: winprotopkg.App,

        /// The base path of the transient cgroup used to put all surfaces
        /// into their own cgroup. This is only set if cgroups are enabled
        /// and initialization was successful.
        transient_cgroup_base: ?[]const u8 = null,

        /// This is set to false internally when the event loop
        /// should exit and the application should quit. This must
        /// only be set by the main loop thread.
        running: bool = false,

        /// The timer used to quit the application after the last window is
        /// closed. Even if there is no quit delay set, this is the state
        /// used to determine to close the app.
        quit_timer: union(enum) {
            off,
            active: c_uint,
            expired,
        } = .off,

        /// If non-null, we're currently showing a config errors dialog.
        /// This is a WeakRef because the dialog can close on its own
        /// outside of our own lifecycle and that's okay.
        config_errors_dialog: WeakRef(ConfigErrorsDialog) = .{},

        /// glib source for our signal handler.
        signal_source: ?c_uint = null,

        pub var offset: c_int = 0;
    };

    /// Get this application as the default, allowing access to its
    /// properties globally.
    ///
    /// This asserts that there is a default application and that the
    /// default application is a GhosttyApplication. The program would have
    /// to be in a very bad state for this to be violated.
    pub fn default() *Self {
        const app = gio.Application.getDefault().?;
        return gobject.ext.cast(Self, app).?;
    }

    /// Creates a new Application instance.
    ///
    /// This does a lot more work than a typical class instantiation,
    /// because we expect that this is the main program entrypoint.
    ///
    /// The only failure mode of initializing the application is early OOM.
    /// Early OOM can't be recovered from. Every other error is mapped to
    /// some degraded state where we can at least show a window with an error.
    pub fn new(
        rt_app: *ApprtApp,
        core_app: *CoreApp,
    ) Allocator.Error!*Self {
        const alloc = core_app.alloc;

        // Log our GTK versions
        gtk_version.logVersion();
        adw_version.logVersion();

        // Set gettext global domain to be our app so that our unqualified
        // translations map to our translations.
        internal_os.i18n.initGlobalDomain() catch |err| {
            // Failures shuldn't stop application startup. Our app may
            // not translate correctly but it should still work. In the
            // future we may want to add this to the GUI to show.
            log.warn("i18n initialization failed error={}", .{err});
        };

        // Load our configuration.
        var config = CoreConfig.load(alloc) catch |err| err: {
            // If we fail to load the configuration, then we should log
            // the error in the diagnostics so it can be shown to the user.
            // We can still load a default which only fails for OOM, allowing
            // us to startup.
            var def: CoreConfig = try .default(alloc);
            errdefer def.deinit();
            try def.addDiagnosticFmt(
                "error loading user configuration: {}",
                .{err},
            );

            break :err def;
        };
        defer config.deinit();

        // Setup our GTK init env vars
        setGtkEnv(&config) catch |err| switch (err) {
            error.NoSpaceLeft => {
                // If we fail to set GTK environment variables then we still
                // try to start the application...
                log.warn(
                    "error setting GTK environment variables err={}",
                    .{err},
                );
            },
        };
        adw.init();

        const single_instance = switch (config.@"gtk-single-instance") {
            .true => true,
            .false => false,
            .desktop => switch (config.@"launched-from".?) {
                .desktop, .systemd, .dbus => true,
                .cli => false,
            },
        };

        // Setup the flags for our application.
        const app_flags: gio.ApplicationFlags = app_flags: {
            var flags: gio.ApplicationFlags = .flags_default_flags;
            if (!single_instance) flags.non_unique = true;
            break :app_flags flags;
        };

        // Our app ID determines uniqueness and maps to our desktop file.
        // We append "-debug" to the ID if we're in debug mode so that we
        // can develop Ghostty in Ghostty.
        const app_id: [:0]const u8 = app_id: {
            if (config.class) |class| {
                if (gio.Application.idIsValid(class) != 0) {
                    break :app_id class;
                } else {
                    log.warn("invalid 'class' in config, ignoring", .{});
                }
            }

            break :app_id ApprtApp.application_id;
        };

        const display: *gdk.Display = gdk.Display.getDefault() orelse {
            // I'm unsure of any scenario where this happens. Because we don't
            // want to litter null checks everywhere, we just exit here.
            log.warn("gdk display is null, exiting", .{});
            std.posix.exit(1);
        };

        // Setup our windowing protocol logic
        var wp: winprotopkg.App = winprotopkg.App.init(
            alloc,
            display,
            app_id,
            &config,
        ) catch |err| wp: {
            // If we fail to detect or setup the windowing protocol
            // specifies, we fallback to a noop implementation so we can
            // still launch.
            log.warn("error initializing windowing protocol err={}", .{err});
            break :wp .{ .none = .{} };
        };
        errdefer wp.deinit(alloc);
        log.debug("windowing protocol={s}", .{@tagName(wp)});

        // Create our GTK Application which encapsulates our process.
        log.debug("creating GTK application id={s} single-instance={}", .{
            app_id,
            single_instance,
        });

        // Wrap our configuration in a GObject.
        const config_obj: *Config = try .new(alloc, &config);
        errdefer config_obj.unref();

        // Initialize the app.
        const self = gobject.ext.newInstance(Self, .{
            .application_id = app_id.ptr,
            .flags = app_flags,

            // Force the resource path to a known value so it doesn't depend
            // on the app id (which changes between debug/release and can be
            // user-configured) and force it to load in compiled resources.
            .resource_base_path = "/com/mitchellh/ghostty",
        });

        // Setup our private state. More setup is done in the init
        // callback that GObject calls, but we can't pass this data through
        // to there (and we don't need it there directly) so this is here.
        const priv = self.private();
        priv.* = .{
            .rt_app = rt_app,
            .core_app = core_app,
            .config = config_obj,
            .winproto = wp,
        };

        return self;
    }

    /// Force deinitialize the application.
    ///
    /// Normally in a GObject lifecycle, this would be called by the
    /// finalizer. But applications are never fully unreferenced so this
    /// ensures that our memory is cleaned up properly.
    pub fn deinit(self: *Self) void {
        const alloc = self.allocator();
        const priv = self.private();
        priv.config.unref();
        priv.winproto.deinit(alloc);
        if (priv.transient_cgroup_base) |base| alloc.free(base);
    }

    /// The global allocator that all other classes should use by
    /// calling `Application.default().allocator()`. Zig code should prefer
    /// this wherever possible so we get leak detection in debug/tests.
    pub fn allocator(self: *Self) std.mem.Allocator {
        return self.private().core_app.alloc;
    }

    /// Run the application. This is a replacement for `gio.Application.run`
    /// because we want more tight control over our event loop so we can
    /// integrate it with libghostty.
    pub fn run(self: *Self) !void {
        // Based on the actual `gio.Application.run` implementation:
        // https://github.com/GNOME/glib/blob/a8e8b742e7926e33eb635a8edceac74cf239d6ed/gio/gapplication.c#L2533

        // Acquire the default context for the application
        const ctx = glib.MainContext.default();
        if (glib.MainContext.acquire(ctx) == 0) return error.ContextAcquireFailed;

        // The final cleanup that is always required at the end of running.
        defer {
            // Ensure our timer source is removed
            self.stopQuitTimer();

            // Sync any remaining settings
            gio.Settings.sync();

            // Clear out the event loop, don't block.
            while (glib.MainContext.iteration(ctx, 0) != 0) {}

            // Release the context so something else can use it.
            defer glib.MainContext.release(ctx);
        }

        // Register the application
        var err_: ?*glib.Error = null;
        if (self.as(gio.Application).register(
            null,
            &err_,
        ) == 0) {
            if (err_) |err| {
                defer err.free();
                log.warn(
                    "error registering application: {s}",
                    .{err.f_message orelse "(unknown)"},
                );
            }

            return error.ApplicationRegisterFailed;
        }
        assert(err_ == null);

        // This just calls the `activate` signal but its part of the normal startup
        // routine so we just call it, but only if the config allows it (this allows
        // for launching Ghostty in the "background" without immediately opening
        // a window). An initial window will not be immediately created if we were
        // launched by D-Bus activation or systemd.  D-Bus activation will send it's
        // own `activate` or `new-window` signal later.
        //
        // https://gitlab.gnome.org/GNOME/glib/-/blob/bd2ccc2f69ecfd78ca3f34ab59e42e2b462bad65/gio/gapplication.c#L2302
        const priv = self.private();
        {
            // We need to scope any config access because once we run our
            // event loop, this can change out from underneath us.
            const config = priv.config.get();
            if (config.@"initial-window") switch (config.@"launched-from".?) {
                .desktop, .cli => self.as(gio.Application).activate(),
                .dbus, .systemd => {},
            };
        }

        // If we are NOT the primary instance, then we never want to run.
        // This means that another instance of the GTK app is running and
        // our "activate" call above will open a window.
        if (self.as(gio.Application).getIsRemote() != 0) {
            log.debug(
                "application is remote, exiting run loop after activation",
                .{},
            );
            return;
        }

        // Tell systemd that we are ready.
        systemd.notify.ready();

        log.debug("entering runloop", .{});
        defer log.debug("exiting runloop", .{});
        priv.running = true;
        while (priv.running) {
            _ = glib.MainContext.iteration(ctx, 1);

            // Tick the core Ghostty terminal app
            try priv.core_app.tick(priv.rt_app);

            // Check if we must quit based on the current state.
            const must_quit = q: {
                // If we are configured to always stay running, don't quit.
                const config = priv.config.get();
                if (!config.@"quit-after-last-window-closed") break :q false;

                // If the quit timer has expired, quit.
                if (priv.quit_timer == .expired) break :q true;

                // There's no quit timer running, or it hasn't expired, don't quit.
                break :q false;
            };

            if (must_quit) self.quit();
        }
    }

    /// Quit the application. This will start the process to stop the
    /// run loop. It will not `posix.exit`.
    pub fn quit(self: *Self) void {
        const priv = self.private();

        // If our run loop has already exited then we are done.
        if (!priv.running) return;

        // If our core app doesn't need to confirm quit then we
        // can exit immediately.
        if (!priv.core_app.needsConfirmQuit()) {
            self.quitNow();
            return;
        }

        // Get the parent for our dialog
        const parent: ?*gtk.Widget = parent: {
            const list = gtk.Window.listToplevels();
            defer list.free();
            const focused = list.findCustom(null, findActiveWindow);
            break :parent @ptrCast(@alignCast(focused.f_data));
        };

        // Show a confirmation dialog
        const dialog: *CloseConfirmationDialog = .new(.app);
        _ = CloseConfirmationDialog.signals.@"close-request".connect(
            dialog,
            *Application,
            handleCloseConfirmation,
            self,
            .{},
        );

        // Show it
        dialog.present(parent);
    }

    fn quitNow(self: *Self) void {
        // Get all our windows and destroy them, forcing them to free.
        const list = gtk.Window.listToplevels();
        defer list.free();
        list.foreach(struct {
            fn callback(data: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
                const ptr = data orelse return;
                const window: *gtk.Window = @ptrCast(@alignCast(ptr));

                // We only want to destroy our windows. These windows own
                // every other type of window that is possible so this will
                // trigger a proper shutdown sequence.
                //
                // We previously just destroyed ALL windows but this leads to
                // a double-free with the fcitx ime, because it has a nested
                // gtk.Window as a property that we don't own and it later
                // tries to free on its own. I think this is probably a bug in
                // the fcitx ime widget but still, we don't want a double free!
                if (gobject.ext.isA(window, Window)) {
                    window.destroy();
                }
            }
        }.callback, null);

        // Trigger our runloop exit.
        self.private().running = false;
    }

    /// apprt API to perform an action.
    pub fn performAction(
        self: *Self,
        target: apprt.Target,
        comptime action: apprt.Action.Key,
        value: apprt.Action.Value(action),
    ) !bool {
        switch (action) {
            .close_tab => Action.close(target, .tab),
            .close_window => Action.close(target, .window),

            .config_change => try Action.configChange(
                self,
                target,
                value.config,
            ),

            .mouse_over_link => Action.mouseOverLink(target, value),
            .mouse_shape => Action.mouseShape(target, value),
            .mouse_visibility => Action.mouseVisibility(target, value),

            .new_window => try Action.newWindow(
                self,
                switch (target) {
                    .app => null,
                    .surface => |v| v,
                },
            ),

            .pwd => Action.pwd(target, value),

            .quit => self.quit(),

            .quit_timer => try Action.quitTimer(self, value),

            .progress_report => return Action.progressReport(target, value),

            .reload_config => try Action.reloadConfig(self, target, value),

            .render => Action.render(target),

            .ring_bell => Action.ringBell(target),

            .set_title => Action.setTitle(target, value),

            .show_child_exited => return Action.showChildExited(target, value),

            .show_gtk_inspector => Action.showGtkInspector(),

            .toggle_maximize => Action.toggleMaximize(target),
            .toggle_fullscreen => Action.toggleFullscreen(target),

            // Unimplemented but todo on gtk-ng branch
            .new_tab,
            .goto_tab,
            .move_tab,
            .new_split,
            .resize_split,
            .equalize_splits,
            .goto_split,
            .open_config,
            .inspector,
            .desktop_notification,
            .present_terminal,
            .initial_size,
            .size_limit,
            .toggle_tab_overview,
            .toggle_split_zoom,
            .toggle_window_decorations,
            .prompt_title,
            .toggle_quick_terminal,
            .toggle_command_palette,
            .open_url,
            .close_all_windows,
            .float_window,
            .toggle_visibility,
            .cell_size,
            .key_sequence,
            .render_inspector,
            .renderer_health,
            .color_change,
            .reset_window_size,
            .check_for_updates,
            .undo,
            .redo,
            => {
                log.warn("unimplemented action={}", .{action});
                return false;
            },

            // Unimplemented
            .secure_input,
            => {
                log.warn("unimplemented action={}", .{action});
                return false;
            },
        }

        // Assume it was handled. The unhandled case must be explicit
        // in the switch above.
        return true;
    }

    /// Returns the core app associated with this application. This is
    /// not a reference-counted type so you should not store this.
    pub fn core(self: *Self) *CoreApp {
        return self.private().core_app;
    }

    /// Returns the apprt application associated with this application.
    pub fn rt(self: *Self) *ApprtApp {
        return self.private().rt_app;
    }

    /// Returns the app winproto implementation.
    pub fn winproto(self: *Self) *winprotopkg.App {
        return &self.private().winproto;
    }

    /// Returns the cgroup base (if any).
    pub fn cgroupBase(self: *Self) ?[]const u8 {
        return self.private().transient_cgroup_base;
    }

    /// This will get called when there are no more open surfaces.
    fn startQuitTimer(self: *Self) void {
        const priv = self.private();
        const config = priv.config.get();

        // Cancel any previous timer.
        self.stopQuitTimer();

        // This is a no-op unless we are configured to quit after last window is closed.
        if (!config.@"quit-after-last-window-closed") return;

        // If a delay is configured, set a timeout function to quit after the delay.
        if (config.@"quit-after-last-window-closed-delay") |v| {
            priv.quit_timer = .{
                .active = glib.timeoutAdd(
                    v.asMilliseconds(),
                    handleQuitTimerExpired,
                    self,
                ),
            };
        } else {
            // If no delay is configured, treat it as expired.
            priv.quit_timer = .expired;
        }
    }

    /// This will get called when a new surface gets opened.
    fn stopQuitTimer(self: *Self) void {
        const priv = self.private();
        switch (priv.quit_timer) {
            .off => {},
            .expired => priv.quit_timer = .off,
            .active => |source| {
                if (glib.Source.remove(source) == 0) {
                    log.warn(
                        "unable to remove quit timer source={d}",
                        .{source},
                    );
                }

                priv.quit_timer = .off;
            },
        }
    }

    //---------------------------------------------------------------
    // Properties

    /// Returns the configuration for this application.
    ///
    /// The reference count is increased.
    pub fn getConfig(self: *Self) *Config {
        return self.private().config.ref();
    }

    /// Set the configuration for this application. The reference count
    /// is increased on the new configuration and the old one is
    /// unreferenced.
    ///
    /// If the config has errors this may show the config errors dialog.
    fn setConfig(self: *Self, config: *Config) void {
        const priv = self.private();
        priv.config.unref();
        priv.config = config.ref();
        self.as(gobject.Object).notifyByPspec(properties.config.impl.param_spec);

        // Show our errors if we have any
        self.showConfigErrorsDialog();
    }

    //---------------------------------------------------------------
    // Libghostty Callbacks

    pub fn wakeup(self: *Self) void {
        _ = self;
        glib.MainContext.wakeup(null);
    }

    //---------------------------------------------------------------
    // Virtual Methods

    fn startup(self: *Self) callconv(.C) void {
        log.debug("startup", .{});

        gio.Application.virtual_methods.startup.call(
            Class.parent,
            self.as(Parent),
        );

        // Set ourselves as the default application.
        gio.Application.setDefault(self.as(gio.Application));

        // Setup our event loop
        self.startupXev();

        // Setup our style manager (light/dark mode)
        self.startupStyleManager();

        // Setup some signal handlers
        self.startupSignals();

        // Setup our action map
        self.startupActionMap();

        // Setup our cgroup for the application.
        self.startupCgroup() catch |err| {
            log.warn("cgroup initialization failed err={}", .{err});

            // Add it to our config diagnostics so it shows up in a GUI dialog.
            // Admittedly this has two issues: (1) we shuldn't be using the
            // config errors dialog for this long term and (2) using a mut
            // ref to the config wouldn't propagate changes to UI properly,
            // but we're in startup mode so its okay.
            const config = self.private().config.getMut();
            config.addDiagnosticFmt(
                "cgroup initialization failed: {}",
                .{err},
            ) catch {};
        };

        // If we have any config diagnostics from loading, then we
        // show the diagnostics dialog. We show this one as a general
        // modal (not to any specific window) because we don't even
        // know if the window will load.
        self.showConfigErrorsDialog();
    }

    /// Configure libxev to use a specific backend.
    ///
    /// This must be called before any other xev APIs are used.
    fn startupXev(self: *Self) void {
        const priv = self.private();
        const config = priv.config.get();

        // If our backend is auto then we have no setup to do.
        if (config.@"async-backend" == .auto) return;

        // Setup our event loop backend to the preferred method
        const result: bool = switch (config.@"async-backend") {
            .auto => unreachable,
            .epoll => if (comptime xev.dynamic) xev.prefer(.epoll) else false,
            .io_uring => if (comptime xev.dynamic) xev.prefer(.io_uring) else false,
        };

        if (result) {
            log.info(
                "libxev manual backend={s}",
                .{@tagName(xev.backend)},
            );
        } else {
            log.warn(
                "libxev manual backend failed, using default={s}",
                .{@tagName(xev.backend)},
            );
        }
    }

    /// Setup the style manager on startup. The primary task here is to
    /// setup our initial light/dark mode based on the configuration and
    /// setup listeners for changes to the style manager.
    fn startupStyleManager(self: *Self) void {
        const priv = self.private();
        const config = priv.config.get();

        // Setup our initial light/dark
        const style = self.as(adw.Application).getStyleManager();
        style.setColorScheme(switch (config.@"window-theme") {
            .auto, .ghostty => auto: {
                const lum = config.background.toTerminalRGB().perceivedLuminance();
                break :auto if (lum > 0.5)
                    .prefer_light
                else
                    .prefer_dark;
            },
            .system => .prefer_light,
            .dark => .force_dark,
            .light => .force_light,
        });

        // Setup color change notifications
        _ = gobject.Object.signals.notify.connect(
            style,
            *Self,
            handleStyleManagerDark,
            self,
            .{ .detail = "dark" },
        );
    }

    /// Setup signal handlers
    fn startupSignals(self: *Self) void {
        const priv = self.private();
        assert(priv.signal_source == null);
        priv.signal_source = glib.unixSignalAdd(
            std.posix.SIG.USR2,
            handleSigusr2,
            self,
        );
    }

    /// Setup our action map.
    fn startupActionMap(self: *Self) void {
        const t_variant_type = glib.ext.VariantType.newFor(u64);
        defer t_variant_type.free();

        const as_variant_type = glib.VariantType.new("as");
        defer as_variant_type.free();

        // The set of actions. Each action has (in order):
        // [0] The action name
        // [1] The callback function
        // [2] The glib.VariantType of the parameter
        //
        // For action names:
        // https://docs.gtk.org/gio/type_func.Action.name_is_valid.html
        const actions = .{
            .{ "new-window", actionNewWindow, null },
            .{ "new-window-command", actionNewWindow, as_variant_type },
            .{ "quit", actionQuit, null },
            .{ "reload-config", actionReloadConfig, null },
        };

        const action_map = self.as(gio.ActionMap);
        inline for (actions) |entry| {
            const action = gio.SimpleAction.new(
                entry[0],
                entry[2],
            );
            defer action.unref();
            _ = gio.SimpleAction.signals.activate.connect(
                action,
                *Self,
                entry[1],
                self,
                .{},
            );
            action_map.addAction(action.as(gio.Action));
        }
    }

    const CgroupError = error{
        DbusConnectionFailed,
        CgroupInitFailed,
    };

    /// Setup our cgroup for the application, if enabled.
    ///
    /// The setup for cgroups involves creating the cgroup for our
    /// application, moving ourselves into it, and storing the base path
    /// so that created surfaces can also have their own cgroups.
    fn startupCgroup(self: *Self) CgroupError!void {
        const priv = self.private();
        const config = priv.config.get();

        // If cgroup isolation isn't enabled then we don't do this.
        if (!switch (config.@"linux-cgroup") {
            .never => false,
            .always => true,
            .@"single-instance" => single: {
                const flags = self.as(gio.Application).getFlags();
                break :single !flags.non_unique;
            },
        }) {
            log.info(
                "cgroup isolation disabled via config={}",
                .{config.@"linux-cgroup"},
            );
            return;
        }

        // We need a dbus connection to do anything else
        const dbus = self.as(gio.Application).getDbusConnection() orelse {
            if (config.@"linux-cgroup-hard-fail") {
                log.err("dbus connection required for cgroup isolation, exiting", .{});
                return error.DbusConnectionFailed;
            }

            return;
        };

        const alloc = priv.core_app.alloc;
        const path = cgroup.init(alloc, dbus, .{
            .memory_high = config.@"linux-cgroup-memory-limit",
            .pids_max = config.@"linux-cgroup-processes-limit",
        }) catch |err| {
            // If we can't initialize cgroups then that's okay. We
            // want to continue to run so we just won't isolate surfaces.
            // NOTE(mitchellh): do we want a config to force it?
            log.warn(
                "failed to initialize cgroups, terminals will not be isolated err={}",
                .{err},
            );

            // If we have hard fail enabled then we exit now.
            if (config.@"linux-cgroup-hard-fail") {
                log.err("linux-cgroup-hard-fail enabled, exiting", .{});
                return error.CgroupInitFailed;
            }

            return;
        };

        log.info("cgroup isolation enabled base={s}", .{path});
        priv.transient_cgroup_base = path;
    }

    fn activate(self: *Self) callconv(.C) void {
        log.debug("activate", .{});

        // Queue a new window
        const priv = self.private();
        _ = priv.core_app.mailbox.push(.{
            .new_window = .{},
        }, .{ .forever = {} });

        // Call the parent activate method.
        gio.Application.virtual_methods.activate.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn dispose(self: *Self) callconv(.C) void {
        const priv = self.private();
        if (priv.config_errors_dialog.get()) |diag| {
            diag.close();
            diag.unref(); // strong ref from get()
        }
        if (priv.signal_source) |v| {
            if (glib.Source.remove(v) == 0) {
                log.warn("unable to remove signal source", .{});
            }
            priv.signal_source = null;
        }

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn finalize(self: *Self) callconv(.C) void {
        self.deinit();
        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    //---------------------------------------------------------------
    // Signal Handlers

    /// SIGUSR2 signal handler via g_unix_signal_add
    fn handleSigusr2(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse
            return @intFromBool(glib.SOURCE_CONTINUE)));

        log.info("received SIGUSR2, reloading configuration", .{});
        Action.reloadConfig(
            self,
            .app,
            .{},
        ) catch |err| {
            // If we fail to reload the configuration, then we want the
            // user to know it. For now we log but we should show another
            // GUI.
            log.warn("error reloading config: {}", .{err});
        };

        return @intFromBool(glib.SOURCE_CONTINUE);
    }

    fn handleCloseConfirmation(
        _: *CloseConfirmationDialog,
        self: *Self,
    ) callconv(.c) void {
        self.quitNow();
    }

    fn handleQuitTimerExpired(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud));
        const priv = self.private();
        priv.quit_timer = .expired;
        return 0;
    }

    fn handleStyleManagerDark(
        style: *adw.StyleManager,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        _ = self;

        const color_scheme: apprt.ColorScheme = if (style.getDark() == 0)
            .light
        else
            .dark;

        log.debug("style manager changed scheme={}", .{color_scheme});
    }

    fn handleReloadConfig(
        _: *ConfigErrorsDialog,
        self: *Self,
    ) callconv(.c) void {
        // We clear our dialog reference because its going to close
        // after response handling and we don't want to reuse it.
        const priv = self.private();
        priv.config_errors_dialog.set(null);

        // Reload our config as if the app reloaded.
        Action.reloadConfig(
            self,
            .app,
            .{},
        ) catch |err| {
            // If we fail to reload the configuration, then we want the
            // user to know it. For now we log but we should show another
            // GUI.
            log.warn("error reloading config: {}", .{err});
        };
    }

    /// Show the config errors dialog if the config on our application
    /// has diagnostics.
    fn showConfigErrorsDialog(self: *Self) void {
        const priv = self.private();

        // If we already have a dialog, just update the config.
        if (priv.config_errors_dialog.get()) |diag| {
            defer diag.unref(); // get gets a strong ref

            var value = gobject.ext.Value.newFrom(priv.config);
            defer value.unset();
            gobject.Object.setProperty(
                diag.as(gobject.Object),
                "config",
                &value,
            );

            if (!priv.config.hasDiagnostics()) {
                diag.close();
            } else {
                diag.present(null);
            }

            return;
        }

        // No diagnostics, do nothing.
        if (!priv.config.hasDiagnostics()) return;

        // No dialog yet, initialize a new one. There's no need to unref
        // here because the widget that it becomes a part of takes ownership.
        const dialog: *ConfigErrorsDialog = .new(priv.config);
        priv.config_errors_dialog.set(dialog);

        // Connect to the reload signal so we know to reload our config.
        _ = ConfigErrorsDialog.signals.@"reload-config".connect(
            dialog,
            *Application,
            handleReloadConfig,
            self,
            .{},
        );

        // Show it
        dialog.present(null);
    }

    fn actionReloadConfig(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        priv.core_app.performAction(self.rt(), .reload_config) catch |err| {
            log.warn("error reloading config err={}", .{err});
        };
    }

    fn actionQuit(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        priv.core_app.performAction(self.rt(), .quit) catch |err| {
            log.warn("error quitting err={}", .{err});
        };
    }

    /// Handle `app.new-window` and `app.new-window-command` GTK actions
    pub fn actionNewWindow(
        _: *gio.SimpleAction,
        parameter_: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        log.debug("received new window action", .{});

        parameter: {
            // were we given a parameter?
            const parameter = parameter_ orelse break :parameter;

            const as_variant_type = glib.VariantType.new("as");
            defer as_variant_type.free();

            // ensure that the supplied parameter is an array of strings
            if (glib.Variant.isOfType(parameter, as_variant_type) == 0) {
                log.warn("parameter is of type {s}", .{parameter.getTypeString()});
                break :parameter;
            }

            const s_variant_type = glib.VariantType.new("s");
            defer s_variant_type.free();

            var it: glib.VariantIter = undefined;
            _ = it.init(parameter);

            while (it.nextValue()) |value| {
                defer value.unref();

                // just to be sure
                if (value.isOfType(s_variant_type) == 0) continue;

                var len: usize = undefined;
                const buf = value.getString(&len);
                const str = buf[0..len];

                log.debug("new-window command argument: {s}", .{str});
            }
        }

        _ = self.core().mailbox.push(.{
            .new_window = .{},
        }, .{ .forever = {} });
    }

    //----------------------------------------------------------------
    // Boilerplate/Noise

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.C) void {
            // Register our compiled resources exactly once.
            {
                const c = @cImport({
                    // generated header files
                    @cInclude("ghostty_resources.h");
                });
                if (c.ghostty_get_resource()) |ptr| {
                    gio.resourcesRegister(@ptrCast(@alignCast(ptr)));
                } else {
                    // If we fail to load resources then things will
                    // probably look really bad but it shouldn't stop our
                    // app from loading.
                    log.warn("unable to load resources", .{});
                }
            }

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.config.impl,
            });

            // Virtual methods
            gio.Application.virtual_methods.activate.implement(class, &activate);
            gio.Application.virtual_methods.startup.implement(class, &startup);
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }
    };
};

/// All apprt action handlers
const Action = struct {
    pub fn close(
        target: apprt.Target,
        scope: Surface.CloseScope,
    ) void {
        switch (target) {
            .app => {},
            .surface => |v| v.rt_surface.surface.close(scope),
        }
    }

    pub fn configChange(
        self: *Application,
        target: apprt.Target,
        new_config: *const CoreConfig,
    ) !void {
        // Wrap our config in a GObject. This will clone it.
        const alloc = self.allocator();
        const config_obj: *Config = try .new(alloc, new_config);
        defer config_obj.unref();

        switch (target) {
            .surface => |core| core.rt_surface.surface.setConfig(config_obj),
            .app => self.setConfig(config_obj),
        }
    }

    pub fn mouseOverLink(
        target: apprt.Target,
        value: apprt.action.MouseOverLink,
    ) void {
        switch (target) {
            .app => log.warn("mouse over link to app is unexpected", .{}),
            .surface => |surface| {
                var v = gobject.ext.Value.new([:0]const u8);
                if (value.url.len > 0) gobject.ext.Value.set(&v, value.url);
                defer v.unset();
                gobject.Object.setProperty(
                    surface.rt_surface.gobj().as(gobject.Object),
                    "mouse-hover-url",
                    &v,
                );
            },
        }
    }

    pub fn mouseShape(
        target: apprt.Target,
        shape: terminal.MouseShape,
    ) void {
        switch (target) {
            .app => log.warn("mouse shape to app is unexpected", .{}),
            .surface => |surface| {
                var value = gobject.ext.Value.newFrom(shape);
                defer value.unset();
                gobject.Object.setProperty(
                    surface.rt_surface.gobj().as(gobject.Object),
                    "mouse-shape",
                    &value,
                );
            },
        }
    }

    pub fn mouseVisibility(
        target: apprt.Target,
        visibility: apprt.action.MouseVisibility,
    ) void {
        switch (target) {
            .app => log.warn("mouse visibility to app is unexpected", .{}),
            .surface => |surface| {
                var value = gobject.ext.Value.newFrom(switch (visibility) {
                    .visible => false,
                    .hidden => true,
                });
                defer value.unset();
                gobject.Object.setProperty(
                    surface.rt_surface.gobj().as(gobject.Object),
                    "mouse-hidden",
                    &value,
                );
            },
        }
    }

    pub fn newWindow(
        self: *Application,
        parent: ?*CoreSurface,
    ) !void {
        const win = Window.new(self, parent);

        // Setup a binding so that whenever our config changes so does the
        // window. There's never a time when the window config should be out
        // of sync with the application config.
        _ = gobject.Object.bindProperty(
            self.as(gobject.Object),
            "config",
            win.as(gobject.Object),
            "config",
            .{},
        );

        // Show the window
        gtk.Window.present(win.as(gtk.Window));
    }

    pub fn pwd(
        target: apprt.Target,
        value: apprt.action.Pwd,
    ) void {
        switch (target) {
            .app => log.warn("pwd to app is unexpected", .{}),
            .surface => |surface| {
                var v = gobject.ext.Value.newFrom(value.pwd);
                defer v.unset();
                gobject.Object.setProperty(
                    surface.rt_surface.gobj().as(gobject.Object),
                    "pwd",
                    &v,
                );
            },
        }
    }

    pub fn quitTimer(
        self: *Application,
        mode: apprt.action.QuitTimer,
    ) !void {
        switch (mode) {
            .start => self.startQuitTimer(),
            .stop => self.stopQuitTimer(),
        }
    }

    pub fn progressReport(
        target: apprt.Target,
        value: terminal.osc.Command.ProgressReport,
    ) bool {
        return switch (target) {
            .app => false,
            .surface => |v| surface: {
                v.rt_surface.surface.setProgressReport(value);
                break :surface true;
            },
        };
    }

    /// Reload the configuration for the application and propagate it
    /// across the entire application and all terminals.
    pub fn reloadConfig(
        self: *Application,
        target: apprt.Target,
        opts: apprt.action.ReloadConfig,
    ) !void {
        // Tell systemd that reloading has started.
        systemd.notify.reloading();

        // When we exit this function tell systemd that reloading has finished.
        defer systemd.notify.ready();

        // Get our config object.
        const config: *Config = config: {
            // Soft-reloading applies conditional logic to the existing loaded
            // config so we return that as-is (but take a reference).
            if (opts.soft) {
                break :config self.private().config.ref();
            }

            // Hard reload, load a new config completely.
            const alloc = self.allocator();
            var config = try CoreConfig.load(alloc);
            defer config.deinit();
            break :config try .new(alloc, &config);
        };
        defer config.unref();

        // Update the proper target. This will trigger a `confige_change`
        // apprt action which will propagate the config properly to our
        // property system.
        switch (target) {
            .app => try self.core().updateConfig(
                self.rt(),
                config.get(),
            ),
            .surface => |core| try core.updateConfig(config.get()),
        }
    }

    pub fn render(target: apprt.Target) void {
        switch (target) {
            .app => {},
            .surface => |v| v.rt_surface.surface.redraw(),
        }
    }

    pub fn ringBell(target: apprt.Target) void {
        switch (target) {
            .app => {},
            .surface => |v| v.rt_surface.surface.ringBell(),
        }
    }

    pub fn setTitle(
        target: apprt.Target,
        value: apprt.action.SetTitle,
    ) void {
        switch (target) {
            .app => log.warn("set_title to app is unexpected", .{}),
            .surface => |surface| {
                var v = gobject.ext.Value.newFrom(value.title);
                defer v.unset();
                gobject.Object.setProperty(
                    surface.rt_surface.gobj().as(gobject.Object),
                    "title",
                    &v,
                );
            },
        }
    }

    pub fn showChildExited(
        target: apprt.Target,
        value: apprt.surface.Message.ChildExited,
    ) bool {
        return switch (target) {
            .app => false,
            .surface => |v| v.rt_surface.surface.childExited(value),
        };
    }

    pub fn showGtkInspector() void {
        gtk.Window.setInteractiveDebugging(@intFromBool(true));
    }

    pub fn toggleFullscreen(target: apprt.Target) void {
        switch (target) {
            .app => {},
            .surface => |v| v.rt_surface.surface.toggleFullscreen(),
        }
    }

    pub fn toggleMaximize(target: apprt.Target) void {
        switch (target) {
            .app => {},
            .surface => |v| v.rt_surface.surface.toggleMaximize(),
        }
    }
};

/// This sets various GTK-related environment variables as necessary
/// given the runtime environment or configuration.
///
/// This must be called BEFORE GTK initialization.
fn setGtkEnv(config: *const CoreConfig) error{NoSpaceLeft}!void {
    assert(gtk.isInitialized() == 0);

    var gdk_debug: struct {
        /// output OpenGL debug information
        opengl: bool = false,
        /// disable GLES, Ghostty can't use GLES
        @"gl-disable-gles": bool = false,
        // GTK's new renderer can cause blurry font when using fractional scaling.
        @"gl-no-fractional": bool = false,
        /// Disabling Vulkan can improve startup times by hundreds of
        /// milliseconds on some systems. We don't use Vulkan so we can just
        /// disable it.
        @"vulkan-disable": bool = false,
    } = .{
        .opengl = config.@"gtk-opengl-debug",
    };

    var gdk_disable: struct {
        @"gles-api": bool = false,
        /// current gtk implementation for color management is not good enough.
        /// see: https://bugs.kde.org/show_bug.cgi?id=495647
        /// gtk issue: https://gitlab.gnome.org/GNOME/gtk/-/issues/6864
        @"color-mgmt": bool = true,
        /// Disabling Vulkan can improve startup times by hundreds of
        /// milliseconds on some systems. We don't use Vulkan so we can just
        /// disable it.
        vulkan: bool = false,
    } = .{};

    environment: {
        if (gtk_version.runtimeAtLeast(4, 18, 0)) {
            gdk_disable.@"color-mgmt" = false;
        }

        if (gtk_version.runtimeAtLeast(4, 16, 0)) {
            // From gtk 4.16, GDK_DEBUG is split into GDK_DEBUG and GDK_DISABLE.
            // For the remainder of "why" see the 4.14 comment below.
            gdk_disable.@"gles-api" = true;
            gdk_disable.vulkan = true;
            break :environment;
        }
        if (gtk_version.runtimeAtLeast(4, 14, 0)) {
            // We need to export GDK_DEBUG to run on Wayland after GTK 4.14.
            // Older versions of GTK do not support these values so it is safe
            // to always set this. Forwards versions are uncertain so we'll have
            // to reassess...
            //
            // Upstream issue: https://gitlab.gnome.org/GNOME/gtk/-/issues/6589
            gdk_debug.@"gl-disable-gles" = true;
            gdk_debug.@"vulkan-disable" = true;

            if (gtk_version.runtimeUntil(4, 17, 5)) {
                // Removed at GTK v4.17.5
                gdk_debug.@"gl-no-fractional" = true;
            }
            break :environment;
        }

        // Versions prior to 4.14 are a bit of an unknown for Ghostty. It
        // is an environment that isn't tested well and we don't have a
        // good understanding of what we may need to do.
        gdk_debug.@"vulkan-disable" = true;
    }

    {
        var buf: [1024]u8 = undefined;
        var fmt = std.io.fixedBufferStream(&buf);
        const writer = fmt.writer();
        var first: bool = true;
        inline for (@typeInfo(@TypeOf(gdk_debug)).@"struct".fields) |field| {
            if (@field(gdk_debug, field.name)) {
                if (!first) try writer.writeAll(",");
                try writer.writeAll(field.name);
                first = false;
            }
        }
        try writer.writeByte(0);
        const value = fmt.getWritten();
        log.warn("setting GDK_DEBUG={s}", .{value[0 .. value.len - 1]});
        _ = internal_os.setenv("GDK_DEBUG", value[0 .. value.len - 1 :0]);
    }

    {
        var buf: [1024]u8 = undefined;
        var fmt = std.io.fixedBufferStream(&buf);
        const writer = fmt.writer();
        var first: bool = true;
        inline for (@typeInfo(@TypeOf(gdk_disable)).@"struct".fields) |field| {
            if (@field(gdk_disable, field.name)) {
                if (!first) try writer.writeAll(",");
                try writer.writeAll(field.name);
                first = false;
            }
        }
        try writer.writeByte(0);
        const value = fmt.getWritten();
        log.warn("setting GDK_DISABLE={s}", .{value[0 .. value.len - 1]});
        _ = internal_os.setenv("GDK_DISABLE", value[0 .. value.len - 1 :0]);
    }
}

fn findActiveWindow(data: ?*const anyopaque, _: ?*const anyopaque) callconv(.c) c_int {
    const window: *gtk.Window = @ptrCast(@alignCast(@constCast(data orelse return -1)));

    // Confusingly, `isActive` returns 1 when active,
    // but we want to return 0 to indicate equality.
    // Abusing integers to be enums and booleans is a terrible idea, C.
    return if (window.isActive() != 0) 0 else -1;
}
