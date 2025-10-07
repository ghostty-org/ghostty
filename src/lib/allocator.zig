const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

/// Useful alias since they're required to create Zig allocators
pub const ZigVTable = std.mem.Allocator.VTable;

/// The VTable required by the C interface.
/// C: GhosttyAllocatorVtable
pub const VTable = extern struct {
    alloc: *const fn (*anyopaque, len: usize, alignment: u8, ret_addr: usize) callconv(.c) ?[*]u8,
    resize: *const fn (*anyopaque, memory: [*]u8, memory_len: usize, alignment: u8, new_len: usize, ret_addr: usize) callconv(.c) bool,
    remap: *const fn (*anyopaque, memory: [*]u8, memory_len: usize, alignment: u8, new_len: usize, ret_addr: usize) callconv(.c) ?[*]u8,
    free: *const fn (*anyopaque, memory: [*]u8, memory_len: usize, alignment: u8, ret_addr: usize) callconv(.c) void,
};

/// Returns an allocator to use for the given possibly-null C allocator,
/// ensuring some allocator is always returned.
pub fn default(c_alloc_: ?*const Allocator) std.mem.Allocator {
    // If we're given an allocator, use it.
    if (c_alloc_) |c_alloc| return c_alloc.zig();

    // If we have libc, use that. We prefer libc if we have it because
    // its generally fast but also lets the embedder easily override
    // malloc/free with custom allocators like mimalloc or something.
    if (comptime builtin.link_libc) return std.heap.c_allocator;

    // No libc, use the preferred allocator for releases which is the
    // Zig SMP allocator.
    return std.heap.smp_allocator;
}

/// The Allocator interface for custom memory allocation strategies
/// within C libghostty APIs.
///
/// This -- purposely -- matches the Zig allocator interface. We do this
/// for two reasons: (1) Zig's allocator interface is well proven in
/// the real world to be flexible and useful, and (2) it allows us to
/// easily convert C allocators to Zig allocators and vice versa, since
/// we're written in Zig.
///
/// C: GhosttyAllocator
pub const Allocator = extern struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    /// vtable for the Zig allocator interface to map our extern
    /// allocator to Zig's allocator interface.
    pub const zig_vtable: ZigVTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    /// Create a C allocator from a Zig allocator. This requires that
    /// the Zig allocator be pointer-stable for the lifetime of the
    /// C allocator.
    pub fn fromZig(zig_alloc: *const std.mem.Allocator) Allocator {
        return .{
            .ctx = @ptrCast(@constCast(zig_alloc)),
            .vtable = &ZigAllocator.vtable,
        };
    }

    /// Create a Zig allocator from this C allocator. This requires
    /// a pointer to a Zig allocator vtable that we can populate with
    /// our callbacks.
    pub fn zig(self: *const Allocator) std.mem.Allocator {
        return .{
            .ptr = @ptrCast(@constCast(self)),
            .vtable = &zig_vtable,
        };
    }

    fn alloc(
        ctx: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        ra: usize,
    ) ?[*]u8 {
        const self: *Allocator = @ptrCast(@alignCast(ctx));
        return self.vtable.alloc(
            self.ctx,
            len,
            @intFromEnum(alignment),
            ra,
        );
    }

    fn resize(
        ctx: *anyopaque,
        old_mem: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ra: usize,
    ) bool {
        const self: *Allocator = @ptrCast(@alignCast(ctx));
        return self.vtable.resize(
            self.ctx,
            old_mem.ptr,
            old_mem.len,
            @intFromEnum(alignment),
            new_len,
            ra,
        );
    }

    fn remap(
        ctx: *anyopaque,
        old_mem: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ra: usize,
    ) ?[*]u8 {
        const self: *Allocator = @ptrCast(@alignCast(ctx));
        return self.vtable.remap(
            self.ctx,
            old_mem.ptr,
            old_mem.len,
            @intFromEnum(alignment),
            new_len,
            ra,
        );
    }

    fn free(
        ctx: *anyopaque,
        old_mem: []u8,
        alignment: std.mem.Alignment,
        ra: usize,
    ) void {
        const self: *Allocator = @ptrCast(@alignCast(ctx));
        self.vtable.free(
            self.ctx,
            old_mem.ptr,
            old_mem.len,
            @intFromEnum(alignment),
            ra,
        );
    }
};

/// An allocator implementation that wraps a Zig allocator so that
/// it can be exposed to C.
const ZigAllocator = struct {
    const vtable: VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(
        ctx: *anyopaque,
        len: usize,
        alignment: u8,
        ra: usize,
    ) callconv(.c) ?[*]u8 {
        const zig_alloc: *const std.mem.Allocator = @ptrCast(@alignCast(ctx));
        return zig_alloc.vtable.alloc(
            zig_alloc.ptr,
            len,
            @enumFromInt(alignment),
            ra,
        );
    }

    fn resize(
        ctx: *anyopaque,
        memory: [*]u8,
        memory_len: usize,
        alignment: u8,
        new_len: usize,
        ra: usize,
    ) callconv(.c) bool {
        const zig_alloc: *const std.mem.Allocator = @ptrCast(@alignCast(ctx));
        return zig_alloc.vtable.resize(
            zig_alloc.ptr,
            memory[0..memory_len],
            @enumFromInt(alignment),
            new_len,
            ra,
        );
    }

    fn remap(
        ctx: *anyopaque,
        memory: [*]u8,
        memory_len: usize,
        alignment: u8,
        new_len: usize,
        ra: usize,
    ) callconv(.c) ?[*]u8 {
        const zig_alloc: *const std.mem.Allocator = @ptrCast(@alignCast(ctx));
        return zig_alloc.vtable.remap(
            zig_alloc.ptr,
            memory[0..memory_len],
            @enumFromInt(alignment),
            new_len,
            ra,
        );
    }

    fn free(
        ctx: *anyopaque,
        memory: [*]u8,
        memory_len: usize,
        alignment: u8,
        ra: usize,
    ) callconv(.c) void {
        const zig_alloc: *const std.mem.Allocator = @ptrCast(@alignCast(ctx));
        return zig_alloc.vtable.free(
            zig_alloc.ptr,
            memory[0..memory_len],
            @enumFromInt(alignment),
            ra,
        );
    }
};

/// libc Allocator, requires linking libc
pub const c_allocator: Allocator = .fromZig(&std.heap.c_allocator);

/// Allocator that can be sent to the C API that does full
/// leak checking within Zig tests. This should only be used from
/// Zig tests.
pub const test_allocator: Allocator = b: {
    if (!builtin.is_test) @compileError("test_allocator can only be used in tests");
    break :b .fromZig(&testing.allocator);
};

test "c allocator" {
    if (!comptime builtin.link_libc) return error.SkipZigTest;

    const alloc = c_allocator.zig();
    const str = try alloc.alloc(u8, 10);
    defer alloc.free(str);
    try testing.expectEqual(10, str.len);
}

test "fba allocator" {
    var buf: [1024]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const zig_alloc = fba.allocator();

    // Convert the Zig allocator to a C interface
    const c_alloc: Allocator = .fromZig(&zig_alloc);

    // Convert back to Zig so we can test it.
    const alloc = c_alloc.zig();
    const str = try alloc.alloc(u8, 10);
    defer alloc.free(str);
    try testing.expectEqual(10, str.len);
}
