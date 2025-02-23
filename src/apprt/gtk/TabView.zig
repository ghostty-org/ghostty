/// An abstraction over the Adwaita tab view to manage all the terminal tabs in
/// a window.
const TabView = @This();

const std = @import("std");

const gtk = @import("gtk");
const adw = @import("adw");
const gobject = @import("gobject");

const Window = @import("Window.zig");
const Tab = @import("Tab.zig");
const adwaita = @import("adwaita.zig");

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

    if (adwaita.versionAtLeast(1, 2, 0)) {
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

pub fn getTabPosition(self: *TabView, tab: *Tab) ?c_int {
    const page = self.tab_view.getPage(@ptrCast(tab.box));
    return self.tab_view.getPagePosition(page);
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
    const page = self.tab_view.getPage(@ptrCast(tab.box));
    _ = self.tab_view.reorderPage(page, position);
}

pub fn setTabTitle(self: *TabView, tab: *Tab, title: [:0]const u8) void {
    const page = self.tab_view.getPage(@ptrCast(tab.box));
    page.setTitle(title.ptr);
}

pub fn setTabTooltip(self: *TabView, tab: *Tab, tooltip: [:0]const u8) void {
    const page = self.tab_view.getPage(@ptrCast(tab.box));
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
    const box_widget: *gtk.Widget = @ptrCast(tab.box);
    const page = self.tab_view.insert(box_widget, position);
    self.setTabTitle(tab, title);
    self.tab_view.setSelectedPage(page);
}

pub fn closeTab(self: *TabView, tab: *Tab) void {
    // Save a pointer to the GTK window in case we need it later. It may be
    // impossible to access later due to how resources are cleaned up.
    const window: *gtk.Window = @ptrCast(@alignCast(self.window.window));

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

    const page = self.tab_view.getPage(@ptrCast(tab.box));
    self.tab_view.closePage(page);

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
            const box: *gtk.Box = @ptrCast(@alignCast(tab.box));
            box.as(gobject.Object).unref();
        }

        window.destroy();
    }
}

pub fn createWindow(currentWindow: *Window) !*Window {
    const alloc = currentWindow.app.core_app.alloc;
    const app = currentWindow.app;

    // Create a new window
    return Window.create(alloc, app);
}

fn adwPageAttached(_: *adw.TabView, page: *adw.TabPage, _: c_int, self: *TabView) callconv(.C) void {
    const child = page.getChild().as(gobject.Object);
    const tab: *Tab = @ptrCast(@alignCast(child.getData(Tab.GHOSTTY_TAB) orelse return));
    tab.window = self.window;

    self.window.focusCurrentTab();
}

fn adwClosePage(
    _: *adw.TabView,
    page: *adw.TabPage,
    self: *TabView,
) callconv(.C) c_int {
    const child = page.getChild().as(gobject.Object);
    const tab: *Tab = @ptrCast(@alignCast(child.getData(Tab.GHOSTTY_TAB) orelse return 0));
    self.tab_view.closePageFinish(page, @intFromBool(self.forcing_close));
    if (!self.forcing_close) tab.closeWithConfirmation();
    return 1;
}

fn adwTabViewCreateWindow(
    _: *adw.TabView,
    self: *TabView,
) callconv(.C) ?*adw.TabView {
    const window = createWindow(self.window) catch |err| {
        log.warn("error creating new window error={}", .{err});
        return null;
    };
    return window.notebook.tab_view;
}

fn adwSelectPage(_: *adw.TabView, _: *gobject.ParamSpec, self: *TabView) callconv(.C) void {
    const page = self.tab_view.getSelectedPage() orelse return;
    const title = page.getTitle();
    self.window.setTitle(std.mem.span(title));
}
