const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("build_config.zig");
const cli = @import("cli.zig");
const internal_os = @import("os/main.zig");
const fontconfig = @import("fontconfig");
const glslang = @import("glslang");
const harfbuzz = @import("harfbuzz");
const oni = @import("oniguruma");
const crash = @import("crash/main.zig");
const renderer = @import("renderer.zig");
const apprt = @import("apprt.zig");
const assert = @import("quirks.zig").inlineAssert;
const allocTmpDir = @import("os/file.zig").allocTmpDir;
const freeTmpDir = @import("os/file.zig").freeTmpDir;

// This file should only be imported for certain platforms.
comptime {
    switch (@import("terminal_options").artifact) {
        .ghostty => {},
        // This file is not allowed to be included in libghostty-vt
        .lib => @compileError("global state cannot be used in libghostty-vt"),
    }
}

/// We export the xev backend we want to use so that the rest of
/// Ghostty can import this once and have access to the proper
/// backend.
pub const xev = @import("xev").Dynamic;

/// Global process state. This is initialized in main() for exe artifacts and
/// by ghostty_init() for lib artifacts. Most other methods in this file will
/// retrieve items stored in this state.
var state: ?GlobalState = undefined;

pub const InitOpts = union(enum) {
    main: std.process.Init,
    c: struct {
        argc: usize,
        argv: [*][*:0]u8,
        environ: std.process.Environ,
    },
};

/// Initialize the global state.
pub fn init(opts: InitOpts) !void {
    // Initialize ourself to nothing so we don't have any extra state.
    // IMPORTANT: this MUST be initialized before any log output because
    // the log function uses the global state.
    state = .{
        .io_impl = undefined,
        .gpa = null,
        .alloc = undefined,
        .environ = switch (opts) {
            .main => |m| m.minimal.environ,
            .c => |c| c.environ,
        },
        .args = switch (opts) {
            .main => |m| m.minimal.args,
            .c => |c| .{ .vector = c.argv[0..c.argc] },
        },
        .tmp_dir_path = null,
        .action = null,
        .logging = .{},
        .rlimits = .{},
        .resources_dir = .{},
    };
    const self = &state.?;
    errdefer deinit();

    self.gpa = gpa: {
        // Use the libc allocator if it is available because it is WAY
        // faster than GPA. We only do this in release modes so that we
        // can get easy memory leak detection in debug modes.
        if (builtin.link_libc) {
            if (switch (builtin.mode) {
                .ReleaseSafe, .ReleaseFast => true,

                // We also use it if we can detect we're running under
                // Valgrind since Valgrind only instruments the C allocator
                else => std.valgrind.runningOnValgrind() > 0,
            }) break :gpa null;
        }

        break :gpa .init;
    };

    self.alloc = if (self.gpa) |*value|
        value.allocator()
    else if (builtin.link_libc)
        std.heap.c_allocator
    else
        unreachable;

    // Set up our main I/O implementation (fully threaded w/allocator). Note
    // that we cannot use any implementation supplied from main at this point,
    // because there are some later initialization steps that depend on us
    // mutating the environment, and thus it needs to be re-synced farther
    // down. For that, we need a stable implementation that allows us to do so.
    self.io_impl = .init(self.alloc, .{
        .argv0 = .init(self.args),
        .environ = self.environ,
    });

    // Discover and save the temporary directory path
    self.tmp_dir_path = try allocTmpDir(self.alloc, self.environ);
    errdefer freeTmpDir(self.alloc, self.tmp_dir_path.?);

    // We first try to parse any action that we may be executing.
    self.action = try cli.action.detectArgs(
        cli.ghostty.Action,
        self.alloc,
        self.args,
    );

    // If we have an action executing, we disable logging by default
    // since we write to stderr we don't want logs messing up our
    // output.
    if (self.action != null) self.logging.stderr = false;

    // I don't love the env var name but I don't have it in my heart
    // to parse CLI args 3 times (once for actions, once for config,
    // maybe once for logging) so for now this is an easy way to do
    // this. Env vars are useful for logging too because they are
    // easy to set.
    logging: {
        const v = self.environ.getAlloc(self.alloc, "GHOSTTY_LOG") catch |err| switch (err) {
            error.EnvironmentVariableMissing => break :logging,
            else => return err,
        };
        defer self.alloc.free(v);
        self.logging = cli.args.parsePackedStruct(GlobalState.Logging, v) catch .{};
    }

    // Setup our signal handlers before logging
    GlobalState.initSignals();

    // Setup our Xev backend if we're dynamic
    if (comptime xev.dynamic) xev.detect() catch |err| {
        std.log.warn("failed to detect xev backend, falling back to " ++
            "most compatible backend err={}", .{err});
    };

    // Output some debug information right away
    std.log.info("ghostty version={s}", .{build_config.version_string});
    std.log.info("ghostty build optimize={s}", .{build_config.mode_string});
    std.log.info("runtime={}", .{build_config.app_runtime});
    std.log.info("font_backend={}", .{build_config.font_backend});
    if (comptime build_config.font_backend.hasHarfbuzz()) {
        std.log.info("dependency harfbuzz={s}", .{harfbuzz.versionString()});
    }
    if (comptime build_config.font_backend.hasFontconfig()) {
        std.log.info("dependency fontconfig={d}", .{fontconfig.version()});
    }
    std.log.info("renderer={}", .{renderer.Renderer});
    std.log.info("libxev default backend={t}", .{xev.backend});

    // As early as possible, initialize our resource limits.
    self.rlimits = .init();

    // Initialize our crash reporting.
    crash.init(self.alloc) catch |err| {
        std.log.warn(
            "sentry init failed, no crash capture available err={}",
            .{err},
        );
    };

    // const sentrylib = @import("sentry");
    // if (sentrylib.captureEvent(sentrylib.Value.initMessageEvent(
    //     .info,
    //     null,
    //     "hello, world",
    // ))) |uuid| {
    //     std.log.warn("uuid={s}", .{uuid.string()});
    // } else std.log.warn("failed to capture event", .{});

    // We need to make sure the process locale is set properly. Locale
    // affects a lot of behaviors in a shell.
    //
    // We need to re-sync the environment after this completes.
    try internal_os.ensureLocale();
    syncEnviron();

    // Initialize glslang for shader compilation
    try glslang.init();

    // Initialize oniguruma for regex
    try oni.init(&.{oni.Encoding.utf8});

    // Find our resources directory once for the app so every launch
    // hereafter can use this cached value.
    self.resources_dir = try apprt.runtime.resourcesDir(self.alloc);
    errdefer self.resources_dir.deinit(self.alloc);

    // Setup i18n
    if (self.resources_dir.app()) |v| internal_os.i18n.init(v) catch |err| {
        std.log.warn("failed to init i18n, translations will not be available err={}", .{err});
    };
}

