const std = @import("std");
const assert = std.debug.assert;
const c = @import("c.zig").c;

const Window = @import("Window.zig");
const Tab = @import("Tab.zig");
const adwaita = @import("adwaita.zig");

const log = std.log.scoped(.gtk);

const AdwTabView = if (adwaita.versionAtLeast(0, 0, 0)) c.AdwTabView else anyopaque;

/// An abstraction over the GTK notebook and Adwaita tab view to manage
/// all the terminal tabs in a window.
pub const Notebook = union(enum) {
    adw_tab_view: *AdwTabView,
    gtk_notebook: *c.GtkNotebook,

    pub fn create(window: *Window) Notebook {
        const app = window.app;
        if (adwaita.enabled(&app.config)) return initAdw(window);
        return initGtk(window);
    }

    fn initGtk(window: *Window) Notebook {
        const app = window.app;

        // Create a notebook to hold our tabs.
        const notebook_widget: *c.GtkWidget = c.gtk_notebook_new();
        const notebook: *c.GtkNotebook = @ptrCast(notebook_widget);
        const notebook_tab_pos: c_uint = switch (app.config.@"gtk-tabs-location") {
            .top, .hidden => c.GTK_POS_TOP,
            .bottom => c.GTK_POS_BOTTOM,
            .left => c.GTK_POS_LEFT,
            .right => c.GTK_POS_RIGHT,
        };
        c.gtk_notebook_set_tab_pos(notebook, notebook_tab_pos);
        c.gtk_notebook_set_scrollable(notebook, 1);
        c.gtk_notebook_set_show_tabs(notebook, 0);
        c.gtk_notebook_set_show_border(notebook, 0);

        // This enables all Ghostty terminal tabs to be exchanged across windows.
        c.gtk_notebook_set_group_name(notebook, "ghostty-terminal-tabs");

        // This is important so the notebook expands to fit available space.
        // Otherwise, it will be zero/zero in the box below.
        c.gtk_widget_set_vexpand(notebook_widget, 1);
        c.gtk_widget_set_hexpand(notebook_widget, 1);

        // Remove the background from the stack widget
        const stack = c.gtk_widget_get_last_child(notebook_widget);
        c.gtk_widget_add_css_class(stack, "transparent");

        // All of our events
        _ = c.g_signal_connect_data(notebook, "page-added", c.G_CALLBACK(&gtkPageAdded), window, null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(notebook, "page-removed", c.G_CALLBACK(&gtkPageRemoved), window, null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(notebook, "switch-page", c.G_CALLBACK(&gtkSwitchPage), window, null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(notebook, "create-window", c.G_CALLBACK(&gtkNotebookCreateWindow), window, null, c.G_CONNECT_DEFAULT);

        return .{ .gtk_notebook = notebook };
    }

    fn initAdw(window: *Window) Notebook {
        const app = window.app;
        assert(adwaita.enabled(&app.config));

        const tab_view: *c.AdwTabView = c.adw_tab_view_new().?;

        if (comptime adwaita.versionAtLeast(1, 2, 0) and adwaita.versionAtLeast(1, 2, 0)) {
            // Adwaita enables all of the shortcuts by default.
            // We want to manage keybindings ourselves.
            c.adw_tab_view_remove_shortcuts(tab_view, c.ADW_TAB_VIEW_SHORTCUT_ALL_SHORTCUTS);
        }

        _ = c.g_signal_connect_data(tab_view, "page-attached", c.G_CALLBACK(&adwPageAttached), window, null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(tab_view, "create-window", c.G_CALLBACK(&adwTabViewCreateWindow), window, null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(tab_view, "notify::selected-page", c.G_CALLBACK(&adwSelectPage), window, null, c.G_CONNECT_DEFAULT);

        return .{ .adw_tab_view = tab_view };
    }

    pub fn asWidget(self: Notebook) *c.GtkWidget {
        return switch (self) {
            .adw_tab_view => |tab_view| @ptrCast(@alignCast(tab_view)),
            .gtk_notebook => |notebook| @ptrCast(@alignCast(notebook)),
        };
    }

    pub fn nPages(self: Notebook) c_int {
        return switch (self) {
            .gtk_notebook => |notebook| c.gtk_notebook_get_n_pages(notebook),
            .adw_tab_view => |tab_view| if (comptime adwaita.versionAtLeast(0, 0, 0))
                c.adw_tab_view_get_n_pages(tab_view)
            else
                unreachable,
        };
    }

    /// Returns the index of the currently selected page.
    /// Returns null if the notebook has no pages.
    fn currentPage(self: Notebook) ?c_int {
        switch (self) {
            .adw_tab_view => |tab_view| {
                if (comptime !adwaita.versionAtLeast(0, 0, 0)) unreachable;
                const page = c.adw_tab_view_get_selected_page(tab_view) orelse return null;
                return c.adw_tab_view_get_page_position(tab_view, page);
            },

            .gtk_notebook => |notebook| {
                const current = c.gtk_notebook_get_current_page(notebook);
                return if (current == -1) null else current;
            },
        }
    }

    /// Returns the currently selected tab or null if there are none.
    pub fn currentTab(self: Notebook) ?*Tab {
        const child = switch (self) {
            .adw_tab_view => |tab_view| child: {
                if (comptime !adwaita.versionAtLeast(0, 0, 0)) unreachable;
                const page = c.adw_tab_view_get_selected_page(tab_view) orelse return null;
                const child = c.adw_tab_page_get_child(page);
                break :child child;
            },

            .gtk_notebook => |notebook| child: {
                const page = self.currentPage() orelse return null;
                break :child c.gtk_notebook_get_nth_page(notebook, page);
            },
        };
        return @ptrCast(@alignCast(
            c.g_object_get_data(@ptrCast(child), Tab.GHOSTTY_TAB) orelse return null,
        ));
    }

    pub fn gotoNthTab(self: Notebook, position: c_int) void {
        switch (self) {
            .adw_tab_view => |tab_view| {
                if (comptime !adwaita.versionAtLeast(0, 0, 0)) unreachable;
                const page_to_select = c.adw_tab_view_get_nth_page(tab_view, position);
                c.adw_tab_view_set_selected_page(tab_view, page_to_select);
            },
            .gtk_notebook => |notebook| c.gtk_notebook_set_current_page(notebook, position),
        }
    }

    pub fn getTabPosition(self: Notebook, tab: *Tab) ?c_int {
        return switch (self) {
            .adw_tab_view => |tab_view| page_idx: {
                if (comptime !adwaita.versionAtLeast(0, 0, 0)) unreachable;
                const page = c.adw_tab_view_get_page(tab_view, @ptrCast(tab.box)) orelse return null;
                break :page_idx c.adw_tab_view_get_page_position(tab_view, page);
            },
            .gtk_notebook => |notebook| page_idx: {
                const page = c.gtk_notebook_get_page(notebook, @ptrCast(tab.box)) orelse return null;
                break :page_idx getNotebookPageIndex(page);
            },
        };
    }

    pub fn gotoPreviousTab(self: Notebook, tab: *Tab) void {
        const page_idx = self.getTabPosition(tab) orelse return;

        // The next index is the previous or we wrap around.
        const next_idx = if (page_idx > 0) page_idx - 1 else next_idx: {
            const max = self.nPages();
            break :next_idx max -| 1;
        };

        // Do nothing if we have one tab
        if (next_idx == page_idx) return;

        self.gotoNthTab(next_idx);
    }

    pub fn gotoNextTab(self: Notebook, tab: *Tab) void {
        const page_idx = self.getTabPosition(tab) orelse return;

        const max = self.nPages() -| 1;
        const next_idx = if (page_idx < max) page_idx + 1 else 0;
        if (next_idx == page_idx) return;

        self.gotoNthTab(next_idx);
    }

    pub fn moveTab(self: Notebook, tab: *Tab, position: c_int) void {
        const page_idx = self.getTabPosition(tab) orelse return;

        const max = self.nPages() -| 1;
        var new_position: c_int = page_idx + position;

        if (new_position < 0) {
            new_position = max + new_position + 1;
        } else if (new_position > max) {
            new_position = new_position - max - 1;
        }

        if (new_position == page_idx) return;
        self.reorderPage(tab, new_position);
    }

    pub fn reorderPage(self: Notebook, tab: *Tab, position: c_int) void {
        switch (self) {
            .gtk_notebook => |notebook| {
                c.gtk_notebook_reorder_child(notebook, @ptrCast(tab.box), position);
            },
            .adw_tab_view => |tab_view| {
                if (comptime !adwaita.versionAtLeast(0, 0, 0)) unreachable;
                const page = c.adw_tab_view_get_page(tab_view, @ptrCast(tab.box));
                _ = c.adw_tab_view_reorder_page(tab_view, page, position);
            },
        }
    }

    pub fn setTabLabel(self: Notebook, tab: *Tab, title: [:0]const u8) void {
        switch (self) {
            .adw_tab_view => |tab_view| {
                if (comptime !adwaita.versionAtLeast(0, 0, 0)) unreachable;
                const page = c.adw_tab_view_get_page(tab_view, @ptrCast(tab.box));
                c.adw_tab_page_set_title(page, title.ptr);
            },
            .gtk_notebook => c.gtk_label_set_text(tab.label_text, title.ptr),
        }
    }

    pub fn setTabTooltip(self: Notebook, tab: *Tab, tooltip: [:0]const u8) void {
        switch (self) {
            .adw_tab_view => |tab_view| {
                if (comptime !adwaita.versionAtLeast(0, 0, 0)) unreachable;
                const page = c.adw_tab_view_get_page(tab_view, @ptrCast(tab.box));
                c.adw_tab_page_set_tooltip(page, tooltip.ptr);
            },
            .gtk_notebook => c.gtk_widget_set_tooltip_text(@ptrCast(@alignCast(tab.label_text)), tooltip.ptr),
        }
    }

    fn newTabInsertPosition(self: Notebook, tab: *Tab) c_int {
        const numPages = self.nPages();
        return switch (tab.window.app.config.@"window-new-tab-position") {
            .current => if (self.currentPage()) |page| page + 1 else numPages,
            .end => numPages,
        };
    }

    /// Adds a new tab with the given title to the notebook.
    pub fn addTab(self: Notebook, tab: *Tab, title: [:0]const u8) !void {
        const box_widget: *c.GtkWidget = @ptrCast(tab.box);
        switch (self) {
            .adw_tab_view => |tab_view| {
                if (comptime !adwaita.versionAtLeast(0, 0, 0)) unreachable;

                const page = c.adw_tab_view_insert(tab_view, box_widget, self.newTabInsertPosition(tab));
                c.adw_tab_page_set_title(page, title.ptr);

                // Switch to the new tab
                c.adw_tab_view_set_selected_page(tab_view, page);
            },
            .gtk_notebook => |notebook| {
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
                    notebook,
                    box_widget,
                    label_box_widget,
                    self.newTabInsertPosition(tab),
                );

                // Clicks
                const gesture_tab_click = c.gtk_gesture_click_new();
                c.gtk_gesture_single_set_button(@ptrCast(gesture_tab_click), 0);
                c.gtk_widget_add_controller(label_box_widget, @ptrCast(gesture_tab_click));

                _ = c.g_signal_connect_data(label_close, "clicked", c.G_CALLBACK(&Tab.gtkTabCloseClick), tab, null, c.G_CONNECT_DEFAULT);
                _ = c.g_signal_connect_data(gesture_tab_click, "pressed", c.G_CALLBACK(&Tab.gtkTabClick), tab, null, c.G_CONNECT_DEFAULT);

                // Tab settings
                c.gtk_notebook_set_tab_reorderable(notebook, box_widget, 1);
                c.gtk_notebook_set_tab_detachable(notebook, box_widget, 1);

                if (self.nPages() > 1) {
                    c.gtk_notebook_set_show_tabs(notebook, 1);
                }

                // Switch to the new tab
                c.gtk_notebook_set_current_page(notebook, page_idx);
            },
        }
    }

    pub fn closeTab(self: Notebook, tab: *Tab) void {
        const window = tab.window;
        switch (self) {
            .adw_tab_view => |tab_view| {
                if (comptime !adwaita.versionAtLeast(0, 0, 0)) unreachable;

                const page = c.adw_tab_view_get_page(tab_view, @ptrCast(tab.box)) orelse return;
                c.adw_tab_view_close_page(tab_view, page);

                // If we have no more tabs we close the window
                if (self.nPages() == 0) {
                    // libadw versions <= 1.3.x leak the final page view
                    // which causes our surface to not properly cleanup. We
                    // unref to force the cleanup. This will trigger a critical
                    // warning from GTK, but I don't know any other workaround.
                    // Note: I'm not actually sure if 1.4.0 contains the fix,
                    // I just know that 1.3.x is broken and 1.5.1 is fixed.
                    // If we know that 1.4.0 is fixed, we can change this.
                    if (!adwaita.versionAtLeast(1, 4, 0)) {
                        c.g_object_unref(tab.box);
                    }

                    c.gtk_window_destroy(window.window);
                }
            },
            .gtk_notebook => |notebook| {
                const page = c.gtk_notebook_get_page(notebook, @ptrCast(tab.box)) orelse return;

                // Find page and tab which we're closing
                const page_idx = getNotebookPageIndex(page);

                // Remove the page. This will destroy the GTK widgets in the page which
                // will trigger Tab cleanup. The `tab` variable is therefore unusable past that point.
                c.gtk_notebook_remove_page(notebook, page_idx);

                const remaining = self.nPages();
                switch (remaining) {
                    // If we have no more tabs we close the window
                    0 => c.gtk_window_destroy(tab.window.window),

                    // If we have one more tab we hide the tab bar
                    1 => c.gtk_notebook_set_show_tabs(notebook, 0),

                    else => {},
                }

                // If we have remaining tabs, we need to make sure we grab focus.
                if (remaining > 0) window.focusCurrentTab();
            },
        }
    }

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
};

fn gtkPageRemoved(
    _: *c.GtkNotebook,
    _: *c.GtkWidget,
    _: c.guint,
    ud: ?*anyopaque,
) callconv(.C) void {
    const self: *Window = @ptrCast(@alignCast(ud.?));

    const notebook: *c.GtkNotebook = self.notebook.gtk_notebook;

    // Hide the tab bar if we only have one tab after removal
    const remaining = c.gtk_notebook_get_n_pages(notebook);
    if (remaining == 1) {
        c.gtk_notebook_set_show_tabs(notebook, 0);
    }
}

fn adwPageAttached(tab_view: *AdwTabView, page: *c.AdwTabPage, position: c_int, ud: ?*anyopaque) callconv(.C) void {
    _ = position;
    _ = tab_view;
    const self: *Window = @ptrCast(@alignCast(ud.?));

    const child = c.adw_tab_page_get_child(page);
    const tab: *Tab = @ptrCast(@alignCast(c.g_object_get_data(@ptrCast(child), Tab.GHOSTTY_TAB) orelse return));
    tab.window = self;

    self.focusCurrentTab();
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

fn adwSelectPage(_: *c.GObject, _: *c.GParamSpec, ud: ?*anyopaque) void {
    const window: *Window = @ptrCast(@alignCast(ud.?));
    const page = c.adw_tab_view_get_selected_page(window.notebook.adw_tab_view) orelse return;
    const title = c.adw_tab_page_get_title(page);
    c.gtk_window_set_title(window.window, title);
}

fn gtkSwitchPage(_: *c.GtkNotebook, page: *c.GtkWidget, _: usize, ud: ?*anyopaque) callconv(.C) void {
    const window: *Window = @ptrCast(@alignCast(ud.?));
    const gtk_label_box = @as(*c.GtkWidget, @ptrCast(c.gtk_notebook_get_tab_label(window.notebook.gtk_notebook, page)));
    const gtk_label = @as(*c.GtkLabel, @ptrCast(c.gtk_widget_get_first_child(gtk_label_box)));
    const label_text = c.gtk_label_get_text(gtk_label);
    c.gtk_window_set_title(window.window, label_text);
}

fn adwTabViewCreateWindow(
    _: *AdwTabView,
    ud: ?*anyopaque,
) callconv(.C) ?*AdwTabView {
    const currentWindow: *Window = @ptrCast(@alignCast(ud.?));
    const window = createWindow(currentWindow) catch |err| {
        log.warn("error creating new window error={}", .{err});
        return null;
    };
    return window.notebook.adw_tab_view;
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
    const window = createWindow(currentWindow) catch |err| {
        log.warn("error creating new window error={}", .{err});
        return null;
    };

    // And add it to the new window.
    tab.window = window;

    return window.notebook.gtk_notebook;
}

fn createWindow(currentWindow: *Window) !*Window {
    const alloc = currentWindow.app.core_app.alloc;
    const app = currentWindow.app;

    // Create a new window
    return Window.create(alloc, app);
}
