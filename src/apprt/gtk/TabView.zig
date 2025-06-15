/// An abstraction over the Adwaita tab view to manage all the terminal tabs in
/// a window.
const TabView = @This();

const std = @import("std");

const gtk = @import("gtk");
const adw = @import("adw");
const gobject = @import("gobject");
const glib = @import("glib");

const Window = @import("Window.zig");
const Tab = @import("Tab.zig");
const adw_version = @import("adw_version.zig");

const log = std.log.scoped(.gtk);

/// our window
window: *Window,

/// the tab view
tab_view: *adw.TabView,

/// Set to true so that the adw close-page handler knows we're forcing
/// and to allow a close to happen with no confirm. This is a bit of a hack
/// because we currently use GTK alerts to confirm tab close and they
/// don't carry with them the ADW state that we are confirming or not.
/// Long term we should move to ADW alerts so we can know if we are
/// confirming or not.
forcing_close: bool = false,

pub fn init(self: *TabView, window: *Window) void {
    self.* = .{
        .window = window,
        .tab_view = adw.TabView.new(),
    };
    self.tab_view.as(gtk.Widget).addCssClass("notebook");

    if (adw_version.atLeast(1, 2, 0)) {
        // Adwaita enables all of the shortcuts by default.
        // We want to manage keybindings ourselves.
        self.tab_view.removeShortcuts(.{
            .alt_digits = true,
            .alt_zero = true,
            .control_end = true,
            .control_home = true,
            .control_page_down = true,
            .control_page_up = true,
            .control_shift_end = true,
            .control_shift_home = true,
            .control_shift_page_down = true,
            .control_shift_page_up = true,
            .control_shift_tab = true,
            .control_tab = true,
        });
    }

    _ = adw.TabView.signals.page_attached.connect(
        self.tab_view,
        *TabView,
        adwPageAttached,
        self,
        .{},
    );
    _ = adw.TabView.signals.close_page.connect(
        self.tab_view,
        *TabView,
        adwClosePage,
        self,
        .{},
    );
    _ = adw.TabView.signals.create_window.connect(
        self.tab_view,
        *TabView,
        adwTabViewCreateWindow,
        self,
        .{},
    );
    _ = gobject.Object.signals.notify.connect(
        self.tab_view,
        *TabView,
        adwSelectPage,
        self,
        .{
            .detail = "selected-page",
        },
    );
}

pub fn asWidget(self: *TabView) *gtk.Widget {
    return self.tab_view.as(gtk.Widget);
}

pub fn nPages(self: *TabView) c_int {
    return self.tab_view.getNPages();
}

/// Returns the index of the currently selected page.
/// Returns null if the notebook has no pages.
fn currentPage(self: *TabView) ?c_int {
    const page = self.tab_view.getSelectedPage() orelse return null;
    return self.tab_view.getPagePosition(page);
}

/// Returns the currently selected tab or null if there are none.
pub fn currentTab(self: *TabView) ?*Tab {
    const page = self.tab_view.getSelectedPage() orelse return null;
    const child = page.getChild().as(gobject.Object);
    return @ptrCast(@alignCast(child.getData(Tab.GHOSTTY_TAB) orelse return null));
}

pub fn gotoNthTab(self: *TabView, position: c_int) bool {
    const page_to_select = self.tab_view.getNthPage(position);
    self.tab_view.setSelectedPage(page_to_select);
    return true;
}

pub fn getTabPage(self: *TabView, tab: *Tab) ?*adw.TabPage {
    return self.tab_view.getPage(tab.box.as(gtk.Widget));
}

pub fn getTabPosition(self: *TabView, tab: *Tab) ?c_int {
    return self.tab_view.getPagePosition(self.getTabPage(tab) orelse return null);
}

