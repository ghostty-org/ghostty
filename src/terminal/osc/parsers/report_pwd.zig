const std = @import("std");

const Parser = @import("../../osc.zig").Parser;
const Command = @import("../../osc.zig").Command;

/// Parse OSC 7
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
        .report_pwd = .{
            .value = data[0 .. data.len - 1 :0],
        },
    };
    return &parser.command;
}

test "OSC 7: report pwd" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "7;file:///tmp/example";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .report_pwd);
    try testing.expectEqualStrings("file:///tmp/example", cmd.report_pwd.value);
}

test "OSC 7: report pwd empty" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "7;";
    for (input) |ch| p.next(ch);
    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .report_pwd);
    try testing.expectEqualStrings("", cmd.report_pwd.value);
}
