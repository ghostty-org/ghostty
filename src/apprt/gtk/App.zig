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

const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const build_config = @import("../../build_config.zig");
const xev = @import("../../global.zig").xev;
const build_options = @import("build_options");
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const input = @import("../../input.zig");
const internal_os = @import("../../os/main.zig");
const terminal = @import("../../terminal/main.zig");
const Config = configpkg.Config;
const CoreApp = @import("../../App.zig");
const CoreSurface = @import("../../Surface.zig");

const cgroup = @import("cgroup.zig");
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");
const ConfigErrorsDialog = @import("ConfigErrorsDialog.zig");
const ClipboardConfirmationWindow = @import("ClipboardConfirmationWindow.zig");
const CloseDialog = @import("CloseDialog.zig");
const GlobalShortcuts = @import("GlobalShortcuts.zig");
const Split = @import("Split.zig");
const inspector = @import("inspector.zig");
const key = @import("key.zig");
const winprotopkg = @import("winproto.zig");
const gtk_version = @import("gtk_version.zig");
const adw_version = @import("adw_version.zig");

pub const c = @cImport({
    // generated header files
    @cInclude("ghostty_resources.h");
});

const log = std.log.scoped(.gtk);

pub const Options = struct {};

core_app: *CoreApp,
config: Config,

app: *adw.Application,
ctx: *glib.MainContext,

/// State and logic for the underlying windowing protocol.
winproto: winprotopkg.App,

/// True if the app was launched with single instance mode.
single_instance: bool,

/// The "none" cursor. We use one that is shared across the entire app.
cursor_none: ?*gdk.Cursor,

/// The clipboard confirmation window, if it is currently open.
clipboard_confirmation_window: ?*ClipboardConfirmationWindow = null,

/// The config errors dialog, if it is currently open.
config_errors_dialog: ?ConfigErrorsDialog = null,

/// The window containing the quick terminal.
/// Null when never initialized.
quick_terminal: ?*Window = null,

/// This is set to false when the main loop should exit.
running: bool = true,

/// The base path of the transient cgroup used to put all surfaces
/// into their own cgroup. This is only set if cgroups are enabled
/// and initialization was successful.
transient_cgroup_base: ?[]const u8 = null,

/// CSS Provider for any styles based on ghostty configuration values
css_provider: *gtk.CssProvider,

/// Providers for loading custom stylesheets defined by user
custom_css_providers: std.ArrayListUnmanaged(*gtk.CssProvider) = .{},

global_shortcuts: ?GlobalShortcuts,

/// The timer used to quit the application after the last window is closed.
quit_timer: union(enum) {
    off: void,
    active: c_uint,
    expired: void,
} = .{ .off = {} },

