const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;
const args = @import("args.zig");
const Allocator = std.mem.Allocator;
const Action = @import("ghostty.zig").Action;
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
/// file, which is typically located at `$XDG_CONFIG_HOME/ghostty/config.ghostty`.
/// On macOS, this may also be located at
/// `~/Library/Application Support/com.mitchellh.ghostty/config.ghostty`.
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

    var buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&buffer);
    const stderr = &stderr_writer.interface;

    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try args.argsIterator(alloc);
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
    }

    const result = runInner(alloc, stderr);
    // Flushing *shouldn't* fail but...
    stderr.flush() catch {};
    return result;
}

fn runInner(alloc: Allocator, stderr: *std.Io.Writer) !u8 {
    // We load the configuration once because that will write our
    // default configuration files to disk. We don't use the config.
    var config = try Config.load(alloc);
    defer config.deinit();

    // Find the preferred path.
    const path = try configpkg.preferredDefaultFilePath(alloc);
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
    const editor = env: {
        // VISUAL vs. EDITOR: https://unix.stackexchange.com/questions/4859/visual-vs-editor-what-s-the-difference
        if (internal_os.getenvNotEmpty("VISUAL")) |v| break :env v;
        if (internal_os.getenvNotEmpty("EDITOR")) |v| break :env v;

        // If we don't have `$VISUAL` or `$EDITOR` set then we can't do anything
        // but we can still print a helpful message.
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
            \\{c}]8;;file://{s}{c}{c}{s}{c}]8;;{c}{c}
            \\
        ,
            .{ '\x1b', path, '\x1b', '\\', path, '\x1b', '\x1b', '\\' },
        );

        return 1;
    };

    const editorZ = try alloc.dupeZ(u8, editor);
    defer alloc.free(editorZ);

    const pathZ = try alloc.dupeZ(u8, path);
    defer alloc.free(pathZ);

    const env = try internal_os.createPosixBlock(alloc);
    defer {
        var i: usize = 0;
        while (env[i]) |e| : (i += 1) alloc.free(std.mem.span(e));
        alloc.free(env);
    }

    const err = std.posix.execvpeZ(
        editorZ,
        &.{ editorZ, pathZ },
        env,
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
        \\Path: {c}]8;;file://{s}{c}{c}{s}{c}]8;;{c}{c}
        \\
    , .{ err, editor, '\x1b', path, '\x1b', '\\', path, '\x1b', '\x1b', '\\' });
    return 1;
}
