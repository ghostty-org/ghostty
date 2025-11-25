const std = @import("std");
const assert = @import("../../../quirks.zig").inlineAssert;
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const Surface = @import("surface.zig").Surface;
const Config = @import("config.zig").Config;

const log = std.log.scoped(.gtk_ghostty_surface_scrolled_window);

/// A wrapper widget that embeds a Surface inside a GtkScrolledWindow.
/// This provides scrollbar functionality for the terminal surface.
/// The surface property can be set during initialization or changed
/// dynamically via the surface property.
pub const SurfaceScrolledWindow = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhostttySurfaceScrolledWindow",
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
                    .accessor = C.privateObjFieldAccessor("config"),
                },
            );
        };

        pub const surface = struct {
            pub const name = "surface";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Surface,
                .{
                    .accessor = .{
                        .getter = getSurfaceValue,
                        .setter = setSurfaceValue,
                    },
                },
            );
        };
    };

    const Private = struct {
        config: ?*Config = null,
        config_binding: ?*gobject.Binding = null,
        surface: ?*Surface = null,
        pub var offset: c_int = 0;
    };

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();

        if (priv.config_binding) |binding| {
            binding.as(gobject.Object).unref();
            priv.config_binding = null;
        }

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

    fn finalize(self: *Self) callconv(.c) void {
        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn getSurfaceValue(self: *Self, value: *gobject.Value) void {
        gobject.ext.Value.set(
            value,
            self.private().surface,
        );
    }

    fn setSurfaceValue(self: *Self, value: *const gobject.Value) void {
        self.setSurface(gobject.ext.Value.get(
            value,
            ?*Surface,
        ));
    }

    pub fn getSurface(self: *Self) ?*Surface {
        return self.private().surface;
    }

    pub fn setSurface(self: *Self, surface_: ?*Surface) void {
        const priv = self.private();

        if (surface_ == priv.surface) return;

        self.as(gobject.Object).freezeNotify();
        defer self.as(gobject.Object).thawNotify();
        self.as(gobject.Object).notifyByPspec(properties.surface.impl.param_spec);

        priv.surface = surface_;
    }

    fn closureScrollbarPolicy(
        _: *Self,
        config_: ?*Config,
    ) callconv(.c) gtk.PolicyType {
        const config = if (config_) |c| c.get() else return .automatic;
        return switch (config.scrollbar) {
            .never => .never,
            .system => .automatic,
        };
    }

    fn propSurface(
        self: *Self,
        _: *gobject.ParamSpec,
        _: ?*anyopaque,
    ) callconv(.c) void {
        const priv = self.private();
        const child: *gtk.Widget = self.as(Parent).getChild().?;
        const scrolled_window = gobject.ext.cast(gtk.ScrolledWindow, child).?;
        scrolled_window.setChild(if (priv.surface) |s| s.as(gtk.Widget) else null);

        // Unbind old config binding if it exists
        if (priv.config_binding) |binding| {
            binding.as(gobject.Object).unref();
            priv.config_binding = null;
        }

        // Bind config from surface to our config property
        if (priv.surface) |surface| {
            priv.config_binding = surface.as(gobject.Object).bindProperty(
                properties.config.name,
                self.as(gobject.Object),
                properties.config.name,
                .{ .sync_create = true },
            );
        }
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
                    .minor = 5,
                    .name = "surface-scrolled-window",
                }),
            );

            // Bindings
            class.bindTemplateCallback("scrollbar_policy", &closureScrollbarPolicy);
            class.bindTemplateCallback("notify_surface", &propSurface);

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.config.impl,
                properties.surface.impl,
            });

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
