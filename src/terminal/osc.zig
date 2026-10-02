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
const lib = @import("lib.zig");
const LibEnum = lib.Enum;
const kitty_color = @import("kitty/color.zig");
const parsers = @import("osc/parsers.zig");
const encoding = @import("osc/encoding.zig");

pub const color = parsers.color;
pub const semantic_prompt = parsers.semantic_prompt;
pub const program_status = parsers.program_status;

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

    /// Semantic prompt command: https://gitlab.freedesktop.org/Per_Bothner/specifications/blob/master/proposals/semantic-prompts.md
    semantic_prompt: SemanticPrompt,

    /// Set or get clipboard contents. If data is "?", then the current
    /// clipboard contents are sent to the pty. Otherwise, the contents
    /// are set on the clipboard.
    clipboard_contents: struct {
        kind: u8,
        data: [:0]const u8,
        terminator: Terminator = .st,
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
        op: color.Operation,
        requests: color.List = .{},
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

    /// ConEmu run process (OSC 9;7)
    conemu_run_process: [:0]const u8,

    /// ConEmu output environment variable (OSC 9;8)
    conemu_output_environment_variable: [:0]const u8,

    /// ConEmu XTerm keyboard and output emulation (OSC 9;10)
    /// https://conemu.github.io/en/TerminalModes.html
    conemu_xterm_emulation: struct {
        /// null => do not change
        /// false => turn off
        /// true => turn on
        keyboard: ?bool,
        /// null => do not change
        /// false => turn off
        /// true => turn on
        output: ?bool,
    },

    /// ConEmu comment (OSC 9;11)
    conemu_comment: [:0]const u8,

    /// Kitty text sizing protocol (OSC 66)
    kitty_text_sizing: parsers.kitty_text_sizing.OSC,

    kitty_clipboard_protocol: KittyClipboardProtocol,

    /// Kitty drag and drop protocol (OSC 72)
    kitty_dnd_protocol: KittyDndProtocol,

    /// OSC 3008. Hierarchical context signalling (UAPI spec).
    /// https://uapi-group.org/specifications/specs/osc_context/
    context_signal: parsers.context_signal.Command,

    /// Kitty desktop notifications (OSC 99)
    kitty_desktop_notification: KittyDesktopNotification,

    /// An OSC sequence whose number this parser does not implement. Only
    /// produced when `Parser.unknown_max_bytes` is nonzero.
    unknown: Unknown,

    /// Program status protocol (OSC 7501). A program reports what it is
    /// doing, such as working or waiting on the user, or asks whether the
    /// terminal supports the protocol. See `ProgramStatus`.
    program_status: ProgramStatus,

    pub const SemanticPrompt = parsers.semantic_prompt.Command;

    pub const KittyClipboardProtocol = parsers.kitty_clipboard_protocol.OSC;

    pub const KittyDndProtocol = parsers.kitty_dnd_protocol.OSC;

    pub const KittyDesktopNotification = parsers.kitty_desktop_notification.OSC;

    pub const ProgramStatus = parsers.program_status.Command;

    pub const Key = LibEnum(
        lib.target,
        // NOTE: Order matters, see LibEnum documentation.
        &.{
            "invalid",
            "change_window_title",
            "change_window_icon",
            "semantic_prompt",
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
            "conemu_run_process",
            "conemu_output_environment_variable",
            "conemu_xterm_emulation",
            "conemu_comment",
            "kitty_text_sizing",
            "kitty_clipboard_protocol",
            "kitty_dnd_protocol",
            "context_signal",
            "kitty_desktop_notification",
            "unknown",
            "program_status",
        },
    );

    /// An OSC sequence whose number this parser does not implement. For
    /// the sequence `ESC ] 7400;status=busy BEL`, `content` is
    /// "7400;status=busy" and `terminator` is `.bel`.
    pub const Unknown = struct {
        /// Every byte fed to the parser for this sequence, including the
        /// number at the start. Owned by the parser and only valid until
        /// the next parser call.
        ///
        /// When the bytes come from the VT stream, this never contains
        /// control characters (bytes below 0x20). Those end the sequence,
        /// cancel it, or are dropped before they reach the OSC parser.
        content: []const u8,

        /// True if the sequence was longer than `Parser.unknown_max_bytes`,
        /// or memory ran out while reading it. In that case `content`
        /// holds only the beginning of the sequence.
        truncated: bool,

        /// How the program ended the sequence. If you send a reply, end it
        /// the same way.
        terminator: Terminator,

        pub const C = extern struct {
            truncated: bool,
            content: lib.String,
            terminator: Terminator.C,
        };

        pub fn cval(self: Unknown) Unknown.C {
            return .{
                .truncated = self.truncated,
                .content = .init(self.content),
                .terminator = self.terminator.cval(),
            };
        }
    };

    pub const ProgressReport = struct {
        const state_keys = &.{
            "remove",
            "set",
            "error",
            "indeterminate",
            "pause",
        };

        pub const State = LibEnum(lib.target, state_keys);

        state: State,
        progress: ?u8 = null,

        // sync with ghostty_action_progress_report_s
        pub const C = extern struct {
            state: c_int,
            progress: i8,
        };

        pub fn cval(self: ProgressReport) C {
            return .{
                .state = @backingInt(self.state),
                .progress = if (self.progress) |progress| @intCast(std.math.clamp(
                    progress,
                    0,
                    100,
                )) else -1,
            };
        }

        test "ghostty.h Command.ProgressReport.State" {
            if (comptime build_options.artifact == .lib) return error.SkipZigTest;
            const CState = LibEnum(.c, state_keys);
            try lib.checkGhosttyHEnum(CState, "GHOSTTY_PROGRESS_STATE_");
        }
    };

    comptime {
        assert(@sizeOf(Command) == switch (@sizeOf(usize)) {
            4 => 44,
            8 => 64,
            else => unreachable,
        });
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
    pub const MAX_BUF = 2048;

    /// Maximum size of an OSC that requires dynamically allocated storage.
    /// OSC input is untrusted, so these captures must have a finite bound.
    pub const MAX_ALLOCATING_BUF = 8 * 1024 * 1024;

    /// Optional allocator used to accept data longer than MAX_BUF.
    /// This only applies to some commands (e.g. OSC 52) that can
    /// reasonably exceed MAX_BUF.
    alloc: ?Allocator,

    /// Maximum number of bytes retained by an allocating capture.
    /// This is configurable primarily so callers and tests can choose a
    /// smaller policy than the default.
    max_allocating_bytes: usize,

    /// The most bytes to keep from each OSC sequence whose number this
    /// parser does not implement.
    ///
    /// Zero, the default, discards these sequences. The parser stops
    /// reading one as soon as it sees a number it doesn't know, and `end`
    /// returns null. Any other value makes `end` return `Command.unknown`
    /// with the sequence's bytes, so you can implement the sequence
    /// yourself:
    ///
    /// ```zig
    /// var p: Parser = .init(alloc);
    /// defer p.deinit();
    /// p.unknown_max_bytes = 1024;
    ///
    /// p.nextSlice("7400;status=busy");
    /// const cmd = p.end(0x07).?; // .unknown, content "7400;status=busy"
    /// ```
    ///
    /// A sequence longer than the limit is still returned, with the
    /// first bytes up to the limit and `truncated` set to true.
    ///
    /// Limits up to `MAX_BUF` use a buffer inside the parser and never
    /// allocate. Larger limits allocate for each unknown sequence. Without
    /// an allocator, a larger limit behaves like `MAX_BUF`. If memory runs
    /// out partway through a sequence, it is returned truncated.
    ///
    /// Sequences with a number the parser does implement are not affected,
    /// even when their contents are malformed.
    unknown_max_bytes: usize,

    /// Current state of the parser.
    state: State,

    /// Buffer for temporary storage of OSC data
    buffer: [MAX_BUF]u8,

    /// Capture state. If this is set then we're actively capturing the
    /// bytes coming into the parser.
    capture: ?Capture,

    /// The command that is the result of parsing.
    command: Command,

    pub const State = enum {
        start,
        invalid,

        /// Collecting the bytes of a sequence whose number is not
        /// implemented, to return as `Command.unknown`. Only entered when
        /// `unknown_max_bytes` is nonzero.
        unknown,

        /// Like `unknown`, but the byte limit has been reached. Later bytes
        /// are dropped and the command is returned with `truncated` set.
        unknown_truncated,

        // OSC command prefixes. Not all of these are valid OSCs, but may be
        // needed to "bridge" to a valid OSC (e.g. to support OSC 777 we need to
        // have a state "77" even though there is no OSC 77).
        //
        // The name of each prefix state must be exactly the bytes consumed
        // to reach it. `beginUnknown` relies on this to recover the prefix.
        @"0",
        @"1",
        @"2",
        @"3",
        @"4",
        @"5",
        @"6",
        @"7",
        @"8",
        @"9",
        @"30",
        @"300",
        @"3008",
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
        @"55",
        @"66",
        @"72",
        @"75",
        @"750",
        @"7501",
        @"77",
        @"99",
        @"104",
        @"105",
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
        @"552",
        @"777",
        @"1337",
        @"5522",
    };

    pub fn init(alloc: ?Allocator) Parser {
        var result: Parser = .{
            .alloc = alloc,
            .max_allocating_bytes = MAX_ALLOCATING_BUF,
            .unknown_max_bytes = 0,
            .state = .start,
            .capture = null,
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
        // If we're capturing, then stop it.
        if (self.capture) |*cap| cap.deinit();

        // Handle any cleanup that individual OSCs require.
        switch (self.command) {
            .kitty_color_protocol => |*v| kitty_color_protocol: {
                v.deinit(self.alloc orelse break :kitty_color_protocol);
            },
            .color_operation => |*v| color_operation: {
                v.requests.deinit(self.alloc orelse break :color_operation);
            },
            .change_window_icon,
            .change_window_title,
            .clipboard_contents,
            .conemu_change_tab_title,
            .conemu_comment,
            .conemu_guimacro,
            .conemu_output_environment_variable,
            .conemu_progress_report,
            .conemu_run_process,
            .conemu_show_message_box,
            .conemu_sleep,
            .conemu_wait_input,
            .conemu_xterm_emulation,
            .hyperlink_end,
            .hyperlink_start,
            .invalid,
            .mouse_shape,
            .report_pwd,
            .semantic_prompt,
            .show_desktop_notification,
            .kitty_text_sizing,
            .kitty_clipboard_protocol,
            .kitty_dnd_protocol,
            .kitty_desktop_notification,
            .context_signal,
            .unknown,
            .program_status,
            => {},
        }

        self.state = .start;
        self.capture = null;
        self.command = .invalid;

        if (std.valgrind.runningOnValgrind() > 0) {
            // Initialize our undefined fields so Valgrind can catch it.
            // https://github.com/ziglang/zig/issues/19148
            self.buffer = undefined;
        }
    }

    /// Make sure that we have an allocator. If we don't, set the state to
    /// invalid so that any additional OSC data is discarded.
    inline fn ensureAllocator(self: *Parser) bool {
        if (self.alloc != null) return true;
        log.warn("An allocator is required to process OSC {t} but none was provided.", .{self.state});
        self.state = .invalid;
        return false;
    }

    const Capture = struct {
        writer: *std.Io.Writer,
        backing: Backing,
        max_bytes: usize,

        const Backing = union(enum) {
            fixed: std.Io.Writer,
            allocating: std.Io.Writer.Allocating,
        };

        const Mode = enum {
            fixed,
            allocating,
        };

        pub inline fn fixed(new: *?Capture, buf: []u8) void {
            new.* = .{
                .backing = .{ .fixed = .fixed(buf) },
                .writer = &new.*.?.backing.fixed,
                .max_bytes = buf.len,
            };
        }

        pub inline fn allocating(
            new: *?Capture,
            alloc: Allocator,
            max_bytes: usize,
        ) error{OutOfMemory}!void {
            new.* = .{
                .backing = .{ .allocating = try std.Io.Writer.Allocating.initCapacity(
                    alloc,
                    @min(MAX_BUF, max_bytes),
                ) },
                .writer = &new.*.?.backing.allocating.writer,
                .max_bytes = max_bytes,
            };
        }

        /// Append one byte without permitting the backing allocation to grow
        /// beyond max_bytes. Allocating.Writer normally grows super-linearly,
        /// so grow it explicitly to keep the allocation itself bounded too.
        pub inline fn writeByte(self: *Capture, byte: u8) error{WriteFailed}!void {
            if (self.writer.buffered().len >= self.max_bytes) return error.WriteFailed;

            switch (self.backing) {
                .fixed => {},
                .allocating => |*w| {
                    if (w.writer.end >= w.writer.buffer.len) {
                        const new_capacity = @min(
                            self.max_bytes,
                            @max(w.writer.buffer.len *| 2, 1),
                        );
                        w.writer.buffer = w.allocator.realloc(
                            w.writer.buffer,
                            new_capacity,
                        ) catch return error.WriteFailed;
                    }
                },
            }

            try self.writer.writeByte(byte);
        }

        /// Append a slice without permitting the backing allocation to
        /// grow beyond max_bytes. This matches the byte-at-a-time
        /// semantics of writeByte: bytes are retained up to exactly
        /// max_bytes and the first byte that doesn't fit fails the
        /// write.
        pub fn writeSlice(
            self: *Capture,
            bytes: []const u8,
        ) error{WriteFailed}!void {
            const avail = self.max_bytes - self.writer.buffered().len;
            const n = @min(bytes.len, avail);

            switch (self.backing) {
                .fixed => {},
                .allocating => |*w| {
                    const needed = w.writer.end + n;
                    if (needed > w.writer.buffer.len) {
                        const new_capacity = @min(
                            self.max_bytes,
                            @max(w.writer.buffer.len *| 2, needed),
                        );
                        w.writer.buffer = w.allocator.realloc(
                            w.writer.buffer,
                            new_capacity,
                        ) catch return error.WriteFailed;
                    }
                },
            }

            try self.writer.writeAll(bytes[0..n]);
            if (n < bytes.len) return error.WriteFailed;
        }

        pub fn deinit(self: *Capture) void {
            switch (self.backing) {
                .fixed => {},
                .allocating => |*w| w.deinit(),
            }
        }

        /// Return the captured trailing data. This is the data from the
        /// point that trailing data capture was requested.
        pub inline fn trailing(self: *Capture) []u8 {
            return self.writer.buffered();
        }
    };

    /// Begin capturing trailing data. All inputs to next from this point
    /// forward will be captured into the `self.capture.writer` buffer
    /// which may be backed by either a fixed size or allocating buffer
    /// depending on mode.
    ///
    /// Get the trailing data using `capture.trailing()`. Do not access
    /// the writer directly.
    inline fn captureTrailing(
        self: *Parser,
        comptime mode: Capture.Mode,
    ) void {
        assert(self.capture == null);
        switch (mode) {
            .fixed => Capture.fixed(
                &self.capture,
                &self.buffer,
            ),

            .allocating => {
                const alloc = self.alloc orelse {
                    // We don't have an allocator - fall back to a fixed buffer and hope
                    // that it's big enough.
                    self.captureTrailing(.fixed);
                    return;
                };

                Capture.allocating(
                    &self.capture,
                    alloc,
                    self.max_allocating_bytes,
                ) catch {
                    // The allocator failed for some reason, fall back to a fixed buffer
                    // and hope that it's big enough.
                    self.captureTrailing(.fixed);
                    return;
                };
            },
        }
    }

    /// Called when the sequence's number turns out not to be one this
    /// parser implements, either at byte c or at the end of the sequence
    /// (c is null). Supported OSCs never reach this.
    ///
    /// With `unknown_max_bytes` at zero, this marks the sequence invalid,
    /// exactly as the parser did before unknown sequences were supported.
    /// Otherwise it starts collecting the sequence's bytes. The digits read
    /// so far are not stored anywhere, but the current state's name is
    /// exactly those digits (state `.@"13"` after reading "13"). So the
    /// state name is written first, then c, and the collected bytes hold
    /// the whole sequence from its first byte.
    ///
    /// This is deliberately not inline. It is referenced from every
    /// prefix state in `next`, and inlining it there grows the state
    /// machine enough to measurably slow per-byte parsing of supported
    /// OSCs (about 4% in the osc-parser benchmark).
    noinline fn unknownOrInvalid(self: *Parser, c: ?u8) void {
        const max_bytes = self.unknown_max_bytes;
        if (max_bytes == 0) {
            @branchHint(.likely);
            self.state = .invalid;
            return;
        }

        assert(self.capture == null);
        const prefix: []const u8 = switch (self.state) {
            .start => "",
            .invalid, .unknown, .unknown_truncated => unreachable,
            inline else => |s| @tagName(s),
        };
        self.state = .unknown;

        // Limits past the fixed buffer need an allocation. Without an
        // allocator, or if allocating fails, the fixed buffer is used and
        // longer sequences are reported as truncated.
        const alloc = if (max_bytes > MAX_BUF) self.alloc else null;
        if (alloc) |a| {
            Capture.allocating(&self.capture, a, max_bytes) catch
                Capture.fixed(&self.capture, &self.buffer);
        } else {
            Capture.fixed(&self.capture, self.buffer[0..@min(max_bytes, MAX_BUF)]);
        }

        const cap = &self.capture.?;
        cap.writeSlice(prefix) catch return self.captureFailed();
        if (c) |byte| cap.writeByte(byte) catch return self.captureFailed();
    }

    /// Handle a failed capture write, either from reaching the capture's
    /// limit or from an allocation failure. Supported OSCs become invalid.
    /// Unknown OSCs keep what was captured and are reported as truncated.
    ///
    /// This is inline so the supported-OSC overflow path stays a single
    /// store, as it was before unknown capture existed.
    inline fn captureFailed(self: *Parser) void {
        switch (self.state) {
            .unknown => {
                // Pin the limit to what was retained so every later write
                // fails at the first bounds check. Without this, a later
                // allocating write could succeed after an allocation
                // failure and leave a gap in the content.
                const cap = &self.capture.?;
                cap.max_bytes = cap.trailing().len;
                self.state = .unknown_truncated;
            },
            // Already truncated: the write failed at the first bounds
            // check and there is nothing more to do.
            .unknown_truncated => {},
            else => self.state = .invalid,
        }
    }

    /// Consume a slice of bytes, advancing the parser state. This is
    /// equivalent to calling `next` for each byte in order, but is much
    /// faster once a data capture is active because the remaining bytes
    /// are appended to the capture in bulk.
    pub fn nextSlice(self: *Parser, input: []const u8) void {
        if (self.state == .invalid) return;

        // Run the state machine byte-at-a-time until a capture begins.
        // The command prefix before a capture starts is only a handful
        // of bytes so this loop is short in practice.
        var offset: usize = 0;
        while (self.capture == null) {
            if (offset >= input.len) return;
            self.next(input[offset]);
            offset += 1;
            if (self.state == .invalid) return;
        }

        const rem = input[offset..];
        if (rem.len == 0) return;
        self.capture.?.writeSlice(rem) catch |err| switch (err) {
            // We have overflowed our buffer or had some other error.
            // Discard any further input.
            error.WriteFailed => self.captureFailed(),
        };
    }

    /// Consume the next character c and advance the parser state.
    pub fn next(self: *Parser, c: u8) void {
        // If the state becomes invalid for any reason, just discard
        // any further input.
        if (self.state == .invalid) return;

        // If a writer has been initialized, we just accumulate the rest of the
        // OSC sequence in the writer's buffer and skip the state machine.
        if (self.capture) |*cap| {
            cap.writeByte(c) catch |err| switch (err) {
                // We have overflowed our buffer or had some other error.
                // Discard any further input.
                error.WriteFailed => self.captureFailed(),
            };
            return;
        }

        switch (self.state) {
            // handled above, so should never be here
            .invalid => unreachable,

            // unknown states always have an active capture
            .unknown, .unknown_truncated => unreachable,

            .start => switch (c) {
                '0' => self.state = .@"0",
                '1' => self.state = .@"1",
                '2' => self.state = .@"2",
                '3' => self.state = .@"3",
                '4' => self.state = .@"4",
                '5' => self.state = .@"5",
                '6' => self.state = .@"6",
                '7' => self.state = .@"7",
                '8' => self.state = .@"8",
                '9' => self.state = .@"9",
                else => self.unknownOrInvalid(c),
            },

            .@"3" => switch (c) {
                '0' => self.state = .@"30",
                else => self.unknownOrInvalid(c),
            },

            .@"30" => switch (c) {
                '0' => self.state = .@"300",
                else => self.unknownOrInvalid(c),
            },

            .@"300" => switch (c) {
                '8' => self.state = .@"3008",
                else => self.unknownOrInvalid(c),
            },

            .@"3008" => switch (c) {
                ';' => self.captureTrailing(.fixed),
                else => self.unknownOrInvalid(c),
            },

            .@"1" => switch (c) {
                ';' => self.captureTrailing(.fixed),
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
                else => self.unknownOrInvalid(c),
            },

            .@"10" => switch (c) {
                ';' => if (self.ensureAllocator()) self.captureTrailing(.fixed),
                '4' => self.state = .@"104",
                '5' => self.state = .@"105",
                else => self.unknownOrInvalid(c),
            },

            .@"11" => switch (c) {
                ';' => if (self.ensureAllocator()) self.captureTrailing(.fixed),
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
                else => self.unknownOrInvalid(c),
            },

            .@"4",
            .@"12",
            .@"14",
            .@"15",
            .@"16",
            .@"17",
            .@"18",
            .@"19",
            .@"21",
            .@"104",
            .@"105",
            .@"110",
            .@"111",
            .@"112",
            .@"113",
            .@"114",
            .@"115",
            .@"116",
            .@"117",
            .@"118",
            .@"119",
            => switch (c) {
                ';' => if (self.ensureAllocator()) self.captureTrailing(.fixed),
                else => self.unknownOrInvalid(c),
            },

            .@"13" => switch (c) {
                ';' => if (self.ensureAllocator()) self.captureTrailing(.fixed),
                '3' => self.state = .@"133",
                else => self.unknownOrInvalid(c),
            },

            .@"2" => switch (c) {
                ';' => self.captureTrailing(.fixed),
                '1' => self.state = .@"21",
                '2' => self.state = .@"22",
                else => self.unknownOrInvalid(c),
            },

            .@"5" => switch (c) {
                ';' => if (self.ensureAllocator()) self.captureTrailing(.fixed),
                '2' => self.state = .@"52",
                '5' => self.state = .@"55",
                else => self.unknownOrInvalid(c),
            },

            .@"6" => switch (c) {
                '6' => self.state = .@"66",
                else => self.unknownOrInvalid(c),
            },

            .@"52",
            .@"66",
            => switch (c) {
                ';' => self.captureTrailing(.allocating),
                else => self.unknownOrInvalid(c),
            },

            .@"55" => switch (c) {
                '2' => self.state = .@"552",
                else => self.unknownOrInvalid(c),
            },

            .@"7" => switch (c) {
                ';' => self.captureTrailing(.fixed),
                '2' => self.state = .@"72",
                '5' => self.state = .@"75",
                '7' => self.state = .@"77",
                else => self.unknownOrInvalid(c),
            },

            .@"75" => switch (c) {
                '0' => self.state = .@"750",
                else => self.unknownOrInvalid(c),
            },

            .@"750" => switch (c) {
                '1' => self.state = .@"7501",
                else => self.unknownOrInvalid(c),
            },

            .@"7501" => switch (c) {
                ';' => self.captureTrailing(.allocating),
                else => self.unknownOrInvalid(c),
            },

            .@"72" => switch (c) {
                ';' => self.captureTrailing(.allocating),
                else => self.unknownOrInvalid(c),
            },

            .@"77" => switch (c) {
                '7' => self.state = .@"777",
                else => self.unknownOrInvalid(c),
            },

            .@"133",
            => switch (c) {
                ';' => self.captureTrailing(.fixed),
                '7' => self.state = .@"1337",
                else => self.unknownOrInvalid(c),
            },

            .@"552" => switch (c) {
                '2' => self.state = .@"5522",
                else => self.unknownOrInvalid(c),
            },

            .@"1337",
            => switch (c) {
                ';' => self.captureTrailing(.fixed),
                else => self.unknownOrInvalid(c),
            },

            .@"5522",
            => switch (c) {
                ';' => self.captureTrailing(.allocating),
                else => self.unknownOrInvalid(c),
            },

            .@"9",
            => switch (c) {
                ';' => self.captureTrailing(.fixed),
                '9' => self.state = .@"99",
                else => self.unknownOrInvalid(c),
            },

            .@"99",
            => switch (c) {
                // OSC 99 encoded payloads can exceed the fixed buffer.
                ';' => self.captureTrailing(.allocating),
                else => self.unknownOrInvalid(c),
            },

            .@"0",
            .@"22",
            .@"777",
            .@"8",
            => switch (c) {
                ';' => self.captureTrailing(.fixed),
                else => self.unknownOrInvalid(c),
            },
        }
    }

    /// End the sequence and return the command it contains, or null if it
    /// isn't a valid command.
    ///
    /// `terminator_ch` is the byte that ended the sequence. Commands that
    /// reply to the program end their reply the same way: BEL (0x07) gets
    /// a BEL reply, and any other byte, or null, gets an ST reply.
    ///
    /// A program can also cancel a sequence partway through by sending CAN
    /// or SUB instead of a terminator. Pass that byte as `terminator_ch`.
    /// The sequence is then discarded and this returns null, whatever
    /// command it contained. This matches xterm.
    ///
    /// ```zig
    /// p.nextSlice("2;hello");
    ///
    /// // The program sent CAN instead of BEL, so the title never changes.
    /// const cmd = p.end(std.ascii.control_code.can); // null
    /// ```
    ///
    /// The returned pointer is only valid until the next call to the parser.
    /// Copy out any data you need to keep.
    pub fn end(self: *Parser, terminator_ch: ?u8) ?*Command {
        if (terminator_ch) |ch| switch (ch) {
            std.ascii.control_code.can,
            std.ascii.control_code.sub,
            => return null,
            else => {},
        };

        return switch (self.state) {
            .start => null,

            .invalid => null,

            .unknown,
            .unknown_truncated,
            => parsers.unknown.parse(self, terminator_ch),

            // These states only lead to longer numbers (3 leads to 3008)
            // and are not OSCs themselves, so ending on one is unknown.
            .@"3",
            .@"30",
            .@"300",
            .@"55",
            .@"552",
            .@"6",
            .@"75",
            .@"750",
            .@"77",
            => bridge: {
                self.unknownOrInvalid(null);
                if (self.state == .invalid) break :bridge null;
                break :bridge parsers.unknown.parse(self, terminator_ch);
            },

            .@"0",
            .@"2",
            => parsers.change_window_title.parse(self, terminator_ch),

            .@"1" => parsers.change_window_icon.parse(self, terminator_ch),

            .@"4",
            .@"5",
            .@"10",
            .@"11",
            .@"12",
            .@"13",
            .@"14",
            .@"15",
            .@"16",
            .@"17",
            .@"18",
            .@"19",
            .@"104",
            .@"105",
            .@"110",
            .@"111",
            .@"112",
            .@"113",
            .@"114",
            .@"115",
            .@"116",
            .@"117",
            .@"118",
            .@"119",
            => parsers.color.parse(self, terminator_ch),

            .@"7" => parsers.report_pwd.parse(self, terminator_ch),

            .@"8" => parsers.hyperlink.parse(self, terminator_ch),

            .@"9" => parsers.osc9.parse(self, terminator_ch),

            .@"21" => parsers.kitty_color.parse(self, terminator_ch),

            .@"22" => parsers.mouse_shape.parse(self, terminator_ch),

            .@"52" => parsers.clipboard_operation.parse(self, terminator_ch),

            .@"3008" => parsers.context_signal.parse(self, terminator_ch),

            .@"66" => parsers.kitty_text_sizing.parse(self, terminator_ch),

            .@"72" => parsers.kitty_dnd_protocol.parse(self, terminator_ch),

            .@"99" => parsers.kitty_desktop_notification.parse(self, terminator_ch),

            .@"7501" => parsers.program_status.parse(self, terminator_ch),

            .@"133" => parsers.semantic_prompt.parse(self, terminator_ch),

            .@"777" => parsers.rxvt_extension.parse(self, terminator_ch),

            .@"1337" => parsers.iterm2.parse(self, terminator_ch),

            .@"5522" => parsers.kitty_clipboard_protocol.parse(self, terminator_ch),
        };
    }
};

test {
    _ = parsers;
    _ = encoding;
}

test "Parser end with CAN or SUB cancels the command" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();

    // A fixed capture (OSC 2) cancelled by CAN.
    for ("2;title") |ch| p.next(ch);
    try testing.expect(p.end(std.ascii.control_code.can) == null);

    // An allocating capture (OSC 52) cancelled by SUB.
    p.reset();
    for ("52;c;Zm9v") |ch| p.next(ch);
    try testing.expect(p.end(std.ascii.control_code.sub) == null);

    // The parser still works normally after a cancel.
    p.reset();
    for ("2;title") |ch| p.next(ch);
    const cmd = p.end(std.ascii.control_code.bel).?.*;
    try testing.expect(cmd == .change_window_title);
    try testing.expectEqualStrings("title", cmd.change_window_title);
}

test "Parser allocating captures have a hard limit" {
    const testing = std.testing;
    const prefixes = [_][]const u8{ "52;", "66;", "72;", "99;", "5522;" };
    const limit = Parser.MAX_BUF + 1;

    for (prefixes) |prefix| {
        var p: Parser = .init(testing.allocator);
        defer p.deinit();
        p.max_allocating_bytes = limit;

        for (prefix) |ch| p.next(ch);
        for (0..limit) |_| p.next('a');

        const cap = &p.capture.?;
        try testing.expectEqual(@as(usize, limit), cap.trailing().len);
        try testing.expectEqual(@as(usize, limit), cap.writer.buffer.len);

        p.next('a');
        try testing.expectEqual(Parser.State.invalid, p.state);
        try testing.expectEqual(@as(usize, limit), cap.trailing().len);
        try testing.expectEqual(@as(usize, limit), cap.writer.buffer.len);
    }
}

test "Parser nextSlice allocating captures have a hard limit" {
    const testing = std.testing;
    const limit = Parser.MAX_BUF + 1;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();
    p.max_allocating_bytes = limit;

    const data = try testing.allocator.alloc(u8, limit);
    defer testing.allocator.free(data);
    @memset(data, 'a');

    // Exactly at the limit stays valid and bounded.
    p.nextSlice("52;");
    p.nextSlice(data);
    const cap = &p.capture.?;
    try testing.expect(p.state != .invalid);
    try testing.expectEqual(@as(usize, limit), cap.trailing().len);
    try testing.expectEqual(@as(usize, limit), cap.writer.buffer.len);

    // One more byte overflows: the state becomes invalid and the
    // retained bytes and allocation stay bounded.
    p.nextSlice("a");
    try testing.expectEqual(Parser.State.invalid, p.state);
    try testing.expectEqual(@as(usize, limit), cap.trailing().len);
    try testing.expectEqual(@as(usize, limit), cap.writer.buffer.len);
    try testing.expect(p.end(null) == null);
}

test "Parser nextSlice overflowing slice is truncated at the limit" {
    const testing = std.testing;

    var p: Parser = .init(testing.allocator);
    defer p.deinit();
    p.max_allocating_bytes = 4;

    p.nextSlice("52;abcdef");
    try testing.expectEqual(Parser.State.invalid, p.state);
    try testing.expect(p.end(null) == null);

    const cap = &p.capture.?;
    try testing.expectEqualStrings("abcd", cap.trailing());
    try testing.expectEqual(@as(usize, 4), cap.writer.buffer.len);
}

test "Parser nextSlice matches per-byte parsing" {
    const testing = std.testing;
    const input = "52;c;aGVsbG8=";

    // Every two-way split of the input must parse identically to
    // the byte-at-a-time path.
    for (0..input.len + 1) |split| {
        var p: Parser = .init(testing.allocator);
        defer p.deinit();
        p.nextSlice(input[0..split]);
        p.nextSlice(input[split..]);

        const cmd = p.end(null).?.*;
        try testing.expect(cmd == .clipboard_contents);
        try testing.expectEqual(@as(u8, 'c'), cmd.clipboard_contents.kind);
        try testing.expectEqualStrings("aGVsbG8=", cmd.clipboard_contents.data);
    }
}

test "Parser allocating capture limit includes parser-added bytes" {
    const testing = std.testing;
    var p: Parser = .init(testing.allocator);
    defer p.deinit();
    p.max_allocating_bytes = 4;

    for ("52;abcd") |ch| p.next(ch);
    try testing.expect(p.end(null) == null);
    try testing.expectEqual(Parser.State.invalid, p.state);

    const cap = &p.capture.?;
    try testing.expectEqual(@as(usize, 4), cap.trailing().len);
    try testing.expectEqual(@as(usize, 4), cap.writer.buffer.len);
}
