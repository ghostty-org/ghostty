const std = @import("std");
const args = @import("args.zig");
const Allocator = std.mem.Allocator;
const Config = @import("../config/Config.zig");

pub const Options = struct {
    /// If true, print out the default config instead of the user's config.
    default: bool = false,

    pub fn deinit(self: Options) void {
        _ = self;
    }
};

/// The "show-config" command is used to list all the available configuration
/// settings for Ghostty.
///
/// When executed without any arguments this will list the current settings
/// loaded by the config file(s). If no config file is found or there aren't
/// any changes to the settings it will print out the default ones configured
/// for Ghostty
///
/// The "--default" argument will print out all the default settings
/// configured for Ghostty
pub fn run(alloc: Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try std.process.argsWithAllocator(alloc);
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
    }

    var config = if (opts.default) try Config.default(alloc) else try Config.load(alloc);
    defer config.deinit();

    const stdout = std.io.getStdOut().writer();

    const info = @typeInfo(Config);
    std.debug.assert(info == .Struct);

    try config.formatConfig(stdout);

    return 0;
}
