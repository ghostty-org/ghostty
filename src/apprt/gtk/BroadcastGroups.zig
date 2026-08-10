//! Manages "broadcast input" groups: sets of terminal surfaces that all
//! receive the keyboard input typed into any one of them, similar to
//! iTerm2's broadcast input and tmux's synchronized panes.
//!
//! Surfaces are toggled in and out of groups with ctrl+shift+click.
//! Multiple groups can exist at once and each group is assigned a distinct
//! border color so its members are visually identifiable.
//!
//! Surfaces are tracked by their core surface ID so that this structure
//! never holds a pointer that could dangle; members are removed explicitly
//! when a surface is destroyed.
const BroadcastGroups = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The number of distinct border colors available for groups. This must
/// match the number of `broadcast-color-N` CSS classes defined in
/// css/style.css. Groups beyond this count cycle through the colors again.
pub const color_count = 6;

const Group = struct {
    /// The color assigned to this group. This is the lowest value unused
    /// by any other group at creation time; apply `% color_count` to get
    /// the CSS palette index.
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
pub fn toggle(
    self: *BroadcastGroups,
    alloc: Allocator,
    id: u64,
    focused_id: ?u64,
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

    // Start a new group.
    var group: Group = .{ .color = self.nextColor() };
    errdefer group.members.deinit(alloc);
    try group.members.append(alloc, id);
    try self.groups.append(alloc, group);
}

/// Remove the given surface from its group, if any. Called when a
/// surface is destroyed.
pub fn remove(self: *BroadcastGroups, alloc: Allocator, id: u64) void {
    const idx = self.groupIndex(id) orelse return;
    self.removeFromGroup(alloc, idx, id);
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

/// The lowest color value not used by any existing group.
fn nextColor(self: *const BroadcastGroups) u8 {
    var candidate: u8 = 0;
    while (candidate < std.math.maxInt(u8)) : (candidate += 1) {
        for (self.groups.items) |group| {
            if (group.color == candidate) break;
        } else return candidate;
    }

    return candidate;
}

test "toggle creates, joins, and removes" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var groups: BroadcastGroups = .empty;
    defer groups.deinit(alloc);

    // New group with the clicked surface.
    try groups.toggle(alloc, 1, null);
    try testing.expectEqual(@as(?u8, 0), groups.colorOf(1));

    // Focused surface in a group: join it.
    try groups.toggle(alloc, 2, 1);
    try testing.expectEqual(@as(?u8, 0), groups.colorOf(2));
    try testing.expectEqual(@as(usize, 2), groups.members(1).?.len);

    // Focused surface not in a group: new group with a new color.
    try groups.toggle(alloc, 3, null);
    try testing.expectEqual(@as(?u8, 1), groups.colorOf(3));

    // Toggling a member removes it.
    try groups.toggle(alloc, 2, 1);
    try testing.expectEqual(@as(?u8, null), groups.colorOf(2));

    // Removing the last member dissolves the group and frees its color.
    try groups.toggle(alloc, 1, null);
    try testing.expectEqual(@as(?u8, null), groups.colorOf(1));
    try groups.toggle(alloc, 4, null);
    try testing.expectEqual(@as(?u8, 0), groups.colorOf(4));
}

test "remove" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var groups: BroadcastGroups = .empty;
    defer groups.deinit(alloc);

    try groups.toggle(alloc, 1, null);
    try groups.toggle(alloc, 2, 1);
    groups.remove(alloc, 1);
    try testing.expectEqual(@as(?u8, null), groups.colorOf(1));
    try testing.expectEqual(@as(?u8, 0), groups.colorOf(2));

    // Removing a surface that isn't in a group is a no-op.
    groups.remove(alloc, 99);
}
