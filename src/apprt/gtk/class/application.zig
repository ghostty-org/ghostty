const std = @import("std");
const assert = @import("../../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const build_config = @import("../../../build_config.zig");
const state = &@import("../../../global.zig").state;
const i18n = @import("../../../os/main.zig").i18n;
const apprt = @import("../../../apprt.zig");
const CoreApp = @import("../../../App.zig");
const configpkg = @import("../../../config.zig");
const input = @import("../../../input.zig");
const internal_os = @import("../../../os/main.zig");
const systemd = @import("../../../os/systemd.zig");
const terminal = @import("../../../terminal/main.zig");
const xev = @import("../../../global.zig").xev;
const Binding = @import("../../../input.zig").Binding;
const CoreConfig = configpkg.Config;
const CoreSurface = @import("../../../Surface.zig");

const ext = @import("../ext.zig");
const key = @import("../key.zig");
const adw_version = @import("../adw_version.zig");
const gtk_version = @import("../gtk_version.zig");
const winprotopkg = @import("../winproto.zig");
const ApprtApp = @import("../App.zig");
const Common = @import("../class.zig").Common;
const WeakRef = @import("../weak_ref.zig").WeakRef;
const Config = @import("config.zig").Config;
const Surface = @import("surface.zig").Surface;
const SplitTree = @import("split_tree.zig").SplitTree;
const Window = @import("window.zig").Window;
const Tab = @import("tab.zig").Tab;
const CloseConfirmationDialog = @import("close_confirmation_dialog.zig").CloseConfirmationDialog;
const ConfigErrorsDialog = @import("config_errors_dialog.zig").ConfigErrorsDialog;
const GlobalShortcuts = @import("global_shortcuts.zig").GlobalShortcuts;

const log = std.log.scoped(.gtk_ghostty_application);

/// Function used to funnel GLib/GObject/GTK log messages into Zig's logging
/// system rather than just getting dumped directly to stderr.
fn glibLogWriterFunction(
    level: glib.LogLevelFlags,
    fields: [*]const glib.LogField,
    n_fields: usize,
    _: ?*anyopaque,
) callconv(.c) glib.LogWriterOutput {
    const glib_log = std.log.scoped(.glib);

    var message_: ?[]const u8 = null;
    var domain_: ?[]const u8 = null;
    for (0..n_fields) |i| {
        const field = fields[i];
        const k = std.mem.span(field.f_key orelse continue);
        const v: []const u8 = v: {
            if (field.f_length >= 0) {
                const v: [*]const u8 = @ptrCast(field.f_value orelse continue);
                break :v v[0..@intCast(field.f_length)];
            }
            const v: [*:0]const u8 = @ptrCast(field.f_value orelse continue);
            break :v std.mem.span(v);
        };
        if (std.mem.eql(u8, k, "MESSAGE")) {
            message_ = v;
            continue;
        }
        if (std.mem.eql(u8, k, "GLIB_DOMAIN")) {
            domain_ = v;
            continue;
        }
    }

    const message = message_ orelse return .unhandled;
    const domain = domain_ orelse "«unknown»";

    if (level.level_error) {
        glib_log.err("ERROR: {s}: {s}", .{ domain, message });
        return .handled;
    }
    if (level.level_critical) {
        glib_log.err("CRITICAL: {s}: {s}", .{ domain, message });
        return .handled;
    }
    if (level.level_warning) {
        glib_log.warn("WARNING: {s}: {s}", .{ domain, message });
        return .handled;
    }
    if (level.level_message) {
        glib_log.info("MESSAGE: {s}: {s}", .{ domain, message });
        return .handled;
    }
    if (level.level_info) {
        glib_log.info("INFO: {s}: {s}", .{ domain, message });
        return .handled;
    }
    if (level.level_debug) {
        glib_log.debug("DEBUG: {s}: {s}", .{ domain, message });
        return .handled;
    }
    glib_log.debug("UNKNOWN: {s}: {s}", .{ domain, message });
    return .handled;
}

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

        /// The global shortcut logic.
        global_shortcuts: *GlobalShortcuts,

        /// This is set to true so long as we request a window exactly
        /// once. This prevents quitting the app before we've shown one
        /// window.
        requested_window: bool = false,

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
        config_errors_dialog: WeakRef(ConfigErrorsDialog) = .empty,

        /// glib source for our signal handler.
        signal_source: ?c_uint = null,

        /// CSS Provider for any styles based on Ghostty configuration values.
        css_provider: *gtk.CssProvider,

        /// Providers for loading custom stylesheets defined by user
        custom_css_providers: std.ArrayListUnmanaged(*gtk.CssProvider) = .empty,

        /// A copy of the LANG environment variable that was provided to Ghostty
        /// by the system. If this is null, the LANG environment variable did
        /// not exist in Ghostty's environment variable.
        saved_language: ?[:0]const u8 = null,

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

        // Capture GLib/GObject/GTK log messages and funnel them through Zig's
        // logging system rather than just getting dumped directly to stderr.
        _ = glib.logSetWriterFunc(glibLogWriterFunction, null, null);

        // Log our GTK versions
        gtk_version.logVersion();
        adw_version.logVersion();

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

        const saved_language: ?[:0]const u8 = saved_language: {
            const old_language = old_language: {
                const result = (internal_os.getenv(alloc, "LANG") catch break :old_language null) orelse break :old_language null;
                defer result.deinit(alloc);
                break :old_language alloc.dupeZ(u8, result.value) catch break :old_language null;
            };

            if (config.language) |language| _ = internal_os.setenv("LANG", language);

            break :saved_language old_language;
        };

        // Set gettext global domain to be our app so that our unqualified
        // translations map to our translations.
        internal_os.i18n.initGlobalDomain() catch |err| {
            // Failures shuldn't stop application startup. Our app may
            // not translate correctly but it should still work. In the
            // future we may want to add this to the GUI to show.
            log.warn("i18n initialization failed error={}", .{err});
        };

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
            // This should have been resolved to true/false during config loading.
            .detect => unreachable,
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

        // Internally, GTK ensures that only one instance of this provider
        // exists in the provider list for the display.
        const css_provider = gtk.CssProvider.new();
        gtk.StyleContext.addProviderForDisplay(
            display,
            css_provider.as(gtk.StyleProvider),
            gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 3,
        );
        errdefer css_provider.unref();

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
        const priv: *Private = self.private();
        priv.* = .{
            .rt_app = rt_app,
            .core_app = core_app,
            .config = config_obj,
            .winproto = wp,
            .css_provider = css_provider,
            .custom_css_providers = .empty,
            .global_shortcuts = gobject.ext.newInstance(GlobalShortcuts, .{}),
            .saved_language = saved_language,
        };

        // Signals
        _ = gobject.Object.signals.notify.connect(
            self,
            *Self,
            propConfig,
            self,
            .{ .detail = "config" },
        );

        _ = gtk.CssProvider.signals.parsing_error.connect(
            css_provider,
            *Self,
            signalCssParsingError,
            self,
            .{},
        );

        // Trigger initial config changes
        self.as(gobject.Object).notifyByPspec(properties.config.impl.param_spec);

        return self;
    }

    /// Force deinitialize the application.
    ///
    /// Normally in a GObject lifecycle, this would be called by the
    /// finalizer. But applications are never fully unreferenced so this
    /// ensures that our memory is cleaned up properly.
    pub fn deinit(self: *Self) void {
        const alloc = self.allocator();
        const priv: *Private = self.private();
        priv.config.unref();
        priv.winproto.deinit(alloc);
        priv.global_shortcuts.unref();
        if (priv.saved_language) |language| alloc.free(language);
        if (gdk.Display.getDefault()) |display| {
            gtk.StyleContext.removeProviderForDisplay(
                display,
                priv.css_provider.as(gtk.StyleProvider),
            );

            for (priv.custom_css_providers.items) |provider| {
                gtk.StyleContext.removeProviderForDisplay(
                    display,
                    provider.as(gtk.StyleProvider),
                );
            }
        }
        priv.css_provider.unref();
        for (priv.custom_css_providers.items) |provider| provider.unref();
        priv.custom_css_providers.deinit(alloc);
    }

    /// The global allocator that all other classes should use by
    /// calling `Application.default().allocator()`. Zig code should prefer
    /// this wherever possible so we get leak detection in debug/tests.
    pub fn allocator(self: *Self) std.mem.Allocator {
        return self.private().core_app.alloc;
    }

    /// Get the original language that Ghostty was launched with. This returns a
    /// pointer to internal memory so it must be copied by callers.
    pub fn savedLanguage(self: *Self) ?[:0]const u8 {
        return self.private().saved_language;
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
        // a window).
        //
        // https://gitlab.gnome.org/GNOME/glib/-/blob/bd2ccc2f69ecfd78ca3f34ab59e42e2b462bad65/gio/gapplication.c#L2302
        const priv = self.private();
        {
            // We need to scope any config access because once we run our
            // event loop, this can change out from underneath us.
            const config = priv.config.get();
            if (config.@"initial-window") self.as(gio.Application).activate();
        }

        // If we are NOT the primary instance, then we never want to run.
        // This means that another instance of the GTK app is running.
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
                if (priv.quit_timer == .expired) {
                    log.debug("must_quit due to quit timer expired", .{});
                    break :q true;
                }

                // If we have no windows attached to our app, also quit.
                // We only do this if we don't have the closed delay set,
                // because with the closed delay set we'll exit eventually.
                if (config.@"quit-after-last-window-closed-delay" == null) {
                    if (priv.requested_window and @as(
                        ?*glib.List,
                        self.as(gtk.Application).getWindows(),
                    ) == null) {
                        log.debug("must_quit due to no app windows", .{});
                        break :q true;
                    }
                }

                // No quit conditions met
                break :q false;
            };

            if (must_quit) {
                // All must quit scenarios do not need confirmation.
                // Furthermore, must quit scenarios may result in a situation
                // where its unsafe to even access the app/surface memory
                // since its in the process of being freed. We must simply
                // begin our exit immediately.
                self.quitNow();
            }
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
            const focused = @as(?*glib.List, list.findCustom(
                null,
                findActiveWindow,
            )) orelse {
                // If we have an active surface then we should have
                // a window available but in the rare case we don't we
                // should exit so we don't crash.
                break :parent null;
            };
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
            .close_tab => return Action.closeTab(target, value),
            .close_window => return Action.closeWindow(target),

            .copy_title_to_clipboard => return Action.copyTitleToClipboard(target),

            .config_change => try Action.configChange(
                self,
                target,
                value.config,
            ),

            .desktop_notification => Action.desktopNotification(self, target, value),

            .equalize_splits => return Action.equalizeSplits(target),

            .goto_split => return Action.gotoSplit(target, value),

            .goto_window => return Action.gotoWindow(value),

            .goto_tab => return Action.gotoTab(target, value),

            .initial_size => return Action.initialSize(target, value),

            .inspector => return Action.controlInspector(target, value),

            .key_sequence => return Action.keySequence(target, value),
            .key_table => return Action.keyTable(target, value),

            .mouse_over_link => Action.mouseOverLink(target, value),
            .mouse_shape => Action.mouseShape(target, value),
            .mouse_visibility => Action.mouseVisibility(target, value),

            .move_tab => return Action.moveTab(target, value),

            .new_split => return Action.newSplit(target, value),

            .new_tab => return Action.newTab(target),

            .new_window => try Action.newWindow(
                self,
                switch (target) {
                    .app => null,
                    .surface => |v| v,
                },
            ),

            .open_config => return Action.openConfig(self),

            .open_url => Action.openUrl(self, value),

            .pwd => Action.pwd(target, value),

            .present_terminal => return Action.presentTerminal(target),

            .progress_report => return Action.progressReport(target, value),

            .prompt_title => return Action.promptTitle(target, value),

            .quit => self.quit(),

            .quit_timer => try Action.quitTimer(self, value),

            .reload_config => try Action.reloadConfig(self, target, value),

            .render => Action.render(target),

            .resize_split => return Action.resizeSplit(target, value),

            .ring_bell => Action.ringBell(target),

            .scrollbar => Action.scrollbar(target, value),

            .set_title => Action.setTitle(target, value),

            .show_child_exited => return Action.showChildExited(target, value),

            .show_gtk_inspector => Action.showGtkInspector(),

            .size_limit => return Action.sizeLimit(target, value),

            .toggle_maximize => Action.toggleMaximize(target),
            .toggle_fullscreen => Action.toggleFullscreen(target),
            .toggle_quick_terminal => return Action.toggleQuickTerminal(self),
            .toggle_tab_overview => return Action.toggleTabOverview(target),
            .toggle_window_decorations => return Action.toggleWindowDecorations(target),
            .toggle_command_palette => return Action.toggleCommandPalette(target),
            .toggle_split_zoom => return Action.toggleSplitZoom(target),
            .show_on_screen_keyboard => return Action.showOnScreenKeyboard(target),
            .command_finished => return Action.commandFinished(target, value),
            .readonly => return Action.setReadonly(target, value),

            .start_search => Action.startSearch(target, value),
            .end_search => Action.endSearch(target),
            .search_total => Action.searchTotal(target, value),
            .search_selected => Action.searchSelected(target, value),

            // Unimplemented
            .secure_input,
            .close_all_windows,
            .float_window,
            .toggle_visibility,
            .toggle_background_opacity,
            .cell_size,
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

    fn loadRuntimeCss(self: *Self) (Allocator.Error || std.Io.Writer.Error)!void {
        const alloc = self.allocator();
        const priv: *Private = self.private();
        const config = priv.config.get();

        var buf: std.Io.Writer.Allocating = try .initCapacity(alloc, 2048);
        defer buf.deinit();

        const writer = &buf.writer;

        // Load standard css first as it can override some of the user configured styling.
        try loadRuntimeCss414(config, writer);
        try loadRuntimeCss416(config, writer);

        const unfocused_fill: CoreConfig.Color = config.@"unfocused-split-fill" orelse config.background;

        try writer.print(
            \\widget.unfocused-split {{
            \\ opacity: {d:.2};
            \\ background-color: rgb({d},{d},{d});
            \\}}
            \\
        , .{
            1.0 - config.@"unfocused-split-opacity",
            unfocused_fill.r,
            unfocused_fill.g,
            unfocused_fill.b,
        });

        if (config.@"split-divider-color") |color| {
            try writer.print(
                \\.window .split paned > separator {{
                \\  color: rgb({[r]d},{[g]d},{[b]d});
                \\  background: rgb({[r]d},{[g]d},{[b]d});
                \\}}
                \\
            , .{
                .r = color.r,
                .g = color.g,
                .b = color.b,
            });
        }

        if (config.@"window-title-font-family") |font_family| {
            try writer.print(
                \\.window headerbar {{
                \\  font-family: "{[font_family]s}";
                \\}}
                \\
            , .{ .font_family = font_family });
        }

        const contents = buf.written();

        log.debug("runtime CSS is {d} bytes", .{contents.len});

        const bytes = glib.Bytes.new(contents.ptr, contents.len);
        defer bytes.unref();

        // Clears any previously loaded CSS from this provider
        priv.css_provider.loadFromBytes(bytes);
    }

    /// Load runtime CSS for older than GTK 4.16
    fn loadRuntimeCss414(
        config: *const CoreConfig,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        if (gtk_version.runtimeAtLeast(4, 16, 0)) return;

        const window_theme = config.@"window-theme";
        const headerbar_background = config.@"window-titlebar-background" orelse config.background;
        const headerbar_foreground = config.@"window-titlebar-foreground" orelse config.foreground;

        switch (window_theme) {
            .ghostty => try writer.print(
                \\windowhandle {{
                \\  background-color: rgb({d},{d},{d});
                \\  color: rgb({d},{d},{d});
                \\}}
                \\windowhandle:backdrop {{
                \\ background-color: oklab(from rgb({d},{d},{d}) calc(l * 0.9) a b / alpha);
                \\}}
                \\
            , .{
                headerbar_background.r,
                headerbar_background.g,
                headerbar_background.b,
                headerbar_foreground.r,
                headerbar_foreground.g,
                headerbar_foreground.b,
                headerbar_background.r,
                headerbar_background.g,
                headerbar_background.b,
            }),
            else => {},
        }
    }

    /// Load runtime for GTK 4.16 and newer
    fn loadRuntimeCss416(
        config: *const CoreConfig,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        if (gtk_version.runtimeUntil(4, 16, 0)) return;

        const window_theme = config.@"window-theme";
        const headerbar_background = config.@"window-titlebar-background" orelse config.background;
        const headerbar_foreground = config.@"window-titlebar-foreground" orelse config.foreground;

        try writer.writeAll(
            \\/*
            \\ * Child Exited Overlay
            \\ */
            \\
            \\.child-exited.normal revealer widget {
            \\  background-color: color-mix(
            \\    in srgb,
            \\    var(--success-bg-color),
            \\    transparent 50%
            \\  );
            \\}
            \\
            \\.child-exited.abnormal revealer widget {
            \\  background-color: color-mix(
            \\    in srgb,
            \\    var(--error-bg-color),
            \\    transparent 50%
            \\  );
            \\}
            \\
            \\/*
            \\ * Surface
            \\ */
            \\
            \\.surface progressbar.error trough progress {
            \\  background-color: color-mix(
            \\    in srgb,
            \\    var(--error-bg-color),
            \\    transparent 50%
            \\  );
            \\}
            \\
            \\.surface .bell-overlay {
            \\  border-color: color-mix(
            \\    in srgb,
            \\    var(--accent-color),
            \\    transparent 50%
            \\  );
            \\}
            \\
            \\/*
            \\ * Splits
            \\ */
            \\
            \\.window .split paned > separator {
            \\  background-color: color-mix(
            \\    in srgb,
            \\    var(--window-bg-color),
            \\    transparent 0%
            \\  );
            \\}
            \\
        );

        switch (window_theme) {
            .ghostty => try writer.print(
                \\:root {{
                \\  --ghostty-fg: rgb({d},{d},{d});
                \\  --ghostty-bg: rgb({d},{d},{d});
                \\  --headerbar-fg-color: var(--ghostty-fg);
                \\  --headerbar-bg-color: var(--ghostty-bg);
                \\  --headerbar-backdrop-color: oklab(from var(--headerbar-bg-color) calc(l * 0.9) a b / alpha);
                \\  --overview-fg-color: var(--ghostty-fg);
                \\  --overview-bg-color: var(--ghostty-bg);
                \\  --popover-fg-color: var(--ghostty-fg);
                \\  --popover-bg-color: var(--ghostty-bg);
                \\  --window-fg-color: var(--ghostty-fg);
                \\  --window-bg-color: var(--ghostty-bg);
                \\}}
                \\windowhandle {{
                \\  background-color: var(--headerbar-bg-color);
                \\  color: var(--headerbar-fg-color);
                \\}}
                \\windowhandle:backdrop {{
                \\ background-color: var(--headerbar-backdrop-color);
                \\}}
            , .{
                headerbar_foreground.r,
                headerbar_foreground.g,
                headerbar_foreground.b,
                headerbar_background.r,
                headerbar_background.g,
                headerbar_background.b,
            }),
            else => {},
        }
    }

    fn loadCustomCss(self: *Self) (std.fs.File.ReadError || Allocator.Error)!void {
        const priv: *Private = self.private();
        const alloc = self.allocator();
        const display = gdk.Display.getDefault() orelse {
            log.warn("unable to get display", .{});
            return;
        };

        // unload the previously loaded style providers
        for (priv.custom_css_providers.items) |provider| {
            gtk.StyleContext.removeProviderForDisplay(
                display,
                provider.as(gtk.StyleProvider),
            );
            provider.unref();
        }
        priv.custom_css_providers.clearRetainingCapacity();

        const config = priv.config.get();
        for (config.@"gtk-custom-css".value.items) |p| {
            const path, const optional = switch (p) {
                .optional => |path| .{ path, true },
                .required => |path| .{ path, false },
            };
            const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
                if (err != error.FileNotFound or !optional) {
                    log.warn(
                        "error opening gtk-custom-css file {s}: {}",
                        .{ path, err },
                    );
                }
                continue;
            };
            defer file.close();

            const css_file_size_limit = 5 * 1024 * 1024; // 5MB

            log.info("loading gtk-custom-css path={s}", .{path});
            const contents = file.readToEndAlloc(
                alloc,
                css_file_size_limit,
            ) catch |err| switch (err) {
                error.FileTooBig => {
                    log.warn("gtk-custom-css file {s} was larger than {Bi}", .{ path, css_file_size_limit });
                    continue;
                },
                else => |e| return e,
            };
            defer alloc.free(contents);

            const bytes = glib.Bytes.new(contents.ptr, contents.len);
            defer bytes.unref();

            const css_provider = gtk.CssProvider.new();
            errdefer css_provider.unref();

            _ = gtk.CssProvider.signals.parsing_error.connect(
                css_provider,
                *Self,
                signalCssParsingError,
                self,
                .{},
            );

            try priv.custom_css_providers.append(alloc, css_provider);

            css_provider.loadFromBytes(bytes);

            gtk.StyleContext.addProviderForDisplay(
                display,
                css_provider.as(gtk.StyleProvider),
                gtk.STYLE_PROVIDER_PRIORITY_USER,
            );
        }
    }

    fn syncActionAccelerators(self: *Self) void {
        self.syncActionAccelerator("app.quit", .{ .quit = {} });
        self.syncActionAccelerator("app.open-config", .{ .open_config = {} });
        self.syncActionAccelerator("app.reload-config", .{ .reload_config = {} });
        self.syncActionAccelerator("win.toggle-inspector", .{ .inspector = .toggle });
        self.syncActionAccelerator("app.show-gtk-inspector", .show_gtk_inspector);
        self.syncActionAccelerator("win.toggle-command-palette", .toggle_command_palette);
        self.syncActionAccelerator("win.close", .{ .close_window = {} });
        self.syncActionAccelerator("win.new-window", .{ .new_window = {} });
        self.syncActionAccelerator("win.new-tab", .{ .new_tab = {} });
        self.syncActionAccelerator("win.close-tab::this", .{ .close_tab = .this });
        self.syncActionAccelerator("tab.close::this", .{ .close_tab = .this });
        self.syncActionAccelerator("win.split-right", .{ .new_split = .right });
        self.syncActionAccelerator("win.split-down", .{ .new_split = .down });
        self.syncActionAccelerator("win.split-left", .{ .new_split = .left });
        self.syncActionAccelerator("win.split-up", .{ .new_split = .up });
        self.syncActionAccelerator("win.copy", .{ .copy_to_clipboard = .mixed });
        self.syncActionAccelerator("win.paste", .{ .paste_from_clipboard = {} });
        self.syncActionAccelerator("win.reset", .{ .reset = {} });
        self.syncActionAccelerator("win.clear", .{ .clear_screen = {} });
        self.syncActionAccelerator("win.prompt-title", .{ .prompt_surface_title = {} });
        self.syncActionAccelerator("split-tree.new-split::left", .{ .new_split = .left });
        self.syncActionAccelerator("split-tree.new-split::right", .{ .new_split = .right });
        self.syncActionAccelerator("split-tree.new-split::up", .{ .new_split = .up });
        self.syncActionAccelerator("split-tree.new-split::down", .{ .new_split = .down });
    }

    fn syncActionAccelerator(
        self: *Self,
        gtk_action: [:0]const u8,
        action: input.Binding.Action,
    ) void {
        const gtk_app = self.as(gtk.Application);

        // Reset it initially
        const zero = [_:null]?[*:0]const u8{};
        gtk_app.setAccelsForAction(gtk_action, &zero);

        const config = self.private().config.get();
        const trigger = config.keybind.set.getTrigger(action) orelse return;
        var buf: [1024]u8 = undefined;
        const accel = if (key.accelFromTrigger(
            &buf,
            trigger,
        )) |accel_|
            accel_ orelse return
        else |err| switch (err) {
            // This should really never, never happen. Its not critical enough
            // to actually crash, but this is a bug somewhere. An accelerator
            // for a trigger can't possibly be more than 1024 bytes.
            error.WriteFailed => {
                log.warn("accelerator somehow longer than 1024 bytes: {f}", .{trigger});
                return;
            },
        };
        const accels = [_:null]?[*:0]const u8{accel};

        gtk_app.setAccelsForAction(gtk_action, &accels);
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

    fn propConfig(
        _: *Application,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // Sync our accelerators for menu items.
        self.syncActionAccelerators();

        // Load our runtime and custom CSS. If this fails then our window is
        // just stuck with the old CSS but we don't want to fail the entire
        // config change operation.
        self.loadRuntimeCss() catch |err| switch (err) {
            error.WriteFailed, error.OutOfMemory => log.warn(
                "out of memory loading runtime CSS, no runtime CSS applied",
                .{},
            ),
        };
        self.loadCustomCss() catch |err| {
            log.warn(
                "failed to load custom CSS, no custom CSS applied, err={}",
                .{err},
            );
        };
    }

    /// Log CSS parsing error
    fn signalCssParsingError(
        _: *gtk.CssProvider,
        css_section: *gtk.CssSection,
        err: *glib.Error,
        _: *Self,
    ) callconv(.c) void {
        const location = css_section.toString();
        defer glib.free(location);
        if (comptime gtk_version.atLeast(4, 16, 0)) bytes: {
            const bytes = css_section.getBytes() orelse break :bytes;
            var len: usize = undefined;
            const ptr = bytes.getData(&len) orelse break :bytes;
            const data = ptr[0..len];
            log.warn("css parsing failed at {s}: {s} {d} {s}\n{s}", .{
                location,
                glib.quarkToString(err.f_domain),
                err.f_code,
                err.f_message orelse "«unknown»",
                data,
            });
            return;
        }
        log.warn("css parsing failed at {s}: {s} {d} {s}", .{
            location,
            glib.quarkToString(err.f_domain),
            err.f_code,
            err.f_message orelse "«unknown»",
        });
    }

    //---------------------------------------------------------------
    // Libghostty Callbacks

    pub fn wakeup(self: *Self) void {
        _ = self;
        glib.MainContext.wakeup(null);
    }

    //---------------------------------------------------------------
    // Virtual Methods

    fn startup(self: *Self) callconv(.c) void {
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

        // Setup our global shortcuts
        self.startupGlobalShortcuts();

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

        // Do an initial color scheme sync. This is idempotent and does nothing
        // if our current theme matches what libghostty has so its safe to
        // call.
        handleStyleManagerDark(style, undefined, self);
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

        const actions = [_]ext.actions.Action(Self){
            .init("new-window", actionNewWindow, null),
            .init("new-window-command", actionNewWindow, as_variant_type),
            .init("open-config", actionOpenConfig, null),
            .init("present-surface", actionPresentSurface, t_variant_type),
            .init("quit", actionQuit, null),
            .init("reload-config", actionReloadConfig, null),
        };

        ext.actions.add(Self, self, &actions);
    }

    /// Setup our global shortcuts.
    fn startupGlobalShortcuts(self: *Self) void {
        const priv = self.private();

        // On startup, our dbus connection should be available.
        priv.global_shortcuts.setDbusConnection(
            self.as(gio.Application).getDbusConnection(),
        );

        // Setup a binding so that the shortcut config always matches the app.
        _ = gobject.Object.bindProperty(
            self.as(gobject.Object),
            "config",
            priv.global_shortcuts.as(gobject.Object),
            "config",
            .{ .sync_create = true },
        );

        // Setup the signal handler for global shortcut triggers
        _ = GlobalShortcuts.signals.trigger.connect(
            priv.global_shortcuts,
            *Application,
            globalShortcutTrigger,
            self,
            .{},
        );
    }

    fn activate(self: *Self) callconv(.c) void {
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

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.config_errors_dialog.get()) |diag| {
            diag.close();
            diag.unref(); // strong ref from get()
        }
        priv.config_errors_dialog.set(null);
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

    fn finalize(self: *Self) callconv(.c) void {
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
        const scheme: apprt.ColorScheme = if (style.getDark() == 0)
            .light
        else
            .dark;
        log.debug("style manager changed scheme={}", .{scheme});

        const priv: *Private = self.private();
        const core_app = priv.core_app;
        core_app.colorSchemeEvent(self.rt(), scheme) catch |err| {
            log.warn("error updating app color scheme err={}", .{err});
        };
        for (core_app.surfaces.items) |surface| {
            surface.core().colorSchemeCallback(scheme) catch |err| {
                log.warn(
                    "unable to tell surface about color scheme change err={}",
                    .{err},
                );
            };
        }

        if (gtk_version.atLeast(4, 20, 0)) {
            const gtk_scheme: gtk.InterfaceColorScheme = switch (scheme) {
                .light => gtk.InterfaceColorScheme.light,
                .dark => gtk.InterfaceColorScheme.dark,
            };
            var value = gobject.ext.Value.newFrom(gtk_scheme);
            gobject.Object.setProperty(
                priv.css_provider.as(gobject.Object),
                "prefers-color-scheme",
                &value,
            );
            for (priv.custom_css_providers.items) |css_provider| {
                gobject.Object.setProperty(
                    css_provider.as(gobject.Object),
                    "prefers-color-scheme",
                    &value,
                );
            }
        }
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

    fn globalShortcutTrigger(
        _: *GlobalShortcuts,
        action: *const Binding.Action,
        self: *Self,
    ) callconv(.c) void {
        self.core().performAllAction(self.rt(), action.*) catch |err| {
            log.warn("failed to perform action={}", .{err});
        };
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

    pub fn actionOpenConfig(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        _ = self.core().mailbox.push(.open_config, .forever);
    }

    fn actionPresentSurface(
        _: *gio.SimpleAction,
        parameter_: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const parameter = parameter_ orelse return;

        const t = glib.ext.VariantType.newFor(u64);
        defer glib.VariantType.free(t);

        // Make sure that we've receiived a u64 from the system.
        if (glib.Variant.isOfType(parameter, t) == 0) {
            return;
        }

        // Convert that u64 to pointer to a core surface. A value of zero
        // means that there was no target surface for the notification so
        // we don't focus any surface.
        //
        // This is admittedly SUPER SUS and we should instead do what we
        // do on macOS which is generate a UUID per surface and then pass
        // that around. But, we do validate the pointer below so at worst
        // this may result in focusing the wrong surface if the pointer was
        // reused for a surface.
        const ptr_int = parameter.getUint64();
        if (ptr_int == 0) return;
        const surface: *CoreSurface = @ptrFromInt(ptr_int);

        // Send a message through the core app mailbox rather than presenting the
        // surface directly so that it can validate that the surface pointer is
        // valid. We could get an invalid pointer if a desktop notification outlives
        // a Ghostty instance and a new one starts up, or there are multiple Ghostty
        // instances running.
        _ = self.core().mailbox.push(
            .{
                .surface_message = .{
                    .surface = surface,
                    .message = .present_surface,
                },
            },
            .forever,
        );
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

        fn init(class: *Class) callconv(.c) void {
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
    pub fn closeTab(target: apprt.Target, value: apprt.Action.Value(.close_tab)) bool {
        switch (target) {
            .app => return false,
            .surface => |core| {
                const surface = core.rt_surface.surface;
                return surface.as(gtk.Widget).activateAction(
                    "tab.close",
                    glib.ext.VariantType.stringFor([:0]const u8),
                    @as([*:0]const u8, @tagName(value)),
                ) != 0;
            },
        }
    }

    pub fn closeWindow(target: apprt.Target) bool {
        switch (target) {
            .app => return false,
            .surface => |core| {
                const surface = core.rt_surface.surface;
                return surface.as(gtk.Widget).activateAction("win.close", null) != 0;
            },
        }
    }

    pub fn copyTitleToClipboard(target: apprt.Target) bool {
        return switch (target) {
            .app => false,
            .surface => |v| v.rt_surface.gobj().copyTitleToClipboard(),
        };
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

    pub fn desktopNotification(
        self: *Application,
        target: apprt.Target,
        n: apprt.action.DesktopNotification,
    ) void {
        switch (target) {
            .app => {},
            .surface => |v| {
                v.rt_surface.gobj().sendDesktopNotification(n.title, n.body);
                return;
            },
        }

        // Set a default title if we don't already have one
        const t = switch (n.title.len) {
            0 => "Ghostty",
            else => n.title,
        };

        const notification = gio.Notification.new(t);
        defer notification.unref();
        notification.setBody(n.body);

        const icon = gio.ThemedIcon.new("com.mitchellh.ghostty");
        defer icon.unref();
        notification.setIcon(icon.as(gio.Icon));
        notification.setDefaultActionAndTargetValue(
            "app.present-surface",
            glib.Variant.newUint64(0),
        );

        // We set the notification ID to the body content. If the content is the
        // same, this notification may replace a previous notification
        const gio_app = self.as(gio.Application);
        gio_app.sendNotification(n.body, notification);
    }

    pub fn equalizeSplits(target: apprt.Target) bool {
        switch (target) {
            .app => {
                log.warn("equalize splits to app is unexpected", .{});
                return false;
            },

            .surface => |core| {
                const surface = core.rt_surface.surface;
                return surface.as(gtk.Widget).activateAction("split-tree.equalize", null) != 0;
            },
        }
    }

    pub fn gotoSplit(
        target: apprt.Target,
        to: apprt.action.GotoSplit,
    ) bool {
        switch (target) {
            .app => return false,
            .surface => |core| {
                // Design note: we can't use widget actions here because
                // we need to know whether there is a goto target for returning
                // the proper perform result (boolean).

                const surface = core.rt_surface.surface;
                const tree = ext.getAncestor(
                    SplitTree,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a split tree, ignoring goto_split", .{});
                    return false;
                };

                return tree.goto(switch (to) {
                    .previous => .previous_wrapped,
                    .next => .next_wrapped,
                    .up => .{ .spatial = .up },
                    .down => .{ .spatial = .down },
                    .left => .{ .spatial = .left },
                    .right => .{ .spatial = .right },
                });
            },
        }
    }

    pub fn gotoTab(
        target: apprt.Target,
        tab: apprt.action.GotoTab,
    ) bool {
        switch (target) {
            .app => return false,
            .surface => |core| {
                const surface = core.rt_surface.surface;
                const window = ext.getAncestor(
                    Window,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a window, ignoring new_tab", .{});
                    return false;
                };

                return window.selectTab(switch (tab) {
                    .previous => .previous,
                    .next => .next,
                    .last => .last,
                    else => .{ .n = @intCast(@intFromEnum(tab)) },
                });
            },
        }
    }

    pub fn gotoWindow(direction: apprt.action.GotoWindow) bool {
        const glist = gtk.Window.listToplevels();
        defer glist.free();

        // The window we're starting from is typically our active window.
        const starting: *glib.List = @as(?*glib.List, glist.findCustom(
            null,
            findActiveWindow,
        )) orelse glist;

        // Go forward or backwards in the list until we find a valid
        // window that is visible.
        var current_: ?*glib.List = starting;
        while (current_) |node| : (current_ = switch (direction) {
            .next => node.f_next,
            .previous => node.f_prev,
        }) {
            const data = node.f_data orelse continue;
            const gtk_window: *gtk.Window = @ptrCast(@alignCast(data));
            if (gotoWindowMaybe(gtk_window)) return true;
        }

        // If we reached here, we didn't find a valid window to focus.
        // Wrap around.
        current_ = switch (direction) {
            .next => glist,
            .previous => last: {
                var end: *glib.List = glist;
                while (end.f_next) |next| end = next;
                break :last end;
            },
        };
        while (current_) |node| : (current_ = switch (direction) {
            .next => node.f_next,
            .previous => node.f_prev,
        }) {
            if (current_ == starting) break;
            const data = node.f_data orelse continue;
            const gtk_window: *gtk.Window = @ptrCast(@alignCast(data));
            if (gotoWindowMaybe(gtk_window)) return true;
        }

        return false;
    }

    fn gotoWindowMaybe(gtk_window: *gtk.Window) bool {
        // If it is already active skip it.
        if (gtk_window.isActive() != 0) return false;
        // If it is hidden, skip it.
        if (gtk_window.as(gtk.Widget).isVisible() == 0) return false;
        // If it isn't a Ghostty window, skip it.
        const window = gobject.ext.cast(
            Window,
            gtk_window,
        ) orelse return false;

        // Focus our active surface
        const surface = window.getActiveSurface() orelse return false;
        gtk.Window.present(gtk_window);
        surface.grabFocus();
        return true;
    }

    pub fn initialSize(
        target: apprt.Target,
        value: apprt.action.InitialSize,
    ) bool {
        switch (target) {
            .app => return false,
            .surface => |core| {
                const surface = core.rt_surface.surface;
                surface.setDefaultSize(.{
                    .width = value.width,
                    .height = value.height,
                });
                return true;
            },
        }
    }

    pub fn mouseOverLink(
        target: apprt.Target,
        value: apprt.action.MouseOverLink,
    ) void {
        switch (target) {
            .app => log.warn("mouse over link to app is unexpected", .{}),
            .surface => |surface| surface.rt_surface.gobj().setMouseHoverUrl(
                if (value.url.len > 0) value.url else null,
            ),
        }
    }

    pub fn mouseShape(
        target: apprt.Target,
        shape: terminal.MouseShape,
    ) void {
        switch (target) {
            .app => log.warn("mouse shape to app is unexpected", .{}),
            .surface => |surface| surface.rt_surface.gobj().setMouseShape(shape),
        }
    }

    pub fn mouseVisibility(
        target: apprt.Target,
        visibility: apprt.action.MouseVisibility,
    ) void {
        switch (target) {
            .app => log.warn("mouse visibility to app is unexpected", .{}),
            .surface => |surface| surface.rt_surface.gobj().setMouseHidden(switch (visibility) {
                .visible => false,
                .hidden => true,
            }),
        }
    }

    pub fn moveTab(
        target: apprt.Target,
        value: apprt.action.MoveTab,
    ) bool {
        switch (target) {
            .app => return false,
            .surface => |core| {
                const surface = core.rt_surface.surface;
                const window = ext.getAncestor(
                    Window,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a window, ignoring new_tab", .{});
                    return false;
                };

                return window.moveTab(
                    surface,
                    @intCast(value.amount),
                );
            },
        }
    }

    pub fn newSplit(
        target: apprt.Target,
        direction: apprt.action.SplitDirection,
    ) bool {
        switch (target) {
            .app => {
                log.warn("new split to app is unexpected", .{});
                return false;
            },

            .surface => |core| {
                const surface = core.rt_surface.surface;

                return surface.as(gtk.Widget).activateAction(
                    "split-tree.new-split",
                    "&s",
                    @tagName(direction).ptr,
                ) != 0;
            },
        }
    }

    pub fn newTab(target: apprt.Target) bool {
        switch (target) {
            .app => {
                log.warn("new tab to app is unexpected", .{});
                return false;
            },

            .surface => |core| {
                // Get the window ancestor of the surface. Surfaces shouldn't
                // be aware they might be in windows but at the app level we
                // can do this.
                const surface = core.rt_surface.surface;
                const window = ext.getAncestor(
                    Window,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a window, ignoring new_tab", .{});
                    return false;
                };
                window.newTab(core);
                return true;
            },
        }
    }

    pub fn newWindow(
        self: *Application,
        parent: ?*CoreSurface,
    ) !void {
        // Note that we've requested a window at least once. This is used
        // to trigger quit on no windows. Note I'm not sure if this is REALLY
        // necessary, but I don't want to risk a bug where on a slow machine
        // or something we quit immediately after starting up because there
        // was a delay in the event loop before we created a Window.
        self.private().requested_window = true;

        const win = Window.new(self);
        initAndShowWindow(self, win, parent);
    }

    fn initAndShowWindow(
        self: *Application,
        win: *Window,
        parent: ?*CoreSurface,
    ) void {
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

        // Create a new tab with window context (first tab in new window)
        win.newTabForWindow(parent);

        // Show the window
        gtk.Window.present(win.as(gtk.Window));
    }

    pub fn openConfig(self: *Application) bool {
        // Get the config file path
        const alloc = self.allocator();
        const path = configpkg.edit.openPath(alloc) catch |err| {
            log.warn("error getting config file path: {}", .{err});
            return false;
        };
        defer alloc.free(path);

        // Open it using openURL. "path" isn't actually a URL but
        // at the time of writing that works just fine for GTK.
        openUrl(self, .{ .kind = .text, .url = path });
        return true;
    }

    pub fn openUrl(
        self: *Application,
        value: apprt.action.OpenUrl,
    ) void {
        // TODO: use https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.OpenURI.html

        // Fallback to the minimal cross-platform way of opening a URL.
        // This is always a safe fallback and enables for example Windows
        // to open URLs (GTK on Windows via WSL is a thing).
        internal_os.open(
            self.allocator(),
            value.kind,
            value.url,
        ) catch |err| log.warn("unable to open url: {}", .{err});
    }

    pub fn pwd(
        target: apprt.Target,
        value: apprt.action.Pwd,
    ) void {
        switch (target) {
            .app => log.warn("pwd to app is unexpected", .{}),
            .surface => |surface| surface.rt_surface.gobj().setPwd(value.pwd),
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

    pub fn presentTerminal(
        target: apprt.Target,
    ) bool {
        return switch (target) {
            .app => false,
            .surface => |v| surface: {
                v.rt_surface.surface.present();
                break :surface true;
            },
        };
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

    pub fn promptTitle(target: apprt.Target, value: apprt.action.PromptTitle) bool {
        switch (value) {
            .surface => switch (target) {
                .app => return false,
                .surface => |v| {
                    v.rt_surface.surface.promptTitle();
                    return true;
                },
            },
            .tab => {
                switch (target) {
                    .app => return false,
                    .surface => |v| {
                        const surface = v.rt_surface.surface;
                        const tab = ext.getAncestor(
                            Tab,
                            surface.as(gtk.Widget),
                        ) orelse {
                            log.warn("surface is not in a tab, ignoring prompt_tab_title", .{});
                            return false;
                        };
                        tab.promptTabTitle();
                        return true;
                    },
                }
            },
            .window => {
                switch (target) {
                    .app => return false,
                    .surface => |v| {
                        const surface = v.rt_surface.surface;
                        const win = ext.getAncestor(
                            Window,
                            surface.as(gtk.Widget),
                        ) orelse {
                            log.warn("surface is not in a window, ignoring prompt_window_title", .{});
                            return false;
                        };
                        win.promptWindowTitle();
                        return true;
                    },
                }
            },
        }
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

    pub fn resizeSplit(
        target: apprt.Target,
        value: apprt.action.ResizeSplit,
    ) bool {
        switch (target) {
            .app => {
                log.warn("resize_split to app is unexpected", .{});
                return false;
            },
            .surface => |core| {
                const surface = core.rt_surface.surface;
                const tree = ext.getAncestor(
                    SplitTree,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a split tree, ignoring resize_split", .{});
                    return false;
                };

                // If the tree has no splits (only one leaf), this action is not performable.
                // This allows the key event to pass through to the terminal.
                if (!tree.getIsSplit()) return false;

                return tree.resize(
                    switch (value.direction) {
                        .up => .up,
                        .down => .down,
                        .left => .left,
                        .right => .right,
                    },
                    value.amount,
                ) catch |err| switch (err) {
                    error.OutOfMemory => {
                        log.warn("unable to resize split, out of memory", .{});
                        return false;
                    },
                };
            },
        }
    }

    pub fn ringBell(target: apprt.Target) void {
        switch (target) {
            .app => {},
            .surface => |v| v.rt_surface.surface.setBellRinging(true),
        }
    }

    pub fn scrollbar(
        target: apprt.Target,
        value: apprt.Action.Value(.scrollbar),
    ) void {
        switch (target) {
            .app => {},
            .surface => |v| v.rt_surface.surface.setScrollbar(value),
        }
    }

    pub fn startSearch(target: apprt.Target, value: apprt.action.StartSearch) void {
        switch (target) {
            .app => {},
            .surface => |v| v.rt_surface.surface.setSearchActive(true, value.needle),
        }
    }

    pub fn endSearch(target: apprt.Target) void {
        switch (target) {
            .app => {},
            .surface => |v| v.rt_surface.surface.setSearchActive(false, ""),
        }
    }

    pub fn searchTotal(target: apprt.Target, value: apprt.action.SearchTotal) void {
        switch (target) {
            .app => {},
            .surface => |v| v.rt_surface.surface.setSearchTotal(value.total),
        }
    }

    pub fn searchSelected(target: apprt.Target, value: apprt.action.SearchSelected) void {
        switch (target) {
            .app => {},
            .surface => |v| v.rt_surface.surface.setSearchSelected(value.selected),
        }
    }

    pub fn setTitle(
        target: apprt.Target,
        value: apprt.action.SetTitle,
    ) void {
        switch (target) {
            .app => log.warn("set_title to app is unexpected", .{}),
            .surface => |surface| surface.rt_surface.gobj().setTitle(value.title),
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

    pub fn sizeLimit(
        target: apprt.Target,
        value: apprt.action.SizeLimit,
    ) bool {
        switch (target) {
            .app => return false,
            .surface => |core| {
                // Note: we ignore the max size currently because we have
                // no mechanism to enforce it.
                const surface = core.rt_surface.surface;
                surface.setMinSize(.{
                    .width = value.min_width,
                    .height = value.min_height,
                });

                return true;
            },
        }
    }

    pub fn toggleFullscreen(target: apprt.Target) void {
        switch (target) {
            .app => {},
            .surface => |v| v.rt_surface.surface.toggleFullscreen(),
        }
    }

    pub fn toggleQuickTerminal(self: *Application) bool {
        // If we already have a quick terminal window, we just toggle the
        // visibility of it.
        if (getQuickTerminalWindow()) |win| {
            win.toggleVisibility();
            return true;
        }

        // If we don't support quick terminals then we do nothing.
        const priv = self.private();
        if (!priv.winproto.supportsQuickTerminal()) return false;

        // Create our new window as a quick terminal
        const win = gobject.ext.newInstance(Window, .{
            .application = self,
            .@"quick-terminal" = true,
        });
        assert(win.isQuickTerminal());
        initAndShowWindow(self, win, null);
        return true;
    }

    pub fn toggleSplitZoom(target: apprt.Target) bool {
        switch (target) {
            .app => {
                log.warn("toggle_split_zoom to app is unexpected", .{});
                return false;
            },

            .surface => |core| {
                // TODO: pass surface ID when we have that
                const surface = core.rt_surface.surface;
                const tree = ext.getAncestor(
                    SplitTree,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a split tree, ignoring toggle_split_zoom", .{});
                    return false;
                };

                // If the tree has no splits (only one leaf), this action is not performable.
                // This allows the key event to pass through to the terminal.
                if (!tree.getIsSplit()) return false;

                return surface.as(gtk.Widget).activateAction("split-tree.zoom", null) != 0;
            },
        }
    }

    pub fn showOnScreenKeyboard(target: apprt.Target) bool {
        switch (target) {
            .app => {
                log.warn("show_on_screen_keyboard to app is unexpected", .{});
                return false;
            },
            // NOTE: Even though `activateOsk` takes a gdk.Event, it's currently
            // unused by all implementations of `activateOsk` as of GTK 4.18.
            // The commit that introduced the method (ce6aa73c) clarifies that
            // the event *may* be used by other IM backends, but for Linux desktop
            // environments this doesn't matter.
            .surface => |v| return v.rt_surface.surface.showOnScreenKeyboard(null),
        }
    }

    fn getQuickTerminalWindow() ?*Window {
        // Find a quick terminal window.
        const list = gtk.Window.listToplevels();
        defer list.free();
        if (ext.listFind(gtk.Window, list, struct {
            fn find(gtk_win: *gtk.Window) bool {
                const win = gobject.ext.cast(
                    Window,
                    gtk_win,
                ) orelse return false;
                return win.isQuickTerminal();
            }
        }.find)) |w| return gobject.ext.cast(
            Window,
            w,
        ).?;

        return null;
    }

    pub fn toggleMaximize(target: apprt.Target) void {
        switch (target) {
            .app => {},
            .surface => |v| v.rt_surface.surface.toggleMaximize(),
        }
    }

    pub fn toggleTabOverview(target: apprt.Target) bool {
        switch (target) {
            .app => return false,
            .surface => |core| {
                const surface = core.rt_surface.surface;
                const window = ext.getAncestor(
                    Window,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a window, ignoring new_tab", .{});
                    return false;
                };

                window.toggleTabOverview();
                return true;
            },
        }
    }

    pub fn toggleWindowDecorations(target: apprt.Target) bool {
        switch (target) {
            .app => return false,
            .surface => |core| {
                const surface = core.rt_surface.surface;
                const window = ext.getAncestor(
                    Window,
                    surface.as(gtk.Widget),
                ) orelse {
                    log.warn("surface is not in a window, ignoring toggle_window_decorations", .{});
                    return false;
                };

                window.toggleWindowDecorations();
                return true;
            },
        }
    }

    pub fn toggleCommandPalette(target: apprt.Target) bool {
        switch (target) {
            .app => return false,
            .surface => |surface| {
                return surface.rt_surface.gobj().toggleCommandPalette();
            },
        }
    }

    pub fn controlInspector(target: apprt.Target, value: apprt.Action.Value(.inspector)) bool {
        switch (target) {
            .app => return false,
            .surface => |surface| {
                return surface.rt_surface.gobj().controlInspector(value);
            },
        }
    }

    pub fn commandFinished(target: apprt.Target, value: apprt.Action.Value(.command_finished)) bool {
        switch (target) {
            .app => return false,
            .surface => |surface| {
                return surface.rt_surface.gobj().commandFinished(value);
            },
        }
    }

    pub fn setReadonly(target: apprt.Target, value: apprt.Action.Value(.readonly)) bool {
        switch (target) {
            .app => return false,
            .surface => |surface| {
                return surface.rt_surface.gobj().setReadonly(value);
            },
        }
    }

    pub fn keySequence(target: apprt.Target, value: apprt.Action.Value(.key_sequence)) bool {
        switch (target) {
            .app => {
                log.warn("key_sequence action to app is unexpected", .{});
                return false;
            },
            .surface => |core| {
                core.rt_surface.gobj().keySequenceAction(value) catch |err| {
                    log.warn("error handling key_sequence action: {}", .{err});
                };
                return true;
            },
        }
    }

    pub fn keyTable(target: apprt.Target, value: apprt.Action.Value(.key_table)) bool {
        switch (target) {
            .app => {
                log.warn("key_table action to app is unexpected", .{});
                return false;
            },
            .surface => |core| {
                core.rt_surface.gobj().keyTableAction(value) catch |err| {
                    log.warn("error handling key_table action: {}", .{err});
                };
                return true;
            },
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
        // `gtk-opengl-debug` dumps logs directly to stderr so both must be true
        // to enable OpenGL debugging.
        .opengl = state.logging.stderr and config.@"gtk-opengl-debug",
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
