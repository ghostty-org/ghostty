const std = @import("std");
const builtin = @import("builtin");
const passwd = @import("passwd.zig");
const global = @import("../global.zig");
const objc = @import("objc");

const Error = error{
    /// The buffer used for output is not large enough to store the value.
    BufferTooSmall,
};

/// Determine the home directory for the currently executing user. This
/// is generally an expensive process so the value should be cached.
pub inline fn home(environ_map: *const std.process.Environ.Map, buf: []u8) !?[]const u8 {
    return switch (builtin.os.tag) {
        .linux, .freebsd, .macos => try homeUnix(environ_map, buf),
        .windows => homeWindows(environ_map, buf) catch return error.BufferTooSmall,

        // iOS doesn't have a user-writable home directory
        .ios => null,

        else => @compileError("unimplemented"),
    };
}

fn homeUnix(environ_map: *const std.process.Environ.Map, buf: []u8) !?[]const u8 {
    // First: if we have a HOME env var, then we use that.
    if (environ_map.get("HOME")) |result| {
        if (buf.len < result.len) return Error.BufferTooSmall;
        @memcpy(buf[0..result.len], result);
        return buf[0..result.len];
    }

    // On macOS: [NSFileManager defaultManager].homeDirectoryForCurrentUser.path
    if (builtin.os.tag == .macos) {
        const NSFileManager = objc.getClass("NSFileManager").?;
        const manager = NSFileManager.msgSend(objc.Object, objc.sel("defaultManager"), .{});
        const homeURL = manager.getProperty(objc.Object, "homeDirectoryForCurrentUser");
        const homePath = homeURL.getProperty(objc.Object, "path");

        const c_str = homePath.getProperty([*:0]const u8, "UTF8String");
        const result = std.mem.sliceTo(c_str, 0);

        if (buf.len < result.len) return Error.BufferTooSmall;
        @memcpy(buf[0..result.len], result);
        return buf[0..result.len];
    }

    // Everything below here will require some allocation
    var tempBuf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&tempBuf);

    // We try passwd. This doesn't work on multi-user mac but we try it anyways.
    const pw = try passwd.get(fba.allocator());
    if (pw.home) |result| {
        if (buf.len < result.len) return Error.BufferTooSmall;
        @memcpy(buf[0..result.len], result);
        return buf[0..result.len];
    }

    // If all else fails, have the shell tell us...
    fba.reset();
    const run = try std.process.run(fba.allocator(), global.io(), .{
        .argv = &[_][]const u8{ "/bin/sh", "-c", "cd && pwd" },
        .stdout_limit = .limited(fba.buffer.len / 2),
        .stderr_limit = .limited(fba.buffer.len / 2),
    });

    if (run.term == .exited and run.term.exited == 0) {
        const result = trimSpace(run.stdout);
        if (buf.len < result.len) return Error.BufferTooSmall;
        @memcpy(buf[0..result.len], result);
        return buf[0..result.len];
    }

    return null;
}

fn homeWindows(environ_map: *const std.process.Environ.Map, buf: []u8) !?[]const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    _ = try writer.write(environ_map.get("HOMEDRIVE") orelse return null);
    _ = try writer.write(environ_map.get("HOMEPATH") orelse return null);
    return writer.buffered();
}

fn trimSpace(input: []const u8) []const u8 {
    return std.mem.trim(u8, input, " \n\t");
}

pub const ExpandError = error{
    HomeDetectionFailed,
    BufferTooSmall,
};

/// Expands a path that starts with a tilde (~) to the home directory of
/// the current user.
///
/// Errors if `home` fails or if the size of the expanded path is larger
/// than `buf.len`.
pub fn expandHome(environ_map: *const std.process.Environ.Map, path: []const u8, buf: []u8) ExpandError![]const u8 {
    return switch (builtin.os.tag) {
        .linux, .freebsd, .macos => try expandHomeUnix(environ_map, path, buf),

        // `~/` is not an idiom generally used on Windows
        .windows => return path,

        // iOS doesn't have a user-writable home directory
        .ios => return path,

        else => @compileError("unimplemented"),
    };
}

fn expandHomeUnix(environ_map: *const std.process.Environ.Map, path: []const u8, buf: []u8) ExpandError![]const u8 {
    if (!std.mem.startsWith(u8, path, "~/")) return path;
    const home_dir: []const u8 = if (home(environ_map, buf)) |home_|
        home_ orelse return error.HomeDetectionFailed
    else |_|
        return error.HomeDetectionFailed;
    const rest = path[1..]; // Skip the ~
    const expanded_len = home_dir.len + rest.len;

    if (expanded_len > buf.len) return Error.BufferTooSmall;
    @memcpy(buf[home_dir.len..expanded_len], rest);

    return buf[0..expanded_len];
}

test "expandHomeUnix" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const testing = std.testing;
    const allocator = testing.allocator;
    var environ_map = try testing.environ.createMap(testing.allocator);
    defer environ_map.deinit();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const home_dir = try expandHomeUnix(&environ_map, "~/", &buf);
    // Joining the home directory `~` with the path `/`
    // the result should end with a separator here. (e.g. `/home/user/`)
    try testing.expect(home_dir[home_dir.len - 1] == std.fs.path.sep);

    const downloads = try expandHomeUnix(&environ_map, "~/Downloads/shader.glsl", &buf);
    const expected_downloads = try std.mem.concat(allocator, u8, &[_][]const u8{ home_dir, "Downloads/shader.glsl" });
    defer allocator.free(expected_downloads);
    try testing.expectEqualStrings(expected_downloads, downloads);

    try testing.expectEqualStrings("~", try expandHomeUnix(&environ_map, "~", &buf));
    try testing.expectEqualStrings("~abc/", try expandHomeUnix(&environ_map, "~abc/", &buf));
    try testing.expectEqualStrings("/home/user", try expandHomeUnix(&environ_map, "/home/user", &buf));
    try testing.expectEqualStrings("", try expandHomeUnix(&environ_map, "", &buf));

    // Expect an error if the buffer is large enough to hold the home directory,
    // but not the expanded path
    var small_buf = try allocator.alloc(u8, home_dir.len);
    defer allocator.free(small_buf);
    try testing.expectError(error.BufferTooSmall, expandHomeUnix(
        &environ_map,
        "~/Downloads",
        small_buf[0..],
    ));
}

test {
    const testing = std.testing;
    var environ_map = try testing.environ.createMap(testing.allocator);
    defer environ_map.deinit();

    var buf: [1024]u8 = undefined;
    const result = try home(&environ_map, &buf);
    try testing.expect(result != null);
    try testing.expect(result.?.len > 0);
}
