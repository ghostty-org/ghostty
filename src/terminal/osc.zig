//! OSC (Operating System Command) related functions and types.
//!
//! OSC is another set of control sequences for terminal programs that start with
//! "ESC ]". Unlike CSI or standard ESC sequences, they may contain strings
//! and other irregular formatting so a dedicated parser is created to handle it.
const osc = @This();

const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const assert = std.debug.assert;
const Allocator = mem.Allocator;
const RGB = @import("color.zig").RGB;
const kitty = @import("kitty.zig");

const log = std.log.scoped(.osc);

pub const Command = union(enum) {
    /// Set the window title of the terminal
    ///
    /// If title mode 0  is set text is expect to be hex encoded (i.e. utf-8
    /// with each code unit further encoded with two hex digits).
    ///
    /// If title mode 2 is set or the terminal is setup for unconditional
    /// utf-8 titles text is interpreted as utf-8. Else text is interpreted
    /// as latin1.
    change_window_title: []const u8,

    /// Set the icon of the terminal window. The name of the icon is not
    /// well defined, so this is currently ignored by Ghostty at the time
    /// of writing this. We just parse it so that we don't get parse errors
    /// in the log.
    change_window_icon: []const u8,

    /// First do a fresh-line. Then start a new command, and enter prompt mode:
    /// Subsequent text (until a OSC "133;B" or OSC "133;I" command) is a
    /// prompt string (as if followed by OSC 133;P;k=i\007). Note: I've noticed
    /// not all shells will send the prompt end code.
    ///
    /// "aid" is an optional "application identifier" that helps disambiguate
    /// nested shell sessions. It can be anything but is usually a process ID.
    ///
    /// "kind" tells us which kind of semantic prompt sequence this is:
    /// - primary: normal, left-aligned first-line prompt (initial, default)
    /// - continuation: an editable continuation line
    /// - secondary: a non-editable continuation line
    /// - right: a right-aligned prompt that may need adjustment during reflow
    prompt_start: struct {
        aid: ?[]const u8 = null,
        kind: enum { primary, continuation, secondary, right } = .primary,
        redraw: bool = true,
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
    end_of_input: void,

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
        data: []const u8,
    },

    /// OSC 7. Reports the current working directory of the shell. This is
    /// a moderately flawed escape sequence but one that many major terminals
    /// support so we also support it. To understand the flaws, read through
    /// this terminal-wg issue: https://gitlab.freedesktop.org/terminal-wg/specifications/-/issues/20
    report_pwd: struct {
        /// The reported pwd value. This is not checked for validity. It should
        /// be a file URL but it is up to the caller to utilize this value.
        value: []const u8,
    },

    /// OSC 22. Set the mouse shape. There doesn't seem to be a standard
    /// naming scheme for cursors but it looks like terminals such as Foot
    /// are moving towards using the W3C CSS cursor names. For OSC parsing,
    /// we just parse whatever string is given.
    mouse_shape: struct {
        value: []const u8,
    },

    /// OSC color operations to set, reset, or report color settings. Some OSCs
    /// allow multiple operations to be specified in a single OSC so we need a
    /// list-like datastructure to manage them. We use std.SegmentedList because
    /// it minimizes the number of allocations and copies because a large
    /// majority of the time there will be only one operation per OSC.
    ///
    /// Currently, these OSCs are handled by `color_operation`:
    ///
    /// 4, 10, 11, 12, 104, 110, 111, 112
    color_operation: struct {
        source: ColorOperation.Source,
        operations: ColorOperation.List = .{},
        terminator: Terminator = .st,
    },

    /// Kitty color protocol, OSC 21
    /// https://sw.kovidgoyal.net/kitty/color-stack/#id1
    kitty_color_protocol: kitty.color.OSC,

    /// Show a desktop notification (OSC 9 or OSC 777)
    show_desktop_notification: struct {
        title: []const u8,
        body: []const u8,
    },

    /// Start a hyperlink (OSC 8)
    hyperlink_start: struct {
        id: ?[]const u8 = null,
        uri: []const u8,
    },

    /// End a hyperlink (OSC 8)
    hyperlink_end: void,

    /// Sleep (OSC 9;1)
    sleep: struct {
        duration_ms: u16,
    },

    /// Show GUI message Box (OSC 9;2)
    show_message_box: []const u8,

    /// Change ConEmu tab (OSC 9;3)
    change_conemu_tab_title: union(enum) {
        reset: void,
        value: []const u8,
    },

    /// Set progress state (OSC 9;4)
    progress: struct {
        state: ProgressState,
        progress: ?u8 = null,
    },

    /// Wait input (OSC 9;5)
    wait_input: void,

    pub const ColorOperation = union(enum) {
        pub const Source = enum(u16) {
            // these numbers are based on the OSC operation code
            // see https://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h3-Operating-System-Commands
            get_set_palette = 4,
            get_set_foreground = 10,
            get_set_background = 11,
            get_set_cursor = 12,
            reset_palette = 104,
            reset_foreground = 110,
            reset_background = 111,
            reset_cursor = 112,

            pub fn format(
                self: Source,
                comptime _: []const u8,
                options: std.fmt.FormatOptions,
                writer: anytype,
            ) !void {
                try std.fmt.formatInt(@intFromEnum(self), 10, .lower, options, writer);
            }
        };

        pub const List = std.SegmentedList(ColorOperation, 2);

        pub const Kind = union(enum) {
            palette: u8,
            foreground,
            background,
            cursor,
        };

        set: struct {
            kind: Kind,
            color: RGB,
        },
        reset: Kind,
        report: Kind,
    };

    pub const ProgressState = enum {
        remove,
        set,
        @"error",
        indeterminate,
        pause,
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

    pub fn format(
        self: Terminator,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.writeAll(self.string());
    }
};

pub const Parser = struct {
    /// Optional allocator used to accept data longer than MAX_BUF.
    /// This only applies to some commands (e.g. OSC 52) that can
    /// reasonably exceed MAX_BUF.
    alloc: ?Allocator = null,

    /// Current state of the parser.
    state: State = .empty,

    /// Current command of the parser, this accumulates.
    command: Command = undefined,

    /// Buffer that stores the input we see for a single OSC command.
    /// Slices in Command are offsets into this buffer.
    buf: [MAX_BUF]u8 = undefined,
    buf_start: usize = 0,
    buf_idx: usize = 0,
    buf_dynamic: ?*std.ArrayListUnmanaged(u8) = null,

    /// True when a command is complete/valid to return.
    complete: bool = false,

    /// Temporary state that is dependent on the current state.
    temp_state: union {
        /// Current string parameter being populated
        str: *[]const u8,

        /// Current numeric parameter being populated
        num: u16,

        /// Temporary state for key/value pairs
        key: []const u8,
    } = undefined,

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

        // Get/set color palette index
        osc_4_index,
        osc_4_color,

        // Get/set foreground color
        osc_10,

        // Get/set background color
        osc_11,

        // Get/set cursor color
        osc_12,

        // Reset color palette index
        osc_104,

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
    };

    /// This must be called to clean up any allocated memory.
    pub fn deinit(self: *Parser) void {
        self.reset();
    }

    /// Reset the parser start.
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

        self.state = .empty;
        self.buf_start = 0;
        self.buf_idx = 0;
        self.complete = false;
        if (self.buf_dynamic) |ptr| {
            const alloc = self.alloc.?;
            ptr.deinit(alloc);
            alloc.destroy(ptr);
            self.buf_dynamic = null;
        }

        // Some commands have their own memory management we need to clear.
        // After cleaning up these command, we reset the command to
        // some nonsense (but valid) command so we don't double free.
        const default: Command = .{ .hyperlink_end = {} };
        switch (self.command) {
            .kitty_color_protocol => |*v| {
                v.list.deinit();
                self.command = default;
            },
            .color_operation => |*v| {
                v.operations.deinit(self.alloc.?);
                self.command = default;
            },
            else => {},
        }
    }

    /// Consume the next character c and advance the parser state.
    pub fn next(self: *Parser, c: u8) void {
        // If our buffer is full then we're invalid, so we set our state
        // accordingly and indicate the sequence is incomplete so that we
        // don't accidentally issue a command when ending.
        if (self.buf_idx >= self.buf.len) {
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
                else => self.state = .invalid,
            },

            .@"10" => switch (c) {
                ';' => osc_10: {
                    if (self.alloc == null) {
                        log.warn("OSC 10 requires an allocator, but none was provided", .{});
                        self.state = .invalid;
                        break :osc_10;
                    }
                    self.command = .{
                        .color_operation = .{
                            .source = .get_set_foreground,
                        },
                    };
                    self.state = .osc_10;
                    self.buf_start = self.buf_idx;
                    self.complete = true;
                },
                '4' => self.state = .@"104",
                else => self.state = .invalid,
            },

            .osc_10, .osc_11, .osc_12 => switch (c) {
                ';' => self.parseOSC101112(false),
                else => {},
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
                            .source = .reset_palette,
                        },
                    };
                    self.state = .osc_104;
                    self.buf_start = self.buf_idx;
                    self.complete = true;
                },
                else => self.state = .invalid,
            },

            .osc_104 => switch (c) {
                ';' => self.parseOSC104(false),
                else => {},
            },

            .@"11" => switch (c) {
                ';' => osc_11: {
                    if (self.alloc == null) {
                        log.warn("OSC 11 requires an allocator, but none was provided", .{});
                        self.state = .invalid;
                        break :osc_11;
                    }
                    self.command = .{
                        .color_operation = .{
                            .source = .get_set_background,
                        },
                    };
                    self.state = .osc_11;
                    self.buf_start = self.buf_idx;
                    self.complete = true;
                },
                '0'...'2' => blk: {
                    if (self.alloc == null) {
                        log.warn("OSC 11{c} requires an allocator, but none was provided", .{c});
                        self.state = .invalid;
                        break :blk;
                    }

                    const alloc = self.alloc orelse return;

                    self.command = .{
                        .color_operation = .{
                            .source = switch (c) {
                                '0' => .reset_foreground,
                                '1' => .reset_background,
                                '2' => .reset_cursor,
                                else => unreachable,
                            },
                        },
                    };
                    const op = self.command.color_operation.operations.addOne(alloc) catch |err| {
                        log.warn("unable to append color operation: {}", .{err});
                        return;
                    };
                    op.* = .{
                        .reset = switch (c) {
                            '0' => .foreground,
                            '1' => .background,
                            '2' => .cursor,
                            else => unreachable,
                        },
                    };
                    self.state = .swallow;
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
                    self.command = .{
                        .color_operation = .{
                            .source = .get_set_cursor,
                        },
                    };
                    self.state = .osc_12;
                    self.buf_start = self.buf_idx;
                    self.complete = true;
                },
                else => self.state = .invalid,
            },

            .@"13" => switch (c) {
                '3' => self.state = .@"133",
                else => self.state = .invalid,
            },

            .@"133" => switch (c) {
                ';' => self.state = .semantic_prompt,
                else => self.state = .invalid,
            },

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
                    const alloc = self.alloc orelse {
                        log.info("OSC 21 requires an allocator, but none was provided", .{});
                        self.state = .invalid;
                        break :kitty;
                    };

                    self.command = .{
                        .kitty_color_protocol = .{
                            .list = std.ArrayList(kitty.color.OSC.Request).init(alloc),
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
                            .source = .get_set_palette,
                        },
                    };
                    self.state = .osc_4_index;
                    self.buf_start = self.buf_idx;
                    self.complete = true;
                },
                else => self.state = .invalid,
            },

            .osc_4_index => switch (c) {
                ';' => self.state = .osc_4_color,
                else => {},
            },

            .osc_4_color => switch (c) {
                ';' => {
                    self.parseOSC4(false);
                    self.state = .osc_4_index;
                },
                else => {},
            },

            .@"5" => switch (c) {
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
                    self.command.show_desktop_notification.title = self.buf[self.buf_start .. self.buf_idx - 1];
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
                },
                '2' => {
                    self.state = .conemu_message_box;
                },
                '3' => {
                    self.state = .conemu_tab;
                },
                '4' => {
                    self.state = .conemu_progress_prestate;
                },
                '5' => {
                    self.state = .swallow;
                    self.command = .{ .wait_input = {} };
                    self.complete = true;
                },

                // Todo: parse out other ConEmu operating system commands.
                // Even if we don't support them we probably don't want
                // them showing up as desktop notifications.

                else => self.showDesktopNotification(),
            },

            .conemu_sleep => switch (c) {
                ';' => {
                    self.command = .{ .sleep = .{ .duration_ms = 100 } };
                    self.buf_start = self.buf_idx;
                    self.complete = true;
                    self.state = .conemu_sleep_value;
                },
                else => self.state = .invalid,
            },

            .conemu_message_box => switch (c) {
                ';' => {
                    self.command = .{ .show_message_box = undefined };
                    self.temp_state = .{ .str = &self.command.show_message_box };
                    self.buf_start = self.buf_idx;
                    self.complete = true;
                    self.prepAllocableString();
                },
                else => self.state = .invalid,
            },

            .conemu_sleep_value => switch (c) {
                else => self.complete = true,
            },

            .conemu_tab => switch (c) {
                ';' => {
                    self.state = .conemu_tab_txt;
                    self.command = .{ .change_conemu_tab_title = .{ .reset = {} } };
                    self.buf_start = self.buf_idx;
                    self.complete = true;
                },
                else => self.state = .invalid,
            },

            .conemu_tab_txt => {
                self.command = .{ .change_conemu_tab_title = .{ .value = undefined } };
                self.temp_state = .{ .str = &self.command.change_conemu_tab_title.value };
                self.complete = true;
                self.prepAllocableString();
            },

            .conemu_progress_prestate => switch (c) {
                ';' => {
                    self.command = .{ .progress = .{
                        .state = undefined,
                    } };
                    self.state = .conemu_progress_state;
                },
                else => self.showDesktopNotification(),
            },

            .conemu_progress_state => switch (c) {
                '0' => {
                    self.command.progress.state = .remove;
                    self.state = .swallow;
                    self.complete = true;
                },
                '1' => {
                    self.command.progress.state = .set;
                    self.command.progress.progress = 0;
                    self.state = .conemu_progress_prevalue;
                },
                '2' => {
                    self.command.progress.state = .@"error";
                    self.complete = true;
                    self.state = .conemu_progress_prevalue;
                },
                '3' => {
                    self.command.progress.state = .indeterminate;
                    self.complete = true;
                    self.state = .swallow;
                },
                '4' => {
                    self.command.progress.state = .pause;
                    self.complete = true;
                    self.state = .conemu_progress_prevalue;
                },
                else => self.showDesktopNotification(),
            },

            .conemu_progress_prevalue => switch (c) {
                ';' => {
                    self.state = .conemu_progress_value;
                },

                else => self.showDesktopNotification(),
            },

            .conemu_progress_value => switch (c) {
                '0'...'9' => value: {
                    // No matter what substate we're in, a number indicates
                    // a completed ConEmu progress command.
                    self.complete = true;

                    // If we aren't a set substate, then we don't care
                    // about the value.
                    const p = &self.command.progress;
                    if (p.state != .set and p.state != .@"error" and p.state != .pause) break :value;

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
                    self.command = .{ .end_of_input = {} };
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
                const value = self.buf[self.buf_start..self.buf_idx];
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
        const value = if (self.buf_start == self.buf_idx)
            ""
        else
            self.buf[self.buf_start .. self.buf_idx - 1];

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
        const value = self.buf[self.buf_start..self.buf_idx];

        if (mem.eql(u8, self.temp_state.key, "aid")) {
            switch (self.command) {
                .prompt_start => |*v| v.aid = value,
                else => {},
            }
        } else if (mem.eql(u8, self.temp_state.key, "redraw")) {
            // Kitty supports a "redraw" option for prompt_start. I can't find
            // this documented anywhere but can see in the code that this is used
            // by shell environments to tell the terminal that the shell will NOT
            // redraw the prompt so we should attempt to resize it.
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
        } else if (mem.eql(u8, self.temp_state.key, "k")) {
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
        self.temp_state.str.* = self.buf[self.buf_start..self.buf_idx];
    }

    fn endConEmuSleepValue(self: *Parser) void {
        switch (self.command) {
            .sleep => |*v| v.duration_ms = value: {
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
            log.warn("zero length key in kitty color protocol", .{});
            return;
        }

        const key = kitty.color.Kind.parse(self.temp_state.key) orelse {
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
                if (v.list.items.len >= @as(usize, kitty.color.Kind.max) * 2) {
                    self.state = .invalid;
                    log.warn("exceeded limit for number of keys in kitty color protocol, ignoring", .{});
                    return;
                }

                if (kind == .key_only or value.len == 0) {
                    v.list.append(.{ .reset = key }) catch |err| {
                        log.warn("unable to append kitty color protocol option: {}", .{err});
                        return;
                    };
                } else if (mem.eql(u8, "?", value)) {
                    v.list.append(.{ .query = key }) catch |err| {
                        log.warn("unable to append kitty color protocol option: {}", .{err});
                        return;
                    };
                } else {
                    v.list.append(.{
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
                        log.warn("unable to append kitty color protocol option: {}", .{err});
                        return;
                    };
                }
            },
            else => {},
        }
    }

    fn endAllocableString(self: *Parser) void {
        const list = self.buf_dynamic.?;
        self.temp_state.str.* = list.items;
    }

    fn parseOSC4(self: *Parser, final: bool) void {
        assert(self.state == .osc_4_color);
        assert(self.command == .color_operation);
        assert(self.command.color_operation.source == .get_set_palette);

        const alloc = self.alloc orelse return;
        const operations = &self.command.color_operation.operations;

        const str = self.buf[self.buf_start .. self.buf_idx - (1 - @intFromBool(final))];
        self.buf_start = 0;
        self.buf_idx = 0;

        var it = std.mem.splitScalar(u8, str, ';');
        const index_str = it.next() orelse {
            log.warn("OSC 4 is missing palette index", .{});
            return;
        };
        const spec_str = it.next() orelse {
            log.warn("OSC 4 is missing color spec", .{});
            return;
        };
        const index = std.fmt.parseUnsigned(u8, index_str, 10) catch |err| switch (err) {
            error.Overflow, error.InvalidCharacter => {
                log.warn("invalid color palette index in OSC 4: {s} {}", .{ index_str, err });
                return;
            },
        };
        if (std.mem.eql(u8, spec_str, "?")) {
            const op = operations.addOne(alloc) catch |err| {
                log.warn("unable to append color operation: {}", .{err});
                return;
            };
            op.* = .{
                .report = .{ .palette = index },
            };
        } else {
            const color = RGB.parse(spec_str) catch |err| {
                log.warn("invalid color specification in OSC 4: '{s}' {}", .{ spec_str, err });
                return;
            };
            const op = operations.addOne(alloc) catch |err| {
                log.warn("unable to append color operation: {}", .{err});
                return;
            };
            op.* = .{
                .set = .{
                    .kind = .{
                        .palette = index,
                    },
                    .color = color,
                },
            };
        }
    }

    fn parseOSC101112(self: *Parser, final: bool) void {
        assert(switch (self.state) {
            .osc_10, .osc_11, .osc_12 => true,
            else => false,
        });
        assert(self.command == .color_operation);
        assert(self.command.color_operation.source == switch (self.state) {
            .osc_10 => Command.ColorOperation.Source.get_set_foreground,
            .osc_11 => Command.ColorOperation.Source.get_set_background,
            .osc_12 => Command.ColorOperation.Source.get_set_cursor,
            else => unreachable,
        });

        const spec_str = self.buf[self.buf_start .. self.buf_idx - (1 - @intFromBool(final))];

        if (self.command.color_operation.operations.count() > 0) {
            // don't emit the warning if the string is empty
            if (spec_str.len == 0) return;

            log.warn("OSC 1{s} can only accept 1 color", .{switch (self.state) {
                .osc_10 => "0",
                .osc_11 => "1",
                .osc_12 => "2",
                else => unreachable,
            }});
            return;
        }

        if (spec_str.len == 0) {
            log.warn("OSC 1{s} requires an argument", .{switch (self.state) {
                .osc_10 => "0",
                .osc_11 => "1",
                .osc_12 => "2",
                else => unreachable,
            }});
            return;
        }

        const alloc = self.alloc orelse return;
        const operations = &self.command.color_operation.operations;

        if (std.mem.eql(u8, spec_str, "?")) {
            const op = operations.addOne(alloc) catch |err| {
                log.warn("unable to append color operation: {}", .{err});
                return;
            };
            op.* = .{
                .report = switch (self.state) {
                    .osc_10 => .foreground,
                    .osc_11 => .background,
                    .osc_12 => .cursor,
                    else => unreachable,
                },
            };
        } else {
            const color = RGB.parse(spec_str) catch |err| {
                log.warn("invalid color specification in OSC 1{s}: {s} {}", .{
                    switch (self.state) {
                        .osc_10 => "0",
                        .osc_11 => "1",
                        .osc_12 => "2",
                        else => unreachable,
                    },
                    spec_str,
                    err,
                });
                return;
            };
            const op = operations.addOne(alloc) catch |err| {
                log.warn("unable to append color operation: {}", .{err});
                return;
            };
            op.* = .{
                .set = .{
                    .kind = switch (self.state) {
                        .osc_10 => .foreground,
                        .osc_11 => .background,
                        .osc_12 => .cursor,
                        else => unreachable,
                    },
                    .color = color,
                },
            };
        }
    }

    fn parseOSC104(self: *Parser, final: bool) void {
        assert(self.state == .osc_104);
        assert(self.command == .color_operation);
        assert(self.command.color_operation.source == .reset_palette);

        const alloc = self.alloc orelse return;

        const index_str = self.buf[self.buf_start .. self.buf_idx - (1 - @intFromBool(final))];
        self.buf_start = 0;
        self.buf_idx = 0;

        const index = std.fmt.parseUnsigned(u8, index_str, 10) catch |err| switch (err) {
            error.Overflow, error.InvalidCharacter => {
                log.warn("invalid color palette index in OSC 104: {s} {}", .{ index_str, err });
                return;
            },
        };
        const op = self.command.color_operation.operations.addOne(alloc) catch |err| {
            log.warn("unable to append color operation: {}", .{err});
            return;
        };
        op.* = .{
            .reset = .{ .palette = index },
        };
    }

    /// End the sequence and return the command, if any. If the return value
    /// is null, then no valid command was found. The optional terminator_ch
    /// is the final character in the OSC sequence. This is used to determine
    /// the response terminator.
    pub fn end(self: *Parser, terminator_ch: ?u8) ?Command {
        if (!self.complete) {
            if (comptime !builtin.is_test) log.warn(
                "invalid OSC command: {s}",
                .{self.buf[0..self.buf_idx]},
            );
            return null;
        }

        // Other cleanup we may have to do depending on state.
        switch (self.state) {
            .semantic_exit_code => self.endSemanticExitCode(),
            .semantic_option_value => self.endSemanticOptionValue(),
            .hyperlink_uri => self.endHyperlink(),
            .string => self.endString(),
            .conemu_sleep_value => self.endConEmuSleepValue(),
            .allocable_string => self.endAllocableString(),
            .kitty_color_protocol_key => self.endKittyColorProtocolOption(.key_only, true),
            .kitty_color_protocol_value => self.endKittyColorProtocolOption(.key_and_value, true),
            .osc_4_color => self.parseOSC4(true),
            .osc_10, .osc_11, .osc_12 => self.parseOSC101112(true),
            .osc_104 => self.parseOSC104(true),
            else => {},
        }

        switch (self.command) {
            .kitty_color_protocol => |*c| c.terminator = .init(terminator_ch),
            .color_operation => |*c| c.terminator = .init(terminator_ch),
            else => {},
        }

        return self.command;
    }
};

test "OSC: change_window_title" {
    const testing = std.testing;

    var p: Parser = .{};
    p.next('0');
    p.next(';');
    p.next('a');
    p.next('b');
    const cmd = p.end(null).?;
    try testing.expect(cmd == .change_window_title);
    try testing.expectEqualStrings("ab", cmd.change_window_title);
}

test "OSC: change_window_title with 2" {
    const testing = std.testing;

    var p: Parser = .{};
    p.next('2');
    p.next(';');
    p.next('a');
    p.next('b');
    const cmd = p.end(null).?;
    try testing.expect(cmd == .change_window_title);
    try testing.expectEqualStrings("ab", cmd.change_window_title);
}

test "OSC: change_window_title with utf8" {
    const testing = std.testing;

    var p: Parser = .{};
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
    const cmd = p.end(null).?;
    try testing.expect(cmd == .change_window_title);
    try testing.expectEqualStrings("— ‐", cmd.change_window_title);
}

test "OSC: change_window_title empty" {
    const testing = std.testing;

    var p: Parser = .{};
    p.next('2');
    p.next(';');
    const cmd = p.end(null).?;
    try testing.expect(cmd == .change_window_title);
    try testing.expectEqualStrings("", cmd.change_window_title);
}

test "OSC: change_window_icon" {
    const testing = std.testing;

    var p: Parser = .{};
    p.next('1');
    p.next(';');
    p.next('a');
    p.next('b');
    const cmd = p.end(null).?;
    try testing.expect(cmd == .change_window_icon);
    try testing.expectEqualStrings("ab", cmd.change_window_icon);
}

test "OSC: prompt_start" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "133;A";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?;
    try testing.expect(cmd == .prompt_start);
    try testing.expect(cmd.prompt_start.aid == null);
    try testing.expect(cmd.prompt_start.redraw);
}

test "OSC: prompt_start with single option" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "133;A;aid=14";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?;
    try testing.expect(cmd == .prompt_start);
    try testing.expectEqualStrings("14", cmd.prompt_start.aid.?);
}

