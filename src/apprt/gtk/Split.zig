/// Split represents a surface split where two surfaces are shown side-by-side
/// within the same window either vertically or horizontally.
const Split = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const gobject = @import("gobject");
const gtk = @import("gtk");

const apprt = @import("../../apprt.zig");
const font = @import("../../font/main.zig");
const CoreSurface = @import("../../Surface.zig");

const Surface = @import("Surface.zig");
const Tab = @import("Tab.zig");

const log = std.log.scoped(.gtk);

/// The split orientation.
pub const Orientation = enum {
    horizontal,
    vertical,

    pub fn fromDirection(direction: apprt.action.SplitDirection) Orientation {
        return switch (direction) {
            .right, .left => .horizontal,
            .down, .up => .vertical,
        };
    }

    pub fn fromResizeDirection(direction: apprt.action.ResizeSplit.Direction) Orientation {
        return switch (direction) {
            .up, .down => .vertical,
            .left, .right => .horizontal,
        };
    }
};

/// Our actual GtkPaned widget
paned: *gtk.Paned,

/// The container for this split panel.
container: Surface.Container,

/// The orientation of this split panel.
orientation: Orientation,

/// The elements of this split panel.
top_left: Surface.Container.Elem,
bottom_right: Surface.Container.Elem,

/// Create a new split panel with the given sibling surface in the given
/// direction. The direction is where the new surface will be initialized.
///
/// The sibling surface can be in a split already or it can be within a
/// tab. This properly handles updating the surface container so that
/// it represents the new split.
pub fn create(
    alloc: Allocator,
    sibling: *Surface,
    direction: apprt.action.SplitDirection,
) !*Split {
    var split = try alloc.create(Split);
    errdefer alloc.destroy(split);
    try split.init(sibling, direction);
    return split;
}

pub fn init(
    self: *Split,
    sibling: *Surface,
    direction: apprt.action.SplitDirection,
) !void {
    // If our sibling is too small to be split in half then we don't
    // allow the split to happen. This avoids a situation where the
    // split becomes too small.
    //
    // This is kind of a hack. Ideally we'd use gtk_widget_set_size_request
    // properly along the path to ensure minimum sizes. I don't know if
    // GTK even respects that all but any way GTK does this for us seems
    // better than this.
    {
        // This is the min size of the sibling split. This means the
        // smallest split is half of this.
        const multiplier = 4;

        const size = &sibling.core_surface.size;
        const small = switch (direction) {
            .right, .left => size.screen.width < size.cell.width * multiplier,
            .down, .up => size.screen.height < size.cell.height * multiplier,
        };
        if (small) return error.SplitTooSmall;
    }

    // Create the new child surface for the other direction.
    const alloc = sibling.app.core_app.alloc;
    var surface = try Surface.create(alloc, sibling.app, .{
        .parent = &sibling.core_surface,
    });
    errdefer surface.destroy(alloc);
    sibling.dimSurface();
    sibling.setSplitZoom(false);

    // Create the actual GTKPaned, attach the proper children.
    const orientation: gtk.Orientation = switch (direction) {
        .right, .left => .horizontal,
        .down, .up => .vertical,
    };
    const paned = gtk.Paned.new(orientation);
    errdefer paned.unref();

    // Keep a long-lived reference, which we unref in destroy.
    paned.ref();

    // Update all of our containers to point to the right place.
    // The split has to point to where the sibling pointed to because
    // we're inheriting its parent. The sibling points to its location
    // in the split, and the surface points to the other location.
    const container = sibling.container;
    const tl: *Surface, const br: *Surface = switch (direction) {
        .right, .down => right_down: {
            sibling.container = .{ .split_tl = &self.top_left };
            surface.container = .{ .split_br = &self.bottom_right };
            break :right_down .{ sibling, surface };
        },

        .left, .up => left_up: {
            sibling.container = .{ .split_br = &self.bottom_right };
            surface.container = .{ .split_tl = &self.top_left };
            break :left_up .{ surface, sibling };
        },
    };

    self.* = .{
        .paned = paned,
        .container = container,
        .top_left = .{ .surface = tl },
        .bottom_right = .{ .surface = br },
        .orientation = .fromDirection(direction),
    };

    // Replace the previous containers element with our split. This allows a
    // non-split to become a split, a split to become a nested split, etc.
    container.replace(.{ .split = self });

    // Update our children so that our GL area is properly added to the paned.
    self.updateChildren();

    // The new surface should always grab focus
    surface.grabFocus();
}

