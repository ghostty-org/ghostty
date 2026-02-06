//! Kitty's desktop notification protocol (OSC 99)
//! Specification: https://sw.kovidgoyal.net/kitty/desktop-notifications/

const std = @import("std");
const build_options = @import("terminal_options");

const assert = @import("../../../quirks.zig").inlineAssert;

const Parser = @import("../../osc.zig").Parser;
const Command = @import("../../osc.zig").Command;
const Terminator = @import("../../osc.zig").Terminator;
const encoding = @import("../encoding.zig");
const lib = @import("../../../lib/main.zig");
const lib_target: lib.Target = if (build_options.c_abi) .c else .zig;

const log = std.log.scoped(.kitty_desktop_notification);

pub const OSC = struct {
    /// The raw metadata that was received. It can be parsed by using the `readOption` method.
    metadata: []const u8,
    /// The raw payload. It may be Base64 encoded, check the `e` option.
    payload: []const u8,
    /// The terminator that was used in case we need to send a response.
    terminator: Terminator,

    /// Decode an option from the metadata.
    pub fn readOption(self: OSC, comptime key: Option) key.Type() {
        return key.read(self.metadata);
    }
};

pub const Action = packed struct {
    focus: bool,
    report: bool,

    pub const default: Action = .{
        .focus = true,
        .report = false,
    };

    pub fn init(str: []const u8) Action {
        return parsePackedStruct(Action, str);
    }
};

pub const Occasion = enum {
    always,
    invisible,
    unfocused,

    pub const default: Occasion = .always;

    pub fn init(str: []const u8) Occasion {
        return std.meta.stringToEnum(Occasion, str) orelse .default;
    }
};

pub const Payload = enum {
    alive,
    body,
    buttons,
    close,
    icon,
    query,
    title,
    /// This is a special value to indicate that an unknown payload value was
    /// specified and it should be ignored.
    unknown,

    pub const default: Payload = .title;

    pub fn init(str: []const u8) Payload {
        if (str.len == 1 and str[0] == '?') return .query;
        // The string `query` is not allowed, it should be a single question
        // mark if you want a query.
        if (std.mem.eql(u8, "query", str)) return .unknown;
        return std.meta.stringToEnum(Payload, str) orelse .unknown;
    }
};

pub const Urgency = enum {
    low,
    normal,
    high,

    pub const default: Urgency = .normal;

    pub fn init(str: []const u8) Urgency {
        if (str.len != 1) return .default;
        return switch (str[0]) {
            '0' => .low,
            '1' => .normal,
            '2' => .high,
            else => .default,
        };
    }
};

