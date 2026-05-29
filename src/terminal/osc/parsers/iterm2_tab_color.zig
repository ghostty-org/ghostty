const std = @import("std");

const Parser = @import("../../osc.zig").Parser;
const Command = @import("../../osc.zig").Command;
const TabColor = Command.TabColor;

const log = std.log.scoped(.osc_tab_color);

/// Parse OSC 6, the iTerm2 tab color sequence.
///
/// iTerm2 sets the tab's background color one channel at a time:
///
///     OSC 6 ; 1 ; bg ; red   ; brightness ; <0-255> ST
///     OSC 6 ; 1 ; bg ; green ; brightness ; <0-255> ST
///     OSC 6 ; 1 ; bg ; blue  ; brightness ; <0-255> ST
///
/// And resets it to the default with a wildcard channel:
///
///     OSC 6 ; 1 ; bg ; * ; default ST
///
/// We only support the background ("bg") target since that is what colors
/// the tab. The leading mode field ("1") and the colorspace field
/// ("brightness") are accepted but not otherwise interpreted.
/// https://iterm2.com/documentation-escape-codes.html
pub fn parse(parser: *Parser, _: ?u8) ?*Command {
    const data = data: {
        const cap = if (parser.capture) |*c| c else {
            parser.state = .invalid;
            return null;
        };
        break :data cap.trailing();
    };

    var it = std.mem.splitScalar(u8, data, ';');

    // Mode field. iTerm2 uses "1" here; we accept any value.
    _ = it.next() orelse return invalid(parser);

    // Target. We only support the tab background color.
    const target = it.next() orelse return invalid(parser);
    if (!std.ascii.eqlIgnoreCase(target, "bg")) return invalid(parser);

    // Channel: red, green, blue, or "*" for reset.
    const channel = it.next() orelse return invalid(parser);

    if (std.mem.eql(u8, channel, "*")) {
        // Reset form. The next field must be "default".
        const reset = it.next() orelse return invalid(parser);
        if (!std.ascii.eqlIgnoreCase(reset, "default")) return invalid(parser);

        parser.command = .{ .tab_color = .reset };
        return &parser.command;
    }

    const ch: TabColor.Channel =
        if (std.ascii.eqlIgnoreCase(channel, "red")) .red else if (std.ascii.eqlIgnoreCase(channel, "green")) .green else if (std.ascii.eqlIgnoreCase(channel, "blue")) .blue else return invalid(parser);

    // Colorspace field. iTerm2 uses "brightness"; we accept any value.
    _ = it.next() orelse return invalid(parser);

    // Channel value, 0-255.
    const value_str = it.next() orelse return invalid(parser);
    const value = std.fmt.parseInt(u8, value_str, 10) catch return invalid(parser);

    parser.command = .{ .tab_color = .{ .set = .{ .channel = ch, .value = value } } };
    return &parser.command;
}

fn invalid(parser: *Parser) ?*Command {
    parser.command = .invalid;
    return null;
}

test "OSC 6: set red channel" {
    const testing = std.testing;

    var p: Parser = .init(null);
    for ("6;1;bg;red;brightness;128") |ch| p.next(ch);
    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .tab_color);
    try testing.expect(cmd.tab_color == .set);
    try testing.expectEqual(TabColor.Channel.red, cmd.tab_color.set.channel);
    try testing.expectEqual(@as(u8, 128), cmd.tab_color.set.value);
}

test "OSC 6: set green channel max" {
    const testing = std.testing;

    var p: Parser = .init(null);
    for ("6;1;bg;green;brightness;255") |ch| p.next(ch);
    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .tab_color);
    try testing.expectEqual(TabColor.Channel.green, cmd.tab_color.set.channel);
    try testing.expectEqual(@as(u8, 255), cmd.tab_color.set.value);
}

test "OSC 6: reset" {
    const testing = std.testing;

    var p: Parser = .init(null);
    for ("6;1;bg;*;default") |ch| p.next(ch);
    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .tab_color);
    try testing.expect(cmd.tab_color == .reset);
}

test "OSC 6: case insensitive" {
    const testing = std.testing;

    var p: Parser = .init(null);
    for ("6;1;BG;Blue;Brightness;10") |ch| p.next(ch);
    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .tab_color);
    try testing.expectEqual(TabColor.Channel.blue, cmd.tab_color.set.channel);
}

test "OSC 6: foreground target unsupported" {
    const testing = std.testing;

    var p: Parser = .init(null);
    for ("6;1;fg;red;brightness;10") |ch| p.next(ch);
    try testing.expect(p.end(null) == null);
}

test "OSC 6: unknown channel" {
    const testing = std.testing;

    var p: Parser = .init(null);
    for ("6;1;bg;alpha;brightness;10") |ch| p.next(ch);
    try testing.expect(p.end(null) == null);
}

test "OSC 6: value out of range" {
    const testing = std.testing;

    var p: Parser = .init(null);
    for ("6;1;bg;red;brightness;300") |ch| p.next(ch);
    try testing.expect(p.end(null) == null);
}

test "OSC 6: missing fields" {
    const testing = std.testing;

    var p: Parser = .init(null);
    for ("6;1;bg") |ch| p.next(ch);
    try testing.expect(p.end(null) == null);
}
