/// An abstraction over the GTK notebook and Adwaita tab view to manage
/// all the terminal tabs in a window.
const Notebook = @This();

const std = @import("std");
const assert = std.debug.assert;
const c = @import("c.zig").c;

const Window = @import("Window.zig");
const Tab = @import("Tab.zig");
const adwaita = @import("adwaita.zig");

const log = std.log.scoped(.gtk);

/// the tab view
tab_view: *c.AdwTabView,

/// Set to true so that the adw close-page handler knows we're forcing
/// and to allow a close to happen with no confirm. This is a bit of a hack
/// because we currently use GTK alerts to confirm tab close and they
/// don't carry with them the ADW state that we are confirming or not.
/// Long term we should move to ADW alerts so we can know if we are
/// confirming or not.
forcing_close: bool = false,

pub fn init(self: *Notebook) void {
    const window: *Window = @fieldParentPtr("notebook", self);

    const tab_view: *c.AdwTabView = c.adw_tab_view_new() orelse unreachable;
    c.gtk_widget_add_css_class(@ptrCast(@alignCast(tab_view)), "notebook");

    if (adwaita.versionAtLeast(1, 2, 0)) {
        // Adwaita enables all of the shortcuts by default.
        // We want to manage keybindings ourselves.
        c.adw_tab_view_remove_shortcuts(tab_view, c.ADW_TAB_VIEW_SHORTCUT_ALL_SHORTCUTS);
    }

    self.* = .{
        .tab_view = tab_view,
    };

    _ = c.g_signal_connect_data(tab_view, "page-attached", c.G_CALLBACK(&adwPageAttached), window, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(tab_view, "close-page", c.G_CALLBACK(&adwClosePage), window, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(tab_view, "create-window", c.G_CALLBACK(&adwTabViewCreateWindow), window, null, c.G_CONNECT_DEFAULT);
    _ = c.g_signal_connect_data(tab_view, "notify::selected-page", c.G_CALLBACK(&adwSelectPage), window, null, c.G_CONNECT_DEFAULT);
}

pub fn asWidget(self: *Notebook) *c.GtkWidget {
    return @ptrCast(@alignCast(self.tab_view));
}

pub fn nPages(self: *Notebook) c_int {
    return c.adw_tab_view_get_n_pages(self.tab_view);
}

/// Returns the index of the currently selected page.
/// Returns null if the notebook has no pages.
fn currentPage(self: *Notebook) ?c_int {
    const page = c.adw_tab_view_get_selected_page(self.tab_view) orelse return null;
    return c.adw_tab_view_get_page_position(self.tab_view, page);
}

/// Returns the currently selected tab or null if there are none.
pub fn currentTab(self: *Notebook) ?*Tab {
    const page = c.adw_tab_view_get_selected_page(self.tab_view) orelse return null;
    const child = c.adw_tab_page_get_child(page);
    return @ptrCast(@alignCast(
        c.g_object_get_data(@ptrCast(child), Tab.GHOSTTY_TAB) orelse return null,
    ));
}

pub fn gotoNthTab(self: *Notebook, position: c_int) bool {
    const page_to_select = c.adw_tab_view_get_nth_page(self.tab_view, position) orelse return false;
    c.adw_tab_view_set_selected_page(self.tab_view, page_to_select);
    return true;
}

pub fn getTabPosition(self: *Notebook, tab: *Tab) ?c_int {
    const page = c.adw_tab_view_get_page(self.tab_view, @ptrCast(tab.box)) orelse return null;
    return c.adw_tab_view_get_page_position(self.tab_view, page);
}

pub fn gotoPreviousTab(self: *Notebook, tab: *Tab) bool {
    const page_idx = self.getTabPosition(tab) orelse return false;

    // The next index is the previous or we wrap around.
    const next_idx = if (page_idx > 0) page_idx - 1 else next_idx: {
        const max = self.nPages();
        break :next_idx max -| 1;
    };

    // Do nothing if we have one tab
    if (next_idx == page_idx) return false;

    return self.gotoNthTab(next_idx);
}

pub fn gotoNextTab(self: *Notebook, tab: *Tab) bool {
    const page_idx = self.getTabPosition(tab) orelse return false;

    const max = self.nPages() -| 1;
    const next_idx = if (page_idx < max) page_idx + 1 else 0;
    if (next_idx == page_idx) return false;

    return self.gotoNthTab(next_idx);
}

pub fn moveTab(self: *Notebook, tab: *Tab, position: c_int) void {
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

pub fn reorderPage(self: *Notebook, tab: *Tab, position: c_int) void {
    const page = c.adw_tab_view_get_page(self.tab_view, @ptrCast(tab.box));
    _ = c.adw_tab_view_reorder_page(self.tab_view, page, position);
}

pub fn setTabLabel(self: *Notebook, tab: *Tab, title: [:0]const u8) void {
    const page = c.adw_tab_view_get_page(self.tab_view, @ptrCast(tab.box));
    c.adw_tab_page_set_title(page, title.ptr);
}

pub fn setTabTooltip(self: *Notebook, tab: *Tab, tooltip: [:0]const u8) void {
    const page = c.adw_tab_view_get_page(self.tab_view, @ptrCast(tab.box));
    c.adw_tab_page_set_tooltip(page, tooltip.ptr);
}

fn newTabInsertPosition(self: *Notebook, tab: *Tab) c_int {
    const numPages = self.nPages();
    return switch (tab.window.app.config.@"window-new-tab-position") {
        .current => if (self.currentPage()) |page| page + 1 else numPages,
        .end => numPages,
    };
}

/// Adds a new tab with the given title to the notebook.
pub fn addTab(self: *Notebook, tab: *Tab, title: [:0]const u8) void {
    const position = self.newTabInsertPosition(tab);
    const box_widget: *c.GtkWidget = @ptrCast(tab.box);
    const page = c.adw_tab_view_insert(self.tab_view, box_widget, position);
    c.adw_tab_page_set_title(page, title.ptr);
    c.adw_tab_view_set_selected_page(self.tab_view, page);
}

pub fn closeTab(self: *Notebook, tab: *Tab) void {
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

pub fn createWindow(currentWindow: *Window) !*Window {
    const alloc = currentWindow.app.core_app.alloc;
    const app = currentWindow.app;

    // Create a new window
    return Window.create(alloc, app);
}

fn adwPageAttached(_: *c.AdwTabView, page: *c.AdwTabPage, _: c_int, ud: ?*anyopaque) callconv(.C) void {
    const window: *Window = @ptrCast(@alignCast(ud.?));

    const child = c.adw_tab_page_get_child(page);
    const tab: *Tab = @ptrCast(@alignCast(c.g_object_get_data(@ptrCast(child), Tab.GHOSTTY_TAB) orelse return));
    tab.window = window;

    window.focusCurrentTab();
}

fn adwClosePage(
    _: *c.AdwTabView,
    page: *c.AdwTabPage,
    ud: ?*anyopaque,
) callconv(.C) c.gboolean {
    const child = c.adw_tab_page_get_child(page);
    const tab: *Tab = @ptrCast(@alignCast(c.g_object_get_data(
        @ptrCast(child),
        Tab.GHOSTTY_TAB,
    ) orelse return 0));

    const window: *Window = @ptrCast(@alignCast(ud.?));
    const notebook = window.notebook;
    c.adw_tab_view_close_page_finish(
        notebook.tab_view,
        page,
        @intFromBool(notebook.forcing_close),
    );
    if (!notebook.forcing_close) tab.closeWithConfirmation();
    return 1;
}

fn adwTabViewCreateWindow(
    _: *c.AdwTabView,
    ud: ?*anyopaque,
) callconv(.C) ?*c.AdwTabView {
    const currentWindow: *Window = @ptrCast(@alignCast(ud.?));
    const window = createWindow(currentWindow) catch |err| {
        log.warn("error creating new window error={}", .{err});
        return null;
    };
    return window.notebook.tab_view;
}

fn adwSelectPage(_: *c.GObject, _: *c.GParamSpec, ud: ?*anyopaque) void {
    const window: *Window = @ptrCast(@alignCast(ud.?));
    const page = c.adw_tab_view_get_selected_page(window.notebook.tab_view) orelse return;
    const title = c.adw_tab_page_get_title(page);
    window.setTitle(std.mem.span(title));
}
