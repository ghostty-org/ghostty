const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.sentry_envelope);

/// The Sentry Envelope format: https://develop.sentry.dev/sdk/envelopes/
///
/// The envelope is our primary crash report format since use the Sentry
/// client. It is designed and created by Sentry but is an open format
/// in that it is publicly documented and can be used by any system. This
/// lets us utilize the Sentry client for crash capture but also gives us
/// the opportunity to migrate to another system if we need to, and doesn't
/// force any user or developer to use Sentry the SaaS if they don't want
/// to.
///
/// This struct implements reading the envelope format (writing is not needed
/// currently but can be added later). It is incomplete; I only implemented
/// what I needed at the time.
pub const Envelope = struct {
    /// The arena that the envelope is allocated in. All items are welcome
    /// to use this allocator for their data, which is freed on deinit.
    arena: std.heap.ArenaAllocator,

    /// The headers of the envelope decoded into a json ObjectMap.
    headers: std.json.ObjectMap,

    /// The items in the envelope in the order they're encoded.
    items: std.ArrayListUnmanaged(Item),

    /// Parse an envelope from a reader.
    ///
    /// The full envelope must fit in memory for this to succeed. This
    /// will always copy the data from the reader into memory, even if the
    /// reader is already in-memory (i.e. a FixedBufferStream). This
    /// simplifies memory lifetimes at the expense of a copy, but envelope
    /// parsing in our use case is not a hot path.
    pub fn parse(
        alloc_gpa: Allocator,
        reader: anytype,
    ) !Envelope {
        // We use an arena allocator to read from reader. We pair this
        // with `alloc_if_needed` when parsing json to allow the json
        // to reference the arena-allocated memory if it can. That way both
        // our temp and perm memory is part of the same arena. This slightly
        // bloats our memory requirements but reduces allocations.
        var arena = std.heap.ArenaAllocator.init(alloc_gpa);
        errdefer arena.deinit();
        const alloc = arena.allocator();

        // Parse our elements. We do this outside of the struct assignment
        // below to avoid the issue where order matters in struct assignment.
        const headers = try parseHeader(alloc, reader);
        const items = try parseItems(alloc, reader);

        return .{
            .headers = headers,
            .items = items,
            .arena = arena,
        };
    }

    fn parseHeader(
        alloc: Allocator,
        reader: anytype,
    ) !std.json.ObjectMap {
        var buf: std.ArrayListUnmanaged(u8) = .{};
        reader.streamUntilDelimiter(
            buf.writer(alloc),
            '\n',
            1024 * 1024, // 1MB, arbitrary choice
        ) catch |err| switch (err) {
            // Envelope can be header-only.
            error.EndOfStream => {},
            else => |v| return v,
        };

        const value = try std.json.parseFromSliceLeaky(
            std.json.Value,
            alloc,
            buf.items,
            .{ .allocate = .alloc_if_needed },
        );

        return switch (value) {
            .object => |map| map,
            else => error.EnvelopeMalformedHeaders,
        };
    }

    fn parseItems(
        alloc: Allocator,
        reader: anytype,
    ) !std.ArrayListUnmanaged(Item) {
        var items: std.ArrayListUnmanaged(Item) = .{};
        errdefer items.deinit(alloc);
        while (try parseOneItem(alloc, reader)) |item| {
            try items.append(alloc, item);
        }

        return items;
    }

    fn parseOneItem(
        alloc: Allocator,
        reader: anytype,
    ) !?Item {
        // Get the next item which must start with a header.
        var buf: std.ArrayListUnmanaged(u8) = .{};
        reader.streamUntilDelimiter(
            buf.writer(alloc),
            '\n',
            1024 * 1024, // 1MB, arbitrary choice
        ) catch |err| switch (err) {
            error.EndOfStream => return null,
            else => |v| return v,
        };

        // Parse the header JSON
        const headers: std.json.ObjectMap = headers: {
            const line = std.mem.trim(u8, buf.items, " \t");
            if (line.len == 0) return null;

            const value = try std.json.parseFromSliceLeaky(
                std.json.Value,
                alloc,
                line,
                .{ .allocate = .alloc_if_needed },
            );

            break :headers switch (value) {
                .object => |map| map,
                else => return error.EnvelopeItemMalformedHeaders,
            };
        };

        // Get the event type
        const typ: ItemType = if (headers.get("type")) |v| switch (v) {
            .string => |str| std.meta.stringToEnum(
                ItemType,
                str,
            ) orelse .unknown,
            else => return error.EnvelopeItemTypeMissing,
        } else return error.EnvelopeItemTypeMissing;

        // Get the payload length. The length is not required. If the length
        // is not specified then it is the next line ending in `\n`.
        const len_: ?u64 = if (headers.get("length")) |v| switch (v) {
            .integer => |int| std.math.cast(
                u64,
                int,
            ) orelse return error.EnvelopeItemLengthMalformed,
            else => return error.EnvelopeItemLengthMalformed,
        } else null;

        // Get the payload
        const payload: []const u8 = if (len_) |len| payload: {
            // The payload length is specified so read the exact length.
            var payload = std.ArrayList(u8).init(alloc);
            defer payload.deinit();
            for (0..len) |_| {
                const byte = reader.readByte() catch |err| switch (err) {
                    error.EndOfStream => return error.EnvelopeItemPayloadTooShort,
                    else => return err,
                };
                try payload.append(byte);
            }

            // The next byte must be a newline.
            if (reader.readByte()) |byte| {
                if (byte != '\n') return error.EnvelopeItemPayloadNoNewline;
            } else |err| switch (err) {
                error.EndOfStream => {},
                else => return err,
            }

            break :payload try payload.toOwnedSlice();
        } else payload: {
            // The payload is the next line ending in `\n`. It is required.
            var payload = std.ArrayList(u8).init(alloc);
            defer payload.deinit();
            reader.streamUntilDelimiter(
                payload.writer(),
                '\n',
                1024 * 1024 * 50, // 50MB, arbitrary choice
            ) catch |err| switch (err) {
                error.EndOfStream => return error.EnvelopeItemPayloadTooShort,
                else => |v| return v,
            };
            break :payload try payload.toOwnedSlice();
        };

        return .{ .encoded = .{
            .headers = headers,
            .type = typ,
            .payload = payload,
        } };
    }

    pub fn deinit(self: *Envelope) void {
        self.arena.deinit();
    }

    /// The arena allocator associated with this envelope
    pub fn allocator(self: *Envelope) Allocator {
        return self.arena.allocator();
    }

    /// Serialize the envelope to the given writer.
    ///
    /// This will convert all decoded items to encoded items and
    /// therefore may allocate.
    pub fn serialize(
        self: *Envelope,
        writer: anytype,
    ) !void {
        // Header line first
        try std.json.stringify(
            std.json.Value{ .object = self.headers },
            json_opts,
            writer,
        );
        try writer.writeByte('\n');

        // Write each item
        const alloc = self.allocator();
        for (self.items.items, 0..) |*item, idx| {
            if (idx > 0) try writer.writeByte('\n');

            const encoded = try item.encode(alloc);
            assert(item.* == .encoded);

            try std.json.stringify(
                std.json.Value{ .object = encoded.headers },
                json_opts,
                writer,
            );
            try writer.writeByte('\n');
            try writer.writeAll(encoded.payload);
        }
    }
};

