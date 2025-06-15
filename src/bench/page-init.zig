//! This benchmark tests the speed to create a terminal "page". This is
//! the internal data structure backing a terminal screen. The creation speed
//! is important because it is one of the primary bottlenecks for processing
//! large amounts of plaintext data.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const cli = @import("../cli.zig");
const terminal_new = @import("../terminal/main.zig");

const Args = struct {
    mode: Mode = .alloc,

    /// The number of pages to create sequentially.
    count: usize = 10_000,

    /// This is set by the CLI parser for deinit.
    _arena: ?ArenaAllocator = null,

    pub fn deinit(self: *Args) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }
};

const Mode = enum {
    /// The default allocation strategy of the structure.
    alloc,

    /// Use a memory pool to allocate pages from a backing buffer.
    pool,
};

pub const std_options: std.Options = .{
    .log_level = .debug,
};

pub fn main() !void {
    // We want to use the c allocator because it is much faster than GPA.
    const alloc = std.heap.c_allocator;

    // Parse our args
    var args: Args = .{};
    defer args.deinit();
    {
        var iter = try cli.args.argsIterator(alloc);
        defer iter.deinit();
        try cli.args.parse(Args, alloc, &args, &iter);
    }

    // Handle the modes that do not depend on terminal state first.
    switch (args.mode) {
        .alloc => try benchAlloc(args.count),
        .pool => try benchPool(alloc, args.count),
    }
}

noinline fn benchAlloc(count: usize) !void {
    for (0..count) |_| {
        _ = try terminal_new.Page.init(terminal_new.page.std_capacity);
    }
}

noinline fn benchPool(alloc: Allocator, count: usize) !void {
    var list = try terminal_new.PageList.init(
        alloc,
        terminal_new.page.std_capacity.cols,
        terminal_new.page.std_capacity.rows,
        0,
    );
    defer list.deinit();

    for (0..count) |_| {
        _ = try list.grow();
    }
}
