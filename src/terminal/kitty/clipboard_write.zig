//! Kitty clipboard protocol (OSC 5522) write transactions: the
//! stateful accumulation of wdata chunks and walias aliases until the
//! commit packet arrives. See clipboard.zig for the protocol overview.

const std = @import("std");
const assert = @import("../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const simd = @import("../../simd/main.zig");
const clipboard = @import("../clipboard.zig");
const clipboard_command = @import("clipboard_command.zig");

const Metadata = clipboard_command.Metadata;
const Payload = clipboard_command.Payload;
const max_mime_len = clipboard_command.max_mime_len;

const log = std.log.scoped(.kitty_clipboard);

/// Default maximum total decoded bytes accumulated by one write
/// transaction. Embedders can override this per-transaction via
/// WriteState.Options (Ghostty exposes it as the
/// `clipboard-write-limit-bytes` configuration).
pub const max_write_size = 64 * 1024 * 1024;

/// Maximum MIME types and aliases per write transaction.
pub const max_write_mimes = 64;
pub const max_write_aliases = 64;

/// One MIME representation of committed clipboard data. This is the
/// same type the clipboard write effect consumes so committed contents
/// can be passed through directly.
pub const Content = clipboard.Content;

/// The state of one in-flight write transaction: a single `type=write`
/// plus all the `wdata` chunks and `walias` aliases until completion
/// or error.
pub const WriteState = struct {
    arena: std.heap.ArenaAllocator,
    loc: clipboard.Location,
    id: []const u8,
    pw: []const u8,
    name: []const u8,
    spool: std.ArrayListUnmanaged(u8) = .empty,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    aliases: std.ArrayListUnmanaged(Alias) = .empty,

    /// Maximum total decoded bytes this transaction will accumulate.
    /// Captured at init so a change to the configured limit doesn't
    /// apply to a transaction already in flight.
    max_size: usize,

    /// Index into entries currently receiving data.
    current: ?usize = null,

    /// Decodes the concatenated payload stream of the entry currently
    /// receiving data. Per the spec's "Encoding of payloads" section,
    /// individual wdata packet payloads split one base64 stream at
    /// arbitrary boundaries; only the concatenation per MIME type must
    /// be valid, correctly padded base64.
    decoder: simd.base64.Streaming = .{},

    pub const Options = struct {
        /// Maximum total decoded bytes accumulated by the transaction.
        max_size: usize = max_write_size,
    };

    const Entry = struct {
        /// Owned by the transaction arena.
        mime: []const u8,
        start: usize = 0,
        len: usize = 0,
    };

    const Alias = struct {
        /// Owned by the transaction arena.
        alias: []const u8,
        target: []const u8,
    };

    /// Begin a transaction from a type=write packet.
    pub fn init(
        alloc: Allocator,
        meta: *const Metadata,
        opts: Options,
    ) Allocator.Error!WriteState {
        assert(meta.op == .write);
        var arena: std.heap.ArenaAllocator = .init(alloc);
        errdefer arena.deinit();
        const id = try arena.allocator().dupe(u8, meta.id);
        const pw = try arena.allocator().dupe(u8, meta.pw);
        const name = try arena.allocator().dupe(u8, meta.name);
        return .{
            .arena = arena,
            .loc = meta.loc,
            .id = id,
            .pw = pw,
            .name = name,
            .max_size = opts.max_size,
        };
    }

    pub fn deinit(self: *WriteState, alloc: Allocator) void {
        self.spool.deinit(alloc);
        self.entries.deinit(alloc);
        self.aliases.deinit(alloc);
        self.arena.deinit();
    }

    /// Accumulate one wdata chunk carrying data for meta.mime (which
    /// must be non-empty; an empty mime is a commit, not data).
    ///
    /// Returns error.TooLarge when the transaction exceeds max_size
    /// and error.Invalid when the payload stream is not valid base64.
    /// The caller must fail the whole transaction with EFBIG or EINVAL
    /// respectively and abort it, as required by the protocol.
    pub fn data(
        self: *WriteState,
        alloc: Allocator,
        meta: *const Metadata,
        payload: []const u8,
    ) error{ OutOfMemory, TooLarge, Invalid }!void {
        assert(meta.op == .wdata);
        assert(meta.mime.len > 0);
        // Switch the receiving entry if this chunk is for a different
        // MIME type than the last one.
        entry: {
            if (self.current) |idx| {
                const entry = &self.entries.items[idx];
                if (std.mem.eql(u8, entry.mime, meta.mime)) {
                    break :entry;
                }

                // Finalize the previous region. Its concatenated
                // stream must have ended on a complete base64 group,
                // otherwise the data was not correctly padded.
                try self.finishCurrent();
                entry.len = self.spool.items.len - entry.start;
            }

            // Re-using an earlier MIME type starts a fresh region,
            // overwriting the previous mapping.
            for (self.entries.items, 0..) |*entry, idx| {
                if (std.mem.eql(u8, entry.mime, meta.mime)) {
                    entry.start = self.spool.items.len;
                    entry.len = 0;
                    self.current = idx;
                    break :entry;
                }
            }

            if (self.entries.items.len >= max_write_mimes) {
                log.warn(
                    "clipboard write has too many MIME types, ignoring mime={s}",
                    .{meta.mime},
                );
                self.current = null;
                return;
            }

            try self.entries.append(alloc, .{
                .mime = try self.arena.allocator().dupe(u8, meta.mime),
                .start = self.spool.items.len,
            });
            self.current = self.entries.items.len - 1;
        }

        // The payloads for one MIME region concatenate into a single
        // strict base64 stream, decoded directly into the spool's
        // unused capacity. Invalid data aborts the transaction; per
        // the spec it must not be silently discarded "since that
        // turns corrupted data into apparently valid data".
        try self.spool.ensureUnusedCapacity(alloc, self.decoder.maxLen(payload));
        const decoded = self.decoder.feed(
            payload,
            self.spool.unusedCapacitySlice(),
        ) catch return error.Invalid;

        // The limit covers all decoded data in the transaction. Going
        // over it aborts the entire write; partial clipboard contents
        // must never reach the embedder.
        const remaining = self.max_size -| self.spool.items.len;
        if (decoded.len > remaining) return error.TooLarge;
        self.spool.items.len += decoded.len;
    }

    /// Finish the decode stream of the entry currently receiving
    /// data. Returns error.Invalid when the stream ends mid-group,
    /// i.e. the concatenated payload was not correctly padded.
    fn finishCurrent(self: *WriteState) error{Invalid}!void {
        self.decoder.finish() catch return error.Invalid;
    }

    /// Register aliases from a walias packet: meta.mime is the target
    /// (the type that carries data) and the payload is a base64-encoded,
    /// whitespace-separated list of aliases. Returns error.Invalid for
    /// an undecodable payload, which aborts the transaction with EINVAL.
    pub fn alias(
        self: *WriteState,
        alloc: Allocator,
        meta: *const Metadata,
        payload: []const u8,
    ) error{ OutOfMemory, Invalid }!void {
        assert(meta.op == .walias);
        assert(meta.mime.len > 0);
        const decoded = try Payload.init(alloc, payload);
        defer decoded.deinit(alloc);
        if (!decoded.isValidUtf8()) return error.Invalid;
        var it = decoded.mimeIterator();

        // Copy the target only if at least one valid alias exists.
        const target: []const u8 = target: {
            while (it.next()) |name| {
                if (name.len > max_mime_len) continue;
                break :target try self.arena.allocator().dupe(u8, meta.mime);
            }

            // If we didn't find a target then ignore it.
            return;
        };

        // Rewind so the alias that satisfied the check above is
        // associated too.
        it.reset();

        // Associate the aliases
        while (it.next()) |name| {
            if (name.len > max_mime_len) continue;

            // A repeated alias overwrites its previous target.
            for (self.aliases.items) |*a| {
                if (std.mem.eql(u8, a.alias, name)) {
                    a.target = target;
                    break;
                }
            } else {
                if (self.aliases.items.len >= max_write_aliases) {
                    log.warn("clipboard write has too many aliases, ignoring", .{});
                    return;
                }

                try self.aliases.append(alloc, .{
                    .alias = try self.arena.allocator().dupe(u8, name),
                    .target = target,
                });
            }
        }
    }

    /// The result of a committed transaction. All slices borrow the
    /// WriteState's memory and are valid until it is deinited.
    pub const Committed = struct {
        loc: clipboard.Location,
        id: []const u8,
        pw: []const u8,
        name: []const u8,
        contents: []const Content,

        pub fn deinit(self: *const Committed, alloc: Allocator) void {
            alloc.free(self.contents);
        }
    };

    /// Commit the transaction (a wdata packet without a MIME type).
    /// The caller must use the result, call Committed.deinit, and then
    /// deinit this state. Returns error.Invalid when the last region's
    /// concatenated payload was not correctly padded; the caller must
    /// fail the transaction with EINVAL and abort it.
    pub fn commit(
        self: *WriteState,
        alloc: Allocator,
    ) error{ OutOfMemory, Invalid }!Committed {
        // Finalize the region receiving data.
        if (self.current) |idx| {
            try self.finishCurrent();
            const entry = &self.entries.items[idx];
            entry.len = self.spool.items.len - entry.start;
            self.current = null;
        }

        // Resolve the final MIME map: entries in arrival order, then
        // aliases applied sequentially against the evolving map so
        // chained aliases work like kitty's dict iteration. An alias
        // whose target has no mapping is dropped; an alias colliding
        // with an existing name overwrites it.
        var contents: std.ArrayListUnmanaged(Content) = .empty;
        defer contents.deinit(alloc);
        try contents.ensureTotalCapacity(
            alloc,
            self.entries.items.len + self.aliases.items.len,
        );

        for (self.entries.items) |*entry| {
            contents.appendAssumeCapacity(.{
                .mime = entry.mime,
                .data = self.spool.items[entry.start..][0..entry.len],
            });
        }

        for (self.aliases.items) |*a| {
            const target: Content = target: {
                for (contents.items) |c| {
                    if (std.mem.eql(u8, c.mime, a.target)) {
                        break :target c;
                    }
                }
                continue;
            };

            for (contents.items) |*c| {
                if (std.mem.eql(u8, c.mime, a.alias)) {
                    c.data = target.data;
                    break;
                }
            } else {
                contents.appendAssumeCapacity(.{
                    .mime = a.alias,
                    .data = target.data,
                });
            }
        }

        return .{
            .loc = self.loc,
            .id = self.id,
            .pw = self.pw,
            .name = self.name,
            .contents = try contents.toOwnedSlice(alloc),
        };
    }
};

test "write: basic transaction" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const begin_meta: Metadata = .{ .op = .write, .id = "42" };
    var state: WriteState = try .init(alloc, &begin_meta, .{});
    defer state.deinit(alloc);

    try state.data(alloc, &.{ .op = .wdata, .mime = "text/plain" }, "R2hvc3R0eQ=="); // "Ghostty"

    const committed = try state.commit(alloc);
    defer committed.deinit(alloc);
    try testing.expectEqualStrings("42", committed.id);
    try testing.expect(committed.loc == .standard);
    try testing.expectEqual(@as(usize, 1), committed.contents.len);
    try testing.expectEqualStrings("text/plain", committed.contents[0].mime);
    try testing.expectEqualStrings("Ghostty", committed.contents[0].data);
}

