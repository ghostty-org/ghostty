const std = @import("std");
const adw = @import("adw");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const adw_version = @import("../adw_version.zig");
const apprt = @import("../../../apprt.zig");
const gresource = @import("../build/gresource.zig");
const i18n = @import("../../../os/main.zig").i18n;
const Common = @import("../class.zig").Common;

const log = std.log.scoped(.gtk_ghostty_surface_child_exited);

pub const SurfaceChildExited = if (adw_version.supportsBanner())
    SurfaceChildExitedBanner
else
    SurfaceChildExitedNoop;

/// Child exited overlay based on adw.Banner introduced in
/// Adwaita 1.3.
const SurfaceChildExitedBanner = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttySurfaceChildExited",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        pub const data = struct {
            pub const name = "data";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*apprt.surface.Message.ChildExited,
                .{
                    .accessor = C.privateBoxedFieldAccessor("data"),
                },
            );
        };
    };

    pub const signals = struct {
        /// Emitted when the banner would like to be closed.
        pub const @"close-request" = struct {
            pub const name = "close-request";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{},
                void,
            );
        };
    };

    const Private = struct {
        /// The child exited data sent by the apprt.
        data: ?*apprt.surface.Message.ChildExited = null,

        // Template bindings
        banner: *adw.Banner,

        pub var offset: c_int = 0;
    };

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
    }

    pub fn setData(
        self: *Self,
        data_: ?*const apprt.surface.Message.ChildExited,
    ) void {
        const priv = self.private();
        if (priv.data) |v| glib.ext.destroy(v);
        const data = data_ orelse {
            priv.data = null;
            return;
        };

        const ptr = glib.ext.create(apprt.surface.Message.ChildExited);
        ptr.* = data.*;
        priv.data = ptr;
        self.as(gobject.Object).notifyByPspec(properties.data.impl.param_spec);
    }

    //---------------------------------------------------------------
    // Signal handlers

    fn propData(
        self: *Self,
        _: *gobject.ParamSpec,
        _: ?*anyopaque,
    ) callconv(.c) void {
        const priv = self.private();
        const banner = priv.banner;
        const data = priv.data orelse {
            // Not localized on purpose.
            banner.as(adw.Banner).setTitle("This is a bug in Ghostty. Please report it.");
            return;
        };
        if (data.exit_code == 0) {
            banner.as(adw.Banner).setTitle(i18n._("Command Succeeded"));
            self.as(gtk.Widget).addCssClass("normal");
            self.as(gtk.Widget).removeCssClass("abnormal");
        } else {
            banner.as(adw.Banner).setTitle(i18n._("Command Failed"));
            self.as(gtk.Widget).removeCssClass("normal");
            self.as(gtk.Widget).addCssClass("abnormal");
        }
    }

    fn closeButtonClicked(
        _: *adw.Banner,
        self: *Self,
    ) callconv(.c) void {
        signals.@"close-request".impl.emit(
            self,
            null,
            .{},
            null,
        );
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn dispose(self: *Self) callconv(.c) void {
        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.data) |v| {
            glib.ext.destroy(v);
            priv.data = null;
        }

        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
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

        fn init(class: *Class) callconv(.c) void {
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 3,
                    .name = "surface-child-exited",
                }),
            );

            // Template bindings
            class.bindTemplateChildPrivate("banner", .{});
            class.bindTemplateCallback("clicked", &closeButtonClicked);
            class.bindTemplateCallback("notify_data", &propData);

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.data.impl,
            });

            // Signals
            signals.@"close-request".impl.register(.{});

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};

/// Empty widget that does nothing if we don't have a new enough
/// Adwaita version to support the child exited banner.
const SurfaceChildExitedNoop = extern struct {
    /// Can be detected at comptime
    pub const noop = true;

    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Widget;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttySurfaceChildExited",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
    });

    pub const signals = struct {
        pub const @"close-request" = struct {
            pub const name = "close-request";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{},
                void,
            );
        };
    };

    pub fn setData(
        self: *Self,
        _: ?*const apprt.surface.Message.ChildExited,
    ) void {
        signals.@"close-request".impl.emit(
            self,
            null,
            .{},
            null,
        );
    }

    const C = Common(Self, null);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            _ = class;
            signals.@"close-request".impl.register(.{});
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
