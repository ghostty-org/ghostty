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
file_writer: std.fs.File.Writer = undefined,

/// Initialize the pager. If stdout is a TTY, this spawns the pager
/// process. Otherwise, output goes directly to stdout.
pub fn init(alloc: Allocator) Pager {
    return .{ .child = initPager(alloc) };
}

/// Writes to the pager process if available; otherwise, stdout.
pub fn writer(self: *Pager, buffer: []u8) *std.Io.Writer {
    if (self.child) |child| {
        self.file_writer = child.stdin.?.writer(buffer);
    } else {
        self.file_writer = std.fs.File.stdout().writer(buffer);
    }
    return &self.file_writer.interface;
}

/// Deinitialize the pager. Waits for the spawned process to exit.
pub fn deinit(self: *Pager) void {
    if (self.child) |*child| {
        // Flush any remaining buffered data, close the pipe so the
        // pager sees EOF, then wait for it to exit.
        self.file_writer.interface.flush() catch {};
        if (child.stdin) |stdin| {
            stdin.close();
            child.stdin = null;
        }
        _ = child.wait() catch {};
    }

    self.* = undefined;
}

fn initPager(alloc: Allocator) ?std.process.Child {
    const stdout_file: std.fs.File = .stdout();
    if (!stdout_file.isTty()) return null;

    // Resolve the pager command: $GHOSTTY_PAGER > $PAGER > `less`.
    // An empty value for either env var disables paging.
    const ghostty_var = internal_os.getenv(alloc, "GHOSTTY_PAGER") catch null;
    defer if (ghostty_var) |v| v.deinit(alloc);
    const pager_var = internal_os.getenv(alloc, "PAGER") catch null;
    defer if (pager_var) |v| v.deinit(alloc);

    const cmd: ?[]const u8 = cmd: {
        if (ghostty_var) |v| break :cmd if (v.value.len > 0) v.value else null;
        if (pager_var) |v| break :cmd if (v.value.len > 0) v.value else null;
        break :cmd "less";
    };

    if (cmd == null) return null;

    var child: std.process.Child = .init(&.{cmd.?}, alloc);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    child.spawn() catch return null;
    return child;
}

test "pager: non-tty" {
    var pager: Pager = .init(std.testing.allocator);
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
