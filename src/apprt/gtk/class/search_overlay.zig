const std = @import("std");
const adw = @import("adw");
const glib = @import("glib");
const gobject = @import("gobject");
const gdk = @import("gdk");
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
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        bool,
                        .{
                            .getter = getSearchActive,
                            .setter = setSearchActive,
                        },
                    ),
                },
            );
        };

        pub const @"search-total" = struct {
            pub const name = "search-total";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                u64,
                .{
                    .default = 0,
                    .minimum = 0,
                    .maximum = std.math.maxInt(u64),
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        u64,
                        .{ .getter = getSearchTotal },
                    ),
                },
            );
        };

        pub const @"has-search-total" = struct {
            pub const name = "has-search-total";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        bool,
                        .{ .getter = getHasSearchTotal },
                    ),
                },
            );
        };

        pub const @"search-selected" = struct {
            pub const name = "search-selected";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                u64,
                .{
                    .default = 0,
                    .minimum = 0,
                    .maximum = std.math.maxInt(u64),
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        u64,
                        .{ .getter = getSearchSelected },
                    ),
                },
            );
        };

        pub const @"has-search-selected" = struct {
            pub const name = "has-search-selected";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        bool,
                        .{ .getter = getHasSearchSelected },
                    ),
                },
            );
        };

        pub const @"halign-target" = struct {
            pub const name = "halign-target";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                gtk.Align,
                .{
                    .default = .end,
                    .accessor = C.privateShallowFieldAccessor("halign_target"),
                },
            );
        };

        pub const @"valign-target" = struct {
            pub const name = "valign-target";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                gtk.Align,
                .{
                    .default = .start,
                    .accessor = C.privateShallowFieldAccessor("valign_target"),
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

        /// Total number of search matches (null means unknown/none).
        search_total: ?usize = null,

        /// Currently selected match index (null means none selected).
        search_selected: ?usize = null,

        /// Target horizontal alignment for the overlay.
        halign_target: gtk.Align = .end,

        /// Target vertical alignment for the overlay.
        valign_target: gtk.Align = .start,

        pub var offset: c_int = 0;
    };

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
    }

    /// Grab focus on the search entry and select all text.
    pub fn grabFocus(self: *Self) void {
        const priv = self.private();
        _ = priv.search_entry.as(gtk.Widget).grabFocus();

        // Select all text in the search entry field. -1 is distance from
        // the end, causing the entire text to be selected.
        priv.search_entry.as(gtk.Editable).selectRegion(0, -1);
    }

    // Set active status, and update search on activation
    fn setSearchActive(self: *Self, active: bool) void {
        const priv = self.private();
        if (!priv.active and active) {
            const text = priv.search_entry.as(gtk.Editable).getText();
            signals.@"search-changed".impl.emit(self, null, .{text}, null);
        }
        priv.active = active;
    }

    // Set contents of search
    pub fn setSearchContents(self: *Self, content: [:0]const u8) void {
        const priv = self.private();
        priv.search_entry.as(gtk.Editable).setText(content);
        signals.@"search-changed".impl.emit(self, null, .{content}, null);
    }

    /// Set the total number of search matches.
    pub fn setSearchTotal(self: *Self, total: ?usize) void {
        const priv = self.private();
        const had_total = priv.search_total != null;
        if (priv.search_total == total) return;
        priv.search_total = total;
        self.as(gobject.Object).notifyByPspec(properties.@"search-total".impl.param_spec);
        if (had_total != (total != null)) {
            self.as(gobject.Object).notifyByPspec(properties.@"has-search-total".impl.param_spec);
        }
    }

    /// Set the currently selected match index.
    pub fn setSearchSelected(self: *Self, selected: ?usize) void {
        const priv = self.private();
        const had_selected = priv.search_selected != null;
        if (priv.search_selected == selected) return;
        priv.search_selected = selected;
        self.as(gobject.Object).notifyByPspec(properties.@"search-selected".impl.param_spec);
        if (had_selected != (selected != null)) {
            self.as(gobject.Object).notifyByPspec(properties.@"has-search-selected".impl.param_spec);
        }
    }

    fn getSearchActive(self: *Self) bool {
        return self.private().active;
    }

    fn getSearchTotal(self: *Self) u64 {
        return self.private().search_total orelse 0;
    }

    fn getHasSearchTotal(self: *Self) bool {
        return self.private().search_total != null;
    }

    fn getSearchSelected(self: *Self) u64 {
        return self.private().search_selected orelse 0;
    }

    fn getHasSearchSelected(self: *Self) bool {
        return self.private().search_selected != null;
    }

    fn closureMatchLabel(
        _: *Self,
        has_selected: bool,
        selected: u64,
        has_total: bool,
        total: u64,
    ) callconv(.c) ?[*:0]const u8 {
        if (!has_total or total == 0) return glib.ext.dupeZ(u8, "0/0");
        var buf: [32]u8 = undefined;
        const label = std.fmt.bufPrintZ(&buf, "{}/{}", .{
            if (has_selected) selected + 1 else 0,
            total,
        }) catch return null;
        return glib.ext.dupeZ(u8, label);
    }

    //---------------------------------------------------------------
    // Template callbacks

    fn searchChanged(entry: *gtk.SearchEntry, self: *Self) callconv(.c) void {
        const text = entry.as(gtk.Editable).getText();
        signals.@"search-changed".impl.emit(self, null, .{text}, null);
    }

    // NOTE: The callbacks below use anyopaque for the first parameter
    // because they're shared with multiple widgets in the template.

    fn stopSearch(_: *anyopaque, self: *Self) callconv(.c) void {
        signals.@"stop-search".impl.emit(self, null, .{}, null);
    }

    fn nextMatch(_: *anyopaque, self: *Self) callconv(.c) void {
        signals.@"next-match".impl.emit(self, null, .{}, null);
    }

    fn previousMatch(_: *anyopaque, self: *Self) callconv(.c) void {
        signals.@"previous-match".impl.emit(self, null, .{}, null);
    }

    fn searchEntryKeyPressed(
        _: *gtk.EventControllerKey,
        keyval: c_uint,
        _: c_uint,
        gtk_mods: gdk.ModifierType,
        self: *Self,
    ) callconv(.c) c_int {
        if (keyval == gdk.KEY_Return or keyval == gdk.KEY_KP_Enter) {
            if (gtk_mods.shift_mask) {
                signals.@"previous-match".impl.emit(self, null, .{}, null);
            } else {
                signals.@"next-match".impl.emit(self, null, .{}, null);
            }

            return 1;
        }

        return 0;
    }

    fn onDragEnd(
        _: *gtk.GestureDrag,
        offset_x: f64,
        offset_y: f64,
        self: *Self,
    ) callconv(.c) void {
        // On drag end, we want to move our halign/valign if we crossed
        // the midpoint on either axis. This lets the search overlay be
        // moved to different corners of the parent container.

        const priv = self.private();
        const widget = self.as(gtk.Widget);
        const parent = widget.getParent() orelse return;

        const parent_width: f64 = @floatFromInt(parent.getAllocatedWidth());
        const parent_height: f64 = @floatFromInt(parent.getAllocatedHeight());
        const self_width: f64 = @floatFromInt(widget.getAllocatedWidth());
        const self_height: f64 = @floatFromInt(widget.getAllocatedHeight());

        const self_x: f64 = if (priv.halign_target == .start) 0 else parent_width - self_width;
        const self_y: f64 = if (priv.valign_target == .start) 0 else parent_height - self_height;

        const new_x = self_x + offset_x + (self_width / 2);
        const new_y = self_y + offset_y + (self_height / 2);

        const new_halign: gtk.Align = if (new_x > parent_width / 2) .end else .start;
        const new_valign: gtk.Align = if (new_y > parent_height / 2) .end else .start;

        var changed = false;
        if (new_halign != priv.halign_target) {
            priv.halign_target = new_halign;
            self.as(gobject.Object).notifyByPspec(properties.@"halign-target".impl.param_spec);
            changed = true;
        }
        if (new_valign != priv.valign_target) {
            priv.valign_target = new_valign;
            self.as(gobject.Object).notifyByPspec(properties.@"valign-target".impl.param_spec);
            changed = true;
        }

        if (changed) self.as(gtk.Widget).queueResize();
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
            class.bindTemplateCallback("search_changed", &searchChanged);
            class.bindTemplateCallback("match_label_closure", &closureMatchLabel);
            class.bindTemplateCallback("next_match", &nextMatch);
            class.bindTemplateCallback("previous_match", &previousMatch);
            class.bindTemplateCallback("search_entry_key_pressed", &searchEntryKeyPressed);
            class.bindTemplateCallback("on_drag_end", &onDragEnd);

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.active.impl,
                properties.@"search-total".impl,
                properties.@"has-search-total".impl,
                properties.@"search-selected".impl,
                properties.@"has-search-selected".impl,
                properties.@"halign-target".impl,
                properties.@"valign-target".impl,
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
