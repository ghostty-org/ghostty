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

        // On Linux, GTK sets GIO_LAUNCHED_DESKTOP_FILE and
        // GIO_LAUNCHED_DESKTOP_FILE_PID. We only check the latter to see if
        // we match the PID and assume that if we do, we were launched from
        // the desktop file. Pid comparing catches the scenario where
        // another terminal was launched from a desktop file and then launches
        // Ghostty and Ghostty inherits the env.
        .linux => linux: {
            const gio_pid_str = posix.getenv("GIO_LAUNCHED_DESKTOP_FILE_PID") orelse
                break :linux false;

            const pid = c.getpid();
            const gio_pid = std.fmt.parseInt(
                @TypeOf(pid),
                gio_pid_str,
                10,
            ) catch break :linux false;

            break :linux gio_pid == pid;
        },

        // TODO: This should have some logic to detect this. Perhaps std.builtin.subsystem
        .windows => false,

        // iPhone/iPad is always launched from the "desktop"
        .ios => true,

        else => @compileError("unsupported platform"),
    };
}

pub const DesktopEnvironment = enum {
    gnome,
    macos,
    other,
    windows,
};

/// Detect what desktop environment we are running under. This is mainly used on
/// Linux to enable or disable GTK client-side decorations but there may be more
/// uses in the future.
pub fn desktopEnvironment() DesktopEnvironment {
    return switch (comptime builtin.os.tag) {
        .macos => .macos,
        .windows => .windows,
        .linux => de: {
            if (@inComptime()) @compileError("Checking for the desktop environment on Linux must be done at runtime.");
            // use $XDG_SESSION_DESKTOP to determine what DE we are using on Linux
            // https://www.freedesktop.org/software/systemd/man/latest/pam_systemd.html#desktop=
            const de = posix.getenv("XDG_SESSION_DESKTOP") orelse break :de .other;
            if (std.ascii.eqlIgnoreCase("gnome", de)) break :de .gnome;
            break :de .other;
        },
        else => .other,
    };
}

pub const DisplayType = enum {
    macos,
    other,
    wayland,
    windows,
    x11,
};

/// Detect what desktop environment we are running under. This is mainly used on
/// Linux to enable or disable GTK client-side decorations but there may be more
/// uses in the future.
pub fn displayType() DisplayType {
    return switch (comptime builtin.os.tag) {
        .macos => .macos,
        .windows => .windows,
        .linux => dt: {
            if (@inComptime()) @compileError("Checking for the display type on Linux must be done at runtime.");
            // use $XDG_SESSION_TYPE to determine what display type we are using on Linux
            const dt = posix.getenv("XDG_SESSION_TYPE") orelse break :dt .other;
            if (std.ascii.eqlIgnoreCase("wayland", dt)) break :dt .wayland;
            if (std.ascii.eqlIgnoreCase("x11", dt)) break :dt .x11;
            break :dt .other;
        },
        else => .other,
    };
}
