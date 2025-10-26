const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const lib_alloc = @import("../../lib/allocator.zig");
const CAllocator = lib_alloc.Allocator;
const sgr = @import("../sgr.zig");
const Result = @import("result.zig").Result;

const log = std.log.scoped(.sgr);

/// Wrapper around parser that tracks the allocator for C API usage.
const ParserWrapper = struct {
    parser: sgr.Parser,
    alloc: Allocator,
};

/// C: GhosttySgrParser
pub const Parser = ?*ParserWrapper;

pub fn new(
    alloc_: ?*const CAllocator,
    result: *Parser,
) callconv(.c) Result {
    const alloc = lib_alloc.default(alloc_);
    const ptr = alloc.create(ParserWrapper) catch
        return .out_of_memory;
    ptr.* = .{
        .parser = .empty,
        .alloc = alloc,
    };
    result.* = ptr;
    return .success;
}

pub fn free(parser_: Parser) callconv(.c) void {
    const wrapper = parser_ orelse return;
    const alloc = wrapper.alloc;
    const parser: *sgr.Parser = &wrapper.parser;
    if (parser.params.len > 0) alloc.free(parser.params);
    alloc.destroy(wrapper);
}

pub fn reset(parser_: Parser) callconv(.c) void {
    const wrapper = parser_ orelse return;
    const parser: *sgr.Parser = &wrapper.parser;
    parser.idx = 0;
}

pub fn setParams(
    parser_: Parser,
    params: [*]const u16,
    seps_: ?[*]const u8,
    len: usize,
) callconv(.c) Result {
    const wrapper = parser_ orelse return .invalid_value;
    const alloc = wrapper.alloc;
    const parser: *sgr.Parser = &wrapper.parser;

    // Copy our new parameters
    const params_slice = alloc.dupe(u16, params[0..len]) catch
        return .out_of_memory;
    if (parser.params.len > 0) alloc.free(parser.params);
    parser.params = params_slice;

    // If we have separators, set that state too.
    parser.params_sep = .initEmpty();
    if (seps_) |seps| {
        if (len > @TypeOf(parser.params_sep).bit_length) {
            log.warn("ghostty_sgr_set_params: separators length {} exceeds max supported length {}", .{
                len,
                @TypeOf(parser.params_sep).bit_length,
            });
            return .invalid_value;
        }

        for (seps[0..len], 0..) |sep, i| {
            if (sep == ':') parser.params_sep.set(i);
        }
    }

    // Reset our parsing state
    parser.idx = 0;

    return .success;
}

pub fn next(
    parser_: Parser,
    result: *sgr.Attribute.C,
) callconv(.c) bool {
    const wrapper = parser_ orelse return false;
    const parser: *sgr.Parser = &wrapper.parser;
    if (parser.next()) |attr| {
        result.* = attr.cval();
        return true;
    }

    return false;
}

pub fn unknown_full(
    unknown: sgr.Attribute.Unknown.C,
    ptr: ?*[*]const u16,
) callconv(.c) usize {
    if (ptr) |p| p.* = unknown.full_ptr;
    return unknown.full_len;
}

pub fn unknown_partial(
    unknown: sgr.Attribute.Unknown.C,
    ptr: ?*[*]const u16,
) callconv(.c) usize {
    if (ptr) |p| p.* = unknown.partial_ptr;
    return unknown.partial_len;
}

pub fn attribute_tag(
    attr: sgr.Attribute.C,
) callconv(.c) sgr.Attribute.Tag {
    return attr.tag;
}

pub fn attribute_value(
    attr: *sgr.Attribute.C,
) callconv(.c) *sgr.Attribute.CValue {
    return &attr.value;
}

pub fn wasm_alloc_attribute() callconv(.c) *sgr.Attribute.C {
    const alloc = std.heap.wasm_allocator;
    const ptr = alloc.create(sgr.Attribute.C) catch @panic("out of memory");
    return ptr;
}

pub fn wasm_free_attribute(attr: *sgr.Attribute.C) callconv(.c) void {
    const alloc = std.heap.wasm_allocator;
    alloc.destroy(attr);
}

test "alloc" {
    var p: Parser = undefined;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &p,
    ));
    free(p);
}

test "simple params, no seps" {
    var p: Parser = undefined;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &p,
    ));
    defer free(p);

    try testing.expectEqual(Result.success, setParams(
        p,
        &.{1},
        null,
        1,
    ));

    // Set it twice on purpose to make sure we don't leak.
    try testing.expectEqual(Result.success, setParams(
        p,
        &.{1},
        null,
        1,
    ));

    // Verify we get bold
    var attr: sgr.Attribute.C = undefined;
    try testing.expect(next(p, &attr));
    try testing.expectEqual(.bold, attr.tag);

    // Nothing else
    try testing.expect(!next(p, &attr));
}
