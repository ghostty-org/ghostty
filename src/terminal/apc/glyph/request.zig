const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

/// Stateful parser for a single glyph APC payload after the `25a1;` prefix.
pub const CommandParser = struct {
    alloc: Allocator,
    data: std.ArrayList(u8) = .empty,

    /// Maximum bytes the data payload can buffer. This is to prevent
    /// malicious input from causing us to allocate too much memory.
    max_bytes: usize,

    pub const Error = Allocator.Error || error{InvalidFormat};

    /// Create a glyph APC parser that buffers the raw command bytes.
    pub fn init(alloc: Allocator, max_bytes: usize) CommandParser {
        return .{ .alloc = alloc, .max_bytes = max_bytes };
    }

    /// Release any buffered command bytes owned by the parser.
    pub fn deinit(self: *CommandParser) void {
        self.data.deinit(self.alloc);
    }

    /// Append one more byte of APC payload to the buffered command.
    pub fn feed(self: *CommandParser, byte: u8) Allocator.Error!void {
        if (self.data.items.len >= self.max_bytes) return error.OutOfMemory;
        try self.data.append(self.alloc, byte);
    }

    /// Finish parsing and return an owned request that can outlive the parser.
    pub fn complete(self: *CommandParser, alloc: Allocator) Error!Request {
        // Normalize bare single-byte verbs like `s` into `s;` so the parsed
        // command always has the standard `verb;...` layout.
        if (self.data.items.len == 1) try self.data.append(self.alloc, ';');

        const raw = try self.data.toOwnedSlice(alloc);

        // Ownership of the buffered bytes has moved to `raw`, so clear the
        // array list before we build the final command value.
        self.data = .empty;
        errdefer alloc.free(raw);
        return try Request.parse(alloc, raw);
    }
};

