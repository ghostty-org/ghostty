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
    /// Optional allocator used to accept data longer than MAX_BUF.
    /// This only applies to some commands (e.g. OSC 52) that can
    /// reasonably exceed MAX_BUF.
    alloc: ?Allocator,

    /// Current state of the parser.
    state: State,

    /// Current command of the parser, this accumulates.
    command: Command,

    /// Buffer that stores the input we see for a single OSC command.
    /// Slices in Command are offsets into this buffer.
    buf: [MAX_BUF]u8,
    buf_start: usize,
    buf_idx: usize,
    buf_dynamic: ?*std.ArrayListUnmanaged(u8),

    /// True when a command is complete/valid to return.
    complete: bool,

    /// Temporary state that is dependent on the current state.
    temp_state: union {
        /// Current string parameter being populated
        str: *[:0]const u8,

        /// Current numeric parameter being populated
        num: u16,

        /// Temporary state for key/value pairs
        key: []const u8,
    },

    // Maximum length of a single OSC command. This is the full OSC command
    // sequence length (excluding ESC ]). This is arbitrary, I couldn't find
    // any definitive resource on how long this should be.
    //
    // NOTE: This does mean certain OSC sequences such as OSC 8 (hyperlinks)
    //       won't work if their parameters are larger than fit in the buffer.
    const MAX_BUF = 2048;

    pub const State = enum {
        empty,
        invalid,
        swallow,

        // Command prefixes. We could just accumulate and compare (mem.eql)
        // but the state space is small enough that we just build it up this way.
        @"0",
        @"1",
        @"10",
        @"104",
        @"11",
        @"12",
        @"13",
        @"133",
        @"14",
        @"15",
        @"16",
        @"17",
        @"18",
        @"19",
        @"2",
        @"21",
        @"22",
        @"4",
        @"5",
        @"52",
        @"7",
        @"77",
        @"777",
        @"8",
        @"9",

        // We're in a semantic prompt OSC command but we aren't sure
        // what the command is yet, i.e. `133;`
        semantic_prompt,
        semantic_option_start,
        semantic_option_key,
        semantic_option_value,
        semantic_exit_code_start,
        semantic_exit_code,

        // Get/set clipboard states
        clipboard_kind,
        clipboard_kind_end,

        // OSC color operation.
        osc_color,

        // Hyperlinks
        hyperlink_param_key,
        hyperlink_param_value,
        hyperlink_uri,

        // rxvt extension. Only used for OSC 777 and only the value "notify" is
        // supported
        rxvt_extension,

        // Title of a desktop notification
        notification_title,

        // Expect a string parameter. param_str must be set as well as
        // buf_start.
        string,

        // A string that can grow beyond MAX_BUF. This uses the allocator.
        // If the parser has no allocator then it is treated as if the
        // buffer is full.
        allocable_string,

        // Kitty color protocol
        // https://sw.kovidgoyal.net/kitty/color-stack/#id1
        kitty_color_protocol_key,
        kitty_color_protocol_value,

        // OSC 9 is used by ConEmu and iTerm2 for different things.
        // iTerm2 uses it to post a notification[1].
        // ConEmu uses it to implement many custom functions[2].
        //
        // Some Linux applications (namely systemd and flatpak) have
        // adopted the ConEmu implementation but this causes bogus
        // notifications on iTerm2 compatible terminal emulators.
        //
        // Ghostty supports both by disallowing ConEmu-specific commands
        // from being shown as desktop notifications.
        //
        // [1]: https://iterm2.com/documentation-escape-codes.html
        // [2]: https://conemu.github.io/en/AnsiEscapeCodes.html#OSC_Operating_system_commands
        osc_9,

        // ConEmu specific substates
        conemu_sleep,
        conemu_sleep_value,
        conemu_message_box,
        conemu_tab,
        conemu_tab_txt,
        conemu_progress_prestate,
        conemu_progress_state,
        conemu_progress_prevalue,
        conemu_progress_value,
        conemu_guimacro,
    };

    pub fn init(alloc: ?Allocator) Parser {
        var result: Parser = .{
            .alloc = alloc,
            .state = .empty,
            .command = .invalid,
            .buf_start = 0,
            .buf_idx = 0,
            .buf_dynamic = null,
            .complete = false,

            // Keeping all our undefined values together so we can
            // visually easily duplicate them in the Valgrind check below.
            .buf = undefined,
            .temp_state = undefined,
        };
        if (std.valgrind.runningOnValgrind() > 0) {
            // Initialize our undefined fields so Valgrind can catch it.
            // https://github.com/ziglang/zig/issues/19148
            result.buf = undefined;
            result.temp_state = undefined;
        }

        return result;
    }

    /// This must be called to clean up any allocated memory.
    pub fn deinit(self: *Parser) void {
        self.reset();
    }

    /// Reset the parser state.
    pub fn reset(self: *Parser) void {
        // If the state is already empty then we do nothing because
        // we may touch uninitialized memory.
        if (self.state == .empty) {
            assert(self.buf_start == 0);
            assert(self.buf_idx == 0);
            assert(!self.complete);
            assert(self.buf_dynamic == null);
            return;
        }

        // Some commands have their own memory management we need to clear.
        switch (self.command) {
            .kitty_color_protocol => |*v| v.list.deinit(self.alloc.?),
            .color_operation => |*v| v.requests.deinit(self.alloc.?),
            else => {},
        }

        self.state = .empty;
        self.buf_start = 0;
        self.buf_idx = 0;
        self.command = .invalid;
        self.complete = false;
        if (self.buf_dynamic) |ptr| {
            const alloc = self.alloc.?;
            ptr.deinit(alloc);
            alloc.destroy(ptr);
            self.buf_dynamic = null;
        }
    }

    /// Consume the next character c and advance the parser state.
    pub fn next(self: *Parser, c: u8) void {
        // If our buffer is full then we're invalid, so we set our state
        // accordingly and indicate the sequence is incomplete so that we
        // don't accidentally issue a command when ending.
        //
        // We always keep space for 1 byte at the end to null-terminate
        // values.
        if (self.buf_idx >= self.buf.len - 1) {
            @branchHint(.cold);
            if (self.state != .invalid) {
                log.warn(
                    "OSC sequence too long (> {d}), ignoring. state={}",
                    .{ self.buf.len, self.state },
                );
            }

            self.state = .invalid;

            // We have to do this here because it will never reach the
            // switch statement below, since our buf_idx will always be
            // too high after this.
            self.complete = false;
            return;
        }

        // We store everything in the buffer so we can do a better job
        // logging if we get to an invalid command.
        self.buf[self.buf_idx] = c;
        self.buf_idx += 1;

        // log.warn("state = {} c = {x}", .{ self.state, c });

        switch (self.state) {
            // If we get something during the invalid state, we've
            // ruined our entry.
            .invalid => self.complete = false,

            .empty => switch (c) {
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

            .swallow => {},

            .@"0" => switch (c) {
                ';' => {
                    self.command = .{ .change_window_title = undefined };
                    self.complete = true;
                    self.state = .string;
                    self.temp_state = .{ .str = &self.command.change_window_title };
                    self.buf_start = self.buf_idx;
                },
                else => self.state = .invalid,
            },

            .@"1" => switch (c) {
                ';' => {
                    self.command = .{ .change_window_icon = undefined };

                    self.state = .string;
                    self.temp_state = .{ .str = &self.command.change_window_icon };
                    self.buf_start = self.buf_idx;
                },
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
                ';' => osc_10: {
                    if (self.alloc == null) {
                        log.warn("OSC 10 requires an allocator, but none was provided", .{});
                        self.state = .invalid;
                        break :osc_10;
                    }
                    self.command = .{ .color_operation = .{
                        .op = .osc_10,
                    } };
                    self.state = .osc_color;
                    self.buf_start = self.buf_idx;
                    self.complete = true;
                },
                '4' => {
                    self.state = .@"104";
                    // If we have an allocator, then we can complete the OSC104
                    if (self.alloc != null) self.complete = true;
                },
                else => self.state = .invalid,
            },

            .@"104" => switch (c) {
                ';' => osc_104: {
                    if (self.alloc == null) {
                        log.warn("OSC 104 requires an allocator, but none was provided", .{});
                        self.state = .invalid;
                        break :osc_104;
                    }
                    self.command = .{
                        .color_operation = .{
                            .op = .osc_104,
                        },
                    };
                    self.state = .osc_color;
                    self.buf_start = self.buf_idx;
                    self.complete = true;
                },
                else => self.state = .invalid,
            },

            .@"11" => switch (c) {
                ';' => osc_11: {
                    if (self.alloc == null) {
                        log.warn("OSC 11 requires an allocator, but none was provided", .{});
                        self.state = .invalid;
                        break :osc_11;
                    }
                    self.command = .{ .color_operation = .{
                        .op = .osc_11,
                    } };
                    self.state = .osc_color;
                    self.buf_start = self.buf_idx;
                    self.complete = true;
                },
                '0'...'9' => blk: {
                    if (self.alloc == null) {
                        log.warn("OSC 11{c} requires an allocator, but none was provided", .{c});
                        self.state = .invalid;
                        break :blk;
                    }

                    self.command = .{
                        .color_operation = .{
                            .op = switch (c) {
                                '0' => .osc_110,
                                '1' => .osc_111,
                                '2' => .osc_112,
                                '3' => .osc_113,
                                '4' => .osc_114,
                                '5' => .osc_115,
                                '6' => .osc_116,
                                '7' => .osc_117,
                                '8' => .osc_118,
                                '9' => .osc_119,
                                else => unreachable,
                            },
                        },
                    };
                    self.state = .osc_color;
                    self.buf_start = self.buf_idx;
                    self.complete = true;
                },
                else => self.state = .invalid,
            },

            .@"12" => switch (c) {
                ';' => osc_12: {
                    if (self.alloc == null) {
                        log.warn("OSC 12 requires an allocator, but none was provided", .{});
                        self.state = .invalid;
                        break :osc_12;
                    }
                    self.command = .{ .color_operation = .{
                        .op = .osc_12,
                    } };
                    self.state = .osc_color;
                    self.buf_start = self.buf_idx;
                    self.complete = true;
                },
                else => self.state = .invalid,
            },

            .@"13" => switch (c) {
                ';' => osc_13: {
                    if (self.alloc == null) {
                        log.warn("OSC 13 requires an allocator, but none was provided", .{});
                        self.state = .invalid;
                        break :osc_13;
                    }
                    self.command = .{ .color_operation = .{
                        .op = .osc_13,
                    } };
                    self.state = .osc_color;
                    self.buf_start = self.buf_idx;
                    self.complete = true;
                },
                '3' => self.state = .@"133",
                else => self.state = .invalid,
            },

            .@"133" => switch (c) {
                ';' => self.state = .semantic_prompt,
                else => self.state = .invalid,
            },

            .@"14" => switch (c) {
                ';' => osc_14: {
                    if (self.alloc == null) {
                        log.warn("OSC 14 requires an allocator, but none was provided", .{});
                        self.state = .invalid;
                        break :osc_14;
                    }
                    self.command = .{ .color_operation = .{
                        .op = .osc_14,
                    } };
                    self.state = .osc_color;
                    self.buf_start = self.buf_idx;
                    self.complete = true;
                },
                else => self.state = .invalid,
            },

            .@"15" => switch (c) {
                ';' => osc_15: {
                    if (self.alloc == null) {
                        log.warn("OSC 15 requires an allocator, but none was provided", .{});
                        self.state = .invalid;
                        break :osc_15;
                    }
                    self.command = .{ .color_operation = .{
                        .op = .osc_15,
                    } };
                    self.state = .osc_color;
                    self.buf_start = self.buf_idx;
                    self.complete = true;
                },
                else => self.state = .invalid,
            },

            .@"16" => switch (c) {
                ';' => osc_16: {
                    if (self.alloc == null) {
                        log.warn("OSC 16 requires an allocator, but none was provided", .{});
                        self.state = .invalid;
                        break :osc_16;
                    }
                    self.command = .{ .color_operation = .{
                        .op = .osc_16,
                    } };
                    self.state = .osc_color;
                    self.buf_start = self.buf_idx;
                    self.complete = true;
                },
                else => self.state = .invalid,
            },

            .@"17" => switch (c) {
                ';' => osc_17: {
                    if (self.alloc == null) {
                        log.warn("OSC 17 requires an allocator, but none was provided", .{});
                        self.state = .invalid;
                        break :osc_17;
                    }
                    self.command = .{ .color_operation = .{
                        .op = .osc_17,
                    } };
                    self.state = .osc_color;
                    self.buf_start = self.buf_idx;
                    self.complete = true;
                },
                else => self.state = .invalid,
            },

            .@"18" => switch (c) {
                ';' => osc_18: {
                    if (self.alloc == null) {
                        log.warn("OSC 18 requires an allocator, but none was provided", .{});
                        self.state = .invalid;
                        break :osc_18;
                    }
                    self.command = .{ .color_operation = .{
                        .op = .osc_18,
                    } };
                    self.state = .osc_color;
                    self.buf_start = self.buf_idx;
                    self.complete = true;
                },
                else => self.state = .invalid,
            },

            .@"19" => switch (c) {
                ';' => osc_19: {
                    if (self.alloc == null) {
                        log.warn("OSC 19 requires an allocator, but none was provided", .{});
                        self.state = .invalid;
                        break :osc_19;
                    }
                    self.command = .{ .color_operation = .{
                        .op = .osc_19,
                    } };
                    self.state = .osc_color;
                    self.buf_start = self.buf_idx;
                    self.complete = true;
                },
                else => self.state = .invalid,
            },

            .osc_color => {},

            .@"2" => switch (c) {
                '1' => self.state = .@"21",
                '2' => self.state = .@"22",
                ';' => {
                    self.command = .{ .change_window_title = undefined };
                    self.complete = true;
                    self.state = .string;
                    self.temp_state = .{ .str = &self.command.change_window_title };
                    self.buf_start = self.buf_idx;
                },
                else => self.state = .invalid,
            },

            .@"21" => switch (c) {
                ';' => kitty: {
                    if (self.alloc == null) {
                        log.info("OSC 21 requires an allocator, but none was provided", .{});
                        self.state = .invalid;
                        break :kitty;
                    }

                    self.command = .{
                        .kitty_color_protocol = .{
                            .list = .empty,
                        },
                    };

                    self.temp_state = .{ .key = "" };
                    self.state = .kitty_color_protocol_key;
                    self.complete = true;
                    self.buf_start = self.buf_idx;
                },
                else => self.state = .invalid,
            },

            .kitty_color_protocol_key => switch (c) {
                ';' => {
                    self.temp_state = .{ .key = self.buf[self.buf_start .. self.buf_idx - 1] };
                    self.endKittyColorProtocolOption(.key_only, false);
                    self.state = .kitty_color_protocol_key;
                    self.buf_start = self.buf_idx;
                },
                '=' => {
                    self.temp_state = .{ .key = self.buf[self.buf_start .. self.buf_idx - 1] };
                    self.state = .kitty_color_protocol_value;
                    self.buf_start = self.buf_idx;
                },
                else => {},
            },

            .kitty_color_protocol_value => switch (c) {
                ';' => {
                    self.endKittyColorProtocolOption(.key_and_value, false);
                    self.state = .kitty_color_protocol_key;
                    self.buf_start = self.buf_idx;
                },
                else => {},
            },

            .@"22" => switch (c) {
                ';' => {
                    self.command = .{ .mouse_shape = undefined };

                    self.state = .string;
                    self.temp_state = .{ .str = &self.command.mouse_shape.value };
                    self.buf_start = self.buf_idx;
                },
                else => self.state = .invalid,
            },

            .@"4" => switch (c) {
                ';' => osc_4: {
                    if (self.alloc == null) {
                        log.info("OSC 4 requires an allocator, but none was provided", .{});
                        self.state = .invalid;
                        break :osc_4;
                    }
                    self.command = .{
                        .color_operation = .{
                            .op = .osc_4,
                        },
                    };
                    self.state = .osc_color;
                    self.buf_start = self.buf_idx;
                    self.complete = true;
                },
                else => self.state = .invalid,
            },

            .@"5" => switch (c) {
                ';' => osc_5: {
                    if (self.alloc == null) {
                        log.info("OSC 5 requires an allocator, but none was provided", .{});
                        self.state = .invalid;
                        break :osc_5;
                    }
                    self.command = .{
                        .color_operation = .{
                            .op = .osc_5,
                        },
                    };
                    self.state = .osc_color;
                    self.buf_start = self.buf_idx;
                    self.complete = true;
                },
                '2' => self.state = .@"52",
                else => self.state = .invalid,
            },

            .@"52" => switch (c) {
                ';' => {
                    self.command = .{ .clipboard_contents = undefined };
                    self.state = .clipboard_kind;
                },
                else => self.state = .invalid,
            },

            .clipboard_kind => switch (c) {
                ';' => {
                    self.command.clipboard_contents.kind = 'c';
                    self.temp_state = .{ .str = &self.command.clipboard_contents.data };
                    self.buf_start = self.buf_idx;
                    self.prepAllocableString();

                    // See clipboard_kind_end
                    self.complete = true;
                },
                else => {
                    self.command.clipboard_contents.kind = c;
                    self.state = .clipboard_kind_end;
                },
            },

            .clipboard_kind_end => switch (c) {
                ';' => {
                    self.temp_state = .{ .str = &self.command.clipboard_contents.data };
                    self.buf_start = self.buf_idx;
                    self.prepAllocableString();

                    // OSC 52 can have empty payloads (quoting xterm ctlseqs):
                    // "If the second parameter is neither a base64 string nor ?,
                    // then the selection is cleared."
                    self.complete = true;
                },
                else => self.state = .invalid,
            },

            .@"7" => switch (c) {
                ';' => {
                    self.command = .{ .report_pwd = .{ .value = "" } };
                    self.complete = true;
                    self.state = .string;
                    self.temp_state = .{ .str = &self.command.report_pwd.value };
                    self.buf_start = self.buf_idx;
                },
                '7' => self.state = .@"77",
                else => self.state = .invalid,
            },

            .@"77" => switch (c) {
                '7' => self.state = .@"777",
                else => self.state = .invalid,
            },

            .@"777" => switch (c) {
                ';' => {
                    self.state = .rxvt_extension;
                    self.buf_start = self.buf_idx;
                },
                else => self.state = .invalid,
            },

            .@"8" => switch (c) {
                ';' => {
                    self.command = .{ .hyperlink_start = .{
                        .uri = "",
                    } };

                    self.state = .hyperlink_param_key;
                    self.buf_start = self.buf_idx;
                },
                else => self.state = .invalid,
            },

            .hyperlink_param_key => switch (c) {
                ';' => {
                    self.complete = true;
                    self.state = .hyperlink_uri;
                    self.buf_start = self.buf_idx;
                },
                '=' => {
                    self.temp_state = .{ .key = self.buf[self.buf_start .. self.buf_idx - 1] };
                    self.state = .hyperlink_param_value;
                    self.buf_start = self.buf_idx;
                },
                else => {},
            },

            .hyperlink_param_value => switch (c) {
                ':' => {
                    self.endHyperlinkOptionValue();
                    self.state = .hyperlink_param_key;
                    self.buf_start = self.buf_idx;
                },
                ';' => {
                    self.endHyperlinkOptionValue();
                    self.state = .string;
                    self.temp_state = .{ .str = &self.command.hyperlink_start.uri };
                    self.buf_start = self.buf_idx;
                },
                else => {},
            },

            .hyperlink_uri => {},

            .rxvt_extension => switch (c) {
                'a'...'z' => {},
                ';' => {
                    const ext = self.buf[self.buf_start .. self.buf_idx - 1];
                    if (!std.mem.eql(u8, ext, "notify")) {
                        @branchHint(.cold);
                        log.warn("unknown rxvt extension: {s}", .{ext});
                        self.state = .invalid;
                        return;
                    }

                    self.command = .{ .show_desktop_notification = undefined };
                    self.buf_start = self.buf_idx;
                    self.state = .notification_title;
                },
                else => self.state = .invalid,
            },

            .notification_title => switch (c) {
                ';' => {
                    self.buf[self.buf_idx - 1] = 0;
                    self.command.show_desktop_notification.title = self.buf[self.buf_start .. self.buf_idx - 1 :0];
                    self.temp_state = .{ .str = &self.command.show_desktop_notification.body };
                    self.buf_start = self.buf_idx;
                    self.state = .string;
                },
                else => {},
            },

            .@"9" => switch (c) {
                ';' => {
                    self.buf_start = self.buf_idx;
                    self.state = .osc_9;
                },
                else => self.state = .invalid,
            },

            .osc_9 => switch (c) {
                '1' => {
                    self.state = .conemu_sleep;
                    // This will end up being either a ConEmu sleep OSC 9;1,
                    // or a desktop notification OSC 9 that begins with '1', so
                    // mark as complete.
                    self.complete = true;
                },
                '2' => {
                    self.state = .conemu_message_box;
                    // This will end up being either a ConEmu message box OSC 9;2,
                    // or a desktop notification OSC 9 that begins with '2', so
                    // mark as complete.
                    self.complete = true;
                },
                '3' => {
                    self.state = .conemu_tab;
                    // This will end up being either a ConEmu message box OSC 9;3,
                    // or a desktop notification OSC 9 that begins with '3', so
                    // mark as complete.
                    self.complete = true;
                },
                '4' => {
                    self.state = .conemu_progress_prestate;
                    // This will end up being either a ConEmu progress report
                    // OSC 9;4, or a desktop notification OSC 9 that begins with
                    // '4', so mark as complete.
                    self.complete = true;
                },
                '5' => {
                    // Note that sending an OSC 9 desktop notification that
                    // starts with 5 is impossible due to this.
                    self.state = .swallow;
                    self.command = .conemu_wait_input;
                    self.complete = true;
                },
                '6' => {
                    self.state = .conemu_guimacro;
                    // This will end up being either a ConEmu GUI macro OSC 9;6,
                    // or a desktop notification OSC 9 that begins with '6', so
                    // mark as complete.
                    self.complete = true;
                },

                // Todo: parse out other ConEmu operating system commands. Even
                // if we don't support them we probably don't want them showing
                // up as desktop notifications.

                else => self.showDesktopNotification(),
            },

            .conemu_sleep => switch (c) {
                ';' => {
                    self.command = .{ .conemu_sleep = .{ .duration_ms = 100 } };
                    self.buf_start = self.buf_idx;
                    self.complete = true;
                    self.state = .conemu_sleep_value;
                },

                // OSC 9;1 <something other than semicolon> is a desktop
                // notification.
                else => self.showDesktopNotification(),
            },

            .conemu_sleep_value => switch (c) {
                else => self.complete = true,
            },

            .conemu_message_box => switch (c) {
                ';' => {
                    self.command = .{ .conemu_show_message_box = undefined };
                    self.temp_state = .{ .str = &self.command.conemu_show_message_box };
                    self.buf_start = self.buf_idx;
                    self.complete = true;
                    self.prepAllocableString();
                },

                // OSC 9;2 <something other than semicolon> is a desktop
                // notification.
                else => self.showDesktopNotification(),
            },

            .conemu_tab => switch (c) {
                ';' => {
                    self.state = .conemu_tab_txt;
                    self.command = .{ .conemu_change_tab_title = .reset };
                    self.buf_start = self.buf_idx;
                    self.complete = true;
                },

                // OSC 9;3 <something other than semicolon> is a desktop
                // notification.
                else => self.showDesktopNotification(),
            },

            .conemu_tab_txt => {
                self.command = .{ .conemu_change_tab_title = .{ .value = undefined } };
                self.temp_state = .{ .str = &self.command.conemu_change_tab_title.value };
                self.complete = true;
                self.prepAllocableString();
            },

            .conemu_progress_prestate => switch (c) {
                ';' => {
                    self.command = .{ .conemu_progress_report = .{
                        .state = undefined,
                    } };
                    self.state = .conemu_progress_state;
                },

                // OSC 9;4 <something other than semicolon> is a desktop
                // notification.
                else => self.showDesktopNotification(),
            },

            .conemu_progress_state => switch (c) {
                '0' => {
                    self.command.conemu_progress_report.state = .remove;
                    self.state = .swallow;
                    self.complete = true;
                },
                '1' => {
                    self.command.conemu_progress_report.state = .set;
                    self.command.conemu_progress_report.progress = 0;
                    self.state = .conemu_progress_prevalue;
                },
                '2' => {
                    self.command.conemu_progress_report.state = .@"error";
                    self.complete = true;
                    self.state = .conemu_progress_prevalue;
                },
                '3' => {
                    self.command.conemu_progress_report.state = .indeterminate;
                    self.complete = true;
                    self.state = .swallow;
                },
                '4' => {
                    self.command.conemu_progress_report.state = .pause;
                    self.complete = true;
                    self.state = .conemu_progress_prevalue;
                },

                // OSC 9;4; <something other than 0-4> is a desktop
                // notification.
                else => self.showDesktopNotification(),
            },

            .conemu_progress_prevalue => switch (c) {
                ';' => {
                    self.state = .conemu_progress_value;
                },

                // OSC 9;4;<0-4> <something other than semicolon> is a desktop
                // notification.
                else => self.showDesktopNotification(),
            },

            .conemu_progress_value => switch (c) {
                '0'...'9' => value: {
                    // No matter what substate we're in, a number indicates
                    // a completed ConEmu progress command.
                    self.complete = true;

                    // If we aren't a set substate, then we don't care
                    // about the value.
                    const p = &self.command.conemu_progress_report;
                    switch (p.state) {
                        .remove,
                        .indeterminate,
                        => break :value,
                        .set,
                        .@"error",
                        .pause,
                        => {},
                    }

                    if (p.state == .set)
                        assert(p.progress != null)
                    else if (p.progress == null)
                        p.progress = 0;

                    // If we're over 100% we're done.
                    if (p.progress.? >= 100) break :value;

                    // If we're over 10 then any new digit forces us to
                    // be 100.
                    if (p.progress.? >= 10)
                        p.progress = 100
                    else {
                        const d = std.fmt.charToDigit(c, 10) catch 0;
                        p.progress = @min(100, (p.progress.? * 10) + d);
                    }
                },

                else => {
                    self.state = .swallow;
                    self.complete = true;
                },
            },

            .conemu_guimacro => switch (c) {
                ';' => {
                    self.command = .{ .conemu_guimacro = undefined };
                    self.temp_state = .{ .str = &self.command.conemu_guimacro };
                    self.buf_start = self.buf_idx;
                    self.state = .string;
                    self.complete = true;
                },

                // OSC 9;6 <something other than semicolon> is a desktop
                // notification.
                else => self.showDesktopNotification(),
            },

            .semantic_prompt => switch (c) {
                'A' => {
                    self.state = .semantic_option_start;
                    self.command = .{ .prompt_start = .{} };
                    self.complete = true;
                },

                'B' => {
                    self.state = .semantic_option_start;
                    self.command = .{ .prompt_end = {} };
                    self.complete = true;
                },

                'C' => {
                    self.state = .semantic_option_start;
                    self.command = .{ .end_of_input = .{} };
                    self.complete = true;
                },

                'D' => {
                    self.state = .semantic_exit_code_start;
                    self.command = .{ .end_of_command = .{} };
                    self.complete = true;
                },

                else => self.state = .invalid,
            },

            .semantic_option_start => switch (c) {
                ';' => {
                    self.state = .semantic_option_key;
                    self.buf_start = self.buf_idx;
                },
                else => self.state = .invalid,
            },

            .semantic_option_key => switch (c) {
                '=' => {
                    self.temp_state = .{ .key = self.buf[self.buf_start .. self.buf_idx - 1] };
                    self.state = .semantic_option_value;
                    self.buf_start = self.buf_idx;
                },
                else => {},
            },

            .semantic_option_value => switch (c) {
                ';' => {
                    self.endSemanticOptionValue();
                    self.state = .semantic_option_key;
                    self.buf_start = self.buf_idx;
                },
                else => {},
            },

            .semantic_exit_code_start => switch (c) {
                ';' => {
                    // No longer complete, if ';' shows up we expect some code.
                    self.complete = false;
                    self.state = .semantic_exit_code;
                    self.temp_state = .{ .num = 0 };
                    self.buf_start = self.buf_idx;
                },
                else => self.state = .invalid,
            },

            .semantic_exit_code => switch (c) {
                '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' => {
                    self.complete = true;

                    const idx = self.buf_idx - self.buf_start;
                    if (idx > 0) self.temp_state.num *|= 10;
                    self.temp_state.num +|= c - '0';
                },
                ';' => {
                    self.endSemanticExitCode();
                    self.state = .semantic_option_key;
                    self.buf_start = self.buf_idx;
                },
                else => self.state = .invalid,
            },

            .allocable_string => {
                const alloc = self.alloc.?;
                const list = self.buf_dynamic.?;
                list.append(alloc, c) catch {
                    self.state = .invalid;
                    return;
                };

                // Never consume buffer space for allocable strings
                self.buf_idx -= 1;

                // We can complete at any time
                self.complete = true;
            },

            .string => self.complete = true,
        }
    }

    fn showDesktopNotification(self: *Parser) void {
        self.command = .{ .show_desktop_notification = .{
            .title = "",
            .body = undefined,
        } };

        self.temp_state = .{ .str = &self.command.show_desktop_notification.body };
        self.state = .string;
        // Set as complete as we've already seen one character that should be
        // part of the notification. If we wait for another character to set
        // `complete` when the state is `.string` we won't be able to send any
        // single character notifications.
        self.complete = true;
    }

    fn prepAllocableString(self: *Parser) void {
        assert(self.buf_dynamic == null);

        // We need an allocator. If we don't have an allocator, we
        // pretend we're just a fixed buffer string and hope we fit!
        const alloc = self.alloc orelse {
            self.state = .string;
            return;
        };

        // Allocate our dynamic buffer
        const list = alloc.create(std.ArrayListUnmanaged(u8)) catch {
            self.state = .string;
            return;
        };
        list.* = .{};

        self.buf_dynamic = list;
        self.state = .allocable_string;
    }

    fn endHyperlink(self: *Parser) void {
        switch (self.command) {
            .hyperlink_start => |*v| {
                self.buf[self.buf_idx] = 0;
                const value = self.buf[self.buf_start..self.buf_idx :0];
                if (v.id == null and value.len == 0) {
                    self.command = .{ .hyperlink_end = {} };
                    return;
                }

                v.uri = value;
            },

            else => unreachable,
        }
    }

    fn endHyperlinkOptionValue(self: *Parser) void {
        const value: [:0]const u8 = if (self.buf_start == self.buf_idx)
            ""
        else buf: {
            self.buf[self.buf_idx - 1] = 0;
            break :buf self.buf[self.buf_start .. self.buf_idx - 1 :0];
        };

        if (mem.eql(u8, self.temp_state.key, "id")) {
            switch (self.command) {
                .hyperlink_start => |*v| {
                    // We treat empty IDs as null ids so that we can
                    // auto-assign.
                    if (value.len > 0) v.id = value;
                },
                else => {},
            }
        } else log.info("unknown hyperlink option: {s}", .{self.temp_state.key});
    }

    fn endSemanticOptionValue(self: *Parser) void {
        const value = value: {
            self.buf[self.buf_idx] = 0;
            defer self.buf_idx += 1;
            break :value self.buf[self.buf_start..self.buf_idx :0];
        };

        if (mem.eql(u8, self.temp_state.key, "aid")) {
            switch (self.command) {
                .prompt_start => |*v| v.aid = value,
                else => {},
            }
        } else if (mem.eql(u8, self.temp_state.key, "cmdline")) {
            // https://sw.kovidgoyal.net/kitty/shell-integration/#notes-for-shell-developers
            switch (self.command) {
                .end_of_input => |*v| v.cmdline = string_encoding.printfQDecode(value) catch null,
                else => {},
            }
        } else if (mem.eql(u8, self.temp_state.key, "cmdline_url")) {
            // https://sw.kovidgoyal.net/kitty/shell-integration/#notes-for-shell-developers
            switch (self.command) {
                .end_of_input => |*v| v.cmdline = string_encoding.urlPercentDecode(value) catch null,
                else => {},
            }
        } else if (mem.eql(u8, self.temp_state.key, "redraw")) {
            // https://sw.kovidgoyal.net/kitty/shell-integration/#notes-for-shell-developers
            switch (self.command) {
                .prompt_start => |*v| {
                    const valid = if (value.len == 1) valid: {
                        switch (value[0]) {
                            '0' => v.redraw = false,
                            '1' => v.redraw = true,
                            else => break :valid false,
                        }

                        break :valid true;
                    } else false;

                    if (!valid) {
                        log.info("OSC 133 A invalid redraw value: {s}", .{value});
                    }
                },
                else => {},
            }
        } else if (mem.eql(u8, self.temp_state.key, "special_key")) {
            // https://sw.kovidgoyal.net/kitty/shell-integration/#notes-for-shell-developers
            switch (self.command) {
                .prompt_start => |*v| {
                    const valid = if (value.len == 1) valid: {
                        switch (value[0]) {
                            '0' => v.special_key = false,
                            '1' => v.special_key = true,
                            else => break :valid false,
                        }

                        break :valid true;
                    } else false;

                    if (!valid) {
                        log.info("OSC 133 A invalid special_key value: {s}", .{value});
                    }
                },
                else => {},
            }
        } else if (mem.eql(u8, self.temp_state.key, "click_events")) {
            // https://sw.kovidgoyal.net/kitty/shell-integration/#notes-for-shell-developers
            switch (self.command) {
                .prompt_start => |*v| {
                    const valid = if (value.len == 1) valid: {
                        switch (value[0]) {
                            '0' => v.click_events = false,
                            '1' => v.click_events = true,
                            else => break :valid false,
                        }

                        break :valid true;
                    } else false;

                    if (!valid) {
                        log.info("OSC 133 A invalid click_events value: {s}", .{value});
                    }
                },
                else => {},
            }
        } else if (mem.eql(u8, self.temp_state.key, "k")) {
            // https://sw.kovidgoyal.net/kitty/shell-integration/#notes-for-shell-developers
            // The "k" marks the kind of prompt, or "primary" if we don't know.
            // This can be used to distinguish between the first (initial) prompt,
            // a continuation, etc.
            switch (self.command) {
                .prompt_start => |*v| if (value.len == 1) {
                    v.kind = switch (value[0]) {
                        'c' => .continuation,
                        's' => .secondary,
                        'r' => .right,
                        'i' => .primary,
                        else => .primary,
                    };
                },
                else => {},
            }
        } else log.info("unknown semantic prompts option: {s}", .{self.temp_state.key});
    }

    fn endSemanticExitCode(self: *Parser) void {
        switch (self.command) {
            .end_of_command => |*v| v.exit_code = @truncate(self.temp_state.num),
            else => {},
        }
    }

    fn endString(self: *Parser) void {
        self.buf[self.buf_idx] = 0;
        defer self.buf_idx += 1;
        self.temp_state.str.* = self.buf[self.buf_start..self.buf_idx :0];
    }

    fn endConEmuSleepValue(self: *Parser) void {
        switch (self.command) {
            .conemu_sleep => |*v| v.duration_ms = value: {
                const str = self.buf[self.buf_start..self.buf_idx];
                if (str.len == 0) break :value 100;

                if (std.fmt.parseUnsigned(u16, str, 10)) |num| {
                    break :value @min(num, 10_000);
                } else |_| {
                    break :value 100;
                }
            },
            else => {},
        }
    }

    fn endKittyColorProtocolOption(self: *Parser, kind: enum { key_only, key_and_value }, final: bool) void {
        if (self.temp_state.key.len == 0) {
            @branchHint(.cold);
            log.warn("zero length key in kitty color protocol", .{});
            return;
        }

        const key = kitty_color.Kind.parse(self.temp_state.key) orelse {
            @branchHint(.cold);
            log.warn("unknown key in kitty color protocol: {s}", .{self.temp_state.key});
            return;
        };

        const value = value: {
            if (self.buf_start == self.buf_idx) break :value "";
            if (final) break :value std.mem.trim(u8, self.buf[self.buf_start..self.buf_idx], " ");
            break :value std.mem.trim(u8, self.buf[self.buf_start .. self.buf_idx - 1], " ");
        };

        switch (self.command) {
            .kitty_color_protocol => |*v| {
                // Cap our allocation amount for our list.
                if (v.list.items.len >= @as(usize, kitty_color.Kind.max) * 2) {
                    @branchHint(.cold);
                    self.state = .invalid;
                    log.warn("exceeded limit for number of keys in kitty color protocol, ignoring", .{});
                    return;
                }

                // Asserted when the command is set to kitty_color_protocol
                // that we have an allocator.
                const alloc = self.alloc.?;

                if (kind == .key_only or value.len == 0) {
                    v.list.append(alloc, .{ .reset = key }) catch |err| {
                        @branchHint(.cold);
                        log.warn("unable to append kitty color protocol option: {}", .{err});
                        return;
                    };
                } else if (mem.eql(u8, "?", value)) {
                    v.list.append(alloc, .{ .query = key }) catch |err| {
                        @branchHint(.cold);
                        log.warn("unable to append kitty color protocol option: {}", .{err});
                        return;
                    };
                } else {
                    v.list.append(alloc, .{
                        .set = .{
                            .key = key,
                            .color = RGB.parse(value) catch |err| switch (err) {
                                error.InvalidFormat => {
                                    log.warn("invalid color format in kitty color protocol: {s}", .{value});
                                    return;
                                },
                            },
                        },
                    }) catch |err| {
                        @branchHint(.cold);
                        log.warn("unable to append kitty color protocol option: {}", .{err});
                        return;
                    };
                }
            },
            else => {},
        }
    }

    fn endOscColor(self: *Parser) void {
        const alloc = self.alloc.?;
        assert(self.command == .color_operation);
        const data = self.buf[self.buf_start..self.buf_idx];
        self.command.color_operation.requests = osc_color.parse(
            alloc,
            self.command.color_operation.op,
            data,
        ) catch |err| list: {
            log.info(
                "failed to parse OSC color request err={} data={s}",
                .{ err, data },
            );
            break :list .{};
        };
    }

    fn endAllocableString(self: *Parser) void {
        const alloc = self.alloc.?;
        const list = self.buf_dynamic.?;
        list.append(alloc, 0) catch {
            @branchHint(.cold);
            log.warn("allocation failed on allocable string termination", .{});
            self.temp_state.str.* = "";
            return;
        };

        self.temp_state.str.* = list.items[0 .. list.items.len - 1 :0];
    }

    /// End the sequence and return the command, if any. If the return value
    /// is null, then no valid command was found. The optional terminator_ch
    /// is the final character in the OSC sequence. This is used to determine
    /// the response terminator.
    ///
    /// The returned pointer is only valid until the next call to the parser.
    /// Callers should copy out any data they wish to retain across calls.
    pub fn end(self: *Parser, terminator_ch: ?u8) ?*Command {
        if (!self.complete) {
            if (comptime !builtin.is_test) log.warn(
                "invalid OSC command: {s}",
                .{self.buf[0..self.buf_idx]},
            );
            return null;
        }

        // Other cleanup we may have to do depending on state.
        switch (self.state) {
            .allocable_string => self.endAllocableString(),
            .semantic_exit_code => self.endSemanticExitCode(),
            .semantic_option_value => self.endSemanticOptionValue(),
            .hyperlink_uri => self.endHyperlink(),
            .string => self.endString(),
            .conemu_sleep_value => self.endConEmuSleepValue(),
            .kitty_color_protocol_key => self.endKittyColorProtocolOption(.key_only, true),
            .kitty_color_protocol_value => self.endKittyColorProtocolOption(.key_and_value, true),
            .osc_color => self.endOscColor(),

            // 104 abruptly ended turns into a reset palette command.
            .@"104" => {
                self.command = .{ .color_operation = .{
                    .op = .osc_104,
                } };
                self.state = .osc_color;
                self.buf_start = self.buf_idx;
                self.endOscColor();
            },

            // We received OSC 9;X ST, but nothing else, finish off as a
            // desktop notification with "X" as the body.
            .conemu_sleep,
            .conemu_message_box,
            .conemu_tab,
            .conemu_progress_prestate,
            .conemu_progress_state,
            .conemu_guimacro,
            => {
                self.showDesktopNotification();
                self.endString();
            },

            // A ConEmu progress report that has reached these states is
            // complete, don't do anything to them.
            .conemu_progress_prevalue,
            .conemu_progress_value,
            => {},

            else => {},
        }

        switch (self.command) {
            .kitty_color_protocol => |*c| c.terminator = .init(terminator_ch),
            .color_operation => |*c| c.terminator = .init(terminator_ch),
            else => {},
        }

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
    try testing.expect(p.complete == false);
}

test "OSC 0: one shorter than buffer length" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const prefix = "0;";
    const title = "a" ** (Parser.MAX_BUF - prefix.len - 1);
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
    const title = "a" ** (Parser.MAX_BUF - prefix.len);
    const input = prefix ++ title;
    for (input) |ch| p.next(ch);

    // This should be null because we always reserve space for a null terminator.
    try testing.expect(p.end(null) == null);
    try testing.expect(p.complete == false);
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

    try testing.expectEqual(Parser.State.empty, p.state);
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
