//! Wrapper for a Config object that keeps track of which settings have been
//! changed. Settings will be marked as set even if they are set to whatever the
//! default value is for that setting. This allows overrides of a setting from
//! a non-default value to the default value. To remove an override it must be
//! explicitly removed from the set that keeps track of what config entries have
//! been changed.

const ConfigOverrides = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const configpkg = @import("../config.zig");
const args = @import("../cli/args.zig");
const Config = configpkg.Config;
const Key = Config.Key;
const Type = Config.Type;

const log = std.log.scoped(.config_overrides);

/// Used to keep track of which settings have been overridden.
isset: std.EnumSet(configpkg.Config.Key),

/// Storage for the overriding settings.
config: configpkg.Config,

/// Create a new object that has no config settings overridden.
pub fn init(self: *ConfigOverrides, alloc: Allocator) Allocator.Error!void {
    self.* = .{
        .isset = .initEmpty(),
        .config = try .default(alloc),
    };
}

/// Has a config setting been overridden?
pub fn isSet(self: *const ConfigOverrides, comptime key: Key) bool {
    return self.isset.contains(key);
}

/// Set a configuration entry and mark it as having been overridden.
pub fn set(self: *ConfigOverrides, comptime key: Key, value: Type(key)) Allocator.Error!void {
    try self.config.set(key, value);
    self.isset.insert(key);
}

/// Mark a configuration entry as having not been overridden.
pub fn unset(self: *ConfigOverrides, comptime key: Key) void {
    self.isset.remove(key);
}

/// Get the value of a configuration entry.
pub fn get(self: *const ConfigOverrides, comptime key: Key) Type(key) {
    return self.config.get(key);
}

/// Parse a string that contains a CLI flag.
pub fn parseCLI(self: *ConfigOverrides, str: []const u8) !void {
    const k: []const u8, const v: ?[]const u8 = kv: {
        if (!std.mem.startsWith(u8, str, "--")) return;
        if (std.mem.indexOfScalarPos(u8, str, 2, '=')) |pos| {
            break :kv .{
                std.mem.trim(u8, str[2..pos], &std.ascii.whitespace),
                std.mem.trim(u8, str[pos + 1 ..], &std.ascii.whitespace),
            };
        }
        break :kv .{ std.mem.trim(u8, str[2..], &std.ascii.whitespace), null };
    };

    const key = std.meta.stringToEnum(Key, k) orelse return;
    try args.parseIntoField(Config, self.config.arenaAlloc(), &self.config, k, v);
    self.isset.insert(key);
}

pub fn deinit(self: *ConfigOverrides) callconv(.c) void {
    self.config.deinit();
}

test "ConfigOverrides" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var config_overrides: ConfigOverrides = undefined;
    try config_overrides.init(alloc);
    defer config_overrides.deinit();

    try testing.expect(config_overrides.isSet(.@"font-size") == false);
    try config_overrides.set(.@"font-size", 24.0);
    try testing.expect(config_overrides.isSet(.@"font-size") == true);
    try testing.expectApproxEqAbs(24.0, config_overrides.get(.@"font-size"), 0.01);

    try testing.expect(config_overrides.isSet(.@"working-directory") == false);
    try config_overrides.parseCLI("--working-directory=/home/ghostty");
    try testing.expect(config_overrides.isSet(.@"working-directory") == true);
    try testing.expectEqualStrings("/home/ghostty", config_overrides.get(.@"working-directory").?);
}
