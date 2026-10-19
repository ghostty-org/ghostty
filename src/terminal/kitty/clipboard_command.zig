//! Kitty clipboard protocol (OSC 5522) request decoding.
//!
//! OSC 5522 format: `<OSC>5522;metadata;payload<ST>`
//!
//! Per the spec: "metadata is a colon separated list of key-value
//! pairs and payload is base64 encoded data."
//!
//! This contains the logic for parsing this.

const std = @import("std");
const Allocator = std.mem.Allocator;
const simd = @import("../../simd/main.zig");
const clipboard = @import("../clipboard.zig");
const protocol = @import("../osc/parsers/kitty_clipboard_protocol.zig");

const Operation = protocol.Operation;

/// Maximum id length, nothing specified but this is the limit used
/// in Kitty's source so we'll match it.
pub const max_id_len = 512;

/// Maximum decoded password length. Kitty has no limit. Passwords are
/// UUID-sized in practice so anything longer simply never matches a
/// stored grant anyway.
pub const max_pw_len = 128;

/// Maximum decoded MIME type length. Kitty has no limit but real MIME
/// types are tiny; anything longer drops the packet.
pub const max_mime_len = 256;

/// Maximum decoded name length. Kitty has no limit but names are shown
/// in permission prompts so anything longer drops the packet.
pub const max_name_len = 256;

