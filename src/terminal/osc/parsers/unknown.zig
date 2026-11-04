const std = @import("std");

const assert = @import("../../../quirks.zig").inlineAssert;

const osc = @import("../../osc.zig");
const Parser = osc.Parser;
const Command = osc.Command;

/// Build `Command.unknown` from the bytes collected for a sequence whose
/// number the parser does not implement. Only reached when
/// `Parser.unknown_max_bytes` is nonzero.
pub fn parse(parser: *Parser, terminator_ch: ?u8) ?*Command {
    assert(parser.state == .unknown or parser.state == .unknown_truncated);

    const cap = &parser.capture.?;
    parser.command = .{ .unknown = .{
        .content = cap.trailing(),
        .truncated = parser.state == .unknown_truncated,
        .terminator = .init(terminator_ch),
    } };
    return &parser.command;
}

const testing = std.testing;

test "OSC unknown: prefix state names are the bytes consumed" {
    // beginUnknown recovers the consumed identifier from the prefix state's
    // name, so every prefix state must be reachable by feeding its name.
    inline for (@typeInfo(Parser.State).@"enum".field_names, @typeInfo(Parser.State).@"enum".field_values) |field, field_value| {
        const state: Parser.State = @fromBackingInt(field_value);
        switch (state) {
            .start, .invalid, .unknown, .unknown_truncated => {},
            else => {
                var p: Parser = .init(null);
                defer p.deinit();
                for (field) |ch| p.next(ch);
                try testing.expectEqual(state, p.state);
            },
        }
    }
}

test "OSC unknown: disabled by default" {
    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    try testing.expectEqual(@as(usize, 0), p.unknown_max_bytes);
    p.nextSlice("7400;status=busy");
    try testing.expectEqual(Parser.State.invalid, p.state);
    try testing.expect(p.capture == null);
    try testing.expect(p.end(0x07) == null);

    // A sequence ending on a partial number is dropped too.
    p.reset();
    p.nextSlice("77");
    try testing.expect(p.end(0x07) == null);
}

test "OSC unknown: reported" {
    const cases = [_]struct {
        input: []const u8,
        terminator_ch: ?u8 = 0x1B,
        terminator: osc.Terminator = .st,
    }{
        // Unsupported number with a body.
        .{ .input = "7400;status=busy" },
        // Unsupported number with no body, BEL terminated.
        .{ .input = "7400", .terminator_ch = 0x07, .terminator = .bel },
        // Bridge states that only lead to longer identifiers.
        .{ .input = "3;x" },
        .{ .input = "30;x" },
        .{ .input = "300;x" },
        .{ .input = "55;x" },
        .{ .input = "552;x" },
        .{ .input = "6;x" },
        .{ .input = "77;x" },
        // Bridge states with no body end on the prefix itself.
        .{ .input = "3" },
        .{ .input = "300" },
        .{ .input = "77", .terminator_ch = 0x07, .terminator = .bel },
        // Known number extended by a digit.
        .{ .input = "1338;x" },
        .{ .input = "1339" },
        // Leading zero is not a known number.
        .{ .input = "0133;x" },
        // Non-numeric identifier.
        .{ .input = "I;name" },
        // Known number followed by junk before ';'.
        .{ .input = "133 x" },
        // Empty identifier.
        .{ .input = ";x" },
        // A null terminator is treated as ST.
        .{ .input = "7400;x", .terminator_ch = null },
    };

    for (cases) |case| {
        var p: Parser = .init(testing.allocator);
        defer p.deinit();
        p.unknown_max_bytes = 64;

        p.nextSlice(case.input);
        const cmd = p.end(case.terminator_ch).?.*;
        try testing.expect(cmd == .unknown);
        try testing.expectEqualStrings(case.input, cmd.unknown.content);
        try testing.expect(!cmd.unknown.truncated);
        try testing.expectEqual(case.terminator, cmd.unknown.terminator);
    }
}

