const std = @import("std");
const Allocator = std.mem.Allocator;
const cli = @import("../cli.zig");
const global = @import("../global.zig");
const Benchmark = @import("Benchmark.zig");

/// The available actions for the CLI. This is the list of available
/// benchmarks. View docs for each individual one in the predictably
/// named files.
pub const Action = enum {
    @"apc-parser",
    @"bidi-resolve",
    @"codepoint-width",
    @"grapheme-break",
    @"hyperlink-map",
    @"page-compression",
    @"scrollback-compression",
    @"screen-clone",
    @"terminal-parser",
    @"terminal-resize",
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
            .@"apc-parser" => @import("ApcParser.zig"),
            .@"bidi-resolve" => @import("BidiResolve.zig"),
            .@"hyperlink-map" => @import("HyperlinkMap.zig"),
            .@"screen-clone" => @import("ScreenClone.zig"),
            .@"page-compression" => @import("PageCompression.zig"),
            .@"scrollback-compression" => @import("ScrollbackCompression.zig"),
            .@"terminal-stream" => @import("TerminalStream.zig"),
            .@"codepoint-width" => @import("CodepointWidth.zig"),
            .@"grapheme-break" => @import("GraphemeBreak.zig"),
            .@"terminal-parser" => @import("TerminalParser.zig"),
            .@"terminal-resize" => @import("TerminalResize.zig"),
            .@"is-symbol" => @import("IsSymbol.zig"),
            .@"osc-parser" => @import("OscParser.zig"),
        };
    }
};

/// An entrypoint for the benchmark CLI.
pub fn main(minimal: std.process.Init.Minimal) !void {
    try global.init(.{ .tool = minimal });
    const alloc = std.heap.c_allocator;
    const action_ = try cli.action.detectArgs(Action, alloc, minimal.args);
    const action = action_ orelse return error.NoAction;
    try mainAction(alloc, action, .{ .cli = minimal.args });
}

/// Arguments that can be passed to the benchmark.
pub const Args = union(enum) {
    /// The arguments passed to the CLI via argc/argv.
    cli: std.process.Args,

    /// Simple string arguments, parsed via ArgIteratorGeneral.
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

/// Options understood by every benchmark, independent of which one is
/// being run. These are filtered out of the argument list before the
/// benchmark-specific options are parsed, so an individual benchmark's
/// `Options` struct never has to know about them.
pub const CommonOptions = struct {
    /// Run the benchmark repeatedly for this many milliseconds and report
    /// the iteration count, instead of running a single step and reporting
    /// nothing.
    ///
    /// Timing the process from the outside (with hyperfine, say) measures
    /// process startup, file I/O, and scheduler noise along with the work
    /// under test. On a shared machine that noise floor is several percent,
    /// which is larger than the regressions worth catching. Sampling many
    /// iterations inside one process and dividing gives a figure that is
    /// stable enough to gate on.
    ///
    /// A benchmark must be able to run its step more than once for this to
    /// be meaningful. A step that consumes a file handle to exhaustion will
    /// report an enormous iteration count and measure nothing; benchmarks
    /// that read input should load it in `setup` instead.
    duration: ?u64 = null,

    /// Consume `arg` if it is a common option. Returns true if it was
    /// consumed and should not be passed to the benchmark's own parser.
    fn consume(self: *CommonOptions, arg: []const u8) !bool {
        const prefix = "--duration=";
        if (!std.mem.startsWith(u8, arg, prefix)) return false;
        self.duration = std.fmt.parseInt(
            u64,
            arg[prefix.len..],
            10,
        ) catch return cli.args.Error.InvalidValue;
        return true;
    }
};

/// Wraps an argument iterator, pulling out the common options as it goes
/// and yielding only the arguments the benchmark itself should see.
fn CommonFilter(comptime Iter: type) type {
    return struct {
        inner: *Iter,
        common: *CommonOptions,
        err: ?anyerror = null,

        pub fn next(self: *@This()) ?[]const u8 {
            while (self.inner.next()) |arg| {
                const consumed = self.common.consume(arg) catch |err| {
                    // The parse loop has no way to surface an error from
                    // the iterator, so stash it and stop yielding.
                    self.err = err;
                    return null;
                };
                if (consumed) continue;
                return arg;
            }
            return null;
        }
    };
}

fn mainActionImpl(
    comptime BenchmarkImpl: type,
    alloc: Allocator,
    args: Args,
) !void {
    // First, parse our CLI options.
    const Options = BenchmarkImpl.Options;
    var opts: Options = .{};
    var common: CommonOptions = .{};
    defer if (@hasDecl(Options, "deinit")) opts.deinit();
    switch (args) {
        .cli => |process_args| {
            var iter = try cli.args.argsIterator(alloc, process_args);
            defer iter.deinit();
            var filter: CommonFilter(@TypeOf(iter)) = .{
                .inner = &iter,
                .common = &common,
            };
            try cli.args.parse(Options, alloc, &opts, &filter);
            if (filter.err) |err| return err;
        },
        .string => |str| {
            var iter = try std.process.Args.IteratorGeneral(.{}).init(
                alloc,
                str,
            );
            defer iter.deinit();
            var filter: CommonFilter(@TypeOf(iter)) = .{
                .inner = &iter,
                .common = &common,
            };
            try cli.args.parse(Options, alloc, &opts, &filter);
            if (filter.err) |err| return err;
        },
    }

    // Create our implementation
    const impl = try BenchmarkImpl.create(alloc, opts);
    defer impl.destroy(alloc);

    // Initialize our benchmark
    const b = impl.benchmark();

    const duration_ms = common.duration orelse {
        // Preserve the historical behavior exactly when no duration is
        // requested: run once, print nothing, let the caller time the
        // process.
        _ = try b.run(.once);
        return;
    };

    const result = try b.run(.{ .duration = duration_ms * std.time.ns_per_ms });
    try reportResult(result);
}

/// Print a duration-mode result in a form that is easy to both read and
/// grep out of CI logs.
fn reportResult(result: Benchmark.RunResult) !void {
    var buf: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(global.io(), &buf);
    const w = &stdout.interface;

    const ns_per_iter: u64 = if (result.iterations > 0)
        result.duration / result.iterations
    else
        0;

    try w.print(
        "iterations={d} duration_ns={d} ns_per_iteration={d}\n",
        .{ result.iterations, result.duration, ns_per_iter },
    );
    try w.flush();
}

test "CommonOptions: consumes duration" {
    const testing = std.testing;

    var common: CommonOptions = .{};
    try testing.expect(try common.consume("--duration=250"));
    try testing.expectEqual(@as(?u64, 250), common.duration);

    // Anything else is left for the benchmark's own parser.
    try testing.expect(!try common.consume("--mode=resolve"));
    try testing.expect(!try common.consume("--duration"));
    try testing.expect(!try common.consume("+bidi-resolve"));

    try testing.expectError(
        cli.args.Error.InvalidValue,
        common.consume("--duration=abc"),
    );
}

test "CommonFilter: hides common options from the inner parser" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var iter = try std.process.Args.IteratorGeneral(.{}).init(
        alloc,
        "--mode=resolve --duration=500 --data=x.txt",
    );
    defer iter.deinit();

    var common: CommonOptions = .{};
    var filter: CommonFilter(@TypeOf(iter)) = .{
        .inner = &iter,
        .common = &common,
    };

    try testing.expectEqualStrings("--mode=resolve", filter.next().?);
    try testing.expectEqualStrings("--data=x.txt", filter.next().?);
    try testing.expectEqual(@as(?[]const u8, null), filter.next());
    try testing.expectEqual(@as(?u64, 500), common.duration);
}
