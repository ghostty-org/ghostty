const std = @import("std");
const assert = std.debug.assert;
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const Application = @import("application.zig").Application;
const Surface = @import("surface.zig").Surface;

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

    const Private = struct {
        /// The surface in the view.
        surface: *Surface = undefined,

        pub var offset: c_int = 0;
    };

    pub fn new(app: *Application) *Self {
        return gobject.ext.newInstance(Self, .{ .application = app });
    }

    fn init(self: *Self, _: *Class) callconv(.C) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));

        const surface = self.private().surface;
        _ = Surface.signals.@"close-request".connect(
            surface,
            *Self,
            surfaceCloseRequest,
            self,
            .{},
        );
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn dispose(self: *Self) callconv(.C) void {
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
            class.bindTemplateChildPrivate("surface", .{});

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
    };
};
