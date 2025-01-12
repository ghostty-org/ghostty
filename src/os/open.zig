const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// The type of the data at the URL to open. This is used as a hint
/// to potentially open the URL in a different way.
pub const Type = enum {
    text,
    unknown,
};

/// Open a URL in the default handling application.
///
/// Any output on stderr is logged as a warning in the application logs.
/// Output on stdout is ignored.
pub fn open(
    alloc: Allocator,
    typ: Type,
    url: []const u8,
) !void {
    const cmd: OpenCommand = switch (builtin.os.tag) {
        .linux => try determineOpenCommandLinux(alloc, url),
        .windows => .{ .child = std.process.Child.init(
            &.{ "rundll32", "url.dll,FileProtocolHandler", url },
            alloc,
        ) },
        .macos => try determineOpenCommandMacOS(alloc, typ, url),
        .ios => return error.Unimplemented,
        else => @compileError("unsupported OS"),
    };

    var exe = cmd.child;
    if (cmd.wait) {
        // Pipe stdout/stderr so we can collect output from the command
        exe.stdout_behavior = .Pipe;
        exe.stderr_behavior = .Pipe;
    }

    try exe.spawn();

    if (cmd.wait) {
        // 50 KiB is the default value used by std.process.Child.run
        const output_max_size = 50 * 1024;

        var stdout = std.ArrayList(u8).init(alloc);
        var stderr = std.ArrayList(u8).init(alloc);
        defer {
            stdout.deinit();
            stderr.deinit();
        }

        try exe.collectOutput(&stdout, &stderr, output_max_size);
        _ = try exe.wait();

        // If we have any stderr output we log it. This makes it easier for
        // users to debug why some open commands may not work as expected.
        if (stderr.items.len > 0) std.log.err("open stderr={s}", .{stderr.items});
    }
}

fn determineOpenCommandLinux(alloc: Allocator, url: []const u8) !OpenCommand {
    const editor = std.process.getEnvVarOptional("EDITOR") orelse return .{ .child = std.process.Child.init(
        &.{ "xdg-open", url },
        alloc,
    ) };

    return .{ .child = std.process.Child.init(
        &.{ editor, url },
        alloc,
    ) };
}

fn determineOpenCommandMacOS(alloc: Allocator, typ: Type, url: []const u8) !OpenCommand {
    const editor = std.process.getEnvVarOptional("EDITOR") orelse return .{ .child = std.process.Child.init(
        switch (typ) {
            .text => &.{ "open", "-t", url },
            .unknown => &.{ "open", url },
        },
        alloc,
    ) };

    return .{ .child = std.process.Child.init(
        &.{ editor, url },
        alloc,
    ) };
}

const OpenCommand = struct {
    child: std.process.Child,
    wait: bool = false,
};
