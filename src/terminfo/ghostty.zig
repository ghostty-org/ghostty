const std = @import("std");
const Source = @import("Source.zig");

/// Ghostty's terminfo entry.
pub const ghostty: Source = .{
    .names = &.{
        // We support the "xterm-" prefix because some poorly behaved programs
        // use this to detect if the terminal supports 256 colors and other
        // features.
        // HACK: This is a hack on a hack...we use "xterm-ghostty" to prevent
        // vim from breaking, and when we do this as the default we break
        // tcell-based applications (lazygit, aerc, etc). tcell has a bug where
        // the primary terminfo name must be the value of TERM.
        // https://github.com/gdamore/tcell/pull/639 fixes the issue but is not
        // merged yet. Consider switching these in the future.
        "xterm-ghostty",

        // The preferred name
        "ghostty",

        // Our "formal" name
        "Ghostty",
    },

    // NOTE: These capabilities are super underdocumented and I'm not 100%
    // I've got the list or my understanding of any in this list fully correct.
    // As we learn more, please update the comments to better explain what
    // anything means.
    //
    // I've marked some capabilities as "???" if I don't understand what they
    // mean but I just assume I support since other modern terminals do. In
    // this case, I'd love if anyone could help explain what this means and
    // verify that Ghostty does indeed support it and if not we can fix it.
    .capabilities = &.{
        // automatic right margin -- when reaching the end of a line, text is
        // wrapped to the next line.
        .{ .name = "am", .value = .{ .boolean = {} } },

        // background color erase -- screen is erased with the background color
        .{ .name = "bce", .value = .{ .boolean = {} } },

        // terminal can change color definitions, i.e. we can change the color
        // palette.
        .{ .name = "ccc", .value = .{ .boolean = {} } },

        // supports changing the window title.
        .{ .name = "hs", .value = .{ .boolean = {} } },

        // terminal has a meta key
        .{ .name = "km", .value = .{ .boolean = {} } },

        // terminal will not echo input on the screen on its own
        .{ .name = "mc5i", .value = .{ .boolean = {} } },

        // safe to move (move what?) while in insert/standout mode. (???)
        .{ .name = "mir", .value = .{ .boolean = {} } },
        .{ .name = "msgr", .value = .{ .boolean = {} } },

        // no pad character (???)
        .{ .name = "npc", .value = .{ .boolean = {} } },

        // newline ignored after 80 cols (???)
        .{ .name = "xenl", .value = .{ .boolean = {} } },

        // Terminal supports default colors
        .{ .name = "AX", .value = .{ .boolean = {} } },

        // Tmux "truecolor" mode. Other programs also use this to detect
        // if the terminal supports "truecolor". This means that the terminal
        // can display 24-bit RGB colors.
        .{ .name = "Tc", .value = .{ .boolean = {} } },

        // Colored underlines. https://sw.kovidgoyal.net/kitty/underlines/
        .{ .name = "Su", .value = .{ .boolean = {} } },

        // Terminal supports a number of xterm extensions
        .{ .name = "XT", .value = .{ .boolean = {} } },

        // Full keyboard support using Kitty's keyboard protocol:
        // https://sw.kovidgoyal.net/kitty/keyboard-protocol/
        .{ .name = "fullkbd", .value = .{ .boolean = {} } },

        // Number of colors in the color palette.
        .{ .name = "colors", .value = .{ .numeric = 256 } },

        // Number of columns in a line. Our terminal is variable width on
        // Window resize but this appears to just be the value set by most
        // terminals.
        .{ .name = "cols", .value = .{ .numeric = 80 } },

        // Initial tabstop interval.
        .{ .name = "it", .value = .{ .numeric = 8 } },

        // Number of lines on a page. Similar to cols this is variable width
        // but this appears to be the value set by most terminals.
        .{ .name = "lines", .value = .{ .numeric = 24 } },

        // Number of color pairs on the screen.
        .{ .name = "pairs", .value = .{ .numeric = 32767 } },

        // Alternate character set. This is the VT100 alternate character set.
        // I don't know what the value means, I copied this from Kitty and
        // verified with some other terminals (looks similar).
        .{ .name = "acsc", .value = .{ .string = "++\\,\\,--..00``aaffgghhiijjkkllmmnnooppqqrrssttuuvvwwxxyyzz{{||}}~~" } },

        // Curly, dashed, etc underlines
        .{ .name = "Smulx", .value = .{ .string = "\\E[4:%p1%dm" } },

        // Colored underlines
        .{ .name = "Setulc", .value = .{ .string = "\\E[58:2::%p1%{65536}%/%d:%p1%{256}%/%{255}%&%d:%p1%{255}%&%d%;m" } },

        // Cursor styles
        .{ .name = "Ss", .value = .{ .string = "\\E[%p1%d q" } },

        // Cursor style reset
        .{ .name = "Se", .value = .{ .string = "\\E[2 q" } },

        // OSC 52 Clipboard
        .{ .name = "Ms", .value = .{ .string = "\\E]52;%p1%s;%p2%s\\007" } },

        // Synchronized output
        .{ .name = "Sync", .value = .{ .string = "\\E[?2026%?%p1%{1}%-%tl%eh%;" } },

        // Bracketed paste mode
        .{ .name = "BD", .value = .{ .string = "\\E[?2004l" } },
        .{ .name = "BE", .value = .{ .string = "\\E[?2004h" } },
        // Bracketed paste start/end
        .{ .name = "PS", .value = .{ .string = "\\E[200~" } },
        .{ .name = "PE", .value = .{ .string = "\\E[201~" } },

        // Mouse
        .{ .name = "XM", .value = .{ .string = "\\E[?1006;1000%?%p1%{1}%=%th%el%;" } },
        .{ .name = "xm", .value = .{ .string = "\\E[<%i%p3%d;%p1%d;%p2%d;%?%p4%tM%em%;" } },

        // Secondary device attributes request / response
        .{ .name = "RV", .value = .{ .string = "\\E[>c" } },
        .{ .name = "rv", .value = .{ .string = "\\E\\\\[[0-9]+;[0-9]+;[0-9]+c" } },

        // XTVERSION
        .{ .name = "XR", .value = .{ .string = "\\E[>0q" } },
        .{ .name = "xr", .value = .{ .string = "\\EP>\\\\|[ -~]+a\\E\\\\" } },

        // DECSLRM (Left/Right Margins)
        .{ .name = "Enmg", .value = .{ .string = "\\E[?69h" } },
        .{ .name = "Dsmg", .value = .{ .string = "\\E[?69l" } },
        .{ .name = "Clmg", .value = .{ .string = "\\E[s" } },
        .{ .name = "Cmg", .value = .{ .string = "\\E[%i%p1%d;%p2%ds" } },

        // Clear screen. E3 is the extension to clear scrollback
        .{ .name = "clear", .value = .{ .string = "\\E[H\\E[2J" } },
        .{ .name = "E3", .value = .{ .string = "\\E[3J" } },

        // Focus reporting. Introduced in ncurses 6.4-20231028
        .{ .name = "fe", .value = .{ .string = "\\E[?1004h" } },
        .{ .name = "fd", .value = .{ .string = "\\E[?1004l" } },
        .{ .name = "kxIN", .value = .{ .string = "\\E[I" } },
        .{ .name = "kxOUT", .value = .{ .string = "\\E[O" } },

        // These are all capabilities that should be pretty straightforward
        // and map to input sequences.
        .{ .name = "bel", .value = .{ .string = "^G" } },
        .{ .name = "blink", .value = .{ .string = "\\E[5m" } },
        .{ .name = "bold", .value = .{ .string = "\\E[1m" } },
        .{ .name = "cbt", .value = .{ .string = "\\E[Z" } },
        .{ .name = "civis", .value = .{ .string = "\\E[?25l" } },
        .{ .name = "cnorm", .value = .{ .string = "\\E[?12l\\E[?25h" } },
        .{ .name = "cr", .value = .{ .string = "\\r" } },
        .{ .name = "csr", .value = .{ .string = "\\E[%i%p1%d;%p2%dr" } },
        .{ .name = "cub", .value = .{ .string = "\\E[%p1%dD" } },
        .{ .name = "cub1", .value = .{ .string = "^H" } },
        .{ .name = "cud", .value = .{ .string = "\\E[%p1%dB" } },
        .{ .name = "cud1", .value = .{ .string = "^J" } },
        .{ .name = "cuf", .value = .{ .string = "\\E[%p1%dC" } },
        .{ .name = "cuf1", .value = .{ .string = "\\E[C" } },
        .{ .name = "cup", .value = .{ .string = "\\E[%i%p1%d;%p2%dH" } },
        .{ .name = "cuu", .value = .{ .string = "\\E[%p1%dA" } },
        .{ .name = "cuu1", .value = .{ .string = "\\E[A" } },
        .{ .name = "cvvis", .value = .{ .string = "\\E[?12;25h" } },
        .{ .name = "dch", .value = .{ .string = "\\E[%p1%dP" } },
        .{ .name = "dch1", .value = .{ .string = "\\E[P" } },
        .{ .name = "dim", .value = .{ .string = "\\E[2m" } },
        .{ .name = "dl", .value = .{ .string = "\\E[%p1%dM" } },
        .{ .name = "dl1", .value = .{ .string = "\\E[M" } },
        .{ .name = "dsl", .value = .{ .string = "\\E]2;\\007" } },
        .{ .name = "ech", .value = .{ .string = "\\E[%p1%dX" } },
        .{ .name = "ed", .value = .{ .string = "\\E[J" } },
        .{ .name = "el", .value = .{ .string = "\\E[K" } },
        .{ .name = "el1", .value = .{ .string = "\\E[1K" } },
        .{ .name = "flash", .value = .{ .string = "\\E[?5h$<100/>\\E[?5l" } },
        .{ .name = "fsl", .value = .{ .string = "^G" } },
        .{ .name = "home", .value = .{ .string = "\\E[H" } },
        .{ .name = "hpa", .value = .{ .string = "\\E[%i%p1%dG" } },
        .{ .name = "ht", .value = .{ .string = "^I" } },
        .{ .name = "hts", .value = .{ .string = "\\EH" } },
        .{ .name = "ich", .value = .{ .string = "\\E[%p1%d@" } },
        .{ .name = "ich1", .value = .{ .string = "\\E[@" } },
        .{ .name = "il", .value = .{ .string = "\\E[%p1%dL" } },
        .{ .name = "il1", .value = .{ .string = "\\E[L" } },
        .{ .name = "ind", .value = .{ .string = "\\n" } },
        .{ .name = "indn", .value = .{ .string = "\\E[%p1%dS" } },
        .{ .name = "initc", .value = .{ .string = "\\E]4;%p1%d;rgb\\:%p2%{255}%*%{1000}%/%2.2X/%p3%{255}%*%{1000}%/%2.2X/%p4%{255}%*%{1000}%/%2.2X\\E\\\\" } },
        .{ .name = "invis", .value = .{ .string = "\\E[8m" } },
        .{ .name = "oc", .value = .{ .string = "\\E]104\\007" } },
        .{ .name = "op", .value = .{ .string = "\\E[39;49m" } },
        .{ .name = "rc", .value = .{ .string = "\\E8" } },
        .{ .name = "rep", .value = .{ .string = "%p1%c\\E[%p2%{1}%-%db" } },
        .{ .name = "rev", .value = .{ .string = "\\E[7m" } },
        .{ .name = "ri", .value = .{ .string = "\\EM" } },
        .{ .name = "rin", .value = .{ .string = "\\E[%p1%dT" } },
        .{ .name = "ritm", .value = .{ .string = "\\E[23m" } },
        .{ .name = "rmacs", .value = .{ .string = "\\E(B" } },
        .{ .name = "rmam", .value = .{ .string = "\\E[?7l" } },
        .{ .name = "rmcup", .value = .{ .string = "\\E[?1049l" } },
        .{ .name = "rmir", .value = .{ .string = "\\E[4l" } },
        .{ .name = "rmkx", .value = .{ .string = "\\E[?1l\\E>" } },
        .{ .name = "rmso", .value = .{ .string = "\\E[27m" } },
        .{ .name = "rmul", .value = .{ .string = "\\E[24m" } },
        .{ .name = "rmxx", .value = .{ .string = "\\E[29m" } },
        .{ .name = "setab", .value = .{ .string = "\\E[%?%p1%{8}%<%t4%p1%d%e%p1%{16}%<%t10%p1%{8}%-%d%e48;5;%p1%d%;m" } },
        .{ .name = "setaf", .value = .{ .string = "\\E[%?%p1%{8}%<%t3%p1%d%e%p1%{16}%<%t9%p1%{8}%-%d%e38;5;%p1%d%;m" } },
        .{ .name = "setrgbb", .value = .{ .string = "\\E[48:2:%p1%d:%p2%d:%p3%dm" } },
        .{ .name = "setrgbf", .value = .{ .string = "\\E[38:2:%p1%d:%p2%d:%p3%dm" } },
        .{ .name = "sgr", .value = .{ .string = "%?%p9%t\\E(0%e\\E(B%;\\E[0%?%p6%t;1%;%?%p2%t;4%;%?%p1%p3%|%t;7%;%?%p4%t;5%;%?%p7%t;8%;m" } },
        .{ .name = "sgr0", .value = .{ .string = "\\E(B\\E[m" } },
        .{ .name = "sitm", .value = .{ .string = "\\E[3m" } },
        .{ .name = "smacs", .value = .{ .string = "\\E(0" } },
        .{ .name = "smam", .value = .{ .string = "\\E[?7h" } },
        .{ .name = "smcup", .value = .{ .string = "\\E[?1049h" } },
        .{ .name = "smir", .value = .{ .string = "\\E[4h" } },
        .{ .name = "smkx", .value = .{ .string = "\\E[?1h\\E=" } },
        .{ .name = "smso", .value = .{ .string = "\\E[7m" } },
        .{ .name = "smul", .value = .{ .string = "\\E[4m" } },
        .{ .name = "smxx", .value = .{ .string = "\\E[9m" } },
        .{ .name = "tbc", .value = .{ .string = "\\E[3g" } },
        .{ .name = "tsl", .value = .{ .string = "\\E]2;" } },
        .{ .name = "u6", .value = .{ .string = "\\E[%i%d;%dR" } },
        .{ .name = "u7", .value = .{ .string = "\\E[6n" } },
        .{ .name = "u8", .value = .{ .string = "\\E[?%[;0123456789]c" } },
        .{ .name = "u9", .value = .{ .string = "\\E[c" } },
        .{ .name = "vpa", .value = .{ .string = "\\E[%i%p1%dd" } },

        //-----------------------------------------------------------
        // Completely unvalidated entries that are blindly copied from
        // other terminals (Kitty, Wezterm, Alacritty) and may or may not
        // actually work with Ghostty. todo is to validate these!

        .{ .name = "kDC", .value = .{ .string = "\\E[3;2~" } },
        .{ .name = "kDC3", .value = .{ .string = "\\E[3;3~" } },
        .{ .name = "kDC4", .value = .{ .string = "\\E[3;4~" } },
        .{ .name = "kDC5", .value = .{ .string = "\\E[3;5~" } },
        .{ .name = "kDC6", .value = .{ .string = "\\E[3;6~" } },
        .{ .name = "kDC7", .value = .{ .string = "\\E[3;7~" } },
        .{ .name = "kDN", .value = .{ .string = "\\E[1;2B" } },
        .{ .name = "kDN3", .value = .{ .string = "\\E[1;3B" } },
        .{ .name = "kDN4", .value = .{ .string = "\\E[1;4B" } },
        .{ .name = "kDN5", .value = .{ .string = "\\E[1;5B" } },
        .{ .name = "kDN6", .value = .{ .string = "\\E[1;6B" } },
        .{ .name = "kDN7", .value = .{ .string = "\\E[1;7B" } },
        .{ .name = "kEND", .value = .{ .string = "\\E[1;2F" } },
        .{ .name = "kEND3", .value = .{ .string = "\\E[1;3F" } },
        .{ .name = "kEND4", .value = .{ .string = "\\E[1;4F" } },
        .{ .name = "kEND5", .value = .{ .string = "\\E[1;5F" } },
        .{ .name = "kEND6", .value = .{ .string = "\\E[1;6F" } },
        .{ .name = "kEND7", .value = .{ .string = "\\E[1;7F" } },
        .{ .name = "kHOM", .value = .{ .string = "\\E[1;2H" } },
        .{ .name = "kHOM3", .value = .{ .string = "\\E[1;3H" } },
        .{ .name = "kHOM4", .value = .{ .string = "\\E[1;4H" } },
        .{ .name = "kHOM5", .value = .{ .string = "\\E[1;5H" } },
        .{ .name = "kHOM6", .value = .{ .string = "\\E[1;6H" } },
        .{ .name = "kHOM7", .value = .{ .string = "\\E[1;7H" } },
        .{ .name = "kIC", .value = .{ .string = "\\E[2;2~" } },
        .{ .name = "kIC3", .value = .{ .string = "\\E[2;3~" } },
        .{ .name = "kIC4", .value = .{ .string = "\\E[2;4~" } },
        .{ .name = "kIC5", .value = .{ .string = "\\E[2;5~" } },
        .{ .name = "kIC6", .value = .{ .string = "\\E[2;6~" } },
        .{ .name = "kIC7", .value = .{ .string = "\\E[2;7~" } },
        .{ .name = "kLFT", .value = .{ .string = "\\E[1;2D" } },
        .{ .name = "kLFT3", .value = .{ .string = "\\E[1;3D" } },
        .{ .name = "kLFT4", .value = .{ .string = "\\E[1;4D" } },
        .{ .name = "kLFT5", .value = .{ .string = "\\E[1;5D" } },
        .{ .name = "kLFT6", .value = .{ .string = "\\E[1;6D" } },
        .{ .name = "kLFT7", .value = .{ .string = "\\E[1;7D" } },
        .{ .name = "kNXT", .value = .{ .string = "\\E[6;2~" } },
        .{ .name = "kNXT3", .value = .{ .string = "\\E[6;3~" } },
        .{ .name = "kNXT4", .value = .{ .string = "\\E[6;4~" } },
        .{ .name = "kNXT5", .value = .{ .string = "\\E[6;5~" } },
        .{ .name = "kNXT6", .value = .{ .string = "\\E[6;6~" } },
        .{ .name = "kNXT7", .value = .{ .string = "\\E[6;7~" } },
        .{ .name = "kPRV", .value = .{ .string = "\\E[5;2~" } },
        .{ .name = "kPRV3", .value = .{ .string = "\\E[5;3~" } },
        .{ .name = "kPRV4", .value = .{ .string = "\\E[5;4~" } },
        .{ .name = "kPRV5", .value = .{ .string = "\\E[5;5~" } },
        .{ .name = "kPRV6", .value = .{ .string = "\\E[5;6~" } },
        .{ .name = "kPRV7", .value = .{ .string = "\\E[5;7~" } },
        .{ .name = "kRIT", .value = .{ .string = "\\E[1;2C" } },
        .{ .name = "kRIT3", .value = .{ .string = "\\E[1;3C" } },
        .{ .name = "kRIT4", .value = .{ .string = "\\E[1;4C" } },
        .{ .name = "kRIT5", .value = .{ .string = "\\E[1;5C" } },
        .{ .name = "kRIT6", .value = .{ .string = "\\E[1;6C" } },
        .{ .name = "kRIT7", .value = .{ .string = "\\E[1;7C" } },
        .{ .name = "kUP", .value = .{ .string = "\\E[1;2A" } },
        .{ .name = "kUP3", .value = .{ .string = "\\E[1;3A" } },
        .{ .name = "kUP4", .value = .{ .string = "\\E[1;4A" } },
        .{ .name = "kUP5", .value = .{ .string = "\\E[1;5A" } },
        .{ .name = "kUP6", .value = .{ .string = "\\E[1;6A" } },
        .{ .name = "kUP7", .value = .{ .string = "\\E[1;7A" } },
        .{ .name = "kbs", .value = .{ .string = "^?" } },
        .{ .name = "kcbt", .value = .{ .string = "\\E[Z" } },
        .{ .name = "kcub1", .value = .{ .string = "\\EOD" } },
        .{ .name = "kcud1", .value = .{ .string = "\\EOB" } },
        .{ .name = "kcuf1", .value = .{ .string = "\\EOC" } },
        .{ .name = "kcuu1", .value = .{ .string = "\\EOA" } },
        .{ .name = "kdch1", .value = .{ .string = "\\E[3~" } },
        .{ .name = "kend", .value = .{ .string = "\\EOF" } },
        .{ .name = "kent", .value = .{ .string = "\\EOM" } },
        .{ .name = "kf1", .value = .{ .string = "\\EOP" } },
        .{ .name = "kf10", .value = .{ .string = "\\E[21~" } },
        .{ .name = "kf11", .value = .{ .string = "\\E[23~" } },
        .{ .name = "kf12", .value = .{ .string = "\\E[24~" } },
        .{ .name = "kf13", .value = .{ .string = "\\E[1;2P" } },
        .{ .name = "kf14", .value = .{ .string = "\\E[1;2Q" } },
        .{ .name = "kf15", .value = .{ .string = "\\E[1;2R" } },
        .{ .name = "kf16", .value = .{ .string = "\\E[1;2S" } },
        .{ .name = "kf17", .value = .{ .string = "\\E[15;2~" } },
        .{ .name = "kf18", .value = .{ .string = "\\E[17;2~" } },
        .{ .name = "kf19", .value = .{ .string = "\\E[18;2~" } },
        .{ .name = "kf2", .value = .{ .string = "\\EOQ" } },
        .{ .name = "kf20", .value = .{ .string = "\\E[19;2~" } },
        .{ .name = "kf21", .value = .{ .string = "\\E[20;2~" } },
        .{ .name = "kf22", .value = .{ .string = "\\E[21;2~" } },
        .{ .name = "kf23", .value = .{ .string = "\\E[23;2~" } },
        .{ .name = "kf24", .value = .{ .string = "\\E[24;2~" } },
        .{ .name = "kf25", .value = .{ .string = "\\E[1;5P" } },
        .{ .name = "kf26", .value = .{ .string = "\\E[1;5Q" } },
        .{ .name = "kf27", .value = .{ .string = "\\E[1;5R" } },
        .{ .name = "kf28", .value = .{ .string = "\\E[1;5S" } },
        .{ .name = "kf29", .value = .{ .string = "\\E[15;5~" } },
        .{ .name = "kf3", .value = .{ .string = "\\EOR" } },
        .{ .name = "kf30", .value = .{ .string = "\\E[17;5~" } },
        .{ .name = "kf31", .value = .{ .string = "\\E[18;5~" } },
        .{ .name = "kf32", .value = .{ .string = "\\E[19;5~" } },
        .{ .name = "kf33", .value = .{ .string = "\\E[20;5~" } },
        .{ .name = "kf34", .value = .{ .string = "\\E[21;5~" } },
        .{ .name = "kf35", .value = .{ .string = "\\E[23;5~" } },
        .{ .name = "kf36", .value = .{ .string = "\\E[24;5~" } },
        .{ .name = "kf37", .value = .{ .string = "\\E[1;6P" } },
        .{ .name = "kf38", .value = .{ .string = "\\E[1;6Q" } },
        .{ .name = "kf39", .value = .{ .string = "\\E[1;6R" } },
        .{ .name = "kf4", .value = .{ .string = "\\EOS" } },
        .{ .name = "kf40", .value = .{ .string = "\\E[1;6S" } },
        .{ .name = "kf41", .value = .{ .string = "\\E[15;6~" } },
        .{ .name = "kf42", .value = .{ .string = "\\E[17;6~" } },
        .{ .name = "kf43", .value = .{ .string = "\\E[18;6~" } },
        .{ .name = "kf44", .value = .{ .string = "\\E[19;6~" } },
        .{ .name = "kf45", .value = .{ .string = "\\E[20;6~" } },
        .{ .name = "kf46", .value = .{ .string = "\\E[21;6~" } },
        .{ .name = "kf47", .value = .{ .string = "\\E[23;6~" } },
        .{ .name = "kf48", .value = .{ .string = "\\E[24;6~" } },
        .{ .name = "kf49", .value = .{ .string = "\\E[1;3P" } },
        .{ .name = "kf5", .value = .{ .string = "\\E[15~" } },
        .{ .name = "kf50", .value = .{ .string = "\\E[1;3Q" } },
        .{ .name = "kf51", .value = .{ .string = "\\E[1;3R" } },
        .{ .name = "kf52", .value = .{ .string = "\\E[1;3S" } },
        .{ .name = "kf53", .value = .{ .string = "\\E[15;3~" } },
        .{ .name = "kf54", .value = .{ .string = "\\E[17;3~" } },
        .{ .name = "kf55", .value = .{ .string = "\\E[18;3~" } },
        .{ .name = "kf56", .value = .{ .string = "\\E[19;3~" } },
        .{ .name = "kf57", .value = .{ .string = "\\E[20;3~" } },
        .{ .name = "kf58", .value = .{ .string = "\\E[21;3~" } },
        .{ .name = "kf59", .value = .{ .string = "\\E[23;3~" } },
        .{ .name = "kf6", .value = .{ .string = "\\E[17~" } },
        .{ .name = "kf60", .value = .{ .string = "\\E[24;3~" } },
        .{ .name = "kf61", .value = .{ .string = "\\E[1;4P" } },
        .{ .name = "kf62", .value = .{ .string = "\\E[1;4Q" } },
        .{ .name = "kf63", .value = .{ .string = "\\E[1;4R" } },
        .{ .name = "kf7", .value = .{ .string = "\\E[18~" } },
        .{ .name = "kf8", .value = .{ .string = "\\E[19~" } },
        .{ .name = "kf9", .value = .{ .string = "\\E[20~" } },
        .{ .name = "khome", .value = .{ .string = "\\EOH" } },
        .{ .name = "kich1", .value = .{ .string = "\\E[2~" } },
        .{ .name = "kind", .value = .{ .string = "\\E[1;2B" } },
        .{ .name = "kmous", .value = .{ .string = "\\E[<" } },
        .{ .name = "knp", .value = .{ .string = "\\E[6~" } },
        .{ .name = "kpp", .value = .{ .string = "\\E[5~" } },
        .{ .name = "kri", .value = .{ .string = "\\E[1;2A" } },
        .{ .name = "rs1", .value = .{ .string = "\\E]\\E\\\\\\Ec" } },
        .{ .name = "sc", .value = .{ .string = "\\E7" } },
    },
};

test "encode" {
    // Encode
    var buf: [1024 * 16]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try ghostty.encode(&writer);
    try std.testing.expect(writer.buffered().len > 0);
}
