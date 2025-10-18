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

extern "c" fn posix_spawnattr_setsigdefault(
    attr: *c.posix_spawnattr_t,
    sigdefault: *const std.posix.sigset_t,
) c_int;
extern "c" fn responsibility_spawnattrs_setdisclaim(
    attrs: *const c.posix_spawnattr_t,
    disclaim: bool,
) c_int;

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

    pub fn setsigdefault(attr: *T, sigdefault: *const std.posix.sigset_t) UnexpectedError!void {
        return switch (errno(posix_spawnattr_setsigdefault(
            attr,
            sigdefault,
        ))) {
            .SUCCESS => {},
            else => |err| return unexpectedErrno(err),
        };
    }

    /// This is undocumented, private API, so I'll link to some resources
    /// here: https://www.qt.io/blog/the-curious-case-of-the-responsible-process
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

pub const Flags = packed struct(c_short) {
    resetids: bool = false,
    setpgroup: bool = false,
    setsigdef: bool = false,
    setsigmask: bool = false,
    _pad1: u2 = 0,
    setexec: bool = false,
    start_suspended: bool = false,
    disable_aslr: bool = false,
    _pad2: u1 = 0,
    setsid: bool = false,
    reslide: bool = false,
    _pad3: u2 = 0,
    cloexec_default: bool = false,
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
