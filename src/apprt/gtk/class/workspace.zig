const std = @import("std");
const assert = @import("../../../quirks.zig").inlineAssert;
const adw = @import("adw");
const gobject = @import("gobject");
const gtk = @import("gtk");

const apprt = @import("../../../apprt.zig");
const configpkg = @import("../../../config.zig");
const CoreSurface = @import("../../../Surface.zig");
const ext = @import("../ext.zig");
const Common = @import("../class.zig").Common;
const Config = @import("config.zig").Config;
const Surface = @import("surface.zig").Surface;
const Tab = @import("tab.zig").Tab;

const log = std.log.scoped(.gtk_ghostty_workspace);

pub const Workspace = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Box;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyWorkspace",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const signals = struct {
        /// Emitted when the workspace's tab view reaches zero pages.
        pub const empty = struct {
            pub const name = "empty";
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
        /// The configuration that new tabs in this workspace use.
        config: ?*Config = null,

        /// The tab view owned by this workspace.
        tab_view: *adw.TabView,

        pub var offset: c_int = 0;
    };

    pub fn new(config: ?*Config) *Self {
        const self = gobject.ext.newInstance(Self, .{});
        const priv = self.private();
        priv.config = if (config) |v| v.ref() else null;
        return self.refSink();
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        const priv = self.private();

        self.as(gtk.Orientable).setOrientation(.vertical);

        const tab_view: *adw.TabView = .new();
        priv.tab_view = tab_view;

        tab_view.setShortcuts(.{});

        _ = gobject.Object.signals.notify.connect(
            tab_view,
            *Self,
            tabViewNPages,
            self,
            .{ .detail = "n-pages" },
        );

        self.as(gtk.Box).append(tab_view.as(gtk.Widget));
    }

    /// Create a new tab with the given parent. The tab will be inserted
    /// at the position dictated by the `window-new-tab-position` config.
    /// The new tab will be selected.
    pub fn newTab(self: *Self, parent_: ?*CoreSurface) void {
        _ = self.newTabPage(parent_, .tab, .none);
    }

    pub fn newTabForWindow(
        self: *Self,
        parent_: ?*CoreSurface,
        overrides: struct {
            command: ?configpkg.Command = null,
            working_directory: ?[:0]const u8 = null,
            title: ?[:0]const u8 = null,

            pub const none: @This() = .{};
        },
    ) void {
        _ = self.newTabPage(
            parent_,
            .window,
            .{
                .command = overrides.command,
                .working_directory = overrides.working_directory,
                .title = overrides.title,
            },
        );
    }

    pub fn newTabPage(
        self: *Self,
        parent_: ?*CoreSurface,
        context: apprt.surface.NewSurfaceContext,
        overrides: struct {
            command: ?configpkg.Command = null,
            working_directory: ?[:0]const u8 = null,
            title: ?[:0]const u8 = null,

            pub const none: @This() = .{};
        },
    ) *adw.TabPage {
        const priv: *Private = self.private();
        const tab_view = priv.tab_view;

        // Create our new tab object.
        const tab = Tab.new(
            priv.config,
            .{
                .command = overrides.command,
                .working_directory = overrides.working_directory,
                .title = overrides.title,
            },
        );

        if (parent_) |p| {
            tab.setParentWithContext(p, context);
        }

        // Get the position that we should insert the new tab at.
        const config = if (priv.config) |v| v.get() else {
            // If we don't have a config we just append it at the end.
            // This should never happen.
            return tab_view.append(tab.as(gtk.Widget));
        };
        const position = switch (config.@"window-new-tab-position") {
            .current => current: {
                const selected = tab_view.getSelectedPage() orelse
                    break :current tab_view.getNPages();
                const current = tab_view.getPagePosition(selected);
                break :current current + 1;
            },

            .end => tab_view.getNPages(),
        };

        // Add the page and select it.
        const page = tab_view.insert(tab.as(gtk.Widget), position);
        tab_view.setSelectedPage(page);

        // Create some property bindings.
        _ = tab.as(gobject.Object).bindProperty(
            "title",
            page.as(gobject.Object),
            "title",
            .{ .sync_create = true },
        );
        _ = tab.as(gobject.Object).bindProperty(
            "tooltip",
            page.as(gobject.Object),
            "tooltip",
            .{ .sync_create = true },
        );

        return page;
    }

    pub const SelectTab = union(enum) {
        previous,
        next,
        last,
        n: usize,
    };

    /// Select the tab as requested. Returns true if the tab selection
    /// changed.
    pub fn selectTab(self: *Self, n: SelectTab) bool {
        const tab_view = self.private().tab_view;

        // Get our current tab numeric position.
        const selected = tab_view.getSelectedPage() orelse return false;
        const current = tab_view.getPagePosition(selected);

        // Get our total.
        const total = tab_view.getNPages();

        const goto: c_int = switch (n) {
            .previous => if (current > 0)
                current - 1
            else
                total - 1,

            .next => if (current < total - 1)
                current + 1
            else
                0,

            .last => total - 1,

            .n => |v| n: {
                // 1-indexed
                if (v == 0) return false;

                const n_int = std.math.cast(
                    c_int,
                    v,
                ) orelse return false;
                break :n @min(n_int - 1, total - 1);
            },
        };
        assert(goto >= 0);
        assert(goto < total);

        // If our target is the same as our current then we do nothing.
        if (goto == current) return false;

        const page = tab_view.getNthPage(goto);
        tab_view.setSelectedPage(page);

        return true;
    }

    /// Move the tab containing the given surface by the given amount.
    /// Returns if this affected any tab positioning.
    pub fn moveTab(
        self: *Self,
        surface: *Surface,
        amount: isize,
    ) bool {
        const tab_view = self.private().tab_view;

        // If we have one tab we never move.
        const total = tab_view.getNPages();
        if (total == 1) return false;

        // Get the tab that contains the given surface.
        const tab = ext.getAncestor(
            Tab,
            surface.as(gtk.Widget),
        ) orelse return false;

        // Get the page position that contains the tab.
        const page = tab_view.getPage(tab.as(gtk.Widget));
        const pos = tab_view.getPagePosition(page);

        // Move it.
        const desired_pos: c_int = desired: {
            const initial: c_int = @intCast(pos + amount);
            const max = total - 1;
            break :desired if (initial < 0)
                max + initial + 1
            else if (initial > max)
                initial - max - 1
            else
                initial;
        };
        assert(desired_pos >= 0);
        assert(desired_pos < total);

        return tab_view.reorderPage(page, desired_pos) != 0;
    }

    /// Get the tab view for this workspace.
    pub fn getTabView(self: *Self) *adw.TabView {
        return self.private().tab_view;
    }

    /// Get the currently selected tab as a Tab object.
    pub fn getSelectedTab(self: *Self) ?*Tab {
        const page = self.private().tab_view.getSelectedPage() orelse return null;
        const child = page.getChild();
        assert(gobject.ext.isA(child, Tab));
        return gobject.ext.cast(Tab, child);
    }

    /// Returns true if this workspace needs confirmation before quitting.
    pub fn getNeedsConfirmQuit(self: *Self) bool {
        const tab_view = self.private().tab_view;
        const n = tab_view.getNPages();
        assert(n >= 0);

        for (0..@intCast(n)) |i| {
            const page = tab_view.getNthPage(@intCast(i));
            const child = page.getChild();
            const tab = gobject.ext.cast(Tab, child) orelse {
                log.warn("unexpected non-Tab child in tab view", .{});
                continue;
            };
            if (tab.getNeedsConfirmQuit()) return true;
        }

        return false;
    }

    fn tabViewNPages(
        _: *adw.TabView,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        if (self.private().tab_view.getNPages() == 0) {
            signals.empty.impl.emit(self, null, .{}, null);
        }
    }

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();

        _ = gobject.signalHandlersDisconnectMatched(
            priv.tab_view.as(gobject.Object),
            .{ .data = true },
            0,
            0,
            null,
            null,
            self,
        );
        self.as(gtk.Box).remove(priv.tab_view.as(gtk.Widget));

        if (priv.config) |v| {
            v.unref();
            priv.config = null;
        }

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const refSink = C.refSink;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            signals.empty.impl.register(.{});

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
    };
};
