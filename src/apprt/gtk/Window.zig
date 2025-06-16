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

const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const build_config = @import("../../build_config.zig");
const configpkg = @import("../../config.zig");
const font = @import("../../font/main.zig");
const i18n = @import("../../os/main.zig").i18n;
const input = @import("../../input.zig");
const CoreSurface = @import("../../Surface.zig");

const App = @import("App.zig");
const Builder = @import("Builder.zig");
const Color = configpkg.Config.Color;
const Surface = @import("Surface.zig");
const Menu = @import("menu.zig").Menu;
const Tab = @import("Tab.zig");
const gtk_key = @import("key.zig");
const TabView = @import("TabView.zig");
const HeaderBar = @import("headerbar.zig");
const CloseDialog = @import("CloseDialog.zig");
const CommandPalette = @import("CommandPalette.zig");
const winprotopkg = @import("winproto.zig");
const gtk_version = @import("gtk_version.zig");
const adw_version = @import("adw_version.zig");

const log = std.log.scoped(.gtk);

app: *App,

/// Used to deduplicate updateConfig invocations
last_config: usize,

/// Local copy of any configuration
config: DerivedConfig,

/// Our window
window: *adw.ApplicationWindow,

/// The header bar for the window.
headerbar: HeaderBar,

/// The tab bar for the window.
tab_bar: *adw.TabBar,

/// The tab overview for the window. This is possibly null since there is no
/// taboverview without a AdwApplicationWindow (libadwaita >= 1.4.0).
tab_overview: ?*adw.TabOverview,

/// The notebook (tab grouping) for this window.
notebook: TabView,

/// The "main" menu that is attached to a button in the headerbar.
titlebar_menu: Menu(Window, "titlebar_menu", true),

/// The libadwaita widget for receiving toast send requests.
toast_overlay: *adw.ToastOverlay,

/// The command palette.
command_palette: CommandPalette,

/// See adwTabOverviewOpen for why we have this.
adw_tab_overview_focus_timer: ?c_uint = null,

/// State and logic for windowing protocol for a window.
winproto: winprotopkg.Window,