/// Parsed glyph APC request with the verb classified eagerly.
pub const Request = union(enum) {
    /// Support query (bare `s` verb, no options).
    support,

    /// Codepoint coverage query.
    query: Query,

    /// Glyph registration request.
    register: Register,

    /// Registration clear request.
    clear: Clear,

    /// Query verb payload with lazily-decoded options.
    pub const Query = struct {
        raw: []const u8,

        /// Initialize a query command from owned raw command bytes.
        pub fn init(raw: []const u8) Query {
            return .{ .raw = raw };
        }

        /// Options recognized for the glyph query request.
        pub const Option = enum {
            /// Target Unicode codepoint encoded in hexadecimal.
            cp,

            /// Return the decoded Zig type for a query option.
            pub fn Type(comptime self: Option) type {
                return switch (self) {
                    .cp => u21,
                };
            }

            /// Return the wire-format option key for this query option.
            fn key(comptime self: Option) []const u8 {
                return @tagName(self);
            }

            /// Read and decode a query option from the raw option string.
            pub fn read(comptime self: Option, raw: []const u8) ?self.Type() {
                const value = optionValue(raw, self.key()) orelse return null;
                return switch (self) {
                    .cp => std.fmt.parseInt(u21, value, 16) catch null,
                };
            }
        };

        /// Lazily decode a query option on demand.
        pub fn get(self: Query, comptime option: Option) ?option.Type() {
            return option.read(self.rawOptions());
        }

        /// Return the raw option portion of a valid query command.
        fn rawOptions(self: Query) []const u8 {
            assert(self.raw.len >= 2);
            assert(self.raw[0] == 'q');
            assert(self.raw[1] == ';');
            return self.raw[2..];
        }
    };

    /// Register verb payload with lazily-decoded options and optional base64 data.
    pub const Register = struct {
        raw: []const u8,
        payload_idx: usize,

        /// Initialize a register command from owned raw command bytes.
        pub fn init(raw: []const u8) Register {
            assert(raw.len >= 2);
            assert(raw[0] == 'r');
            assert(raw[1] == ';');
            const payload_idx = std.mem.lastIndexOfScalar(u8, raw, ';').?;
            assert(payload_idx > 1);

            return .{
                .raw = raw,
                .payload_idx = payload_idx,
            };
        }

        /// Options recognized for the glyph register verb.
        pub const Option = enum {
            /// Target Unicode codepoint encoded in hexadecimal.
            cp,

            /// Glyph payload format.
            fmt,

            /// Requested reply verbosity for registration.
            reply,

            /// Units-per-em for the glyph coordinate system.
            upm,

            /// Authored advance width in units-per-em units.
            aw,

            /// Authored line height in units-per-em units.
            lh,

            /// Unicode cell width for terminal layout.
            width,

            /// Glyph scale policy.
            size,

            /// Glyph placement within the render span.
            @"align",

            /// Fractional insets from the render span edges.
            pad,

            /// Return the decoded Zig type for a register option.
            pub fn Type(comptime self: Option) type {
                return switch (self) {
                    .cp => u21,
                    .fmt => Format,
                    .reply => Reply,
                    .upm => u32,
                    .aw => u32,
                    .lh => u32,
                    .width => Width,
                    .size => Size,
                    .@"align" => Align,
                    .pad => Pad,
                };
            }

            /// Return the protocol default value for this option, if any.
            pub fn default(comptime self: Option) ?self.Type() {
                return switch (self) {
                    .cp => null,
                    .fmt => .glyf,
                    .reply => .all,
                    .upm => 1000,
                    .aw => null,
                    .lh => null,
                    .width => .narrow,
                    .size => .height,
                    .@"align" => .{},
                    .pad => .{},
                };
            }

            /// Return the wire-format option key for this register option.
            fn key(comptime self: Option) []const u8 {
                return @tagName(self);
            }

            /// Read and decode a register option from the raw option string.
            pub fn read(comptime self: Option, raw: []const u8) ?self.Type() {
                const value = optionValue(raw, self.key()) orelse return null;
                return switch (self) {
                    .cp => std.fmt.parseInt(u21, value, 16) catch null,
                    .fmt => Format.init(value),
                    .reply => Reply.init(value) orelse .all,
                    .upm => std.fmt.parseInt(u32, value, 10) catch null,
                    .aw => std.fmt.parseInt(u32, value, 10) catch null,
                    .lh => std.fmt.parseInt(u32, value, 10) catch null,
                    .width => Width.init(value),
                    .size => Size.init(value),
                    .@"align" => Align.init(value),
                    .pad => Pad.init(value),
                };
            }
        };

        /// Lazily decode a register option on demand, applying protocol
        /// defaults when the option is omitted.
        pub fn get(self: Register, comptime option: Option) ?option.Type() {
            const raw = self.rawOptions();
            if (optionValue(raw, option.key()) == null) {
                return switch (option) {
                    .aw, .lh => self.get(.upm),
                    else => option.default(),
                };
            }
            return option.read(raw);
        }

        /// Return the base64 payload carried by a register request.
        ///
        /// If no payload is present, this returns an empty slice. The returned
        /// bytes may still be invalid base64; this function only exposes the raw
        /// payload segment and does not validate or decode it.
        pub fn payload(self: Register) []const u8 {
            assert(self.raw.len >= 2);
            assert(self.raw[0] == 'r');
            assert(self.raw[1] == ';');
            return if (self.payload_idx == self.raw.len)
                ""
            else
                self.raw[self.payload_idx + 1 ..];
        }

        /// Return the raw option portion of a valid register command.
        fn rawOptions(self: Register) []const u8 {
            assert(self.raw.len >= 2);
            assert(self.raw[0] == 'r');
            assert(self.raw[1] == ';');
            assert(self.payload_idx >= 2);
            assert(self.payload_idx <= self.raw.len);
            return self.raw[2..self.payload_idx];
        }
    };

    /// Clear verb payload with lazily-decoded options.
    pub const Clear = struct {
        raw: []const u8,

        /// Initialize a clear command from owned raw command bytes.
        pub fn init(raw: []const u8) Clear {
            return .{ .raw = raw };
        }

        /// Options recognized for the glyph clear request.
        pub const Option = enum {
            /// Target Unicode codepoint encoded in hexadecimal.
            cp,

            /// Return the decoded Zig type for a clear option.
            pub fn Type(comptime self: Option) type {
                return switch (self) {
                    .cp => u21,
                };
            }

            /// Return the wire-format option key for this clear option.
            fn key(comptime self: Option) []const u8 {
                return @tagName(self);
            }

            /// Read and decode a clear option from the raw option string.
            pub fn read(comptime self: Option, raw: []const u8) ?self.Type() {
                const value = optionValue(raw, self.key()) orelse return null;
                return switch (self) {
                    .cp => std.fmt.parseInt(u21, value, 16) catch null,
                };
            }
        };

        /// Lazily decode a clear option on demand.
        pub fn get(self: Clear, comptime option: Option) ?option.Type() {
            return option.read(self.rawOptions());
        }

        /// Return the raw option portion of a valid clear command.
        fn rawOptions(self: Clear) []const u8 {
            assert(self.raw.len >= 2);
            assert(self.raw[0] == 'c');
            assert(self.raw[1] == ';');
            return self.raw[2..];
        }
    };

    /// Parse an owned glyph APC payload into its eagerly-classified request
    /// form.
    ///
    /// The raw format here is strict on its requirements to avoid
    /// edge cases: it must contain the request AND the request must
    /// end in a semicolon (even if there are no options). The spec itself
    /// does not require this but we artificially insert it in our parser
    /// to simplify parsing later.
    pub fn parse(alloc: Allocator, raw: []const u8) error{InvalidFormat}!Request {
        if (raw.len < 2) return error.InvalidFormat;
        if (raw[1] != ';') return error.InvalidFormat;

        return switch (raw[0]) {
            's' => {
                alloc.free(raw);
                return .support;
            },
            'q' => .{ .query = .init(raw) },
            'r' => .{ .register = .init(raw) },
            'c' => .{ .clear = .init(raw) },
            else => error.InvalidFormat,
        };
    }

    /// Free the raw bytes retained by any request variant.
    pub fn deinit(self: *Request, alloc: Allocator) void {
        switch (self.*) {
            .support => {},
            inline else => |*cmd| if (cmd.raw.len > 0) alloc.free(cmd.raw),
        }
    }
};

