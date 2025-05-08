const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const EnvMap = std.process.EnvMap;
const config = @import("../config.zig");
const homedir = @import("../os/homedir.zig");
const internal_os = @import("../os/main.zig");

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
    command: config.Command,
};

/// Set up the command execution environment for automatic
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
    command: config.Command,
    env: *EnvMap,
    force_shell: ?Shell,
    features: config.ShellIntegrationFeatures,
) !?ShellIntegration {
    const exe = if (force_shell) |shell| switch (shell) {
        .bash => "bash",
        .elvish => "elvish",
        .fish => "fish",
        .zsh => "zsh",
    } else switch (command) {
        .direct => |v| std.fs.path.basename(v[0]),
        .shell => |v| exe: {
            // Shell strings can include spaces so we want to only
            // look up to the space if it exists. No shell that we integrate
            // has spaces.
            const idx = std.mem.indexOfScalar(u8, v, ' ') orelse v.len;
            break :exe std.fs.path.basename(v[0..idx]);
        },
    };

    const result = try setupShell(
        alloc_arena,
        resource_dir,
        command,
        env,
        exe,
    );

    // Setup our feature env vars
    try setupFeatures(env, features);

    return result;
}

fn setupShell(
    alloc_arena: Allocator,
    resource_dir: []const u8,
    command: config.Command,
    env: *EnvMap,
    exe: []const u8,
) !?ShellIntegration {
    if (std.mem.eql(u8, "bash", exe)) {
        // Apple distributes their own patched version of Bash 3.2
        // on macOS that disables the ENV-based POSIX startup path.
        // This means we're unable to perform our automatic shell
        // integration sequence in this specific environment.
        //
        // If we're running "/bin/bash" on Darwin, we can assume
        // we're using Apple's Bash because /bin is non-writable
        // on modern macOS due to System Integrity Protection.
        if (comptime builtin.target.os.tag.isDarwin()) {
            if (std.mem.eql(u8, "/bin/bash", switch (command) {
                .direct => |v| v[0],
                .shell => |v| v,
            })) {
                return null;
            }
        }

        const new_command = try setupBash(
            alloc_arena,
            command,
            resource_dir,
            env,
        ) orelse return null;
        return .{
            .shell = .bash,
            .command = new_command,
        };
    }

    if (std.mem.eql(u8, "elvish", exe)) {
        try setupXdgDataDirs(alloc_arena, resource_dir, env);
        return .{
            .shell = .elvish,
            .command = try command.clone(alloc_arena),
        };
    }

    if (std.mem.eql(u8, "fish", exe)) {
        try setupXdgDataDirs(alloc_arena, resource_dir, env);
        return .{
            .shell = .fish,
            .command = try command.clone(alloc_arena),
        };
    }

    if (std.mem.eql(u8, "zsh", exe)) {
        try setupZsh(resource_dir, env);
        return .{
            .shell = .zsh,
            .command = try command.clone(alloc_arena),
        };
    }

    return null;
}

test "force shell" {
    const testing = std.testing;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    inline for (@typeInfo(Shell).@"enum".fields) |field| {
        const shell = @field(Shell, field.name);
        const result = try setup(
            alloc,
            ".",
            .{ .shell = "sh" },
            &env,
            shell,
            .{},
        );
        try testing.expectEqual(shell, result.?.shell);
    }
}

/// Set up the shell integration features environment variable.
pub fn setupFeatures(
    env: *EnvMap,
    features: config.ShellIntegrationFeatures,
) !void {
    const fields = @typeInfo(@TypeOf(features)).@"struct".fields;
    const capacity: usize = capacity: {
        comptime var n: usize = fields.len - 1; // commas
        inline for (fields) |field| n += field.name.len;
        break :capacity n;
    };
    var buffer = try std.BoundedArray(u8, capacity).init(0);

    inline for (fields) |field| {
        if (@field(features, field.name)) {
            if (buffer.len > 0) try buffer.append(',');
            try buffer.appendSlice(field.name);
        }
    }

    if (buffer.len > 0) {
        try env.put("GHOSTTY_SHELL_FEATURES", buffer.slice());
    }
}

