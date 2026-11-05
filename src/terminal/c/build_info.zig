const std = @import("std");
const builtin = @import("builtin");
const lib = @import("../lib.zig");
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
    version_string = 5,
    version_major = 6,
    version_minor = 7,
    version_patch = 8,
    version_pre = 9,
    version_build = 10,
    feature_snapshot = 11,
    feature_formatter = 12,
    feature_selection = 13,
    feature_search = 14,
    feature_render_state = 15,
    feature_input_encode = 16,
    feature_color = 17,
    feature_grid_introspection = 18,
    feature_glyph_protocol = 19,

    _,

    /// Output type expected for querying the data of the given kind.
    pub fn OutType(comptime self: BuildInfo) type {
        return switch (self) {
            .invalid => void,
            .simd,
            .kitty_graphics,
            .tmux_control_mode,
            .feature_snapshot,
            .feature_formatter,
            .feature_selection,
            .feature_search,
            .feature_render_state,
            .feature_input_encode,
            .feature_color,
            .feature_grid_introspection,
            .feature_glyph_protocol,
            => bool,
            .optimize => OptimizeMode,
            .version_string, .version_pre, .version_build => lib.String,
            .version_major, .version_minor, .version_patch => usize,
            _ => void,
        };
    }
};

/// The library version as a null-terminated string, for ghostty_version.
/// It has the same text as the version_string build info.
const version_z: [:0]const u8 = std.fmt.comptimePrint(
    "{s}",
    .{build_options.version_string},
);

/// C: ghostty_version
pub fn version() callconv(lib.calling_conv) [*:0]const u8 {
    return version_z.ptr;
}

pub fn get(
    data: BuildInfo,
    out: ?*anyopaque,
) callconv(lib.calling_conv) Result {
    return switch (data) {
        _ => .unsupported,
        .invalid => .invalid_value,
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
            .debug => .debug,
            .safe => .release_safe,
            .small => .release_small,
            .fast => .release_fast,
        },
        .version_string => out.* = .{ .ptr = build_options.version_string.ptr, .len = build_options.version_string.len },
        .version_major => out.* = build_options.version_major,
        .version_minor => out.* = build_options.version_minor,
        .version_patch => out.* = build_options.version_patch,
        .version_pre => {
            if (build_options.version_pre) |b| {
                out.* = .{ .ptr = b.ptr, .len = b.len };
            } else {
                out.* = .{ .ptr = "", .len = 0 };
            }
        },
        .version_build => {
            if (build_options.version_build) |b| {
                out.* = .{ .ptr = b.ptr, .len = b.len };
            } else {
                out.* = .{ .ptr = "", .len = 0 };
            }
        },
        .feature_snapshot => out.* = lib.feature(.snapshot),
        .feature_formatter => out.* = lib.feature(.formatter),
        .feature_selection => out.* = lib.feature(.selection),
        .feature_search => out.* = lib.feature(.search),
        .feature_render_state => out.* = lib.feature(.render_state),
        .feature_input_encode => out.* = lib.feature(.input_encode),
        .feature_color => out.* = lib.feature(.color),
        .feature_grid_introspection => out.* = lib.feature(.grid_introspection),
        .feature_glyph_protocol => out.* = lib.feature(.glyph_protocol),
        _ => comptime unreachable,
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

test "get feature keys" {
    const testing = std.testing;
    inline for (.{
        .{ BuildInfo.feature_snapshot, build_options.snapshot },
        .{ BuildInfo.feature_formatter, build_options.formatter },
        .{ BuildInfo.feature_selection, build_options.selection },
        .{ BuildInfo.feature_search, build_options.search },
        .{ BuildInfo.feature_render_state, build_options.render_state },
        .{ BuildInfo.feature_input_encode, build_options.input_encode },
        .{ BuildInfo.feature_color, build_options.color },
        .{ BuildInfo.feature_grid_introspection, build_options.grid_introspection },
        .{ BuildInfo.feature_glyph_protocol, build_options.glyph_protocol },
        .{ BuildInfo.kitty_graphics, build_options.kitty_graphics },
    }) |case| {
        var value: bool = !case[1];
        try testing.expectEqual(Result.success, get(case[0], @ptrCast(&value)));
        try testing.expectEqual(case[1], value);
    }
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
        .debug => .debug,
        .safe => .release_safe,
        .small => .release_small,
        .fast => .release_fast,
    }, value);
}

test "get version_string" {
    const testing = std.testing;
    var value: lib.String = undefined;
    try testing.expectEqual(Result.success, get(.version_string, @ptrCast(&value)));
    try testing.expect(value.len > 0);
}

test "get version_major" {
    const testing = std.testing;
    var value: usize = undefined;
    try testing.expectEqual(Result.success, get(.version_major, @ptrCast(&value)));
    try testing.expectEqual(build_options.version_major, value);
}

test "get version_minor" {
    const testing = std.testing;
    var value: usize = undefined;
    try testing.expectEqual(Result.success, get(.version_minor, @ptrCast(&value)));
    try testing.expectEqual(build_options.version_minor, value);
}

test "get version_patch" {
    const testing = std.testing;
    var value: usize = undefined;
    try testing.expectEqual(Result.success, get(.version_patch, @ptrCast(&value)));
    try testing.expectEqual(build_options.version_patch, value);
}

test "get version_pre" {
    const testing = std.testing;
    var value: lib.String = undefined;
    try testing.expectEqual(Result.success, get(.version_pre, @ptrCast(&value)));
}

test "get version_build" {
    const testing = std.testing;
    var value: lib.String = undefined;
    try testing.expectEqual(Result.success, get(.version_build, @ptrCast(&value)));
}

test "version" {
    const testing = std.testing;
    const value = std.mem.span(version());
    try testing.expectEqualStrings(build_options.version_string, value);

    var string: lib.String = undefined;
    try testing.expectEqual(Result.success, get(.version_string, @ptrCast(&string)));
    try testing.expectEqualStrings(string.ptr[0..string.len], value);
}

test "get invalid" {
    try std.testing.expectEqual(Result.invalid_value, get(.invalid, null));
}