test "OSC: prompt_start with redraw disabled" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "133;A;redraw=0";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?;
    try testing.expect(cmd == .prompt_start);
    try testing.expect(!cmd.prompt_start.redraw);
}

test "OSC: prompt_start with redraw invalid value" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "133;A;redraw=42";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?;
    try testing.expect(cmd == .prompt_start);
    try testing.expect(cmd.prompt_start.redraw);
    try testing.expect(cmd.prompt_start.kind == .primary);
}

test "OSC: prompt_start with continuation" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "133;A;k=c";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?;
    try testing.expect(cmd == .prompt_start);
    try testing.expect(cmd.prompt_start.kind == .continuation);
}

test "OSC: prompt_start with secondary" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "133;A;k=s";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?;
    try testing.expect(cmd == .prompt_start);
    try testing.expect(cmd.prompt_start.kind == .secondary);
}

test "OSC: end_of_command no exit code" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "133;D";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?;
    try testing.expect(cmd == .end_of_command);
}

test "OSC: end_of_command with exit code" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "133;D;25";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?;
    try testing.expect(cmd == .end_of_command);
    try testing.expectEqual(@as(u8, 25), cmd.end_of_command.exit_code.?);
}

test "OSC: prompt_end" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "133;B";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?;
    try testing.expect(cmd == .prompt_end);
}

