//! Kitty's clipboard protocol (OSC 5522)
//! Specification: https://sw.kovidgoyal.net/kitty/clipboard/
//! https://rockorager.dev/misc/bracketed-paste-mime/

const std = @import("std");
const build_options = @import("terminal_options");

const assert = @import("../../../quirks.zig").inlineAssert;

const Parser = @import("../../osc.zig").Parser;
const Command = @import("../../osc.zig").Command;
const Terminator = @import("../../osc.zig").Terminator;
const Iterator = @import("../lib.zig").Iterator;
const encoding = @import("../encoding.zig");

const log = std.log.scoped(.kitty_clipboard_protocol);

pub const OSC = struct {
    /// The raw metadata that was received. It can be parsed by using the `readOption` method.
    metadata: []const u8,
    /// The raw payload. It may be Base64 encoded, check the `e` option.
    payload: ?[]const u8,
    /// The terminator that was used in case we need to send a response.
    terminator: Terminator,

    /// Decode an option from the metadata.
    pub fn readOption(self: OSC, comptime key: Option) ?key.Type() {
        return key.read(self.metadata);
    }
};

pub const Location = enum {
    primary,

    pub fn init(str: []const u8) ?Location {
        return std.meta.stringToEnum(Location, str);
    }
};

pub const Operation = enum {
    read,
    walias,
    wdata,
    write,

    pub fn init(str: []const u8) ?Operation {
        return std.meta.stringToEnum(Operation, str);
    }
};

pub const Status = enum {
    DATA,
    DONE,
    EBUSY,
    EINVAL,
    EIO,
    ENOSYS,
    EPERM,
    OK,

    pub fn init(str: []const u8) ?Status {
        return std.meta.stringToEnum(Status, str);
    }
};

pub const Option = enum {
    id,
    loc,
    mime,
    name,
    password,
    pw,
    status,
    type,

    pub fn Type(comptime key: Option) type {
        return switch (key) {
            .id => []const u8,
            .loc => Location,
            .mime => []const u8,
            .name => []const u8,
            .password => []const u8,
            .pw => []const u8,
            .status => Status,
            .type => Operation,
        };
    }

    /// Read the option value from the raw metadata string.
    pub fn read(
        comptime key: Option,
        metadata: []const u8,
    ) ?key.Type() {
        var it: Iterator(Option, isValidMetadataValue, key) = .init(metadata);
        const value = it.next() orelse return null;

        // return the parsed value
        return switch (key) {
            .id => parseIdentifier(value),
            .loc => .init(value),
            .mime => value,
            .name => value,
            .password => value,
            .pw => value,
            .status => .init(value),
            .type => .init(value),
        };
    }
};

/// Characters that are valid in identifiers.
const valid_identifier_characters: []const u8 = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_+.";

fn isValidIdentifier(str: []const u8) bool {
    if (str.len == 0) return false;
    return std.mem.indexOfNone(u8, str, valid_identifier_characters) == null;
}

fn parseIdentifier(str: []const u8) ?[]const u8 {
    if (isValidIdentifier(str)) return str;
    return null;
}

fn isValidMetadataValue(_: []const u8) bool {
    return true;
}

pub fn parse(parser: *Parser, terminator_ch: ?u8) ?*Command {
    assert(parser.state == .@"5522");

    const writer = parser.writer orelse {
        parser.state = .invalid;
        return null;
    };

    const data = writer.buffered();

    const metadata: []const u8, const payload: ?[]const u8 = result: {
        const start = std.mem.indexOfScalar(u8, data, ';') orelse break :result .{ data, null };
        break :result .{ data[0..start], data[start + 1 .. data.len] };
    };

    parser.command = .{
        .kitty_clipboard_protocol = .{
            .metadata = metadata,
            .payload = payload,
            .terminator = .init(terminator_ch),
        },
    };

    return &parser.command;
}

