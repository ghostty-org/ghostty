const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const build_config = @import("../build_config.zig");
const build_options = @import("build_options");
const sentry = if (build_options.sentry) @import("sentry");
const internal_os = @import("../os/main.zig");
const crash = @import("main.zig");
const Surface = @import("../Surface.zig");

const log = std.log.scoped(.sentry);

/// The global state for the Sentry SDK. This is unavoidable since crash
/// handling is a global process-wide thing.
var init_thread: ?std.Thread = null;

/// Directory memory, holds the cache and state dirs persistently. This
/// prevents any sort of crashes due to initialization races.
var dir_mem: [std.fs.max_path_bytes * 2]u8 = undefined;

/// Holds the XDG cache dir.
var cache_dir_: ?[]const u8 = null;

/// Holds the XDG state dir.
var state_dir_: ?[]const u8 = null;

/// Thread-local state that can be set by thread main functions so that
/// crashes have more context.
///
/// This is a hack over Sentry native SDK limitations. The native SDK has
/// one global scope for all threads and no support for thread-local scopes.
/// This means that if we want to set thread-specific data we have to do it
/// on our own in the on crash callback.
pub const ThreadState = struct {
    /// Thread type, used to tag the crash
    type: Type,

    /// The surface that this thread is attached to.
    surface: *Surface,

    pub const Type = enum { main, renderer, io };
};

/// See ThreadState. This should only ever be set by the owner of the
/// thread entry function.
pub threadlocal var thread_state: ?ThreadState = null;

/// Process-wide initialization of our Sentry client.
///
/// This should only be called from one thread, and deinit should be called
/// from the same thread that calls init to avoid data races.
///
/// PRIVACY NOTE: I want to make it very clear that Ghostty by default does
/// NOT send any data over the network. We use the Sentry native SDK to collect
/// crash reports and logs, but we only store them locally (see Transport).
/// It is up to the user to grab the logs and manually send them to us
/// (or to their own Sentry instance) if they want to.
pub fn init(gpa: Allocator, environ_map: std.process.Environ.Map) !void {
    if (comptime !build_options.sentry) {
        var map = environ_map;
        map.deinit();
        return;
    }

    // Not supported on Windows currently, doesn't build.
    if (comptime builtin.os.tag == .windows) {
        var map = environ_map;
        map.deinit();
        return;
    }

    // Must only start once
    assert(init_thread == null);

    // We use a thread for initializing Sentry because initialization is
    // slow enough to matter for process startup: resolving our directories
    // can take multiple milliseconds on macOS (Apple APIs) and Sentry's
    // own init does disk I/O. Everything Sentry is doing initially is safe
    // to do on a separate thread and fast enough that its very likely to
    // be done before a crash occurs.
    //
    // The environ map is a snapshot owned by the thread (and freed there),
    // so it is safe against concurrent mutations of the process environment
    // (e.g. ensureLocale on the main thread).
    const thr = std.Thread.spawn(
        .{},
        initThread,
        .{ gpa, environ_map },
    ) catch |err| {
        var map = environ_map;
        map.deinit();
        return err;
    };

    // Naming the thread from here only works on some platforms (e.g.
    // Linux). On Darwin the thread names itself in initThread.
    var single_threaded: std.Io.Threaded = .init_single_threaded;
    defer single_threaded.deinit();
    thr.setName(single_threaded.io(), "sentry-init") catch {};

    init_thread = thr;
}

