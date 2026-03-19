const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const mem = @import("mem.zig");
const osc = ghostty_vt.osc;

/// Use a single global allocator for simplicity and to avoid heap
/// allocation overhead in the fuzzer. The allocator is backed by a fixed
/// buffer, and every fuzz input resets the bump pointer to the start.
var fuzz_alloc: mem.FuzzAllocator(8 * 1024 * 1024) = .{};

pub export fn zig_fuzz_init() callconv(.c) void {
    fuzz_alloc.init();
}

pub export fn zig_fuzz_test(
    buf: [*]const u8,
    len: usize,
) callconv(.c) void {
    // Need at least one byte for the terminator selector.
    if (len == 0) return;

    fuzz_alloc.reset();
    const alloc = fuzz_alloc.allocator();
    const input = buf[0..len];

    // Use the first byte to select the terminator variant.
    const selector = input[0];
    const payload = input[1..];

    var p = osc.Parser.init(alloc);
    defer p.deinit();
    for (payload) |byte| p.next(byte);

    // Exercise all three terminator paths:
    //   0 -> BEL  (0x07)
    //   1 -> ST   (0x9c)
    //   2 -> missing terminator (null)
    const terminator: ?u8 = switch (selector % 3) {
        0 => 0x07,
        1 => 0x9c,
        else => null,
    };

    _ = p.end(terminator);
}
