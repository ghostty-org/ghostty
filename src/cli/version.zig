const std = @import("std");
const build_options = @import("build_options");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const build_config = @import("../build_config.zig");
const internal_os = @import("../os/main.zig");
const xev = @import("../global.zig").xev;
const renderer = @import("../renderer.zig");

const gtk_version = @import("../apprt/gtk/gtk_version.zig");
const adw_version = @import("../apprt/gtk/adw_version.zig");

pub const Options = struct {};

/// The `version` command is used to display information about Ghostty. Recognized as
/// either `+version` or `--version`.
pub fn run(alloc: Allocator) !u8 {
    _ = alloc;

    const stdout = std.io.getStdOut().writer();
    const tty = std.io.getStdOut().isTty();

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
    try stdout.print("  - channel: {s}\n", .{@tagName(build_config.release_channel)});

    try stdout.print("Build Config\n", .{});
    try stdout.print("  - Zig version: {s}\n", .{builtin.zig_version_string});
    try stdout.print("  - build mode : {}\n", .{builtin.mode});
    try stdout.print("  - app runtime: {}\n", .{build_config.app_runtime});
    try stdout.print("  - font engine: {}\n", .{build_config.font_backend});
    try stdout.print("  - renderer   : {}\n", .{renderer.Renderer});
    try stdout.print("  - libxev     : {s}\n", .{@tagName(xev.backend)});
    if (comptime build_config.app_runtime == .gtk) {
        try stdout.print("  - desktop env: {s}\n", .{@tagName(internal_os.desktopEnvironment())});
        try stdout.print("  - GTK version:\n", .{});
        try stdout.print("    build      : {}\n", .{gtk_version.comptime_version});
        try stdout.print("    runtime    : {}\n", .{gtk_version.getRuntimeVersion()});
        try stdout.print("  - libadwaita : enabled\n", .{});
        try stdout.print("    build      : {}\n", .{adw_version.comptime_version});
        try stdout.print("    runtime    : {}\n", .{adw_version.getRuntimeVersion()});
        if (comptime build_options.x11) {
            try stdout.print("  - libX11     : enabled\n", .{});
        } else {
            try stdout.print("  - libX11     : disabled\n", .{});
        }

        // We say `libwayland` since it is possible to build Ghostty without
        // Wayland integration but with Wayland-enabled GTK
        if (comptime build_options.wayland) {
            try stdout.print("  - libwayland : enabled\n", .{});
        } else {
            try stdout.print("  - libwayland : disabled\n", .{});
        }
    }
    return 0;
}
