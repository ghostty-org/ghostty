//! The "os" package contains utilities for interfacing with the operating
//! system. These aren't restricted to syscalls or low-level operations, but
//! also OS-specific features and conventions.

pub usingnamespace @import("env.zig");
pub usingnamespace @import("dbus.zig");
pub usingnamespace @import("desktop.zig");
pub usingnamespace @import("file.zig");
pub usingnamespace @import("flatpak.zig");
pub usingnamespace @import("homedir.zig");
pub usingnamespace @import("locale.zig");
pub usingnamespace @import("macos_version.zig");
pub usingnamespace @import("mouse.zig");
pub usingnamespace @import("open.zig");
pub usingnamespace @import("pipe.zig");
pub usingnamespace @import("resourcesdir.zig");
pub usingnamespace @import("systemd.zig");
pub const CFReleaseThread = @import("cf_release_thread.zig");
pub const TempDir = @import("TempDir.zig");
pub const cgroup = @import("cgroup.zig");
pub const passwd = @import("passwd.zig");
pub const xdg = @import("xdg.zig");
pub const windows = @import("windows.zig");
