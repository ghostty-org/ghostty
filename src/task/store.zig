const std = @import("std");
const types = @import("types.zig");

const ProjectParseError = error{
    InvalidCardStatus,
    InvalidPriority,
    InvalidSession,
    InvalidCard,
    InvalidProject,
};

/// Parse a CardStatus from a string
fn parseCardStatus(s: []const u8) ProjectParseError!types.CardStatus {
    if (std.mem.eql(u8, s, "todo")) return .todo;
    if (std.mem.eql(u8, s, "in_progress")) return .in_progress;
    if (std.mem.eql(u8, s, "review")) return .review;
    if (std.mem.eql(u8, s, "done")) return .done;
    return ProjectParseError.InvalidCardStatus;
}

/// Parse a Priority from a string
fn parsePriority(s: []const u8) ProjectParseError!types.Priority {
    if (std.mem.eql(u8, s, "p0")) return .p0;
    if (std.mem.eql(u8, s, "p1")) return .p1;
    if (std.mem.eql(u8, s, "p2")) return .p2;
    if (std.mem.eql(u8, s, "p3")) return .p3;
    return ProjectParseError.InvalidPriority;
}

/// Serialize CardStatus to a string
fn cardStatusToString(status: types.CardStatus) []const u8 {
    return switch (status) {
        .todo => "todo",
        .in_progress => "in_progress",
        .review => "review",
        .done => "done",
    };
}

/// Serialize Priority to a string
fn priorityToString(priority: types.Priority) []const u8 {
    return switch (priority) {
        .p0 => "p0",
        .p1 => "p1",
        .p2 => "p2",
        .p3 => "p3",
    };
}

/// Load projects from a JSON file using the global allocator.
/// Returns an empty slice if the file does not exist.
/// The returned slice is allocated and must be freed by the caller.
pub fn load(path: []const u8) []const types.Project {
    return loadAlloc(path, std.heap.page_allocator) catch return &.{};
}

/// Get the Io instance for file operations
fn getIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Save projects to a JSON file.
pub fn save(projects: []const types.Project, path: []const u8) !void {
    const io = getIo();
    const dir = std.Io.Dir.cwd();
    const gpa = std.heap.page_allocator;

    var json_bytes: std.ArrayList(u8) = .empty;
    defer json_bytes.deinit(std.heap.page_allocator);

    try json_bytes.appendSlice(gpa, "[");
    for (projects, 0..) |project, pi| {
        try json_bytes.appendSlice(gpa, "{\"id\":\"");
        try json_bytes.appendSlice(gpa, project.id);
        try json_bytes.appendSlice(gpa, "\",\"name\":\"");
        try json_bytes.appendSlice(gpa, project.name);
        try json_bytes.appendSlice(gpa, "\",\"cards\":[");

        for (project.cards, 0..) |card, ci| {
            try json_bytes.appendSlice(gpa, "{\"id\":\"");
            try json_bytes.appendSlice(gpa, card.id);
            try json_bytes.appendSlice(gpa, "\",\"title\":\"");
            try json_bytes.appendSlice(gpa, card.title);
            try json_bytes.appendSlice(gpa, "\",\"description\":\"");
            try json_bytes.appendSlice(gpa, card.description);
            try json_bytes.appendSlice(gpa, "\",\"status\":\"");
            try json_bytes.appendSlice(gpa, cardStatusToString(card.status));
            try json_bytes.appendSlice(gpa, "\",\"priority\":\"");
            try json_bytes.appendSlice(gpa, priorityToString(card.priority));
            try json_bytes.appendSlice(gpa, "\",\"sessions\":[");

            for (card.sessions, 0..) |session, si| {
                try json_bytes.appendSlice(gpa, "{\"id\":\"");
                try json_bytes.appendSlice(gpa, session.id);
                try json_bytes.appendSlice(gpa, "\",\"name\":\"");
                try json_bytes.appendSlice(gpa, session.name);
                try json_bytes.appendSlice(gpa, "\",\"cwd\":\"");
                try json_bytes.appendSlice(gpa, session.cwd);
                try json_bytes.appendSlice(gpa, "\",\"command\":\"");
                try json_bytes.appendSlice(gpa, session.command);
                try json_bytes.appendSlice(gpa, "\"");
                if (session.split_id) |sid| {
                    try json_bytes.appendSlice(gpa, ",\"split_id\":\"");
                    try json_bytes.appendSlice(gpa, sid);
                    try json_bytes.appendSlice(gpa, "\"");
                }
                if (session.is_worktree) {
                    try json_bytes.appendSlice(gpa, ",\"is_worktree\":true");
                }
                if (session.worktree_name) |wn| {
                    try json_bytes.appendSlice(gpa, ",\"worktree_name\":\"");
                    try json_bytes.appendSlice(gpa, wn);
                    try json_bytes.appendSlice(gpa, "\"");
                }
                try json_bytes.appendSlice(gpa, "}");
                if (si < card.sessions.len - 1) try json_bytes.appendSlice(gpa, ",");
            }

            try json_bytes.appendSlice(gpa, "]}");
            if (ci < project.cards.len - 1) try json_bytes.appendSlice(gpa, ",");
        }

        try json_bytes.appendSlice(gpa, "]}");
        if (pi < projects.len - 1) try json_bytes.appendSlice(gpa, ",");
    }
    try json_bytes.appendSlice(gpa, "]");

    try dir.writeFile(io, .{
        .sub_path = path,
        .data = json_bytes.items,
    });
}