pub fn gotoPreviousTab(self: *TabView, tab: *Tab) bool {
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

pub fn gotoNextTab(self: *TabView, tab: *Tab) bool {
    const page_idx = self.getTabPosition(tab) orelse return false;

    const max = self.nPages() -| 1;
    const next_idx = if (page_idx < max) page_idx + 1 else 0;
    if (next_idx == page_idx) return false;

    return self.gotoNthTab(next_idx);
}

pub fn moveTab(self: *TabView, tab: *Tab, position: c_int) void {
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

pub fn reorderPage(self: *TabView, tab: *Tab, position: c_int) void {
    _ = self.tab_view.reorderPage(self.getTabPage(tab) orelse return, position);
}

pub fn setTabTitle(self: *TabView, tab: *Tab, title: [:0]const u8) void {
    const page = self.getTabPage(tab) orelse return;
    page.setTitle(title.ptr);
}

pub fn setTabTooltip(self: *TabView, tab: *Tab, tooltip: [:0]const u8) void {
    const page = self.getTabPage(tab) orelse return;
    page.setTooltip(tooltip.ptr);
}

fn newTabInsertPosition(self: *TabView, tab: *Tab) c_int {
    const numPages = self.nPages();
    return switch (tab.window.app.config.@"window-new-tab-position") {
        .current => if (self.currentPage()) |page| page + 1 else numPages,
        .end => numPages,
    };
}

/// Adds a new tab with the given title to the notebook.
pub fn addTab(self: *TabView, tab: *Tab, title: [:0]const u8) void {
    const position = self.newTabInsertPosition(tab);
    const page = self.tab_view.insert(tab.box.as(gtk.Widget), position);
    self.setTabTitle(tab, title);
    self.tab_view.setSelectedPage(page);
}

pub fn closeTab(self: *TabView, tab: *Tab) void {
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

    if (self.getTabPage(tab)) |page| self.tab_view.closePage(page);

    // If we have no more tabs we close the window
    if (self.nPages() == 0) {
        // libadw versions < 1.5.1 leak the final page view
        // which causes our surface to not properly cleanup. We
        // unref to force the cleanup. This will trigger a critical
        // warning from GTK, but I don't know any other workaround.
        if (!adw_version.atLeast(1, 5, 1)) {
            tab.box.unref();
        }

        self.window.close();
    }
}

pub fn createWindow(window: *Window) !*Window {
    const new_window = try Window.create(window.app.core_app.alloc, window.app);
    new_window.present();
    return new_window;
}

fn adwPageAttached(_: *adw.TabView, page: *adw.TabPage, _: c_int, self: *TabView) callconv(.c) void {
    const child = page.getChild().as(gobject.Object);
    const tab: *Tab = @ptrCast(@alignCast(child.getData(Tab.GHOSTTY_TAB) orelse return));
    tab.window = self.window;

    self.window.focusCurrentTab();
}

fn adwClosePage(
    _: *adw.TabView,
    page: *adw.TabPage,
    self: *TabView,
) callconv(.c) c_int {
    const child = page.getChild().as(gobject.Object);
    const tab: *Tab = @ptrCast(@alignCast(child.getData(Tab.GHOSTTY_TAB) orelse return 0));
    self.tab_view.closePageFinish(page, @intFromBool(self.forcing_close));
    if (!self.forcing_close) {
        // We cannot trigger a close directly in here as the page will stay
        // alive until this handler returns, breaking the assumption where
        // no pages means they are all destroyed.
        //
        // Schedule the close request to happen in the next event cycle.
        _ = glib.idleAddOnce(glibIdleOnceCloseTab, tab);
    }

    return 1;
}

fn adwTabViewCreateWindow(
    _: *adw.TabView,
    self: *TabView,
) callconv(.c) ?*adw.TabView {
    const window = createWindow(self.window) catch |err| {
        log.warn("error creating new window error={}", .{err});
        return null;
    };
    return window.notebook.tab_view;
}

fn adwSelectPage(_: *adw.TabView, _: *gobject.ParamSpec, self: *TabView) callconv(.c) void {
    const page = self.tab_view.getSelectedPage() orelse return;

    // If the tab was previously marked as needing attention
    // (e.g. due to a bell character), we now unmark that
    page.setNeedsAttention(@intFromBool(false));

    const title = page.getTitle();
    self.window.setTitle(std.mem.span(title));
}

fn glibIdleOnceCloseTab(data: ?*anyopaque) callconv(.c) void {
    const tab: *Tab = @ptrCast(@alignCast(data orelse return));
    tab.closeWithConfirmation();
}
