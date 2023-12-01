const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const passwd = @import("passwd.zig");

const Error = error{
    /// The buffer used for output is not large enough to store the value.
    BufferTooSmall,
};

/// Determine the home directory for the currently executing user. This
/// is generally an expensive process so the value should be cached.
pub inline fn home(buf: []u8) !?[]u8 {
    return switch (builtin.os.tag) {
        inline .linux, .macos => try homeUnix(buf),
        .windows => try homeWindows(buf),
        else => @compileError("unimplemented"),
    };
}

fn homeUnix(buf: []u8) !?[]u8 {
    // First: if we have a HOME env var, then we use that.
    if (std.os.getenv("HOME")) |result| {
        if (buf.len < result.len) return Error.BufferTooSmall;
        @memcpy(buf[0..result.len], result);
        return buf[0..result.len];
    }

    // Everything below here will require some allocation
    var tempBuf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&tempBuf);

    // If we're on darwin, we try the directory service. I'm not sure if there
    // is a Mac API to do this but if so we can link to that...
    if (builtin.os.tag == .macos) {
        const run = try std.ChildProcess.run(.{
            .allocator = fba.allocator(),
            .argv = &[_][]const u8{
                "/bin/sh",
                "-c",
                "dscl -q . -read /Users/\"$(whoami)\" NFSHomeDirectory | sed 's/^[^ ]*: //'",
            },
            .max_output_bytes = fba.buffer.len / 2,
        });

        if (run.term == .Exited and run.term.Exited == 0) {
            const result = trimSpace(run.stdout);
            if (buf.len < result.len) return Error.BufferTooSmall;
            @memcpy(buf[0..result.len], result);
            return buf[0..result.len];
        }
    }

    // We try passwd. This doesn't work on multi-user mac but we try it anyways.
    fba.reset();
    const pw = try passwd.get(fba.allocator());
    if (pw.home) |result| {
        if (buf.len < result.len) return Error.BufferTooSmall;
        @memcpy(buf[0..result.len], result);
        return buf[0..result.len];
    }

    // If all else fails, have the shell tell us...
    fba.reset();
    const run = try std.ChildProcess.run(.{
        .allocator = fba.allocator(),
        .argv = &[_][]const u8{ "/bin/sh", "-c", "cd && pwd" },
        .max_output_bytes = fba.buffer.len / 2,
    });

    if (run.term == .Exited and run.term.Exited == 0) {
        const result = trimSpace(run.stdout);
        if (buf.len < result.len) return Error.BufferTooSmall;
        @memcpy(buf[0..result.len], result);
        return buf[0..result.len];
    }

    return null;
}

fn homeWindows(buf: []u8) !?[]u8 {
    const drive_len = blk: {
        var fba_instance = std.heap.FixedBufferAllocator.init(buf);
        const fba = fba_instance.allocator();
        const drive = std.process.getEnvVarOwned(fba, "HOMEDRIVE") catch |err| switch (err) {
            error.OutOfMemory => return Error.BufferTooSmall,
            error.InvalidUtf8, error.EnvironmentVariableNotFound => return null,
        };
        // could shift the contents if this ever happens
        if (drive.ptr != buf.ptr) @panic("codebug");
        break :blk drive.len;
    };

    const path_len = blk: {
        const path_buf = buf[drive_len..];
        var fba_instance = std.heap.FixedBufferAllocator.init(buf[drive_len..]);
        const fba = fba_instance.allocator();
        const homepath = std.process.getEnvVarOwned(fba, "HOMEPATH") catch |err| switch (err) {
            error.OutOfMemory => return Error.BufferTooSmall,
            error.InvalidUtf8, error.EnvironmentVariableNotFound => return null,
        };
        // could shift the contents if this ever happens
        if (homepath.ptr != path_buf.ptr) @panic("codebug");
        break :blk homepath.len;
    };

    return buf[0 .. drive_len + path_len];
}

fn trimSpace(input: []const u8) []const u8 {
    return std.mem.trim(u8, input, " \n\t");
}

test {
    const testing = std.testing;

    var buf: [1024]u8 = undefined;
    const result = try home(&buf);
    try testing.expect(result != null);
    try testing.expect(result.?.len > 0);
}