test "OSC unknown: supported commands are unchanged" {
    var p: Parser = .init(testing.allocator);
    defer p.deinit();
    p.unknown_max_bytes = 64;

    // A supported command still parses as itself.
    p.nextSlice("0;title");
    const cmd = p.end(0x07).?.*;
    try testing.expect(cmd == .change_window_title);
    try testing.expectEqualStrings("title", cmd.change_window_title);

    // A known number with a malformed body is not reported as unknown.
    p.reset();
    p.nextSlice("9;4;9");
    if (p.end(0x07)) |c| try testing.expect(c.* != .unknown);

    // A known number with an unsupported sub-command is not reported.
    p.reset();
    p.nextSlice("1337;SetUserVar=foo=YmFy");
    if (p.end(0x07)) |c| try testing.expect(c.* != .unknown);

    // A known number without a body is not reported.
    p.reset();
    p.nextSlice("7");
    if (p.end(0x07)) |c| try testing.expect(c.* != .unknown);

    // An empty OSC has no identifier and is not reported.
    p.reset();
    try testing.expect(p.end(0x07) == null);
}

test "OSC unknown: aborted sequences are dropped" {
    var p: Parser = .init(testing.allocator);
    defer p.deinit();
    p.unknown_max_bytes = 64;

    p.nextSlice("7400;x");
    try testing.expect(p.end(std.ascii.control_code.can) == null);

    p.reset();
    p.nextSlice("7400;x");
    try testing.expect(p.end(std.ascii.control_code.sub) == null);

    // Bridge prefixes are dropped on abort too.
    p.reset();
    p.nextSlice("77");
    try testing.expect(p.end(std.ascii.control_code.can) == null);
}

test "OSC unknown: truncated at the limit" {
    var p: Parser = .init(testing.allocator);
    defer p.deinit();
    p.unknown_max_bytes = 8;

    // Exactly at the limit is not truncated.
    p.nextSlice("7400;abc");
    var cmd = p.end(0x07).?.*;
    try testing.expectEqualStrings("7400;abc", cmd.unknown.content);
    try testing.expect(!cmd.unknown.truncated);

    // One byte over is truncated but still reported.
    p.reset();
    p.nextSlice("7400;abcd");
    cmd = p.end(0x07).?.*;
    try testing.expectEqualStrings("7400;abc", cmd.unknown.content);
    try testing.expect(cmd.unknown.truncated);

    // Later input is discarded, both by slice and by byte.
    p.reset();
    p.nextSlice("7400;abcdef");
    p.nextSlice("ghi");
    p.next('j');
    cmd = p.end(0x07).?.*;
    try testing.expectEqualStrings("7400;abc", cmd.unknown.content);
    try testing.expect(cmd.unknown.truncated);
}

test "OSC unknown: limit smaller than the identifier" {
    var p: Parser = .init(testing.allocator);
    defer p.deinit();
    p.unknown_max_bytes = 2;

    // The prefix itself overflows while beginning the capture.
    p.nextSlice("7400;x");
    var cmd = p.end(0x07).?.*;
    try testing.expectEqualStrings("74", cmd.unknown.content);
    try testing.expect(cmd.unknown.truncated);

    // The prefix fits but the unrecognized byte does not.
    p.reset();
    p.nextSlice("77x");
    cmd = p.end(0x07).?.*;
    try testing.expectEqualStrings("77", cmd.unknown.content);
    try testing.expect(cmd.unknown.truncated);

    // A bridge prefix longer than the limit at end.
    p.reset();
    p.unknown_max_bytes = 1;
    p.nextSlice("77");
    cmd = p.end(0x07).?.*;
    try testing.expectEqualStrings("7", cmd.unknown.content);
    try testing.expect(cmd.unknown.truncated);
}

test "OSC unknown: fixed tier does not allocate" {
    var p: Parser = .init(testing.failing_allocator);
    defer p.deinit();
    p.unknown_max_bytes = Parser.MAX_BUF;

    p.nextSlice("7400;");
    try testing.expect(p.capture.?.backing == .fixed);
    try testing.expectEqual(@as(usize, Parser.MAX_BUF), p.capture.?.max_bytes);
    p.nextSlice("x");
    const cmd = p.end(0x07).?.*;
    try testing.expectEqualStrings("7400;x", cmd.unknown.content);
}

