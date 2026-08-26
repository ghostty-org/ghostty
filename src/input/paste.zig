const std = @import("std");
const Terminal = @import("../terminal/Terminal.zig");

/// The bracketed paste (mode 2004) frame written around the data.
pub const bracketed_prefix = "\x1b[200~";
pub const bracketed_suffix = "\x1b[201~";

/// The maximum number of bytes `encode` adds around the data, so callers
/// can size a buffer for the full encoded result.
pub const max_frame_size = bracketed_prefix.len + bracketed_suffix.len;

pub const Options = struct {
    /// True if bracketed paste mode is on.
    bracketed: bool,

    /// Return the encoding options based on the current terminal state.
    pub fn fromTerminal(t: *const Terminal) Options {
        return .{
            .bracketed = t.modes.get(.bracketed_paste),
        };
    }
};

/// Encode the given data for pasting. The resulting value can be written
/// to the pty to perform a paste of the input data.
///
/// The data can be either a `[]u8` or a `[]const u8`. If the data
/// type is const then `EncodeError` may be returned. If the data type
/// is mutable then this function can't return an error.
///
/// This slightly complex calling style allows for initially const
/// data to be passed in without an allocation, since it is rare in normal
/// use cases that the data will need to be modified. In the unlikely case
/// data does need to be modified, the caller can make a mutable copy
/// after seeing the error.
///
/// The data is returned as a set of slices to limit allocations. The caller
/// can combine the slices into a single buffer if desired.
///
/// WARNING: The input data is not checked for safety. See the `isSafe`
/// function to check if the data is safe to paste.
pub fn encode(
    data: anytype,
    opts: Options,
) switch (@TypeOf(data)) {
    []u8 => [3][]const u8,
    []const u8 => Error![3][]const u8,
    else => unreachable,
} {
    // These are the set of byte values that are always replaced by
    // a space (per xterm's behavior) for any text insertion method e.g.
    // a paste, drag and drop, etc. These are copied directly from xterm's
    // source.
    const strip: []const u8 = &.{
        0x00, // NUL
        0x08, // BS
        0x05, // ENQ
        0x04, // EOT
        0x1B, // ESC
        0x7F, // DEL

        // These can be overridden by the running terminal program
        // via tcsetattr, so they aren't totally safe to hardcode like
        // this. In practice, I haven't seen modern programs change these
        // and its a much bigger architectural change to pass these through
        // so for now they're hardcoded.
        0x03, // VINTR (Ctrl+C)
        0x1C, // VQUIT (Ctrl+\)
        0x15, // VKILL (Ctrl+U)
        0x1A, // VSUSP (Ctrl+Z)
        0x11, // VSTART (Ctrl+Q)
        0x13, // VSTOP (Ctrl+S)
        0x17, // VWERASE (Ctrl+W)
        0x16, // VLNEXT (Ctrl+V)
        0x12, // VREPRINT (Ctrl+R)
        0x0F, // VDISCARD (Ctrl+O)
    };

    const mutable = @TypeOf(data) == []u8;

    var result: [3][]const u8 = .{ "", data, "" };

    // If we have any of the strip values, then we need to replace them
    // with spaces. This is what xterm does and it does it regardless
    // of bracketed paste mode. This is a security measure to prevent pastes
    // from containing bytes that could be used to inject commands.
    if (std.mem.indexOfAny(u8, data, strip) != null) {
        if (comptime !mutable) return Error.MutableRequired;
        var offset: usize = 0;
        while (std.mem.indexOfAny(
            u8,
            data[offset..],
            strip,
        )) |idx| {
            offset += idx;
            data[offset] = ' ';
            offset += 1;
        }
    }

    // Bracketed paste mode (mode 2004) wraps pasted data in
    // fenceposts so that the terminal can ignore things like newlines.
    if (opts.bracketed) {
        result[0] = bracketed_prefix;
        result[2] = bracketed_suffix;
        return result;
    }

    // Non-bracketed. We have to replace newline with `\r`. This matches
    // the behavior of xterm and other terminals. For `\r\n` this will
    // result in `\r\r` which does match xterm.
    if (comptime mutable) {
        std.mem.replaceScalar(u8, data, '\n', '\r');
    } else if (std.mem.indexOfScalar(u8, data, '\n') != null) {
        return Error.MutableRequired;
    }

    return result;
}

pub const Error = error{
    /// Returned if encoding requires a mutable copy of the data. This
    /// can only be returned if the input data type is const.
    MutableRequired,
};

