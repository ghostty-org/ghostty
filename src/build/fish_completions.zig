const std = @import("std");

const Config = @import("../config/Config.zig");
const Action = @import("../cli/action.zig").Action;

/// A fish completions configuration that contains all the available commands
/// and options.
pub const completions = comptimeGenerateFishCompletions();

fn comptimeGenerateFishCompletions() []const u8 {
    comptime {
        @setEvalBranchQuota(50000);
        var counter = std.io.countingWriter(std.io.null_writer);
        try writeFishCompletions(&counter.writer());

        var buf: [counter.bytes_written]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        try writeFishCompletions(stream.writer());
        const final = buf;
        return final[0..stream.getWritten().len];
    }
}

fn writeFishCompletions(writer: anytype) !void {
    {
        try writer.writeAll("set -l commands \"");
        var count: usize = 0;
        for (@typeInfo(Action).@"enum".fields) |field| {
            if (std.mem.eql(u8, "help", field.name)) continue;
            if (std.mem.eql(u8, "version", field.name)) continue;
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
        try writer.writeAll("\n");
    }

    {
        try writer.writeAll("complete -c ghostty -n \"string match -q -- '+*' (commandline -pt)\" -f -a \"");
        var count: usize = 0;
        for (@typeInfo(Action).@"enum".fields) |field| {
            if (std.mem.eql(u8, "help", field.name)) continue;
            if (std.mem.eql(u8, "version", field.name)) continue;
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