test "setup features" {
    const testing = std.testing;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Test: all features enabled
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        try setupFeatures(&env, .{ .cursor = true, .sudo = true, .title = true });
        try testing.expectEqualStrings("cursor,sudo,title", env.get("GHOSTTY_SHELL_FEATURES").?);
    }

    // Test: all features disabled
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        try setupFeatures(&env, .{ .cursor = false, .sudo = false, .title = false });
        try testing.expect(env.get("GHOSTTY_SHELL_FEATURES") == null);
    }

    // Test: mixed features
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        try setupFeatures(&env, .{ .cursor = false, .sudo = true, .title = false });
        try testing.expectEqualStrings("sudo", env.get("GHOSTTY_SHELL_FEATURES").?);
    }
}

/// Setup the bash automatic shell integration. This works by
/// starting bash in POSIX mode and using the ENV environment
/// variable to load our bash integration script. This prevents
/// bash from loading its normal startup files, which becomes
/// our script's responsibility (along with disabling POSIX
/// mode).
///
/// This returns a new (allocated) shell command string that
/// enables the integration or null if integration failed.
fn setupBash(
    alloc: Allocator,
    command: config.Command,
    resource_dir: []const u8,
    env: *EnvMap,
) !?config.Command {
    var args = try std.ArrayList([:0]const u8).initCapacity(alloc, 3);
    defer args.deinit();

    // Iterator that yields each argument in the original command line.
    // This will allocate once proportionate to the command line length.
    var iter = try command.argIterator(alloc);
    defer iter.deinit();

    // Start accumulating arguments with the executable and initial flags.
    if (iter.next()) |exe| {
        try args.append(try alloc.dupeZ(u8, exe));
    } else return null;
    try args.append("--posix");

    // On macOS, we request a login shell to match that platform's norms.
    if (comptime builtin.target.os.tag.isDarwin()) {
        try args.append("--login");
    }

    // Stores the list of intercepted command line flags that will be passed
    // to our shell integration script: --norc --noprofile
    // We always include at least "1" so the script can differentiate between
    // being manually sourced or automatically injected (from here).
    var inject = try std.BoundedArray(u8, 32).init(0);
    try inject.appendSlice("1");

    // Walk through the rest of the given arguments. If we see an option that
    // would require complex or unsupported integration behavior, we bail out
    // and skip loading our shell integration. Users can still manually source
    // the shell integration script.
    //
    // Unsupported options:
    //  -c          -c is always non-interactive
    //  --posix     POSIX mode (a la /bin/sh)
    var rcfile: ?[]const u8 = null;
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--posix")) {
            return null;
        } else if (std.mem.eql(u8, arg, "--norc")) {
            try inject.appendSlice(" --norc");
        } else if (std.mem.eql(u8, arg, "--noprofile")) {
            try inject.appendSlice(" --noprofile");
        } else if (std.mem.eql(u8, arg, "--rcfile") or std.mem.eql(u8, arg, "--init-file")) {
            rcfile = iter.next();
        } else if (arg.len > 1 and arg[0] == '-' and arg[1] != '-') {
            // '-c command' is always non-interactive
            if (std.mem.indexOfScalar(u8, arg, 'c') != null) {
                return null;
            }
            try args.append(try alloc.dupeZ(u8, arg));
        } else if (std.mem.eql(u8, arg, "-") or std.mem.eql(u8, arg, "--")) {
            // All remaining arguments should be passed directly to the shell
            // command. We shouldn't perform any further option processing.
            try args.append(try alloc.dupeZ(u8, arg));
            while (iter.next()) |remaining_arg| {
                try args.append(try alloc.dupeZ(u8, remaining_arg));
            }
            break;
        } else {
            try args.append(try alloc.dupeZ(u8, arg));
        }
    }
    try env.put("GHOSTTY_BASH_INJECT", inject.slice());
    if (rcfile) |v| {
        try env.put("GHOSTTY_BASH_RCFILE", v);
    }

    // In POSIX mode, HISTFILE defaults to ~/.sh_history, so unless we're
    // staying in POSIX mode (--posix), change it back to ~/.bash_history.
    if (env.get("HISTFILE") == null) {
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

    // Set our new ENV to point to our integration script.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const integ_dir = try std.fmt.bufPrint(
        &path_buf,
        "{s}/shell-integration/bash/ghostty.bash",
        .{resource_dir},
    );
    try env.put("ENV", integ_dir);

    // Since we built up a command line, we don't need to wrap it in
    // ANOTHER shell anymore and can do a direct command.
    return .{ .direct = try args.toOwnedSlice() };
}

