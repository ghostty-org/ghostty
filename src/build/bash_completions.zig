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
pub const completions = comptimeGenerateBashCompletions();

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
    const pad5 = pad4 ++ pad1;

    try writer.writeAll(
        \\_ghostty() {
        \\
        \\  # -o nospace requires we add back a space when a completion is finished
        \\  # and not part of a --key= completion
        \\  _add_spaces() {
        \\    for idx in "${!COMPREPLY[@]}"; do
        \\      [ -n "${COMPREPLY[idx]}" ] && COMPREPLY[idx]="${COMPREPLY[idx]} ";
        \\    done
        \\  }
        \\
        \\  _fonts() {
        \\    local IFS=$'\n'
        \\    mapfile -t COMPREPLY < <( compgen -P '"' -S '"' -W "$($ghostty +list-fonts | grep '^[A-Z]' )" -- "$cur")
        \\  }
        \\
        \\  _themes() {
        \\    local IFS=$'\n'
        \\    mapfile -t COMPREPLY < <( compgen -P '"' -S '"' -W "$($ghostty +list-themes | sed -E 's/^(.*) \(.*$/\1/')" -- "$cur")
        \\  }
        \\
        \\  _files() {
        \\    mapfile -t COMPREPLY < <( compgen -o filenames -f -- "$cur" )
        \\    for i in "${!COMPREPLY[@]}"; do
        \\      if [[ -d "${COMPREPLY[i]}" ]]; then
        \\        COMPREPLY[i]="${COMPREPLY[i]}/";
        \\      fi
        \\      if [[ -f "${COMPREPLY[i]}" ]]; then
        \\        COMPREPLY[i]="${COMPREPLY[i]} ";
        \\      fi
        \\    done
        \\  }
        \\
        \\  _dirs() {
        \\    mapfile -t COMPREPLY < <( compgen -o dirnames -d -- "$cur" )
        \\    for i in "${!COMPREPLY[@]}"; do
        \\      if [[ -d "${COMPREPLY[i]}" ]]; then
        \\        COMPREPLY[i]="${COMPREPLY[i]}/";
        \\      fi
        \\    done
        \\    if [[ "${#COMPREPLY[@]}" == 0 && -d "$cur" ]]; then
        \\      COMPREPLY=( "$cur " )
        \\    fi
        \\  }
        \\
        \\  _handle_config() {
        \\    local config="--help"
        \\    config+=" --version"
        \\
    );

    for (@typeInfo(Config).@"struct".fields) |field| {
        if (field.name[0] == '_') continue;
        switch (field.type) {
            bool, ?bool => try writer.writeAll(pad2 ++ "config+=\" '--" ++ field.name ++ " '\"\n"),
            else => try writer.writeAll(pad2 ++ "config+=\" --" ++ field.name ++ "=\"\n"),
        }
    }

    try writer.writeAll(
        \\
        \\    case "$prev" in
        \\
    );

    for (@typeInfo(Config).@"struct".fields) |field| {
        if (field.name[0] == '_') continue;
        try writer.writeAll(pad3 ++ "--" ++ field.name ++ ") ");

        if (std.mem.startsWith(u8, field.name, "font-family"))
            try writer.writeAll("_fonts ;;")
        else if (std.mem.eql(u8, "theme", field.name))
            try writer.writeAll("_themes ;;")
        else if (std.mem.eql(u8, "working-directory", field.name))
            try writer.writeAll("_dirs ;;")
        else if (field.type == Config.RepeatablePath)
            try writer.writeAll("_files ;;")
        else {
            const compgenPrefix = "mapfile -t COMPREPLY < <( compgen -W \"";
            const compgenSuffix = "\" -- \"$cur\" ); _add_spaces ;;";
            switch (@typeInfo(field.type)) {
                .bool => try writer.writeAll("return ;;"),
                .@"enum" => |info| {
                    try writer.writeAll(compgenPrefix);
                    for (info.fields, 0..) |f, i| {
                        if (i > 0) try writer.writeAll(" ");
                        try writer.writeAll(f.name);
                    }
                    try writer.writeAll(compgenSuffix);
                },
                .@"struct" => |info| {
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
        \\      *) mapfile -t COMPREPLY < <( compgen -W "$config" -- "$cur" ) ;;
        \\    esac
        \\
        \\    return 0
        \\  }
        \\
        \\  _handle_actions() {
        \\
    );

    for (@typeInfo(Action).@"enum".fields) |field| {
        if (std.mem.eql(u8, "help", field.name)) continue;
        if (std.mem.eql(u8, "version", field.name)) continue;

        const options = @field(Action, field.name).options();
        // assumes options will never be created with only <_name> members
        if (@typeInfo(options).@"struct".fields.len == 0) continue;

        var buffer: [field.name.len]u8 = undefined;
        const bashName: []u8 = buffer[0..field.name.len];
        @memcpy(bashName, field.name);

        std.mem.replaceScalar(u8, bashName, '-', '_');
        try writer.writeAll(pad2 ++ "local " ++ bashName ++ "=\"");

        {
            var count = 0;
            for (@typeInfo(options).@"struct".fields) |opt| {
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
        \\    case "${COMP_WORDS[1]}" in
        \\
    );

    for (@typeInfo(Action).@"enum".fields) |field| {
        if (std.mem.eql(u8, "help", field.name)) continue;
        if (std.mem.eql(u8, "version", field.name)) continue;

        const options = @field(Action, field.name).options();
        if (@typeInfo(options).@"struct".fields.len == 0) continue;

        // bash doesn't allow variable names containing '-' so replace them
        var buffer: [field.name.len]u8 = undefined;
        const bashName: []u8 = buffer[0..field.name.len];
        _ = std.mem.replace(u8, field.name, "-", "_", bashName);

        try writer.writeAll(pad3 ++ "+" ++ field.name ++ ")\n");
        try writer.writeAll(pad4 ++ "case $prev in\n");
        for (@typeInfo(options).@"struct".fields) |opt| {
            if (opt.name[0] == '_') continue;

            try writer.writeAll(pad5 ++ "--" ++ opt.name ++ ") ");

            const compgenPrefix = "mapfile -t COMPREPLY < <( compgen -W \"";
            const compgenSuffix = "\" -- \"$cur\" ); _add_spaces ;;";
            switch (@typeInfo(opt.type)) {
                .bool => try writer.writeAll("return ;;"),
                .@"enum" => |info| {
                    try writer.writeAll(compgenPrefix);
                    for (info.fields, 0..) |f, i| {
                        if (i > 0) try writer.writeAll(" ");
                        try writer.writeAll(f.name);
                    }
                    try writer.writeAll(compgenSuffix);
                },
                .optional => |optional| {
                    switch (@typeInfo(optional.child)) {
                        .@"enum" => |info| {
                            try writer.writeAll(compgenPrefix);
                            for (info.fields, 0..) |f, i| {
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
                },
                else => {
                    if (std.mem.eql(u8, "config-file", opt.name)) {
                        try writer.writeAll("_files ;;");
                    } else try writer.writeAll("return;;");
                },
            }
            try writer.writeAll("\n");
        }
        try writer.writeAll(pad5 ++ "*) mapfile -t COMPREPLY < <( compgen -W \"$" ++ bashName ++ "\" -- \"$cur\" ) ;;\n");
        try writer.writeAll(
            \\        esac
            \\      ;;
            \\
        );
    }

    try writer.writeAll(
        \\      *) mapfile -t COMPREPLY < <( compgen -W "--help" -- "$cur" ) ;;
        \\    esac
        \\
        \\    return 0
        \\  }
        \\
        \\  # begin main logic
        \\  local topLevel="-e"
        \\  topLevel+=" --help"
        \\  topLevel+=" --version"
        \\
    );

    for (@typeInfo(Action).@"enum".fields) |field| {
        if (std.mem.eql(u8, "help", field.name)) continue;
        if (std.mem.eql(u8, "version", field.name)) continue;

        try writer.writeAll(pad1 ++ "topLevel+=\" +" ++ field.name ++ "\"\n");
    }

    try writer.writeAll(
        \\
        \\  local cur=""; local prev=""; local prevWasEq=false; COMPREPLY=()
        \\  local ghostty="$1"
        \\
        \\  # script assumes default COMP_WORDBREAKS of roughly $' \t\n"\'><=;|&(:'
        \\  # if = is missing this script will degrade to matching on keys only.
        \\  # eg: --key=
        \\  # this can be improved if needed see: https://github.com/ghostty-org/ghostty/discussions/2994
        \\
        \\  if [ "$2" = "=" ]; then cur=""
        \\  else                    cur="$2"
        \\  fi
        \\
        \\  if [ "$3" = "=" ]; then prev="${COMP_WORDS[COMP_CWORD-2]}"; prevWasEq=true;
        \\  else                    prev="${COMP_WORDS[COMP_CWORD-1]}"
        \\  fi
        \\
        \\  # current completion is double quoted add a space so the curor progresses
        \\  if [[ "$2" == \"*\" ]]; then
        \\    COMPREPLY=( "$cur " );
        \\    return;
        \\  fi
        \\
        \\  case "$COMP_CWORD" in
        \\    1)
        \\      case "${COMP_WORDS[1]}" in
        \\        -e | --help | --version) return 0 ;;
        \\        --*) _handle_config ;;
        \\        *) mapfile -t COMPREPLY < <( compgen -W "${topLevel}" -- "$cur" ); _add_spaces ;;
        \\      esac
        \\      ;;
        \\    *)
        \\      case "$prev" in
        \\        -e | --help | --version) return 0 ;;
        \\        *)
        \\          if [[ "=" != "${COMP_WORDS[COMP_CWORD]}" && $prevWasEq != true ]]; then
        \\            # must be completing with a space after the key eg: '--<key> '
        \\            # clear out prev so we don't run any of the key specific completions
        \\            prev=""
        \\          fi
        \\
        \\          case "${COMP_WORDS[1]}" in
        \\            --*) _handle_config ;;
        \\            +*) _handle_actions ;;
        \\          esac
        \\          ;;
        \\      esac
        \\      ;;
        \\  esac
        \\
        \\  return 0
        \\}
        \\
        \\complete -o nospace -o bashdefault -F _ghostty ghostty
        \\
    );
}
