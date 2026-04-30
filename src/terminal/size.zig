const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;

/// The maximum size of a page in bytes. We use a u16 here because any
/// smaller bit size by Zig is upgraded anyways to a u16 on mainstream
/// CPU architectures, and because 65KB is a reasonable page size. To
/// support better configurability, we derive everything from this.
pub const max_page_size = std.math.maxInt(u32);

/// The int type that can contain the maximum memory offset in bytes,
/// derived from the maximum terminal page size.
pub const OffsetInt = std.math.IntFittingRange(0, max_page_size - 1);

/// Int types for maximum values of things. A lot of these sizes are
/// based on "X is enough for any reasonable use case" principles.
// The goal is that a user can have the maxInt amount of all of these
// present at one time and be able to address them in a single Page.zig.

// Total number of cells that are possible in each dimension (row/col).
// Based on 2^16 being enough for any reasonable terminal size and allowing
// IDs to remain 16-bit.
pub const CellCountInt = u16;

// Total number of styles and hyperlinks that are possible in a page.
// We match CellCountInt here because each cell in a single row can have at
// most one style, making it simple to split a page by splitting rows.
//
// Note due to the way RefCountedSet works, we are short one value, but
// this is a theoretical limit we accept. A page with a single row max
// columns wide would be one short of having every cell have a unique style.
pub const StyleCountInt = CellCountInt;
pub const HyperlinkCountInt = CellCountInt;

// Total number of bytes that can be taken up by grapheme data and string
// data. Both of these technically unlimited with malicious input, but
// we choose a reasonable limit of 2^32 (4GB) per.
pub const GraphemeBytesInt = u32;
pub const StringBytesInt = u32;

/// The offset from the base address of the page to the start of some data.
/// This is typed for ease of use.
///
/// This is a packed struct so we can attach methods to an int.
pub fn Offset(comptime T: type) type {
    return packed struct(OffsetInt) {
        const Self = @This();

        offset: OffsetInt = 0,

        /// A slice of type T that stores via a base offset and len.
        pub const Slice = struct {
            offset: Self = .{},
            len: usize = 0,

            /// Returns a slice for the data, properly typed.
            pub inline fn slice(self: Slice, base: anytype) []T {
                return self.offset.ptr(base)[0..self.len];
            }
        };

        /// Returns a pointer to the start of the data, properly typed.
        pub inline fn ptr(self: Self, base: anytype) [*]T {
            // The offset must be properly aligned for the type since
            // our return type is naturally aligned. We COULD modify this
            // to return arbitrary alignment, but its not something we need.
            const addr = intFromBase(base) + self.offset;
            assert(addr % @alignOf(T) == 0);
            return @ptrFromInt(addr);
        }
    };
}

/// Represents a buffer that is offset from some base pointer.
/// Offset-based structures should use this as their initialization
/// parameter so that they can know what segment of memory they own
/// while at the same time initializing their offset fields to be
/// against the true base.
///
/// The term "true base" is used to describe the base address of
/// the allocation, which i.e. can include memory that you do NOT
/// own and is used by some other structures. All offsets are against
/// this "true base" so that to determine addresses structures don't
/// need to add up all the intermediary offsets.
pub const OffsetBuf = struct {
    /// The true base pointer to the backing memory. This is
    /// "byte zero" of the allocation. This plus the offset make
    /// it easy to pass in the base pointer in all usage to this
    /// structure and the offsets are correct.
    base: [*]u8,

    /// Offset from base where the beginning of /this/ data
    /// structure is located. We use this so that we can slowly
    /// build up a chain of offset-based structures but always
    /// have the base pointer sent into functions be the true base.
    offset: usize = 0,

    /// Initialize a zero-offset buffer from a base.
    pub fn init(base: anytype) OffsetBuf {
        return initOffset(base, 0);
    }

    /// Initialize from some base pointer and offset.
    pub fn initOffset(base: anytype, offset: usize) OffsetBuf {
        return .{
            .base = @ptrFromInt(intFromBase(base)),
            .offset = offset,
        };
    }

    /// The base address for the start of the data for the user
    /// of this OffsetBuf. This is where your data structure should
    /// begin; anything before this is NOT your memory.
    pub fn start(self: OffsetBuf) [*]u8 {
        const ptr = self.base + self.offset;
        return @ptrCast(ptr);
    }

    /// Returns an Offset calculation for some child member of
    /// your struct. The offset is against the true base pointer
    /// so that future callers can pass that in as the base.
    pub fn member(
        self: OffsetBuf,
        comptime T: type,
        len: usize,
    ) Offset(T) {
        return .{ .offset = @intCast(self.offset + len) };
    }

    /// Add an offset to the current offset.
    pub fn add(self: OffsetBuf, offset: usize) OffsetBuf {
        return .{
            .base = self.base,
            .offset = self.offset + offset,
        };
    }

    /// Rebase the offset to have a zero offset by rebasing onto start.
    /// This is similar to `add` but all of the offsets are merged into base.
    pub fn rebase(self: OffsetBuf, offset: usize) OffsetBuf {
        return .{
            .base = self.start() + offset,
            .offset = 0,
        };
    }
};

/// Get the offset for a given type from some base pointer to the
/// actual pointer to the type.
pub inline fn getOffset(
    comptime T: type,
    base: anytype,
    ptr: *const T,
) Offset(T) {
    const base_int = intFromBase(base);
    const ptr_int = @intFromPtr(ptr);
    const offset = ptr_int - base_int;
    return .{ .offset = @intCast(offset) };
}

inline fn intFromBase(base: anytype) usize {
    const T = @TypeOf(base);
    return switch (@typeInfo(T)) {
        .pointer => |v| switch (v.size) {
            .one,
            .many,
            .c,
            => @intFromPtr(base),

            .slice => @intFromPtr(base.ptr),
        },

        else => switch (T) {
            OffsetBuf => @intFromPtr(base.base),

            else => @compileError("invalid base type"),
        },
    };
}

test "Offset" {
    // This test is here so that if Offset changes, we can be very aware
    // of this effect and think about the implications of it.
    const testing = std.testing;
    try testing.expect(OffsetInt == u32);
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

test "getOffset bytes" {
    const testing = std.testing;
    var widgets: []const u8 = "ABCD";
    const offset = getOffset(u8, widgets.ptr, &widgets[2]);
    try testing.expectEqual(@as(OffsetInt, 2), offset.offset);
}

test "getOffset structs" {
    const testing = std.testing;
    const Widget = struct { x: u32, y: u32 };
    const widgets: []const Widget = &.{
        .{ .x = 1, .y = 2 },
        .{ .x = 3, .y = 4 },
        .{ .x = 5, .y = 6 },
        .{ .x = 7, .y = 8 },
        .{ .x = 9, .y = 10 },
    };
    const offset = getOffset(Widget, widgets.ptr, &widgets[2]);
    try testing.expectEqual(
        @as(OffsetInt, @sizeOf(Widget) * 2),
        offset.offset,
    );
}
