const std = @import("std");
const assert = std.debug.assert;
const c = @import("c.zig").c;

const Window = @import("Window.zig");
const Tab = @import("Tab.zig");
const Notebook = @import("notebook.zig").Notebook;
const createWindow = @import("notebook.zig").createWindow;

const log = std.log.scoped(.gtk);

/// An abstraction over the GTK notebook and Adwaita tab view to manage
/// all the terminal tabs in a window.
pub const NotebookGtk = struct {
    notebook: *c.GtkNotebook,

    pub fn init(notebook: *Notebook) void {
        const window: *Window = @fieldParentPtr("notebook", notebook);
        const app = window.app;

        // Create a notebook to hold our tabs.
        const notebook_widget: *c.GtkWidget = c.gtk_notebook_new();
        c.gtk_widget_add_css_class(notebook_widget, "notebook");

        const gtk_notebook: *c.GtkNotebook = @ptrCast(notebook_widget);
        const notebook_tab_pos: c_uint = switch (app.config.@"gtk-tabs-location") {
            .top, .hidden => c.GTK_POS_TOP,
            .bottom => c.GTK_POS_BOTTOM,
            .left => c.GTK_POS_LEFT,
            .right => c.GTK_POS_RIGHT,
        };
        c.gtk_notebook_set_tab_pos(gtk_notebook, notebook_tab_pos);
        c.gtk_notebook_set_scrollable(gtk_notebook, 1);
        c.gtk_notebook_set_show_tabs(gtk_notebook, 0);
        c.gtk_notebook_set_show_border(gtk_notebook, 0);

        // This enables all Ghostty terminal tabs to be exchanged across windows.
        c.gtk_notebook_set_group_name(gtk_notebook, "ghostty-terminal-tabs");

        // This is important so the notebook expands to fit available space.
        // Otherwise, it will be zero/zero in the box below.
        c.gtk_widget_set_vexpand(notebook_widget, 1);
        c.gtk_widget_set_hexpand(notebook_widget, 1);

        // Remove the background from the stack widget
        const stack = c.gtk_widget_get_last_child(notebook_widget);
        c.gtk_widget_add_css_class(stack, "transparent");

        notebook.* = .{
            .gtk = .{
                .notebook = gtk_notebook,
            },
        };

        // All of our events
        _ = c.g_signal_connect_data(gtk_notebook, "page-added", c.G_CALLBACK(&gtkPageAdded), window, null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(gtk_notebook, "page-removed", c.G_CALLBACK(&gtkPageRemoved), window, null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(gtk_notebook, "switch-page", c.G_CALLBACK(&gtkSwitchPage), window, null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(gtk_notebook, "create-window", c.G_CALLBACK(&gtkNotebookCreateWindow), window, null, c.G_CONNECT_DEFAULT);
    }

    /// return the underlying widget as a generic GtkWidget
    pub fn asWidget(self: *NotebookGtk) *c.GtkWidget {
        return @ptrCast(@alignCast(self.notebook));
    }

    /// returns the number of pages in the notebook
    pub fn nPages(self: *NotebookGtk) c_int {
        return c.gtk_notebook_get_n_pages(self.notebook);
    }

    /// Returns the index of the currently selected page.
    /// Returns null if the notebook has no pages.
    pub fn currentPage(self: *NotebookGtk) ?c_int {
        const current = c.gtk_notebook_get_current_page(self.notebook);
        return if (current == -1) null else current;
    }

    /// Returns the currently selected tab or null if there are none.
    pub fn currentTab(self: *NotebookGtk) ?*Tab {
        log.warn("currentTab", .{});
        const page = self.currentPage() orelse return null;
        const child = c.gtk_notebook_get_nth_page(self.notebook, page);
        return @ptrCast(@alignCast(
            c.g_object_get_data(@ptrCast(child), Tab.GHOSTTY_TAB) orelse return null,
        ));
    }

    /// focus the nth tab
    pub fn gotoNthTab(self: *NotebookGtk, position: c_int) void {
        c.gtk_notebook_set_current_page(self.notebook, position);
    }

    /// get the position of the current tab
    pub fn getTabPosition(self: *NotebookGtk, tab: *Tab) ?c_int {
        const page = c.gtk_notebook_get_page(self.notebook, @ptrCast(tab.box)) orelse return null;
        return getNotebookPageIndex(page);
    }

    pub fn reorderPage(self: *NotebookGtk, tab: *Tab, position: c_int) void {
        c.gtk_notebook_reorder_child(self.notebook, @ptrCast(tab.box), position);
    }

    pub fn setTabLabel(_: *NotebookGtk, tab: *Tab, title: [:0]const u8) void {
        c.gtk_label_set_text(tab.label_text, title.ptr);
    }

    pub fn setTabTooltip(_: *NotebookGtk, tab: *Tab, tooltip: [:0]const u8) void {
        c.gtk_widget_set_tooltip_text(@ptrCast(@alignCast(tab.label_text)), tooltip.ptr);
    }

    /// Adds a new tab with the given title to the notebook.
    pub fn addTab(self: *NotebookGtk, tab: *Tab, position: c_int, title: [:0]const u8) void {
        const box_widget: *c.GtkWidget = @ptrCast(tab.box);

        // Build the tab label
        const label_box_widget = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 0);
        const label_box = @as(*c.GtkBox, @ptrCast(label_box_widget));
        const label_text_widget = c.gtk_label_new(title.ptr);
        const label_text: *c.GtkLabel = @ptrCast(label_text_widget);
        c.gtk_box_append(label_box, label_text_widget);
        tab.label_text = label_text;

        const window = tab.window;
        if (window.app.config.@"gtk-wide-tabs") {
            c.gtk_widget_set_hexpand(label_box_widget, 1);
            c.gtk_widget_set_halign(label_box_widget, c.GTK_ALIGN_FILL);
            c.gtk_widget_set_hexpand(label_text_widget, 1);
            c.gtk_widget_set_halign(label_text_widget, c.GTK_ALIGN_FILL);

            // This ensures that tabs are always equal width. If they're too
            // long, they'll be truncated with an ellipsis.
            c.gtk_label_set_max_width_chars(label_text, 1);
            c.gtk_label_set_ellipsize(label_text, c.PANGO_ELLIPSIZE_END);

            // We need to set a minimum width so that at a certain point
            // the notebook will have an arrow button rather than shrinking tabs
            // to an unreadably small size.
            c.gtk_widget_set_size_request(label_text_widget, 100, 1);
        }

        // Build the close button for the tab
        const label_close_widget = c.gtk_button_new_from_icon_name("window-close-symbolic");
        const label_close: *c.GtkButton = @ptrCast(label_close_widget);
        c.gtk_button_set_has_frame(label_close, 0);
        c.gtk_box_append(label_box, label_close_widget);

        const page_idx = c.gtk_notebook_insert_page(
            self.notebook,
            box_widget,
            label_box_widget,
            position,
        );

        // Clicks
        const gesture_tab_click = c.gtk_gesture_click_new();
        c.gtk_gesture_single_set_button(@ptrCast(gesture_tab_click), 0);
        c.gtk_widget_add_controller(label_box_widget, @ptrCast(gesture_tab_click));

        _ = c.g_signal_connect_data(label_close, "clicked", c.G_CALLBACK(&Tab.gtkTabCloseClick), tab, null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(gesture_tab_click, "pressed", c.G_CALLBACK(&Tab.gtkTabClick), tab, null, c.G_CONNECT_DEFAULT);

        // Tab settings
        c.gtk_notebook_set_tab_reorderable(self.notebook, box_widget, 1);
        c.gtk_notebook_set_tab_detachable(self.notebook, box_widget, 1);

        if (self.nPages() > 1) {
            c.gtk_notebook_set_show_tabs(self.notebook, 1);
        }

        // Switch to the new tab
        c.gtk_notebook_set_current_page(self.notebook, page_idx);
    }

    pub fn closeTab(self: *NotebookGtk, tab: *Tab) void {
        const page = c.gtk_notebook_get_page(self.notebook, @ptrCast(tab.box)) orelse return;

        // Find page and tab which we're closing
        const page_idx = getNotebookPageIndex(page);

        // Remove the page. This will destroy the GTK widgets in the page which
        // will trigger Tab cleanup. The `tab` variable is therefore unusable past that point.
        c.gtk_notebook_remove_page(self.notebook, page_idx);

        const remaining = self.nPages();
        switch (remaining) {
            // If we have no more tabs we close the window
            0 => c.gtk_window_destroy(tab.window.window),

            // If we have one more tab we hide the tab bar
            1 => c.gtk_notebook_set_show_tabs(self.notebook, 0),

            else => {},
        }

        // If we have remaining tabs, we need to make sure we grab focus.
        if (remaining > 0)
            (self.currentTab() orelse return).window.focusCurrentTab();
    }
};

fn getNotebookPageIndex(page: *c.GtkNotebookPage) c_int {
    var value: c.GValue = std.mem.zeroes(c.GValue);
    defer c.g_value_unset(&value);
    _ = c.g_value_init(&value, c.G_TYPE_INT);
    c.g_object_get_property(
        @ptrCast(@alignCast(page)),
        "position",
        &value,
    );

    return c.g_value_get_int(&value);
}

fn gtkPageAdded(
    notebook: *c.GtkNotebook,
    _: *c.GtkWidget,
    page_idx: c.guint,
    ud: ?*anyopaque,
) callconv(.C) void {
    const self: *Window = @ptrCast(@alignCast(ud.?));

    // The added page can come from another window with drag and drop, thus we migrate the tab
    // window to be self.
    const page = c.gtk_notebook_get_nth_page(notebook, @intCast(page_idx));
    const tab: *Tab = @ptrCast(@alignCast(
        c.g_object_get_data(@ptrCast(page), Tab.GHOSTTY_TAB) orelse return,
    ));
    tab.window = self;

    // Whenever a new page is added, we always grab focus of the
    // currently selected page. This was added specifically so that when
    // we drag a tab out to create a new window ("create-window" event)
    // we grab focus in the new window. Without this, the terminal didn't
    // have focus.
    self.focusCurrentTab();
}

fn gtkPageRemoved(
    _: *c.GtkNotebook,
    _: *c.GtkWidget,
    _: c.guint,
    ud: ?*anyopaque,
) callconv(.C) void {
    log.warn("gtkPageRemoved", .{});
    const window: *Window = @ptrCast(@alignCast(ud.?));

    // Hide the tab bar if we only have one tab after removal
    const remaining = c.gtk_notebook_get_n_pages(window.notebook.gtk.notebook);

    if (remaining == 1) {
        c.gtk_notebook_set_show_tabs(window.notebook.gtk.notebook, 0);
    }
}

fn gtkSwitchPage(_: *c.GtkNotebook, page: *c.GtkWidget, _: usize, ud: ?*anyopaque) callconv(.C) void {
    const window: *Window = @ptrCast(@alignCast(ud.?));
    const self = &window.notebook.gtk;
    const gtk_label_box = @as(*c.GtkWidget, @ptrCast(c.gtk_notebook_get_tab_label(self.notebook, page)));
    const gtk_label = @as(*c.GtkLabel, @ptrCast(c.gtk_widget_get_first_child(gtk_label_box)));
    const label_text = c.gtk_label_get_text(gtk_label);
    window.setTitle(std.mem.span(label_text));
}

fn gtkNotebookCreateWindow(
    _: *c.GtkNotebook,
    page: *c.GtkWidget,
    ud: ?*anyopaque,
) callconv(.C) ?*c.GtkNotebook {
    // The tab for the page is stored in the widget data.
    const tab: *Tab = @ptrCast(@alignCast(
        c.g_object_get_data(@ptrCast(page), Tab.GHOSTTY_TAB) orelse return null,
    ));

    const currentWindow: *Window = @ptrCast(@alignCast(ud.?));
    const newWindow = createWindow(currentWindow) catch |err| {
        log.warn("error creating new window error={}", .{err});
        return null;
    };

    // And add it to the new window.
    tab.window = newWindow;

    return newWindow.notebook.gtk.notebook;
}