/// Glyph payload formats named by the protocol.
pub const Format = enum {
    /// TrueType simple glyph outline data.
    glyf,

    /// OpenType COLR version 0 layered color glyph data.
    colrv0,

    /// OpenType COLR version 1 paint graph glyph data.
    colrv1,

    /// Parse a glyph payload format name.
    pub fn init(value: []const u8) ?Format {
        return std.meta.stringToEnum(Format, value);
    }
};

/// Register command reply verbosity.
pub const Reply = enum(u2) {
    /// Suppress both success and failure replies.
    none = 0,

    /// Emit replies for both success and failure cases.
    all = 1,

    /// Emit replies only for failure cases.
    failures = 2,

    /// Parse the register command reply mode from its single-digit encoding.
    pub fn init(value: []const u8) ?Reply {
        if (value.len != 1) return null;
        return switch (value[0]) {
            '0' => .none,
            '1' => .all,
            '2' => .failures,
            else => null,
        };
    }
};

/// Register command width override for terminal layout.
pub const Width = enum(u2) {
    /// One terminal cell.
    narrow = 1,

    /// Two terminal cells.
    wide = 2,

    /// Parse the register command width from its single-digit encoding.
    pub fn init(value: []const u8) ?Width {
        if (value.len != 1) return null;
        return switch (value[0]) {
            '1' => .narrow,
            '2' => .wide,
            else => null,
        };
    }
};

