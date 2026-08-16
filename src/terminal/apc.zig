const std = @import("std");
const build_options = @import("terminal_options");
const Allocator = std.mem.Allocator;

pub const glyph = @import("apc/glyph.zig");
const kitty_gfx = @import("kitty/graphics.zig");

const log = std.log.scoped(.terminal_apc);

/// APC command handler. This should be hooked into a terminal.Stream handler.
/// The start/feed/end functions are meant to be called from the terminal.Stream
/// apcStart, apcPut, and apcEnd functions, respectively.
pub const Handler = struct {
    state: State = .inactive,

    /// Maximum content bytes retained for unsupported APC identifiers. Zero
    /// drops and ignores unknown APC values.
    unknown_max_bytes: usize = 0,

    /// Maximum bytes each APC protocol can buffer. This is to prevent
    /// malicious input from causing us to allocate too much memory.
    /// If you want to be lazy and set a single value for all protocols,
    /// use `.initFull`.
    max_bytes: std.EnumMap(Protocol, usize) = .initFullWith(.{
        .kitty = Protocol.defaultMaxBytes(.kitty),
        .glyph = Protocol.defaultMaxBytes(.glyph),
    }),

    /// Protocols recognized by this APC handler. When a protocol is absent,
    /// matching APC sequences are ignored and are not reported as unknown.
    enabled: std.EnumSet(Protocol) = .initFull(),

    pub fn deinit(self: *Handler) void {
        self.state.deinit();
    }

    pub fn start(self: *Handler) void {
        self.state.deinit();
        self.state = .{ .identify = .{} };
    }

    /// Enable or disable APC protocol recognition for future APC sequences.
    /// This does not affect any APC command already being parsed.
    pub fn enable(self: *Handler, protocol: Protocol, enabled: bool) void {
        self.enabled.setPresent(protocol, enabled);
    }

    pub fn feed(self: *Handler, alloc: Allocator, byte: u8) void {
        switch (self.state) {
            .inactive => unreachable,

            // We're ignoring this APC command, likely because we don't
            // recognize it so there is no need to store the data in memory.
            .ignore => return,

            // Unsupported APC content is retained only when enabled.
            .unknown => |*unknown| unknown.append(&.{byte}),

            // We identify the APC command by the first byte.
            .identify => |*id| id: {
                // Kitty graphics is detected immediately on the `G` byte,
                // since commands begin immediately after with no termination
                // character after the 'G'.
                if (id.len == 0 and byte == 'G') {
                    if (comptime build_options.kitty_graphics) {
                        if (self.enabled.contains(.kitty)) {
                            self.state = .{ .kitty = .init(
                                alloc,
                                self.max_bytes.get(.kitty) orelse
                                    Protocol.defaultMaxBytes(.kitty),
                            ) };
                        } else {
                            self.state = .ignore;
                        }
                    } else {
                        self.state = .ignore;
                    }
                    break :id;
                }

                // If we hit `;` then identify...
                if (byte == ';') {
                    const str = id.buf[0..id.len];
                    if (std.mem.eql(u8, str, glyph.identifier)) {
                        if (comptime build_options.glyph_protocol) {
                            if (self.enabled.contains(.glyph)) {
                                self.state = .{ .glyph = .init(
                                    alloc,
                                    self.max_bytes.get(.glyph) orelse
                                        Protocol.defaultMaxBytes(.glyph),
                                ) };
                            } else {
                                self.state = .ignore;
                            }
                        } else {
                            self.state = .ignore;
                        }
                    } else {
                        self.beginUnknown(alloc, str, &.{byte});
                    }

                    break :id;
                }

                // If we're out of identification space, the identifier is
                // unsupported. Preserve the buffered prefix before replacing
                // the identify union state.
                if (id.len >= id.buf.len) {
                    self.beginUnknown(alloc, id.buf[0..id.len], &.{byte});
                    break :id;
                }

                const expected_idx: usize = id.len;
                id.buf[id.len] = byte;
                id.len += 1;

                // Once the buffered input is no longer a prefix of a known
                // protocol, it is an unsupported identifier.
                if (self.unknown_max_bytes > 0 and
                    byte != glyph.identifier[expected_idx])
                {
                    self.beginUnknown(alloc, id.buf[0..id.len], &.{});
                }
            },

            .kitty => |*p| if (comptime build_options.kitty_graphics) {
                p.feed(byte) catch |err| {
                    log.warn("kitty graphics protocol error: {}", .{err});
                    p.deinit();
                    self.state = .ignore;
                };
            } else unreachable,

            .glyph => |*p| if (comptime build_options.glyph_protocol) {
                p.feed(byte) catch |err| {
                    log.warn("glyph protocol error: {}", .{err});
                    p.deinit();
                    self.state = .ignore;
                };
            } else unreachable,
        }
    }

    /// Transition from protocol identification to bounded unknown capture.
    fn beginUnknown(
        self: *Handler,
        alloc: Allocator,
        prefix: []const u8,
        suffix: []const u8,
    ) void {
        const max_bytes = self.unknown_max_bytes;
        if (max_bytes == 0) {
            self.state = .ignore;
            return;
        }

        // Build the replacement before overwriting identify because prefix
        // points into that union field.
        var unknown: UnknownBuilder = .init(alloc, max_bytes);
        unknown.append(prefix);
        unknown.append(suffix);
        self.state = .{ .unknown = unknown };
    }

    /// Feed a slice of bytes to the handler. This is equivalent to
    /// calling feed for each byte in order, but protocol payload bytes
    /// are passed through in bulk so large payloads (e.g. Kitty graphics
    /// images) avoid per-byte dispatch overhead.
    pub fn feedSlice(self: *Handler, alloc: Allocator, bytes: []const u8) void {
        var rem = bytes;
        while (rem.len > 0) {
            switch (self.state) {
                .inactive => unreachable,

                // We're ignoring this APC command; drop the whole slice.
                .ignore => return,

                // We're capturing an unknown APC command, so store it.
                .unknown => |*unknown| {
                    unknown.append(rem);
                    return;
                },

                // Identification consumes at most a few bytes; step
                // through them one at a time until the state changes.
                .identify => {
                    self.feed(alloc, rem[0]);
                    rem = rem[1..];
                },

                .kitty => |*p| if (comptime build_options.kitty_graphics) {
                    p.feedSlice(rem) catch |err| {
                        log.warn("kitty graphics protocol error: {}", .{err});
                        p.deinit();
                        self.state = .ignore;
                    };
                    return;
                } else unreachable,

                .glyph => |*p| if (comptime build_options.glyph_protocol) {
                    p.feedSlice(rem) catch |err| {
                        log.warn("glyph protocol error: {}", .{err});
                        p.deinit();
                        self.state = .ignore;
                    };
                    return;
                } else unreachable,
            }
        }
    }

    /// Complete the current APC. The caller owns a returned result and must
    /// call `Command.deinit` with the allocator used while feeding the APC.
    pub fn end(self: *Handler) ?Command {
        defer {
            self.state.deinit();
            self.state = .inactive;
        }

        return switch (self.state) {
            .inactive => unreachable,
            .ignore, .identify => null,
            .unknown => |*unknown| .{ .unknown = unknown.toOwned() },
            .kitty => |*p| kitty: {
                if (comptime !build_options.kitty_graphics) unreachable;

                // Use the same allocator that was used to create the parser.
                const alloc = p.alloc;
                const command = p.complete(alloc) catch |err| {
                    log.warn("kitty graphics protocol error: {}", .{err});
                    break :kitty null;
                };

                break :kitty .{ .kitty = command };
            },

            .glyph => |*p| glyph_cmd: {
                if (comptime !build_options.glyph_protocol) unreachable;

                const command = p.complete(p.alloc) catch |err| {
                    log.warn("glyph protocol error: {}", .{err});
                    break :glyph_cmd null;
                };

                break :glyph_cmd .{ .glyph = command };
            },
        };
    }
};

