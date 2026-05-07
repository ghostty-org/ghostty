//! Code taken from 0.15.2 `std.posix` and `std.fs.file`. See README.md for
//! license and details.
const builtin = @import("builtin");
const std = @import("std");
const global = @import("../../global.zig");

pub const ReadToEndAllocError = error{ FileTooBig, BytesReadMismatch } ||
    std.Io.File.StatError ||
    std.Io.File.ReadStreamingError ||
    std.mem.Allocator.Error;

/// This is a much simpler `readToEndAlloc` that just pre-allocates the memory
/// for the file ahead of time, and errors out if the size is larger than
/// `max_bytes`.
///
/// Caller owns the memory.
pub fn readToEndAlloc(file: std.Io.File, alloc: std.mem.Allocator, max_bytes: usize) ReadToEndAllocError![]u8 {
    const size = (try file.stat(global.io())).size;
    if (size > max_bytes) {
        return error.FileTooBig;
    }

    const buf = try alloc.alloc(u8, size);
    errdefer alloc.free(buf);
    if (try file.readStreaming(global.io(), &.{buf}) != size) {
        return error.BytesReadMismatch;
    }

    return buf;
}
