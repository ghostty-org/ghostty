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

/// We export the xev backend we want to use so that the rest of
/// Ghostty can import this once and have access to the proper
/// backend.
pub const xev = @import("xev").Dynamic;

/// Global process state. This is initialized in main() for exe artifacts
/// and by ghostty_init() for lib artifacts. This should ONLY be used by
/// the C API. The Zig API should NOT use any global state and should
/// rely on allocators being passed in as parameters.
pub var state: GlobalState = undefined;

/// This represents the global process state. There should only
/// be one of these at any given moment. This is extracted into a dedicated
/// struct because it is reused by main and the static C lib.
pub const GlobalState = struct {
    const GPA = std.heap.GeneralPurposeAllocator(.{});

    gpa: ?GPA,
    alloc: std.mem.Allocator,
    action: ?cli.ghostty.Action,
    logging: Logging,
    rlimits: ResourceLimits = .{},

    /// The app resources directory, equivalent to zig-out/share when we build
    /// from source. This is null if we can't detect it.
    resources_dir: internal_os.ResourcesDir,

    /// Where logging should go
    pub const Logging = union(enum) {
        disabled: void,
        stderr: void,
    };

    /// Initialize the global state.
    pub fn init(self: *GlobalState) !void {
        // const start = try std.time.Instant.now();
        // const start_micro = std.time.microTimestamp();
        // defer {
        //     const end = std.time.Instant.now() catch unreachable;
        //     // "[updateFrame critical time] <START us>\t<TIME_TAKEN us>"
        //     std.log.err("[global init time] start={}us duration={}ns", .{ start_micro, end.since(start) / std.time.ns_per_us });
        // }

        // Initialize ourself to nothing so we don't have any extra state.
        // IMPORTANT: this MUST be initialized before any log output because
        // the log function uses the global state.
        self.* = .{
            .gpa = null,
            .alloc = undefined,
            .action = null,
            .logging = .{ .stderr = {} },
            .rlimits = .{},
            .resources_dir = .{},
        };
        errdefer self.deinit();

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

            break :gpa GPA{};
        };

        self.alloc = if (self.gpa) |*value|
            value.allocator()
        else if (builtin.link_libc)
            std.heap.c_allocator
        else
            unreachable;

        // We first try to parse any action that we may be executing.
        self.action = try cli.action.detectArgs(
            cli.ghostty.Action,
            self.alloc,
        );

        // If we have an action executing, we disable logging by default
        // since we write to stderr we don't want logs messing up our
        // output.
        if (self.action != null) self.logging = .{ .disabled = {} };

        // For lib mode we always disable stderr logging by default.
        if (comptime build_config.app_runtime == .none) {
            self.logging = .{ .disabled = {} };
        }

        // I don't love the env var name but I don't have it in my heart
        // to parse CLI args 3 times (once for actions, once for config,
        // maybe once for logging) so for now this is an easy way to do
        // this. Env vars are useful for logging too because they are
        // easy to set.
        if ((try internal_os.getenv(self.alloc, "GHOSTTY_LOG"))) |v| {
            defer v.deinit(self.alloc);
            if (v.value.len > 0) {
                self.logging = .{ .stderr = {} };
            }
        }

        // Setup our signal handlers before logging
        initSignals();

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
        std.log.info("libxev default backend={s}", .{@tagName(xev.backend)});

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
        try internal_os.ensureLocale(self.alloc);

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
    pub fn deinit(self: *GlobalState) void {
        self.resources_dir.deinit(self.alloc);

        // Flush our crash logs
        crash.deinit();

        if (self.gpa) |*value| {
            // We want to ensure that we deinit the GPA because this is
            // the point at which it will output if there were safety violations.
            _ = value.deinit();
        }
    }

    fn initSignals() void {
        // Only posix systems.
        if (comptime builtin.os.tag == .windows) return;

        const p = std.posix;

        var sa: p.Sigaction = .{
            .handler = .{ .handler = p.SIG.IGN },
            .mask = p.empty_sigset,
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