pub fn init(core_app: *CoreApp, opts: Options) !App {
    _ = opts;

    // Log our GTK version
    gtk_version.logVersion();

    // log the adwaita version
    adw_version.logVersion();

    // Set gettext global domain to be our app so that our unqualified
    // translations map to our translations.
    try internal_os.i18n.initGlobalDomain();

    // Load our configuration
    var config = try Config.load(core_app.alloc);
    errdefer config.deinit();

    // If we had configuration errors, then log them.
    if (!config._diagnostics.empty()) {
        var buf = std.ArrayList(u8).init(core_app.alloc);
        defer buf.deinit();
        for (config._diagnostics.items()) |diag| {
            try diag.write(buf.writer());
            log.warn("configuration error: {s}", .{buf.items});
            buf.clearRetainingCapacity();
        }

        // If we have any CLI errors, exit.
        if (config._diagnostics.containsLocation(.cli)) {
            log.warn("CLI errors detected, exiting", .{});
            std.posix.exit(1);
        }
    }

    // Setup our event loop backend
    if (config.@"async-backend" != .auto) {
        const result: bool = switch (config.@"async-backend") {
            .auto => unreachable,
            .epoll => xev.prefer(.epoll),
            .io_uring => xev.prefer(.io_uring),
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
        var buf: [128]u8 = undefined;
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
        var buf: [128]u8 = undefined;
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

    adw.init();

    const display: *gdk.Display = gdk.Display.getDefault() orelse {
        // I'm unsure of any scenario where this happens. Because we don't
        // want to litter null checks everywhere, we just exit here.
        log.warn("gdk display is null, exiting", .{});
        std.posix.exit(1);
    };

    // The "none" cursor is used for hiding the cursor
    const cursor_none = gdk.Cursor.newFromName("none", null);
    errdefer if (cursor_none) |cursor| cursor.unref();

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

        const default_id = comptime build_config.bundle_id;
        break :app_id if (builtin.mode == .Debug) default_id ++ "-debug" else default_id;
    };

    // Create our GTK Application which encapsulates our process.
    log.debug("creating GTK application id={s} single-instance={}", .{
        app_id,
        single_instance,
    });

    // Using an AdwApplication lets us use Adwaita widgets and access things
    // such as the color scheme.
    const adw_app = adw.Application.new(
        app_id.ptr,
        app_flags,
    );
    errdefer adw_app.unref();

    const style_manager = adw_app.getStyleManager();
    style_manager.setColorScheme(
        switch (config.@"window-theme") {
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
        },
    );

    const gio_app = adw_app.as(gio.Application);

    // force the resource path to a known value so that it doesn't depend on
    // the app id and load in compiled resources
    gio_app.setResourceBasePath("/com/mitchellh/ghostty");
    gio.resourcesRegister(@ptrCast(@alignCast(c.ghostty_get_resource() orelse {
        log.err("unable to load resources", .{});
        return error.GtkNoResources;
    })));

    // The `activate` signal is used when Ghostty is first launched and when a
    // secondary Ghostty is launched and requests a new window.
    _ = gio.Application.signals.activate.connect(
        adw_app,
        *CoreApp,
        gtkActivate,
        core_app,
        .{},
    );

    // Other signals
    _ = gtk.Application.signals.window_added.connect(
        adw_app,
        *CoreApp,
        gtkWindowAdded,
        core_app,
        .{},
    );
    _ = gtk.Application.signals.window_removed.connect(
        adw_app,
        *CoreApp,
        gtkWindowRemoved,
        core_app,
        .{},
    );

    // We don't use g_application_run, we want to manually control the
    // loop so we have to do the same things the run function does:
    // https://github.com/GNOME/glib/blob/a8e8b742e7926e33eb635a8edceac74cf239d6ed/gio/gapplication.c#L2533
    const ctx = glib.MainContext.default();
    if (glib.MainContext.acquire(ctx) == 0) return error.GtkContextAcquireFailed;
    errdefer glib.MainContext.release(ctx);

    var err_: ?*glib.Error = null;
    if (gio_app.register(
        null,
        &err_,
    ) == 0) {
        if (err_) |err| {
            log.warn("error registering application: {s}", .{err.f_message orelse "(unknown)"});
            err.free();
        }
        return error.GtkApplicationRegisterFailed;
    }

    // Setup our windowing protocol logic
    var winproto_app = try winprotopkg.App.init(
        core_app.alloc,
        display,
        app_id,
        &config,
    );
    errdefer winproto_app.deinit(core_app.alloc);
    log.debug("windowing protocol={s}", .{@tagName(winproto_app)});

    // This just calls the `activate` signal but its part of the normal startup
    // routine so we just call it, but only if the config allows it (this allows
    // for launching Ghostty in the "background" without immediately opening
    // a window)
    //
    // https://gitlab.gnome.org/GNOME/glib/-/blob/bd2ccc2f69ecfd78ca3f34ab59e42e2b462bad65/gio/gapplication.c#L2302
    if (config.@"initial-window")
        gio_app.activate();

    // Internally, GTK ensures that only one instance of this provider exists in the provider list
    // for the display.
    const css_provider = gtk.CssProvider.new();
    gtk.StyleContext.addProviderForDisplay(
        display,
        css_provider.as(gtk.StyleProvider),
        gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 3,
    );

    return .{
        .core_app = core_app,
        .app = adw_app,
        .config = config,
        .ctx = ctx,
        .cursor_none = cursor_none,
        .winproto = winproto_app,
        .single_instance = single_instance,
        // If we are NOT the primary instance, then we never want to run.
        // This means that another instance of the GTK app is running and
        // our "activate" call above will open a window.
        .running = gio_app.getIsRemote() == 0,
        .css_provider = css_provider,
        .global_shortcuts = .init(core_app.alloc, gio_app),
    };
}

// Terminate the application. The application will not be restarted after
// this so all global state can be cleaned up.
pub fn terminate(self: *App) void {
    gio.Settings.sync();
    while (glib.MainContext.iteration(self.ctx, 0) != 0) {}
    glib.MainContext.release(self.ctx);
    self.app.unref();

    if (self.cursor_none) |cursor| cursor.unref();
    if (self.transient_cgroup_base) |path| self.core_app.alloc.free(path);

    for (self.custom_css_providers.items) |provider| {
        provider.unref();
    }
    self.custom_css_providers.deinit(self.core_app.alloc);

    self.winproto.deinit(self.core_app.alloc);

    if (self.global_shortcuts) |*shortcuts| shortcuts.deinit();

    self.config.deinit();
}

/// Perform a given action. Returns `true` if the action was able to be
/// performed, `false` otherwise.
pub fn performAction(
    self: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    switch (action) {
        .quit => self.quit(),
        .new_window => _ = try self.newWindow(switch (target) {
            .app => null,
            .surface => |v| v,
        }),
        .close_window => return try self.closeWindow(target),
        .toggle_maximize => self.toggleMaximize(target),
        .toggle_fullscreen => self.toggleFullscreen(target, value),
        .new_tab => try self.newTab(target),
        .close_tab => return try self.closeTab(target),
        .goto_tab => return self.gotoTab(target, value),
        .move_tab => self.moveTab(target, value),
        .new_split => try self.newSplit(target, value),
        .resize_split => self.resizeSplit(target, value),
        .equalize_splits => self.equalizeSplits(target),
        .goto_split => return self.gotoSplit(target, value),
        .open_config => try configpkg.edit.open(self.core_app.alloc),
        .config_change => self.configChange(target, value.config),
        .reload_config => try self.reloadConfig(target, value),
        .inspector => self.controlInspector(target, value),
        .show_gtk_inspector => self.showGTKInspector(),
        .desktop_notification => self.showDesktopNotification(target, value),
        .set_title => try self.setTitle(target, value),
        .pwd => try self.setPwd(target, value),
        .present_terminal => self.presentTerminal(target),
        .initial_size => try self.setInitialSize(target, value),
        .size_limit => try self.setSizeLimit(target, value),
        .mouse_visibility => self.setMouseVisibility(target, value),
        .mouse_shape => try self.setMouseShape(target, value),
        .mouse_over_link => self.setMouseOverLink(target, value),
        .toggle_tab_overview => self.toggleTabOverview(target),
        .toggle_tab_icons => self.toggleTabIcons(target),
        .toggle_split_zoom => self.toggleSplitZoom(target),
        .toggle_window_decorations => self.toggleWindowDecorations(target),
        .quit_timer => self.quitTimer(value),
        .prompt_title => try self.promptTitle(target),
        .toggle_quick_terminal => return try self.toggleQuickTerminal(),
        .secure_input => self.setSecureInput(target, value),
        .ring_bell => try self.ringBell(target),
        .toggle_command_palette => try self.toggleCommandPalette(target),

        // Unimplemented
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
    }

    // We can assume it was handled because all unknown/unimplemented actions
    // are caught above.
    return true;
}

fn newTab(_: *App, target: apprt.Target) !void {
    switch (target) {
        .app => {},
        .surface => |v| {
            const window = v.rt_surface.container.window() orelse {
                log.info(
                    "new_tab invalid for container={s}",
                    .{@tagName(v.rt_surface.container)},
                );
                return;
            };

            try window.newTab(v);
        },
    }
}

fn closeTab(_: *App, target: apprt.Target) !bool {
    switch (target) {
        .app => return false,
        .surface => |v| {
            const tab = v.rt_surface.container.tab() orelse {
                log.info(
                    "close_tab invalid for container={s}",
                    .{@tagName(v.rt_surface.container)},
                );
                return false;
            };

            tab.closeWithConfirmation();
            return true;
        },
    }
}

fn gotoTab(_: *App, target: apprt.Target, tab: apprt.action.GotoTab) bool {
    switch (target) {
        .app => return false,
        .surface => |v| {
            const window = v.rt_surface.container.window() orelse {
                log.info(
                    "gotoTab invalid for container={s}",
                    .{@tagName(v.rt_surface.container)},
                );
                return false;
            };

            return switch (tab) {
                .previous => window.gotoPreviousTab(v.rt_surface),
                .next => window.gotoNextTab(v.rt_surface),
                .last => window.gotoLastTab(),
                else => window.gotoTab(@intCast(@intFromEnum(tab))),
            };
        },
    }
}

fn moveTab(_: *App, target: apprt.Target, move_tab: apprt.action.MoveTab) void {
    switch (target) {
        .app => {},
        .surface => |v| {
            const window = v.rt_surface.container.window() orelse {
                log.info(
                    "moveTab invalid for container={s}",
                    .{@tagName(v.rt_surface.container)},
                );
                return;
            };

            window.moveTab(v.rt_surface, @intCast(move_tab.amount));
        },
    }
}

fn newSplit(
    self: *App,
    target: apprt.Target,
    direction: apprt.action.SplitDirection,
) !void {
    switch (target) {
        .app => {},
        .surface => |v| {
            const alloc = self.core_app.alloc;
            _ = try Split.create(alloc, v.rt_surface, direction);
        },
    }
}

fn equalizeSplits(_: *App, target: apprt.Target) void {
    switch (target) {
        .app => {},
        .surface => |v| {
            const tab = v.rt_surface.container.tab() orelse return;
            const top_split = switch (tab.elem) {
                .split => |s| s,
                else => return,
            };
            _ = top_split.equalize();
        },
    }
}

fn gotoSplit(
    _: *const App,
    target: apprt.Target,
    direction: apprt.action.GotoSplit,
) bool {
    switch (target) {
        .app => return false,
        .surface => |v| {
            const s = v.rt_surface.container.split() orelse return false;
            const map = s.directionMap(switch (v.rt_surface.container) {
                .split_tl => .top_left,
                .split_br => .bottom_right,
                .none, .tab_ => unreachable,
            });
            const surface_ = map.get(direction) orelse return false;
            if (surface_) |surface| {
                surface.grabFocus();
                return true;
            }
            return false;
        },
    }
}

fn resizeSplit(
    _: *const App,
    target: apprt.Target,
    resize: apprt.action.ResizeSplit,
) void {
    switch (target) {
        .app => {},
        .surface => |v| {
            const s = v.rt_surface.container.firstSplitWithOrientation(
                Split.Orientation.fromResizeDirection(resize.direction),
            ) orelse return;
            s.moveDivider(resize.direction, resize.amount);
        },
    }
}

fn presentTerminal(
    _: *const App,
    target: apprt.Target,
) void {
    switch (target) {
        .app => {},
        .surface => |v| v.rt_surface.present(),
    }
}

fn controlInspector(
    _: *const App,
    target: apprt.Target,
    mode: apprt.action.Inspector,
) void {
    const surface: *Surface = switch (target) {
        .app => return,
        .surface => |v| v.rt_surface,
    };

    surface.controlInspector(mode);
}

fn showGTKInspector(
    _: *const App,
) void {
    gtk.Window.setInteractiveDebugging(@intFromBool(true));
}

fn toggleMaximize(_: *App, target: apprt.Target) void {
    switch (target) {
        .app => {},
        .surface => |v| {
            const window = v.rt_surface.container.window() orelse {
                log.info(
                    "toggleMaximize invalid for container={s}",
                    .{@tagName(v.rt_surface.container)},
                );
                return;
            };
            window.toggleMaximize();
        },
    }
}

fn toggleFullscreen(
    _: *App,
    target: apprt.Target,
    _: apprt.action.Fullscreen,
) void {
    switch (target) {
        .app => {},
        .surface => |v| {
            const window = v.rt_surface.container.window() orelse {
                log.info(
                    "toggleFullscreen invalid for container={s}",
                    .{@tagName(v.rt_surface.container)},
                );
                return;
            };

            window.toggleFullscreen();
        },
    }
}

fn toggleTabOverview(_: *App, target: apprt.Target) void {
    switch (target) {
        .app => {},
        .surface => |v| {
            const window = v.rt_surface.container.window() orelse {
                log.info(
                    "toggleTabOverview invalid for container={s}",
                    .{@tagName(v.rt_surface.container)},
                );
                return;
            };

            window.toggleTabOverview();
        },
    }
}

fn toggleTabIcons(_: *App, target: apprt.Target) void {
    switch (target) {
        .app => {},
        .surface => |v| {
            const window = v.rt_surface.container.window() orelse {
                log.info(
                    "toggleTabIcons invalid for container={s}",
                    .{@tagName(v.rt_surface.container)},
                );
                return;
            };

            window.toggleTabIcons();
        },
    }
}

fn toggleSplitZoom(_: *App, target: apprt.Target) void {
    switch (target) {
        .app => {},
        .surface => |surface| surface.rt_surface.toggleSplitZoom(),
    }
}

fn toggleWindowDecorations(
    _: *App,
    target: apprt.Target,
) void {
    switch (target) {
        .app => {},
        .surface => |v| {
            const window = v.rt_surface.container.window() orelse {
                log.info(
                    "toggleWindowDecorations invalid for container={s}",
                    .{@tagName(v.rt_surface.container)},
                );
                return;
            };

            window.toggleWindowDecorations();
        },
    }
}

fn toggleQuickTerminal(self: *App) !bool {
    if (self.quick_terminal) |qt| {
        qt.toggleVisibility();
        return true;
    }

    if (!self.winproto.supportsQuickTerminal()) return false;

    const qt = Window.create(self.core_app.alloc, self) catch |err| {
        log.err("failed to initialize quick terminal={}", .{err});
        return true;
    };
    self.quick_terminal = qt;

    // The setup has to happen *before* the window-specific winproto is
    // initialized, so we need to initialize it through the app winproto
    try self.winproto.initQuickTerminal(qt);

    // Finalize creating the quick terminal
    try qt.newTab(null);
    qt.present();
    return true;
}

fn ringBell(_: *App, target: apprt.Target) !void {
    switch (target) {
        .app => {},
        .surface => |surface| try surface.rt_surface.ringBell(),
    }
}

fn toggleCommandPalette(_: *App, target: apprt.Target) !void {
    switch (target) {
        .app => {},
        .surface => |surface| {
            const window = surface.rt_surface.container.window() orelse {
                log.info(
                    "toggleCommandPalette invalid for container={s}",
                    .{@tagName(surface.rt_surface.container)},
                );
                return;
            };

            window.toggleCommandPalette();
        },
    }
}

fn quitTimer(self: *App, mode: apprt.action.QuitTimer) void {
    switch (mode) {
        .start => self.startQuitTimer(),
        .stop => self.stopQuitTimer(),
    }
}

fn promptTitle(_: *App, target: apprt.Target) !void {
    switch (target) {
        .app => {},
        .surface => |v| {
            try v.rt_surface.promptTitle();
        },
    }
}

fn setTitle(
    _: *App,
    target: apprt.Target,
    title: apprt.action.SetTitle,
) !void {
    switch (target) {
        .app => {},
        .surface => |v| try v.rt_surface.setTitle(title.title, .terminal),
    }
}

fn setPwd(
    _: *App,
    target: apprt.Target,
    pwd: apprt.action.Pwd,
) !void {
    switch (target) {
        .app => {},
        .surface => |v| try v.rt_surface.setPwd(pwd.pwd),
    }
}

fn setMouseVisibility(
    _: *App,
    target: apprt.Target,
    visibility: apprt.action.MouseVisibility,
) void {
    switch (target) {
        .app => {},
        .surface => |v| v.rt_surface.setMouseVisibility(switch (visibility) {
            .visible => true,
            .hidden => false,
        }),
    }
}

fn setMouseShape(
    _: *App,
    target: apprt.Target,
    shape: terminal.MouseShape,
) !void {
    switch (target) {
        .app => {},
        .surface => |v| try v.rt_surface.setMouseShape(shape),
    }
}

fn setMouseOverLink(
    _: *App,
    target: apprt.Target,
    value: apprt.action.MouseOverLink,
) void {
    switch (target) {
        .app => {},
        .surface => |v| v.rt_surface.mouseOverLink(if (value.url.len > 0)
            value.url
        else
            null),
    }
}

fn setInitialSize(
    _: *App,
    target: apprt.Target,
    value: apprt.action.InitialSize,
) !void {
    switch (target) {
        .app => {},
        .surface => |v| try v.rt_surface.setInitialWindowSize(
            value.width,
            value.height,
        ),
    }
}

fn setSizeLimit(
    _: *App,
    target: apprt.Target,
    value: apprt.action.SizeLimit,
) !void {
    switch (target) {
        .app => {},
        .surface => |v| try v.rt_surface.setSizeLimits(.{
            .width = value.min_width,
            .height = value.min_height,
        }, if (value.max_width > 0) .{
            .width = value.max_width,
            .height = value.max_height,
        } else null),
    }
}

fn showDesktopNotification(
    self: *App,
    target: apprt.Target,
    n: apprt.action.DesktopNotification,
) void {
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

    const pointer = glib.Variant.newUint64(switch (target) {
        .app => 0,
        .surface => |v| @intFromPtr(v),
    });
    notification.setDefaultActionAndTargetValue("app.present-surface", pointer);

    const gio_app = self.app.as(gio.Application);

    // We set the notification ID to the body content. If the content is the
    // same, this notification may replace a previous notification
    gio_app.sendNotification(n.body, notification);
}

fn configChange(
    self: *App,
    target: apprt.Target,
    new_config: *const Config,
) void {
    switch (target) {
        .surface => |surface| surface: {
            surface.rt_surface.updateConfig(new_config) catch |err| {
                log.err("unable to update surface config: {}", .{err});
            };
            const window = surface.rt_surface.container.window() orelse break :surface;
            window.updateConfig(new_config) catch |err| {
                log.warn("error updating config for window err={}", .{err});
            };
        },

        .app => {
            // We clone (to take ownership) and update our configuration.
            if (new_config.clone(self.core_app.alloc)) |config_clone| {
                self.config.deinit();
                self.config = config_clone;
            } else |err| {
                log.warn("error cloning configuration err={}", .{err});
            }

            // App changes needs to show a toast that our configuration
            // has reloaded.
            const window = window: {
                if (self.core_app.focusedSurface()) |core_surface| {
                    const surface = core_surface.rt_surface;
                    if (surface.container.window()) |window| {
                        window.onConfigReloaded();
                        break :window window;
                    }
                }
                break :window null;
            };

            self.syncConfigChanges(window) catch |err| {
                log.warn("error handling configuration changes err={}", .{err});
            };
        },
    }
}

pub fn reloadConfig(
    self: *App,
    target: apprt.action.Target,
    opts: apprt.action.ReloadConfig,
) !void {
    if (opts.soft) {
        switch (target) {
            .app => try self.core_app.updateConfig(self, &self.config),
            .surface => |core_surface| try core_surface.updateConfig(
                &self.config,
            ),
        }
        return;
    }

    // Load our configuration
    var config = try Config.load(self.core_app.alloc);
    errdefer config.deinit();

    // Call into our app to update
    switch (target) {
        .app => try self.core_app.updateConfig(self, &config),
        .surface => |core_surface| try core_surface.updateConfig(&config),
    }

    // Update the existing config, be sure to clean up the old one.
    self.config.deinit();
    self.config = config;
}

/// Call this anytime the configuration changes.
fn syncConfigChanges(self: *App, window_: ?*Window) !void {
    ConfigErrorsDialog.maybePresent(self, window_);
    try self.syncActionAccelerators();

    if (self.global_shortcuts) |*shortcuts| {
        shortcuts.refreshSession(self) catch |err| {
            log.warn("failed to refresh global shortcuts={}", .{err});
        };
    }

    // Load our runtime and custom CSS. If this fails then our window is just stuck
    // with the old CSS but we don't want to fail the entire sync operation.
    self.loadRuntimeCss() catch |err| switch (err) {
        error.OutOfMemory => log.warn(
            "out of memory loading runtime CSS, no runtime CSS applied",
            .{},
        ),
    };
    self.loadCustomCss() catch |err| {
        log.warn("Failed to load custom CSS, no custom CSS applied, err={}", .{err});
    };

    // if we have a window, it may need to update it's appearance
    if (window_) |window| try window.syncAppearance();
}

fn syncActionAccelerators(self: *App) !void {
    try self.syncActionAccelerator("app.quit", .{ .quit = {} });
    try self.syncActionAccelerator("app.open-config", .{ .open_config = {} });
    try self.syncActionAccelerator("app.reload-config", .{ .reload_config = {} });
    try self.syncActionAccelerator("win.toggle-inspector", .{ .inspector = .toggle });
    try self.syncActionAccelerator("app.show-gtk-inspector", .show_gtk_inspector);
    try self.syncActionAccelerator("win.toggle-command-palette", .toggle_command_palette);
    try self.syncActionAccelerator("win.close", .{ .close_window = {} });
    try self.syncActionAccelerator("win.new-window", .{ .new_window = {} });
    try self.syncActionAccelerator("win.new-tab", .{ .new_tab = {} });
    try self.syncActionAccelerator("win.close-tab", .{ .close_tab = {} });
    try self.syncActionAccelerator("win.split-right", .{ .new_split = .right });
    try self.syncActionAccelerator("win.split-down", .{ .new_split = .down });
    try self.syncActionAccelerator("win.split-left", .{ .new_split = .left });
    try self.syncActionAccelerator("win.split-up", .{ .new_split = .up });
    try self.syncActionAccelerator("win.copy", .{ .copy_to_clipboard = {} });
    try self.syncActionAccelerator("win.paste", .{ .paste_from_clipboard = {} });
    try self.syncActionAccelerator("win.reset", .{ .reset = {} });
    try self.syncActionAccelerator("win.clear", .{ .clear_screen = {} });
    try self.syncActionAccelerator("win.prompt-title", .{ .prompt_surface_title = {} });
    try self.syncActionAccelerator("win.toggle-tab-icons", .toggle_tab_icons);
}

fn syncActionAccelerator(
    self: *App,
    gtk_action: [:0]const u8,
    action: input.Binding.Action,
) !void {
    const gtk_app = self.app.as(gtk.Application);

    // Reset it initially
    const zero = [_:null]?[*:0]const u8{};
    gtk_app.setAccelsForAction(gtk_action, &zero);

    const trigger = self.config.keybind.set.getTrigger(action) orelse return;
    var buf: [256]u8 = undefined;
    const accel = try key.accelFromTrigger(&buf, trigger) orelse return;
    const accels = [_:null]?[*:0]const u8{accel};

    gtk_app.setAccelsForAction(gtk_action, &accels);
}

fn loadRuntimeCss(
    self: *const App,
) Allocator.Error!void {
    const alloc = self.core_app.alloc;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);

    const writer = buf.writer(alloc);

    const config: *const Config = &self.config;
    const window_theme = config.@"window-theme";
    const unfocused_fill: Config.Color = config.@"unfocused-split-fill" orelse config.background;
    const headerbar_background = config.@"window-titlebar-background" orelse config.background;
    const headerbar_foreground = config.@"window-titlebar-foreground" orelse config.foreground;

    try writer.print(
        \\widget.unfocused-split {{
        \\ opacity: {d:.2};
        \\ background-color: rgb({d},{d},{d});
        \\}}
    , .{
        1.0 - config.@"unfocused-split-opacity",
        unfocused_fill.r,
        unfocused_fill.g,
        unfocused_fill.b,
    });

    if (config.@"split-divider-color") |color| {
        try writer.print(
            \\.terminal-window .notebook separator {{
            \\  color: rgb({[r]d},{[g]d},{[b]d});
            \\  background: rgb({[r]d},{[g]d},{[b]d});
            \\}}
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
        , .{ .font_family = font_family });
    }

    if (gtk_version.runtimeAtLeast(4, 16, 0)) {
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
    } else {
        try writer.print(
            \\window.window-theme-ghostty .top-bar,
            \\window.window-theme-ghostty .bottom-bar,
            \\window.window-theme-ghostty box > tabbar {{
            \\ background-color: rgb({d},{d},{d});
            \\ color: rgb({d},{d},{d});
            \\}}
        , .{
            headerbar_background.r,
            headerbar_background.g,
            headerbar_background.b,
            headerbar_foreground.r,
            headerbar_foreground.g,
            headerbar_foreground.b,
        });
    }

    const data = try alloc.dupeZ(u8, buf.items);
    defer alloc.free(data);

    // Clears any previously loaded CSS from this provider
    loadCssProviderFromData(self.css_provider, data);
}

