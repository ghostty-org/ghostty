const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const posix = std.posix;
const xev = @import("../global.zig").xev;

const log = std.log.scoped(.flatpak);

/// Returns true if we're running in a Flatpak environment.
pub fn isFlatpak() bool {
    // If we're not on Linux then we'll make this comptime false.
    if (comptime builtin.os.tag != .linux) return false;
    return if (std.fs.accessAbsolute("/.flatpak-info", .{})) true else |_| false;
}

/// A struct to help execute commands on the host via the
/// org.freedesktop.Flatpak.Development DBus module. This uses GIO/GLib
/// under the hood.
///
/// This always spawns its own thread and maintains its own GLib event loop.
/// This makes it easy for the command to behave synchronously similar to
/// std.process.Child.
///
/// There are lots of chances for low-hanging improvements here (automatic
/// pipes, /dev/null, etc.) but this was purpose built for my needs so
/// it doesn't have all of those.
///
/// Requires GIO, GLib to be available and linked.
pub const FlatpakHostCommand = struct {
    const fd_t = posix.fd_t;
    const EnvMap = std.process.EnvMap;
    const c = @cImport({
        @cInclude("gio/gio.h");
        @cInclude("gio/gunixfdlist.h");
    });

    /// Argv are the arguments to call on the host with argv[0] being
    /// the command to execute.
    argv: []const []const u8,

    /// The cwd for the new process. If this is not set then it will use
    /// the current cwd of the calling process.
    cwd: ?[:0]const u8 = null,

    /// Environment variables for the child process. If this is null, this
    /// does not send any environment variables.
    env: ?*const EnvMap = null,

    /// File descriptors to send to the child process. It is up to the
    /// caller to create the file descriptors and set them up.
    stdin: fd_t,
    stdout: fd_t,
    stderr: fd_t,

    /// State of the process. This is updated by the dedicated thread it
    /// runs in and is protected by the given lock and condition variable.
    state: State = .{ .init = {} },
    state_mutex: std.Thread.Mutex = .{},
    state_cv: std.Thread.Condition = .{},

    /// State the process is in. This can't be inspected directly, you
    /// must use getters on the struct to get access.
    const State = union(enum) {
        /// Initial state
        init: void,

        /// Error starting. The error message is only available via logs.
        /// (This isn't a fundamental limitation, just didn't need the
        /// error message yet)
        err: void,

        /// Process started with the given pid on the host.
        started: struct {
            pid: u32,
            loop_xev: ?*xev.Loop,
            completion: ?*Completion,
            subscription: c.guint,
            loop: *c.GMainLoop,
        },

        /// Process exited
        exited: struct {
            pid: u32,
            status: u8,
        },
    };

    pub const Completion = struct {
        callback: *const fn (ud: ?*anyopaque, l: *xev.Loop, c: *Completion, r: WaitError!u8) void = noopCallback,
        c_xev: xev.Completion = .{},
        userdata: ?*anyopaque = null,
        timer: ?xev.Timer = null,
        result: ?WaitError!u8 = null,
    };

    /// Errors that are possible from us.
    pub const Error = error{
        FlatpakMustBeStarted,
        FlatpakSpawnFail,
        FlatpakSetupFail,
        FlatpakRPCFail,
    };

    pub const WaitError = xev.Timer.RunError || Error;

    /// Spawn the command. This will start the host command. On return,
    /// the pid will be available. This must only be called with the
    /// state in "init".
    ///
    /// Precondition: The self pointer MUST be stable.
    pub fn spawn(self: *FlatpakHostCommand, alloc: Allocator) !u32 {
        const thread = try std.Thread.spawn(.{}, threadMain, .{ self, alloc });
        thread.setName("flatpak-host-command") catch {};
        // We don't track this thread, it will terminate on its own on command exit
        thread.detach();

        // Wait for the process to start or error.
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        while (self.state == .init) self.state_cv.wait(&self.state_mutex);

        return switch (self.state) {
            .init => unreachable,
            .err => Error.FlatpakSpawnFail,
            .started => |v| v.pid,
            .exited => |v| v.pid,
        };
    }

    /// Wait for the process to end and return the exit status. This
    /// can only be called ONCE. Once this returns, the state is reset.
    pub fn wait(self: *FlatpakHostCommand) !u8 {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();

        while (true) {
            switch (self.state) {
                .init => return Error.FlatpakMustBeStarted,
                .err => return Error.FlatpakSpawnFail,
                .started => {},
                .exited => |v| {
                    self.state = .{ .init = {} };
                    self.state_cv.broadcast();
                    return v.status;
                },
            }

            self.state_cv.wait(&self.state_mutex);
        }
    }

    /// Wait for the process to end asynchronously via libxev. This
    /// can only be called ONCE.
    pub fn waitXev(
        self: *FlatpakHostCommand,
        loop: *xev.Loop,
        completion: *Completion,
        comptime Userdata: type,
        userdata: ?*Userdata,
        comptime cb: *const fn (
            ud: ?*Userdata,
            l: *xev.Loop,
            c: *Completion,
            r: WaitError!u8,
        ) void,
    ) void {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();

        completion.* = .{
            .callback = (struct {
                fn callback(
                    ud_: ?*anyopaque,
                    l_inner: *xev.Loop,
                    c_inner: *Completion,
                    r: WaitError!u8,
                ) void {
                    const ud = @as(?*Userdata, if (Userdata == void) null else @ptrCast(@alignCast(ud_)));
                    @call(.always_inline, cb, .{ ud, l_inner, c_inner, r });
                }
            }).callback,
            .userdata = userdata,
            .timer = xev.Timer.init() catch unreachable, // not great, but xev timer can't fail atm
        };

        switch (self.state) {
            .init => completion.result = Error.FlatpakMustBeStarted,
            .err => completion.result = Error.FlatpakSpawnFail,
            .started => |*v| {
                v.loop_xev = loop;
                v.completion = completion;
                return;
            },
            .exited => |v| {
                completion.result = v.status;
            },
        }

        completion.timer.?.run(
            loop,
            &completion.c_xev,
            0,
            anyopaque,
            completion.userdata,
            (struct {
                fn callback(
                    ud: ?*anyopaque,
                    l_inner: *xev.Loop,
                    c_inner: *xev.Completion,
                    r: xev.Timer.RunError!void,
                ) xev.CallbackAction {
                    const c_outer: *Completion = @fieldParentPtr("c_xev", c_inner);
                    defer if (c_outer.timer) |*t| t.deinit();

                    const result = if (r) |_| c_outer.result.? else |err| err;
                    c_outer.callback(ud, l_inner, c_outer, result);
                    return .disarm;
                }
            }).callback,
        );
    }

    /// Send a signal to the started command. This does nothing if the
    /// command is not in the started state.
    pub fn signal(self: *FlatpakHostCommand, sig: u8, pg: bool) !void {
        const pid = pid: {
            self.state_mutex.lock();
            defer self.state_mutex.unlock();
            switch (self.state) {
                .started => |v| break :pid v.pid,
                else => return,
            }
        };

        // Get our bus connection.
        var g_err: ?*c.GError = null;
        defer if (g_err) |ptr| c.g_error_free(ptr);
        const bus = c.g_bus_get_sync(c.G_BUS_TYPE_SESSION, null, &g_err) orelse {
            log.warn("signal error getting bus: {s}", .{g_err.?.*.message});
            return Error.FlatpakSetupFail;
        };
        defer c.g_object_unref(bus);

        const reply = c.g_dbus_connection_call_sync(
            bus,
            "org.freedesktop.Flatpak",
            "/org/freedesktop/Flatpak/Development",
            "org.freedesktop.Flatpak.Development",
            "HostCommandSignal",
            c.g_variant_new(
                "(uub)",
                pid,
                sig,
                @as(c_int, @intCast(@intFromBool(pg))),
            ),
            c.G_VARIANT_TYPE("()"),
            c.G_DBUS_CALL_FLAGS_NONE,
            c.G_MAXINT,
            null,
            &g_err,
        );
        if (g_err != null) {
            log.warn("signal send error: {s}", .{g_err.?.*.message});
            return;
        }
        defer c.g_variant_unref(reply);
    }

    fn threadMain(self: *FlatpakHostCommand, alloc: Allocator) void {
        // Create a new thread-local context so that all our sources go
        // to this context and we can run our loop correctly.
        const ctx = c.g_main_context_new();
        defer c.g_main_context_unref(ctx);
        c.g_main_context_push_thread_default(ctx);
        defer c.g_main_context_pop_thread_default(ctx);

        // Get our loop for the current thread
        const loop = c.g_main_loop_new(ctx, 1).?;
        defer c.g_main_loop_unref(loop);

        // Get our bus connection. This has to remain active until we exit
        // the thread otherwise our signals won't be called.
        var g_err: ?*c.GError = null;
        defer if (g_err) |ptr| c.g_error_free(ptr);
        const bus = c.g_bus_get_sync(c.G_BUS_TYPE_SESSION, null, &g_err) orelse {
            log.warn("spawn error getting bus: {s}", .{g_err.?.*.message});
            self.updateState(.{ .err = {} });
            return;
        };
        defer c.g_object_unref(bus);

        // Spawn the command first. This will setup all our IO.
        self.start(alloc, bus, loop) catch |err| {
            log.warn("error starting host command: {}", .{err});
            self.updateState(.{ .err = {} });
            return;
        };

        // Run the event loop. It quits in the exit callback.
        c.g_main_loop_run(loop);
    }

    /// Start the command. This will start the host command and set the
    /// pid field on success. This will not wait for completion.
    ///
    /// Once this is called, the self pointer MUST remain stable. This
    /// requirement is due to using GLib under the covers with callbacks.
    fn start(
        self: *FlatpakHostCommand,
        alloc: Allocator,
        bus: *c.GDBusConnection,
        loop: *c.GMainLoop,
    ) !void {
        var err: ?*c.GError = null;
        defer if (err) |ptr| c.g_error_free(ptr);
        var arena_allocator = std.heap.ArenaAllocator.init(alloc);
        defer arena_allocator.deinit();
        const arena = arena_allocator.allocator();

        // Our list of file descriptors that we need to send to the process.
        const fd_list = c.g_unix_fd_list_new();
        defer c.g_object_unref(fd_list);
        if (c.g_unix_fd_list_append(fd_list, self.stdin, &err) < 0) {
            log.warn("error adding fd: {s}", .{err.?.*.message});
            return Error.FlatpakSetupFail;
        }
        if (c.g_unix_fd_list_append(fd_list, self.stdout, &err) < 0) {
            log.warn("error adding fd: {s}", .{err.?.*.message});
            return Error.FlatpakSetupFail;
        }
        if (c.g_unix_fd_list_append(fd_list, self.stderr, &err) < 0) {
            log.warn("error adding fd: {s}", .{err.?.*.message});
            return Error.FlatpakSetupFail;
        }

        // Build our arguments for the file descriptors.
        const fd_builder = c.g_variant_builder_new(c.G_VARIANT_TYPE("a{uh}"));
        defer c.g_variant_builder_unref(fd_builder);
        c.g_variant_builder_add(fd_builder, "{uh}", @as(c_int, 0), self.stdin);
        c.g_variant_builder_add(fd_builder, "{uh}", @as(c_int, 1), self.stdout);
        c.g_variant_builder_add(fd_builder, "{uh}", @as(c_int, 2), self.stderr);

        // Build our env vars
        const env_builder = c.g_variant_builder_new(c.G_VARIANT_TYPE("a{ss}"));
        defer c.g_variant_builder_unref(env_builder);
        if (self.env) |env| {
            var it = env.iterator();
            while (it.next()) |pair| {
                const key = try arena.dupeZ(u8, pair.key_ptr.*);
                const value = try arena.dupeZ(u8, pair.value_ptr.*);
                c.g_variant_builder_add(env_builder, "{ss}", key.ptr, value.ptr);
            }
        }

        // Build our args
        const args = try arena.alloc(?[*:0]u8, self.argv.len + 1);
        for (0.., self.argv) |i, arg| {
            const argZ = try arena.dupeZ(u8, arg);
            args[i] = argZ.ptr;
        }
        args[args.len - 1] = null;

        // Get the cwd in case we don't have ours set. A small optimization
        // would be to do this only if we need it but this isn't a
        // common code path.
        const g_cwd = c.g_get_current_dir();
        defer c.g_free(g_cwd);

        // The params for our RPC call
        const params = c.g_variant_new(
            "(^ay^aay@a{uh}@a{ss}u)",
            @as(*const anyopaque, if (self.cwd) |*cwd| cwd.ptr else g_cwd),
            args.ptr,
            c.g_variant_builder_end(fd_builder),
            c.g_variant_builder_end(env_builder),
            @as(c_int, 0),
        );
        _ = c.g_variant_ref_sink(params); // take ownership
        defer c.g_variant_unref(params);

        // Subscribe to exit notifications
        const subscription_id = c.g_dbus_connection_signal_subscribe(
            bus,
            "org.freedesktop.Flatpak",
            "org.freedesktop.Flatpak.Development",
            "HostCommandExited",
            "/org/freedesktop/Flatpak/Development",
            null,
            0,
            onExit,
            self,
            null,
        );
        errdefer c.g_dbus_connection_signal_unsubscribe(bus, subscription_id);

        // Go!
        const reply = c.g_dbus_connection_call_with_unix_fd_list_sync(
            bus,
            "org.freedesktop.Flatpak",
            "/org/freedesktop/Flatpak/Development",
            "org.freedesktop.Flatpak.Development",
            "HostCommand",
            params,
            c.G_VARIANT_TYPE("(u)"),
            c.G_DBUS_CALL_FLAGS_NONE,
            c.G_MAXINT,
            fd_list,
            null,
            null,
            &err,
        ) orelse {
            log.warn("Flatpak.HostCommand failed: {s}", .{err.?.*.message});
            return Error.FlatpakRPCFail;
        };
        defer c.g_variant_unref(reply);

        var pid: u32 = 0;
        c.g_variant_get(reply, "(u)", &pid);
        log.debug("HostCommand started pid={} subscription={}", .{
            pid,
            subscription_id,
        });

        self.updateState(.{
            .started = .{
                .pid = pid,
                .subscription = subscription_id,
                .loop = loop,
                .completion = null,
                .loop_xev = null,
            },
        });
    }

    /// Helper to update the state and notify waiters via the cv.
    fn updateState(self: *FlatpakHostCommand, state: State) void {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        defer self.state_cv.broadcast();
        self.state = state;
    }

    fn onExit(
        bus: ?*c.GDBusConnection,
        _: [*c]const u8,
        _: [*c]const u8,
        _: [*c]const u8,
        _: [*c]const u8,
        params: ?*c.GVariant,
        ud: ?*anyopaque,
    ) callconv(.c) void {
        const self = @as(*FlatpakHostCommand, @ptrCast(@alignCast(ud)));
        const state = state: {
            self.state_mutex.lock();
            defer self.state_mutex.unlock();
            break :state self.state.started;
        };

        var pid: u32 = 0;
        var exit_status_raw: u32 = 0;
        c.g_variant_get(params.?, "(uu)", &pid, &exit_status_raw);
        if (state.pid != pid) return;

        const exit_status = posix.W.EXITSTATUS(exit_status_raw);
        // Update our state
        self.updateState(.{
            .exited = .{
                .pid = pid,
                .status = exit_status,
            },
        });
        if (state.completion) |completion| {
            completion.result = exit_status;
            completion.timer.?.run(
                state.loop_xev.?,
                &completion.c_xev,
                0,
                anyopaque,
                completion.userdata,
                (struct {
                    fn callback(
                        ud_inner: ?*anyopaque,
                        l_inner: *xev.Loop,
                        c_inner: *xev.Completion,
                        r: xev.Timer.RunError!void,
                    ) xev.CallbackAction {
                        const c_outer: *Completion = @fieldParentPtr("c_xev", c_inner);
                        defer if (c_outer.timer) |*t| t.deinit();

                        const result = if (r) |_| c_outer.result.? else |err| err;
                        c_outer.callback(ud_inner, l_inner, c_outer, result);
                        return .disarm;
                    }
                }).callback,
            );
        }
        log.debug("HostCommand exited pid={} status={}", .{ pid, exit_status });

        // We're done now, so we can unsubscribe
        c.g_dbus_connection_signal_unsubscribe(bus.?, state.subscription);

        // We are also done with our loop so we can exit.
        c.g_main_loop_quit(state.loop);
    }

    fn noopCallback(_: ?*anyopaque, _: *xev.Loop, _: *Completion, _: WaitError!u8) void {}
};