pub const Option = enum {
    /// What action(s) should be taken when a notification is clicked.
    a,
    /// Should a notification be sent to the application when the notification
    /// is closed?
    c,
    /// Are we done with the notification, and it is ready to be sent?
    d,
    /// Is the payload encoded with Base64?
    e,
    /// The name of the application that is sending the notification.
    f,
    /// Identifier for icon data. Only used when the payload is icon data.
    g,
    /// Identifier for the notification.
    i,
    /// Icon name.
    n,
    /// When to honor the notification request.
    o,
    /// Type of the payload.
    p,
    /// The sound name to play with the notification.
    s,
    /// The type of the notification.
    t,
    /// The urgency of the notification.
    u,
    /// When to auto-close the notification.
    w,

    pub fn Type(comptime key: Option) type {
        return switch (key) {
            .a => Action,
            .c => bool,
            .d => bool,
            .e => bool,
            .f => ?[]const u8,
            .g => ?[]const u8,
            .i => ?[]const u8,
            .n => Iterator(.n),
            .o => Occasion,
            .p => Payload,
            .s => []const u8,
            .t => Iterator(.t),
            .u => Urgency,
            .w => i32,
        };
    }

    pub fn default(comptime key: Option) key.Type() {
        return switch (key) {
            .a => .default,
            .c => false,
            .d => true,
            .e => false,
            .f => null,
            .g => null,
            .i => null,
            .n => unreachable,
            .o => .default,
            .p => .default,
            .s => "system",
            .t => unreachable,
            .u => .default,
            .w => -1,
        };
    }

    /// Read the option value from the raw metadata string.
    ///
    /// Any errors in the raw string will return null since the OSC 99
    /// specification says to ignore unknown or malformed options.
    pub fn read(
        comptime key: Option,
        metadata: []const u8,
    ) key.Type() {
        var it: Iterator(key) = switch (key) {
            inline .t, .n => return .init(metadata),
            inline else => .init(metadata),
        };

        const value = it.next() orelse return key.default();

        // return the parsed value, the iterator guarantees that it's a valid
        // metadata value
        return switch (key) {
            .a => .init(value),
            .c => parseBool(value) orelse key.default(),
            .d => parseBool(value) orelse key.default(),
            .e => parseBool(value) orelse key.default(),
            .f => value,
            .g => parseIdentifier(value),
            .i => parseIdentifier(value),
            .n => unreachable,
            .o => .init(value),
            .p => .init(value),
            .s => value,
            .t => unreachable,
            .u => .init(value),
            .w => value: {
                // Zig's integer parser allows '_', we don't
                if (std.mem.indexOfScalar(u8, value, '_')) |_| break :value key.default();
                const tmp = std.fmt.parseInt(i32, value, 10) catch break :value key.default();
                // negative values less than -1 are not allowed
                if (tmp < -1) break :value key.default();
                break :value tmp;
            },
        };
    }
};

/// Parse the protocol's booleans
fn parseBool(str: []const u8) ?bool {
    if (str.len != 1) return null;
    return switch (str[0]) {
        '0' => false,
        '1' => true,
        else => null,
    };
}

/// This is similar to the packed struct parser used in the configs. The
/// differences are that a literal `true` or `false` value does not turn on/off
/// all the values, and the negation prefix is `-` not `no-`.
pub fn parsePackedStruct(comptime T: type, str: []const u8) T {
    const info = @typeInfo(T).@"struct";
    comptime assert(info.layout == .@"packed");

    var result: T = .default;

    // We split each value by ","
    var iter = std.mem.splitSequence(u8, str, ",");
    loop: while (iter.next()) |raw| {
        // Determine the field we're looking for and the value. If the
        // field is prefixed with "-" then we set the value to false.
        const part, const value = part: {
            const negation_prefix = "-";
            const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
            if (std.mem.startsWith(u8, trimmed, negation_prefix)) {
                break :part .{ trimmed[negation_prefix.len..], false };
            } else {
                break :part .{ trimmed, true };
            }
        };

        inline for (info.fields) |field| {
            comptime assert(field.type == bool);
            if (std.mem.eql(u8, field.name, part)) {
                @field(result, field.name) = value;
                continue :loop;
            }
        }

        // No field matched
        return .default;
    }

    return result;
}

/// Characters that are valid in a metadata value. Including `=` is technically
/// against the spec but is needed since Base64 encoded values (with padding)
/// are valid for some options. Including `?` is technically against the spec
/// but is needed since it is a valid value for the `p` option.
const valid_metadata_value_characters: []const u8 = valid_identifier_characters ++ "/.,(){}[]*&^%$#@!`~=?";

fn isValidMetadataValue(str: []const u8) bool {
    return std.mem.indexOfNone(u8, str, valid_metadata_value_characters) == null;
}

/// Characters that are valid in identifiers.
const valid_identifier_characters: []const u8 = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_+";

fn isValidIdentifier(str: []const u8) bool {
    return std.mem.indexOfNone(u8, str, valid_identifier_characters) == null;
}

fn parseIdentifier(str: []const u8) ?[]const u8 {
    if (isValidIdentifier(str)) return str;
    return null;
}

