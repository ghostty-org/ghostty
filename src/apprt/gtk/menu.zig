const std = @import("std");

const c = @import("c.zig").c;
const apprt = @import("../../apprt.zig");
const App = @import("App.zig");
const Window = @import("Window.zig");
const Surface = @import("Surface.zig");

const log = std.log.scoped(.gtk_menu);

pub fn Menu(
    comptime T: type,
    comptime variant: enum { top, titlebar, context },
    comptime style: enum { popover_menu, popover_menu_bar },
) type {
    return struct {
        const Self = @This();
        const MenuWidget = switch (style) {
            .popover_menu => c.GtkPopoverMenu,
            .popover_menu_bar => c.GtkPopoverMenuBar,
        };

        parent: *T,
        menu_widget: *MenuWidget,

        pub fn init(self: *Self) void {
            const name = switch (T) {
                Window => "window",
                Surface => "surface",
                else => unreachable,
            };
            const parent: *T = @alignCast(@fieldParentPtr(@tagName(variant) ++ "_menu", self));

            // embed the menu data using Zig @embedFile rather than as a GTK resource so that we get
            // compile-time errors if we try and embed a file that doesn't exist
            const data = @embedFile("ui/menu-" ++ name ++ "-" ++ @tagName(variant) ++ ".ui");
            const builder = c.gtk_builder_new_from_string(data.ptr, @intCast(data.len));
            defer c.g_object_unref(@ptrCast(builder));

            const menu_model: *c.GMenuModel = @ptrCast(@alignCast(c.gtk_builder_get_object(builder, "menu")));

            const menu_widget: *MenuWidget = switch (style) {
                .popover_menu => brk: {
                    const menu_widget: *MenuWidget = @ptrCast(@alignCast(c.gtk_popover_menu_new_from_model(menu_model)));
                    c.gtk_popover_menu_set_flags(menu_widget, c.GTK_POPOVER_MENU_NESTED);
                    _ = c.g_signal_connect_data(
                        @ptrCast(@alignCast(menu_widget)),
                        "closed",
                        c.G_CALLBACK(&gtkRefocusTerm),
                        self,
                        null,
                        c.G_CONNECT_DEFAULT,
                    );
                    break :brk menu_widget;
                },
                .popover_menu_bar => brk: {
                    break :brk @ptrCast(@alignCast(c.gtk_popover_menu_bar_new_from_model(menu_model)));
                },
            };

            self.* = .{
                .parent = parent,
                .menu_widget = menu_widget,
            };
        }

        pub fn setParent(self: *const Self, widget: *c.GtkWidget) void {
            c.gtk_widget_set_parent(self.asWidget(), widget);
        }

        pub fn asPopover(self: *const Self) *c.GtkPopover {
            return @ptrCast(@alignCast(self.menu_widget));
        }

        pub fn asWidget(self: *const Self) *c.GtkWidget {
            return @ptrCast(@alignCast(self.menu_widget));
        }

        pub fn isVisible(self: *const Self) bool {
            return c.gtk_widget_get_visible(self.asWidget()) != 0;
        }

        pub fn setVisible(self: *const Self, visible: bool) void {
            return c.gtk_widget_set_visible(self.asWidget(), @intFromBool(visible));
        }

        pub fn refresh(self: *const Self) void {
            const window: *Window, const has_selection: bool = switch (T) {
                Window => window: {
                    const core_surface = self.parent.actionSurface() orelse break :window .{ self.parent, false };
                    const has_selection = core_surface.hasSelection();
                    break :window .{ self.parent, has_selection };
                },
                Surface => surface: {
                    const window = self.parent.container.window() orelse return;
                    const has_selection = self.parent.core_surface.hasSelection();
                    break :surface .{ window, has_selection };
                },
                else => unreachable,
            };

            const action: ?*c.GSimpleAction = @ptrCast(c.g_action_map_lookup_action(
                @ptrCast(@alignCast(window.window)),
                "copy",
            ));
            c.g_simple_action_set_enabled(action, @intFromBool(has_selection));
        }

        pub fn popupAt(self: *const Self, x: f64, y: f64) void {
            const rect: c.GdkRectangle = .{
                .x = @intFromFloat(x),
                .y = @intFromFloat(y),
                .width = 1,
                .height = 1,
            };
            c.gtk_popover_set_pointing_to(self.asPopover(), &rect);
            self.refresh();
            c.gtk_popover_popup(self.asPopover());
        }

        /// refocus tab that lost focus because of the popover menu
        fn gtkRefocusTerm(_: *MenuWidget, _: *c.GVariant, ud: ?*anyopaque) callconv(.C) bool {
            const self: *Self = @ptrCast(@alignCast(ud orelse return false));

            log.info("closed!!!", .{});

            const window: *Window = switch (T) {
                Window => self.parent,
                Surface => self.parent.container.window() orelse return false,
                else => unreachable,
            };

            window.focusCurrentTab();

            return true;
        }
    };
}
