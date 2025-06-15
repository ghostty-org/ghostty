//! This benchmark tests the throughput of grapheme break calculation.
//! This is a common operation in terminal character printing for terminals
//! that support grapheme clustering.
//!
//! This will consume all of the available stdin, so you should run it
//! with `head` in a pipe to restrict. For example, to test ASCII input:
//!
//!   bench-stream --mode=gen-ascii | head -c 50M | bench-grapheme-break --mode=ziglyph
//!

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ziglyph = @import("ziglyph");
const cli = @import("../cli.zig");
const simd = @import("../simd/main.zig");
const unicode = @import("../unicode/main.zig");
const UTF8Decoder = @import("../terminal/UTF8Decoder.zig");

const Args = struct {
    mode: Mode = .noop,

    /// The size for read buffers. Doesn't usually need to be changed. The
    /// main point is to make this runtime known so we can avoid compiler
    /// optimizations.
    @"buffer-size": usize = 4096,

    /// This is set by the CLI parser for deinit.
    _arena: ?ArenaAllocator = null,

    pub fn deinit(self: *Args) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }
};

const Mode = enum {
    /// The baseline mode copies the data from the fd into a buffer. This
    /// is used to show the minimal overhead of reading the fd into memory
    /// and establishes a baseline for the other modes.
    noop,

    /// Use ziglyph library to calculate the display width of each codepoint.
    ziglyph,

    /// Ghostty's table-based approach.
    table,
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

    const reader = std.io.getStdIn().reader();
    const buf = try alloc.alloc(u8, args.@"buffer-size");

    // Handle the modes that do not depend on terminal state first.
    switch (args.mode) {
        .noop => try benchNoop(reader, buf),
        .ziglyph => try benchZiglyph(reader, buf),
        .table => try benchTable(reader, buf),
    }
}

noinline fn benchNoop(
    reader: anytype,
    buf: []u8,
) !void {
    var d: UTF8Decoder = .{};
    while (true) {
        const n = try reader.read(buf);
        if (n == 0) break;

        // Using stream.next directly with a for loop applies a naive
        // scalar approach.
        for (buf[0..n]) |c| {
            _ = d.next(c);
        }
    }
}

noinline fn benchTable(
    reader: anytype,
    buf: []u8,
) !void {
    var d: UTF8Decoder = .{};
    var state: unicode.GraphemeBreakState = .{};
    var cp1: u21 = 0;
    while (true) {
        const n = try reader.read(buf);
        if (n == 0) break;

        // Using stream.next directly with a for loop applies a naive
        // scalar approach.
        for (buf[0..n]) |c| {
            const cp_, const consumed = d.next(c);
            assert(consumed);
            if (cp_) |cp2| {
                const v = unicode.graphemeBreak(cp1, @intCast(cp2), &state);
                buf[0] = @intCast(@intFromBool(v));
                cp1 = cp2;
            }
        }
    }
}

noinline fn benchZiglyph(
    reader: anytype,
    buf: []u8,
) !void {
    var d: UTF8Decoder = .{};
    var state: u3 = 0;
    var cp1: u21 = 0;
    while (true) {
        const n = try reader.read(buf);
        if (n == 0) break;

        // Using stream.next directly with a for loop applies a naive
        // scalar approach.
        for (buf[0..n]) |c| {
            const cp_, const consumed = d.next(c);
            assert(consumed);
            if (cp_) |cp2| {
                const v = ziglyph.graphemeBreak(cp1, @intCast(cp2), &state);
                buf[0] = @intCast(@intFromBool(v));
                cp1 = cp2;
            }
        }
    }
}
