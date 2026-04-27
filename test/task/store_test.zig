const std = @import("std");
const types = @import("../../../src/task/types.zig");
const store = @import("../../../src/task/store.zig");

test "load from non-existent file returns empty slice" {
    const loaded = store.load("non_existent_file_12345.json");
    defer std.heap.page_allocator.free(loaded);

    try std.testing.expectEqual(@as(usize, 0), loaded.len);
}

test "save and load roundtrip with sessions" {
    const session = types.Session{
        .id = "s1",
        .name = "Test Session",
        .cwd = "/tmp",
        .command = "echo hello",
        .split_id = null,
        .is_worktree = false,
        .worktree_name = null,
    };

    const card = types.Card{
        .id = "c1",
        .title = "Test Card",
        .description = "A test description",
        .status = .in_progress,
        .priority = .p1,
        .sessions = &.{session},
    };

    const project = types.Project{
        .id = "p1",
        .name = "Test Project",
        .cards = &.{card},
    };

    const path = "test_kanban_roundtrip.json";
    const io = store.getIo();
    const dir = std.Io.Dir.cwd();
    dir.deleteFile(io, path) catch {};

    try store.save(&.{project}, path);

    const loaded = try store.loadAlloc(path, std.heap.page_allocator);
    defer store.freeProjects(loaded, std.heap.page_allocator);

    try std.testing.expectEqual(@as(usize, 1), loaded.len);
    try std.testing.expectEqualStrings("p1", loaded[0].id);
    try std.testing.expectEqualStrings("Test Project", loaded[0].name);
    try std.testing.expectEqual(@as(usize, 1), loaded[0].cards.len);
    try std.testing.expectEqualStrings("c1", loaded[0].cards[0].id);
    try std.testing.expectEqualStrings("Test Card", loaded[0].cards[0].title);
    try std.testing.expectEqualStrings("A test description", loaded[0].cards[0].description);
    try std.testing.expectEqual(types.CardStatus.in_progress, loaded[0].cards[0].status);
    try std.testing.expectEqual(types.Priority.p1, loaded[0].cards[0].priority);
    try std.testing.expectEqual(@as(usize, 1), loaded[0].cards[0].sessions.len);
    try std.testing.expectEqualStrings("s1", loaded[0].cards[0].sessions[0].id);
    try std.testing.expectEqualStrings("Test Session", loaded[0].cards[0].sessions[0].name);
}

test "save and load empty projects" {
    const path = "test_kanban_empty.json";
    const io = store.getIo();
    const dir = std.Io.Dir.cwd();
    dir.deleteFile(io, path) catch {};

    try store.save(&.{}, path);

    const loaded = try store.loadAlloc(path, std.heap.page_allocator);
    defer store.freeProjects(loaded, std.heap.page_allocator);

    try std.testing.expectEqual(@as(usize, 0), loaded.len);
}

test "all card statuses serialize correctly" {
    inline for (.{
        types.CardStatus.todo,
        types.CardStatus.in_progress,
        types.CardStatus.review,
        types.CardStatus.done,
    }) |status| {
        const session = types.Session{
            .id = "s1",
            .name = "Test",
            .cwd = "/tmp",
            .command = "echo",
            .split_id = null,
            .is_worktree = false,
            .worktree_name = null,
        };
        const card = types.Card{
            .id = "c1",
            .title = "Test",
            .description = "",
            .status = status,
            .priority = .p2,
            .sessions = &.{session},
        };
        const project = types.Project{
            .id = "p1",
            .name = "Test",
            .cards = &.{card},
        };

        const path = "test_status.json";
        const io = store.getIo();
        const dir = std.Io.Dir.cwd();
        dir.deleteFile(io, path) catch {};

        try store.save(&.{project}, path);

        const loaded = try store.loadAlloc(path, std.heap.page_allocator);
        defer store.freeProjects(loaded, std.heap.page_allocator);

        try std.testing.expectEqual(status, loaded[0].cards[0].status);
    }
}

test "all priorities serialize correctly" {
    inline for (.{ types.Priority.p0, types.Priority.p1, types.Priority.p2, types.Priority.p3 }) |priority| {
        const card = types.Card{
            .id = "c1",
            .title = "Test",
            .description = "",
            .status = .todo,
            .priority = priority,
            .sessions = &.{},
        };
        const project = types.Project{
            .id = "p1",
            .name = "Test",
            .cards = &.{card},
        };

        const path = "test_priority.json";
        const io = store.getIo();
        const dir = std.Io.Dir.cwd();
        dir.deleteFile(io, path) catch {};

        try store.save(&.{project}, path);

        const loaded = try store.loadAlloc(path, std.heap.page_allocator);
        defer store.freeProjects(loaded, std.heap.page_allocator);

        try std.testing.expectEqual(priority, loaded[0].cards[0].priority);
    }
}

test "session with optional fields" {
    const session = types.Session{
        .id = "s1",
        .name = "Worktree Session",
        .cwd = "/home/user/project",
        .command = "zig build",
        .split_id = "split-123",
        .is_worktree = true,
        .worktree_name = "feature-branch",
    };

    const card = types.Card{
        .id = "c1",
        .title = "Worktree Card",
        .description = "Testing worktree sessions",
        .status = .review,
        .priority = .p0,
        .sessions = &.{session},
    };

    const project = types.Project{
        .id = "p1",
        .name = "Worktree Project",
        .cards = &.{card},
    };

    const path = "test_worktree_session.json";
    const io = store.getIo();
    const dir = std.Io.Dir.cwd();
    dir.deleteFile(io, path) catch {};

    try store.save(&.{project}, path);

    const loaded = try store.loadAlloc(path, std.heap.page_allocator);
    defer store.freeProjects(loaded, std.heap.page_allocator);

    try std.testing.expectEqualStrings("split-123", loaded[0].cards[0].sessions[0].split_id.?);
    try std.testing.expectEqual(true, loaded[0].cards[0].sessions[0].is_worktree);
    try std.testing.expectEqualStrings("feature-branch", loaded[0].cards[0].sessions[0].worktree_name.?);
}
