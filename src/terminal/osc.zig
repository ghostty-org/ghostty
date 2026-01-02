//! OSC (Operating System Command) related functions and types.
//!
//! OSC is another set of control sequences for terminal programs that start with
//! "ESC ]". Unlike CSI or standard ESC sequences, they may contain strings
//! and other irregular formatting so a dedicated parser is created to handle it.
const osc = @This();

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("terminal_options");
const mem = std.mem;
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = mem.Allocator;
const LibEnum = @import("../lib/enum.zig").Enum;
const RGB = @import("color.zig").RGB;
const kitty_color = @import("kitty/color.zig");
const osc_color = @import("osc/color.zig");
const string_encoding = @import("../os/string_encoding.zig");
pub const color = osc_color;

const log = std.log.scoped(.osc);

pub const Command = union(Key) {
    /// This generally shouldn't ever be set except as an initial zero value.
    /// Ignore it.
    invalid,

    /// Set the window title of the terminal
    ///
    /// If title mode 0 is set text is expect to be hex encoded (i.e. utf-8
    /// with each code unit further encoded with two hex digits).
    ///
    /// If title mode 2 is set or the terminal is setup for unconditional
    /// utf-8 titles text is interpreted as utf-8. Else text is interpreted
    /// as latin1.
    change_window_title: [:0]const u8,

    /// Set the icon of the terminal window. The name of the icon is not
    /// well defined, so this is currently ignored by Ghostty at the time
    /// of writing this. We just parse it so that we don't get parse errors
    /// in the log.
    change_window_icon: [:0]const u8,

    /// First do a fresh-line. Then start a new command, and enter prompt mode:
    /// Subsequent text (until a OSC "133;B" or OSC "133;I" command) is a
    /// prompt string (as if followed by OSC 133;P;k=i\007). Note: I've noticed
    /// not all shells will send the prompt end code.
    prompt_start: struct {
        /// "aid" is an optional "application identifier" that helps disambiguate
        /// nested shell sessions. It can be anything but is usually a process ID.
        aid: ?[:0]const u8 = null,
        /// "kind" tells us which kind of semantic prompt sequence this is:
        /// - primary: normal, left-aligned first-line prompt (initial, default)
        /// - continuation: an editable continuation line
        /// - secondary: a non-editable continuation line
        /// - right: a right-aligned prompt that may need adjustment during reflow
        kind: enum { primary, continuation, secondary, right } = .primary,
        /// If true, the shell will not redraw the prompt on resize so don't erase it.
        /// See: https://sw.kovidgoyal.net/kitty/shell-integration/#notes-for-shell-developers
        redraw: bool = true,
        /// Use a special key instead of arrow keys to move the cursor on
        /// mouse click. Useful if arrow keys have side-effets like triggering
        /// auto-complete. The shell integration script should bind the special
        /// key as needed.
        /// See: https://sw.kovidgoyal.net/kitty/shell-integration/#notes-for-shell-developers
        special_key: bool = false,
        /// If true, the shell is capable of handling mouse click events.
        /// Ghostty will then send a click event to the shell when the user
        /// clicks somewhere in the prompt. The shell can then move the cursor
        /// to that position or perform some other appropriate action. If false,
        /// Ghostty may generate a number of fake key events to move the cursor
        /// which is not very robust.
        /// See: https://sw.kovidgoyal.net/kitty/shell-integration/#notes-for-shell-developers
        click_events: bool = false,
    },

    /// End of prompt and start of user input, terminated by a OSC "133;C"
    /// or another prompt (OSC "133;P").
    prompt_end: void,

    /// The OSC "133;C" command can be used to explicitly end
    /// the input area and begin the output area.  However, some applications
    /// don't provide a convenient way to emit that command.
    /// That is why we also specify an implicit way to end the input area
    /// at the end of the line. In the case of  multiple input lines: If the
    /// cursor is on a fresh (empty) line and we see either OSC "133;P" or
    /// OSC "133;I" then this is the start of a continuation input line.
    /// If we see anything else, it is the start of the output area (or end
    /// of command).
    end_of_input: struct {
        /// The command line that the user entered.
        /// See: https://sw.kovidgoyal.net/kitty/shell-integration/#notes-for-shell-developers
        cmdline: ?[:0]const u8 = null,
    },

    /// End of current command.
    ///
    /// The exit-code need not be specified if there are no options,
    /// or if the command was cancelled (no OSC "133;C"), such as by typing
    /// an interrupt/cancel character (typically ctrl-C) during line-editing.
    /// Otherwise, it must be an integer code, where 0 means the command
    /// succeeded, and other values indicate failure. In additing to the
    /// exit-code there may be an err= option, which non-legacy terminals
    /// should give precedence to. The err=_value_ option is more general:
    /// an empty string is success, and any non-empty value (which need not
    /// be an integer) is an error code. So to indicate success both ways you
    /// could send OSC "133;D;0;err=\007", though `OSC "133;D;0\007" is shorter.
    end_of_command: struct {
        exit_code: ?u8 = null,
        // TODO: err option
    },

    /// Set or get clipboard contents. If data is null, then the current
    /// clipboard contents are sent to the pty. If data is set, this
    /// contents is set on the clipboard.
    clipboard_contents: struct {
        kind: u8,
        data: [:0]const u8,
    },

    /// OSC 7. Reports the current working directory of the shell. This is
    /// a moderately flawed escape sequence but one that many major terminals
    /// support so we also support it. To understand the flaws, read through
    /// this terminal-wg issue: https://gitlab.freedesktop.org/terminal-wg/specifications/-/issues/20
    report_pwd: struct {
        /// The reported pwd value. This is not checked for validity. It should
        /// be a file URL but it is up to the caller to utilize this value.
        value: [:0]const u8,
    },

    /// OSC 22. Set the mouse shape. There doesn't seem to be a standard
    /// naming scheme for cursors but it looks like terminals such as Foot
    /// are moving towards using the W3C CSS cursor names. For OSC parsing,
    /// we just parse whatever string is given.
    mouse_shape: struct {
        value: [:0]const u8,
    },

    /// OSC color operations to set, reset, or report color settings. Some OSCs
    /// allow multiple operations to be specified in a single OSC so we need a
    /// list-like datastructure to manage them. We use std.SegmentedList because
    /// it minimizes the number of allocations and copies because a large
    /// majority of the time there will be only one operation per OSC.
    ///
    /// Currently, these OSCs are handled by `color_operation`:
    ///
    /// 4, 5, 10-19, 104, 105, 110-119
    color_operation: struct {
        op: osc_color.Operation,
        requests: osc_color.List = .{},
        terminator: Terminator = .st,
    },

    /// Kitty color protocol, OSC 21
    /// https://sw.kovidgoyal.net/kitty/color-stack/#id1
    kitty_color_protocol: kitty_color.OSC,

    /// Show a desktop notification (OSC 9 or OSC 777)
    show_desktop_notification: struct {
        title: [:0]const u8,
        body: [:0]const u8,
    },

    /// Start a hyperlink (OSC 8)
    hyperlink_start: struct {
        id: ?[:0]const u8 = null,
        uri: [:0]const u8,
    },

    /// End a hyperlink (OSC 8)
    hyperlink_end: void,

    /// ConEmu sleep (OSC 9;1)
    conemu_sleep: struct {
        duration_ms: u16,
    },

    /// ConEmu show GUI message box (OSC 9;2)
    conemu_show_message_box: [:0]const u8,

    /// ConEmu change tab title (OSC 9;3)
    conemu_change_tab_title: union(enum) {
        reset,
        value: [:0]const u8,
    },

    /// ConEmu progress report (OSC 9;4)
    conemu_progress_report: ProgressReport,

    /// ConEmu wait input (OSC 9;5)
    conemu_wait_input,

    /// ConEmu GUI macro (OSC 9;6)
    conemu_guimacro: [:0]const u8,

    pub const Key = LibEnum(
        if (build_options.c_abi) .c else .zig,
        // NOTE: Order matters, see LibEnum documentation.
        &.{
            "invalid",
            "change_window_title",
            "change_window_icon",
            "prompt_start",
            "prompt_end",
            "end_of_input",
            "end_of_command",
            "clipboard_contents",
            "report_pwd",
            "mouse_shape",
            "color_operation",
            "kitty_color_protocol",
            "show_desktop_notification",
            "hyperlink_start",
            "hyperlink_end",
            "conemu_sleep",
            "conemu_show_message_box",
            "conemu_change_tab_title",
            "conemu_progress_report",
            "conemu_wait_input",
            "conemu_guimacro",
        },
    );

    pub const ProgressReport = struct {
        pub const State = enum(c_int) {
            remove,
            set,
            @"error",
            indeterminate,
            pause,
        };

        state: State,
        progress: ?u8 = null,

        // sync with ghostty_action_progress_report_s
        pub const C = extern struct {
            state: c_int,
            progress: i8,
        };

        pub fn cval(self: ProgressReport) C {
            return .{
                .state = @intFromEnum(self.state),
                .progress = if (self.progress) |progress| @intCast(std.math.clamp(
                    progress,
                    0,
                    100,
                )) else -1,
            };
        }
    };

    comptime {
        assert(@sizeOf(Command) == switch (@sizeOf(usize)) {
            4 => 44,
            8 => 64,
            else => unreachable,
        });
        // @compileLog(@sizeOf(Command));
    }
};

