const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const internal_os = @import("../os/main.zig");

/// Open the configuration in the OS default editor according to the default
/// paths the main config file could be in.
pub fn open(alloc_gpa: Allocator) !void {
    // default location
    const config_path = config_path: {
        const xdg_config_path = try internal_os.xdg.config(alloc_gpa, .{ .subdir = "ghostty/config" });

        if (comptime builtin.os.tag == .macos) macos: {
            // On macOS, use the XDG path if the app support path doesn't exist.
            const app_support_path = try internal_os.macos.appSupportDir(alloc_gpa, "config");

            // If no configuration file currently exist, it should be created in app support.
            var no_config_file = false;

            if (std.fs.accessAbsolute(app_support_path, .{})) {
                alloc_gpa.free(xdg_config_path);
                break :config_path app_support_path;
            } else |err| switch (err) {
                error.BadPathName, error.FileNotFound => {
                    no_config_file = true;
                },
                else => break :macos,
            }

            if (std.fs.accessAbsolute(xdg_config_path, .{})) {
                alloc_gpa.free(app_support_path);
                break :macos;
            } else |err| switch (err) {
                error.BadPathName, error.FileNotFound => {
                    no_config_file = true;
                },
                else => break :macos,
            }
            if (no_config_file) break :config_path app_support_path;
        }

        break :config_path xdg_config_path;
    };
    defer alloc_gpa.free(config_path);

    // Create config directory recursively.
    if (std.fs.path.dirname(config_path)) |config_dir| {
        try std.fs.cwd().makePath(config_dir);
    }

    // Try to create file and go on if it already exists
    _ = std.fs.createFileAbsolute(
        config_path,
        .{ .exclusive = true },
    ) catch |err| {
        switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        }
    };

    try internal_os.open(alloc_gpa, config_path);
}
