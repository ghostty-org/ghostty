const std = @import("std");

/// Fixed-capacity allocator that avoids heap allocation and gives the
/// fuzzer deterministic, bounded memory behaviour. Backed by a single
/// fixed buffer; every `reset()` returns the bump pointer to the start
/// so the same memory is reused across iterations.
pub fn FuzzAllocator(comptime mem_size: usize) type {
    return struct {
        buf: [mem_size]u8 = undefined,
        state: std.heap.FixedBufferAllocator = undefined,

        const Self = @This();

        pub fn init(self: *Self) void {
            self.state = .init(&self.buf);
        }

        pub fn allocator(self: *Self) std.mem.Allocator {
            return self.state.allocator();
        }

        pub fn reset(self: *Self) void {
            self.state.reset();
        }
    };
}
