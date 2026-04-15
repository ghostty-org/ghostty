const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const build_config = @import("../build_config.zig");
const internal_os = @import("../os/main.zig");

const log = std.log.scoped(.config);

/// Default path for the XDG home configuration file. Returned value
/// must be freed by the caller.
pub fn defaultXdgPath(alloc: Allocator) ![]const u8 {
    return try internal_os.xdg.config(
        alloc,
        .{ .subdir = build_config.data_dir_name ++ "/config.ghostty" },
    );
}

/// Legacy Ghostty default path for the XDG home configuration file.
/// Returned value must be freed by the caller.
pub fn legacyGhosttyDefaultXdgPath(alloc: Allocator) ![]const u8 {
    return try internal_os.xdg.config(
        alloc,
        .{ .subdir = "ghostty/config" },
    );
}

pub fn legacyGhosttyConfigDotGhosttyPath(alloc: Allocator) ![]const u8 {
    return try internal_os.xdg.config(
        alloc,
        .{ .subdir = "ghostty/config.ghostty" },
    );
}

/// Preferred default path for the XDG home configuration file.
/// Returned value must be freed by the caller.
pub fn preferredXdgPath(alloc: Allocator) ![]const u8 {
    // If the XDG path exists, use that.
    const xdg_path = try defaultXdgPath(alloc);
    if (open(xdg_path)) |f| {
        f.close();
        return xdg_path;
    } else |_| {}

    // Try the legacy path
    errdefer alloc.free(xdg_path);
    const legacy_config_ghostty_path = try legacyGhosttyConfigDotGhosttyPath(alloc);
    if (open(legacy_config_ghostty_path)) |f| {
        f.close();
        alloc.free(xdg_path);
        return legacy_config_ghostty_path;
    } else |_| {}

    alloc.free(legacy_config_ghostty_path);
    const legacy_xdg_path = try legacyGhosttyDefaultXdgPath(alloc);
    if (open(legacy_xdg_path)) |f| {
        f.close();
        alloc.free(xdg_path);
        return legacy_xdg_path;
    } else |_| {}

    // Legacy paths and XDG path both don't exist. Return the new one.
    alloc.free(legacy_xdg_path);
    return xdg_path;
}

/// Returns the path to the preferred default configuration file.
/// This is the file where users should place their configuration.
///
/// This doesn't create or populate the file with any default
/// contents; downstream callers must handle this.
///
/// In the Windows-only fork, this resolves to the per-user config location
/// backed by `LOCALAPPDATA` or the Windows known-folder fallback used by the
/// XDG helper.
///
/// The returned value must be freed by the caller.
pub fn preferredDefaultFilePath(alloc: Allocator) ![]const u8 {
    return try preferredXdgPath(alloc);
}

const OpenFileError = error{
    FileNotFound,
    FileIsEmpty,
    FileOpenFailed,
    NotAFile,
};

/// Opens the file at the given path and returns the file handle
/// if it exists and is non-empty. This also constrains the possible
/// errors to a smaller set that we can explicitly handle.
pub fn open(path: []const u8) OpenFileError!std.fs.File {
    assert(std.fs.path.isAbsolute(path));

    var file = std.fs.openFileAbsolute(
        path,
        .{},
    ) catch |err| switch (err) {
        error.FileNotFound => return OpenFileError.FileNotFound,
        else => {
            log.warn("unexpected file open error path={s} err={}", .{
                path,
                err,
            });
            return OpenFileError.FileOpenFailed;
        },
    };
    errdefer file.close();

    const stat = file.stat() catch |err| {
        log.warn("error getting file stat path={s} err={}", .{
            path,
            err,
        });
        return OpenFileError.FileOpenFailed;
    };
    switch (stat.kind) {
        .file => {},
        else => return OpenFileError.NotAFile,
    }

    if (stat.size == 0) return OpenFileError.FileIsEmpty;

    return file;
}
