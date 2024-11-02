const std = @import("std");
const assert = std.debug.assert;
const c = @import("c.zig").c;

const Window = @import("Window.zig");
const Tab = @import("Tab.zig");
const NotebookAdw = @import("notebook_adw.zig").NotebookAdw;
const NotebookGtk = @import("notebook_gtk.zig").NotebookGtk;
const adwaita = @import("adwaita.zig");

const log = std.log.scoped(.gtk);

/// An abstraction over the GTK notebook and Adwaita tab view to manage
/// all the terminal tabs in a window.
pub const Notebook = union(enum) {
    adw: NotebookAdw,
    gtk: NotebookGtk,

    pub fn create(alloc: std.mem.Allocator, window: *Window) std.mem.Allocator.Error!*Notebook {
        // Allocate a fixed pointer for our notebook. We try to minimize
        // allocations but windows and other GUI requirements are so minimal
        // compared to the steady-state terminal operation so we use heap
        // allocation for this.
        //
        // The allocation is owned by the GtkWindow created. It will be
        // freed when the window is closed.
        const notebook = try alloc.create(Notebook);
        errdefer alloc.destroy(notebook);
        const app = window.app;
        if (adwaita.enabled(&app.config)) {
            NotebookAdw.init(notebook, window);
            return notebook;
        }
        NotebookGtk.init(notebook, window);
        return notebook;
    }

    pub fn asWidget(self: *Notebook) *c.GtkWidget {
        return switch (self.*) {
            .adw => |*adw| adw.asWidget(),
            .gtk => |*gtk| gtk.asWidget(),
        };
    }

    pub fn nPages(self: *Notebook) c_int {
        return switch (self.*) {
            .adw => |*adw| adw.nPages(),
            .gtk => |*gtk| gtk.nPages(),
        };
    }

    /// Returns the index of the currently selected page.
    /// Returns null if the notebook has no pages.
    fn currentPage(self: *Notebook) ?c_int {
        return switch (self.*) {
            .adw => |*adw| adw.currentPage(),
            .gtk => |*gtk| gtk.currentPage(),
        };
    }

    /// Returns the currently selected tab or null if there are none.
    pub fn currentTab(self: *Notebook) ?*Tab {
        return switch (self.*) {
            .adw => |*adw| adw.currentTab(),
            .gtk => |*gtk| gtk.currentTab(),
        };
    }

    pub fn gotoNthTab(self: *Notebook, position: c_int) void {
        switch (self.*) {
            .adw => |*adw| adw.gotoNthTab(position),
            .gtk => |*gtk| gtk.gotoNthTab(position),
        }
    }

    pub fn getTabPosition(self: *Notebook, tab: *Tab) ?c_int {
        return switch (self.*) {
            .adw => |*adw| adw.getTabPosition(tab),
            .gtk => |*gtk| gtk.getTabPosition(tab),
        };
    }

    pub fn gotoPreviousTab(self: *Notebook, tab: *Tab) void {
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

    pub fn gotoNextTab(self: *Notebook, tab: *Tab) void {
        const page_idx = self.getTabPosition(tab) orelse return;

        const max = self.nPages() -| 1;
        const next_idx = if (page_idx < max) page_idx + 1 else 0;
        if (next_idx == page_idx) return;

        self.gotoNthTab(next_idx);
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
        switch (self.*) {
            .adw => |*adw| adw.reorderPage(tab, position),
            .gtk => |*gtk| gtk.reorderPage(tab, position),
        }
    }

    pub fn setTabLabel(self: *Notebook, tab: *Tab, title: [:0]const u8) void {
        switch (self.*) {
            .adw => |*adw| adw.setTabLabel(tab, title),
            .gtk => |*gtk| gtk.setTabLabel(tab, title),
        }
    }

    pub fn setTabTooltip(self: *Notebook, tab: *Tab, tooltip: [:0]const u8) void {
        switch (self.*) {
            .adw => |*adw| adw.setTabTooltip(tab, tooltip),
            .gtk => |*gtk| gtk.setTabTooltip(tab, tooltip),
        }
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
        switch (self.*) {
            .adw => |*adw| adw.addTab(tab, position, title),
            .gtk => |*gtk| gtk.addTab(tab, position, title),
        }
    }

    pub fn closeTab(self: *Notebook, tab: *Tab) void {
        switch (self.*) {
            .adw => |*adw| adw.closeTab(tab),
            .gtk => |*gtk| gtk.closeTab(tab),
        }
    }
};

pub fn createWindow(currentWindow: *Window) !*Window {
    const alloc = currentWindow.app.core_app.alloc;
    const app = currentWindow.app;

    // Create a new window
    return Window.create(alloc, app);
}