/// Register command glyph scale policy.
pub const Size = enum {
    height,
    advance,
    contain,
    cover,
    stretch,

    /// Parse a glyph scale policy name.
    pub fn init(value: []const u8) ?Size {
        return std.meta.stringToEnum(Size, value);
    }
};

/// Register command glyph placement within the render span.
pub const Align = struct {
    horizontal: Horizontal = .center,
    vertical: Vertical = .center,

    pub const Horizontal = enum {
        start,
        center,
        end,

        fn init(value: []const u8) ?Horizontal {
            return std.meta.stringToEnum(Horizontal, value);
        }
    };

    pub const Vertical = enum {
        start,
        center,
        end,
        baseline,

        fn init(value: []const u8) ?Vertical {
            return std.meta.stringToEnum(Vertical, value);
        }
    };

    /// Parse an align value in `<horizontal>,<vertical>` form.
    pub fn init(value: []const u8) ?Align {
        var it = std.mem.splitScalar(u8, value, ',');
        const horizontal = Horizontal.init(it.next() orelse return null) orelse return null;
        const vertical = Vertical.init(it.next() orelse return null) orelse return null;
        if (it.next() != null) return null;

        return .{
            .horizontal = horizontal,
            .vertical = vertical,
        };
    }
};

/// Register command fractional insets from the render span edges.
pub const Pad = struct {
    top: f64 = 0,
    right: f64 = 0,
    bottom: f64 = 0,
    left: f64 = 0,

    /// Parse a pad value in `<top>,<right>,<bottom>,<left>` form.
    pub fn init(value: []const u8) ?Pad {
        var it = std.mem.splitScalar(u8, value, ',');
        const top = parseFraction(it.next() orelse return null) orelse return null;
        const right = parseFraction(it.next() orelse return null) orelse return null;
        const bottom = parseFraction(it.next() orelse return null) orelse return null;
        const left = parseFraction(it.next() orelse return null) orelse return null;
        if (it.next() != null) return null;

        // Glyph Protocol §8.5.2: "If `l + r ≥ 1` or `t + b ≥ 1`
        // the terminal MUST treat the request as if `pad=0,0,0,0`."
        if (left + right >= 1 or top + bottom >= 1) return .{};

        return .{
            .top = top,
            .right = right,
            .bottom = bottom,
            .left = left,
        };
    }

    /// Parse one pad component from the spec's `0.0`–`1.0` fractional range.
    /// Top/bottom fractions are relative to cell height; left/right fractions
    /// are relative to render span width.
    fn parseFraction(value: []const u8) ?f64 {
        const result = std.fmt.parseFloat(f64, value) catch return null;
        if (!(result >= 0 and result <= 1)) return null;
        return result;
    }
};

/// Find the last occurrence of `key=value` for a lazily-parsed option list.
fn optionValue(raw: []const u8, comptime key: []const u8) ?[]const u8 {
    var remaining = raw;
    var result: ?[]const u8 = null;
    while (remaining.len > 0) {
        // Options are semicolon-delimited, so each loop peels off one segment
        // and checks whether it matches the requested key.
        const len = std.mem.indexOfScalar(u8, remaining, ';') orelse remaining.len;
        const full = remaining[0..len];

        if (std.mem.indexOfScalar(u8, full, '=')) |eql_idx| {
            if (std.mem.eql(u8, full[0..eql_idx], key)) {
                result = full[eql_idx + 1 ..];
            }
        }

        if (len == remaining.len) break;
        remaining = remaining[len + 1 ..];
    }

    return result;
}

fn testParse(alloc: Allocator, data: []const u8) CommandParser.Error!Request {
    var parser = CommandParser.init(alloc, 1024 * 1024);
    defer parser.deinit();
    for (data) |byte| try parser.feed(byte);
    return try parser.complete(alloc);
}

test "support command" {
    const testing = std.testing;

    var cmd = try testParse(testing.allocator, "s");
    defer cmd.deinit(testing.allocator);

    try testing.expect(cmd == .support);
}

