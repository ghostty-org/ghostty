const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const build_config = @import("../build_config.zig");
const xev = @import("../global.zig").xev;
const renderer = @import("../renderer.zig");

const build_config_heading = "Build Config\n";
const platform_label = "  - platform      : ";
const event_backend_label = "  - event backend : ";

pub const Options = struct {};

/// The `version` command is used to display information about Ghostty. Recognized as
/// either `+version` or `--version`.
pub fn run(alloc: Allocator) !u8 {
    _ = alloc;
    var buffer: [1024]u8 = undefined;
    const stdout_file: std.fs.File = .stdout();
    var stdout_writer = stdout_file.writer(&buffer);

    const stdout = &stdout_writer.interface;
    const tty = stdout_file.isTty();

    if (tty) if (build_config.version.build) |commit_hash| {
        try stdout.print(
            "\x1b]8;;https://github.com/ghostty-org/ghostty/commit/{s}\x1b\\",
            .{commit_hash},
        );
    };
    try stdout.print("Ghostty {s}\n\n", .{build_config.version_string});
    if (tty) try stdout.print("\x1b]8;;\x1b\\", .{});

    try stdout.print("Version\n", .{});
    try stdout.print("  - version: {s}\n", .{build_config.version_string});
    try stdout.print("  - channel: {t}\n", .{build_config.release_channel});

    try stdout.writeAll(build_config_heading);
    try stdout.print("  - Zig version   : {s}\n", .{builtin.zig_version_string});
    try stdout.print("  - build mode    : {}\n", .{builtin.mode});
    try stdout.print("{s}{}\n", .{ platform_label, builtin.target.os.tag });
    try stdout.print("  - app runtime   : {}\n", .{build_config.app_runtime});
    try stdout.print("  - font engine   : {}\n", .{build_config.font_backend});
    try stdout.print("  - renderer      : {}\n", .{renderer.Renderer});
    try stdout.print("{s}{t}\n", .{ event_backend_label, xev.backend });

    // Don't forget to flush!
    try stdout.flush();
    return 0;
}

test "version output labels are Windows-facing" {
    try std.testing.expect(std.mem.indexOf(u8, build_config_heading, "Build Config") != null);
    try std.testing.expect(std.mem.indexOf(u8, platform_label, "platform") != null);
    try std.testing.expect(std.mem.indexOf(u8, event_backend_label, "event backend") != null);
    try std.testing.expect(std.mem.indexOf(u8, event_backend_label, "libxev") == null);
}
