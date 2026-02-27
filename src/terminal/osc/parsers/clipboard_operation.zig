const std = @import("std");

const assert = @import("../../../quirks.zig").inlineAssert;

const Parser = @import("../../osc.zig").Parser;
const Command = @import("../../osc.zig").Command;

/// Parse OSC 52
pub fn parse(parser: *Parser, _: ?u8) ?*Command {
    assert(parser.state == .@"52");
    const writer = parser.writer orelse {
        parser.state = .invalid;
        return null;
    };
    writer.writeByte(0) catch {
        parser.state = .invalid;
        return null;
    };
    const data = writer.buffered();
    if (data.len == 1) {
        parser.state = .invalid;
        return null;
    }
    if (data[0] == ';') {
        parser.command = .{
            .clipboard_contents = .{
                .kind = 'c',
                .data = data[1 .. data.len - 1 :0],
            },
        };
    } else {
        if (data.len < 2) {
            parser.state = .invalid;
            return null;
        }
        if (data[1] != ';') {
            parser.state = .invalid;
            return null;
        }
        parser.command = .{
            .clipboard_contents = .{
                .kind = data[0],
                .data = data[2 .. data.len - 1 :0],
            },
        };
    }
    return &parser.command;
}

test "OSC 52: get/set clipboard" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "52;s;?";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .clipboard_contents);
    try testing.expect(cmd.clipboard_contents.kind == 's');
    try testing.expectEqualStrings("?", cmd.clipboard_contents.data);
}

test "OSC 52: get/set clipboard (optional parameter)" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "52;;?";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .clipboard_contents);
    try testing.expect(cmd.clipboard_contents.kind == 'c');
    try testing.expectEqualStrings("?", cmd.clipboard_contents.data);
}

test "OSC 52: get/set clipboard with allocator" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "52;s;?";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .clipboard_contents);
    try testing.expect(cmd.clipboard_contents.kind == 's');
    try testing.expectEqualStrings("?", cmd.clipboard_contents.data);
}

test "OSC 52: clear clipboard" {
    const testing = std.testing;

    var p: Parser = .init(null);
    defer p.deinit();

    const input = "52;;";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .clipboard_contents);
    try testing.expect(cmd.clipboard_contents.kind == 'c');
    try testing.expectEqualStrings("", cmd.clipboard_contents.data);
}
