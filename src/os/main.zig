//! The "os" package contains utilities for interfacing with the operating
//! system. These aren't restricted to syscalls or low-level operations, but
//! also OS-specific features and conventions.

const desktop = @import("desktop.zig");
const env = @import("env.zig");
const file = @import("file.zig");
const flatpak = @import("flatpak.zig");
const homedir = @import("homedir.zig");
const locale = @import("locale.zig");
const macos_version = @import("macos_version.zig");
const mouse = @import("mouse.zig");
const openpkg = @import("open.zig");
const pipepkg = @import("pipe.zig");
const resourcesdir = @import("resourcesdir.zig");

// Namespaces
pub const args = @import("args.zig");
pub const cgroup = @import("cgroup.zig");
pub const hostname = @import("hostname.zig");
pub const passwd = @import("passwd.zig");
pub const xdg = @import("xdg.zig");
pub const windows = @import("windows.zig");

// Functions and types
pub const CFReleaseThread = @import("cf_release_thread.zig");
pub const TempDir = @import("TempDir.zig");
pub const appendEnv = env.appendEnv;
pub const appendEnvAlways = env.appendEnvAlways;
pub const getenv = env.getenv;
pub const setenv = env.setenv;
pub const unsetenv = env.unsetenv;
pub const launchedFromDesktop = desktop.launchedFromDesktop;
pub const fixMaxFiles = file.fixMaxFiles;
pub const allocTmpDir = file.allocTmpDir;
pub const freeTmpDir = file.freeTmpDir;
pub const isFlatpak = flatpak.isFlatpak;
pub const home = homedir.home;
pub const ensureLocale = locale.ensureLocale;
pub const macosVersionAtLeast = macos_version.macosVersionAtLeast;
pub const clickInterval = mouse.clickInterval;
pub const open = openpkg.open;
pub const pipe = pipepkg.pipe;
pub const resourcesDir = resourcesdir.resourcesDir;