pub fn destroy(self: *Split, alloc: Allocator) void {
    self.top_left.deinit(alloc);
    self.bottom_right.deinit(alloc);

    // Clean up our GTK reference. This will trigger all the destroy callbacks
    // that are necessary for the surfaces to clean up.
    self.paned.unref();

    alloc.destroy(self);
}

/// Remove the top left child.
pub fn removeTopLeft(self: *Split) void {
    self.removeChild(self.top_left, self.bottom_right);
}

/// Remove the top left child.
pub fn removeBottomRight(self: *Split) void {
    self.removeChild(self.bottom_right, self.top_left);
}

fn removeChild(
    self: *Split,
    remove: Surface.Container.Elem,
    keep: Surface.Container.Elem,
) void {
    const window = self.container.window() orelse return;
    const alloc = window.app.core_app.alloc;

    // Remove our children since we are going to no longer be a split anyways.
    // This prevents widgets with multiple parents.
    self.removeChildren();

    // Our container must become whatever our top left is
    self.container.replace(keep);

    // Grab focus of the left-over side
    keep.grabFocus();

    // When a child is removed we are no longer a split, so destroy ourself
    remove.deinit(alloc);
    alloc.destroy(self);
}

/// Move the divider in the given direction by the given amount.
pub fn moveDivider(
    self: *Split,
    direction: apprt.action.ResizeSplit.Direction,
    amount: u16,
) void {
    const min_pos = 10;

    const pos = self.paned.getPosition();
    const new = switch (direction) {
        .up, .left => @max(pos - amount, min_pos),
        .down, .right => new_pos: {
            const max_pos: u16 = @as(u16, @intFromFloat(self.maxPosition())) - min_pos;
            break :new_pos @min(pos + amount, max_pos);
        },
    };

    self.paned.setPosition(new);
}

/// Equalize the splits in this split panel. Each split is equalized based on
/// its weight, i.e. the number of Surfaces it contains.
///
/// It works recursively by equalizing the children of each split.
///
/// It returns this split's weight.
pub fn equalize(self: *Split) f64 {
    // Calculate weights of top_left/bottom_right
    const top_left_weight = self.top_left.equalize();
    const bottom_right_weight = self.bottom_right.equalize();
    const weight = top_left_weight + bottom_right_weight;

    // Ratio of top_left weight to overall weight, which gives the split ratio
    const ratio = top_left_weight / weight;

    // Convert split ratio into new position for divider
    self.paned.setPosition(@intFromFloat(self.maxPosition() * ratio));

    return weight;
}

// maxPosition returns the maximum position of the GtkPaned, which is the
// "max-position" attribute.
fn maxPosition(self: *Split) f64 {
    var value: gobject.Value = std.mem.zeroes(gobject.Value);
    defer value.unset();

    _ = value.init(gobject.ext.types.int);
    self.paned.as(gobject.Object).getProperty(
        "max-position",
        &value,
    );

    return @floatFromInt(value.getInt());
}

// This replaces the element at the given pointer with a new element.
// The ptr must be either top_left or bottom_right (asserted in debug).
// The memory of the old element must be freed or otherwise handled by
// the caller.
pub fn replace(
    self: *Split,
    ptr: *Surface.Container.Elem,
    new: Surface.Container.Elem,
) void {
    // We can write our element directly. There's nothing special.
    assert(&self.top_left == ptr or &self.bottom_right == ptr);
    ptr.* = new;

    // Update our paned children. This will reset the divider
    // position but we want to keep it in place so save and restore it.
    const pos = self.paned.getPosition();
    defer self.paned.setPosition(pos);
    self.updateChildren();
}

// grabFocus grabs the focus of the top-left element.
pub fn grabFocus(self: *Split) void {
    self.top_left.grabFocus();
}

/// Update the paned children to represent the current state.
/// This should be called anytime the top/left or bottom/right
/// element is changed.
pub fn updateChildren(self: *const Split) void {
    // We have to set both to null. If we overwrite the pane with
    // the same value, then GTK bugs out (the GL area unrealizes
    // and never rerealizes).
    self.removeChildren();

    // Set our current children
    self.paned.setStartChild(self.top_left.widget());
    self.paned.setEndChild(self.bottom_right.widget());
}

