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
