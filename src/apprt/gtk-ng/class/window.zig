const std = @import("std");
const build_config = @import("../../../build_config.zig");
const assert = std.debug.assert;
const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const i18n = @import("../../../os/main.zig").i18n;
const apprt = @import("../../../apprt.zig");
const input = @import("../../../input.zig");
const CoreSurface = @import("../../../Surface.zig");
const gtk_version = @import("../gtk_version.zig");
const adw_version = @import("../adw_version.zig");
const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const Config = @import("config.zig").Config;
const Application = @import("application.zig").Application;
const CloseConfirmationDialog = @import("close_confirmation_dialog.zig").CloseConfirmationDialog;
const Surface = @import("surface.zig").Surface;
const DebugWarning = @import("debug_warning.zig").DebugWarning;

const log = std.log.scoped(.gtk_ghostty_window);

pub const Window = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.ApplicationWindow;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyWindow",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        /// The active surface is the focus that should be receiving all
        /// surface-targeted actions. This is usually the focused surface,
        /// but may also not be focused if the user has selected a non-surface
        /// widget.
        pub const @"active-surface" = struct {
            pub const name = "active-surface";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Surface,
                .{
                    .nick = "Active Surface",
                    .blurb = "The currently active surface.",
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?*Surface,
                        .{
                            .getter = Self.getActiveSurface,
                        },
                    ),
                },
            );
        };

        pub const config = struct {
            pub const name = "config";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Config,
                .{
                    .nick = "Config",
                    .blurb = "The configuration that this surface is using.",
                    .accessor = C.privateObjFieldAccessor("config"),
                },
            );
        };

        pub const debug = struct {
            pub const name = "debug";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .nick = "Debug",
                    .blurb = "True if runtime safety checks are enabled.",
                    .default = build_config.is_debug,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = struct {
                            pub fn getter(_: *Window) bool {
                                return build_config.is_debug;
                            }
                        }.getter,
                    }),
                },
            );
        };

        pub const @"headerbar-visible" = struct {
            pub const name = "headerbar-visible";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .nick = "Headerbar Visible",
                    .blurb = "True if the headerbar is visible.",
                    .default = true,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = Self.getHeaderbarVisible,
                    }),
                },
            );
        };

        pub const @"background-opaque" = struct {
            pub const name = "background-opaque";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .nick = "Background Opaque",
                    .blurb = "True if the background should be opaque.",
                    .default = true,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = Self.getBackgroundOpaque,
                    }),
                },
            );
        };
    };

    const Private = struct {
        /// The configuration that this surface is using.
        config: ?*Config = null,

        // Template bindings
        surface: *Surface,
        toast_overlay: *adw.ToastOverlay,

        pub var offset: c_int = 0;
    };

    pub fn new(app: *Application, parent_: ?*CoreSurface) *Self {
        const self = gobject.ext.newInstance(Self, .{
            .application = app,
        });

        if (parent_) |parent| {
            const priv = self.private();
            priv.surface.setParent(parent);
        }

        return self;
    }

    fn init(self: *Self, _: *Class) callconv(.C) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));

        // If our configuration is null then we get the configuration
        // from the application.
        const priv = self.private();
        if (priv.config == null) {
            const app = Application.default();
            priv.config = app.getConfig();
        }

        // Add our dev CSS class if we're in debug mode.
        if (comptime build_config.is_debug) {
            self.as(gtk.Widget).addCssClass("devel");
        }

        // Set our window icon. We can't set this in the blueprint file
        // because its dependent on the build config.
        self.as(gtk.Window).setIconName(build_config.bundle_id);

        // Initialize our actions
        self.initActionMap();

        // We always sync our appearance at the end because loading our
        // config and such can affect our bindings which ar setup initially
        // in initTemplate.
        self.syncAppearance();

        // We need to do this so that the title initializes properly,
        // I think because its a dynamic getter.
        self.as(gobject.Object).notifyByPspec(properties.@"active-surface".impl.param_spec);
    }

    /// Setup our action map.
    fn initActionMap(self: *Self) void {
        const actions = .{
            .{ "about", actionAbout, null },
            .{ "close", actionClose, null },
            .{ "new-window", actionNewWindow, null },
            .{ "copy", actionCopy, null },
            .{ "paste", actionPaste, null },
            .{ "reset", actionReset, null },
            .{ "clear", actionClear, null },
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

    /// Updates various appearance properties. This should always be safe
    /// to call multiple times. This should be called whenever a change
    /// happens that might affect how the window appears (config change,
    /// fullscreen, etc.).
    fn syncAppearance(self: *Window) void {
        // TODO: CSD/SSD

        // Trigger our headerbar visibility to refresh
        self.as(gobject.Object).notifyByPspec(properties.@"headerbar-visible".impl.param_spec);
        // Trigger background opacity to refresh
        self.as(gobject.Object).notifyByPspec(properties.@"background-opaque".impl.param_spec);
    }

    fn toggleCssClass(self: *Window, class: [:0]const u8, value: bool) void {
        const widget = self.as(gtk.Widget);
        if (value)
            widget.addCssClass(class.ptr)
        else
            widget.removeCssClass(class.ptr);
    }

    /// Perform a binding action on the window's active surface.
    fn performBindingAction(
        self: *Window,
        action: input.Binding.Action,
    ) void {
        const surface = self.getActiveSurface() orelse return;
        const core_surface = surface.core() orelse return;
        _ = core_surface.performBindingAction(action) catch |err| {
            log.warn("error performing binding action error={}", .{err});
            return;
        };
    }

    /// Queue a simple text-based toast. All text-based toasts share the
    /// same timeout for consistency.
    ///
    // This is not `pub` because we should be using signals emitted by
    // other widgets to trigger our toasts. Other objects should not
    // trigger toasts directly.
    fn addToast(self: *Window, title: [*:0]const u8) void {
        const toast = adw.Toast.new(title);
        toast.setTimeout(3);
        self.private().toast_overlay.addToast(toast);
    }

    //---------------------------------------------------------------
    // Properties

    /// Get the currently active surface. See the "active-surface" property.
    /// This does not ref the value.
    fn getActiveSurface(self: *Self) ?*Surface {
        const priv = self.private();
        return priv.surface;
    }

    fn getHeaderbarVisible(self: *Self) bool {
        // TODO: CSD/SSD
        // TODO: QuickTerminal

        // If we're fullscreen we never show the header bar.
        if (self.as(gtk.Window).isFullscreen() != 0) return false;

        // The remainder needs a config
        const config_obj = self.private().config orelse return true;
        const config = config_obj.get();

        // *Conditionally* disable the header bar when maximized,
        // and gtk-titlebar-hide-when-maximized is set
        if (self.as(gtk.Window).isMaximized() != 0 and
            config.@"gtk-titlebar-hide-when-maximized")
        {
            return false;
        }

        return config.@"gtk-titlebar";
    }

    fn getBackgroundOpaque(self: *Self) bool {
        const priv = self.private();
        const config = (priv.config orelse return true).get();
        return config.@"background-opacity" >= 1.0;
    }

    fn propConfig(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // We only toast if configured to
        const priv = self.private();
        const config_obj = priv.config orelse {
            self.syncAppearance();
            return;
        };
        const config = config_obj.get();
        if (config.@"app-notifications".@"config-reload") {
            self.addToast(i18n._("Reloaded the configuration"));
        }
        self.syncAppearance();
    }

    fn propFullscreened(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.syncAppearance();
    }

    fn propMaximized(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.syncAppearance();
    }

    fn propMenuActive(
        button: *gtk.MenuButton,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // Debian 12 is stuck on GTK 4.8
        if (!gtk_version.atLeast(4, 10, 0)) return;

        // We only care if we're activating. If we're activating then
        // we need to check the validity of our menu items.
        const active = button.getActive() != 0;
        if (!active) return;

        const has_selection = selection: {
            const surface = self.getActiveSurface() orelse
                break :selection false;
            const core_surface = surface.core() orelse
                break :selection false;
            break :selection core_surface.hasSelection();
        };

        const action_map: *gio.ActionMap = gobject.ext.cast(
            gio.ActionMap,
            self,
        ) orelse return;
        const action: *gio.SimpleAction = gobject.ext.cast(
            gio.SimpleAction,
            action_map.lookupAction("copy") orelse return,
        ) orelse return;
        action.setEnabled(@intFromBool(has_selection));
    }

    /// Add or remove "background" CSS class depending on if the background
    /// should be opaque.
    fn propBackgroundOpaque(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.toggleCssClass("background", self.getBackgroundOpaque());
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn dispose(self: *Self) callconv(.C) void {
        const priv = self.private();
        if (priv.config) |v| {
            v.unref();
            priv.config = null;
        }

        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    //---------------------------------------------------------------
    // Signal handlers

    fn windowCloseRequest(
        _: *gtk.Window,
        self: *Self,
    ) callconv(.c) c_int {
        // If our surface needs confirmation then we show confirmation.
        // This will have to be expanded to a list when we have tabs
        // or splits.
        confirm: {
            const surface = self.getActiveSurface() orelse break :confirm;
            const core_surface = surface.core() orelse break :confirm;
            if (!core_surface.needsConfirmQuit()) break :confirm;

            // Show a confirmation dialog
            const dialog: *CloseConfirmationDialog = .new(.app);
            _ = CloseConfirmationDialog.signals.@"close-request".connect(
                dialog,
                *Self,
                closeConfirmationClose,
                self,
                .{},
            );

            // Show it
            dialog.present(self.as(gtk.Widget));
            return @intFromBool(true);
        }

        self.as(gtk.Window).destroy();
        return @intFromBool(false);
    }

    fn closeConfirmationClose(
        _: *CloseConfirmationDialog,
        self: *Self,
    ) callconv(.c) void {
        self.as(gtk.Window).destroy();
    }

    fn surfaceClipboardWrite(
        _: *Surface,
        clipboard_type: apprt.Clipboard,
        text: [*:0]const u8,
        self: *Self,
    ) callconv(.c) void {
        // We only toast for the standard clipboard.
        if (clipboard_type != .standard) return;

        // We only toast if configured to
        const priv = self.private();
        const config_obj = priv.config orelse return;
        const config = config_obj.get();
        if (!config.@"app-notifications".@"clipboard-copy") {
            return;
        }

        if (text[0] != 0)
            self.addToast(i18n._("Copied to clipboard"))
        else
            self.addToast(i18n._("Cleared clipboard"));
    }

    fn surfaceCloseRequest(
        surface: *Surface,
        scope: *const Surface.CloseScope,
        self: *Self,
    ) callconv(.c) void {
        // Todo
        _ = scope;

        assert(surface == self.private().surface);
        self.as(gtk.Window).close();
    }

    fn surfaceToggleFullscreen(
        surface: *Surface,
        self: *Self,
    ) callconv(.c) void {
        _ = surface;
        if (self.as(gtk.Window).isFullscreen() != 0) {
            self.as(gtk.Window).unfullscreen();
        } else {
            self.as(gtk.Window).fullscreen();
        }

        // We react to the changes in the propFullscreen callback
    }

    fn surfaceToggleMaximize(
        surface: *Surface,
        self: *Self,
    ) callconv(.c) void {
        _ = surface;
        if (self.as(gtk.Window).isMaximized() != 0) {
            self.as(gtk.Window).unmaximize();
        } else {
            self.as(gtk.Window).maximize();
        }

        // We react to the changes in the propMaximized callback
    }

    fn actionAbout(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const name = "Ghostty";
        const icon = "com.mitchellh.ghostty";
        const website = "https://ghostty.org";

        if (adw_version.supportsDialogs()) {
            adw.showAboutDialog(
                self.as(gtk.Widget),
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
                self.as(gtk.Window),
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

    fn actionClose(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        self.as(gtk.Window).close();
    }

    fn actionNewWindow(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.new_window);
    }

    fn actionCopy(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.copy_to_clipboard);
    }

    fn actionPaste(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.paste_from_clipboard);
    }

    fn actionReset(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.reset);
    }

    fn actionClear(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.clear_screen);
    }

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
            gobject.ext.ensureType(Surface);
            gobject.ext.ensureType(DebugWarning);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "window",
                }),
            );

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.@"active-surface".impl,
                properties.config.impl,
                properties.debug.impl,
                properties.@"headerbar-visible".impl,
                properties.@"background-opaque".impl,
            });

            // Bindings
            class.bindTemplateChildPrivate("surface", .{});
            class.bindTemplateChildPrivate("toast_overlay", .{});

            // Template Callbacks
            class.bindTemplateCallback("close_request", &windowCloseRequest);
            class.bindTemplateCallback("surface_clipboard_write", &surfaceClipboardWrite);
            class.bindTemplateCallback("surface_close_request", &surfaceCloseRequest);
            class.bindTemplateCallback("surface_toggle_fullscreen", &surfaceToggleFullscreen);
            class.bindTemplateCallback("surface_toggle_maximize", &surfaceToggleMaximize);
            class.bindTemplateCallback("notify_config", &propConfig);
            class.bindTemplateCallback("notify_fullscreened", &propFullscreened);
            class.bindTemplateCallback("notify_maximized", &propMaximized);
            class.bindTemplateCallback("notify_menu_active", &propMenuActive);
            class.bindTemplateCallback("notify_background_opaque", &propBackgroundOpaque);

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