pub const DerivedConfig = struct {
    background_opacity: f64,
    background_blur: configpkg.Config.BackgroundBlur,
    window_theme: configpkg.Config.WindowTheme,
    gtk_titlebar: bool,
    gtk_titlebar_hide_when_maximized: bool,
    gtk_tabs_location: configpkg.Config.GtkTabsLocation,
    gtk_wide_tabs: bool,
    gtk_toolbar_style: configpkg.Config.GtkToolbarStyle,
    window_show_tab_bar: configpkg.Config.WindowShowTabBar,

    quick_terminal_position: configpkg.Config.QuickTerminalPosition,
    quick_terminal_size: configpkg.Config.QuickTerminalSize,
    quick_terminal_autohide: bool,
    quick_terminal_keyboard_interactivity: configpkg.Config.QuickTerminalKeyboardInteractivity,

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
            .window_show_tab_bar = config.@"window-show-tab-bar",

            .quick_terminal_position = config.@"quick-terminal-position",
            .quick_terminal_size = config.@"quick-terminal-size",
            .quick_terminal_autohide = config.@"quick-terminal-autohide",
            .quick_terminal_keyboard_interactivity = config.@"quick-terminal-keyboard-interactivity",

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
        .config = .init(&app.config),
        .window = undefined,
        .headerbar = undefined,
        .tab_bar = undefined,
        .tab_overview = null,
        .notebook = undefined,
        .titlebar_menu = undefined,
        .toast_overlay = undefined,
        .command_palette = undefined,
        .winproto = .none,
    };

    // Create the window
    self.window = .new(app.app.as(gtk.Application));
    const gtk_window = self.window.as(gtk.Window);
    const gtk_widget = self.window.as(gtk.Widget);
    errdefer gtk_window.destroy();

    gtk_window.setTitle("Ghostty");
    gtk_window.setDefaultSize(1000, 600);
    gtk_widget.addCssClass("window");
    gtk_widget.addCssClass("terminal-window");

    // GTK4 grabs F10 input by default to focus the menubar icon. We want
    // to disable this so that terminal programs can capture F10 (such as htop)
    gtk_window.setHandleMenubarAccel(0);
    gtk_window.setIconName(build_config.bundle_id);

    // Create our box which will hold our widgets in the main content area.
    const box = gtk.Box.new(.vertical, 0);

    // Set up the menus
    self.titlebar_menu.init(self);

    // Setup our notebook
    self.notebook.init(self);

    if (adw_version.supportsDialogs()) try self.command_palette.init(self);

    // If we are using Adwaita, then we can support the tab overview.
    self.tab_overview = if (adw_version.supportsTabOverview()) overview: {
        const tab_overview = adw.TabOverview.new();
        tab_overview.setView(self.notebook.tab_view);
        tab_overview.setEnableNewTab(1);
        _ = adw.TabOverview.signals.create_tab.connect(
            tab_overview,
            *Window,
            gtkNewTabFromOverview,
            self,
            .{},
        );
        _ = gobject.Object.signals.notify.connect(
            tab_overview,
            *Window,
            adwTabOverviewOpen,
            self,
            .{
                .detail = "open",
            },
        );
        break :overview tab_overview;
    } else null;

    // gtk-titlebar can be used to disable the header bar (but keep the window
    // manager's decorations). We create this no matter if we are decorated or
    // not because we can have a keybind to toggle the decorations.
    self.headerbar.init(self);

    {
        const btn = gtk.MenuButton.new();
        btn.as(gtk.Widget).setTooltipText(i18n._("Main Menu"));
        btn.setIconName("open-menu-symbolic");
        btn.setPopover(self.titlebar_menu.asWidget());
        _ = gobject.Object.signals.notify.connect(
            btn,
            *Window,
            gtkTitlebarMenuActivate,
            self,
            .{
                .detail = "active",
            },
        );
        self.headerbar.packEnd(btn.as(gtk.Widget));
    }

    // If we're using an AdwWindow then we can support the tab overview.
    if (self.tab_overview) |tab_overview| {
        if (!adw_version.supportsTabOverview()) unreachable;

        const btn = switch (self.config.window_show_tab_bar) {
            .always, .auto => btn: {
                const btn = gtk.ToggleButton.new();
                btn.as(gtk.Widget).setTooltipText(i18n._("View Open Tabs"));
                btn.as(gtk.Button).setIconName("view-grid-symbolic");
                _ = btn.as(gobject.Object).bindProperty(
                    "active",
                    tab_overview.as(gobject.Object),
                    "open",
                    .{ .bidirectional = true, .sync_create = true },
                );
                break :btn btn.as(gtk.Widget);
            },
            .never => btn: {
                const btn = adw.TabButton.new();
                btn.setView(self.notebook.tab_view);
                btn.as(gtk.Actionable).setActionName("overview.open");
                break :btn btn.as(gtk.Widget);
            },
        };

        btn.setFocusOnClick(0);
        self.headerbar.packEnd(btn);
    }

    {
        const btn = adw.SplitButton.new();
        btn.setIconName("tab-new-symbolic");
        btn.as(gtk.Widget).setTooltipText(i18n._("New Tab"));
        btn.setDropdownTooltip(i18n._("New Split"));

        var builder = Builder.init("menu-headerbar-split_menu", 1, 0);
        defer builder.deinit();
        btn.setMenuModel(builder.getObject(gio.MenuModel, "menu"));

        _ = adw.SplitButton.signals.clicked.connect(
            btn,
            *Window,
            adwNewTabClick,
            self,
            .{},
        );
        self.headerbar.packStart(btn.as(gtk.Widget));
    }

    _ = gobject.Object.signals.notify.connect(
        self.window,
        *Window,
        gtkWindowNotifyMaximized,
        self,
        .{
            .detail = "maximized",
        },
    );
    _ = gobject.Object.signals.notify.connect(
        self.window,
        *Window,
        gtkWindowNotifyFullscreened,
        self,
        .{
            .detail = "fullscreened",
        },
    );
    _ = gobject.Object.signals.notify.connect(
        self.window,
        *Window,
        gtkWindowNotifyIsActive,
        self,
        .{
            .detail = "is-active",
        },
    );
    _ = gobject.Object.signals.notify.connect(
        self.window,
        *Window,
        gtkWindowUpdateScaleFactor,
        self,
        .{
            .detail = "scale-factor",
        },
    );

    // If Adwaita is enabled and is older than 1.4.0 we don't have the tab overview and so we
    // need to stick the headerbar into the content box.
    if (!adw_version.supportsTabOverview()) {
        box.append(self.headerbar.asWidget());
    }

    // In debug we show a warning and apply the 'devel' class to the window.
    // This is a really common issue where people build from source in debug and performance is really bad.
    if (comptime std.debug.runtime_safety) {
        const warning_box = gtk.Box.new(.vertical, 0);
        const warning_text = i18n._("⚠️ You're running a debug build of Ghostty! Performance will be degraded.");
        if (adw_version.supportsBanner()) {
            const banner = adw.Banner.new(warning_text);
            banner.setRevealed(1);
            warning_box.append(banner.as(gtk.Widget));
        } else {
            const warning = gtk.Label.new(warning_text);
            warning.as(gtk.Widget).setMarginTop(10);
            warning.as(gtk.Widget).setMarginBottom(10);
            warning_box.append(warning.as(gtk.Widget));
        }
        gtk_widget.addCssClass("devel");
        warning_box.as(gtk.Widget).addCssClass("background");
        box.append(warning_box.as(gtk.Widget));
    }

    // Setup our toast overlay if we have one
    self.toast_overlay = .new();
    self.toast_overlay.setChild(self.notebook.asWidget());
    box.append(self.toast_overlay.as(gtk.Widget));

    // If we have a tab overview then we can set it on our notebook.
    if (self.tab_overview) |tab_overview| {
        if (!adw_version.supportsTabOverview()) unreachable;
        tab_overview.setView(self.notebook.tab_view);
    }

    // We register a key event controller with the window so
    // we can catch key events when our surface may not be
    // focused (i.e. when the libadw tab overview is shown).
    const ec_key_press = gtk.EventControllerKey.new();
    errdefer ec_key_press.unref();
    gtk_widget.addController(ec_key_press.as(gtk.EventController));

    // All of our events
    _ = gtk.Widget.signals.realize.connect(
        self.window,
        *Window,
        gtkRealize,
        self,
        .{},
    );
    _ = gtk.Window.signals.close_request.connect(
        self.window,
        *Window,
        gtkCloseRequest,
        self,
        .{},
    );
    _ = gtk.Widget.signals.destroy.connect(
        self.window,
        *Window,
        gtkDestroy,
        self,
        .{},
    );
    _ = gtk.EventControllerKey.signals.key_pressed.connect(
        ec_key_press,
        *Window,
        gtkKeyPressed,
        self,
        .{},
    );

    // Our actions for the menu
    initActions(self);

    self.tab_bar = adw.TabBar.new();
    self.tab_bar.setView(self.notebook.tab_view);

    if (adw_version.supportsToolbarView()) {
        const toolbar_view = adw.ToolbarView.new();
        toolbar_view.addTopBar(self.headerbar.asWidget());

        switch (self.config.gtk_tabs_location) {
            .top => toolbar_view.addTopBar(self.tab_bar.as(gtk.Widget)),
            .bottom => toolbar_view.addBottomBar(self.tab_bar.as(gtk.Widget)),
        }
        toolbar_view.setContent(box.as(gtk.Widget));

        const toolbar_style: adw.ToolbarStyle = switch (self.config.gtk_toolbar_style) {
            .flat => .flat,
            .raised => .raised,
            .@"raised-border" => .raised_border,
        };
        toolbar_view.setTopBarStyle(toolbar_style);
        toolbar_view.setTopBarStyle(toolbar_style);

        // Set our application window content.
        self.tab_overview.?.setChild(toolbar_view.as(gtk.Widget));
        self.window.setContent(self.tab_overview.?.as(gtk.Widget));
    } else {
        // In earlier adwaita versions, we need to add the tabbar manually since we do not use
        // an AdwToolbarView.
        self.tab_bar.as(gtk.Widget).addCssClass("inline");

        switch (self.config.gtk_tabs_location) {
            .top => box.insertChildAfter(
                self.tab_bar.as(gtk.Widget),
                self.headerbar.asWidget(),
            ),
            .bottom => box.append(self.tab_bar.as(gtk.Widget)),
        }
    }

    // If we want the window to be maximized, we do that here.
    if (self.config.maximize) self.window.as(gtk.Window).maximize();

    // If we are in fullscreen mode, new windows start fullscreen.
    if (self.config.fullscreen) self.window.as(gtk.Window).fullscreen();
}

