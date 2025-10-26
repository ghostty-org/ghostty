const std = @import("std");
const paste = @import("../../input/paste.zig");
const lib_alloc = @import("../../lib/allocator.zig");
const CAllocator = lib_alloc.Allocator;
const Allocator = std.mem.Allocator;
const Result = @import("result.zig").Result;

/// Wrapper around paste encoding options that tracks the allocator for C API usage.
const PasteEncoderWrapper = struct {
    opts: paste.Options,
    alloc: Allocator,
};

/// C: GhosttyPasteEncoder
pub const Encoder = ?*PasteEncoderWrapper;

pub fn new(
    alloc_: ?*const CAllocator,
    result: *Encoder,
) callconv(.c) Result {
    const alloc = lib_alloc.default(alloc_);
    const ptr = alloc.create(PasteEncoderWrapper) catch
        return .out_of_memory;
    ptr.* = .{
        .opts = .{ .bracketed = false },
        .alloc = alloc,
    };
    result.* = ptr;
    return .success;
}

pub fn free(encoder_: Encoder) callconv(.c) void {
    const wrapper = encoder_ orelse return;
    const alloc = wrapper.alloc;
    alloc.destroy(wrapper);
}

pub fn encoder_set_bracketed(encoder_: Encoder, enabled: bool) callconv(.c) void {
    if (encoder_) |e| {
        e.opts.bracketed = enabled;
    }
}

pub fn encode(
    encoder_: Encoder,
    data_: ?[*]u8,
    len: usize,
    out_: ?[*]u8,
    out_len: usize,
    out_written_: ?*usize,
) callconv(.c) Result {
    var writer: std.Io.Writer = .fixed(if (out_) |out| out[0..out_len] else &.{});

    const data: []u8 = if (data_) |d| d[0..len] else &.{};
    const encoded: [3][]const u8 = paste.encode(data, encoder_.?.*.opts);
    if (out_written_) |out_written| out_written.* = encoded[0].len + encoded[1].len + encoded[2].len + 1;
    for (encoded[0..]) |part| {
        writer.writeAll(part) catch |err| switch (err) {
            error.WriteFailed => {
                return .out_of_memory;
            },
        };
    }
    writer.writeByte(0) catch |err| switch (err) {
        error.WriteFailed => {
            return .out_of_memory;
        },
    };
    return .success;
}

pub fn is_safe(data: ?[*]const u8, len: usize) callconv(.c) bool {
    const slice: []const u8 = if (data) |v| v[0..len] else &.{};
    return paste.isSafe(slice);
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

test "encode bracketed" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var encoder: Encoder = undefined;
    try testing.expect(new(&lib_alloc.test_allocator, &encoder) == .success);
    encoder_set_bracketed(encoder, true);

    const text: []u8 = try alloc.dupe(u8, "hello");
    defer alloc.free(text);

    var out: [128]u8 = undefined;
    var out_len: usize = 0;

    try testing.expect(encode(encoder, text.ptr, text.len, &out, out.len, &out_len) == .success);
    try testing.expectEqualStrings("\x1b[200~hello\x1b[201~", out[0 .. out_len - 1]);

    free(encoder);
}

test "encode unbracketed no newlines" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var encoder: Encoder = undefined;
    try testing.expect(new(&lib_alloc.test_allocator, &encoder) == .success);
    encoder_set_bracketed(encoder, false);

    const text: []u8 = try alloc.dupe(u8, "hello");
    defer alloc.free(text);

    var out: [128]u8 = undefined;
    var out_len: usize = 0;

    try testing.expect(encode(encoder, text.ptr, text.len, &out, out.len, &out_len) == .success);
    try testing.expectEqualStrings("hello", out[0 .. out_len - 1]);

    free(encoder);
}

test "encode unbracketed newlines" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var encoder: Encoder = undefined;
    try testing.expect(new(&lib_alloc.test_allocator, &encoder) == .success);
    encoder_set_bracketed(encoder, false);

    const text: []u8 = try alloc.dupe(u8, "hello\nworld");
    defer alloc.free(text);

    var out: [128]u8 = undefined;
    var out_len: usize = 0;

    try testing.expect(encode(encoder, text.ptr, text.len, &out, out.len, &out_len) == .success);
    try testing.expectEqualStrings("hello\rworld", out[0 .. out_len - 1]);

    free(encoder);
}

test "encode unbracketed windows-style newline" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var encoder: Encoder = undefined;
    try testing.expect(new(&lib_alloc.test_allocator, &encoder) == .success);
    encoder_set_bracketed(encoder, false);

    const text: []u8 = try alloc.dupe(u8, "hello\r\nworld");
    defer alloc.free(text);

    var out: [128]u8 = undefined;
    var out_len: usize = 0;

    try testing.expect(encode(encoder, text.ptr, text.len, &out, out.len, &out_len) == .success);
    try testing.expectEqualStrings("hello\r\rworld", out[0 .. out_len - 1]);

    free(encoder);
}
