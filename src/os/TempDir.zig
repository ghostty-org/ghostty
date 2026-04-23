//! Creates a temporary directory at runtime that can be safely used to
//! store temporary data and is destroyed on deinit.
const TempDir = @This();

const std = @import("std");
const testing = std.testing;
const Dir = std.Io.Dir;
const getTmpDir = @import("file.zig").getTmpDir;

const log = std.log.scoped(.tempdir);

/// Dir is the directory handle
dir: Dir,

/// Parent directory
parent: Dir,

/// Name buffer that name points into. Generally do not use. To get the
/// name call the name() function.
name_buf: [TMP_PATH_LEN:0]u8,

/// Create the temporary directory.
pub fn init(io: std.Io, env: *const std.process.Environ.Map) !TempDir {
    // Note: the tmp_path_buf sentinel is important because it ensures
    // we actually always have TMP_PATH_LEN+1 bytes of available space. We
    // need that so we can set the sentinel in the case we use all the
    // possible length.
    var tmp_path_buf: [TMP_PATH_LEN:0]u8 = undefined;
    var rand_buf: [RANDOM_BYTES]u8 = undefined;

    const dir = dir: {
        const cwd: std.Io.Dir = .cwd();
        const tmp_dir = getTmpDir(env) orelse break :dir cwd;
        break :dir try cwd.openDir(io, tmp_dir, .{});
    };

    // We now loop forever until we can find a directory that we can create.
    while (true) {
        io.random(rand_buf[0..]);
        const tmp_path = b64_encoder.encode(&tmp_path_buf, &rand_buf);
        tmp_path_buf[tmp_path.len] = 0;

        dir.createDir(io, tmp_path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => |e| return e,
        };

        return .{
            .dir = try dir.openDir(io, tmp_path, .{}),
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
pub fn deinit(self: *TempDir, io: std.Io) void {
    self.dir.close(io);
    self.parent.deleteTree(io, self.name()) catch |err|
        log.err("error deleting temp dir err={}", .{err});
}

// The amount of random bytes to get to determine our filename.
const RANDOM_BYTES = 16;
const TMP_PATH_LEN = b64_encoder.calcSize(RANDOM_BYTES);

// Base64 encoder, replacing the standard `+/` with `-_` so that it can
// be used in a file name on any filesystem.
const b64_encoder = std.base64.Base64Encoder.init(b64_alphabet, null);
const b64_alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".*;

test {
    const io = std.testing.io;
    const env = try std.testing.environ.createMap(std.testing.allocator);
    errdefer env.deinit();

    var td = try init(io, env);
    errdefer td.deinit(io);

    const nameval = td.name();
    try testing.expect(nameval.len > 0);

    // Can open a new handle to it proves it exists.
    var dir = try td.parent.openDir(io, nameval, .{});
    dir.close(io);

    // Should be deleted after we deinit
    td.deinit();
    try testing.expectError(error.FileNotFound, td.parent.openDir(io, nameval, .{}));
}
