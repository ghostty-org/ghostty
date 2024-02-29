//! This benchmark tests the speed of copying the active area of the screen.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const cli = @import("../cli.zig");
const terminal = @import("../terminal/main.zig");

const Args = struct {
    mode: Mode = .old,

    /// The number of times to loop.
    count: usize = 5_000,

    /// Rows and cols in the terminal.
    rows: usize = 100,
    cols: usize = 300,

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
            try benchOld(alloc, &t, args);
        },

        .new => {
            var t = try terminal.new.Terminal.init(
                alloc,
                @intCast(args.cols),
                @intCast(args.rows),
            );
            defer t.deinit(alloc);
            try benchNew(alloc, &t, args);
        },
    }
}

noinline fn benchOld(alloc: Allocator, t: *terminal.Terminal, args: Args) !void {
    // We fill the terminal with letters.
    for (0..args.rows) |row| {
        for (0..args.cols) |col| {
            t.setCursorPos(row + 1, col + 1);
            try t.print('A');
        }
    }

    for (0..args.count) |_| {
        var s = try t.screen.clone(
            alloc,
            .{ .active = 0 },
            .{ .active = t.rows - 1 },
        );
        errdefer s.deinit();
    }
}

noinline fn benchNew(alloc: Allocator, t: *terminal.new.Terminal, args: Args) !void {
    // We fill the terminal with letters.
    for (0..args.rows) |row| {
        for (0..args.cols) |col| {
            t.setCursorPos(row + 1, col + 1);
            try t.print('A');
        }
    }

    for (0..args.count) |_| {
        var s = try t.screen.clone(alloc, .{ .active = .{} }, null);
        errdefer s.deinit();
    }
}
