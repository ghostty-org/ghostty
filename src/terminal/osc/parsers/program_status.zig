//! OSC 7501: Program Status Protocol
//!
//! Specification: https://www.superlogical.com/rex/docs/build/program-status
//!
//! A program uses this protocol to tell the terminal what it is doing:
//! idle, working, done, waiting on the user, or failed. Each report is a
//! list of `key=value` pairs separated by colons:
//!
//! ```
//! ESC ] 7501 ; state=working:app=cargo:progress=40 ESC \
//! ```
//!
//! A terminal keeps one record per id, and each report replaces its
//! record completely. This parser only reads and validates one report at
//! a time. Keeping records is up to the code that handles the command.
//! In libghostty-vt, that is the `program_status` effect of
//! `stream_terminal.Handler`.
//!
//! A program checks whether the terminal supports the protocol by sending
//! `?` as the body. A terminal that supports it replies with the same
//! sequence. See `Command.query`.
//!
//! Example:
//!
//! ```zig
//! var p: osc.Parser = .init(alloc);
//! defer p.deinit();
//!
//! p.nextSlice("7501;state=working:id=sync:progress=40");
//! const report = p.end('\x1b').?.program_status.report;
//! report.state; // .working
//! report.readOption(.id); // "sync"
//! report.readOption(.progress); // 40
//! report.readOption(.app); // null, the program didn't send one
//! ```

const program_status = @This();

const std = @import("std");
const lib = @import("../../lib.zig");
const osc = @import("../../osc.zig");
const encoding = @import("../encoding.zig");
const kitty_metadata = @import("../kitty_metadata.zig");

const assert = @import("../../../quirks.zig").inlineAssert;
const Parser = osc.Parser;
const OSCCommand = osc.Command;
const Terminator = osc.Terminator;

const log = std.log.scoped(.osc_program_status);

// Size limits from the specification. Every limit counts bytes, not
// characters. A report that breaks any limit is discarded as a whole.

/// The longest whole sequence, from `ESC ]` through the terminator.
pub const max_sequence_bytes = 4096;

/// The longest body, everything after `7501;`. This assumes the
/// longer terminator (`ESC \`), so a sequence ended with BEL is limited
/// to one byte less than the specification allows. The specification
/// lets terminals choose lower limits.
pub const max_body_bytes = max_sequence_bytes - "\x1b]7501;".len - "\x1b\\".len;

/// The longest key, including keys this parser doesn't know.
pub const max_key_bytes = 16;

/// The longest `msg` value before and after base64 decoding.
pub const max_msg_encoded_bytes = 2732;
pub const max_msg_bytes = 2048;

/// The longest `title` value before and after base64 decoding.
pub const max_title_encoded_bytes = 256;
pub const max_title_bytes = 192;

/// The longest `app` value.
pub const max_app_bytes = 32;

/// The longest `id` value, the longest part between two slashes, and the
/// most parts an id can have.
pub const max_id_bytes = 128;
pub const max_id_segment_bytes = 32;
pub const max_id_depth = 8;

/// A parsed OSC 7501 sequence: either a support query or a report.
pub const Command = union(enum) {
    pub const C = void;
    pub const Report = program_status.Report;
    pub const State = program_status.State;
    pub const Kind = program_status.Kind;
    pub const Option = program_status.Option;

    /// The program asked whether the terminal supports the protocol by
    /// sending `OSC 7501 ; ? ST`. A terminal that supports it sends the
    /// same sequence back, ended with this terminator so the program
    /// recognizes it. A program that gets no reply assumes the protocol
    /// is unsupported.
    query: Terminator,

    /// A valid status report for one record.
    report: program_status.Report,
};

/// The value of the required `state` key.
///
/// - `idle`: at rest, waiting for the user's next instruction.
/// - `working`: running. May carry a progress percentage.
/// - `done`: finished a piece of work the user hasn't looked at yet.
/// - `blocked`: can't continue until the user does something. The
///   report's `kind` says what. May carry a progress percentage.
/// - `error`: failed and stopped.
/// - `clear`: not a real state. Removes the addressed record and every
///   record beneath it. Without an id, it removes every record.
pub const State = lib.Enum(lib.target, &.{
    "idle",
    "working",
    "done",
    "blocked",
    "error",
    "clear",
});

