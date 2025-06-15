//! This benchmark tests the throughput of the terminal escape code parser.
//!
//! To benchmark, this takes an input stream (which is expected to come in
//! as fast as possible), runs it through the parser, and does nothing
//! with the parse result. This bottlenecks and tests the throughput of the
//! parser.
//!
//! Usage:
//!
//!   "--f=<path>" - A file to read to parse. If path is "-" then stdin
//!     is read. Required.
//!

const std = @import("std");
const ArenaAllocator = std.heap.ArenaAllocator;
const cli = @import("../cli.zig");
const terminal = @import("../terminal/main.zig");

pub fn main() !void {
    // Just use a GPA
    const GPA = std.heap.GeneralPurposeAllocator(.{});
    var gpa = GPA{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Parse our args
    var args: Args = args: {
        var args: Args = .{};
        errdefer args.deinit();
        var iter = try cli.args.argsIterator(alloc);
        defer iter.deinit();
        try cli.args.parse(Args, alloc, &args, &iter);
        break :args args;
    };
    defer args.deinit();

    // Read the file for our input
    const file = file: {
        if (std.mem.eql(u8, args.f, "-"))
            break :file std.io.getStdIn();

        @panic("file reading not implemented yet");
    };

    // Read all into memory (TODO: support buffers one day)
    const input = try file.reader().readAllAlloc(
        alloc,
        1024 * 1024 * 1024 * 1024 * 16, // 16 GB
    );
    defer alloc.free(input);

    // Run our parser
    var p: terminal.Parser = .{};
    for (input) |c| {
        const actions = p.next(c);
        //std.log.warn("actions={any}", .{actions});
        _ = actions;
    }
}

const Args = struct {
    f: []const u8 = "-",

    /// This is set by the CLI parser for deinit.
    _arena: ?ArenaAllocator = null,

    pub fn deinit(self: *Args) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }
};