fn initThread(gpa: Allocator, environ_map_: std.process.Environ.Map) !void {
    var environ_map = environ_map_;
    defer environ_map.deinit();

    // Right now, on Darwin, `std.Thread.setName` can only name the current
    // thread, and we have no way to get the current thread from within it,
    // so instead we use this code to name the thread instead.
    if (builtin.os.tag.isDarwin()) {
        internal_os.macos.pthread_setname_np(&"sentry-init".*);
    }

    // Get our directories.
    var single_threaded: std.Io.Threaded = .init_single_threaded;
    defer single_threaded.deinit();
    var fba: std.heap.FixedBufferAllocator = .init(&dir_mem);

    state_dir_ = state_dir: {
        const dir = try crash.defaultDir(
            single_threaded.io(),
            gpa,
            &environ_map,
        );
        defer gpa.free(dir.path);
        break :state_dir try fba.allocator().dupe(u8, dir.path);
    };
    errdefer state_dir_ = null;

    const cache_dir = cache_dir: {
        const dir = try cacheDir(
            single_threaded.io(),
            gpa,
            &environ_map,
        );
        defer gpa.free(dir);
        break :cache_dir try fba.allocator().dupe(u8, dir);
    };
    cache_dir_ = cache_dir;
    errdefer cache_dir_ = null;

    const transport = sentry.Transport.init(&Transport.send);
    // This will crash if the transport was never used so we avoid
    // that for now. This probably leaks some memory but it'd be very
    // small and a one time cost. Once this is fixed upstream we can
    // remove this.
    //errdefer transport.deinit();

    const opts = sentry.c.sentry_options_new();
    errdefer sentry.c.sentry_options_free(opts);
    sentry.c.sentry_options_set_release_n(
        opts,
        build_config.version_string.ptr,
        build_config.version_string.len,
    );
    sentry.c.sentry_options_set_transport(opts, @ptrCast(transport));

    // Set our crash callback. See beforeSend for more details on what we
    // do here and why we use this.
    sentry.c.sentry_options_set_before_send(opts, beforeSend, null);

    sentry.c.sentry_options_set_database_path_n(
        opts,
        cache_dir.ptr,
        cache_dir.len,
    );

    if (comptime builtin.mode == .Debug) {
        // Debug logging for Sentry
        sentry.c.sentry_options_set_debug(opts, @intFromBool(true));
    }

    // Initialize
    if (sentry.c.sentry_init(opts) != 0) return error.SentryInitFailed;

    // Setup some basic tags that we always want present
    sentry.setTag("build-mode", build_config.mode_string);
    sentry.setTag("app-runtime", @tagName(build_config.app_runtime));
    sentry.setTag("font-backend", @tagName(build_config.font_backend));
    sentry.setTag("renderer", @tagName(build_config.renderer));

    // Log some information about sentry
    log.debug("sentry initialized database={s}", .{cache_dir});
}

fn cacheDir(io: std.Io, alloc: Allocator, environ_map: *const std.process.Environ.Map) ![]const u8 {
    // On macOS, we prefer to use the NSCachesDirectory value to be
    // a more idiomatic macOS application. But if XDG env vars are set
    // we will respect them.
    if (comptime builtin.os.tag == .macos) macos: {
        const xdg_cache_home = environ_map.get("XDG_CACHE_HOME") orelse break :macos;
        if (xdg_cache_home.len > 0) {
            return try internal_os.macos.cacheDir(
                alloc,
                "sentry",
            );
        }
    }

    return try internal_os.xdg.cache(
        io,
        alloc,
        environ_map,
        .{ .subdir = "ghostty/sentry" },
    );
}

/// Process-wide deinitialization of our Sentry client. This ensures all
/// our data is flushed.
pub fn deinit() void {
    if (comptime !build_options.sentry) return;

    if (comptime builtin.os.tag == .windows) return;

    // If we're still initializing then wait for init to finish. This
    // is highly unlikely since init is a very fast operation but we want
    // to avoid the possibility.
    const thr = init_thread orelse return;
    thr.join();
    _ = sentry.c.sentry_close();
}