/// The decoded, validated metadata of one OSC 5522 sequence.
///
/// All slice values are allocated from the allocator given to parse and
/// are sized to their contents. Callers are expected to pass an arena
/// scoped to handling the packet. There is no deinit.
pub const Metadata = struct {
    op: Operation,

    /// The clipboard this operation targets. Per the spec: "To read
    /// from the primary selection instead of the clipboard, add the
    /// key `loc=primary` to the metadata section." Any other value
    /// means the clipboard, so only standard and primary are possible
    /// here.
    loc: clipboard.Location = .standard,

    /// Sanitized id: invalid characters stripped, truncated to
    /// max_id_len. Empty means no id.
    id: []const u8 = "",

    /// Decoded mime metadata value. Empty means absent; kitty treats an
    /// empty mime the same as a missing one everywhere it matters (a
    /// wdata packet with either commits the transaction).
    mime: []const u8 = "",

    /// Decoded password. Empty means absent. Per the spec:
    /// "Specifying a password without a human friendly name is
    /// equivalent to not specifying a password and the terminal must
    /// treat the request as though it had no password."
    pw: []const u8 = "",

    /// Decoded human friendly name of the requesting program, shown in
    /// permission prompts. Empty means absent. Its presence opts into
    /// password grants.
    name: []const u8 = "",

    /// Parse the metadata field. The raw value is expected to be exactly
    /// the metadata (prefix and payload and separators stripped out).
    ///
    /// A null result means the packet should be silently dropped. An
    /// InvalidValue error means a decoded textual value was not valid
    /// UTF-8 or exceeded a local safety limit. Callers use the raw
    /// operation to decide whether that invalid value aborts an in-flight
    /// write transaction.
    pub fn parse(
        alloc: Allocator,
        raw: []const u8,
    ) error{ OutOfMemory, InvalidValue }!?Metadata {
        const fields = Raw.parse(raw) orelse return null;
        var result: Metadata = .{
            .op = Operation.init(fields.op orelse return null) orelse return null,
            .loc = if (std.mem.eql(u8, fields.loc, "primary"))
                .primary
            else
                .standard,
            .id = try sanitizeId(alloc, fields.id),
        };

        result.mime = decodeValue(
            alloc,
            fields.mime,
            max_mime_len,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Overflow,
            error.InvalidBase64,
            error.InvalidUtf8,
            => return error.InvalidValue,
        };
        result.pw = decodeValue(
            alloc,
            fields.pw,
            max_pw_len,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidBase64, error.InvalidUtf8 => return error.InvalidValue,
            // An over-long password behaves as if none was given: it can
            // never match a stored grant.
            error.Overflow => "",
        };
        result.name = decodeValue(
            alloc,
            fields.name,
            max_name_len,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Overflow,
            error.InvalidBase64,
            error.InvalidUtf8,
            => return error.InvalidValue,
        };
        return result;
    }

    /// Return the last recognized operation from syntactically valid raw
    /// metadata. This intentionally does not decode any values, so callers
    /// can still classify an InvalidValue parse error.
    pub fn operation(raw: []const u8) ?Operation {
        const fields = Raw.parse(raw) orelse return null;
        return Operation.init(fields.op orelse return null);
    }

    const Raw = struct {
        op: ?[]const u8 = null,
        loc: []const u8 = "",
        id: []const u8 = "",
        mime: []const u8 = "",
        pw: []const u8 = "",
        name: []const u8 = "",

        fn parse(raw: []const u8) ?Raw {
            var result: Raw = .{};

            // This visits every record even though an empty raw string
            // yields one empty record. Validating the complete structure
            // before decoding also ensures the last duplicate value wins.
            var it = std.mem.splitScalar(u8, raw, ':');
            while (it.next()) |record| {
                const eql_idx = std.mem.indexOfScalar(u8, record, '=') orelse return null;
                const key = record[0..eql_idx];
                const value = record[eql_idx + 1 ..];

                if (std.mem.eql(u8, key, "type")) {
                    result.op = value;
                } else if (std.mem.eql(u8, key, "loc")) {
                    result.loc = value;
                } else if (std.mem.eql(u8, key, "id")) {
                    result.id = value;
                } else if (std.mem.eql(u8, key, "mime")) {
                    result.mime = value;
                } else if (std.mem.eql(u8, key, "pw")) {
                    result.pw = value;
                } else if (std.mem.eql(u8, key, "name")) {
                    result.name = value;
                }
                // Unknown keys are ignored.
            }

            return result;
        }
    };

    /// Sanitize the ID according to the spec:
    ///
    /// Valid ids must include only characters from the set: [a-zA-Z0-9-_+.].
    /// Any other characters must be stripped out from the id by the terminal
    /// emulator before retransmitting it.
    fn sanitizeId(alloc: Allocator, value: []const u8) Allocator.Error![]const u8 {
        var list: std.ArrayListUnmanaged(u8) = .empty;
        defer list.deinit(alloc);
        for (value) |c| {
            switch (c) {
                'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '+', '.' => {},
                else => continue,
            }
            if (list.items.len >= max_id_len) break;
            try list.append(alloc, c);
        }
        return try list.toOwnedSlice(alloc);
    }

    /// Base64-decode a metadata value. Per the spec these values "are
    /// UTF-8 strings that are base64 encoded", so the decoded result
    /// must be valid UTF-8, and the encoding is strict RFC 4648 with
    /// required padding per the spec's "Encoding of payloads" section.
    fn decodeValue(alloc: Allocator, value: []const u8, max_len: usize) error{
        OutOfMemory,
        Overflow,
        InvalidBase64,
        InvalidUtf8,
    }![]const u8 {
        const Encoder = std.base64.standard.Encoder;

        // Avoid hostile large payloads.
        if (value.len > Encoder.calcSize(max_len)) return error.Overflow;

        // Decode
        const buf = try alloc.alloc(u8, simd.base64.maxLen(value));
        errdefer alloc.free(buf);
        const decoded = simd.base64.decodeStrict(
            value,
            buf,
            .required,
        ) catch return error.InvalidBase64;

        // Must be valid UTF-8
        if (!std.unicode.utf8ValidateSlice(decoded)) return error.InvalidUtf8;
        if (decoded.len > max_len) return error.Overflow;
        return decoded;
    }
};

