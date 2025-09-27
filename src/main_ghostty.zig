//! The main entrypoint for the `ghostty` application. This also serves
//! as the process initialization code for the `libghostty` library.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const build_config = @import("build_config.zig");
const options = @import("build_options");
const glslang = @import("glslang");
const macos = @import("macos");
const oni = @import("oniguruma");
const cli = @import("cli.zig");
const internal_os = @import("os/main.zig");
const fontconfig = @import("fontconfig");
const harfbuzz = @import("harfbuzz");
const renderer = @import("renderer.zig");
const apprt = @import("apprt.zig");

const App = @import("App.zig");
const Ghostty = @import("main_c.zig").Ghostty;
const state = &@import("global.zig").state;

/// The return type for main() depends on the build artifact. The lib build
/// also calls "main" in order to run the CLI actions, but it calls it as
/// an API and not an entrypoint.
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
        defer posix.exit(1);
        const ErrSet = @TypeOf(err) || error{Unknown};
        switch (@as(ErrSet, @errorCast(err))) {
            error.MultipleActions => try stderr.print(
                "Error: multiple CLI actions specified. You must specify only one\n" ++
                    "action starting with the `+` character.\n",
                .{},
            ),

            error.InvalidAction => try stderr.print(
                "Error: unknown CLI action specified. CLI actions are specified with\n" ++
                    "the '+' character.\n\n" ++
                    "All valid CLI actions can be listed with `ghostty +help`\n",
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
        posix.exit(action.run(alloc) catch |err| err: {
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
            \\On macOS, the terminal can also be launched using `open -na Ghostty.app`,
            \\or `open -na Ghostty.app --args --foo=bar --baz=qux` to pass arguments.
            \\
            \\We don't have proper help output yet, sorry! Please refer to the
            \\source code or Discord community for help for now. We'll fix this in time.
            \\
        ,
            .{},
        );

        posix.exit(0);
    }

    // Create our app state
    const app: *App = try App.create(alloc);
    defer app.destroy();

    // Create our runtime app
    var app_runtime: apprt.App = undefined;
    try app_runtime.init(app, .{});
    defer app_runtime.terminate();

    // Since - by definition - there are no surfaces when first started, the
    // quit timer may need to be started. The start timer will get cancelled if/
    // when the first surface is created.
    if (@hasDecl(apprt.App, "startQuitTimer")) app_runtime.startQuitTimer();

    // Run the GUI event loop
    try app_runtime.run();
}

// The function std.log will call.
fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    // On Mac, we use unified logging. To view this:
    //
    //   sudo log stream --level debug --predicate 'subsystem=="com.mitchellh.ghostty"'
    //
    // macOS logging is thread safe so no need for locks/mutexes
    macos: {
        if (comptime !builtin.target.os.tag.isDarwin()) break :macos;
        if (!state.logging.macos) break :macos;

        const prefix = if (scope == .default) "" else @tagName(scope) ++ ": ";

        // Convert our levels to Mac levels
        const mac_level: macos.os.LogType = switch (level) {
            .debug => .debug,
            .info => .info,
            .warn => .err,
            .err => .fault,
        };

        // Initialize a logger. This is slow to do on every operation
        // but we shouldn't be logging too much.
        const logger = macos.os.Log.create(build_config.bundle_id, @tagName(scope));
        defer logger.release();
        logger.log(std.heap.c_allocator, mac_level, prefix ++ format, args);
    }

    stderr: {
        // don't log debug messages to stderr unless we are a debug build
        if (comptime builtin.mode != .Debug and level == .debug) break :stderr;

        // skip if we are not logging to stderr
        if (!state.logging.stderr) break :stderr;

        // Lock so we are thread-safe
        std.debug.lockStdErr();
        defer std.debug.unlockStdErr();

        const level_txt = comptime level.asText();
        const prefix = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
        const stderr = std.io.getStdErr().writer();
        nosuspend stderr.print(level_txt ++ prefix ++ format ++ "\n", args) catch break :stderr;
    }
}

pub const std_options: std.Options = .{
    .log_level = .info,
    .logFn = logFn,
};

test {
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
    _ = @import("benchmark/main.zig");
    _ = @import("crash/main.zig");
    _ = @import("datastruct/main.zig");
    _ = @import("inspector/main.zig");
    _ = @import("terminal/main.zig");
    _ = @import("terminfo/main.zig");
    _ = @import("simd/main.zig");
    _ = @import("synthetic/main.zig");
    _ = @import("unicode/main.zig");
    _ = @import("unicode/props_ziglyph.zig");
    _ = @import("unicode/symbols_ziglyph.zig");

    // Extra
    _ = @import("extra/bash.zig");
    _ = @import("extra/fish.zig");
    _ = @import("extra/sublime.zig");
    _ = @import("extra/vim.zig");
    _ = @import("extra/zsh.zig");
}
