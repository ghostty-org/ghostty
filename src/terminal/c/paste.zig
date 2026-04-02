const std = @import("std");
const lib = @import("../lib.zig");
const paste = @import("../../input/paste.zig");
const paste_homoglyph = @import("../../input/paste_homoglyph.zig");
const Result = @import("result.zig").Result;

pub fn is_safe(data: ?[*]const u8, len: usize) callconv(lib.calling_conv) bool {
    const slice: []const u8 = if (data) |v| v[0..len] else &.{};
    return paste.isSafe(slice);
}

pub const homoglyph_suspicious_spans = paste_homoglyph.homoglyphSuspiciousSpans;
pub const homoglyph_first_url_range = paste_homoglyph.homoglyphFirstUrlRange;
pub const homoglyph_first_url_report = paste_homoglyph.homoglyphFirstUrlReport;

pub fn encode(
    data: ?[*]u8,
    data_len: usize,
    bracketed: bool,
    out_: ?[*]u8,
    out_len: usize,
    out_written: *usize,
) callconv(lib.calling_conv) Result {
    const slice: []u8 = if (data) |v| v[0..data_len] else &.{};
    const result = paste.encode(slice, .{ .bracketed = bracketed });

    const total = result[0].len + result[1].len + result[2].len;
    out_written.* = total;

    const out: []u8 = if (out_) |o| o[0..out_len] else &.{};
    if (out.len < total) return .out_of_space;

    var offset: usize = 0;
    for (result) |segment| {
        @memcpy(out[offset..][0..segment.len], segment);
        offset += segment.len;
    }

    return .success;
}

test "encode bracketed" {
    const testing = std.testing;
    const input = try testing.allocator.dupe(u8, "hello");
    defer testing.allocator.free(input);
    var buf: [64]u8 = undefined;
    var written: usize = 0;
    const result = encode(input.ptr, input.len, true, &buf, buf.len, &written);
    try testing.expectEqual(.success, result);
    try testing.expectEqualStrings("\x1b[200~hello\x1b[201~", buf[0..written]);
}

test "encode unbracketed no newlines" {
    const testing = std.testing;
    const input = try testing.allocator.dupe(u8, "hello");
    defer testing.allocator.free(input);
    var buf: [64]u8 = undefined;
    var written: usize = 0;
    const result = encode(input.ptr, input.len, false, &buf, buf.len, &written);
    try testing.expectEqual(.success, result);
    try testing.expectEqualStrings("hello", buf[0..written]);
}

test "encode unbracketed newlines" {
    const testing = std.testing;
    const input = try testing.allocator.dupe(u8, "hello\nworld");
    defer testing.allocator.free(input);
    var buf: [64]u8 = undefined;
    var written: usize = 0;
    const result = encode(input.ptr, input.len, false, &buf, buf.len, &written);
    try testing.expectEqual(.success, result);
    try testing.expectEqualStrings("hello\rworld", buf[0..written]);
}

test "encode strip unsafe bytes" {
    const testing = std.testing;
    const input = try testing.allocator.dupe(u8, "hel\x1blo\x00world");
    defer testing.allocator.free(input);
    var buf: [64]u8 = undefined;
    var written: usize = 0;
    const result = encode(input.ptr, input.len, true, &buf, buf.len, &written);
    try testing.expectEqual(.success, result);
    try testing.expectEqualStrings("\x1b[200~hel lo world\x1b[201~", buf[0..written]);
}

test "encode with insufficient buffer" {
    const testing = std.testing;
    const input = try testing.allocator.dupe(u8, "hello");
    defer testing.allocator.free(input);
    var buf: [1]u8 = undefined;
    var written: usize = 0;
    const result = encode(input.ptr, input.len, true, &buf, buf.len, &written);
    try testing.expectEqual(.out_of_space, result);
    try testing.expectEqual(17, written);
}

test "encode with null buffer" {
    const testing = std.testing;
    const input = try testing.allocator.dupe(u8, "hello");
    defer testing.allocator.free(input);
    var written: usize = 0;
    const result = encode(input.ptr, input.len, true, null, 0, &written);
    try testing.expectEqual(.out_of_space, result);
    try testing.expectEqual(17, written);
}

test "is_safe with safe data" {
    const testing = std.testing;
    const safe = "hello world";
    try testing.expect(is_safe(safe.ptr, safe.len));
}

test "is_safe with newline" {
    const testing = std.testing;
    const unsafe = "hello\nworld";
    try testing.expect(!is_safe(unsafe.ptr, unsafe.len));
}

test "is_safe with bracketed paste end" {
    const testing = std.testing;
    const unsafe = "hello\x1b[201~world";
    try testing.expect(!is_safe(unsafe.ptr, unsafe.len));
}

test "is_safe with empty data" {
    const testing = std.testing;
    const empty = "";
    try testing.expect(is_safe(empty.ptr, 0));
}

test "is_safe with null empty data" {
    const testing = std.testing;
    try testing.expect(is_safe(null, 0));
}