/// Encode the given data for pasting directly into a writer. This is
/// the same transformation as `encode` (unsafe bytes replaced, bracketed
/// frame or newline conversion per `opts`) but the data is copied
/// exactly once: into the writer's buffer, where it is modified in place.
/// This is the form to use when the data is const and the result is
/// being assembled into a single buffer anyway.
///
/// The data is copied in chunks sized to the writer's buffer, so any
/// writer works; a writer with less total capacity than the writer
/// needs to hold at once reports `error.WriteFailed` as usual.
///
/// WARNING: The input data is not checked for safety. See `isSafe`
/// and `isSafeWith` to check if the data is safe to paste.
pub fn encodeWriter(
    writer: *std.Io.Writer,
    data: []const u8,
    opts: Options,
) std.Io.Writer.Error!void {
    if (opts.bracketed) try writer.writeAll(bracketed_prefix);

    // The byte transformations are position-independent, so the data
    // can be copied and encoded chunk by chunk. The frame returned by
    // encode is ignored since it's written around the whole data here.
    var remaining = data;
    while (remaining.len > 0) {
        const dest = try writer.writableSliceGreedy(1);
        const n = @min(dest.len, remaining.len);
        @memcpy(dest[0..n], remaining[0..n]);
        _ = encode(dest[0..n], opts);
        writer.advance(n);
        remaining = remaining[n..];
    }

    if (opts.bracketed) try writer.writeAll(bracketed_suffix);
}

/// Returns true if the data looks safe to paste. Data is considered
/// unsafe if it contains any of the following:
///
/// - `\n`: Newlines can be used to inject commands.
/// - `\x1b[201~`: This is the end of a bracketed paste. This cane be used
///   to exit a bracketed paste and inject commands.
///
/// We consider any scenario unsafe regardless of current terminal state.
/// For example, even if bracketed paste mode is not active, we still
/// consider `\x1b[201~` unsafe. The existence of these types of bytes
/// should raise suspicion that the producer of the paste data is
/// acting strangely.
pub fn isSafe(data: []const u8) bool {
    return std.mem.indexOf(u8, data, "\n") == null and
        std.mem.indexOf(u8, data, "\x1b[201~") == null;
}

/// Returns true if the data looks safe to paste given how it will be
/// encoded. This is the terminal-state-aware counterpart of `isSafe`:
///
/// - Bracketed (mode 2004 on): the program receives the data as one
///   framed unit, so newlines are fine. The data is unsafe only if it
///   contains the end of the frame (`\x1b[201~`), which would let the
///   rest of the data escape the frame and inject commands.
/// - Unbracketed: the same rule as `isSafe`.
///
/// Callers wanting the conservative rule regardless of terminal state
/// should use `isSafe` instead.
pub fn isSafeWith(data: []const u8, opts: Options) bool {
    if (opts.bracketed) return std.mem.indexOf(u8, data, bracketed_suffix) == null;
    return isSafe(data);
}

test isSafe {
    const testing = std.testing;
    try testing.expect(isSafe("hello"));
    try testing.expect(!isSafe("hello\n"));
    try testing.expect(!isSafe("hello\nworld"));
    try testing.expect(!isSafe("he\x1b[201~llo"));
}

test isSafeWith {
    const testing = std.testing;

    // Bracketed: newlines are fine, the frame terminator is not.
    try testing.expect(isSafeWith("hello", .{ .bracketed = true }));
    try testing.expect(isSafeWith("hello\nworld", .{ .bracketed = true }));
    try testing.expect(!isSafeWith("he\x1b[201~llo", .{ .bracketed = true }));
    try testing.expect(!isSafeWith("hello\n\x1b[201~", .{ .bracketed = true }));

    // Unbracketed: the conservative rule.
    try testing.expect(isSafeWith("hello", .{ .bracketed = false }));
    try testing.expect(!isSafeWith("hello\nworld", .{ .bracketed = false }));
    try testing.expect(!isSafeWith("he\x1b[201~llo", .{ .bracketed = false }));
}

test "encodeWriter bracketed" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try encodeWriter(&writer, "hel\x1blo\nworld", .{ .bracketed = true });
    try testing.expectEqualStrings("\x1b[200~hel lo\nworld\x1b[201~", writer.buffered());
}

test "encodeWriter unbracketed" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try encodeWriter(&writer, "hel\x00lo\r\nworld", .{ .bracketed = false });
    try testing.expectEqualStrings("hel lo\r\rworld", writer.buffered());
}

test "encodeWriter empty" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try encodeWriter(&writer, "", .{ .bracketed = true });
    try testing.expectEqualStrings("\x1b[200~\x1b[201~", writer.buffered());
    writer = .fixed(&buf);
    try encodeWriter(&writer, "", .{ .bracketed = false });
    try testing.expectEqualStrings("", writer.buffered());
}

