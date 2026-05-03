const std = @import("std");

/// Query response coverage state for a codepoint. Encoded on the
/// wire as a comma-separated list of coverage names.
pub const Coverage = enum {
    /// No system font or registered glyph covers the codepoint.
    free,

    /// A system font covers the codepoint.
    system,

    /// A session glyph registration covers the codepoint.
    glossary,

    /// Both the system font and a session registration cover the codepoint.
    both,

    /// Wire form of the `status=` value: a comma-separated list of
    /// coverage names. `free` returns the empty string.
    pub fn asStr(self: Coverage) []const u8 {
        return switch (self) {
            .free => "",
            .system => "system",
            .glossary => "glossary",
            .both => "system,glossary",
        };
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

        pub const Formats = struct {
            /// TrueType simple glyph outlines (required in v1).
            glyf: bool = false,

            /// Write the wire form of `fmt=`: a comma-separated list
            /// of names of the format flags set on `self`. Empty
            /// when no formats are advertised.
            pub fn writeWire(
                self: Formats,
                writer: *std.Io.Writer,
            ) std.Io.Writer.Error!void {
                var first = true;
                inline for (@typeInfo(Formats).@"struct".fields) |field| {
                    if (field.type != bool) continue;
                    if (@field(self, field.name)) {
                        if (!first) try writer.writeAll(",");
                        try writer.writeAll(field.name);
                        first = false;
                    }
                }
            }
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
                try r.fmt.writeWire(writer);
            },
            .query => |r| {
                try writer.print("q;cp={x};status=", .{r.cp});
                try writer.writeAll(r.status.asStr());
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

test "support formats writeWire emits names" {
    const testing = std.testing;
    const Formats = Response.Support.Formats;

    var buf: [64]u8 = undefined;

    var w1: std.Io.Writer = .fixed(&buf);
    try (Formats{ .glyf = true }).writeWire(&w1);
    try testing.expectEqualStrings("glyf", w1.buffered());

    var w2: std.Io.Writer = .fixed(&buf);
    try (Formats{}).writeWire(&w2);
    try testing.expectEqualStrings("", w2.buffered());
}

test "response support formatWire" {
    const testing = std.testing;

    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    const resp: Response = .{ .support = .{ .fmt = .{ .glyf = true } } };
    try resp.formatWire(&writer);
    try testing.expectEqualStrings("\x1b_25a1;s;fmt=glyf\x1b\\", writer.buffered());
}

test "response query formatWire" {
    const testing = std.testing;

    var buf: [256]u8 = undefined;

    var w_both: std.Io.Writer = .fixed(&buf);
    try (Response{ .query = .{ .cp = 0xE0A0, .status = .both } }).formatWire(&w_both);
    try testing.expectEqualStrings(
        "\x1b_25a1;q;cp=e0a0;status=system,glossary\x1b\\",
        w_both.buffered(),
    );

    var w_free: std.Io.Writer = .fixed(&buf);
    try (Response{ .query = .{ .cp = 0xE0A0, .status = .free } }).formatWire(&w_free);
    try testing.expectEqualStrings(
        "\x1b_25a1;q;cp=e0a0;status=\x1b\\",
        w_free.buffered(),
    );
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
