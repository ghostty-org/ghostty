const std = @import("std");
const Config = @import("../../config/Config.zig");
const help_strings = @import("help_strings");

pub fn main() !void {
    var buffer: [2048]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&buffer);
    const stdout = &stdout_writer.interface;
    try genConfig(stdout);
}

pub fn genConfig(writer: *std.Io.Writer) !void {
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
    const fields = @typeInfo(Config).@"struct".fields;
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

        while (iter.next()) |s| {
            // Empty line resets our block
            if (std.mem.eql(u8, s, "")) {
                try endBlock(writer, block);
                block = null;

                try writer.writeAll("\n");
                continue;
            }

            // If we don't have a block figure out our type.
            const first: bool = block == null;
            if (block == null) {
                if (std.mem.startsWith(u8, s, "    ")) {
                    block = .code;
                    try writer.writeAll("```\n");
                } else if (std.ascii.startsWithIgnoreCase(s, "note:")) {
                    block = .callout_note;
                    try writer.writeAll("<Note>\n");
                } else if (std.ascii.startsWithIgnoreCase(s, "warning:")) {
                    block = .callout_warning;
                    try writer.writeAll("<Warning>\n");
                } else {
                    block = .text;
                }
            }

            try writer.writeAll(switch (block.?) {
                .text => s,
                .callout_note => if (first) s["note:".len..] else s,
                .callout_warning => if (first) s["warning:".len..] else s,

                .code => if (std.mem.startsWith(u8, s, "    "))
                    s[4..]
                else
                    s,
            });
            try writer.writeAll("\n");
        }
        try endBlock(writer, block);
        try writer.writeAll("\n");
    }
}

fn endBlock(writer: *std.Io.Writer, block: anytype) !void {
    if (block) |v| switch (v) {
        .text => {},
        .code => try writer.writeAll("```\n"),
        .callout_note => try writer.writeAll("</Note>\n"),
        .callout_warning => try writer.writeAll("</Warning>\n"),
    };
}