test "write: chunked data accumulates" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const begin_meta: Metadata = .{ .op = .write };
    var state: WriteState = try .init(alloc, &begin_meta, .{});
    defer state.deinit(alloc);

    try state.data(alloc, &.{ .op = .wdata, .mime = "text/plain" }, "SGVsbG8="); // "Hello"
    try state.data(alloc, &.{ .op = .wdata, .mime = "text/plain" }, "V29ybGQ="); // "World"

    const committed = try state.commit(alloc);
    defer committed.deinit(alloc);
    try testing.expectEqualStrings("HelloWorld", committed.contents[0].data);
}

test "write: multiple mimes in order" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const begin_meta: Metadata = .{ .op = .write };
    var state: WriteState = try .init(alloc, &begin_meta, .{});
    defer state.deinit(alloc);

    try state.data(alloc, &.{ .op = .wdata, .mime = "text/plain" }, "YQ=="); // "a"
    try state.data(alloc, &.{ .op = .wdata, .mime = "text/html" }, "Yg=="); // "b"

    const committed = try state.commit(alloc);
    defer committed.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), committed.contents.len);
    try testing.expectEqualStrings("text/plain", committed.contents[0].mime);
    try testing.expectEqualStrings("a", committed.contents[0].data);
    try testing.expectEqualStrings("text/html", committed.contents[1].mime);
    try testing.expectEqualStrings("b", committed.contents[1].data);
}