/// A mapping of direction to the element (if any) in that direction.
pub const DirectionMap = std.EnumMap(
    apprt.action.GotoSplit,
    ?*Surface,
);

pub const Side = enum { top_left, bottom_right };

/// Returns the map that can be used to determine elements in various
/// directions (primarily for gotoSplit).
pub fn directionMap(self: *const Split, from: Side) DirectionMap {
    var result = DirectionMap.initFull(null);

    if (self.directionPrevious(from)) |prev| {
        result.put(.previous, prev.surface);
        if (!prev.wrapped) {
            result.put(.up, prev.surface);
        }
    }

    if (self.directionNext(from)) |next| {
        result.put(.next, next.surface);
        if (!next.wrapped) {
            result.put(.down, next.surface);
        }
    }

    if (self.directionLeft(from)) |left| {
        result.put(.left, left);
    }

    if (self.directionRight(from)) |right| {
        result.put(.right, right);
    }

    return result;
}

fn directionLeft(self: *const Split, from: Side) ?*Surface {
    switch (from) {
        .bottom_right => {
            switch (self.orientation) {
                .horizontal => return self.top_left.deepestSurface(.bottom_right),
                .vertical => return directionLeft(
                    self.container.split() orelse return null,
                    .bottom_right,
                ),
            }
        },
        .top_left => return directionLeft(
            self.container.split() orelse return null,
            .bottom_right,
        ),
    }
}

fn directionRight(self: *const Split, from: Side) ?*Surface {
    switch (from) {
        .top_left => {
            switch (self.orientation) {
                .horizontal => return self.bottom_right.deepestSurface(.top_left),
                .vertical => return directionRight(
                    self.container.split() orelse return null,
                    .top_left,
                ),
            }
        },
        .bottom_right => return directionRight(
            self.container.split() orelse return null,
            .top_left,
        ),
    }
}

fn directionPrevious(self: *const Split, from: Side) ?struct {
    surface: *Surface,
    wrapped: bool,
} {
    switch (from) {
        // From the bottom right, our previous is the deepest surface
        // in the top-left of our own split.
        .bottom_right => return .{
            .surface = self.top_left.deepestSurface(.bottom_right) orelse return null,
            .wrapped = false,
        },

        // From the top left its more complicated. It is the de
        .top_left => {
            // If we have no parent split then there can be no unwrapped prev.
            // We can still have a wrapped previous.
            const parent = self.container.split() orelse return .{
                .surface = self.bottom_right.deepestSurface(.bottom_right) orelse return null,
                .wrapped = true,
            };

            // The previous value is the previous of the side that we are.
            const side = self.container.splitSide() orelse return null;
            return switch (side) {
                .top_left => parent.directionPrevious(.top_left),
                .bottom_right => parent.directionPrevious(.bottom_right),
            };
        },
    }
}

fn directionNext(self: *const Split, from: Side) ?struct {
    surface: *Surface,
    wrapped: bool,
} {
    switch (from) {
        // From the top left, our next is the earliest surface in the
        // top-left direction of the bottom-right side of our split. Fun!
        .top_left => return .{
            .surface = self.bottom_right.deepestSurface(.top_left) orelse return null,
            .wrapped = false,
        },

        // From the bottom right is more compliated. It is the deepest
        // (last) surface in the
        .bottom_right => {
            // If we have no parent split then there can be no next.
            const parent = self.container.split() orelse return .{
                .surface = self.top_left.deepestSurface(.top_left) orelse return null,
                .wrapped = true,
            };

            // The previous value is the previous of the side that we are.
            const side = self.container.splitSide() orelse return null;
            return switch (side) {
                .top_left => parent.directionNext(.top_left),
                .bottom_right => parent.directionNext(.bottom_right),
            };
        },
    }
}

pub fn detachTopLeft(self: *const Split) void {
    self.paned.setStartChild(null);
}

pub fn detachBottomRight(self: *const Split) void {
    self.paned.setEndChild(null);
}

fn removeChildren(self: *const Split) void {
    self.detachTopLeft();
    self.detachBottomRight();
}
