const std = @import("std");
const paste = @import("../../input/paste.zig");
const lib_alloc = @import("../../lib/allocator.zig");
const CAllocator = lib_alloc.Allocator;
const Result = @import("result.zig").Result;

/// C: GhosttyPasteOptions
pub const Options = ?*paste.Options;

pub fn options_new(
    alloc_: ?*const CAllocator,
    result: *Options,
) callconv(.c) Result {
    const alloc = lib_alloc.default(alloc_);
    const ptr = alloc.create(paste.Options) catch
        return .out_of_memory;
    result.* = ptr;
    return .success;
}

pub fn options_free(alloc_: ?*const CAllocator, options_: Options) callconv(.c) void {
    const alloc = lib_alloc.default(alloc_);
    const options = options_ orelse return;
    alloc.destroy(options);
}

pub fn options_set_bracketed(options_: Options, enabled: bool) callconv(.c) void {
    const options = options_ orelse return;
    options.bracketed = enabled;
}

pub fn encode(
    alloc_: ?*const CAllocator,
    data_: ?[*]u8,
    len: usize,
    options_: Options,
    out: ?*[*]u8,
) callconv(.c) Result {
    const alloc = lib_alloc.default(alloc_);
    // make data mutable
    const data: []u8 = if (data_) |d|
        alloc.dupe(u8, d[0..len]) catch {
            return .out_of_memory;
        }
    else
        &.{};

    const options = if (options_) |o| o else &paste.Options{ .bracketed = false };
    const encoded: [3][]const u8 = paste.encode(data, options.*);

    const buf = alloc.alloc(u8, encoded[0].len + encoded[1].len + encoded[2].len) catch
        return .out_of_memory;
    var offset: usize = 0;
    for (encoded[0..]) |part| {
        @memmove(buf[offset..][0..part.len], part);
        offset += part.len;
    }
    if (out) |o| {
        o.* = buf.ptr;
    }
    alloc.free(data);
    return .success;
}

pub fn encode_free(alloc_: ?*const CAllocator, data: ?[*]u8, len: usize) callconv(.c) void {
    const alloc = lib_alloc.default(alloc_);
    if (data) |d| {
        alloc.free(d[0..len]);
    }
}

pub fn is_safe(data: ?[*]const u8, len: usize) callconv(.c) bool {
    const slice: []const u8 = if (data) |v| v[0..len] else &.{};
    return paste.isSafe(slice);
}

test "alloc options" {
    const testing = std.testing;
    var opts: Options = null;
    try testing.expectEqual(Result.success, options_new(&lib_alloc.test_allocator, &opts));
    try testing.expect(opts != null);
    options_free(&lib_alloc.test_allocator, opts);
}

test "set bracketed" {
    const testing = std.testing;
    var opts: Options = null;
    try testing.expectEqual(Result.success, options_new(&lib_alloc.test_allocator, &opts));
    try testing.expect(opts != null);
    options_set_bracketed(opts, true);
    try testing.expect(opts.?.bracketed);
    options_free(&lib_alloc.test_allocator, opts);
}

test "encode simple" {
    const testing = std.testing;
    var out: ?[*]u8 = null;
    const data = "hello world";

    var opts: Options = null;
    try testing.expectEqual(Result.success, options_new(&lib_alloc.test_allocator, &opts));
    try testing.expect(opts != null);

    try testing.expectEqual(
        Result.success,
        encode(
            &lib_alloc.test_allocator,
            data.ptr,
            data.len,
            opts,
            &out,
        ),
    );
    try testing.expect(out != null);
    try testing.expectEqualStrings("hello world", out.?[0..data.len]);
    encode_free(&lib_alloc.test_allocator, out, data.len);
}

test "encode bracketed" {
    const testing = std.testing;
    var opts: Options = null;
    try testing.expectEqual(Result.success, options_new(&lib_alloc.test_allocator, &opts));
    try testing.expect(opts != null);
    options_set_bracketed(opts, true);

    var out: ?[*]u8 = null;
    const data = "hello world";
    try testing.expectEqual(
        Result.success,
        encode(
            &lib_alloc.test_allocator,
            data.ptr,
            data.len,
            opts,
            &out,
        ),
    );
    try testing.expect(out != null);
    try testing.expectEqualStrings("\x1b[200~hello world\x1b[201~", out.?[0 .. data.len + 12]);
    encode_free(&lib_alloc.test_allocator, out, data.len + 12);
    options_free(&lib_alloc.test_allocator, opts);
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