test "OSC: end_of_input" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "133;C";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?;
    try testing.expect(cmd == .end_of_input);
}

test "OSC: OSC110: reset foreground color" {
    const testing = std.testing;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "110";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?;
    try testing.expect(cmd == .color_operation);
    try testing.expectEqual(cmd.color_operation.terminator, .st);
    try testing.expect(cmd.color_operation.source == .reset_foreground);
    try testing.expect(cmd.color_operation.operations.count() == 1);
    var it = cmd.color_operation.operations.constIterator(0);
    {
        const op = it.next().?;
        try testing.expect(op.* == .reset);
        try testing.expectEqual(
            Command.ColorOperation.Kind.foreground,
            op.reset,
        );
    }
    try testing.expect(it.next() == null);
}

test "OSC: OSC111: reset background color" {
    const testing = std.testing;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "111";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?;
    try testing.expect(cmd == .color_operation);
    try testing.expectEqual(cmd.color_operation.terminator, .st);
    try testing.expect(cmd.color_operation.source == .reset_background);
    try testing.expect(cmd.color_operation.operations.count() == 1);
    var it = cmd.color_operation.operations.constIterator(0);
    {
        const op = it.next().?;
        try testing.expect(op.* == .reset);
        try testing.expectEqual(
            Command.ColorOperation.Kind.background,
            op.reset,
        );
    }
    try testing.expect(it.next() == null);
}