/// The various item types that can be in an envelope. This is a point
/// in time snapshot of the types that are known whenever this is edited.
/// Event types can be introduced at any time and unknown types will
/// take the "unknown" enum value.
///
/// https://develop.sentry.dev/sdk/envelopes/#data-model
pub const ItemType = enum {
    /// Special event type for when the item type is unknown.
    unknown,

    /// Documented event types
    event,
    transaction,
    attachment,
    session,
    sessions,
    statsd,
    metric_meta,
    user_feedback,
    client_report,
    replay_event,
    replay_recording,
    profile,
    check_in,
};

/// An item in the envelope. An item can be either in an encoded
/// or decoded state. The encoded state lets us parse the envelope
/// more cheaply since we can defer the full decoding of the item
/// until we need it.
///
/// The decoded state is more ergonomic to work with and lets us
/// easily build up new items and defer encoding until serialization
/// time.
pub const Item = union(enum) {
    encoded: EncodedItem,
    attachment: Attachment,

    /// Convert the item to an encoded item. This modify the item
    /// in place.
    pub fn encode(
        self: *Item,
        alloc: Allocator,
    ) !EncodedItem {
        const result: EncodedItem = switch (self.*) {
            .encoded => |v| return v,
            .attachment => |*v| try v.encode(alloc),
        };
        self.* = .{ .encoded = result };
        return result;
    }

    /// Returns the type of item represented here, whether
    /// it is an encoded item or not.
    pub fn itemType(self: Item) ItemType {
        return switch (self) {
            .encoded => |v| v.type,
            .attachment => .attachment,
        };
    }

    pub const DecodeError = Allocator.Error || error{
        MissingRequiredField,
        InvalidFieldType,
        UnsupportedType,
    };

    /// Decode the item if it is encoded. This will modify itself.
    /// If the item is already decoded this does nothing.
    ///
    /// The allocator argument should be an arena-style allocator,
    /// typically the allocator associated with the Envelope.
    ///
    /// If the decoding fails because the item is in an invalid
    /// state (i.e. its missing a required field) then this will
    /// error but the encoded item will remain unmodified. This
    /// allows the caller to handle the error without corrupting the
    /// envelope.
    ///
    /// If decoding fails, the allocator may still allocate so the
    /// allocator should be an arena-style allocator.
    pub fn decode(self: *Item, alloc: Allocator) DecodeError!void {
        // Get our encoded item. If we're not encoded we're done.
        const encoded: EncodedItem = switch (self.*) {
            .encoded => |v| v,
            else => return,
        };

        // Decode the item.
        self.* = switch (encoded.type) {
            .attachment => .{ .attachment = try .decode(
                alloc,
                encoded,
            ) },
            else => return error.UnsupportedType,
        };
    }
};

