//! The "os" package contains utilities for interfacing with the operating
//! system.

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
pub const TempDir = @import("TempDir.zig");
pub const passwd = @import("passwd.zig");
pub const xdg = @import("xdg.zig");
pub const windows = @import("windows.zig");