test "OSC: OSC112: reset cursor color" {
    const testing = std.testing;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "112";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?;
    try testing.expect(cmd == .color_operation);
    try testing.expectEqual(cmd.color_operation.terminator, .st);
    try testing.expect(cmd.color_operation.source == .reset_cursor);
    try testing.expect(cmd.color_operation.operations.count() == 1);
    var it = cmd.color_operation.operations.constIterator(0);
    {
        const op = it.next().?;
        try testing.expect(op.* == .reset);
        try testing.expectEqual(
            Command.ColorOperation.Kind.cursor,
            op.reset,
        );
    }
    try testing.expect(it.next() == null);
}

test "OSC: OSC112: reset cursor color with semicolon" {
    const testing = std.testing;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "112;";
    for (input) |ch| p.next(ch);
    log.warn("finish: {s}", .{@tagName(p.state)});

    const cmd = p.end(0x07).?;
    try testing.expect(cmd == .color_operation);
    try testing.expectEqual(cmd.color_operation.terminator, .bel);
    try testing.expect(cmd.color_operation.source == .reset_cursor);
    try testing.expect(cmd.color_operation.operations.count() == 1);
    var it = cmd.color_operation.operations.constIterator(0);
    {
        const op = it.next().?;
        try testing.expect(op.* == .reset);
        try testing.expectEqual(
            Command.ColorOperation.Kind.cursor,
            op.reset,
        );
    }
    try testing.expect(it.next() == null);
}

