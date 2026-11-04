const std = @import("std");

/// Decoded OSC 72 metadata.
pub const Metadata = struct {
    /// Event type (`t`). Null when the metadata had no `t` key; such
    /// commands parse successfully but are ignored, matching kitty.
    type: ?EventType = null,

    /// Chunking flag (`m`): true when more chunks follow.
    more: bool = false,

    /// Multiplexer client ID (`i`), echoed in every response so a
    /// terminal multiplexer can route responses to the correct client.
    client_id: u32 = 0,

    /// Operation (`o`): meaning depends on the event type, commonly
    /// 0=none/reject, 1=copy, 2=move, 3=copy or move.
    operation: u32 = 0,

    /// `x`, `y`, `X`, `Y` keys.
    cell_x: i32 = 0,
    cell_y: i32 = 0,
    pixel_x: i32 = 0,
    pixel_y: i32 = 0,

    /// Parse raw OSC 72 metadata (the part before the first `;`).
    /// Returns null when malformed; callers should ignore the command,
    /// matching kitty which rejects the entire command on any error.
    pub fn parse(raw: []const u8) ?Metadata {
        var result: Metadata = .{};
        var pos: usize = 0;
        // The continue expression consumes the ':' separating a field
        // from the next; the body advances past the field itself.
        while (pos < raw.len) : (pos += 1) {
            // Single-character key.
            const key = raw[pos];
            pos += 1;
            switch (key) {
                't', 'm', 'i', 'o', 'x', 'y', 'X', 'Y' => {},
                else => return null,
            }

            // '=' separator.
            if (pos >= raw.len) return null;
            if (raw[pos] != '=') return null;
            pos += 1;

            // Value.
            if (pos >= raw.len) return null;
            switch (key) {
                't' => {
                    result.type = std.enums.fromInt(
                        EventType,
                        raw[pos],
                    ) orelse return null;
                    pos += 1;
                },

                'm', 'i', 'o' => {
                    const v = parseUnsigned(raw, &pos) orelse return null;
                    switch (key) {
                        'm' => result.more = v != 0,
                        'i' => result.client_id = v,
                        'o' => result.operation = v,
                        else => unreachable,
                    }
                },

                'x', 'y', 'X', 'Y' => {
                    const negative = raw[pos] == '-';
                    if (negative) pos += 1;
                    const unsigned = parseUnsigned(raw, &pos) orelse return null;
                    // Matches kitty's cast of the u32 magnitude to i32,
                    // which wraps rather than erroring on overflow.
                    const magnitude: i32 = @bitCast(unsigned);
                    const v = if (negative) 0 -% magnitude else magnitude;
                    switch (key) {
                        'x' => result.cell_x = v,
                        'y' => result.cell_y = v,
                        'X' => result.pixel_x = v,
                        'Y' => result.pixel_y = v,
                        else => unreachable,
                    }
                },

                else => unreachable,
            }

            // Values are separated by ':'.
            if (pos >= raw.len) break;
            if (raw[pos] != ':') return null;
        }

        return result;
    }

    /// Parse an unsigned decimal value at `pos`, advancing it. At most
    /// 10 digits and at most maxInt(u32), matching kitty. Returns null
    /// when there are no digits or the value is too large.
    fn parseUnsigned(raw: []const u8, pos: *usize) ?u32 {
        const start = pos.*;
        var acc: u64 = 0;
        var i = start;
        while (i < raw.len and i < start + 10) : (i += 1) {
            const d = raw[i] -% '0';
            if (d > 9) break;
            acc = acc * 10 + d;
        }
        if (i == start) return null;
        pos.* = i;
        return std.math.cast(u32, acc) orelse null;
    }
};