test "write: reused mime overwrites" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const begin_meta: Metadata = .{ .op = .write };
    var state: WriteState = try .init(alloc, &begin_meta, .{});
    defer state.deinit(alloc);

    try state.data(alloc, &.{ .op = .wdata, .mime = "text/plain" }, "YQ=="); // "a"
    try state.data(alloc, &.{ .op = .wdata, .mime = "text/html" }, "Yg=="); // "b"
    try state.data(alloc, &.{ .op = .wdata, .mime = "text/plain" }, "Yw=="); // "c"

    const committed = try state.commit(alloc);
    defer committed.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), committed.contents.len);
    // Position preserved, data replaced.
    try testing.expectEqualStrings("text/plain", committed.contents[0].mime);
    try testing.expectEqualStrings("c", committed.contents[0].data);
}

test "write: invalid base64 chunk aborts the transaction" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Invalid characters anywhere in the stream are error.Invalid,
    // which the handlers turn into an EINVAL abort. These mirror
    // kitty's own tests for the spec change.
    const invalid_payloads = [_][]const u8{
        "!!!",
        "SGVs!!!bG8=",
        "\nZGF0YSB3aXRoIGEgbmV3bGluZQ==",
    };
    for (invalid_payloads) |payload| {
        const begin_meta: Metadata = .{ .op = .write };
        var state: WriteState = try .init(alloc, &begin_meta, .{});
        defer state.deinit(alloc);
        try testing.expectError(error.Invalid, state.data(
            alloc,
            &.{ .op = .wdata, .mime = "text/plain" },
            payload,
        ));
    }

    // Also after an earlier valid chunk for the same MIME type.
    {
        const begin_meta: Metadata = .{ .op = .write };
        var state: WriteState = try .init(alloc, &begin_meta, .{});
        defer state.deinit(alloc);
        try state.data(alloc, &.{ .op = .wdata, .mime = "text/plain" }, "Z29vZA=="); // "good"
        try testing.expectError(error.Invalid, state.data(
            alloc,
            &.{ .op = .wdata, .mime = "text/plain" },
            "SGVs!!!bG8=",
        ));
    }
}

