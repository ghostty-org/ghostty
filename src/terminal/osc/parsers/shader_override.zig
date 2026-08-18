const std = @import("std");

const Parser = @import("../../osc.zig").Parser;
const Command = @import("../../osc.zig").Command;

/// Parse OSC 7776 (fork-specific shader override).
/// Expected payload: "shader=on" or "shader=off".
pub fn parse(parser: *Parser, _: ?u8) ?*Command {
    const cap = if (parser.capture) |*c| c else {
        parser.state = .invalid;
        return null;
    };
    cap.writer.writeByte(0) catch {
        parser.state = .invalid;
        return null;
    };
    const data = cap.trailing();
    const payload = data[0 .. data.len - 1 :0];

    if (std.mem.eql(u8, payload, "shader=off")) {
        parser.command = .{ .shader_override = .off };
        return &parser.command;
    } else if (std.mem.eql(u8, payload, "shader=on")) {
        parser.command = .{ .shader_override = .on };
        return &parser.command;
    }

    parser.state = .invalid;
    return null;
}

test "OSC 7776: shader override off" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "7776;shader=off";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .shader_override);
    try testing.expectEqual(.off, cmd.shader_override);
}

test "OSC 7776: shader override on" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "7776;shader=on";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .shader_override);
    try testing.expectEqual(.on, cmd.shader_override);
}

test "OSC 7776: invalid payload" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "7776;shader=maybe";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end(null) == null);
}
