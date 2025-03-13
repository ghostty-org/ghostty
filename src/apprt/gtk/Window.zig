/// A Window is a single, real GTK window that holds terminal surfaces.
///
/// A Window always contains a notebook (what GTK calls a tabbed container)
/// even while no tabs are in use, because a notebook without a tab bar has
/// no visible UI chrome.
const Window = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const build_config = @import("../../build_config.zig");
const configpkg = @import("../../config.zig");
const font = @import("../../font/main.zig");
const input = @import("../../input.zig");
const CoreSurface = @import("../../Surface.zig");

const App = @import("App.zig");
const Color = configpkg.Config.Color;
const Surface = @import("Surface.zig");
const Menu = @import("menu.zig").Menu;
const Tab = @import("Tab.zig");
const c = @import("c.zig").c;
const adwaita = @import("adwaita.zig");
const gtk_key = @import("key.zig");
const TabView = @import("TabView.zig");
const HeaderBar = @import("headerbar.zig");
const version = @import("version.zig");
const winproto = @import("winproto.zig");

const log = std.log.scoped(.gtk);

app: *App,

/// Used to deduplicate updateConfig invocations
last_config: usize,

/// Local copy of any configuration
config: DerivedConfig,

/// Our window
window: *c.GtkWindow,

/// The header bar for the window.
headerbar: HeaderBar,

/// The tab overview for the window. This is possibly null since there is no
/// taboverview without a AdwApplicationWindow (libadwaita >= 1.4.0).
tab_overview: ?*c.GtkWidget,

/// The notebook (tab grouping) for this window.
notebook: TabView,

/// The "main" menu that is attached to a button in the headerbar.
titlebar_menu: Menu(Window, "titlebar_menu", true),

/// The libadwaita widget for receiving toast send requests.
toast_overlay: *c.GtkWidget,

/// See adwTabOverviewOpen for why we have this.
adw_tab_overview_focus_timer: ?c.guint = null,

/// State and logic for windowing protocol for a window.
winproto: winproto.Window,

pub const DerivedConfig = struct {
    background_opacity: f64,
    background_blur: configpkg.Config.BackgroundBlur,
    window_theme: configpkg.Config.WindowTheme,
    gtk_titlebar: bool,
    gtk_titlebar_hide_when_maximized: bool,
    gtk_tabs_location: configpkg.Config.GtkTabsLocation,
    gtk_wide_tabs: bool,
    gtk_toolbar_style: configpkg.Config.GtkToolbarStyle,

    quick_terminal_position: configpkg.Config.QuickTerminalPosition,

    maximize: bool,
    fullscreen: bool,
    window_decoration: configpkg.Config.WindowDecoration,

    pub fn init(config: *const configpkg.Config) DerivedConfig {
        return .{
            .background_opacity = config.@"background-opacity",
            .background_blur = config.@"background-blur",
            .window_theme = config.@"window-theme",
            .gtk_titlebar = config.@"gtk-titlebar",
            .gtk_titlebar_hide_when_maximized = config.@"gtk-titlebar-hide-when-maximized",
            .gtk_tabs_location = config.@"gtk-tabs-location",
            .gtk_wide_tabs = config.@"gtk-wide-tabs",
            .gtk_toolbar_style = config.@"gtk-toolbar-style",

            .quick_terminal_position = config.@"quick-terminal-position",

            .maximize = config.maximize,
            .fullscreen = config.fullscreen,
            .window_decoration = config.@"window-decoration",
        };
    }
};

pub fn create(alloc: Allocator, app: *App) !*Window {
    // Allocate a fixed pointer for our window. We try to minimize
    // allocations but windows and other GUI requirements are so minimal
    // compared to the steady-state terminal operation so we use heap
    // allocation for this.
    //
    // The allocation is owned by the GtkWindow created. It will be
    // freed when the window is closed.
    var window = try alloc.create(Window);
    errdefer alloc.destroy(window);
    try window.init(app);
    return window;
}