test "encodeWriter chunks through a small writer buffer" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // A writer with a 4-byte staging buffer that drains into a list,
    // so the data is copied and encoded in several chunks.
    const Sink = struct {
        list: std.ArrayList(u8) = .empty,
        writer: std.Io.Writer,

        fn drain(
            w: *std.Io.Writer,
            data: []const []const u8,
            splat: usize,
        ) std.Io.Writer.Error!usize {
            const self: *@This() = @alignCast(@fieldParentPtr("writer", w));
            self.list.appendSlice(testing.allocator, w.buffered()) catch return error.WriteFailed;
            w.end = 0;
            var n: usize = 0;
            for (data[0 .. data.len - 1]) |slice| {
                self.list.appendSlice(testing.allocator, slice) catch return error.WriteFailed;
                n += slice.len;
            }
            for (0..splat) |_| {
                self.list.appendSlice(testing.allocator, data[data.len - 1]) catch return error.WriteFailed;
            }
            return n + splat * data[data.len - 1].len;
        }
    };

    var staging: [4]u8 = undefined;
    var sink: Sink = .{ .writer = .{
        .buffer = &staging,
        .vtable = &.{ .drain = Sink.drain },
    } };
    defer sink.list.deinit(alloc);

    const data = "line one\nline\x1btwo\nline three\n";
    try encodeWriter(&sink.writer, data, .{ .bracketed = true });
    try sink.writer.flush();
    try testing.expectEqualStrings(
        "\x1b[200~line one\nline two\nline three\n\x1b[201~",
        sink.list.items,
    );
}

test "encodeWriter too small" {
    const testing = std.testing;
    var buf: [4]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try testing.expectError(
        error.WriteFailed,
        encodeWriter(&writer, "hello", .{ .bracketed = true }),
    );
}

test max_frame_size {
    const testing = std.testing;
    const result = try encode(@as([]const u8, ""), .{ .bracketed = true });
    try testing.expectEqual(max_frame_size, result[0].len + result[2].len);
}

test "encode bracketed" {
    const testing = std.testing;
    const result = try encode(
        @as([]const u8, "hello"),
        .{ .bracketed = true },
    );
    try testing.expectEqualStrings("\x1b[200~", result[0]);
    try testing.expectEqualStrings("hello", result[1]);
    try testing.expectEqualStrings("\x1b[201~", result[2]);
}

test "encode unbracketed no newlines" {
    const testing = std.testing;
    const result = try encode(
        @as([]const u8, "hello"),
        .{ .bracketed = false },
    );
    try testing.expectEqualStrings("", result[0]);
    try testing.expectEqualStrings("hello", result[1]);
    try testing.expectEqualStrings("", result[2]);
}

test "encode unbracketed newlines const" {
    const testing = std.testing;
    try testing.expectError(Error.MutableRequired, encode(
        @as([]const u8, "hello\nworld"),
        .{ .bracketed = false },
    ));
}

test "encode unbracketed newlines" {
    const testing = std.testing;
    const data: []u8 = try testing.allocator.dupe(u8, "hello\nworld");
    defer testing.allocator.free(data);
    const result = encode(data, .{ .bracketed = false });
    try testing.expectEqualStrings("", result[0]);
    try testing.expectEqualStrings("hello\rworld", result[1]);
    try testing.expectEqualStrings("", result[2]);
}

test "encode unbracketed windows-stye newline" {
    const testing = std.testing;
    const data: []u8 = try testing.allocator.dupe(u8, "hello\r\nworld");
    defer testing.allocator.free(data);
    const result = encode(data, .{ .bracketed = false });
    try testing.expectEqualStrings("", result[0]);
    try testing.expectEqualStrings("hello\r\rworld", result[1]);
    try testing.expectEqualStrings("", result[2]);
}

test "encode strip unsafe bytes const" {
    const testing = std.testing;
    try testing.expectError(Error.MutableRequired, encode(
        @as([]const u8, "hello\x00world"),
        .{ .bracketed = true },
    ));
}

test "encode strip unsafe bytes mutable bracketed" {
    const testing = std.testing;
    const data: []u8 = try testing.allocator.dupe(u8, "hel\x1blo\x00world");
    defer testing.allocator.free(data);
    const result = encode(data, .{ .bracketed = true });
    try testing.expectEqualStrings("\x1b[200~", result[0]);
    try testing.expectEqualStrings("hel lo world", result[1]);
    try testing.expectEqualStrings("\x1b[201~", result[2]);
}

test "encode strip unsafe bytes mutable unbracketed" {
    const testing = std.testing;
    const data: []u8 = try testing.allocator.dupe(u8, "hel\x03lo");
    defer testing.allocator.free(data);
    const result = encode(data, .{ .bracketed = false });
    try testing.expectEqualStrings("", result[0]);
    try testing.expectEqualStrings("hel lo", result[1]);
    try testing.expectEqualStrings("", result[2]);
}

test "encode strip multiple unsafe bytes" {
    const testing = std.testing;
    const data: []u8 = try testing.allocator.dupe(u8, "\x00\x08\x7f");
    defer testing.allocator.free(data);
    const result = encode(data, .{ .bracketed = true });
    try testing.expectEqualStrings("   ", result[1]);
}
