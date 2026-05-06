const BlurRegion = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;

const gobject = @import("gobject");
const gdk = @import("gdk");
const gtk = @import("gtk");

const Window = @import("../winproto.zig").Window;
const ApprtWindow = @import("../class/window.zig").Window;

slices: std.ArrayList(Slice),

/// A rectangular slice of the blur region.
// Marked `extern` since we want to be able to use this in X11 directly.
pub const Slice = extern struct {
    x: Pos,
    y: Pos,
    width: Pos,
    height: Pos,
};

// X11 compatibility. Ideally this should just be an `i32` like Wayland,
// but XLib sucks
const Pos = c_long;

pub const empty: BlurRegion = .{
    .slices = .empty,
};

pub fn deinit(self: *BlurRegion, alloc: Allocator) void {
    self.slices.deinit(alloc);
    self.slices = .empty;
}

// Calculate the blur regions for a window.
//
// Since we have rounded corners by default, we need to carve out the
// pixels on each corner to avoid the "korners bug".
// (cf. https://github.com/cutefishos/fishui/blob/41d4ba194063a3c7fff4675619b57e6ac0504f06/src/platforms/linux/blurhelper/windowblur.cpp#L134)
pub fn calcForWindow(
    alloc: Allocator,
    window: *ApprtWindow,
    csd: bool,
    to_device_coordinates: bool,
) Allocator.Error!BlurRegion {
    const native = window.as(gtk.Native);
    const surface = native.getSurface() orelse return .empty;

    var slices: std.ArrayList(Slice) = .empty;
    errdefer slices.deinit(alloc);

    // Calculate the primary blur region
    // (the one that covers most of the screen).
    // It's easier to do this inside a vector since we have to scale
    // everything by the scale factor anyways.

    // NOTE(pluiedev): CSDs are a f--king mistake.
    // Please, GNOME, stop this nonsense of making a window ~30% bigger
    // internally than how they really are just for your shadows and
    // rounded corners and all that fluff. Please. I beg of you.
    const x: Pos, const y: Pos = off: {
        var x: f64 = 0;
        var y: f64 = 0;
        native.getSurfaceTransform(&x, &y);
        // Slightly inset the corners if we're using CSDs
        if (csd) {
            x += 1;
            y += 1;
        }
        break :off .{ @intFromFloat(x), @intFromFloat(y) };
    };

    var width = @as(Pos, surface.getWidth());
    var height = @as(Pos, surface.getHeight());

    // Trim off the offsets. Be careful not to get negative.
    width -= x * 2;
    height -= y * 2;
    if (width <= 0 or height <= 0) return .empty;

    // Empirically determined.
    const are_corners_rounded = rounded: {
        // This cast should always succeed as all of our windows
        // should be toplevel. If this fails, something very strange
        // is going on.
        const toplevel = gobject.ext.cast(
            gdk.Toplevel,
            surface,
        ) orelse break :rounded false;

        const state = toplevel.getState();
        if (state.fullscreen or state.maximized or state.tiled)
            break :rounded false;

        break :rounded csd;
    };

    const new_slices = try approxRoundedRect(
        alloc,
        x,
        y,
        width,
        height,
        // See https://gnome.pages.gitlab.gnome.org/libadwaita/doc/main/css-variables.html#window-radius
        if (are_corners_rounded) 15 else 0,
    );

    if (to_device_coordinates) {
        // Transform surface coordinates to device coordinates.
        const sf = surface.getScaleFactor();
        for (new_slices.items) |*s| {
            s.x *= sf;
            s.y *= sf;
            s.width *= sf;
            s.height *= sf;
        }
    }

    return .{ .slices = new_slices };
}

/// Whether two sets of blur regions are equal.
pub fn eql(self: BlurRegion, other: BlurRegion) bool {
    if (self.slices.items.len != other.slices.items.len) return false;
    for (self.slices.items, other.slices.items) |this, that| {
        if (!std.meta.eql(this, that)) return false;
    }
    return true;
}

/// Approximate a rounded rectangle with many smaller rectangles.
fn approxRoundedRect(
    alloc: Allocator,
    x: Pos,
    y: Pos,
    width: Pos,
    height: Pos,
    radius: Pos,
) Allocator.Error!std.ArrayList(Slice) {
    const r_f: f32 = @floatFromInt(radius);

    var slices: std.ArrayList(Slice) = .empty;
    errdefer slices.deinit(alloc);

    // Add the central rectangle
    try slices.append(alloc, .{
        .x = x,
        .y = y + radius,
        .width = width,
        .height = height - 2 * radius,
    });

    // Add the corner rows. This is honestly quite cursed.
    var row: Pos = 0;
    while (row < radius) : (row += 1) {
        // y distance from this row to the center corner circle
        const dy = @as(f32, @floatFromInt(radius - row)) - 0.5;

        // x distance - as given by the definition of a circle
        const dx = @sqrt(r_f * r_f - dy * dy);

        // How much each row should be offset, rounded to an integer
        const row_x: Pos = @intFromFloat(r_f - @round(dx + 0.5));

        // Remove the offset from both ends
        const row_w = width - 2 * row_x;

        // Top slice
        try slices.append(alloc, .{
            .x = x + row_x,
            .y = y + row,
            .width = row_w,
            .height = 1,
        });

        // Bottom slice
        try slices.append(alloc, .{
            .x = x + row_x,
            .y = y + height - 1 - row,
            .width = row_w,
            .height = 1,
        });
    }

    return slices;
}
