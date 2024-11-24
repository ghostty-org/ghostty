const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const EnvMap = std.process.EnvMap;
const config = @import("../config.zig");
const homedir = @import("../os/homedir.zig");

const log = std.log.scoped(.shell_integration);

/// Shell types we support
pub const Shell = enum {
    bash,
    elvish,
    fish,
    zsh,
};

/// The result of setting up a shell integration.
pub const ShellIntegration = struct {
    /// The successfully-integrated shell.
    shell: Shell,

    /// The command to use to start the shell with the integration.
    /// In most cases this is identical to the command given but for
    /// bash in particular it may be different.
    ///
    /// The memory is allocated in the arena given to setup.
    command: []const u8,
};

/// Setup the command execution environment for automatic
/// integrated shell integration and return a ShellIntegration
/// struct describing the integration.  If integration fails
/// (shell type couldn't be detected, etc.), this will return null.
///
/// The allocator is used for temporary values and to allocate values
/// in the ShellIntegration result. It is expected to be an arena to
/// simplify cleanup.
pub fn setup(
    alloc_arena: Allocator,
    resource_dir: []const u8,
    command: []const u8,
    env: *EnvMap,
    force_shell: ?Shell,
    features: config.ShellIntegrationFeatures,
) !?ShellIntegration {
    const exe = if (force_shell) |shell| switch (shell) {
        .bash => "bash",
        .elvish => "elvish",
        .fish => "fish",
        .zsh => "zsh",
    } else exe: {
        // The command can include arguments. Look for the first space
        // and use the basename of the first part as the command's exe.
        const idx = std.mem.indexOfScalar(u8, command, ' ') orelse command.len;
        break :exe std.fs.path.basename(command[0..idx]);
    };

    const result: ShellIntegration = shell: {
        // For now, bash integration must be explicitly enabled via force_shell.
        // Our automatic shell integration requires bash version 4 or later,
        // and systems like macOS continue to ship bash version 3 by default.
        // This approach avoids the cost of performing a runtime version check.
        if (std.mem.eql(u8, "bash", exe) and force_shell == .bash) {
            const new_command = try setupBash(
                alloc_arena,
                command,
                resource_dir,
                env,
            ) orelse return null;
            break :shell .{
                .shell = .bash,
                .command = new_command,
            };
        }

        if (std.mem.eql(u8, "elvish", exe)) {
            try setupXdgDataDirs(alloc_arena, resource_dir, env);
            break :shell .{
                .shell = .elvish,
                .command = try alloc_arena.dupe(u8, command),
            };
        }

        if (std.mem.eql(u8, "fish", exe)) {
            try setupXdgDataDirs(alloc_arena, resource_dir, env);
            break :shell .{
                .shell = .fish,
                .command = try alloc_arena.dupe(u8, command),
            };
        }

        if (std.mem.eql(u8, "zsh", exe)) {
            try setupZsh(resource_dir, env);
            break :shell .{
                .shell = .zsh,
                .command = try alloc_arena.dupe(u8, command),
            };
        }

        return null;
    };

    // Setup our feature env vars
    if (!features.cursor) try env.put("GHOSTTY_SHELL_INTEGRATION_NO_CURSOR", "1");
    if (!features.sudo) try env.put("GHOSTTY_SHELL_INTEGRATION_NO_SUDO", "1");
    if (!features.title) try env.put("GHOSTTY_SHELL_INTEGRATION_NO_TITLE", "1");

    return result;
}

test "force shell" {
    const testing = std.testing;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    inline for (@typeInfo(Shell).Enum.fields) |field| {
        const shell = @field(Shell, field.name);
        const result = try setup(alloc, ".", "sh", &env, shell, .{});
        try testing.expectEqual(shell, result.?.shell);
    }
}