/// Used to iterate over matching key/values in the metadata
pub fn Iterator(comptime key: Option) type {
    return struct {
        metadata: []const u8,
        pos: usize,

        pub fn init(metadata: []const u8) Iterator(key) {
            return .{
                .metadata = metadata,
                .pos = 0,
            };
        }

        /// Return the value of the next matching key. The value is guaranteed
        /// to be `null` or a valid metadata value.
        pub fn next(self: *Iterator(key)) ?[]const u8 {
            // bail if we are out of metadata
            if (self.pos >= self.metadata.len) return null;
            while (self.pos < self.metadata.len) {
                // skip any whitespace
                while (self.pos < self.metadata.len and std.ascii.isWhitespace(self.metadata[self.pos])) self.pos += 1;
                // bail if we are out of metadata
                if (self.pos >= self.metadata.len) return null;
                if (self.metadata[self.pos] != @tagName(key)[0]) {
                    // this isn't the key we are looking for, skip to the next option, or bail if
                    // there is no next option
                    self.pos = std.mem.indexOfScalarPos(u8, self.metadata, self.pos, ':') orelse {
                        self.pos = self.metadata.len;
                        return null;
                    };
                    self.pos += 1;
                    continue;
                }
                // skip past the key
                self.pos += 1;
                // skip any whitespace
                while (self.pos < self.metadata.len and std.ascii.isWhitespace(self.metadata[self.pos])) self.pos += 1;
                // bail if we are out of metadata
                if (self.pos >= self.metadata.len) return null;
                // a valid option has an '='
                if (self.metadata[self.pos] != '=') return null;
                // the end of the value is bounded by a ':' or the end of the metadata
                const end = std.mem.indexOfScalarPos(u8, self.metadata, self.pos, ':') orelse self.metadata.len;
                const start = self.pos + 1;
                self.pos = end + 1;
                // strip any leading or trailing whitespace
                const value = std.mem.trim(u8, self.metadata[start..end], &std.ascii.whitespace);
                // if this is not a valid value, skip it
                if (!isValidMetadataValue(value)) continue;
                // return the value
                return value;
            }
            // the key was not found
            return null;
        }
    };
}

pub fn parse(parser: *Parser, terminator_ch: ?u8) ?*Command {
    assert(parser.state == .@"99");

    const writer = parser.writer orelse {
        parser.state = .invalid;
        return null;
    };

    const data = writer.buffered();

    const payload_start = std.mem.indexOfScalar(u8, data, ';') orelse {
        log.warn("missing semicolon before payload", .{});
        parser.state = .invalid;
        return null;
    };

    const metadata = data[0..payload_start];
    const payload = data[payload_start + 1 .. data.len];

    // Payload has to be a URL-safe UTF-8 string.
    if (!encoding.isSafeUtf8(payload)) {
        log.warn("payload is not escape code safe UTF-8", .{});
        parser.state = .invalid;
        return null;
    }

    parser.command = .{
        .kitty_desktop_notification = .{
            .metadata = metadata,
            .payload = payload,
            .terminator = .init(terminator_ch),
        },
    };

    return &parser.command;
}

test "OSC 99: empty metadata and payload" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;;";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("", cmd.kitty_desktop_notification.metadata);
    try testing.expectEqualStrings("", cmd.kitty_desktop_notification.payload);
    try testing.expectEqualDeep(Option.a.default(), cmd.kitty_desktop_notification.readOption(.a));
    try testing.expect(cmd.kitty_desktop_notification.readOption(.c) == false);
    try testing.expect(cmd.kitty_desktop_notification.readOption(.d) == true);
    try testing.expect(cmd.kitty_desktop_notification.readOption(.e) == false);
    try testing.expect(cmd.kitty_desktop_notification.readOption(.f) == null);
    try testing.expect(cmd.kitty_desktop_notification.readOption(.g) == null);
    try testing.expect(cmd.kitty_desktop_notification.readOption(.i) == null);
    {
        var it = cmd.kitty_desktop_notification.readOption(.n);
        try testing.expect(it.next() == null);
    }
    try testing.expectEqual(.always, cmd.kitty_desktop_notification.readOption(.o));
    try testing.expectEqual(.title, cmd.kitty_desktop_notification.readOption(.p));
    try testing.expectEqualStrings("system", cmd.kitty_desktop_notification.readOption(.s));
    {
        var it = cmd.kitty_desktop_notification.readOption(.t);
        try testing.expect(it.next() == null);
    }
    try testing.expectEqual(.normal, cmd.kitty_desktop_notification.readOption(.u));
    try testing.expectEqual(-1, cmd.kitty_desktop_notification.readOption(.w));
    try testing.expectEqual(.st, cmd.kitty_desktop_notification.terminator);
}