/// The terminator used to end an OSC command. For OSC commands that demand
/// a response, we try to match the terminator used in the request since that
/// is most likely to be accepted by the calling program.
pub const Terminator = enum {
    /// The preferred string terminator is ESC followed by \
    st,

    /// Some applications and terminals use BELL (0x07) as the string terminator.
    bel,

    pub const C = LibEnum(.c, &.{ "st", "bel" });

    /// Initialize the terminator based on the last byte seen. If the
    /// last byte is a BEL then we use BEL, otherwise we just assume ST.
    pub fn init(ch: ?u8) Terminator {
        return switch (ch orelse return .st) {
            0x07 => .bel,
            else => .st,
        };
    }

    /// The terminator as a string. This is static memory so it doesn't
    /// need to be freed.
    pub fn string(self: Terminator) []const u8 {
        return switch (self) {
            .st => "\x1b\\",
            .bel => "\x07",
        };
    }

    pub fn cval(self: Terminator) C {
        return switch (self) {
            .st => .st,
            .bel => .bel,
        };
    }

    pub fn format(
        self: Terminator,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: *std.Io.Writer,
    ) !void {
        try writer.writeAll(self.string());
    }
};

pub const Parser = struct {
    /// Maximum size of a "normal" OSC.
    const MAX_BUF = 2048;

    /// Optional allocator used to accept data longer than MAX_BUF.
    /// This only applies to some commands (e.g. OSC 52) that can
    /// reasonably exceed MAX_BUF.
    alloc: ?Allocator = null,

    /// Current state of the parser.
    state: State = .start,

    /// Buffer for temporary storage of OSC data
    buffer: [MAX_BUF]u8 = undefined,
    /// Fixed writer for accumulating OSC data
    fixed: ?std.Io.Writer = null,
    /// Allocating writer for accumulating OSC data
    allocating: ?std.Io.Writer.Allocating = null,
    /// Pointer to the active writer for accumulating OSC data
    writer: ?*std.Io.Writer = null,

    /// The command that is the result of parsing.
    command: Command = .invalid,

    pub const State = enum {
        start,
        invalid,

        // OSC command prefixes. Not all of these are valid OSCs, but may be
        // needed to "bridge" to a valid OSC (e.g. to support OSC 777 we need to
        // have a state "77" even though there is no OSC 77).
        @"0",
        @"1",
        @"2",
        @"4",
        @"5",
        @"7",
        @"8",
        @"9",
        @"10",
        @"11",
        @"12",
        @"13",
        @"14",
        @"15",
        @"16",
        @"17",
        @"18",
        @"19",
        @"21",
        @"22",
        @"52",
        @"77",
        @"104",
        @"110",
        @"111",
        @"112",
        @"113",
        @"114",
        @"115",
        @"116",
        @"117",
        @"118",
        @"119",
        @"133",
        @"777",
    };

    pub fn init(alloc: ?Allocator) Parser {
        var result: Parser = .{
            .alloc = alloc,
            .state = .start,
            .fixed = null,
            .allocating = null,
            .writer = null,
            .command = .invalid,

            // Keeping all our undefined values together so we can
            // visually easily duplicate them in the Valgrind check below.
            .buffer = undefined,
        };
        if (std.valgrind.runningOnValgrind() > 0) {
            // Initialize our undefined fields so Valgrind can catch it.
            // https://github.com/ziglang/zig/issues/19148
            result.buffer = undefined;
        }

        return result;
    }

    /// This must be called to clean up any allocated memory.
    pub fn deinit(self: *Parser) void {
        self.reset();
    }

    /// Reset the parser state.
    pub fn reset(self: *Parser) void {
        // If we set up an allocating writer, free up that memory.
        if (self.allocating) |*allocating| allocating.deinit();

        // Handle any cleanup that individual OSCs require.
        switch (self.command) {
            .kitty_color_protocol => |*v| kitty_color_protocol: {
                v.deinit(self.alloc orelse break :kitty_color_protocol);
            },
            .change_window_icon,
            .change_window_title,
            .clipboard_contents,
            .color_operation,
            .conemu_change_tab_title,
            .conemu_guimacro,
            .conemu_progress_report,
            .conemu_show_message_box,
            .conemu_sleep,
            .conemu_wait_input,
            .end_of_command,
            .end_of_input,
            .hyperlink_end,
            .hyperlink_start,
            .invalid,
            .mouse_shape,
            .prompt_end,
            .prompt_start,
            .report_pwd,
            .show_desktop_notification,
            => {},
        }

        self.state = .start;
        self.fixed = null;
        self.allocating = null;
        self.writer = null;
        self.command = .invalid;

        if (std.valgrind.runningOnValgrind() > 0) {
            // Initialize our undefined fields so Valgrind can catch it.
            // https://github.com/ziglang/zig/issues/19148
            self.buffer = undefined;
        }
    }

    /// Make sure that we have an allocator. If we don't, set the state to
    /// invalid so that any additional OSC data is discarded.
    pub inline fn ensureAllocator(self: *Parser) bool {
        if (self.alloc != null) return true;
        log.warn("An allocator is required to process OSC {t} but none was provided.", .{self.state});
        self.state = .invalid;
        return false;
    }

    /// Set up a fixed Writer to collect the rest of the OSC data.
    pub inline fn writeToFixed(self: *Parser) void {
        self.fixed = .fixed(&self.buffer);
        self.writer = &self.fixed.?;
    }

    /// Set up an allocating Writer to collect the rest of the OSC data. If we
    /// don't have an allocator or setting up the allocator fails, fall back to
    /// writing to a fixed buffer and hope that it's big enough.
    pub inline fn writeToAllocating(self: *Parser) void {
        const alloc = self.alloc orelse {
            // We don't have an allocator - fall back to a fixed buffer and hope
            // that it's big enough.
            self.writeToFixed();
            return;
        };

        self.allocating = std.Io.Writer.Allocating.initCapacity(alloc, 2048) catch {
            // The allocator failed for some reason, fall back to a fixed buffer
            // and hope that it's big enough.
            self.writeToFixed();
            return;
        };

        self.writer = &self.allocating.?.writer;
    }

    /// Consume the next character c and advance the parser state.
    pub inline fn next(self: *Parser, c: u8) void {
        // If the state becomes invalid for any reason, just discard
        // any further input.
        if (self.state == .invalid) return;

        // If a writer has been initialized, we just accumulate the rest of the
        // OSC sequence in the writer's buffer and skip the state machine.
        if (self.writer) |writer| {
            writer.writeByte(c) catch |err| switch (err) {
                // We have overflowed our buffer or had some other error, set the
                // state to invalid so that we discard any further input.
                error.WriteFailed => self.state = .invalid,
            };
            return;
        }

        switch (self.state) {
            // handled above, so should never be here
            .invalid => unreachable,

            .start => switch (c) {
                '0' => self.state = .@"0",
                '1' => self.state = .@"1",
                '2' => self.state = .@"2",
                '4' => self.state = .@"4",
                '5' => self.state = .@"5",
                '7' => self.state = .@"7",
                '8' => self.state = .@"8",
                '9' => self.state = .@"9",
                else => self.state = .invalid,
            },

            .@"0" => switch (c) {
                ';' => self.writeToFixed(),
                else => self.state = .invalid,
            },

            .@"1" => switch (c) {
                ';' => self.writeToFixed(),
                '0' => self.state = .@"10",
                '1' => self.state = .@"11",
                '2' => self.state = .@"12",
                '3' => self.state = .@"13",
                '4' => self.state = .@"14",
                '5' => self.state = .@"15",
                '6' => self.state = .@"16",
                '7' => self.state = .@"17",
                '8' => self.state = .@"18",
                '9' => self.state = .@"19",
                else => self.state = .invalid,
            },

            .@"10" => switch (c) {
                ';' => if (self.ensureAllocator()) self.writeToFixed(),
                '4' => self.state = .@"104",
                else => self.state = .invalid,
            },

            .@"104" => switch (c) {
                ';' => if (self.ensureAllocator()) self.writeToFixed(),
                else => self.state = .invalid,
            },

            .@"11" => switch (c) {
                ';' => if (self.ensureAllocator()) self.writeToFixed(),
                '0' => self.state = .@"110",
                '1' => self.state = .@"111",
                '2' => self.state = .@"112",
                '3' => self.state = .@"113",
                '4' => self.state = .@"114",
                '5' => self.state = .@"115",
                '6' => self.state = .@"116",
                '7' => self.state = .@"117",
                '8' => self.state = .@"118",
                '9' => self.state = .@"119",
                else => self.state = .invalid,
            },

            .@"110" => switch (c) {
                ';' => if (self.ensureAllocator()) self.writeToFixed(),
                else => self.state = .invalid,
            },

            .@"111" => switch (c) {
                ';' => if (self.ensureAllocator()) self.writeToFixed(),
                else => self.state = .invalid,
            },

            .@"112" => switch (c) {
                ';' => if (self.ensureAllocator()) self.writeToFixed(),
                else => self.state = .invalid,
            },

            .@"113" => switch (c) {
                ';' => if (self.ensureAllocator()) self.writeToFixed(),
                else => self.state = .invalid,
            },

            .@"114" => switch (c) {
                ';' => if (self.ensureAllocator()) self.writeToFixed(),
                else => self.state = .invalid,
            },

            .@"115" => switch (c) {
                ';' => if (self.ensureAllocator()) self.writeToFixed(),
                else => self.state = .invalid,
            },

            .@"116" => switch (c) {
                ';' => if (self.ensureAllocator()) self.writeToFixed(),
                else => self.state = .invalid,
            },

            .@"117" => switch (c) {
                ';' => if (self.ensureAllocator()) self.writeToFixed(),
                else => self.state = .invalid,
            },

            .@"118" => switch (c) {
                ';' => if (self.ensureAllocator()) self.writeToFixed(),
                else => self.state = .invalid,
            },

            .@"119" => switch (c) {
                ';' => if (self.ensureAllocator()) self.writeToFixed(),
                else => self.state = .invalid,
            },

            .@"12" => switch (c) {
                ';' => if (self.ensureAllocator()) self.writeToFixed(),
                else => self.state = .invalid,
            },

            .@"13" => switch (c) {
                ';' => if (self.ensureAllocator()) self.writeToFixed(),
                '3' => self.state = .@"133",
                else => self.state = .invalid,
            },

            .@"133" => switch (c) {
                ';' => self.writeToFixed(),
                else => self.state = .invalid,
            },

            .@"14" => switch (c) {
                ';' => if (self.ensureAllocator()) self.writeToFixed(),
                else => self.state = .invalid,
            },

            .@"15" => switch (c) {
                ';' => if (self.ensureAllocator()) self.writeToFixed(),
                else => self.state = .invalid,
            },

            .@"16" => switch (c) {
                ';' => if (self.ensureAllocator()) self.writeToFixed(),
                else => self.state = .invalid,
            },

            .@"17" => switch (c) {
                ';' => if (self.ensureAllocator()) self.writeToFixed(),
                else => self.state = .invalid,
            },

            .@"18" => switch (c) {
                ';' => if (self.ensureAllocator()) self.writeToFixed(),
                else => self.state = .invalid,
            },

            .@"19" => switch (c) {
                ';' => if (self.ensureAllocator()) self.writeToFixed(),
                else => self.state = .invalid,
            },

            .@"2" => switch (c) {
                ';' => self.writeToFixed(),
                '1' => self.state = .@"21",
                '2' => self.state = .@"22",
                else => self.state = .invalid,
            },

            .@"21" => switch (c) {
                ';' => if (self.ensureAllocator()) self.writeToFixed(),
                else => self.state = .invalid,
            },

            .@"22" => switch (c) {
                ';' => self.writeToFixed(),
                else => self.state = .invalid,
            },

            .@"4" => switch (c) {
                ';' => if (self.ensureAllocator()) self.writeToFixed(),
                else => self.state = .invalid,
            },

            .@"5" => switch (c) {
                ';' => if (self.ensureAllocator()) self.writeToFixed(),
                '2' => self.state = .@"52",
                else => self.state = .invalid,
            },

            .@"52" => switch (c) {
                ';' => self.writeToAllocating(),
                else => self.state = .invalid,
            },

            .@"7" => switch (c) {
                ';' => self.writeToFixed(),
                '7' => self.state = .@"77",
                else => self.state = .invalid,
            },

            .@"77" => switch (c) {
                '7' => self.state = .@"777",
                else => self.state = .invalid,
            },

            .@"777" => switch (c) {
                ';' => self.writeToFixed(),
                else => self.state = .invalid,
            },

            .@"8" => switch (c) {
                ';' => self.writeToFixed(),
                else => self.state = .invalid,
            },

            .@"9" => switch (c) {
                ';' => self.writeToFixed(),
                else => self.state = .invalid,
            },
        }
    }

    /// End the sequence and return the command, if any. If the return value
    /// is null, then no valid command was found. The optional terminator_ch
    /// is the final character in the OSC sequence. This is used to determine
    /// the response terminator.
    ///
    /// The returned pointer is only valid until the next call to the parser.
    /// Callers should copy out any data they wish to retain across calls.
    pub fn end(self: *Parser, terminator_ch: ?u8) ?*Command {
        return switch (self.state) {
            .start => null,
            .invalid => null,
            .@"0" => self.parseChangeWindowTitle(terminator_ch),
            .@"1" => self.parseChangeWindowIcon(terminator_ch),
            .@"2" => self.parseChangeWindowTitle(terminator_ch),
            .@"4" => self.parseOscColor(terminator_ch),
            .@"5" => self.parseOscColor(terminator_ch),
            .@"7" => self.parseReportPwd(terminator_ch),
            .@"8" => self.parseHyperlink(terminator_ch),
            .@"9" => self.parseOsc9(terminator_ch),
            .@"10" => self.parseOscColor(terminator_ch),
            .@"11" => self.parseOscColor(terminator_ch),
            .@"12" => self.parseOscColor(terminator_ch),
            .@"13" => self.parseOscColor(terminator_ch),
            .@"14" => self.parseOscColor(terminator_ch),
            .@"15" => self.parseOscColor(terminator_ch),
            .@"16" => self.parseOscColor(terminator_ch),
            .@"17" => self.parseOscColor(terminator_ch),
            .@"18" => self.parseOscColor(terminator_ch),
            .@"19" => self.parseOscColor(terminator_ch),
            .@"21" => self.parseKittyColorProtocol(terminator_ch),
            .@"22" => self.parseMouseShape(terminator_ch),
            .@"52" => self.parseClipboardOperation(terminator_ch),
            .@"77" => null,
            .@"104" => self.parseOscColor(terminator_ch),
            .@"110" => self.parseOscColor(terminator_ch),
            .@"111" => self.parseOscColor(terminator_ch),
            .@"112" => self.parseOscColor(terminator_ch),
            .@"113" => self.parseOscColor(terminator_ch),
            .@"114" => self.parseOscColor(terminator_ch),
            .@"115" => self.parseOscColor(terminator_ch),
            .@"116" => self.parseOscColor(terminator_ch),
            .@"117" => self.parseOscColor(terminator_ch),
            .@"118" => self.parseOscColor(terminator_ch),
            .@"119" => self.parseOscColor(terminator_ch),
            .@"133" => self.parseSemanticPrompt(terminator_ch),
            .@"777" => self.parseRxvtExtension(terminator_ch),
        };
    }

    /// Parse OSC 0 and OSC 2
    fn parseChangeWindowTitle(self: *Parser, _: ?u8) ?*Command {
        const writer = self.writer orelse {
            self.state = .invalid;
            return null;
        };
        writer.writeByte(0) catch {
            self.state = .invalid;
            return null;
        };
        const data = writer.buffered();
        self.command = .{
            .change_window_title = data[0 .. data.len - 1 :0],
        };
        return &self.command;
    }

    /// Parse OSC 1
    fn parseChangeWindowIcon(self: *Parser, _: ?u8) ?*Command {
        const writer = self.writer orelse {
            self.state = .invalid;
            return null;
        };
        writer.writeByte(0) catch {
            self.state = .invalid;
            return null;
        };
        const data = writer.buffered();
        self.command = .{
            .change_window_icon = data[0 .. data.len - 1 :0],
        };
        return &self.command;
    }

    /// Parse OSCs 4, 5, 10-19, 104, 110-119
    fn parseOscColor(self: *Parser, terminator_ch: ?u8) ?*Command {
        const alloc = self.alloc orelse {
            self.state = .invalid;
            return null;
        };
        // If we've collected any extra data parse that, otherwise use an empty
        // string.
        const data = data: {
            const writer = self.writer orelse break :data "";
            break :data writer.buffered();
        };
        // Check and make sure that we're parsing the correct OSCs
        const op: osc_color.Operation = switch (self.state) {
            .@"4" => .osc_4,
            .@"5" => .osc_5,
            .@"10" => .osc_10,
            .@"11" => .osc_11,
            .@"12" => .osc_12,
            .@"13" => .osc_13,
            .@"14" => .osc_14,
            .@"15" => .osc_15,
            .@"16" => .osc_16,
            .@"17" => .osc_17,
            .@"18" => .osc_18,
            .@"19" => .osc_19,
            .@"104" => .osc_104,
            .@"110" => .osc_110,
            .@"111" => .osc_111,
            .@"112" => .osc_112,
            .@"113" => .osc_113,
            .@"114" => .osc_114,
            .@"115" => .osc_115,
            .@"116" => .osc_116,
            .@"117" => .osc_117,
            .@"118" => .osc_118,
            .@"119" => .osc_119,
            else => {
                self.state = .invalid;
                return null;
            },
        };
        self.command = .{
            .color_operation = .{
                .op = op,
                .requests = osc_color.parse(alloc, op, data) catch |err| list: {
                    log.info(
                        "failed to parse OSC {t} color request err={} data={s}",
                        .{ self.state, err, data },
                    );
                    break :list .{};
                },
                .terminator = .init(terminator_ch),
            },
        };
        return &self.command;
    }

    /// Parse OSC 7
    fn parseReportPwd(self: *Parser, _: ?u8) ?*Command {
        const writer = self.writer orelse {
            self.state = .invalid;
            return null;
        };
        writer.writeByte(0) catch {
            self.state = .invalid;
            return null;
        };
        const data = writer.buffered();
        self.command = .{
            .report_pwd = .{
                .value = data[0 .. data.len - 1 :0],
            },
        };
        return &self.command;
    }

    /// Parse OSC 8 hyperlinks
    fn parseHyperlink(self: *Parser, _: ?u8) ?*Command {
        const writer = self.writer orelse {
            self.state = .invalid;
            return null;
        };
        writer.writeByte(0) catch {
            self.state = .invalid;
            return null;
        };
        const data = writer.buffered();
        const s = std.mem.indexOfScalar(u8, data, ';') orelse {
            self.state = .invalid;
            return null;
        };

        self.command = .{
            .hyperlink_start = .{
                .uri = data[s + 1 .. data.len - 1 :0],
            },
        };

        data[s] = 0;
        const kvs = data[0 .. s + 1];
        std.mem.replaceScalar(u8, kvs, ':', 0);
        var kv_start: usize = 0;
        while (kv_start < kvs.len) {
            const kv_end = std.mem.indexOfScalarPos(u8, kvs, kv_start + 1, 0) orelse break;
            const kv = data[kv_start .. kv_end + 1];
            const v = std.mem.indexOfScalar(u8, kv, '=') orelse break;
            const key = kv[0..v];
            const value = kv[v + 1 .. kv.len - 1 :0];
            if (std.mem.eql(u8, key, "id")) {
                if (value.len > 0) self.command.hyperlink_start.id = value;
            } else {
                log.warn("unknown hyperlink option: '{s}'", .{key});
            }
            kv_start = kv_end + 1;
        }

        if (self.command.hyperlink_start.uri.len == 0) {
            if (self.command.hyperlink_start.id != null) {
                self.state = .invalid;
                return null;
            }
            self.command = .hyperlink_end;
        }

        return &self.command;
    }

    /// Parse OSC 9, which could be an iTerm2 notification or a ConEmu extension.
    fn parseOsc9(self: *Parser, _: ?u8) ?*Command {
        const writer = self.writer orelse {
            self.state = .invalid;
            return null;
        };

        // Check first to see if this is a ConEmu OSC
        // https://conemu.github.io/en/AnsiEscapeCodes.html#ConEmu_specific_OSC
        conemu: {
            var data = writer.buffered();
            if (data.len == 0) break :conemu;
            switch (data[0]) {
                // Check for OSC 9;1 9;10 9;12
                '1' => {
                    if (data.len < 2) break :conemu;
                    switch (data[1]) {
                        // OSC 9;1
                        ';' => {
                            self.command = .{
                                .conemu_sleep = .{
                                    .duration_ms = if (std.fmt.parseUnsigned(u16, data[2..], 10)) |num| @min(num, 10_000) else |_| 100,
                                },
                            };
                            return &self.command;
                        },
                        // OSC 9;10
                        '0' => {
                            self.state = .invalid;
                            return null;
                        },
                        // OSC 9;12
                        '2' => {
                            self.command = .{
                                .prompt_start = .{},
                            };
                            return &self.command;
                        },
                        else => break :conemu,
                    }
                },
                // OSC 9;2
                '2' => {
                    if (data.len < 2) break :conemu;
                    if (data[1] != ';') break :conemu;
                    writer.writeByte(0) catch {
                        self.state = .invalid;
                        return null;
                    };
                    data = writer.buffered();
                    self.command = .{
                        .conemu_show_message_box = data[2 .. data.len - 1 :0],
                    };
                    return &self.command;
                },
                // OSC 9;3
                '3' => {
                    if (data.len < 2) break :conemu;
                    if (data[1] != ';') break :conemu;
                    if (data.len == 2) {
                        self.command = .{
                            .conemu_change_tab_title = .reset,
                        };
                        return &self.command;
                    }
                    writer.writeByte(0) catch {
                        self.state = .invalid;
                        return null;
                    };
                    data = writer.buffered();
                    self.command = .{
                        .conemu_change_tab_title = .{
                            .value = data[2 .. data.len - 1 :0],
                        },
                    };
                    return &self.command;
                },
                // OSC 9;4
                '4' => {
                    if (data.len < 2) break :conemu;
                    if (data[1] != ';') break :conemu;
                    if (data.len < 3) break :conemu;
                    switch (data[2]) {
                        '0' => {
                            self.command = .{
                                .conemu_progress_report = .{
                                    .state = .remove,
                                },
                            };
                        },
                        '1' => {
                            self.command = .{
                                .conemu_progress_report = .{
                                    .state = .set,
                                    .progress = 0,
                                },
                            };
                        },
                        '2' => {
                            self.command = .{
                                .conemu_progress_report = .{
                                    .state = .@"error",
                                },
                            };
                        },
                        '3' => {
                            self.command = .{
                                .conemu_progress_report = .{
                                    .state = .indeterminate,
                                },
                            };
                        },
                        '4' => {
                            self.command = .{
                                .conemu_progress_report = .{
                                    .state = .pause,
                                },
                            };
                        },
                        else => break :conemu,
                    }
                    switch (self.command.conemu_progress_report.state) {
                        .remove, .indeterminate => {},
                        .set, .@"error", .pause => progress: {
                            if (data.len < 4) break :progress;
                            if (data[3] != ';') break :progress;
                            // parse the progress value
                            self.command.conemu_progress_report.progress = value: {
                                break :value @intCast(std.math.clamp(
                                    std.fmt.parseUnsigned(usize, data[4..], 10) catch break :value null,
                                    0,
                                    100,
                                ));
                            };
                        },
                    }
                    return &self.command;
                },
                // OSC 9;5
                '5' => {
                    self.command = .conemu_wait_input;
                    return &self.command;
                },
                // OSC 9;6
                '6' => {
                    if (data.len < 2) break :conemu;
                    if (data[1] != ';') break :conemu;
                    writer.writeByte(0) catch {
                        self.state = .invalid;
                        return null;
                    };
                    data = writer.buffered();
                    self.command = .{
                        .conemu_guimacro = data[2 .. data.len - 1 :0],
                    };
                    return &self.command;
                },
                // OSC 9;7
                '7' => {
                    if (data.len < 2) break :conemu;
                    if (data[1] != ';') break :conemu;
                    self.state = .invalid;
                    return null;
                },
                // OSC 9;8
                '8' => {
                    if (data.len < 2) break :conemu;
                    if (data[1] != ';') break :conemu;
                    self.state = .invalid;
                    return null;
                },
                // OSC 9;9
                '9' => {
                    if (data.len < 2) break :conemu;
                    if (data[1] != ';') break :conemu;
                    self.state = .invalid;
                    return null;
                },
                else => break :conemu,
            }
        }

        // If it's not a ConEmu OSC, it's an iTerm2 notification

        writer.writeByte(0) catch {
            self.state = .invalid;
            return null;
        };
        const data = writer.buffered();
        self.command = .{
            .show_desktop_notification = .{
                .title = "",
                .body = data[0 .. data.len - 1 :0],
            },
        };
        return &self.command;
    }

    /// Parse OSC 21, the Kitty Color Protocol.
    fn parseKittyColorProtocol(self: *Parser, terminator_ch: ?u8) ?*Command {
        assert(self.state == .@"21");
        const alloc = self.alloc orelse {
            self.state = .invalid;
            return null;
        };
        const writer = self.writer orelse {
            self.state = .invalid;
            return null;
        };
        self.command = .{
            .kitty_color_protocol = .{
                .list = .empty,
                .terminator = .init(terminator_ch),
            },
        };
        const list = &self.command.kitty_color_protocol.list;
        const data = writer.buffered();
        var kv_it = std.mem.splitScalar(u8, data, ';');
        while (kv_it.next()) |kv| {
            if (list.items.len >= @as(usize, kitty_color.Kind.max) * 2) {
                log.warn("exceeded limit for number of keys in kitty color protocol, ignoring", .{});
                self.state = .invalid;
                return null;
            }
            var it = std.mem.splitScalar(u8, kv, '=');
            const k = it.next() orelse continue;
            if (k.len == 0) {
                log.warn("zero length key in kitty color protocol", .{});
                continue;
            }
            const key = kitty_color.Kind.parse(k) orelse {
                log.warn("unknown key in kitty color protocol: {s}", .{k});
                continue;
            };
            const value = std.mem.trim(u8, it.rest(), " ");
            if (value.len == 0) {
                list.append(alloc, .{ .reset = key }) catch |err| {
                    log.warn("unable to append kitty color protocol option: {}", .{err});
                    continue;
                };
            } else if (mem.eql(u8, "?", value)) {
                list.append(alloc, .{ .query = key }) catch |err| {
                    log.warn("unable to append kitty color protocol option: {}", .{err});
                    continue;
                };
            } else {
                list.append(alloc, .{
                    .set = .{
                        .key = key,
                        .color = RGB.parse(value) catch |err| switch (err) {
                            error.InvalidFormat => {
                                log.warn("invalid color format in kitty color protocol: {s}", .{value});
                                continue;
                            },
                        },
                    },
                }) catch |err| {
                    log.warn("unable to append kitty color protocol option: {}", .{err});
                    continue;
                };
            }
        }
        return &self.command;
    }

    // Parse OSC 22
    fn parseMouseShape(self: *Parser, _: ?u8) ?*Command {
        assert(self.state == .@"22");
        const writer = self.writer orelse {
            self.state = .invalid;
            return null;
        };
        writer.writeByte(0) catch {
            self.state = .invalid;
            return null;
        };
        const data = writer.buffered();
        self.command = .{
            .mouse_shape = .{
                .value = data[0 .. data.len - 1 :0],
            },
        };
        return &self.command;
    }

    /// Parse OSC 52
    fn parseClipboardOperation(self: *Parser, _: ?u8) ?*Command {
        assert(self.state == .@"52");
        const writer = self.writer orelse {
            self.state = .invalid;
            return null;
        };
        writer.writeByte(0) catch {
            self.state = .invalid;
            return null;
        };
        const data = writer.buffered();
        if (data.len == 1) {
            self.state = .invalid;
            return null;
        }
        if (data[0] == ';') {
            self.command = .{
                .clipboard_contents = .{
                    .kind = 'c',
                    .data = data[1 .. data.len - 1 :0],
                },
            };
        } else {
            if (data.len < 2) {
                self.state = .invalid;
                return null;
            }
            if (data[1] != ';') {
                self.state = .invalid;
                return null;
            }
            self.command = .{
                .clipboard_contents = .{
                    .kind = data[0],
                    .data = data[2 .. data.len - 1 :0],
                },
            };
        }
        return &self.command;
    }

    /// Parse OSC 133, semantic prompts
    fn parseSemanticPrompt(self: *Parser, _: ?u8) ?*Command {
        const writer = self.writer orelse {
            self.state = .invalid;
            return null;
        };
        const data = writer.buffered();
        if (data.len == 0) {
            self.state = .invalid;
            return null;
        }
        switch (data[0]) {
            'A' => prompt_start: {
                self.command = .{
                    .prompt_start = .{},
                };
                if (data.len == 1) break :prompt_start;
                if (data[1] != ';') {
                    self.state = .invalid;
                    return null;
                }
                var it = SemanticPromptKVIterator.init(writer) catch {
                    self.state = .invalid;
                    return null;
                };
                while (it.next()) |kv| {
                    if (std.mem.eql(u8, kv.key, "aid")) {
                        self.command.prompt_start.aid = kv.value;
                    } else if (std.mem.eql(u8, kv.key, "redraw")) redraw: {
                        // https://sw.kovidgoyal.net/kitty/shell-integration/#notes-for-shell-developers
                        // Kitty supports a "redraw" option for prompt_start. I can't find
                        // this documented anywhere but can see in the code that this is used
                        // by shell environments to tell the terminal that the shell will NOT
                        // redraw the prompt so we should attempt to resize it.
                        self.command.prompt_start.redraw = (value: {
                            if (kv.value.len != 1) break :value null;
                            switch (kv.value[0]) {
                                '0' => break :value false,
                                '1' => break :value true,
                                else => break :value null,
                            }
                        }) orelse {
                            log.info("OSC 133 A: invalid redraw value: {s}", .{kv.value});
                            break :redraw;
                        };
                    } else if (std.mem.eql(u8, kv.key, "special_key")) redraw: {
                        // https://sw.kovidgoyal.net/kitty/shell-integration/#notes-for-shell-developers
                        self.command.prompt_start.special_key = (value: {
                            if (kv.value.len != 1) break :value null;
                            switch (kv.value[0]) {
                                '0' => break :value false,
                                '1' => break :value true,
                                else => break :value null,
                            }
                        }) orelse {
                            log.info("OSC 133 A invalid special_key value: {s}", .{kv.value});
                            break :redraw;
                        };
                    } else if (std.mem.eql(u8, kv.key, "click_events")) redraw: {
                        // https://sw.kovidgoyal.net/kitty/shell-integration/#notes-for-shell-developers
                        self.command.prompt_start.click_events = (value: {
                            if (kv.value.len != 1) break :value null;
                            switch (kv.value[0]) {
                                '0' => break :value false,
                                '1' => break :value true,
                                else => break :value null,
                            }
                        }) orelse {
                            log.info("OSC 133 A invalid click_events value: {s}", .{kv.value});
                            break :redraw;
                        };
                    } else if (std.mem.eql(u8, kv.key, "k")) k: {
                        // The "k" marks the kind of prompt, or "primary" if we don't know.
                        // This can be used to distinguish between the first (initial) prompt,
                        // a continuation, etc.
                        if (kv.value.len != 1) break :k;
                        self.command.prompt_start.kind = switch (kv.value[0]) {
                            'c' => .continuation,
                            's' => .secondary,
                            'r' => .right,
                            'i' => .primary,
                            else => .primary,
                        };
                    } else log.info("OSC 133 A: unknown semantic prompt option: {s}", .{kv.key});
                }
            },
            'B' => prompt_end: {
                self.command = .prompt_end;
                if (data.len == 1) break :prompt_end;
                if (data[1] != ';') {
                    self.state = .invalid;
                    return null;
                }
                var it = SemanticPromptKVIterator.init(writer) catch {
                    self.state = .invalid;
                    return null;
                };
                while (it.next()) |kv| {
                    log.info("OSC 133 B: unknown semantic prompt option: {s}", .{kv.key});
                }
            },
            'C' => end_of_input: {
                self.command = .{
                    .end_of_input = .{},
                };
                if (data.len == 1) break :end_of_input;
                if (data[1] != ';') {
                    self.state = .invalid;
                    return null;
                }
                var it = SemanticPromptKVIterator.init(writer) catch {
                    self.state = .invalid;
                    return null;
                };
                while (it.next()) |kv| {
                    if (std.mem.eql(u8, kv.key, "cmdline")) {
                        self.command.end_of_input.cmdline = string_encoding.printfQDecode(kv.value) catch null;
                    } else if (std.mem.eql(u8, kv.key, "cmdline_url")) {
                        self.command.end_of_input.cmdline = string_encoding.urlPercentDecode(kv.value) catch null;
                    } else {
                        log.info("OSC 133 C: unknown semantic prompt option: {s}", .{kv.key});
                    }
                }
            },
            'D' => {
                const exit_code: ?u8 = exit_code: {
                    if (data.len == 1) break :exit_code null;
                    if (data[1] != ';') {
                        self.state = .invalid;
                        return null;
                    }
                    break :exit_code std.fmt.parseUnsigned(u8, data[2..], 10) catch null;
                };
                self.command = .{
                    .end_of_command = .{
                        .exit_code = exit_code,
                    },
                };
            },
            else => {
                self.state = .invalid;
                return null;
            },
        }
        return &self.command;
    }

    const SemanticPromptKVIterator = struct {
        index: usize,
        string: []u8,

        pub const SemanticPromptKV = struct {
            key: [:0]u8,
            value: [:0]u8,
        };

        pub fn init(writer: *std.Io.Writer) std.Io.Writer.Error!SemanticPromptKVIterator {
            // add a semicolon to make it easier to find and sentinel terminate the values
            try writer.writeByte(';');
            return .{
                .index = 0,
                .string = writer.buffered()[2..],
            };
        }

        pub fn next(self: *SemanticPromptKVIterator) ?SemanticPromptKV {
            if (self.index >= self.string.len) return null;

            const kv = kv: {
                const index = std.mem.indexOfScalarPos(u8, self.string, self.index, ';') orelse {
                    self.index = self.string.len;
                    return null;
                };
                self.string[index] = 0;
                const kv = self.string[self.index..index :0];
                self.index = index + 1;
                break :kv kv;
            };

            const key = key: {
                const index = std.mem.indexOfScalar(u8, kv, '=') orelse break :key kv;
                kv[index] = 0;
                const key = kv[0..index :0];
                break :key key;
            };

            const value = kv[key.len + 1 .. :0];

            return .{
                .key = key,
                .value = value,
            };
        }
    };

    /// Parse OSC 777
    fn parseRxvtExtension(self: *Parser, _: ?u8) ?*Command {
        const writer = self.writer orelse {
            self.state = .invalid;
            return null;
        };
        // ensure that we are sentinel terminated
        writer.writeByte(0) catch {
            self.state = .invalid;
            return null;
        };
        const data = writer.buffered();
        const k = std.mem.indexOfScalar(u8, data, ';') orelse {
            self.state = .invalid;
            return null;
        };
        const ext = data[0..k];
        if (!std.mem.eql(u8, ext, "notify")) {
            log.warn("unknown rxvt extension: {s}", .{ext});
            self.state = .invalid;
            return null;
        }
        const t = std.mem.indexOfScalarPos(u8, data, k + 1, ';') orelse {
            log.warn("rxvt notify extension is missing the title", .{});
            self.state = .invalid;
            return null;
        };
        data[t] = 0;
        const title = data[k + 1 .. t :0];
        const body = data[t + 1 .. data.len - 1 :0];
        self.command = .{
            .show_desktop_notification = .{
                .title = title,
                .body = body,
            },
        };
        return &self.command;
    }
};

