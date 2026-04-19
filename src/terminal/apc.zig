const std = @import("std");
const build_options = @import("terminal_options");
const Allocator = std.mem.Allocator;

const glyph = @import("apc/glyph.zig");
const kitty_gfx = @import("kitty/graphics.zig");

const log = std.log.scoped(.terminal_apc);

/// APC command handler. This should be hooked into a terminal.Stream handler.
/// The start/feed/end functions are meant to be called from the terminal.Stream
/// apcStart, apcPut, and apcEnd functions, respectively.
pub const Handler = struct {
    state: State = .inactive,

    /// Maximum bytes each APC protocol can buffer. This is to prevent
    /// malicious input from causing us to allocate too much memory.
    /// If you want to be lazy and set a single value for all protocols,
    /// use `.initFull`.
    max_bytes: std.EnumMap(Protocol, usize) = .initFullWith(.{
        .kitty = Protocol.defaultMaxBytes(.kitty),
        .glyph = Protocol.defaultMaxBytes(.glyph),
    }),

    pub fn deinit(self: *Handler) void {
        self.state.deinit();
    }

    pub fn start(self: *Handler) void {
        self.state.deinit();
        self.state = .{ .identify = .{} };
    }

    pub fn feed(self: *Handler, alloc: Allocator, byte: u8) void {
        switch (self.state) {
            .inactive => unreachable,

            // We're ignoring this APC command, likely because we don't
            // recognize it so there is no need to store the data in memory.
            .ignore => return,

            // We identify the APC command by the first byte.
            .identify => |*id| id: {
                // Kitty graphics is detected immediately on the `G` byte,
                // since commands begin immediately after with no termination
                // character after the 'G'.
                if (comptime build_options.kitty_graphics) {
                    if (id.len == 0 and byte == 'G') {
                        self.state = .{ .kitty = .init(
                            alloc,
                            self.max_bytes.get(.kitty) orelse
                                Protocol.defaultMaxBytes(.kitty),
                        ) };
                        break :id;
                    }
                }

                // If we hit `;` then identify...
                if (byte == ';') {
                    const str = id.buf[0..id.len];
                    if (std.mem.eql(u8, str, "25a1")) {
                        self.state = .{ .glyph = .init(
                            alloc,
                            self.max_bytes.get(.glyph) orelse
                                Protocol.defaultMaxBytes(.glyph),
                        ) };
                    } else {
                        self.state = .ignore;
                    }

                    break :id;
                }

                // If we're out of space to buffer then we're done.
                if (id.len >= id.buf.len) {
                    self.state = .ignore;
                    break :id;
                }

                id.buf[id.len] = byte;
                id.len += 1;
            },

            .kitty => |*p| if (comptime build_options.kitty_graphics) {
                p.feed(byte) catch |err| {
                    log.warn("kitty graphics protocol error: {}", .{err});
                    p.deinit();
                    self.state = .ignore;
                };
            } else unreachable,

            .glyph => |*p| p.feed(byte) catch |err| {
                log.warn("glyph protocol error: {}", .{err});
                p.deinit();
                self.state = .ignore;
            },
        }
    }

    pub fn end(self: *Handler) ?Command {
        defer {
            self.state.deinit();
            self.state = .inactive;
        }

        return switch (self.state) {
            .inactive => unreachable,
            .ignore, .identify => null,
            .kitty => |*p| kitty: {
                if (comptime !build_options.kitty_graphics) unreachable;

                // Use the same allocator that was used to create the parser.
                const alloc = p.arena.child_allocator;
                const command = p.complete(alloc) catch |err| {
                    log.warn("kitty graphics protocol error: {}", .{err});
                    break :kitty null;
                };

                break :kitty .{ .kitty = command };
            },

            .glyph => |*p| glyph_cmd: {
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
        buf: [4]u8 = undefined,
    },

    /// Kitty graphics protocol
    kitty: if (build_options.kitty_graphics)
        kitty_gfx.CommandParser
    else
        void,

    /// Glyph protocol
    glyph: glyph.CommandParser,

    pub fn deinit(self: *State) void {
        switch (self.*) {
            .inactive, .ignore, .identify => {},
            .glyph => |*v| v.deinit(),
            .kitty => |*v| if (comptime build_options.kitty_graphics)
                v.deinit()
            else
                unreachable,
        }
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
};

/// Possible APC commands.
pub const Command = union(Protocol) {
    kitty: if (build_options.kitty_graphics)
        kitty_gfx.Command
    else
        void,

    glyph: glyph.Request,

    pub fn deinit(self: *Command, alloc: Allocator) void {
        switch (self.*) {
            .kitty => |*v| if (comptime build_options.kitty_graphics)
                v.deinit(alloc)
            else
                unreachable,

            .glyph => |*v| v.deinit(alloc),
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

    var cmd = h.end().?;
    defer cmd.deinit(alloc);
    try testing.expect(cmd == .kitty);
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
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    h.start();
    for ("25a1;q;cp=E0A0") |c| h.feed(alloc, c);

    var cmd = h.end().?;
    defer cmd.deinit(alloc);
    try testing.expect(cmd == .glyph);
    try testing.expect(cmd.glyph == .query);
}