pub fn init(self: *Window, app: *App) !void {
    // Set up our own state
    self.* = .{
        .app = app,
        .last_config = @intFromPtr(&app.config),
        .config = DerivedConfig.init(&app.config),
        .window = undefined,
        .headerbar = undefined,
        .tab_overview = null,
        .notebook = undefined,
        .titlebar_menu = undefined,
        .toast_overlay = undefined,
        .winproto = .none,
    };

    // Create the window
    const gtk_widget = c.adw_application_window_new(app.app);
    errdefer c.gtk_window_destroy(@ptrCast(gtk_widget));

    self.window = @ptrCast(@alignCast(gtk_widget));

    c.gtk_window_set_title(self.window, "Ghostty");
    c.gtk_window_set_default_size(self.window, 1000, 600);
    c.gtk_widget_add_css_class(gtk_widget, "window");
    c.gtk_widget_add_css_class(gtk_widget, "terminal-window");

    // GTK4 grabs F10 input by default to focus the menubar icon. We want
    // to disable this so that terminal programs can capture F10 (such as htop)
    c.gtk_window_set_handle_menubar_accel(self.window, 0);

    c.gtk_window_set_icon_name(self.window, build_config.bundle_id);

    // Create our box which will hold our widgets in the main content area.
    const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);

    // Set up the menus
    self.titlebar_menu.init(self);

    // Setup our notebook
    self.notebook.init(self);

    // If we are using Adwaita, then we can support the tab overview.
    self.tab_overview = if (adwaita.versionAtLeast(1, 4, 0)) overview: {
        const tab_overview = c.adw_tab_overview_new();
        c.adw_tab_overview_set_view(@ptrCast(tab_overview), @ptrCast(@alignCast(self.notebook.tab_view)));
        c.adw_tab_overview_set_enable_new_tab(@ptrCast(tab_overview), 1);
        _ = c.g_signal_connect_data(
            tab_overview,
            "create-tab",
            c.G_CALLBACK(&gtkNewTabFromOverview),
            self,
            null,
            c.G_CONNECT_DEFAULT,
        );
        _ = c.g_signal_connect_data(
            tab_overview,
            "notify::open",
            c.G_CALLBACK(&adwTabOverviewOpen),
            self,
            null,
            c.G_CONNECT_DEFAULT,
        );

        break :overview tab_overview;
    } else null;

    // gtk-titlebar can be used to disable the header bar (but keep the window
    // manager's decorations). We create this no matter if we are decorated or
    // not because we can have a keybind to toggle the decorations.
    self.headerbar.init();

    {
        const btn = c.gtk_menu_button_new();
        c.gtk_widget_set_tooltip_text(btn, "Main Menu");
        c.gtk_menu_button_set_icon_name(@ptrCast(btn), "open-menu-symbolic");
        c.gtk_menu_button_set_popover(@ptrCast(btn), @ptrCast(@alignCast(self.titlebar_menu.asWidget())));
        _ = c.g_signal_connect_data(
            btn,
            "notify::active",
            c.G_CALLBACK(&gtkTitlebarMenuActivate),
            self,
            null,
            c.G_CONNECT_DEFAULT,
        );
        self.headerbar.packEnd(btn);
    }

    // If we're using an AdwWindow then we can support the tab overview.
    if (self.tab_overview) |tab_overview| {
        if (!adwaita.versionAtLeast(1, 4, 0)) unreachable;
        const btn = switch (self.config.gtk_tabs_location) {
            .top, .bottom => btn: {
                const btn = c.gtk_toggle_button_new();
                c.gtk_widget_set_tooltip_text(btn, "View Open Tabs");
                c.gtk_button_set_icon_name(@ptrCast(btn), "view-grid-symbolic");
                _ = c.g_object_bind_property(
                    btn,
                    "active",
                    tab_overview,
                    "open",
                    c.G_BINDING_BIDIRECTIONAL | c.G_BINDING_SYNC_CREATE,
                );

                break :btn btn;
            },

            .hidden => btn: {
                const btn = c.adw_tab_button_new();
                c.adw_tab_button_set_view(@ptrCast(btn), @ptrCast(@alignCast(self.notebook.tab_view)));
                c.gtk_actionable_set_action_name(@ptrCast(btn), "overview.open");
                break :btn btn;
            },
        };

        c.gtk_widget_set_focus_on_click(btn, c.FALSE);
        self.headerbar.packEnd(btn);
    }

    {
        const btn = c.gtk_button_new_from_icon_name("tab-new-symbolic");
        c.gtk_widget_set_tooltip_text(btn, "New Tab");
        _ = c.g_signal_connect_data(btn, "clicked", c.G_CALLBACK(&gtkTabNewClick), self, null, c.G_CONNECT_DEFAULT);
        self.headerbar.packStart(btn);
    }

    _ = c.g_signal_connect_data(self.window, "notify::maximized", c.G_CALLBACK(&gtkWindowNotifyMaximized), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(self.window, "notify::fullscreened", c.G_CALLBACK(&gtkWindowNotifyFullscreened), self, null, c.G_CONNECT_DEFAULT);

    // If Adwaita is enabled and is older than 1.4.0 we don't have the tab overview and so we
    // need to stick the headerbar into the content box.
    if (!adwaita.versionAtLeast(1, 4, 0)) {
        c.gtk_box_append(@ptrCast(box), self.headerbar.asWidget());
    }

    // In debug we show a warning and apply the 'devel' class to the window.
    // This is a really common issue where people build from source in debug and performance is really bad.
    if (comptime std.debug.runtime_safety) {
        const warning_box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
        const warning_text = "⚠️ You're running a debug build of Ghostty! Performance will be degraded.";
        if (adwaita.versionAtLeast(1, 3, 0)) {
            const banner = c.adw_banner_new(warning_text);
            c.adw_banner_set_revealed(@ptrCast(banner), 1);
            c.gtk_box_append(@ptrCast(warning_box), @ptrCast(banner));
        } else {
            const warning = c.gtk_label_new(warning_text);
            c.gtk_widget_set_margin_top(warning, 10);
            c.gtk_widget_set_margin_bottom(warning, 10);
            c.gtk_box_append(@ptrCast(warning_box), warning);
        }
        c.gtk_widget_add_css_class(gtk_widget, "devel");
        c.gtk_widget_add_css_class(@ptrCast(warning_box), "background");
        c.gtk_box_append(@ptrCast(box), warning_box);
    }

    // Setup our toast overlay if we have one
    self.toast_overlay = c.adw_toast_overlay_new();
    c.adw_toast_overlay_set_child(
        @ptrCast(self.toast_overlay),
        @ptrCast(@alignCast(self.notebook.asWidget())),
    );
    c.gtk_box_append(@ptrCast(box), self.toast_overlay);

    // If we have a tab overview then we can set it on our notebook.
    if (self.tab_overview) |tab_overview| {
        if (!adwaita.versionAtLeast(1, 4, 0)) unreachable;
        c.adw_tab_overview_set_view(@ptrCast(tab_overview), @ptrCast(@alignCast(self.notebook.tab_view)));
    }

    // We register a key event controller with the window so
    // we can catch key events when our surface may not be
    // focused (i.e. when the libadw tab overview is shown).
    const ec_key_press = c.gtk_event_controller_key_new();
    errdefer c.g_object_unref(ec_key_press);
    c.gtk_widget_add_controller(gtk_widget, ec_key_press);

    // All of our events
    _ = c.g_signal_connect_data(self.window, "realize", c.G_CALLBACK(&gtkRealize), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(self.window, "close-request", c.G_CALLBACK(&gtkCloseRequest), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(self.window, "destroy", c.G_CALLBACK(&gtkDestroy), self, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(ec_key_press, "key-pressed", c.G_CALLBACK(&gtkKeyPressed), self, null, c.G_CONNECT_DEFAULT);

    // Our actions for the menu
    initActions(self);

    if (adwaita.versionAtLeast(1, 4, 0)) {
        const toolbar_view: *c.AdwToolbarView = @ptrCast(c.adw_toolbar_view_new());

        c.adw_toolbar_view_add_top_bar(toolbar_view, self.headerbar.asWidget());

        if (self.config.gtk_tabs_location != .hidden) {
            const tab_bar = c.adw_tab_bar_new();
            c.adw_tab_bar_set_view(tab_bar, @ptrCast(@alignCast(self.notebook.tab_view)));

            if (!self.config.gtk_wide_tabs) c.adw_tab_bar_set_expand_tabs(tab_bar, 0);

            const tab_bar_widget: *c.GtkWidget = @ptrCast(@alignCast(tab_bar));
            switch (self.config.gtk_tabs_location) {
                .top => c.adw_toolbar_view_add_top_bar(toolbar_view, tab_bar_widget),
                .bottom => c.adw_toolbar_view_add_bottom_bar(toolbar_view, tab_bar_widget),
                .hidden => unreachable,
            }
        }
        c.adw_toolbar_view_set_content(toolbar_view, box);

        const toolbar_style: c.AdwToolbarStyle = switch (self.config.gtk_toolbar_style) {
            .flat => c.ADW_TOOLBAR_FLAT,
            .raised => c.ADW_TOOLBAR_RAISED,
            .@"raised-border" => c.ADW_TOOLBAR_RAISED_BORDER,
        };
        c.adw_toolbar_view_set_top_bar_style(toolbar_view, toolbar_style);
        c.adw_toolbar_view_set_bottom_bar_style(toolbar_view, toolbar_style);

        // Set our application window content.
        c.adw_tab_overview_set_child(
            @ptrCast(self.tab_overview),
            @ptrCast(@alignCast(toolbar_view)),
        );
        c.adw_application_window_set_content(
            @ptrCast(gtk_widget),
            @ptrCast(@alignCast(self.tab_overview)),
        );
    } else tab_bar: {
        if (self.config.gtk_tabs_location == .hidden) break :tab_bar;
        // In earlier adwaita versions, we need to add the tabbar manually since we do not use
        // an AdwToolbarView.
        const tab_bar: *c.AdwTabBar = c.adw_tab_bar_new().?;
        c.gtk_widget_add_css_class(@ptrCast(@alignCast(tab_bar)), "inline");
        switch (self.config.gtk_tabs_location) {
            .top => c.gtk_box_insert_child_after(
                @ptrCast(box),
                @ptrCast(@alignCast(tab_bar)),
                @ptrCast(@alignCast(self.headerbar.asWidget())),
            ),
            .bottom => c.gtk_box_append(
                @ptrCast(box),
                @ptrCast(@alignCast(tab_bar)),
            ),
            .hidden => unreachable,
        }
        c.adw_tab_bar_set_view(tab_bar, @ptrCast(@alignCast(self.notebook.tab_view)));

        if (!self.config.gtk_wide_tabs) c.adw_tab_bar_set_expand_tabs(tab_bar, 0);
    }

    // If we want the window to be maximized, we do that here.
    if (self.config.maximize) c.gtk_window_maximize(self.window);

    // If we are in fullscreen mode, new windows start fullscreen.
    if (self.config.fullscreen) c.gtk_window_fullscreen(self.window);
}

pub fn present(self: *Window) void {
    const window: *gtk.Window = @ptrCast(self.window);
    window.present();
}

pub fn toggleVisibility(self: *Window) void {
    const window: *gtk.Widget = @ptrCast(self.window);
    window.setVisible(@intFromBool(window.isVisible() == 0));
}

pub fn updateConfig(
    self: *Window,
    config: *const configpkg.Config,
) !void {
    // avoid multiple reconfigs when we have many surfaces contained in this
    // window using the integer value of config as a simple marker to know if
    // we've "seen" this particular config before
    const this_config = @intFromPtr(config);
    if (self.last_config == this_config) return;
    self.last_config = this_config;

    self.config = DerivedConfig.init(config);

    // We always resync our appearance whenever the config changes.
    try self.syncAppearance();
}

/// Updates appearance based on config settings. Will be called once upon window
/// realization, every time the config is reloaded, and every time a window state
/// is toggled (un-/maximized, un-/fullscreened, window decorations toggled, etc.)
///
/// TODO: Many of the initial style settings in `create` could possibly be made
/// reactive by moving them here.
pub fn syncAppearance(self: *Window) !void {
    const csd_enabled = self.winproto.clientSideDecorationEnabled();
    c.gtk_window_set_decorated(self.window, @intFromBool(csd_enabled));

    // Fix any artifacting that may occur in window corners. The .ssd CSS
    // class is defined in the GtkWindow documentation:
    // https://docs.gtk.org/gtk4/class.Window.html#css-nodes. A definition
    // for .ssd is provided by GTK and Adwaita.
    toggleCssClass(@ptrCast(self.window), "csd", csd_enabled);
    toggleCssClass(@ptrCast(self.window), "ssd", !csd_enabled);
    toggleCssClass(@ptrCast(self.window), "no-border-radius", !csd_enabled);

    self.headerbar.setVisible(visible: {
        // Never display the header bar when CSDs are disabled.
        if (!csd_enabled) break :visible false;

        // Never display the header bar as a quick terminal.
        if (self.app.quick_terminal == self) break :visible false;

        // Unconditionally disable the header bar when fullscreened.
        if (self.config.fullscreen) break :visible false;

        // *Conditionally* disable the header bar when maximized,
        // and gtk-titlebar-hide-when-maximized is set
        if (self.config.maximize and self.config.gtk_titlebar_hide_when_maximized)
            break :visible false;

        break :visible self.config.gtk_titlebar;
    });

    toggleCssClass(
        @ptrCast(self.window),
        "background",
        self.config.background_opacity >= 1,
    );

    // Apply class to color headerbar if window-theme is set to `ghostty` and
    // GTK version is before 4.16. The conditional is because above 4.16
    // we use GTK CSS color variables.
    toggleCssClass(
        @ptrCast(self.window),
        "window-theme-ghostty",
        !version.atLeast(4, 16, 0) and self.config.window_theme == .ghostty,
    );

    if (self.tab_overview) |tab_overview| {
        if (!adwaita.versionAtLeast(1, 4, 0)) unreachable;

        // Disable the title buttons (close, maximize, minimize, ...)
        // *inside* the tab overview if CSDs are disabled.
        // We do spare the search button, though.
        c.adw_tab_overview_set_show_start_title_buttons(@ptrCast(tab_overview), @intFromBool(csd_enabled));
        c.adw_tab_overview_set_show_end_title_buttons(@ptrCast(tab_overview), @intFromBool(csd_enabled));

        // Update toolbar view style
        const toolbar_view: *c.AdwToolbarView = @ptrCast(c.adw_tab_overview_get_child(@ptrCast(tab_overview)));
        const toolbar_style: c.AdwToolbarStyle = switch (self.config.gtk_toolbar_style) {
            .flat => c.ADW_TOOLBAR_FLAT,
            .raised => c.ADW_TOOLBAR_RAISED,
            .@"raised-border" => c.ADW_TOOLBAR_RAISED_BORDER,
        };
        c.adw_toolbar_view_set_top_bar_style(toolbar_view, toolbar_style);
        c.adw_toolbar_view_set_bottom_bar_style(toolbar_view, toolbar_style);
    }

    self.winproto.syncAppearance() catch |err| {
        log.warn("failed to sync winproto appearance error={}", .{err});
    };

    if (self.app.quick_terminal == self) {
        self.winproto.syncQuickTerminal() catch |err| {
            log.warn("failed to sync quick terminal appearance error={}", .{err});
        };
    }
}

fn toggleCssClass(
    widget: *c.GtkWidget,
    class: [:0]const u8,
    v: bool,
) void {
    if (v) {
        c.gtk_widget_add_css_class(widget, class);
    } else {
        c.gtk_widget_remove_css_class(widget, class);
    }
}

/// Sets up the GTK actions for the window scope. Actions are how GTK handles
/// menus and such. The menu is defined in App.zig but the action is defined
/// here. The string name binds them.
fn initActions(self: *Window) void {
    // FIXME: when rest of file is converted to gobject
    const window: *gtk.ApplicationWindow = @ptrCast(@alignCast(self.window));
    const action_map = window.as(gio.ActionMap);
    const actions = .{
        .{ "about", gtkActionAbout },
        .{ "close", gtkActionClose },
        .{ "new-window", gtkActionNewWindow },
        .{ "new-tab", gtkActionNewTab },
        .{ "close-tab", gtkActionCloseTab },
        .{ "split-right", gtkActionSplitRight },
        .{ "split-down", gtkActionSplitDown },
        .{ "split-left", gtkActionSplitLeft },
        .{ "split-up", gtkActionSplitUp },
        .{ "toggle-inspector", gtkActionToggleInspector },
        .{ "copy", gtkActionCopy },
        .{ "paste", gtkActionPaste },
        .{ "reset", gtkActionReset },
        .{ "clear", gtkActionClear },
        .{ "prompt-title", gtkActionPromptTitle },
    };

    inline for (actions) |entry| {
        const action = gio.SimpleAction.new(entry[0], null);
        defer action.unref();
        _ = gio.SimpleAction.signals.activate.connect(
            action,
            *Window,
            entry[1],
            self,
            .{},
        );
        action_map.addAction(action.as(gio.Action));
    }
}

pub fn deinit(self: *Window) void {
    self.winproto.deinit(self.app.core_app.alloc);

    if (self.adw_tab_overview_focus_timer) |timer| {
        _ = c.g_source_remove(timer);
    }
}

/// Set the title of the window.
pub fn setTitle(self: *Window, title: [:0]const u8) void {
    self.headerbar.setTitle(title);
}

/// Set the subtitle of the window if it has one.
pub fn setSubtitle(self: *Window, subtitle: [:0]const u8) void {
    self.headerbar.setSubtitle(subtitle);
}

/// Add a new tab to this window.
pub fn newTab(self: *Window, parent: ?*CoreSurface) !void {
    const alloc = self.app.core_app.alloc;
    _ = try Tab.create(alloc, self, parent);

    // TODO: When this is triggered through a GTK action, the new surface
    // redraws correctly. When it's triggered through keyboard shortcuts, it
    // does not (cursor doesn't blink) unless reactivated by refocusing.
}

/// Close the tab for the given notebook page. This will automatically
/// handle closing the window if there are no more tabs.
pub fn closeTab(self: *Window, tab: *Tab) void {
    self.notebook.closeTab(tab);
}

/// Go to the previous tab for a surface.
pub fn gotoPreviousTab(self: *Window, surface: *Surface) bool {
    const tab = surface.container.tab() orelse {
        log.info("surface is not attached to a tab bar, cannot navigate", .{});
        return false;
    };
    if (!self.notebook.gotoPreviousTab(tab)) return false;
    self.focusCurrentTab();
    return true;
}

/// Go to the next tab for a surface.
pub fn gotoNextTab(self: *Window, surface: *Surface) bool {
    const tab = surface.container.tab() orelse {
        log.info("surface is not attached to a tab bar, cannot navigate", .{});
        return false;
    };
    if (!self.notebook.gotoNextTab(tab)) return false;
    self.focusCurrentTab();
    return true;
}

/// Move the current tab for a surface.
pub fn moveTab(self: *Window, surface: *Surface, position: c_int) void {
    const tab = surface.container.tab() orelse {
        log.info("surface is not attached to a tab bar, cannot navigate", .{});
        return;
    };
    self.notebook.moveTab(tab, position);
}

/// Go to the last tab for a surface.
pub fn gotoLastTab(self: *Window) bool {
    const max = self.notebook.nPages();
    return self.gotoTab(@intCast(max));
}

/// Go to the specific tab index.
pub fn gotoTab(self: *Window, n: usize) bool {
    if (n == 0) return false;
    const max = self.notebook.nPages();
    if (max == 0) return false;
    const page_idx = std.math.cast(c_int, n - 1) orelse return false;
    if (!self.notebook.gotoNthTab(@min(page_idx, max - 1))) return false;
    self.focusCurrentTab();
    return true;
}

/// Toggle tab overview (if present)
pub fn toggleTabOverview(self: *Window) void {
    if (self.tab_overview) |tab_overview_widget| {
        if (!adwaita.versionAtLeast(1, 4, 0)) unreachable;
        const tab_overview: *c.AdwTabOverview = @ptrCast(@alignCast(tab_overview_widget));
        c.adw_tab_overview_set_open(tab_overview, 1 - c.adw_tab_overview_get_open(tab_overview));
    }
}

/// Toggle the maximized state for this window.
pub fn toggleMaximize(self: *Window) void {
    if (self.config.maximize) {
        c.gtk_window_unmaximize(self.window);
    } else {
        c.gtk_window_maximize(self.window);
    }
    // We update the config and call syncAppearance
    // in the gtkWindowNotifyMaximized callback
}

/// Toggle fullscreen for this window.
pub fn toggleFullscreen(self: *Window) void {
    if (self.config.fullscreen) {
        c.gtk_window_unfullscreen(self.window);
    } else {
        c.gtk_window_fullscreen(self.window);
    }
    // We update the config and call syncAppearance
    // in the gtkWindowNotifyFullscreened callback
}

/// Toggle the window decorations for this window.
pub fn toggleWindowDecorations(self: *Window) void {
    self.config.window_decoration = switch (self.config.window_decoration) {
        .none => switch (self.app.config.@"window-decoration") {
            // If we started as none, then we switch to auto
            .none => .auto,
            // Switch back
            .auto, .client, .server => |v| v,
        },
        // Always set to none
        .auto, .client, .server => .none,
    };

    self.syncAppearance() catch |err| {
        log.err("failed to sync appearance={}", .{err});
    };
}

/// Grabs focus on the currently selected tab.
pub fn focusCurrentTab(self: *Window) void {
    const tab = self.notebook.currentTab() orelse return;
    const surface = tab.focus_child orelse return;
    const gl_area = @as(*c.GtkWidget, @ptrCast(surface.gl_area));
    _ = c.gtk_widget_grab_focus(gl_area);

    if (surface.getTitle()) |title| {
        self.setTitle(title);
    }
}

pub fn onConfigReloaded(self: *Window) void {
    self.sendToast("Reloaded the configuration");
}

pub fn sendToast(self: *Window, title: [:0]const u8) void {
    const toast = c.adw_toast_new(title);
    c.adw_toast_set_timeout(toast, 3);
    c.adw_toast_overlay_add_toast(@ptrCast(self.toast_overlay), toast);
}

fn gtkRealize(_: *c.GtkWindow, ud: ?*anyopaque) callconv(.C) bool {
    const self = userdataSelf(ud.?);

    // Initialize our window protocol logic
    if (winproto.Window.init(
        self.app.core_app.alloc,
        &self.app.winproto,
        self,
    )) |wp| {
        self.winproto = wp;
    } else |err| {
        log.warn("failed to initialize window protocol error={}", .{err});
    }

    // When we are realized we always setup our appearance
    self.syncAppearance() catch |err| {
        log.err("failed to initialize appearance={}", .{err});
    };

    return true;
}

fn gtkWindowNotifyMaximized(
    _: *c.GObject,
    _: *c.GParamSpec,
    ud: ?*anyopaque,
) callconv(.C) void {
    const self = userdataSelf(ud orelse return);
    self.config.maximize = c.gtk_window_is_maximized(self.window) != 0;
    self.syncAppearance() catch |err| {
        log.err("failed to sync appearance={}", .{err});
    };
}

fn gtkWindowNotifyFullscreened(
    _: *c.GObject,
    _: *c.GParamSpec,
    ud: ?*anyopaque,
) callconv(.C) void {
    const self = userdataSelf(ud orelse return);
    self.config.fullscreen = c.gtk_window_is_fullscreen(self.window) != 0;
    self.syncAppearance() catch |err| {
        log.err("failed to sync appearance={}", .{err});
    };
}

// Note: we MUST NOT use the GtkButton parameter because gtkActionNewTab
// sends an undefined value.
fn gtkTabNewClick(_: *c.GtkButton, ud: ?*anyopaque) callconv(.C) void {
    const self: *Window = @ptrCast(@alignCast(ud orelse return));
    const surface = self.actionSurface() orelse return;
    _ = surface.performBindingAction(.{ .new_tab = {} }) catch |err| {
        log.warn("error performing binding action error={}", .{err});
        return;
    };
}

/// Create a new tab from the AdwTabOverview. We can't copy gtkTabNewClick
/// because we need to return an AdwTabPage from this function.
fn gtkNewTabFromOverview(_: *c.GtkWidget, ud: ?*anyopaque) callconv(.C) ?*c.AdwTabPage {
    if (!adwaita.versionAtLeast(1, 4, 0)) unreachable;
    const self: *Window = userdataSelf(ud.?);

    const alloc = self.app.core_app.alloc;
    const surface = self.actionSurface();
    const tab = Tab.create(alloc, self, surface) catch return null;
    return c.adw_tab_view_get_page(@ptrCast(@alignCast(self.notebook.tab_view)), @ptrCast(@alignCast(tab.box)));
}

fn adwTabOverviewOpen(
    object: *c.GObject,
    _: *c.GParamSpec,
    ud: ?*anyopaque,
) void {
    const tab_overview: *c.AdwTabOverview = @ptrCast(@alignCast(object));

    // We only care about when the tab overview is closed.
    if (c.adw_tab_overview_get_open(tab_overview) == 1) {
        return;
    }

    // On tab overview close, focus is sometimes lost. This is an
    // upstream issue in libadwaita[1]. When this is resolved we
    // can put a runtime version check here to avoid this workaround.
    //
    // Our workaround is to start a timer after 500ms to refocus
    // the currently selected tab. We choose 500ms because the adw
    // animation is 400ms.
    //
    // [1]: https://gitlab.gnome.org/GNOME/libadwaita/-/issues/670
    const window: *Window = @ptrCast(@alignCast(ud.?));

    // If we have an old timer remove it
    if (window.adw_tab_overview_focus_timer) |timer| {
        _ = c.g_source_remove(timer);
    }

    // Restart our timer
    window.adw_tab_overview_focus_timer = c.g_timeout_add(
        500,
        @ptrCast(&adwTabOverviewFocusTimer),
        window,
    );
}

fn adwTabOverviewFocusTimer(
    self: *Window,
) callconv(.C) c.gboolean {
    self.adw_tab_overview_focus_timer = null;
    self.focusCurrentTab();

    // Remove the timer
    return 0;
}

pub fn close(self: *Window) void {
    const window: *gtk.Window = @ptrCast(self.window);

    // Unset the quick terminal on the app level
    if (self.app.quick_terminal == self) self.app.quick_terminal = null;

    window.destroy();
}

fn gtkCloseRequest(v: *c.GtkWindow, ud: ?*anyopaque) callconv(.C) bool {
    _ = v;
    log.debug("window close request", .{});
    const self = userdataSelf(ud.?);

    // This path should never occur, but this is here as a safety measure.
    if (self.app.quick_terminal == self) return true;

    // If none of our surfaces need confirmation, we can just exit.
    for (self.app.core_app.surfaces.items) |surface| {
        if (surface.container.window()) |window| {
            if (window == self and
                surface.core_surface.needsConfirmQuit()) break;
        }
    } else {
        self.close();
        return true;
    }

    // Setup our basic message
    const alert = c.gtk_message_dialog_new(
        self.window,
        c.GTK_DIALOG_MODAL,
        c.GTK_MESSAGE_QUESTION,
        c.GTK_BUTTONS_YES_NO,
        "Close this window?",
    );
    c.gtk_message_dialog_format_secondary_text(
        @ptrCast(alert),
        "All terminal sessions in this window will be terminated.",
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

    _ = c.g_signal_connect_data(alert, "response", c.G_CALLBACK(&gtkCloseConfirmation), self, null, c.G_CONNECT_DEFAULT);

    c.gtk_widget_show(alert);
    return true;
}

fn gtkCloseConfirmation(
    alert: *c.GtkMessageDialog,
    response: c.gint,
    ud: ?*anyopaque,
) callconv(.C) void {
    c.gtk_window_destroy(@ptrCast(alert));
    if (response == c.GTK_RESPONSE_YES) {
        const self = userdataSelf(ud.?);
        self.close();
    }
}

/// "destroy" signal for the window
fn gtkDestroy(v: *c.GtkWidget, ud: ?*anyopaque) callconv(.C) void {
    _ = v;
    log.debug("window destroy", .{});

    const self = userdataSelf(ud.?);
    const alloc = self.app.core_app.alloc;
    self.deinit();
    alloc.destroy(self);
}

fn gtkKeyPressed(
    ec_key: *c.GtkEventControllerKey,
    keyval: c.guint,
    keycode: c.guint,
    gtk_mods: c.GdkModifierType,
    ud: ?*anyopaque,
) callconv(.C) c.gboolean {
    const self = userdataSelf(ud.?);

    // We only process window-level events currently for the tab
    // overview. This is primarily defensive programming because
    // I'm not 100% certain how our logic below will interact with
    // other parts of the application but I know for sure we must
    // handle this during the tab overview.
    //
    // If someone can confidently show or explain that this is not
    // necessary, please remove this check.
    if (adwaita.versionAtLeast(1, 4, 0)) {
        if (self.tab_overview) |tab_overview_widget| {
            const tab_overview: *c.AdwTabOverview = @ptrCast(@alignCast(tab_overview_widget));
            if (c.adw_tab_overview_get_open(tab_overview) == 0) return 0;
        }
    }

    const surface = self.app.core_app.focusedSurface() orelse return 0;
    return if (surface.rt_surface.keyEvent(
        .press,
        ec_key,
        keyval,
        keycode,
        gtk_mods,
    )) 1 else 0;
}

fn gtkActionAbout(
    _: *gio.SimpleAction,
    _: ?*glib.Variant,
    self: *Window,
) callconv(.C) void {
    const name = "Ghostty";
    const icon = "com.mitchellh.ghostty";
    const website = "https://ghostty.org";

    if (adwaita.versionAtLeast(1, 5, 0)) {
        c.adw_show_about_dialog(
            @ptrCast(self.window),
            "application-name",
            name,
            "developer-name",
            "Ghostty Developers",
            "application-icon",
            icon,
            "version",
            build_config.version_string.ptr,
            "issue-url",
            "https://github.com/ghostty-org/ghostty/issues",
            "website",
            website,
            @as(?*anyopaque, null),
        );
    } else {
        c.gtk_show_about_dialog(
            self.window,
            "program-name",
            name,
            "logo-icon-name",
            icon,
            "title",
            "About Ghostty",
            "version",
            build_config.version_string.ptr,
            "website",
            website,
            @as(?*anyopaque, null),
        );
    }
}

fn gtkActionClose(
    _: *gio.SimpleAction,
    _: ?*glib.Variant,
    self: *Window,
) callconv(.C) void {
    self.close();
}

fn gtkActionNewWindow(
    _: *gio.SimpleAction,
    _: ?*glib.Variant,
    self: *Window,
) callconv(.C) void {
    const surface = self.actionSurface() orelse return;
    _ = surface.performBindingAction(.{ .new_window = {} }) catch |err| {
        log.warn("error performing binding action error={}", .{err});
        return;
    };
}

fn gtkActionNewTab(
    _: *gio.SimpleAction,
    _: ?*glib.Variant,
    self: *Window,
) callconv(.C) void {
    // We can use undefined because the button is not used.
    gtkTabNewClick(undefined, self);
}

fn gtkActionCloseTab(
    _: *gio.SimpleAction,
    _: ?*glib.Variant,
    self: *Window,
) callconv(.C) void {
    const surface = self.actionSurface() orelse return;
    _ = surface.performBindingAction(.{ .close_tab = {} }) catch |err| {
        log.warn("error performing binding action error={}", .{err});
        return;
    };
}

fn gtkActionSplitRight(
    _: *gio.SimpleAction,
    _: ?*glib.Variant,
    self: *Window,
) callconv(.C) void {
    const surface = self.actionSurface() orelse return;
    _ = surface.performBindingAction(.{ .new_split = .right }) catch |err| {
        log.warn("error performing binding action error={}", .{err});
        return;
    };
}

fn gtkActionSplitDown(
    _: *gio.SimpleAction,
    _: ?*glib.Variant,
    self: *Window,
) callconv(.C) void {
    const surface = self.actionSurface() orelse return;
    _ = surface.performBindingAction(.{ .new_split = .down }) catch |err| {
        log.warn("error performing binding action error={}", .{err});
        return;
    };
}

fn gtkActionSplitLeft(
    _: *gio.SimpleAction,
    _: ?*glib.Variant,
    self: *Window,
) callconv(.C) void {
    const surface = self.actionSurface() orelse return;
    _ = surface.performBindingAction(.{ .new_split = .left }) catch |err| {
        log.warn("error performing binding action error={}", .{err});
        return;
    };
}

fn gtkActionSplitUp(
    _: *gio.SimpleAction,
    _: ?*glib.Variant,
    self: *Window,
) callconv(.C) void {
    const surface = self.actionSurface() orelse return;
    _ = surface.performBindingAction(.{ .new_split = .up }) catch |err| {
        log.warn("error performing binding action error={}", .{err});
        return;
    };
}

fn gtkActionToggleInspector(
    _: *gio.SimpleAction,
    _: ?*glib.Variant,
    self: *Window,
) callconv(.C) void {
    const surface = self.actionSurface() orelse return;
    _ = surface.performBindingAction(.{ .inspector = .toggle }) catch |err| {
        log.warn("error performing binding action error={}", .{err});
        return;
    };
}

fn gtkActionCopy(
    _: *gio.SimpleAction,
    _: ?*glib.Variant,
    self: *Window,
) callconv(.C) void {
    const surface = self.actionSurface() orelse return;
    _ = surface.performBindingAction(.{ .copy_to_clipboard = {} }) catch |err| {
        log.warn("error performing binding action error={}", .{err});
        return;
    };
}

fn gtkActionPaste(
    _: *gio.SimpleAction,
    _: ?*glib.Variant,
    self: *Window,
) callconv(.C) void {
    const surface = self.actionSurface() orelse return;
    _ = surface.performBindingAction(.{ .paste_from_clipboard = {} }) catch |err| {
        log.warn("error performing binding action error={}", .{err});
        return;
    };
}

fn gtkActionReset(
    _: *gio.SimpleAction,
    _: ?*glib.Variant,
    self: *Window,
) callconv(.C) void {
    const surface = self.actionSurface() orelse return;
    _ = surface.performBindingAction(.{ .reset = {} }) catch |err| {
        log.warn("error performing binding action error={}", .{err});
        return;
    };
}

fn gtkActionClear(
    _: *gio.SimpleAction,
    _: ?*glib.Variant,
    self: *Window,
) callconv(.C) void {
    const surface = self.actionSurface() orelse return;
    _ = surface.performBindingAction(.{ .clear_screen = {} }) catch |err| {
        log.warn("error performing binding action error={}", .{err});
        return;
    };
}

fn gtkActionPromptTitle(
    _: *gio.SimpleAction,
    _: ?*glib.Variant,
    self: *Window,
) callconv(.C) void {
    const surface = self.actionSurface() orelse return;
    _ = surface.performBindingAction(.{ .prompt_surface_title = {} }) catch |err| {
        log.warn("error performing binding action error={}", .{err});
        return;
    };
}

/// Returns the surface to use for an action.
pub fn actionSurface(self: *Window) ?*CoreSurface {
    const tab = self.notebook.currentTab() orelse return null;
    const surface = tab.focus_child orelse return null;
    return &surface.core_surface;
}

fn gtkTitlebarMenuActivate(
    btn: *c.GtkMenuButton,
    _: *c.GParamSpec,
    ud: ?*anyopaque,
) callconv(.C) void {
    // debian 12 is stuck on GTK 4.8
    if (!version.atLeast(4, 10, 0)) return;
    const active = c.gtk_menu_button_get_active(btn) != 0;
    const self = userdataSelf(ud orelse return);
    if (active) {
        self.titlebar_menu.refresh();
    } else {
        self.focusCurrentTab();
    }
}

fn userdataSelf(ud: *anyopaque) *Window {
    return @ptrCast(@alignCast(ud));
}
