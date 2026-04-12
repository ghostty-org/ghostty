const std = @import("std");
const builtin = @import("builtin");
const internal_os = @import("main.zig");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const posix = std.posix;

const log = std.log.scoped(.passwd);

// We want to be extra sure since this will force bad symbols into our import table
comptime {
    if (builtin.target.cpu.arch.isWasm()) {
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
    shell: ?[:0]const u8 = null,
    home: ?[:0]const u8 = null,
    name: ?[:0]const u8 = null,
};

/// Get the passwd entry for the currently executing user.
pub fn get(alloc: Allocator) !Entry {
    if (builtin.os.tag == .windows) @compileError("passwd is not available on windows");

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

    if (pw.pw_shell) |ptr| {
        const source = std.mem.sliceTo(ptr, 0);
        const value = try alloc.dupeZ(u8, source);
        result.shell = value;
    }

    if (pw.pw_dir) |ptr| {
        const source = std.mem.sliceTo(ptr, 0);
        const value = try alloc.dupeZ(u8, source);
        result.home = value;
    }

    if (pw.pw_name) |ptr| {
        const source = std.mem.sliceTo(ptr, 0);
        const value = try alloc.dupeZ(u8, source);
        result.name = value;
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