pub fn present(self: *Window) void {
    self.window.as(gtk.Window).present();
}

pub fn toggleVisibility(self: *Window) void {
    const widget = self.window.as(gtk.Widget);

    widget.setVisible(@intFromBool(widget.isVisible() == 0));
}

pub fn isQuickTerminal(self: *Window) bool {
    return self.app.quick_terminal == self;
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

    self.config = .init(config);

    // We always resync our appearance whenever the config changes.
    try self.syncAppearance();

    // Update binds inside the command palette
    try self.command_palette.updateConfig(config);
}

/// Updates appearance based on config settings. Will be called once upon window
/// realization, every time the config is reloaded, and every time a window state
/// is toggled (un-/maximized, un-/fullscreened, window decorations toggled, etc.)
///
/// TODO: Many of the initial style settings in `create` could possibly be made
/// reactive by moving them here.
pub fn syncAppearance(self: *Window) !void {
    const csd_enabled = self.winproto.clientSideDecorationEnabled();
    const gtk_window = self.window.as(gtk.Window);
    const gtk_widget = self.window.as(gtk.Widget);
    gtk_window.setDecorated(@intFromBool(csd_enabled));

    // Fix any artifacting that may occur in window corners. The .ssd CSS
    // class is defined in the GtkWindow documentation:
    // https://docs.gtk.org/gtk4/class.Window.html#css-nodes. A definition
    // for .ssd is provided by GTK and Adwaita.
    toggleCssClass(gtk_widget, "csd", csd_enabled);
    toggleCssClass(gtk_widget, "ssd", !csd_enabled);
    toggleCssClass(gtk_widget, "no-border-radius", !csd_enabled);

    self.headerbar.setVisible(visible: {
        // Never display the header bar when CSDs are disabled.
        if (!csd_enabled) break :visible false;

        // Never display the header bar as a quick terminal.
        if (self.isQuickTerminal()) break :visible false;

        // Unconditionally disable the header bar when fullscreened.
        if (self.window.as(gtk.Window).isFullscreen() != 0)
            break :visible false;

        // *Conditionally* disable the header bar when maximized,
        // and gtk-titlebar-hide-when-maximized is set
        if (self.window.as(gtk.Window).isMaximized() != 0 and
            self.config.gtk_titlebar_hide_when_maximized)
            break :visible false;

        break :visible self.config.gtk_titlebar;
    });

    toggleCssClass(
        gtk_widget,
        "background",
        self.config.background_opacity >= 1,
    );

    // Apply class to color headerbar if window-theme is set to `ghostty` and
    // GTK version is before 4.16. The conditional is because above 4.16
    // we use GTK CSS color variables.
    toggleCssClass(
        gtk_widget,
        "window-theme-ghostty",
        !gtk_version.atLeast(4, 16, 0) and self.config.window_theme == .ghostty,
    );

    if (self.tab_overview) |tab_overview| {
        if (!adw_version.supportsTabOverview()) unreachable;

        // Disable the title buttons (close, maximize, minimize, ...)
        // *inside* the tab overview if CSDs are disabled.
        // We do spare the search button, though.
        tab_overview.setShowStartTitleButtons(@intFromBool(csd_enabled));
        tab_overview.setShowEndTitleButtons(@intFromBool(csd_enabled));

        // Update toolbar view style
        toolbar_view: {
            const tab_overview_child = tab_overview.getChild() orelse break :toolbar_view;
            const toolbar_view = gobject.ext.cast(
                adw.ToolbarView,
                tab_overview_child,
            ) orelse break :toolbar_view;
            const toolbar_style: adw.ToolbarStyle = switch (self.config.gtk_toolbar_style) {
                .flat => .flat,
                .raised => .raised,
                .@"raised-border" => .raised_border,
            };
            toolbar_view.setTopBarStyle(toolbar_style);
            toolbar_view.setBottomBarStyle(toolbar_style);
        }
    }

    self.tab_bar.setExpandTabs(@intFromBool(self.config.gtk_wide_tabs));
    self.tab_bar.setAutohide(switch (self.config.window_show_tab_bar) {
        .auto, .never => @intFromBool(true),
        .always => @intFromBool(false),
    });
    self.tab_bar.as(gtk.Widget).setVisible(switch (self.config.window_show_tab_bar) {
        .always, .auto => @intFromBool(true),
        .never => @intFromBool(false),
    });

    self.winproto.syncAppearance() catch |err| {
        log.warn("failed to sync winproto appearance error={}", .{err});
    };
}

