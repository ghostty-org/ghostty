const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const build_config = @import("build_config.zig");
const options = @import("build_options");
const glfw = @import("glfw");
const glslang = @import("glslang");
const macos = @import("macos");
const oni = @import("oniguruma");
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
    if (state.action) |action| {
        std.log.info("executing CLI action={}", .{action});
        std.os.exit(action.run(alloc) catch |err| err: {
            std.log.err("CLI action failed error={}", .{err});
            break :err 1;
        });
        return;
    }

    if (comptime build_config.app_runtime == .none) {
        const stdout = std.io.getStdOut().writer();
        try stdout.print("Usage: ghostty +<action> [flags]\n\n", .{});
        try stdout.print(
            \\This is the Ghostty helper CLI that accompanies the graphical Ghostty app.
            \\To launch the terminal directly, please launch the graphical app
            \\(i.e. Ghostty.app on macOS). This CLI can be used to perform various
            \\actions such as inspecting the version, listing fonts, etc.
            \\
            \\We don't have proper help output yet, sorry! Please refer to the
            \\source code or Discord community for help for now. We'll fix this in time.
        ,
            .{},
        );

        std.os.exit(0);
    }

    // Create our app state
    var app = try App.create(alloc);
    defer app.destroy();

    // Create our runtime app
    var app_runtime = try apprt.App.init(app, .{});
    defer if (@typeInfo(@TypeOf(app_runtime)) == .Pointer) alloc.destroy(app_runtime);
    defer app_runtime.terminate();

    // Run the GUI event loop
    try app_runtime.run();
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
        if (builtin.target.isDarwin()) {
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
    action: ?cli.Action,
    logging: Logging,

    /// The app resources directory, equivalent to zig-out/share when we build
    /// from source. This is null if we can't detect it.
    resources_dir: ?[]const u8,

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
            .action = null,
            .logging = .{ .stderr = {} },
            .resources_dir = null,
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
        self.action = try cli.Action.detectCLI(self.alloc);

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

        // Initialize glslang for shader compilation
        try glslang.init();

        // Initialize oniguruma for regex
        try oni.init(&.{oni.Encoding.utf8});

        // Find our resources directory once for the app so every launch
        // hereafter can use this cached value.
        self.resources_dir = try internal_os.resourcesDir(self.alloc);
        errdefer if (self.resources_dir) |dir| self.alloc.free(dir);
    }

    /// Cleans up the global state. This doesn't _need_ to be called but
    /// doing so in dev modes will check for memory leaks.
    pub fn deinit(self: *GlobalState) void {
        if (self.resources_dir) |dir| self.alloc.free(dir);

        if (self.gpa) |*value| {
            // We want to ensure that we deinit the GPA because this is
            // the point at which it will output if there were safety violations.
            _ = value.deinit();
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
    _ = @import("surface_mouse.zig");

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