pub const State = union(enum) {
    /// We're not in the middle of an APC command yet.
    inactive,

    /// We got an unrecognized APC sequence or the APC sequence we
    /// recognized became invalid. We're just dropping bytes.
    ignore,

    /// We're waiting to identify the APC sequence. The way this is done
    /// is pretty fluid depending on supported APC protocols, but for now
    /// our rule is:
    ///
    ///  * 'G' - immediate transition to Kitty graphics protocol
    ///  * Buffer up to `;` and the bytes before dictate the protocol.
    ///    If we overflow then we're immediately invalid because we don't
    ///    support anything longer than this.
    ///
    identify: struct {
        len: u3 = 0,
        buf: [glyph.identifier.len]u8 = undefined,
    },

    /// Kitty graphics protocol
    kitty: if (build_options.kitty_graphics)
        kitty_gfx.CommandParser
    else
        void,

    /// Glyph protocol
    glyph: if (build_options.glyph_protocol)
        glyph.CommandParser
    else
        void,

    /// An unsupported APC retained for the optional unknown callback.
    /// Keep this after recognized protocol states so their tag values and
    /// generated dispatch stay stable when unknown capture is unused.
    unknown: UnknownBuilder,

    pub fn deinit(self: *State) void {
        switch (self.*) {
            .inactive, .ignore, .identify => {},
            .unknown => |*v| v.deinit(),
            .glyph => |*v| if (comptime build_options.glyph_protocol)
                v.deinit()
            else
                unreachable,
            .kitty => |*v| if (comptime build_options.kitty_graphics)
                v.deinit()
            else
                unreachable,
        }
    }
};