/// Load projects from a JSON file using the provided allocator.
/// The returned slice is allocated with the provided allocator and must be freed
/// by the caller using freeProjects.
pub fn loadAlloc(path: []const u8, allocator: std.mem.Allocator) ![]const types.Project {
    const io = getIo();
    const dir = std.Io.Dir.cwd();

    const file = dir.openFile(io, path, .{}) catch |err| {
        if (err == error.FileNotFound) return &.{};
        return err;
    };
    defer file.close(io);

    // Read file size
    const stat = try file.stat(io);
    const file_size = stat.size;

    // Read file content
    var content = try allocator.alloc(u8, file_size);
    errdefer allocator.free(content);

    var offset: u64 = 0;
    while (offset < file_size) {
        var iovecs: [1][]u8 = .{content[offset..]};
        const n = try file.readPositional(io, &iovecs, offset);
        offset += n;
    }

    return try parseProjects(content, allocator);
}

/// Free projects that were allocated with loadAlloc.
pub fn freeProjects(projects: []const types.Project, allocator: std.mem.Allocator) void {
    for (projects) |project| {
        for (project.cards) |card| {
            for (card.sessions) |session| {
                allocator.free(session.id);
                allocator.free(session.name);
                allocator.free(session.cwd);
                allocator.free(session.command);
                if (session.split_id) |sid| allocator.free(sid);
                if (session.worktree_name) |wn| allocator.free(wn);
            }
            allocator.free(card.sessions);
            allocator.free(card.id);
            allocator.free(card.title);
            allocator.free(card.description);
        }
        allocator.free(project.cards);
        allocator.free(project.id);
        allocator.free(project.name);
    }
    allocator.free(projects);
}

