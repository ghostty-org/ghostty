const std = @import("std");
const Allocator = std.mem.Allocator;
const Child = std.process.Child;

/// Get the path to the shared cache script
fn getCacheScriptPath(alloc: Allocator) ![]u8 {
    // Use GHOSTTY_RESOURCES_DIR if available, otherwise assume relative path
    const resources_dir = std.process.getEnvVarOwned(alloc, "GHOSTTY_RESOURCES_DIR") catch {
        // Fallback: assume we're running from build directory
        return try alloc.dupe(u8, "src");
    };
    defer alloc.free(resources_dir);

    return try std.fs.path.join(alloc, &[_][]const u8{ resources_dir, "shell-integration", "shared", "ghostty-ssh-cache" });
}

/// Generic function to run cache script commands
fn runCacheCommand(alloc: Allocator, writer: anytype, command: []const u8) !void {
    const script_path = try getCacheScriptPath(alloc);
    defer alloc.free(script_path);

    var child = Child.init(&[_][]const u8{ script_path, command }, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    const stdout = try child.stdout.?.readToEndAlloc(alloc, std.math.maxInt(usize));
    defer alloc.free(stdout);

    const stderr = try child.stderr.?.readToEndAlloc(alloc, std.math.maxInt(usize));
    defer alloc.free(stderr);

    _ = try child.wait();

    // Output the results regardless of exit code
    try writer.writeAll(stdout);
    if (stderr.len > 0) {
        try writer.writeAll(stderr);
    }
}

/// List cached hosts by calling the external script
pub fn listCachedHosts(alloc: Allocator, writer: anytype) !void {
    try runCacheCommand(alloc, writer, "list");
}

/// Clear cache by calling the external script
pub fn clearCache(alloc: Allocator, writer: anytype) !void {
    try runCacheCommand(alloc, writer, "clear");
}