test "OSC: get/set clipboard" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "52;s;?";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?;
    try testing.expect(cmd == .clipboard_contents);
    try testing.expect(cmd.clipboard_contents.kind == 's');
    try testing.expect(std.mem.eql(u8, "?", cmd.clipboard_contents.data));
}

test "OSC: get/set clipboard (optional parameter)" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "52;;?";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?;
    try testing.expect(cmd == .clipboard_contents);
    try testing.expect(cmd.clipboard_contents.kind == 'c');
    try testing.expect(std.mem.eql(u8, "?", cmd.clipboard_contents.data));
}

test "OSC: get/set clipboard with allocator" {
    const testing = std.testing;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "52;s;?";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?;
    try testing.expect(cmd == .clipboard_contents);
    try testing.expect(cmd.clipboard_contents.kind == 's');
    try testing.expect(std.mem.eql(u8, "?", cmd.clipboard_contents.data));
}

test "OSC: report pwd" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "7;file:///tmp/example";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?;
    try testing.expect(cmd == .report_pwd);
    try testing.expect(std.mem.eql(u8, "file:///tmp/example", cmd.report_pwd.value));
}

test "OSC: report pwd empty" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "7;";
    for (input) |ch| p.next(ch);
    const cmd = p.end(null).?;
    try testing.expect(cmd == .report_pwd);
    try testing.expect(std.mem.eql(u8, "", cmd.report_pwd.value));
}

test "OSC: pointer cursor" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "22;pointer";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?;
    try testing.expect(cmd == .mouse_shape);
    try testing.expect(std.mem.eql(u8, "pointer", cmd.mouse_shape.value));
}

test "OSC: longer than buffer" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "0;" ++ "a" ** (Parser.MAX_BUF + 2);
    for (input) |ch| p.next(ch);

    try testing.expect(p.end(null) == null);
    try testing.expect(p.complete == false);
}

test "OSC: OSC10: report foreground color" {
    const testing = std.testing;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "10;?";
    for (input) |ch| p.next(ch);

    // This corresponds to ST = ESC followed by \
    const cmd = p.end('\x1b').?;

    try testing.expect(cmd == .color_operation);
    try testing.expectEqual(cmd.color_operation.terminator, .st);
    try testing.expect(cmd.color_operation.source == .get_set_foreground);
    try testing.expect(cmd.color_operation.operations.count() == 1);
    var it = cmd.color_operation.operations.constIterator(0);
    {
        const op = it.next().?;
        try testing.expect(op.* == .report);
        try testing.expectEqual(
            Command.ColorOperation.Kind.foreground,
            op.report,
        );
    }
    try testing.expect(it.next() == null);
}

test "OSC: OSC10: set foreground color" {
    const testing = std.testing;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "10;rgbi:0.0/0.5/1.0";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x07').?;
    try testing.expect(cmd == .color_operation);
    try testing.expectEqual(cmd.color_operation.terminator, .bel);
    try testing.expect(cmd.color_operation.source == .get_set_foreground);
    try testing.expect(cmd.color_operation.operations.count() == 1);
    var it = cmd.color_operation.operations.constIterator(0);
    {
        const op = it.next().?;
        try testing.expect(op.* == .set);
        try testing.expectEqual(
            Command.ColorOperation.Kind.foreground,
            op.set.kind,
        );
        try testing.expectEqual(
            RGB{ .r = 0x00, .g = 0x7f, .b = 0xff },
            op.set.color,
        );
    }
    try testing.expect(it.next() == null);
}

test "OSC: OSC11: report background color" {
    const testing = std.testing;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "11;?";
    for (input) |ch| p.next(ch);

    // This corresponds to ST = BEL character
    const cmd = p.end('\x07').?;
    try testing.expect(cmd == .color_operation);
    try testing.expectEqual(cmd.color_operation.terminator, .bel);
    try testing.expect(cmd.color_operation.source == .get_set_background);
    try testing.expect(cmd.color_operation.operations.count() == 1);
    var it = cmd.color_operation.operations.constIterator(0);
    {
        const op = it.next().?;
        try testing.expect(op.* == .report);
        try testing.expectEqual(
            Command.ColorOperation.Kind.background,
            op.report,
        );
    }
    try testing.expectEqual(cmd.color_operation.terminator, .bel);
    try testing.expect(it.next() == null);
}

test "OSC: OSC11: set background color" {
    const testing = std.testing;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "11;rgb:f/ff/ffff";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .color_operation);
    try testing.expectEqual(cmd.color_operation.terminator, .st);
    try testing.expect(cmd.color_operation.source == .get_set_background);
    try testing.expect(cmd.color_operation.operations.count() == 1);
    var it = cmd.color_operation.operations.constIterator(0);
    {
        const op = it.next().?;
        try testing.expect(op.* == .set);
        try testing.expectEqual(
            Command.ColorOperation.Kind.background,
            op.set.kind,
        );
        try testing.expectEqual(
            RGB{ .r = 0xff, .g = 0xff, .b = 0xff },
            op.set.color,
        );
    }
    try testing.expect(it.next() == null);
}

test "OSC: OSC12: report cursor color" {
    const testing = std.testing;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "12;?";
    for (input) |ch| p.next(ch);

    // This corresponds to ST = BEL character
    const cmd = p.end('\x07').?;
    try testing.expect(cmd == .color_operation);
    try testing.expectEqual(cmd.color_operation.terminator, .bel);
    try testing.expect(cmd.color_operation.source == .get_set_cursor);
    try testing.expect(cmd.color_operation.operations.count() == 1);
    var it = cmd.color_operation.operations.constIterator(0);
    {
        const op = it.next().?;
        try testing.expect(op.* == .report);
        try testing.expectEqual(
            Command.ColorOperation.Kind.cursor,
            op.report,
        );
    }
    try testing.expectEqual(cmd.color_operation.terminator, .bel);
    try testing.expect(it.next() == null);
}

test "OSC: OSC12: set cursor color" {
    const testing = std.testing;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "12;rgb:f/ff/ffff";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .color_operation);
    try testing.expectEqual(cmd.color_operation.terminator, .st);
    try testing.expect(cmd.color_operation.source == .get_set_cursor);
    try testing.expect(cmd.color_operation.operations.count() == 1);
    var it = cmd.color_operation.operations.constIterator(0);
    {
        const op = it.next().?;
        try testing.expect(op.* == .set);
        try testing.expectEqual(
            Command.ColorOperation.Kind.cursor,
            op.set.kind,
        );
        try testing.expectEqual(
            RGB{ .r = 0xff, .g = 0xff, .b = 0xff },
            op.set.color,
        );
    }
    try testing.expect(it.next() == null);
}

test "OSC: OSC4: get palette color 1" {
    const testing = std.testing;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "4;1;?";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .color_operation);
    try testing.expect(cmd.color_operation.source == .get_set_palette);
    try testing.expect(cmd.color_operation.operations.count() == 1);
    var it = cmd.color_operation.operations.constIterator(0);
    {
        const op = it.next().?;
        try testing.expect(op.* == .report);
        try testing.expectEqual(
            Command.ColorOperation.Kind{ .palette = 1 },
            op.report,
        );
        try testing.expectEqual(cmd.color_operation.terminator, .st);
    }
    try testing.expect(it.next() == null);
}

