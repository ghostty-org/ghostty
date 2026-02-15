//! Protocol-independent utilities used to implement background blur.
const std = @import("std");
const Allocator = std.mem.Allocator;

const gtk = @import("gtk");

pub const Region = struct {
    slices: std.ArrayList(Slice),

    /// A rectangular slice of the blur region.
    // Marked `extern` since we want to be able to use this in X11 directly,
    // and we use `c_long`s as, while XLib *says* they should be 32 bit integers,
    // in actuality they are architecture-dependent. I love legacy cruft
    pub const Slice = extern struct {
        x: c_long,
        y: c_long,
        width: c_long,
        height: c_long,
    };

    pub const empty: Region = .{
        .slices = .empty,
    };

    pub fn clear(self: *Region) void {
        self.slices.clearRetainingCapacity();
    }

    pub fn deinit(self: *Region, alloc: std.mem.Allocator) void {
        self.slices.deinit(alloc);
    }

    // Calculate the blur regions for a window.
    //
    // Since we have rounded corners by default, we need to carve out the
    // pixels on each corner to avoid the "korners bug".
    // (cf. https://github.com/cutefishos/fishui/blob/41d4ba194063a3c7fff4675619b57e6ac0504f06/src/platforms/linux/blurhelper/windowblur.cpp#L134)
    pub fn calcForWindow(alloc: Allocator, window: *gtk.Window) Allocator.Error!Region {
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
        var x: f64 = 0;
        var y: f64 = 0;
        native.getSurfaceTransform(&x, &y);

        var width: f64 = @floatFromInt(surface.getWidth());
        var height: f64 = @floatFromInt(surface.getHeight());

        // Trim off the offsets. Be careful not to get negative.
        width = @max(0, width - x * 2);
        height = @max(0, height - y * 2);

        // Transform surface coordinates to device coordinates.
        const scale: f64 = @floatFromInt(surface.getScaleFactor());

        // TODO: Add more regions to mitigate the "korners bug".
        try slices.append(alloc, .{
            .x = @intFromFloat(x * scale),
            .y = @intFromFloat(y * scale),
            .width = @intFromFloat(width * scale),
            .height = @intFromFloat(height * scale),
        });

        return .{
            .slices = slices,
        };
    }

    /// Whether two sets of blur regions are equal.
    pub fn eql(self: Region, other: Region) bool {
        if (self.slices.items.len != other.slices.items.len) return false;
        for (self.slices.items, other.slices.items) |this, that| {
            if (!std.meta.eql(this, that)) return false;
        }
        return true;
    }
};
