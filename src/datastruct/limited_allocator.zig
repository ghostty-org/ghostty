const std = @import("std");
const Allocator = std.mem.Allocator;

/// An allocator that rejects any single allocation or resize larger than a
/// configured byte limit. The limit applies to each request independently,
/// not to the total amount of memory currently allocated.
pub const LimitedAllocator = struct {
    child: Allocator,
    limit: usize,

    /// Set after an allocation, resize, or remap is rejected for exceeding
    /// the limit. This remains set until the caller clears it.
    limit_exceeded: bool = false,

    pub fn init(child: Allocator, limit: usize) LimitedAllocator {
        return .{
            .child = child,
            .limit = limit,
        };
    }

    pub fn allocator(self: *LimitedAllocator) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn check(self: *LimitedAllocator, size: usize) bool {
        if (size <= self.limit) return true;
        self.limit_exceeded = true;
        return false;
    }

    fn alloc(
        ctx: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *LimitedAllocator = @ptrCast(@alignCast(ctx));
        if (!self.check(len)) return null;
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *LimitedAllocator = @ptrCast(@alignCast(ctx));
        if (!self.check(new_len)) return false;
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *LimitedAllocator = @ptrCast(@alignCast(ctx));
        if (!self.check(new_len)) return null;
        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *LimitedAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

test "LimitedAllocator allows allocations through the limit" {
    const testing = std.testing;

    var limited: LimitedAllocator = .init(testing.allocator, 8);
    const alloc = limited.allocator();
    const data = try alloc.alloc(u8, 8);
    defer alloc.free(data);

    try testing.expect(!limited.limit_exceeded);
}

test "LimitedAllocator rejects allocations before the child" {
    const testing = std.testing;

    var failing = testing.FailingAllocator.init(testing.allocator, .{
        .fail_index = 0,
    });
    var limited: LimitedAllocator = .init(failing.allocator(), 8);

    try testing.expectError(error.OutOfMemory, limited.allocator().alloc(u8, 9));
    try testing.expect(limited.limit_exceeded);
    try testing.expect(!failing.has_induced_failure);
}

test "LimitedAllocator rejects oversized resize and remap" {
    const testing = std.testing;

    var limited: LimitedAllocator = .init(testing.allocator, 8);
    const alloc = limited.allocator();
    const data = try alloc.alloc(u8, 8);
    defer alloc.free(data);

    try testing.expect(!alloc.resize(data, 9));
    try testing.expect(limited.limit_exceeded);

    limited.limit_exceeded = false;
    try testing.expect(alloc.remap(data, 9) == null);
    try testing.expect(limited.limit_exceeded);
}
