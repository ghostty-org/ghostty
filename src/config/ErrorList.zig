const ErrorList = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = struct {
    message: [:0]const u8,
};

/// The list of errors. This will use the arena allocator associated
/// with the config structure (or whatever allocated used to call ErrorList
/// functions).
list: std.ArrayList(Error) = .{},

/// True if there are no errors.
pub fn empty(self: ErrorList) bool {
    return self.list.items.len == 0;
}

/// Add a new error to the list.
pub fn add(self: *ErrorList, alloc: Allocator, err: Error) !void {
    try self.list.append(alloc, err);
}
