const std = @import("std");
const Allocator = std.mem.Allocator;
const cli = @import("../cli.zig");

/// The available actions for the CLI. This is the list of available
/// benchmarks. View docs for each individual one in the predictably
/// named files.
pub const Action = enum {
    @"codepoint-width",
    @"grapheme-break",
    @"screen-clone",
    @"terminal-parser",
    @"terminal-stream",
    @"is-symbol",
    @"osc-parser",

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
            .@"screen-clone" => @import("ScreenClone.zig"),
            .@"terminal-stream" => @import("TerminalStream.zig"),
            .@"codepoint-width" => @import("CodepointWidth.zig"),
            .@"grapheme-break" => @import("GraphemeBreak.zig"),
            .@"terminal-parser" => @import("TerminalParser.zig"),
            .@"is-symbol" => @import("IsSymbol.zig"),
            .@"osc-parser" => @import("OscParser.zig"),
        };
    }
};

/// An entrypoint for the benchmark CLI.
pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    const action_ = try cli.action.detectArgs(Action, alloc, init.minimal.args);
    const action = action_ orelse return error.NoAction;
    try mainAction(alloc, action, init.io, .cli);
}

/// Arguments that can be passed to the benchmark.
pub const Args = union(enum) {
    /// The arguments passed to the CLI via argc/argv.
    cli: std.process.Args,

    /// Simple string arguments, parsed via std.process.Args.IteratorGeneral.
    string: []const u8,
};

pub fn mainAction(
    alloc: Allocator,
    action: Action,
    io: std.Io,
    env: *const std.process.Environ.Map,
    args: Args,
) !void {
    switch (action) {
        inline else => |comptime_action| {
            const BenchmarkImpl = Action.Struct(comptime_action);
            try mainActionImpl(BenchmarkImpl, alloc, io, env, args);
        },
    }
}

fn mainActionImpl(
    comptime BenchmarkImpl: type,
    alloc: Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    args: Args,
) !void {
    // First, parse our CLI options.
    const Options = BenchmarkImpl.Options;
    var opts: Options = .{};
    defer if (@hasDecl(Options, "deinit")) opts.deinit();
    switch (args) {
        .cli => |a| {
            var iter = try cli.args.argsIterator(a, alloc);
            defer iter.deinit();
            try cli.args.parse(Options, alloc, &opts, &iter);
        },
        .string => |str| {
            var iter = try std.process.Args.IteratorGeneral(.{}).init(
                alloc,
                str,
            );
            defer iter.deinit();
            try cli.args.parse(Options, alloc, &opts, &iter);
        },
    }

    // Create our implementation
    const impl = try BenchmarkImpl.create(alloc, io, env, opts);
    defer impl.destroy(alloc);

    // Initialize our benchmark
    const b = impl.benchmark();
    _ = try b.run(io, .once);
}
