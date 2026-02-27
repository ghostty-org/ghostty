//! Fish completions.
const std = @import("std");

const Config = @import("../config/Config.zig");
const Action = @import("../cli.zig").ghostty.Action;
const help_strings = @import("help_strings");

/// A fish completions configuration that contains all the available commands
/// and options.
pub const completions = comptimeGenerateCompletions();

fn comptimeGenerateCompletions() []const u8 {
    comptime {
        @setEvalBranchQuota(50000);
        var counter: std.Io.Writer.Discarding = .init(&.{});
        try writeCompletions(&counter.writer);

        var buf: [counter.count]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        try writeCompletions(&writer);
        const final = buf;
        return final[0..writer.end];
    }
}

fn writeCompletions(writer: *std.Io.Writer) !void {
    {
        try writer.writeAll("set -l commands \"");
        var count: usize = 0;
        for (@typeInfo(Action).@"enum".fields) |field| {
            if (count > 0) try writer.writeAll(" ");
            try writer.writeAll("+");
            try writer.writeAll(field.name);
            count += 1;
        }
        try writer.writeAll("\"\n");
    }

    try writer.writeAll("complete -c ghostty -f\n");

    try writer.writeAll("complete -c ghostty -s e -l help -f\n");
    try writer.writeAll("complete -c ghostty -n \"not __fish_seen_subcommand_from $commands\" -l version -f\n");

    for (@typeInfo(Config).@"struct".fields) |field| {
        if (field.name[0] == '_') continue;

        try writer.writeAll("complete -c ghostty -n \"not __fish_seen_subcommand_from $commands\" -l ");
        try writer.writeAll(field.name);
        try writer.writeAll(if (field.type != bool) " -r" else " ");
        if (std.mem.startsWith(u8, field.name, "font-family"))
            try writer.writeAll(" -f  -a \"(ghostty +list-fonts | grep '^[A-Z]')\"")
        else if (std.mem.eql(u8, "theme", field.name))
            try writer.writeAll(" -f -a \"(ghostty +list-themes | sed -E 's/^(.*) \\(.*\\$/\\1/')\"")
        else if (std.mem.eql(u8, "working-directory", field.name))
            try writer.writeAll(" -f -k -a \"(__fish_complete_directories)\"")
        else {
            try writer.writeAll(if (field.type != Config.RepeatablePath) " -f" else " -F");
            switch (@typeInfo(field.type)) {
                .bool => {},
                .@"enum" => |info| {
                    try writer.writeAll(" -a \"");
                    for (info.fields, 0..) |f, i| {
                        if (i > 0) try writer.writeAll(" ");
                        try writer.writeAll(f.name);
                    }
                    try writer.writeAll("\"");
                },
                .@"struct" => |info| {
                    if (!@hasDecl(field.type, "parseCLI") and info.layout == .@"packed") {
                        try writer.writeAll(" -a \"");
                        for (info.fields, 0..) |f, i| {
                            if (i > 0) try writer.writeAll(" ");
                            try writer.writeAll(f.name);
                            try writer.writeAll(" no-");
                            try writer.writeAll(f.name);
                        }
                        try writer.writeAll("\"");
                    }
                },
                else => {},
            }
        }

        if (@hasDecl(help_strings.Config, field.name)) {
            const help = @field(help_strings.Config, field.name);
            const desc = getDescription(help);
            try writer.writeAll(" -d \"");
            try writer.writeAll(desc);
            try writer.writeAll("\"");
        }

        try writer.writeAll("\n");
    }

    {
        try writer.writeAll("complete -c ghostty -n \"string match -q -- '+*' (commandline -pt)\" -f -a \"");
        var count: usize = 0;
        for (@typeInfo(Action).@"enum".fields) |field| {
            if (count > 0) try writer.writeAll(" ");
            try writer.writeAll("+");
            try writer.writeAll(field.name);
            count += 1;
        }
        try writer.writeAll("\"\n");
    }

    for (@typeInfo(Action).@"enum".fields) |field| {
        if (std.mem.eql(u8, "help", field.name)) continue;
        if (std.mem.eql(u8, "version", field.name)) continue;

        const options = @field(Action, field.name).options();
        for (@typeInfo(options).@"struct".fields) |opt| {
            if (opt.name[0] == '_') continue;
            try writer.writeAll("complete -c ghostty -n \"__fish_seen_subcommand_from +" ++ field.name ++ "\" -l ");
            try writer.writeAll(opt.name);
            try writer.writeAll(if (opt.type != bool) " -r" else "");

            // special case +validate_config --config-file
            if (std.mem.eql(u8, "config-file", opt.name)) {
                try writer.writeAll(" -F");
            } else try writer.writeAll(" -f");

            switch (@typeInfo(opt.type)) {
                .bool => {},
                .@"enum" => |info| {
                    try writer.writeAll(" -a \"");
                    for (info.fields, 0..) |f, i| {
                        if (i > 0) try writer.writeAll(" ");
                        try writer.writeAll(f.name);
                    }
                    try writer.writeAll("\"");
                },
                .optional => |optional| {
                    switch (@typeInfo(optional.child)) {
                        .@"enum" => |info| {
                            try writer.writeAll(" -a \"");
                            for (info.fields, 0..) |f, i| {
                                if (i > 0) try writer.writeAll(" ");
                                try writer.writeAll(f.name);
                            }
                            try writer.writeAll("\"");
                        },
                        else => {},
                    }
                },
                else => {},
            }
            try writer.writeAll("\n");
        }
    }
}

fn getDescription(comptime help: []const u8) []const u8 {
    var out: [help.len * 2]u8 = undefined;
    var len: usize = 0;
    var prev_was_space = false;

    for (help, 0..) |c, i| {
        switch (c) {
            '.' => {
                out[len] = '.';
                len += 1;

                if (i + 1 >= help.len) break;
                const next = help[i + 1];
                if (next == ' ' or next == '\n') break;
            },
            '\n' => {
                if (!prev_was_space and len > 0) {
                    out[len] = ' ';
                    len += 1;
                    prev_was_space = true;
                }
            },
            '"' => {
                out[len] = '\\';
                out[len + 1] = '"';
                len += 2;
                prev_was_space = false;
            },
            else => {
                out[len] = c;
                len += 1;
                prev_was_space = (c == ' ');
            },
        }
    }

    return out[0..len];
}

test "getDescription" {
    const testing = std.testing;

    const input = "First sentence with \"quotes\"\nand newlines. Second sentence.";
    const expected = "First sentence with \\\"quotes\\\" and newlines.";

    comptime {
        const result = getDescription(input);
        try testing.expectEqualStrings(expected, result);
    }
}
