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
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const build_config = @import("../../build_config.zig");
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const input = @import("../../input.zig");
const internal_os = @import("../../os/main.zig");
const terminal = @import("../../terminal/main.zig");
const Config = configpkg.Config;
const CoreApp = @import("../../App.zig");
const CoreSurface = @import("../../Surface.zig");

const adwaita = @import("adwaita.zig");
const cgroup = @import("cgroup.zig");
const Surface = @import("Surface.zig");
const Window = @import("Window.zig");
const ConfigErrorsWindow = @import("ConfigErrorsWindow.zig");
const ClipboardConfirmationWindow = @import("ClipboardConfirmationWindow.zig");
const Split = @import("Split.zig");
const c = @import("c.zig").c;
const version = @import("version.zig");
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

/// The timer used to quit the application after the last window is closed.
quit_timer: union(enum) {
    off: void,
    active: c.guint,
    expired: void,
} = .{ .off = {} },

pub fn init(core_app: *CoreApp, opts: Options) !App {
    _ = opts;

    // Log our GTK version
    log.info("GTK version build={d}.{d}.{d} runtime={d}.{d}.{d}", .{
        c.GTK_MAJOR_VERSION,
        c.GTK_MINOR_VERSION,
        c.GTK_MICRO_VERSION,
        c.gtk_get_major_version(),
        c.gtk_get_minor_version(),
        c.gtk_get_micro_version(),
    });

    // Disabling Vulkan can improve startup times by hundreds of
    // milliseconds on some systems. We don't use Vulkan so we can just
    // disable it.
    if (version.atLeast(4, 16, 0)) {
        // From gtk 4.16, GDK_DEBUG is split into GDK_DEBUG and GDK_DISABLE.
        // For the remainder of "why" see the 4.14 comment below.
        _ = internal_os.setenv("GDK_DISABLE", "gles-api,vulkan");
        _ = internal_os.setenv("GDK_DEBUG", "opengl");
    } else if (version.atLeast(4, 14, 0)) {
        // We need to export GDK_DEBUG to run on Wayland after GTK 4.14.
        // Older versions of GTK do not support these values so it is safe
        // to always set this. Forwards versions are uncertain so we'll have to
        // reassess...
        //
        // Upstream issue: https://gitlab.gnome.org/GNOME/gtk/-/issues/6589
        //
        // Specific details about values:
        //   - "opengl" - output OpenGL debug information
        //   - "gl-disable-gles" - disable GLES, Ghostty can't use GLES
        //   - "vulkan-disable" - disable Vulkan, Ghostty can't use Vulkan
        //     and initializing a Vulkan context was causing a longer delay
        //     on some systems.
        _ = internal_os.setenv("GDK_DEBUG", "opengl,gl-disable-gles,vulkan-disable");

        // Wayland-EGL on GTK 4.14 causes "Failed to create EGL context" errors.
        // This can be fixed by forcing the backend to prefer X11. This issue
        // appears to be fixed in GTK 4.16 but I wasn't able to bisect why.
        // The "*" at the end says that if X11 fails, try all remaining
        // backends.
        _ = internal_os.setenv("GDK_BACKEND", "x11,*");
    } else {
        // Versions prior to 4.14 are a bit of an unknown for Ghostty. It
        // is an environment that isn't tested well and we don't have a
        // good understanding of what we may need to do.
        _ = internal_os.setenv("GDK_DEBUG", "vulkan-disable");
    }

    if (version.atLeast(4, 14, 0)) {
        // We need to export GSK_RENDERER to opengl because GTK uses ngl by
        // default after 4.14
        _ = internal_os.setenv("GSK_RENDERER", "opengl");
    }

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

    c.gtk_init();
    const display = c.gdk_display_get_default();

    // If we're using libadwaita, log the version
    if (adwaita.enabled(&config)) {
        log.info("libadwaita version build={s} runtime={}.{}.{}", .{
            c.ADW_VERSION_S,
            c.adw_get_major_version(),
            c.adw_get_minor_version(),
            c.adw_get_micro_version(),
        });
    }

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
    const app_id: [:0]const u8 = app_id: {
        if (config.class) |class| {
            if (isValidAppId(class)) {
                break :app_id class;
            } else {
                log.warn("invalid 'class' in config, ignoring", .{});
            }
        }

        const default_id = comptime build_config.bundle_id;
        break :app_id if (builtin.mode == .Debug) default_id ++ "-debug" else default_id;
    };

    // Create our GTK Application which encapsulates our process.
    const app: *c.GtkApplication = app: {
        log.debug("creating GTK application id={s} single-instance={} adwaita={}", .{
            app_id,
            single_instance,
            adwaita,
        });

        // If not libadwaita, create a standard GTK application.
        if ((comptime !adwaita.versionAtLeast(0, 0, 0)) or
            !adwaita.enabled(&config))
        {
            {
                const provider = c.gtk_css_provider_new();
                defer c.g_object_unref(provider);
                switch (config.@"window-theme") {
                    .system, .light => {},
                    .dark => {
                        c.gtk_css_provider_load_from_resource(
                            provider,
                            "/com/mitchellh/ghostty/style-dark.css",
                        );
                        c.gtk_style_context_add_provider_for_display(
                            display,
                            @ptrCast(provider),
                            c.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION + 2,
                        );
                    },
                    .auto, .ghostty => {
                        const lum = config.background.toTerminalRGB().perceivedLuminance();
                        if (lum <= 0.5) {
                            c.gtk_css_provider_load_from_resource(
                                provider,
                                "/com/mitchellh/ghostty/style-dark.css",
                            );
                            c.gtk_style_context_add_provider_for_display(
                                display,
                                @ptrCast(provider),
                                c.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION + 2,
                            );
                        }
                    },
                }
            }

            {
                const provider = c.gtk_css_provider_new();
                defer c.g_object_unref(provider);

                c.gtk_css_provider_load_from_resource(provider, "/com/mitchellh/ghostty/style.css");
                c.gtk_style_context_add_provider_for_display(
                    display,
                    @ptrCast(provider),
                    c.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION + 1,
                );
            }

            break :app @as(?*c.GtkApplication, @ptrCast(c.gtk_application_new(
                app_id.ptr,
                app_flags,
            ))) orelse return error.GtkInitFailed;
        }

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
                .auto, .ghostty => auto: {
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

    // Other signals
    _ = c.g_signal_connect_data(
        app,
        "window-added",
        c.G_CALLBACK(&gtkWindowAdded),
        core_app,
        null,
        c.G_CONNECT_DEFAULT,
    );
    _ = c.g_signal_connect_data(
        app,
        "window-removed",
        c.G_CALLBACK(&gtkWindowRemoved),
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
    // routine so we just call it, but only if the config allows it (this allows
    // for launching Ghostty in the "background" without immediately opening
    // a window)
    //
    // https://gitlab.gnome.org/GNOME/glib/-/blob/bd2ccc2f69ecfd78ca3f34ab59e42e2b462bad65/gio/gapplication.c#L2302
    if (config.@"initial-window")
        c.g_application_activate(gapp);

    // Internally, GTK ensures that only one instance of this provider exists in the provider list
    // for the display.
    const css_provider = c.gtk_css_provider_new();
    c.gtk_style_context_add_provider_for_display(
        display,
        @ptrCast(css_provider),
        c.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION + 3,
    );

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

/// Perform a given action.
pub fn performAction(
    self: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !void {
    switch (action) {
        .new_window => _ = try self.newWindow(switch (target) {
            .app => null,
            .surface => |v| v,
        }),
        .toggle_fullscreen => self.toggleFullscreen(target, value),

        .new_tab => try self.newTab(target),
        .goto_tab => self.gotoTab(target, value),
        .move_tab => self.moveTab(target, value),
        .new_split => try self.newSplit(target, value),
        .resize_split => self.resizeSplit(target, value),
        .equalize_splits => self.equalizeSplits(target),
        .goto_split => self.gotoSplit(target, value),
        .open_config => try configpkg.edit.open(self.core_app.alloc),
        .config_change => self.configChange(target, value.config),
        .reload_config => try self.reloadConfig(target, value),
        .inspector => self.controlInspector(target, value),
        .desktop_notification => self.showDesktopNotification(target, value),
        .set_title => try self.setTitle(target, value),
        .pwd => try self.setPwd(target, value),
        .present_terminal => self.presentTerminal(target),
        .initial_size => try self.setInitialSize(target, value),
        .mouse_visibility => self.setMouseVisibility(target, value),
        .mouse_shape => try self.setMouseShape(target, value),
        .mouse_over_link => self.setMouseOverLink(target, value),
        .toggle_tab_overview => self.toggleTabOverview(target),
        .toggle_split_zoom => self.toggleSplitZoom(target),
        .toggle_window_decorations => self.toggleWindowDecorations(target),
        .quit_timer => self.quitTimer(value),

        // Unimplemented
        .close_all_windows,
        .toggle_quick_terminal,
        .toggle_visibility,
        .size_limit,
        .cell_size,
        .secure_input,
        .key_sequence,
        .render_inspector,
        .renderer_health,
        .color_change,
        => log.warn("unimplemented action={}", .{action}),
    }
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

fn gotoTab(_: *App, target: apprt.Target, tab: apprt.action.GotoTab) void {
    switch (target) {
        .app => {},
        .surface => |v| {
            const window = v.rt_surface.container.window() orelse {
                log.info(
                    "gotoTab invalid for container={s}",
                    .{@tagName(v.rt_surface.container)},
                );
                return;
            };

            switch (tab) {
                .previous => window.gotoPreviousTab(v.rt_surface),
                .next => window.gotoNextTab(v.rt_surface),
                .last => window.gotoLastTab(),
                else => window.gotoTab(@intCast(@intFromEnum(tab))),
            }
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
) void {
    switch (target) {
        .app => {},
        .surface => |v| {
            const s = v.rt_surface.container.split() orelse return;
            const map = s.directionMap(switch (v.rt_surface.container) {
                .split_tl => .top_left,
                .split_br => .bottom_right,
                .none, .tab_ => unreachable,
            });
            const surface_ = map.get(direction) orelse return;
            if (surface_) |surface| surface.grabFocus();
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
                    "toggleFullscreen invalid for container={s}",
                    .{@tagName(v.rt_surface.container)},
                );
                return;
            };

            window.toggleWindowDecorations();
        },
    }
}

fn quitTimer(self: *App, mode: apprt.action.QuitTimer) void {
    switch (mode) {
        .start => self.startQuitTimer(),
        .stop => self.stopQuitTimer(),
    }
}

fn setTitle(
    _: *App,
    target: apprt.Target,
    title: apprt.action.SetTitle,
) !void {
    switch (target) {
        .app => {},
        .surface => |v| try v.rt_surface.setTitle(title.title),
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

    const notification = c.g_notification_new(t.ptr);
    defer c.g_object_unref(notification);
    c.g_notification_set_body(notification, n.body.ptr);

    const icon = c.g_themed_icon_new("com.mitchellh.ghostty");
    defer c.g_object_unref(icon);
    c.g_notification_set_icon(notification, icon);

    const pointer = c.g_variant_new_uint64(switch (target) {
        .app => 0,
        .surface => |v| @intFromPtr(v),
    });
    c.g_notification_set_default_action_and_target_value(
        notification,
        "app.present-surface",
        pointer,
    );

    const g_app: *c.GApplication = @ptrCast(self.app);

    // We set the notification ID to the body content. If the content is the
    // same, this notification may replace a previous notification
    c.g_application_send_notification(g_app, n.body.ptr, notification);
}

fn configChange(
    self: *App,
    target: apprt.Target,
    new_config: *const Config,
) void {
    switch (target) {
        // We don't do anything for surface config change events. There
        // is nothing to sync with regards to a surface today.
        .surface => {},

        .app => {
            // We clone (to take ownership) and update our configuration.
            if (new_config.clone(self.core_app.alloc)) |config_clone| {
                self.config.deinit();
                self.config = config_clone;
            } else |err| {
                log.warn("error cloning configuration err={}", .{err});
            }

            self.syncConfigChanges() catch |err| {
                log.warn("error handling configuration changes err={}", .{err});
            };

            // App changes needs to show a toast that our configuration
            // has reloaded.
            if (adwaita.enabled(&self.config)) {
                if (self.core_app.focusedSurface()) |core_surface| {
                    const surface = core_surface.rt_surface;
                    if (surface.container.window()) |window| window.onConfigReloaded();
                }
            }
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
fn syncConfigChanges(self: *App) !void {
    try self.updateConfigErrors();
    try self.syncActionAccelerators();

    // Load our runtime CSS. If this fails then our window is just stuck
    // with the old CSS but we don't want to fail the entire sync operation.
    self.loadRuntimeCss() catch |err| switch (err) {
        error.OutOfMemory => log.warn(
            "out of memory loading runtime CSS, no runtime CSS applied",
            .{},
        ),
    };
}

/// This should be called whenever the configuration changes to update
/// the state of our config errors window. This will show the window if
/// there are new configuration errors and hide the window if the errors
/// are resolved.
fn updateConfigErrors(self: *App) !void {
    if (!self.config._diagnostics.empty()) {
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
    try self.syncActionAccelerator("app.open-config", .{ .open_config = {} });
    try self.syncActionAccelerator("app.reload-config", .{ .reload_config = {} });
    try self.syncActionAccelerator("win.toggle_inspector", .{ .inspector = .toggle });
    try self.syncActionAccelerator("win.close", .{ .close_surface = {} });
    try self.syncActionAccelerator("win.new_window", .{ .new_window = {} });
    try self.syncActionAccelerator("win.new_tab", .{ .new_tab = {} });
    try self.syncActionAccelerator("win.split_right", .{ .new_split = .right });
    try self.syncActionAccelerator("win.split_down", .{ .new_split = .down });
    try self.syncActionAccelerator("win.split_left", .{ .new_split = .left });
    try self.syncActionAccelerator("win.split_up", .{ .new_split = .up });
    try self.syncActionAccelerator("win.copy", .{ .copy_to_clipboard = {} });
    try self.syncActionAccelerator("win.paste", .{ .paste_from_clipboard = {} });
    try self.syncActionAccelerator("win.reset", .{ .reset = {} });
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

fn loadRuntimeCss(
    self: *const App,
) Allocator.Error!void {
    var stack_alloc = std.heap.stackFallback(4096, self.core_app.alloc);
    var buf = std.ArrayList(u8).init(stack_alloc.get());
    defer buf.deinit();
    const writer = buf.writer();

    const config: *const Config = &self.config;
    const window_theme = config.@"window-theme";
    const unfocused_fill: Config.Color = config.@"unfocused-split-fill" orelse config.background;
    const headerbar_background = config.background;
    const headerbar_foreground = config.foreground;

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

    if (version.atLeast(4, 16, 0)) {
        switch (window_theme) {
            .ghostty => try writer.print(
                \\:root {{
                \\  --headerbar-fg-color: rgb({d},{d},{d});
                \\  --headerbar-bg-color: rgb({d},{d},{d});
                \\  --headerbar-backdrop-color: oklab(from var(--headerbar-bg-color) calc(l * 0.9) a b / alpha);
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

    // Clears any previously loaded CSS from this provider
    c.gtk_css_provider_load_from_data(
        self.css_provider,
        buf.items.ptr,
        @intCast(buf.items.len),
    );
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
    } else log.debug("cgroup isolation disabled config={}", .{self.config.@"linux-cgroup"});

    // Setup our D-Bus connection for listening to settings changes.
    self.initDbus();

    // Setup our menu items
    self.initActions();
    self.initMenu();
    self.initContextMenu();

    // Setup our initial color scheme
    self.colorSchemeEvent(self.getColorScheme());

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

        // Check if we must quit based on the current state.
        const must_quit = q: {
            // If we've been told by GTK that we should quit, do so regardless
            // of any other setting.
            if (should_quit) break :q true;

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

fn initDbus(self: *App) void {
    const dbus = c.g_application_get_dbus_connection(@ptrCast(self.app)) orelse {
        log.warn("unable to get dbus connection, not setting up events", .{});
        return;
    };

    _ = c.g_dbus_connection_signal_subscribe(
        dbus,
        null,
        "org.freedesktop.portal.Settings",
        "SettingChanged",
        "/org/freedesktop/portal/desktop",
        "org.freedesktop.appearance",
        c.G_DBUS_SIGNAL_FLAGS_MATCH_ARG0_NAMESPACE,
        &gtkNotifyColorScheme,
        self,
        null,
    );
}

// This timeout function is started when no surfaces are open. It can be
// cancelled if a new surface is opened before the timer expires.
pub fn gtkQuitTimerExpired(ud: ?*anyopaque) callconv(.C) c.gboolean {
    const self: *App = @ptrCast(@alignCast(ud));
    self.quit_timer = .{ .expired = {} };
    return c.FALSE;
}

/// This will get called when there are no more open surfaces.
fn startQuitTimer(self: *App) void {
    // Cancel any previous timer.
    self.stopQuitTimer();

    // This is a no-op unless we are configured to quit after last window is closed.
    if (!self.config.@"quit-after-last-window-closed") return;

    if (self.config.@"quit-after-last-window-closed-delay") |v| {
        // If a delay is configured, set a timeout function to quit after the delay.
        self.quit_timer = .{ .active = c.g_timeout_add(v.asMilliseconds(), gtkQuitTimerExpired, self) };
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
            if (c.g_source_remove(source) == c.FALSE) {
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

/// This is called by the `activate` signal. This is sent on program startup and
/// also when a secondary instance launches and requests a new window.
fn gtkActivate(app: *c.GtkApplication, ud: ?*anyopaque) callconv(.C) void {
    _ = app;

    const core_app: *CoreApp = @ptrCast(@alignCast(ud orelse return));

    // Queue a new window
    _ = core_app.mailbox.push(.{
        .new_window = .{},
    }, .{ .forever = {} });
}

fn gtkWindowAdded(
    _: *c.GtkApplication,
    window: *c.GtkWindow,
    ud: ?*anyopaque,
) callconv(.C) void {
    const core_app: *CoreApp = @ptrCast(@alignCast(ud orelse return));

    // Request the is-active property change so we can detect
    // when our app loses focus.
    _ = c.g_signal_connect_data(
        window,
        "notify::is-active",
        c.G_CALLBACK(&gtkWindowIsActive),
        core_app,
        null,
        c.G_CONNECT_DEFAULT,
    );
}

fn gtkWindowRemoved(
    _: *c.GtkApplication,
    _: *c.GtkWindow,
    ud: ?*anyopaque,
) callconv(.C) void {
    const core_app: *CoreApp = @ptrCast(@alignCast(ud orelse return));

    // Recheck if we are focused
    gtkWindowIsActive(null, undefined, core_app);
}

fn gtkWindowIsActive(
    window: ?*c.GtkWindow,
    _: *c.GParamSpec,
    ud: ?*anyopaque,
) callconv(.C) void {
    const core_app: *CoreApp = @ptrCast(@alignCast(ud orelse return));

    // If our window is active, then we can tell the app
    // that we are focused.
    if (window) |w| {
        if (c.gtk_window_is_active(w) == 1) {
            core_app.focusEvent(true);
            return;
        }
    }

    // If the window becomes inactive, we need to check if any
    // other windows are active. If not, then we are no longer
    // focused.
    if (c.gtk_window_list_toplevels()) |list| {
        defer c.g_list_free(list);
        var current: ?*c.GList = list;
        while (current) |elem| : (current = elem.next) {
            // If the window is active then we are still focused.
            // This is another window since we did our check above.
            // That window should trigger its own is-active
            // callback so we don't need to call it here.
            const w: *c.GtkWindow = @alignCast(@ptrCast(elem.data));
            if (c.gtk_window_is_active(w) == 1) return;
        }
    }

    // We are not focused
    core_app.focusEvent(false);
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
    const self: *App = @ptrCast(@alignCast(user_data orelse {
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
    self.reloadConfig(.app, .{}) catch |err| {
        log.err("error reloading configuration: {}", .{err});
    };
}

fn gtkActionQuit(
    _: *c.GSimpleAction,
    _: *c.GVariant,
    ud: ?*anyopaque,
) callconv(.C) void {
    const self: *App = @ptrCast(@alignCast(ud orelse return));
    self.core_app.setQuit();
}

/// Action sent by the window manager asking us to present a specific surface to
/// the user. Usually because the user clicked on a desktop notification.
fn gtkActionPresentSurface(
    _: *c.GSimpleAction,
    parameter: *c.GVariant,
    ud: ?*anyopaque,
) callconv(.C) void {
    const self: *App = @ptrCast(@alignCast(ud orelse return));

    // Make sure that we've receiived a u64 from the system.
    if (c.g_variant_is_of_type(parameter, c.G_VARIANT_TYPE("t")) == 0) {
        return;
    }

    // Convert that u64 to pointer to a core surface. A value of zero
    // means that there was no target surface for the notification so
    // we dont' focus any surface.
    const ptr_int: u64 = c.g_variant_get_uint64(parameter);
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
    const actions = .{
        .{ "quit", &gtkActionQuit, null },
        .{ "open-config", &gtkActionOpenConfig, null },
        .{ "reload-config", &gtkActionReloadConfig, null },
        .{ "present-surface", &gtkActionPresentSurface, c.G_VARIANT_TYPE("t") },
    };

    inline for (actions) |entry| {
        const action = c.g_simple_action_new(entry[0], entry[2]);
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
        c.g_menu_append(section, "Open Configuration", "app.open-config");
        c.g_menu_append(section, "Reload Configuration", "app.reload-config");
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
        c.g_menu_append(section, "Reset", "win.reset");
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