test "write: chunks split one base64 stream at arbitrary boundaries" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // The concatenation of all payloads per MIME type is the base64
    // stream; individual packets need not be a multiple of four bytes.
    const encoded = "c29tZSBkYXRh"; // "some data"
    const splits = [_][]const usize{
        &.{ 3, 7 },
        &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 },
    };
    for (splits) |split| {
        const begin_meta: Metadata = .{ .op = .write };
        var state: WriteState = try .init(alloc, &begin_meta, .{});
        defer state.deinit(alloc);

        var prev: usize = 0;
        for (split) |end| {
            try state.data(
                alloc,
                &.{ .op = .wdata, .mime = "text/plain" },
                encoded[prev..end],
            );
            prev = end;
        }
        try state.data(alloc, &.{ .op = .wdata, .mime = "text/plain" }, encoded[prev..]);

        const committed = try state.commit(alloc);
        defer committed.deinit(alloc);
        try testing.expectEqualStrings("some data", committed.contents[0].data);
    }
}

test "write: incorrectly padded stream aborts at commit" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const begin_meta: Metadata = .{ .op = .write };
    var state: WriteState = try .init(alloc, &begin_meta, .{});
    defer state.deinit(alloc);

    // "Hello" without its final padding byte: every chunk decodes,
    // but the stream ends mid-group so the commit reports it.
    try state.data(alloc, &.{ .op = .wdata, .mime = "text/plain" }, "SGVsbG8");
    try testing.expectError(error.Invalid, state.commit(alloc));
}