/// An encoded item. It is "encoded" in the sense that the payload
/// is a byte slice. The headers are "decoded" into a json ObjectMap
/// but that's still a pretty low-level representation.
pub const EncodedItem = struct {
    headers: std.json.ObjectMap,
    type: ItemType,
    payload: []const u8,
};

/// An arbitrary file attachment.
///
/// https://develop.sentry.dev/sdk/envelopes/#attachment
pub const Attachment = struct {
    /// "filename" field is the name of the uploaded file without
    /// a path component.
    filename: []const u8,

    /// A special "type" associated with the attachment. This
    /// is documented on the Sentry website. In the future we should
    /// make this an enum.
    type: ?[]const u8 = null,

    /// Additional headers for the attachment.
    headers_extra: ObjectMapUnmanaged = .{},

    /// The data for the attachment.
    payload: []const u8,

    pub fn decode(
        alloc: Allocator,
        item: EncodedItem,
    ) Item.DecodeError!Attachment {
        _ = alloc;

        return .{
            .filename = if (item.headers.get("filename")) |v| switch (v) {
                .string => |str| str,
                else => return error.InvalidFieldType,
            } else return error.MissingRequiredField,

            .type = if (item.headers.get("attachment_type")) |v| switch (v) {
                .string => |str| str,
                else => return error.InvalidFieldType,
            } else null,

            .headers_extra = item.headers.unmanaged,
            .payload = item.payload,
        };
    }

    pub fn encode(
        self: *Attachment,
        alloc: Allocator,
    ) !EncodedItem {
        try self.headers_extra.put(
            alloc,
            "filename",
            .{ .string = self.filename },
        );

        if (self.type) |v| {
            try self.headers_extra.put(
                alloc,
                "attachment_type",
                .{ .string = v },
            );
        } else {
            _ = self.headers_extra.swapRemove("attachment_type");
        }

        return .{
            .headers = self.headers_extra.promote(alloc),
            .type = .attachment,
            .payload = self.payload,
        };
    }
};

