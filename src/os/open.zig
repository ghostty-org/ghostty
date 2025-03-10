const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const apprt = @import("../apprt.zig");
const CircBuf = @import("../datastruct/circ_buf.zig").CircBuf;

const log = std.log.scoped(.os);

/// Open a URL in the default handling application.
///
/// Any output on stderr is logged as a warning in the application logs.
/// Output on stdout is ignored.
pub fn open(
    alloc: Allocator,
    kind: apprt.action.OpenUrlKind,
    url: []const u8,
) !void {
    const cmd: OpenCommand = switch (builtin.os.tag) {
        .linux => .{ .child = std.process.Child.init(
            &.{ "xdg-open", url },
            alloc,
        ) },

        .windows => .{ .child = std.process.Child.init(
            &.{ "rundll32", "url.dll,FileProtocolHandler", url },
            alloc,
        ) },

        .macos => .{
            .child = std.process.Child.init(
                switch (kind) {
                    .text => &.{ "open", "-t", url },
                    .unknown => &.{ "open", url },
                },
                alloc,
            ),
            .wait = true,
        },

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

const OpenCommand = struct {
    child: std.process.Child,
    wait: bool = false,
};

/// Use `xdg-open` to open a URL using the default application.
///
/// Any output on stderr is logged as a warning in the application logs. Output
/// on stdout is ignored.
pub fn openUrlLinux(
    alloc: Allocator,
    url: []const u8,
) void {
    openUrlLinuxError(alloc, url) catch |err| {
        log.warn("unable to open url: {}", .{err});
    };
}

fn openUrlLinuxError(
    alloc: Allocator,
    url: []const u8,
) !void {
    // Make a copy of the URL so that we can use it in the thread without
    // worrying about it getting freed by other threads.
    const copy = try alloc.dupe(u8, url);
    errdefer alloc.free(copy);

    // Run `xdg-open` in a thread so that it never blocks the main thread, no
    // matter how long it takes to execute.
    const thread = try std.Thread.spawn(.{}, _openUrlLinux, .{ alloc, copy });

    // Don't worry about the thread any more.
    thread.detach();
}

fn _openUrlLinux(alloc: Allocator, url: []const u8) void {
    _openUrlLinuxError(alloc, url) catch |err| {
        log.warn("error while opening url: {}", .{err});
    };
}

fn _openUrlLinuxError(alloc: Allocator, url: []const u8) !void {
    defer alloc.free(url);

    var exe = std.process.Child.init(
        &.{ "xdg-open", url },
        alloc,
    );

    // We're only interested in stderr
    exe.stdin_behavior = .Ignore;
    exe.stdout_behavior = .Ignore;
    exe.stderr_behavior = .Pipe;

    exe.spawn() catch |err| {
        switch (err) {
            error.FileNotFound => {
                log.err("Unable to find xdg-open. Please install xdg-open and ensure that it is available on the PATH.", .{});
            },
            else => |e| return e,
        }
        return;
    };

    const stderr = exe.stderr orelse {
        log.warn("Unable to access the stderr of the spawned program!", .{});
        return;
    };

    var cb = try CircBuf(u8, 0).init(alloc, 50 * 1024);
    defer cb.deinit(alloc);

    // Read any error output and store it in a circular buffer so that we
    // get that _last_ 50K of output.
    while (true) {
        var buf: [1024]u8 = undefined;
        const len = try stderr.read(&buf);
        if (len == 0) break;
        try cb.appendSlice(buf[0..len]);
    }

    // If we have any stderr output we log it. This makes it easier for users to
    // debug why some open commands may not work as expected.
    if (cb.len() > 0) log: {
        {
            var it = cb.iterator(.forward);
            while (it.next()) |char| {
                if (std.mem.indexOfScalar(u8, &std.ascii.whitespace, char.*)) |_| continue;
                break;
            }
            // it's all whitespace, don't log
            break :log;
        }
        var buf = std.ArrayList(u8).init(alloc);
        defer buf.deinit();
        var it = cb.iterator(.forward);
        while (it.next()) |char| {
            if (char.* == '\n') {
                log.err("xdg-open stderr: {s}", .{buf.items});
                buf.clearRetainingCapacity();
            }
            try buf.append(char.*);
        }
        if (buf.items.len > 0)
            log.err("xdg-open stderr: {s}", .{buf.items});
    }

    const rc = try exe.wait();

    switch (rc) {
        .Exited => |code| {
            if (code != 0) {
                log.warn("xdg-open exited with error code {d}", .{code});
            }
        },
        .Signal => |signal| {
            log.warn("xdg-open was terminaled with signal {}", .{signal});
        },
        .Stopped => |signal| {
            log.warn("xdg-open was stopped with signal {}", .{signal});
        },
        .Unknown => |code| {
            log.warn("xdg-open had an unknown error {}", .{code});
        },
    }
}
