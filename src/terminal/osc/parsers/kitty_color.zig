const std = @import("std");

const assert = @import("../../../quirks.zig").inlineAssert;

const Parser = @import("../../osc.zig").Parser;
const Command = @import("../../osc.zig").Command;
const kitty_color = @import("../../kitty/color.zig");
const RGB = @import("../../color.zig").RGB;

const log = std.log.scoped(.osc_kitty_color);

/// Parse OSC 21, the Kitty Color Protocol.
pub fn parse(parser: *Parser, terminator_ch: ?u8) ?*Command {
    assert(parser.state == .@"21");

    const alloc = parser.alloc orelse {
        parser.state = .invalid;
        return null;
    };
    const writer = parser.writer orelse {
        parser.state = .invalid;
        return null;
    };
    parser.command = .{
        .kitty_color_protocol = .{
            .list = .empty,
            .terminator = .init(terminator_ch),
        },
    };
    const list = &parser.command.kitty_color_protocol.list;
    const data = writer.buffered();
    var kv_it = std.mem.splitScalar(u8, data, ';');
    while (kv_it.next()) |kv| {
        if (list.items.len >= @as(usize, kitty_color.Kind.max) * 2) {
            log.warn("exceeded limit for number of keys in kitty color protocol, ignoring", .{});
            parser.state = .invalid;
            return null;
        }
        var it = std.mem.splitScalar(u8, kv, '=');
        const k = it.next() orelse continue;
        if (k.len == 0) {
            log.warn("zero length key in kitty color protocol", .{});
            continue;
        }
        const key = kitty_color.Kind.parse(k) orelse {
            log.warn("unknown key in kitty color protocol: {s}", .{k});
            continue;
        };
        const value = std.mem.trim(u8, it.rest(), " ");
        if (value.len == 0) {
            list.append(alloc, .{ .reset = key }) catch |err| {
                log.warn("unable to append kitty color protocol option: {}", .{err});
                continue;
            };
        } else if (std.mem.eql(u8, "?", value)) {
            list.append(alloc, .{ .query = key }) catch |err| {
                log.warn("unable to append kitty color protocol option: {}", .{err});
                continue;
            };
        } else {
            list.append(alloc, .{
                .set = .{
                    .key = key,
                    .color = RGB.parse(value) catch |err| switch (err) {
                        error.InvalidFormat => {
                            log.warn("invalid color format in kitty color protocol: {s}", .{value});
                            continue;
                        },
                    },
                },
            }) catch |err| {
                log.warn("unable to append kitty color protocol option: {}", .{err});
                continue;
            };
        }
    }
    return &parser.command;
}

test "OSC 21: kitty color protocol" {
    const testing = std.testing;
    const Kind = kitty_color.Kind;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "21;foreground=?;background=rgb:f0/f8/ff;cursor=aliceblue;cursor_text;visual_bell=;selection_foreground=#xxxyyzz;selection_background=?;selection_background=#aabbcc;2=?;3=rgbi:1.0/1.0/1.0";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_color_protocol);
    try testing.expectEqual(@as(usize, 9), cmd.kitty_color_protocol.list.items.len);
    {
        const item = cmd.kitty_color_protocol.list.items[0];
        try testing.expect(item == .query);
        try testing.expectEqual(Kind{ .special = .foreground }, item.query);
    }
    {
        const item = cmd.kitty_color_protocol.list.items[1];
        try testing.expect(item == .set);
        try testing.expectEqual(Kind{ .special = .background }, item.set.key);
        try testing.expectEqual(@as(u8, 0xf0), item.set.color.r);
        try testing.expectEqual(@as(u8, 0xf8), item.set.color.g);
        try testing.expectEqual(@as(u8, 0xff), item.set.color.b);
    }
    {
        const item = cmd.kitty_color_protocol.list.items[2];
        try testing.expect(item == .set);
        try testing.expectEqual(Kind{ .special = .cursor }, item.set.key);
        try testing.expectEqual(@as(u8, 0xf0), item.set.color.r);
        try testing.expectEqual(@as(u8, 0xf8), item.set.color.g);
        try testing.expectEqual(@as(u8, 0xff), item.set.color.b);
    }
    {
        const item = cmd.kitty_color_protocol.list.items[3];
        try testing.expect(item == .reset);
        try testing.expectEqual(Kind{ .special = .cursor_text }, item.reset);
    }
    {
        const item = cmd.kitty_color_protocol.list.items[4];
        try testing.expect(item == .reset);
        try testing.expectEqual(Kind{ .special = .visual_bell }, item.reset);
    }
    {
        const item = cmd.kitty_color_protocol.list.items[5];
        try testing.expect(item == .query);
        try testing.expectEqual(Kind{ .special = .selection_background }, item.query);
    }
    {
        const item = cmd.kitty_color_protocol.list.items[6];
        try testing.expect(item == .set);
        try testing.expectEqual(Kind{ .special = .selection_background }, item.set.key);
        try testing.expectEqual(@as(u8, 0xaa), item.set.color.r);
        try testing.expectEqual(@as(u8, 0xbb), item.set.color.g);
        try testing.expectEqual(@as(u8, 0xcc), item.set.color.b);
    }
    {
        const item = cmd.kitty_color_protocol.list.items[7];
        try testing.expect(item == .query);
        try testing.expectEqual(Kind{ .palette = 2 }, item.query);
    }
    {
        const item = cmd.kitty_color_protocol.list.items[8];
        try testing.expect(item == .set);
        try testing.expectEqual(Kind{ .palette = 3 }, item.set.key);
        try testing.expectEqual(@as(u8, 0xff), item.set.color.r);
        try testing.expectEqual(@as(u8, 0xff), item.set.color.g);
        try testing.expectEqual(@as(u8, 0xff), item.set.color.b);
    }
}

test "OSC 21: kitty color protocol without allocator" {
    const testing = std.testing;

    var p: Parser = .init(null);
    defer p.deinit();

    const input = "21;foreground=?";
    for (input) |ch| p.next(ch);
    try testing.expect(p.end('\x1b') == null);
}

test "OSC 21: kitty color protocol double reset" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "21;foreground=?;background=rgb:f0/f8/ff;cursor=aliceblue;cursor_text;visual_bell=;selection_foreground=#xxxyyzz;selection_background=?;selection_background=#aabbcc;2=?;3=rgbi:1.0/1.0/1.0";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_color_protocol);

    p.reset();
    p.reset();
}

test "OSC 21: kitty color protocol reset after invalid" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "21;foreground=?;background=rgb:f0/f8/ff;cursor=aliceblue;cursor_text;visual_bell=;selection_foreground=#xxxyyzz;selection_background=?;selection_background=#aabbcc;2=?;3=rgbi:1.0/1.0/1.0";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_color_protocol);

    p.reset();

    try testing.expectEqual(Parser.State.start, p.state);
    p.next('X');
    try testing.expectEqual(Parser.State.invalid, p.state);

    p.reset();
}

test "OSC 21: kitty color protocol no key" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "21;";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_color_protocol);
    try testing.expectEqual(0, cmd.kitty_color_protocol.list.items.len);
}
