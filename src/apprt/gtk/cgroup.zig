/// Contains all the logic for putting the Ghostty process and
/// each individual surface into its own cgroup.
const std = @import("std");
const assert = std.debug.assert;

const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");

const Allocator = std.mem.Allocator;
const App = @import("App.zig");
const internal_os = @import("../../os/main.zig");

const log = std.log.scoped(.gtk_systemd_cgroup);

/// Initialize the cgroup for the app. This will create our
/// transient scope, initialize the cgroups we use for the app,
/// configure them, and return the cgroup path for the app.
pub fn init(app: *App) ![]const u8 {
    const pid = std.os.linux.getpid();
    const alloc = app.core_app.alloc;

    // Get our initial cgroup. We need this so we can compare
    // and detect when we've switched to our transient group.
    const original = try internal_os.cgroup.current(
        alloc,
        pid,
    ) orelse "";
    defer alloc.free(original);

    // Create our transient scope. If this succeeds then the unit
    // was created, but we may not have moved into it yet, so we need
    // to do a dumb busy loop to wait for the move to complete.
    try createScope(app, pid);
    const transient = transient: while (true) {
        const current = try internal_os.cgroup.current(
            alloc,
            pid,
        ) orelse "";
        if (!std.mem.eql(u8, original, current)) break :transient current;
        alloc.free(current);
        std.time.sleep(25 * std.time.ns_per_ms);
    };
    errdefer alloc.free(transient);
    log.info("transient scope created cgroup={s}", .{transient});

    // Create the app cgroup and put ourselves in it. This is
    // required because controllers can't be configured while a
    // process is in a cgroup.
    try internal_os.cgroup.create(transient, "app", pid);

    // Create a cgroup that will contain all our surfaces. We will
    // enable the controllers and configure resource limits for surfaces
    // only on this cgroup so that it doesn't affect our main app.
    try internal_os.cgroup.create(transient, "surfaces", null);
    const surfaces = try std.fmt.allocPrint(alloc, "{s}/surfaces", .{transient});
    defer alloc.free(surfaces);

    // Enable all of our cgroup controllers. If these fail then
    // we just log. We can't reasonably undo what we've done above
    // so we log the warning and still return the transient group.
    // I don't know a scenario where this fails yet.
    try enableControllers(alloc, transient);
    try enableControllers(alloc, surfaces);

    // Configure the "high" memory limit. This limit is used instead
    // of "max" because it's a soft limit that can be exceeded and
    // can be monitored by things like systemd-oomd to kill if needed,
    // versus an instant hard kill.
    if (app.config.@"linux-cgroup-memory-limit") |limit| {
        try internal_os.cgroup.configureLimit(surfaces, .{
            .memory_high = limit,
        });
    }

    // Configure the "max" pids limit. This is a hard limit and cannot be
    // exceeded.
    if (app.config.@"linux-cgroup-processes-limit") |limit| {
        try internal_os.cgroup.configureLimit(surfaces, .{
            .pids_max = limit,
        });
    }

    return transient;
}

/// Enable all the cgroup controllers for the given cgroup.
fn enableControllers(alloc: Allocator, cgroup: []const u8) !void {
    const raw = try internal_os.cgroup.controllers(alloc, cgroup);
    defer alloc.free(raw);

    // Build our string builder for enabling all controllers
    var builder = std.ArrayList(u8).init(alloc);
    defer builder.deinit();

    // Controllers are space-separated
    var it = std.mem.splitScalar(u8, raw, ' ');
    while (it.next()) |controller| {
        try builder.append('+');
        try builder.appendSlice(controller);
        if (it.rest().len > 0) try builder.append(' ');
    }

    // Enable them all
    try internal_os.cgroup.configureControllers(
        cgroup,
        builder.items,
    );
}

/// Create a transient systemd scope unit for the current process.
///
/// On success this will return the name of the transient scope
/// cgroup prefix, allocated with the given allocator.
fn createScope(app: *App, pid_: std.os.linux.pid_t) !void {
    const gio_app = app.app.as(gio.Application);
    const connection = gio_app.getDbusConnection() orelse
        return error.DbusConnectionRequired;

    const pid: u32 = @intCast(pid_);

    // The unit name needs to be unique. We use the pid for this.
    var name_buf: [256]u8 = undefined;
    const name = std.fmt.bufPrintZ(
        &name_buf,
        "app-ghostty-transient-{}.scope",
        .{pid},
    ) catch unreachable;

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

        // https://www.freedesktop.org/software/systemd/man/latest/systemd-oomd.service.html
        const pressure_value = glib.Variant.newString("kill");

        builder.add("(sv)", "ManagedOOMMemoryPressure", pressure_value);

        // Delegate
        const delegate_value = glib.Variant.newBoolean(1);
        builder.add("(sv)", "Delegate", delegate_value);

        // Pid to move into the unit
        const pids_value_type = glib.VariantType.new("u");
        defer glib.free(pids_value_type);

        const pids_value = glib.Variant.newFixedArray(pids_value_type, &pid, 1, @sizeOf(u32));

        builder.add("(sv)", "PIDs", pids_value);
    }

    {
        // Aux
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

    const reply = connection.callSync(
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