test "OSC: OSC4: get palette color 2" {
    const testing = std.testing;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "4;1;?;2;?";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .color_operation);
    try testing.expect(cmd.color_operation.source == .get_set_palette);
    try testing.expect(cmd.color_operation.operations.count() == 2);
    var it = cmd.color_operation.operations.constIterator(0);
    {
        const op = it.next().?;
        try testing.expect(op.* == .report);
        try testing.expectEqual(
            Command.ColorOperation.Kind{ .palette = 1 },
            op.report,
        );
    }
    {
        const op = it.next().?;
        try testing.expect(op.* == .report);
        try testing.expectEqual(
            Command.ColorOperation.Kind{ .palette = 2 },
            op.report,
        );
    }
    try testing.expectEqual(cmd.color_operation.terminator, .st);
    try testing.expect(it.next() == null);
}

test "OSC: OSC4: set palette color 1" {
    const testing = std.testing;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "4;17;rgb:aa/bb/cc";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .color_operation);
    try testing.expect(cmd.color_operation.source == .get_set_palette);
    try testing.expect(cmd.color_operation.operations.count() == 1);
    var it = cmd.color_operation.operations.constIterator(0);
    {
        const op = it.next().?;
        try testing.expect(op.* == .set);
        try testing.expectEqual(
            Command.ColorOperation.Kind{ .palette = 17 },
            op.set.kind,
        );
        try testing.expectEqual(
            RGB{ .r = 0xaa, .g = 0xbb, .b = 0xcc },
            op.set.color,
        );
    }
    try testing.expect(it.next() == null);
}

test "OSC: OSC4: set palette color 2" {
    const testing = std.testing;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "4;17;rgb:aa/bb/cc;1;rgb:00/11/22";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .color_operation);
    try testing.expect(cmd.color_operation.source == .get_set_palette);
    try testing.expect(cmd.color_operation.operations.count() == 2);
    var it = cmd.color_operation.operations.constIterator(0);
    {
        const op = it.next().?;
        try testing.expect(op.* == .set);
        try testing.expectEqual(
            Command.ColorOperation.Kind{ .palette = 17 },
            op.set.kind,
        );
        try testing.expectEqual(
            RGB{ .r = 0xaa, .g = 0xbb, .b = 0xcc },
            op.set.color,
        );
    }
    {
        const op = it.next().?;
        try testing.expect(op.* == .set);
        try testing.expectEqual(
            Command.ColorOperation.Kind{ .palette = 1 },
            op.set.kind,
        );
        try testing.expectEqual(
            RGB{ .r = 0x00, .g = 0x11, .b = 0x22 },
            op.set.color,
        );
    }
    try testing.expect(it.next() == null);
}

test "OSC: OSC4: get with invalid index 1" {
    const testing = std.testing;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "4;1111;?;1;?";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .color_operation);
    try testing.expect(cmd.color_operation.source == .get_set_palette);
    try testing.expect(cmd.color_operation.operations.count() == 1);
    var it = cmd.color_operation.operations.constIterator(0);
    {
        const op = it.next().?;
        try testing.expect(op.* == .report);
        try testing.expectEqual(
            Command.ColorOperation.Kind{ .palette = 1 },
            op.report,
        );
    }
    try testing.expect(it.next() == null);
}

test "OSC: OSC4: get with invalid index 2" {
    const testing = std.testing;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "4;5;?;1111;?;1;?";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .color_operation);
    try testing.expect(cmd.color_operation.source == .get_set_palette);
    try testing.expect(cmd.color_operation.operations.count() == 2);
    var it = cmd.color_operation.operations.constIterator(0);
    {
        const op = it.next().?;
        try testing.expect(op.* == .report);
        try testing.expectEqual(
            Command.ColorOperation.Kind{ .palette = 5 },
            op.report,
        );
    }
    {
        const op = it.next().?;
        try testing.expect(op.* == .report);
        try testing.expectEqual(
            Command.ColorOperation.Kind{ .palette = 1 },
            op.report,
        );
    }
    try testing.expect(it.next() == null);
}

// Inspired by Microsoft Edit
test "OSC: OSC4: multiple get 8a" {
    const testing = std.testing;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "4;0;?;1;?;2;?;3;?;4;?;5;?;6;?;7;?";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .color_operation);
    try testing.expect(cmd.color_operation.source == .get_set_palette);
    try testing.expect(cmd.color_operation.operations.count() == 8);
    var it = cmd.color_operation.operations.constIterator(0);
    {
        const op = it.next().?;
        try testing.expect(op.* == .report);
        try testing.expectEqual(
            Command.ColorOperation.Kind{ .palette = 0 },
            op.report,
        );
    }
    {
        const op = it.next().?;
        try testing.expect(op.* == .report);
        try testing.expectEqual(
            Command.ColorOperation.Kind{ .palette = 1 },
            op.report,
        );
    }
    {
        const op = it.next().?;
        try testing.expect(op.* == .report);
        try testing.expectEqual(
            Command.ColorOperation.Kind{ .palette = 2 },
            op.report,
        );
    }
    {
        const op = it.next().?;
        try testing.expect(op.* == .report);
        try testing.expectEqual(
            Command.ColorOperation.Kind{ .palette = 3 },
            op.report,
        );
    }
    {
        const op = it.next().?;
        try testing.expect(op.* == .report);
        try testing.expectEqual(
            Command.ColorOperation.Kind{ .palette = 4 },
            op.report,
        );
    }
    {
        const op = it.next().?;
        try testing.expect(op.* == .report);
        try testing.expectEqual(
            Command.ColorOperation.Kind{ .palette = 5 },
            op.report,
        );
    }
    {
        const op = it.next().?;
        try testing.expect(op.* == .report);
        try testing.expectEqual(
            Command.ColorOperation.Kind{ .palette = 6 },
            op.report,
        );
    }
    {
        const op = it.next().?;
        try testing.expect(op.* == .report);
        try testing.expectEqual(
            Command.ColorOperation.Kind{ .palette = 7 },
            op.report,
        );
    }
    try testing.expect(it.next() == null);
}

// Inspired by Microsoft Edit
test "OSC: OSC4: multiple get 8b" {
    const testing = std.testing;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "4;8;?;9;?;10;?;11;?;12;?;13;?;14;?;15;?";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .color_operation);
    try testing.expect(cmd.color_operation.source == .get_set_palette);
    try testing.expect(cmd.color_operation.operations.count() == 8);
    var it = cmd.color_operation.operations.constIterator(0);
    {
        const op = it.next().?;
        try testing.expect(op.* == .report);
        try testing.expectEqual(
            Command.ColorOperation.Kind{ .palette = 8 },
            op.report,
        );
    }
    {
        const op = it.next().?;
        try testing.expect(op.* == .report);
        try testing.expectEqual(
            Command.ColorOperation.Kind{ .palette = 9 },
            op.report,
        );
    }
    {
        const op = it.next().?;
        try testing.expect(op.* == .report);
        try testing.expectEqual(
            Command.ColorOperation.Kind{ .palette = 10 },
            op.report,
        );
    }
    {
        const op = it.next().?;
        try testing.expect(op.* == .report);
        try testing.expectEqual(
            Command.ColorOperation.Kind{ .palette = 11 },
            op.report,
        );
    }
    {
        const op = it.next().?;
        try testing.expect(op.* == .report);
        try testing.expectEqual(
            Command.ColorOperation.Kind{ .palette = 12 },
            op.report,
        );
    }
    {
        const op = it.next().?;
        try testing.expect(op.* == .report);
        try testing.expectEqual(
            Command.ColorOperation.Kind{ .palette = 13 },
            op.report,
        );
    }
    {
        const op = it.next().?;
        try testing.expect(op.* == .report);
        try testing.expectEqual(
            Command.ColorOperation.Kind{ .palette = 14 },
            op.report,
        );
    }
    {
        const op = it.next().?;
        try testing.expect(op.* == .report);
        try testing.expectEqual(
            Command.ColorOperation.Kind{ .palette = 15 },
            op.report,
        );
    }
    try testing.expect(it.next() == null);
}