/// Same as std.json.ObjectMap but unmanaged. This lets us store
/// them alongside all our items without the overhead of duplicated
/// allocators. Additional, items do not own their own memory so this
/// makes it clear that deinit of an item will not free the memory.
pub const ObjectMapUnmanaged = std.StringArrayHashMapUnmanaged(std.json.Value);

/// The options we must use for serialization.
const json_opts: std.json.StringifyOptions = .{
    // This is the default but I want to be explicit because its
    // VERY important for the correctness of the envelope. This is
    // the only whitespace type in std.json that doesn't emit newlines.
    // All JSON headers in the envelope must be on a single line.
    .whitespace = .minified,
};

test "Envelope parse" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var fbs = std.io.fixedBufferStream(
        \\{}
    );
    var v = try Envelope.parse(alloc, fbs.reader());
    defer v.deinit();
}

test "Envelope parse session" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var fbs = std.io.fixedBufferStream(
        \\{}
        \\{"type":"session","length":218}
        \\{"init":true,"sid":"c148cc2f-5f9f-4231-575c-2e85504d6434","status":"abnormal","errors":0,"started":"2024-08-29T02:38:57.607016Z","duration":0.000343,"attrs":{"release":"0.1.0-HEAD+d37b7d09","environment":"production"}}
    );
    var v = try Envelope.parse(alloc, fbs.reader());
    defer v.deinit();

    try testing.expectEqual(@as(usize, 1), v.items.items.len);
    try testing.expectEqual(ItemType.session, v.items.items[0].encoded.type);
}

test "Envelope parse multiple" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var fbs = std.io.fixedBufferStream(
        \\{}
        \\{"type":"session","length":218}
        \\{"init":true,"sid":"c148cc2f-5f9f-4231-575c-2e85504d6434","status":"abnormal","errors":0,"started":"2024-08-29T02:38:57.607016Z","duration":0.000343,"attrs":{"release":"0.1.0-HEAD+d37b7d09","environment":"production"}}
        \\{"type":"attachment","length":4,"filename":"test.txt"}
        \\ABCD
    );
    var v = try Envelope.parse(alloc, fbs.reader());
    defer v.deinit();

    try testing.expectEqual(@as(usize, 2), v.items.items.len);
    try testing.expectEqual(ItemType.session, v.items.items[0].encoded.type);
    try testing.expectEqual(ItemType.attachment, v.items.items[1].encoded.type);
}

test "Envelope parse multiple no length" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var fbs = std.io.fixedBufferStream(
        \\{}
        \\{"type":"session"}
        \\{}
        \\{"type":"attachment","length":4,"filename":"test.txt"}
        \\ABCD
    );
    var v = try Envelope.parse(alloc, fbs.reader());
    defer v.deinit();

    try testing.expectEqual(@as(usize, 2), v.items.items.len);
    try testing.expectEqual(ItemType.session, v.items.items[0].encoded.type);
    try testing.expectEqual(ItemType.attachment, v.items.items[1].encoded.type);
}

test "Envelope parse end in new line" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var fbs = std.io.fixedBufferStream(
        \\{}
        \\{"type":"session","length":218}
        \\{"init":true,"sid":"c148cc2f-5f9f-4231-575c-2e85504d6434","status":"abnormal","errors":0,"started":"2024-08-29T02:38:57.607016Z","duration":0.000343,"attrs":{"release":"0.1.0-HEAD+d37b7d09","environment":"production"}}
        \\
    );
    var v = try Envelope.parse(alloc, fbs.reader());
    defer v.deinit();

    try testing.expectEqual(@as(usize, 1), v.items.items.len);
    try testing.expectEqual(ItemType.session, v.items.items[0].encoded.type);
}