fn loadCustomCss(self: *App) !void {
    const alloc = self.core_app.alloc;

    const display = gdk.Display.getDefault() orelse {
        log.warn("unable to get display", .{});
        return;
    };

    // unload the previously loaded style providers
    for (self.custom_css_providers.items) |provider| {
        gtk.StyleContext.removeProviderForDisplay(
            display,
            provider.as(gtk.StyleProvider),
        );
        provider.unref();
    }
    self.custom_css_providers.clearRetainingCapacity();

    for (self.config.@"gtk-custom-css".value.items) |p| {
        const path, const optional = switch (p) {
            .optional => |path| .{ path, true },
            .required => |path| .{ path, false },
        };
        const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
            if (err != error.FileNotFound or !optional) {
                log.err(
                    "error opening gtk-custom-css file {s}: {}",
                    .{ path, err },
                );
            }
            continue;
        };
        defer file.close();

        log.info("loading gtk-custom-css path={s}", .{path});
        const contents = try file.reader().readAllAlloc(
            self.core_app.alloc,
            5 * 1024 * 1024, // 5MB,
        );
        defer alloc.free(contents);

        const data = try alloc.dupeZ(u8, contents);
        defer alloc.free(data);

        const provider = gtk.CssProvider.new();
        loadCssProviderFromData(provider, data);
        gtk.StyleContext.addProviderForDisplay(
            display,
            provider.as(gtk.StyleProvider),
            gtk.STYLE_PROVIDER_PRIORITY_USER,
        );

        try self.custom_css_providers.append(self.core_app.alloc, provider);
    }
}