/// The value of the `kind` key, which says what a blocked program needs
/// from the user.
///
/// - `permission`: approval to do something.
/// - `question`: an answer the user has to type.
/// - `auth`: a login, token, or other credential.
pub const Kind = lib.Enum(lib.target, &.{
    "permission",
    "question",
    "auth",
});

/// A status report that passed every check in the specification.
///
/// `state` is always present. Read everything else with `readOption`,
/// and the text values with `writeText`:
///
/// ```zig
/// const report = cmd.program_status.report;
/// if (report.readOption(.progress)) |percent| showProgress(percent);
///
/// var buf: [program_status.max_msg_bytes]u8 = undefined;
/// var writer: std.Io.Writer = .fixed(&buf);
/// try report.writeText(.msg, &writer);
/// showMessage(writer.buffered());
/// ```
///
/// The values point into the parser's buffer, so they are only valid
/// until the next call to the parser. Copy anything you want to keep.
///
/// A key the program didn't send reads as null. A report replaces its
/// record completely, so a null value means the record no longer has
/// that value, not that the old value should be kept.
pub const Report = struct {
    /// What the program is doing.
    state: State,

    /// Everything after `7501;`, already validated by the parser. Read
    /// it with `readOption` and `writeText`.
    data: []const u8 = "",

    /// Read the value of a key, or null if the program didn't send it.
    /// If the program sent a key more than once, the last value wins.
    pub fn readOption(
        self: Report,
        comptime option: Option,
    ) ?option.Type() {
        const v = lastValue(@tagName(option), self.data) orelse return null;

        return switch (option) {
            // The parser already discarded reports with an invalid id.
            .id => v,
            .app => if (isName(v)) v else null,
            .kind => if (self.state == .blocked) std.meta.stringToEnum(Kind, v) else null,
            .progress => switch (self.state) {
                .working, .blocked => parseProgress(v),
                else => null,
            },
            .title, .msg => if (v.len > 0) v else null,
        };
    }

    /// Write the decoded text of `title` or `msg` to `writer`. Writes
    /// nothing if the program didn't send it.
    ///
    /// The text is valid UTF-8 with no control characters, but it is
    /// still untrusted text from the program. It is at most
    /// `max_title_bytes` or `max_msg_bytes` long.
    pub fn writeText(
        self: Report,
        comptime option: Option,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        comptime assert(option == .title or option == .msg);
        const encoded = self.readOption(option) orelse return;

        // The parser already checked that this decodes, so it can't fail.
        var buf: [max_msg_bytes]u8 = undefined;
        try writer.writeAll(decodeText(encoded, &buf) catch unreachable);
    }
};

/// The keys of a report, other than `state`.
///
/// - `id`: the record this report is about. Without it, the report is
///   about the root record, the program itself. A program that reports on
///   several things at once, like a deploy to several regions, gives each
///   one an id. A `/` makes one record the child of another, so
///   `deploy/us-east` is a child of `deploy`. The parent doesn't have to
///   exist.
/// - `kind`: what a blocked program needs from the user. Only read when
///   the state is `blocked`. An unknown kind reads as null.
/// - `progress`: how far along the work is, from 0 to 100. Only read when
///   the state is `working` or `blocked`. A value outside that range
///   reads as null.
/// - `app`: a stable name for the program that a machine can match on,
///   such as `cargo` or `terraform`.
/// - `title`: a short label for the record, meant for people. Programs
///   that report several records use this to tell them apart.
/// - `msg`: one line of text for people, saying what the record is
///   doing, waiting for, or has finished. Don't try to read meaning into
///   it.
///
/// `readOption` returns `title` and `msg` still encoded as base64. Use
/// `writeText` to read their text.
pub const Option = enum {
    id,
    kind,
    progress,
    app,
    title,
    msg,

    pub fn Type(comptime self: Option) type {
        return switch (self) {
            .kind => Kind,
            .progress => u8,
            .id, .app, .title, .msg => []const u8,
        };
    }
};

