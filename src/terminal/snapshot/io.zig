//! Wire-format I/O helpers.
//!
//! These are sometimes very thin layers over standard `std.Io.Writer`
//! but its to help ensure consistency in our behavior and avoid some
//! pitfalls.

const std = @import("std");
const testing = std.testing;

/// writeInt ensures we write in little-endian since that is our
/// standard form.
pub fn writeInt(
    writer: *std.Io.Writer,
    comptime T: type,
    value: T,
) std.Io.Writer.Error!void {
    try writer.writeInt(T, value, .little);
}

/// Read a little-endian integer.
///
/// This avoids `takeInt` because at the time of writing this the underlying
/// implementation uses `takeArray` which asserts that the reader buffer
/// is as large as T. Our approach works with caller-selected buffers that
/// may be smaller.
pub fn readInt(
    reader: *std.Io.Reader,
    comptime T: type,
) std.Io.Reader.Error!T {
    var buf: [@sizeOf(T)]u8 = undefined;
    try reader.readSliceAll(&buf);
    return std.mem.readInt(T, &buf, .little);
}

test "integer round trip with a one-byte reader buffer" {
    var encoded: [6]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&encoded);
    try writeInt(&writer, u16, 0x1234);
    try writeInt(&writer, u32, 0x56789abc);

    var source: std.Io.Reader = .fixed(&encoded);
    var buf: [1]u8 = undefined;
    var limited = source.limited(.unlimited, &buf);

    try testing.expectEqual(
        @as(u16, 0x1234),
        try readInt(&limited.interface, u16),
    );
    try testing.expectEqual(
        @as(u32, 0x56789abc),
        try readInt(&limited.interface, u32),
    );
}
