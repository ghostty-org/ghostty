const std = @import("std");
const Action = @import("../../cli/ghostty.zig").Action;
const help_strings = @import("help_strings");

pub fn main() !void {
    var buffer: [2048]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&buffer);
    const stdout = &stdout_writer.interface;
    try genActions(stdout);
}

// Note: as a shortcut for defining inline editOnGithubLinks per cli action the user
// is directed to the folder view on Github. This includes a README pointing them to
// the files to edit.
pub fn genActions(writer: *std.Io.Writer) !void {
    // Write the header
    try writer.writeAll(
        \\---
        \\title: Reference
        \\description: Reference of all Ghostty action subcommands.
        \\editOnGithubLink: https://github.com/ghostty-org/ghostty/tree/main/src/cli
        \\---
        \\Ghostty includes a number of utility actions that can be accessed as subcommands.
        \\Actions provide utilities to work with config, list keybinds, list fonts, demo themes,
        \\and debug.
        \\
    );

    inline for (@typeInfo(Action).@"enum".fields) |field| {
        const action = std.meta.stringToEnum(Action, field.name).?;

        switch (action) {
            .help, .version => try writer.writeAll("## " ++ field.name ++ "\n"),
            else => try writer.writeAll("## " ++ field.name ++ "\n"),
        }

        if (@hasDecl(help_strings.Action, field.name)) {
            var iter = std.mem.splitScalar(u8, @field(help_strings.Action, field.name), '\n');
            var first = true;
            while (iter.next()) |s| {
                try writer.writeAll(s);
                try writer.writeAll("\n");
                first = false;
            }
            try writer.writeAll("\n```\n");
            switch (action) {
                .help, .version => try writer.writeAll("ghostty --" ++ field.name ++ "\n"),
                else => try writer.writeAll("ghostty +" ++ field.name ++ "\n"),
            }
            try writer.writeAll("```\n\n");
        }
    }
}
