const std = @import("std");
const wasm = @import("../os/wasm.zig");
const cli = @import("../cli.zig");
const alloc = wasm.alloc;

const Config = @import("Config.zig");

const log = std.log.scoped(.config);

/// Create a new configuration filled with the initial default values.
export fn config_new() ?*Config {
    const result = alloc.create(Config) catch |err| {
        log.err("error allocating config err={}", .{err});
        return null;
    };

    result.* = Config.default(alloc) catch |err| {
        log.err("error creating config err={}", .{err});
        return null;
    };

    return result;
}

export fn config_free(ptr: ?*Config) void {
    if (ptr) |v| {
        v.deinit();
        alloc.destroy(v);
    }
}

/// Load the configuration from a string in the same format as
/// the file-based syntax for the desktop version of the terminal.
export fn config_load_string(
    self: *Config,
    str: [*]const u8,
    len: usize,
) void {
    config_load_string_(self, str[0..len]) catch |err| {
        log.err("error loading config err={}", .{err});
    };
}

fn config_load_string_(self: *Config, str: []const u8) !void {
    var fbs = std.io.fixedBufferStream(str);
    var iter = cli.args.lineIterator(fbs.reader());
    try cli.args.parse(Config, @TypeOf(iter), alloc, self, &iter);
}

export fn config_finalize(self: *Config) void {
    self.finalize() catch |err| {
        log.err("error finalizing config err={}", .{err});
    };
}