test "OSC: OSC4: set with invalid index" {
    const testing = std.testing;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "4;256;#ffffff;1;#aabbcc";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .color_operation);
    try testing.expect(cmd.color_operation.source == .get_set_palette);
    try testing.expect(cmd.color_operation.operations.count() == 1);
    var it = cmd.color_operation.operations.constIterator(0);
    {
        const op = it.next().?;
        try testing.expect(op.* == .set);
        try testing.expectEqual(
            Command.ColorOperation.Kind{ .palette = 1 },
            op.set.kind,
        );
        try testing.expectEqual(
            RGB{ .r = 0xaa, .g = 0xbb, .b = 0xcc },
            op.set.color,
        );
    }
    try testing.expect(it.next() == null);
}

test "OSC: OSC4: mix get/set palette color" {
    const testing = std.testing;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "4;17;rgb:aa/bb/cc;254;?";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .color_operation);
    try testing.expect(cmd.color_operation.source == .get_set_palette);
    try testing.expect(cmd.color_operation.operations.count() == 2);
    var it = cmd.color_operation.operations.constIterator(0);
    {
        const op = it.next().?;
        try testing.expect(op.* == .set);
        try testing.expectEqual(
            Command.ColorOperation.Kind{ .palette = 17 },
            op.set.kind,
        );
        try testing.expectEqual(
            RGB{ .r = 0xaa, .g = 0xbb, .b = 0xcc },
            op.set.color,
        );
    }
    {
        const op = it.next().?;
        try testing.expect(op.* == .report);
        try testing.expectEqual(
            Command.ColorOperation.Kind{ .palette = 254 },
            op.report,
        );
    }
    try testing.expect(it.next() == null);
}

test "OSC: OSC4: incomplete color/spec 1" {
    const testing = std.testing;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "4;17";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .color_operation);
    try testing.expect(cmd.color_operation.source == .get_set_palette);
    try testing.expect(cmd.color_operation.operations.count() == 0);
    var it = cmd.color_operation.operations.constIterator(0);
    try testing.expect(it.next() == null);
}

test "OSC: OSC4: incomplete color/spec 2" {
    const testing = std.testing;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "4;17;?;42";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .color_operation);
    try testing.expect(cmd.color_operation.source == .get_set_palette);
    try testing.expect(cmd.color_operation.operations.count() == 1);
    var it = cmd.color_operation.operations.constIterator(0);
    {
        const op = it.next().?;
        try testing.expect(op.* == .report);
        try testing.expectEqual(
            Command.ColorOperation.Kind{ .palette = 17 },
            op.report,
        );
    }
    try testing.expect(it.next() == null);
}

test "OSC: OSC104: reset palette color 1" {
    const testing = std.testing;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "104;17";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .color_operation);
    try testing.expect(cmd.color_operation.source == .reset_palette);
    try testing.expect(cmd.color_operation.operations.count() == 1);
    var it = cmd.color_operation.operations.constIterator(0);
    {
        const op = it.next().?;
        try testing.expect(op.* == .reset);
        try testing.expectEqual(
            Command.ColorOperation.Kind{ .palette = 17 },
            op.reset,
        );
    }
    try testing.expect(it.next() == null);
}

test "OSC: OSC104: reset palette color 2" {
    const testing = std.testing;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "104;17;111";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .color_operation);
    try testing.expect(cmd.color_operation.source == .reset_palette);
    try testing.expectEqual(2, cmd.color_operation.operations.count());
    var it = cmd.color_operation.operations.constIterator(0);
    {
        const op = it.next().?;
        try testing.expect(op.* == .reset);
        try testing.expectEqual(
            Command.ColorOperation.Kind{ .palette = 17 },
            op.reset,
        );
    }
    {
        const op = it.next().?;
        try testing.expect(op.* == .reset);
        try testing.expectEqual(
            Command.ColorOperation.Kind{ .palette = 111 },
            op.reset,
        );
    }
    try testing.expect(it.next() == null);
}

test "OSC: OSC104: invalid palette index" {
    const testing = std.testing;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "104;ffff;111";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .color_operation);
    try testing.expect(cmd.color_operation.source == .reset_palette);
    try testing.expect(cmd.color_operation.operations.count() == 1);
    var it = cmd.color_operation.operations.constIterator(0);
    {
        const op = it.next().?;
        try testing.expect(op.* == .reset);
        try testing.expectEqual(
            Command.ColorOperation.Kind{ .palette = 111 },
            op.reset,
        );
    }
    try testing.expect(it.next() == null);
}

test "OSC: OSC104: empty palette index" {
    const testing = std.testing;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "104;;111";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .color_operation);
    try testing.expect(cmd.color_operation.source == .reset_palette);
    try testing.expect(cmd.color_operation.operations.count() == 1);
    var it = cmd.color_operation.operations.constIterator(0);
    {
        const op = it.next().?;
        try testing.expect(op.* == .reset);
        try testing.expectEqual(
            Command.ColorOperation.Kind{ .palette = 111 },
            op.reset,
        );
    }
    try std.testing.expect(it.next() == null);
}

test "OSC: conemu sleep" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "9;1;420";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;

    try testing.expect(cmd == .sleep);
    try testing.expectEqual(420, cmd.sleep.duration_ms);
}

test "OSC: conemu sleep with no value default to 100ms" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "9;1;";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;

    try testing.expect(cmd == .sleep);
    try testing.expectEqual(100, cmd.sleep.duration_ms);
}

test "OSC: conemu sleep cannot exceed 10000ms" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "9;1;12345";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;

    try testing.expect(cmd == .sleep);
    try testing.expectEqual(10000, cmd.sleep.duration_ms);
}

test "OSC: conemu sleep invalid input" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "9;1;foo";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;

    try testing.expect(cmd == .sleep);
    try testing.expectEqual(100, cmd.sleep.duration_ms);
}

test "OSC: show desktop notification" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "9;Hello world";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .show_desktop_notification);
    try testing.expectEqualStrings(cmd.show_desktop_notification.title, "");
    try testing.expectEqualStrings(cmd.show_desktop_notification.body, "Hello world");
}

test "OSC: show desktop notification with title" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "777;notify;Title;Body";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .show_desktop_notification);
    try testing.expectEqualStrings(cmd.show_desktop_notification.title, "Title");
    try testing.expectEqualStrings(cmd.show_desktop_notification.body, "Body");
}

test "OSC: conemu message box" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "9;2;hello world";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .show_message_box);
    try testing.expectEqualStrings("hello world", cmd.show_message_box);
}

test "OSC: conemu message box invalid input" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "9;2";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b');
    try testing.expect(cmd == null);
}

test "OSC: conemu message box empty message" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "9;2;";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .show_message_box);
    try testing.expectEqualStrings("", cmd.show_message_box);
}

test "OSC: conemu message box spaces only message" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "9;2;   ";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .show_message_box);
    try testing.expectEqualStrings("   ", cmd.show_message_box);
}

