const std = @import("std");
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const gresource = @import("../build/gresource.zig");
const adw_version = @import("../adw_version.zig");
const Common = @import("../class.zig").Common;
const Config = @import("config.zig").Config;

const log = std.log.scoped(.gtk_ghostty_dialog);

/// Dialog is a simple abstraction over the `adw.AlertDialog` and
/// `adw.MessageDialog` widgets, chosen at comptime based on the linked
/// Adwaita version.
///
/// Once we drop support for Adwaita <= 1.2, this can be fully removed
/// and we can use `adw.AlertDialog` directly.
pub const Dialog = extern struct {
    const Self = @This();
    parent_instance: Parent,

    pub const Parent = if (adw_version.supportsDialogs())
        adw.AlertDialog
    else
        adw.MessageDialog;

    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyDialog",
        .classInit = &Class.init,
        .parent_class = &Class.parent,
    });

    pub const virtual_methods = struct {
        /// Forwarded from parent so subclasses can reference this
        /// directly. This will make it easier to remove Dialog in the future.
        pub const response = Parent.virtual_methods.response;
    };

    pub fn present(self: *Self, parent: ?*gtk.Widget) void {
        switch (Parent) {
            adw.AlertDialog => self.as(adw.Dialog).present(parent),

            adw.MessageDialog => {
                // Reset the previous parent window
                self.as(gtk.Window).setTransientFor(null);

                // We need to get the window for the parent in order
                // to set the transient-for property on the MessageDialog.
                if (parent) |widget| parent: {
                    const root = gtk.Widget.getRoot(widget) orelse break :parent;
                    const window = gobject.ext.cast(
                        gtk.Window,
                        root,
                    ) orelse break :parent;
                    self.as(gtk.Window).setTransientFor(window);
                }

                self.as(gtk.Window).present();
            },

            else => comptime unreachable,
        }
    }

    pub fn close(self: *Self) void {
        switch (Parent) {
            adw.AlertDialog => self.as(adw.Dialog).forceClose(),
            adw.MessageDialog => self.as(gtk.Window).close(),
            else => comptime unreachable,
        }
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
        }

        pub fn as(class: *Class, comptime T: type) *T {
            return gobject.ext.as(T, class);
        }
    };
};
