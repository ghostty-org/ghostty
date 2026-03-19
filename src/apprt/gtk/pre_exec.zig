const std = @import("std");

const log = std.log.scoped(.gtk_pre_exec);

const configpkg = @import("../../config.zig");

const internal_os = @import("../../os/main.zig");
const Command = @import("../../Command.zig");
const cgroup = @import("./cgroup.zig");

pub const PreExecInfo = struct {
    gtk_single_instance: configpkg.Config.GtkSingleInstance,
    linux_cgroup: configpkg.Config.LinuxCgroup,
    linux_cgroup_hard_fail: bool,

    pub fn init(cfg: *const configpkg.Config) PreExecInfo {
        return .{
            .gtk_single_instance = cfg.@"gtk-single-instance",
            .linux_cgroup = cfg.@"linux-cgroup",
            .linux_cgroup_hard_fail = cfg.@"linux-cgroup-hard-fail",
        };
    }
};

/// If we are expecting to be moved to a transient systemd scope, wait to see if
/// that happens by checking for the correct name of the current cgroup. Wait at
/// most 250ms so that we don't overly delay the soft-fail scenario.
///
/// If we are configured to hard fail, log an error message and return an error
/// code if we don't detect the move in time.
pub fn preExec(cmd: *Command) ?u8 {
    switch (cmd.rt_pre_exec_info.linux_cgroup) {
        .always => {},
        .never => return null,
        .@"single-instance" => switch (cmd.rt_pre_exec_info.gtk_single_instance) {
            .true => {},
            .false => return null,
            .detect => {
                log.err("gtk-single-instance is set to detect", .{});
                return 127;
            },
        },
    }

    const pid: u32 = @intCast(std.os.linux.getpid());

    var expected_cgroup_buf: [256]u8 = undefined;
    const expected_cgroup = cgroup.fmtScope(&expected_cgroup_buf, pid);

    const start = std.time.Instant.now() catch unreachable;

    while (true) {
        const now = std.time.Instant.now() catch unreachable;

        if (now.since(start) > 250 * std.time.ns_per_ms) {
            if (cmd.rt_pre_exec_info.linux_cgroup_hard_fail) {
                log.err("transition to new transient systemd scope took too long", .{});
                return 127;
            }
            break;
        }

        not_found: {
            var current_cgroup_buf: [4096]u8 = undefined;

            const current_cgroup_raw = internal_os.cgroup.current(
                &current_cgroup_buf,
                @intCast(pid),
            ) orelse break :not_found;

            const index = std.mem.lastIndexOfScalar(u8, current_cgroup_raw, '/') orelse break :not_found;
            const current_cgroup = current_cgroup_raw[index + 1 ..];

            if (std.mem.eql(u8, current_cgroup, expected_cgroup)) return null;
        }

        std.Thread.sleep(25 * std.time.ns_per_ms);
    }

    return null;
}
