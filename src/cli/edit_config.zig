const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
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

/// The `edit-config` command opens the winghostty configuration file in the
/// editor specified by the `$VISUAL` or `$EDITOR` environment variables.
///
/// IMPORTANT: This command will not reload the configuration after
/// editing. You will need to manually reload the configuration using the
/// application menu, configured keybind, or by restarting winghostty. We
/// plan to auto-reload in the future, but winghostty isn't capable of
/// this yet.
///
/// The filepath opened is the default user-specific configuration
/// file for winghostty.
///
/// This command prefers the `$VISUAL` environment variable over `$EDITOR`,
/// if both are set. On Windows, if neither are set, the configuration file
/// will be opened with the associated editor.
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

    // Find the preferred path.
    const path = try configpkg.preferredDefaultFilePath(alloc);
    defer alloc.free(path);

    if (comptime builtin.os.tag == .windows) {
        if (editor.len > 0) {
            try launchWindowsEditor(alloc, editor, path);
            return 0;
        }

        try openPathWithShell(alloc, path);
        return 0;
    }

    // If we don't have `$EDITOR` set then we can't do anything
    // but we can still print a helpful message.
    if (editor.len == 0) {
        try stderr.print(
            \\The $EDITOR or $VISUAL environment variable is not set or is empty.
            \\This environment variable is required to edit the winghostty configuration
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

    const command = command: {
        var buffer: std.io.Writer.Allocating = .init(alloc);
        defer buffer.deinit();
        const writer = &buffer.writer;
        try writer.writeAll(editor);
        try writer.writeByte(' ');
        {
            var sh: internal_os.ShellEscapeWriter = .init(writer);
            try sh.writer.writeAll(path);
            try sh.writer.flush();
        }
        try writer.flush();
        break :command try buffer.toOwnedSliceSentinel(0);
    };
    defer alloc.free(command);

    // We require libc because we want to use std.c.environ for envp
    // and not have to build that ourselves. We can remove this
    // limitation later but Ghostty already heavily requires libc
    // so this is not a big deal.
    comptime assert(builtin.link_libc);

    const err = std.posix.execvpeZ(
        "/bin/sh",
        &.{ "/bin/sh", "-c", command },
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

fn launchWindowsEditor(
    alloc: Allocator,
    editor: []const u8,
    path: []const u8,
) !void {
    const command = try std.fmt.allocPrint(
        alloc,
        "start \"\" {s} \"{s}\"",
        .{ editor, path },
    );
    defer alloc.free(command);

    var child = std.process.Child.init(
        &.{ "C:\\Windows\\System32\\cmd.exe", "/C", command },
        alloc,
    );
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = try child.spawnAndWait();
}

fn openPathWithShell(
    alloc: Allocator,
    path: []const u8,
) !void {
    const path_w = try std.unicode.utf8ToUtf16LeAllocZ(alloc, path);
    defer alloc.free(path_w);
    const verb_w = std.unicode.utf8ToUtf16LeStringLiteral("open");
    const result = ShellExecuteW(
        null,
        verb_w.ptr,
        path_w.ptr,
        null,
        null,
        1,
    );
    if (@intFromPtr(result) <= 32) return error.OpenConfigFailed;
}

extern "shell32" fn ShellExecuteW(
    hwnd: ?windows.HWND,
    lpOperation: ?windows.LPCWSTR,
    lpFile: ?windows.LPCWSTR,
    lpParameters: ?windows.LPCWSTR,
    lpDirectory: ?windows.LPCWSTR,
    nShowCmd: windows.INT,
) callconv(.winapi) ?windows.HINSTANCE;
