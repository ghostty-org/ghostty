const std = @import("std");
const Terminator = @import("../osc.zig").Terminator;

/// The maximum raw bytes per base64-encoded chunk, chosen by kitty so a
/// chunk is exactly 4096 base64 characters (the protocol's chunk limit).
pub const max_chunk_raw = 3072;

/// The maximum bytes per plain-text (non-base64) chunk.
pub const max_chunk_plain = 4096;

/// Error names used in protocol error payloads. The wire encoding is
/// the tag name itself. This matches kitty's get_errno_name vocabulary,
/// which extends the spec's list with EISDIR, ENOSPC, and OK.
pub const Errno = enum {
    OK,
    EPERM,
    ENOENT,
    EIO,
    EINVAL,
    EMFILE,
    ENOMEM,
    EFBIG,
    EISDIR,
    ENOSPC,
    EUNKNOWN,
};

/// The payload encoding for a message.
pub const Encoding = enum {
    /// Payload bytes are sent as-is (MIME lists, error strings).
    plain,

    /// Payload bytes are base64-encoded (all binary data).
    base64,
};

/// The `x`/`y`/`Y` keys of the data request currently being answered,
/// echoed in responses and errors so the client can match them up. Only
/// non-zero keys are written, matching kitty's drop_append_request_keys.
pub const RequestKeys = struct {
    x: i32 = 0,
    y: i32 = 0,
    Y: i32 = 0,

    pub fn format(self: RequestKeys, writer: *std.Io.Writer) !void {
        if (self.x != 0) try writer.print(":x={d}", .{self.x});
        if (self.y != 0) try writer.print(":y={d}", .{self.y});
        if (self.Y != 0) try writer.print(":Y={d}", .{self.Y});
    }
};

/// Encode a complete protocol message: one bare OSC when `data` is
/// empty, otherwise one complete OSC per chunk of `data`, each
/// repeating the header. The final chunk carries `m=0`, earlier
/// chunks `m=1`.
///
/// `header` is the metadata without the OSC introducer, e.g. "t=q" or
/// "t=m:x=5:y=3". The client ID is appended as `:i=N` when non-zero.
pub fn encode(
    writer: *std.Io.Writer,
    header: []const u8,
    client_id: u32,
    data: []const u8,
    encoding: Encoding,
    terminator: Terminator,
) std.Io.Writer.Error!void {
    // The client ID is part of the repeated header.
    var id_buf: [16]u8 = undefined;
    const id: []const u8 = if (client_id != 0) std.fmt.bufPrint(
        &id_buf,
        ":i={d}",
        .{client_id},
    ) catch unreachable else "";

    if (data.len == 0) {
        try writer.print("\x1b]72;{s}{s}{s}", .{
            header,
            id,
            terminator.string(),
        });
        return;
    }

    const limit: usize = switch (encoding) {
        .base64 => max_chunk_raw,
        .plain => max_chunk_plain,
    };

    var offset: usize = 0;
    while (offset < data.len) {
        const chunk_len = @min(data.len - offset, limit);
        const chunk = data[offset .. offset + chunk_len];
        offset += chunk_len;
        const last: u8 = if (offset >= data.len) '0' else '1';

        try writer.print("\x1b]72;{s}{s}:m={c};", .{ header, id, last });
        switch (encoding) {
            .plain => try writer.writeAll(chunk),
            .base64 => {
                var b64_buf: [std.base64.standard.Encoder.calcSize(max_chunk_raw)]u8 = undefined;
                try writer.writeAll(std.base64.standard.Encoder.encode(
                    &b64_buf,
                    chunk,
                ));
            },
        }
        try writer.writeAll(terminator.string());
    }
}

/// Encode an error response. `kind` selects the header: t=R for drop
/// data request errors, t=E for drag offer errors. The payload is
/// "NAME" or "NAME:description", sent plain (not base64).
pub fn encodeError(
    writer: *std.Io.Writer,
    kind: enum { drop, drag },
    keys: RequestKeys,
    client_id: u32,
    errno: Errno,
    desc: []const u8,
    terminator: Terminator,
) std.Io.Writer.Error!void {
    var header_buf: [64]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "t={c}{f}", .{
        @as(u8, switch (kind) {
            .drop => 'R',
            .drag => 'E',
        }),
        keys,
    }) catch unreachable;

    // Description strings are short static messages; size the buffer
    // for the longest error name plus a generous description.
    var payload_buf: [256]u8 = undefined;
    const payload = if (desc.len > 0) std.fmt.bufPrint(
        &payload_buf,
        "{t}:{s}",
        .{ errno, desc },
    ) catch unreachable else @tagName(errno);

    try encode(writer, header, client_id, payload, .plain, terminator);
}