/// Setup the bash automatic shell integration. This works by
/// starting bash in POSIX mode and using the ENV environment
/// variable to load our bash integration script. This prevents
/// bash from loading its normal startup files, which becomes
/// our script's responsibility (along with disabling POSIX
/// mode).
///
/// This approach requires bash version 4 or later.
///
/// This returns a new (allocated) shell command string that
/// enables the integration or null if integration failed.
fn setupBash(
    alloc: Allocator,
    command: []const u8,
    resource_dir: []const u8,
    env: *EnvMap,
) !?[]const u8 {
    // Accumulates the arguments that will form the final shell command line.
    // We can build this list on the stack because we're just temporarily
    // referencing other slices, but we can fall back to heap in extreme cases.
    var args_alloc = std.heap.stackFallback(1024, alloc);
    var args = try std.ArrayList([]const u8).initCapacity(args_alloc.get(), 2);
    defer args.deinit();

    // Iterator that yields each argument in the original command line.
    // This will allocate once proportionate to the command line length.
    var iter = try std.process.ArgIteratorGeneral(.{}).init(alloc, command);
    defer iter.deinit();

    // Start accumulating arguments with the executable and `--posix` mode flag.
    if (iter.next()) |exe| {
        try args.append(exe);
    } else return null;
    try args.append("--posix");

    // Stores the list of intercepted command line flags that will be passed
    // to our shell integration script: --posix --norc --noprofile
    // We always include at least "1" so the script can differentiate between
    // being manually sourced or automatically injected (from here).
    var inject = try std.BoundedArray(u8, 32).init(0);
    try inject.appendSlice("1");

    var posix = false;

    // Some additional cases we don't yet cover:
    //
    //  - If additional file arguments are provided (after a `-` or `--` flag),
    //    and the `i` shell option isn't being explicitly set, we can assume a
    //    non-interactive shell session and skip loading our shell integration.
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--posix")) {
            try inject.appendSlice(" --posix");
            posix = true;
        } else if (std.mem.eql(u8, arg, "--norc")) {
            try inject.appendSlice(" --norc");
        } else if (std.mem.eql(u8, arg, "--noprofile")) {
            try inject.appendSlice(" --noprofile");
        } else if (std.mem.eql(u8, arg, "--rcfile") or std.mem.eql(u8, arg, "--init-file")) {
            if (iter.next()) |rcfile| {
                try env.put("GHOSTTY_BASH_RCFILE", rcfile);
            }
        } else if (arg.len > 1 and arg[0] == '-' and arg[1] != '-') {
            // '-c command' is always non-interactive
            if (std.mem.indexOfScalar(u8, arg, 'c') != null) {
                return null;
            }
            try args.append(arg);
        } else {
            try args.append(arg);
        }
    }
    try env.put("GHOSTTY_BASH_INJECT", inject.slice());

    // In POSIX mode, HISTFILE defaults to ~/.sh_history, so unless we're
    // staying in POSIX mode (--posix), change it back to ~/.bash_history.
    if (!posix and env.get("HISTFILE") == null) {
        var home_buf: [1024]u8 = undefined;
        if (try homedir.home(&home_buf)) |home| {
            var histfile_buf: [std.fs.max_path_bytes]u8 = undefined;
            const histfile = try std.fmt.bufPrint(
                &histfile_buf,
                "{s}/.bash_history",
                .{home},
            );
            try env.put("HISTFILE", histfile);
            try env.put("GHOSTTY_BASH_UNEXPORT_HISTFILE", "1");
        }
    }

    // Preserve the existing ENV value when staying in POSIX mode (--posix).
    if (env.get("ENV")) |old| {
        if (posix) {
            try env.put("GHOSTTY_BASH_ENV", old);
        }
    }

    // Set our new ENV to point to our integration script.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const integ_dir = try std.fmt.bufPrint(
        &path_buf,
        "{s}/shell-integration/bash/ghostty.bash",
        .{resource_dir},
    );
    try env.put("ENV", integ_dir);

    // Join the accumulated arguments to form the final command string.
    return try std.mem.join(alloc, " ", args.items);
}

test "bash" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var env = EnvMap.init(alloc);
    defer env.deinit();

    const command = try setupBash(alloc, "bash", ".", &env);
    defer if (command) |c| alloc.free(c);

    try testing.expectEqualStrings("bash --posix", command.?);
    try testing.expectEqualStrings("./shell-integration/bash/ghostty.bash", env.get("ENV").?);
    try testing.expectEqualStrings("1", env.get("GHOSTTY_BASH_INJECT").?);
}

