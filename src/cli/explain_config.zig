const std = @import("std");
const args = @import("args.zig");
const Allocator = std.mem.Allocator;
const Action = @import("ghostty.zig").Action;
const help_strings = @import("help_strings");
const Config = @import("../config/Config.zig");
const ConfigKey = @import("../config/key.zig").Key;
const KeybindAction = @import("../input/Binding.zig").Action;
const Pager = @import("Pager.zig");

pub const Options = struct {
    /// The config option to explain. For example:
    ///
    ///   winghostty +explain-config --option=font-size
    option: ?[]const u8 = null,

    /// The keybind action to explain. For example:
    ///
    ///   winghostty +explain-config --keybind=copy_to_clipboard
    keybind: ?[]const u8 = null,

    pub fn deinit(self: Options) void {
        _ = self;
    }

    /// Enables `-h` and `--help` to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `explain-config` command prints the documentation for a single
/// winghostty configuration option or keybind action.
///
/// Examples:
///
///   winghostty +explain-config font-size
///   winghostty +explain-config copy_to_clipboard
///   winghostty +explain-config --option=font-size
///   winghostty +explain-config --keybind=copy_to_clipboard
///
/// Flags:
///
///   * `--option`: The name of the configuration option to explain.
///   * `--keybind`: The name of the keybind action to explain.
///   * `--no-pager`: Disable automatic paging of output.
pub fn run(alloc: Allocator) !u8 {
    var option_name: ?[]const u8 = null;
    var keybind_name: ?[]const u8 = null;
    var positional: ?[]const u8 = null;
    var no_pager: bool = false;

    var iter = try args.argsIterator(alloc);
    defer iter.deinit();
    defer if (option_name) |s| alloc.free(s);
    defer if (keybind_name) |s| alloc.free(s);
    defer if (positional) |s| alloc.free(s);

    while (iter.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--option=")) {
            option_name = try alloc.dupe(u8, arg["--option=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--keybind=")) {
            keybind_name = try alloc.dupe(u8, arg["--keybind=".len..]);
        } else if (std.mem.eql(u8, arg, "--no-pager")) {
            no_pager = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return Action.help_error;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            positional = try alloc.dupe(u8, arg);
        }
    }

    // Resolve what to look up. Explicit flags go directly to their
    // respective lookup. A bare positional argument tries config
    // options first, then keybind actions as a fallback.
    const name = keybind_name orelse option_name orelse positional orelse {
        var stderr: std.fs.File = .stderr();
        var buffer: [4096]u8 = undefined;
        var stderr_writer = stderr.writer(&buffer);
        try stderr_writer.interface.writeAll("Usage: winghostty +explain-config <option>\n");
        try stderr_writer.interface.writeAll("       winghostty +explain-config --option=<option>\n");
        try stderr_writer.interface.writeAll("       winghostty +explain-config --keybind=<action>\n");
        try stderr_writer.end();
        return 1;
    };

    const text = if (keybind_name != null)
        explainKeybind(name)
    else if (option_name != null)
        explainOption(name)
    else
        explainOption(name) orelse explainKeybind(name);

    var pager: Pager = if (!no_pager) .init(alloc) else .{};
    defer pager.deinit();
    var buffer: [4096]u8 = undefined;
    const writer = pager.writer(&buffer);

    if (text) |t| {
        try writer.writeAll(t);
        try writer.writeAll("\n");
    } else {
        try writer.writeAll("Unknown: '");
        try writer.writeAll(name);
        try writer.writeAll("'.\n");
        try writer.flush();
        return 1;
    }

    try writer.flush();
    return 0;
}

fn explainOption(name: []const u8) ?[]const u8 {
    const key = std.meta.stringToEnum(ConfigKey, name) orelse return null;
    return switch (key) {
        inline else => |tag| {
            const field_name = @tagName(tag);
            return if (@hasDecl(help_strings.Config, field_name))
                @field(help_strings.Config, field_name)
            else
                null;
        },
    };
}

fn explainKeybind(name: []const u8) ?[]const u8 {
    const tag = std.meta.stringToEnum(std.meta.Tag(KeybindAction), name) orelse return null;
    return switch (tag) {
        inline else => |t| {
            const field_name = @tagName(t);
            return if (@hasDecl(help_strings.KeybindAction, field_name))
                @field(help_strings.KeybindAction, field_name)
            else
                null;
        },
    };
}

test "explain" {
    // Config options
    try std.testing.expect(explainOption("font-size") != null);
    try std.testing.expect(explainOption("copy_to_clipboard") == null);
    try std.testing.expect(explainOption("unknown-option") == null);

    // Keybind actions
    try std.testing.expect(explainKeybind("copy_to_clipboard") != null);
    try std.testing.expect(explainKeybind("font-size") == null);
    try std.testing.expect(explainKeybind("unknown_keybind") == null);
}
