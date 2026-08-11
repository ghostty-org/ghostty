//! Manages "broadcast input" groups: sets of terminal surfaces that all
//! receive the keyboard input typed into any one of them, similar to
//! iTerm2's broadcast input and tmux's synchronized panes.
//!
//! Surfaces are toggled in and out of groups with ctrl+shift+click, or
//! join a specific numbered group with the `join_broadcast_group`
//! keybinding action (ctrl+shift+<digit> by default). Multiple groups can
//! exist at once and each group is assigned a distinct border color so
//! its members are visually identifiable. At most `max_groups` groups can
//! exist, one per palette color.
//!
//! Surfaces are tracked by their core surface ID so that this structure
//! never holds a pointer that could dangle; members are removed explicitly
//! when a surface is destroyed.
const BroadcastGroups = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The number of distinct border colors available for groups. This must
/// match the number of `broadcast-color-N` CSS classes defined in
/// css/style.css.
pub const color_count = 10;

/// The maximum number of groups that can exist at once. Each group owns
/// one palette color, so this is bounded by the palette size.
pub const max_groups = color_count;

const Group = struct {
    /// The number of this group, which doubles as its palette color
    /// index. Always less than `max_groups`. Click-created groups take
    /// the lowest number unused by any other group; the keyboard
    /// shortcut addresses groups by this number directly.
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
/// If all `max_groups` groups already exist, no new group is created and
/// this is a no-op.
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

    // Start a new group, unless every group number is already taken.
    const color = self.nextColor() orelse return;
    var group: Group = .{ .color = color };
    errdefer group.members.deinit(alloc);
    try group.members.append(alloc, id);
    try self.groups.append(alloc, group);
}

/// Add the given surface to the group with the given number, creating
/// the group if it doesn't exist yet. A surface already in a different
/// group is moved; a surface already in that exact group is removed
/// from it instead (toggle). The number must be less than `max_groups`.
pub fn join(
    self: *BroadcastGroups,
    alloc: Allocator,
    id: u64,
    number: u8,
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
fn nextColor(self: *const BroadcastGroups) ?u8 {
    var candidate: u8 = 0;
    while (candidate < max_groups) : (candidate += 1) {
        if (self.groupIndexByColor(candidate) == null) return candidate;
    }

    return null;
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

test "toggle refuses to create more than max_groups groups" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var groups: BroadcastGroups = .empty;
    defer groups.deinit(alloc);

    // Fill every group number with a single-member group.
    var id: u64 = 1;
    while (id <= max_groups) : (id += 1) {
        try groups.toggle(alloc, id, null);
        try testing.expectEqual(@as(?u8, @intCast(id - 1)), groups.colorOf(id));
    }

    // The next toggle would need an eleventh group: it must be a no-op.
    try groups.toggle(alloc, 99, null);
    try testing.expectEqual(@as(?u8, null), groups.colorOf(99));

    // Joining an existing group is still allowed while full.
    try groups.toggle(alloc, 99, 1);
    try testing.expectEqual(@as(?u8, 0), groups.colorOf(99));
}

test "join creates, moves, and toggles" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var groups: BroadcastGroups = .empty;
    defer groups.deinit(alloc);

    // Joining a group that doesn't exist creates it with that number.
    try groups.join(alloc, 1, 4);
    try testing.expectEqual(@as(?u8, 4), groups.colorOf(1));

    // Another surface joins the same group.
    try groups.join(alloc, 2, 4);
    try testing.expectEqual(@as(?u8, 4), groups.colorOf(2));
    try testing.expectEqual(@as(usize, 2), groups.members(1).?.len);

    // Joining a different group moves the surface.
    try groups.join(alloc, 2, 7);
    try testing.expectEqual(@as(?u8, 7), groups.colorOf(2));
    try testing.expectEqual(@as(usize, 1), groups.members(1).?.len);

    // Joining the surface's current group removes it (toggle off), and
    // the emptied group dissolves so its number is free again.
    try groups.join(alloc, 2, 7);
    try testing.expectEqual(@as(?u8, null), groups.colorOf(2));
    try groups.toggle(alloc, 3, null);
    try testing.expectEqual(@as(?u8, 0), groups.colorOf(3));

    // The highest valid group number works.
    try groups.join(alloc, 5, max_groups - 1);
    try testing.expectEqual(@as(?u8, max_groups - 1), groups.colorOf(5));
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
