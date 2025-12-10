const std = @import("std");
const build_options = @import("terminal_options");
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
                    'G' => self.state = if (comptime build_options.kitty_graphics)
                        .{ .kitty = kitty_gfx.CommandParser.init(alloc) }
                    else
                        .{ .ignore = {} },

                    // Unknown
                    else => self.state = .{ .ignore = {} },
                }
            },

            .kitty => |*p| if (comptime build_options.kitty_graphics) {
                p.feed(byte) catch |err| {
                    log.warn("kitty graphics protocol error: {}", .{err});
                    self.state = .{ .ignore = {} };
                };
            } else unreachable,
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
                if (comptime !build_options.kitty_graphics) unreachable;

                // Use the same allocator that was used to create the parser.
                const alloc = p.arena.child_allocator;
                const command = p.complete(alloc) catch |err| {
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
    kitty: if (build_options.kitty_graphics)
        kitty_gfx.CommandParser
    else
        void,

    pub fn deinit(self: *State) void {
        switch (self.*) {
            .inactive, .ignore, .identify => {},
            .kitty => |*v| if (comptime build_options.kitty_graphics)
                v.deinit()
            else
                unreachable,
        }
    }
};

/// Possible APC commands.
pub const Command = union(enum) {
    kitty: if (build_options.kitty_graphics)
        kitty_gfx.Command
    else
        void,

    pub fn deinit(self: *Command, alloc: Allocator) void {
        switch (self.*) {
            .kitty => |*v| if (comptime build_options.kitty_graphics)
                v.deinit(alloc)
            else
                unreachable,
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
