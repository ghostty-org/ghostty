const std = @import("std");
const builtin = @import("builtin");

/// Returns true if the program was launched by D-Bus activation.
///
/// On Linux GTK, this returns true if the program was launched using D-Bus
/// activation. It will return false if Ghostty was launched any other way.
///
/// For other platforms and app runtimes, this returns false.
pub fn launchedByDbusActivation() bool {
    return switch (builtin.os.tag) {
        // On Linux, D-Bus activation sets `DBUS_STARTER_ADDRESS` and
        // `DBUS_STARTER_BUS_TYPE`. If these environment variables are present
        // (no matter the value) we were launched by D-Bus activation.
        .linux => std.posix.getenv("DBUS_STARTER_ADDRESS") != null and
            std.posix.getenv("DBUS_STARTER_BUS_TYPE") != null,

        // No other system supports D-Bus so always return false.
        else => false,
    };
}
