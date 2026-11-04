const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

/// Wasm-specific allocation helpers.
pub const wasm = @import("allocator/wasm.zig");

/// Useful alias since they're required to create Zig allocators
pub const ZigVTable = std.mem.Allocator.VTable;

/// The VTable required by the C interface. Every function receives the
/// `ctx` pointer of the `Allocator` it belongs to, which may be null.
///
/// `resize` and `remap` are optional. A null `resize` behaves as if it
/// returned false and a null `remap` behaves as if it returned null, so
/// callers fall back to alloc, copy, and free.
///
/// `reserved` must be null. A future release may define these slots and
/// will detect them with a non-null check. A library that does not know a
/// slot ignores it.
///
/// C: GhosttyAllocatorVtable
pub const VTable = extern struct {
    alloc: *const fn (?*anyopaque, len: usize, alignment: u8, ret_addr: usize) callconv(.c) ?[*]u8,
    resize: ?*const fn (?*anyopaque, memory: [*]u8, memory_len: usize, alignment: u8, new_len: usize, ret_addr: usize) callconv(.c) bool,
    remap: ?*const fn (?*anyopaque, memory: [*]u8, memory_len: usize, alignment: u8, new_len: usize, ret_addr: usize) callconv(.c) ?[*]u8,
    free: *const fn (?*anyopaque, memory: [*]u8, memory_len: usize, alignment: u8, ret_addr: usize) callconv(.c) void,
    reserved: [4]?*anyopaque = @splat(null),
};

