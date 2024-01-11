const std = @import("std");
const inputpkg = @import("../input.zig");
const args = @import("args.zig");
const Arena = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const Config = @import("../config/Config.zig");

pub const Options = struct {
    /// If true, print out the default keybinds instead of the ones
    /// configured in the config file.
    default: bool = false,

    pub fn deinit(self: Options) void {
        _ = self;
    }
};

/// The "list-keybinds" command is used to list all the available keybinds
/// for Ghostty.
///
/// When executed without any arguments this will list the current keybinds
/// loaded by the config file. If no config file is found or there aren't any
/// changes to the keybinds it will print out the default ones configured for
/// Ghostty
///
/// The "--default" argument will print out all the default keybinds
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
    try config.keybind.formatConfig(stdout, "keybind=");

    return 0;
}
