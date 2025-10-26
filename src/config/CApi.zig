const std = @import("std");
const assert = std.debug.assert;
const cli = @import("../cli.zig");
const inputpkg = @import("../input.zig");
const state = &@import("../global.zig").state;
const c = @import("../main_c.zig");

const Config = @import("Config.zig");
const c_get = @import("c_get.zig");
const edit = @import("edit.zig");
const Key = @import("key.zig").Key;

const log = std.log.scoped(.config);

/// Create a new configuration filled with the initial default values.
export fn ghostty_config_new() ?*Config {
    const result = state.alloc.create(Config) catch |err| {
        log.err("error allocating config err={}", .{err});
        return null;
    };

    result.* = Config.default(state.alloc) catch |err| {
        log.err("error creating config err={}", .{err});
        state.alloc.destroy(result);
        return null;
    };

    return result;
}

export fn ghostty_config_free(ptr: ?*Config) void {
    if (ptr) |v| {
        v.deinit();
        state.alloc.destroy(v);
    }
}

/// Deep clone the configuration.
export fn ghostty_config_clone(self: *Config) ?*Config {
    const result = state.alloc.create(Config) catch |err| {
        log.err("error allocating config err={}", .{err});
        return null;
    };

    result.* = self.clone(state.alloc) catch |err| {
        log.err("error cloning config err={}", .{err});
        state.alloc.destroy(result);
        return null;
    };

    return result;
}

/// Load the configuration from the CLI args.
export fn ghostty_config_load_cli_args(self: *Config) void {
    self.loadCliArgs(state.alloc) catch |err| {
        log.err("error loading config err={}", .{err});
    };
}

/// Load the configuration from the default file locations. This
/// is usually done first. The default file locations are locations
/// such as the home directory.
export fn ghostty_config_load_default_files(self: *Config) void {
    self.loadDefaultFiles(state.alloc) catch |err| {
        log.err("error loading config err={}", .{err});
    };
}

/// Load the configuration from the user-specified configuration
/// file locations in the previously loaded configuration. This will
/// recursively continue to load up to a built-in limit.
export fn ghostty_config_load_recursive_files(self: *Config) void {
    self.loadRecursiveFiles(state.alloc) catch |err| {
        log.err("error loading config err={}", .{err});
    };
}

/// Load the configuration from a specific file path.
/// The path must be null-terminated.
export fn ghostty_config_load_file(self: *Config, path: [*:0]const u8) void {
    const path_slice = std.mem.span(path);
    self.loadFile(state.alloc, path_slice) catch |err| {
        log.err("error loading config from file path={s} err={}", .{ path_slice, err });
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

export fn ghostty_config_set(
    self: *Config,
    key_str: [*]const u8,
    key_len: usize,
    value_str: [*]const u8,
    value_len: usize,
) bool {
    @setEvalBranchQuota(10_000);
    const key = key_str[0..key_len];
    const value = value_str[0..value_len];

    const entry = std.fmt.allocPrint(state.alloc, "--{s}={s}", .{ key, value }) catch |err| {
        log.err("error setting {s} to {s} trigger err={}", .{ key, value, err });
        return false;
    };

    var it: SimpleIterator = .{ .data = &.{
        entry,
    } };
    self.loadIter(state.alloc, &it) catch |err| {
        log.err("error changing config err={}", .{err});
        return false;
    };
    return true;
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

export fn ghostty_config_diagnostics_count(self: *Config) u32 {
    return @intCast(self._diagnostics.items().len);
}

export fn ghostty_config_get_diagnostic(self: *Config, idx: u32) Diagnostic {
    const items = self._diagnostics.items();
    if (idx >= items.len) return .{};
    const message = self._diagnostics.precompute.messages.items[idx];
    return .{ .message = message.ptr };
}

export fn ghostty_config_open_path() c.String {
    const path = edit.openPath(state.alloc) catch |err| {
        log.err("error opening config in editor err={}", .{err});
        return .empty;
    };

    return .fromSlice(path);
}

/// Export the configuration to a string.
/// Returns null-terminated string on success, empty string on error.
/// The returned string must be freed with ghostty_string_free.
export fn ghostty_config_export_string(config: *Config) [*:0]const u8 {
    // Safety check: ensure config pointer is valid
    if (@intFromPtr(config) == 0) {
        log.err("config pointer is null in ghostty_config_export_string", .{});
        return "";
    }

    var buf: std.Io.Writer.Allocating = .init(state.alloc);
    defer buf.deinit();

    // Try the same approach as show_config.zig
    const formatter = @import("formatter.zig").FileFormatter{
        .alloc = state.alloc,
        .config = config,
        .docs = false,
        .changed = true,
    };

    formatter.format(&buf.writer) catch |err| {
        log.err("error formatting config err={}", .{err});
        return "";
    };

    const result = buf.toOwnedSliceSentinel(0) catch |err| {
        log.err("error duplicating config string err={}", .{err});
        return "";
    };

    return result;
}

/// Sync with ghostty_diagnostic_s
const Diagnostic = extern struct {
    message: [*:0]const u8 = "",
};

/// Helper iterator for ghostty_config_set
const SimpleIterator = struct {
    data: []const []const u8,
    i: usize = 0,

    pub fn next(self: *SimpleIterator) ?[]const u8 {
        if (self.i >= self.data.len) return null;
        const result = self.data[self.i];
        self.i += 1;
        return result;
    }
};