test "OSC 99: empty metadata with payload" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;;bobr";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("", cmd.kitty_desktop_notification.metadata);
    try testing.expectEqualStrings("bobr", cmd.kitty_desktop_notification.payload);
    try testing.expectEqualDeep(Option.a.default(), cmd.kitty_desktop_notification.readOption(.a));
    try testing.expect(cmd.kitty_desktop_notification.readOption(.c) == false);
    try testing.expect(cmd.kitty_desktop_notification.readOption(.d) == true);
    try testing.expect(cmd.kitty_desktop_notification.readOption(.e) == false);
    try testing.expect(cmd.kitty_desktop_notification.readOption(.f) == null);
    try testing.expect(cmd.kitty_desktop_notification.readOption(.g) == null);
    try testing.expect(cmd.kitty_desktop_notification.readOption(.i) == null);
    {
        var it = cmd.kitty_desktop_notification.readOption(.n);
        try testing.expect(it.next() == null);
    }
    try testing.expectEqual(.always, cmd.kitty_desktop_notification.readOption(.o));
    try testing.expectEqual(.title, cmd.kitty_desktop_notification.readOption(.p));
    try testing.expectEqualStrings("system", cmd.kitty_desktop_notification.readOption(.s));
    {
        var it = cmd.kitty_desktop_notification.readOption(.t);
        try testing.expect(it.next() == null);
    }
    try testing.expectEqual(.normal, cmd.kitty_desktop_notification.readOption(.u));
    try testing.expectEqual(-1, cmd.kitty_desktop_notification.readOption(.w));
}

test "OSC 99: single parameter i" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;i=bobr;kurwa";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("bobr", cmd.kitty_desktop_notification.readOption(.i).?);
    try testing.expectEqualStrings("kurwa", cmd.kitty_desktop_notification.payload);
}

test "OSC 99: repeated parameter i" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;i=bobr:i=foobar;kurwa";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("bobr", cmd.kitty_desktop_notification.readOption(.i).?);
    try testing.expectEqualStrings("kurwa", cmd.kitty_desktop_notification.payload);
}

test "OSC 99: multiple types" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;t=bobr: t = kurwa : t = ghostty ;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    var it = cmd.kitty_desktop_notification.readOption(.t);
    try testing.expectEqualStrings("bobr", it.next().?);
    try testing.expectEqualStrings("kurwa", it.next().?);
    try testing.expectEqualStrings("ghostty", it.next().?);
    try testing.expect(it.next() == null);
}

test "OSC 99: a 1" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;a=report,focus;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    try testing.expectEqualDeep(Action{ .report = true, .focus = true }, cmd.kitty_desktop_notification.readOption(.a));
}

test "OSC 99: a 2" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;a=report,-focus;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    try testing.expectEqualDeep(Action{ .report = true, .focus = false }, cmd.kitty_desktop_notification.readOption(.a));
}

test "OSC 99: a 3" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;a=-report,focus;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    try testing.expectEqualDeep(Action{ .report = false, .focus = true }, cmd.kitty_desktop_notification.readOption(.a));
}

test "OSC 99: a 4" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;a=-report,-focus;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    try testing.expectEqualDeep(Action{ .report = false, .focus = false }, cmd.kitty_desktop_notification.readOption(.a));
}

test "OSC 99: c 1" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;c=0;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    try testing.expect(cmd.kitty_desktop_notification.readOption(.c) == false);
}

