const std = @import("std");
const cli = @import("../cli.zig");
const inputpkg = @import("../input.zig");
const global = &@import("../global.zig").state;

const Config = @import("Config.zig");
const c_get = @import("c_get.zig");
const edit = @import("edit.zig");
const Key = @import("key.zig").Key;

const log = std.log.scoped(.config);

/// Create a new configuration filled with the initial default values.
export fn ghostty_config_new() ?*Config {
    const result = global.alloc.create(Config) catch |err| {
        log.err("error allocating config err={}", .{err});
        return null;
    };

    result.* = Config.default(global.alloc) catch |err| {
        log.err("error creating config err={}", .{err});
        return null;
    };

    return result;
}

export fn ghostty_config_free(ptr: ?*Config) void {
    if (ptr) |v| {
        v.deinit();
        global.alloc.destroy(v);
    }
}

/// Load the configuration from the CLI args.
export fn ghostty_config_load_cli_args(self: *Config) void {
    self.loadCliArgs(global.alloc) catch |err| {
        log.err("error loading config err={}", .{err});
    };
}

/// Load the configuration from a string in the same format as
/// the file-based syntax for the desktop version of the terminal.
export fn ghostty_config_load_string(
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
    try cli.args.parse(Config, @TypeOf(iter), global.alloc, self, &iter);
}

/// Load the configuration from the default file locations. This
/// is usually done first. The default file locations are locations
/// such as the home directory.
export fn ghostty_config_load_default_files(self: *Config) void {
    self.loadDefaultFiles(global.alloc) catch |err| {
        log.err("error loading config err={}", .{err});
    };
}

/// Load the configuration from the user-specified configuration
/// file locations in the previously loaded configuration. This will
/// recursively continue to load up to a built-in limit.
export fn ghostty_config_load_recursive_files(self: *Config) void {
    self.loadRecursiveFiles(global.alloc) catch |err| {
        log.err("error loading config err={}", .{err});
    };
}

export fn ghostty_config_finalize(self: *Config) void {
    self.finalize() catch |err| {
        log.err("error finalizing config err={}", .{err});
    };
}

export fn ghostty_config_get(
    self: *Config,
    ptr: *anyopaque,
    key_str: [*]const u8,
    len: usize,
) bool {
    @setEvalBranchQuota(10_000);
    const key = std.meta.stringToEnum(Key, key_str[0..len]) orelse return false;
    return c_get.get(self, key, ptr);
}

export fn ghostty_config_trigger(
    self: *Config,
    str: [*]const u8,
    len: usize,
) inputpkg.Binding.Trigger.C {
    return config_trigger_(self, str[0..len]) catch |err| err: {
        log.err("error finding trigger err={}", .{err});
        break :err .{};
    };
}

fn config_trigger_(
    self: *Config,
    str: []const u8,
) !inputpkg.Binding.Trigger.C {
    const action = try inputpkg.Binding.Action.parse(str);
    const trigger: inputpkg.Binding.Trigger = self.keybind.set.getTrigger(action) orelse .{};
    return trigger.cval();
}

export fn ghostty_config_errors_count(self: *Config) u32 {
    return @intCast(self._errors.list.items.len);
}

export fn ghostty_config_get_error(self: *Config, idx: u32) Error {
    if (idx >= self._errors.list.items.len) return .{};
    const err = self._errors.list.items[idx];
    return .{ .message = err.message.ptr };
}

export fn ghostty_config_open() void {
    edit.open(global.alloc) catch |err| {
        log.err("error opening config in editor err={}", .{err});
    };
}

/// Sync with ghostty_error_s
const Error = extern struct {
    message: [*:0]const u8 = "",
};
