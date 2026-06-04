const std = @import("std");

/// Query response coverage state for a codepoint.
pub const Coverage = packed struct(u2) {
    /// A system font covers the codepoint.
    system: bool = false,

    /// A session glyph registration covers the codepoint.
    glossary: bool = false,

    /// No system font or registered glyph covers the codepoint.
    pub const free: Coverage = .{};

    /// Parse the query response coverage list from its comma-separated form.
    /// Unknown coverage names are ignored for forward compatibility.
    pub fn init(value: []const u8) ?Coverage {
        var result: Coverage = .free;
        var it = std.mem.splitScalar(u8, value, ',');
        while (it.next()) |name| {
            if (std.mem.eql(u8, name, "system")) {
                result.system = true;
            } else if (std.mem.eql(u8, name, "glossary")) {
                result.glossary = true;
            }
        }

        return result;
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

        /// Optional symbolic error reason.
        reason: ?Reason = null,

        /// Register error reason codes defined by Glyph Protocol §6.2.
        pub const Reason = union(enum) {
            /// `cp` is not in any PUA range.
            out_of_namespace,

            /// Payload contains composite glyphs.
            composite_unsupported,

            /// Payload contains hinting instructions.
            hinting_unsupported,

            /// Payload failed to parse as the declared `fmt`.
            malformed_payload,

            /// Payload exceeds 64 KiB after base64 decoding.
            payload_too_large,

            /// A reason code not known by this version of Ghostty.
            other: []const u8,

            /// Return the wire-format reason name.
            pub fn name(self: Reason) []const u8 {
                return switch (self) {
                    .out_of_namespace => "out_of_namespace",
                    .composite_unsupported => "composite_unsupported",
                    .hinting_unsupported => "hinting_unsupported",
                    .malformed_payload => "malformed_payload",
                    .payload_too_large => "payload_too_large",
                    .other => |value| value,
                };
            }
        };
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
                // From the spec:
                // Order is not significant; clients MUST treat the value as a
                // set. An empty fmt= value means the terminal recognises
                // Glyph Protocol but currently advertises no payload formats
                // — every r will be rejected. Clients MUST ignore names they
                // do not recognise rather than failing the reply, so future
                // format names are forward- compatible.
                try writer.writeAll("s;fmt=");
                var first = true;
                if (r.fmt.glyf) {
                    first = false;
                    try writer.writeAll("glyf");
                }
                if (r.fmt.colrv0) {
                    if (!first) try writer.writeByte(',');
                    first = false;
                    try writer.writeAll("colrv0");
                }
                if (r.fmt.colrv1) {
                    if (!first) try writer.writeByte(',');
                    first = false;
                    try writer.writeAll("colrv1");
                }
            },
            .query => |r| {
                // status is a comma-separated list of coverage names — the
                // set of sources that can render cp in this session. Order is
                // not significant; clients MUST treat the value as a set.
                try writer.print("q;cp={x};status=", .{r.cp});
                var first = true;
                if (r.status.system) {
                    first = false;
                    try writer.writeAll("system");
                }
                if (r.status.glossary) {
                    if (!first) try writer.writeByte(',');
                    try writer.writeAll("glossary");
                }
            },
            .register => |r| {
                try writer.print("r;cp={x};status={d}", .{ r.cp, @intFromEnum(r.status) });
                if (r.reason) |reason| {
                    try writer.writeAll(";reason=");
                    try writer.writeAll(reason.name());
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

test "support formats default to no advertised formats" {
    const testing = std.testing;
    const Formats = Response.Support.Formats;

    try testing.expectEqual(@as(u8, 0), @as(u8, @bitCast(Formats{})));
}

test "response support formatWire" {
    const testing = std.testing;

    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    const resp: Response = .{ .support = .{ .fmt = .{ .glyf = true, .colrv0 = true } } };
    try resp.formatWire(&writer);
    try testing.expectEqualStrings("\x1b_25a1;s;fmt=glyf,colrv0\x1b\\", writer.buffered());
}

test "response support formatWire with no formats" {
    const testing = std.testing;

    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    const resp: Response = .{ .support = .{ .fmt = .{} } };
    try resp.formatWire(&writer);
    try testing.expectEqualStrings("\x1b_25a1;s;fmt=\x1b\\", writer.buffered());
}

test "response query formatWire" {
    const testing = std.testing;

    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    const resp: Response = .{ .query = .{ .cp = 0xE0A0, .status = .{ .system = true, .glossary = true } } };
    try resp.formatWire(&writer);
    try testing.expectEqualStrings("\x1b_25a1;q;cp=e0a0;status=system,glossary\x1b\\", writer.buffered());
}

test "response query formatWire with no coverage" {
    const testing = std.testing;

    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    const resp: Response = .{ .query = .{ .cp = 0xE0A0, .status = .{} } };
    try resp.formatWire(&writer);
    try testing.expectEqualStrings("\x1b_25a1;q;cp=e0a0;status=\x1b\\", writer.buffered());
}

test "coverage parses comma-separated names" {
    const testing = std.testing;

    try testing.expectEqual(Coverage{}, Coverage.init("").?);
    try testing.expectEqual(Coverage{ .system = true }, Coverage.init("system").?);
    try testing.expectEqual(Coverage{ .glossary = true }, Coverage.init("glossary").?);
    try testing.expectEqual(Coverage{ .system = true, .glossary = true }, Coverage.init("system,glossary").?);
    try testing.expectEqual(Coverage{ .system = true, .glossary = true }, Coverage.init("glossary,system").?);
    try testing.expectEqual(Coverage{ .system = true }, Coverage.init("system,future").?);
    try testing.expectEqual(Coverage{}, Coverage.init("future").?);
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

    const resp: Response = .{ .register = .{ .cp = 0xE0A0, .status = .err, .reason = .out_of_namespace } };
    try resp.formatWire(&writer);
    try testing.expectEqualStrings("\x1b_25a1;r;cp=e0a0;status=1;reason=out_of_namespace\x1b\\", writer.buffered());
}

test "response register arbitrary status formatWire" {
    const testing = std.testing;

    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    const resp: Response = .{ .register = .{ .cp = 0xE0A0, .status = @enumFromInt(37), .reason = .payload_too_large } };
    try resp.formatWire(&writer);
    try testing.expectEqualStrings("\x1b_25a1;r;cp=e0a0;status=37;reason=payload_too_large\x1b\\", writer.buffered());
}

test "register reason names" {
    const testing = std.testing;
    const Reason = Response.Register.Reason;

    try testing.expectEqualStrings("out_of_namespace", Reason.out_of_namespace.name());
    try testing.expectEqualStrings("composite_unsupported", Reason.composite_unsupported.name());
    try testing.expectEqualStrings("hinting_unsupported", Reason.hinting_unsupported.name());
    try testing.expectEqualStrings("malformed_payload", Reason.malformed_payload.name());
    try testing.expectEqualStrings("payload_too_large", Reason.payload_too_large.name());
    try testing.expectEqualStrings("future_reason", (Reason{ .other = "future_reason" }).name());
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
