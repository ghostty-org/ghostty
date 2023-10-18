const std = @import("std");
const builtin = @import("builtin");
const internal_os = @import("main.zig");
const build_config = @import("../build_config.zig");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const log = std.log.scoped(.passwd);

// We want to be extra sure since this will force bad symbols into our import table
comptime {
    if (builtin.target.isWasm()) {
        @compileError("passwd is not available for wasm");
    }
}

/// Used to determine the default shell and directory on Unixes.
const c = if (builtin.os.tag != .windows) @cImport({
    @cInclude("sys/types.h");
    @cInclude("unistd.h");
    @cInclude("pwd.h");
}) else {};

// Entry that is retrieved from the passwd API. This only contains the fields
// we care about.
pub const Entry = struct {
    shell: ?[]const u8 = null,
    home: ?[]const u8 = null,
};

/// Get the passwd entry for the currently executing user.
pub fn get(alloc: Allocator) !Entry {
    if (builtin.os.tag == .windows) @panic("todo: windows");

    var buf: [1024]u8 = undefined;
    var pw: c.struct_passwd = undefined;
    var pw_ptr: ?*c.struct_passwd = null;
    const res = c.getpwuid_r(c.getuid(), &pw, &buf, buf.len, &pw_ptr);
    if (res != 0) {
        log.warn("error retrieving pw entry code={d}", .{res});
        return Entry{};
    }

    if (pw_ptr == null) {
        // Future: let's check if a better shell is available like zsh
        log.warn("no pw entry to detect default shell, will default to 'sh'", .{});
        return Entry{};
    }

    var result: Entry = .{};

    // If we're in flatpak then our entry is always empty so we grab it
    // by shelling out to the host. note that we do HAVE an entry in the
    // sandbox but only the username is correct.
    if (internal_os.isFlatpak()) flatpak: {
        if (comptime !build_config.flatpak) {
            log.warn("flatpak detected, but this build doesn't contain flatpak support", .{});
            break :flatpak;
        }

        log.info("flatpak detected, will use host command to get our entry", .{});

        // Note: we wrap our getent call in a /bin/sh login shell because
        // some operating systems (NixOS tested) don't set the PATH for various
        // utilities properly until we get a login shell.
        const Pty = @import("../Pty.zig");
        var pty = try Pty.open(.{});
        defer pty.deinit();
        var cmd: internal_os.FlatpakHostCommand = .{
            .argv = &[_][]const u8{
                "/bin/sh",
                "-l",
                "-c",
                try std.fmt.allocPrint(
                    alloc,
                    "getent passwd {s}",
                    .{std.mem.sliceTo(pw.pw_name, 0)},
                ),
            },
            .stdin = pty.slave,
            .stdout = pty.slave,
            .stderr = pty.slave,
        };
        _ = try cmd.spawn(alloc);
        _ = try cmd.wait();

        // Once started, we can close the child side. We do this after
        // wait right now but that is fine too. This lets us read the
        // parent and detect EOF.
        _ = std.os.close(pty.slave);

        // Read all of our output
        const output = output: {
            var output: std.ArrayListUnmanaged(u8) = .{};
            while (true) {
                const n = std.os.read(pty.master, &buf) catch |err| {
                    switch (err) {
                        // EIO is triggered at the end since we closed our
                        // child side. This is just EOF for this. I'm not sure
                        // if I'm doing this wrong.
                        error.InputOutput => break,
                        else => return err,
                    }
                };

                try output.appendSlice(alloc, buf[0..n]);

                // Max total size is buf.len. We can do better here by trimming
                // the front and continuing reading but we choose to just exit.
                if (output.items.len > buf.len) break;
            }

            break :output try output.toOwnedSlice(alloc);
        };

        // Shell and home are the last two entries
        var it = std.mem.splitBackwards(u8, std.mem.trimRight(u8, output, " \r\n"), ":");
        result.shell = it.next() orelse null;
        result.home = it.next() orelse null;
        return result;
    }

    if (pw.pw_shell) |ptr| {
        const source = std.mem.sliceTo(ptr, 0);
        const sh = try alloc.alloc(u8, source.len);
        std.mem.copy(u8, sh, source);
        result.shell = sh;
    }

    if (pw.pw_dir) |ptr| {
        const source = std.mem.sliceTo(ptr, 0);
        const dir = try alloc.alloc(u8, source.len);
        std.mem.copy(u8, dir, source);
        result.home = dir;
    }

    return result;
}

test {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const testing = std.testing;
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // We should be able to get an entry
    const entry = try get(alloc);
    try testing.expect(entry.shell != null);
    try testing.expect(entry.home != null);
}