/// Parse OSC 7501. The body is everything after `7501;`.
///
/// The parser is forgiving about single pairs and strict about the
/// report as a whole, as the specification requires. It skips a pair
/// that is malformed or has a key it doesn't know, and keeps going:
///
/// ```
/// state=idle:future=yes:oops   ->  a report with state idle
/// ```
///
/// It returns null, so nothing from the report is applied, when:
///
/// - `state` is missing or isn't a state this parser knows.
/// - Any key or value is longer than its limit, even one that a later
///   pair with the same key replaces.
/// - The id isn't made of valid names joined by single slashes. This
///   throws out the report instead of skipping the pair, so a report
///   meant for one record never falls back to the root record. For
///   `state=clear`, that would remove every record.
/// - `title` or `msg` isn't valid base64, or decodes to text that isn't
///   UTF-8 or contains a control character.
pub fn parse(parser: *Parser, terminator_ch: ?u8) ?*OSCCommand {
    assert(parser.state == .@"7501");

    const cap = if (parser.capture) |*c| c else {
        parser.state = .invalid;
        return null;
    };

    const data = cap.trailing();
    if (data.len > max_body_bytes) {
        log.warn("OSC 7501 sequence too long len={d}", .{data.len});
        parser.state = .invalid;
        return null;
    }

    if (std.mem.eql(u8, data, "?")) {
        parser.command = .{ .program_status = .{ .query = .init(terminator_ch) } };
        return &parser.command;
    }

    const state = validate(data) catch |err| {
        log.warn("invalid OSC 7501 report err={}", .{err});
        parser.state = .invalid;
        return null;
    };

    parser.command = .{ .program_status = .{ .report = .{
        .state = state,
        .data = data,
    } } };
    return &parser.command;
}

/// Check a report body against the specification and return its state.
fn validate(data: []const u8) error{
    InvalidState,
    InvalidId,
    InvalidText,
    TooLong,
}!State {
    // A key that is too long breaks a limit, even a key we don't know.
    var pairs = std.mem.splitScalar(u8, data, ':');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key = std.mem.trim(u8, pair[0..eq], &std.ascii.whitespace);
        if (key.len > max_key_bytes) return error.TooLong;
    }

    // Every value is checked against its limit, even one a later pair
    // replaces, because any limit violation discards the whole report.
    var ids: kitty_metadata.ValueIterator("id", value_bytes) = .init(data);
    while (ids.next()) |v| try validateId(v);
    inline for (.{
        .{ "app", max_app_bytes },
        .{ "title", max_title_encoded_bytes },
        .{ "msg", max_msg_encoded_bytes },
    }) |limit| {
        var it: kitty_metadata.ValueIterator(limit[0], value_bytes) = .init(data);
        while (it.next()) |v| if (v.len > limit[1]) return error.TooLong;
    }

    var buf: [max_msg_bytes]u8 = undefined;
    if (lastValue("title", data)) |v| {
        if ((try decodeText(v, &buf)).len > max_title_bytes) return error.TooLong;
    }
    if (lastValue("msg", data)) |v| _ = try decodeText(v, &buf);

    // An unknown state discards the report rather than guessing, so a
    // state added in a later revision never turns into something else.
    return std.meta.stringToEnum(
        State,
        lastValue("state", data) orelse return error.InvalidState,
    ) orelse error.InvalidState;
}

/// The last value of `key` in a report body. Pairs without an `=` and
/// values with bytes outside the value alphabet are skipped.
fn lastValue(comptime key: []const u8, data: []const u8) ?[]const u8 {
    var it: kitty_metadata.ValueIterator(key, value_bytes) = .init(data);
    var last: ?[]const u8 = null;
    while (it.next()) |v| last = v;
    return last;
}

/// The bytes allowed in a name and a value. A name is the form of an
/// `app` value and of each part of an `id`.
const name_bytes = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.+-";
const value_bytes = name_bytes ++ ",/=";

