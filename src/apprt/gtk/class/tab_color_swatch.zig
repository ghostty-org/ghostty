const std = @import("std");
const gobject = @import("gobject");
const gtk = @import("gtk");

const Common = @import("../class.zig").Common;
const TabColor = @import("tab.zig").TabColor;

/// Vector color swatch drawn in `snapshot` via `TabColor.appendSwatch`.
pub const TabColorSwatch = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gtk.Widget;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyTabColorSwatch",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        color: TabColor = .none,
        selected: bool = false,
        pub var offset: c_int = 0;
    };

    const css_size: c_int = 18;

    fn init(self: *Self, _: *Class) callconv(.c) void {
        self.as(gtk.Widget).setOverflow(.visible);
    }

    pub fn new(color: TabColor, selected: bool) *Self {
        const self = gobject.ext.newInstance(Self, .{});
        const priv = self.private();
        priv.color = color;
        priv.selected = selected;
        return self;
    }

    fn measure(
        _: *Self,
        _: gtk.Orientation,
        _: c_int,
        minimum: ?*c_int,
        natural: ?*c_int,
        minimum_baseline: ?*c_int,
        natural_baseline: ?*c_int,
    ) callconv(.c) void {
        if (minimum) |v| v.* = css_size;
        if (natural) |v| v.* = css_size;
        if (minimum_baseline) |v| v.* = -1;
        if (natural_baseline) |v| v.* = -1;
    }

    fn snapshot(self: *Self, snap: *gtk.Snapshot) callconv(.c) void {
        const widget = self.as(gtk.Widget);
        const width = widget.getWidth();
        const height = widget.getHeight();
        if (width <= 0 or height <= 0) return;
        const size: f32 = @floatFromInt(@min(width, height));
        const priv = self.private();
        priv.color.appendSwatch(snap, size, priv.selected);
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
            gtk.Widget.Class.setCssName(class.as(gtk.Widget.Class), "ghostty-tab-color-swatch");
            gtk.Widget.virtual_methods.measure.implement(class, &measure);
            gtk.Widget.virtual_methods.snapshot.implement(class, &snapshot);
        }

        pub const as = C.Class.as;
    };
};
