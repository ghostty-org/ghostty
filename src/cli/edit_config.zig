const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const args = @import("args.zig");
const Allocator = std.mem.Allocator;
const Action = @import("action.zig").Action;
const configpkg = @import("../config.zig");
const internal_os = @import("../os/main.zig");
const Config = configpkg.Config;

pub const Options = struct {
    pub fn deinit(self: Options) void {
        _ = self;
    }

    /// Enables `-h` and `--help` to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `edit-config` command opens the Ghostty configuration file in the
/// editor specified by the `$VISUAL` or `$EDITOR` environment variables.
///
/// IMPORTANT: This command will not reload the configuration after
/// editing. You will need to manually reload the configuration using the
/// application menu, configured keybind, or by restarting Ghostty. We
/// plan to auto-reload in the future, but Ghostty isn't capable of
/// this yet.
///
/// The filepath opened is the default user-specific configuration
/// file, which is typically located at `$XDG_CONFIG_HOME/ghostty/config`.
/// On macOS, this may also be located at
/// `~/Library/Application Support/com.mitchellh.ghostty/config`.
/// On macOS, whichever path exists and is non-empty will be prioritized,
/// prioritizing the Application Support directory if neither are
/// non-empty.
///
/// This command prefers the `$VISUAL` environment variable over `$EDITOR`,
/// if both are set. If neither are set, it will print an error
/// and exit.
pub fn run(alloc: Allocator) !u8 {
    // Implementation note (by @mitchellh): I do proper memory cleanup
    // throughout this command, even though we plan on doing `exec`.
    // I do this out of good hygiene in case we ever change this to
    // not using `exec` anymore and because this command isn't performance
    // critical where setting up the defer cleanup is a problem.

    const stderr = std.io.getStdErr().writer();

    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try args.argsIterator(alloc);
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
    }

    // We load the configuration once because that will write our
    // default configuration files to disk. We don't use the config.
    var config = try Config.load(alloc);
    defer config.deinit();

    // Find the preferred path.
    const path = try Config.preferredDefaultFilePath(alloc);
    defer alloc.free(path);

    // We don't currently support Windows because we use the exec syscall.
    if (comptime builtin.os.tag == .windows) {
        try stderr.print(
            \\The `ghostty +edit-config` command is not supported on Windows.
            \\Please edit the configuration file manually at the following path:
            \\
            \\{s}
            \\
        ,
            .{path},
        );
        return 1;
    }

    // Get our editor
    const get_env_: ?internal_os.GetEnvResult = env: {
        // VISUAL vs. EDITOR: https://unix.stackexchange.com/questions/4859/visual-vs-editor-what-s-the-difference
        if (try internal_os.getenv(alloc, "VISUAL")) |v| {
            if (v.value.len > 0) break :env v;
            v.deinit(alloc);
        }

        if (try internal_os.getenv(alloc, "EDITOR")) |v| {
            if (v.value.len > 0) break :env v;
            v.deinit(alloc);
        }

        break :env null;
    };
    defer if (get_env_) |v| v.deinit(alloc);
    const editor: []const u8 = if (get_env_) |v| v.value else "";

    // If we don't have `$EDITOR` set then we can't do anything
    // but we can still print a helpful message.
    if (editor.len == 0) {
        try stderr.print(
            \\The $EDITOR or $VISUAL environment variable is not set or is empty.
            \\This environment variable is required to edit the Ghostty configuration
            \\via this CLI command.
            \\
            \\Please set the environment variable to your preferred terminal
            \\text editor and try again.
            \\
            \\If you prefer to edit the configuration file another way,
            \\you can find the configuration file at the following path:
            \\
            \\
        ,
            .{},
        );

        // Output the path using the OSC8 sequence so that it is linked.
        try stderr.print(
            "\x1b]8;;file://{s}\x1b\\{s}\x1b]8;;\x1b\\\n",
            .{ path, path },
        );

        return 1;
    }

    // We require libc because we want to use std.c.environ for envp
    // and not have to build that ourselves. We can remove this
    // limitation later but Ghostty already heavily requires libc
    // so this is not a big deal.
    comptime assert(builtin.link_libc);

    const editorZ = try alloc.dupeZ(u8, editor);
    defer alloc.free(editorZ);
    const pathZ = try alloc.dupeZ(u8, path);
    defer alloc.free(pathZ);
    const err = std.posix.execvpeZ(
        editorZ,
        &.{ editorZ, pathZ },
        std.c.environ,
    );

    // If we reached this point then exec failed.
    try stderr.print(
        \\Failed to execute the editor. Error code={}.
        \\
        \\This is usually due to the executable path not existing, invalid
        \\permissions, or the shell environment not being set up
        \\correctly.
        \\
        \\Editor: {s}
        \\Path: {s}
        \\
    , .{ err, editor, path });
    return 1;
}