test {
    _ = osc_color;
}

test "OSC 0: change_window_title" {
    const testing = std.testing;

    var p: Parser = .init(null);
    p.next('0');
    p.next(';');
    p.next('a');
    p.next('b');
    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .change_window_title);
    try testing.expectEqualStrings("ab", cmd.change_window_title);
}

test "OSC 0: longer than buffer" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "0;" ++ "a" ** (Parser.MAX_BUF + 2);
    for (input) |ch| p.next(ch);

    try testing.expect(p.end(null) == null);
}

test "OSC 0: one shorter than buffer length" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const prefix = "0;";
    const title = "a" ** (Parser.MAX_BUF - 1);
    const input = prefix ++ title;
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .change_window_title);
    try testing.expectEqualStrings(title, cmd.change_window_title);
}

test "OSC 0: exactly at buffer length" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const prefix = "0;";
    const title = "a" ** Parser.MAX_BUF;
    const input = prefix ++ title;
    for (input) |ch| p.next(ch);

    // This should be null because we always reserve space for a null terminator.
    try testing.expect(p.end(null) == null);
}

test "OSC 1: change_window_icon" {
    const testing = std.testing;

    var p: Parser = .init(null);
    p.next('1');
    p.next(';');
    p.next('a');
    p.next('b');
    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .change_window_icon);
    try testing.expectEqualStrings("ab", cmd.change_window_icon);
}

