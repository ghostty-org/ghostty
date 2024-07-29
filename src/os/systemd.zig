const std = @import("std");
const builtin = @import("builtin");

/// Returns true if the program was launched as a systemd service.
///
/// On Linux, this returns true if the program was launched as a systemd
/// service. It will return false if Ghostty was launched any other way.
///
/// For other platforms and app runtimes, this returns false.
pub fn launchedBySystemd() bool {
    return switch (builtin.os.tag) {
        // On Linux, systemd sets the `INVOCATION_ID` (v232+) and the
        // `JOURNAL_STREAM` (v231+) enviroment variables. If these environment
        // variables are present (no matter the value) we were launched by
        // systemd. This can be fooled if Ghostty is launched from another
        // terminal that does not clean up these environment variables.
        .linux => std.posix.getenv("INVOCATION_ID") != null and std.posix.getenv("JOURNAL_STREAM") != null,

        // No other system supports systemd so always return false.
        else => false,
    };
}
