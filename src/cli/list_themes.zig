const std = @import("std");
const inputpkg = @import("../input.zig");
const args = @import("args.zig");
const Arena = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const Config = @import("../config/Config.zig");
const global_state = &@import("../main.zig").state;

pub const Options = struct {
    pub fn deinit(self: Options) void {
        _ = self;
    }
};

/// The "list-themes" command is used to list all the available themes
/// for Ghostty.
///
/// Themes require that Ghostty have access to the resources directory.
/// On macOS this is embedded in the app bundle. On Linux, this is usually
/// in `/usr/share`. If you're compiling from source, this is the
/// `zig-out/share` directory. You can also set the `GHOSTTY_RESOURCES_DIR`
/// environment variable to point to the resources directory. Themes
/// live in the `themes` subdirectory of the resources directory.
pub fn run(alloc: Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try std.process.argsWithAllocator(alloc);
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
    }

    const stderr = std.io.getStdErr().writer();
    const stdout = std.io.getStdOut().writer();

    const resources_dir = global_state.resources_dir orelse {
        try stderr.print("Could not find the Ghostty resources directory. Please ensure " ++
            "that Ghostty is installed correctly.\n", .{});
        return 1;
    };

    const path = try std.fs.path.join(alloc, &.{ resources_dir, "themes" });
    defer alloc.free(path);

    var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(alloc);
    defer walker.deinit();

    var themes = std.ArrayList([]const u8).init(alloc);
    defer {
        for (themes.items) |v| alloc.free(v);
        themes.deinit();
    }

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        try themes.append(try alloc.dupe(u8, entry.basename));
    }

    std.mem.sortUnstable([]const u8, themes.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.ascii.orderIgnoreCase(lhs, rhs) == .lt;
        }
    }.lessThan);

    for (themes.items) |theme| {
        try stdout.print("{s}\n", .{theme});
    }

    return 0;
}
