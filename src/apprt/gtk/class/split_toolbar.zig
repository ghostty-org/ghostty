const std = @import("std");
const adw = @import("adw");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const Application = @import("application.zig").Application;
const Config = @import("config.zig").Config;
const Surface = @import("surface.zig").Surface;

const log = std.log.scoped(.gtk_ghostty_split_toolbar);

/// Toolbar that appears when hovering over a split pane, showing the split's
/// title and controls for closing and zooming.
pub const SplitToolbar = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttySplitToolbar",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        pub const visible = struct {
            pub const name = "visible";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = gobject.ext.privateFieldAccessor(
                        Self,
                        Private,
                        &Private.offset,
                        "visible",
                    ),
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
                    .accessor = C.privateObjFieldAccessor("surface"),
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

        pub const zoomed = struct {
            pub const name = "zoomed";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = gobject.ext.privateFieldAccessor(
                        Self,
                        Private,
                        &Private.offset,
                        "zoomed",
                    ),
                },
            );
        };
    };

    pub const signals = struct {
        pub const @"close-request" = gobject.ext.defineSignal(
            "close-request",
            Self,
            &.{},
            void,
        );

        pub const @"toggle-zoom" = gobject.ext.defineSignal(
            "toggle-zoom",
            Self,
            &.{},
            void,
        );
    };

    const Private = struct {
        visible: c_int = 0,
        surface: ?*Surface = null,
        config: ?*Config = null,
        zoomed: c_int = 0,

        /// The revealer widget that handles show/hide animation
        revealer: *gtk.Revealer,

        /// The label showing the split title
        title_label: *gtk.Label,

        /// Buttons
        zoom_button: *gtk.Button,
        close_button: *gtk.Button,

        pub var offset: c_int = 0;
    };

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
    }

    pub fn setVisible(self: *Self, visible: bool) void {
        const priv = self.private();
        priv.visible = @intFromBool(visible);
        self.as(gobject.Object).notifyByPspec(properties.visible.impl.param_spec);
    }

    pub fn setSurface(self: *Self, surface: ?*Surface) void {
        const priv = self.private();
        if (priv.surface) |old| old.unref();
        priv.surface = null;
        if (surface) |s| {
            s.ref();
            priv.surface = s;
        }
        self.as(gobject.Object).notifyByPspec(properties.surface.impl.param_spec);
    }

    pub fn setConfig(self: *Self, config: ?*Config) void {
        const priv = self.private();
        if (priv.config) |old| old.unref();
        priv.config = null;
        if (config) |c| {
            c.ref();
            priv.config = c;
        }
        self.as(gobject.Object).notifyByPspec(properties.config.impl.param_spec);
    }

    pub fn setZoomed(self: *Self, zoomed: bool) void {
        const priv = self.private();
        priv.zoomed = @intFromBool(zoomed);
        self.as(gobject.Object).notifyByPspec(properties.zoomed.impl.param_spec);
    }

    /// Compute the title for display in the toolbar.
    /// This reuses the exact same logic as tab titles.
    fn closureComputedTitle(
        _: *Self,
        config_: ?*Config,
        terminal_: ?[*:0]const u8,
        override_: ?[*:0]const u8,
        zoomed_: c_int,
        bell_ringing_: c_int,
        _: *gobject.ParamSpec,
    ) callconv(.c) ?[*:0]const u8 {
        const zoomed = zoomed_ != 0;
        const bell_ringing = bell_ringing_ != 0;

        // Our plain title is the overridden title if it exists, otherwise
        // the terminal title if it exists, otherwise a default string.
        const plain = plain: {
            const default = "Ghostty";
            const config_title: ?[*:0]const u8 = title: {
                const config = config_ orelse break :title null;
                break :title config.get().title orelse null;
            };

            const plain = override_ orelse
                terminal_ orelse
                config_title orelse
                break :plain default;
            break :plain std.mem.span(plain);
        };

        // We don't need a config in every case, but if we don't have a config
        // let's just assume something went terribly wrong and use our
        // default title. Its easier then guarding on the config existing
        // in every case for something so unlikely.
        const config = if (config_) |v| v.get() else {
            log.warn("config unavailable for computed title, likely bug", .{});
            return glib.ext.dupeZ(u8, plain);
        };

        // Use an allocator to build up our string as we write it.
        var buf: std.Io.Writer.Allocating = .init(Application.default().allocator());
        defer buf.deinit();

        // If our bell is ringing, then we prefix the bell icon to the title.
        if (bell_ringing and config.@"bell-features".title) {
            buf.writer.writeAll("🔔 ") catch {};
        }

        // If we're zoomed, prefix with the magnifying glass emoji.
        if (zoomed) {
            buf.writer.writeAll("🔍 ") catch {};
        }

        buf.writer.writeAll(plain) catch return glib.ext.dupeZ(u8, plain);
        return glib.ext.dupeZ(u8, buf.written());
    }

    /// Handle close button click
    fn closeClicked(
        _: *gtk.Button,
        self: *Self,
    ) callconv(.c) void {
        signals.@"close-request".impl.emit(self, null, .{}, null);
    }

    /// Handle zoom button click
    fn zoomClicked(
        _: *gtk.Button,
        self: *Self,
    ) callconv(.c) void {
        signals.@"toggle-zoom".impl.emit(self, null, .{}, null);
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();

        // Release references
        if (priv.surface) |s| {
            s.unref();
            priv.surface = null;
        }
        if (priv.config) |c| {
            c.unref();
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
                    .name = "split-toolbar",
                }),
            );

            // Bind template children
            class.bindTemplateChildPrivate("revealer", .{});
            class.bindTemplateChildPrivate("title_label", .{});
            class.bindTemplateChildPrivate("zoom_button", .{});
            class.bindTemplateChildPrivate("close_button", .{});

            // Callbacks
            class.bindTemplateCallback("computed_title", closureComputedTitle);
            class.bindTemplateCallback("close_clicked", closeClicked);
            class.bindTemplateCallback("zoom_clicked", zoomClicked);

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.visible.impl,
                properties.surface.impl,
                properties.config.impl,
                properties.zoomed.impl,
            });

            // Signals
            gobject.ext.registerSignals(class, &.{
                signals.@"close-request".impl,
                signals.@"toggle-zoom".impl,
            });

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
