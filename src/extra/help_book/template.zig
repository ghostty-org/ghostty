//! A minimal comptime-parsed template engine for the help book assets:
//! `{{name}}` placeholders in a template are replaced by the identically
//! named field of the `args` struct; everything else is written through
//! verbatim. Values are written as-is, so callers must HTML-escape any
//! dynamic value that needs it. A placeholder without a matching field is
//! a compile error.
const std = @import("std");

pub fn write(
    w: *std.Io.Writer,
    comptime source: []const u8,
    args: anytype,
) !void {
    const parts = comptime parse(source);
    inline for (parts) |part| switch (part) {
        .literal => |text| try w.writeAll(text),
        .placeholder => |name| try w.writeAll(@field(args, name)),
    };
}

const Part = union(enum) {
    literal: []const u8,
    placeholder: []const u8,
};

fn parse(comptime source: []const u8) []const Part {
    @setEvalBranchQuota(1_000_000);
    var parts: []const Part = &.{};
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, source, i, "{{")) |start| {
        const end = std.mem.indexOfPos(u8, source, start + 2, "}}") orelse
            @compileError("unterminated {{placeholder}} in template");
        if (start > i) parts = parts ++ [_]Part{.{ .literal = source[i..start] }};
        parts = parts ++ [_]Part{.{ .placeholder = source[start + 2 .. end] }};
        i = end + 2;
    }
    if (i < source.len) parts = parts ++ [_]Part{.{ .literal = source[i..] }};
    return parts;
}

test "template substitution" {
    const testing = std.testing;

    var stream: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stream.deinit();

    try write(&stream.writer, "<title>{{title}}</title>{{body}} and {{title}}", .{
        .title = "T",
        .body = "<p>B</p>",
    });
    try testing.expectEqualStrings("<title>T</title><p>B</p> and T", stream.written());
}
