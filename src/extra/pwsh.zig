const std = @import("std");

const Config = @import("../config/Config.zig");
const Action = @import("../cli.zig").ghostty.Action;

/// PowerShell completions that contains all available commands and options.
pub const module = comptimeGeneratePwshCompletions();

fn comptimeGeneratePwshCompletions() []const u8 {
    comptime {
        @setEvalBranchQuota(50000);
        var counter: std.Io.Writer.Discarding = .init(&.{});
        try writePwshCompletions(&counter.writer);

        var buf: [counter.count]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        try writePwshCompletions(&writer);
        const final = buf;
        return final[0..writer.end];
    }
}

fn writePwshCompletions(writer: *std.Io.Writer) !void {
    // -- Static header: outer wrapper, Register-ArgumentCompleter, helpers --
    try writer.writeAll(
        \\ param($ghostty)
        \\ $commandName = (Split-Path -Leaf $ghostty) -replace '\.exe$'
        \\
        \\ Register-ArgumentCompleter -Native -CommandName $commandName,"$commandName.exe" -ScriptBlock {
        \\   param($wordToComplete, $commandAst, $cursorPosition)
        \\
        \\   function Get-Fonts {
        \\     & "$ghostty" +list-fonts | Where-Object { $_ -match '^[A-Z]' }
        \\   }
        \\
        \\   function Get-Themes {
        \\     & "$ghostty" +list-themes | ForEach-Object { $_ -replace ' \(.*$' }
        \\   }
        \\
        \\   $elements = $commandAst.CommandElements
        \\   $action = $null
        \\   $prev = $null
        \\ 
        \\   for ($i = 1; $i -lt $elements.Count; $i++) {
        \\     $t = $elements[$i].ToString()
        \\
        \\     if ($t.StartsWith('+') -and -not $action) { $action = $t }
        \\     if ($i -lt $elements.Count - 1 -or $wordToComplete -eq '') {
        \\       $prev = $t
        \\     }
        \\   }
        \\
        \\   filter Select-Completion {
        \\     if ($_ -like "$wordToComplete*") {
        \\       [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
        \\     }
        \\   }
        \\
        \\   filter Select-ValueCompletion($key) {
        \\     $c = "--$key=$_"
        \\     if ($c -like "$wordToComplete*") {
        \\       [System.Management.Automation.CompletionResult]::new($c, $_, 'ParameterValue', $_)
        \\     }
        \\   }
        \\
    );

    // -- Section: config --key=value completion (no action context) --
    try writer.writeAll("   if (-not $action -and $wordToComplete -like '--*=*') {\n");
    try writer.writeAll("     $key, $val = $wordToComplete -split '=', 2\n");
    try writer.writeAll("     $key = $key -replace '^--'\n");
    try writer.writeAll("     switch ($key) {\n");

    for (@typeInfo(Config).@"struct".fields) |field| {
        if (field.name[0] == '_') continue;

        if (std.mem.startsWith(u8, field.name, "font-family")) {
            try writer.writeAll("       '" ++ field.name ++ "' { Get-Fonts | Select-ValueCompletion $key; return }\n");
        } else if (std.mem.eql(u8, "theme", field.name)) {
            try writer.writeAll("       'theme' { Get-Themes | Select-ValueCompletion $key; return }\n");
        } else if (std.mem.eql(u8, "working-directory", field.name)) {
            try writer.writeAll("       'working-directory' { Get-ChildItem -Directory -Path \"$val*\" | ForEach-Object { $_.FullName } | Select-ValueCompletion $key; return }\n");
        } else if (field.type == Config.RepeatablePath) {
            try writer.writeAll("       '" ++ field.name ++ "' { Resolve-Path -Path \"$val*\" -ErrorAction SilentlyContinue | ForEach-Object { $_.Path } | Select-ValueCompletion $key; return }\n");
        } else {
            switch (@typeInfo(field.type)) {
                .bool => {},
                .@"enum" => |info| {
                    try writer.writeAll("       '" ++ field.name ++ "' { @(");
                    for (info.fields, 0..) |f, i| {
                        if (i > 0) try writer.writeAll(", ");
                        try writer.writeAll("'" ++ f.name ++ "'");
                    }
                    try writer.writeAll(") | Select-ValueCompletion $key; return }\n");
                },
                .@"struct" => |info| {
                    if (!@hasDecl(field.type, "parseCLI") and info.layout == .@"packed") {
                        try writer.writeAll("       '" ++ field.name ++ "' { @(");
                        for (info.fields, 0..) |f, i| {
                            if (i > 0) try writer.writeAll(", ");
                            try writer.writeAll("'" ++ f.name ++ "', 'no-" ++ f.name ++ "'");
                        }
                        try writer.writeAll(") | Select-ValueCompletion $key; return }\n");
                    }
                },
                else => {},
            }
        }
    }

    try writer.writeAll("     }\n");
    try writer.writeAll("     return\n");
    try writer.writeAll("   }\n");

    // -- Section: action context --
    try writer.writeAll("   if ($action) {\n");

    // D1: --opt=value completion for action options
    try writer.writeAll("     if ($wordToComplete -like '--*=*') {\n");
    try writer.writeAll("       $key, $val = $wordToComplete -split '=', 2\n");
    try writer.writeAll("       $key = $key -replace '^--'\n");
    try writer.writeAll("       switch ($action) {\n");

    for (@typeInfo(Action).@"enum".fields) |field| {
        const options = @field(Action, field.name).options();
        const opt_fields = @typeInfo(options).@"struct".fields;
        if (opt_fields.len == 0) continue;

        // Check if this action has any completable option values
        var has_completable = false;
        for (opt_fields) |opt| {
            if (opt.name[0] == '_') continue;
            switch (@typeInfo(opt.type)) {
                .@"enum" => {
                    has_completable = true;
                    break;
                },
                .optional => |optional| {
                    switch (@typeInfo(optional.child)) {
                        .@"enum" => {
                            has_completable = true;
                            break;
                        },
                        else => {},
                    }
                },
                else => {
                    if (std.mem.eql(u8, "config-file", opt.name)) {
                        has_completable = true;
                        break;
                    }
                },
            }
        }
        if (!has_completable) continue;

        try writer.writeAll("         '+" ++ field.name ++ "' {\n");
        try writer.writeAll("           switch ($key) {\n");
        for (opt_fields) |opt| {
            if (opt.name[0] == '_') continue;
            switch (@typeInfo(opt.type)) {
                .@"enum" => |info| {
                    try writer.writeAll("             '" ++ opt.name ++ "' { @(");
                    for (info.fields, 0..) |f, i| {
                        if (i > 0) try writer.writeAll(", ");
                        try writer.writeAll("'" ++ f.name ++ "'");
                    }
                    try writer.writeAll(") | Select-ValueCompletion $key; return }\n");
                },
                .optional => |optional| {
                    switch (@typeInfo(optional.child)) {
                        .@"enum" => |info| {
                            try writer.writeAll("             '" ++ opt.name ++ "' { @(");
                            for (info.fields, 0..) |f, i| {
                                if (i > 0) try writer.writeAll(", ");
                                try writer.writeAll("'" ++ f.name ++ "'");
                            }
                            try writer.writeAll(") | Select-ValueCompletion $key; return }\n");
                        },
                        else => {},
                    }
                },
                else => {
                    if (std.mem.eql(u8, "config-file", opt.name)) {
                        try writer.writeAll("             'config-file' { Resolve-Path -Path \"$val*\" -ErrorAction SilentlyContinue | ForEach-Object { $_.Path } | Select-ValueCompletion $key; return }\n");
                    }
                },
            }
        }
        try writer.writeAll("           }\n");
        try writer.writeAll("         }\n");
    }

    try writer.writeAll("       }\n");
    try writer.writeAll("       return\n");
    try writer.writeAll("     }\n");

    // D2: list action-specific option names
    try writer.writeAll("     switch ($action) {\n");
    for (@typeInfo(Action).@"enum".fields) |field| {
        const options = @field(Action, field.name).options();
        const opt_fields = @typeInfo(options).@"struct".fields;
        if (opt_fields.len == 0) continue;

        try writer.writeAll("       '+" ++ field.name ++ "' { @(");
        var count: usize = 0;
        for (opt_fields) |opt| {
            if (opt.name[0] == '_') continue;
            if (count > 0) try writer.writeAll(", ");
            switch (opt.type) {
                bool, ?bool => try writer.writeAll("'--" ++ opt.name ++ "'"),
                else => try writer.writeAll("'--" ++ opt.name ++ "='"),
            }
            count += 1;
        }
        try writer.writeAll(", '--help') | Select-Completion }\n");
    }
    try writer.writeAll("       default { @('--help') | Select-Completion }\n");
    try writer.writeAll("     }\n");
    try writer.writeAll("     return\n");
    try writer.writeAll("   }\n");

    // -- Section: top-level completions --
    try writer.writeAll("   @('-e', '--help', '--version'");

    // Actions
    for (@typeInfo(Action).@"enum".fields) |field| {
        try writer.writeAll(", '+" ++ field.name ++ "'");
    }

    // Config keys
    for (@typeInfo(Config).@"struct".fields) |field| {
        if (field.name[0] == '_') continue;
        switch (field.type) {
            bool, ?bool => try writer.writeAll(", '--" ++ field.name ++ "'"),
            else => try writer.writeAll(", '--" ++ field.name ++ "='"),
        }
    }

    try writer.writeAll(") | Select-Completion\n");

    // -- Static footer --
    try writer.writeAll(
        \\ }.GetNewClosure()
        \\
    );
}
