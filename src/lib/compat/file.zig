//! Code taken from 0.15.2 and `std.fs.file`. See README.md for license and
//! details.
const builtin = @import("builtin");
const std = @import("std");
const global = @import("../../global.zig");

pub const ReadToEndAllocError = error{FileTooBig} ||
    std.Io.File.ReadStreamingError ||
    std.mem.Allocator.Error;

/// Read the file from its current position through end-of-stream, returning
/// `error.FileTooBig` if the result exceeds `max_bytes`.
///
/// Caller owns the memory.
pub fn readToEndAlloc(file: std.Io.File, alloc: std.mem.Allocator, max_bytes: usize) ReadToEndAllocError![]u8 {
    var read_buf: [4096]u8 = undefined;
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(alloc);

    while (true) {
        const n = file.readStreaming(global.io(), &.{&read_buf}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        if (n == 0) continue;
        if (n > max_bytes - result.items.len) return error.FileTooBig;
        try result.appendSlice(alloc, read_buf[0..n]);
    }

    return result.toOwnedSlice(alloc);
}

test "readToEndAlloc reads through EOF and permits exact limit" {
    const testing = std.testing;
    const contents = "hello, world";

    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try tmp_dir.dir.writeFile(testing.io, .{
        .sub_path = "data",
        .data = contents,
    });

    const file = try tmp_dir.dir.openFile(testing.io, "data", .{});
    defer file.close(testing.io);
    const result = try readToEndAlloc(file, testing.allocator, contents.len);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings(contents, result);

    const too_big_file = try tmp_dir.dir.openFile(testing.io, "data", .{});
    defer too_big_file.close(testing.io);
    try testing.expectError(
        error.FileTooBig,
        readToEndAlloc(too_big_file, testing.allocator, contents.len - 1),
    );
}
