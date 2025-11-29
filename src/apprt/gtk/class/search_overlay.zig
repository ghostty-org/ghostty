const std = @import("std");
const adw = @import("adw");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;

const log = std.log.scoped(.gtk_ghostty_search_overlay);

/// The overlay that shows the current size while a surface is resizing.
/// This can be used generically to show pretty much anything with a
/// disappearing overlay, but we have no other use at this point so it
/// is named specifically for what it does.
///
/// General usage:
///
///   1. Add it to an overlay
///   2. Set the label with `setLabel`
///   3. Schedule to show it with `schedule`
///
/// Set any properties to change the behavior.
pub const SearchOverlay = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttySearchOverlay",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        pub const duration = struct {
            pub const name = "duration";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                c_uint,
                .{
                    .default = 750,
                    .minimum = 250,
                    .maximum = std.math.maxInt(c_uint),
                    .accessor = gobject.ext.privateFieldAccessor(
                        Self,
                        Private,
                        &Private.offset,
                        "duration",
                    ),
                },
            );
        };
    };

    const Private = struct {
        /// The time that the overlay appears.
        duration: c_uint,

        pub var offset: c_int = 0;
    };

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));

        const priv = self.private();
        _ = priv;
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        _ = priv;

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
        _ = priv;

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
                    .minor = 2,
                    .name = "search-overlay",
                }),
            );

            // Bindings
            // class.bindTemplateChildPrivate("label", .{});

            // Properties
            // gobject.ext.registerProperties(class, &.{
            //     properties.duration.impl,
            //     properties.label.impl,
            //     properties.@"first-delay".impl,
            //     properties.@"overlay-halign".impl,
            //     properties.@"overlay-valign".impl,
            // });

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
    };
};