test "OSC: 5522: empty metadata and missing payload" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "5522;";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_clipboard_protocol);
    try testing.expectEqualStrings("", cmd.kitty_clipboard_protocol.metadata);
    try testing.expect(cmd.kitty_clipboard_protocol.payload == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.id) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.loc) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.mime) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.name) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.password) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.pw) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.status) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.type) == null);
}

test "OSC: 5522: empty metadata and empty payload" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "5522;;";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_clipboard_protocol);
    try testing.expectEqualStrings("", cmd.kitty_clipboard_protocol.metadata);
    try testing.expectEqualStrings("", cmd.kitty_clipboard_protocol.payload.?);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.id) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.loc) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.mime) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.name) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.password) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.pw) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.status) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.type) == null);
}

test "OSC: 5522: non-empty metadata and payload" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "5522;type=read;dGV4dC9wbGFpbg==";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_clipboard_protocol);
    try testing.expectEqualStrings("type=read", cmd.kitty_clipboard_protocol.metadata);
    try testing.expectEqualStrings("dGV4dC9wbGFpbg==", cmd.kitty_clipboard_protocol.payload.?);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.id) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.loc) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.mime) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.name) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.password) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.pw) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.status) == null);
    try testing.expectEqual(.read, cmd.kitty_clipboard_protocol.readOption(.type));
}

test "OSC: 5522: empty id" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "5522;id=";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_clipboard_protocol);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.id) == null);
}

test "OSC: 5522: valid id" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "5522;id=5c076ad9-d36f-4705-847b-d4dbf356cc0d";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_clipboard_protocol);
    try testing.expectEqualStrings("5c076ad9-d36f-4705-847b-d4dbf356cc0d", cmd.kitty_clipboard_protocol.readOption(.id).?);
}

test "OSC: 5522: invalid id" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "5522;id=*42*";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_clipboard_protocol);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.id) == null);
}

test "OSC: 5522: invalid status" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "5522;status=BOBR";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_clipboard_protocol);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.status) == null);
}

test "OSC: 5522: valid status" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "5522;status=DONE";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_clipboard_protocol);
    try testing.expectEqual(.DONE, cmd.kitty_clipboard_protocol.readOption(.status).?);
}

test "OSC: 5522: invalid location" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "5522;loc=bobr";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_clipboard_protocol);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.loc) == null);
}

test "OSC: 5522: valid location" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "5522;loc=primary";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_clipboard_protocol);
    try testing.expectEqual(.primary, cmd.kitty_clipboard_protocol.readOption(.loc).?);
}

test "OSC: 5522: password 1" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "5522;pw=R2hvc3R0eQ==:name=Qk9CUiBLVVJXQQ==";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_clipboard_protocol);
    try testing.expectEqualStrings("R2hvc3R0eQ==", cmd.kitty_clipboard_protocol.readOption(.pw).?);
    try testing.expectEqualStrings("Qk9CUiBLVVJXQQ==", cmd.kitty_clipboard_protocol.readOption(.name).?);
}

test "OSC: 5522: password 2" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "5522;password=R2hvc3R0eQ==";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_clipboard_protocol);
    try testing.expectEqualStrings("R2hvc3R0eQ==", cmd.kitty_clipboard_protocol.readOption(.password).?);
}

test "OSC: 5522: example 1" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "5522;type=read:status=OK";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_clipboard_protocol);
    try testing.expect(cmd.kitty_clipboard_protocol.payload == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.id) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.loc) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.mime) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.name) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.password) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.pw) == null);
    try testing.expectEqual(.OK, cmd.kitty_clipboard_protocol.readOption(.status).?);
    try testing.expectEqual(.read, cmd.kitty_clipboard_protocol.readOption(.type).?);
}

