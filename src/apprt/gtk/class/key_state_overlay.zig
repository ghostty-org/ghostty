const std = @import("std");
const adw = @import("adw");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const ext = @import("../ext.zig");
const gresource = @import("../build/gresource.zig");
const Application = @import("application.zig").Application;
const Common = @import("../class.zig").Common;

const log = std.log.scoped(.gtk_ghostty_key_state_overlay);

/// An overlay that displays the current key table stack and pending key sequence.
/// This helps users understand what key bindings are active and what keys they've
/// pressed in a multi-key sequence.
pub const KeyStateOverlay = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyKeyStateOverlay",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        pub const tables = struct {
            pub const name = "tables";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*ext.StringList,
                .{
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?*ext.StringList,
                        .{
                            .getter = getTables,
                            .getter_transfer = .none,
                            .setter = setTables,
                            .setter_transfer = .full,
                        },
                    ),
                },
            );
        };

        pub const @"has-tables" = struct {
            pub const name = "has-tables";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        bool,
                        .{ .getter = getHasTables },
                    ),
                },
            );
        };

        pub const sequence = struct {
            pub const name = "sequence";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*ext.StringList,
                .{
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?*ext.StringList,
                        .{
                            .getter = getSequence,
                            .getter_transfer = .none,
                            .setter = setSequence,
                            .setter_transfer = .full,
                        },
                    ),
                },
            );
        };

        pub const @"has-sequence" = struct {
            pub const name = "has-sequence";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        bool,
                        .{ .getter = getHasSequence },
                    ),
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
                    .default = .end,
                    .accessor = C.privateShallowFieldAccessor("valign_target"),
                },
            );
        };
    };

    const Private = struct {
        /// The key table stack.
        tables: ?*ext.StringList = null,

        /// The key sequence.
        sequence: ?*ext.StringList = null,

        /// Target vertical alignment for the overlay.
        valign_target: gtk.Align = .end,

        pub var offset: c_int = 0;
    };

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
    }

    fn getTables(self: *Self) ?*ext.StringList {
        return self.private().tables;
    }

    fn getSequence(self: *Self) ?*ext.StringList {
        return self.private().sequence;
    }

    fn setTables(self: *Self, value: ?*ext.StringList) void {
        const priv = self.private();
        if (priv.tables) |old| {
            old.destroy();
            priv.tables = null;
        }
        if (value) |v| {
            priv.tables = v;
        }

        self.as(gobject.Object).notifyByPspec(properties.tables.impl.param_spec);
        self.as(gobject.Object).notifyByPspec(properties.@"has-tables".impl.param_spec);
    }

    fn setSequence(self: *Self, value: ?*ext.StringList) void {
        const priv = self.private();
        if (priv.sequence) |old| {
            old.destroy();
            priv.sequence = null;
        }
        if (value) |v| {
            priv.sequence = v;
        }

        self.as(gobject.Object).notifyByPspec(properties.sequence.impl.param_spec);
        self.as(gobject.Object).notifyByPspec(properties.@"has-sequence".impl.param_spec);
    }

    fn getHasTables(self: *Self) bool {
        const v = self.private().tables orelse return false;
        return v.strings.len > 0;
    }

    fn getHasSequence(self: *Self) bool {
        const v = self.private().sequence orelse return false;
        return v.strings.len > 0;
    }

    fn closureShowChevron(
        _: *Self,
        has_tables: bool,
        has_sequence: bool,
    ) callconv(.c) c_int {
        return if (has_tables and has_sequence) 1 else 0;
    }

    fn closureHasState(
        _: *Self,
        has_tables: bool,
        has_sequence: bool,
    ) callconv(.c) c_int {
        return if (has_tables or has_sequence) 1 else 0;
    }

    fn closureTablesText(
        _: *Self,
        tables: ?*ext.StringList,
    ) callconv(.c) ?[*:0]const u8 {
        const list = tables orelse return null;
        if (list.strings.len == 0) return null;

        var buf: std.Io.Writer.Allocating = .init(Application.default().allocator());
        defer buf.deinit();

        for (list.strings, 0..) |s, i| {
            if (i > 0) buf.writer.writeAll(" > ") catch return null;
            buf.writer.writeAll(s) catch return null;
        }

        return glib.ext.dupeZ(u8, buf.written());
    }

    fn closureSequenceText(
        _: *Self,
        sequence: ?*ext.StringList,
    ) callconv(.c) ?[*:0]const u8 {
        const list = sequence orelse return null;
        if (list.strings.len == 0) return null;

        var buf: std.Io.Writer.Allocating = .init(Application.default().allocator());
        defer buf.deinit();

        for (list.strings, 0..) |s, i| {
            if (i > 0) buf.writer.writeAll(" ") catch return null;
            buf.writer.writeAll(s) catch return null;
        }

        return glib.ext.dupeZ(u8, buf.written());
    }

    //---------------------------------------------------------------
    // Template callbacks

    fn onDragEnd(
        _: *gtk.GestureDrag,
        _: f64,
        offset_y: f64,
        self: *Self,
    ) callconv(.c) void {
        // Key state overlay only moves between top-center and bottom-center.
        // Horizontal alignment is always center.
        const priv = self.private();
        const widget = self.as(gtk.Widget);
        const parent = widget.getParent() orelse return;

        const parent_height: f64 = @floatFromInt(parent.getAllocatedHeight());
        const self_height: f64 = @floatFromInt(widget.getAllocatedHeight());

        const self_y: f64 = if (priv.valign_target == .start) 0 else parent_height - self_height;
        const new_y = self_y + offset_y + (self_height / 2);

        const new_valign: gtk.Align = if (new_y > parent_height / 2) .end else .start;

        if (new_valign != priv.valign_target) {
            priv.valign_target = new_valign;
            self.as(gobject.Object).notifyByPspec(properties.@"valign-target".impl.param_spec);
            self.as(gtk.Widget).queueResize();
        }
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn dispose(self: *Self) callconv(.c) void {
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

        if (priv.tables) |v| {
            v.destroy();
        }
        if (priv.sequence) |v| {
            v.destroy();
        }

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
                    .name = "key-state-overlay",
                }),
            );

            // Template Callbacks
            class.bindTemplateCallback("on_drag_end", &onDragEnd);
            class.bindTemplateCallback("show_chevron", &closureShowChevron);
            class.bindTemplateCallback("has_state", &closureHasState);
            class.bindTemplateCallback("tables_text", &closureTablesText);
            class.bindTemplateCallback("sequence_text", &closureSequenceText);

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.tables.impl,
                properties.@"has-tables".impl,
                properties.sequence.impl,
                properties.@"has-sequence".impl,
                properties.@"valign-target".impl,
            });

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
