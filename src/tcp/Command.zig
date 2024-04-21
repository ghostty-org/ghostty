const std = @import("std");
const log = std.log.scoped(.tcp_thread);
const Server = @import("Server.zig");

const ping = @import("commands/ping.zig").ping;

pub const Command = enum {
    ping,

    pub const Error = error{
        InvalidInput,
        InvalidCommand,
    };

    /// Takes the bytes from our TCP handle and parses them into a Command.
    pub fn parse(raw_read: []const u8) !Command {
        const trimmed = std.mem.trim(u8, raw_read, "\t\n\r");

        if (trimmed.len == 0) {
            return error.InvalidInput;
        }

        var iter = std.mem.splitScalar(u8, trimmed, ' ');

        // Not using .first() because it returns everything if there is no space
        // Instead we're doing what's equivalent to popping the first element
        const cmdName = iter.next() orelse return error.InvalidInput;
        // TODO: Handle/support arguments

        return std.meta.stringToEnum(Command, cmdName) orelse
            return error.InvalidCommand;
    }

    pub fn handle(self: Command, server: *Server) ![]const u8 {
        _ = server; // TODO: Only pass into commands that actually need it
        switch (self) {
            .ping => return ping(),
        }
    }

    pub fn handleError(err: Command.Error) ![]const u8 {
        switch (err) {
            error.InvalidInput => return "INVALID INPUT\n",
            error.InvalidCommand => return "INVALID COMMAND\n",
        }
    }
};

test "Command.parse ping" {
    const input = "ping";
    const expected = Command.ping;
    const result = try Command.parse(input);
    try std.testing.expect(result == expected);
}

test "Command.parse invalid input" {
    const input = "";
    const result = Command.parse(input);
    try std.testing.expectError(Command.Error.InvalidInput, result);
}