fn loadCssProviderFromData(provider: *gtk.CssProvider, data: [:0]const u8) void {
    if (gtk_version.atLeast(4, 12, 0)) {
        const g_bytes = glib.Bytes.new(data.ptr, data.len);
        defer g_bytes.unref();

        provider.loadFromBytes(g_bytes);
    } else {
        provider.loadFromData(data, @intCast(data.len));
    }
}

/// Called by CoreApp to wake up the event loop.
pub fn wakeup(_: App) void {
    glib.MainContext.wakeup(null);
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
    } else log.debug("cgroup isolation disabled config={}", .{self.config.@"linux-cgroup"});

    // Setup color scheme notifications
    const style_manager: *adw.StyleManager = self.app.getStyleManager();
    _ = gobject.Object.signals.notify.connect(
        style_manager,
        *App,
        adwNotifyDark,
        self,
        .{
            .detail = "dark",
        },
    );

    // Make an initial request to set up the color scheme
    const light = style_manager.getDark() == 0;
    self.colorSchemeEvent(if (light) .light else .dark);

    // Setup our actions
    self.initActions();

    // On startup, we want to check for configuration errors right away
    // so we can show our error window. We also need to setup other initial
    // state.
    self.syncConfigChanges(null) catch |err| {
        log.warn("error handling configuration changes err={}", .{err});
    };

    while (self.running) {
        _ = glib.MainContext.iteration(self.ctx, 1);

        // Tick the terminal app and see if we should quit.
        try self.core_app.tick(self);

        // Check if we must quit based on the current state.
        const must_quit = q: {
            // If we are configured to always stay running, don't quit.
            if (!self.config.@"quit-after-last-window-closed") break :q false;

            // If the quit timer has expired, quit.
            if (self.quit_timer == .expired) break :q true;

            // There's no quit timer running, or it hasn't expired, don't quit.
            break :q false;
        };

        if (must_quit) self.quit();
    }
}

