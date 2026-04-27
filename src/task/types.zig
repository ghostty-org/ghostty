const std = @import("std");

pub const CardStatus = enum(u2) {
    todo = 0,
    in_progress = 1,
    review = 2,
    done = 3,
};

pub const Priority = enum(u2) {
    p0 = 0, // Critical
    p1 = 1, // High
    p2 = 2, // Medium
    p3 = 3, // Low
};

pub const Session = struct {
    id: []const u8,
    name: []const u8,
    cwd: []const u8,
    command: []const u8,
    split_id: ?[]const u8 = null,
    is_worktree: bool = false,
    worktree_name: ?[]const u8 = null,
};

pub const Card = struct {
    id: []const u8,
    title: []const u8,
    description: []const u8 = "",
    status: CardStatus = .todo,
    priority: Priority = .p2,
    sessions: []const Session = &.{},
};

pub const Project = struct {
    id: []const u8,
    name: []const u8,
    cards: []const Card = &.{},
};
