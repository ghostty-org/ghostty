//! The "os" package contains utilities for interfacing with the operating
//! system. These aren't restricted to syscalls or low-level operations, but
//! also OS-specific features and conventions.

const std = @import("std");
const builtin = @import("builtin");

const dbus = if (builtin.os.tag == .linux) @import("dbus.zig") else struct {
    pub fn launchedByDbusActivation() bool {
        return false;
    }
};
const desktop = if (builtin.os.tag == .windows) struct {
    pub const DesktopEnvironment = enum {
        gnome,
        macos,
        other,
        windows,
    };

    pub fn launchedFromDesktop() bool {
        return false;
    }

    pub fn desktopEnvironment() DesktopEnvironment {
        return .windows;
    }
} else @import("desktop.zig");
const env = @import("env.zig");
const file = @import("file.zig");
const flatpak = if (builtin.os.tag == .linux) @import("flatpak.zig") else struct {
    pub fn isFlatpak() bool {
        return false;
    }

    pub const FlatpakHostCommand = struct {
        pub const Completion = struct {};
    };
};
const homedir = @import("homedir.zig");
const locale = @import("locale.zig");
const mouse = @import("mouse.zig");
const openpkg = @import("open.zig");
const pipepkg = @import("pipe.zig");
const resourcesdir = @import("resourcesdir.zig");
const systemd = if (builtin.os.tag == .linux) @import("systemd.zig") else struct {
    pub fn launchedBySystemd() bool {
        return false;
    }
};
const kernel_info = if (builtin.os.tag == .linux) @import("kernel_info.zig") else struct {
    pub fn getKernelInfo(_: std.mem.Allocator) ?[]const u8 {
        return null;
    }
};

// Namespaces
pub const args = @import("args.zig");
pub const cgroup = @import("cgroup.zig");
pub const hostname = @import("hostname.zig");
pub const i18n = @import("i18n.zig");
pub const mach = if (builtin.os.tag.isDarwin()) @import("mach.zig") else struct {};
pub const path = @import("path.zig");
pub const passwd = @import("passwd.zig");
pub const xdg = @import("xdg.zig");
pub const windows = @import("windows.zig");
pub const macos = if (builtin.os.tag.isDarwin()) @import("macos.zig") else struct {};
pub const shell = @import("shell.zig");
pub const uri = @import("uri.zig");

// Functions and types
pub const CFReleaseThread = if (builtin.os.tag.isDarwin()) @import("cf_release_thread.zig") else struct {};
pub const TempDir = @import("TempDir.zig");
pub const GetEnvResult = env.GetEnvResult;
pub const getEnvMap = env.getEnvMap;
pub const appendEnv = env.appendEnv;
pub const appendEnvAlways = env.appendEnvAlways;
pub const prependEnv = env.prependEnv;
pub const getenv = env.getenv;
pub const setenv = env.setenv;
pub const unsetenv = env.unsetenv;
pub const launchedFromDesktop = desktop.launchedFromDesktop;
pub const launchedByDbusActivation = dbus.launchedByDbusActivation;
pub const launchedBySystemd = systemd.launchedBySystemd;
pub const desktopEnvironment = desktop.desktopEnvironment;
pub const rlimit = file.rlimit;
pub const fixMaxFiles = file.fixMaxFiles;
pub const restoreMaxFiles = file.restoreMaxFiles;
pub const allocTmpDir = file.allocTmpDir;
pub const freeTmpDir = file.freeTmpDir;
pub const isFlatpak = flatpak.isFlatpak;
pub const FlatpakHostCommand = flatpak.FlatpakHostCommand;
pub const home = homedir.home;
pub const expandHome = homedir.expandHome;
pub const ensureLocale = locale.ensureLocale;
pub const clickInterval = mouse.clickInterval;
pub const open = openpkg.open;
pub const OpenType = openpkg.Type;
pub const pipe = pipepkg.pipe;
pub const resourcesDir = resourcesdir.resourcesDir;
pub const ResourcesDir = resourcesdir.ResourcesDir;
pub const ShellEscapeWriter = shell.ShellEscapeWriter;
pub const getKernelInfo = kernel_info.getKernelInfo;

test {
    _ = i18n;
    _ = path;
    _ = uri;
    _ = shell;

    if (comptime builtin.os.tag == .linux) {
        _ = kernel_info;
    } else if (comptime builtin.os.tag.isDarwin()) {
        _ = mach;
        _ = macos;
    }
}
