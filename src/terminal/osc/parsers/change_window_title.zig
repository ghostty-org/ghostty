const std = @import("std");

const Parser = @import("../../osc.zig").Parser;
const Command = @import("../../osc.zig").Command;

/// Parse OSC 0 and OSC 2
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
    parser.command = .{
        .change_window_title = data[0 .. data.len - 1 :0],
    };
    return &parser.command;
}

test "OSC 0: change_window_title" {
    const testing = std.testing;

    var p: Parser = .init(null);
    p.next('0');
    p.next(';');
    p.next('a');
    p.next('b');
    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .change_window_title);
    try testing.expectEqualStrings("ab", cmd.change_window_title);
}

test "OSC 0: longer than buffer" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "0;" ++ "a" ** (Parser.MAX_BUF + 2);
    for (input) |ch| p.next(ch);

    try testing.expect(p.end(null) == null);
}

test "OSC 0: one shorter than buffer length" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const prefix = "0;";
    const title = "a" ** (Parser.MAX_BUF - 1);
    const input = prefix ++ title;
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .change_window_title);
    try testing.expectEqualStrings(title, cmd.change_window_title);
}

test "OSC 0: exactly at buffer length" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const prefix = "0;";
    const title = "a" ** Parser.MAX_BUF;
    const input = prefix ++ title;
    for (input) |ch| p.next(ch);

    // This should be null because we always reserve space for a null terminator.
    try testing.expect(p.end(null) == null);
}
test "OSC 2: change_window_title with 2" {
    const testing = std.testing;

    var p: Parser = .init(null);
    p.next('2');
    p.next(';');
    p.next('a');
    p.next('b');
    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .change_window_title);
    try testing.expectEqualStrings("ab", cmd.change_window_title);
}

test "OSC 2: change_window_title with utf8" {
    const testing = std.testing;

    var p: Parser = .init(null);
    p.next('2');
    p.next(';');
    // '—' EM DASH U+2014 (E2 80 94)
    p.next(0xE2);
    p.next(0x80);
    p.next(0x94);

    p.next(' ');
    // '‐' HYPHEN U+2010 (E2 80 90)
    // Intententionally chosen to conflict with the 0x90 C1 control
    p.next(0xE2);
    p.next(0x80);
    p.next(0x90);
    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .change_window_title);
    try testing.expectEqualStrings("— ‐", cmd.change_window_title);
}

test "OSC 2: change_window_title empty" {
    const testing = std.testing;

    var p: Parser = .init(null);
    p.next('2');
    p.next(';');
    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .change_window_title);
    try testing.expectEqualStrings("", cmd.change_window_title);
}
