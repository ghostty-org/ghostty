const std = @import("std");
const builtin = @import("builtin");

/// Same as @memmove but prefers libc memmove if it is
/// available because it is generally much faster?.
pub inline fn move(comptime T: type, dest: []T, source: []const T) void {
    if (builtin.link_libc) {
        _ = memmove(dest.ptr, source.ptr, source.len * @sizeOf(T));
    } else {
        @memmove(dest, source);
    }
}

/// Same as @memcpy but prefers libc memcpy if it is available
/// because it is generally much faster.
pub inline fn copy(comptime T: type, dest: []T, source: []const T) void {
    if (builtin.link_libc) {
        _ = memcpy(dest.ptr, source.ptr, source.len * @sizeOf(T));
    } else {
        @memcpy(dest[0..source.len], source);
    }
}

/// Moves the first item to the end.
/// For the reverse of this, use `fastmem.rotateOnceR`.
///
/// Same as std.mem.rotate(T, items, 1) but more efficient by using memmove
/// and a tmp var for the single rotated item instead of 3 calls to reverse.
///
/// e.g. `0 1 2 3` -> `1 2 3 0`.
pub inline fn rotateOnce(comptime T: type, items: []T) void {
    const tmp = items[0];
    move(T, items[0 .. items.len - 1], items[1..items.len]);
    items[items.len - 1] = tmp;
}

/// Moves the last item to the start.
/// Reverse operation of `fastmem.rotateOnce`.
///
/// Same as std.mem.rotate(T, items, items.len - 1) but more efficient by
/// using memmove and a tmp var for the single rotated item instead of 3
/// calls to reverse.
///
/// e.g. `0 1 2 3` -> `3 0 1 2`.
pub inline fn rotateOnceR(comptime T: type, items: []T) void {
    const tmp = items[items.len - 1];
    move(T, items[1..items.len], items[0 .. items.len - 1]);
    items[0] = tmp;
}

/// Rotates a new item in to the end of a slice.
/// The first item from the slice is removed and returned.
///
/// e.g. rotating `4` in to `0 1 2 3` makes it `1 2 3 4` and returns `0`.
///
/// For the reverse of this, use `fastmem.rotateInR`.
pub inline fn rotateIn(comptime T: type, items: []T, item: T) T {
    const removed = items[0];
    move(T, items[0 .. items.len - 1], items[1..items.len]);
    items[items.len - 1] = item;
    return removed;
}

/// Rotates a new item in to the start of a slice.
/// The last item from the slice is removed and returned.
///
/// e.g. rotating `4` in to `0 1 2 3` makes it `4 0 1 2` and returns `3`.
///
/// Reverse operation of `fastmem.rotateIn`.
pub inline fn rotateInR(comptime T: type, items: []T, item: T) T {
    const removed = items[items.len - 1];
    move(T, items[1..items.len], items[0 .. items.len - 1]);
    items[0] = item;
    return removed;
}

extern "c" fn memcpy(*anyopaque, *const anyopaque, usize) *anyopaque;
extern "c" fn memmove(*anyopaque, *const anyopaque, usize) *anyopaque;
