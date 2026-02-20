const std = @import("std");

const gio = @import("gio");
const glib = @import("glib");

const log = std.log.scoped(.gtk_post_fork);

const configpkg = @import("../../config.zig");
const internal_os = @import("../../os/main.zig");
const Command = @import("../../Command.zig");
const cgroup = @import("./cgroup.zig");

const Application = @import("class/application.zig").Application;

pub const PostForkInfo = struct {
    gtk_single_instance: configpkg.Config.GtkSingleInstance,
    linux_cgroup: configpkg.Config.LinuxCgroup,
    linux_cgroup_hard_fail: bool,
    linux_cgroup_memory_limit: ?u64,
    linux_cgroup_processes_limit: ?u64,

    pub fn init(cfg: *const configpkg.Config) PostForkInfo {
        return .{
            .gtk_single_instance = cfg.@"gtk-single-instance",
            .linux_cgroup = cfg.@"linux-cgroup",
            .linux_cgroup_hard_fail = cfg.@"linux-cgroup-hard-fail",
            .linux_cgroup_memory_limit = cfg.@"linux-cgroup-memory-limit",
            .linux_cgroup_processes_limit = cfg.@"linux-cgroup-processes-limit",
        };
    }
};

/// If we are configured to do so, tell `systemd` to move the new child PID into
/// a transient `systemd` scope with the configured resource limits.
///
/// If we are configured to hard fail, log an error message and return an error
/// code if we don't detect the move in time.
pub fn postFork(cmd: *Command) Command.PostForkError!void {
    switch (cmd.rt_post_fork_info.linux_cgroup) {
        .always => {},
        .never => return,
        .@"single-instance" => switch (cmd.rt_post_fork_info.gtk_single_instance) {
            .true => {},
            .false => return,
            .detect => {
                log.err("gtk-single-instance is set to detect which should be impossible!", .{});
                return error.PostForkError;
            },
        },
    }

    const pid: u32 = @intCast(cmd.pid orelse {
        log.err("PID of child not known!", .{});
        return error.PostForkError;
    });

    var expected_cgroup_buf: [256]u8 = undefined;
    const expected_cgroup = cgroup.fmtScope(&expected_cgroup_buf, pid);

    log.debug("beginning transition to transient systemd scope {s}", .{expected_cgroup});

    const app = Application.default();

    const dbus = app.as(gio.Application).getDbusConnection() orelse {
        if (cmd.rt_post_fork_info.linux_cgroup_hard_fail) {
            log.err("dbus connection required for cgroup isolation, exiting", .{});
            return error.PostForkError;
        }
        return;
    };

    cgroup.createScope(
        dbus,
        pid,
        .{
            .memory_high = cmd.rt_post_fork_info.linux_cgroup_memory_limit,
            .tasks_max = cmd.rt_post_fork_info.linux_cgroup_processes_limit,
        },
    ) catch |err| {
        if (cmd.rt_post_fork_info.linux_cgroup_hard_fail) {
            log.err("unable to create transient systemd scope {s}: {t}", .{ expected_cgroup, err });
            return error.PostForkError;
        }
        log.warn("unable to create transient systemd scope {s}: {t}", .{ expected_cgroup, err });
        return;
    };

    const start = std.time.Instant.now() catch unreachable;

    loop: while (true) {
        const now = std.time.Instant.now() catch unreachable;

        if (now.since(start) > 250 * std.time.ns_per_ms) {
            if (cmd.rt_pre_exec_info.linux_cgroup_hard_fail) {
                log.err("transition to new transient systemd scope {s} took too long", .{expected_cgroup});
                return error.PostForkError;
            }
            log.warn("transition to transient systemd scope {s} took too long", .{expected_cgroup});
            break :loop;
        }

        not_found: {
            var current_cgroup_buf: [4096]u8 = undefined;

            const current_cgroup_raw = internal_os.cgroup.current(
                &current_cgroup_buf,
                @intCast(pid),
            ) orelse break :not_found;

            const index = std.mem.lastIndexOfScalar(u8, current_cgroup_raw, '/') orelse break :not_found;
            const current_cgroup = current_cgroup_raw[index + 1 ..];

            if (std.mem.eql(u8, current_cgroup, expected_cgroup)) {
                log.debug("transition to transient systemd scope {s} complete", .{expected_cgroup});
                break :loop;
            }
        }

        std.Thread.sleep(25 * std.time.ns_per_ms);
    }
}