test "OSC unknown: allocating tier" {
    const limit = Parser.MAX_BUF * 2;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();
    p.unknown_max_bytes = limit;

    p.nextSlice("7400;");
    try testing.expect(p.capture.?.backing == .allocating);

    const body = try testing.allocator.alloc(u8, limit);
    defer testing.allocator.free(body);
    @memset(body, 'a');

    // Fill to exactly the limit, including the 5 identifier bytes.
    p.nextSlice(body[0 .. limit - 5]);
    try testing.expectEqual(Parser.State.unknown, p.state);
    try testing.expectEqual(@as(usize, limit), p.capture.?.writer.buffer.len);

    // One more byte truncates without growing the allocation.
    p.nextSlice("a");
    try testing.expectEqual(Parser.State.unknown_truncated, p.state);
    try testing.expectEqual(@as(usize, limit), p.capture.?.writer.buffer.len);

    const cmd = p.end(0x07).?.*;
    try testing.expect(cmd == .unknown);
    try testing.expect(cmd.unknown.truncated);
    try testing.expectEqual(@as(usize, limit), cmd.unknown.content.len);
    try testing.expect(std.mem.startsWith(u8, cmd.unknown.content, "7400;aaa"));
}

test "OSC unknown: large limit without allocator uses fixed buffer" {
    var p: Parser = .init(null);
    defer p.deinit();
    p.unknown_max_bytes = Parser.MAX_BUF * 2;

    p.nextSlice("7400;");
    try testing.expect(p.capture.?.backing == .fixed);

    var body: [Parser.MAX_BUF]u8 = undefined;
    @memset(&body, 'a');
    p.nextSlice(&body);

    const cmd = p.end(0x07).?.*;
    try testing.expect(cmd.unknown.truncated);
    try testing.expectEqual(@as(usize, Parser.MAX_BUF), cmd.unknown.content.len);
}

test "OSC unknown: allocation failure falls back to fixed buffer" {
    var p: Parser = .init(testing.failing_allocator);
    defer p.deinit();
    p.unknown_max_bytes = Parser.MAX_BUF * 2;

    p.nextSlice("7400;x");
    try testing.expect(p.capture.?.backing == .fixed);
    const cmd = p.end(0x07).?.*;
    try testing.expectEqualStrings("7400;x", cmd.unknown.content);
}

test "OSC unknown: allocation failure while growing truncates" {
    // Allow the initial capacity allocation and fail the first growth,
    // whether it is attempted in place or by a new allocation.
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{
        .fail_index = 1,
        .resize_fail_index = 0,
    });

    var p: Parser = .init(failing.allocator());
    defer p.deinit();
    p.unknown_max_bytes = Parser.MAX_BUF * 2;

    p.nextSlice("7400;");
    try testing.expect(p.capture.?.backing == .allocating);

    var body: [Parser.MAX_BUF]u8 = undefined;
    @memset(&body, 'a');
    p.nextSlice(&body);
    try testing.expectEqual(Parser.State.unknown_truncated, p.state);
    const retained = p.capture.?.trailing().len;
    try testing.expect(retained <= Parser.MAX_BUF);

    // Later bytes must not be appended after the gap, even if an
    // allocation would now succeed.
    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    p.nextSlice("zz");
    p.next('z');

    const cmd = p.end(0x07).?.*;
    try testing.expect(cmd.unknown.truncated);
    try testing.expectEqual(retained, cmd.unknown.content.len);
    try testing.expect(std.mem.indexOfScalar(u8, cmd.unknown.content, 'z') == null);
}

test "OSC unknown: nextSlice matches per-byte parsing" {
    const inputs = [_][]const u8{
        "7400;status=busy:jobs=4",
        "I;name",
        "1338;x",
        "77",
        "7400;abcdefghijklmnop",
    };

    for (inputs) |input| {
        // Per-byte reference.
        var ref: Parser = .init(testing.allocator);
        defer ref.deinit();
        ref.unknown_max_bytes = 12;
        for (input) |ch| ref.next(ch);
        const expected = ref.end(0x07).?.*.unknown;

        // Every two-way split of the input must parse identically.
        for (0..input.len + 1) |split| {
            var p: Parser = .init(testing.allocator);
            defer p.deinit();
            p.unknown_max_bytes = 12;
            p.nextSlice(input[0..split]);
            p.nextSlice(input[split..]);

            const cmd = p.end(0x07).?.*;
            try testing.expect(cmd == .unknown);
            try testing.expectEqualStrings(expected.content, cmd.unknown.content);
            try testing.expectEqual(expected.truncated, cmd.unknown.truncated);
        }
    }
}