/// Parse projects from JSON content
fn parseProjects(content: []const u8, allocator: std.mem.Allocator) ![]const types.Project {
    var scanner = std.json.Scanner.initCompleteInput(allocator, content);
    defer scanner.deinit();

    const value = try std.json.Value.jsonParse(allocator, &scanner, .{
        .max_value_len = std.math.maxInt(usize),
    });

    if (value != .array) return ProjectParseError.InvalidProject;
    const arr = value.array;

    const projects = try allocator.alloc(types.Project, arr.items.len);

    for (arr.items, 0..) |project_node, pi| {
        if (project_node != .object) return ProjectParseError.InvalidProject;
        const obj = project_node.object;

        const id_node = obj.get("id") orelse return ProjectParseError.InvalidProject;
        const name_node = obj.get("name") orelse return ProjectParseError.InvalidProject;
        const cards_node = obj.get("cards") orelse return ProjectParseError.InvalidProject;

        if (id_node != .string or name_node != .string or cards_node != .array) {
            return ProjectParseError.InvalidProject;
        }

        const id = try allocator.dupe(u8, id_node.string);
        errdefer allocator.free(id);

        const name = try allocator.dupe(u8, name_node.string);
        errdefer allocator.free(name);

        const cards_arr = cards_node.array;
        const cards = try allocator.alloc(types.Card, cards_arr.items.len);
        errdefer allocator.free(cards);

        for (cards_arr.items, 0..) |card_node, ci| {
            if (card_node != .object) return ProjectParseError.InvalidCard;
            const card_obj = card_node.object;

            const card_id_node = card_obj.get("id") orelse return ProjectParseError.InvalidCard;
            const card_title_node = card_obj.get("title") orelse return ProjectParseError.InvalidCard;

            if (card_id_node != .string or card_title_node != .string) {
                return ProjectParseError.InvalidCard;
            }

            const card_desc_node = card_obj.get("description");
            const card_status_node = card_obj.get("status") orelse return ProjectParseError.InvalidCard;
            const card_priority_node = card_obj.get("priority") orelse return ProjectParseError.InvalidCard;
            const card_sessions_node = card_obj.get("sessions") orelse return ProjectParseError.InvalidCard;

            if (card_status_node != .string or card_priority_node != .string or card_sessions_node != .array) {
                return ProjectParseError.InvalidCard;
            }

            const card_id = try allocator.dupe(u8, card_id_node.string);
            errdefer allocator.free(card_id);

            const card_title = try allocator.dupe(u8, card_title_node.string);
            errdefer allocator.free(card_title);

            const card_desc = if (card_desc_node) |n|
                if (n == .string) try allocator.dupe(u8, n.string) else ""
            else
                "";

            const status = parseCardStatus(card_status_node.string) catch return ProjectParseError.InvalidCard;
            const priority = parsePriority(card_priority_node.string) catch return ProjectParseError.InvalidCard;

            const sessions_arr = card_sessions_node.array;
            const sessions = try allocator.alloc(types.Session, sessions_arr.items.len);
            errdefer allocator.free(sessions);

            for (sessions_arr.items, 0..) |session_node, si| {
                if (session_node != .object) return ProjectParseError.InvalidSession;
                const session_obj = session_node.object;

                const sess_id_node = session_obj.get("id") orelse return ProjectParseError.InvalidSession;
                const sess_name_node = session_obj.get("name") orelse return ProjectParseError.InvalidSession;
                const sess_cwd_node = session_obj.get("cwd") orelse return ProjectParseError.InvalidSession;
                const sess_cmd_node = session_obj.get("command") orelse return ProjectParseError.InvalidSession;

                if (sess_id_node != .string or sess_name_node != .string or
                    sess_cwd_node != .string or sess_cmd_node != .string) {
                    return ProjectParseError.InvalidSession;
                }

                const sess_id = try allocator.dupe(u8, sess_id_node.string);
                errdefer allocator.free(sess_id);

                const sess_name = try allocator.dupe(u8, sess_name_node.string);
                errdefer allocator.free(sess_name);

                const sess_cwd = try allocator.dupe(u8, sess_cwd_node.string);
                errdefer allocator.free(sess_cwd);

                const sess_cmd = try allocator.dupe(u8, sess_cmd_node.string);
                errdefer allocator.free(sess_cmd);

                const split_id_node = session_obj.get("split_id");
                const is_worktree_node = session_obj.get("is_worktree");
                const worktree_name_node = session_obj.get("worktree_name");

                sessions[si] = .{
                    .id = sess_id,
                    .name = sess_name,
                    .cwd = sess_cwd,
                    .command = sess_cmd,
                    .split_id = if (split_id_node) |n|
                        if (n == .string) try allocator.dupe(u8, n.string) else null
                    else
                        null,
                    .is_worktree = if (is_worktree_node) |n| n == .bool and n.bool else false,
                    .worktree_name = if (worktree_name_node) |n|
                        if (n == .string) try allocator.dupe(u8, n.string) else null
                    else
                        null,
                };
            }

            cards[ci] = .{
                .id = card_id,
                .title = card_title,
                .description = card_desc,
                .status = status,
                .priority = priority,
                .sessions = sessions,
            };
        }

        projects[pi] = .{
            .id = id,
            .name = name,
            .cards = cards,
        };
    }

    return projects;
}

test "save and load roundtrip" {
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

    const path = "test_kanban.json";
    const io = getIo();
    const dir = std.Io.Dir.cwd();
    dir.deleteFile(io, path) catch {};

    try save(&.{project}, path);

    const loaded = try loadAlloc(path, std.heap.page_allocator);
    defer freeProjects(loaded, std.heap.page_allocator);

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

test "load from non-existent file returns empty slice" {
    const loaded = load("non_existent_file_12345.json");
    defer std.heap.page_allocator.free(loaded);

    try std.testing.expectEqual(@as(usize, 0), loaded.len);
}

test "save and load empty projects" {
    const path = "test_kanban_empty.json";
    const io = getIo();
    const dir = std.Io.Dir.cwd();
    dir.deleteFile(io, path) catch {};

    try save(&.{}, path);

    const loaded = try loadAlloc(path, std.heap.page_allocator);
    defer freeProjects(loaded, std.heap.page_allocator);

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
        const io = getIo();
        const dir = std.Io.Dir.cwd();
        dir.deleteFile(io, path) catch {};

        try save(&.{project}, path);

        const loaded = try loadAlloc(path, std.heap.page_allocator);
        defer freeProjects(loaded, std.heap.page_allocator);

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
        const io = getIo();
        const dir = std.Io.Dir.cwd();
        dir.deleteFile(io, path) catch {};

        try save(&.{project}, path);

        const loaded = try loadAlloc(path, std.heap.page_allocator);
        defer freeProjects(loaded, std.heap.page_allocator);

        try std.testing.expectEqual(priority, loaded[0].cards[0].priority);
    }
}
