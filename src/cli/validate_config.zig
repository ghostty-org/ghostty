const std = @import("std");
const Allocator = std.mem.Allocator;
const args = @import("args.zig");
const Action = @import("ghostty.zig").Action;
const Config = @import("../config.zig").Config;

pub const Options = struct {
    /// The path of the config file to validate. If this isn't specified,
    /// then the default config file paths will be validated.
    @"config-file": ?[:0]const u8 = null,

    pub fn deinit(self: Options) void {
        _ = self;
    }

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `validate-config` command is used to validate a Ghostty config file.
///
/// When executed without any arguments, this will load the config from the default
/// location.
///
/// Flags:
///
///   * `--config-file`: can be passed to validate a specific target config file in
///     a non-default location
pub fn run(
    alloc: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    proc_args: std.process.Args,
) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try args.argsIterator(
            proc_args,
            alloc,
        );
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
    }

    var buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File
        .stdout().writer(io, &buffer);
    const stdout = &stdout_writer.interface;
    const result = runInner(
        io,
        alloc,
        env,
        proc_args,
        opts,
        stdout,
    );
    try stdout_writer.end();
    return result;
}

fn runInner(
    io: std.Io,
    alloc: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    proc_args: std.process.Args,
    opts: Options,
    stdout: *std.Io.Writer,
) !u8 {
    var cfg = try Config.default(alloc);
    defer cfg.deinit();

    // If a config path is passed, validate it, otherwise validate default configs
    if (opts.@"config-file") |config_path| {
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const abs_len = try std.Io.Dir.cwd()
            .realPathFile(io, config_path, &buf);
        const abs_path = buf[0..abs_len];
        try cfg.loadFile(alloc, io, env, abs_path);
        try cfg.loadRecursiveFiles(alloc, io, env);
    } else {
        cfg = try Config.load(
            alloc,
            io,
            proc_args,
            env,
        );
    }

    try cfg.finalize(io, proc_args, env);

    if (cfg._diagnostics.items().len > 0) {
        for (cfg._diagnostics.items()) |diag| {
            try stdout.print("{f}\n", .{diag});
        }
        return 1;
    }

    return 0;
}
