//! This benchmark tests the throughput of codepoint width calculation.
//! This is a common operation in terminal character printing and the
//! motivating factor to write this benchmark was discovering that our
//! codepoint width function was 30% of the runtime of every character
//! print.
//!
//! This will consume all of the available stdin, so you should run it
//! with `head` in a pipe to restrict. For example, to test ASCII input:
//!
//!   bench-stream --mode=gen-ascii | head -c 50M | bench-codepoint-width --mode=ziglyph
//!

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ziglyph = @import("ziglyph");
const cli = @import("../cli.zig");
const simd = @import("../simd/main.zig");
const table = @import("../unicode/main.zig").table;
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

    /// libc wcwidth
    wcwidth,

    /// Use ziglyph library to calculate the display width of each codepoint.
    ziglyph,

    /// Our SIMD implementation.
    simd,

    /// Test our lookup table implementation.
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
        .wcwidth => try benchWcwidth(reader, buf),
        .ziglyph => try benchZiglyph(reader, buf),
        .simd => try benchSimd(reader, buf),
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

extern "c" fn wcwidth(c: u32) c_int;

noinline fn benchWcwidth(
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
            const cp_, const consumed = d.next(c);
            assert(consumed);
            if (cp_) |cp| {
                const width = wcwidth(cp);

                // Write the width to the buffer to avoid it being compiled away
                buf[0] = @intCast(width);
            }
        }
    }
}

noinline fn benchTable(
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
            const cp_, const consumed = d.next(c);
            assert(consumed);
            if (cp_) |cp| {
                // This is the same trick we do in terminal.zig so we
                // keep it here.
                const width = if (cp <= 0xFF) 1 else table.get(@intCast(cp)).width;

                // Write the width to the buffer to avoid it being compiled away
                buf[0] = @intCast(width);
            }
        }
    }
}

noinline fn benchZiglyph(
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
            const cp_, const consumed = d.next(c);
            assert(consumed);
            if (cp_) |cp| {
                const width = ziglyph.display_width.codePointWidth(cp, .half);

                // Write the width to the buffer to avoid it being compiled away
                buf[0] = @intCast(width);
            }
        }
    }
}

noinline fn benchSimd(
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
            const cp_, const consumed = d.next(c);
            assert(consumed);
            if (cp_) |cp| {
                const width = simd.codepointWidth(cp);

                // Write the width to the buffer to avoid it being compiled away
                buf[0] = @intCast(width);
            }
        }
    }
}
