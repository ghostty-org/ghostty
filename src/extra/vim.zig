const std = @import("std");
const Config = @import("../config/Config.zig");

/// This is the associated Vim file as named by the variable.
pub const syntax = comptimeGenSyntax();
pub const ftdetect =
    \\" Vim filetype detect file
    \\" Language: Ghostty config file
    \\" Maintainer: Ghostty <https://github.com/ghostty-org/ghostty>
    \\"
    \\" THIS FILE IS AUTO-GENERATED
    \\
    \\au BufRead,BufNewFile */ghostty/config,*/ghostty/themes/*,*.ghostty setf ghostty
    \\
;
pub const ftplugin =
    \\" Vim filetype plugin file
    \\" Language: Ghostty config file
    \\" Maintainer: Ghostty <https://github.com/ghostty-org/ghostty>
    \\"
    \\" THIS FILE IS AUTO-GENERATED
    \\
    \\if exists('b:did_ftplugin')
    \\  finish
    \\endif
    \\let b:did_ftplugin = 1
    \\
    \\setlocal commentstring=#\ %s
    \\setlocal iskeyword+=-
    \\
    \\" Use syntax keywords for completion
    \\setlocal omnifunc=syntaxcomplete#Complete
    \\
    \\let b:undo_ftplugin = 'setl cms< isk< ofu<'
    \\
    \\if !exists('current_compiler')
    \\  compiler ghostty
    \\  let b:undo_ftplugin .= " makeprg< errorformat<"
    \\endif
    \\
;
pub const compiler =
    \\" Vim compiler file
    \\" Language: Ghostty config file
    \\" Maintainer: Ghostty <https://github.com/ghostty-org/ghostty>
    \\"
    \\" THIS FILE IS AUTO-GENERATED
    \\
    \\if exists("current_compiler")
    \\  finish
    \\endif
    \\let current_compiler = "ghostty"
    \\
    \\CompilerSet makeprg=ghostty\ +validate-config\ --config-file=%:S
    \\CompilerSet errorformat=%f:%l:%m,%m
    \\
;

/// Generates the syntax file at comptime.
fn comptimeGenSyntax() []const u8 {
    comptime {
        @setEvalBranchQuota(50000);
        var counter: std.Io.Writer.Discarding = .init(&.{});
        try writeSyntax(&counter.writer);

        var buf: [counter.count]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        try writeSyntax(&writer);
        const final = buf;
        return final[0..writer.end];
    }
}

/// Writes the syntax file to the given writer.
fn writeSyntax(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\" Vim syntax file
        \\" Language: Ghostty config file
        \\" Maintainer: Ghostty <https://github.com/ghostty-org/ghostty>
        \\"
        \\" THIS FILE IS AUTO-GENERATED
        \\
        \\if exists('b:current_syntax')
        \\  finish
        \\endif
        \\
        \\let b:current_syntax = 'ghostty'
        \\
        \\let s:cpo_save = &cpo
        \\set cpo&vim
        \\
        \\syn iskeyword @,48-57,-
        \\syn keyword ghosttyConfigKeyword
    );

    const config_fields = @typeInfo(Config).@"struct".fields;
    inline for (config_fields) |field| {
        if (field.name[0] == '_') continue;
        try writer.print("\n\t\\ {s}", .{field.name});
    }

    try writer.writeAll(
        \\
        \\
        \\syn match ghosttyConfigComment /^\s*#.*/ contains=@Spell
        \\
        \\hi def link ghosttyConfigComment Comment
        \\hi def link ghosttyConfigKeyword Keyword
        \\
        \\let &cpo = s:cpo_save
        \\unlet s:cpo_save
        \\
    );
}

test {
    _ = syntax;
}
