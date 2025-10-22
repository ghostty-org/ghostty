//! This module is a help generator for keybind actions documentation.
//! It can generate documentation in different formats (plaintext for CLI,
//! markdown for website) while maintaining consistent content.

const std = @import("std");
const KeybindAction = @import("Binding.zig").Action;
const help_strings = @import("help_strings");

/// Format options for generating keybind actions documentation
pub const Format = enum {
    /// Plain text output with indentation
    plaintext,
    /// Markdown formatted output
    markdown,

    fn formatFieldName(self: Format, writer: *std.Io.Writer, field_name: []const u8) !void {
        switch (self) {
            .plaintext => {
                try writer.writeAll(field_name);
                try writer.writeAll(":\n");
            },
            .markdown => {
                try writer.writeAll("## `");
                try writer.writeAll(field_name);
                try writer.writeAll("`\n");
            },
        }
    }

    fn formatDocLine(self: Format, writer: *std.Io.Writer, line: []const u8) !void {
        switch (self) {
            .plaintext => {
                try writer.writeAll("  ");
                try writer.writeAll(line);
                try writer.writeAll("\n");
            },
            .markdown => {
                try writer.writeAll(line);
                try writer.writeAll("\n");
            },
        }
    }

    fn header(self: Format) ?[]const u8 {
        return switch (self) {
            .plaintext => null,
            .markdown =>
            \\---
            \\title: Keybinding Action Reference
            \\description: Reference of all Ghostty keybinding actions.
            \\editOnGithubLink: https://github.com/ghostty-org/ghostty/edit/main/src/input/Binding.zig
            \\---
            \\
            \\This is a reference of all Ghostty keybinding actions.
            \\
            \\
            ,
        };
    }
};

/// Generate keybind actions documentation with the specified format
pub fn generate(
    writer: *std.Io.Writer,
    format: Format,
    show_docs: bool,
    page_allocator: std.mem.Allocator,
) !void {
    if (format.header()) |header| {
        try writer.writeAll(header);
    }

    var stream: std.Io.Writer.Allocating = .init(page_allocator);
    defer stream.deinit();

    const fields = @typeInfo(KeybindAction).@"union".fields;
    inline for (fields) |field| {
        if (field.name[0] == '_') continue;

        // Write previously stored doc comment below all related actions
        if (show_docs and @hasDecl(help_strings.KeybindAction, field.name)) {
            try writer.writeAll(stream.written());
            try writer.writeAll("\n");
            stream.clearRetainingCapacity();
        }

        if (show_docs) {
            try format.formatFieldName(writer, field.name);
        } else {
            try writer.writeAll(field.name);
            try writer.writeAll("\n");
        }

        if (show_docs and @hasDecl(help_strings.KeybindAction, field.name)) {
            var iter = std.mem.splitScalar(
                u8,
                @field(help_strings.KeybindAction, field.name),
                '\n',
            );
            while (iter.next()) |s| {
                // If it is the last line and empty, then skip it.
                if (iter.peek() == null and s.len == 0) continue;
                try format.formatDocLine(&stream.writer, s);
            }
        }
    }

    // Write any remaining buffered documentation
    if (stream.written().len > 0) {
        try writer.writeAll(stream.written());
    }
}
