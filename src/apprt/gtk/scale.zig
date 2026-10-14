const std = @import("std");
const gobject = @import("gobject");
const graphene = @import("graphene");
const gtk = @import("gtk");

pub const DeviceSize = struct {
    width: u32,
    height: u32,
};

pub const CssPoint = struct {
    x: f64,
    y: f64,
};

/// Scale, GdkSurface-space origin, and snapped device size for one widget.
pub const Layout = struct {
    scale: f64,
    /// Widget-to-native scaling introduced by pixel-aligned split allocations.
    transform_scale: CssPoint = .{ .x = 1, .y = 1 },
    origin: CssPoint,
    size: DeviceSize,

    /// CSS offset that moves widget (0,0) onto the nearest device pixel.
    pub fn snapOrigin(self: Layout) CssPoint {
        return .{
            .x = snapOffset(self.origin.x, self.scale) / self.transform_scale.x,
            .y = snapOffset(self.origin.y, self.scale) / self.transform_scale.y,
        };
    }

    /// Device pixels per local widget unit; font DPI still uses `scale`.
    pub fn pixelScale(self: Layout) CssPoint {
        return .{
            .x = self.scale * self.transform_scale.x,
            .y = self.scale * self.transform_scale.y,
        };
    }
};

pub fn widgetSurfaceScale(widget: *gtk.Widget) f64 {
    if (widget.getNative()) |native| {
        if (native.getSurface()) |surface| {
            const scale = surface.getScale();
            if (scale > 0) return scale;
        }
    }

    const scale = widget.getScaleFactor();
    if (scale <= 0) return 1.0;
    return @floatFromInt(scale);
}

/// Widget (0,0) in GdkSurface CSS coordinates.
///
/// `computePoint` to the native widget is CSS inside the window. CSD shadows
/// live outside that, so add `gtk_native_get_surface_transform` to get the
/// origin on the GdkSurface.
pub fn widgetSurfaceOrigin(widget: *gtk.Widget) CssPoint {
    const native = widget.getNative() orelse return .{ .x = 0, .y = 0 };
    const native_widget = gobject.ext.cast(gtk.Widget, native) orelse return .{ .x = 0, .y = 0 };

    var native_origin: graphene.Point = undefined;
    if (widget.computePoint(
        native_widget,
        &.{ .f_x = 0, .f_y = 0 },
        &native_origin,
    ) == 0) return .{ .x = 0, .y = 0 };

    var tx: f64 = 0;
    var ty: f64 = 0;
    native.getSurfaceTransform(&tx, &ty);

    return .{
        .x = @as(f64, native_origin.f_x) + tx,
        .y = @as(f64, native_origin.f_y) + ty,
    };
}

pub fn widgetLayout(widget: *gtk.Widget) Layout {
    return widgetLayoutForSize(widget, widget.getWidth(), widget.getHeight());
}

pub fn widgetLayoutForSize(widget: *gtk.Widget, css_width: c_int, css_height: c_int) Layout {
    const scale = widgetSurfaceScale(widget);
    const origin = widgetSurfaceOrigin(widget);
    const transform_scale = widgetTransformScale(widget);
    return .{
        .scale = scale,
        .transform_scale = transform_scale,
        .origin = origin,
        .size = .{
            .width = snappedAxis(origin.x, @as(f64, @floatFromInt(css_width)) * transform_scale.x, scale),
            .height = snappedAxis(origin.y, @as(f64, @floatFromInt(css_height)) * transform_scale.y, scale),
        },
    };
}

fn widgetTransformScale(widget: *gtk.Widget) CssPoint {
    const identity: CssPoint = .{ .x = 1, .y = 1 };
    const native = widget.getNative() orelse return identity;
    const native_widget = gobject.ext.cast(gtk.Widget, native) orelse return identity;
    // Graphene uses SIMD loads; the generated binding omits its alignment.
    var matrix: graphene.Matrix align(16) = undefined;
    if (widget.computeTransform(native_widget, &matrix) == 0) return identity;
    const x = matrix.getXScale();
    const y = matrix.getYScale();
    if (!(x > 0) or !(y > 0)) return identity;
    return .{ .x = x, .y = y };
}

pub fn deviceSize(css_width: c_int, css_height: c_int, scale: f64) DeviceSize {
    return snappedDeviceSize(0, 0, css_width, css_height, scale);
}

