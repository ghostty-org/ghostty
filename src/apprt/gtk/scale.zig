const std = @import("std");
const gtk = @import("gtk");

pub const DeviceSize = struct {
    width: u32,
    height: u32,
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

pub fn widgetDeviceSize(widget: *gtk.Widget) DeviceSize {
    return deviceSize(
        widget.getWidth(),
        widget.getHeight(),
        widgetSurfaceScale(widget),
    );
}

pub fn deviceSize(css_width: c_int, css_height: c_int, scale: f64) DeviceSize {
    return .{
        .width = scaledAxis(css_width, scale),
        .height = scaledAxis(css_height, scale),
    };
}

fn scaledAxis(css: c_int, scale: f64) u32 {
    if (css <= 0 or !(scale > 0)) return 0;
    return @intFromFloat(@ceil(@as(f64, @floatFromInt(css)) * scale));
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
    try testing.expectEqual(DeviceSize{ .width = 127, .height = 127 }, deviceSize(101, 101, 1.25));
}

test "deviceSize rejects non-positive inputs" {
    const testing = std.testing;
    try testing.expectEqual(DeviceSize{ .width = 0, .height = 15 }, deviceSize(0, 10, 1.5));
    try testing.expectEqual(DeviceSize{ .width = 0, .height = 0 }, deviceSize(10, 10, 0));
    try testing.expectEqual(DeviceSize{ .width = 0, .height = 15 }, deviceSize(-1, 10, 1.5));
}