test "OSC 2: change_window_title with 2" {
    const testing = std.testing;

    var p: Parser = .init(null);
    p.next('2');
    p.next(';');
    p.next('a');
    p.next('b');
    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .change_window_title);
    try testing.expectEqualStrings("ab", cmd.change_window_title);
}

test "OSC 2: change_window_title with utf8" {
    const testing = std.testing;

    var p: Parser = .init(null);
    p.next('2');
    p.next(';');
    // '—' EM DASH U+2014 (E2 80 94)
    p.next(0xE2);
    p.next(0x80);
    p.next(0x94);

    p.next(' ');
    // '‐' HYPHEN U+2010 (E2 80 90)
    // Intententionally chosen to conflict with the 0x90 C1 control
    p.next(0xE2);
    p.next(0x80);
    p.next(0x90);
    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .change_window_title);
    try testing.expectEqualStrings("— ‐", cmd.change_window_title);
}

test "OSC 2: change_window_title empty" {
    const testing = std.testing;

    var p: Parser = .init(null);
    p.next('2');
    p.next(';');
    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .change_window_title);
    try testing.expectEqualStrings("", cmd.change_window_title);
}

test "OSC 4: empty param" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "4;;";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b');
    try testing.expect(cmd == null);
}

// See src/terminal/osc/color.zig for more OSC 4 tests.

