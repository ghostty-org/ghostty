const std = @import("std");
const assert = std.debug.assert;

/// The maximum size of a page in bytes. We use a u16 here because any
/// smaller bit size by Zig is upgraded anyways to a u16 on mainstream
/// CPU architectures, and because 65KB is a reasonable page size. To
/// support better configurability, we derive everything from this.
pub const max_page_size = 65_536;

/// The int type that can contain the maximum memory offset in bytes,
/// derived from the maximum terminal page size.
pub const OffsetInt = std.math.IntFittingRange(0, max_page_size - 1);

/// The int type that can contain the maximum number of cells in a page.
pub const CellCountInt = u16; // TODO: derive
//
/// The offset from the base address of the page to the start of some data.
/// This is typed for ease of use.
///
/// This is a packed struct so we can attach methods to an int.
pub fn Offset(comptime T: type) type {
    return packed struct(OffsetInt) {
        const Self = @This();

        offset: OffsetInt = 0,

        /// Returns a pointer to the start of the data, properly typed.
        pub fn ptr(self: Self, base: anytype) [*]T {
            // The offset must be properly aligned for the type since
            // our return type is naturally aligned. We COULD modify this
            // to return arbitrary alignment, but its not something we need.
            assert(@mod(self.offset, @alignOf(T)) == 0);
            return @ptrFromInt(@intFromPtr(base) + self.offset);
        }
    };
}

test "Offset" {
    // This test is here so that if Offset changes, we can be very aware
    // of this effect and think about the implications of it.
    const testing = std.testing;
    try testing.expect(OffsetInt == u16);
}

test "Offset ptr u8" {
    const testing = std.testing;
    const offset: Offset(u8) = .{ .offset = 42 };
    const base_int: usize = @intFromPtr(&offset);
    const actual = offset.ptr(&offset);
    try testing.expectEqual(@as(usize, base_int + 42), @intFromPtr(actual));
}

test "Offset ptr structural" {
    const Struct = struct { x: u32, y: u32 };
    const testing = std.testing;
    const offset: Offset(Struct) = .{ .offset = @alignOf(Struct) * 4 };
    const base_int: usize = std.mem.alignForward(usize, @intFromPtr(&offset), @alignOf(Struct));
    const base: [*]u8 = @ptrFromInt(base_int);
    const actual = offset.ptr(base);
    try testing.expectEqual(@as(usize, base_int + offset.offset), @intFromPtr(actual));
}
