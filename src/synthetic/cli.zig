const std = @import("std");
const Allocator = std.mem.Allocator;
const cli = @import("../cli.zig");

/// The available actions for the CLI. This is the list of available
/// synthetic generators. View docs for each individual one in the
/// predictably named files under `cli/`.
pub const Action = enum {
    ascii,
    osc,
    utf8,
    code,

    /// Returns the struct associated with the action. The struct
    /// should have a few decls:
    ///
    ///   - `const Options`: The CLI options for the action.
    ///   - `fn create`: Create a new instance of the action from options.
    ///   - `fn destroy`: Destroy the instance of the action.
    ///
    /// See TerminalStream for an example.
    pub fn Struct(comptime action: Action) type {
        return switch (action) {
            .ascii => @import("cli/Ascii.zig"),
            .osc => @import("cli/Osc.zig"),
            .utf8 => @import("cli/Utf8.zig"),
            .code => @import("cli/Code.zig"),
        };
    }
};

/// An entrypoint for the synthetic generator CLI.
pub fn main() !void {
    const alloc = std.heap.c_allocator;
    const action_ = try cli.action.detectArgs(Action, alloc);
    const action = action_ orelse return error.NoAction;
    try mainAction(alloc, action, .cli);
}

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
            const Impl = Action.Struct(comptime_action);
            try mainActionImpl(Impl, alloc, args);
        },
    }
}

fn mainActionImpl(
    comptime Impl: type,
    alloc: Allocator,
    args: Args,
) !void {
    // First, parse our CLI options.
    const Options = Impl.Options;
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

    // TODO: Make this a command line option.
    const seed: u64 = @truncate(@as(
        u128,
        @bitCast(std.time.nanoTimestamp()),
    ));
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    // Our output always goes to stdout.
    const writer = std.io.getStdOut().writer();

    // Create our implementation
    const impl = try Impl.create(alloc, opts);
    defer impl.destroy(alloc);
    try impl.run(writer, rand);
}

test {
    // Make sure we ref all our actions
    inline for (@typeInfo(Action).@"enum".fields) |field| {
        const action = @field(Action, field.name);
        const Impl = Action.Struct(action);
        _ = Impl;
    }
}