// See src/terminal/osc/color.zig for OSC 5 tests.

test "OSC 7: report pwd" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "7;file:///tmp/example";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .report_pwd);
    try testing.expectEqualStrings("file:///tmp/example", cmd.report_pwd.value);
}

test "OSC 7: report pwd empty" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "7;";
    for (input) |ch| p.next(ch);
    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .report_pwd);
    try testing.expectEqualStrings("", cmd.report_pwd.value);
}

test "OSC 8: hyperlink" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "8;;http://example.com";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .hyperlink_start);
    try testing.expectEqualStrings(cmd.hyperlink_start.uri, "http://example.com");
}

test "OSC 8: hyperlink with id set" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "8;id=foo;http://example.com";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .hyperlink_start);
    try testing.expectEqualStrings(cmd.hyperlink_start.id.?, "foo");
    try testing.expectEqualStrings(cmd.hyperlink_start.uri, "http://example.com");
}

test "OSC 8: hyperlink with empty id" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "8;id=;http://example.com";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .hyperlink_start);
    try testing.expectEqual(null, cmd.hyperlink_start.id);
    try testing.expectEqualStrings(cmd.hyperlink_start.uri, "http://example.com");
}

test "OSC 8: hyperlink with incomplete key" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "8;id;http://example.com";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .hyperlink_start);
    try testing.expectEqual(null, cmd.hyperlink_start.id);
    try testing.expectEqualStrings(cmd.hyperlink_start.uri, "http://example.com");
}