/// The event type, i.e. values for the `t` metadata key. A single OSC 72
/// code is used for both directions of the protocol, so most types have
/// one meaning when received by the terminal from a client and another
/// when sent by the terminal to a client.
///
/// The `drop` and `request_response` types are only ever sent by the
/// terminal; kitty parses but ignores them when received and we do the
/// same.
pub const EventType = enum(u8) {
    /// 'a': (recv) client registers to accept drops. With x=1 the payload
    /// is the client's machine ID for remote drop support instead.
    register = 'a',

    /// 'A': (recv) client unregisters from accepting drops.
    unregister = 'A',

    /// 'm': (recv) client reports acceptance status for the drag currently
    /// over the terminal: `o` is the chosen operation and the payload is
    /// the accepted MIME list. (send) pointer moved over the terminal
    /// during a drag, or with x=-1,y=-1 the drag left the window.
    status = 'm',

    /// 'M': (send only) items were dropped onto the terminal.
    drop = 'M',

    /// 'r': (recv) client requests drop data, or with x=y=Y=0 concludes
    /// the drop with `o` as the performed operation. (send) drop data
    /// response chunks.
    request = 'r',

    /// 'R': (send only) error response to a data request.
    request_error = 'R',

    /// 'o': (recv) drag source control: x=1 enables offering drags (payload
    /// optionally the client machine ID), x=2 disables, x=0 offers a MIME
    /// list for a new drag. (send) request that the client start a drag at
    /// the given position.
    offer = 'o',

    /// 'p': (recv) pre-sent data for an offered drag: x>=0 is a 0-based
    /// MIME index, x<0 attaches drag image -x.
    present = 'p',

    /// 'P': (recv) x=-1 starts the offered drag, x>=0 changes the drag
    /// image mid-drag.
    start_drag = 'P',

    /// 'e': (recv) drag data for MIME index `y` of an in-progress drag.
    /// (send) drag status events (accepted, dropped, finished, ...).
    drag_event = 'e',

    /// 'E': (recv) client aborts the whole drag (y=-1) or reports an error
    /// for MIME index `y`. (send) drag start response (OK or error).
    drag_error = 'E',

    /// 'k': (recv) remote file data for a drag. (send) request for remote
    /// file data.
    remote_data = 'k',

    /// 'q': (recv) query protocol support. (send) the query response.
    query = 'q',
};

/// A drop operation. Values match the protocol's `o` key.
pub const Operation = enum(u2) {
    none = 0,
    copy = 1,
    move = 2,

    /// Convert a protocol `o` value the way kitty does: anything other
    /// than copy or move means none.
    pub fn fromProtocol(v: u32) Operation {
        return switch (v) {
            1 => .copy,
            2 => .move,
            else => .none,
        };
    }
};

/// The set of operations allowed by a drag source, sent as a bitmask in
/// the `o` key of move and drop events.
pub const Operations = packed struct(u2) {
    copy: bool = false,
    move: bool = false,

    pub fn protocolValue(self: Operations) u2 {
        return @bitCast(self);
    }
};

/// A decoded `t=r` data request. The request form is disambiguated by
/// which keys are non-zero, mirroring kitty's drop_process_queue.
pub const Request = union(enum) {
    /// x=y=Y=0: the drop is concluded with the given operation.
    conclude: Operation,

    /// Y=0, y=0, x!=0: request data for the 1-based MIME index x.
    mime: i32,

    /// Y=0, y!=0: request the contents of the y'th (1-based) file in the
    /// text/uri-list MIME at 1-based index x. Remote drops only.
    uri: struct {
        mime_idx: i32,
        uri_idx: i32,
    },

    /// Y!=0: request entry x (1-based) of directory handle Y, or close
    /// the handle when x=0. Remote drops only.
    dir: struct {
        handle: i32,
        entry: i32,
    },

    pub fn init(meta: Metadata) Request {
        if (meta.pixel_y != 0) return .{ .dir = .{
            .handle = meta.pixel_y,
            .entry = meta.cell_x,
        } };
        if (meta.cell_y != 0) return .{ .uri = .{
            .mime_idx = meta.cell_x,
            .uri_idx = meta.cell_y,
        } };
        if (meta.cell_x != 0) return .{ .mime = meta.cell_x };
        return .{ .conclude = .fromProtocol(meta.operation) };
    }
};

