const std = @import("std");

/// Parse a string literal into a byte array. The string can contain
/// any valid Zig string literal escape sequences.
///
/// The output buffer never needs to be larger than the input buffer.
/// The buffers may alias.
pub fn parse(out: []u8, bytes: []const u8) ![]u8 {
    var dst_i: usize = 0;
    var src_i: usize = 0;
    while (src_i < bytes.len) {
        if (dst_i >= out.len) return error.OutOfMemory;

        // If this byte is not beginning an escape sequence we copy.
        const b = bytes[src_i];
        if (b != '\\') {
            out[dst_i] = b;
            dst_i += 1;
            src_i += 1;
            continue;
        }

        // Parse the escape sequence
        switch (std.zig.string_literal.parseEscapeSequence(
            bytes,
            &src_i,
        )) {
            .failure => return error.InvalidString,
            .success => |cp| dst_i += try std.unicode.utf8Encode(
                cp,
                out[dst_i..],
            ),
        }
    }

    return out[0..dst_i];
}

test "parse: empty" {
    const testing = std.testing;

    var buf: [128]u8 = undefined;
    const result = try parse(&buf, "");
    try testing.expectEqualStrings("", result);
}

test "parse: no escapes" {
    const testing = std.testing;

    var buf: [128]u8 = undefined;
    const result = try parse(&buf, "hello world");
    try testing.expectEqualStrings("hello world", result);
}

test "parse: escapes" {
    const testing = std.testing;

    var buf: [128]u8 = undefined;
    {
        const result = try parse(&buf, "hello\\nworld");
        try testing.expectEqualStrings("hello\nworld", result);
    }
    {
        const result = try parse(&buf, "hello\\u{1F601}world");
        try testing.expectEqualStrings("hello\u{1F601}world", result);
    }
}