/// Cleans up the global state. This doesn't _need_ to be called but
/// doing so in dev modes will check for memory leaks.
///
/// Asserts that the state exists.
pub fn deinit() void {
    const self = &state.?;

    self.resources_dir.deinit(self.alloc);

    // Flush our crash logs
    crash.deinit();

    // Release our tmp_dir_path if needed
    if (self.tmp_dir_path) |td| freeTmpDir(self.alloc, td);

    // Release our I/O instance
    self.io_impl.deinit();

    if (self.gpa) |*value| {
        // We want to ensure that we deinit the GPA because this is
        // the point at which it will output if there were safety violations.
        _ = value.deinit();
    }
}

/// Helper to return either the state's I/O instance, or one from testing.
///
/// Asserts that the global state is initialized when not running as as test.
pub fn io() std.Io {
    if (builtin.is_test) return std.testing.io;

    return state.?.io();
}

/// Helper to return either the state's I/O instance, or one from testing.
///
/// Asserts that the global state is initialized when not running as as test.
pub fn alloc() std.mem.Allocator {
    if (builtin.is_test) return std.testing.allocator;

    return state.?.alloc;
}

/// Helper to return either the state's environment, or one from testing.
///
/// Asserts that the global state is initialized when not running as a test.
pub fn environ() std.process.Environ {
    if (builtin.is_test) return std.testing.environ;

    return state.?.environ;
}

/// Helper to create an environment map off of the state's environment, or one
/// from testing. The map is created off of the state allocator.
///
/// Asserts that the global state is initialized when not running as a test.
pub fn environMap() !std.process.Environ.Map {
    if (builtin.is_test) return std.testing.environ.createMap(std.testing.allocator);

    return state.?.environ.createMap(state.?.alloc);
}

