const std = @import("std");
const assert = std.debug.assert;
const c = @import("c.zig").c;

const Window = @import("Window.zig");
const Tab = @import("Tab.zig");
const Notebook = @import("notebook.zig").Notebook;
const createWindow = @import("notebook.zig").createWindow;
const adwaita = @import("adwaita.zig");

const log = std.log.scoped(.gtk);

const AdwTabView = if (adwaita.versionAtLeast(0, 0, 0)) c.AdwTabView else struct {};
const AdwTabPage = if (adwaita.versionAtLeast(0, 0, 0)) c.AdwTabPage else struct {};

/// An Adwaita-flavored notebook
pub const NotebookAdw = struct {
    /// the window that we belong to
    window: *Window,

    /// the tab view
    tab_view: *AdwTabView,

    /// Set to true so that the adw close-page handler knows we're forcing
    /// and to allow a close to happen with no confirm. This is a bit of a hack
    /// because we currently use GTK alerts to confirm tab close and they
    /// don't carry with them the ADW state that we are confirming or not.
    /// Long term we should move to ADW alerts so we can know if we are
    /// confirming or not.
    forcing_close: bool = false,

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
                .window = window,
                .tab_view = tab_view,
            },
        };

        const self = &notebook.adw;

        _ = c.g_signal_connect_data(tab_view, "create-window", c.G_CALLBACK(&adwTabViewCreateWindow), self, null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(tab_view, "page-attached", c.G_CALLBACK(&adwTabViewPageAttached), self, null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(tab_view, "page-detached", c.G_CALLBACK(&adwTabViewPageAttached), self, null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(tab_view, "page-reordered", c.G_CALLBACK(&adwTabViewPageAttached), self, null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(tab_view, "notify::selected-page", c.G_CALLBACK(&adwTabViewSelectPage), self, null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(tab_view, "close-page", c.G_CALLBACK(&adwTabViewClosePage), self, null, c.G_CONNECT_DEFAULT);
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

        // closeTab always expects to close unconditionally so we mark this
        // as true so that the close_page call below doesn't request
        // confirmation.
        self.forcing_close = true;
        const n = self.nPages();
        defer {
            // self becomes invalid if we close the last page because we close
            // the whole window
            if (n > 1) self.forcing_close = false;
        }

        const page = c.adw_tab_view_get_page(self.tab_view, @ptrCast(tab.box)) orelse return;
        c.adw_tab_view_close_page(self.tab_view, page);

        // If we have no more tabs we close the window
        if (self.nPages() == 0) {
            const window = tab.window.window;

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

            // `self` will become invalid after this call because it will have
            // been freed up as part of the process of closing the window.
            c.gtk_window_destroy(window);
        }
    }

    fn setPageIcons(self: *NotebookAdw) void {
        const count: usize = @intCast(c.adw_tab_view_get_n_pages(self.tab_view));
        for (0..count) |position| {
            const page = c.adw_tab_view_get_nth_page(self.tab_view, @intCast(position));
            if (self.window.app.config.@"gtk-tabs-icon") |icon_type| {
                switch (icon_type) {
                    .numeric => {
                        if (position <= 9) {
                            var buf: [48]u8 = undefined;
                            const name = std.fmt.bufPrintZ(
                                &buf,
                                "numeric-{d}-circle-outline-symbolic",
                                .{if (position == 9) 0 else position + 1},
                            ) catch unreachable;
                            const icon = c.g_themed_icon_new(name);
                            c.adw_tab_page_set_icon(page, icon);
                        } else {
                            c.adw_tab_page_set_icon(page, null);
                        }
                    },
                }
            } else {
                c.adw_tab_page_set_icon(page, null);
            }
        }
    }
};

fn adwTabViewPageAttached(
    _: *AdwTabView,
    page: *AdwTabPage,
    _: c_int,
    ud: ?*anyopaque,
) callconv(.C) void {
    const self: *NotebookAdw = @ptrCast(@alignCast(ud.?));

    const child = c.adw_tab_page_get_child(page);
    const tab: *Tab = @ptrCast(@alignCast(c.g_object_get_data(@ptrCast(child), Tab.GHOSTTY_TAB) orelse return));
    tab.window = self.window;

    self.window.focusCurrentTab();
    self.setPageIcons();
}

fn adwTabViewClosePage(
    _: *AdwTabView,
    page: *AdwTabPage,
    ud: ?*anyopaque,
) callconv(.C) c.gboolean {
    const child = c.adw_tab_page_get_child(page);
    const tab: *Tab = @ptrCast(@alignCast(c.g_object_get_data(
        @ptrCast(child),
        Tab.GHOSTTY_TAB,
    ) orelse return 0));

    const self: *NotebookAdw = @ptrCast(@alignCast(ud.?));
    c.adw_tab_view_close_page_finish(
        self.tab_view,
        page,
        @intFromBool(self.forcing_close),
    );
    if (!self.forcing_close) tab.closeWithConfirmation();
    return 1;
}

fn adwTabViewPageDetached(
    _: *AdwTabView,
    _: *AdwTabPage,
    _: c_int,
    ud: ?*anyopaque,
) callconv(.C) void {
    const self: *NotebookAdw = @ptrCast(@alignCast(ud.?));
    self.setPageIcons();
}

fn adwTabViewPageReordered(
    _: *AdwTabView,
    _: *AdwTabPage,
    _: c_int,
    ud: ?*anyopaque,
) callconv(.C) void {
    const self: *NotebookAdw = @ptrCast(@alignCast(ud.?));
    self.setPageIcons();
}

fn adwTabViewCreateWindow(
    _: *AdwTabView,
    ud: ?*anyopaque,
) callconv(.C) ?*AdwTabView {
    const self: *NotebookAdw = @ptrCast(@alignCast(ud.?));
    const window = createWindow(self.window) catch |err| {
        log.warn("error creating new window error={}", .{err});
        return null;
    };
    assert(window.notebook == .adw);
    return window.notebook.adw.tab_view;
}

fn adwTabViewSelectPage(_: *c.GObject, _: *c.GParamSpec, ud: ?*anyopaque) void {
    const self: *NotebookAdw = @ptrCast(@alignCast(ud.?));
    const page = c.adw_tab_view_get_selected_page(self.tab_view) orelse return;
    const title = c.adw_tab_page_get_title(page);
    self.window.setTitle(std.mem.span(title));
}
