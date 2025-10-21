const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const lib_alloc = @import("../../lib/allocator.zig");
const CAllocator = lib_alloc.Allocator;
const osc = @import("../osc.zig");
const Result = @import("result.zig").Result;

/// C: GhosttyOscParser
pub const Parser = ?*osc.Parser;

/// C: GhosttyOscCommand
pub const Command = ?*osc.Command;

pub fn new(
    alloc_: ?*const CAllocator,
    result: *Parser,
) callconv(.c) Result {
    const alloc = lib_alloc.default(alloc_);
    const ptr = alloc.create(osc.Parser) catch
        return .out_of_memory;
    ptr.* = .init(alloc);
    result.* = ptr;
    return .success;
}

pub fn free(parser_: Parser) callconv(.c) void {
    // C-built parsers always have an associated allocator.
    const parser = parser_ orelse return;
    const alloc = parser.alloc.?;
    parser.deinit();
    alloc.destroy(parser);
}

pub fn reset(parser_: Parser) callconv(.c) void {
    parser_.?.reset();
}

pub fn next(parser_: Parser, byte: u8) callconv(.c) void {
    parser_.?.next(byte);
}

pub fn end(parser_: Parser, terminator: u8) callconv(.c) Command {
    return parser_.?.end(terminator);
}

pub fn commandType(command_: Command) callconv(.c) osc.Command.Key {
    const command = command_ orelse return .invalid;
    return command.*;
}

/// C: GhosttyOscCommandData
pub const CommandData = enum(c_int) {
    invalid = 0,
    change_window_title_str = 1,

    /// Output type expected for querying the data of the given kind.
    pub fn OutType(comptime self: CommandData) type {
        return switch (self) {
            .invalid => void,
            .change_window_title_str => [*:0]const u8,
        };
    }
};

pub fn commandData(
    command_: Command,
    data: CommandData,
    out: ?*anyopaque,
) callconv(.c) bool {
    return switch (data) {
        inline else => |comptime_data| commandDataTyped(
            command_,
            comptime_data,
            @ptrCast(@alignCast(out)),
        ),
    };
}

fn commandDataTyped(
    command_: Command,
    comptime data: CommandData,
    out: *data.OutType(),
) bool {
    const command = command_.?;
    switch (data) {
        .invalid => return false,
        .change_window_title_str => switch (command.*) {
            .change_window_title => |v| out.* = v.ptr,
            else => return false,
        },
    }

    return true;
}

test "alloc" {
    const testing = std.testing;
    var p: Parser = undefined;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &p,
    ));
    free(p);
}

test "command type null" {
    const testing = std.testing;
    try testing.expectEqual(.invalid, commandType(null));
}

test "change window title" {
    const testing = std.testing;
    var p: Parser = undefined;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &p,
    ));
    defer free(p);

    // Parse it
    next(p, '0');
    next(p, ';');
    next(p, 'a');
    const cmd = end(p, 0);
    try testing.expectEqual(.change_window_title, commandType(cmd));

    // Extract the title
    var title: [*:0]const u8 = undefined;
    try testing.expect(commandData(cmd, .change_window_title_str, @ptrCast(&title)));
    try testing.expectEqualStrings("a", std.mem.span(title));
}
