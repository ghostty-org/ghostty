const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const apprt = @import("../../../apprt.zig");
const ext = @import("../ext.zig");
const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const Tab = @import("tab.zig").Tab;

const log = std.log.scoped(.gtk_vertical_tab_sidebar);

/// A vertical tab sidebar widget that displays tabs in a vertical list.
/// This syncs with an Adw.TabView to provide an alternative to Adw.TabBar.
pub const VerticalTabSidebar = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyVerticalTabSidebar",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        pub const @"tab-view" = struct {
            pub const name = "tab-view";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*adw.TabView,
                .{
                    .default = null,
                    .accessor = C.privateObjFieldAccessor("tab_view"),
                    .flags = .{},
                },
            );
        };

        pub const @"tab-overview-open" = struct {
            pub const name = "tab-overview-open";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = C.privateShallowFieldAccessor("tab_overview_open"),
                    .flags = .{},
                },
            );
        };
    };

    pub const signals = struct {
        pub const @"new-tab-request" = struct {
            pub const name = "new-tab-request";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{},
                void,
            );
        };
    };

    const Private = struct {
        tab_view: ?*adw.TabView = null,
        tab_overview_open: bool = false,

        // Template bindings
        tab_list: *gtk.ListBox,
        new_tab_button: *gtk.Button,

        // Signal handlers for tab view
        page_attached_handler: c_ulong = 0,
        page_detached_handler: c_ulong = 0,
        selected_page_handler: c_ulong = 0,
        page_reordered_handler: c_ulong = 0,

        // Flag to prevent recursive selection
        updating_selection: bool = false,

        pub var offset: c_int = 0;
    };

    /// Set the tab view that this sidebar should sync with.
    pub fn setTabView(self: *Self, tab_view: ?*adw.TabView) void {
        const priv = self.private();

        // Disconnect from old tab view
        if (priv.tab_view) |old_view| {
            if (priv.page_attached_handler != 0) {
                old_view.as(gobject.Object).signalHandlerDisconnect(priv.page_attached_handler);
                priv.page_attached_handler = 0;
            }
            if (priv.page_detached_handler != 0) {
                old_view.as(gobject.Object).signalHandlerDisconnect(priv.page_detached_handler);
                priv.page_detached_handler = 0;
            }
            if (priv.selected_page_handler != 0) {
                old_view.as(gobject.Object).signalHandlerDisconnect(priv.selected_page_handler);
                priv.selected_page_handler = 0;
            }
            if (priv.page_reordered_handler != 0) {
                old_view.as(gobject.Object).signalHandlerDisconnect(priv.page_reordered_handler);
                priv.page_reordered_handler = 0;
            }
            old_view.unref();
        }

        priv.tab_view = tab_view;

        // Connect to new tab view
        if (tab_view) |view| {
            _ = view.ref();

            priv.page_attached_handler = view.connectPageAttached(*Self, self, &onPageAttached, .{});
            priv.page_detached_handler = view.connectPageDetached(*Self, self, &onPageDetached, .{});
            priv.selected_page_handler = view.as(gobject.Object).connectNotify(
                "selected-page",
                *Self,
                self,
                &onSelectedPageChanged,
                .{},
            );

            // Populate with existing pages
            self.rebuildTabList();
        }
    }

    /// Rebuild the entire tab list from the tab view.
    fn rebuildTabList(self: *Self) void {
        const priv = self.private();
        const tab_view = priv.tab_view orelse return;

        // Clear existing rows
        while (priv.tab_list.getRowAtIndex(0)) |row| {
            priv.tab_list.remove(row.as(gtk.Widget));
        }

        // Add rows for each page
        const n_pages = tab_view.getNPages();
        var i: c_int = 0;
        while (i < n_pages) : (i += 1) {
            if (tab_view.getNthPage(i)) |page| {
                self.addRowForPage(page, i);
            }
        }

        // Update selection
        self.syncSelection();
    }

    /// Add a row for a tab page at the given position.
    fn addRowForPage(self: *Self, page: *adw.TabPage, position: c_int) void {
        const priv = self.private();

        const row = gtk.ListBoxRow.new();
        row.as(gtk.Widget).setName("tab-row");

        // Create the row content
        const box = gtk.Box.new(.horizontal, 6);
        box.as(gtk.Widget).setMarginStart(8);
        box.as(gtk.Widget).setMarginEnd(8);
        box.as(gtk.Widget).setMarginTop(6);
        box.as(gtk.Widget).setMarginBottom(6);

        // Tab title label
        const label = gtk.Label.new(page.getTitle());
        label.setXalign(0);
        label.setEllipsize(.end);
        label.setHexpand(true);
        label.as(gtk.Widget).addCssClass("tab-title");

        // Bind the label to the page title
        _ = page.as(gobject.Object).bindProperty(
            "title",
            label.as(gobject.Object),
            "label",
            .{ .sync_create = true },
        );

        // Close button
        const close_button = gtk.Button.newFromIconName("window-close-symbolic");
        close_button.as(gtk.Widget).addCssClass("flat");
        close_button.as(gtk.Widget).addCssClass("circular");
        close_button.as(gtk.Widget).setValign(.center);
        close_button.as(gtk.Widget).setTooltipText("Close Tab");

        // Store the page pointer in the close button for the handler
        close_button.as(gtk.Widget).setData(
            adw.TabPage,
            "tab-page",
            page,
        );
        _ = close_button.connectClicked(*Self, self, &onCloseButtonClicked, .{});

        box.append(label.as(gtk.Widget));
        box.append(close_button.as(gtk.Widget));
        row.setChild(box.as(gtk.Widget));

        // Store the page pointer in the row for later lookup
        row.as(gtk.Widget).setData(adw.TabPage, "tab-page", page);

        // Insert at the correct position
        if (position < 0) {
            priv.tab_list.append(row.as(gtk.Widget));
        } else {
            priv.tab_list.insert(row.as(gtk.Widget), position);
        }

        // Show indicator for pages needing attention
        if (page.getNeedsAttention() != 0) {
            row.as(gtk.Widget).addCssClass("needs-attention");
        }
    }

    /// Sync the selection state from the tab view to the list box.
    fn syncSelection(self: *Self) void {
        const priv = self.private();
        if (priv.updating_selection) return;

        const tab_view = priv.tab_view orelse return;
        const selected_page = tab_view.getSelectedPage() orelse return;

        priv.updating_selection = true;
        defer priv.updating_selection = false;

        // Find the row for this page
        var i: c_int = 0;
        while (priv.tab_list.getRowAtIndex(i)) |row| : (i += 1) {
            const page = row.as(gtk.Widget).getData(adw.TabPage, "tab-page") orelse continue;
            if (page == selected_page) {
                priv.tab_list.selectRow(row);
                break;
            }
        }
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
    }

    //---------------------------------------------------------------
    // Signal handlers

    fn onPageAttached(
        _: *adw.TabView,
        page: *adw.TabPage,
        position: c_int,
        self: *Self,
    ) callconv(.c) void {
        self.addRowForPage(page, position);
    }

    fn onPageDetached(
        _: *adw.TabView,
        page: *adw.TabPage,
        _: c_int,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();

        // Find and remove the row for this page
        var i: c_int = 0;
        while (priv.tab_list.getRowAtIndex(i)) |row| : (i += 1) {
            const row_page = row.as(gtk.Widget).getData(adw.TabPage, "tab-page") orelse continue;
            if (row_page == page) {
                priv.tab_list.remove(row.as(gtk.Widget));
                break;
            }
        }
    }

    fn onSelectedPageChanged(
        _: *gobject.Object,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.syncSelection();
    }

    fn onCloseButtonClicked(
        button: *gtk.Button,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        const tab_view = priv.tab_view orelse return;

        const page = button.as(gtk.Widget).getData(adw.TabPage, "tab-page") orelse return;
        tab_view.closePage(page);
    }

    fn rowSelected(
        _: *gtk.ListBox,
        row_: ?*gtk.ListBoxRow,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        if (priv.updating_selection) return;

        const tab_view = priv.tab_view orelse return;
        const row = row_ orelse return;

        priv.updating_selection = true;
        defer priv.updating_selection = false;

        const page = row.as(gtk.Widget).getData(adw.TabPage, "tab-page") orelse return;
        tab_view.setSelectedPage(page);
    }

    fn newTab(
        _: *gtk.Button,
        self: *Self,
    ) callconv(.c) void {
        signals.@"new-tab-request".impl.emit(
            self,
            null,
            .{},
            null,
        );
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();

        // Disconnect and unref the tab view
        if (priv.tab_view) |view| {
            if (priv.page_attached_handler != 0) {
                view.as(gobject.Object).signalHandlerDisconnect(priv.page_attached_handler);
                priv.page_attached_handler = 0;
            }
            if (priv.page_detached_handler != 0) {
                view.as(gobject.Object).signalHandlerDisconnect(priv.page_detached_handler);
                priv.page_detached_handler = 0;
            }
            if (priv.selected_page_handler != 0) {
                view.as(gobject.Object).signalHandlerDisconnect(priv.selected_page_handler);
                priv.selected_page_handler = 0;
            }
            if (priv.page_reordered_handler != 0) {
                view.as(gobject.Object).signalHandlerDisconnect(priv.page_reordered_handler);
                priv.page_reordered_handler = 0;
            }
            view.unref();
            priv.tab_view = null;
        }

        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "vertical-tab-sidebar",
                }),
            );

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.@"tab-view".impl,
                properties.@"tab-overview-open".impl,
            });

            // Bindings
            class.bindTemplateChildPrivate("tab_list", .{});
            class.bindTemplateChildPrivate("new_tab_button", .{});

            // Template Callbacks
            class.bindTemplateCallback("row_selected", &rowSelected);
            class.bindTemplateCallback("new_tab", &newTab);

            // Signals
            signals.@"new-tab-request".impl.register(.{});

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};

