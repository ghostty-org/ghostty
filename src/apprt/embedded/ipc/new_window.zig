const std = @import("std");
const Allocator = std.mem.Allocator;

const apprt = @import("../../../apprt.zig");
const build_config = @import("../../../build_config.zig");

// Use a Unix domain socket to open a new window in a running Ghostty instance.
//
// `ghostty +new-window` is equivalent to connecting to the socket and sending
// a frame with action=new_window and no arguments.
//
// `ghostty +new-window -e echo hello` sends the same frame with the arguments
// ["--working-directory=<cwd>", "-e", "echo", "hello"].
pub fn newWindow(
    alloc: Allocator,
    target: apprt.ipc.Target,
    value: apprt.ipc.Action.NewWindow,
) (Allocator.Error || std.Io.Writer.Error || apprt.ipc.Errors)!bool {
    var buf: [256]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&buf);
    const stderr = &stderr_writer.interface;

    var path_buf: [std.posix.PATH_MAX]u8 = undefined;
    const path = socketPath(&path_buf, target) catch {
        try stderr.print("ghostty: failed to determine the Ghostty IPC socket path\n", .{});
        try stderr.flush();
        return error.IPCFailed;
    };

    const stream = std.net.connectUnixSocket(path) catch |err| {
        try stderr.print(
            "ghostty: unable to reach a running Ghostty instance ({s}): {s}. Is Ghostty running?\n",
            .{ path, @errorName(err) },
        );
        try stderr.flush();
        return error.IPCFailed;
    };
    defer stream.close();

    // Frame: [u8 action][u32 argc] then argc times [u32 len][bytes].
    // All integers little-endian.
    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(alloc);
    try frame.append(alloc, @intCast(@intFromEnum(apprt.ipc.Action.Key.new_window)));

    const arguments = value.arguments orelse &.{};
    try appendU32(&frame, alloc, @intCast(arguments.len));
    for (arguments) |arg| {
        try appendU32(&frame, alloc, @intCast(arg.len));
        try frame.appendSlice(alloc, arg);
    }

    stream.writeAll(frame.items) catch |err| {
        try stderr.print("ghostty: failed to send the IPC request: {s}\n", .{@errorName(err)});
        try stderr.flush();
        return error.IPCFailed;
    };

    // A non-zero acknowledgement byte means the instance rejected the
    // request. A missing ack is not treated as fatal: the request may have
    // been handled anyway and there's nothing useful to retry.
    var ack: [1]u8 = .{0};
    const n = stream.read(&ack) catch 0;
    if (n == 1 and ack[0] != 0) {
        try stderr.print("ghostty: the running Ghostty instance could not handle the request\n", .{});
        try stderr.flush();
        return error.IPCFailed;
    }

    return true;
}

/// Build the socket path. Both this and the Swift listener resolve the
/// per-user temp dir via confstr so they agree without relying on $TMPDIR.
fn socketPath(buf: []u8, target: apprt.ipc.Target) ![]const u8 {
    var dir_buf: [std.posix.PATH_MAX]u8 = undefined;
    const n = confstr(CS_DARWIN_USER_TEMP_DIR, &dir_buf, dir_buf.len);
    const dir: []const u8 = if (n > 0 and n <= dir_buf.len)
        std.mem.sliceTo(&dir_buf, 0)
    else
        "/tmp/";

    return socketPathForDir(buf, target, dir);
}

/// Build the socket path given an explicit directory. The directory is
/// expected to end with a path separator. Separated from socketPath so
/// it can be tested without a real confstr call.
fn socketPathForDir(buf: []u8, target: apprt.ipc.Target, dir: []const u8) ![]const u8 {
    const instance: []const u8 = switch (target) {
        .class => |class| class,
        .detect => build_config.bundle_id,
    };

    // The Darwin temp dir already ends in a path separator.
    return std.fmt.bufPrint(buf, "{s}ghostty-ipc-{s}.sock", .{ dir, instance });
}

fn appendU32(frame: *std.ArrayList(u8), alloc: Allocator, v: u32) Allocator.Error!void {
    var tmp: [4]u8 = undefined;
    std.mem.writeInt(u32, &tmp, v, .little);
    try frame.appendSlice(alloc, &tmp);
}

const CS_DARWIN_USER_TEMP_DIR: c_int = 65537;
extern "c" fn confstr(name: c_int, buf: [*]u8, len: usize) usize;

test "socketPath: detect uses bundle id" {
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    const path = try socketPathForDir(&buf, .detect, "/tmp/");
    try std.testing.expectEqualStrings(
        "/tmp/ghostty-ipc-" ++ build_config.bundle_id ++ ".sock",
        path,
    );
}

test "socketPath: class uses provided name" {
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    const path = try socketPathForDir(&buf, .{ .class = "com.example.ghostty-debug" }, "/tmp/");
    try std.testing.expectEqualStrings(
        "/tmp/ghostty-ipc-com.example.ghostty-debug.sock",
        path,
    );
}

test "socketPath: dir already has trailing separator" {
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    const path = try socketPathForDir(&buf, .detect, "/var/folders/xx/yyy/T/");
    try std.testing.expect(std.mem.startsWith(u8, path, "/var/folders/xx/yyy/T/ghostty-ipc-"));
    try std.testing.expect(std.mem.endsWith(u8, path, ".sock"));
}

test "appendU32: little-endian encoding" {
    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(std.testing.allocator);
    try appendU32(&frame, std.testing.allocator, 0x01020304);
    try std.testing.expectEqualSlices(u8, &.{ 0x04, 0x03, 0x02, 0x01 }, frame.items);
}

test "appendU32: zero" {
    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(std.testing.allocator);
    try appendU32(&frame, std.testing.allocator, 0);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x00, 0x00, 0x00 }, frame.items);
}

test "appendU32: max value" {
    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(std.testing.allocator);
    try appendU32(&frame, std.testing.allocator, std.math.maxInt(u32));
    try std.testing.expectEqualSlices(u8, &.{ 0xFF, 0xFF, 0xFF, 0xFF }, frame.items);
}
