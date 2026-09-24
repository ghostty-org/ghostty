const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("wuffs_c");
const Error = @import("error.zig").Error;
const check = @import("error.zig").check;

const log = std.log.scoped(.wuffs_zlib);

/// Decode a complete RFC 1950 zlib stream. `size_hint` is the expected output
/// size when known; the output may grow up to `limit` bytes.
pub fn decode(
    alloc: Allocator,
    data: []const u8,
    limit: usize,
    size_hint: ?usize,
) Error![]u8 {
    if (limit == 0) return error.Overflow;

    // Wuffs' translated decoder is opaque, so allocate its storage with Zig.
    const decoder_buf = try alloc.alloc(u8, c.sizeof__wuffs_zlib__decoder());
    defer alloc.free(decoder_buf);
    const decoder: ?*c.wuffs_zlib__decoder = @ptrCast(decoder_buf);
    {
        const status = c.wuffs_zlib__decoder__initialize(
            decoder,
            c.sizeof__wuffs_zlib__decoder(),
            c.WUFFS_VERSION,
            0,
        );
        try check(log, &status);
    }

    var source: c.wuffs_base__io_buffer = .{
        .data = .{ .ptr = @ptrCast(@constCast(data.ptr)), .len = data.len },
        .meta = .{ .wi = data.len, .ri = 0, .pos = 0, .closed = true },
    };

    const initial_size = @max(1, @min(limit, size_hint orelse
        std.math.mul(usize, data.len, 2) catch limit));
    var destination = try alloc.alloc(u8, initial_size);
    errdefer alloc.free(destination);

    var output: c.wuffs_base__io_buffer = .{
        .data = .{ .ptr = @ptrCast(destination.ptr), .len = destination.len },
        .meta = .{ .wi = 0, .ri = 0, .pos = 0, .closed = false },
    };
    while (true) {
        const status = c.wuffs_zlib__decoder__transform_io(
            decoder,
            &output,
            &source,
            c.wuffs_base__empty_slice_u8(),
        );
        if (c.wuffs_base__status__is_ok(&status)) {
            if (source.meta.ri != data.len) return error.WuffsError;
            return try alloc.realloc(destination, output.meta.wi);
        }
        if (status.repr != c.wuffs_base__suspension__short_write) {
            try check(log, &status);
            unreachable;
        }
        if (output.meta.wi != destination.len) return error.WuffsError;
        if (destination.len == limit) return error.Overflow;

        const next_size = destination.len + @min(destination.len, limit - destination.len);
        destination = try alloc.realloc(destination, next_size);
        output.data = .{ .ptr = @ptrCast(destination.ptr), .len = destination.len };
    }
}

test "zlib decode grows output" {
    const compressed = [_]u8{
        0x78, 0x9c, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0x28, 0x2f,
        0x4d, 0x4b, 0x2b, 0x06, 0x00, 0x1a, 0x02, 0x04, 0x60,
    };
    const output = try decode(std.testing.allocator, &compressed, 64, 1);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("hello wuffs", output);
}

test "zlib decode enforces output limit" {
    const compressed = [_]u8{
        0x78, 0x9c, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0x28, 0x2f,
        0x4d, 0x4b, 0x2b, 0x06, 0x00, 0x1a, 0x02, 0x04, 0x60,
    };
    try std.testing.expectError(error.Overflow, decode(std.testing.allocator, &compressed, 10, null));
}

test "zlib decode accepts exact limit and rejects truncated input" {
    const compressed = [_]u8{
        0x78, 0x9c, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0x28, 0x2f,
        0x4d, 0x4b, 0x2b, 0x06, 0x00, 0x1a, 0x02, 0x04, 0x60,
    };
    const output = try decode(std.testing.allocator, &compressed, 11, 11);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("hello wuffs", output);
    try std.testing.expectError(error.WuffsError, decode(std.testing.allocator, compressed[0 .. compressed.len - 1], 64, null));
}