test "OSC: 5522: example 2" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "5522;type=read:mime=dGV4dC9wbGFpbg==;R2hvc3R0eQ==";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_clipboard_protocol);
    try testing.expectEqualStrings("R2hvc3R0eQ==", cmd.kitty_clipboard_protocol.payload.?);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.id) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.loc) == null);
    try testing.expectEqualStrings("dGV4dC9wbGFpbg==", cmd.kitty_clipboard_protocol.readOption(.mime).?);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.name) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.password) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.pw) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.status) == null);
    try testing.expectEqual(.read, cmd.kitty_clipboard_protocol.readOption(.type).?);
}

test "OSC: 5522: example 3" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "5522;type=read:status=OK";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_clipboard_protocol);
    try testing.expect(cmd.kitty_clipboard_protocol.payload == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.id) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.loc) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.mime) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.name) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.password) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.pw) == null);
    try testing.expectEqual(.OK, cmd.kitty_clipboard_protocol.readOption(.status).?);
    try testing.expectEqual(.read, cmd.kitty_clipboard_protocol.readOption(.type).?);
}

test "OSC: 5522: example 4" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "5522;type=write";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_clipboard_protocol);
    try testing.expect(cmd.kitty_clipboard_protocol.payload == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.id) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.loc) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.mime) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.name) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.password) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.pw) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.status) == null);
    try testing.expectEqual(.write, cmd.kitty_clipboard_protocol.readOption(.type).?);
}

test "OSC: 5522: example 5" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "5522;type=wdata:mime=dGV4dC9wbGFpbg==;R2hvc3R0eQ==";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_clipboard_protocol);
    try testing.expectEqualStrings("R2hvc3R0eQ==", cmd.kitty_clipboard_protocol.payload.?);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.id) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.loc) == null);
    try testing.expectEqualStrings("dGV4dC9wbGFpbg==", cmd.kitty_clipboard_protocol.readOption(.mime).?);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.name) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.password) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.pw) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.status) == null);
    try testing.expectEqual(.wdata, cmd.kitty_clipboard_protocol.readOption(.type).?);
}

test "OSC: 5522: example 6" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "5522;type=wdata";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_clipboard_protocol);
    try testing.expect(cmd.kitty_clipboard_protocol.payload == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.id) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.loc) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.mime) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.name) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.password) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.pw) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.status) == null);
    try testing.expectEqual(.wdata, cmd.kitty_clipboard_protocol.readOption(.type).?);
}

test "OSC: 5522: example 7" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "5522;type=write:status=DONE";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_clipboard_protocol);
    try testing.expect(cmd.kitty_clipboard_protocol.payload == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.id) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.loc) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.mime) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.name) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.password) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.pw) == null);
    try testing.expectEqual(.DONE, cmd.kitty_clipboard_protocol.readOption(.status).?);
    try testing.expectEqual(.write, cmd.kitty_clipboard_protocol.readOption(.type).?);
}

test "OSC: 5522: example 8" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "5522;type=write:status=EPERM";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_clipboard_protocol);
    try testing.expect(cmd.kitty_clipboard_protocol.payload == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.id) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.loc) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.mime) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.name) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.password) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.pw) == null);
    try testing.expectEqual(.EPERM, cmd.kitty_clipboard_protocol.readOption(.status).?);
    try testing.expectEqual(.write, cmd.kitty_clipboard_protocol.readOption(.type).?);
}

test "OSC: 5522: example 9" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "5522;type=walias:mime=dGV4dC9wbGFpbg==;dGV4dC9odG1sIGFwcGxpY2F0aW9uL2pzb24=";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_clipboard_protocol);
    try testing.expectEqualStrings("dGV4dC9odG1sIGFwcGxpY2F0aW9uL2pzb24=", cmd.kitty_clipboard_protocol.payload.?);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.id) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.loc) == null);
    try testing.expectEqualStrings("dGV4dC9wbGFpbg==", cmd.kitty_clipboard_protocol.readOption(.mime).?);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.name) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.password) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.pw) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.status) == null);
    try testing.expectEqual(.walias, cmd.kitty_clipboard_protocol.readOption(.type).?);
}

