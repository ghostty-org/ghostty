//! Code taken from older reader implementations, still may be useful to keep
//! around in general. See README.md for license and details.
const std = @import("std");

/// Pulled from old stdlib as this function has been removed.
pub fn readSkipUntilDelimiterOrEof(reader: *std.Io.Reader, delimiter: u8) std.Io.Reader.Error!void {
    while (true) {
        const byte = readByte(reader) catch |err| switch (err) {
            error.EndOfStream => return,
            else => |e| return e,
        };
        if (byte == delimiter) return;
    }
}

/// Pulled from old stdlib as this function has been removed.
pub fn readStructEndian(
    reader: *std.Io.Reader,
    comptime T: type,
    endian: std.builtin.Endian,
) std.Io.Reader.Error!T {
    var result: [1]T = undefined;
    try reader.readSliceEndian(T, &result, endian);
    return result[0];
}

/// Pulled from old stdlib as this function has been removed.
pub fn readerInt(reader: *std.Io.Reader, comptime T: type, endian: std.builtin.Endian) std.Io.Reader.Error!T {
    const bytes = try readBytesNoEof(reader, @divExact(@typeInfo(T).int.bits, 8));
    return std.mem.readInt(T, &bytes, endian);
}

/// Pulled from old stdlib as this function has been removed.
pub fn readByteSigned(reader: *std.Io.Reader) std.Io.Reader.Error!i8 {
    return @as(i8, @bitCast(try readByte(reader)));
}

/// Pulled from old stdlib as this function has been removed.
pub fn readByte(reader: *std.Io.Reader) std.Io.Reader.Error!u8 {
    var result: [1]u8 = undefined;
    try reader.readSliceAll(&result);
    return result[0];
}

/// Pulled from old stdlib as this function has been removed.
pub fn readSkipBytes(reader: *std.Io.Reader, num_bytes: u64) std.Io.Reader.Error!void {
    const buf_size = 512;

    var buf: [buf_size]u8 = undefined;
    var remaining = num_bytes;

    while (remaining > 0) {
        const amt = @min(remaining, buf_size);
        try reader.readSliceAll(buf[0..amt]);
        remaining -= amt;
    }
}

/// Pulled from old stdlib as this function has been removed.
fn readBytesNoEof(reader: *std.Io.Reader, comptime num_bytes: usize) std.Io.Reader.Error![num_bytes]u8 {
    var bytes: [num_bytes]u8 = undefined;
    try reader.readSliceAll(&bytes);
    return bytes;
}
