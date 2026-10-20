const std = @import("std");
const assert = std.debug.assert;
const UndoHistory = @This();

entries: [2]std.DoublyLinkedList = .{ .{}, .{} },
sequence: u64 = 0,
group: ?u64 = null,
depth: usize = 0,

pub const Direction = enum { undo, redo };

pub const Entry = struct {
    node: std.DoublyLinkedList.Node = .{},
    direction: Direction = .undo,
    group: u64 = 0,
};

pub fn append(self: *UndoHistory, entry: *Entry, direction: Direction) void {
    entry.direction = direction;
    entry.group = self.group orelse self.nextGroup();
    self.entries[@intFromEnum(direction)].append(&entry.node);
}

pub fn last(self: *const UndoHistory, direction: Direction) ?*Entry {
    const node = self.entries[@intFromEnum(direction)].last orelse return null;
    return @fieldParentPtr("node", node);
}

pub fn pop(self: *UndoHistory, direction: Direction) ?*Entry {
    const entry = self.last(direction) orelse return null;
    self.remove(entry);
    return entry;
}

pub fn remove(self: *UndoHistory, entry: *Entry) void {
    self.entries[@intFromEnum(entry.direction)].remove(&entry.node);
}

pub fn isEmpty(self: *const UndoHistory) bool {
    return self.last(.undo) == null and self.last(.redo) == null;
}

pub fn beginGroup(self: *UndoHistory) void {
    if (self.depth == 0) self.group = self.nextGroup();
    self.depth += 1;
}

pub fn endGroup(self: *UndoHistory) void {
    assert(self.depth > 0);
    self.depth -= 1;
    if (self.depth == 0) self.group = null;
}

fn nextGroup(self: *UndoHistory) u64 {
    self.sequence += 1;
    return self.sequence;
}

test "UndoHistory records independent actions" {
    const testing = std.testing;
    var history: UndoHistory = .{};
    var first: Entry = .{};
    var second: Entry = .{};
    history.append(&first, .undo);
    history.append(&second, .undo);
    try testing.expect(first.group != second.group);
    try testing.expectEqual(&second, history.pop(.undo));
    try testing.expectEqual(&first, history.pop(.undo));
    try testing.expect(history.isEmpty());
}

test "UndoHistory nested groups preserve operation order" {
    const testing = std.testing;
    var history: UndoHistory = .{};
    var entries: [3]Entry = @splat(.{});
    history.beginGroup();
    history.append(&entries[0], .undo);
    history.beginGroup();
    history.append(&entries[1], .undo);
    history.endGroup();
    history.append(&entries[2], .undo);
    history.endGroup();
    for (&entries) |*entry| try testing.expectEqual(entries[0].group, entry.group);
    const original_group = entries[0].group;
    history.beginGroup();
    while (history.pop(.undo)) |entry| history.append(entry, .redo);
    history.endGroup();
    try testing.expect(entries[0].group != original_group);
    for (&entries) |*entry| {
        try testing.expectEqual(entries[0].group, entry.group);
        try testing.expectEqual(entry, history.pop(.redo));
    }
    try testing.expect(history.isEmpty());
}

test "UndoHistory empty groups leave no history" {
    const testing = std.testing;
    var history: UndoHistory = .{};
    history.beginGroup();
    history.beginGroup();
    history.endGroup();
    history.endGroup();
    try testing.expect(history.isEmpty());
    var first: Entry = .{};
    var second: Entry = .{};
    history.append(&first, .undo);
    history.append(&second, .undo);
    try testing.expect(first.group != second.group);
}

test "UndoHistory expiration preserves both stacks" {
    const testing = std.testing;
    for ([_]Direction{ .undo, .redo }) |direction| {
        var history: UndoHistory = .{};
        var entries: [3]Entry = @splat(.{});
        for (&entries) |*entry| history.append(entry, direction);
        var other: Entry = .{};
        const opposite: Direction = if (direction == .undo) .redo else .undo;
        history.append(&other, opposite);
        history.remove(&entries[1]);
        try testing.expectEqual(&entries[2], history.pop(direction));
        try testing.expectEqual(&entries[0], history.pop(direction));
        try testing.expect(!history.isEmpty());
        try testing.expectEqual(&other, history.pop(opposite));
        try testing.expect(history.isEmpty());
    }
}