test "OSC: 5522: example 10" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "5522;type=read:status=OK:password=Qk9CUiBLVVJXQQ==";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_clipboard_protocol);
    try testing.expect(cmd.kitty_clipboard_protocol.payload == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.id) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.loc) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.mime) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.name) == null);
    try testing.expectEqualStrings("Qk9CUiBLVVJXQQ==", cmd.kitty_clipboard_protocol.readOption(.password).?);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.pw) == null);
    try testing.expectEqual(.OK, cmd.kitty_clipboard_protocol.readOption(.status).?);
    try testing.expectEqual(.read, cmd.kitty_clipboard_protocol.readOption(.type).?);
}

test "OSC: 5522: example 11" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "5522;type=read:status=DATA:mime=dGV4dC9wbGFpbg==";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_clipboard_protocol);
    try testing.expect(cmd.kitty_clipboard_protocol.payload == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.id) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.loc) == null);
    try testing.expectEqualStrings("dGV4dC9wbGFpbg==", cmd.kitty_clipboard_protocol.readOption(.mime).?);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.name) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.password) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.pw) == null);
    try testing.expectEqual(.DATA, cmd.kitty_clipboard_protocol.readOption(.status).?);
    try testing.expectEqual(.read, cmd.kitty_clipboard_protocol.readOption(.type).?);
}

test "OSC: 5522: example 12" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "5522;type=read:mime=dGV4dC9wbGFpbg==:password=Qk9CUiBLVVJXQQ==";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_clipboard_protocol);
    try testing.expect(cmd.kitty_clipboard_protocol.payload == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.id) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.loc) == null);
    try testing.expectEqualStrings("dGV4dC9wbGFpbg==", cmd.kitty_clipboard_protocol.readOption(.mime).?);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.name) == null);
    try testing.expectEqualStrings("Qk9CUiBLVVJXQQ==", cmd.kitty_clipboard_protocol.readOption(.password).?);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.pw) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.status) == null);
    try testing.expectEqual(.read, cmd.kitty_clipboard_protocol.readOption(.type).?);
}

test "OSC: 5522: example 13" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "5522;type=read:status=OK";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_clipboard_protocol);
    try testing.expect(cmd.kitty_clipboard_protocol.payload == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.id) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.loc) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.mime) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.name) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.password) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.pw) == null);
    try testing.expectEqual(.OK, cmd.kitty_clipboard_protocol.readOption(.status).?);
    try testing.expectEqual(.read, cmd.kitty_clipboard_protocol.readOption(.type).?);
}

test "OSC: 5522: example 14" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "5522;type=read:status=DATA:mime=dGV4dC9wbGFpbg==;Qk9CUiBLVVJXQQ==";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_clipboard_protocol);
    try testing.expectEqualStrings("Qk9CUiBLVVJXQQ==", cmd.kitty_clipboard_protocol.payload.?);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.id) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.loc) == null);
    try testing.expectEqualStrings("dGV4dC9wbGFpbg==", cmd.kitty_clipboard_protocol.readOption(.mime).?);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.name) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.password) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.pw) == null);
    try testing.expectEqual(.DATA, cmd.kitty_clipboard_protocol.readOption(.status).?);
    try testing.expectEqual(.read, cmd.kitty_clipboard_protocol.readOption(.type).?);
}

test "OSC: 5522: example 15" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "5522;type=read:status=OK";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_clipboard_protocol);
    try testing.expect(cmd.kitty_clipboard_protocol.payload == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.id) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.loc) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.mime) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.name) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.password) == null);
    try testing.expect(cmd.kitty_clipboard_protocol.readOption(.pw) == null);
    try testing.expectEqual(.OK, cmd.kitty_clipboard_protocol.readOption(.status).?);
    try testing.expectEqual(.read, cmd.kitty_clipboard_protocol.readOption(.type).?);
}
