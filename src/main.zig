const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const build_config = @import("build_config.zig");
const options = @import("build_options");
const glfw = @import("glfw");
const macos = @import("macos");
const tracy = @import("tracy");
const cli = @import("cli.zig");
const internal_os = @import("os/main.zig");
const xev = @import("xev");
const fontconfig = @import("fontconfig");
const harfbuzz = @import("harfbuzz");
const renderer = @import("renderer.zig");
const apprt = @import("apprt.zig");

const App = @import("App.zig");
const Ghostty = @import("main_c.zig").Ghostty;

/// Global process state. This is initialized in main() for exe artifacts
/// and by ghostty_init() for lib artifacts. This should ONLY be used by
/// the C API. The Zig API should NOT use any global state and should
/// rely on allocators being passed in as parameters.
pub var state: GlobalState = undefined;

/// The return type for main() depends on the build artifact.
const MainReturn = switch (build_config.artifact) {
    .lib => noreturn,
    else => void,
};

pub fn main() !MainReturn {
    // We first start by initializing our global state. This will setup
    // process-level state we need to run the terminal. The reason we use
    // a global is because the C API needs to be able to access this state;
    // no other Zig code should EVER access the global state.
    state.init() catch |err| {
        const stderr = std.io.getStdErr().writer();
        defer std.os.exit(1);
        const ErrSet = @TypeOf(err) || error{Unknown};
        switch (@as(ErrSet, @errorCast(err))) {
            error.MultipleActions => try stderr.print(
                "Error: multiple CLI actions specified. You must specify only one\n" ++
                    "action starting with the `+` character.\n",
                .{},
            ),

            error.InvalidAction => try stderr.print(
                "Error: unknown CLI action specified. CLI actions are specified with\n" ++
                    "the '+' character.\n",
                .{},
            ),

            else => try stderr.print("invalid CLI invocation err={}\n", .{err}),
        }
    };
    defer state.deinit();
    const alloc = state.alloc;

    if (comptime builtin.mode == .Debug) {
        std.log.warn("This is a debug build. Performance will be very poor.", .{});
        std.log.warn("You should only use a debug build for developing Ghostty.", .{});
        std.log.warn("Otherwise, please rebuild in a release mode.", .{});
    }

    // Execute our action if we have one
    if (state.action_xtra) |action_x| {
        var retcode: u8 = 0;
        std.log.info("executing CLI action = {}", .{action_x});
        if (action_x.action == .help) {
            const stdout = std.io.getStdOut().writer();
            retcode = action_x.help(alloc, stdout) catch |err| err: {
                std.log.err("CLI action '{s}' failed error={}",
                    .{@tagName(action_x.action), err});
                break :err 1;
            };
        } else { 
            retcode = action_x.run(alloc) catch |err| err: {
                std.log.err("CLI action '{s}' failed error={}",
                    .{@tagName(action_x.action), err});
                break :err 1;
            };
        }
        std.os.exit(retcode);
        return;
    }

    if (comptime build_config.app_runtime == .none) {
        const stdout = std.io.getStdOut().writer();
        try stdout.print("{s}\n", .{cli.welcome_msg});

        std.os.exit(0);
    }

    // Create our app state
    var app = try App.create(alloc);
    defer app.destroy();

    // Create our runtime app
    var app_runtime = try apprt.App.init(app, .{});
    defer app_runtime.terminate();

    // Run the GUI event loop
    try app_runtime.run();
}

// Required by tracy/tracy.zig to enable/disable tracy support.
pub fn tracy_enabled() bool {
    return options.tracy_enabled;
}

pub const std_options = struct {
    // Our log level is always at least info in every build mode.
    pub const log_level: std.log.Level = switch (builtin.mode) {
        .Debug => .debug,
        else => .info,
    };

    // The function std.log will call.
    pub fn logFn(
        comptime level: std.log.Level,
        comptime scope: @TypeOf(.EnumLiteral),
        comptime format: []const u8,
        args: anytype,
    ) void {
        // Stuff we can do before the lock
        const level_txt = comptime level.asText();
        const prefix = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";

        // Lock so we are thread-safe
        std.debug.getStderrMutex().lock();
        defer std.debug.getStderrMutex().unlock();

        // On Mac, we use unified logging. To view this:
        //
        //   sudo log stream --level debug --predicate 'subsystem=="com.mitchellh.ghostty"'
        //
        if (builtin.os.tag == .macos) {
            // Convert our levels to Mac levels
            const mac_level: macos.os.LogType = switch (level) {
                .debug => .debug,
                .info => .info,
                .warn => .err,
                .err => .fault,
            };

            // Initialize a logger. This is slow to do on every operation
            // but we shouldn't be logging too much.
            const logger = macos.os.Log.create("com.mitchellh.ghostty", @tagName(scope));
            defer logger.release();
            logger.log(std.heap.c_allocator, mac_level, format, args);
        }

        switch (state.logging) {
            .disabled => {},

            .stderr => {
                // Always try default to send to stderr
                const stderr = std.io.getStdErr().writer();
                nosuspend stderr.print(level_txt ++ prefix ++ format ++ "\n", args) catch return;
            },
        }
    }
};