test "write: incorrectly padded stream aborts at MIME switch" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const begin_meta: Metadata = .{ .op = .write };
    var state: WriteState = try .init(alloc, &begin_meta, .{});
    defer state.deinit(alloc);

    try state.data(alloc, &.{ .op = .wdata, .mime = "text/plain" }, "SGVsbG8");
    try testing.expectError(error.Invalid, state.data(
        alloc,
        &.{ .op = .wdata, .mime = "text/html" },
        "PGI+aGk8L2I+",
    ));
}

test "write: independently padded chunks accumulate" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // A packet payload ending exactly at terminal padding resets the
    // stream, so clients that base64-encode every chunk independently
    // keep working (matching kitty, which resets its streaming
    // decoder on EOF). Padding followed by more data within a single
    // packet stays invalid.
    const begin_meta: Metadata = .{ .op = .write };
    var state: WriteState = try .init(alloc, &begin_meta, .{});
    defer state.deinit(alloc);

    try state.data(alloc, &.{ .op = .wdata, .mime = "text/plain" }, "Z29vZA=="); // "good"
    try state.data(alloc, &.{ .op = .wdata, .mime = "text/plain" }, "bW9yZQ=="); // "more"

    const committed = try state.commit(alloc);
    defer committed.deinit(alloc);
    try testing.expectEqualStrings("goodmore", committed.contents[0].data);
}

test "write: data after padding within one chunk aborts" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const begin_meta: Metadata = .{ .op = .write };
    var state: WriteState = try .init(alloc, &begin_meta, .{});
    defer state.deinit(alloc);

    try testing.expectError(error.Invalid, state.data(
        alloc,
        &.{ .op = .wdata, .mime = "text/plain" },
        "Z29vZA==bW9yZQ==",
    ));
}

test "write: aliases resolve at commit" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const begin_meta: Metadata = .{ .op = .write };
    var state: WriteState = try .init(alloc, &begin_meta, .{});
    defer state.deinit(alloc);

    try state.data(alloc, &.{ .op = .wdata, .mime = "text/plain" }, "R2hvc3R0eQ=="); // "Ghostty"

    // Alias "TEXT UTF8_STRING" -> text/plain.
    const alias_meta: Metadata = .{ .op = .walias, .mime = "text/plain" };
    try state.alias(alloc, &alias_meta, "VEVYVCBVVEY4X1NUUklORw==");

    const committed = try state.commit(alloc);
    defer committed.deinit(alloc);
    try testing.expectEqual(@as(usize, 3), committed.contents.len);
    try testing.expectEqualStrings("TEXT", committed.contents[1].mime);
    try testing.expectEqualStrings("Ghostty", committed.contents[1].data);
    try testing.expectEqualStrings("UTF8_STRING", committed.contents[2].mime);
    try testing.expectEqualStrings("Ghostty", committed.contents[2].data);
}

test "write: alias payload must be valid utf8" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const begin_meta: Metadata = .{ .op = .write };
    var state: WriteState = try .init(alloc, &begin_meta, .{});
    defer state.deinit(alloc);

    const alias_meta: Metadata = .{ .op = .walias, .mime = "text/plain" };
    // Valid base64 encoding of a single 0xff byte.
    try testing.expectError(
        error.Invalid,
        state.alias(alloc, &alias_meta, "/w=="),
    );
}

