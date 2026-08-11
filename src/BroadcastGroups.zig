//! Manages "broadcast input" groups: sets of terminal surfaces that all
//! receive the keyboard input typed into any one of them, similar to
//! iTerm2's broadcast input and tmux's synchronized panes.
//!
//! This is pure group bookkeeping; the App owns an instance and layers
//! the user-facing behavior on top: input replication, click and
//! keybinding toggles, and notifying apprts of membership changes so
//! they can draw the group border colors.
//!
//! Multiple groups can exist at once and each group is assigned a
//! distinct border color (see `broadcast-group-colors`) so its members
//! are visually identifiable. The number of configured colors bounds the
//! number of groups, which is why the mutating functions take a
//! `max_groups` argument: each group owns one color.
//!
//! Surfaces are tracked by their core surface ID so that this structure
//! never holds a pointer that could dangle; members are removed explicitly
//! when a surface is destroyed.
const BroadcastGroups = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Group = struct {
    /// The number of this group, which doubles as its color index into
    /// the `broadcast-group-colors` list. Always less than the
    /// `max_groups` it was created with. Click-created groups take the
    /// lowest number unused by any other group; the keyboard shortcut
    /// addresses groups by this number directly.
    color: u8,

    /// The core surface IDs of the group members.
    members: std.ArrayListUnmanaged(u64) = .empty,
};

groups: std.ArrayListUnmanaged(Group) = .empty,

pub const empty: BroadcastGroups = .{};

pub fn deinit(self: *BroadcastGroups, alloc: Allocator) void {
    for (self.groups.items) |*group| group.members.deinit(alloc);
    self.groups.deinit(alloc);
}

/// Toggle the given surface's group membership: a surface already in a
/// group is removed from it (empty groups dissolve); otherwise, if the
/// focused surface is in a group then the given surface joins that group;
/// otherwise a new group is created containing only the given surface.
/// If `max_groups` groups already exist, no new group is created and
/// this is a no-op.
pub fn toggle(
    self: *BroadcastGroups,
    alloc: Allocator,
    id: u64,
    focused_id: ?u64,
    max_groups: u8,
) Allocator.Error!void {
    // Already a member somewhere: remove.
    if (self.groupIndex(id)) |idx| {
        self.removeFromGroup(alloc, idx, id);
        return;
    }

    // If the focused surface is in a group, join that group.
    if (focused_id) |focused| {
        if (self.groupIndex(focused)) |idx| {
            try self.groups.items[idx].members.append(alloc, id);
            return;
        }
    }

    // Start a new group, unless every group number is already taken.
    const color = self.nextColor(max_groups) orelse return;
    var group: Group = .{ .color = color };
    errdefer group.members.deinit(alloc);
    try group.members.append(alloc, id);
    try self.groups.append(alloc, group);
}

/// Toggle the given surface's membership in the group with the given
/// number, creating the group if it doesn't exist yet. A surface already
/// in a different group is moved; a surface already in that exact group
/// is removed from it instead. The number must be less than `max_groups`.
pub fn toggleNumbered(
    self: *BroadcastGroups,
    alloc: Allocator,
    id: u64,
    number: u8,
    max_groups: u8,
) Allocator.Error!void {
    std.debug.assert(number < max_groups);

    // Leave the current group, if any. If it was the requested group
    // then this is a toggle off and we're done.
    if (self.groupIndex(id)) |idx| {
        const current = self.groups.items[idx].color;
        self.removeFromGroup(alloc, idx, id);
        if (current == number) return;
    }

    // Join the requested group, creating it if needed. Note that
    // removeFromGroup above may have reordered `groups` so we search
    // by number only now.
    const idx = self.groupIndexByColor(number) orelse idx: {
        try self.groups.append(alloc, .{ .color = number });
        break :idx self.groups.items.len - 1;
    };
    try self.groups.items[idx].members.append(alloc, id);
}

/// Remove the given surface from its group, if any. Called when a
/// surface is destroyed.
pub fn remove(self: *BroadcastGroups, alloc: Allocator, id: u64) void {
    const idx = self.groupIndex(id) orelse return;
    self.removeFromGroup(alloc, idx, id);
}

/// Dissolve all groups, removing every member.
pub fn clear(self: *BroadcastGroups, alloc: Allocator) void {
    for (self.groups.items) |*group| group.members.deinit(alloc);
    self.groups.clearRetainingCapacity();
}

/// The color assigned to the given surface's group, or null if the
/// surface is not in any group.
pub fn colorOf(self: *const BroadcastGroups, id: u64) ?u8 {
    const idx = self.groupIndex(id) orelse return null;
    return self.groups.items[idx].color;
}

/// All members of the given surface's group (including the surface
/// itself), or null if the surface is not in any group. The returned
/// slice is invalidated by any mutation of this structure.
pub fn members(self: *const BroadcastGroups, id: u64) ?[]const u64 {
    const idx = self.groupIndex(id) orelse return null;
    return self.groups.items[idx].members.items;
}

fn groupIndexByColor(self: *const BroadcastGroups, color: u8) ?usize {
    for (self.groups.items, 0..) |group, i| {
        if (group.color == color) return i;
    }

    return null;
}

fn groupIndex(self: *const BroadcastGroups, id: u64) ?usize {
    for (self.groups.items, 0..) |group, i| {
        for (group.members.items) |member| {
            if (member == id) return i;
        }
    }

    return null;
}