test "bash" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    const command = try setupBash(alloc, .{ .shell = "bash" }, ".", &env);

    try testing.expect(command.?.direct.len >= 2);
    try testing.expectEqualStrings("bash", command.?.direct[0]);
    try testing.expectEqualStrings("--posix", command.?.direct[1]);
    if (comptime builtin.target.os.tag.isDarwin()) {
        try testing.expectEqualStrings("--login", command.?.direct[2]);
    }
    try testing.expectEqualStrings("./shell-integration/bash/ghostty.bash", env.get("ENV").?);
    try testing.expectEqualStrings("1", env.get("GHOSTTY_BASH_INJECT").?);
}

test "bash: unsupported options" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cmdlines = [_][:0]const u8{
        "bash --posix",
        "bash --rcfile script.sh --posix",
        "bash --init-file script.sh --posix",
        "bash -c script.sh",
        "bash -ic script.sh",
    };

    for (cmdlines) |cmdline| {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        try testing.expect(try setupBash(alloc, .{ .shell = cmdline }, ".", &env) == null);
        try testing.expect(env.get("GHOSTTY_BASH_INJECT") == null);
        try testing.expect(env.get("GHOSTTY_BASH_RCFILE") == null);
        try testing.expect(env.get("GHOSTTY_BASH_UNEXPORT_HISTFILE") == null);
    }
}

test "bash: inject flags" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // bash --norc
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        const command = try setupBash(alloc, .{ .shell = "bash --norc" }, ".", &env);

        try testing.expect(command.?.direct.len >= 2);
        try testing.expectEqualStrings("bash", command.?.direct[0]);
        try testing.expectEqualStrings("--posix", command.?.direct[1]);
        if (comptime builtin.target.os.tag.isDarwin()) {
            try testing.expectEqualStrings("--login", command.?.direct[2]);
        }
        try testing.expectEqualStrings("1 --norc", env.get("GHOSTTY_BASH_INJECT").?);
    }

    // bash --noprofile
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        const command = try setupBash(alloc, .{ .shell = "bash --noprofile" }, ".", &env);

        try testing.expect(command.?.direct.len >= 2);
        try testing.expectEqualStrings("bash", command.?.direct[0]);
        try testing.expectEqualStrings("--posix", command.?.direct[1]);
        if (comptime builtin.target.os.tag.isDarwin()) {
            try testing.expectEqualStrings("--login", command.?.direct[2]);
        }
        try testing.expectEqualStrings("1 --noprofile", env.get("GHOSTTY_BASH_INJECT").?);
    }
}

test "bash: rcfile" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    // bash --rcfile
    {
        const command = try setupBash(alloc, .{ .shell = "bash --rcfile profile.sh" }, ".", &env);
        try testing.expect(command.?.direct.len >= 2);
        try testing.expectEqualStrings("bash", command.?.direct[0]);
        try testing.expectEqualStrings("--posix", command.?.direct[1]);
        if (comptime builtin.target.os.tag.isDarwin()) {
            try testing.expectEqualStrings("--login", command.?.direct[2]);
        }
        try testing.expectEqualStrings("profile.sh", env.get("GHOSTTY_BASH_RCFILE").?);
    }

    // bash --init-file
    {
        const command = try setupBash(alloc, .{ .shell = "bash --init-file profile.sh" }, ".", &env);
        try testing.expect(command.?.direct.len >= 2);
        try testing.expectEqualStrings("bash", command.?.direct[0]);
        try testing.expectEqualStrings("--posix", command.?.direct[1]);
        if (comptime builtin.target.os.tag.isDarwin()) {
            try testing.expectEqualStrings("--login", command.?.direct[2]);
        }
        try testing.expectEqualStrings("profile.sh", env.get("GHOSTTY_BASH_RCFILE").?);
    }
}

test "bash: HISTFILE" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // HISTFILE unset
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        _ = try setupBash(alloc, .{ .shell = "bash" }, ".", &env);
        try testing.expect(std.mem.endsWith(u8, env.get("HISTFILE").?, ".bash_history"));
        try testing.expectEqualStrings("1", env.get("GHOSTTY_BASH_UNEXPORT_HISTFILE").?);
    }

    // HISTFILE set
    {
        var env = EnvMap.init(alloc);
        defer env.deinit();

        try env.put("HISTFILE", "my_history");

        _ = try setupBash(alloc, .{ .shell = "bash" }, ".", &env);
        try testing.expectEqualStrings("my_history", env.get("HISTFILE").?);
        try testing.expect(env.get("GHOSTTY_BASH_UNEXPORT_HISTFILE") == null);
    }
}

