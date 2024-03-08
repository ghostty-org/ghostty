// This is the C-ABI API for the terminal package. This isn't used
// by other Zig programs but by C or WASM interfacing.
//
// NOTE: This is far, far from complete. We did a very minimal amount to
// prove that compilation works, but we haven't completed coverage yet.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Terminal = @import("main.zig").Terminal;
const wasm = @import("../os/wasm.zig");
const alloc = wasm.alloc;

export fn terminal_new(cols: usize, rows: usize) ?*Terminal {
    const term = Terminal.init(alloc, cols, rows) catch return null;
    const result = alloc.create(Terminal) catch return null;
    result.* = term;
    return result;
}

export fn terminal_free(ptr: ?*Terminal) void {
    if (ptr) |v| {
        v.deinit(alloc);
        alloc.destroy(v);
    }
}

export fn terminal_print(ptr: ?*Terminal, char: u32) void {
    if (ptr) |t| {
        t.print(@intCast(char)) catch return;
    }
}
