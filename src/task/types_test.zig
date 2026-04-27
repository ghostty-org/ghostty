const std = @import("std");
const types = @import("types.zig");

test "CardStatus enum has all four states" {
    const info = @typeInfo(types.CardStatus);
    switch (info) {
        .@"enum" => |e| try std.testing.expectEqual(@as(u8, 4), e.fields.len),
        else => unreachable,
    }
    try std.testing.expectEqual(types.CardStatus.todo, types.CardStatus.todo);
    try std.testing.expectEqual(types.CardStatus.in_progress, types.CardStatus.in_progress);
    try std.testing.expectEqual(types.CardStatus.review, types.CardStatus.review);
    try std.testing.expectEqual(types.CardStatus.done, types.CardStatus.done);
}

test "Priority enum ordered correctly" {
    try std.testing.expectEqual(@as(u2, 0), @intFromEnum(types.Priority.p0));
    try std.testing.expectEqual(@as(u2, 1), @intFromEnum(types.Priority.p1));
    try std.testing.expectEqual(@as(u2, 2), @intFromEnum(types.Priority.p2));
    try std.testing.expectEqual(@as(u2, 3), @intFromEnum(types.Priority.p3));
}

test "Session struct fields" {
    const session = types.Session{
        .id = "s1",
        .name = "Test Session",
        .cwd = "/tmp",
        .command = "echo hello",
        .split_id = null,
        .is_worktree = false,
        .worktree_name = null,
    };
    try std.testing.expectEqualStrings("s1", session.id);
    try std.testing.expectEqualStrings("Test Session", session.name);
    try std.testing.expectEqualStrings("/tmp", session.cwd);
    try std.testing.expectEqualStrings("echo hello", session.command);
    try std.testing.expectEqual(false, session.is_worktree);
}

test "Card struct with sessions" {
    const session = types.Session{
        .id = "s1",
        .name = "Session 1",
        .cwd = "/home",
        .command = "ls",
        .split_id = null,
        .is_worktree = false,
        .worktree_name = null,
    };
    const card = types.Card{
        .id = "c1",
        .title = "My Task",
        .description = "Description here",
        .status = .todo,
        .priority = .p1,
        .sessions = &.{session},
    };
    try std.testing.expectEqualStrings("c1", card.id);
    try std.testing.expectEqualStrings("My Task", card.title);
    try std.testing.expectEqual(types.CardStatus.todo, card.status);
    try std.testing.expectEqual(types.Priority.p1, card.priority);
    try std.testing.expectEqual(@as(usize, 1), card.sessions.len);
}

test "Project struct with cards" {
    const card = types.Card{
        .id = "c1",
        .title = "Task 1",
        .description = "",
        .status = .todo,
        .priority = .p2,
        .sessions = &.{},
    };
    const project = types.Project{
        .id = "p1",
        .name = "My Project",
        .cards = &.{card},
    };
    try std.testing.expectEqualStrings("p1", project.id);
    try std.testing.expectEqualStrings("My Project", project.name);
    try std.testing.expectEqual(@as(usize, 1), project.cards.len);
}