fn removeFromGroup(
    self: *BroadcastGroups,
    alloc: Allocator,
    idx: usize,
    id: u64,
) void {
    const group = &self.groups.items[idx];
    for (group.members.items, 0..) |member, i| {
        if (member == id) {
            _ = group.members.swapRemove(i);
            break;
        }
    }

    // Dissolve empty groups so their color becomes available again.
    if (group.members.items.len == 0) {
        group.members.deinit(alloc);
        _ = self.groups.swapRemove(idx);
    }
}

/// The lowest group number not used by any existing group, or null if
/// all `max_groups` numbers are taken.
fn nextColor(self: *const BroadcastGroups, max_groups: u8) ?u8 {
    var candidate: u8 = 0;
    while (candidate < max_groups) : (candidate += 1) {
        if (self.groupIndexByColor(candidate) == null) return candidate;
    }

    return null;
}

test "toggle creates, joins, and removes" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const max_groups = 10;

    var groups: BroadcastGroups = .empty;
    defer groups.deinit(alloc);

    // New group with the clicked surface.
    try groups.toggle(alloc, 1, null, max_groups);
    try testing.expectEqual(@as(?u8, 0), groups.colorOf(1));

    // Focused surface in a group: join it.
    try groups.toggle(alloc, 2, 1, max_groups);
    try testing.expectEqual(@as(?u8, 0), groups.colorOf(2));
    try testing.expectEqual(@as(usize, 2), groups.members(1).?.len);

    // Focused surface not in a group: new group with a new color.
    try groups.toggle(alloc, 3, null, max_groups);
    try testing.expectEqual(@as(?u8, 1), groups.colorOf(3));

    // Toggling a member removes it.
    try groups.toggle(alloc, 2, 1, max_groups);
    try testing.expectEqual(@as(?u8, null), groups.colorOf(2));

    // Removing the last member dissolves the group and frees its color.
    try groups.toggle(alloc, 1, null, max_groups);
    try testing.expectEqual(@as(?u8, null), groups.colorOf(1));
    try groups.toggle(alloc, 4, null, max_groups);
    try testing.expectEqual(@as(?u8, 0), groups.colorOf(4));
}

test "toggle refuses to create more than max_groups groups" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const max_groups = 10;

    var groups: BroadcastGroups = .empty;
    defer groups.deinit(alloc);

    // Fill every group number with a single-member group.
    var id: u64 = 1;
    while (id <= max_groups) : (id += 1) {
        try groups.toggle(alloc, id, null, max_groups);
        try testing.expectEqual(@as(?u8, @intCast(id - 1)), groups.colorOf(id));
    }

    // The next toggle would need an eleventh group: it must be a no-op.
    try groups.toggle(alloc, 99, null, max_groups);
    try testing.expectEqual(@as(?u8, null), groups.colorOf(99));

    // Joining an existing group is still allowed while full.
    try groups.toggle(alloc, 99, 1, max_groups);
    try testing.expectEqual(@as(?u8, 0), groups.colorOf(99));
}

test "toggleNumbered creates, moves, and toggles" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const max_groups = 10;

    var groups: BroadcastGroups = .empty;
    defer groups.deinit(alloc);

    // Toggling a group that doesn't exist creates it with that number.
    try groups.toggleNumbered(alloc, 1, 4, max_groups);
    try testing.expectEqual(@as(?u8, 4), groups.colorOf(1));

    // Another surface joins the same group.
    try groups.toggleNumbered(alloc, 2, 4, max_groups);
    try testing.expectEqual(@as(?u8, 4), groups.colorOf(2));
    try testing.expectEqual(@as(usize, 2), groups.members(1).?.len);

    // Toggling into a different group moves the surface.
    try groups.toggleNumbered(alloc, 2, 7, max_groups);
    try testing.expectEqual(@as(?u8, 7), groups.colorOf(2));
    try testing.expectEqual(@as(usize, 1), groups.members(1).?.len);

    // Toggling the surface's current group removes it, and the emptied
    // group dissolves so its number is free again.
    try groups.toggleNumbered(alloc, 2, 7, max_groups);
    try testing.expectEqual(@as(?u8, null), groups.colorOf(2));
    try groups.toggle(alloc, 3, null, max_groups);
    try testing.expectEqual(@as(?u8, 0), groups.colorOf(3));

    // The highest valid group number works.
    try groups.toggleNumbered(alloc, 5, max_groups - 1, max_groups);
    try testing.expectEqual(@as(?u8, max_groups - 1), groups.colorOf(5));
}

test "remove" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const max_groups = 10;

    var groups: BroadcastGroups = .empty;
    defer groups.deinit(alloc);

    try groups.toggle(alloc, 1, null, max_groups);
    try groups.toggle(alloc, 2, 1, max_groups);
    groups.remove(alloc, 1);
    try testing.expectEqual(@as(?u8, null), groups.colorOf(1));
    try testing.expectEqual(@as(?u8, 0), groups.colorOf(2));

    // Removing a surface that isn't in a group is a no-op.
    groups.remove(alloc, 99);
}

test "clear" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const max_groups = 10;

    var groups: BroadcastGroups = .empty;
    defer groups.deinit(alloc);

    try groups.toggle(alloc, 1, null, max_groups);
    try groups.toggle(alloc, 2, 1, max_groups);
    try groups.toggleNumbered(alloc, 3, 5, max_groups);
    groups.clear(alloc);
    try testing.expectEqual(@as(?u8, null), groups.colorOf(1));
    try testing.expectEqual(@as(?u8, null), groups.colorOf(2));
    try testing.expectEqual(@as(?u8, null), groups.colorOf(3));

    // Cleared groups free their colors.
    try groups.toggle(alloc, 4, null, max_groups);
    try testing.expectEqual(@as(?u8, 0), groups.colorOf(4));
}