/// UnknownBuilder is responsible for accumulating bytes for an
/// unidentified APC command if unknown capture is enabled.
const UnknownBuilder = struct {
    data: std.ArrayList(u8) = .empty,
    alloc: Allocator,
    max_bytes: usize,
    truncated: bool = false,

    fn init(alloc: Allocator, max_bytes: usize) UnknownBuilder {
        return .{
            .alloc = alloc,
            .max_bytes = max_bytes,
        };
    }

    fn deinit(self: *UnknownBuilder) void {
        self.data.deinit(self.alloc);
        self.data = .empty;
    }

    // Append some bytes to the unknown capture. This flags as truncated
    // if allocation fails or we reach our byte limit, therefore
    // it can't fail.
    fn append(self: *UnknownBuilder, bytes: []const u8) void {
        if (bytes.len == 0) return;
        const current = self.data.items.len;

        // Determine how many bytes we can store in this append and
        // if it is less than our input, then we have to note we're
        // truncating.
        const retained = @min(bytes.len, self.max_bytes -| current);
        if (retained < bytes.len) self.truncated = true;

        // If we require more bytes than our capacity allows then we
        // need to grow.
        const required = current + retained;
        if (required > self.data.capacity) {
            const capacity = @min(
                self.max_bytes,
                @max(required, @max(self.data.capacity *| 2, 1)),
            );
            self.data.ensureTotalCapacityPrecise(
                self.alloc,
                capacity,
            ) catch {
                self.truncated = true;
                return;
            };
        }

        self.data.appendSliceAssumeCapacity(bytes[0..retained]);
    }

    /// Convert the current capture state to an Unknown where allocator
    /// ownership shifts to Unknown. Removes any accumulated unknown
    /// capture in this struct.
    ///
    /// This can't fail because if there is an allocator issue we return
    /// an empty truncate-flagged Unknown.
    fn toOwned(self: *UnknownBuilder) Unknown {
        // toOwnedSlice allows us to reuse data but this makes error
        // handling a little simpler.
        const content = self.data.toOwnedSlice(self.alloc) catch {
            self.data.deinit(self.alloc);
            self.data = .empty;
            return .{
                .content = self.data.items,
                .truncated = true,
            };
        };

        return .{
            .content = content,
            .truncated = self.truncated,
        };
    }
};

/// An unsupported APC returned by `Handler.end`.
pub const Unknown = struct {
    content: []u8,
    truncated: bool,

    pub fn deinit(self: *Unknown, alloc: Allocator) void {
        if (self.content.len > 0) alloc.free(self.content);
        self.* = undefined;
    }
};

