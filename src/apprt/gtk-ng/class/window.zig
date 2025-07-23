const std = @import("std");
const assert = std.debug.assert;
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const Application = @import("application.zig").Application;
const Surface = @import("surface.zig").Surface;
const Config = @import("config.zig").Config;

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
        pub const config = struct {
            pub const name = "config";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Config,
                .{
                    .nick = "Config",
                    .blurb = "The configuration that this window is using.",
                    .accessor = gobject.ext.privateFieldAccessor(
                        Self,
                        Private,
                        &Private.offset,
                        "config",
                    ),
                },
            );
        };
    };

    const Private = struct {
        /// The configuration that this window is using.
        config: ?*Config = null,

        /// The window title widget.
        window_title: *adw.WindowTitle = undefined,

        /// The surface in the view.
        surface: *Surface = undefined,

        pub var offset: c_int = 0;
    };

    pub fn new(app: *Application) *Self {
        return gobject.ext.newInstance(Self, .{ .application = app });
    }

    pub fn setupInitialFocus(self: *Self) void {
        _ = self.private().surface.as(gtk.Widget).grabFocus();
    }

    fn init(self: *Self, _: *Class) callconv(.C) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));

        const priv = self.private();

        const app = Application.default();
        priv.config = app.getConfig();

        const surface = priv.surface;
        _ = Surface.signals.@"close-request".connect(
            surface,
            *Self,
            surfaceCloseRequest,
            self,
            .{},
        );
        _ = gobject.Object.signals.notify.connect(
            surface,
            *Self,
            &surfaceNotifyHasFocus,
            self,
            .{ .detail = "has-focus" },
        );
        self.setupSurfacePropertyConnections(surface);
    }

    fn setupSurfacePropertyConnections(self: *Self, surface: *Surface) void {
        _ = gobject.Object.signals.notify.connect(
            surface,
            *Self,
            &surfaceNotifyTitle,
            self,
            .{ .detail = "title" },
        );

        _ = gobject.Object.signals.notify.connect(
            surface,
            *Self,
            &surfaceNotifyPwd,
            self,
            .{ .detail = "pwd" },
        );
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn dispose(self: *Self) callconv(.C) void {
        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        const priv = self.private();
        if (priv.config) |v| {
            v.unref();
            priv.config = null;
        }

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    /// Set the title of the window.
    fn setTitle(self: *Self, title: [:0]const u8) void {
        const window_title = self.private().window_title;
        window_title.setTitle(title);
    }

    /// Set the subtitle of the window.
    fn setSubtitle(self: *Self, subtitle: [:0]const u8) void {
        const window_title = self.private().window_title;
        window_title.setSubtitle(subtitle);
    }

    //---------------------------------------------------------------
    // Signal handlers

    fn surfaceCloseRequest(
        surface: *Surface,
        process_active: bool,
        self: *Self,
    ) callconv(.c) void {
        // Todo
        _ = process_active;

        assert(surface == self.private().surface);
        self.as(gtk.Window).close();
    }

    fn surfaceNotifyHasFocus(surface: *Surface, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        assert(surface == self.private().surface);

        self.setTitle(surface.getTitle().?);

        const subtitle: [:0]const u8 = switch (Application.default().getConfig().get().@"window-subtitle") {
            .@"working-directory" => surface.getPwd() orelse "",
            .false => "",
        };
        self.setSubtitle(subtitle);
    }

    fn surfaceNotifyTitle(surface: *Surface, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        assert(surface == self.private().surface);

        if (surface.as(gtk.Widget).grabFocus() == 0) {
            return;
        }

        self.setTitle(surface.getTitle().?);
    }

    fn surfaceNotifyPwd(surface: *Surface, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        assert(surface == self.private().surface);

        if (surface.as(gtk.Widget).grabFocus() == 0) {
            return;
        }

        if (Application.default().getConfig().get().@"window-subtitle" != .@"working-directory") {
            return;
        }

        self.setSubtitle(surface.getPwd() orelse "");
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
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "window",
                }),
            );

            // Bindings
            class.bindTemplateChildPrivate("window_title", .{});
            class.bindTemplateChildPrivate("surface", .{});

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.config.impl,
            });

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
    };
};