/// Chunk reassembly state.
///
/// While a chunked command is in progress, the metadata of the first
/// chunk is reused for all subsequent chunks; only the `more` flag is
/// taken from each continuation.
pub const Chunking = struct {
    active: bool = false,
    metadata: Metadata = .{},

    /// Returns the effective metadata for a received chunk and updates
    /// the reassembly state.
    pub fn apply(self: *Chunking, meta: Metadata) Metadata {
        if (self.active) {
            var copy = self.metadata;
            copy.more = meta.more;
            self.active = meta.more;
            return copy;
        }

        if (meta.more) {
            self.active = true;
            self.metadata = meta;
        }

        return meta;
    }
};

test "Metadata: empty" {
    const testing = std.testing;
    const meta = Metadata.parse("").?;
    try testing.expect(meta.type == null);
    try testing.expect(!meta.more);
    try testing.expectEqual(@as(u32, 0), meta.client_id);
}

test "Metadata: all keys" {
    const testing = std.testing;
    const meta = Metadata.parse("t=m:m=1:i=3:o=2:x=10:y=5:X=320:Y=200").?;
    try testing.expectEqual(EventType.status, meta.type.?);
    try testing.expect(meta.more);
    try testing.expectEqual(@as(u32, 3), meta.client_id);
    try testing.expectEqual(@as(u32, 2), meta.operation);
    try testing.expectEqual(@as(i32, 10), meta.cell_x);
    try testing.expectEqual(@as(i32, 5), meta.cell_y);
    try testing.expectEqual(@as(i32, 320), meta.pixel_x);
    try testing.expectEqual(@as(i32, 200), meta.pixel_y);
}

test "Metadata: all event types" {
    const testing = std.testing;
    const cases = .{
        .{ "t=a", EventType.register },
        .{ "t=A", EventType.unregister },
        .{ "t=m", EventType.status },
        .{ "t=M", EventType.drop },
        .{ "t=r", EventType.request },
        .{ "t=R", EventType.request_error },
        .{ "t=o", EventType.offer },
        .{ "t=p", EventType.present },
        .{ "t=P", EventType.start_drag },
        .{ "t=e", EventType.drag_event },
        .{ "t=E", EventType.drag_error },
        .{ "t=k", EventType.remote_data },
        .{ "t=q", EventType.query },
    };
    inline for (cases) |case| {
        try testing.expectEqual(case[1], Metadata.parse(case[0]).?.type.?);
    }
}

test "Metadata: case-sensitive coordinate keys" {
    const testing = std.testing;
    const meta = Metadata.parse("x=10:Y=200").?;
    try testing.expectEqual(@as(i32, 10), meta.cell_x);
    try testing.expectEqual(@as(i32, 0), meta.cell_y);
    try testing.expectEqual(@as(i32, 0), meta.pixel_x);
    try testing.expectEqual(@as(i32, 200), meta.pixel_y);
}

test "Metadata: negative coordinates" {
    const testing = std.testing;
    const meta = Metadata.parse("t=m:x=-1:y=-1").?;
    try testing.expectEqual(@as(i32, -1), meta.cell_x);
    try testing.expectEqual(@as(i32, -1), meta.cell_y);
}

