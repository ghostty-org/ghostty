const std = @import("std");
const Allocator = std.mem.Allocator;
const configpkg = @import("../config.zig");

const log = std.log.scoped(.shadertoy);

pub const Uniforms = extern struct {
    resolution: [3]f32 align(16),
    time: f32 align(4),
    time_delta: f32 align(4),
    frame_rate: f32 align(4),
    frame: i32 align(4),
    channel_time: [4][4]f32 align(16),
    channel_resolution: [4][4]f32 align(16),
    mouse: [4]f32 align(16),
    date: [4]f32 align(16),
    sample_rate: f32 align(4),
    current_cursor: [4]f32 align(16),
    previous_cursor: [4]f32 align(16),
    current_cursor_color: [4]f32 align(16),
    previous_cursor_color: [4]f32 align(16),
    current_cursor_style: i32 align(4),
    previous_cursor_style: i32 align(4),
    cursor_visible: i32 align(4),
    cursor_change_time: f32 align(4),
    time_focus: f32 align(4),
    focus: i32 align(4),
    palette: [256][4]f32 align(16),
    background_color: [4]f32 align(16),
    foreground_color: [4]f32 align(16),
    cursor_color: [4]f32 align(16),
    cursor_text: [4]f32 align(16),
    selection_background_color: [4]f32 align(16),
    selection_foreground_color: [4]f32 align(16),
};

pub const Target = enum { glsl, msl };

pub fn init() !void {}

pub fn loadFromFiles(
    _: Allocator,
    paths: configpkg.RepeatablePath,
    _: Target,
) ![]const [:0]const u8 {
    if (paths.value.items.len > 0) {
        log.warn(
            "custom shader configuration ignored because this build was compiled without custom shader support",
            .{},
        );
    }

    return &.{};
}