/// Returns the Zig allocator for a C API allocator argument. A null
/// argument selects the platform default. In Debug builds this also
/// panics if the caller's vtable has a non-null reserved slot.
pub fn default(c_alloc_: ?*const Allocator) std.mem.Allocator {
    // If we're given an allocator, use it.
    if (c_alloc_) |c_alloc| {
        // Reserved slots must be null. Release builds ignore them so a
        // vtable written against a newer header keeps working. Debug
        // builds catch callers that forgot to zero-initialize.
        if (comptime builtin.mode == .debug) {
            for (c_alloc.vtable.reserved) |slot| {
                if (slot != null) @panic("GhosttyAllocatorVtable.reserved must be NULL");
            }
        }

        return c_alloc.zig();
    }

    // Tests always use the test allocator so we can detect leaks.
    if (comptime builtin.is_test) return testing.allocator;

    // If we have libc, use that. We prefer libc if we have it because
    // its generally fast but also lets the embedder easily override
    // malloc/free with custom allocators like mimalloc or something.
    if (comptime builtin.link_libc) return std.heap.c_allocator;

    // Wasm
    if (comptime builtin.target.cpu.arch.isWasm()) return std.heap.wasm_allocator;

    // Freestanding targets don't have a default heap. Using the failing
    // allocator makes a missing allocator show up as out-of-memory.
    if (comptime builtin.target.os.tag == .freestanding) return std.mem.Allocator.failing;

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
    /// Passed unchanged to every vtable function. May be null.
    ctx: ?*anyopaque,
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

    /// Create a Zig allocator that calls through this C allocator. The
    /// result points at `self`, so `self` must outlive every allocation
    /// made with it. A null `resize` or `remap` in the C vtable makes the
    /// matching Zig call report "not supported", and Zig falls back to
    /// alloc, copy, and free.
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
            @backingInt(alignment),
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
        const func = self.vtable.resize orelse return false;
        return func(
            self.ctx,
            old_mem.ptr,
            old_mem.len,
            @backingInt(alignment),
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
        const func = self.vtable.remap orelse return null;
        return func(
            self.ctx,
            old_mem.ptr,
            old_mem.len,
            @backingInt(alignment),
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
            @backingInt(alignment),
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
        .reserved = @splat(null),
    };

    fn alloc(
        ctx: ?*anyopaque,
        len: usize,
        alignment: u8,
        ra: usize,
    ) callconv(.c) ?[*]u8 {
        const zig_alloc: *const std.mem.Allocator = @ptrCast(@alignCast(ctx.?));
        return zig_alloc.vtable.alloc(
            zig_alloc.ptr,
            len,
            @fromBackingInt(@truncate(alignment)),
            ra,
        );
    }

    fn resize(
        ctx: ?*anyopaque,
        memory: [*]u8,
        memory_len: usize,
        alignment: u8,
        new_len: usize,
        ra: usize,
    ) callconv(.c) bool {
        const zig_alloc: *const std.mem.Allocator = @ptrCast(@alignCast(ctx.?));
        return zig_alloc.vtable.resize(
            zig_alloc.ptr,
            memory[0..memory_len],
            @fromBackingInt(@truncate(alignment)),
            new_len,
            ra,
        );
    }

    fn remap(
        ctx: ?*anyopaque,
        memory: [*]u8,
        memory_len: usize,
        alignment: u8,
        new_len: usize,
        ra: usize,
    ) callconv(.c) ?[*]u8 {
        const zig_alloc: *const std.mem.Allocator = @ptrCast(@alignCast(ctx.?));
        return zig_alloc.vtable.remap(
            zig_alloc.ptr,
            memory[0..memory_len],
            @fromBackingInt(@truncate(alignment)),
            new_len,
            ra,
        );
    }

    fn free(
        ctx: ?*anyopaque,
        memory: [*]u8,
        memory_len: usize,
        alignment: u8,
        ra: usize,
    ) callconv(.c) void {
        const zig_alloc: *const std.mem.Allocator = @ptrCast(@alignCast(ctx.?));
        return zig_alloc.vtable.free(
            zig_alloc.ptr,
            memory[0..memory_len],
            @fromBackingInt(@truncate(alignment)),
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

test "fromZig leaves reserved slots null" {
    const c_alloc: Allocator = .fromZig(&testing.allocator);
    for (c_alloc.vtable.reserved) |slot| try testing.expectEqual(null, slot);
    try testing.expect(c_alloc.vtable.resize != null);
    try testing.expect(c_alloc.vtable.remap != null);

    // Round-trip through zig() still allocates and frees.
    const alloc = default(&c_alloc);
    const str = try alloc.alloc(u8, 10);
    defer alloc.free(str);
    try testing.expectEqual(10, str.len);
}

test "null resize and remap fall back to alloc, copy, free" {
    // An allocator with only alloc and free, like one built on plain
    // malloc and free. The context is the backing Zig allocator.
    const Minimal = struct {
        fn alloc(ctx: ?*anyopaque, len: usize, alignment: u8, ra: usize) callconv(.c) ?[*]u8 {
            const zig_alloc: *const std.mem.Allocator = @ptrCast(@alignCast(ctx.?));
            return zig_alloc.rawAlloc(len, @fromBackingInt(@truncate(alignment)), ra);
        }

        fn free(ctx: ?*anyopaque, memory: [*]u8, memory_len: usize, alignment: u8, ra: usize) callconv(.c) void {
            const zig_alloc: *const std.mem.Allocator = @ptrCast(@alignCast(ctx.?));
            zig_alloc.rawFree(memory[0..memory_len], @fromBackingInt(@truncate(alignment)), ra);
        }

        const vtable: VTable = .{
            .alloc = alloc,
            .resize = null,
            .remap = null,
            .free = free,
        };
    };

    const c_alloc: Allocator = .{
        .ctx = @ptrCast(@constCast(&testing.allocator)),
        .vtable = &Minimal.vtable,
    };
    const alloc = default(&c_alloc);

    var buf = try alloc.alloc(u8, 4);
    @memcpy(buf, "abcd");

    // Neither resize nor remap is supported.
    try testing.expect(!alloc.resize(buf, 8));
    try testing.expectEqual(null, alloc.remap(buf, 8));

    // Growth still works and keeps the contents.
    buf = try alloc.realloc(buf, 4096);
    defer alloc.free(buf);
    try testing.expectEqual(4096, buf.len);
    try testing.expectEqualStrings("abcd", buf[0..4]);

    // An ArrayList grows through the same path.
    var list: std.ArrayList(u32) = .empty;
    defer list.deinit(alloc);
    for (0..1000) |i| try list.append(alloc, @intCast(i));
    try testing.expectEqual(1000, list.items.len);
    try testing.expectEqual(999, list.items[999]);
}
