//! A pager wraps output to an external pager program (like `less`) when
//! stdout is a TTY. The pager command is resolved as:
//!
//!   `$GHOSTTY_PAGER` > `$PAGER` > `less`
//!
//! Setting either env var to an empty string disables paging.
//! If stdout is not a TTY, writes go directly to stdout.
const Pager = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const internal_os = @import("../os/main.zig");

/// The pager child process, if one was spawned.
child: ?std.process.Child = null,

/// The buffered file writer used for both the pager pipe and direct
/// stdout paths.
file_writer: std.Io.File.Writer = undefined,

/// Initialize the pager. If stdout is a TTY, this spawns the pager
/// process. Otherwise, output goes directly to stdout.
pub fn init(io: std.Io, env: *const std.process.Environ.Map) Pager {
    return .{
        .io = io,
        .child = initPager(io, env),
    };
}

/// Writes to the pager process if available; otherwise, stdout.
pub fn writer(self: *Pager, io: std.Io, buffer: []u8) *std.Io.Writer {
    if (self.child) |child| {
        self.file_writer = child.stdin.?.writer(io, buffer);
    } else {
        self.file_writer = std.Io.File.stdout().writer(io, buffer);
    }
    return &self.file_writer.interface;
}

/// Deinitialize the pager. Waits for the spawned process to exit.
pub fn deinit(self: *Pager, io: std.Io) void {
    if (self.child) |*child| {
        // Flush any remaining buffered data, close the pipe so the
        // pager sees EOF, then wait for it to exit.
        self.file_writer.interface.flush() catch {};
        if (child.stdin) |stdin| {
            stdin.close(io);
            child.stdin = null;
        }
        _ = child.wait(io) catch {};
    }

    self.* = undefined;
}

fn initPager(io: std.Io, env: *const std.process.Environ.Map) ?std.process.Child {
    const stdout_file: std.Io.File = .stdout();
    const is_tty = stdout_file.isTty(io) catch return null;
    if (!is_tty) return null;

    // Resolve the pager command: $GHOSTTY_PAGER > $PAGER > `less`.
    // An empty value for either env var disables paging.
    const ghostty_var = env.get("GHOSTTY_PAGER") catch return null;
    const pager_var = env.get("PAGER") catch return null;

    const cmd: []const u8 = cmd: {
        if (ghostty_var) |v| break :cmd if (v.value.len > 0) v.value else return null;
        if (pager_var) |v| break :cmd if (v.value.len > 0) v.value else return null;
        break :cmd "less";
    };

    return std.process.spawn(io, .{
        .argv = &.{cmd},
        .stdin = .pipe,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch null;
}

test "pager: non-tty" {
    var pager: Pager = .init(
        std.testing.allocator,
        std.testing.io,
        std.testing.environ,
    );
    defer pager.deinit();
    try std.testing.expect(pager.child == null);
}

test "pager: default writer" {
    var pager: Pager = .{};
    defer pager.deinit();
    try std.testing.expect(pager.child == null);
    var buf: [4096]u8 = undefined;
    const w = pager.writer(&buf);
    try w.writeAll("hello");
}