fn isName(s: []const u8) bool {
    return s.len > 0 and std.mem.indexOfNone(u8, s, name_bytes) == null;
}

/// Validate an id: names joined by single slashes, within the limits.
fn validateId(value: []const u8) error{ InvalidId, TooLong }!void {
    if (value.len > max_id_bytes) return error.TooLong;
    var depth: usize = 0;
    var it = std.mem.splitScalar(u8, value, '/');
    while (it.next()) |segment| {
        depth += 1;
        if (depth > max_id_depth) return error.TooLong;
        if (segment.len > max_id_segment_bytes) return error.TooLong;
        if (!isName(segment)) return error.InvalidId;
    }
}

/// Parse a whole number from 0 to 100. Anything else is treated as
/// absent. This doesn't use std.fmt because it accepts underscores.
fn parseProgress(value: []const u8) ?u8 {
    if (value.len == 0) return null;
    var n: u16 = 0;
    for (value) |c| {
        const digit = std.fmt.charToDigit(c, 10) catch return null;
        n = n * 10 + digit;
        if (n > 100) return null;
    }
    return @intCast(n);
}

/// Decode a base64 title or msg into `buf` and check that the text is
/// safe to show. Padding is optional. The caller must have checked the
/// encoded length against `max_msg_encoded_bytes`.
fn decodeText(
    encoded: []const u8,
    buf: *[max_msg_bytes]u8,
) error{ InvalidText, TooLong }![]const u8 {
    const decoder = if (std.mem.endsWith(u8, encoded, "="))
        std.base64.standard.Decoder
    else
        std.base64.standard_no_pad.Decoder;

    const len = decoder.calcSizeForSlice(encoded) catch
        return error.InvalidText;
    if (len > buf.len) return error.TooLong;

    const decoded = buf[0..len];
    decoder.decode(decoded, encoded) catch return error.InvalidText;
    if (!encoding.isSafeUtf8(decoded)) return error.InvalidText;
    return decoded;
}

test "OSC 7501: query" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    p.nextSlice("7501;?");
    try testing.expectEqual(Terminator.st, p.end('\x1b').?.program_status.query);

    p.reset();
    p.nextSlice("7501;?");
    try testing.expectEqual(Terminator.bel, p.end(0x07).?.program_status.query);
}

test "OSC 7501: minimal report" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    p.nextSlice("7501;state=idle");
    const report = p.end('\x1b').?.program_status.report;
    try testing.expectEqual(State.idle, report.state);
    try testing.expect(report.readOption(.kind) == null);
    try testing.expect(report.readOption(.progress) == null);
    try testing.expect(report.readOption(.id) == null);
    try testing.expect(report.readOption(.app) == null);
    try testing.expect(report.readOption(.title) == null);
    try testing.expect(report.readOption(.msg) == null);
}

test "OSC 7501: all keys" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    // "Plan" and "Apply 3 to add, 1 to change, 0 to destroy?"
    p.nextSlice("7501;state=blocked:kind=permission:progress=42:id=tf/plan:app=terraform" ++
        ":title=UGxhbg==:msg=QXBwbHkgMyB0byBhZGQsIDEgdG8gY2hhbmdlLCAwIHRvIGRlc3Ryb3k/");
    const report = p.end('\x1b').?.program_status.report;
    try testing.expectEqual(State.blocked, report.state);
    try testing.expectEqual(Kind.permission, report.readOption(.kind).?);
    try testing.expectEqual(@as(u8, 42), report.readOption(.progress).?);
    try testing.expectEqualStrings("tf/plan", report.readOption(.id).?);
    try testing.expectEqualStrings("terraform", report.readOption(.app).?);

    var buf: [max_msg_bytes]u8 = undefined;
    var title: std.Io.Writer = .fixed(&buf);
    try report.writeText(.title, &title);
    try testing.expectEqualStrings("Plan", title.buffered());

    var msg: std.Io.Writer = .fixed(&buf);
    try report.writeText(.msg, &msg);
    try testing.expectEqualStrings(
        "Apply 3 to add, 1 to change, 0 to destroy?",
        msg.buffered(),
    );
}