test "Envelope parse attachment" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var fbs = std.io.fixedBufferStream(
        \\{}
        \\{"type":"attachment","length":4,"filename":"test.txt"}
        \\ABCD
    );
    var v = try Envelope.parse(alloc, fbs.reader());
    defer v.deinit();

    try testing.expectEqual(@as(usize, 1), v.items.items.len);

    var item = &v.items.items[0];
    try testing.expectEqual(ItemType.attachment, item.encoded.type);
    try item.decode(v.allocator());
    try testing.expect(item.* == .attachment);
    try testing.expectEqualStrings("test.txt", item.attachment.filename);

    // Serialization test
    {
        var output = std.ArrayList(u8).init(alloc);
        defer output.deinit();
        try v.serialize(output.writer());
        try testing.expectEqualStrings(
            \\{}
            \\{"type":"attachment","length":4,"filename":"test.txt"}
            \\ABCD
        , std.mem.trim(u8, output.items, "\n"));
    }
}

test "Envelope serialize empty" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var fbs = std.io.fixedBufferStream(
        \\{}
    );
    var v = try Envelope.parse(alloc, fbs.reader());
    defer v.deinit();

    var output = std.ArrayList(u8).init(alloc);
    defer output.deinit();
    try v.serialize(output.writer());

    try testing.expectEqualStrings(
        \\{}
    , std.mem.trim(u8, output.items, "\n"));
}

test "Envelope serialize session" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var fbs = std.io.fixedBufferStream(
        \\{}
        \\{"type":"session","length":218}
        \\{"init":true,"sid":"c148cc2f-5f9f-4231-575c-2e85504d6434","status":"abnormal","errors":0,"started":"2024-08-29T02:38:57.607016Z","duration":0.000343,"attrs":{"release":"0.1.0-HEAD+d37b7d09","environment":"production"}}
    );
    var v = try Envelope.parse(alloc, fbs.reader());
    defer v.deinit();

    var output = std.ArrayList(u8).init(alloc);
    defer output.deinit();
    try v.serialize(output.writer());

    try testing.expectEqualStrings(
        \\{}
        \\{"type":"session","length":218}
        \\{"init":true,"sid":"c148cc2f-5f9f-4231-575c-2e85504d6434","status":"abnormal","errors":0,"started":"2024-08-29T02:38:57.607016Z","duration":0.000343,"attrs":{"release":"0.1.0-HEAD+d37b7d09","environment":"production"}}
    , std.mem.trim(u8, output.items, "\n"));
}

// // Uncomment this test if you want to extract a minidump file from an
// // existing envelope. This is useful for getting new test contents.
// test "Envelope extract mdmp" {
//     const testing = std.testing;
//     const alloc = testing.allocator;
//
//     var fbs = std.io.fixedBufferStream(@embedFile("in.crash"));
//     var v = try Envelope.parse(alloc, fbs.reader());
//     defer v.deinit();
//
//     try testing.expect(v.items.items.len > 0);
//     for (v.items.items, 0..) |*item, i| {
//         if (item.encoded.type != .attachment) {
//             log.warn("ignoring item type={} i={}", .{ item.encoded.type, i });
//             continue;
//         }
//
//         try item.decode(v.allocator());
//         const attach = item.attachment;
//         const attach_type = attach.type orelse {
//             log.warn("attachment missing type i={}", .{i});
//             continue;
//         };
//         if (!std.mem.eql(u8, attach_type, "event.minidump")) {
//             log.warn("ignoring attachment type={s} i={}", .{ attach_type, i });
//             continue;
//         }
//
//         log.warn("found minidump i={}", .{i});
//         var f = try std.fs.cwd().createFile("out.mdmp", .{});
//         defer f.close();
//         try f.writer().writeAll(attach.payload);
//         return;
//     }
// }
