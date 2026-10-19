pub const String = extern struct {
    ptr: [*]const u8,
    len: usize,

    pub fn init(zig: anytype) String {
        return switch (@TypeOf(zig)) {
            []u8, []const u8 => .{
                // Borrowed strings keep a non-null pointer, but it must point
                // to real storage: empty Zig slices can use invalid sentinels
                // that foreign runtimes reject even without dereferencing.
                .ptr = if (zig.len == 0) "" else zig.ptr,
                .len = zig.len,
            },
            else => @compileError("unsupported String.init type: " ++ @typeName(@TypeOf(zig))),
        };
    }
};

pub const Buffer = extern struct {
    ptr: ?[*]u8 = null,
    cap: usize = 0,
    len: usize = 0,
};

test "String.init empty output" {
    const std = @import("std");
    const empty = try std.testing.allocator.alloc(u8, 0);
    defer std.testing.allocator.free(empty);
    const str = String.init(empty);
    try std.testing.expectEqual(@as(usize, 0), str.len);
    // Empty borrowed strings use the same real storage as an empty literal,
    // never Zig's zero-length allocation sentinel.
    try std.testing.expectEqual(@as([*]const u8, ""), str.ptr);
}
