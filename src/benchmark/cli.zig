const std = @import("std");
const Allocator = std.mem.Allocator;
const cli = @import("../cli.zig");

/// The available actions for the CLI. This is the list of available
/// benchmarks. View docs for each individual one in the predictably
/// named files.
pub const Action = enum {
    @"codepoint-width",
    @"grapheme-break",
    @"terminal-parser",
    @"terminal-stream",
    @"is-symbol",

    /// Returns the struct associated with the action. The struct
    /// should have a few decls:
    ///
    ///   - `const Options`: The CLI options for the action.
    ///   - `fn create`: Create a new instance of the action from options.
    ///   - `fn benchmark`: Returns a `Benchmark` instance for the action.
    ///
    /// See TerminalStream for an example.
    pub fn Struct(comptime action: Action) type {
        return switch (action) {
            .@"terminal-stream" => @import("TerminalStream.zig"),
            .@"codepoint-width" => @import("CodepointWidth.zig"),
            .@"grapheme-break" => @import("GraphemeBreak.zig"),
            .@"terminal-parser" => @import("TerminalParser.zig"),
            .@"is-symbol" => @import("IsSymbol.zig"),
        };
    }
};

/// An entrypoint for the benchmark CLI.
pub fn main() !void {
    const alloc = std.heap.c_allocator;
    const action_ = try cli.action.detectArgs(Action, alloc);
    const action = action_ orelse return error.NoAction;
    try mainAction(alloc, action, .cli);
}

/// Arguments that can be passed to the benchmark.
pub const Args = union(enum) {
    /// The arguments passed to the CLI via argc/argv.
    cli,

    /// Simple string arguments, parsed via std.process.ArgIteratorGeneral.
    string: []const u8,
};

pub fn mainAction(
    alloc: Allocator,
    action: Action,
    args: Args,
) !void {
    switch (action) {
        inline else => |comptime_action| {
            const BenchmarkImpl = Action.Struct(comptime_action);
            try mainActionImpl(BenchmarkImpl, alloc, args);
        },
    }
}

fn mainActionImpl(
    comptime BenchmarkImpl: type,
    alloc: Allocator,
    args: Args,
) !void {
    // First, parse our CLI options.
    const Options = BenchmarkImpl.Options;
    var opts: Options = .{};
    defer if (@hasDecl(Options, "deinit")) opts.deinit();
    switch (args) {
        .cli => {
            var iter = try cli.args.argsIterator(alloc);
            defer iter.deinit();
            try cli.args.parse(Options, alloc, &opts, &iter);
        },
        .string => |str| {
            var iter = try std.process.ArgIteratorGeneral(.{}).init(
                alloc,
                str,
            );
            defer iter.deinit();
            try cli.args.parse(Options, alloc, &opts, &iter);
        },
    }

    // Create our implementation
    const impl = try BenchmarkImpl.create(alloc, opts);
    defer impl.destroy(alloc);

    // Initialize our benchmark
    const b = impl.benchmark();
    _ = try b.run(.once);
}
