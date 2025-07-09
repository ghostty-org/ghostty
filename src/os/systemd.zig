const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.systemd);

/// Returns true if the program was launched as a systemd service.
///
/// On Linux, this returns true if the program was launched as a systemd
/// service. It will return false if Ghostty was launched any other way.
///
/// For other platforms and app runtimes, this returns false.
pub fn launchedBySystemd() bool {
    return switch (builtin.os.tag) {
        .linux => linux: {
            // On Linux, systemd sets the `INVOCATION_ID` (v232+) and the
            // `JOURNAL_STREAM` (v231+) environment variables. If these
            // environment variables are not present we were not launched by
            // systemd.
            if (std.posix.getenv("INVOCATION_ID") == null) break :linux false;
            if (std.posix.getenv("JOURNAL_STREAM") == null) break :linux false;

            // If `INVOCATION_ID` and `JOURNAL_STREAM` are present, check to make sure
            // that our parent process is actually `systemd`, not some other terminal
            // emulator that doesn't clean up those environment variables.
            const ppid = std.os.linux.getppid();
            if (ppid == 1) break :linux true;

            // If the parent PID is not 1 we need to check to see if we were launched by
            // a user systemd daemon. Do that by checking the `/proc/<ppid>/comm`
            // to see if it ends with `systemd`.
            var comm_path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const comm_path = std.fmt.bufPrint(&comm_path_buf, "/proc/{d}/comm", .{ppid}) catch {
                log.err("unable to format comm path for pid {d}", .{ppid});
                break :linux false;
            };
            const comm_file = std.fs.openFileAbsolute(comm_path, .{ .mode = .read_only }) catch {
                log.err("unable to open '{s}' for reading", .{comm_path});
                break :linux false;
            };
            defer comm_file.close();

            // The maximum length of the command name is defined by
            // `TASK_COMM_LEN` in the Linux kernel. This is usually 16
            // bytes at the time of writing (Jun 2025) so its set to that.
            // Also, since we only care to compare to "systemd", anything
            // longer can be assumed to not be systemd.
            const TASK_COMM_LEN = 16;
            var comm_data_buf: [TASK_COMM_LEN]u8 = undefined;
            const comm_size = comm_file.readAll(&comm_data_buf) catch {
                log.err("problems reading from '{s}'", .{comm_path});
                break :linux false;
            };
            const comm_data = comm_data_buf[0..comm_size];

            break :linux std.mem.eql(
                u8,
                std.mem.trimRight(u8, comm_data, "\n"),
                "systemd",
            );
        },

        // No other system supports systemd so always return false.
        else => false,
    };
}

/// systemd notifications. Used by Ghostty to inform systemd of the state of the
/// process. Currently only used to notify systemd that we are ready and that
/// configuration reloading has started.
///
/// See: https://www.freedesktop.org/software/systemd/man/latest/sd_notify.html
///
/// These functions were re-implemented in Zig instead of using the `libsystemd`
/// library to avoid the complexity of another external dependency, as well as
/// to take advantage of Zig features like `comptime` to ensure minimal impact
/// on non-Linux systems (like FreeBSD) that will never support `systemd`.
///
/// Linux systems that do not use `systemd` should not be impacted as they
/// should never start Ghostty with the `NOTIFY_SOCKET` environment variable set
/// and these functions essentially become a no-op.
///
/// See `systemd`'s [Interface Portability and Stability Promise](https://systemd.io/PORTABILITY_AND_STABILITY/)
/// for assurances that the interfaces used here will be supported and stable for
/// the long term.
pub const notify = struct {
    /// Send the given message to the UNIX socket specified in the NOTIFY_SOCKET
    /// environment variable. If there NOTIFY_SOCKET environment variable does
    /// not exist then no message is sent.
    fn send(message: []const u8) void {
        // systemd is Linux-only so this is a no-op anywhere else
        if (comptime builtin.os.tag != .linux) return;

        // Get the socket address that should receive notifications.
        const socket_path = std.posix.getenv("NOTIFY_SOCKET") orelse return;

        // If the socket address is an empty string return.
        if (socket_path.len == 0) return;

        // The socket address must be a path or an abstract socket.
        if (socket_path[0] != '/' and socket_path[0] != '@') {
            log.warn("only AF_UNIX sockets with path or abstract namespace addresses are supported!", .{});
            return;
        }

        var socket_address: std.os.linux.sockaddr.un = undefined;

        // Error out if the supplied socket path is too long.
        if (socket_address.path.len < socket_path.len) {
            log.warn("NOTIFY_SOCKET path is too long!", .{});
            return;
        }

        socket_address.family = std.os.linux.AF.UNIX;

        @memcpy(socket_address.path[0..socket_path.len], socket_path);
        socket_address.path[socket_path.len] = 0;

        const socket: std.os.linux.socket_t = socket: {
            const rc = std.os.linux.socket(
                std.os.linux.AF.UNIX,
                std.os.linux.SOCK.DGRAM | std.os.linux.SOCK.CLOEXEC,
                0,
            );
            switch (std.os.linux.E.init(rc)) {
                .SUCCESS => break :socket @intCast(rc),
                else => |e| {
                    log.warn("creating socket failed: {s}", .{@tagName(e)});
                    return;
                },
            }
        };

        defer _ = std.os.linux.close(socket);

        connect: {
            const rc = std.os.linux.connect(
                socket,
                &socket_address,
                @offsetOf(std.os.linux.sockaddr.un, "path") + socket_address.path.len,
            );
            switch (std.os.linux.E.init(rc)) {
                .SUCCESS => break :connect,
                else => |e| {
                    log.warn("unable to connect to notify socket: {s}", .{@tagName(e)});
                    return;
                },
            }
        }

        write: {
            const rc = std.os.linux.write(socket, message.ptr, message.len);
            switch (std.os.linux.E.init(rc)) {
                .SUCCESS => {
                    const written = rc;
                    if (written < message.len) {
                        log.warn("short write to notify socket: {d} < {d}", .{ rc, message.len });
                        return;
                    }
                    break :write;
                },
                else => |e| {
                    log.warn("unable to write to notify socket: {s}", .{@tagName(e)});
                    return;
                },
            }
        }
    }

    /// Tell systemd that we are ready or that we are finished reloading.
    /// See: https://www.freedesktop.org/software/systemd/man/latest/sd_notify.html#READY=1
    pub fn ready() void {
        if (comptime builtin.os.tag != .linux) return;

        send("READY=1");
    }

    /// Tell systemd that we have started reloading our configuration.
    /// See: https://www.freedesktop.org/software/systemd/man/latest/sd_notify.html#RELOADING=1
    /// and: https://www.freedesktop.org/software/systemd/man/latest/sd_notify.html#MONOTONIC_USEC=%E2%80%A6
    pub fn reloading() void {
        if (comptime builtin.os.tag != .linux) return;

        const ts = std.posix.clock_gettime(.MONOTONIC) catch |err| {
            log.err("unable to get MONOTONIC clock: {}", .{err});
            return;
        };

        const now = ts.sec * std.time.us_per_s + @divFloor(ts.nsec, std.time.ns_per_us);

        var buffer: [64]u8 = undefined;
        const message = std.fmt.bufPrint(&buffer, "RELOADING=1\nMONOTONIC_USEC={d}", .{now}) catch |err| {
            log.err("unable to format reloading message: {}", .{err});
            return;
        };

        send(message);
    }
};