test "Metadata: malformed inputs rejected" {
    const testing = std.testing;
    // Unknown event type.
    try testing.expect(Metadata.parse("t=z") == null);
    // Unknown key.
    try testing.expect(Metadata.parse("z=1") == null);
    // Missing '=' mid-stream.
    try testing.expect(Metadata.parse("x10") == null);
    // No digits.
    try testing.expect(Metadata.parse("x=notanumber") == null);
    try testing.expect(Metadata.parse("x=-") == null);
    // Too large.
    try testing.expect(Metadata.parse("i=4294967296") == null);
    try testing.expect(Metadata.parse("i=99999999999") == null);
    // Garbage after value.
    try testing.expect(Metadata.parse("x=1z") == null);
    // No whitespace tolerance, matching kitty.
    try testing.expect(Metadata.parse("t=a: x=1") == null);
    try testing.expect(Metadata.parse("t = a") == null);
    // Truncated mid-construct, matching kitty's final-state check.
    // Nothing state-changing may be parsed out of these: e.g. "t=r:x="
    // must not be treated as a drop conclusion.
    try testing.expect(Metadata.parse("t") == null);
    try testing.expect(Metadata.parse("t=") == null);
    try testing.expect(Metadata.parse("x=") == null);
    try testing.expect(Metadata.parse("t=r:x=") == null);
    try testing.expect(Metadata.parse("x=1:t=") == null);
}

test "Metadata: trailing separator accepted" {
    const testing = std.testing;

    // Kitty's state machine accepts the metadata ending right after a
    // value separator.
    const meta = Metadata.parse("t=a:").?;
    try testing.expectEqual(EventType.register, meta.type.?);
}

test "Metadata: u32 boundary accepted" {
    const testing = std.testing;
    const meta = Metadata.parse("i=4294967295").?;
    try testing.expectEqual(@as(u32, std.math.maxInt(u32)), meta.client_id);
}

test "Request: classification" {
    const testing = std.testing;

    // Conclude.
    {
        const r: Request = .init(Metadata.parse("t=r:o=2").?);
        try testing.expectEqual(Operation.move, r.conclude);
    }
    // Conclude with unknown operation is none (canceled).
    {
        const r: Request = .init(Metadata.parse("t=r:o=9").?);
        try testing.expectEqual(Operation.none, r.conclude);
    }
    // MIME data request.
    {
        const r: Request = .init(Metadata.parse("t=r:x=2").?);
        try testing.expectEqual(@as(i32, 2), r.mime);
    }
    // URI file request.
    {
        const r: Request = .init(Metadata.parse("t=r:x=1:y=3").?);
        try testing.expectEqual(@as(i32, 1), r.uri.mime_idx);
        try testing.expectEqual(@as(i32, 3), r.uri.uri_idx);
    }
    // Directory handle request.
    {
        const r: Request = .init(Metadata.parse("t=r:Y=2:x=1").?);
        try testing.expectEqual(@as(i32, 2), r.dir.handle);
        try testing.expectEqual(@as(i32, 1), r.dir.entry);
    }
}

test "Chunking: reassembly reuses first chunk metadata" {
    const testing = std.testing;
    var chunking: Chunking = .{};

    // First chunk starts reassembly.
    const first = chunking.apply(Metadata.parse("t=m:o=1:m=1").?);
    try testing.expect(chunking.active);
    try testing.expectEqual(EventType.status, first.type.?);
    try testing.expect(first.more);

    // Continuation metadata is ignored except for `more`.
    const second = chunking.apply(Metadata.parse("t=q:o=2:m=1").?);
    try testing.expect(chunking.active);
    try testing.expectEqual(EventType.status, second.type.?);
    try testing.expectEqual(@as(u32, 1), second.operation);
    try testing.expect(second.more);

    // Final chunk ends reassembly.
    const last = chunking.apply(Metadata.parse("t=q:m=0").?);
    try testing.expect(!chunking.active);
    try testing.expectEqual(EventType.status, last.type.?);
    try testing.expect(!last.more);
}

test "Chunking: unchunked commands pass through" {
    const testing = std.testing;
    var chunking: Chunking = .{};
    const meta = chunking.apply(Metadata.parse("t=q").?);
    try testing.expect(!chunking.active);
    try testing.expectEqual(EventType.query, meta.type.?);
}