/// Re-synchronizes the global Environ (both the higher-level and I/O versions)
/// from the process. No-op on Windows, asserts libc and an initialized global
/// state on everything else.
///
/// It is not valid to run this within any code that needs to be run through
/// tests. For any of these, re-factor the code to take an environment map
/// instead, where you can modify the environment as needed.
///
/// NOTE: Be cognizant of where you are calling this! While the only real
/// difference between the POSIX environment and higher-level Zig `PosixBlock`
/// struct is that the latter has a length versus the former's many-item
/// pointer state, there is no concurrency control on this function (or for
/// that matter, `environ` or `environMap`. Direct modification of the system
/// environment is becoming more discouraged in the standard library as well,
/// and this should be kept in mind when resorting to lower-level `setenv` or
/// `unsetenv` - as a rule, beyond initialization, favor
/// `std.process.Environ.Map` whenever possible.
pub fn syncEnviron() void {
    switch (builtin.os.tag) {
        .windows => {},
        else => {
            assert(builtin.link_libc);
            assert(!builtin.is_test);
            const new_environ: std.process.Environ = .{ .block = .{ .slice = std.c.environ[0..env_len: {
                var len: usize = 0;
                while (std.c.environ[len]) |_| : (len += 1) {}
                break :env_len len;
            } :null] } };
            state.?.environ = new_environ;
            state.?.io_impl.environ = .{ .process_environ = new_environ };
        },
    }
}

/// Helper to return either the state's args, or one from testing.
///
/// Asserts that the global state is initialized when not running as a test.
pub fn args() std.process.Args {
    if (builtin.is_test) return .{ .vector = &.{} };

    return state.?.args;
}

/// Returns the temporary directory discovered from the global environment
/// (saves allocation of the temporary directory where you can get at global
/// state).
///
/// Asserts that the global state is initialized.
pub fn tmpDirPath() []const u8 {
    return state.?.tmp_dir_path.?;
}

/// Returns the global state resources_dir, or an empty one when testing.
///
/// Asserts that the global state is initialized when not running as a test.
pub fn resourcesDir() internal_os.ResourcesDir {
    if (builtin.is_test) return .{};

    return state.?.resources_dir;
}

/// Returns the global state rlimits, or an empty one when testing.
///
/// Asserts that the global state is initialized when not running as a test.
pub fn rlimits() ResourceLimits {
    if (builtin.is_test) return .{};

    return state.?.rlimits;
}

/// Returns the global state logging configuration.
///
/// Asserts that the global state is initialized.
pub fn logging() GlobalState.Logging {
    return state.?.logging;
}

/// Returns the global state action.
///
/// Asserts that the global state is initialized.
pub fn action() ?cli.ghostty.Action {
    return state.?.action;
}

/// This represents the global process state. There should only
/// be one of these at any given moment. This is extracted into a dedicated
/// struct because it is reused by main and the static C lib.
pub const GlobalState = struct {
    const GPA = std.heap.DebugAllocator(.{});

    io_impl: std.Io.Threaded,
    gpa: ?GPA,
    alloc: std.mem.Allocator,
    environ: std.process.Environ,
    args: std.process.Args,
    tmp_dir_path: ?[]const u8,
    action: ?cli.ghostty.Action,
    logging: Logging,
    rlimits: ResourceLimits = .{},

    /// The app resources directory, equivalent to zig-out/share when we build
    /// from source. This is null if we can't detect it.
    resources_dir: internal_os.ResourcesDir,

    /// Where logging should go
    pub const Logging = packed struct {
        /// Whether to log to stderr. For lib mode we always disable stderr
        /// logging by default. Otherwise it's enabled by default.
        stderr: bool = build_config.app_runtime != .none,
        /// Whether to log to macOS's unified logging. Enabled by default
        /// on macOS.
        macos: bool = builtin.os.tag.isDarwin(),
    };

    /// Asserts that `self.io_impl` has been initialized.
    pub fn io(self: *GlobalState) std.Io {
        return self.io_impl.io();
    }

    fn initSignals() void {
        // Only posix systems.
        if (comptime builtin.os.tag == .windows) return;

        const p = std.posix;

        var sa: p.Sigaction = .{
            .handler = .{ .handler = p.SIG.IGN },
            .mask = p.sigemptyset(),
            .flags = 0,
        };

        // We ignore SIGPIPE because it is a common signal we may get
        // due to how we implement termio. When a terminal is closed we
        // often write to a broken pipe to exit the read thread. This should
        // be fixed one day but for now this helps make this a bit more
        // robust.
        p.sigaction(p.SIG.PIPE, &sa, null);
    }
};

/// Maintains the Unix resource limits that we set for our process. This
/// can be used to restore the limits to their original values.
pub const ResourceLimits = struct {
    nofile: ?internal_os.rlimit = null,

    pub fn init() ResourceLimits {
        return .{
            // Maximize the number of file descriptors we can have open
            // because we can consume a lot of them if we make many terminals.
            .nofile = internal_os.fixMaxFiles(),
        };
    }

    pub fn restore(self: *const ResourceLimits) void {
        if (self.nofile) |lim| internal_os.restoreMaxFiles(lim);
    }
};
