const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.systemd);

const c = @cImport({
    @cInclude("unistd.h");
});

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
            // `JOURNAL_STREAM` (v231+) enviroment variables. If these
            // environment variables are not present we were not launched by
            // systemd.

            if (std.posix.getenv("INVOCATION_ID") == null) break :linux false;
            if (std.posix.getenv("JOURNAL_STREAM") == null) break :linux false;

            // If `INVOCATION_ID` and `JOURNAL_STREAM` are present, check to make sure
            // that our parent process is actually `systemd`, not some other terminal
            // emulator that doesn't clean up those environment variables.

            const ppid = c.getppid();

            // If the parent PID is 1 we'll assume that it's `systemd` as other init systems
            // are unlikely.

            if (ppid == 1) break :linux true;

            // If the parent PID is not 1 we need to check to see if we were launched by
            // a user systemd daemon. Do that by checking the `/proc/<ppid>/exe` symlink
            // to see if it ends with `/systemd`.

            var exe_path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const exe_path = std.fmt.bufPrint(&exe_path_buf, "/proc/{d}/exe", .{ppid}) catch {
                log.err("unable to format path to exe for pid {d}", .{ppid});
                break :linux false;
            };
            var exe_link_buf: [std.fs.max_path_bytes]u8 = undefined;
            const exe_link = std.fs.readLinkAbsolute(exe_path, &exe_link_buf) catch {
                log.err("unable to read link '{s}'", .{exe_path});

                // Some systems prohibit access to /proc/<pid>/exe for some
                // reason so fall back to reading /proc/<pid>/comm and see if it
                // is equal to "systemd".

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

                var comm_data_buf: [std.fs.MAX_NAME_BYTES]u8 = undefined;
                const comm_size = comm_file.readAll(&comm_data_buf) catch {
                    log.err("problems reading from '{s}'", .{comm_path});
                    break :linux false;
                };
                const comm_data = comm_data_buf[0..comm_size];

                if (std.mem.eql(u8, comm_data, "systemd")) break :linux true;

                break :linux false;
            };

            if (std.mem.endsWith(u8, exe_link, "/systemd")) break :linux true;

            break :linux false;
        },

        // No other system supports systemd so always return false.
        else => false,
    };
}
