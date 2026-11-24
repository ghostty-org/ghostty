const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const glib = @import("glib");
const gobject = @import("gobject");
const graphene = @import("graphene");
const gsk = @import("gsk");
const gtk = @import("gtk");

const Common = @import("../class.zig").Common;

const log = std.log.scoped(.gtk_ghostty_tab_color_swatch);

/// Draw the swatch for `color` into `snap` as vector paths: a filled circle,
/// or for `null` (no color) an outlined circle with a slash.
pub fn appendSwatch(color: ?adw.AccentColor, snap: *gtk.Snapshot, size: f32) void {
    const mid = size / 2.0;
    const radius = size * 0.3125;
    const stroke_width = @max(1.0, size * (1.5 / 16.0));
    const center: graphene.Point = .{ .f_x = mid, .f_y = mid };

    if (color) |accent| {
        var fill: gdk.RGBA = undefined;
        accent.toRgba(&fill);
        const builder = gsk.PathBuilder.new();
        builder.addCircle(&center, radius);
        const path = builder.freeToPath();
        defer path.unref();
        snap.appendFill(path, .winding, &fill);
    } else {
        var stroke_color: gdk.RGBA = undefined;
        adw.AccentColor.slate.toRgba(&stroke_color);
        const stroke = gsk.Stroke.new(stroke_width);
        defer stroke.free();

        const circle_builder = gsk.PathBuilder.new();
        circle_builder.addCircle(&center, radius);
        const circle = circle_builder.freeToPath();
        defer circle.unref();
        snap.appendStroke(circle, stroke, &stroke_color);

        const inset = radius * 0.72;
        const slash_builder = gsk.PathBuilder.new();
        slash_builder.moveTo(mid - inset, mid + inset);
        slash_builder.lineTo(mid + inset, mid - inset);
        const slash = slash_builder.freeToPath();
        defer slash.unref();
        snap.appendStroke(slash, stroke, &stroke_color);
    }
}

const indicator_px = 48;

fn emptyIndicatorTexture() *gdk.Texture {
    const transparent: [indicator_px * indicator_px * 4]u8 = @splat(0);
    const bytes = glib.Bytes.new(&transparent, transparent.len);
    defer bytes.unref();
    return gdk.MemoryTexture.new(
        indicator_px,
        indicator_px,
        .r8g8b8a8_premultiplied,
        bytes,
        indicator_px * 4,
    ).as(gdk.Texture);
}

/// Render the vector swatch for `color` to a texture for use as a tab
/// indicator icon. It is rendered at 3x (48px) so GTK can scale for HiDPI.
pub fn createIndicatorIcon(color: adw.AccentColor) *gdk.Texture {
    const size: f32 = indicator_px;

    const snap = gtk.Snapshot.new();
    appendSwatch(color, snap, size);
    const node = snap.freeToNode() orelse return emptyIndicatorTexture();
    defer node.unref();

    const cairo_renderer = gsk.CairoRenderer.new();
    defer cairo_renderer.unref();
    const renderer = cairo_renderer.as(gsk.Renderer);
    var err: ?*glib.Error = null;
    if (renderer.realize(null, &err) == 0) {
        if (err) |e| {
            defer e.free();
            log.warn("failed to realize swatch renderer: {s}", .{e.f_message orelse "unknown"});
        }
        return emptyIndicatorTexture();
    }
    defer renderer.unrealize();

    const viewport: graphene.Rect = .{
        .f_origin = .{ .f_x = 0, .f_y = 0 },
        .f_size = .{ .f_width = size, .f_height = size },
    };
    return renderer.renderTexture(node, &viewport);
}

/// Vector color swatch drawn in `snapshot` via `appendSwatch`.
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
        color: ?adw.AccentColor = null,
        pub var offset: c_int = 0;
    };

    const css_size: c_int = 18;

    fn init(self: *Self, _: *Class) callconv(.c) void {
        self.as(gtk.Widget).setOverflow(.visible);
    }

    pub fn new(color: ?adw.AccentColor) *Self {
        const self = gobject.ext.newInstance(Self, .{});
        self.private().color = color;
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
        appendSwatch(self.private().color, snap, size);
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
