const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("../build_config.zig");
const posix = std.posix;

const c = @cImport({
    @cInclude("unistd.h");
});

/// Returns true if the program was launched from a desktop environment.
///
/// On macOS, this returns true if the program was launched from Finder.
///
/// On Linux GTK, this returns true if the program was launched using the
/// desktop file. This also includes when `gtk-launch` is used because I
/// can't find a way to distinguish the two scenarios.
///
/// For other platforms and app runtimes, this returns false.
pub fn launchedFromDesktop() bool {
    return switch (builtin.os.tag) {
        // macOS apps launched from finder or `open` always have the init
        // process as their parent.
        .macos => macos: {
            // This special case is so that if we launch the app via the
            // app bundle (i.e. via open) then we still treat it as if it
            // was launched from the desktop.
            if (build_config.artifact == .lib and
                posix.getenv("GHOSTTY_MAC_APP") != null) break :macos true;

            break :macos c.getppid() == 1;
        },

        // On Linux and BSD, GTK sets GIO_LAUNCHED_DESKTOP_FILE and
        // GIO_LAUNCHED_DESKTOP_FILE_PID. We only check the latter to see if
        // we match the PID and assume that if we do, we were launched from
        // the desktop file. Pid comparing catches the scenario where
        // another terminal was launched from a desktop file and then launches
        // Ghostty and Ghostty inherits the env.
        .linux, .freebsd => ul: {
            const gio_pid_str = posix.getenv("GIO_LAUNCHED_DESKTOP_FILE_PID") orelse
                break :ul false;

            const pid = c.getpid();
            const gio_pid = std.fmt.parseInt(
                @TypeOf(pid),
                gio_pid_str,
                10,
            ) catch break :ul false;

            break :ul gio_pid == pid;
        },

        // TODO: This should have some logic to detect this. Perhaps std.builtin.subsystem
        .windows => false,

        // iPhone/iPad is always launched from the "desktop"
        .ios => true,

        else => @compileError("unsupported platform"),
    };
}

/// The list of desktop environments that we detect. New Linux desktop
/// environments should only be added to this list if there's a specific reason
/// to differentiate between `gnome` and `other`.
pub const DesktopEnvironment = enum {
    gnome,
    macos,
    other,
    windows,
};

/// Detect what desktop environment we are running under. This is mainly used
/// on Linux and BSD to enable or disable certain features but there may be more uses in
/// the future.
pub fn desktopEnvironment() DesktopEnvironment {
    return switch (comptime builtin.os.tag) {
        .macos => .macos,
        .windows => .windows,
        .linux, .freebsd => de: {
            if (@inComptime()) @compileError("Checking for the desktop environment on Linux/BSD must be done at runtime.");

            // Use $XDG_SESSION_DESKTOP to determine what DE we are using on Linux
            // https://www.freedesktop.org/software/systemd/man/latest/pam_systemd.html#desktop=
            if (posix.getenv("XDG_SESSION_DESKTOP")) |sd| {
                if (std.ascii.eqlIgnoreCase("gnome", sd)) break :de .gnome;
                if (std.ascii.eqlIgnoreCase("gnome-xorg", sd)) break :de .gnome;
            }

            // If $XDG_SESSION_DESKTOP is not set, or doesn't match any known
            // DE, check $XDG_CURRENT_DESKTOP. $XDG_CURRENT_DESKTOP is a
            // colon-separated list of up to three desktop names, although we
            // only look at the first.
            // https://specifications.freedesktop.org/desktop-entry-spec/latest/recognized-keys.html
            if (posix.getenv("XDG_CURRENT_DESKTOP")) |cd| {
                var cd_it = std.mem.splitScalar(u8, cd, ':');
                const cd_first = cd_it.first();
                if (std.ascii.eqlIgnoreCase(cd_first, "gnome")) break :de .gnome;
            }

            break :de .other;
        },
        else => .other,
    };
}

test "desktop environment" {
    const testing = std.testing;

    switch (builtin.os.tag) {
        .macos => try testing.expectEqual(.macos, desktopEnvironment()),
        .windows => try testing.expectEqual(.windows, desktopEnvironment()),
        .linux, .freebsd => {
            const getenv = std.posix.getenv;
            const setenv = @import("env.zig").setenv;
            const unsetenv = @import("env.zig").unsetenv;

            const xdg_current_desktop = getenv("XDG_CURRENT_DESKTOP");
            defer if (xdg_current_desktop) |v| {
                _ = setenv("XDG_CURRENT_DESKTOP", v);
            } else {
                _ = unsetenv("XDG_CURRENT_DESKTOP");
            };
            _ = unsetenv("XDG_CURRENT_DESKTOP");

            const xdg_session_desktop = getenv("XDG_SESSION_DESKTOP");
            defer if (xdg_session_desktop) |v| {
                _ = setenv("XDG_SESSION_DESKTOP", v);
            } else {
                _ = unsetenv("XDG_SESSION_DESKTOP");
            };
            _ = unsetenv("XDG_SESSION_DESKTOP");

            _ = setenv("XDG_SESSION_DESKTOP", "gnome");
            try testing.expectEqual(.gnome, desktopEnvironment());
            _ = setenv("XDG_SESSION_DESKTOP", "gnome-xorg");
            try testing.expectEqual(.gnome, desktopEnvironment());
            _ = setenv("XDG_SESSION_DESKTOP", "foobar");
            try testing.expectEqual(.other, desktopEnvironment());

            _ = unsetenv("XDG_SESSION_DESKTOP");
            try testing.expectEqual(.other, desktopEnvironment());

            _ = setenv("XDG_CURRENT_DESKTOP", "GNOME");
            try testing.expectEqual(.gnome, desktopEnvironment());
            _ = setenv("XDG_CURRENT_DESKTOP", "FOOBAR");
            try testing.expectEqual(.other, desktopEnvironment());
            _ = unsetenv("XDG_CURRENT_DESKTOP");
            try testing.expectEqual(.other, desktopEnvironment());
        },
        else => try testing.expectEqual(.other, DesktopEnvironment()),
    }
}
