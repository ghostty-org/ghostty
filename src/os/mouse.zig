const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.os);

extern "user32" fn GetDoubleClickTime() callconv(.winapi) u32;

/// The system-configured double-click interval if its available.
pub fn clickInterval() ?u32 {
    return switch (builtin.os.tag) {
        .windows => GetDoubleClickTime(),

        else => null,
    };
}