test "OSC 8: hyperlink with empty key" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "8;=value;http://example.com";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .hyperlink_start);
    try testing.expectEqual(null, cmd.hyperlink_start.id);
    try testing.expectEqualStrings(cmd.hyperlink_start.uri, "http://example.com");
}

test "OSC 8: hyperlink with empty key and id" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "8;=value:id=foo;http://example.com";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .hyperlink_start);
    try testing.expectEqualStrings(cmd.hyperlink_start.id.?, "foo");
    try testing.expectEqualStrings(cmd.hyperlink_start.uri, "http://example.com");
}

test "OSC 8: hyperlink with empty uri" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "8;id=foo;";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b');
    try testing.expect(cmd == null);
}

test "OSC 8: hyperlink end" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "8;;";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .hyperlink_end);
}

test "OSC 9: show desktop notification" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "9;Hello world";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .show_desktop_notification);
    try testing.expectEqualStrings("", cmd.show_desktop_notification.title);
    try testing.expectEqualStrings("Hello world", cmd.show_desktop_notification.body);
}

test "OSC 9: show single character desktop notification" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "9;H";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .show_desktop_notification);
    try testing.expectEqualStrings("", cmd.show_desktop_notification.title);
    try testing.expectEqualStrings("H", cmd.show_desktop_notification.body);
}

test "OSC 9;1: ConEmu sleep" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "9;1;420";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;

    try testing.expect(cmd == .conemu_sleep);
    try testing.expectEqual(420, cmd.conemu_sleep.duration_ms);
}

test "OSC 9;1: ConEmu sleep with no value default to 100ms" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "9;1;";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;

    try testing.expect(cmd == .conemu_sleep);
    try testing.expectEqual(100, cmd.conemu_sleep.duration_ms);
}

test "OSC 9;1: conemu sleep cannot exceed 10000ms" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "9;1;12345";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;

    try testing.expect(cmd == .conemu_sleep);
    try testing.expectEqual(10000, cmd.conemu_sleep.duration_ms);
}

test "OSC 9;1: conemu sleep invalid input" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "9;1;foo";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;

    try testing.expect(cmd == .conemu_sleep);
    try testing.expectEqual(100, cmd.conemu_sleep.duration_ms);
}

test "OSC 9;1: conemu sleep -> desktop notification 1" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "9;1";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;

    try testing.expect(cmd == .show_desktop_notification);
    try testing.expectEqualStrings("1", cmd.show_desktop_notification.body);
}

test "OSC 9;1: conemu sleep -> desktop notification 2" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "9;1a";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;

    try testing.expect(cmd == .show_desktop_notification);
    try testing.expectEqualStrings("1a", cmd.show_desktop_notification.body);
}

test "OSC 9;2: ConEmu message box" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "9;2;hello world";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .conemu_show_message_box);
    try testing.expectEqualStrings("hello world", cmd.conemu_show_message_box);
}

test "OSC 9;2: ConEmu message box invalid input" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "9;2";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .show_desktop_notification);
    try testing.expectEqualStrings("2", cmd.show_desktop_notification.body);
}

test "OSC 9;2: ConEmu message box empty message" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "9;2;";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .conemu_show_message_box);
    try testing.expectEqualStrings("", cmd.conemu_show_message_box);
}

test "OSC 9;2: ConEmu message box spaces only message" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "9;2;   ";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .conemu_show_message_box);
    try testing.expectEqualStrings("   ", cmd.conemu_show_message_box);
}

test "OSC 9;2: message box -> desktop notification 1" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "9;2";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;

    try testing.expect(cmd == .show_desktop_notification);
    try testing.expectEqualStrings("2", cmd.show_desktop_notification.body);
}

test "OSC 9;2: message box -> desktop notification 2" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "9;2a";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;

    try testing.expect(cmd == .show_desktop_notification);
    try testing.expectEqualStrings("2a", cmd.show_desktop_notification.body);
}

test "OSC 9;3: ConEmu change tab title" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "9;3;foo bar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .conemu_change_tab_title);
    try testing.expectEqualStrings("foo bar", cmd.conemu_change_tab_title.value);
}

test "OSC 9;3: ConEmu change tab title reset" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "9;3;";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;

    const expected_command: Command = .{ .conemu_change_tab_title = .reset };
    try testing.expectEqual(expected_command, cmd);
}

test "OSC 9;3: ConEmu change tab title spaces only" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "9;3;   ";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;

    try testing.expect(cmd == .conemu_change_tab_title);
    try testing.expectEqualStrings("   ", cmd.conemu_change_tab_title.value);
}

test "OSC 9;3: change tab title -> desktop notification 1" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "9;3";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;

    try testing.expect(cmd == .show_desktop_notification);
    try testing.expectEqualStrings("3", cmd.show_desktop_notification.body);
}

test "OSC 9;3: message box -> desktop notification 2" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "9;3a";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;

    try testing.expect(cmd == .show_desktop_notification);
    try testing.expectEqualStrings("3a", cmd.show_desktop_notification.body);
}

test "OSC 9;4: ConEmu progress set" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "9;4;1;100";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .conemu_progress_report);
    try testing.expect(cmd.conemu_progress_report.state == .set);
    try testing.expect(cmd.conemu_progress_report.progress == 100);
}

test "OSC 9;4: ConEmu progress set overflow" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "9;4;1;900";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .conemu_progress_report);
    try testing.expect(cmd.conemu_progress_report.state == .set);
    try testing.expectEqual(100, cmd.conemu_progress_report.progress);
}

test "OSC 9;4: ConEmu progress set single digit" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "9;4;1;9";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .conemu_progress_report);
    try testing.expect(cmd.conemu_progress_report.state == .set);
    try testing.expect(cmd.conemu_progress_report.progress == 9);
}

test "OSC 9;4: ConEmu progress set double digit" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "9;4;1;94";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .conemu_progress_report);
    try testing.expect(cmd.conemu_progress_report.state == .set);
    try testing.expectEqual(94, cmd.conemu_progress_report.progress);
}

test "OSC 9;4: ConEmu progress set extra semicolon ignored" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "9;4;1;100";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .conemu_progress_report);
    try testing.expect(cmd.conemu_progress_report.state == .set);
    try testing.expectEqual(100, cmd.conemu_progress_report.progress);
}

