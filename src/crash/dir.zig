const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const internal_os = @import("../os/main.zig");

/// Returns a Dir for the default directory. The Dir.path field must be
/// freed with the given allocator.
pub fn defaultDir(io: std.Io, alloc: Allocator) !Dir {
    const crash_dir = try internal_os.xdg.state(alloc, .{ .subdir = "ghostty/crash" });
    errdefer alloc.free(crash_dir);
    return .{ .io = io, .path = crash_dir };
}

pub const Dir = struct {
    io: std.Io,
    /// The directory where crash reports are stored. This memory is owned
    /// by the caller.
    path: []const u8,

    /// Returns an iterator over the crash reports in this directory. This
    /// iterator must be freed with `ReportIterator.deinit`. The iterator
    /// may have no reports.
    pub fn iterator(self: *const Dir) !ReportIterator {
        var dir = std.Io.Dir.openDirAbsolute(
            self.io,
            self.path,
            .{ .iterate = true },
        ) catch return .{};
        errdefer dir.close(self.io);

        return .{
            .io = self.io,
            .dir = dir,
            .it = dir.iterate(),
        };
    }
};

pub const ReportIterator = struct {
    io: std.Io,
    dir: ?std.Io.Dir = null,
    it: std.Io.Dir.Iterator = undefined,

    pub fn deinit(self: *ReportIterator) void {
        if (self.dir) |dir| dir.close(self.io);
    }

    pub fn next(self: *ReportIterator) !?Report {
        // If we have no dir then we failed to open the directory.
        const dir = self.dir orelse return null;

        // Get the next file entry, if any.
        const entry = entry: while (true) {
            const entry = try self.it.next() orelse return null;
            if (entry.kind != .file) continue;
            break :entry entry;
        };

        const stat = try dir.statFile(self.io, entry.name);
        return .{
            .name = entry.name,
            .mtime = stat.mtime,
        };
    }
};

pub const Report = struct {
    name: []const u8,
    mtime: i128,
};
