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

            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/exe", .{ppid}) catch {
                log.err("unable to format path to exe {d}", .{ppid});
                break :linux false;
            };
            var link_buf: [std.fs.max_path_bytes]u8 = undefined;
            const link = std.fs.readLinkAbsolute(path, &link_buf) catch {
                log.err("unable to read link '{s}'", .{path});
                // Some systems prohibit access to /proc/<pid>/exe for some
                // reason so don't fail if we can't read the link.
                break :linux true;
            };

            if (std.mem.endsWith(u8, link, "/systemd")) break :linux true;

            break :linux false;
        },

        // No other system supports systemd so always return false.
        else => false,
    };
}
