const std = @import("std");
const lib_alloc = @import("../../lib/allocator.zig");
const CAllocator = lib_alloc.Allocator;
const osc = @import("../osc.zig");
const Result = @import("result.zig").Result;

const log = std.log.scoped(.osc);

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

/// C: GhosttySemanticPromptAction
pub const SemanticPromptAction = osc.semantic_prompt.Command.Action;

/// C: GhosttyOscCommandData
pub const CommandData = enum(c_int) {
    invalid = 0,
    change_window_title_str = 1,
    semantic_prompt_action = 2,
    semantic_prompt_exit_code = 3,

    /// Output type expected for querying the data of the given kind.
    pub fn OutType(comptime self: CommandData) type {
        return switch (self) {
            .invalid => void,
            .change_window_title_str => [*:0]const u8,
            .semantic_prompt_action => *SemanticPromptAction,
            .semantic_prompt_exit_code => *i32,
        };
    }
};

pub fn commandData(
    command_: Command,
    data: CommandData,
    out: ?*anyopaque,
) callconv(.c) bool {
    if (comptime std.debug.runtime_safety) {
        _ = std.meta.intToEnum(CommandData, @intFromEnum(data)) catch {
            log.warn("commandData invalid data value={d}", .{@intFromEnum(data)});
            return false;
        };
    }

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
        .semantic_prompt_action => switch (command.*) {
            .semantic_prompt => |v| out.* = v.action,
            else => return false,
        },
        .semantic_prompt_exit_code => switch (command.*) {
            .semantic_prompt => |v| {
                if (v.readOption(.exit_code)) |exit_code| {
                    out.* = exit_code;
                } else return false;
            },
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

test "semantic prompt" {
    const testing = std.testing;
    var p: Parser = undefined;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &p,
    ));
    defer free(p);

    // Parse it
    next(p, '1');
    next(p, '3');
    next(p, '3');
    next(p, ';');
    next(p, 'A');
    next(p, ';');
    next(p, 'a');
    next(p, 'i');
    next(p, 'd');
    next(p, '=');
    next(p, '1');
    next(p, '4');
    const cmd = end(p, 0);
    try testing.expectEqual(.semantic_prompt, commandType(cmd));

    // Extract the action
    var action: SemanticPromptAction = undefined;
    try testing.expect(commandData(cmd, .semantic_prompt_action, @ptrCast(&action)));
    try testing.expectEqual(SemanticPromptAction.fresh_line_new_prompt, action);
}

test "semantic prompt with exit code" {
    const testing = std.testing;
    var p: Parser = undefined;
    try testing.expectEqual(Result.success, new(
        &lib_alloc.test_allocator,
        &p,
    ));
    defer free(p);

    // Parse it
    next(p, '1');
    next(p, '3');
    next(p, '3');
    next(p, ';');
    next(p, 'D');
    next(p, ';');
    next(p, '4');
    next(p, '2');
    const cmd = end(p, 0);
    try testing.expectEqual(.semantic_prompt, commandType(cmd));

    // Extract the action
    var action: SemanticPromptAction = undefined;
    try testing.expect(commandData(cmd, .semantic_prompt_action, @ptrCast(&action)));
    try testing.expectEqual(SemanticPromptAction.end_command, action);

    // Extract the exit code
    var exit_code: i32 = 0;
    try testing.expect(commandData(cmd, .semantic_prompt_exit_code, @ptrCast(&exit_code)));
    try testing.expectEqual(@as(i32, 42), exit_code);
}
