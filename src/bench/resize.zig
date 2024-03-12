//! This benchmark tests the speed of resizing.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const cli = @import("../cli.zig");
const terminal = @import("../terminal-old/main.zig");
const terminal_new = @import("../terminal/main.zig");

const Args = struct {
    mode: Mode = .old,

    /// The number of times to loop.
    count: usize = 10_000,

    /// Rows and cols in the terminal.
    rows: usize = 50,
    cols: usize = 100,

    /// This is set by the CLI parser for deinit.
    _arena: ?ArenaAllocator = null,

    pub fn deinit(self: *Args) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }
};

const Mode = enum {
    /// The default allocation strategy of the structure.
    old,

    /// Use a memory pool to allocate pages from a backing buffer.
    new,
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
        var iter = try std.process.argsWithAllocator(alloc);
        defer iter.deinit();
        try cli.args.parse(Args, alloc, &args, &iter);
    }

    // Handle the modes that do not depend on terminal state first.
    switch (args.mode) {
        .old => {
            var t = try terminal.Terminal.init(alloc, args.cols, args.rows);
            defer t.deinit(alloc);
            try benchOld(&t, args);
        },

        .new => {
            var t = try terminal_new.Terminal.init(alloc, .{
                .cols = @intCast(args.cols),
                .rows = @intCast(args.rows),
            });
            defer t.deinit(alloc);
            try benchNew(&t, args);
        },
    }
}

noinline fn benchOld(t: *terminal.Terminal, args: Args) !void {
    // We fill the terminal with letters.
    for (0..args.rows) |row| {
        for (0..args.cols) |col| {
            t.setCursorPos(row + 1, col + 1);
            try t.print('A');
        }
    }

    for (0..args.count) |i| {
        const cols: usize, const rows: usize = if (i % 2 == 0)
            .{ args.cols * 2, args.rows * 2 }
        else
            .{ args.cols, args.rows };

        try t.screen.resizeWithoutReflow(@intCast(rows), @intCast(cols));
    }
}

noinline fn benchNew(t: *terminal_new.Terminal, args: Args) !void {
    // We fill the terminal with letters.
    for (0..args.rows) |row| {
        for (0..args.cols) |col| {
            t.setCursorPos(row + 1, col + 1);
            try t.print('A');
        }
    }

    for (0..args.count) |i| {
        const cols: usize, const rows: usize = if (i % 2 == 0)
            .{ args.cols * 2, args.rows * 2 }
        else
            .{ args.cols, args.rows };

        try t.screen.resizeWithoutReflow(@intCast(rows), @intCast(cols));
    }
}
