const std = @import("std");
const inputpkg = @import("../input.zig");
const args = @import("args.zig");
const Action = @import("action.zig").Action;
const Config = @import("../config/Config.zig");
const themepkg = @import("../config/theme.zig");
const internal_os = @import("../os/main.zig");
const global_state = &@import("../global.zig").state;

pub const Options = struct {
    /// If true, print the full path to the theme.
    path: bool = false,

    /// If true, show a small preview of the theme.
    preview: bool = false,

    pub fn deinit(self: Options) void {
        _ = self;
    }

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `list-themes` command is used to list all the available themes for
/// Ghostty.
///
/// Two different directories will be searched for themes.
///
/// The first directory is the `themes` subdirectory of your Ghostty
/// configuration directory. This is `$XDG_CONFIG_DIR/ghostty/themes` or
/// `~/.config/ghostty/themes`.
///
/// The second directory is the `themes` subdirectory of the Ghostty resources
/// directory. Ghostty ships with a multitude of themes that will be installed
/// into this directory. On macOS, this directory is the `Ghostty.app/Contents/
/// Resources/ghostty/themes`. On Linux, this directory is the `share/ghostty/
/// themes` (wherever you installed the Ghostty "share" directory). If you're
/// running Ghostty from the source, this is the `zig-out/share/ghostty/themes`
/// directory.
///
/// You can also set the `GHOSTTY_RESOURCES_DIR` environment variable to point
/// to the resources directory.
///
/// Flags:
///
///   * `--path`: Show the full path to the theme.
///   * `--preview`: Show a short preview of the theme colors.
pub fn run(gpa_alloc: std.mem.Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try std.process.argsWithAllocator(gpa_alloc);
        defer iter.deinit();
        try args.parse(Options, @TypeOf(iter), gpa_alloc, &opts, &iter);
    }

    var arena = std.heap.ArenaAllocator.init(gpa_alloc);
    const alloc = arena.allocator();

    const stderr = std.io.getStdErr().writer();
    const stdout = std.io.getStdOut().writer();

    if (global_state.resources_dir == null)
        try stderr.print("Could not find the Ghostty resources directory. Please ensure " ++
            "that Ghostty is installed correctly.\n", .{});

    const ThemeListElement = struct {
        location: themepkg.Location,
        path: []const u8,
        theme: []const u8,
        fn lessThan(_: void, lhs: @This(), rhs: @This()) bool {
            // TODO: use Unicode-aware comparison
            return std.ascii.orderIgnoreCase(lhs.theme, rhs.theme) == .lt;
        }
    };

    var count: usize = 0;

    var themes = std.ArrayList(ThemeListElement).init(alloc);

    var it = themepkg.LocationIterator{ .arena_alloc = arena.allocator() };

    while (try it.next()) |loc| {
        var dir = std.fs.cwd().openDir(loc.dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => {
                std.debug.print("error trying to open {s}: {}\n", .{ loc.dir, err });
                continue;
            },
        };
        defer dir.close();

        var walker = dir.iterate();

        while (try walker.next()) |entry| {
            if (entry.kind != .file) continue;
            count += 1;
            try themes.append(.{
                .location = loc.location,
                .path = try std.fs.path.join(alloc, &.{ loc.dir, entry.name }),
                .theme = try alloc.dupe(u8, entry.name),
            });
        }
    }

    std.mem.sortUnstable(ThemeListElement, themes.items, {}, ThemeListElement.lessThan);

    for (themes.items) |theme| {
        if (opts.path)
            try stdout.print("{s} ({s}) {s}\n", .{ theme.theme, @tagName(theme.location), theme.path })
        else
            try stdout.print("{s} ({s})\n", .{ theme.theme, @tagName(theme.location) });

        if (opts.preview) {
            var config = try Config.default(gpa_alloc);
            defer config.deinit();
            if (config.loadFile(config._arena.?.allocator(), theme.path)) |_| {
                if (!config._errors.empty()) {
                    try stderr.print("  Problems were encountered trying to load the theme:\n", .{});
                    for (config._errors.list.items) |err| {
                        try stderr.print("    {s}\n", .{err.message});
                    }
                }
                try stdout.print("\n   ", .{});
                for (0..8) |i| {
                    try stdout.print(" {d:2} \x1b[38;2;{d};{d};{d}m██\x1b[0m", .{
                        i,
                        config.palette.value[i].r,
                        config.palette.value[i].g,
                        config.palette.value[i].b,
                    });
                }
                try stdout.print("\n   ", .{});
                for (8..16) |i| {
                    try stdout.print(" {d:2} \x1b[38;2;{d};{d};{d}m██\x1b[0m", .{
                        i,
                        config.palette.value[i].r,
                        config.palette.value[i].g,
                        config.palette.value[i].b,
                    });
                }
                try stdout.print("\n\n", .{});
            } else |err| {
                try stderr.print("unable to load {s}: {}", .{ theme.path, err });
            }
        }
    }

    if (count == 0) {
        try stderr.print("No themes found, check to make sure that the themes were installed correctly.", .{});
        return 1;
    }

    return 0;
}
