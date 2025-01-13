const std = @import("std");
const Config = @import("../../config/Config.zig");
const help_strings = @import("help_strings");
const formatter = @import("../../config/formatter.zig");

pub fn main() !void {
    const output = std.io.getStdOut().writer();
    try genConfig(output);
}

pub fn genConfig(writer: anytype) !void {
    // Write the header
    try writer.writeAll(
        \\---
        \\title: Reference
        \\description: Reference of all Ghostty configuration options.
        \\editOnGithubLink: https://github.com/ghostty-org/ghostty/edit/main/src/config/Config.zig
        \\---
        \\
        \\This is a reference of all Ghostty configuration options. These
        \\options are ordered roughly by how common they are to be used
        \\and grouped with related options. I recommend utilizing your
        \\browser's search functionality to find the option you're looking
        \\for.
        \\
        \\In the future, we'll have a more user-friendly way to view and
        \\organize these options.
        \\
        \\
    );

    @setEvalBranchQuota(50_000);
    const fields = @typeInfo(Config).Struct.fields;
    inline for (fields, 0..) |field, i| {
        if (field.name[0] == '_') continue;
        if (!@hasDecl(help_strings.Config, field.name)) continue;

        // Write the field name.
        try writer.writeAll("## `");
        try writer.writeAll(field.name);
        try writer.writeAll("`\n");

        // For all subsequent fields with no docs, they are grouped
        // with the previous field.
        if (i + 1 < fields.len) {
            inline for (fields[i + 1 ..]) |next_field| {
                if (next_field.name[0] == '_') break;
                if (@hasDecl(help_strings.Config, next_field.name)) break;

                try writer.writeAll("## `");
                try writer.writeAll(next_field.name);
                try writer.writeAll("`\n");
            }
        }

        // Newline after our headers
        try writer.writeAll("\n");

        var iter = std.mem.splitScalar(
            u8,
            @field(help_strings.Config, field.name),
            '\n',
        );

        // We do some really rough markdown "parsing" here so that
        // we can fix up some styles for what our website expects.
        var block: ?enum {
            /// Plaintext, do nothing.
            text,

            /// Code block, wrap in triple backticks. We use indented
            /// code blocks in our comments but the website parser only
            /// supports triple backticks.
            code,

            /// Callouts. We detect these based on paragraphs starting
            /// with "Note:", "Warning:", etc. (case-insensitive).
            callout_note,
            callout_warning,
        } = null;
        var block_indent: usize = 0;

        while (iter.next()) |line| {
            var indent: usize = 0;
            while (indent < line.len and line[indent] == ' ') : (indent += 1) {}
            const s = line[indent..];

            // Empty line resets our block
            if (std.mem.eql(u8, s, "")) {
                try writer.writeByteNTimes(' ', block_indent);
                try endBlock(writer, block);
                block = null;

                try writer.writeAll("\n");
                continue;
            }

            // If we don't have a block figure out our type.
            const first: bool = block == null;
            if (block == null) block: {
                if (indent == 4) {
                    block = .code;
                    try writer.writeAll("```\n");
                    break :block;
                }

                try writer.writeByteNTimes(' ', indent);
                block_indent = indent;

                if (std.ascii.startsWithIgnoreCase(s, "note:")) {
                    block = .callout_note;
                    try writer.writeAll("<Note>\n");
                    try writer.writeByteNTimes(' ', indent);
                } else if (std.ascii.startsWithIgnoreCase(s, "warning:")) {
                    block = .callout_warning;
                    try writer.writeAll("<Warning>\n");
                    try writer.writeByteNTimes(' ', indent);
                } else {
                    block = .text;
                }
            } else if (block != .code) {
                try writer.writeByteNTimes(' ', indent);
            }

            try writer.writeAll(switch (block.?) {
                .text, .code => s,
                .callout_note => std.mem.trim(u8, if (first) s["note:".len..] else s, " "),
                .callout_warning => std.mem.trim(u8, if (first) s["warning:".len..] else s, " "),
            });
            try writer.writeAll("\n");
        }
        try endBlock(writer, block);
        try writer.writeAll("\n");
    }
}

fn endBlock(writer: anytype, block: anytype) !void {
    if (block) |v| switch (v) {
        .text => {},
        .code => try writer.writeAll("```\n"),
        .callout_note => try writer.writeAll("</Note>\n"),
        .callout_warning => try writer.writeAll("</Warning>\n"),
    };
}
