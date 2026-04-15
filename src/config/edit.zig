const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const file_load = @import("file_load.zig");

/// The path to the configuration that should be opened for editing.
///
/// The Windows-only fork keeps a single per-user config location, so we only
/// need to consider the current and legacy XDG-style config filenames and pick
/// the first non-empty file that already exists.
///
/// The returned value is allocated using the provided allocator.
pub fn openPath(alloc_gpa: Allocator) ![:0]const u8 {
    // Use an arena to make memory management easier in here.
    var arena = ArenaAllocator.init(alloc_gpa);
    defer arena.deinit();
    const alloc_arena = arena.allocator();

    // Get the path we should open
    const config_path = try configPath(alloc_arena);

    // Create config directory recursively.
    if (std.fs.path.dirname(config_path)) |config_dir| {
        try std.fs.cwd().makePath(config_dir);
    }

    // Try to create file and go on if it already exists
    _ = std.fs.createFileAbsolute(
        config_path,
        .{ .exclusive = true },
    ) catch |err| {
        switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        }
    };

    return try alloc_gpa.dupeZ(u8, config_path);
}

/// Returns the config path to use for open for the current OS.
///
/// The allocator must be an arena allocator. No memory is freed by this
/// function and the resulting path is not all the memory that is allocated.
fn configPath(alloc_arena: Allocator) ![]const u8 {
    const paths: []const []const u8 = try configPathCandidates(alloc_arena);
    assert(paths.len > 0);

    // Find the first path that exists and is non-empty. If no paths are
    // non-empty but at least one exists, we will return the first path that
    // exists.
    var exists: ?[]const u8 = null;
    for (paths) |path| {
        const f = std.fs.openFileAbsolute(path, .{}) catch |err| {
            switch (err) {
                // File doesn't exist, continue.
                error.BadPathName, error.FileNotFound => continue,

                // Some other error, assume it exists and return it.
                else => return err,
            }
        };
        defer f.close();

        // We expect stat to succeed because we just opened the file.
        const stat = try f.stat();

        // If the file is non-empty, return it.
        if (stat.size > 0) return path;

        // If the file is empty, remember it exists.
        if (exists == null) exists = path;
    }

    // No paths are non-empty, return the first path that exists.
    if (exists) |v| return v;

    // No paths are non-empty or exist, return the first path.
    return paths[0];
}

/// Returns the possible main-config paths for the Windows-only fork.
fn configPathCandidates(alloc_arena: Allocator) ![]const []const u8 {
    var paths: std.ArrayList([]const u8) = try .initCapacity(alloc_arena, 3);
    errdefer paths.deinit(alloc_arena);

    paths.appendAssumeCapacity(try file_load.defaultXdgPath(alloc_arena));
    paths.appendAssumeCapacity(try file_load.legacyGhosttyConfigDotGhosttyPath(alloc_arena));
    paths.appendAssumeCapacity(try file_load.legacyGhosttyDefaultXdgPath(alloc_arena));

    return paths.items;
}
