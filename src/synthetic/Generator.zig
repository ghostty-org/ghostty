/// A common interface for all generators.
const Generator = @This();

const std = @import("std");
const assert = std.debug.assert;

/// For generators, this is the only error that is allowed to be
/// returned by the next function.
pub const Error = error{WriteFailed};

/// The vtable for the generator.
ptr: *anyopaque,
nextFn: *const fn (ptr: *anyopaque, *std.Io.Writer, usize) Error!void,

/// Create a new generator from a pointer and a function pointer.
/// This usually is only called by generator implementations, not
/// generator users.
pub fn init(
    pointer: anytype,
    comptime nextFn: fn (ptr: @TypeOf(pointer), *std.Io.Writer, usize) Error!void,
) Generator {
    const Ptr = @TypeOf(pointer);
    assert(@typeInfo(Ptr) == .pointer); // Must be a pointer
    assert(@typeInfo(Ptr).pointer.size == .one); // Must be a single-item pointer
    assert(@typeInfo(@typeInfo(Ptr).pointer.child) == .@"struct"); // Must point to a struct
    const gen = struct {
        fn next(ptr: *anyopaque, writer: *std.Io.Writer, max_len: usize) Error!void {
            const self: Ptr = @ptrCast(@alignCast(ptr));
            try nextFn(self, writer, max_len);
        }
    };

    return .{
        .ptr = pointer,
        .nextFn = gen.next,
    };
}

/// Get the next value from the generator. Returns the data written.
pub fn next(self: Generator, writer: *std.Io.Writer, max_size: usize) Error!void {
    try self.nextFn(self.ptr, writer, max_size);
}