pub fn snappedDeviceSize(
    origin_x: f64,
    origin_y: f64,
    css_width: c_int,
    css_height: c_int,
    scale: f64,
) DeviceSize {
    return .{
        .width = snappedAxis(origin_x, @floatFromInt(css_width), scale),
        .height = snappedAxis(origin_y, @floatFromInt(css_height), scale),
    };
}

/// CSS delta that lands a surface-relative origin on the nearest device pixel.
///
/// Tab chrome can put widget (0,0) on a fractional device coordinate, so GTK
/// linearly samples every texel. Shift by less than 0.5 device px without
/// changing content size.
pub fn snapOffset(css_origin: f64, scale: f64) f64 {
    if (!(scale > 0)) return 0;
    const device_origin = css_origin * scale;
    return (@round(device_origin) - device_origin) / scale;
}

/// Device coverage of one axis after snapping both edges.
///
/// `round(end) - round(start)`, not `ceil(css × scale)`, so the buffer spans
/// the same snapped pixels the texture is drawn into.
fn snappedAxis(css_origin: f64, css: f64, scale: f64) u32 {
    if (css <= 0 or !(scale > 0)) return 0;
    const start = @round(css_origin * scale);
    const end = @round((css_origin + css) * scale);
    if (end <= start) return 0;
    return @intFromFloat(end - start);
}

test "deviceSize integer scale" {
    const testing = std.testing;
    try testing.expectEqual(DeviceSize{ .width = 800, .height = 600 }, deviceSize(800, 600, 1.0));
    try testing.expectEqual(DeviceSize{ .width = 1600, .height = 1200 }, deviceSize(800, 600, 2.0));
}

test "deviceSize fractional scale" {
    const testing = std.testing;
    try testing.expectEqual(DeviceSize{ .width = 1000, .height = 750 }, deviceSize(800, 600, 1.25));
    try testing.expectEqual(DeviceSize{ .width = 1200, .height = 900 }, deviceSize(800, 600, 1.5));
    try testing.expectEqual(DeviceSize{ .width = 126, .height = 126 }, deviceSize(101, 101, 1.25));
}

test "deviceSize rejects non-positive inputs" {
    const testing = std.testing;
    try testing.expectEqual(DeviceSize{ .width = 0, .height = 15 }, deviceSize(0, 10, 1.5));
    try testing.expectEqual(DeviceSize{ .width = 0, .height = 0 }, deviceSize(10, 10, 0));
    try testing.expectEqual(DeviceSize{ .width = 0, .height = 15 }, deviceSize(-1, 10, 1.5));
}

test "snapOffset aligns fractional device origins" {
    const testing = std.testing;
    try testing.expectApproxEqAbs(@as(f64, 0), snapOffset(0, 1.75), 0.000001);
    try testing.expectApproxEqAbs(@as(f64, -1.0 / 7.0), snapOffset(47, 1.75), 0.000001);
    try testing.expectApproxEqAbs(@as(f64, 0.2), snapOffset(47, 1.25), 0.000001);
    try testing.expectApproxEqAbs(@as(f64, 0.25), snapOffset(47, 4.0 / 3.0), 0.000001);
}

test "snapOffset rejects non-positive scale" {
    const testing = std.testing;
    try testing.expectEqual(@as(f64, 0), snapOffset(47, 0));
    try testing.expectEqual(@as(f64, 0), snapOffset(47, -1.25));
}

test "snappedDeviceSize uses origin-aware device spans" {
    const testing = std.testing;
    const scale_4_3 = 4.0 / 3.0;
    try testing.expectEqual(
        DeviceSize{ .width = 1066, .height = 1066 },
        snappedDeviceSize(47, 47, 800, 800, scale_4_3),
    );
    try testing.expectEqual(
        DeviceSize{ .width = 1097, .height = 628 },
        snappedDeviceSize(0, 0, 823, 471, scale_4_3),
    );
    try testing.expectEqual(
        DeviceSize{ .width = 126, .height = 126 },
        snappedDeviceSize(0, 0, 101, 101, 1.25),
    );
}

test "snappedDeviceSize integer scale with origin" {
    const testing = std.testing;
    try testing.expectEqual(
        DeviceSize{ .width = 800, .height = 600 },
        snappedDeviceSize(47, 11, 800, 600, 1.0),
    );
    try testing.expectEqual(
        DeviceSize{ .width = 1600, .height = 1200 },
        snappedDeviceSize(0.25, 0.75, 800, 600, 2.0),
    );
}