test "OSC 99: c 2" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;c=1;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    try testing.expect(cmd.kitty_desktop_notification.readOption(.c) == true);
}

test "OSC 99: c 3" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;c=bobr;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    try testing.expect(cmd.kitty_desktop_notification.readOption(.c) == false);
}

test "OSC 99: d 1" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;d=0;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    try testing.expect(cmd.kitty_desktop_notification.readOption(.d) == false);
}

test "OSC 99: d 2" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;d=1;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    try testing.expect(cmd.kitty_desktop_notification.readOption(.d) == true);
}

test "OSC 99: d 3" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;d=bobr;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    try testing.expect(cmd.kitty_desktop_notification.readOption(.d) == true);
}

test "OSC 99: e 1" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;e=0;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    try testing.expect(cmd.kitty_desktop_notification.readOption(.e) == false);
}

test "OSC 99: e 2" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;e=1;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    try testing.expect(cmd.kitty_desktop_notification.readOption(.e) == true);
}

test "OSC 99: e 3" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;e=bobr;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    try testing.expect(cmd.kitty_desktop_notification.readOption(.e) == false);
}

test "OSC 99: f 1" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;f=R2hvc3R0eQ==;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    try testing.expectEqualStrings("R2hvc3R0eQ==", cmd.kitty_desktop_notification.readOption(.f).?);
}

test "OSC 99: f 2" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;c=0:f= R2hvc3R0eQ== ;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    try testing.expectEqualStrings("R2hvc3R0eQ==", cmd.kitty_desktop_notification.readOption(.f).?);
}

test "OSC 99: g 1" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;c=0:g=7f8a9129-a35d-4e9f-8043-ce2700e15e2c;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    try testing.expectEqualStrings("7f8a9129-a35d-4e9f-8043-ce2700e15e2c", cmd.kitty_desktop_notification.readOption(.g).?);
}

test "OSC 99: g 2" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;c=0:g=aaa*bbb;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    try testing.expect(cmd.kitty_desktop_notification.readOption(.g) == null);
}

test "OSC 99: i 1" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    try testing.expect(cmd.kitty_desktop_notification.readOption(.i) == null);
}

test "OSC 99: i 2" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;i=bobr;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    try testing.expectEqualStrings("bobr", cmd.kitty_desktop_notification.readOption(.i).?);
}

test "OSC 99: i 3" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;i=;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    try testing.expectEqualStrings("", cmd.kitty_desktop_notification.readOption(.i).?);
}

test "OSC 99: i 4" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;i= :;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    try testing.expectEqualStrings("", cmd.kitty_desktop_notification.readOption(.i).?);
}

test "OSC 99: i 5" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;i= bobr ;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    try testing.expectEqualStrings("bobr", cmd.kitty_desktop_notification.readOption(.i).?);
}

test "OSC 99: i 6" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;i= bobr : i=kurwa ;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    try testing.expectEqualStrings("bobr", cmd.kitty_desktop_notification.readOption(.i).?);
}

test "OSC 99: n 1" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;n=R2hvc3R0eQ==;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    var it = cmd.kitty_desktop_notification.readOption(.n);
    try testing.expectEqualStrings("R2hvc3R0eQ==", it.next().?);
    try testing.expect(it.next() == null);
}

test "OSC 99: n 2" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;n=R2hvc3R0eQ==:n=R2hvc3R0eQ==;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    var it = cmd.kitty_desktop_notification.readOption(.n);
    try testing.expectEqualStrings("R2hvc3R0eQ==", it.next().?);
    try testing.expectEqualStrings("R2hvc3R0eQ==", it.next().?);
    try testing.expect(it.next() == null);
}

test "OSC 99: o 1" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;o= ;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    try testing.expectEqual(.always, cmd.kitty_desktop_notification.readOption(.o));
}

test "OSC 99: o 2" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;o=always;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    try testing.expectEqual(.always, cmd.kitty_desktop_notification.readOption(.o));
}