/// This represents the global process state. There should only
/// be one of these at any given moment. This is extracted into a dedicated
/// struct because it is reused by main and the static C lib.
pub const GlobalState = struct {
    const GPA = std.heap.GeneralPurposeAllocator(.{});

    gpa: ?GPA,
    alloc: std.mem.Allocator,
    tracy: if (tracy.enabled) ?tracy.Allocator(null) else void,
    action_xtra: ?cli.ActionXtra,
    logging: Logging,

    /// Where logging should go
    pub const Logging = union(enum) {
        disabled: void,
        stderr: void,
    };

    /// Initialize the global state.
    pub fn init(self: *GlobalState) !void {
        // Initialize ourself to nothing so we don't have any extra state.
        // IMPORTANT: this MUST be initialized before any log output because
        // the log function uses the global state.
        self.* = .{
            .gpa = null,
            .alloc = undefined,
            .tracy = undefined,
            .action_xtra = null,
            .logging = .{ .stderr = {} },
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

        self.alloc = alloc: {
            const base = if (self.gpa) |*value|
                value.allocator()
            else if (builtin.link_libc)
                std.heap.c_allocator
            else
                unreachable;

            // If we're tracing, wrap the allocator
            if (!tracy.enabled) break :alloc base;
            self.tracy = tracy.allocator(base, null);
            break :alloc self.tracy.?.allocator();
        };

        // We first try to parse any action that we may be executing.
        self.action_xtra = try cli.Action.detectCLI(self.alloc);

        // If we have an action executing, we disable logging by default
        // since we write to stderr we don't want logs messing up our
        // output.
        if (self.action_xtra != null) self.logging = .{ .disabled = {} };

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

        // Output some debug information right away
        std.log.info("ghostty version={s}", .{build_config.version_string});
        std.log.info("runtime={}", .{build_config.app_runtime});
        std.log.info("font_backend={}", .{build_config.font_backend});
        std.log.info("dependency harfbuzz={s}", .{harfbuzz.versionString()});
        if (comptime build_config.font_backend.hasFontconfig()) {
            std.log.info("dependency fontconfig={d}", .{fontconfig.version()});
        }
        std.log.info("renderer={}", .{renderer.Renderer});
        std.log.info("libxev backend={}", .{xev.backend});

        // First things first, we fix our file descriptors
        internal_os.fixMaxFiles();

        // We need to make sure the process locale is set properly. Locale
        // affects a lot of behaviors in a shell.
        try internal_os.ensureLocale(self.alloc);
    }

    /// Cleans up the global state. This doesn't _need_ to be called but
    /// doing so in dev modes will check for memory leaks.
    pub fn deinit(self: *GlobalState) void {
        if (self.gpa) |*value| {
            // We want to ensure that we deinit the GPA because this is
            // the point at which it will output if there were safety violations.
            _ = value.deinit();
        }

        if (tracy.enabled) {
            self.tracy = null;
        }
    }
};
test {
    _ = @import("circ_buf.zig");
    _ = @import("pty.zig");
    _ = @import("Command.zig");
    _ = @import("font/main.zig");
    _ = @import("apprt.zig");
    _ = @import("renderer.zig");
    _ = @import("termio.zig");
    _ = @import("input.zig");
    _ = @import("cli.zig");

    // Libraries
    _ = @import("segmented_pool.zig");
    _ = @import("inspector/main.zig");
    _ = @import("terminal/main.zig");
    _ = @import("terminfo/main.zig");

    // TODO
    _ = @import("blocking_queue.zig");
    _ = @import("config.zig");
    _ = @import("lru.zig");
}
