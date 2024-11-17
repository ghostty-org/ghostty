const std = @import("std");
const assert = std.debug.assert;
const c = @import("c.zig").c;

const Window = @import("Window.zig");
const Tab = @import("Tab.zig");
const Notebook = @import("notebook.zig").Notebook;
const createWindow = @import("notebook.zig").createWindow;
const adwaita = @import("adwaita.zig");

const log = std.log.scoped(.gtk);

const AdwTabView = if (adwaita.versionAtLeast(0, 0, 0)) c.AdwTabView else anyopaque;
const AdwTabPage = if (adwaita.versionAtLeast(0, 0, 0)) c.AdwTabPage else anyopaque;

pub const NotebookAdw = struct {
    /// the tab view
    tab_view: *AdwTabView,

    pub fn init(notebook: *Notebook) void {
        const window: *Window = @fieldParentPtr("notebook", notebook);
        const app = window.app;
        assert(adwaita.enabled(&app.config));

        const tab_view: *c.AdwTabView = c.adw_tab_view_new().?;
        c.gtk_widget_add_css_class(@ptrCast(@alignCast(tab_view)), "notebook");

        if (comptime adwaita.versionAtLeast(1, 2, 0) and adwaita.versionAtLeast(1, 2, 0)) {
            // Adwaita enables all of the shortcuts by default.
            // We want to manage keybindings ourselves.
            c.adw_tab_view_remove_shortcuts(tab_view, c.ADW_TAB_VIEW_SHORTCUT_ALL_SHORTCUTS);
        }

        notebook.* = .{
            .adw = .{
                .tab_view = tab_view,
            },
        };

        _ = c.g_signal_connect_data(tab_view, "page-attached", c.G_CALLBACK(&adwPageAttached), window, null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(tab_view, "create-window", c.G_CALLBACK(&adwTabViewCreateWindow), window, null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(tab_view, "notify::selected-page", c.G_CALLBACK(&adwSelectPage), window, null, c.G_CONNECT_DEFAULT);
    }

    pub fn asWidget(self: *NotebookAdw) *c.GtkWidget {
        return @ptrCast(@alignCast(self.tab_view));
    }

    pub fn nPages(self: *NotebookAdw) c_int {
        if (comptime adwaita.versionAtLeast(0, 0, 0))
            return c.adw_tab_view_get_n_pages(self.tab_view)
        else
            unreachable;
    }

    /// Returns the index of the currently selected page.
    /// Returns null if the notebook has no pages.
    pub fn currentPage(self: *NotebookAdw) ?c_int {
        if (comptime !adwaita.versionAtLeast(0, 0, 0)) unreachable;
        const page = c.adw_tab_view_get_selected_page(self.tab_view) orelse return null;
        return c.adw_tab_view_get_page_position(self.tab_view, page);
    }

    /// Returns the currently selected tab or null if there are none.
    pub fn currentTab(self: *NotebookAdw) ?*Tab {
        if (comptime !adwaita.versionAtLeast(0, 0, 0)) unreachable;
        const page = c.adw_tab_view_get_selected_page(self.tab_view) orelse return null;
        const child = c.adw_tab_page_get_child(page);
        return @ptrCast(@alignCast(
            c.g_object_get_data(@ptrCast(child), Tab.GHOSTTY_TAB) orelse return null,
        ));
    }

    pub fn gotoNthTab(self: *NotebookAdw, position: c_int) void {
        if (comptime !adwaita.versionAtLeast(0, 0, 0)) unreachable;
        const page_to_select = c.adw_tab_view_get_nth_page(self.tab_view, position);
        c.adw_tab_view_set_selected_page(self.tab_view, page_to_select);
    }

    pub fn getTabPosition(self: *NotebookAdw, tab: *Tab) ?c_int {
        if (comptime !adwaita.versionAtLeast(0, 0, 0)) unreachable;
        const page = c.adw_tab_view_get_page(self.tab_view, @ptrCast(tab.box)) orelse return null;
        return c.adw_tab_view_get_page_position(self.tab_view, page);
    }

    pub fn reorderPage(self: *NotebookAdw, tab: *Tab, position: c_int) void {
        if (comptime !adwaita.versionAtLeast(0, 0, 0)) unreachable;
        const page = c.adw_tab_view_get_page(self.tab_view, @ptrCast(tab.box));
        _ = c.adw_tab_view_reorder_page(self.tab_view, page, position);
    }

    pub fn setTabLabel(self: *NotebookAdw, tab: *Tab, title: [:0]const u8) void {
        if (comptime !adwaita.versionAtLeast(0, 0, 0)) unreachable;
        const page = c.adw_tab_view_get_page(self.tab_view, @ptrCast(tab.box));
        c.adw_tab_page_set_title(page, title.ptr);
    }

    pub fn setTabTooltip(self: *NotebookAdw, tab: *Tab, tooltip: [:0]const u8) void {
        if (comptime !adwaita.versionAtLeast(0, 0, 0)) unreachable;
        const page = c.adw_tab_view_get_page(self.tab_view, @ptrCast(tab.box));
        c.adw_tab_page_set_tooltip(page, tooltip.ptr);
    }

    pub fn addTab(self: *NotebookAdw, tab: *Tab, position: c_int, title: [:0]const u8) void {
        if (comptime !adwaita.versionAtLeast(0, 0, 0)) unreachable;
        const box_widget: *c.GtkWidget = @ptrCast(tab.box);
        const page = c.adw_tab_view_insert(self.tab_view, box_widget, position);
        c.adw_tab_page_set_title(page, title.ptr);
        c.adw_tab_view_set_selected_page(self.tab_view, page);
    }

    pub fn closeTab(self: *NotebookAdw, tab: *Tab) void {
        if (comptime !adwaita.versionAtLeast(0, 0, 0)) unreachable;

        const page = c.adw_tab_view_get_page(self.tab_view, @ptrCast(tab.box)) orelse return;
        c.adw_tab_view_close_page(self.tab_view, page);

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

            c.gtk_window_destroy(tab.window.window);
        }
    }
};

fn adwPageAttached(_: *AdwTabView, page: *c.AdwTabPage, _: c_int, ud: ?*anyopaque) callconv(.C) void {
    const window: *Window = @ptrCast(@alignCast(ud.?));

    const child = c.adw_tab_page_get_child(page);
    const tab: *Tab = @ptrCast(@alignCast(c.g_object_get_data(@ptrCast(child), Tab.GHOSTTY_TAB) orelse return));
    tab.window = window;

    window.focusCurrentTab();
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
    return window.notebook.adw.tab_view;
}

fn adwSelectPage(_: *c.GObject, _: *c.GParamSpec, ud: ?*anyopaque) void {
    const window: *Window = @ptrCast(@alignCast(ud.?));
    const page = c.adw_tab_view_get_selected_page(window.notebook.adw.tab_view) orelse return;
    const title = c.adw_tab_page_get_title(page);
    window.setTitle(std.mem.span(title));
}
