const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const kitty_gfx = @import("kitty/graphics.zig");

const log = std.log.scoped(.terminal_apc);

/// APC command handler. This should be hooked into a terminal.Stream handler.
/// The start/feed/end functions are meant to be called from the terminal.Stream
/// apcStart, apcPut, and apcEnd functions, respectively.
pub const Handler = struct {
    state: State = .{ .inactive = {} },

    pub fn deinit(self: *Handler) void {
        self.state.deinit();
    }

    pub fn start(self: *Handler) void {
        self.state.deinit();
        self.state = .{ .identify = {} };
    }

    pub fn feed(self: *Handler, alloc: Allocator, byte: u8) void {
        switch (self.state) {
            .inactive => unreachable,

            // We're ignoring this APC command, likely because we don't
            // recognize it so there is no need to store the data in memory.
            .ignore => return,

            // We identify the APC command by the first byte.
            .identify => {
                switch (byte) {
                    // Kitty graphics protocol
                    'G' => self.state = .{ .kitty = kitty_gfx.CommandParser.init(alloc) },

                    // Unknown
                    else => self.state = .{ .ignore = {} },
                }
            },

            .kitty => |*p| p.feed(byte) catch |err| {
                log.warn("kitty graphics protocol error: {}", .{err});
                self.state = .{ .ignore = {} };
            },
        }
    }

    pub fn end(self: *Handler) ?Command {
        defer {
            self.state.deinit();
            self.state = .{ .inactive = {} };
        }

        return switch (self.state) {
            .inactive => unreachable,
            .ignore, .identify => null,
            .kitty => |*p| kitty: {
                const command = p.complete() catch |err| {
                    log.warn("kitty graphics protocol error: {}", .{err});
                    break :kitty null;
                };

                break :kitty .{ .kitty = command };
            },
        };
    }
};

pub const State = union(enum) {
    /// We're not in the middle of an APC command yet.
    inactive: void,

    /// We got an unrecognized APC sequence or the APC sequence we
    /// recognized became invalid. We're just dropping bytes.
    ignore: void,

    /// We're waiting to identify the APC sequence. This is done by
    /// inspecting the first byte of the sequence.
    identify: void,

    /// Kitty graphics protocol
    kitty: kitty_gfx.CommandParser,

    pub fn deinit(self: *State) void {
        switch (self.*) {
            .inactive, .ignore, .identify => {},
            .kitty => |*v| v.deinit(),
        }
    }
};

/// Possible APC commands.
pub const Command = union(enum) {
    kitty: kitty_gfx.Command,

    pub fn deinit(self: *Command, alloc: Allocator) void {
        switch (self.*) {
            .kitty => |*v| v.deinit(alloc),
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
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    h.start();
    for ("Gabcdef1234") |c| h.feed(alloc, c);
    try testing.expect(h.end() == null);
}

test "valid Kitty command" {
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
