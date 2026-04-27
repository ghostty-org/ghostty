const std = @import("std");

pub const SidePanel = struct {
    pub const Interface = struct {
        create_split: *const fn () [:0]const u8,
        focus_split: *const fn ([:0]const u8) void,
        split_exists: *const fn ([:0]const u8) bool,
        run_command: *const fn (split: [:0]const u8, cwd: [:0]const u8, cmd: [:0]const u8) void,
    };

    pub fn create(comptime T: type) Interface {
        return .{
            .create_split = T.create_split,
            .focus_split = T.focus_split,
            .split_exists = T.split_exists,
            .run_command = T.run_command,
        };
    }
};