fn beforeSend(
    event_val: sentry.c.sentry_value_t,
    _: ?*anyopaque,
    _: ?*anyopaque,
) callconv(.c) sentry.c.sentry_value_t {
    // The native SDK at the time of writing doesn't support thread-local
    // scopes. The full SDK has one global scope. So we use the beforeSend
    // handler to set thread-specific data such as window size, grid size,
    // etc. that we can use to debug crashes.

    // If we don't have thread state we can't reliably determine
    // metadata such as surface dimensions. In the future we can probably
    // drop full app state (all surfaces, all windows, etc.).
    const thr_state = thread_state orelse {
        log.debug("no thread state, skipping crash metadata", .{});
        return event_val;
    };

    // Get our event contexts. At this point Sentry has already merged
    // all the contexts so we should have this key. If not, we create it.
    const event: sentry.Value = .{ .value = event_val };
    const contexts = event.get("contexts") orelse contexts: {
        const obj = sentry.Value.initObject();
        event.set("contexts", obj);
        break :contexts obj;
    };
    const tags = event.get("tags") orelse tags: {
        const obj = sentry.Value.initObject();
        event.set("tags", obj);
        break :tags obj;
    };

    // Store our thread type
    tags.set("thread-type", sentry.Value.initString(@tagName(thr_state.type)));

    // Read the surface data. This is likely unsafe because on a crash
    // other threads can continue running. We don't have race-safe way to
    // access this data so this might be corrupted but it's most likely fine.
    {
        const obj = sentry.Value.initObject();
        errdefer obj.decref();
        const surface = thr_state.surface;
        const grid_size = surface.size.grid();
        obj.set(
            "screen-width",
            sentry.Value.initInt32(std.math.cast(i32, surface.size.screen.width) orelse -1),
        );
        obj.set(
            "screen-height",
            sentry.Value.initInt32(std.math.cast(i32, surface.size.screen.height) orelse -1),
        );
        obj.set(
            "grid-columns",
            sentry.Value.initInt32(std.math.cast(i32, grid_size.columns) orelse -1),
        );
        obj.set(
            "grid-rows",
            sentry.Value.initInt32(std.math.cast(i32, grid_size.rows) orelse -1),
        );
        obj.set(
            "cell-width",
            sentry.Value.initInt32(std.math.cast(i32, surface.size.cell.width) orelse -1),
        );
        obj.set(
            "cell-height",
            sentry.Value.initInt32(std.math.cast(i32, surface.size.cell.height) orelse -1),
        );

        contexts.set("Dimensions", obj);
    }

    return event_val;
}

pub const Transport = struct {
    pub fn send(envelope: *sentry.Envelope, ud: ?*anyopaque) callconv(.c) void {
        _ = ud;
        defer envelope.deinit();

        // Call our internal impl. If it fails there is nothing we can do
        // but log to the user.
        sendInternal(envelope) catch |err| {
            log.warn("failed to persist crash report err={}", .{err});
        };
    }

    /// Implementation of send but we can use Zig errors.
    fn sendInternal(envelope: *sentry.Envelope) !void {
        const state_dir = state_dir_ orelse return error.StateDirNotInitialized;

        // The I/O and allocator we use here are just meant to get the job
        // done for saving the crash report.
        var single_threaded: std.Io.Threaded = .init_single_threaded;
        defer single_threaded.deinit();
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const alloc = arena.allocator();

        // Parse into an envelope structure
        const json = envelope.serialize();
        defer sentry.free(@ptrCast(json.ptr));
        var parsed: crash.Envelope = parsed: {
            var reader: std.Io.Reader = .fixed(json);
            break :parsed try crash.Envelope.parse(alloc, &reader);
        };
        defer parsed.deinit();

        // If our envelope doesn't have an event then we don't do anything.
        // To figure this out we first encode it into a string, parse it,
        // and check if it has an event. Kind of wasteful but the best
        // option we have at the time of writing this since the C API doesn't
        // expose this information.
        if (try shouldDiscard(&parsed)) {
            log.info("sentry envelope does not contain crash, discarding", .{});
            return;
        }

        // Generate a UUID for this envelope. The envelope DOES have an event_id
        // header but I don't think there is any public API way to get it
        // afaict so we generate a new UUID for the filename just so we don't
        // conflict.
        const uuid = sentry.UUID.init();

        try std.Io.Dir.cwd().createDirPath(single_threaded.io(), state_dir);

        // Build our final path and write to it.
        const path = try std.fs.path.join(alloc, &.{
            state_dir,
            try std.fmt.allocPrint(alloc, "{s}.ghosttycrash", .{uuid.string()}),
        });
        const file = try std.Io.Dir.cwd().createFile(single_threaded.io(), path, .{});
        defer file.close(single_threaded.io());
        var buf: [4096]u8 = undefined;
        var file_writer = file.writer(single_threaded.io(), &buf);
        try file_writer.interface.writeAll(json);
        try file_writer.end();

        log.warn("crash report written to disk path={s}", .{path});
    }

    fn shouldDiscard(envelope: *const crash.Envelope) !bool {
        // If we have an event item then we're good.
        for (envelope.items.items) |item| {
            if (item.itemType() == .event) return false;
        }

        return true;
    }
};
