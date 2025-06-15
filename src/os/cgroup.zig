const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const posix = std.posix;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.@"linux-cgroup");

/// Returns the path to the cgroup for the given pid.
pub fn current(alloc: Allocator, pid: std.os.linux.pid_t) !?[]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;

    // Read our cgroup by opening /proc/<pid>/cgroup and reading the first
    // line. The first line will look something like this:
    // 0::/user.slice/user-1000.slice/session-1.scope
    // The cgroup path is the third field.
    const path = try std.fmt.bufPrint(&buf, "/proc/{}/cgroup", .{pid});
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    // Read it all into memory -- we don't expect this file to ever be that large.
    var buf_reader = std.io.bufferedReader(file.reader());
    const contents = try buf_reader.reader().readAllAlloc(
        alloc,
        1 * 1024 * 1024, // 1MB
    );
    defer alloc.free(contents);

    // Find the last ':'
    const idx = std.mem.lastIndexOfScalar(u8, contents, ':') orelse return null;
    const result = std.mem.trimRight(u8, contents[idx + 1 ..], " \r\n");
    return try alloc.dupe(u8, result);
}

/// Create a new cgroup. This will not move any process into it unless move is
/// set. If move is set, the given pid will be moved into the created cgroup.
pub fn create(
    cgroup: []const u8,
    child: []const u8,
    move: ?std.os.linux.pid_t,
) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/sys/fs/cgroup{s}/{s}", .{ cgroup, child });
    try std.fs.cwd().makePath(path);

    // If we have a PID to move into the cgroup immediately, do it.
    if (move) |pid| {
        const pid_path = try std.fmt.bufPrint(
            &buf,
            "/sys/fs/cgroup{s}/{s}/cgroup.procs",
            .{ cgroup, child },
        );
        const file = try std.fs.cwd().openFile(pid_path, .{ .mode = .write_only });
        defer file.close();
        try file.writer().print("{}", .{pid});
    }
}

/// Remove a cgroup. This will only succeed if the cgroup is empty
/// (has no processes). The cgroup path should be relative to the
/// cgroup root (e.g. "/user.slice/surfaces/abc123.scope").
pub fn remove(cgroup: []const u8) !void {
    assert(cgroup.len > 0);
    assert(cgroup[0] == '/');

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/sys/fs/cgroup{s}", .{cgroup});
    std.fs.cwd().deleteDir(path) catch |err| switch (err) {
        // If it doesn't exist, that's fine - maybe it was already cleaned up
        error.FileNotFound => {},

        // Any other error we failed to delete it so we want to notify
        // the user.
        else => return err,
    };
}

/// Move the given PID into the given cgroup.
pub fn moveInto(
    cgroup: []const u8,
    pid: std.os.linux.pid_t,
) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/sys/fs/cgroup{s}/cgroup.procs", .{cgroup});
    const file = try std.fs.cwd().openFile(path, .{ .mode = .write_only });
    defer file.close();
    try file.writer().print("{}", .{pid});
}

