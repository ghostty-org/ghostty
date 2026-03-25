const std = @import("std");
const lib = @import("../lib.zig");
const terminal_focus = @import("../focus.zig");
const Result = @import("result.zig").Result;

pub fn encode(
    event: terminal_focus.Event,
    out_: ?[*]u8,
    out_len: usize,
    out_written: *usize,
) callconv(lib.calling_conv) Result {
    var writer: std.Io.Writer = .fixed(if (out_) |out| out[0..out_len] else &.{});
    terminal_focus.encode(&writer, event) catch |err| switch (err) {
        error.WriteFailed => {
            var discarding: std.Io.Writer.Discarding = .init(&.{});
            terminal_focus.encode(&discarding.writer, event) catch unreachable;
            out_written.* = @intCast(discarding.count);
            return .out_of_space;
        },
    };

    out_written.* = writer.end;
    return .success;
}

test "encode focus gained" {
    var buf: [terminal_focus.max_encode_size]u8 = undefined;
    var written: usize = 0;
    const result = encode(.gained, &buf, buf.len, &written);
    try std.testing.expectEqual(.success, result);
    try std.testing.expectEqualStrings("\x1B[I", buf[0..written]);
}

test "encode focus lost" {
    var buf: [terminal_focus.max_encode_size]u8 = undefined;
    var written: usize = 0;
    const result = encode(.lost, &buf, buf.len, &written);
    try std.testing.expectEqual(.success, result);
    try std.testing.expectEqualStrings("\x1B[O", buf[0..written]);
}

test "encode with insufficient buffer" {
    var buf: [1]u8 = undefined;
    var written: usize = 0;
    const result = encode(.gained, &buf, buf.len, &written);
    try std.testing.expectEqual(.out_of_space, result);
    try std.testing.expectEqual(terminal_focus.max_encode_size, written);
}

test "encode with null buffer" {
    var written: usize = 0;
    const result = encode(.gained, null, 0, &written);
    try std.testing.expectEqual(.out_of_space, result);
    try std.testing.expectEqual(terminal_focus.max_encode_size, written);
}