test "OSC 9;4: ConEmu progress remove with no progress" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "9;4;0;";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .conemu_progress_report);
    try testing.expect(cmd.conemu_progress_report.state == .remove);
    try testing.expect(cmd.conemu_progress_report.progress == null);
}

test "OSC 9;4: ConEmu progress remove with double semicolon" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "9;4;0;;";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .conemu_progress_report);
    try testing.expect(cmd.conemu_progress_report.state == .remove);
    try testing.expect(cmd.conemu_progress_report.progress == null);
}

test "OSC 9;4: ConEmu progress remove ignores progress" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "9;4;0;100";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .conemu_progress_report);
    try testing.expect(cmd.conemu_progress_report.state == .remove);
    try testing.expect(cmd.conemu_progress_report.progress == null);
}

test "OSC 9;4: ConEmu progress remove extra semicolon" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "9;4;0;100;";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .conemu_progress_report);
    try testing.expect(cmd.conemu_progress_report.state == .remove);
}

test "OSC 9;4: ConEmu progress error" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "9;4;2";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .conemu_progress_report);
    try testing.expect(cmd.conemu_progress_report.state == .@"error");
    try testing.expect(cmd.conemu_progress_report.progress == null);
}

test "OSC 9;4: ConEmu progress error with progress" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "9;4;2;100";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .conemu_progress_report);
    try testing.expect(cmd.conemu_progress_report.state == .@"error");
    try testing.expect(cmd.conemu_progress_report.progress == 100);
}

test "OSC 9;4: progress pause" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "9;4;4";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .conemu_progress_report);
    try testing.expect(cmd.conemu_progress_report.state == .pause);
    try testing.expect(cmd.conemu_progress_report.progress == null);
}

test "OSC 9;4: ConEmu progress pause with progress" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "9;4;4;100";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .conemu_progress_report);
    try testing.expect(cmd.conemu_progress_report.state == .pause);
    try testing.expect(cmd.conemu_progress_report.progress == 100);
}

test "OSC 9;4: progress -> desktop notification 1" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "9;4";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;

    try testing.expect(cmd == .show_desktop_notification);
    try testing.expectEqualStrings("4", cmd.show_desktop_notification.body);
}

test "OSC 9;4: progress -> desktop notification 2" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "9;4;";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;

    try testing.expect(cmd == .show_desktop_notification);
    try testing.expectEqualStrings("4;", cmd.show_desktop_notification.body);
}

test "OSC 9;4: progress -> desktop notification 3" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "9;4;5";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;

    try testing.expect(cmd == .show_desktop_notification);
    try testing.expectEqualStrings("4;5", cmd.show_desktop_notification.body);
}

test "OSC 9;4: progress -> desktop notification 4" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "9;4;5a";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;

    try testing.expect(cmd == .show_desktop_notification);
    try testing.expectEqualStrings("4;5a", cmd.show_desktop_notification.body);
}

test "OSC 9;5: ConEmu wait input" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "9;5";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .conemu_wait_input);
}

test "OSC 9;5: ConEmu wait ignores trailing characters" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "9;5;foo";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .conemu_wait_input);
}

test "OSC 9;6: ConEmu guimacro 1" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "9;6;a";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .conemu_guimacro);
    try testing.expectEqualStrings("a", cmd.conemu_guimacro);
}

test "OSC: 9;6: ConEmu guimacro 2" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "9;6;ab";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .conemu_guimacro);
    try testing.expectEqualStrings("ab", cmd.conemu_guimacro);
}

test "OSC: 9;6: ConEmu guimacro 3 incomplete -> desktop notification" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "9;6";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .show_desktop_notification);
    try testing.expectEqualStrings("6", cmd.show_desktop_notification.body);
}

// See src/terminal/osc/color.zig for OSC 10 tests.

// See src/terminal/osc/color.zig for OSC 11 tests.

// See src/terminal/osc/color.zig for OSC 12 tests.

// See src/terminal/osc/color.zig for OSC 13 tests.

// See src/terminal/osc/color.zig for OSC 14 tests.

// See src/terminal/osc/color.zig for OSC 15 tests.

// See src/terminal/osc/color.zig for OSC 16 tests.

// See src/terminal/osc/color.zig for OSC 17 tests.

// See src/terminal/osc/color.zig for OSC 18 tests.

// See src/terminal/osc/color.zig for OSC 19 tests.

test "OSC 21: kitty color protocol" {
    const testing = std.testing;
    const Kind = kitty_color.Kind;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "21;foreground=?;background=rgb:f0/f8/ff;cursor=aliceblue;cursor_text;visual_bell=;selection_foreground=#xxxyyzz;selection_background=?;selection_background=#aabbcc;2=?;3=rgbi:1.0/1.0/1.0";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_color_protocol);
    try testing.expectEqual(@as(usize, 9), cmd.kitty_color_protocol.list.items.len);
    {
        const item = cmd.kitty_color_protocol.list.items[0];
        try testing.expect(item == .query);
        try testing.expectEqual(Kind{ .special = .foreground }, item.query);
    }
    {
        const item = cmd.kitty_color_protocol.list.items[1];
        try testing.expect(item == .set);
        try testing.expectEqual(Kind{ .special = .background }, item.set.key);
        try testing.expectEqual(@as(u8, 0xf0), item.set.color.r);
        try testing.expectEqual(@as(u8, 0xf8), item.set.color.g);
        try testing.expectEqual(@as(u8, 0xff), item.set.color.b);
    }
    {
        const item = cmd.kitty_color_protocol.list.items[2];
        try testing.expect(item == .set);
        try testing.expectEqual(Kind{ .special = .cursor }, item.set.key);
        try testing.expectEqual(@as(u8, 0xf0), item.set.color.r);
        try testing.expectEqual(@as(u8, 0xf8), item.set.color.g);
        try testing.expectEqual(@as(u8, 0xff), item.set.color.b);
    }
    {
        const item = cmd.kitty_color_protocol.list.items[3];
        try testing.expect(item == .reset);
        try testing.expectEqual(Kind{ .special = .cursor_text }, item.reset);
    }
    {
        const item = cmd.kitty_color_protocol.list.items[4];
        try testing.expect(item == .reset);
        try testing.expectEqual(Kind{ .special = .visual_bell }, item.reset);
    }
    {
        const item = cmd.kitty_color_protocol.list.items[5];
        try testing.expect(item == .query);
        try testing.expectEqual(Kind{ .special = .selection_background }, item.query);
    }
    {
        const item = cmd.kitty_color_protocol.list.items[6];
        try testing.expect(item == .set);
        try testing.expectEqual(Kind{ .special = .selection_background }, item.set.key);
        try testing.expectEqual(@as(u8, 0xaa), item.set.color.r);
        try testing.expectEqual(@as(u8, 0xbb), item.set.color.g);
        try testing.expectEqual(@as(u8, 0xcc), item.set.color.b);
    }
    {
        const item = cmd.kitty_color_protocol.list.items[7];
        try testing.expect(item == .query);
        try testing.expectEqual(Kind{ .palette = 2 }, item.query);
    }
    {
        const item = cmd.kitty_color_protocol.list.items[8];
        try testing.expect(item == .set);
        try testing.expectEqual(Kind{ .palette = 3 }, item.set.key);
        try testing.expectEqual(@as(u8, 0xff), item.set.color.r);
        try testing.expectEqual(@as(u8, 0xff), item.set.color.g);
        try testing.expectEqual(@as(u8, 0xff), item.set.color.b);
    }
}

test "OSC 21: kitty color protocol without allocator" {
    const testing = std.testing;

    var p: Parser = .init(null);
    defer p.deinit();

    const input = "21;foreground=?";
    for (input) |ch| p.next(ch);
    try testing.expect(p.end('\x1b') == null);
}

test "OSC 21: kitty color protocol double reset" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "21;foreground=?;background=rgb:f0/f8/ff;cursor=aliceblue;cursor_text;visual_bell=;selection_foreground=#xxxyyzz;selection_background=?;selection_background=#aabbcc;2=?;3=rgbi:1.0/1.0/1.0";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_color_protocol);

    p.reset();
    p.reset();
}

test "OSC 21: kitty color protocol reset after invalid" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "21;foreground=?;background=rgb:f0/f8/ff;cursor=aliceblue;cursor_text;visual_bell=;selection_foreground=#xxxyyzz;selection_background=?;selection_background=#aabbcc;2=?;3=rgbi:1.0/1.0/1.0";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_color_protocol);

    p.reset();

    try testing.expectEqual(Parser.State.start, p.state);
    p.next('X');
    try testing.expectEqual(Parser.State.invalid, p.state);

    p.reset();
}

test "OSC 21: kitty color protocol no key" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "21;";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .kitty_color_protocol);
    try testing.expectEqual(0, cmd.kitty_color_protocol.list.items.len);
}

test "OSC 22: pointer cursor" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "22;pointer";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .mouse_shape);
    try testing.expectEqualStrings("pointer", cmd.mouse_shape.value);
}

test "OSC 52: get/set clipboard" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "52;s;?";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .clipboard_contents);
    try testing.expect(cmd.clipboard_contents.kind == 's');
    try testing.expectEqualStrings("?", cmd.clipboard_contents.data);
}

test "OSC 52: get/set clipboard (optional parameter)" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "52;;?";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .clipboard_contents);
    try testing.expect(cmd.clipboard_contents.kind == 'c');
    try testing.expectEqualStrings("?", cmd.clipboard_contents.data);
}

