const std = @import("std");
const cli = @import("cli.zig");
const state = &@import("../global.zig").state;

const log = std.log.scoped(.benchmark);

/// Run the Ghostty benchmark CLI with the given action and arguments.
export fn ghostty_benchmark_cli(
    action_name_: [*:0]const u8,
    args: [*:0]const u8,
) bool {
    const action_name = std.mem.sliceTo(action_name_, 0);
    const action: cli.Action = std.meta.stringToEnum(
        cli.Action,
        action_name,
    ) orelse {
        log.warn("unknown action={s}", .{action_name});
        return false;
    };

    cli.mainAction(
        state.alloc,
        action,
        .{ .string = std.mem.sliceTo(args, 0) },
    ) catch |err| {
        log.warn("failed to run action={s} err={}", .{
            @tagName(action),
            err,
        });
        return false;
    };

    return true;
}
