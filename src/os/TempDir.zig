//! Creates a temporary directory at runtime that can be safely used to
//! store temporary data and is destroyed on deinit.
const TempDir = @This();

const std = @import("std");
const Dir = std.fs.Dir;
const file = @import("file.zig");

const log = std.log.scoped(.tempdir);

/// Dir is the directory handle
dir: Dir,

/// Parent directory
parent: Dir,

/// Name buffer that name points into. Generally do not use. To get the
/// name call the name() function.
name_buf: [file.random_basename_len:0]u8,

/// Create the temporary directory.
pub fn init() !TempDir {
    // Note: the tmp_path_buf sentinel is important because it ensures
    // we actually always have random_basename_len+1 bytes of available
    // space. We need that so we can set the sentinel in the case we use
    // all the possible length.
    var tmp_path_buf: [file.random_basename_len:0]u8 = undefined;

    const dir = dir: {
        const cwd = std.fs.cwd();
        const tmp_dir = try file.allocTmpDir(std.heap.page_allocator);
        defer file.freeTmpDir(std.heap.page_allocator, tmp_dir);
        break :dir try cwd.openDir(tmp_dir, .{});
    };

    // We now loop forever until we can find a directory that we can create.
    while (true) {
        const tmp_path = try file.randomBasename(&tmp_path_buf);
        tmp_path_buf[tmp_path.len] = 0;

        dir.makeDir(tmp_path) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => |e| return e,
        };

        return TempDir{
            .dir = try dir.openDir(tmp_path, .{}),
            .parent = dir,
            .name_buf = tmp_path_buf,
        };
    }
}

/// Name returns the name of the directory. This is just the basename
/// and is not the full absolute path.
pub fn name(self: *TempDir) []const u8 {
    return std.mem.sliceTo(&self.name_buf, 0);
}

/// Finish with the temporary directory. This deletes all contents in the
/// directory.
pub fn deinit(self: *TempDir) void {
    self.dir.close();
    self.parent.deleteTree(self.name()) catch |err|
        log.err("error deleting temp dir err={}", .{err});
}

test {
    const testing = std.testing;

    var td = try init();
    errdefer td.deinit();

    const nameval = td.name();
    try testing.expect(nameval.len > 0);

    // Can open a new handle to it proves it exists.
    var dir = try td.parent.openDir(nameval, .{});
    dir.close();

    // Should be deleted after we deinit
    td.deinit();
    try testing.expectError(error.FileNotFound, td.parent.openDir(nameval, .{}));
}
