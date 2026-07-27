const std = @import("std");
const Allocator = std.mem.Allocator;
const internal_os = @import("../os/main.zig");
const global = @import("../global.zig");

/// Returns a Dir for the default directory. The Dir.path field must be
/// freed with the given allocator.
pub fn defaultDir(alloc: Allocator) !Dir {
    var environ_map = try global.environMap();
    defer environ_map.deinit();
    const crash_dir = try internal_os.xdg.state(alloc, &environ_map, .{ .subdir = "ghostty/crash" });
    errdefer alloc.free(crash_dir);
    return .{ .path = crash_dir };
}

pub const Dir = struct {
    /// The directory where crash reports are stored. This memory is owned
    /// by the caller.
    path: []const u8,

    /// Returns an iterator over the crash reports in this directory. This
    /// iterator must be freed with `ReportIterator.deinit`. The iterator
    /// may have no reports.
    pub fn iterator(self: *const Dir) !ReportIterator {
        var dir = std.Io.Dir.openDirAbsolute(
            global.io(),
            self.path,
            .{ .iterate = true },
        ) catch return .{};
        errdefer dir.close(global.io());

        return .{
            .dir = dir,
            .it = dir.iterate(),
        };
    }
};

pub const ReportIterator = struct {
    dir: ?std.Io.Dir = null,
    it: std.Io.Dir.Iterator = undefined,

    pub fn deinit(self: *ReportIterator) void {
        if (self.dir) |dir| dir.close(global.io());
    }

    pub fn next(self: *ReportIterator) !?Report {
        // If we have no dir then we failed to open the directory.
        const dir = self.dir orelse return null;

        // Get the next file entry, if any.
        const entry = entry: while (true) {
            const entry = try self.it.next(global.io()) orelse return null;
            if (entry.kind != .file) continue;
            break :entry entry;
        };

        const stat = try dir.statFile(global.io(), entry.name, .{});
        return .{
            .name = entry.name,
            .mtime = stat.mtime.toNanoseconds(),
        };
    }
};

pub const Report = struct {
    name: []const u8,
    mtime: i128,
};