/// Possible APC command types.
pub const Protocol = enum {
    kitty,
    glyph,

    /// Returns the default maximum bytes for the given protocol.
    pub fn defaultMaxBytes(self: Protocol) usize {
        return switch (self) {
            // Kitty graphics payloads can be very large (e.g. full images
            // encoded as base64), so the default is set to 65 MiB.
            .kitty => 65 * 1024 * 1024,
            // Glyph protocol messages carry single glyf outlines which
            // are small, but base64 encoding inflates them. 1 MiB is
            // generous for any single simple-glyph record.
            .glyph => 1 * 1024 * 1024,
        };
    }

    /// Return the largest default buffer limit across every APC protocol.
    /// Consumers that must retain any unfinished APC can derive their limit
    /// here instead of duplicating a particular protocol's current default.
    pub fn maxDefaultBytes() usize {
        var result: usize = 0;
        for (std.enums.values(Protocol)) |protocol| {
            result = @max(result, protocol.defaultMaxBytes());
        }
        return result;
    }
};

/// A recognized or unsupported APC command.
pub const Command = union(enum) {
    kitty: if (build_options.kitty_graphics)
        kitty_gfx.Command
    else
        void,

    glyph: if (build_options.glyph_protocol)
        glyph.Request
    else
        void,

    unknown: Unknown,

    pub fn deinit(self: *Command, alloc: Allocator) void {
        switch (self.*) {
            .kitty => |*v| if (comptime build_options.kitty_graphics)
                v.deinit(alloc)
            else
                unreachable,

            .glyph => |*v| if (comptime build_options.glyph_protocol)
                v.deinit(alloc)
            else
                unreachable,

            .unknown => |*v| v.deinit(alloc),
        }
    }
};

test "unknown APC command" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    h.start();
    for ("Xabcdef1234") |c| h.feed(alloc, c);
    try testing.expect(h.end() == null);
}

test "capture unknown APC command" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{ .unknown_max_bytes = 5 };
    defer h.deinit();
    h.start();
    h.feedSlice(alloc, "abcd;payload");

    var result = h.end().?;
    defer result.deinit(alloc);
    const unknown = &result.unknown;
    try testing.expectEqualStrings("abcd;", unknown.content);
    try testing.expect(unknown.truncated);
}

test "capture short unknown APC command" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{ .unknown_max_bytes = 16 };
    defer h.deinit();
    h.start();
    h.feed(alloc, 'X');

    var result = h.end().?;
    const unknown = &result.unknown;
    try testing.expectEqualStrings("X", unknown.content);
    try testing.expect(!unknown.truncated);
    result.deinit(alloc);

    h.unknown_max_bytes = 1;
    h.start();
    h.feedSlice(alloc, "XYZ");
    result = h.end().?;
    const truncated = &result.unknown;
    try testing.expectEqualStrings("X", truncated.content);
    try testing.expect(truncated.truncated);
    result.deinit(alloc);
}

test "disabled known APC protocol is not unknown" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{ .unknown_max_bytes = 64 };
    defer h.deinit();
    h.enable(.glyph, false);
    h.start();
    h.feedSlice(alloc, "25a1;q;cp=E0A0");
    try testing.expect(h.end() == null);

    // An incomplete known protocol identifier is malformed, not unknown.
    h.start();
    h.feedSlice(alloc, "25a");
    try testing.expect(h.end() == null);
}

test "garbage Kitty command" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    h.start();
    for ("Gabcdef1234") |c| h.feed(alloc, c);
    try testing.expect(h.end() == null);
}

test "Kitty command with overflow u32" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    h.start();
    for ("Ga=p,i=10000000000") |c| h.feed(alloc, c);
    try testing.expect(h.end() == null);
}

test "Kitty command with overflow i32" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    h.start();
    for ("Ga=p,i=1,z=-9999999999") |c| h.feed(alloc, c);
    try testing.expect(h.end() == null);
}

test "kitty feed error deinits parser" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    // Feed a valid kitty command start to allocate parser state, then
    // trigger an error during feed via an integer overflow. The testing
    // allocator will detect leaks if deinit is not called.
    var h: Handler = .{};
    defer h.deinit();
    h.start();
    for ("Ga=p,i=10000000000;") |c| h.feed(alloc, c);
    try testing.expect(h.state == .ignore);
}

