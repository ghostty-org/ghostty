//! This file contains a wrapper around the `posix_spawn` API and
//! exposes it in a higher-level idiomatic Zig way.

const std = @import("std");
const c = std.c;
const Allocator = std.mem.Allocator;
const UnexpectedError = std.posix.UnexpectedError;
const unexpectedErrno = std.posix.unexpectedErrno;
const errno = std.posix.errno;
const fd_t = std.posix.fd_t;
const pid_t = std.posix.pid_t;

// Zig's standard library doesn't yet wrap posix_spawnattr_setsigdefault,
// so we declare it here. This sets the signals that will be set to SIG_DFL
// in the spawned child process. See man 3 posix_spawnattr_setsigdefault
// for details. Only takes effect when used with POSIX_SPAWN_SETSIGDEF flag.
extern "c" fn posix_spawnattr_setsigdefault(
    attr: *c.posix_spawnattr_t,
    sigdefault: *const std.posix.sigset_t,
) c_int;

// This function is not part of any public Apple header and is not documented
// in man pages. It controls whether a spawned process inherits the "responsible
// process" designation from its parent for purposes of TCC (Transparency, Consent,
// and Control) permissions and resource accounting.
//
// When `disclaim` is true, the spawned process becomes responsible for itself
// rather than being attributed to the spawning process. This is critical for
// terminal emulators to avoid having all child processes' permission requests
// and resource usage attributed to the terminal itself.
//
// References:
// - https://www.qt.io/blog/the-curious-case-of-the-responsible-process
// - Reverse-engineered from various open source projects
extern "c" fn responsibility_spawnattrs_setdisclaim(
    attrs: *const c.posix_spawnattr_t,
    disclaim: bool,
) c_int;

/// Spawn a new process using PATH resolution.
pub fn spawnp(
    path: [:0]const u8,
    actions: ?*file_actions.T,
    attr: ?*spawn_attr.T,
    argv: [*:null]const ?[*:0]const u8,
    env: [*:null]const ?[*:0]const u8,
) UnexpectedError!pid_t {
    var pid: pid_t = undefined;
    return switch (errno(c.posix_spawnp(
        &pid,
        path,
        actions,
        attr,
        argv,
        env,
    ))) {
        .SUCCESS => pid,
        else => |err| return unexpectedErrno(err),
    };
}

/// Wrapper around the posix_spawn_file_actions_t type. This will be
/// sparsely documented since it should mostly just match the man pages.
///
/// NOTE: This purposely does not implement many functions. We only
/// implement what we need for our use case. It is trivial to add more.
pub const file_actions = struct {
    pub const T = c.posix_spawn_file_actions_t;

    pub fn create() (Allocator.Error || UnexpectedError)!T {
        var actions: T = undefined;
        return switch (errno(c.posix_spawn_file_actions_init(&actions))) {
            .SUCCESS => actions,
            .NOMEM => return error.OutOfMemory,
            else => |err| return unexpectedErrno(err),
        };
    }

    pub fn destroy(actions: *T) void {
        _ = c.posix_spawn_file_actions_destroy(actions);
    }

    pub fn close(
        actions: *T,
        fildes: fd_t,
    ) (error{BadFileDescriptor} || UnexpectedError)!void {
        return switch (errno(c.posix_spawn_file_actions_addclose(
            actions,
            fildes,
        ))) {
            .SUCCESS => {},
            .BADF => return error.BadFileDescriptor,
            else => |err| return unexpectedErrno(err),
        };
    }

    pub fn dup2(
        actions: *T,
        fildes: fd_t,
        newfildes: fd_t,
    ) (error{BadFileDescriptor} || UnexpectedError)!void {
        return switch (errno(c.posix_spawn_file_actions_adddup2(
            actions,
            fildes,
            newfildes,
        ))) {
            .SUCCESS => {},
            .BADF => return error.BadFileDescriptor,
            else => |err| return unexpectedErrno(err),
        };
    }

    /// Change working directory in the spawned process.
    ///
    /// Uses the non-portable (_np suffix) addchdir function which is available
    /// on Darwin and some other platforms.
    pub fn chdir(
        actions: *T,
        path: [*:0]const u8,
    ) UnexpectedError!void {
        return switch (errno(c.posix_spawn_file_actions_addchdir_np(
            actions,
            path,
        ))) {
            .SUCCESS => {},
            else => |err| return unexpectedErrno(err),
        };
    }
};

