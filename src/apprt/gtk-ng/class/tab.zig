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
const SplitTree = @import("split_tree.zig").SplitTree;
const Surface = @import("surface.zig").Surface;

const log = std.log.scoped(.gtk_ghostty_window);

pub const Tab = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyTab",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        /// The active surface is the surface that should be receiving all
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
                    .accessor = C.privateObjFieldAccessor("config"),
                },
            );
        };

        pub const @"surface-tree" = struct {
            pub const name = "surface-tree";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Surface.Tree,
                .{
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?*Surface.Tree,
                        .{
                            .getter = getSurfaceTree,
                        },
                    ),
                },
            );
        };

        pub const title = struct {
            pub const name = "title";
            pub const get = impl.get;
            pub const set = impl.set;
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("title"),
                },
            );
        };

        /// The subtitle for this tab. It is copied from the active surface.
        pub const subtitle = struct {
            pub const name = "subtitle";
            pub const get = impl.get;
            pub const set = impl.set;
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("subtitle"),
                },
            );
        };

        /// The working directory for this tab. It is copied from the active
        /// surface.
        pub const pwd = struct {
            pub const name = "pwd";
            pub const get = impl.get;
            pub const set = impl.set;
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = C.privateStringFieldAccessor("pwd"),
                },
            );
        };
    };

    pub const signals = struct {
        /// Emitted whenever the tab would like to be closed.
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
        /// The configuration that this surface is using.
        config: ?*Config = null,

        /// The title to show for this tab. This is usually set to a binding
        /// with the active surface but can be manually set to anything.
        title: ?[:0]const u8 = null,

        /// The subtitle for this tab. This is used to sync the surface's
        /// subtitle property with the window's subtitle property.
        subtitle: ?[:0]const u8 = null,

        /// The working directory for this tab. This is shown as the tooltip on
        /// the tab page's header.
        pwd: ?[:0]const u8 = null,

        /// The binding groups for the current active surface.
        surface_bindings: *gobject.BindingGroup,

        // Template bindings
        split_tree: *SplitTree,

        pub var offset: c_int = 0;
    };

    /// Set the parent of this tab page. This only affects the first surface
    /// ever created for a tab. If a surface was already created this does
    /// nothing.
    pub fn setParent(self: *Self, parent: *CoreSurface) void {
        if (self.getActiveSurface()) |surface| {
            surface.setParent(parent);
        }
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));

        // If our configuration is null then we get the configuration
        // from the application.
        const priv = self.private();
        if (priv.config == null) {
            const app = Application.default();
            priv.config = app.getConfig();
        }

        // Setup binding groups for surface properties
        priv.surface_bindings = gobject.BindingGroup.new();
        priv.surface_bindings.bind(
            "title",
            self.as(gobject.Object),
            "title",
            .{},
        );
        priv.surface_bindings.bind(
            "subtitle",
            self.as(gobject.Object),
            "subtitle",
            .{},
        );
        priv.surface_bindings.bind(
            "pwd",
            self.as(gobject.Object),
            "pwd",
            .{},
        );

        // Create our initial surface in the split tree.
        priv.split_tree.newSplit(.right, null) catch |err| switch (err) {
            error.OutOfMemory => {
                // TODO: We should make our "no surfaces" state more aesthetically
                // pleasing and show something like an "Oops, something went wrong"
                // message. For now, this is incredibly unlikely.
                @panic("oom");
            },
        };
    }

    //---------------------------------------------------------------
    // Properties

    /// Get the currently active surface. See the "active-surface" property.
    /// This does not ref the value.
    pub fn getActiveSurface(self: *Self) ?*Surface {
        return self.getSplitTree().getActiveSurface();
    }

    /// Get the surface tree of this tab.
    pub fn getSurfaceTree(self: *Self) ?*Surface.Tree {
        const priv = self.private();
        return priv.split_tree.getTree();
    }

    /// Get the split tree widget that is in this tab.
    pub fn getSplitTree(self: *Self) *SplitTree {
        const priv = self.private();
        return priv.split_tree;
    }

    /// Returns true if this tab needs confirmation before quitting based
    /// on the various Ghostty configurations.
    pub fn getNeedsConfirmQuit(self: *Self) bool {
        const surface = self.getActiveSurface() orelse return false;
        const core_surface = surface.core() orelse return false;
        return core_surface.needsConfirmQuit();
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.config) |v| {
            v.unref();
            priv.config = null;
        }
        priv.surface_bindings.setSource(null);

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
        if (priv.title) |v| {
            glib.free(@constCast(@ptrCast(v)));
            priv.title = null;
        }
        priv.surface_bindings.unref();

        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }
    //---------------------------------------------------------------
    // Signal handlers

    fn propSplitTree(
        _: *SplitTree,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.as(gobject.Object).notifyByPspec(properties.@"surface-tree".impl.param_spec);

        // If our tree is empty we close the tab.
        const tree: *const Surface.Tree = self.getSurfaceTree() orelse &.empty;
        if (tree.isEmpty()) {
            signals.@"close-request".impl.emit(
                self,
                null,
                .{},
                null,
            );
            return;
        }
    }

    fn propActiveSurface(
        _: *SplitTree,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        priv.surface_bindings.setSource(null);
        if (self.getActiveSurface()) |surface| {
            priv.surface_bindings.setSource(surface.as(gobject.Object));
        }

        self.as(gobject.Object).notifyByPspec(properties.@"active-surface".impl.param_spec);
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
            gobject.ext.ensureType(SplitTree);
            gobject.ext.ensureType(Surface);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "tab",
                }),
            );

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.@"active-surface".impl,
                properties.config.impl,
                properties.@"surface-tree".impl,
                properties.title.impl,
                properties.subtitle.impl,
                properties.pwd.impl,
            });

            // Bindings
            class.bindTemplateChildPrivate("split_tree", .{});

            // Template Callbacks
            class.bindTemplateCallback("notify_active_surface", &propActiveSurface);
            class.bindTemplateCallback("notify_tree", &propSplitTree);

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