test "query command" {
    const testing = std.testing;

    var cmd = try testParse(testing.allocator, "q;cp=E0A0");
    defer cmd.deinit(testing.allocator);

    try testing.expect(cmd == .query);
    try testing.expectEqual(@as(u21, 0xE0A0), cmd.query.get(.cp).?);
}

test "register command with payload" {
    const testing = std.testing;

    var cmd = try testParse(
        testing.allocator,
        "r;cp=e0a0;fmt=glyf;upm=1000;reply=2;QQ==",
    );
    defer cmd.deinit(testing.allocator);

    try testing.expect(cmd == .register);
    try testing.expectEqual(@as(u21, 0xE0A0), cmd.register.get(.cp).?);
    try testing.expectEqual(Format.glyf, cmd.register.get(.fmt).?);
    try testing.expectEqual(@as(u32, 1000), cmd.register.get(.upm).?);
    try testing.expectEqual(Reply.failures, cmd.register.get(.reply).?);
    try testing.expectEqualStrings("QQ==", cmd.register.payload());
}

test "register command with sizing and placement options" {
    const testing = std.testing;

    var cmd = try testParse(
        testing.allocator,
        "r;cp=e0a0;upm=2048;aw=1024;lh=1536;width=2;size=contain;align=end,baseline;pad=0.1,0.2,0.3,0.4;QQ==",
    );
    defer cmd.deinit(testing.allocator);

    try testing.expect(cmd == .register);
    try testing.expectEqual(@as(u32, 2048), cmd.register.get(.upm).?);
    try testing.expectEqual(@as(u32, 1024), cmd.register.get(.aw).?);
    try testing.expectEqual(@as(u32, 1536), cmd.register.get(.lh).?);
    try testing.expectEqual(Width.wide, cmd.register.get(.width).?);
    try testing.expectEqual(Size.contain, cmd.register.get(.size).?);
    try testing.expectEqual(Align{
        .horizontal = .end,
        .vertical = .baseline,
    }, cmd.register.get(.@"align").?);
    try testing.expectEqual(Pad{
        .top = 0.1,
        .right = 0.2,
        .bottom = 0.3,
        .left = 0.4,
    }, cmd.register.get(.pad).?);
    try testing.expectEqualStrings("QQ==", cmd.register.payload());
}

test "register option defaults" {
    const testing = std.testing;
    const Option = Request.Register.Option;

    try testing.expect(Option.cp.default() == null);
    try testing.expectEqual(Format.glyf, Option.fmt.default().?);
    try testing.expectEqual(@as(u32, 1000), Option.upm.default().?);
    try testing.expect(Option.aw.default() == null);
    try testing.expect(Option.lh.default() == null);
    try testing.expectEqual(Width.narrow, Option.width.default().?);
    try testing.expectEqual(Size.height, Option.size.default().?);
    try testing.expectEqual(Align{}, Option.@"align".default().?);
    try testing.expectEqual(Pad{}, Option.pad.default().?);
    try testing.expectEqual(Reply.all, Option.reply.default().?);
}

test "register command defaults" {
    const testing = std.testing;

    var cmd = try testParse(testing.allocator, "r;cp=e0a0;QQ==");
    defer cmd.deinit(testing.allocator);

    try testing.expect(cmd == .register);
    try testing.expectEqual(@as(u21, 0xE0A0), cmd.register.get(.cp).?);
    try testing.expectEqual(Format.glyf, cmd.register.get(.fmt).?);
    try testing.expectEqual(@as(u32, 1000), cmd.register.get(.upm).?);
    try testing.expectEqual(@as(u32, 1000), cmd.register.get(.aw).?);
    try testing.expectEqual(@as(u32, 1000), cmd.register.get(.lh).?);
    try testing.expectEqual(Width.narrow, cmd.register.get(.width).?);
    try testing.expectEqual(Size.height, cmd.register.get(.size).?);
    try testing.expectEqual(Align{}, cmd.register.get(.@"align").?);
    try testing.expectEqual(Pad{}, cmd.register.get(.pad).?);
    try testing.expectEqual(Reply.all, cmd.register.get(.reply).?);
}

