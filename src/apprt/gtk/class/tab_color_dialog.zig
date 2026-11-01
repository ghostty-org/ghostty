const std = @import("std");
const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const i18n = @import("../../../os/main.zig").i18n;
const ext = @import("../ext.zig");
const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const Tab = @import("tab.zig").Tab;
const TabColor = @import("tab.zig").TabColor;
const TabColorSwatch = @import("tab_color_swatch.zig").TabColorSwatch;

/// Dialog to pick a per-tab color indicator.
pub const TabColorDialog = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.AlertDialog;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyTabColorDialog",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        tab: ?*Tab = null,
        swatches: *gtk.Box,

        pub var offset: c_int = 0;
    };

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
    }

    pub fn new(tab: *Tab) *Self {
        const self = gobject.ext.newInstance(Self, .{});
        self.private().tab = tab.ref();
        self.populateSwatches();
        return self;
    }

    fn populateSwatches(self: *Self) void {
        const priv = self.private();
        const tab = priv.tab orelse return;
        const current = tab.getTabColor();

        for (std.meta.tags(TabColor)) |color| {
            const tooltip: [*:0]const u8 = switch (color) {
                .none => i18n._("None"),
                .blue => i18n._("Blue"),
                .purple => i18n._("Purple"),
                .pink => i18n._("Pink"),
                .red => i18n._("Red"),
                .orange => i18n._("Orange"),
                .yellow => i18n._("Yellow"),
                .green => i18n._("Green"),
                .teal => i18n._("Teal"),
                .graphite => i18n._("Graphite"),
            };

            const swatch = TabColorSwatch.new(color, color == current);
            const button = gtk.Button.new();
            button.setChild(swatch.as(gtk.Widget));
            button.as(gtk.Widget).addCssClass("flat");
            button.as(gtk.Widget).addCssClass("circular");
            button.as(gtk.Widget).setTooltipText(tooltip);

            var label_value = std.mem.zeroes(gobject.Value);
            gtk.AccessibleProperty.initValue(.label, &label_value);
            defer label_value.unset();
            label_value.setString(tooltip);
            var props = [_]gtk.AccessibleProperty{.label};
            button.as(gtk.Accessible).updatePropertyValue(1, &props, @ptrCast(&label_value));

            const ud = glib.ext.create(ColorPick);
            ud.* = .{
                .dialog = self,
                .color = color,
            };
            _ = gtk.Button.signals.clicked.connect(
                button,
                *ColorPick,
                colorPickClicked,
                ud,
                .{ .destroyData = colorPickDestroy },
            );

            priv.swatches.append(button.as(gtk.Widget));
        }
    }

    pub fn present(self: *Self, parent_: *gtk.Widget) void {
        const parent: *gtk.Widget = if (ext.getAncestor(
            adw.ApplicationWindow,
            parent_,
        )) |window|
            window.as(gtk.Widget)
        else if (ext.getAncestor(
            adw.Window,
            parent_,
        )) |window|
            window.as(gtk.Widget)
        else
            parent_;

        self.as(adw.AlertDialog).choose(parent, null, null, null);
    }

    const ColorPick = struct {
        dialog: *Self,
        color: TabColor,
    };

    fn colorPickClicked(_: *gtk.Button, ud: *ColorPick) callconv(.c) void {
        if (ud.dialog.private().tab) |tab| {
            tab.setTabColor(ud.color);
        }
        ud.dialog.as(adw.Dialog).forceClose();
    }

    fn colorPickDestroy(ud: *ColorPick) callconv(.c) void {
        glib.ext.destroy(ud);
    }

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
        if (priv.tab) |tab| {
            tab.unref();
            priv.tab = null;
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
            gobject.ext.ensureType(TabColorSwatch);

            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "tab-color-dialog",
                }),
            );

            class.bindTemplateChildPrivate("swatches", .{});

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
