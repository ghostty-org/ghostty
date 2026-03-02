const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const Terminal = ghostty_vt.Terminal;
const ReadonlyStream = ghostty_vt.ReadonlyStream;

/// Use a single global allocator for simplicity and to avoid heap
/// allocation overhead in the fuzzer. The allocator is backed by a fixed
/// buffer, and every fuzz input resets the bump pointer to the start.
var fuzz_alloc: FuzzAllocator = .{};

pub export fn zig_fuzz_init() callconv(.c) void {
    fuzz_alloc.init();
}

pub export fn zig_fuzz_test(
    buf: [*]const u8,
    len: usize,
) callconv(.c) void {
    // Do not test zero-length input paths.
    if (len == 0) return;

    fuzz_alloc.reset();
    const alloc = fuzz_alloc.allocator();
    const input = buf[0..len];

    // Allocate a terminal; if we run out of fixed-buffer space just
    // skip this input (not a bug, just a very large allocation).
    var t = Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
        .max_scrollback = 100,
    }) catch return;
    defer t.deinit(alloc);

    var stream: ReadonlyStream = t.vtStream();
    defer stream.deinit();

    // Use the first byte to decide between the scalar and slice paths
    // so both code paths get exercised by the fuzzer.
    const mode = input[0];
    const data = input[1..];

    if (mode & 1 == 0) {
        // Slice path — exercises SIMD fast-path if enabled
        stream.nextSlice(data) catch |err|
            std.debug.panic("nextSlice: {}", .{err});
    } else {
        // Scalar path — exercises byte-at-a-time UTF-8 decoding
        for (data) |byte| _ = stream.next(byte) catch |err|
            std.debug.panic("next: {}", .{err});
    }
}

/// Fixed-capacity allocator that avoids heap allocation and gives the
/// fuzzer deterministic, bounded memory behaviour. Backed by a single
/// fixed buffer; every `reset()` returns the bump pointer to the start
/// so the same memory is reused across iterations.
const FuzzAllocator = struct {
    buf: [mem_size]u8 = undefined,
    state: std.heap.FixedBufferAllocator = undefined,

    /// 64 MiB gives the fuzzer enough headroom to exercise terminal
    /// resizes, large scrollback, and other allocation-heavy paths
    /// without running into out-of-memory on every other input.
    const mem_size = 64 * 1024 * 1024;

    fn init(self: *FuzzAllocator) void {
        self.state = .init(&self.buf);
    }

    fn allocator(self: *FuzzAllocator) std.mem.Allocator {
        return self.state.allocator();
    }

    fn reset(self: *FuzzAllocator) void {
        self.state.reset();
    }
};