test "OSC 99: o 3" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;o=unfocused;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    try testing.expectEqual(.unfocused, cmd.kitty_desktop_notification.readOption(.o));
}

test "OSC 99: o 4" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;o=invisible;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    try testing.expectEqual(.invisible, cmd.kitty_desktop_notification.readOption(.o));
}

test "OSC 99: o 5" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;o=bobr;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    try testing.expectEqual(.always, cmd.kitty_desktop_notification.readOption(.o));
}

test "OSC 99: p 1" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;p=alive;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    try testing.expectEqual(.alive, cmd.kitty_desktop_notification.readOption(.p));
}

test "OSC 99: p 2" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;p=body;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    try testing.expectEqual(.body, cmd.kitty_desktop_notification.readOption(.p));
}

test "OSC 99: p 3" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;p=buttons;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    try testing.expectEqual(.buttons, cmd.kitty_desktop_notification.readOption(.p));
}

test "OSC 99: p 4" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;p=close;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    try testing.expectEqual(.close, cmd.kitty_desktop_notification.readOption(.p));
}

test "OSC 99: p 5" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;p=icon;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    try testing.expectEqual(.icon, cmd.kitty_desktop_notification.readOption(.p));
}

test "OSC 99: p 6" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;p=?;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    try testing.expectEqual(.query, cmd.kitty_desktop_notification.readOption(.p));
}

test "OSC 99: p 7" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;p=title;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    try testing.expectEqual(.title, cmd.kitty_desktop_notification.readOption(.p));
}

test "OSC 99: p 8" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;p=query;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    try testing.expectEqual(.unknown, cmd.kitty_desktop_notification.readOption(.p));
}

test "OSC 99: p 9" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;p=bobr;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    try testing.expectEqual(.unknown, cmd.kitty_desktop_notification.readOption(.p));
}

test "OSC 99: s 1" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;s=R2hvc3R0eQ==;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    try testing.expectEqualStrings("R2hvc3R0eQ==", cmd.kitty_desktop_notification.readOption(.s));
}

test "OSC 99: t 1" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;t=R2hvc3R0eQ==;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    var it = cmd.kitty_desktop_notification.readOption(.t);
    try testing.expectEqualStrings("R2hvc3R0eQ==", it.next().?);
    try testing.expect(it.next() == null);
}

test "OSC 99: t 2" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;t=R2hvc3R0eQ==:t=R2hvc3R0eQ==;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    var it = cmd.kitty_desktop_notification.readOption(.t);
    try testing.expectEqualStrings("R2hvc3R0eQ==", it.next().?);
    try testing.expectEqualStrings("R2hvc3R0eQ==", it.next().?);
    try testing.expect(it.next() == null);
}

test "OSC 99: u 1" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;u=0;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    try testing.expectEqual(.low, cmd.kitty_desktop_notification.readOption(.u));
}

test "OSC 99: u 2" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;u=1;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    try testing.expectEqual(.normal, cmd.kitty_desktop_notification.readOption(.u));
}

test "OSC 99: u 3" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;u=2;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    try testing.expectEqual(.high, cmd.kitty_desktop_notification.readOption(.u));
}

test "OSC 99: u 4" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;u=bobr;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    try testing.expectEqual(.normal, cmd.kitty_desktop_notification.readOption(.u));
}

test "OSC 99: w 1" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;w=0;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    try testing.expectEqual(0, cmd.kitty_desktop_notification.readOption(.w));
}

test "OSC 99: w 2" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;w=-1;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    try testing.expectEqual(-1, cmd.kitty_desktop_notification.readOption(.w));
}

test "OSC 99: w 3" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;w=-42;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    try testing.expectEqual(-1, cmd.kitty_desktop_notification.readOption(.w));
}

test "OSC 99: w 4" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "99;w=4294967296;foobar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_desktop_notification);
    try testing.expectEqualStrings("foobar", cmd.kitty_desktop_notification.payload);
    try testing.expectEqual(-1, cmd.kitty_desktop_notification.readOption(.w));
}