// This timeout function is started when no surfaces are open. It can be
// cancelled if a new surface is opened before the timer expires.
pub fn gtkQuitTimerExpired(ud: ?*anyopaque) callconv(.c) c_int {
    const self: *App = @ptrCast(@alignCast(ud));
    self.quit_timer = .{ .expired = {} };
    return 0;
}

/// This will get called when there are no more open surfaces.
fn startQuitTimer(self: *App) void {
    // Cancel any previous timer.
    self.stopQuitTimer();

    // This is a no-op unless we are configured to quit after last window is closed.
    if (!self.config.@"quit-after-last-window-closed") return;

    if (self.config.@"quit-after-last-window-closed-delay") |v| {
        // If a delay is configured, set a timeout function to quit after the delay.
        self.quit_timer = .{
            .active = glib.timeoutAdd(
                v.asMilliseconds(),
                gtkQuitTimerExpired,
                self,
            ),
        };
    } else {
        // If no delay is configured, treat it as expired.
        self.quit_timer = .{ .expired = {} };
    }
}

/// This will get called when a new surface gets opened.
fn stopQuitTimer(self: *App) void {
    switch (self.quit_timer) {
        .off => {},
        .expired => self.quit_timer = .{ .off = {} },
        .active => |source| {
            if (glib.Source.remove(source) == 0) {
                log.warn("unable to remove quit timer source={d}", .{source});
            }
            self.quit_timer = .{ .off = {} };
        },
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
fn newWindow(self: *App, parent_: ?*CoreSurface) !void {
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

    // Show the new window
    window.present();
}

fn setSecureInput(_: *App, target: apprt.Target, value: apprt.action.SecureInput) void {
    switch (target) {
        .app => {},
        .surface => |surface| {
            surface.rt_surface.setSecureInput(value);
        },
    }
}

fn closeWindow(_: *App, target: apprt.action.Target) !bool {
    switch (target) {
        .app => return false,
        .surface => |v| {
            const window = v.rt_surface.container.window() orelse return false;
            window.closeWithConfirmation();
            return true;
        },
    }
}

fn quit(self: *App) void {
    // If we're already not running, do nothing.
    if (!self.running) return;

    // If the app says we don't need to confirm, then we can quit now.
    if (!self.core_app.needsConfirmQuit()) {
        self.quitNow();
        return;
    }

    CloseDialog.show(.{ .app = self }) catch |err| {
        log.err("failed to open close dialog={}", .{err});
    };
}

/// This immediately destroys all windows, forcing the application to quit.
pub fn quitNow(self: *App) void {
    const list = gtk.Window.listToplevels();
    defer list.free();
    list.foreach(struct {
        fn callback(data: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
            const ptr = data orelse return;
            const window: *gtk.Window = @ptrCast(@alignCast(ptr));
            window.destroy();
        }
    }.callback, null);

    self.running = false;
}

/// This is called by the `activate` signal. This is sent on program startup and
/// also when a secondary instance launches and requests a new window.
fn gtkActivate(_: *adw.Application, core_app: *CoreApp) callconv(.c) void {
    // Queue a new window
    _ = core_app.mailbox.push(.{
        .new_window = .{},
    }, .{ .forever = {} });
}

fn gtkWindowAdded(
    _: *adw.Application,
    window: *gtk.Window,
    core_app: *CoreApp,
) callconv(.c) void {
    // Request the is-active property change so we can detect
    // when our app loses focus.
    _ = gobject.Object.signals.notify.connect(
        window,
        *CoreApp,
        gtkWindowIsActive,
        core_app,
        .{
            .detail = "is-active",
        },
    );
}

fn gtkWindowRemoved(
    _: *adw.Application,
    _: *gtk.Window,
    core_app: *CoreApp,
) callconv(.c) void {
    // Recheck if we are focused
    gtkWindowIsActive(null, undefined, core_app);
}

fn gtkWindowIsActive(
    window: ?*gtk.Window,
    _: *gobject.ParamSpec,
    core_app: *CoreApp,
) callconv(.c) void {
    // If our window is active, then we can tell the app
    // that we are focused.
    if (window) |w| {
        if (w.isActive() != 0) {
            core_app.focusEvent(true);
            return;
        }
    }

    // If the window becomes inactive, we need to check if any
    // other windows are active. If not, then we are no longer
    // focused.
    {
        const list = gtk.Window.listToplevels();
        defer list.free();
        var current: ?*glib.List = list;
        while (current) |elem| : (current = elem.f_next) {
            // If the window is active then we are still focused.
            // This is another window since we did our check above.
            // That window should trigger its own is-active
            // callback so we don't need to call it here.
            const w: *gtk.Window = @alignCast(@ptrCast(elem.f_data));
            if (w.isActive() == 1) return;
        }
    }

    // We are not focused
    core_app.focusEvent(false);
}

fn adwNotifyDark(
    style_manager: *adw.StyleManager,
    _: *gobject.ParamSpec,
    self: *App,
) callconv(.c) void {
    const color_scheme: apprt.ColorScheme = if (style_manager.getDark() == 0)
        .light
    else
        .dark;

    self.colorSchemeEvent(color_scheme);
}

fn colorSchemeEvent(
    self: *App,
    scheme: apprt.ColorScheme,
) void {
    self.core_app.colorSchemeEvent(self, scheme) catch |err| {
        log.err("error updating app color scheme err={}", .{err});
    };

    for (self.core_app.surfaces.items) |surface| {
        surface.core_surface.colorSchemeCallback(scheme) catch |err| {
            log.err("unable to tell surface about color scheme change err={}", .{err});
        };
    }
}

fn gtkActionOpenConfig(
    _: *gio.SimpleAction,
    _: ?*glib.Variant,
    self: *App,
) callconv(.c) void {
    _ = self.core_app.mailbox.push(.{
        .open_config = {},
    }, .{ .forever = {} });
}

fn gtkActionReloadConfig(
    _: *gio.SimpleAction,
    _: ?*glib.Variant,
    self: *App,
) callconv(.c) void {
    self.reloadConfig(.app, .{}) catch |err| {
        log.err("error reloading configuration: {}", .{err});
    };
}

fn gtkActionQuit(
    _: *gio.SimpleAction,
    _: ?*glib.Variant,
    self: *App,
) callconv(.c) void {
    self.core_app.performAction(self, .quit) catch |err| {
        log.err("error quitting err={}", .{err});
    };
}

/// Action sent by the window manager asking us to present a specific surface to
/// the user. Usually because the user clicked on a desktop notification.
fn gtkActionPresentSurface(
    _: *gio.SimpleAction,
    parameter_: ?*glib.Variant,
    self: *App,
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
    const ptr_int = parameter.getUint64();
    if (ptr_int == 0) return;
    const surface: *CoreSurface = @ptrFromInt(ptr_int);

    // Send a message through the core app mailbox rather than presenting the
    // surface directly so that it can validate that the surface pointer is
    // valid. We could get an invalid pointer if a desktop notification outlives
    // a Ghostty instance and a new one starts up, or there are multiple Ghostty
    // instances running.
    _ = self.core_app.mailbox.push(
        .{
            .surface_message = .{
                .surface = surface,
                .message = .{ .present_surface = {} },
            },
        },
        .{ .forever = {} },
    );
}

fn gtkActionShowGTKInspector(
    _: *gio.SimpleAction,
    _: ?*glib.Variant,
    self: *App,
) callconv(.c) void {
    self.core_app.performAction(self, .show_gtk_inspector) catch |err| {
        log.err("error showing GTK inspector err={}", .{err});
    };
}

/// This is called to setup the action map that this application supports.
/// This should be called only once on startup.
fn initActions(self: *App) void {
    // The set of actions. Each action has (in order):
    // [0] The action name
    // [1] The callback function
    // [2] The GVariantType of the parameter
    //
    // For action names:
    // https://docs.gtk.org/gio/type_func.Action.name_is_valid.html
    const t = glib.ext.VariantType.newFor(u64);
    defer glib.VariantType.free(t);

    const actions = .{
        .{ "quit", gtkActionQuit, null },
        .{ "open-config", gtkActionOpenConfig, null },
        .{ "reload-config", gtkActionReloadConfig, null },
        .{ "present-surface", gtkActionPresentSurface, t },
        .{ "show-gtk-inspector", gtkActionShowGTKInspector, null },
    };
    inline for (actions) |entry| {
        const action = gio.SimpleAction.new(entry[0], entry[2]);
        defer action.unref();
        _ = gio.SimpleAction.signals.activate.connect(
            action,
            *App,
            entry[1],
            self,
            .{},
        );
        const action_map = self.app.as(gio.ActionMap);
        action_map.addAction(action.as(gio.Action));
    }
}