test "bash: inject flags" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // bash --posix
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        const command = try setupBash(alloc, "bash --posix", ".", &env);
        defer if (command) |c| alloc.free(c);

        try testing.expectEqualStrings("bash --posix", command.?);
        try testing.expectEqualStrings("1 --posix", env.get("GHOSTTY_BASH_INJECT").?);
    }

    // bash --norc
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        const command = try setupBash(alloc, "bash --norc", ".", &env);
        defer if (command) |c| alloc.free(c);

        try testing.expectEqualStrings("bash --posix", command.?);
        try testing.expectEqualStrings("1 --norc", env.get("GHOSTTY_BASH_INJECT").?);
    }

    // bash --noprofile
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        const command = try setupBash(alloc, "bash --noprofile", ".", &env);
        defer if (command) |c| alloc.free(c);

        try testing.expectEqualStrings("bash --posix", command.?);
        try testing.expectEqualStrings("1 --noprofile", env.get("GHOSTTY_BASH_INJECT").?);
    }
}

test "bash: rcfile" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var env = EnvMap.init(alloc);
    defer env.deinit();

    // bash --rcfile
    {
        const command = try setupBash(alloc, "bash --rcfile profile.sh", ".", &env);
        defer if (command) |c| alloc.free(c);

        try testing.expectEqualStrings("bash --posix", command.?);
        try testing.expectEqualStrings("profile.sh", env.get("GHOSTTY_BASH_RCFILE").?);
    }

    // bash --init-file
    {
        const command = try setupBash(alloc, "bash --init-file profile.sh", ".", &env);
        defer if (command) |c| alloc.free(c);

        try testing.expectEqualStrings("bash --posix", command.?);
        try testing.expectEqualStrings("profile.sh", env.get("GHOSTTY_BASH_RCFILE").?);
    }
}

test "bash: -c command" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var env = EnvMap.init(alloc);
    defer env.deinit();

    try testing.expect(try setupBash(alloc, "bash -c script.sh", ".", &env) == null);
    try testing.expect(try setupBash(alloc, "bash -ic script.sh", ".", &env) == null);
}

test "bash: HISTFILE" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // HISTFILE unset
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        const command = try setupBash(alloc, "bash", ".", &env);
        defer if (command) |c| alloc.free(c);

        try testing.expect(std.mem.endsWith(u8, env.get("HISTFILE").?, ".bash_history"));
        try testing.expectEqualStrings("1", env.get("GHOSTTY_BASH_UNEXPORT_HISTFILE").?);
    }

    // HISTFILE set
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        try env.put("HISTFILE", "my_history");

        const command = try setupBash(alloc, "bash", ".", &env);
        defer if (command) |c| alloc.free(c);

        try testing.expectEqualStrings("my_history", env.get("HISTFILE").?);
        try testing.expect(env.get("GHOSTTY_BASH_UNEXPORT_HISTFILE") == null);
    }

    // HISTFILE unset (POSIX mode)
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        const command = try setupBash(alloc, "bash --posix", ".", &env);
        defer if (command) |c| alloc.free(c);

        try testing.expect(env.get("HISTFILE") == null);
        try testing.expect(env.get("GHOSTTY_BASH_UNEXPORT_HISTFILE") == null);
    }

    // HISTFILE set (POSIX mode)
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        try env.put("HISTFILE", "my_history");

        const command = try setupBash(alloc, "bash --posix", ".", &env);
        defer if (command) |c| alloc.free(c);

        try testing.expectEqualStrings("my_history", env.get("HISTFILE").?);
        try testing.expect(env.get("GHOSTTY_BASH_UNEXPORT_HISTFILE") == null);
    }
}

