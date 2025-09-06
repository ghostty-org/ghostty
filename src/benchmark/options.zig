//! This file contains helpers for CLI options.

const std = @import("std");

/// Returns the data file for the given path in a way that is consistent
/// across our CLI. If the path is not set then no file is returned.
/// If the path is "-", then we will return stdin. If the path is
/// a file then we will open and return the handle.
pub fn dataFile(path_: ?[]const u8) !?std.fs.File {
    const path = path_ orelse return null;

    // Stdin
    if (std.mem.eql(u8, path, "-")) return std.io.getStdIn();

    // Normal file
    const file = try std.fs.cwd().openFile(path, .{});
    errdefer file.close();

    return file;
}
