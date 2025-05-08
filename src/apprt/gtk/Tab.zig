//! The state associated with a single tab in the window.
//!
//! A tab can contain one or more terminals due to splits.
const Tab = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const gobject = @import("gobject");
const gtk = @import("gtk");

const font = @import("../../font/main.zig");
const input = @import("../../input.zig");
const CoreSurface = @import("../../Surface.zig");

const Surface = @import("Surface.zig");
const Window = @import("Window.zig");
const CloseDialog = @import("CloseDialog.zig");

const log = std.log.scoped(.gtk);

pub const GHOSTTY_TAB = "ghostty_tab";

/// The window that owns this tab.
window: *Window,

/// The tab label. The tab label is the text that appears on the tab.
label_text: *gtk.Label,

/// We'll put our children into this box instead of packing them
/// directly, so that we can send the box into `c.g_signal_connect_data`
/// for the close button
box: *gtk.Box,

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

/// Initialize the tab, create a surface, and add it to the window. "self" needs
/// to be a stable pointer, since it is used for GTK events.
pub fn init(self: *Tab, window: *Window, parent_: ?*CoreSurface) !void {
    self.* = .{
        .window = window,
        .label_text = undefined,
        .box = undefined,
        .elem = undefined,
        .focus_child = null,
    };

    // Create a Box in which we'll later keep either Surface or Split. Using a
    // box makes it easier to maintain the tab contents because we never need to
    // change the root widget of the notebook page (tab).
    const box = gtk.Box.new(.vertical, 0);
    errdefer box.unref();
    const box_widget = box.as(gtk.Widget);
    box_widget.setHexpand(1);
    box_widget.setVexpand(1);
    self.box = box;

    // Create the initial surface since all tabs start as a single non-split
    var surface = try Surface.create(window.app.core_app.alloc, window.app, .{
        .parent = parent_,
    });
    errdefer surface.unref();
    surface.container = .{ .tab_ = self };
    self.elem = .{ .surface = surface };

    // Add Surface to the Tab
    self.box.append(surface.primaryWidget());

    // Set the userdata of the box to point to this tab.
    self.box.as(gobject.Object).setData(GHOSTTY_TAB, self);
    window.notebook.addTab(self, "Ghostty");

    // Attach all events
    _ = gtk.Widget.signals.destroy.connect(
        self.box,
        *Tab,
        gtkDestroy,
        self,
        .{},
    );

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
    self.box.remove(self.elem.widget());

    // Add our new one
    self.box.append(elem.widget());
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
        .surface => |s| s.closeWithConfirmation(
            s.core_surface.needsConfirmQuit(),
            .{ .tab = tab },
        ),
        .split => |s| {
            if (!needsConfirm(s.top_left) and !needsConfirm(s.bottom_right)) {
                tab.remove();
                return;
            }

            CloseDialog.show(.{ .tab = tab }) catch |err| {
                log.err("failed to open close dialog={}", .{err});
            };
        },
    }
}

fn gtkDestroy(_: *gtk.Box, self: *Tab) callconv(.c) void {
    log.debug("tab box destroy", .{});

    const alloc = self.window.app.core_app.alloc;

    // When our box is destroyed, we want to destroy our tab, too.
    self.destroy(alloc);
}