test "kitty max bytes exceeded" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{ .max_bytes = .init(.{ .kitty = 4 }) };
    defer h.deinit();
    h.start();
    // 'G' identifies kitty, 'a=t;' moves to data state, then feed exceeds max_bytes.
    for ("Ga=t;") |c| h.feed(alloc, c);
    try testing.expect(h.state != .ignore);
    for ("abcd") |c| h.feed(alloc, c);
    try testing.expect(h.state != .ignore);
    // The 5th data byte exceeds the 4-byte limit.
    h.feed(alloc, 'e');
    try testing.expect(h.state == .ignore);
}

test "valid Kitty command" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    h.start();
    const input = "Gf=24,s=10,v=20,hello=world";
    for (input) |c| h.feed(alloc, c);

    var result = h.end().?;
    defer result.deinit(alloc);
    try testing.expect(result == .kitty);
}

test "identify with unrecognized command" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    h.start();
    for ("abcd;payload") |c| h.feed(alloc, c);
    try testing.expect(h.end() == null);
}

test "identify buffer overflow" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    h.start();
    for ("abcde;payload") |c| h.feed(alloc, c);
    try testing.expect(h.end() == null);
}

test "identify with no input" {
    const testing = std.testing;

    var h: Handler = .{};
    h.start();
    try testing.expect(h.end() == null);
}

test "identify with unknown partial input" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    h.start();
    for ("25a") |c| h.feed(alloc, c);
    try testing.expect(h.end() == null);
}

test "garbage glyph command" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    h.start();
    for ("25a1;X") |c| h.feed(alloc, c);

    try testing.expect(h.end() == null);
}

test "valid glyph command" {
    if (comptime !build_options.glyph_protocol) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    h.start();
    for ("25a1;q;cp=E0A0") |c| h.feed(alloc, c);

    var result = h.end().?;
    defer result.deinit(alloc);
    try testing.expect(result == .glyph);
    try testing.expect(result.glyph == .query);
}

test "feedSlice valid Kitty command" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    h.start();
    h.feedSlice(alloc, "Gf=24,s=10,v=20;aGVsbG8=");

    var result = h.end().?;
    defer result.deinit(alloc);
    try testing.expect(result == .kitty);

    // The payload is base64-decoded by the parser on completion.
    try testing.expectEqualStrings("hello", result.kitty.data);
}

test "feedSlice identify split across slices" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    h.start();
    h.feedSlice(alloc, "G");
    h.feedSlice(alloc, "f=24,s=10,");
    h.feedSlice(alloc, "v=20;aGVsbG8=");

    var result = h.end().?;
    defer result.deinit(alloc);
    try testing.expect(result == .kitty);

    // The payload is base64-decoded by the parser on completion.
    try testing.expectEqualStrings("hello", result.kitty.data);
}

test "feedSlice unknown APC command is ignored" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    h.start();
    h.feedSlice(alloc, "Xabcdef1234");
    try testing.expect(h.state == .ignore);
    h.feedSlice(alloc, "more data that is dropped");
    try testing.expect(h.end() == null);
}

test "feedSlice valid glyph command" {
    if (comptime !build_options.glyph_protocol) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    h.start();
    h.feedSlice(alloc, "25a1;q;cp=E0A0");

    var result = h.end().?;
    defer result.deinit(alloc);
    try testing.expect(result == .glyph);
    try testing.expect(result.glyph == .query);
}

test "feedSlice kitty max bytes exceeded" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{ .max_bytes = .init(.{ .kitty = 4 }) };
    defer h.deinit();
    h.start();
    h.feedSlice(alloc, "Ga=t;abcd");
    try testing.expect(h.state != .ignore);
    h.feedSlice(alloc, "e");
    try testing.expect(h.state == .ignore);
}

test "disabled glyph command is ignored" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    h.enable(.glyph, false);
    h.start();
    for ("25a1;q;cp=e0a0") |c| h.feed(alloc, c);
    try testing.expect(h.end() == null);
}
