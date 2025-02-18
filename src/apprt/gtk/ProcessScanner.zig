const ProcessScanner = @This();

const std = @import("std");
const linux = std.os.linux;

const xev = @import("xev");

const CoreApp = @import("../../App.zig");
const App = @import("App.zig");
const Surface = @import("Surface.zig");

const linuxproc = @import("../../os/linuxproc.zig");

const log = std.log.scoped(.process_scanner);

alloc: std.mem.Allocator,
app: *App,
thread: ?std.Thread,

stop_: ?*xev.Async = null,

pub fn init(self: *ProcessScanner, app: *App) void {
    self.* = .{
        .alloc = app.core_app.alloc,
        .app = app,
        .thread = null,
    };

    self.thread = std.Thread.spawn(.{}, run, .{self}) catch |err| {
        log.warn("unable to spawn process scanner thread: {}", .{err});
        return;
    };
}

pub fn stop(self: *ProcessScanner) void {
    if (self.stop_) |s| s.notify() catch |err| {
        log.warn("unable to stop process scanner: {}", .{err});
    };
    if (self.thread) |thread| thread.join();
}

fn run(self: *ProcessScanner) void {
    var loop = xev.Loop.init(.{}) catch |err| {
        log.warn("unable to initialize process scan event loop: {}", .{err});
        return;
    };
    defer loop.deinit();

    var stop_a = xev.Async.init() catch |err| {
        log.warn("unable to initialize process scan stop async: {}", .{err});
        return;
    };
    defer stop_a.deinit();

    var stop_c: xev.Completion = undefined;

    stop_a.wait(
        &loop,
        &stop_c,
        ProcessScanner,
        self,
        stopCallback,
    );
    self.stop_ = &stop_a;

    var timer = xev.Timer.init() catch |err| {
        log.warn("unable to init process scan timer: {}", .{err});
        return;
    };
    defer timer.deinit();

    var timer_c: xev.Completion = undefined;

    timer.run(
        &loop,
        &timer_c,
        500,
        ProcessScanner,
        self,
        timerCallback,
    );

    loop.run(.until_done) catch |err| {
        log.warn("error while running process scan loop: {}", .{err});
    };
}

fn stopCallback(_: ?*ProcessScanner, loop: *xev.Loop, _: *xev.Completion, result: xev.Async.WaitError!void) xev.CallbackAction {
    _ = result catch unreachable;
    loop.stop();
    return .disarm;
}

const SurfaceInfo = struct {
    surface: *Surface,
    ssh: bool = false,
    elevated: bool = false,
};

const SurfaceInfoContext = struct {
    pub fn hash(_: SurfaceInfoContext, pid: std.os.linux.pid_t) u32 {
        return std.hash.XxHash32.hash(0, std.mem.asBytes(&pid));
    }

    pub fn eql(_: SurfaceInfoContext, a: std.os.linux.pid_t, b: std.os.linux.pid_t, b_index: usize) bool {
        _ = b_index;
        return a == b;
    }
};

const SurfacePidMap = std.ArrayHashMap(
    linux.pid_t,
    SurfaceInfo,
    SurfaceInfoContext,
    false,
);

const ProcessPidMap = std.ArrayHashMap(
    linux.pid_t,
    linuxproc.LinuxProcessInfo,
    linuxproc.LinuxProcessInfoContext,
    false,
);

fn timerCallback(
    self_: ?*ProcessScanner,
    _: *xev.Loop,
    _: *xev.Completion,
    result: xev.Timer.RunError!void,
) xev.CallbackAction {
    const start = std.time.Instant.now() catch unreachable;
    _ = result catch unreachable;
    const self = self_ orelse unreachable;

    var arena = std.heap.ArenaAllocator.init(self.alloc);
    defer arena.deinit();
    const alloc = arena.allocator();

    // build a map from PID to surface of all our surfaces
    var surfaces = SurfacePidMap.init(alloc);
    {
        for (self.app.core_app.surfaces.items) |surface| {
            const pid = surface.getPid() orelse continue;
            surfaces.put(pid, .{ .surface = surface }) catch |err| {
                log.warn("unable to add surface to map: {}", .{err});
                return .rearm;
            };
        }
    }

    // build a map of all processes on the system
    var pids = ProcessPidMap.init(alloc);
    {
        const s = std.time.Instant.now() catch unreachable;
        var it = linuxproc.Iterator.init() catch |err| {
            log.err("unable to initialize linux proc iterator: {}", .{err});
            return .rearm;
        };
        defer it.deinit();

        while (it.next() catch |err| {
            log.err("error getting next pid: {}", .{err});
            return .rearm;
        }) |pid| {
            pids.put(pid.pid, pid) catch |err| {
                log.err("unable to put pid {} into map: {}", .{ pid.pid, err });
                return .rearm;
            };
        }

        const e = std.time.Instant.now() catch unreachable;
        const d = e.since(s);
        const d_ms = @as(f64, @floatFromInt(d)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
        if (d_ms > 10.0) log.info("reading /proc took: {d:1.3}ms", .{d_ms});
    }

    // iterate over all pids
    {
        var it = pids.iterator();
        while (it.next()) |kv| {
            // this is the process currently being considered
            const pi = kv.value_ptr;

            // don't bother if it's not "special"
            if (!pi.ssh and !pi.elevated) continue;

            // climb the tree of processes to try and find one that is
            // the "root" of a surface process tree
            var ppid = pi.pid;
            var entry_: ?SurfacePidMap.Entry = null;
            while (entry_ == null) {
                entry_ = surfaces.getEntry(ppid);

                if (entry_) |entry| {
                    // we got one!
                    const si = entry.value_ptr;
                    si.ssh = si.ssh or pi.ssh;
                    si.elevated = si.elevated or pi.elevated;
                    break;
                }
                const i = pids.get(ppid) orelse break;
                if (i.pid == 1) break;
                ppid = i.ppid;
            }
        }
    }

    {
        var it = surfaces.iterator();
        while (it.next()) |kv| {
            const pid = kv.key_ptr.*;
            const si = kv.value_ptr;
            const surface = si.surface;
            if (surface.core_surface.ssh != si.ssh) {
                log.info("surface: pid: {} ssh: {} -> {}", .{ pid, surface.core_surface.ssh, si.ssh });
                surface.core_surface.ssh = si.ssh;
            }
            if (surface.core_surface.elevated != si.elevated) {
                log.info("surface: pid: {} elevated: {} -> {}", .{ pid, surface.core_surface.elevated, si.elevated });
                surface.core_surface.elevated = si.elevated;
            }
        }
    }

    const end = std.time.Instant.now() catch unreachable;
    const diff = end.since(start);
    const diff_ms = @as(f64, @floatFromInt(diff)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
    if (diff_ms > 10.0) log.info("process scan took: {d:1.3}ms", .{diff_ms});

    return .rearm;
}
