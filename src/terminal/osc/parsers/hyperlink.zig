const std = @import("std");

const Parser = @import("../../osc.zig").Parser;
const Command = @import("../../osc.zig").Command;

const log = std.log.scoped(.osc_hyperlink);

/// Parse OSC 8 hyperlinks
pub fn parse(parser: *Parser, _: ?u8) ?*Command {
    const writer = parser.writer orelse {
        parser.state = .invalid;
        return null;
    };
    writer.writeByte(0) catch {
        parser.state = .invalid;
        return null;
    };
    const data = writer.buffered();
    const s = std.mem.indexOfScalar(u8, data, ';') orelse {
        parser.state = .invalid;
        return null;
    };

    parser.command = .{
        .hyperlink_start = .{
            .uri = data[s + 1 .. data.len - 1 :0],
        },
    };

    data[s] = 0;
    const kvs = data[0 .. s + 1];
    std.mem.replaceScalar(u8, kvs, ':', 0);
    var kv_start: usize = 0;
    while (kv_start < kvs.len) {
        const kv_end = std.mem.indexOfScalarPos(u8, kvs, kv_start + 1, 0) orelse break;
        const kv = data[kv_start .. kv_end + 1];
        const v = std.mem.indexOfScalar(u8, kv, '=') orelse break;
        const key = kv[0..v];
        const value = kv[v + 1 .. kv.len - 1 :0];
        if (std.mem.eql(u8, key, "id")) {
            if (value.len > 0) parser.command.hyperlink_start.id = value;
        } else {
            log.warn("unknown hyperlink option: '{s}'", .{key});
        }
        kv_start = kv_end + 1;
    }

    if (parser.command.hyperlink_start.uri.len == 0) {
        if (parser.command.hyperlink_start.id != null) {
            parser.state = .invalid;
            return null;
        }
        parser.command = .hyperlink_end;
    }

    return &parser.command;
}

test "OSC 8: hyperlink" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "8;;http://example.com";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .hyperlink_start);
    try testing.expectEqualStrings(cmd.hyperlink_start.uri, "http://example.com");
}

test "OSC 8: hyperlink with id set" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "8;id=foo;http://example.com";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .hyperlink_start);
    try testing.expectEqualStrings(cmd.hyperlink_start.id.?, "foo");
    try testing.expectEqualStrings(cmd.hyperlink_start.uri, "http://example.com");
}

test "OSC 8: hyperlink with empty id" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "8;id=;http://example.com";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .hyperlink_start);
    try testing.expectEqual(null, cmd.hyperlink_start.id);
    try testing.expectEqualStrings(cmd.hyperlink_start.uri, "http://example.com");
}

test "OSC 8: hyperlink with incomplete key" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "8;id;http://example.com";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .hyperlink_start);
    try testing.expectEqual(null, cmd.hyperlink_start.id);
    try testing.expectEqualStrings(cmd.hyperlink_start.uri, "http://example.com");
}

test "OSC 8: hyperlink with empty key" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "8;=value;http://example.com";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .hyperlink_start);
    try testing.expectEqual(null, cmd.hyperlink_start.id);
    try testing.expectEqualStrings(cmd.hyperlink_start.uri, "http://example.com");
}

test "OSC 8: hyperlink with empty key and id" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "8;=value:id=foo;http://example.com";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .hyperlink_start);
    try testing.expectEqualStrings(cmd.hyperlink_start.id.?, "foo");
    try testing.expectEqualStrings(cmd.hyperlink_start.uri, "http://example.com");
}

test "OSC 8: hyperlink with empty uri" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "8;id=foo;";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b');
    try testing.expect(cmd == null);
}

test "OSC 8: hyperlink end" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "8;;";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .hyperlink_end);
}
