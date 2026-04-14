const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const internal_os = @import("../os/main.zig");

const log = std.log.scoped(.config);

/// Default path for the XDG home configuration file. Returned value
/// must be freed by the caller.
pub fn defaultXdgPath(alloc: Allocator, io: std.Io, env: *const std.process.Environ.Map) ![]const u8 {
    return try internal_os.xdg.config(
        alloc,
        io,
        env,
        .{ .subdir = "ghostty/config.ghostty" },
    );
}

/// Ghostty <1.3.0 default path for the XDG home configuration file.
/// Returned value must be freed by the caller.
pub fn legacyDefaultXdgPath(alloc: Allocator, io: std.Io, env: *const std.process.Environ.Map) ![]const u8 {
    return try internal_os.xdg.config(
        alloc,
        io,
        env,
        .{ .subdir = "ghostty/config" },
    );
}

/// Preferred default path for the XDG home configuration file.
/// Returned value must be freed by the caller.
pub fn preferredXdgPath(alloc: Allocator, io: std.Io, env: *const std.process.Environ.Map) ![]const u8 {
    // If the XDG path exists, use that.
    const xdg_path = try defaultXdgPath(alloc, io, env);
    if (open(io, xdg_path)) |f| {
        f.close(io);
        return xdg_path;
    } else |_| {}

    // Try the legacy path
    errdefer alloc.free(xdg_path);
    const legacy_xdg_path = try legacyDefaultXdgPath(alloc, io, env);
    if (open(io, legacy_xdg_path)) |f| {
        f.close(io);
        alloc.free(xdg_path);
        return legacy_xdg_path;
    } else |_| {}

    // Legacy path and XDG path both don't exist. Return the
    // new one.
    alloc.free(legacy_xdg_path);
    return xdg_path;
}

/// Default path for the macOS Application Support configuration file.
/// Returned value must be freed by the caller.
pub fn defaultAppSupportPath(alloc: Allocator) ![]const u8 {
    return try internal_os.macos.appSupportDir(alloc, "config.ghostty");
}

/// Ghostty <1.3.0 default path for the macOS Application Support
/// configuration file. Returned value must be freed by the caller.
pub fn legacyDefaultAppSupportPath(alloc: Allocator) ![]const u8 {
    return try internal_os.macos.appSupportDir(alloc, "config");
}

/// Preferred default path for the macOS Application Support configuration file.
/// Returned value must be freed by the caller.
pub fn preferredAppSupportPath(alloc: Allocator, io: std.Io) ![]const u8 {
    // If the app support path exists, use that.
    const app_support_path = try defaultAppSupportPath(alloc);
    if (open(io, app_support_path)) |f| {
        f.close(io);
        return app_support_path;
    } else |_| {}

    // Try the legacy path
    errdefer alloc.free(app_support_path);
    const legacy_app_support_path = try legacyDefaultAppSupportPath(alloc);
    if (open(io, legacy_app_support_path)) |f| {
        f.close(io);
        alloc.free(app_support_path);
        return legacy_app_support_path;
    } else |_| {}

    // Legacy path and app support path both don't exist. Return the
    // new one.
    alloc.free(legacy_app_support_path);
    return app_support_path;
}

/// Returns the path to the preferred default configuration file.
/// This is the file where users should place their configuration.
///
/// This doesn't create or populate the file with any default
/// contents; downstream callers must handle this.
///
/// The returned value must be freed by the caller.
pub fn preferredDefaultFilePath(alloc: Allocator, io: std.Io, env: *const std.process.Environ.Map) ![]const u8 {
    switch (builtin.os.tag) {
        .macos => {
            // macOS prefers the Application Support directory
            // if it exists.
            const app_support_path = try preferredAppSupportPath(alloc, io);
            const app_support_file = open(io, app_support_path) catch {
                // Try the XDG path if it exists
                const xdg_path = try preferredXdgPath(alloc, io, env);
                const xdg_file = open(io, xdg_path) catch {
                    // If neither file exists, use app support
                    alloc.free(xdg_path);
                    return app_support_path;
                };
                xdg_file.close(io);
                alloc.free(app_support_path);
                return xdg_path;
            };
            app_support_file.close(io);
            return app_support_path;
        },

        // All other platforms use XDG only
        else => return try preferredXdgPath(alloc, io, env),
    }
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
pub fn open(io: std.Io, path: []const u8) OpenFileError!std.Io.File {
    assert(std.fs.path.isAbsolute(path));

    var file = std.Io.Dir.openFileAbsolute(
        io,
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
    errdefer file.close(io);

    const stat = file.stat(io) catch |err| {
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
