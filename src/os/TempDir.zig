//! Creates a temporary directory at runtime that can be safely used to
//! store temporary data and is destroyed on deinit.
const TempDir = @This();

const std = @import("std");
const Dir = std.Io.Dir;
const file = @import("file.zig");
const global = @import("../global.zig");

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
        const cwd = std.Io.Dir.cwd();
        const tmp_dir = try file.allocTmpDir(std.heap.page_allocator, global.environ());
        defer file.freeTmpDir(std.heap.page_allocator, tmp_dir);
        break :dir try cwd.openDir(global.io(), tmp_dir, .{});
    };

    // We now loop forever until we can find a directory that we can create.
    while (true) {
        const tmp_path = try file.randomBasename(&tmp_path_buf);
        tmp_path_buf[tmp_path.len] = 0;

        dir.createDir(global.io(), tmp_path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => |e| return e,
        };

        return TempDir{
            .dir = try dir.openDir(global.io(), tmp_path, .{}),
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
    self.close(.delete);
}

pub const CloseMode = enum { delete, retain };

/// Close the directory handles, optionally retaining the temporary directory
/// and its contents on disk.
pub fn close(self: *TempDir, mode: CloseMode) void {
    self.dir.close(global.io());
    switch (mode) {
        .delete => self.parent.deleteTree(global.io(), self.name()) catch |err|
            log.err("error deleting temp dir err={}", .{err}),
        .retain => {},
    }
    self.parent.close(global.io());
}

test {
    const testing = std.testing;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var path_len: usize = undefined;
    {
        var td = try init();
        errdefer td.deinit();

        const nameval = td.name();
        try testing.expect(nameval.len > 0);

        // Can open a new handle to it proves it exists.
        var dir = try td.parent.openDir(testing.io, nameval, .{});
        dir.close(testing.io);

        path_len = try td.dir.realPath(testing.io, &path_buf);

        // Don't check the raw handles after close: descriptor numbers can be
        // reused immediately, so a valid number does not imply that we leaked it.
        td.deinit();
    }

    try testing.expectError(
        error.FileNotFound,
        Dir.openDirAbsolute(testing.io, path_buf[0..path_len], .{}),
    );
}

test "close retains temporary directory" {
    const testing = std.testing;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var path_len: usize = undefined;
    {
        var td = try init();
        errdefer td.deinit();

        path_len = try td.dir.realPath(testing.io, &path_buf);

        // Don't check the raw handles after close: descriptor numbers can be
        // reused immediately, so a valid number does not imply that we leaked it.
        td.close(.retain);
    }
    defer Dir.deleteDirAbsolute(testing.io, path_buf[0..path_len]) catch {};

    var dir = try Dir.openDirAbsolute(testing.io, path_buf[0..path_len], .{});
    dir.close(testing.io);
}