test "bash: preserve ENV" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var env = EnvMap.init(alloc);
    defer env.deinit();

    const original_env = "original-env.bash";

    // POSIX mode
    {
        try env.put("ENV", original_env);
        const command = try setupBash(alloc, "bash --posix", ".", &env);
        defer if (command) |c| alloc.free(c);

        try testing.expect(std.mem.indexOf(u8, command.?, "--posix") != null);
        try testing.expect(std.mem.indexOf(u8, env.get("GHOSTTY_BASH_INJECT").?, "posix") != null);
        try testing.expectEqualStrings(original_env, env.get("GHOSTTY_BASH_ENV").?);
        try testing.expectEqualStrings("./shell-integration/bash/ghostty.bash", env.get("ENV").?);
    }

    env.remove("GHOSTTY_BASH_ENV");

    // Not POSIX mode
    {
        try env.put("ENV", original_env);
        const command = try setupBash(alloc, "bash", ".", &env);
        defer if (command) |c| alloc.free(c);

        try testing.expect(std.mem.indexOf(u8, command.?, "--posix") != null);
        try testing.expect(std.mem.indexOf(u8, env.get("GHOSTTY_BASH_INJECT").?, "posix") == null);
        try testing.expect(env.get("GHOSTTY_BASH_ENV") == null);
        try testing.expectEqualStrings("./shell-integration/bash/ghostty.bash", env.get("ENV").?);
    }
}

/// Setup automatic shell integration for shells that include
/// their modules from paths in `XDG_DATA_DIRS` env variable.
///
/// Path of shell-integration dir is prepended to `XDG_DATA_DIRS`.
/// It is also saved in `GHOSTTY_SHELL_INTEGRATION_XDG_DIR` variable
/// so that the shell can refer to it and safely remove this directory
/// from `XDG_DATA_DIRS` when integration is complete.
fn setupXdgDataDirs(
    alloc_arena: Allocator,
    resource_dir: []const u8,
    env: *EnvMap,
) !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;

    // Get our path to the shell integration directory.
    const integ_dir = try std.fmt.bufPrint(
        &path_buf,
        "{s}/shell-integration",
        .{resource_dir},
    );

    // Set an env var so we can remove this from XDG_DATA_DIRS later.
    // This happens in the shell integration config itself. We do this
    // so that our modifications don't interfere with other commands.
    try env.put("GHOSTTY_SHELL_INTEGRATION_XDG_DIR", integ_dir);

    {
        const xdg_data_dir_key = "XDG_DATA_DIRS";

        // We attempt to avoid allocating by using the stack up to 4K.
        // Max stack size is considerably larger on macOS and Linux but
        // 4K is a reasonable size for this for most cases. However, env
        // vars can be significantly larger so if we have to we fall
        // back to a heap allocated value.
        var stack_alloc_state = std.heap.stackFallback(4096, alloc_arena);
        const stack_alloc = stack_alloc_state.get();

        // If no XDG_DATA_DIRS set use the default value as specified.
        // This ensures that the default directories aren't lost by setting
        // our desired integration dir directly. See #2711.
        // <https://specifications.freedesktop.org/basedir-spec/0.6/#variables>
        const old = env.get(xdg_data_dir_key) orelse "/usr/local/share:/usr/share";

        const prepended = try std.fmt.allocPrint(stack_alloc, "{s}{c}{s}", .{
            integ_dir,
            std.fs.path.delimiter,
            old,
        });
        defer stack_alloc.free(prepended);

        try env.put(xdg_data_dir_key, prepended);
    }
}

/// Setup the zsh automatic shell integration. This works by setting
/// ZDOTDIR to our resources dir so that zsh will load our config. This
/// config then loads the true user config.
fn setupZsh(
    resource_dir: []const u8,
    env: *EnvMap,
) !void {
    // Preserve the old zdotdir value so we can recover it.
    if (env.get("ZDOTDIR")) |old| {
        try env.put("GHOSTTY_ZSH_ZDOTDIR", old);
    }

    // Set our new ZDOTDIR
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const integ_dir = try std.fmt.bufPrint(
        &path_buf,
        "{s}/shell-integration/zsh",
        .{resource_dir},
    );
    try env.put("ZDOTDIR", integ_dir);
}