test "bash: additional arguments" {
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    // "-" argument separator
    {
        const command = try setupBash(alloc, .{ .shell = "bash - --arg file1 file2" }, ".", &env);
        try testing.expect(command.?.direct.len >= 6);
        try testing.expectEqualStrings("bash", command.?.direct[0]);
        try testing.expectEqualStrings("--posix", command.?.direct[1]);
        if (comptime builtin.target.os.tag.isDarwin()) {
            try testing.expectEqualStrings("--login", command.?.direct[2]);
        }

        const offset = if (comptime builtin.target.os.tag.isDarwin()) 3 else 2;
        try testing.expectEqualStrings("-", command.?.direct[offset + 0]);
        try testing.expectEqualStrings("--arg", command.?.direct[offset + 1]);
        try testing.expectEqualStrings("file1", command.?.direct[offset + 2]);
        try testing.expectEqualStrings("file2", command.?.direct[offset + 3]);
    }

    // "--" argument separator
    {
        const command = try setupBash(alloc, .{ .shell = "bash -- --arg file1 file2" }, ".", &env);
        try testing.expect(command.?.direct.len >= 6);
        try testing.expectEqualStrings("bash", command.?.direct[0]);
        try testing.expectEqualStrings("--posix", command.?.direct[1]);
        if (comptime builtin.target.os.tag.isDarwin()) {
            try testing.expectEqualStrings("--login", command.?.direct[2]);
        }

        const offset = if (comptime builtin.target.os.tag.isDarwin()) 3 else 2;
        try testing.expectEqualStrings("--", command.?.direct[offset + 0]);
        try testing.expectEqualStrings("--arg", command.?.direct[offset + 1]);
        try testing.expectEqualStrings("file1", command.?.direct[offset + 2]);
        try testing.expectEqualStrings("file2", command.?.direct[offset + 3]);
    }
}

/// Setup automatic shell integration for shells that include
/// their modules from paths in `XDG_DATA_DIRS` env variable.
///
/// The shell-integration path is prepended to `XDG_DATA_DIRS`.
/// It is also saved in the `GHOSTTY_SHELL_INTEGRATION_XDG_DIR` variable
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

    // We attempt to avoid allocating by using the stack up to 4K.
    // Max stack size is considerably larger on mac
    // 4K is a reasonable size for this for most cases. However, env
    // vars can be significantly larger so if we have to we fall
    // back to a heap allocated value.
    var stack_alloc_state = std.heap.stackFallback(4096, alloc_arena);
    const stack_alloc = stack_alloc_state.get();

    // If no XDG_DATA_DIRS set use the default value as specified.
    // This ensures that the default directories aren't lost by setting
    // our desired integration dir directly. See #2711.
    // <https://specifications.freedesktop.org/basedir-spec/0.6/#variables>
    const xdg_data_dirs_key = "XDG_DATA_DIRS";
    try env.put(
        xdg_data_dirs_key,
        try internal_os.prependEnv(
            stack_alloc,
            env.get(xdg_data_dirs_key) orelse "/usr/local/share:/usr/share",
            integ_dir,
        ),
    );
}

test "xdg: empty XDG_DATA_DIRS" {
    const testing = std.testing;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    try setupXdgDataDirs(alloc, ".", &env);

    try testing.expectEqualStrings("./shell-integration", env.get("GHOSTTY_SHELL_INTEGRATION_XDG_DIR").?);
    try testing.expectEqualStrings("./shell-integration:/usr/local/share:/usr/share", env.get("XDG_DATA_DIRS").?);
}

test "xdg: existing XDG_DATA_DIRS" {
    const testing = std.testing;

    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var env = EnvMap.init(alloc);
    defer env.deinit();

    try env.put("XDG_DATA_DIRS", "/opt/share");
    try setupXdgDataDirs(alloc, ".", &env);

    try testing.expectEqualStrings("./shell-integration", env.get("GHOSTTY_SHELL_INTEGRATION_XDG_DIR").?);
    try testing.expectEqualStrings("./shell-integration:/opt/share", env.get("XDG_DATA_DIRS").?);
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
