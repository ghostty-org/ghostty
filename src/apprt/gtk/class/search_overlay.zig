const std = @import("std");
const adw = @import("adw");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;

const log = std.log.scoped(.gtk_ghostty_search_overlay);

/// The overlay that shows the current size while a surface is resizing.
/// This can be used generically to show pretty much anything with a
/// disappearing overlay, but we have no other use at this point so it
/// is named specifically for what it does.
///
/// General usage:
///
///   1. Add it to an overlay
///   2. Set the label with `setLabel`
///   3. Schedule to show it with `schedule`
///
/// Set any properties to change the behavior.
pub const SearchOverlay = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttySearchOverlay",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        pub const active = struct {
            pub const name = "active";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = C.privateShallowFieldAccessor("active"),
                },
            );
        };

        pub const @"search-total" = struct {
            pub const name = "search-total";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                i64,
                .{
                    .default = -1,
                    .minimum = -1,
                    .maximum = std.math.maxInt(i64),
                    .accessor = C.privateShallowFieldAccessor("search_total"),
                },
            );
        };

        pub const @"search-selected" = struct {
            pub const name = "search-selected";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                i64,
                .{
                    .default = -1,
                    .minimum = -1,
                    .maximum = std.math.maxInt(i64),
                    .accessor = C.privateShallowFieldAccessor("search_selected"),
                },
            );
        };
    };

    pub const signals = struct {
        /// Emitted when the search is stopped (e.g., Escape pressed).
        pub const @"stop-search" = struct {
            pub const name = "stop-search";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{},
                void,
            );
        };

        /// Emitted when the search text changes (debounced).
        pub const @"search-changed" = struct {
            pub const name = "search-changed";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{?[*:0]const u8},
                void,
            );
        };

        /// Emitted when navigating to the next match.
        pub const @"next-match" = struct {
            pub const name = "next-match";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{},
                void,
            );
        };

        /// Emitted when navigating to the previous match.
        pub const @"previous-match" = struct {
            pub const name = "previous-match";
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
        /// The search entry widget.
        search_entry: *gtk.SearchEntry,

        /// True when a search is active, meaning we should show the overlay.
        active: bool = false,

        /// Total number of search matches (-1 means unknown/none).
        search_total: i64 = -1,

        /// Currently selected match index (-1 means none selected).
        search_selected: i64 = -1,

        pub var offset: c_int = 0;
    };

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
    }

    /// Grab focus on the search entry and select all text.
    pub fn grabFocus(self: *Self) void {
        const priv = self.private();
        _ = priv.search_entry.as(gtk.Widget).grabFocus();
        priv.search_entry.as(gtk.Editable).selectRegion(0, -1);
    }

    /// Set the total number of search matches.
    pub fn setSearchTotal(self: *Self, total: ?usize) void {
        const value: i64 = if (total) |t| @intCast(t) else -1;
        var gvalue = gobject.ext.Value.newFrom(value);
        defer gvalue.unset();
        self.as(gobject.Object).setProperty(properties.@"search-total".name, &gvalue);
    }

    /// Set the currently selected match index.
    pub fn setSearchSelected(self: *Self, selected: ?usize) void {
        const value: i64 = if (selected) |s| @intCast(s) else -1;
        var gvalue = gobject.ext.Value.newFrom(value);
        defer gvalue.unset();
        self.as(gobject.Object).setProperty(properties.@"search-selected".name, &gvalue);
    }

    fn closureMatchLabel(_: *Self, selected: i64, total: i64) callconv(.c) ?[*:0]const u8 {
        var buf: [32]u8 = undefined;
        const label = std.fmt.bufPrintZ(&buf, "{}/{}", .{
            if (selected >= 0) selected else 0,
            if (total >= 0) total else 0,
        }) catch return null;
        return glib.ext.dupeZ(u8, label);
    }

    //---------------------------------------------------------------
    // Template callbacks

    fn stopSearch(_: *gtk.SearchEntry, self: *Self) callconv(.c) void {
        signals.@"stop-search".impl.emit(self, null, .{}, null);
    }

    fn stopSearchButton(_: *gtk.Button, self: *Self) callconv(.c) void {
        signals.@"stop-search".impl.emit(self, null, .{}, null);
    }

    fn searchChanged(entry: *gtk.SearchEntry, self: *Self) callconv(.c) void {
        const text = entry.as(gtk.Editable).getText();
        signals.@"search-changed".impl.emit(self, null, .{text}, null);
    }

    fn nextMatch(_: *gtk.Button, self: *Self) callconv(.c) void {
        signals.@"next-match".impl.emit(self, null, .{}, null);
    }

    fn previousMatch(_: *gtk.Button, self: *Self) callconv(.c) void {
        signals.@"previous-match".impl.emit(self, null, .{}, null);
    }

    fn nextMatchEntry(_: *gtk.SearchEntry, self: *Self) callconv(.c) void {
        signals.@"next-match".impl.emit(self, null, .{}, null);
    }

    fn previousMatchEntry(_: *gtk.SearchEntry, self: *Self) callconv(.c) void {
        signals.@"previous-match".impl.emit(self, null, .{}, null);
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        _ = priv;

        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();
        _ = priv;

        gobject.Object.virtual_methods.finalize.call(
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
                    .minor = 2,
                    .name = "search-overlay",
                }),
            );

            // Bindings
            class.bindTemplateChildPrivate("search_entry", .{});

            // Template Callbacks
            class.bindTemplateCallback("stop_search", &stopSearch);
            class.bindTemplateCallback("stop_search_button", &stopSearchButton);
            class.bindTemplateCallback("search_changed", &searchChanged);
            class.bindTemplateCallback("match_label_closure", &closureMatchLabel);
            class.bindTemplateCallback("next_match", &nextMatch);
            class.bindTemplateCallback("previous_match", &previousMatch);
            class.bindTemplateCallback("next_match_entry", &nextMatchEntry);
            class.bindTemplateCallback("previous_match_entry", &previousMatchEntry);

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.active.impl,
                properties.@"search-total".impl,
                properties.@"search-selected".impl,
            });

            // Signals
            signals.@"stop-search".impl.register(.{});
            signals.@"search-changed".impl.register(.{});
            signals.@"next-match".impl.register(.{});
            signals.@"previous-match".impl.register(.{});

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
