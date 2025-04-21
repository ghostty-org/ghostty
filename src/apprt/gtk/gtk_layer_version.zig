const std = @import("std");
const gtk4_layer_shell = @import("gtk4-layer-shell");
const VersionChecked = @import("version.zig").VersionChecked;

pub const getRuntimeVersion = gtk4_layer_shell.getRuntimeVersion;
const LayerShellVersion = VersionChecked("gtk4-layer-shell", std.log.scoped(.gtk), getRuntimeVersion, null);

pub const atLeast = LayerShellVersion.atLeast;
pub const runtimeAtLeast = LayerShellVersion.runtimeAtLeast;
pub const logVersion = LayerShellVersion.logVersion;
