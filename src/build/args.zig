const std = @import("std");

/// Helper function for args allocation. Caller fully owns the slice and can
/// deinit as need be.
pub fn argsAlloc(alloc: std.mem.Allocator, args: std.process.Args) std.mem.Allocator.Error![][:0]const u8 {
    var result: std.ArrayList([:0]const u8) = .empty;
    errdefer result.deinit(alloc);
    var it = args.iterate();
    while (it.next()) |arg| {
        try result.append(alloc, arg);
    }
    return try result.toOwnedSlice(alloc);
}