/// Use clone3 to have the kernel create a new process with the correct cgroup
/// rather than moving the process to the correct cgroup later.
pub fn cloneInto(cgroup: []const u8) !posix.pid_t {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&buf, "/sys/fs/cgroup{s}", .{cgroup});

    // Get a file descriptor that refers to the cgroup directory in the cgroup
    // sysfs to pass to the kernel in clone3.
    const fd: linux.fd_t = fd: {
        const rc = linux.open(
            path,
            .{
                // Self-explanatory: we expect to open a directory, and
                // we only need the path-level permissions.
                .PATH = true,
                .DIRECTORY = true,

                // We don't want to leak this fd to the child process
                // when we clone below since we're using this fd for
                // a cgroup clone.
                .CLOEXEC = true,
            },
            0,
        );

        switch (posix.errno(rc)) {
            .SUCCESS => break :fd @as(linux.fd_t, @intCast(rc)),
            else => |errno| {
                log.err("unable to open cgroup dir {s}: {}", .{ path, errno });
                return error.CloneError;
            },
        }
    };
    assert(fd >= 0);
    defer _ = linux.close(fd);

    const args: extern struct {
        flags: u64,
        pidfd: u64,
        child_tid: u64,
        parent_tid: u64,
        exit_signal: u64,
        stack: u64,
        stack_size: u64,
        tls: u64,
        set_tid: u64,
        set_tid_size: u64,
        cgroup: u64,
    } = .{
        .flags = linux.CLONE.INTO_CGROUP,
        .pidfd = 0,
        .child_tid = 0,
        .parent_tid = 0,
        .exit_signal = linux.SIG.CHLD,
        .stack = 0,
        .stack_size = 0,
        .tls = 0,
        .set_tid = 0,
        .set_tid_size = 0,
        .cgroup = @intCast(fd),
    };

    const rc = linux.syscall2(linux.SYS.clone3, @intFromPtr(&args), @sizeOf(@TypeOf(args)));
    // do not use posix.errno, when linking libc it will use the libc errno which will not be set when making the syscall directly
    return switch (std.os.linux.E.init(rc)) {
        .SUCCESS => @as(posix.pid_t, @intCast(rc)),
        else => |errno| err: {
            log.err("unable to clone: {}", .{errno});
            break :err error.CloneError;
        },
    };
}

/// Returns all available cgroup controllers for the given cgroup.
/// The cgroup should have a '/'-prefix.
///
/// The returned list of is the raw space-separated list of
/// controllers from the /sys/fs directory. This avoids some extra
/// work since creating an iterator over this is easy and much cheaper
/// than allocating a bunch of copies for an array.
pub fn controllers(alloc: Allocator, cgroup: []const u8) ![]const u8 {
    assert(cgroup[0] == '/');
    var buf: [std.fs.max_path_bytes]u8 = undefined;

    // Read the available controllers. These will be space separated.
    const path = try std.fmt.bufPrint(
        &buf,
        "/sys/fs/cgroup{s}/cgroup.controllers",
        .{cgroup},
    );
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    // Read it all into memory -- we don't expect this file to ever
    // be that large.
    var buf_reader = std.io.bufferedReader(file.reader());
    const contents = try buf_reader.reader().readAllAlloc(
        alloc,
        1 * 1024 * 1024, // 1MB
    );
    defer alloc.free(contents);

    // Return our raw list of controllers
    const result = std.mem.trimRight(u8, contents, " \r\n");
    return try alloc.dupe(u8, result);
}

/// Configure the set of controllers in the cgroup. The "v" should
/// be in a valid format for "cgroup.subtree_control"
pub fn configureControllers(
    cgroup: []const u8,
    v: []const u8,
) !void {
    assert(cgroup[0] == '/');
    var buf: [std.fs.max_path_bytes]u8 = undefined;

    // Read the available controllers. These will be space separated.
    const path = try std.fmt.bufPrint(
        &buf,
        "/sys/fs/cgroup{s}/cgroup.subtree_control",
        .{cgroup},
    );
    const file = try std.fs.cwd().openFile(path, .{ .mode = .write_only });
    defer file.close();

    // Write
    try file.writer().writeAll(v);
}

pub const Limit = union(enum) {
    memory_high: usize,
    pids_max: usize,
};

/// Configure a limit for the given cgroup. Use the various
/// fields in Limit to configure a specific type of limit.
pub fn configureLimit(cgroup: []const u8, limit: Limit) !void {
    assert(cgroup[0] == '/');

    const filename, const size = switch (limit) {
        .memory_high => |v| .{ "memory.high", v },
        .pids_max => |v| .{ "pids.max", v },
    };

    // Open our file
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &buf,
        "/sys/fs/cgroup{s}/{s}",
        .{ cgroup, filename },
    );
    const file = try std.fs.cwd().openFile(path, .{ .mode = .write_only });
    defer file.close();

    // Write our limit in bytes
    try file.writer().print("{}", .{size});
}
