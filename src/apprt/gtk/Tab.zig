/// The state associated with a single tab in the window.
///
/// A tab can contain one or more terminals due to splits.
const Tab = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const font = @import("../../font/main.zig");
const input = @import("../../input.zig");
const CoreSurface = @import("../../Surface.zig");

const Surface = @import("Surface.zig");
const Window = @import("Window.zig");
const c = @import("c.zig").c;

const log = std.log.scoped(.gtk);

pub const GHOSTTY_TAB = "ghostty_tab";

/// The window that owns this tab.
window: *Window,

/// The tab label. The tab label is the text that appears on the tab.
label_text: *c.GtkLabel,

/// We'll put our children into this box instead of packing them
/// directly, so that we can send the box into `c.g_signal_connect_data`
/// for the close button
box: *c.GtkBox,

/// The element of this tab so that we can handle splits and so on.
elem: Surface.Container.Elem,

// We'll update this every time a Surface gains focus, so that we have it
// when we switch to another Tab. Then when we switch back to this tab, we
// can easily re-focus that terminal.
focus_child: ?*Surface,

pub fn create(alloc: Allocator, window: *Window, parent_: ?*CoreSurface) !*Tab {
    var tab = try alloc.create(Tab);
    errdefer alloc.destroy(tab);
    try tab.init(window, parent_);
    return tab;
}

/// Initialize the tab, create a surface, and add it to the window. "self"
/// needs to be a stable pointer, since it is used for GTK events.
pub fn init(self: *Tab, window: *Window, parent_: ?*CoreSurface) !void {
    self.* = .{
        .window = window,
        .label_text = undefined,
        .box = undefined,
        .elem = undefined,
        .focus_child = null,
    };

    // Create a Box in which we'll later keep either Surface or Split.
    // Using a box makes it easier to maintain the tab contents because
    // we never need to change the root widget of the notebook page (tab).
    const box_widget = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
    c.gtk_widget_set_hexpand(box_widget, 1);
    c.gtk_widget_set_vexpand(box_widget, 1);
    self.box = @ptrCast(box_widget);

    // Create the initial surface since all tabs start as a single non-split
    var surface = try Surface.create(window.app.core_app.alloc, window.app, .{
        .parent = parent_,
    });
    errdefer surface.unref();
    surface.container = .{ .tab_ = self };
    self.elem = .{ .surface = surface };

    // Add Surface to the Tab
    c.gtk_box_append(self.box, surface.primaryWidget());

    // Set the userdata of the box to point to this tab.
    c.g_object_set_data(@ptrCast(box_widget), GHOSTTY_TAB, self);
    window.notebook.addTab(self, "Ghostty");

    // Attach all events
    _ = c.g_signal_connect_data(box_widget, "destroy", c.G_CALLBACK(&gtkDestroy), self, null, c.G_CONNECT_DEFAULT);

    // We need to grab focus after Surface and Tab is added to the window. When
    // creating a Tab we want to always focus on the widget.
    surface.grabFocus();
}

/// Deinits tab by deiniting child elem.
pub fn deinit(self: *Tab, alloc: Allocator) void {
    self.elem.deinit(alloc);
}

/// Deinit and deallocate the tab.
pub fn destroy(self: *Tab, alloc: Allocator) void {
    self.deinit(alloc);
    alloc.destroy(self);
}

// TODO: move this
/// Replace the surface element that this tab is showing.
pub fn replaceElem(self: *Tab, elem: Surface.Container.Elem) void {
    // Remove our previous widget
    c.gtk_box_remove(self.box, self.elem.widget());

    // Add our new one
    c.gtk_box_append(self.box, elem.widget());
    self.elem = elem;
}

pub fn setTitleText(self: *Tab, title: [:0]const u8) void {
    self.window.notebook.setTabTitle(self, title);
}

pub fn setTooltipText(self: *Tab, tooltip: [:0]const u8) void {
    self.window.notebook.setTabTooltip(self, tooltip);
}

/// Remove this tab from the window.
pub fn remove(self: *Tab) void {
    self.window.closeTab(self);
}

/// Helper function to check if any surface in the split hierarchy needs close confirmation
fn needsConfirm(elem: Surface.Container.Elem) bool {
    return switch (elem) {
        .surface => |s| s.core_surface.needsConfirmQuit(),
        .split => |s| needsConfirm(s.top_left) or needsConfirm(s.bottom_right),
    };
}

/// Close the tab, asking for confirmation if any surface requests it.
pub fn closeWithConfirmation(tab: *Tab) void {
    switch (tab.elem) {
        .surface => |s| s.close(s.core_surface.needsConfirmQuit()),
        .split => |s| {
            if (needsConfirm(s.top_left) or needsConfirm(s.bottom_right)) {
                const alert = c.gtk_message_dialog_new(
                    tab.window.window,
                    c.GTK_DIALOG_MODAL,
                    c.GTK_MESSAGE_QUESTION,
                    c.GTK_BUTTONS_YES_NO,
                    "Close this tab?",
                );
                c.gtk_message_dialog_format_secondary_text(
                    @ptrCast(alert),
                    "All terminal sessions in this tab will be terminated.",
                );

                // We want the "yes" to appear destructive.
                const yes_widget = c.gtk_dialog_get_widget_for_response(
                    @ptrCast(alert),
                    c.GTK_RESPONSE_YES,
                );
                c.gtk_widget_add_css_class(yes_widget, "destructive-action");

                // We want the "no" to be the default action
                c.gtk_dialog_set_default_response(
                    @ptrCast(alert),
                    c.GTK_RESPONSE_NO,
                );

                _ = c.g_signal_connect_data(alert, "response", c.G_CALLBACK(&gtkTabCloseConfirmation), tab, null, c.G_CONNECT_DEFAULT);
                c.gtk_widget_show(alert);
                return;
            }
            tab.remove();
        },
    }
}

fn gtkTabCloseConfirmation(
    alert: *c.GtkMessageDialog,
    response: c.gint,
    ud: ?*anyopaque,
) callconv(.C) void {
    const tab: *Tab = @ptrCast(@alignCast(ud));
    c.gtk_window_destroy(@ptrCast(alert));
    if (response != c.GTK_RESPONSE_YES) return;
    tab.remove();
}

fn gtkDestroy(v: *c.GtkWidget, ud: ?*anyopaque) callconv(.C) void {
    _ = v;
    log.debug("tab box destroy", .{});

    // When our box is destroyed, we want to destroy our tab, too.
    const tab: *Tab = @ptrCast(@alignCast(ud));
    tab.destroy(tab.window.app.core_app.alloc);
}
