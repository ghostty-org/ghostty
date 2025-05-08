const std = @import("std");

const gtk = @import("gtk");
const gdk = @import("gdk");
const gio = @import("gio");
const gobject = @import("gobject");

const apprt = @import("../../apprt.zig");
const App = @import("App.zig");
const Window = @import("Window.zig");
const Surface = @import("Surface.zig");
const Builder = @import("Builder.zig");

/// Abstract GTK menus to take advantage of machinery for buildtime/comptime
/// error checking.
pub fn Menu(
    /// GTK apprt type that the menu is "for". Window and Surface are supported
    /// right now.
    comptime T: type,
    /// Name of the menu. Along with the apprt type, this is used to look up the
    /// builder ui definitions of the menu.
    comptime menu_name: []const u8,
    /// Should the popup have a pointer pointing to the location that it's
    /// attached to.
    comptime arrow: bool,
) type {
    return struct {
        const Self = @This();

        /// parent apprt object
        parent: *T,

        /// our widget
        menu_widget: *gtk.PopoverMenu,

        /// initialize the menu
        pub fn init(self: *Self, parent: *T) void {
            const object_type = switch (T) {
                Window => "window",
                Surface => "surface",
                else => unreachable,
            };

            var builder = Builder.init("menu-" ++ object_type ++ "-" ++ menu_name, 1, 0);
            defer builder.deinit();

            const menu_model = builder.getObject(gio.MenuModel, "menu").?;

            const menu_widget = gtk.PopoverMenu.newFromModelFull(menu_model, .{ .nested = true });

            // If this menu has an arrow, don't modify the horizontal alignment
            // or you get visual anomalies. See PR #6087. Otherwise set the
            // horizontal alignment to `start` so that the top left corner of
            // the menu aligns with the point that the menu is popped up at.
            if (!arrow) menu_widget.as(gtk.Widget).setHalign(.start);

            menu_widget.as(gtk.Popover).setHasArrow(@intFromBool(arrow));

            _ = gtk.Popover.signals.closed.connect(
                menu_widget,
                *Self,
                gtkRefocusTerm,
                self,
                .{},
            );

            self.* = .{
                .parent = parent,
                .menu_widget = menu_widget,
            };
        }

        pub fn setParent(self: *const Self, widget: *gtk.Widget) void {
            self.menu_widget.as(gtk.Widget).setParent(widget);
        }

        pub fn asWidget(self: *const Self) *gtk.Widget {
            return self.menu_widget.as(gtk.Widget);
        }

        pub fn isVisible(self: *const Self) bool {
            return self.menu_widget.as(gtk.Widget).getVisible() != 0;
        }

        pub fn setVisible(self: *const Self, visible: bool) void {
            self.menu_widget.as(gtk.Widget).setVisible(@intFromBool(visible));
        }

        /// Refresh the menu. Right now that means enabling/disabling the "Copy"
        /// menu item based on whether there is an active selection or not, but
        /// that may change in the future.
        pub fn refresh(self: *const Self) void {
            const window: *gtk.Window, const has_selection: bool = switch (T) {
                Window => window: {
                    const has_selection = if (self.parent.actionSurface()) |core_surface|
                        core_surface.hasSelection()
                    else
                        false;

                    break :window .{ self.parent.window.as(gtk.Window), has_selection };
                },
                Surface => surface: {
                    const window = self.parent.container.window() orelse return;
                    const has_selection = self.parent.core_surface.hasSelection();
                    break :surface .{ window.window.as(gtk.Window), has_selection };
                },
                else => unreachable,
            };

            const action_map: *gio.ActionMap = gobject.ext.cast(gio.ActionMap, window) orelse return;
            const action: *gio.SimpleAction = gobject.ext.cast(
                gio.SimpleAction,
                action_map.lookupAction("copy") orelse return,
            ) orelse return;
            action.setEnabled(@intFromBool(has_selection));
        }

        /// Pop up the menu at the given coordinates
        pub fn popupAt(self: *const Self, x: c_int, y: c_int) void {
            const rect: gdk.Rectangle = .{
                .f_x = x,
                .f_y = y,
                .f_width = 1,
                .f_height = 1,
            };
            const popover = self.menu_widget.as(gtk.Popover);
            popover.setPointingTo(&rect);
            self.refresh();
            popover.popup();
        }

        /// Refocus tab that lost focus because of the popover menu
        fn gtkRefocusTerm(_: *gtk.PopoverMenu, self: *Self) callconv(.c) void {
            const window: *Window = switch (T) {
                Window => self.parent,
                Surface => self.parent.container.window() orelse return,
                else => unreachable,
            };

            window.focusCurrentTab();
        }
    };
}
