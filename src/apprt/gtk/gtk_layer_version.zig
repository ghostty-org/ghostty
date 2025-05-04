const std = @import("std");
const gtk4_layer_shell = @import("gtk4-layer-shell");
const VersionChecked = @import("version.zig").VersionChecked;
const log = std.log.scoped(.gtk);

pub const getRuntimeVersion = gtk4_layer_shell.getRuntimeVersion;
const LayerShellVersion = VersionChecked("gtk4-layer-shell", getRuntimeVersion, null);

pub const atLeast = LayerShellVersion.atLeast;
pub const runtimeAtLeast = LayerShellVersion.runtimeAtLeast;
pub fn logVersion() void {
    log.info("{s}", .{LayerShellVersion.logFormat()});
}
