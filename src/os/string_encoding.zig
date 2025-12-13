const std = @import("std");

/// Do an in-place decode of a string that has been encoded in the same way
/// that `bash`'s `printf %q` encodes a string. This is safe because a string
/// can only get shorter after decoding. This destructively modifies the buffer
/// given to it. If an error is returned the buffer may be in an unusable state.
pub fn printfQDecode(buf: [:0]u8) error{DecodeError}![:0]const u8 {
    const data: [:0]u8 = data: {
        // Strip off `$''` quoting.
        if (std.mem.startsWith(u8, buf, "$'")) {
            if (buf.len < 3 or !std.mem.endsWith(u8, buf, "'")) return error.DecodeError;
            buf[buf.len - 1] = 0;
            break :data buf[2 .. buf.len - 1 :0];
        }
        // Strip off `''` quoting.
        if (std.mem.startsWith(u8, buf, "'")) {
            if (buf.len < 2 or !std.mem.endsWith(u8, buf, "'")) return error.DecodeError;
            buf[buf.len - 1] = 0;
            break :data buf[1 .. buf.len - 1 :0];
        }
        break :data buf;
    };

    var src: usize = 0;
    var dst: usize = 0;

    while (src < data.len) {
        switch (data[src]) {
            else => {
                data[dst] = data[src];
                src += 1;
                dst += 1;
            },
            '\\' => {
                if (src + 1 >= data.len) return error.DecodeError;
                switch (data[src + 1]) {
                    ' ',
                    '\\',
                    '"',
                    '\'',
                    '$',
                    => |c| {
                        data[dst] = c;
                        src += 2;
                        dst += 1;
                    },
                    'e' => {
                        data[dst] = std.ascii.control_code.esc;
                        src += 2;
                        dst += 1;
                    },
                    'n' => {
                        data[dst] = std.ascii.control_code.lf;
                        src += 2;
                        dst += 1;
                    },
                    'r' => {
                        data[dst] = std.ascii.control_code.cr;
                        src += 2;
                        dst += 1;
                    },
                    't' => {
                        data[dst] = std.ascii.control_code.ht;
                        src += 2;
                        dst += 1;
                    },
                    'v' => {
                        data[dst] = std.ascii.control_code.vt;
                        src += 2;
                        dst += 1;
                    },
                    else => return error.DecodeError,
                }
            },
        }
    }

    data[dst] = 0;
    return data[0..dst :0];
}

test "printf_q 1" {
    const s: [:0]const u8 = "bobr\\ kurwa";
    var src: [s.len:0]u8 = undefined;
    @memcpy(&src, s);
    const dst = try printfQDecode(&src);
    try std.testing.expectEqualStrings("bobr kurwa", dst);
}

test "printf_q 2" {
    const s: [:0]const u8 = "bobr\\nkurwa";
    var src: [s.len:0]u8 = undefined;
    @memcpy(&src, s);
    const dst = try printfQDecode(&src);
    try std.testing.expectEqualStrings("bobr\nkurwa", dst);
}

test "printf_q 3" {
    const s: [:0]const u8 = "bobr\\dkurwa";
    var src: [s.len:0]u8 = undefined;
    @memcpy(&src, s);
    try std.testing.expectError(error.DecodeError, printfQDecode(&src));
}

test "printf_q 4" {
    const s: [:0]const u8 = "bobr kurwa\\";
    var src: [s.len:0]u8 = undefined;
    @memcpy(&src, s);
    try std.testing.expectError(error.DecodeError, printfQDecode(&src));
}

test "printf_q 5" {
    const s: [:0]const u8 = "$'bobr kurwa'";
    var src: [s.len:0]u8 = undefined;
    @memcpy(&src, s);
    const dst = try printfQDecode(&src);
    try std.testing.expectEqualStrings("bobr kurwa", dst);
}

test "printf_q 6" {
    const s: [:0]const u8 = "'bobr kurwa'";
    var src: [s.len:0]u8 = undefined;
    @memcpy(&src, s);
    const dst = try printfQDecode(&src);
    try std.testing.expectEqualStrings("bobr kurwa", dst);
}

test "printf_q 7" {
    const s: [:0]const u8 = "$'bobr kurwa";
    var src: [s.len:0]u8 = undefined;
    @memcpy(&src, s);
    try std.testing.expectError(error.DecodeError, printfQDecode(&src));
}

test "printf_q 8" {
    const s: [:0]const u8 = "$'";
    var src: [s.len:0]u8 = undefined;
    @memcpy(&src, s);
    try std.testing.expectError(error.DecodeError, printfQDecode(&src));
}

test "printf_q 9" {
    const s: [:0]const u8 = "'bobr kurwa";
    var src: [s.len:0]u8 = undefined;
    @memcpy(&src, s);
    try std.testing.expectError(error.DecodeError, printfQDecode(&src));
}