test "encode: bare message" {
    const testing = std.testing;
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try encode(&writer, "t=q", 0, "", .plain, .st);
    try testing.expectEqualStrings("\x1b]72;t=q\x1b\\", writer.buffered());
}

test "encode: bare message with client id" {
    const testing = std.testing;
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try encode(&writer, "t=q", 7, "", .plain, .st);
    try testing.expectEqualStrings("\x1b]72;t=q:i=7\x1b\\", writer.buffered());
}

test "encode: plain payload single chunk" {
    const testing = std.testing;
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try encode(&writer, "t=m:x=1:y=2", 0, "text/plain ", .plain, .st);
    try testing.expectEqualStrings(
        "\x1b]72;t=m:x=1:y=2:m=0;text/plain \x1b\\",
        writer.buffered(),
    );
}

test "encode: base64 payload chunking" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();

    // Exactly one byte more than a chunk to force two chunks.
    const data = [_]u8{'A'} ** (max_chunk_raw + 1);
    try encode(&aw.writer, "t=r:x=1", 3, &data, .base64, .st);

    const out = aw.written();

    // First chunk: full header, m=1, 4096 base64 chars.
    const prefix = "\x1b]72;t=r:x=1:i=3:m=1;";
    try testing.expect(std.mem.startsWith(u8, out, prefix));
    const first_end = std.mem.indexOf(u8, out, "\x1b\\").?;
    try testing.expectEqual(@as(usize, prefix.len + 4096), first_end);

    // Second chunk: m=0 with the single remaining byte.
    const rest = out[first_end + 2 ..];
    try testing.expect(std.mem.startsWith(u8, rest, "\x1b]72;t=r:x=1:i=3:m=0;"));

    // Decodes back to the original data.
    var decoded: std.ArrayList(u8) = .empty;
    defer decoded.deinit(alloc);
    var it = std.mem.splitSequence(u8, out, "\x1b\\");
    while (it.next()) |osc| {
        if (osc.len == 0) continue;
        const payload_start = std.mem.indexOfScalar(u8, osc, ';').?;
        const payload = osc[std.mem.indexOfScalarPos(u8, osc, payload_start + 1, ';').? + 1 ..];
        const n = try std.base64.standard.Decoder.calcSizeForSlice(payload);
        const start = decoded.items.len;
        try decoded.resize(alloc, start + n);
        try std.base64.standard.Decoder.decode(decoded.items[start..], payload);
    }
    try testing.expectEqualSlices(u8, &data, decoded.items);
}

test "encodeError: with and without description" {
    const testing = std.testing;
    var buf: [256]u8 = undefined;

    {
        var writer: std.Io.Writer = .fixed(&buf);
        try encodeError(&writer, .drop, .{ .x = 2 }, 0, .ENOENT, "drop data request index out of bounds", .st);
        try testing.expectEqualStrings(
            "\x1b]72;t=R:x=2:m=0;ENOENT:drop data request index out of bounds\x1b\\",
            writer.buffered(),
        );
    }
    {
        var writer: std.Io.Writer = .fixed(&buf);
        try encodeError(&writer, .drag, .{}, 5, .EPERM, "", .st);
        try testing.expectEqualStrings(
            "\x1b]72;t=E:i=5:m=0;EPERM\x1b\\",
            writer.buffered(),
        );
    }
}

test "RequestKeys: only non-zero keys written" {
    const testing = std.testing;
    var buf: [64]u8 = undefined;

    {
        const s = try std.fmt.bufPrint(&buf, "{f}", .{RequestKeys{}});
        try testing.expectEqualStrings("", s);
    }
    {
        const s = try std.fmt.bufPrint(&buf, "{f}", .{RequestKeys{ .x = 1, .y = 2, .Y = 3 }});
        try testing.expectEqualStrings(":x=1:y=2:Y=3", s);
    }
    {
        const s = try std.fmt.bufPrint(&buf, "{f}", .{RequestKeys{ .Y = 4 }});
        try testing.expectEqualStrings(":Y=4", s);
    }
}