test "OSC 52: get/set clipboard with allocator" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    const input = "52;s;?";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .clipboard_contents);
    try testing.expect(cmd.clipboard_contents.kind == 's');
    try testing.expectEqualStrings("?", cmd.clipboard_contents.data);
}

test "OSC 52: clear clipboard" {
    const testing = std.testing;

    var p: Parser = .init(null);
    defer p.deinit();

    const input = "52;;";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .clipboard_contents);
    try testing.expect(cmd.clipboard_contents.kind == 'c');
    try testing.expectEqualStrings("", cmd.clipboard_contents.data);
}

// See src/terminal/osc/color.zig for OSC 104 tests.

// See src/terminal/osc/color.zig for OSC 105 tests.

// See src/terminal/osc/color.zig for OSC 110 tests.

// See src/terminal/osc/color.zig for OSC 111 tests.

// See src/terminal/osc/color.zig for OSC 112 tests.

// See src/terminal/osc/color.zig for OSC 113 tests.

// See src/terminal/osc/color.zig for OSC 114 tests.

// See src/terminal/osc/color.zig for OSC 115 tests.

// See src/terminal/osc/color.zig for OSC 116 tests.

// See src/terminal/osc/color.zig for OSC 117 tests.

// See src/terminal/osc/color.zig for OSC 118 tests.

// See src/terminal/osc/color.zig for OSC 119 tests.

test "OSC 133: prompt_start" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;A";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .prompt_start);
    try testing.expect(cmd.prompt_start.aid == null);
    try testing.expect(cmd.prompt_start.redraw);
}

test "OSC 133: prompt_start with single option" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;A;aid=14";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .prompt_start);
    try testing.expectEqualStrings("14", cmd.prompt_start.aid.?);
}

test "OSC 133: prompt_start with '=' in aid" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;A;aid=a=b;redraw=0";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .prompt_start);
    try testing.expectEqualStrings("a=b", cmd.prompt_start.aid.?);
    try testing.expect(!cmd.prompt_start.redraw);
}

test "OSC 133: prompt_start with redraw disabled" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;A;redraw=0";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .prompt_start);
    try testing.expect(!cmd.prompt_start.redraw);
}

test "OSC 133: prompt_start with redraw invalid value" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;A;redraw=42";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .prompt_start);
    try testing.expect(cmd.prompt_start.redraw);
    try testing.expect(cmd.prompt_start.kind == .primary);
}

test "OSC 133: prompt_start with continuation" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;A;k=c";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .prompt_start);
    try testing.expect(cmd.prompt_start.kind == .continuation);
}

test "OSC 133: prompt_start with secondary" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;A;k=s";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .prompt_start);
    try testing.expect(cmd.prompt_start.kind == .secondary);
}

test "OSC 133: prompt_start with special_key" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;A;special_key=1";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .prompt_start);
    try testing.expect(cmd.prompt_start.special_key == true);
}

test "OSC 133: prompt_start with special_key invalid" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;A;special_key=bobr";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .prompt_start);
    try testing.expect(cmd.prompt_start.special_key == false);
}

test "OSC 133: prompt_start with special_key 0" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;A;special_key=0";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .prompt_start);
    try testing.expect(cmd.prompt_start.special_key == false);
}

test "OSC 133: prompt_start with special_key empty" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;A;special_key=";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .prompt_start);
    try testing.expect(cmd.prompt_start.special_key == false);
}

test "OSC 133: prompt_start with click_events true" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;A;click_events=1";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .prompt_start);
    try testing.expect(cmd.prompt_start.click_events == true);
}

test "OSC 133: prompt_start with click_events false" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;A;click_events=0";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .prompt_start);
    try testing.expect(cmd.prompt_start.click_events == false);
}

test "OSC 133: prompt_start with click_events empty" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;A;click_events=";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .prompt_start);
    try testing.expect(cmd.prompt_start.click_events == false);
}

test "OSC 133: end_of_command no exit code" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;D";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .end_of_command);
}

test "OSC 133: end_of_command with exit code" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;D;25";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .end_of_command);
    try testing.expectEqual(@as(u8, 25), cmd.end_of_command.exit_code.?);
}

test "OSC 133: prompt_end" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;B";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .prompt_end);
}

test "OSC 133: end_of_input" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;C";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .end_of_input);
}

test "OSC 133: end_of_input with cmdline 1" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;C;cmdline=echo bobr kurwa";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .end_of_input);
    try testing.expect(cmd.end_of_input.cmdline != null);
    try testing.expectEqualStrings("echo bobr kurwa", cmd.end_of_input.cmdline.?);
}

test "OSC 133: end_of_input with cmdline 2" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;C;cmdline=echo bobr\\ kurwa";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .end_of_input);
    try testing.expect(cmd.end_of_input.cmdline != null);
    try testing.expectEqualStrings("echo bobr kurwa", cmd.end_of_input.cmdline.?);
}

test "OSC 133: end_of_input with cmdline 3" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;C;cmdline=echo bobr\\nkurwa";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .end_of_input);
    try testing.expect(cmd.end_of_input.cmdline != null);
    try testing.expectEqualStrings("echo bobr\nkurwa", cmd.end_of_input.cmdline.?);
}

test "OSC 133: end_of_input with cmdline 4" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;C;cmdline=$'echo bobr kurwa'";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .end_of_input);
    try testing.expect(cmd.end_of_input.cmdline != null);
    try testing.expectEqualStrings("echo bobr kurwa", cmd.end_of_input.cmdline.?);
}

test "OSC 133: end_of_input with cmdline 5" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;C;cmdline='echo bobr kurwa'";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .end_of_input);
    try testing.expect(cmd.end_of_input.cmdline != null);
    try testing.expectEqualStrings("echo bobr kurwa", cmd.end_of_input.cmdline.?);
}

test "OSC 133: end_of_input with cmdline 6" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;C;cmdline='echo bobr kurwa";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .end_of_input);
    try testing.expect(cmd.end_of_input.cmdline == null);
}

test "OSC 133: end_of_input with cmdline 7" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;C;cmdline=$'echo bobr kurwa";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .end_of_input);
    try testing.expect(cmd.end_of_input.cmdline == null);
}

test "OSC 133: end_of_input with cmdline 8" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;C;cmdline=$'";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .end_of_input);
    try testing.expect(cmd.end_of_input.cmdline == null);
}

test "OSC 133: end_of_input with cmdline 9" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;C;cmdline=$'";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .end_of_input);
    try testing.expect(cmd.end_of_input.cmdline == null);
}

test "OSC 133: end_of_input with cmdline 10" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;C;cmdline=";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .end_of_input);
    try testing.expect(cmd.end_of_input.cmdline != null);
    try testing.expectEqualStrings("", cmd.end_of_input.cmdline.?);
}

test "OSC 133: end_of_input with cmdline_url 1" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;C;cmdline_url=echo bobr kurwa";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .end_of_input);
    try testing.expect(cmd.end_of_input.cmdline != null);
    try testing.expectEqualStrings("echo bobr kurwa", cmd.end_of_input.cmdline.?);
}

test "OSC 133: end_of_input with cmdline_url 2" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;C;cmdline_url=echo bobr%20kurwa";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .end_of_input);
    try testing.expect(cmd.end_of_input.cmdline != null);
    try testing.expectEqualStrings("echo bobr kurwa", cmd.end_of_input.cmdline.?);
}

test "OSC 133: end_of_input with cmdline_url 3" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;C;cmdline_url=echo bobr%3bkurwa";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .end_of_input);
    try testing.expect(cmd.end_of_input.cmdline != null);
    try testing.expectEqualStrings("echo bobr;kurwa", cmd.end_of_input.cmdline.?);
}

test "OSC 133: end_of_input with cmdline_url 4" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;C;cmdline_url=echo bobr%3kurwa";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .end_of_input);
    try testing.expect(cmd.end_of_input.cmdline == null);
}

test "OSC 133: end_of_input with cmdline_url 5" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;C;cmdline_url=echo bobr%kurwa";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .end_of_input);
    try testing.expect(cmd.end_of_input.cmdline == null);
}

test "OSC 133: end_of_input with cmdline_url 6" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;C;cmdline_url=echo bobr%kurwa";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .end_of_input);
    try testing.expect(cmd.end_of_input.cmdline == null);
}

test "OSC 133: end_of_input with cmdline_url 7" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;C;cmdline_url=echo bobr kurwa%20";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .end_of_input);
    try testing.expect(cmd.end_of_input.cmdline != null);
    try testing.expectEqualStrings("echo bobr kurwa ", cmd.end_of_input.cmdline.?);
}

test "OSC 133: end_of_input with cmdline_url 8" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;C;cmdline_url=echo bobr kurwa%2";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .end_of_input);
    try testing.expect(cmd.end_of_input.cmdline == null);
}

test "OSC 133: end_of_input with cmdline_url 9" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "133;C;cmdline_url=echo bobr kurwa%2";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .end_of_input);
    try testing.expect(cmd.end_of_input.cmdline == null);
}

test "OSC: OSC 777 show desktop notification with title" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "777;notify;Title;Body";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?.*;
    try testing.expect(cmd == .show_desktop_notification);
    try testing.expectEqualStrings(cmd.show_desktop_notification.title, "Title");
    try testing.expectEqualStrings(cmd.show_desktop_notification.body, "Body");
}