test "OSC: conemu change tab title" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "9;3;foo bar";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .change_conemu_tab_title);
    try testing.expectEqualStrings("foo bar", cmd.change_conemu_tab_title.value);
}

test "OSC: conemu change tab reset title" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "9;3;";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;

    const expected_command: Command = .{ .change_conemu_tab_title = .{ .reset = {} } };
    try testing.expectEqual(expected_command, cmd);
}

test "OSC: conemu change tab spaces only title" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "9;3;   ";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;

    try testing.expect(cmd == .change_conemu_tab_title);
    try testing.expectEqualStrings("   ", cmd.change_conemu_tab_title.value);
}

test "OSC: conemu change tab invalid input" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "9;3";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b');
    try testing.expect(cmd == null);
}

test "OSC: OSC9 progress set" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "9;4;1;100";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .progress);
    try testing.expect(cmd.progress.state == .set);
    try testing.expect(cmd.progress.progress == 100);
}

test "OSC: OSC9 progress set overflow" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "9;4;1;900";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .progress);
    try testing.expect(cmd.progress.state == .set);
    try testing.expect(cmd.progress.progress == 100);
}

test "OSC: OSC9 progress set single digit" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "9;4;1;9";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .progress);
    try testing.expect(cmd.progress.state == .set);
    try testing.expect(cmd.progress.progress == 9);
}

test "OSC: OSC9 progress set double digit" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "9;4;1;94";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .progress);
    try testing.expect(cmd.progress.state == .set);
    try testing.expect(cmd.progress.progress == 94);
}

test "OSC: OSC9 progress set extra semicolon ignored" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "9;4;1;100";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .progress);
    try testing.expect(cmd.progress.state == .set);
    try testing.expect(cmd.progress.progress == 100);
}

test "OSC: OSC9 progress remove with no progress" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "9;4;0;";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .progress);
    try testing.expect(cmd.progress.state == .remove);
    try testing.expect(cmd.progress.progress == null);
}

test "OSC: OSC9 progress remove with double semicolon" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "9;4;0;;";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .progress);
    try testing.expect(cmd.progress.state == .remove);
    try testing.expect(cmd.progress.progress == null);
}

test "OSC: OSC9 progress remove ignores progress" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "9;4;0;100";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .progress);
    try testing.expect(cmd.progress.state == .remove);
    try testing.expect(cmd.progress.progress == null);
}

test "OSC: OSC9 progress remove extra semicolon" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "9;4;0;100;";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .progress);
    try testing.expect(cmd.progress.state == .remove);
}

test "OSC: OSC9 progress error" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "9;4;2";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .progress);
    try testing.expect(cmd.progress.state == .@"error");
    try testing.expect(cmd.progress.progress == null);
}

test "OSC: OSC9 progress error with progress" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "9;4;2;100";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .progress);
    try testing.expect(cmd.progress.state == .@"error");
    try testing.expect(cmd.progress.progress == 100);
}

test "OSC: OSC9 progress pause" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "9;4;4";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .progress);
    try testing.expect(cmd.progress.state == .pause);
    try testing.expect(cmd.progress.progress == null);
}

test "OSC: OSC9 progress pause with progress" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "9;4;4;100";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .progress);
    try testing.expect(cmd.progress.state == .pause);
    try testing.expect(cmd.progress.progress == 100);
}

test "OSC: OSC9 conemu wait input" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "9;5";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .wait_input);
}

test "OSC: OSC9 conemu wait ignores trailing characters" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "9;5;foo";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .wait_input);
}

test "OSC: empty param" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "4;;";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b');
    try testing.expect(cmd == null);
}

test "OSC: hyperlink" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "8;;http://example.com";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .hyperlink_start);
    try testing.expectEqualStrings(cmd.hyperlink_start.uri, "http://example.com");
}

test "OSC: hyperlink with id set" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "8;id=foo;http://example.com";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .hyperlink_start);
    try testing.expectEqualStrings(cmd.hyperlink_start.id.?, "foo");
    try testing.expectEqualStrings(cmd.hyperlink_start.uri, "http://example.com");
}

test "OSC: hyperlink with empty id" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "8;id=;http://example.com";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .hyperlink_start);
    try testing.expectEqual(null, cmd.hyperlink_start.id);
    try testing.expectEqualStrings(cmd.hyperlink_start.uri, "http://example.com");
}

test "OSC: hyperlink with incomplete key" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "8;id;http://example.com";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .hyperlink_start);
    try testing.expectEqual(null, cmd.hyperlink_start.id);
    try testing.expectEqualStrings(cmd.hyperlink_start.uri, "http://example.com");
}

test "OSC: hyperlink with empty key" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "8;=value;http://example.com";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .hyperlink_start);
    try testing.expectEqual(null, cmd.hyperlink_start.id);
    try testing.expectEqualStrings(cmd.hyperlink_start.uri, "http://example.com");
}

test "OSC: hyperlink with empty key and id" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "8;=value:id=foo;http://example.com";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .hyperlink_start);
    try testing.expectEqualStrings(cmd.hyperlink_start.id.?, "foo");
    try testing.expectEqualStrings(cmd.hyperlink_start.uri, "http://example.com");
}

test "OSC: hyperlink with empty uri" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "8;id=foo;";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b');
    try testing.expect(cmd == null);
}

test "OSC: hyperlink end" {
    const testing = std.testing;

    var p: Parser = .{};

    const input = "8;;";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .hyperlink_end);
}

test "OSC: kitty color protocol" {
    const testing = std.testing;
    const Kind = kitty.color.Kind;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "21;foreground=?;background=rgb:f0/f8/ff;cursor=aliceblue;cursor_text;visual_bell=;selection_foreground=#xxxyyzz;selection_background=?;selection_background=#aabbcc;2=?;3=rgbi:1.0/1.0/1.0";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
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

test "OSC: kitty color protocol without allocator" {
    const testing = std.testing;

    var p: Parser = .{};
    defer p.deinit();

    const input = "21;foreground=?";
    for (input) |ch| p.next(ch);
    try testing.expect(p.end('\x1b') == null);
}

test "OSC: kitty color protocol double reset" {
    const testing = std.testing;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "21;foreground=?;background=rgb:f0/f8/ff;cursor=aliceblue;cursor_text;visual_bell=;selection_foreground=#xxxyyzz;selection_background=?;selection_background=#aabbcc;2=?;3=rgbi:1.0/1.0/1.0";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .kitty_color_protocol);

    p.reset();
    p.reset();
}

test "OSC: kitty color protocol reset after invalid" {
    const testing = std.testing;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "21;foreground=?;background=rgb:f0/f8/ff;cursor=aliceblue;cursor_text;visual_bell=;selection_foreground=#xxxyyzz;selection_background=?;selection_background=#aabbcc;2=?;3=rgbi:1.0/1.0/1.0";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .kitty_color_protocol);

    p.reset();

    try testing.expectEqual(Parser.State.empty, p.state);
    p.next('X');
    try testing.expectEqual(Parser.State.invalid, p.state);

    p.reset();
}

test "OSC: kitty color protocol no key" {
    const testing = std.testing;

    var p: Parser = .{ .alloc = testing.allocator };
    defer p.deinit();

    const input = "21;";
    for (input) |ch| p.next(ch);

    const cmd = p.end('\x1b').?;
    try testing.expect(cmd == .kitty_color_protocol);
    try testing.expectEqual(0, cmd.kitty_color_protocol.list.items.len);
}
