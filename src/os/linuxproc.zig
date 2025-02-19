const ProcessScanner = @This();

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

const log = std.log.scoped(.linuxproc);

/// Information about a Linux process that we are interested in
pub const LinuxProcessInfo = struct {
    /// This PID of the process.
    pid: linux.pid_t,
    /// The parent PID of the process.
    ppid: linux.pid_t,
    /// If the process is named 'ssh'.
    ssh: bool,
    /// If the process has an effective UID of 0.
    elevated: bool,
};

pub const LinuxProcessInfoContext = struct {
    pub fn hash(_: LinuxProcessInfoContext, pid: linux.pid_t) u32 {
        return std.hash.XxHash32.hash(0, std.mem.asBytes(&pid));
    }

    pub fn eql(_: LinuxProcessInfoContext, a: linux.pid_t, b: linux.pid_t, b_index: usize) bool {
        _ = b_index;
        return a == b;
    }
};

pub const Error = std.mem.Allocator.Error || std.fs.File.OpenError || std.fs.File.ReadError;

pub fn getProcessInfo(pid: linux.pid_t) Error!?LinuxProcessInfo {
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const alloc = fba.allocator();

    const pathname = try std.fs.path.join(
        alloc,
        &.{
            "/proc",
            try std.fmt.allocPrint(alloc, "{}", .{pid}),
            "status",
        },
    );

    const status_file = std.fs.openFileAbsolute(pathname, .{ .mode = .read_only }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    defer status_file.close();

    const data = status_file.readToEndAlloc(alloc, 2048) catch |err| switch (err) {
        error.FileTooBig => {
            log.warn("{s} too big", .{pathname});
            return null;
        },
        else => |e| return e,
    };

    var ppid_: ?std.os.linux.pid_t = null;
    var uid_effective_: ?std.os.linux.uid_t = null;
    var ssh: bool = false;

    // for the format of /proc/$pid/status see:
    // https://man7.org/linux/man-pages/man5/proc_pid_status.5.html

    var lines = std.mem.splitScalar(u8, data, '\n');

    while (lines.next()) |line| {
        var kv = std.mem.splitSequence(u8, line, ":\t");
        const key = kv.first();
        const value = kv.rest();
        const field = std.meta.stringToEnum(
            // The keys in this enum must match the name of a field in /proc/$pid/status
            enum {
                Name,
                PPid,
                Uid,
            },
            key,
        ) orelse continue;
        switch (field) {
            .Name => {
                if (std.mem.eql(u8, value, "ssh")) ssh = true;
            },
            .PPid => {
                ppid_ = std.fmt.parseUnsigned(
                    std.os.linux.pid_t,
                    value,
                    10,
                ) catch continue;
            },
            .Uid => {
                var u_it = std.mem.splitScalar(u8, value, '\t');

                _ = u_it.next() orelse continue;

                uid_effective_ = std.fmt.parseUnsigned(
                    std.os.linux.uid_t,
                    u_it.next() orelse continue,
                    10,
                ) catch continue;

                // this is the last thing we need so don't parse the rest of the file
                break;
            },
        }
    }

    return .{
        .pid = pid,
        .ppid = ppid_ orelse return null,
        .ssh = ssh,
        .elevated = (uid_effective_ orelse return null) == 0,
    };
}

pub const Iterator = struct {
    dir: std.fs.Dir,
    iterator: std.fs.Dir.Iterator,

    pub fn init() !Iterator {
        var dir = try std.fs.openDirAbsolute("/proc", .{ .iterate = true });
        const iterator = dir.iterate();
        return .{
            .dir = dir,
            .iterator = iterator,
        };
    }

    pub fn deinit(self: *Iterator) void {
        self.dir.close();
    }

    pub fn next(self: *Iterator) !?LinuxProcessInfo {
        while (try self.iterator.next()) |file| {
            switch (file.kind) {
                .directory => {
                    const pid = std.fmt.parseUnsigned(linux.pid_t, file.name, 10) catch continue;
                    const info = try getProcessInfo(pid) orelse continue;
                    return info;
                },
                else => {},
            }
        }
        return null;
    }
};
