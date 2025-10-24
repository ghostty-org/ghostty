const Code = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const synthetic = @import("../main.zig");

pub const Options = struct {};

alloc: Allocator,

/// Create a new terminal stream handler for the given arguments.
pub fn create(
    alloc: Allocator,
    _: Options,
) !*Code {
    const ptr = try alloc.create(Code);
    errdefer alloc.destroy(ptr);
    ptr.alloc = alloc;
    return ptr;
}

pub fn destroy(self: *Code, alloc: Allocator) void {
    alloc.destroy(self);
}

pub fn run(self: *Code, writer: anytype, _: std.Random) !void {
    while (true) {
        var dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
        defer dir.close();
        var walk = try dir.walk(self.alloc);
        defer walk.deinit();
        while (try walk.next()) |entry| {
            switch (entry.kind) {
                .file => file: {
                    const ext = std.fs.path.extension(entry.basename);
                    process: {
                        if (std.mem.eql(u8, ext, ".blp")) break :process;
                        if (std.mem.eql(u8, ext, ".c")) break :process;
                        if (std.mem.eql(u8, ext, ".cpp")) break :process;
                        if (std.mem.eql(u8, ext, ".h")) break :process;
                        if (std.mem.eql(u8, ext, ".in")) break :process;
                        if (std.mem.eql(u8, ext, ".json")) break :process;
                        if (std.mem.eql(u8, ext, ".md")) break :process;
                        if (std.mem.eql(u8, ext, ".nix")) break :process;
                        if (std.mem.eql(u8, ext, ".nu")) break :process;
                        if (std.mem.eql(u8, ext, ".pl")) break :process;
                        if (std.mem.eql(u8, ext, ".po")) break :process;
                        if (std.mem.eql(u8, ext, ".pot")) break :process;
                        if (std.mem.eql(u8, ext, ".py")) break :process;
                        if (std.mem.eql(u8, ext, ".rs")) break :process;
                        if (std.mem.eql(u8, ext, ".sh")) break :process;
                        if (std.mem.eql(u8, ext, ".swift")) break :process;
                        if (std.mem.eql(u8, ext, ".toml")) break :process;
                        if (std.mem.eql(u8, ext, ".txt")) break :process;
                        if (std.mem.eql(u8, ext, ".yaml")) break :process;
                        if (std.mem.eql(u8, ext, ".zig")) break :process;
                        break :file;
                    }
                    const file = try entry.dir.openFile(entry.basename, .{ .mode = .read_only });
                    defer file.close();
                    while (true) {
                        var buf: [4096]u8 = undefined;
                        const len = try file.read(&buf);
                        if (len == 0) break;
                        writer.writeAll(buf[0..len]) catch |err| switch (err) {
                            error.NoSpaceLeft => return,
                            else => |e| return e,
                        };
                    }
                },
                else => {},
            }
        }
    }
}

test Code {
    const testing = std.testing;
    const alloc = testing.allocator;

    const impl: *Code = try .create(alloc, .{});
    defer impl.destroy(alloc);

    var prng = std.Random.DefaultPrng.init(1);
    const rand = prng.random();

    var buf: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    try impl.run(writer, rand);
}
