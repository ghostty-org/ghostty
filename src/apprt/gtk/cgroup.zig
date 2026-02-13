/// Contains all the logic for putting individual surfaces into
/// transient systemd scopes.
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = @import("../../quirks.zig").inlineAssert;

const gio = @import("gio");
const glib = @import("glib");

const internal_os = @import("../../os/main.zig");

const log = std.log.scoped(.gtk_systemd_cgroup);

pub const Options = struct {
    memory_high: ?u64 = null,
    tasks_max: ?u64 = null,
};

pub fn fmtScope(buf: []u8, pid: u32) [:0]const u8 {
    const fmt = "app-ghostty-surface-transient-{}.scope";

    assert(buf.len >= fmt.len - 2 + std.math.log10_int(@as(usize, std.math.maxInt(@TypeOf(pid)))) + 1);

    return std.fmt.bufPrintZ(buf, fmt, .{pid}) catch unreachable;
}

/// Create a transient systemd scope unit for the given process and
/// move the process into it.
pub fn createScope(
    dbus: *gio.DBusConnection,
    pid: u32,
    options: Options,
) error{DbusCallFailed}!void {
    // The unit name needs to be unique. We use the PID for this.
    var name_buf: [256]u8 = undefined;
    const name = fmtScope(&name_buf, pid);

    const builder_type = glib.VariantType.new("(ssa(sv)a(sa(sv)))");
    defer glib.free(builder_type);

    // Initialize our builder to build up our parameters
    var builder: glib.VariantBuilder = undefined;
    builder.init(builder_type);

    builder.add("s", name.ptr);
    builder.add("s", "fail");

    {
        // Properties
        const properties_type = glib.VariantType.new("a(sv)");
        defer glib.free(properties_type);

        builder.open(properties_type);
        defer builder.close();

        if (options.memory_high) |value| {
            builder.add("(sv)", "MemoryHigh", glib.Variant.newUint64(value));
        }

        if (options.tasks_max) |value| {
            builder.add("(sv)", "TasksMax", glib.Variant.newUint64(value));
        }

        // https://www.freedesktop.org/software/systemd/man/latest/systemd-oomd.service.html
        builder.add("(sv)", "ManagedOOMMemoryPressure", glib.Variant.newString("kill"));

        // PID to move into the unit
        const pids_value_type = glib.VariantType.new("u");
        defer glib.free(pids_value_type);

        const pids_value = glib.Variant.newFixedArray(pids_value_type, &pid, 1, @sizeOf(u32));

        builder.add("(sv)", "PIDs", pids_value);
    }

    {
        // Aux - unused but must be present
        const aux_type = glib.VariantType.new("a(sa(sv))");
        defer glib.free(aux_type);

        builder.open(aux_type);
        defer builder.close();
    }

    var err: ?*glib.Error = null;
    defer if (err) |e| e.free();

    const reply_type = glib.VariantType.new("(o)");
    defer glib.free(reply_type);

    const value = builder.end();

    const reply = dbus.callSync(
        "org.freedesktop.systemd1",
        "/org/freedesktop/systemd1",
        "org.freedesktop.systemd1.Manager",
        "StartTransientUnit",
        value,
        reply_type,
        .{},
        -1,
        null,
        &err,
    ) orelse {
        if (err) |e| log.err(
            "creating transient cgroup scope failed code={} err={s}",
            .{
                e.f_code,
                if (e.f_message) |msg| msg else "(no message)",
            },
        );
        return error.DbusCallFailed;
    };
    defer reply.unref();
}
