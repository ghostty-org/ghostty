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
        pub const active = struct {
            pub const name = "active";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = C.privateShallowFieldAccessor("active"),
                },
            );
        };
    };

    const Private = struct {
        /// The search entry widget.
        search_entry: *gtk.SearchEntry,

        /// True when a search is active, meaning we should show the overlay.
        active: bool = false,

        pub var offset: c_int = 0;
    };

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
    }

    /// Grab focus on the search entry and select all text.
    pub fn grabFocus(self: *Self) void {
        const priv = self.private();
        _ = priv.search_entry.as(gtk.Widget).grabFocus();
        priv.search_entry.as(gtk.Editable).selectRegion(0, -1);
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
            class.bindTemplateChildPrivate("search_entry", .{});

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.active.impl,
            });

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
    };
};