test "OSC 7501: base64 padding is optional" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    p.nextSlice("7501;state=done:msg=UGxhbg");
    const report = p.end('\x1b').?.program_status.report;

    var buf: [max_msg_bytes]u8 = undefined;
    var msg: std.Io.Writer = .fixed(&buf);
    try report.writeText(.msg, &msg);
    try testing.expectEqualStrings("Plan", msg.buffered());
}

test "OSC 7501: whitespace around keys and values" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    p.nextSlice("7501; state = working :\tapp=cargo\t");
    const report = p.end('\x1b').?.program_status.report;
    try testing.expectEqual(State.working, report.state);
    try testing.expectEqualStrings("cargo", report.readOption(.app).?);
}

test "OSC 7501: last value wins" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    p.nextSlice("7501;state=idle:app=a:state=done:app=b");
    const report = p.end('\x1b').?.program_status.report;
    try testing.expectEqual(State.done, report.state);
    try testing.expectEqualStrings("b", report.readOption(.app).?);
}

test "OSC 7501: malformed pairs and unknown keys are skipped" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    p.nextSlice("7501;garbage:=x:Bad=1:app=b@d:future=yes:state=working:app=ok:::");
    const report = p.end('\x1b').?.program_status.report;
    try testing.expectEqual(State.working, report.state);
    try testing.expectEqualStrings("ok", report.readOption(.app).?);
}

test "OSC 7501: kind and progress only apply to some states" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    p.nextSlice("7501;state=working:kind=auth:progress=10");
    var report = p.end('\x1b').?.program_status.report;
    try testing.expect(report.readOption(.kind) == null);
    try testing.expectEqual(@as(u8, 10), report.readOption(.progress).?);

    p.reset();
    p.nextSlice("7501;state=done:kind=auth:progress=10");
    report = p.end('\x1b').?.program_status.report;
    try testing.expect(report.readOption(.kind) == null);
    try testing.expect(report.readOption(.progress) == null);

    p.reset();
    p.nextSlice("7501;state=blocked:kind=dance");
    report = p.end('\x1b').?.program_status.report;
    try testing.expect(report.readOption(.kind) == null);
}

test "OSC 7501: out of range progress is absent" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const cases = [_]struct { []const u8, ?u8 }{
        .{ "0", 0 },
        .{ "100", 100 },
        .{ "101", null },
        .{ "256", null },
        .{ "99999999999999999999", null },
        .{ "-1", null },
        .{ "+1", null },
        .{ "4.5", null },
        .{ "1_0", null },
        .{ "007", 7 },
        .{ "", null },
    };

    for (cases) |case| {
        p.reset();
        p.nextSlice("7501;state=working:progress=");
        p.nextSlice(case[0]);
        const report = p.end('\x1b').?.program_status.report;
        try testing.expectEqual(case[1], report.readOption(.progress));
    }
}

test "OSC 7501: invalid app is ignored" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    p.nextSlice("7501;state=idle:app=a/b");
    const report = p.end('\x1b').?.program_status.report;
    try testing.expect(report.readOption(.app) == null);
}

test "OSC 7501: ids" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const max_segment = "a" ** max_id_segment_bytes;
    const valid = [_][]const u8{
        "a",
        "build/test",
        "A-Z_0.9+",
        max_segment,
        "a/b/c/d/e/f/g/h",
    };
    for (valid) |id| {
        p.reset();
        p.nextSlice("7501;state=clear:id=");
        p.nextSlice(id);
        const report = p.end('\x1b').?.program_status.report;
        try testing.expectEqualStrings(id, report.readOption(.id).?);
    }

    // An invalid id discards the report so that it can never fall back
    // to the root record.
    const invalid = [_][]const u8{
        "",
        "/",
        "a/",
        "/a",
        "a//b",
        "a,b",
        "a=b",
        max_segment ++ "a",
        "a/b/c/d/e/f/g/h/i",
        ("a" ** 31 ++ "/") ** 4 ++ "a",
    };
    for (invalid) |id| {
        p.reset();
        p.nextSlice("7501;state=clear:id=");
        p.nextSlice(id);
        try testing.expect(p.end('\x1b') == null);
    }
}

