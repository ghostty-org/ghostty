const std = @import("std");
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const gresource = @import("../build/gresource.zig");
const adw_version = @import("../adw_version.zig");
const Common = @import("../class.zig").Common;
const Config = @import("config.zig").Config;
const Dialog = @import("dialog.zig").Dialog;

const log = std.log.scoped(.gtk_ghostty_config_errors_dialog);

pub const ConfigErrorsDialog = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = Dialog;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyConfigErrorsDialog",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        pub const config = gobject.ext.defineProperty(
            "config",
            Self,
            ?*Config,
            .{
                .accessor = gobject.ext.typedAccessor(
                    Self,
                    ?*Config,
                    .{
                        .getter = Self.getConfig,
                        .setter = Self.setConfig,
                    },
                ),
            },
        );
    };

    pub const signals = struct {
        pub const @"reload-config" = struct {
            pub const name = "reload-config";
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
        config: ?*Config,
        pub var offset: c_int = 0;
    };

    pub fn new(config: *Config) *Self {
        return gobject.ext.newInstance(Self, .{
            .config = config,
        });
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
    }

    pub fn present(self: *Self, parent: ?*gtk.Widget) void {
        self.as(Dialog).present(parent);
    }

    pub fn close(self: *Self) void {
        self.as(Dialog).close();
    }

    fn response(
        self: *Self,
        response_id: [*:0]const u8,
    ) callconv(.c) void {
        if (std.mem.orderZ(u8, response_id, "reload") != .eq) return;
        signals.@"reload-config".impl.emit(
            self,
            null,
            .{},
            null,
        );
    }

    fn dispose(self: *Self) callconv(.c) void {
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

    fn getConfig(self: *Self) ?*Config {
        return self.private().config;
    }

    fn setConfig(self: *Self, config: ?*Config) void {
        const priv = self.private();
        if (priv.config) |old| old.unref();

        // We don't need to increase the reference count because
        // the property setter handles it (uses GValue.get vs. take)
        priv.config = config;
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
            gobject.ext.ensureType(Dialog);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 2,
                    .name = "config-errors-dialog",
                }),
            );

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.config,
            });

            // Signals
            signals.@"reload-config".impl.register(.{});

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            Dialog.virtual_methods.response.implement(class, &response);
        }

        pub fn as(class: *Class, comptime T: type) *T {
            return gobject.ext.as(T, class);
        }
    };
};