test "register command aw and lh default to upm" {
    const testing = std.testing;

    var cmd = try testParse(testing.allocator, "r;cp=e0a0;upm=2048;QQ==");
    defer cmd.deinit(testing.allocator);

    try testing.expect(cmd == .register);
    try testing.expectEqual(@as(u32, 2048), cmd.register.get(.aw).?);
    try testing.expectEqual(@as(u32, 2048), cmd.register.get(.lh).?);
}

test "register command invalid sizing and placement options" {
    const testing = std.testing;

    var cmd = try testParse(
        testing.allocator,
        "r;cp=e0a0;width=3;size=invalid;align=center,middle;pad=0,1.2,0,0;QQ==",
    );
    defer cmd.deinit(testing.allocator);

    try testing.expect(cmd == .register);
    try testing.expect(cmd.register.get(.width) == null);
    try testing.expect(cmd.register.get(.size) == null);
    try testing.expect(cmd.register.get(.@"align") == null);
    try testing.expect(cmd.register.get(.pad) == null);
}

test "register command degenerate padding defaults to no padding" {
    const testing = std.testing;

    var cmd = try testParse(
        testing.allocator,
        "r;cp=e0a0;pad=0.4,0.2,0.6,0.1;QQ==",
    );
    defer cmd.deinit(testing.allocator);

    try testing.expect(cmd == .register);
    try testing.expectEqual(Pad{}, cmd.register.get(.pad).?);
}

test "register command invalid reply falls back to reply=1" {
    const testing = std.testing;

    var cmd = try testParse(testing.allocator, "r;cp=e0a0;reply=9;QQ==");
    defer cmd.deinit(testing.allocator);

    try testing.expect(cmd == .register);
    try testing.expectEqual(Reply.all, cmd.register.get(.reply).?);
}

test "register command duplicate options use the last value" {
    const testing = std.testing;

    var cmd = try testParse(testing.allocator, "r;cp=e0a0;reply=1;reply=2;QQ==");
    defer cmd.deinit(testing.allocator);

    try testing.expect(cmd == .register);
    try testing.expectEqual(Reply.failures, cmd.register.get(.reply).?);
}

test "register command with invalid payload" {
    const testing = std.testing;

    var cmd = try testParse(
        testing.allocator,
        "r;cp=e0a0;fmt=glyf;%%%not-base64%%%",
    );
    defer cmd.deinit(testing.allocator);

    try testing.expect(cmd == .register);
    try testing.expectEqual(@as(u21, 0xE0A0), cmd.register.get(.cp).?);
    try testing.expectEqual(Format.glyf, cmd.register.get(.fmt).?);
    try testing.expectEqualStrings("%%%not-base64%%%", cmd.register.payload());
}

test "register response without payload" {
    const testing = std.testing;

    var cmd = try testParse(
        testing.allocator,
        "r;cp=E0A0;status=4;reason=out_of_namespace",
    );
    defer cmd.deinit(testing.allocator);

    // Register parsing is request-only, so the final segment is always treated
    // as payload rather than as a response field.
    try testing.expect(cmd == .register);
    try testing.expectEqual(@as(u21, 0xE0A0), cmd.register.get(.cp).?);
    try testing.expectEqualStrings("reason=out_of_namespace", cmd.register.payload());
}

test "clear command" {
    const testing = std.testing;

    var cmd = try testParse(testing.allocator, "c;cp=e0a0");
    defer cmd.deinit(testing.allocator);

    try testing.expect(cmd == .clear);
    try testing.expectEqual(@as(u21, 0xE0A0), cmd.clear.get(.cp).?);
}

test "invalid command" {
    const testing = std.testing;

    try testing.expectError(
        error.InvalidFormat,
        testParse(testing.allocator, "x"),
    );
}
