const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const apprt = @import("../apprt.zig");
const CircBuf = @import("../datastruct/circ_buf.zig").CircBuf;

const log = std.log.scoped(.@"os-open");

/// Open a URL in the default handling application.
///
/// Any output on stderr is logged as a warning in the application logs.
/// Output on stdout is ignored. The allocator is used to buffer the
/// log output and may allocate from another thread.
pub fn open(
    alloc: Allocator,
    kind: apprt.action.OpenUrlKind,
    url: []const u8,
) !void {
    // Make a copy of the URL so that we can use it in the thread without
    // worrying about it getting freed by other threads.
    const copy = try alloc.dupe(u8, url);
    errdefer alloc.free(copy);

    // Run in a thread so that it never blocks the main thread, no matter how
    // long it takes to execute.
    const thread = try std.Thread.spawn(.{}, _openThread, .{ alloc, kind, copy });

    // Don't worry about the thread any more.
    thread.detach();
}

fn _openThread(
    alloc: Allocator,
    kind: apprt.action.OpenUrlKind,
    url: []const u8,
) void {
    _openThreadError(alloc, kind, url) catch |err| {
        log.warn("error while opening url: {}", .{err});
    };
}

fn _openThreadError(
    alloc: Allocator,
    kind: apprt.action.OpenUrlKind,
    url: []const u8,
) !void {
    defer alloc.free(url);

    var exe: std.process.Child = switch (builtin.os.tag) {
        .linux, .freebsd => .init(
            &.{ "xdg-open", url },
            alloc,
        ),

        .windows => .init(
            &.{ "rundll32", "url.dll,FileProtocolHandler", url },
            alloc,
        ),

        .macos => .init(
            switch (kind) {
                .text => &.{ "open", "-t", url },
                .unknown => &.{ "open", url },
            },
            alloc,
        ),

        .ios => return error.Unimplemented,
        else => @compileError("unsupported OS"),
    };

    // Ignore stdin & stdout, collect the output from stderr.
    // This must be set before spawning the process.
    exe.stdin_behavior = .Ignore;
    exe.stdout_behavior = .Ignore;
    exe.stderr_behavior = .Pipe;

    exe.spawn() catch |err| {
        switch (err) {
            error.FileNotFound => {
                log.warn("Unable to find {s}. Please install {s} and ensure that it is available on the PATH.", .{
                    exe.argv[0],
                    exe.argv[0],
                });
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
                log.err("{s} stderr: {s}", .{ exe.argv[0], buf.items });
                buf.clearRetainingCapacity();
            }
            try buf.append(char.*);
        }
        if (buf.items.len > 0)
            log.err("{s} stderr: {s}", .{buf.items});
    }

    const rc = exe.wait() catch |err| {
        switch (err) {
            error.FileNotFound => {
                log.warn("Unable to find {s}. Please install {s} and ensure that it is available on the PATH.", .{
                    exe.argv[0],
                    exe.argv[0],
                });
            },
            else => |e| return e,
        }
        return;
    };

    switch (rc) {
        .Exited => |code| {
            if (code != 0) {
                log.warn("{s} exited with error code {d}", .{ exe.argv[0], code });
            }
        },
        .Signal => |signal| {
            log.warn("{s} was terminaled with signal {}", .{ exe.argv[0], signal });
        },
        .Stopped => |signal| {
            log.warn("{s} was stopped with signal {}", .{ exe.argv[0], signal });
        },
        .Unknown => |code| {
            log.warn("{s} had an unknown error {}", .{ exe.argv[0], code });
        },
    }
}
