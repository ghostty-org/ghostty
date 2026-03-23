const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("terminal_options");
const Result = @import("result.zig").Result;

const log = std.log.scoped(.build_info_c);

/// C: GhosttyOptimizeMode
pub const OptimizeMode = enum(c_int) {
    debug = 0,
    release_safe = 1,
    release_small = 2,
    release_fast = 3,
};

/// C: GhosttyBuildInfo
pub const BuildInfo = enum(c_int) {
    invalid = 0,
    simd = 1,
    kitty_graphics = 2,
    tmux_control_mode = 3,
    optimize = 4,

    /// Output type expected for querying the data of the given kind.
    pub fn OutType(comptime self: BuildInfo) type {
        return switch (self) {
            .invalid => void,
            .simd, .kitty_graphics, .tmux_control_mode => bool,
            .optimize => OptimizeMode,
        };
    }
};

pub fn get(
    data: BuildInfo,
    out: ?*anyopaque,
) callconv(.c) Result {
    if (comptime std.debug.runtime_safety) {
        _ = std.meta.intToEnum(BuildInfo, @intFromEnum(data)) catch {
            log.warn("build_info invalid data value={d}", .{@intFromEnum(data)});
            return .invalid_value;
        };
    }

    if (data == .invalid) return .invalid_value;

    return switch (data) {
        .invalid => unreachable,
        inline else => |comptime_data| getTyped(
            comptime_data,
            @ptrCast(@alignCast(out)),
        ),
    };
}

fn getTyped(
    comptime data: BuildInfo,
    out: *data.OutType(),
) Result {
    switch (data) {
        .invalid => return .invalid_value,
        .simd => out.* = build_options.simd,
        .kitty_graphics => out.* = build_options.kitty_graphics,
        .tmux_control_mode => out.* = build_options.tmux_control_mode,
        .optimize => out.* = switch (builtin.mode) {
            .Debug => .debug,
            .ReleaseSafe => .release_safe,
            .ReleaseSmall => .release_small,
            .ReleaseFast => .release_fast,
        },
    }

    return .success;
}

test "get simd" {
    const testing = std.testing;
    var value: bool = undefined;
    try testing.expectEqual(Result.success, get(.simd, @ptrCast(&value)));
    try testing.expectEqual(build_options.simd, value);
}

test "get kitty_graphics" {
    const testing = std.testing;
    var value: bool = undefined;
    try testing.expectEqual(Result.success, get(.kitty_graphics, @ptrCast(&value)));
    try testing.expectEqual(build_options.kitty_graphics, value);
}

test "get tmux_control_mode" {
    const testing = std.testing;
    var value: bool = undefined;
    try testing.expectEqual(Result.success, get(.tmux_control_mode, @ptrCast(&value)));
    try testing.expectEqual(build_options.tmux_control_mode, value);
}

test "get optimize" {
    const testing = std.testing;
    var value: OptimizeMode = undefined;
    try testing.expectEqual(Result.success, get(.optimize, @ptrCast(&value)));
    try testing.expectEqual(switch (builtin.mode) {
        .Debug => .debug,
        .ReleaseSafe => .release_safe,
        .ReleaseSmall => .release_small,
        .ReleaseFast => .release_fast,
    }, value);
}

test "get invalid" {
    try std.testing.expectEqual(Result.invalid_value, get(.invalid, null));
}
