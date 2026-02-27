//! Kitty's text sizing protocol (OSC 66)
//! Specification: https://sw.kovidgoyal.net/kitty/text-sizing-protocol/

const std = @import("std");
const build_options = @import("terminal_options");

const assert = @import("../../../quirks.zig").inlineAssert;

const Parser = @import("../../osc.zig").Parser;
const Command = @import("../../osc.zig").Command;
const encoding = @import("../encoding.zig");
const lib = @import("../../../lib/main.zig");
const lib_target: lib.Target = if (build_options.c_abi) .c else .zig;

const log = std.log.scoped(.kitty_text_sizing);

pub const max_payload_length = 4096;

pub const VAlign = lib.Enum(lib_target, &.{
    "top",
    "bottom",
    "center",
});

pub const HAlign = lib.Enum(lib_target, &.{
    "left",
    "right",
    "center",
});

pub const OSC = struct {
    scale: u3 = 1, // 1 - 7
    width: u3 = 0, // 0 - 7 (0 means default)
    numerator: u4 = 0,
    denominator: u4 = 0,
    valign: VAlign = .top,
    halign: HAlign = .left,
    text: [:0]const u8,

    /// We don't currently support encoding this to C in any way.
    pub const C = void;

    pub fn cval(_: OSC) C {
        return {};
    }

    fn update(self: *OSC, key: u8, value: []const u8) error{
        UnknownKey,
        InvalidValue,
    }!void {
        // All values are numeric, so we can do a small hack here
        const v = std.fmt.parseInt(
            u4,
            value,
            10,
        ) catch return error.InvalidValue;

        switch (key) {
            's' => {
                if (v == 0) return error.InvalidValue;
                self.scale = std.math.cast(u3, v) orelse return error.InvalidValue;
            },
            'w' => self.width = std.math.cast(u3, v) orelse return error.InvalidValue,
            'n' => self.numerator = v,
            'd' => self.denominator = v,
            'v' => self.valign = std.enums.fromInt(VAlign, v) orelse return error.InvalidValue,
            'h' => self.halign = std.enums.fromInt(HAlign, v) orelse return error.InvalidValue,
            else => return error.UnknownKey,
        }
    }
};

pub fn parse(parser: *Parser, _: ?u8) ?*Command {
    assert(parser.state == .@"66");

    const writer = parser.writer orelse {
        parser.state = .invalid;
        return null;
    };

    // Write a NUL byte to ensure that `text` is NUL-terminated
    writer.writeByte(0) catch {
        parser.state = .invalid;
        return null;
    };
    const data = writer.buffered();

    const payload_start = std.mem.indexOfScalar(u8, data, ';') orelse {
        log.warn("missing semicolon before payload", .{});
        parser.state = .invalid;
        return null;
    };
    const payload = data[payload_start + 1 .. data.len - 1 :0];

    // Payload has to be a URL-safe UTF-8 string,
    // and be under the size limit.
    if (payload.len > max_payload_length) {
        log.warn("payload is too long", .{});
        parser.state = .invalid;
        return null;
    }
    if (!encoding.isSafeUtf8(payload)) {
        log.warn("payload is not escape code safe UTF-8", .{});
        parser.state = .invalid;
        return null;
    }

    parser.command = .{
        .kitty_text_sizing = .{ .text = payload },
    };
    const cmd = &parser.command.kitty_text_sizing;

    // Parse any arguments if given
    if (payload_start > 0) {
        var kv_it = std.mem.splitScalar(
            u8,
            data[0..payload_start],
            ':',
        );

        while (kv_it.next()) |kv| {
            var it = std.mem.splitScalar(u8, kv, '=');
            const k = it.next() orelse {
                log.warn("missing key", .{});
                continue;
            };
            if (k.len != 1) {
                log.warn("key must be a single character", .{});
                continue;
            }

            const value = it.next() orelse {
                log.warn("missing value", .{});
                continue;
            };

            cmd.update(k[0], value) catch |err| {
                switch (err) {
                    error.UnknownKey => log.warn("unknown key: '{c}'", .{k[0]}),
                    error.InvalidValue => log.warn("invalid value for key '{c}': {}", .{ k[0], err }),
                }
                continue;
            };
        }
    }

    return &parser.command;
}

test "OSC 66: empty parameters" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "66;;bobr";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_text_sizing);
    try testing.expectEqual(1, cmd.kitty_text_sizing.scale);
    try testing.expectEqualStrings("bobr", cmd.kitty_text_sizing.text);
}

test "OSC 66: single parameter" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "66;s=2;kurwa";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_text_sizing);
    try testing.expectEqual(2, cmd.kitty_text_sizing.scale);
    try testing.expectEqualStrings("kurwa", cmd.kitty_text_sizing.text);
}

test "OSC 66: multiple parameters" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "66;s=2:w=7:n=13:d=15:v=1:h=2;long";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_text_sizing);
    try testing.expectEqual(2, cmd.kitty_text_sizing.scale);
    try testing.expectEqual(7, cmd.kitty_text_sizing.width);
    try testing.expectEqual(13, cmd.kitty_text_sizing.numerator);
    try testing.expectEqual(15, cmd.kitty_text_sizing.denominator);
    try testing.expectEqual(.bottom, cmd.kitty_text_sizing.valign);
    try testing.expectEqual(.center, cmd.kitty_text_sizing.halign);
    try testing.expectEqualStrings("long", cmd.kitty_text_sizing.text);
}

test "OSC 66: scale is zero" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "66;s=0;nope";
    for (input) |ch| p.next(ch);
    const cmd = p.end('\x1b').?.*;

    try testing.expect(cmd == .kitty_text_sizing);
    try testing.expectEqual(1, cmd.kitty_text_sizing.scale);
}

test "OSC 66: invalid parameters" {
    const testing = std.testing;

    var p: Parser = .init(null);

    for ("66;w=8:v=3:n=16;") |ch| p.next(ch);
    const cmd = p.end('\x1b').?.*;

    try testing.expect(cmd == .kitty_text_sizing);
    try testing.expectEqual(0, cmd.kitty_text_sizing.width);
    try testing.expect(cmd.kitty_text_sizing.valign == .top);
    try testing.expectEqual(0, cmd.kitty_text_sizing.numerator);
}

test "OSC 66: UTF-8" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "66;;👻魑魅魍魉ゴースッティ";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_text_sizing);
    try testing.expectEqualStrings("👻魑魅魍魉ゴースッティ", cmd.kitty_text_sizing.text);
}

test "OSC 66: unsafe UTF-8" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "66;;\n";
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}

test "OSC 66: overlong UTF-8" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "66;;" ++ "bobr" ** 1025;
    for (input) |ch| p.next(ch);

    try testing.expect(p.end('\x1b') == null);
}
