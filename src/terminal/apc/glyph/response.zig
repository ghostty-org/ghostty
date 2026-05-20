const std = @import("std");

/// Query response coverage state for a codepoint.
pub const Coverage = enum(u2) {
    /// No system font or registered glyph covers the codepoint.
    free = 0,

    /// A system font covers the codepoint.
    system = 1,

    /// A session glyph registration covers the codepoint.
    glossary = 2,

    /// Both the system font and a session registration cover the codepoint.
    both = 3,

    /// Parse the query response coverage bitfield from its decimal form.
    pub fn init(value: []const u8) ?Coverage {
        const raw = std.fmt.parseInt(u2, value, 10) catch return null;
        return std.meta.intToEnum(Coverage, raw) catch null;
    }
};

/// Response to a glyph APC request, formatted for the wire protocol.
pub const Response = union(enum) {
    /// Support query response listing supported payload formats.
    support: Support,

    /// Codepoint coverage query response.
    query: Query,

    /// Glyph registration response (success or error).
    register: Register,

    /// Registration clear response.
    clear: Clear,

    /// Support query response fields.
    pub const Support = struct {
        /// Supported payload formats.
        fmt: Formats,

        pub const Formats = packed struct(u8) {
            /// TrueType simple glyph outlines (required in v1).
            glyf: bool = false,

            /// COLR v0 layered flat-colour glyphs.
            colrv0: bool = false,

            /// COLR v1 paint-graph glyphs.
            colrv1: bool = false,

            _padding: u5 = 0,
        };
    };

    /// Codepoint query response fields.
    pub const Query = struct {
        /// The queried codepoint.
        cp: u21,

        /// Coverage status for the codepoint.
        status: Coverage,
    };

    /// Register response fields.
    pub const Register = struct {
        /// The target codepoint of the registration.
        cp: u21,

        /// Result status of the registration encoded as a decimal u8.
        status: Status = .ok,

        /// Optional symbolic error reason (e.g. `out_of_namespace`).
        reason: ?[]const u8 = null,
    };

    /// Clear response fields.
    pub const Clear = struct {
        /// Result status of the clear operation encoded as a decimal u8.
        status: Status = .ok,

        /// Optional symbolic error reason.
        reason: ?[]const u8 = null,
    };

    /// Status code for register and clear responses.
    pub const Status = enum(u8) {
        /// The operation completed successfully.
        ok = 0,

        /// A generic or unspecified error occurred.
        err = 1,

        _,
    };

    /// Write the response in the glyph APC wire format to `writer`.
    ///
    /// The framing is: `ESC _ 25a1 ; <verb> ; <key=value>* ESC \`
    pub fn formatWire(
        self: Response,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.writeAll("\x1b_25a1;");
        switch (self) {
            .support => |r| {
                try writer.writeAll("s;fmt=");
                try writer.print("{d}", .{@as(u8, @bitCast(r.fmt))});
            },
            .query => |r| {
                try writer.print("q;cp={x};status={d}", .{ r.cp, @intFromEnum(r.status) });
            },
            .register => |r| {
                try writer.print("r;cp={x};status={d}", .{ r.cp, @intFromEnum(r.status) });
                if (r.reason) |reason| {
                    try writer.writeAll(";reason=");
                    try writer.writeAll(reason);
                }
            },
            .clear => |r| {
                try writer.print("c;status={d}", .{@intFromEnum(r.status)});
                if (r.reason) |reason| {
                    try writer.writeAll(";reason=");
                    try writer.writeAll(reason);
                }
            },
        }
        try writer.writeAll("\x1b\\");
    }
};

test "support formats bit layout" {
    const testing = std.testing;
    const Formats = Response.Support.Formats;

    try testing.expectEqual(@as(u8, 1), @as(u8, @bitCast(Formats{ .glyf = true })));
    try testing.expectEqual(@as(u8, 2), @as(u8, @bitCast(Formats{ .colrv0 = true })));
    try testing.expectEqual(@as(u8, 4), @as(u8, @bitCast(Formats{ .colrv1 = true })));
    try testing.expectEqual(@as(u8, 7), @as(u8, @bitCast(Formats{ .glyf = true, .colrv0 = true, .colrv1 = true })));
}

test "response support formatWire" {
    const testing = std.testing;

    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    const resp: Response = .{ .support = .{ .fmt = .{ .glyf = true, .colrv0 = true } } };
    try resp.formatWire(&writer);
    try testing.expectEqualStrings("\x1b_25a1;s;fmt=3\x1b\\", writer.buffered());
}

test "response query formatWire" {
    const testing = std.testing;

    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    const resp: Response = .{ .query = .{ .cp = 0xE0A0, .status = .both } };
    try resp.formatWire(&writer);
    try testing.expectEqualStrings("\x1b_25a1;q;cp=e0a0;status=3\x1b\\", writer.buffered());
}

test "response register success formatWire" {
    const testing = std.testing;

    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    const resp: Response = .{ .register = .{ .cp = 0xE0A0 } };
    try resp.formatWire(&writer);
    try testing.expectEqualStrings("\x1b_25a1;r;cp=e0a0;status=0\x1b\\", writer.buffered());
}

test "response register error formatWire" {
    const testing = std.testing;

    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    const resp: Response = .{ .register = .{ .cp = 0xE0A0, .status = .err, .reason = "out_of_namespace" } };
    try resp.formatWire(&writer);
    try testing.expectEqualStrings("\x1b_25a1;r;cp=e0a0;status=1;reason=out_of_namespace\x1b\\", writer.buffered());
}

test "response register arbitrary status formatWire" {
    const testing = std.testing;

    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    const resp: Response = .{ .register = .{ .cp = 0xE0A0, .status = @enumFromInt(37), .reason = "payload_too_large" } };
    try resp.formatWire(&writer);
    try testing.expectEqualStrings("\x1b_25a1;r;cp=e0a0;status=37;reason=payload_too_large\x1b\\", writer.buffered());
}

test "response clear formatWire" {
    const testing = std.testing;

    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    const resp: Response = .{ .clear = .{} };
    try resp.formatWire(&writer);
    try testing.expectEqualStrings("\x1b_25a1;c;status=0\x1b\\", writer.buffered());
}

test "response clear error formatWire" {
    const testing = std.testing;

    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    const resp: Response = .{ .clear = .{ .status = .err, .reason = "out_of_namespace" } };
    try resp.formatWire(&writer);
    try testing.expectEqualStrings("\x1b_25a1;c;status=1;reason=out_of_namespace\x1b\\", writer.buffered());
}