test "write: default limit when unset" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const begin_meta: Metadata = .{ .op = .write };
    var state: WriteState = try .init(alloc, &begin_meta, .{});
    defer state.deinit(alloc);
    try testing.expectEqual(@as(usize, max_write_size), state.max_size);
}

test "write: text over limit rejects transaction" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const begin_meta: Metadata = .{ .op = .write };
    var state: WriteState = try .init(alloc, &begin_meta, .{ .max_size = 8 });
    defer state.deinit(alloc);

    try testing.expectError(error.TooLarge, state.data(
        alloc,
        &.{ .op = .wdata, .mime = "text/plain" },
        "SGVsbG9Xb3JsZA==", // "HelloWorld"
    ));
}

test "write: text crossing limit across chunks rejects transaction" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const begin_meta: Metadata = .{ .op = .write };
    var state: WriteState = try .init(alloc, &begin_meta, .{ .max_size = 8 });
    defer state.deinit(alloc);

    try state.data(alloc, &.{ .op = .wdata, .mime = "text/plain" }, "SGVsbG8="); // "Hello"
    try testing.expectError(error.TooLarge, state.data(
        alloc,
        &.{ .op = .wdata, .mime = "text/plain" },
        "V29ybGQ=", // "World"
    ));
}

test "write: data exactly at limit is accepted" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const begin_meta: Metadata = .{ .op = .write };
    var state: WriteState = try .init(alloc, &begin_meta, .{ .max_size = 5 });
    defer state.deinit(alloc);

    try state.data(alloc, &.{ .op = .wdata, .mime = "text/plain" }, "SGVsbG8="); // "Hello"

    const committed = try state.commit(alloc);
    defer committed.deinit(alloc);
    try testing.expectEqualStrings("Hello", committed.contents[0].data);
}

test "write: non-text under limit is unaffected" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const begin_meta: Metadata = .{ .op = .write };
    var state: WriteState = try .init(alloc, &begin_meta, .{ .max_size = 8 });
    defer state.deinit(alloc);

    try state.data(alloc, &.{ .op = .wdata, .mime = "image/png" }, "iVBORw=="); // "\x89PNG"

    const committed = try state.commit(alloc);
    defer committed.deinit(alloc);
    try testing.expectEqualStrings("\x89PNG", committed.contents[0].data);
}

test "write: non-text over limit rejects transaction" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const begin_meta: Metadata = .{ .op = .write };
    var state: WriteState = try .init(alloc, &begin_meta, .{ .max_size = 8 });
    defer state.deinit(alloc);

    try testing.expectError(error.TooLarge, state.data(
        alloc,
        &.{ .op = .wdata, .mime = "image/png" },
        "SGVsbG9Xb3JsZA==", // "HelloWorld"
    ));
}

test "write: total data across MIME types is limited" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const begin_meta: Metadata = .{ .op = .write };
    var state: WriteState = try .init(alloc, &begin_meta, .{ .max_size = 8 });
    defer state.deinit(alloc);

    try state.data(alloc, &.{ .op = .wdata, .mime = "text/plain" }, "SGVsbG8="); // "Hello"

    try testing.expectError(error.TooLarge, state.data(
        alloc,
        &.{ .op = .wdata, .mime = "image/png" },
        "V29ybGQ=", // "World"
    ));
}

test "write: alias without data target is dropped" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const begin_meta: Metadata = .{ .op = .write };
    var state: WriteState = try .init(alloc, &begin_meta, .{});
    defer state.deinit(alloc);

    const alias_meta: Metadata = .{ .op = .walias, .mime = "text/plain" };
    try state.alias(alloc, &alias_meta, "VEVYVA=="); // "TEXT"

    const committed = try state.commit(alloc);
    defer committed.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), committed.contents.len);
}