/// A decoded base64 payload of one OSC 5522 sequence, e.g. the MIME
/// type list of a read request or the alias list of a walias packet.
/// The data slice aliases the allocated buf.
pub const Payload = struct {
    buf: []u8,
    data: []const u8,

    /// Decode a base64 payload into freshly allocated memory. The
    /// encoding is strict RFC 4648 with required padding per the
    /// spec's "Encoding of payloads" section; how an invalid payload
    /// is reported (or not) depends on the packet type.
    pub fn init(
        alloc: Allocator,
        payload: []const u8,
    ) error{ OutOfMemory, Invalid }!Payload {
        const buf = try alloc.alloc(u8, simd.base64.maxLen(payload));
        errdefer alloc.free(buf);
        const data = simd.base64.decodeStrict(
            payload,
            buf,
            .required,
        ) catch return error.Invalid;
        return .{ .buf = buf, .data = data };
    }

    pub fn deinit(self: *const Payload, alloc: Allocator) void {
        alloc.free(self.buf);
    }

    pub fn isValidUtf8(self: *const Payload) bool {
        return std.unicode.utf8ValidateSlice(self.data);
    }

    /// Iterate the whitespace-separated MIME types of the payload.
    /// Matches Python str.split() used by kitty.
    pub fn mimeIterator(self: *const Payload) std.mem.TokenIterator(u8, .any) {
        return std.mem.tokenizeAny(
            u8,
            self.data,
            &std.ascii.whitespace,
        );
    }
};

/// Whether a read request with this many data MIME types (the targets
/// type '.' excluded) is exempt from the user permission prompt.
pub fn readPromptExempt(data_mimes: usize) bool {
    return data_mimes == 0;
}

test "metadata: empty is dropped" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try Metadata.parse(arena.allocator(), "")) == null);
}

test "metadata: record without = is dropped" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try Metadata.parse(arena.allocator(), "type=read:bare")) == null);
    try testing.expect((try Metadata.parse(arena.allocator(), "bare:type=read")) == null);
}

test "metadata: missing or unknown type is dropped" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try Metadata.parse(arena.allocator(), "loc=primary")) == null);
    try testing.expect((try Metadata.parse(arena.allocator(), "type=bobr")) == null);
    try testing.expect((try Metadata.parse(arena.allocator(), "type=")) == null);
}

test "metadata: duplicate keys keep the last occurrence" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqual(
        Operation.read,
        (try Metadata.parse(arena.allocator(), "type=bobr:type=read")).?.op,
    );
    try testing.expect((try Metadata.parse(arena.allocator(), "type=read:type=bobr")) == null);
}

test "metadata: basic read" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const meta = (try Metadata.parse(arena.allocator(), "type=read")).?;
    try testing.expectEqual(Operation.read, meta.op);
    try testing.expect(meta.loc == .standard);
    try testing.expectEqual(@as(usize, 0), meta.id.len);
}

test "metadata: unknown keys ignored" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const meta = (try Metadata.parse(arena.allocator(), "type=read:bobr=kurwa")).?;
    try testing.expectEqual(Operation.read, meta.op);
}

test "metadata: loc" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try Metadata.parse(arena.allocator(), "type=read:loc=primary")).?.loc == .primary);
    // Anything other than "primary" means the clipboard; it is not an
    // error.
    try testing.expect((try Metadata.parse(arena.allocator(), "type=read:loc=bobr")).?.loc == .standard);
}

test "metadata: id sanitized" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    {
        const meta = (try Metadata.parse(arena.allocator(), "type=read:id=abc-123_x.Y+z")).?;
        try testing.expectEqualStrings("abc-123_x.Y+z", meta.id);
    }
    {
        // Invalid characters are stripped, not rejected.
        const meta = (try Metadata.parse(arena.allocator(), "type=read:id=*4 2*")).?;
        try testing.expectEqualStrings("42", meta.id);
    }
}

test "metadata: id truncated to max" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const raw = "type=read:id=" ++ "a" ** (max_id_len + 100);
    const meta = (try Metadata.parse(arena.allocator(), raw)).?;
    try testing.expectEqual(@as(usize, max_id_len), meta.id.len);
}

test "metadata: mime decoded" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // "text/plain"
    const meta = (try Metadata.parse(arena.allocator(), "type=wdata:mime=dGV4dC9wbGFpbg==")).?;
    try testing.expectEqualStrings("text/plain", meta.mime);
}