/// Wrapper around the posix_spawnattr_t type. This will be
/// sparsely documented since it should mostly just match the man pages.
///
/// NOTE: This purposely does not implement many functions. We only
/// implement what we need for our use case. It is trivial to add more.
pub const spawn_attr = struct {
    pub const T = c.posix_spawnattr_t;

    pub fn create() (Allocator.Error || UnexpectedError)!T {
        var attr: T = undefined;
        return switch (errno(c.posix_spawnattr_init(&attr))) {
            .SUCCESS => attr,
            .NOMEM => return error.OutOfMemory,
            else => |err| return unexpectedErrno(err),
        };
    }

    pub fn destroy(attr: *T) void {
        _ = c.posix_spawnattr_destroy(attr);
    }

    pub fn setflags(attr: *T, flags: Flags) UnexpectedError!void {
        return switch (errno(c.posix_spawnattr_setflags(
            attr,
            flags.int(),
        ))) {
            .SUCCESS => {},
            else => |err| return unexpectedErrno(err),
        };
    }

    /// Set signals to default (SIG_DFL) in the spawned process.
    ///
    /// This function sets which signals should be reset to their default
    /// handlers in the child process. Only takes effect when the
    /// POSIX_SPAWN_SETSIGDEF flag is set in the spawn attributes.
    ///
    /// This is typically paired with Flags.setsigdef = true to ensure
    /// the child doesn't inherit custom signal handlers from the parent.
    pub fn setsigdefault(attr: *T, sigdefault: *const std.posix.sigset_t) UnexpectedError!void {
        return switch (errno(posix_spawnattr_setsigdefault(
            attr,
            sigdefault,
        ))) {
            .SUCCESS => {},
            else => |err| return unexpectedErrno(err),
        };
    }

    /// Set the "disclaim" flag for macOS responsible process handling.
    ///
    /// See: https://www.qt.io/blog/the-curious-case-of-the-responsible-process
    pub fn disclaim(attr: *T, v: bool) UnexpectedError!void {
        return switch (errno(responsibility_spawnattrs_setdisclaim(
            attr,
            v,
        ))) {
            .SUCCESS => {},
            else => |err| return unexpectedErrno(err),
        };
    }
};

/// POSIX spawn flags with Apple/Darwin extensions.
///
/// Note: Several fields are Apple-specific extensions and will not work on
/// other POSIX systems.
pub const Flags = packed struct(c_short) {
    resetids: bool = false, // Reset effective UID/GID to real UID/GID
    setpgroup: bool = false, // Set process group
    setsigdef: bool = false, // Reset signals to SIG_DFL (see setsigdefault)
    setsigmask: bool = false, // Set signal mask in child
    _pad1: u2 = 0,
    setexec: bool = false, // Replace current process image (like exec)
    start_suspended: bool = false, // Start process suspended (debugging)
    disable_aslr: bool = false, // Disable ASLR for spawned process
    _pad2: u1 = 0,
    setsid: bool = false, // Create new session (process becomes session leader)
    reslide: bool = false, // Re-randomize ASLR slide
    _pad3: u2 = 0,
    cloexec_default: bool = false, // Default file descriptors to close-on-exec
    _pad4: u1 = 0,

    /// Integer value of this struct.
    pub fn int(self: Flags) c_short {
        return @bitCast(self);
    }
};

test file_actions {
    var actions = try file_actions.create();
    defer file_actions.destroy(&actions);
}

test "dup2" {
    var actions = try file_actions.create();
    defer file_actions.destroy(&actions);
    try file_actions.dup2(&actions, 0, 1);
}

test "close" {
    var actions = try file_actions.create();
    defer file_actions.destroy(&actions);
    try file_actions.close(&actions, 0);
}

test "chdir" {
    var actions = try file_actions.create();
    defer file_actions.destroy(&actions);
    try file_actions.chdir(&actions, "/tmp");
}

test spawn_attr {
    var attr = try spawn_attr.create();
    defer spawn_attr.destroy(&attr);
}

test "spawn_attr.setflags" {
    var attr = try spawn_attr.create();
    defer spawn_attr.destroy(&attr);
    try spawn_attr.setflags(&attr, .{ .setsid = true });
}

test "spawn_attr.setsigdefault" {
    var attr = try spawn_attr.create();
    defer spawn_attr.destroy(&attr);
    var sigset = std.mem.zeroes(std.posix.sigset_t);
    try spawn_attr.setsigdefault(&attr, &sigset);
}

test "spawn_attr.disclaim" {
    // This test uses the private macOS API and will only pass on Darwin
    const builtin = @import("builtin");
    if (comptime builtin.os.tag != .macos) return error.SkipZigTest;

    var attr = try spawn_attr.create();
    defer spawn_attr.destroy(&attr);
    try spawn_attr.disclaim(&attr, true);
}

test "flags match std.c values" {
    const testing = std.testing;
    try testing.expectEqual(std.c.POSIX_SPAWN.RESETIDS, Flags.int(.{ .resetids = true }));
    try testing.expectEqual(std.c.POSIX_SPAWN.SETPGROUP, Flags.int(.{ .setpgroup = true }));
    try testing.expectEqual(std.c.POSIX_SPAWN.SETSIGDEF, Flags.int(.{ .setsigdef = true }));
    try testing.expectEqual(std.c.POSIX_SPAWN.SETSIGMASK, Flags.int(.{ .setsigmask = true }));
    try testing.expectEqual(std.c.POSIX_SPAWN.SETEXEC, Flags.int(.{ .setexec = true }));
    try testing.expectEqual(std.c.POSIX_SPAWN.START_SUSPENDED, Flags.int(.{ .start_suspended = true }));
    try testing.expectEqual(std.c.POSIX_SPAWN.DISABLE_ASLR, Flags.int(.{ .disable_aslr = true }));
    try testing.expectEqual(std.c.POSIX_SPAWN.SETSID, Flags.int(.{ .setsid = true }));
    try testing.expectEqual(std.c.POSIX_SPAWN.RESLIDE, Flags.int(.{ .reslide = true }));
    try testing.expectEqual(std.c.POSIX_SPAWN.CLOEXEC_DEFAULT, Flags.int(.{ .cloexec_default = true }));
}

test spawnp {
    const testing = std.testing;
    const pid = try spawnp(
        "true",
        null,
        null,
        &.{"true"},
        &.{},
    );
    try testing.expect(pid > 0);
    const result = std.posix.waitpid(pid, 0);
    try std.testing.expectEqual(@as(u32, 0), result.status);
}
