const std = @import("std");

const Config = @import("../config/Config.zig");
const Action = @import("../cli/action.zig").Action;

/// A bash completions configuration that contains all the available commands
/// and options.
///
/// Notes: bash completion support for --<key>=<value> depends on setting the completion
/// system to _not_ print a space following each successful completion (see -o nospace).
/// This results leading or tailing spaces being necessary to move onto the next match.
///
/// bash completion will read = as it's own completiong word regardless of whether or not
/// it's part of an on going completion like --<key>=. Working around this requires looking
/// backward in the command line args to pretend the = is an empty string
/// see: https://www.gnu.org/software/gnuastro/manual/html_node/Bash-TAB-completion-tutorial.html
pub const bash_completions = comptimeGenerateBashCompletions();

fn comptimeGenerateBashCompletions() []const u8 {
    comptime {
        @setEvalBranchQuota(50000);
        var counter = std.io.countingWriter(std.io.null_writer);
        try writeBashCompletions(&counter.writer());

        var buf: [counter.bytes_written]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        try writeBashCompletions(stream.writer());
        const final = buf;
        return final[0..stream.getWritten().len];
    }
}

fn writeBashCompletions(writer: anytype) !void {
    const pad1 = "  ";
    const pad2 = pad1 ++ pad1;
    const pad3 = pad2 ++ pad1;
    const pad4 = pad3 ++ pad1;

    try writer.writeAll(
        \\# -o nospace requires we add back a space when a completion is finished
        \\# and not part of a --key= completion
        \\addSpaces() {
        \\  for idx in "${!COMPREPLY[@]}"; do
        \\    [ -n "${COMPREPLY[idx]}" ] && COMPREPLY[idx]="${COMPREPLY[idx]} ";
        \\  done
        \\}
        \\
        \\config="--help"
        \\config+=" --version"
        \\
    );

    for (@typeInfo(Config).Struct.fields) |field| {
        if (field.name[0] == '_') continue;
        switch (field.type) {
            bool, ?bool => try writer.writeAll("config+=\" '--" ++ field.name ++ " '\"\n"),
            else => try writer.writeAll("config+=\" --" ++ field.name ++ "=\"\n"),
        }
    }

    try writer.writeAll(
        \\
        \\_handleConfig() {
        \\  case "$prev" in
        \\
    );

    for (@typeInfo(Config).Struct.fields) |field| {
        if (field.name[0] == '_') continue;
        try writer.writeAll(pad2 ++ "--" ++ field.name ++ ") ");

        if (std.mem.startsWith(u8, field.name, "font-family"))
            try writer.writeAll("return ;;")
        else if (std.mem.eql(u8, "theme", field.name))
            try writer.writeAll("return ;;")
        else if (std.mem.eql(u8, "working-directory", field.name))
            try writer.writeAll("return ;;")
        else if (field.type == Config.RepeatablePath)
            try writer.writeAll("return ;;")
        else {
            const compgenPrefix = "mapfile -t COMPREPLY < <( compgen -W \"";
            const compgenSuffix = "\" -- \"$cur\" ); addSpaces ;;";
            switch (@typeInfo(field.type)) {
                .Bool => try writer.writeAll("return ;;"),
                .Enum => |info| {
                    try writer.writeAll(compgenPrefix);
                    for (info.fields, 0..) |f, i| {
                        if (i > 0) try writer.writeAll(" ");
                        try writer.writeAll(f.name);
                    }
                    try writer.writeAll(compgenSuffix);
                },
                .Struct => |info| {
                    if (!@hasDecl(field.type, "parseCLI") and info.layout == .@"packed") {
                        try writer.writeAll(compgenPrefix);
                        for (info.fields, 0..) |f, i| {
                            if (i > 0) try writer.writeAll(" ");
                            try writer.writeAll(f.name ++ " no-" ++ f.name);
                        }
                        try writer.writeAll(compgenSuffix);
                    } else {
                        try writer.writeAll("return ;;");
                    }
                },
                else => try writer.writeAll("return ;;"),
            }
        }

        try writer.writeAll("\n");
    }

    try writer.writeAll(
        \\    *) mapfile -t COMPREPLY < <( compgen -W "$config" -- "$cur" ) ;;
        \\  esac
        \\
        \\  return 0
        \\}
        \\
        \\
    );

    for (@typeInfo(Action).Enum.fields) |field| {
        if (std.mem.eql(u8, "help", field.name)) continue;
        if (std.mem.eql(u8, "version", field.name)) continue;

        const options = @field(Action, field.name).options();
        // assumes options will never be created with only <_name> members
        if (@typeInfo(options).Struct.fields.len == 0) continue;

        var buffer: [field.name.len]u8 = undefined;
        const bashName: []u8 = buffer[0..field.name.len];
        @memcpy(bashName, field.name);

        std.mem.replaceScalar(u8, bashName, '-', '_');
        try writer.writeAll(bashName ++ "=\"");

        {
            var count = 0;
            for (@typeInfo(options).Struct.fields) |opt| {
                if (opt.name[0] == '_') continue;
                if (count > 0) try writer.writeAll(" ");
                switch (opt.type) {
                    bool, ?bool => try writer.writeAll("'--" ++ opt.name ++ " '"),
                    else => try writer.writeAll("--" ++ opt.name ++ "="),
                }
                count += 1;
            }
        }
        try writer.writeAll(" --help\"\n");
    }

    try writer.writeAll(
        \\
        \\_handleActions() {
        \\  case "${COMP_WORDS[1]}" in
        \\
    );

    for (@typeInfo(Action).Enum.fields) |field| {
        if (std.mem.eql(u8, "help", field.name)) continue;
        if (std.mem.eql(u8, "version", field.name)) continue;

        const options = @field(Action, field.name).options();
        if (@typeInfo(options).Struct.fields.len == 0) continue;

        // bash doesn't allow variable names containing '-' so replace them
        var buffer: [field.name.len]u8 = undefined;
        const bashName: []u8 = buffer[0..field.name.len];
        _ = std.mem.replace(u8, field.name, "-", "_", bashName);

        try writer.writeAll(pad2 ++ "+" ++ field.name ++ ")\n");
        try writer.writeAll(pad3 ++ "case $prev in\n");
        for (@typeInfo(options).Struct.fields) |opt| {
            if (opt.name[0] == '_') continue;

            try writer.writeAll(pad4 ++ "--" ++ opt.name ++ ") ");

            const compgenPrefix = "mapfile -t COMPREPLY < <( compgen -W \"";
            const compgenSuffix = "\" -- \"$cur\" ); addSpaces ;;";
            switch (@typeInfo(opt.type)) {
                .Bool => try writer.writeAll("return ;;"),
                .Enum => |info| {
                    try writer.writeAll(compgenPrefix);
                    for (info.opts, 0..) |f, i| {
                        if (i > 0) try writer.writeAll(" ");
                        try writer.writeAll(f.name);
                    }
                    try writer.writeAll(compgenSuffix);
                },
                else => {
                    if (std.mem.eql(u8, "config-file", opt.name)) {
                        try writer.writeAll("return ;;");
                    } else try writer.writeAll("return;;");
                },
            }
            try writer.writeAll("\n");
        }
        try writer.writeAll(pad4 ++ "*) mapfile -t COMPREPLY < <( compgen -W \"$" ++ bashName ++ "\" -- \"$cur\" ) ;;\n");
        try writer.writeAll(
            \\      esac
            \\    ;;
            \\
        );
    }

    try writer.writeAll(
        \\    *) mapfile -t COMPREPLY < <( compgen -W "--help" -- "$cur" ) ;;
        \\  esac
        \\
        \\  return 0
        \\}
        \\
        \\topLevel="-e"
        \\topLevel+=" --help"
        \\topLevel+=" --version"
        \\
    );

    for (@typeInfo(Action).Enum.fields) |field| {
        if (std.mem.eql(u8, "help", field.name)) continue;
        if (std.mem.eql(u8, "version", field.name)) continue;

        try writer.writeAll("topLevel+=\" +" ++ field.name ++ "\"\n");
    }

    try writer.writeAll(
        \\
        \\_ghostty() {
        \\  cur=""; prev=""; prevWasEq=false; COMPREPLY=()
        \\  ghostty="$1"
        \\
        \\  if [ "$2" = "=" ]; then cur=""
        \\  else                    cur="$2"
        \\  fi
        \\
        \\  if [ "$3" = "=" ]; then prev="${COMP_WORDS[COMP_CWORD-2]}"; prevWasEq=true;
        \\  else                    prev="${COMP_WORDS[COMP_CWORD-1]}"
        \\  fi
        \\
        \\  case "$COMP_CWORD" in
        \\    1)
        \\      case "${COMP_WORDS[1]}" in
        \\        -e | --help | --version) return 0 ;;
        \\        --*) _handleConfig ;;
        \\        *) mapfile -t COMPREPLY < <( compgen -W "${topLevel}" -- "$cur" ); addSpaces ;;
        \\      esac
        \\      ;;
        \\    *)
        \\      case "$prev" in
        \\        -e | --help | --version) return 0 ;;
        \\        *)
        \\          case "${COMP_WORDS[1]}" in
        \\            --*) _handleConfig ;;
        \\            +*) _handleActions ;;
        \\          esac
        \\          ;;
        \\      esac
        \\      ;;
        \\  esac
        \\
        \\  return 0
        \\}
        \\
        \\if ! command -v mapfile 2>&1 >/dev/null
        \\then
        \\  echo "mapfile could not be found. ghostty autocomplete requires bash >=4.0"
        \\else
        \\  complete -o nospace -o bashdefault -F _ghostty ghostty
        \\fi
        \\
    );
}