fn toggleCssClass(
    widget: *gtk.Widget,
    class: [:0]const u8,
    v: bool,
) void {
    if (v) {
        widget.addCssClass(class);
    } else {
        widget.removeCssClass(class);
    }
}

/// Sets up the GTK actions for the window scope. Actions are how GTK handles
/// menus and such. The menu is defined in App.zig but the action is defined
/// here. The string name binds them.
fn initActions(self: *Window) void {
    const window = self.window.as(gtk.ApplicationWindow);
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
        .{ "toggle-command-palette", gtkActionToggleCommandPalette },
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
    if (adw_version.supportsDialogs()) self.command_palette.deinit();

    if (self.adw_tab_overview_focus_timer) |timer| {
        _ = glib.Source.remove(timer);
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
    if (self.tab_overview) |tab_overview| {
        if (!adw_version.supportsTabOverview()) unreachable;
        const is_open = tab_overview.getOpen() != 0;
        tab_overview.setOpen(@intFromBool(!is_open));
    }
}

/// Toggle the maximized state for this window.
pub fn toggleMaximize(self: *Window) void {
    if (self.window.as(gtk.Window).isMaximized() != 0) {
        self.window.as(gtk.Window).unmaximize();
    } else {
        self.window.as(gtk.Window).maximize();
    }
    // We update the config and call syncAppearance
    // in the gtkWindowNotifyMaximized callback
}

/// Toggle fullscreen for this window.
pub fn toggleFullscreen(self: *Window) void {
    if (self.window.as(gtk.Window).isFullscreen() != 0) {
        self.window.as(gtk.Window).unfullscreen();
    } else {
        self.window.as(gtk.Window).fullscreen();
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

/// Toggle the window decorations for this window.
pub fn toggleCommandPalette(self: *Window) void {
    if (adw_version.supportsDialogs()) {
        self.command_palette.toggle();
    } else {
        log.warn("libadwaita 1.5+ is required for the command palette", .{});
    }
}

/// Grabs focus on the currently selected tab.
pub fn focusCurrentTab(self: *Window) void {
    const tab = self.notebook.currentTab() orelse return;
    const surface = tab.focus_child orelse return;
    _ = surface.gl_area.as(gtk.Widget).grabFocus();

    if (surface.getTitle()) |title| {
        self.setTitle(title);
    }
}

pub fn onConfigReloaded(self: *Window) void {
    self.sendToast(i18n._("Reloaded the configuration"));
}

pub fn sendToast(self: *Window, title: [*:0]const u8) void {
    const toast = adw.Toast.new(title);
    toast.setTimeout(3);
    self.toast_overlay.addToast(toast);
}

fn gtkRealize(_: *adw.ApplicationWindow, self: *Window) callconv(.c) void {
    // Initialize our window protocol logic
    if (winprotopkg.Window.init(
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
}

fn gtkWindowNotifyMaximized(
    _: *adw.ApplicationWindow,
    _: *gobject.ParamSpec,
    self: *Window,
) callconv(.c) void {
    self.syncAppearance() catch |err| {
        log.err("failed to sync appearance={}", .{err});
    };
}

fn gtkWindowNotifyFullscreened(
    _: *adw.ApplicationWindow,
    _: *gobject.ParamSpec,
    self: *Window,
) callconv(.c) void {
    self.syncAppearance() catch |err| {
        log.err("failed to sync appearance={}", .{err});
    };
}

fn gtkWindowNotifyIsActive(
    _: *adw.ApplicationWindow,
    _: *gobject.ParamSpec,
    self: *Window,
) callconv(.c) void {
    self.winproto.setUrgent(false) catch |err| {
        log.err("failed to unrequest user attention={}", .{err});
    };

    if (self.isQuickTerminal()) {
        // Hide when we're unfocused
        if (self.config.quick_terminal_autohide and self.window.as(gtk.Window).isActive() == 0) {
            self.toggleVisibility();
        }
    }
}

fn gtkWindowUpdateScaleFactor(
    _: *adw.ApplicationWindow,
    _: *gobject.ParamSpec,
    self: *Window,
) callconv(.c) void {
    // On some platforms (namely X11) we need to refresh our appearance when
    // the scale factor changes. In theory this could be more fine-grained as
    // a full refresh could be expensive, but a) this *should* be rare, and
    // b) quite noticeable visual bugs would occur if this is not present.
    self.winproto.syncAppearance() catch |err| {
        log.err(
            "failed to sync appearance after scale factor has been updated={}",
            .{err},
        );
        return;
    };
}

/// Perform a binding action on the window's action surface.
pub fn performBindingAction(self: *Window, action: input.Binding.Action) void {
    const surface = self.actionSurface() orelse return;
    _ = surface.performBindingAction(action) catch |err| {
        log.warn("error performing binding action error={}", .{err});
        return;
    };
}

fn gtkTabNewClick(_: *gtk.Button, self: *Window) callconv(.c) void {
    self.performBindingAction(.{ .new_tab = {} });
}

/// Create a new surface (tab or split).
fn adwNewTabClick(_: *adw.SplitButton, self: *Window) callconv(.c) void {
    self.performBindingAction(.{ .new_tab = {} });
}

/// Create a new tab from the AdwTabOverview. We can't copy gtkTabNewClick
/// because we need to return an AdwTabPage from this function.
fn gtkNewTabFromOverview(_: *adw.TabOverview, self: *Window) callconv(.c) *adw.TabPage {
    if (!adw_version.supportsTabOverview()) unreachable;

    const alloc = self.app.core_app.alloc;
    const surface = self.actionSurface();
    const tab = Tab.create(alloc, self, surface) catch unreachable;
    return self.notebook.tab_view.getPage(tab.box.as(gtk.Widget));
}

fn adwTabOverviewOpen(
    tab_overview: *adw.TabOverview,
    _: *gobject.ParamSpec,
    self: *Window,
) callconv(.c) void {
    if (!adw_version.supportsTabOverview()) unreachable;

    // We only care about when the tab overview is closed.
    if (tab_overview.getOpen() != 0) return;

    // On tab overview close, focus is sometimes lost. This is an
    // upstream issue in libadwaita[1]. When this is resolved we
    // can put a runtime version check here to avoid this workaround.
    //
    // Our workaround is to start a timer after 500ms to refocus
    // the currently selected tab. We choose 500ms because the adw
    // animation is 400ms.
    //
    // [1]: https://gitlab.gnome.org/GNOME/libadwaita/-/issues/670

    // If we have an old timer remove it
    if (self.adw_tab_overview_focus_timer) |timer| {
        _ = glib.Source.remove(timer);
    }

    // Restart our timer
    self.adw_tab_overview_focus_timer = glib.timeoutAdd(
        500,
        adwTabOverviewFocusTimer,
        self,
    );
}

fn adwTabOverviewFocusTimer(
    ud: ?*anyopaque,
) callconv(.c) c_int {
    if (!adw_version.supportsTabOverview()) unreachable;
    const self: *Window = @ptrCast(@alignCast(ud orelse return 0));
    self.adw_tab_overview_focus_timer = null;
    self.focusCurrentTab();

    // Remove the timer
    return 0;
}

pub fn close(self: *Window) void {
    const window = self.window.as(gtk.Window);

    // Unset the quick terminal on the app level
    if (self.isQuickTerminal()) self.app.quick_terminal = null;

    window.destroy();
}

pub fn closeWithConfirmation(self: *Window) void {
    // If none of our surfaces need confirmation, we can just exit.
    for (self.app.core_app.surfaces.items) |surface| {
        if (surface.container.window()) |window| {
            if (window == self and
                surface.core_surface.needsConfirmQuit()) break;
        }
    } else {
        self.close();
        return;
    }

    CloseDialog.show(.{ .window = self }) catch |err| {
        log.err("failed to open close dialog={}", .{err});
    };
}

fn gtkCloseRequest(_: *adw.ApplicationWindow, self: *Window) callconv(.c) c_int {
    log.debug("window close request", .{});

    self.closeWithConfirmation();
    return 1;
}

/// "destroy" signal for the window
fn gtkDestroy(_: *adw.ApplicationWindow, self: *Window) callconv(.c) void {
    log.debug("window destroy", .{});

    const alloc = self.app.core_app.alloc;
    self.deinit();
    alloc.destroy(self);
}

fn gtkKeyPressed(
    ec_key: *gtk.EventControllerKey,
    keyval: c_uint,
    keycode: c_uint,
    gtk_mods: gdk.ModifierType,
    self: *Window,
) callconv(.c) c_int {
    // We only process window-level events currently for the tab
    // overview. This is primarily defensive programming because
    // I'm not 100% certain how our logic below will interact with
    // other parts of the application but I know for sure we must
    // handle this during the tab overview.
    //
    // If someone can confidently show or explain that this is not
    // necessary, please remove this check.
    if (adw_version.supportsTabOverview()) {
        if (self.tab_overview) |tab_overview| {
            if (tab_overview.getOpen() == 0) return 0;
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
) callconv(.c) void {
    const name = "Ghostty";
    const icon = "com.mitchellh.ghostty";
    const website = "https://ghostty.org";

    if (adw_version.supportsDialogs()) {
        adw.showAboutDialog(
            self.window.as(gtk.Widget),
            "application-name",
            name,
            "developer-name",
            i18n._("Ghostty Developers"),
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
        gtk.showAboutDialog(
            self.window.as(gtk.Window),
            "program-name",
            name,
            "logo-icon-name",
            icon,
            "title",
            i18n._("About Ghostty"),
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
) callconv(.c) void {
    self.closeWithConfirmation();
}

fn gtkActionNewWindow(
    _: *gio.SimpleAction,
    _: ?*glib.Variant,
    self: *Window,
) callconv(.c) void {
    self.performBindingAction(.{ .new_window = {} });
}

fn gtkActionNewTab(
    _: *gio.SimpleAction,
    _: ?*glib.Variant,
    self: *Window,
) callconv(.c) void {
    self.performBindingAction(.{ .new_tab = {} });
}

fn gtkActionCloseTab(
    _: *gio.SimpleAction,
    _: ?*glib.Variant,
    self: *Window,
) callconv(.c) void {
    self.performBindingAction(.{ .close_tab = {} });
}

fn gtkActionSplitRight(
    _: *gio.SimpleAction,
    _: ?*glib.Variant,
    self: *Window,
) callconv(.c) void {
    self.performBindingAction(.{ .new_split = .right });
}

fn gtkActionSplitDown(
    _: *gio.SimpleAction,
    _: ?*glib.Variant,
    self: *Window,
) callconv(.c) void {
    self.performBindingAction(.{ .new_split = .down });
}

fn gtkActionSplitLeft(
    _: *gio.SimpleAction,
    _: ?*glib.Variant,
    self: *Window,
) callconv(.c) void {
    self.performBindingAction(.{ .new_split = .left });
}

fn gtkActionSplitUp(
    _: *gio.SimpleAction,
    _: ?*glib.Variant,
    self: *Window,
) callconv(.c) void {
    self.performBindingAction(.{ .new_split = .up });
}

fn gtkActionToggleInspector(
    _: *gio.SimpleAction,
    _: ?*glib.Variant,
    self: *Window,
) callconv(.c) void {
    self.performBindingAction(.{ .inspector = .toggle });
}

fn gtkActionToggleCommandPalette(
    _: *gio.SimpleAction,
    _: ?*glib.Variant,
    self: *Window,
) callconv(.C) void {
    self.performBindingAction(.toggle_command_palette);
}

fn gtkActionCopy(
    _: *gio.SimpleAction,
    _: ?*glib.Variant,
    self: *Window,
) callconv(.c) void {
    self.performBindingAction(.{ .copy_to_clipboard = {} });
}

fn gtkActionPaste(
    _: *gio.SimpleAction,
    _: ?*glib.Variant,
    self: *Window,
) callconv(.c) void {
    self.performBindingAction(.{ .paste_from_clipboard = {} });
}

fn gtkActionReset(
    _: *gio.SimpleAction,
    _: ?*glib.Variant,
    self: *Window,
) callconv(.c) void {
    self.performBindingAction(.{ .reset = {} });
}

fn gtkActionClear(
    _: *gio.SimpleAction,
    _: ?*glib.Variant,
    self: *Window,
) callconv(.c) void {
    self.performBindingAction(.{ .clear_screen = {} });
}

fn gtkActionPromptTitle(
    _: *gio.SimpleAction,
    _: ?*glib.Variant,
    self: *Window,
) callconv(.c) void {
    self.performBindingAction(.{ .prompt_surface_title = {} });
}

/// Returns the surface to use for an action.
pub fn actionSurface(self: *Window) ?*CoreSurface {
    const tab = self.notebook.currentTab() orelse return null;
    const surface = tab.focus_child orelse return null;
    return &surface.core_surface;
}

fn gtkTitlebarMenuActivate(
    btn: *gtk.MenuButton,
    _: *gobject.ParamSpec,
    self: *Window,
) callconv(.c) void {
    // debian 12 is stuck on GTK 4.8
    if (!gtk_version.atLeast(4, 10, 0)) return;
    const active = btn.getActive() != 0;
    if (active) {
        self.titlebar_menu.refresh();
    } else {
        self.focusCurrentTab();
    }
}