test "OSC 7501: text must decode to safe UTF-8" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const invalid = [_][]const u8{
        // Not base64.
        "7501;state=done:msg=a",
        "7501;state=done:msg=QQ=",
        "7501;state=done:title=a",
        // "a\nb", a control character.
        "7501;state=done:msg=YQpi",
        // "\x9b", a C1 control character as UTF-8.
        "7501;state=done:msg=wps=",
        // Invalid UTF-8.
        "7501;state=done:msg=/w==",
    };
    for (invalid) |input| {
        p.reset();
        p.nextSlice(input);
        try testing.expect(p.end('\x1b') == null);
    }

    // Unicode is fine. "安全"
    p.reset();
    p.nextSlice("7501;state=done:msg=5a6J5YWo");
    const report = p.end('\x1b').?.program_status.report;
    var buf: [max_msg_bytes]u8 = undefined;
    var msg: std.Io.Writer = .fixed(&buf);
    try report.writeText(.msg, &msg);
    try testing.expectEqualStrings("安全", msg.buffered());
}

test "OSC 7501: empty text is absent" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    p.nextSlice("7501;state=done:msg=:title=");
    const report = p.end('\x1b').?.program_status.report;
    try testing.expect(report.readOption(.msg) == null);
    try testing.expect(report.readOption(.title) == null);
}

test "OSC 7501: discarded reports" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    // 192 bytes of title and 2048 bytes of message are the most allowed.
    // "QUFB" decodes to "AAA" and "QUE" to "AA".
    const title = "QUFB" ** (max_title_encoded_bytes / 4);
    const msg = "QUFB" ** (max_msg_bytes / 3) ++ "QUE";
    const fill = max_sequence_bytes - "\x1b]7501;state=idle:".len - "\x1b\\".len;

    const cases = [_]struct { []const u8, bool }{
        // A missing or unknown state.
        .{ "7501;", false },
        .{ "7501;app=cargo", false },
        .{ "7501;state=sleeping", false },
        .{ "7501;state=", false },
        .{ "7501;state=IDLE", false },

        // A key that is too long, even one we don't know.
        .{ "7501;state=idle:" ++ "a" ** max_key_bytes ++ "=1", true },
        .{ "7501;state=idle:" ++ "a" ** (max_key_bytes + 1) ++ "=1", false },

        // An app that is too long, even if a later pair replaces it.
        .{ "7501;state=idle:app=" ++ "a" ** (max_app_bytes + 1), false },
        .{ "7501;state=idle:app=" ++ "a" ** (max_app_bytes + 1) ++ ":app=ok", false },

        // Text at its limits and one step over.
        .{ "7501;state=idle:title=" ++ title, true },
        .{ "7501;state=idle:title=" ++ title ++ "QUFB", false },
        .{ "7501;state=idle:msg=" ++ msg, true },
        .{ "7501;state=idle:msg=" ++ "QUFB" ** (max_msg_bytes / 3 + 1), false },

        // The whole sequence, including the terminator.
        .{ "7501;state=idle:" ++ "x" ** fill, true },
        .{ "7501;state=idle:" ++ "x" ** (fill + 1), false },

        // Numbers that only start like 7501.
        .{ "75;state=idle", false },
        .{ "750;state=idle", false },
        .{ "75010;state=idle", false },
        .{ "7501", false },
    };
    for (cases) |case| {
        p.reset();
        p.nextSlice(case[0]);
        try testing.expectEqual(case[1], p.end('\x1b') != null);
    }
}

test "OSC 7501: no allocator" {
    const testing = std.testing;

    var p: Parser = .init(null);
    defer p.deinit();

    p.nextSlice("7501;state=working:app=cargo");
    const report = p.end('\x1b').?.program_status.report;
    try testing.expectEqual(State.working, report.state);
    try testing.expectEqualStrings("cargo", report.readOption(.app).?);
}