test "printf_q 10" {
    const s: [:0]const u8 = "'";
    var src: [s.len:0]u8 = undefined;
    @memcpy(&src, s);
    try std.testing.expectError(error.DecodeError, printfQDecode(&src));
}

/// Do an in-place decode of a string that has been URL percent encoded.
/// This is safe because a string can only get shorter after decoding. This
/// destructively modifies the buffer given to it. If an error is returned the
/// buffer may be in an unusable state.
pub fn urlPercentDecode(buf: [:0]u8) error{DecodeError}![:0]const u8 {
    var src: usize = 0;
    var dst: usize = 0;
    while (src < buf.len) {
        switch (buf[src]) {
            else => {
                buf[dst] = buf[src];
                src += 1;
                dst += 1;
            },
            '%' => {
                if (src + 2 >= buf.len) return error.DecodeError;
                switch (buf[src + 1]) {
                    '0'...'9', 'a'...'f', 'A'...'F' => {
                        switch (buf[src + 2]) {
                            '0'...'9', 'a'...'f', 'A'...'F' => {
                                buf[dst] = std.math.shl(u8, hex(buf[src + 1]), 4) | hex(buf[src + 2]);
                                src += 3;
                                dst += 1;
                            },
                            else => return error.DecodeError,
                        }
                    },
                    else => return error.DecodeError,
                }
            },
        }
    }
    buf[dst] = 0;
    return buf[0..dst :0];
}

inline fn hex(c: u8) u4 {
    switch (c) {
        '0'...'9' => return @truncate(c - '0'),
        'a'...'f' => return @truncate(c - 'a' + 10),
        'A'...'F' => return @truncate(c - 'A' + 10),
        else => unreachable,
    }
}

test "singles percent" {
    for (0..255) |c| {
        var buf_: [4]u8 = undefined;
        const buf = try std.fmt.bufPrintZ(&buf_, "%{x:0>2}", .{c});
        const decoded = try urlPercentDecode(buf);
        try std.testing.expectEqual(1, decoded.len);
        try std.testing.expectEqual(c, decoded[0]);
    }
    for (0..255) |c| {
        var buf_: [4]u8 = undefined;
        const buf = try std.fmt.bufPrintZ(&buf_, "%{X:0>2}", .{c});
        const decoded = try urlPercentDecode(buf);
        try std.testing.expectEqual(1, decoded.len);
        try std.testing.expectEqual(c, decoded[0]);
    }
}

test "percent 1" {
    const s: [:0]const u8 = "bobr%20kurwa";
    var src: [s.len:0]u8 = undefined;
    @memcpy(&src, s);
    const dst = try urlPercentDecode(&src);
    try std.testing.expectEqualStrings("bobr kurwa", dst);
}

test "percent 2" {
    const s: [:0]const u8 = "bobr%2kurwa";
    var src: [s.len:0]u8 = undefined;
    @memcpy(&src, s);
    try std.testing.expectError(error.DecodeError, urlPercentDecode(&src));
}

test "percent 3" {
    const s: [:0]const u8 = "bobr%kurwa";
    var src: [s.len:0]u8 = undefined;
    @memcpy(&src, s);
    try std.testing.expectError(error.DecodeError, urlPercentDecode(&src));
}

test "percent 4" {
    const s: [:0]const u8 = "bobr%%kurwa";
    var src: [s.len:0]u8 = undefined;
    @memcpy(&src, s);
    try std.testing.expectError(error.DecodeError, urlPercentDecode(&src));
}

test "percent 5" {
    const s: [:0]const u8 = "bobr%20kurwa%20";
    var src: [s.len:0]u8 = undefined;
    @memcpy(&src, s);
    const dst = try urlPercentDecode(&src);
    try std.testing.expectEqualStrings("bobr kurwa ", dst);
}

test "percent 6" {
    const s: [:0]const u8 = "bobr%20kurwa%2";
    var src: [s.len:0]u8 = undefined;
    @memcpy(&src, s);
    try std.testing.expectError(error.DecodeError, urlPercentDecode(&src));
}

test "percent 7" {
    const s: [:0]const u8 = "bobr%20kurwa%";
    var src: [s.len:0]u8 = undefined;
    @memcpy(&src, s);
    try std.testing.expectError(error.DecodeError, urlPercentDecode(&src));
}

/// Is the given character valid in URI percent encoding?
fn isValidChar(c: u8) bool {
    return switch (c) {
        ' ', ';', '=' => false,
        else => return std.ascii.isPrint(c),
    };
}

/// Write data to the writer after URI percent encoding.
pub fn urlPercentEncode(writer: *std.Io.Writer, data: []const u8) std.Io.Writer.Error!void {
    try std.Uri.Component.percentEncode(writer, data, isValidChar);
}