test "metadata: invalid mime base64 reported" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // Invalid base64 in a metadata value aborts an in-flight write
    // per the spec, so like invalid UTF-8 it is reported rather than
    // silently dropping the packet. Unpadded or whitespace-laced
    // values are invalid too: metadata values use the same strict
    // encoding as payloads.
    const cases = [_][]const u8{
        "type=wdata:mime=!!!",
        // "text/plain" without its padding.
        "type=wdata:mime=dGV4dC9wbGFpbg",
        // "text/plain" with its final byte replaced by '!'.
        "type=wdata:mime=dGV4dC9wbGFpbg=!",
        // A newline inside otherwise valid base64.
        "type=wdata:mime=dGV4dC9w\nbGFpbg==",
    };
    for (cases) |case| {
        try testing.expectError(
            error.InvalidValue,
            Metadata.parse(arena.allocator(), case),
        );
        try testing.expectEqual(
            Operation.wdata,
            Metadata.operation(case).?,
        );
    }
}

test "metadata: invalid mime utf8 reported" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // base64 of 0xff 0xfe
    try testing.expectError(
        error.InvalidValue,
        Metadata.parse(arena.allocator(), "type=wdata:mime=//4="),
    );
    try testing.expectEqual(
        Operation.wdata,
        Metadata.operation("type=wdata:mime=//4=").?,
    );
}

test "metadata: pw and name" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // pw="secret", name="app"
    const meta = (try Metadata.parse(arena.allocator(), "type=read:pw=c2VjcmV0:name=YXBw")).?;
    try testing.expectEqualStrings("secret", meta.pw);
    try testing.expectEqualStrings("app", meta.name);
}

test "metadata: over-long name reported" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const Encoder = std.base64.standard.Encoder;
    const long = "n" ** (max_name_len + 1);
    var buf: [Encoder.calcSize(long.len)]u8 = undefined;
    const raw = try std.mem.concat(arena.allocator(), u8, &.{
        "type=read:name=",
        Encoder.encode(&buf, long),
    });
    try testing.expectError(
        error.InvalidValue,
        Metadata.parse(arena.allocator(), raw),
    );
}

test "metadata: empty name" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const meta = (try Metadata.parse(arena.allocator(), "type=read:pw=c2VjcmV0:name=")).?;
    try testing.expectEqual(@as(usize, 0), meta.name.len);
}

test "read prompt exemption: only requests without data types" {
    const testing = std.testing;

    // A targets-only ('.') read parses to zero data MIME types and is
    // served without a prompt; any data type, even alongside the
    // targets listing, still prompts.
    try testing.expect(readPromptExempt(0));
    try testing.expect(!readPromptExempt(1));
}

test "payload: mime iterator" {
    const testing = std.testing;
    // base64 of "text/plain  text/html\ntext/uri-list"
    const payload = try Payload.init(
        testing.allocator,
        "dGV4dC9wbGFpbiAgdGV4dC9odG1sCnRleHQvdXJpLWxpc3Q=",
    );
    defer payload.deinit(testing.allocator);
    var it = payload.mimeIterator();
    try testing.expectEqualStrings("text/plain", it.next().?);
    try testing.expectEqualStrings("text/html", it.next().?);
    try testing.expectEqualStrings("text/uri-list", it.next().?);
    try testing.expect(it.next() == null);
}

test "payload: invalid base64" {
    const testing = std.testing;
    const cases = [_][]const u8{
        "!!!",
        // "text/plain" without its padding: payloads use the strict
        // encoding, so missing padding is rejected.
        "dGV4dC9wbGFpbg",
        // A newline inside otherwise valid base64.
        "dGV4dC9w\nbGFpbg==",
    };
    for (cases) |case| {
        try testing.expectError(
            error.Invalid,
            Payload.init(testing.allocator, case),
        );
    }
}

test "payload: decoded text must be valid utf8" {
    const testing = std.testing;
    // Valid base64 encoding of a single 0xff byte.
    const payload = try Payload.init(testing.allocator, "/w==");
    defer payload.deinit(testing.allocator);
    try testing.expect(!payload.isValidUtf8());
}
