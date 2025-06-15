/// A common interface for all generators.
const Generator = @This();

const std = @import("std");
const assert = std.debug.assert;

/// For generators, this is the only error that is allowed to be
/// returned by the next function.
pub const Error = error{NoSpaceLeft};

/// The vtable for the generator.
ptr: *anyopaque,
nextFn: *const fn (ptr: *anyopaque, buf: []u8) Error![]const u8,

/// Create a new generator from a pointer and a function pointer.
/// This usually is only called by generator implementations, not
/// generator users.
pub fn init(
    pointer: anytype,
    comptime nextFn: fn (ptr: @TypeOf(pointer), buf: []u8) Error![]const u8,
) Generator {
    const Ptr = @TypeOf(pointer);
    assert(@typeInfo(Ptr) == .pointer); // Must be a pointer
    assert(@typeInfo(Ptr).pointer.size == .one); // Must be a single-item pointer
    assert(@typeInfo(@typeInfo(Ptr).pointer.child) == .@"struct"); // Must point to a struct
    const gen = struct {
        fn next(ptr: *anyopaque, buf: []u8) Error![]const u8 {
            const self: Ptr = @ptrCast(@alignCast(ptr));
            return try nextFn(self, buf);
        }
    };

    return .{
        .ptr = pointer,
        .nextFn = gen.next,
    };
}

/// Get the next value from the generator. Returns the data written.
pub fn next(self: Generator, buf: []u8) Error![]const u8 {
    return try self.nextFn(self.ptr, buf);
}
