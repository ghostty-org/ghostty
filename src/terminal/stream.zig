const streampkg = @This();
const std = @import("std");
const build_options = @import("terminal_options");
const assert = @import("../quirks.zig").inlineAssert;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const simd = @import("../simd/main.zig");
const lib = @import("lib.zig");
const Parser = @import("Parser.zig");
const ansi = @import("ansi.zig");
const charsets = @import("charsets.zig");
const device_attributes = @import("device_attributes.zig");
const xt_checksum = @import("xt_checksum.zig");
const device_status = @import("device_status.zig");
const csi = @import("csi.zig");
const kitty = @import("kitty.zig");
const modes = @import("modes.zig");
const osc = @import("osc.zig");
const sgr = @import("sgr.zig");
const continuationpkg = @import("stream_continuation.zig");
const UTF8Decoder = @import("UTF8Decoder.zig");
const MouseShape = @import("mouse.zig").Shape;

const log = std.log.scoped(.stream);

/// Flip this to true when you want verbose debug output for
/// debugging terminal stream issues. In addition to louder
/// output this will also disable the SIMD optimizations in
/// order to make it easier to see every byte. So if you're
/// debugging an issue in the SIMD code then you'll need to
/// do something else.
const debug = false;

/// The possible actions that can be emitted by the Stream
/// function for handling.
pub const Action = union(Key) {
    print: Print,
    print_slice: PrintSlice,
    print_repeat: usize,
    bell,
    backspace,
    horizontal_tab: u16,
    horizontal_tab_back: u16,
    linefeed,
    carriage_return,
    enquiry,
    invoke_charset: InvokeCharset,
    cursor_up: CursorMovement,
    cursor_down: CursorMovement,
    cursor_left: CursorMovement,
    cursor_right: CursorMovement,
    cursor_col: CursorMovement,
    cursor_row: CursorMovement,
    cursor_col_relative: CursorMovement,
    cursor_row_relative: CursorMovement,
    cursor_pos: CursorPos,
    cursor_style: ansi.CursorStyle,
    erase_display_below: bool,
    erase_display_above: bool,
    erase_display_complete: bool,
    erase_display_scrollback: bool,
    erase_display_scroll_complete: bool,
    erase_line_right: bool,
    erase_line_left: bool,
    erase_line_complete: bool,
    erase_line_right_unless_pending_wrap: bool,
    delete_chars: usize,
    erase_chars: usize,
    insert_lines: usize,
    insert_blanks: usize,
    delete_lines: usize,
    scroll_up: usize,
    scroll_down: usize,
    tab_clear_current,
    tab_clear_all,
    tab_set,
    tab_reset,
    index,
    next_line,
    reverse_index,
    full_reset,
    set_mode: Mode,
    reset_mode: Mode,
    save_mode: Mode,
    restore_mode: Mode,
    request_mode: Mode,
    request_mode_unknown: RawMode,
    top_and_bottom_margin: Margin,
    left_and_right_margin: Margin,
    left_and_right_margin_ambiguous,
    save_cursor,
    restore_cursor,
    modify_key_format: ansi.ModifyKeyFormat,
    mouse_shift_capture: bool,
    protected_mode_off,
    protected_mode_iso,
    protected_mode_dec,
    size_report: csi.SizeReportStyle,
    title_push: u16,
    title_pop: u16,
    xtversion,
    device_attributes: device_attributes.Req,
    device_status: DeviceStatus,
    kitty_keyboard_query,
    kitty_keyboard_push: KittyKeyboardFlags,
    kitty_keyboard_pop: u16,
    kitty_keyboard_set: KittyKeyboardFlags,
    kitty_keyboard_set_or: KittyKeyboardFlags,
    kitty_keyboard_set_not: KittyKeyboardFlags,
    dcs_hook: Parser.Action.DCS,
    dcs_put: u8,
    dcs_unhook,
    apc_start,
    apc_end: ApcEnd,
    apc_put: u8,
    apc_put_slice: ApcPutSlice,
    end_hyperlink,
    active_status_display: ansi.StatusDisplay,
    decaln,
    window_title: WindowTitle,
    report_pwd: ReportPwd,
    show_desktop_notification: ShowDesktopNotification,
    progress_report: osc.Command.ProgressReport,
    start_hyperlink: StartHyperlink,
    clipboard_contents: ClipboardContents,
    mouse_shape: MouseShape,
    configure_charset: ConfigureCharset,
    set_attributes: SetAttributes,
    kitty_color_report: kitty.color.OSC,
    color_operation: ColorOperation,
    semantic_prompt: SemanticPrompt,
    kitty_clipboard: KittyClipboard,
    kitty_dnd: KittyDnd,
    resize_window: ResizeWindow,
    osc_unknown: osc.Command.Unknown,
    mouse_shape_reset,
    request_xt_checksum: xt_checksum.Request,
    xt_checksum_extension: XtChecksumExtension,
    program_status: ProgramStatus,
    soft_reset,
    back_index,
    forward_index,
    insert_columns: usize,
    delete_columns: usize,

    pub const Key = lib.Enum(
        lib.target,
        &.{
            "print",
            "print_slice",
            "print_repeat",
            "bell",
            "backspace",
            "horizontal_tab",
            "horizontal_tab_back",
            "linefeed",
            "carriage_return",
            "enquiry",
            "invoke_charset",
            "cursor_up",
            "cursor_down",
            "cursor_left",
            "cursor_right",
            "cursor_col",
            "cursor_row",
            "cursor_col_relative",
            "cursor_row_relative",
            "cursor_pos",
            "cursor_style",
            "erase_display_below",
            "erase_display_above",
            "erase_display_complete",
            "erase_display_scrollback",
            "erase_display_scroll_complete",
            "erase_line_right",
            "erase_line_left",
            "erase_line_complete",
            "erase_line_right_unless_pending_wrap",
            "delete_chars",
            "erase_chars",
            "insert_lines",
            "insert_blanks",
            "delete_lines",
            "scroll_up",
            "scroll_down",
            "tab_clear_current",
            "tab_clear_all",
            "tab_set",
            "tab_reset",
            "index",
            "next_line",
            "reverse_index",
            "full_reset",
            "set_mode",
            "reset_mode",
            "save_mode",
            "restore_mode",
            "request_mode",
            "request_mode_unknown",
            "top_and_bottom_margin",
            "left_and_right_margin",
            "left_and_right_margin_ambiguous",
            "save_cursor",
            "restore_cursor",
            "modify_key_format",
            "mouse_shift_capture",
            "protected_mode_off",
            "protected_mode_iso",
            "protected_mode_dec",
            "size_report",
            "title_push",
            "title_pop",
            "xtversion",
            "device_attributes",
            "device_status",
            "kitty_keyboard_query",
            "kitty_keyboard_push",
            "kitty_keyboard_pop",
            "kitty_keyboard_set",
            "kitty_keyboard_set_or",
            "kitty_keyboard_set_not",
            "dcs_hook",
            "dcs_put",
            "dcs_unhook",
            "apc_start",
            "apc_end",
            "apc_put",
            "apc_put_slice",
            "end_hyperlink",
            "active_status_display",
            "decaln",
            "window_title",
            "report_pwd",
            "show_desktop_notification",
            "progress_report",
            "start_hyperlink",
            "clipboard_contents",
            "mouse_shape",
            "configure_charset",
            "set_attributes",
            "kitty_color_report",
            "color_operation",
            "semantic_prompt",
            "kitty_clipboard",
            "kitty_dnd",
            "resize_window",
            "osc_unknown",
            "mouse_shape_reset",
            "request_xt_checksum",
            "xt_checksum_extension",
            "program_status",
            "soft_reset",
            "back_index",
            "forward_index",
            "insert_columns",
            "delete_columns",
        },
    );

    /// C ABI functions.
    const c_union = lib.TaggedUnion(
        lib.target,
        @This(),
        // TODO: Before shipping an ABI-compatible libghostty, verify this.
        // This was just arbitrarily chosen for now.
        .{ .padding = [16]u64 },
    );
    pub const Tag = c_union.Tag;
    pub const Value = c_union.Value;
    pub const C = c_union.C;
    pub const CValue = c_union.CValue;
    pub const cval = c_union.cval;

    /// Field types
    pub const Print = struct {
        cp: u21,

        pub const C = extern struct {
            cp: u32,
        };

        pub fn cval(self: Print) Print.C {
            return .{ .cp = @intCast(self.cp) };
        }
    };

    /// A run of printable codepoints. This is emitted instead of
    /// individual print actions when the stream can decode multiple
    /// printable codepoints at once, so handlers can process them in
    /// batch with per-run rather than per-codepoint overhead (see
    /// Terminal.printSlice). A naive handler can simply loop and
    /// handle each codepoint like a print action.
    ///
    /// The slice is only valid for the duration of the handler call.
    pub const PrintSlice = struct {
        cps: []const u32,

        pub const C = extern struct {
            cps: [*]const u32,
            len: usize,
        };

        pub fn cval(self: PrintSlice) PrintSlice.C {
            return .{ .cps = self.cps.ptr, .len = self.cps.len };
        }
    };

    /// All the attributes of one SGR sequence (`CSI ... m`), as its raw
    /// parameters. A handler iterates them with `parser`. Sending the
    /// whole sequence at once lets a handler apply every attribute
    /// before doing per-sequence work, such as interning the resulting
    /// style, instead of repeating that work per attribute.
    ///
    /// The slice is only valid for the duration of the handler call.
    pub const SetAttributes = struct {
        params: []const u16,
        params_sep: Parser.Action.CSI.SepList,

        /// A parser over the attributes of this sequence.
        pub fn parser(self: SetAttributes) sgr.Parser {
            return .{
                .params = self.params,
                .params_sep = self.params_sep,
            };
        }

        pub const C = extern struct {
            params: [*]const u16,
            len: usize,
            /// Bit `i` is set when a colon follows `params[i]`, as in
            /// `ghostty_sgr_parser_set_params` separators.
            params_sep: u32,
        };

        pub fn cval(self: SetAttributes) SetAttributes.C {
            return .{
                .params = self.params.ptr,
                .len = self.params.len,
                .params_sep = self.params_sep.mask,
            };
        }
    };

    pub const ApcPutSlice = struct {
        bytes: []const u8,

        pub const C = extern struct {
            bytes: [*]const u8,
            len: usize,
        };

        pub fn cval(self: ApcPutSlice) ApcPutSlice.C {
            return .{ .bytes = self.bytes.ptr, .len = self.bytes.len };
        }
    };

    /// Sent when an APC string ends, for any reason.
    ///
    /// An APC is only complete when it ends with the string terminator,
    /// either `ESC \` or the 8-bit 0x9C. A program can also stop an APC
    /// partway through. CAN (0x18) or SUB (0x1A) cancels it, and any other
    /// 8-bit control byte, such as CSI (0x9B), aborts it. ECMA-48 says a
    /// string stopped this way must be thrown away, so a handler should
    /// only act on the APC when `terminated` is true.
    ///
    /// ```zig
    /// .apc_end => |value| {
    ///     var cmd = apc_handler.end() orelse return;
    ///     defer cmd.deinit(alloc);
    ///     if (!value.terminated) return;
    ///     run(cmd);
    /// },
    /// ```
    pub const ApcEnd = extern struct {
        /// True when the string terminator ended the APC. False when the
        /// APC was cancelled or aborted, in which case its contents
        /// should be discarded.
        terminated: bool,
    };

    pub const InvokeCharset = lib.Struct(lib.target, struct {
        bank: charsets.ActiveSlot,
        charset: charsets.Slots,
        locking: bool,
    });

    pub const CursorMovement = extern struct {
        /// The value of the cursor movement. Depending on the tag of this
        /// union this may be an absolute value or it may be a relative
        /// value. For example, `cursor_up` is relative, but `cursor_row`
        /// is absolute.
        value: u16,
    };

    pub const CursorPos = extern struct {
        row: u16,
        col: u16,
    };

    pub const DeviceStatus = struct {
        request: device_status.Request,

        /// The id that a DECCKSR (memory_checksum) request asks to have
        /// echoed in its reply. Zero for every other request.
        id: u16 = 0,

        pub const C = extern struct {
            request: u16,
            id: u16,
        };

        pub fn cval(self: DeviceStatus) DeviceStatus.C {
            return .{
                .request = @bitCast(self.request),
                .id = self.id,
            };
        }
    };

    pub const Mode = struct {
        mode: modes.Mode,

        pub const C = u16;

        pub fn cval(self: Mode) Mode.C {
            return @bitCast(self.mode);
        }
    };

    pub const RawMode = extern struct {
        mode: u16,
        ansi: bool,
    };

    pub const Margin = extern struct {
        top_left: u16,
        bottom_right: u16,
    };

    /// A request to resize the window's text area (CSI 8 t). A value
    /// of zero means the parameter was omitted or zero, and the current
    /// size for that dimension should be kept. xterm treats an explicit
    /// zero as the screen size, but we can't distinguish it from omitted.
    pub const ResizeWindow = extern struct {
        rows: u16,
        columns: u16,
    };

    pub const XtChecksumExtension = struct {
        flags: xt_checksum.Flags,

        pub const C = u8;

        pub fn cval(self: XtChecksumExtension) XtChecksumExtension.C {
            return @as(u5, @bitCast(self.flags));
        }
    };

    pub const KittyKeyboardFlags = struct {
        flags: kitty.KeyFlags,

        pub const C = u8;

        pub fn cval(self: KittyKeyboardFlags) KittyKeyboardFlags.C {
            return @intCast(self.flags.int());
        }
    };

    pub const WindowTitle = struct {
        title: []const u8,

        pub const C = lib.String;

        pub fn cval(self: WindowTitle) WindowTitle.C {
            return .init(self.title);
        }
    };

    pub const ReportPwd = struct {
        url: []const u8,

        pub const C = lib.String;

        pub fn cval(self: ReportPwd) ReportPwd.C {
            return .init(self.url);
        }
    };

    pub const ShowDesktopNotification = struct {
        title: []const u8,
        body: []const u8,

        pub const C = extern struct {
            title: lib.String,
            body: lib.String,
        };

        pub fn cval(self: ShowDesktopNotification) ShowDesktopNotification.C {
            return .{
                .title = .init(self.title),
                .body = .init(self.body),
            };
        }
    };

    pub const StartHyperlink = struct {
        uri: []const u8,
        id: ?[]const u8,

        pub const C = extern struct {
            uri: lib.String,
            id: lib.String,
        };

        pub fn cval(self: StartHyperlink) StartHyperlink.C {
            return .{
                .uri = .init(self.uri),
                .id = .init(self.id orelse ""),
            };
        }
    };

    pub const ClipboardContents = struct {
        kind: u8,
        data: []const u8,
        terminator: osc.Terminator,

        pub const C = extern struct {
            kind: u8,
            data: lib.String,
        };

        pub fn cval(self: ClipboardContents) ClipboardContents.C {
            return .{
                .kind = self.kind,
                .data = .init(self.data),
            };
        }
    };

    pub const ConfigureCharset = lib.Struct(lib.target, struct {
        slot: charsets.Slots,
        charset: charsets.Charset,
    });

    pub const ColorOperation = struct {
        op: osc.color.Operation,
        requests: osc.color.List,
        terminator: osc.Terminator,

        pub const C = void;

        pub fn cval(_: ColorOperation) ColorOperation.C {
            return {};
        }
    };

    pub const SemanticPrompt = osc.Command.SemanticPrompt;

    pub const KittyClipboard = osc.Command.KittyClipboardProtocol;

    pub const KittyDnd = osc.Command.KittyDndProtocol;

    pub const ProgramStatus = osc.Command.ProgramStatus;
};

/// Returns a type that can process a stream of tty control characters.
/// This will call the `vt` function on type T with the following signature:
///
///   fn(comptime action: Action.Key, value: Action.Value(action)) void
///
/// The handler type T can choose to react to whatever actions it cares
/// about in its pursuit of implementing a terminal emulator or other
/// functionality.
///
/// Note that printable text is delivered via `print_slice` actions
/// (runs of codepoints) whenever the stream can decode multiple
/// codepoints at once, and via `print` actions otherwise. Handlers
/// that care about text must handle both.
///
/// The Handler type must also have a `deinit` function.
///
/// The "comptime" key is on purpose (vs. a standard Zig tagged union)
/// because it allows the compiler to optimize away unimplemented actions.
/// e.g. you don't need to pay a conditional branching cost on every single
/// action because the Zig compiler codegens separate code paths for every
/// single action at comptime.
pub fn Stream(comptime H: type) type {
    return struct {
        const Self = @This();

        pub const Action = streampkg.Action;
        pub const Handler = H;

        const T = switch (@typeInfo(Handler)) {
            .pointer => |p| p.child,
            else => Handler,
        };

        handler: Handler,
        parser: Parser,
        utf8decoder: UTF8Decoder,
        continuation: ?continuationpkg.Tracker,

        pub const Options = struct {
            /// The handler initial value, must be set.
            handler: Handler,

            /// Allocator to use. If this is not set then the stream
            /// will be fully allocation free. There are some operations
            /// that will be dropped in this case such as OSC 52 clipboard
            /// ops.
            allocator: ?Allocator = null,

            /// Maximum size in bytes of the continuation suffix. If this is
            /// null or zero then continuation tracking is disabled. This is
            /// only applied when `allocator` is non-null; without an allocator
            /// continuation tracking is disabled. Feeding this continuation
            /// suffix into an equivalent stream at ground reconstructs the
            /// unfinished state without repeating committed terminal effects.
            /// Continuation tracking is only supported by TerminalStream.
            continuation_max_bytes: ?usize = null,

            /// The most bytes to keep from each OSC sequence whose number
            /// the OSC parser does not implement. Zero, the default,
            /// discards these sequences. Any other value sends them to the
            /// handler as `osc_unknown` actions. See
            /// `osc.Parser.unknown_max_bytes` for how the limit behaves.
            ///
            /// This only affects OSC. Other kinds of unknown sequences,
            /// such as APC, are collected by the handler and have their own
            /// limits there.
            osc_unknown_max_bytes: usize = 0,
        };

        /// Initialize a stream. Without an allocator, operations that require
        /// heap allocation are dropped.
        ///
        /// As a concrete example of something that requires heap allocation,
        /// consider OSC 52 (clipboard operations) which can be arbitrarily
        /// large.
        ///
        /// This takes ownership of the handler and will call deinit
        /// when the stream is deinitialized.
        pub fn init(options: Options) Self {
            // Initialize the parser
            var parser: Parser = .init();
            if (options.allocator) |alloc| parser.osc_parser.alloc = alloc;
            parser.osc_parser.unknown_max_bytes = options.osc_unknown_max_bytes;

            // Initialize the continuation tracker if one is requested.
            var tracker: ?continuationpkg.Tracker = null;
            if (options.allocator) |alloc| {
                if (options.continuation_max_bytes) |max_bytes| {
                    if (max_bytes > 0) tracker = .init(alloc, max_bytes);
                }
            }

            return .{
                .handler = options.handler,
                .parser = parser,
                .utf8decoder = .{},
                .continuation = tracker,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.continuation) |*tracker| tracker.deinit();
            self.parser.deinit();
            self.handler.deinit();
        }

        /// Write the current continuation suffix directly to a caller-owned
        /// writer. The caller must pause and serialize access to this Stream.
        pub fn writeContinuation(
            self: *const Self,
            writer: *std.Io.Writer,
        ) (std.Io.Writer.Error || error{
            ContinuationDisabled,
            ContinuationUnavailable,
        })!void {
            const tracker = self.continuation orelse
                return error.ContinuationDisabled;
            if (tracker.broken)
                return error.ContinuationUnavailable;
            try tracker.write(writer);
        }

        /// True when no continuation suffix is needed to reproduce the
        /// stream's current parsing state.
        pub inline fn ground(self: *const Self) bool {
            // Parser ground alone is not sufficient because the UTF-8
            // decoder may have some state.
            return self.parser.state == .ground and self.utf8decoder.state == 0;
        }

        /// Update the continuation suffix after one complete feed call.
        /// Must only be called when tracking is enabled.
        fn trackContinuation(self: *Self, input: []const u8) void {
            const tracker = &self.continuation.?;

            // If we're in a ground state, we have no continuation suffix
            // to track by definition.
            if (self.ground()) {
                tracker.reset();
                return;
            }

            // Retain the part of this feed needed to replay the unfinished
            // state. When the parser is grounded here, the feed must have
            // ended inside a UTF-8 codepoint instead, because the ground
            // check above covers both state machines.
            tracker.append(
                if (self.parser.state != .ground) .vt else .utf8,
                input,
            );
        }

        /// Process a string of characters.
        pub inline fn nextSlice(self: *Self, input: []const u8) void {
            self.nextSliceUntracked(input, false, {});

            // Continuation tracking is opt-in and this branch predicts
            // perfectly, so disabled streams pay nothing else here.
            if (self.continuation != null) self.trackContinuation(input);
        }

        /// Process input until the first byte that reaches one of
        /// `boundaries`, and stop right after that byte.
        ///
        /// Returns the stop, or null if the whole input was consumed
        /// without reaching a boundary. Only the consumed bytes are
        /// processed, so handler actions never run for bytes after the
        /// stop. Feed the rest of the input in a later call.
        ///
        /// The bytes consumed across a series of calls are exactly the
        /// bytes the stream parsed, in order, and a second stream fed those
        /// same bytes is in the same parser state at every stop. This is
        /// what a proxy that sits between a program and a terminal needs.
        /// It can find exactly where a control string starts and ends, or
        /// wait for a safe point before inserting its own output, using
        /// the same parse that drives its terminal.
        ///
        /// `.ground` is a state, not an event. If the stream is already at
        /// ground, this consumes nothing and returns a stop with
        /// `consumed == 0`. A loop that keeps asking for `.ground` with the
        /// same input never makes progress. After a ground stop, feed the
        /// next bytes without `.ground` in the set, or with `nextSlice`.
        ///
        /// This loop finds the content of every APC string in `input`.
        /// DCS and OSC strings work the same way with their own
        /// boundaries:
        ///
        /// ```zig
        /// const set: Boundary.Set = .initMany(&.{ .apc_start, .apc_end });
        /// var rest = input;
        /// var content_start: ?usize = null;
        /// while (stream.nextSliceUntil(rest, set)) |stop| {
        ///     const offset = input.len - rest.len;
        ///     if (stop.start != null) content_start = offset + stop.consumed;
        ///     if (stop.end != null) {
        ///         // The ending byte is consumed but is not content.
        ///         const content_end = offset + stop.consumed - 1;
        ///         handleApc(input[content_start.?..content_end]);
        ///     }
        ///     rest = rest[stop.consumed..];
        /// }
        /// ```
        ///
        /// The loop needs no special case for a string that ends with the
        /// two-byte terminator `ESC \`. The stop lands on the ESC, and the
        /// backslash is just the next byte of `rest`.
        ///
        /// Asking for `.ground` costs 1% to 5% over `nextSlice`, because the
        /// stream has to leave its fast path at every return to ground.
        /// Asking only for string boundaries costs nothing on the bulk
        /// paths that handle text and string payloads, and a little for
        /// each byte of an escape sequence. Every check is compiled out
        /// of `nextSlice`, so its code is unchanged whether or not this
        /// function is used.
        pub inline fn nextSliceUntil(
            self: *Self,
            input: []const u8,
            boundaries: Boundary.Set,
        ) ?Boundary.Stop {
            if (boundaries.contains(.ground) and self.ground()) return .{
                .consumed = 0,
                .reached = .initOne(.ground),
            };

            var u: Until = .{
                .boundaries = boundaries,
                .base = input.ptr,
            };
            self.nextSliceUntracked(input, true, &u);

            const consumed = if (u.stop) |stop| stop.consumed else input.len;
            if (self.continuation != null and consumed > 0) {
                self.trackContinuation(input[0..consumed]);
            }

            return u.stop;
        }

        /// In until mode, called after the byte just before `end` has been
        /// fully processed. Completes the stop if that byte reached a
        /// requested boundary (including ground, which is also checked
        /// here) and returns true when the caller must return.
        inline fn untilReached(self: *Self, u: *Until, end: [*]const u8) bool {
            const at_ground = u.boundaries.contains(.ground) and self.ground();
            if (u.stop == null and !at_ground) return false;
            const stop = u.stopPtr();
            stop.consumed = @intFromPtr(end) - @intFromPtr(u.base);
            if (at_ground) stop.reached.insert(.ground);
            return true;
        }

        inline fn nextSliceUntracked(
            self: *Self,
            input: []const u8,
            comptime until: bool,
            u: Until.Arg(until),
        ) void {
            // Byte-at-a-time parsing in debug mode only. Even without
            // SIMD support (build_options.simd == false, e.g. wasm), the
            // batched path below is much faster than per-byte dispatch
            // because it decodes UTF-8 in bulk (via scalar fallbacks) and
            // hands printable runs to the handler as print_slice actions.
            if (comptime debug) {
                for (input, 0..) |c, i| {
                    self.nextUntracked(c, until, u);
                    if (comptime until) {
                        if (self.untilReached(u, input.ptr + i + 1)) return;
                    }
                }
                return;
            }

            // This is the maximum number of codepoints we can decode
            // at one time for this function call. This is somewhat arbitrary
            // so if someone can demonstrate a better number then we can switch.
            var cp_buf: [4096]u32 = undefined;

            // Split the input into chunks that fit into cp_buf.
            var i: usize = 0;
            while (true) {
                const len = @min(cp_buf.len, input.len - i);
                self.nextSliceCapped(input[i .. i + len], &cp_buf, until, u);
                if (comptime until) if (u.stop != null) return;
                i += len;
                if (i >= input.len) break;
            }
        }

        inline fn nextSliceCapped(
            self: *Self,
            input: []const u8,
            cp_buf: []u32,
            comptime until: bool,
            u: Until.Arg(until),
        ) void {
            assert(input.len <= cp_buf.len);

            var offset: usize = 0;

            // If the scalar UTF-8 decoder was in the middle of processing
            // a code sequence, we continue until it's not.
            while (self.utf8decoder.state != 0) {
                if (offset >= input.len) return;
                self.nextUtf8(input[offset]);
                offset += 1;
            }
            // Completing the codepoint may have reached ground.
            if (comptime until) if (self.untilReached(u, input.ptr + offset)) return;
            if (offset >= input.len) return;

            // If we're not in the ground state then we process until
            // we are. This can happen if the last chunk of input put us
            // in the middle of a control sequence.
            offset += self.consumeUntilGround(input[offset..], until, u);
            if (comptime until) if (self.untilReached(u, input.ptr + offset)) return;
            if (offset >= input.len) return;
            offset += self.consumeAllEscapes(input[offset..], until, u);
            if (comptime until) if (self.untilReached(u, input.ptr + offset)) return;

            // If we're in the ground state then we can use SIMD to process
            // input until we see an ESC (0x1B), since all other characters
            // up to that point are just UTF-8.
            while (self.parser.state == .ground and offset < input.len) {
                const res = simd.vt.utf8DecodeUntilControlSeq(input[offset..], cp_buf);
                const cps = cp_buf[0..res.decoded];

                // Hand runs of printable codepoints to the handler as
                // print_slice actions so it can process them with
                // per-run rather than per-codepoint overhead.
                var i: usize = 0;
                while (i < cps.len) {
                    const cp = cps[i];
                    // C0 and UTF-8-decoded C1 controls never enter
                    // printable runs. A codepoint is one of those
                    // exactly when it has no bit set outside 0x9F:
                    // bits 0-4 and bit 7 cover 0x00-0x1F and
                    // 0x80-0x9F and nothing else, so a single
                    // AND-test classifies both ranges.
                    if ((cp & ~@as(u32, 0x9F)) == 0) {
                        @branchHint(.unlikely);
                        if (cp <= 0x1F) {
                            // C0 controls execute rather than print.
                            self.execute(@intCast(cp));
                        } else {
                            // C1 controls decoded from UTF-8 are ignored.
                            logUnsupportedOnce(
                                "ignoring UTF-8-decoded C1 controls, first: 0x{x}",
                                .{cp},
                                0x80,
                            );
                        }
                        i += 1;
                        continue;
                    }

                    // Find the end of the printable run. This is an
                    // early-exit search loop that LLVM won't
                    // auto-vectorize, and printable runs dominate real
                    // input, so scan several codepoints at a time
                    // manually (same idiom as the printSliceFill run
                    // scan).
                    var end = i + 1;
                    scan: {
                        if (simd.lanes(u32)) |lanes| {
                            const V = @Vector(lanes, u32);
                            // Non-printable (C0 or decoded C1) is
                            // equivalent to "no bit outside 0x9F is
                            // set": one AND-test per lane.
                            const mask: V = @splat(~@as(u32, 0x9F));
                            const zero: V = @splat(0);
                            while (end + lanes <= cps.len) {
                                const v: V = cps[end..][0..lanes].*;
                                const stop = (v & mask) == zero;
                                if (@reduce(.Or, stop)) {
                                    const bits: @Int(.unsigned, lanes) = @bitCast(stop);
                                    end += @ctz(bits);
                                    break :scan;
                                }
                                end += lanes;
                            }
                        }
                        while (end < cps.len and (cps[end] & ~@as(u32, 0x9F)) != 0) end += 1;
                    }
                    self.handler.vt(.print_slice, .{ .cps = cps[i..end] });
                    i = end;
                }
                // Consume the bytes we just processed.
                offset += res.consumed;

                if (offset >= input.len) return;

                // If our offset is NOT an escape then we must have a
                // partial UTF-8 sequence. In that case, we pass it off
                // to the scalar parser.
                if (input[offset] != 0x1B) {
                    const rem = input[offset..];
                    for (rem) |c| self.nextUtf8(c);
                    return;
                }

                // Process control sequences until we run out.
                offset += self.consumeAllEscapes(input[offset..], until, u);
                if (comptime until) if (self.untilReached(u, input.ptr + offset)) return;
            }
        }

        /// Parses back-to-back escape sequences until none are left.
        /// Returns the number of bytes consumed from the provided input.
        ///
        /// Expects input to start with 0x1B, use consumeUntilGround first
        /// if the stream may be in the middle of an escape sequence.
        inline fn consumeAllEscapes(
            self: *Self,
            input: []const u8,
            comptime until: bool,
            u: Until.Arg(until),
        ) usize {
            var offset: usize = 0;
            while (input[offset] == 0x1B) {
                self.parser.state = .escape;
                self.parser.clear();
                offset += 1;
                offset += self.consumeUntilGround(input[offset..], until, u);
                if (comptime until) if (self.untilReached(u, input.ptr + offset)) return offset;
                if (offset >= input.len) return input.len;
            }
            return offset;
        }

        /// Parses escape sequences until the parser reaches the ground state.
        /// Returns the number of bytes consumed from the provided input.
        inline fn consumeUntilGround(
            self: *Self,
            input: []const u8,
            comptime until: bool,
            u: Until.Arg(until),
        ) usize {
            var offset: usize = 0;
            while (self.parser.state != .ground) {
                if (offset >= input.len) return input.len;

                // Fast path for CSI entry: "ESC [" is by far the most
                // common escape sequence prefix, so handle the '[' and
                // the byte that follows it here rather than paying a
                // nextNonUtf8 call for each.
                if (self.parser.state == .escape and input[offset] == '[') {
                    self.parser.state = .csi_entry;
                    offset += 1;
                    continue;
                }

                if (comptime !@hasDecl(T, "vtRaw")) {
                    if (self.parser.state == .csi_entry) {
                        if (self.csiEntryByte(input[offset])) {
                            offset += 1;
                            continue;
                        }
                    }

                    // Bulk-consume CSI parameter bytes. This can't be
                    // used for handlers with a vtRaw hook because it
                    // dispatches the CSI directly (see nextNonUtf8).
                    if (self.parser.state == .csi_param) {
                        offset += self.consumeCsiParams(input[offset..]);
                        if (offset >= input.len) return input.len;
                        // If we're still in csi_param then the next byte
                        // isn't a parameter byte; let nextNonUtf8 below
                        // handle it. Otherwise re-check our state.
                        if (self.parser.state != .csi_param) continue;
                    }

                    // Bulk-consume APC string bytes into a single slice.
                    // APC payloads (e.g. Kitty graphics) can be megabytes
                    // of base64 data, so per-byte dispatch is far too slow.
                    // This can't be used for handlers with a vtRaw hook
                    // because it dispatches the slice directly.
                    if (self.parser.state == .sos_pm_apc_string) {
                        offset += self.consumeApcString(input[offset..]);
                        if (offset >= input.len) return input.len;

                        // Fast-path normal string termination. This matches
                        // Parser.next's exit and entry actions while avoiding
                        // the generic action loop for every completed APC.
                        switch (input[offset]) {
                            std.ascii.control_code.esc => {
                                self.parser.clear();
                                self.parser.state = .escape;
                                self.handler.vt(.apc_end, .{ .terminated = true });
                                if (comptime until) {
                                    u.stringEnd(.apc, input[offset]);
                                    offset += 1;
                                    if (self.untilReached(u, input.ptr + offset)) return offset;
                                    continue;
                                }
                                offset += 1;
                                continue;
                            },
                            0x9C => {
                                self.parser.state = .ground;
                                self.handler.vt(.apc_end, .{ .terminated = true });
                                if (comptime until) {
                                    u.stringEnd(.apc, input[offset]);
                                    offset += 1;
                                    if (self.untilReached(u, input.ptr + offset)) return offset;
                                    continue;
                                }
                                offset += 1;
                                continue;
                            },
                            else => {},
                        }

                        // Aborting transitions need the scalar path so the
                        // handler can distinguish them from terminators.
                    }

                    // Bulk-consume OSC string bytes into the OSC parser.
                    // OSC payloads (e.g. OSC 52 clipboard operations and
                    // the kitty clipboard protocol) can be megabytes of
                    // base64 data, so per-byte dispatch is far too slow.
                    // This can't be used for handlers with a vtRaw hook
                    // because the bytes never produce osc_put actions.
                    if (self.parser.state == .osc_string) {
                        offset += self.consumeOscString(input[offset..]);
                        if (offset >= input.len) return input.len;

                        // Fast-path normal string termination. This matches
                        // Parser.next's exit and entry actions while avoiding
                        // the generic action loop for every completed OSC.
                        switch (input[offset]) {
                            // The sequence should be terminated by a full
                            // ST ("ESC \"); the "\" that should follow is
                            // dispatched as a normal escape sequence.
                            std.ascii.control_code.esc => {
                                if (self.parser.osc_parser.end(
                                    std.ascii.control_code.esc,
                                )) |cmd| self.oscDispatch(cmd.*);
                                self.parser.clear();
                                self.parser.state = .escape;
                                if (comptime until) {
                                    u.stringEnd(.osc, input[offset]);
                                    offset += 1;
                                    if (self.untilReached(u, input.ptr + offset)) return offset;
                                    continue;
                                }
                                offset += 1;
                                continue;
                            },
                            // BEL terminates the string directly.
                            std.ascii.control_code.bel => {
                                if (self.parser.osc_parser.end(
                                    std.ascii.control_code.bel,
                                )) |cmd| self.oscDispatch(cmd.*);
                                self.parser.state = .ground;
                                if (comptime until) {
                                    u.stringEnd(.osc, input[offset]);
                                    offset += 1;
                                    if (self.untilReached(u, input.ptr + offset)) return offset;
                                    continue;
                                }
                                offset += 1;
                                continue;
                            },
                            // CAN/SUB abort and ignored C0 bytes go
                            // through the state machine below.
                            else => {},
                        }
                    }
                }

                self.nextNonUtf8(input[offset], until, u);
                offset += 1;
                if (comptime until) if (self.untilReached(u, input.ptr + offset)) return offset;
            }
            return offset;
        }

        /// Fast path for a byte in the csi_entry state, the state right
        /// after "ESC [". Virtually every CSI sequence spends exactly
        /// one byte in this state, on either a digit, a private marker,
        /// or a final byte. Returns true if the byte was fully handled;
        /// false means the caller must process it through the general
        /// state machine.
        ///
        /// Must not be used by handlers with a vtRaw hook because the
        /// final byte case dispatches the CSI directly.
        inline fn csiEntryByte(self: *Self, c: u8) bool {
            comptime assert(!@hasDecl(T, "vtRaw"));
            assert(self.parser.state == .csi_entry);
            switch (c) {
                // First parameter digit.
                '0'...'9' => {
                    self.parser.state = .csi_param;
                    // param_acc is zero (cleared on escape entry)
                    // so accumulating is just the digit value.
                    self.parser.param_acc = c - '0';
                    self.parser.param_acc_idx = 1;
                },
                // An empty first parameter.
                ';' => {
                    self.parser.state = .csi_param;
                    self.parser.params[0] = 0;
                    self.parser.params_idx = 1;
                },
                // Private marker (e.g. '?' in "ESC [ ? 2004 h").
                0x3C...0x3F => {
                    self.parser.state = .csi_param;
                    self.parser.collect(c);
                },
                // A final byte: a parameterless CSI.
                0x40...0x7E => self.csiDispatchFinal(c),
                // Defer to the state machine for anything else
                // (C0 controls, intermediates, colon).
                else => return false,
            }
            return true;
        }

        /// Bulk-consume CSI parameter bytes (digits and separators)
        /// and, if reached, the final byte (dispatching the CSI).
        /// Returns the number of bytes consumed. Stops at the first
        /// byte that isn't handled here, leaving the parser in the
        /// csi_param state so the caller can process that byte.
        fn consumeCsiParams(self: *Self, input: []const u8) usize {
            const p = &self.parser;
            assert(p.state == .csi_param);

            // Accumulate parser state in locals for the hot loop.
            var acc = p.param_acc;
            var acc_idx = p.param_acc_idx;
            var idx = p.params_idx;

            var offset: usize = 0;
            while (offset < input.len) {
                const c = input[offset];
                switch (c) {
                    // A parameter digit.
                    '0'...'9' => {
                        if (idx < Parser.MAX_PARAMS) {
                            acc *|= 10;
                            acc +|= c - '0';
                            acc_idx |= 1;
                        }
                        offset += 1;
                    },

                    // A parameter separator.
                    ':', ';' => {
                        if (idx < Parser.MAX_PARAMS) {
                            p.params[idx] = acc;
                            if (c == ':') p.params_sep.set(idx);
                            idx += 1;
                            acc = 0;
                            acc_idx = 0;
                        }
                        offset += 1;
                    },

                    // A final byte: dispatch the CSI.
                    0x40...0x7E => {
                        p.param_acc = acc;
                        p.param_acc_idx = acc_idx;
                        p.params_idx = idx;
                        self.csiDispatchFinal(c);
                        return offset + 1;
                    },

                    // Anything else (C0 controls, intermediates, etc.)
                    // is handled by the caller.
                    else => break,
                }
            }

            p.param_acc = acc;
            p.param_acc_idx = acc_idx;
            p.params_idx = idx;
            return offset;
        }

        /// Bulk-consume APC string bytes and dispatch them as a single
        /// apc_put_slice action. Returns the number of bytes consumed.
        /// Stops at the first byte that is not an apc_put byte in the
        /// parse table, leaving it for the caller to process through
        /// the state machine. CAN, SUB, ESC, and most C1 bytes exit
        /// or abort the string state; 0xA0-0xFF are ignored by the
        /// table (not payload), so they can't be bulk-consumed either.
        ///
        /// Must not be used by handlers with a vtRaw hook because it
        /// dispatches the slice directly.
        fn consumeApcString(self: *Self, input: []const u8) usize {
            comptime assert(!@hasDecl(T, "vtRaw"));
            assert(self.parser.state == .sos_pm_apc_string);

            var end: usize = 0;
            if (comptime std.simd.suggestVectorLength(u8)) |vector_len| {
                const ByteVector = @Vector(vector_len, u8);
                while (end + vector_len <= input.len) {
                    const bytes: ByteVector = input[end..][0..vector_len].*;
                    const invalid = (bytes == @as(ByteVector, @splat(0x18))) |
                        (bytes == @as(ByteVector, @splat(0x1A))) |
                        (bytes == @as(ByteVector, @splat(0x1B))) |
                        (bytes >= @as(ByteVector, @splat(0x80)));
                    if (@reduce(.Or, invalid)) break;
                    end += vector_len;
                }
            }
            while (end < input.len) {
                switch (input[end]) {
                    // Not apc_put bytes: CAN/SUB/ESC and most C1 exit
                    // or abort the state; 0xA0-0xFF are ignored by it.
                    0x18, 0x1A, 0x1B, 0x80...0xFF => break,
                    // Everything else is an apc_put byte.
                    else => end += 1,
                }
            }

            if (end > 0) self.handler.vt(
                .apc_put_slice,
                .{ .bytes = input[0..end] },
            );
            return end;
        }

        /// Bulk-consume OSC string bytes into the OSC parser. Returns
        /// the number of bytes consumed. Stops at the first byte that
        /// is not an osc_put byte in the parse table, leaving it for
        /// the caller to process through the state machine. Every byte
        /// >= 0x20 is an osc_put byte; bytes below either terminate or
        /// abort the string (BEL, CAN, SUB, ESC) or are ignored.
        ///
        /// Must not be used by handlers with a vtRaw hook because the
        /// consumed bytes never produce osc_put actions.
        fn consumeOscString(self: *Self, input: []const u8) usize {
            comptime assert(!@hasDecl(T, "vtRaw"));
            assert(self.parser.state == .osc_string);

            var end: usize = 0;
            if (comptime std.simd.suggestVectorLength(u8)) |vector_len| {
                const ByteVector = @Vector(vector_len, u8);
                while (end + vector_len <= input.len) {
                    const bytes: ByteVector = input[end..][0..vector_len].*;
                    const stop = bytes < @as(ByteVector, @splat(0x20));
                    if (@reduce(.Or, stop)) break;
                    end += vector_len;
                }
            }
            while (end < input.len) {
                switch (input[end]) {
                    // Not osc_put bytes: BEL/CAN/SUB/ESC terminate or
                    // abort the state; other C0 bytes are ignored by it.
                    0x00...0x1F => break,
                    // Everything else is an osc_put byte.
                    else => end += 1,
                }
            }

            if (end > 0) self.parser.osc_parser.nextSlice(input[0..end]);
            return end;
        }

        /// Like nextSlice but takes one byte and is necessarily a scalar
        /// operation that can't use SIMD. Prefer nextSlice if you can and
        /// try to get multiple bytes at once.
        pub inline fn next(self: *Self, c: u8) void {
            self.nextUntracked(c, false, {});
            if (self.continuation != null) self.trackContinuation(&.{c});
        }

        inline fn nextUntracked(
            self: *Self,
            c: u8,
            comptime until: bool,
            u: Until.Arg(until),
        ) void {
            // The scalar path can be responsible for decoding UTF-8.
            if (self.parser.state == .ground) {
                self.nextUtf8(c);
                return;
            }

            self.nextNonUtf8(c, until, u);
        }

        /// Process the next byte and print as necessary.
        ///
        /// This assumes we're in the UTF-8 decoding state. If we may not
        /// be in the UTF-8 decoding state call nextSlice or next.
        inline fn nextUtf8(self: *Self, c: u8) void {
            assert(self.parser.state == .ground);

            const res = self.utf8decoder.next(c);
            const consumed = res[1];
            if (res[0]) |codepoint| {
                self.handleCodepoint(codepoint);
            }
            if (!consumed) {
                // We optimize for the scenario where the text being
                // printed in the terminal ISN'T full of ill-formed
                // UTF-8 sequences.
                @branchHint(.unlikely);

                const retry = self.utf8decoder.next(c);
                // It should be impossible for the decoder
                // to not consume the byte twice in a row.
                assert(retry[1] == true);
                if (retry[0]) |codepoint| {
                    self.handleCodepoint(codepoint);
                }
            }
        }

        /// To be called whenever the utf-8 decoder produces a codepoint.
        ///
        /// This function is abstracted this way to handle the case where
        /// the decoder emits a 0x1B after rejecting an ill-formed sequence.
        inline fn handleCodepoint(self: *Self, c: u21) void {
            // We need to increase the eval branch limit because a lot of
            // tests end up running almost completely at comptime due to
            // a chain of inline functions.
            @setEvalBranchQuota(200_000);

            // C0 control or a C1 control decoded from UTF-8: exactly
            // the codepoints with no bit set outside 0x9F (bits 0-4
            // and bit 7 cover 0x00-0x1F and 0x80-0x9F and nothing
            // else), so the printable fast path stays a single
            // AND-test.
            if ((c & ~@as(u21, 0x9F)) == 0) {
                @branchHint(.unlikely);

                // ESC
                if (c == 0x1B) {
                    self.parser.state = .escape;
                    self.parser.clear();
                    return;
                }

                // Ignore C1 that came via UTF-8 decoding, matching xterm.
                if (c > 0x1F) {
                    logUnsupportedOnce(
                        "ignoring UTF-8-decoded C1 controls, first: 0x{x}",
                        .{c},
                        0x80,
                    );
                    return;
                }

                self.execute(@intCast(c));
                return;
            }
            self.print(@intCast(c));
        }

        /// Process the next character and call any callbacks if necessary.
        ///
        /// This assumes that we're not in the UTF-8 decoding state. If
        /// we may be in the UTF-8 decoding state call nextSlice or next.
        fn nextNonUtf8(
            self: *Self,
            c: u8,
            comptime until: bool,
            u: Until.Arg(until),
        ) void {
            assert(self.parser.state != .ground);

            // Fast path for CSI entry.
            if (self.parser.state == .escape and c == '[') {
                self.parser.state = .csi_entry;
                return;
            }

            // The fast paths below dispatch actions directly rather than
            // going through Parser.next, so they'd bypass a handler's
            // vtRaw hook. Handlers with vtRaw (e.g. the inspector) use
            // the general path for anything that produces an action.
            const has_vt_raw = comptime @hasDecl(T, "vtRaw");

            // Fast path for CSI params.
            if (self.parser.state == .csi_param) csi_param: {
                // csi_param is the most common parser state
                // other than ground by a fairly wide margin.
                //
                // ref: https://github.com/qwerasd205/asciinema-stats
                @branchHint(.likely);
                switch (c) {
                    // A C0 escape (yes, this is valid):
                    0x00...0x0F => self.execute(c),
                    // We ignore C0 escapes > 0xF since execute
                    // doesn't have processing for them anyway:
                    0x10...0x17, 0x19, 0x1C...0x1F => {},
                    // We don't currently have any handling for
                    // 0x18 or 0x1A, but they should still move
                    // the parser state to ground.
                    0x18, 0x1A => self.parser.state = .ground,
                    // A parameter digit:
                    '0'...'9' => if (self.parser.params_idx < Parser.MAX_PARAMS) {
                        self.parser.param_acc *|= 10;
                        self.parser.param_acc +|= c - '0';
                        // The parser's CSI param action uses param_acc_idx
                        // to decide if there's a final param that needs to
                        // be consumed or not, but it doesn't matter really
                        // what it is as long as it's not 0.
                        self.parser.param_acc_idx |= 1;
                    },
                    // A parameter separator:
                    ':', ';' => if (self.parser.params_idx < Parser.MAX_PARAMS) {
                        self.parser.params[self.parser.params_idx] = self.parser.param_acc;
                        if (c == ':') self.parser.params_sep.set(self.parser.params_idx);
                        self.parser.params_idx += 1;

                        self.parser.param_acc = 0;
                        self.parser.param_acc_idx = 0;
                    },
                    // A final byte: dispatch the CSI directly.
                    0x40...0x7E => if (comptime !has_vt_raw) {
                        self.csiDispatchFinal(c);
                    } else break :csi_param,
                    // Explicitly ignored:
                    0x7F => {},
                    // Defer to the state machine to
                    // handle any other characters:
                    else => break :csi_param,
                }
                return;
            }

            // Fast path for CSI entry, the state right after "ESC [".
            if (comptime !has_vt_raw) {
                if (self.parser.state == .csi_entry) {
                    if (self.csiEntryByte(c)) return;
                }
            }

            // String boundaries are parser state transitions, not
            // handler actions: an OSC or DCS can start and end without
            // producing one, and a vtRaw handler can skip any action.
            // So in until mode they are found by comparing the parser
            // state before and after the byte.
            const prev_state = if (comptime until) self.parser.state else {};

            // We explicitly inline this call here for performance reasons.
            //
            // We do this rather than mark Parser.next as inline because doing
            // that causes weird behavior in some tests- I'm not sure if they
            // miscompile or it's just very counter-intuitive comptime stuff,
            // but regardless, this is the easy solution.
            const actions = @call(.always_inline, Parser.next, .{ &self.parser, c });
            if (comptime until) u.transition(prev_state, self.parser.state, c);

            for (actions) |action_opt| {
                const action = action_opt orelse continue;
                if (comptime debug) log.info("action: {f}", .{action});

                // A handler can expose this to get the raw action before
                // it is further parsed. If this returns `true` then we skip
                // processing ourselves.
                if (@hasDecl(T, "vtRaw")) {
                    const skip = self.handler.vtRaw(action) catch |err| err: {
                        log.warn("error handling action manually err={} action={f}", .{
                            err,
                            action,
                        });
                        // Always skip erroneous actions because we can't
                        // be sure...
                        break :err true;
                    };

                    if (skip) continue;
                }

                switch (action) {
                    .print => |p| self.print(p),
                    .execute => |code| self.execute(code),
                    .csi_dispatch => |csi_action| self.csiDispatch(csi_action),
                    .esc_dispatch => |esc| self.escDispatch(esc),
                    .osc_dispatch => |cmd| self.oscDispatch(cmd),
                    .dcs_hook => |dcs| self.handler.vt(.dcs_hook, dcs),
                    .dcs_put => |code| self.handler.vt(.dcs_put, code),
                    .dcs_unhook => self.handler.vt(.dcs_unhook, {}),
                    .apc_start => self.handler.vt(.apc_start, {}),
                    .apc_put => |code| self.handler.vt(.apc_put, code),
                    .apc_end => self.handler.vt(.apc_end, .{
                        .terminated = c == std.ascii.control_code.esc or c == 0x9C,
                    }),
                }
            }
        }

        /// Finalize and dispatch a CSI directly from parser state for
        /// the fast paths in nextNonUtf8, without going through
        /// Parser.next. This must match the behavior of the parser's
        /// csi_dispatch action.
        fn csiDispatchFinal(self: *Self, c: u8) void {
            const p = &self.parser;
            p.state = .ground;

            // Ignore sequences with too many parameters, matching the
            // parser's behavior of dropping the dispatch entirely.
            if (p.params_idx >= Parser.MAX_PARAMS) {
                @branchHint(.unlikely);
                return;
            }

            // Finalize the last parameter if we have one.
            if (p.param_acc_idx > 0) {
                p.params[p.params_idx] = p.param_acc;
                p.params_idx += 1;
            }

            const action: Parser.Action.CSI = .{
                .intermediates = p.intermediates[0..p.intermediates_idx],
                .params = p.params[0..p.params_idx],
                .params_sep = p.params_sep,
                .final = c,
            };

            // We only allow colon or mixed separators for the 'm' command.
            if (c != 'm' and p.params_sep.count() > 0) {
                @branchHint(.cold);
                log.warn(
                    "CSI colon or mixed separators only allowed for 'm' command, got: {f}",
                    .{action},
                );
                return;
            }

            if (comptime debug) log.info("action: {f}", .{Parser.Action{ .csi_dispatch = action }});
            self.csiDispatch(action);
        }

        inline fn print(self: *Self, c: u21) void {
            self.handler.vt(.print, .{ .cp = c });
        }

        inline fn execute(self: *Self, c: u8) void {
            // If the character is > 0x7F, it's a C1 (8-bit) control,
            // which is strictly equivalent to `ESC` plus `c - 0x40`.
            if (c > 0x7F) {
                @branchHint(.unlikely);
                log.info("executing C1 0x{x} as ESC {c}", .{ c, c - 0x40 });
                self.escDispatch(.{
                    .intermediates = &.{},
                    .final = c - 0x40,
                });
                return;
            }

            const c0: ansi.C0 = @fromBackingInt(@truncate(c));
            if (comptime debug) log.info("execute: {f}", .{c0});
            switch (c0) {
                // We ignore SOH/STX: https://github.com/microsoft/terminal/issues/10786
                .NUL, .SOH, .STX => {},

                .ENQ => self.handler.vt(.enquiry, {}),
                .BEL => self.handler.vt(.bell, {}),
                .BS => self.handler.vt(.backspace, {}),
                .HT => self.handler.vt(.horizontal_tab, 1),
                .LF, .VT, .FF => self.handler.vt(.linefeed, {}),
                .CR => self.handler.vt(.carriage_return, {}),
                .SO => self.handler.vt(.invoke_charset, .{ .bank = .GL, .charset = .G1, .locking = false }),
                .SI => self.handler.vt(.invoke_charset, .{ .bank = .GL, .charset = .G0, .locking = false }),

                else => logUnsupportedOnce("invalid C0 character, ignoring: 0x{x}", .{c}, c),
            }
        }

        inline fn csiDispatch(self: *Self, input: Parser.Action.CSI) void {
            // The branch hints here are based on real world data
            // which indicates that the most common CSI finals are:
            //
            // 1. m
            // 2. H
            // 3. K
            // 4. A
            // 5. C
            // 6. X
            // 7. l
            // 8. h
            // 9. r
            //
            // Together, these 9 finals make up about 96% of all
            // CSI sequences encountered in real world scenarios.
            //
            // Additionally, within the prongs, unlikely branch
            // hints have been added to branches that deal with
            // invalid sequences/commands, this is in order to
            // optimize for the happy path where we're getting
            // valid data from the program we're running.
            //
            // ref: https://github.com/qwerasd205/asciinema-stats

            switch (input.final) {
                // CUU - Cursor Up
                'A', 'k' => {
                    @branchHint(.likely);
                    switch (input.intermediates.len) {
                        0 => self.handler.vt(.cursor_up, .{
                            .value = switch (input.params.len) {
                                0 => 1,
                                1 => input.params[0],
                                else => {
                                    @branchHint(.unlikely);
                                    log.warn("invalid cursor up command: {f}", .{input});
                                    return;
                                },
                            },
                        }),

                        else => log.warn(
                            "ignoring unimplemented CSI A with intermediates: {s}",
                            .{input.intermediates},
                        ),
                    }
                },

                // CUD - Cursor Down
                'B' => switch (input.intermediates.len) {
                    0 => self.handler.vt(.cursor_down, .{
                        .value = switch (input.params.len) {
                            0 => 1,
                            1 => input.params[0],
                            else => {
                                @branchHint(.unlikely);
                                log.warn("invalid cursor down command: {f}", .{input});
                                return;
                            },
                        },
                    }),

                    else => log.warn(
                        "ignoring unimplemented CSI B with intermediates: {s}",
                        .{input.intermediates},
                    ),
                },

                // CUF - Cursor Right
                'C' => {
                    @branchHint(.likely);
                    switch (input.intermediates.len) {
                        0 => self.handler.vt(.cursor_right, .{
                            .value = switch (input.params.len) {
                                0 => 1,
                                1 => input.params[0],
                                else => {
                                    @branchHint(.unlikely);
                                    log.warn("invalid cursor right command: {f}", .{input});
                                    return;
                                },
                            },
                        }),

                        else => log.warn(
                            "ignoring unimplemented CSI C with intermediates: {s}",
                            .{input.intermediates},
                        ),
                    }
                },

                // CUB - Cursor Left
                'D', 'j' => switch (input.intermediates.len) {
                    0 => self.handler.vt(.cursor_left, .{
                        .value = switch (input.params.len) {
                            0 => 1,
                            1 => input.params[0],
                            else => {
                                @branchHint(.unlikely);
                                log.warn("invalid cursor left command: {f}", .{input});
                                return;
                            },
                        },
                    }),

                    else => log.warn(
                        "ignoring unimplemented CSI D with intermediates: {s}",
                        .{input.intermediates},
                    ),
                },

                // CNL - Cursor Next Line
                'E' => switch (input.intermediates.len) {
                    0 => {
                        self.handler.vt(.cursor_down, .{
                            .value = switch (input.params.len) {
                                0 => 1,
                                1 => input.params[0],
                                else => {
                                    @branchHint(.unlikely);
                                    log.warn("invalid cursor up command: {f}", .{input});
                                    return;
                                },
                            },
                        });
                        self.handler.vt(.carriage_return, {});
                    },

                    else => log.warn(
                        "ignoring unimplemented CSI E with intermediates: {s}",
                        .{input.intermediates},
                    ),
                },

                // CPL - Cursor Previous Line
                'F' => switch (input.intermediates.len) {
                    0 => {
                        self.handler.vt(.cursor_up, .{
                            .value = switch (input.params.len) {
                                0 => 1,
                                1 => input.params[0],
                                else => {
                                    @branchHint(.unlikely);
                                    log.warn("invalid cursor down command: {f}", .{input});
                                    return;
                                },
                            },
                        });
                        self.handler.vt(.carriage_return, {});
                    },

                    else => log.warn(
                        "ignoring unimplemented CSI F with intermediates: {s}",
                        .{input.intermediates},
                    ),
                },

                // HPA - Cursor Horizontal Position Absolute
                // TODO: test
                'G', '`' => switch (input.intermediates.len) {
                    0 => self.handler.vt(.cursor_col, .{
                        .value = switch (input.params.len) {
                            0 => 1,
                            1 => input.params[0],
                            else => {
                                @branchHint(.unlikely);
                                log.warn("invalid HPA command: {f}", .{input});
                                return;
                            },
                        },
                    }),

                    else => log.warn(
                        "ignoring unimplemented CSI G with intermediates: {s}",
                        .{input.intermediates},
                    ),
                },

                // CUP - Set Cursor Position.
                // TODO: test
                'H', 'f' => {
                    @branchHint(.likely);
                    switch (input.intermediates.len) {
                        0 => {
                            const pos: streampkg.Action.CursorPos = switch (input.params.len) {
                                0 => .{ .row = 1, .col = 1 },
                                1 => .{ .row = input.params[0], .col = 1 },
                                2 => .{ .row = input.params[0], .col = input.params[1] },
                                else => {
                                    @branchHint(.unlikely);
                                    log.warn("invalid CUP command: {f}", .{input});
                                    return;
                                },
                            };
                            self.handler.vt(.cursor_pos, pos);
                        },

                        else => log.warn(
                            "ignoring unimplemented CSI H with intermediates: {s}",
                            .{input.intermediates},
                        ),
                    }
                },

                // CHT - Cursor Horizontal Tabulation
                'I' => switch (input.intermediates.len) {
                    0 => self.handler.vt(.horizontal_tab, switch (input.params.len) {
                        0 => 1,
                        1 => input.params[0],
                        else => {
                            log.warn("invalid horizontal tab command: {f}", .{input});
                            return;
                        },
                    }),

                    else => log.warn(
                        "ignoring unimplemented CSI I with intermediates: {s}",
                        .{input.intermediates},
                    ),
                },

                // Erase Display
                'J' => {
                    const protected_: ?bool = switch (input.intermediates.len) {
                        0 => false,
                        1 => if (input.intermediates[0] == '?') true else null,
                        else => null,
                    };

                    const protected = protected_ orelse {
                        log.warn("invalid erase display command: {f}", .{input});
                        return;
                    };

                    const mode_: ?csi.EraseDisplay = switch (input.params.len) {
                        0 => .below,
                        1 => std.enums.fromInt(csi.EraseDisplay, input.params[0]),
                        else => null,
                    };

                    const mode = mode_ orelse {
                        log.warn("invalid erase display command: {f}", .{input});
                        return;
                    };

                    switch (mode) {
                        .below => self.handler.vt(.erase_display_below, protected),
                        .above => self.handler.vt(.erase_display_above, protected),
                        .complete => self.handler.vt(.erase_display_complete, protected),
                        .scrollback => self.handler.vt(.erase_display_scrollback, protected),
                        .scroll_complete => self.handler.vt(.erase_display_scroll_complete, protected),
                    }
                },

                // Erase Line
                'K' => {
                    @branchHint(.likely);
                    const protected_: ?bool = switch (input.intermediates.len) {
                        0 => false,
                        1 => if (input.intermediates[0] == '?') true else null,
                        else => null,
                    };

                    const protected = protected_ orelse {
                        @branchHint(.unlikely);
                        log.warn("invalid erase line command: {f}", .{input});
                        return;
                    };

                    const mode_: ?csi.EraseLine = switch (input.params.len) {
                        0 => .right,
                        1 => if (input.params[0] < 3) @fromBackingInt(@truncate(input.params[0])) else null,
                        else => null,
                    };

                    const mode = mode_ orelse {
                        @branchHint(.unlikely);
                        log.warn("invalid erase line command: {f}", .{input});
                        return;
                    };

                    switch (mode) {
                        .right => self.handler.vt(.erase_line_right, protected),
                        .left => self.handler.vt(.erase_line_left, protected),
                        .complete => self.handler.vt(.erase_line_complete, protected),
                        .right_unless_pending_wrap => self.handler.vt(.erase_line_right_unless_pending_wrap, protected),
                        _ => {
                            @branchHint(.unlikely);
                            log.warn("invalid erase line mode: {}", .{mode});
                        },
                    }
                },

                // IL - Insert Lines
                // TODO: test
                'L' => switch (input.intermediates.len) {
                    0 => self.handler.vt(.insert_lines, switch (input.params.len) {
                        0 => 1,
                        1 => input.params[0],
                        else => {
                            log.warn("invalid IL command: {f}", .{input});
                            return;
                        },
                    }),

                    else => log.warn(
                        "ignoring unimplemented CSI L with intermediates: {s}",
                        .{input.intermediates},
                    ),
                },

                // DL - Delete Lines
                // TODO: test
                'M' => switch (input.intermediates.len) {
                    0 => self.handler.vt(.delete_lines, switch (input.params.len) {
                        0 => 1,
                        1 => input.params[0],
                        else => {
                            log.warn("invalid DL command: {f}", .{input});
                            return;
                        },
                    }),

                    else => log.warn(
                        "ignoring unimplemented CSI M with intermediates: {s}",
                        .{input.intermediates},
                    ),
                },

                // Delete Character (DCH)
                'P' => switch (input.intermediates.len) {
                    0 => self.handler.vt(.delete_chars, switch (input.params.len) {
                        0 => 1,
                        1 => input.params[0],
                        else => {
                            log.warn("invalid delete characters command: {f}", .{input});
                            return;
                        },
                    }),

                    else => log.warn(
                        "ignoring unimplemented CSI P with intermediates: {s}",
                        .{input.intermediates},
                    ),
                },

                // Scroll Up (SD)

                'S' => switch (input.intermediates.len) {
                    0 => self.handler.vt(.scroll_up, switch (input.params.len) {
                        0 => 1,
                        1 => input.params[0],
                        else => {
                            log.warn("invalid scroll up command: {f}", .{input});
                            return;
                        },
                    }),

                    else => log.warn(
                        "ignoring unimplemented CSI S with intermediates: {s}",
                        .{input.intermediates},
                    ),
                },

                // Scroll Down (SD)
                'T' => switch (input.intermediates.len) {
                    0 => self.handler.vt(.scroll_down, switch (input.params.len) {
                        0 => 1,
                        1 => input.params[0],
                        else => {
                            log.warn("invalid scroll down command: {f}", .{input});
                            return;
                        },
                    }),

                    else => log.warn(
                        "ignoring unimplemented CSI T with intermediates: {s}",
                        .{input.intermediates},
                    ),
                },

                // Cursor Tabulation Control
                'W' => switch (input.intermediates.len) {
                    0 => {
                        if (input.params.len == 0 or
                            (input.params.len == 1 and input.params[0] == 0))
                        {
                            self.handler.vt(.tab_set, {});
                            return;
                        }

                        switch (input.params.len) {
                            0 => unreachable,

                            1 => switch (input.params[0]) {
                                0 => unreachable,

                                2 => self.handler.vt(.tab_clear_current, {}),

                                5 => self.handler.vt(.tab_clear_all, {}),

                                else => {},
                            },

                            else => {},
                        }

                        log.warn("invalid cursor tabulation control: {f}", .{input});
                        return;
                    },

                    1 => if (input.intermediates[0] == '?' and
                        input.params.len == 1 and
                        input.params[0] == 5)
                    {
                        self.handler.vt(.tab_reset, {});
                    } else log.warn("invalid cursor tabulation control: {f}", .{input}),

                    else => log.warn(
                        "ignoring unimplemented CSI W with intermediates: {s}",
                        .{input.intermediates},
                    ),
                },

                // Erase Characters (ECH)
                'X' => {
                    @branchHint(.likely);
                    switch (input.intermediates.len) {
                        0 => self.handler.vt(.erase_chars, switch (input.params.len) {
                            0 => 1,
                            1 => input.params[0],
                            else => {
                                @branchHint(.unlikely);
                                log.warn("invalid erase characters command: {f}", .{input});
                                return;
                            },
                        }),

                        else => log.warn(
                            "ignoring unimplemented CSI X with intermediates: {s}",
                            .{input.intermediates},
                        ),
                    }
                },

                // CHT - Cursor Horizontal Tabulation Back
                'Z' => switch (input.intermediates.len) {
                    0 => self.handler.vt(.horizontal_tab_back, switch (input.params.len) {
                        0 => 1,
                        1 => input.params[0],
                        else => {
                            log.warn("invalid horizontal tab back command: {f}", .{input});
                            return;
                        },
                    }),

                    else => log.warn(
                        "ignoring unimplemented CSI Z with intermediates: {s}",
                        .{input.intermediates},
                    ),
                },

                // HPR - Cursor Horizontal Position Relative
                'a' => switch (input.intermediates.len) {
                    0 => self.handler.vt(.cursor_col_relative, .{
                        .value = switch (input.params.len) {
                            0 => 1,
                            1 => input.params[0],
                            else => {
                                log.warn("invalid HPR command: {f}", .{input});
                                return;
                            },
                        },
                    }),

                    else => log.warn(
                        "ignoring unimplemented CSI a with intermediates: {s}",
                        .{input.intermediates},
                    ),
                },

                // Repeat Previous Char (REP)
                'b' => switch (input.intermediates.len) {
                    0 => self.handler.vt(.print_repeat, switch (input.params.len) {
                        0 => 1,
                        1 => input.params[0],
                        else => {
                            log.warn("invalid print repeat command: {f}", .{input});
                            return;
                        },
                    }),

                    else => log.warn(
                        "ignoring unimplemented CSI b with intermediates: {s}",
                        .{input.intermediates},
                    ),
                },

                // c - Device Attributes (DA1)
                'c' => {
                    const req: ?device_attributes.Req = switch (input.intermediates.len) {
                        0 => .primary,
                        1 => switch (input.intermediates[0]) {
                            '>' => .secondary,
                            '=' => .tertiary,
                            else => null,
                        },
                        else => null,
                    };

                    if (req) |r| {
                        self.handler.vt(.device_attributes, r);
                    } else {
                        logUnsupportedOnce(
                            "invalid device attributes command: {f}",
                            .{input},
                            if (input.params.len > 0) input.params[0] else 0,
                        );
                        return;
                    }
                },

                // VPA - Cursor Vertical Position Absolute
                'd' => switch (input.intermediates.len) {
                    0 => self.handler.vt(.cursor_row, .{
                        .value = switch (input.params.len) {
                            0 => 1,
                            1 => input.params[0],
                            else => {
                                log.warn("invalid VPA command: {f}", .{input});
                                return;
                            },
                        },
                    }),

                    else => log.warn(
                        "ignoring unimplemented CSI d with intermediates: {s}",
                        .{input.intermediates},
                    ),
                },

                // VPR - Cursor Vertical Position Relative
                'e' => switch (input.intermediates.len) {
                    0 => self.handler.vt(.cursor_row_relative, .{
                        .value = switch (input.params.len) {
                            0 => 1,
                            1 => input.params[0],
                            else => {
                                log.warn("invalid VPR command: {f}", .{input});
                                return;
                            },
                        },
                    }),

                    else => log.warn(
                        "ignoring unimplemented CSI e with intermediates: {s}",
                        .{input.intermediates},
                    ),
                },

                // TBC - Tab Clear
                // TODO: test
                'g' => switch (input.intermediates.len) {
                    0 => {
                        const mode: csi.TabClear = switch (input.params.len) {
                            0 => .current,
                            1 => std.enums.fromInt(csi.TabClear, input.params[0]) orelse {
                                log.warn("invalid tab clear mode: {}", .{input.params[0]});
                                return;
                            },
                            else => {
                                log.warn("invalid tab clear command: {f}", .{input});
                                return;
                            },
                        };
                        switch (mode) {
                            .current => self.handler.vt(.tab_clear_current, {}),
                            .all => self.handler.vt(.tab_clear_all, {}),
                            _ => log.warn("unknown tab clear mode: {}", .{mode}),
                        }
                    },

                    else => log.warn(
                        "ignoring unimplemented CSI g with intermediates: {s}",
                        .{input.intermediates},
                    ),
                },

                // SM - Set Mode
                'h' => mode: {
                    @branchHint(.likely);
                    const ansi_mode = ansi: {
                        if (input.intermediates.len == 0) break :ansi true;
                        if (input.intermediates.len == 1 and
                            input.intermediates[0] == '?') break :ansi false;

                        log.warn("invalid set mode command: {f}", .{input});
                        break :mode;
                    };

                    for (input.params) |mode_int| {
                        if (modes.modeFromInt(mode_int, ansi_mode)) |mode| {
                            self.handler.vt(.set_mode, .{ .mode = mode });
                        } else {
                            logUnsupportedOnce("unimplemented mode: {}", .{mode_int}, mode_int);
                        }
                    }
                },

                // RM - Reset Mode
                'l' => mode: {
                    @branchHint(.likely);
                    const ansi_mode = ansi: {
                        if (input.intermediates.len == 0) break :ansi true;
                        if (input.intermediates.len == 1 and
                            input.intermediates[0] == '?') break :ansi false;

                        log.warn("invalid set mode command: {f}", .{input});
                        break :mode;
                    };

                    for (input.params) |mode_int| {
                        if (modes.modeFromInt(mode_int, ansi_mode)) |mode| {
                            self.handler.vt(.reset_mode, .{ .mode = mode });
                        } else {
                            logUnsupportedOnce("unimplemented mode: {}", .{mode_int}, mode_int);
                        }
                    }
                },

                // SGR - Select Graphic Rendition
                'm' => {
                    @branchHint(.likely);
                    switch (input.intermediates.len) {
                        0 => {
                            // This is the most common case.
                            @branchHint(.likely);
                            // log.info("parse SGR params={any}", .{input.params});
                            const attrs: streampkg.Action.SetAttributes = .{
                                .params = input.params,
                                .params_sep = input.params_sep,
                            };
                            self.handler.vt(.set_attributes, attrs);
                        },

                        1 => switch (input.intermediates[0]) {
                            '>' => blk: {
                                if (input.params.len == 0) {
                                    // Reset
                                    self.handler.vt(.modify_key_format, .legacy);
                                    break :blk;
                                }

                                var format: ansi.ModifyKeyFormat = switch (input.params[0]) {
                                    0 => .legacy,
                                    1 => .cursor_keys,
                                    2 => .function_keys,
                                    4 => .other_keys_none,
                                    else => {
                                        @branchHint(.unlikely);
                                        log.warn("invalid setModifyKeyFormat: {f}", .{input});
                                        break :blk;
                                    },
                                };

                                if (input.params.len > 2) {
                                    @branchHint(.unlikely);
                                    log.warn("invalid setModifyKeyFormat: {f}", .{input});
                                    break :blk;
                                }

                                if (input.params.len == 2) {
                                    switch (format) {
                                        // We don't support any of the subparams yet for these.
                                        .legacy => {},
                                        .cursor_keys => {},
                                        .function_keys => {},

                                        // We only support the numeric form.
                                        .other_keys_none => switch (input.params[1]) {
                                            2 => format = .other_keys_numeric,
                                            else => {},
                                        },
                                        .other_keys_numeric_except => {},
                                        .other_keys_numeric => {},
                                    }
                                }

                                self.handler.vt(.modify_key_format, format);
                            },

                            else => logUnsupportedOnce(
                                "unknown CSI m with intermediate: {}",
                                .{input.intermediates[0]},
                                input.intermediates[0],
                            ),
                        },

                        else => {
                            // Nothing, but I wanted a place to put this comment:
                            // there are others forms of CSI m that have intermediates.
                            // `vim --clean` uses `CSI ? 4 m` and I don't know what
                            // that means.
                            log.warn(
                                "ignoring unimplemented CSI m with intermediates: {s}",
                                .{input.intermediates},
                            );
                        },
                    }
                },

                // TODO: test
                'n' => {
                    // Handle deviceStatusReport first
                    if (input.intermediates.len == 0 or
                        input.intermediates[0] == '?')
                    {
                        if (input.params.len == 0 or input.params.len > 2) {
                            log.warn("invalid device status report command: {f}", .{input});
                            return;
                        }

                        const question = question: {
                            if (input.intermediates.len == 0) break :question false;
                            if (input.intermediates.len == 1 and
                                input.intermediates[0] == '?') break :question true;

                            log.warn("invalid set mode command: {f}", .{input});
                            return;
                        };

                        const req = device_status.reqFromInt(input.params[0], question) orelse {
                            log.warn("invalid device status report command: {f}", .{input});
                            return;
                        };

                        // Only DECCKSR takes a second parameter.
                        if (input.params.len == 2 and req != .memory_checksum) {
                            log.warn("invalid device status report command: {f}", .{input});
                            return;
                        }

                        self.handler.vt(.device_status, .{
                            .request = req,
                            .id = if (input.params.len == 2) input.params[1] else 0,
                        });
                        return;
                    }

                    // Handle other forms of CSI n
                    switch (input.intermediates.len) {
                        0 => unreachable, // handled above

                        1 => switch (input.intermediates[0]) {
                            '>' => {
                                // This isn't strictly correct. CSI > n has parameters that
                                // control what exactly is being disabled. However, we
                                // only support reverting back to modify other keys in
                                // numeric except format.
                                self.handler.vt(.modify_key_format, .other_keys_numeric_except);
                            },

                            else => log.warn(
                                "unknown CSI n with intermediate: {}",
                                .{input.intermediates[0]},
                            ),
                        },

                        else => log.warn(
                            "ignoring unimplemented CSI n with intermediates: {s}",
                            .{input.intermediates},
                        ),
                    }
                },

                // DECRQM - Request Mode, DECSTR - Soft Terminal Reset
                'p' => switch (input.intermediates.len) {
                    1, 2 => decrqm: {
                        // DECSTR - Soft Terminal Reset
                        if (input.intermediates.len == 1 and
                            input.intermediates[0] == '!')
                        {
                            if (input.params.len != 0) {
                                log.warn("invalid DECSTR command: {f}", .{input});
                                break :decrqm;
                            }

                            self.handler.vt(.soft_reset, {});
                            break :decrqm;
                        }

                        const ansi_mode = ansi: {
                            switch (input.intermediates.len) {
                                1 => if (input.intermediates[0] == '$') break :ansi true,
                                2 => if (input.intermediates[0] == '?' and
                                    input.intermediates[1] == '$') break :ansi false,
                                else => {},
                            }

                            log.warn(
                                "ignoring unimplemented CSI p with intermediates: {s}",
                                .{input.intermediates},
                            );
                            break :decrqm;
                        };

                        if (input.params.len != 1) {
                            log.warn("invalid DECRQM command: {f}", .{input});
                            break :decrqm;
                        }

                        const mode_raw = input.params[0];
                        const mode = modes.modeFromInt(mode_raw, ansi_mode);
                        if (mode) |m| {
                            self.handler.vt(.request_mode, .{ .mode = m });
                        } else {
                            self.handler.vt(.request_mode_unknown, .{
                                .mode = mode_raw,
                                .ansi = ansi_mode,
                            });
                        }
                    },

                    else => log.warn(
                        "ignoring unimplemented CSI p with intermediates: {s}",
                        .{input.intermediates},
                    ),
                },

                'q' => switch (input.intermediates.len) {
                    1 => switch (input.intermediates[0]) {
                        // DECSCUSR - Select Cursor Style
                        // TODO: test
                        ' ' => {
                            const style: ansi.CursorStyle = switch (input.params.len) {
                                0 => .default,
                                1 => switch (input.params[0]) {
                                    0 => .default,
                                    1 => .blinking_block,
                                    2 => .steady_block,
                                    3 => .blinking_underline,
                                    4 => .steady_underline,
                                    5 => .blinking_bar,
                                    6 => .steady_bar,
                                    else => {
                                        log.warn("invalid cursor style value: {}", .{input.params[0]});
                                        return;
                                    },
                                },
                                else => {
                                    log.warn("invalid set cursor style command: {f}", .{input});
                                    return;
                                },
                            };
                            self.handler.vt(.cursor_style, style);
                        },

                        // DECSCA
                        '"' => {
                            const mode_: ?ansi.ProtectedMode = switch (input.params.len) {
                                else => null,
                                0 => .off,
                                1 => switch (input.params[0]) {
                                    0, 2 => .off,
                                    1 => .dec,
                                    else => null,
                                },
                            };

                            const mode = mode_ orelse {
                                log.warn("invalid set protected mode command: {f}", .{input});
                                return;
                            };

                            switch (mode) {
                                .off => self.handler.vt(.protected_mode_off, {}),
                                .iso => self.handler.vt(.protected_mode_iso, {}),
                                .dec => self.handler.vt(.protected_mode_dec, {}),
                            }
                        },

                        // XTVERSION
                        '>' => self.handler.vt(.xtversion, {}),
                        else => {
                            log.warn(
                                "ignoring unimplemented CSI q with intermediates: {s}",
                                .{input.intermediates},
                            );
                        },
                    },

                    else => log.warn(
                        "ignoring unimplemented CSI p with intermediates: {s}",
                        .{input.intermediates},
                    ),
                },

                'r' => {
                    @branchHint(.likely);
                    switch (input.intermediates.len) {
                        // DECSTBM - Set Top and Bottom Margins
                        0 => switch (input.params.len) {
                            0 => self.handler.vt(.top_and_bottom_margin, .{ .top_left = 0, .bottom_right = 0 }),
                            1 => self.handler.vt(.top_and_bottom_margin, .{ .top_left = input.params[0], .bottom_right = 0 }),
                            2 => self.handler.vt(.top_and_bottom_margin, .{ .top_left = input.params[0], .bottom_right = input.params[1] }),
                            else => {
                                @branchHint(.unlikely);
                                log.warn("invalid DECSTBM command: {f}", .{input});
                            },
                        },

                        1 => switch (input.intermediates[0]) {
                            // Restore Mode
                            '?' => {
                                for (input.params) |mode_int| {
                                    if (modes.modeFromInt(mode_int, false)) |mode| {
                                        self.handler.vt(.restore_mode, .{ .mode = mode });
                                    } else {
                                        log.warn(
                                            "unimplemented restore mode: {}",
                                            .{mode_int},
                                        );
                                    }
                                }
                            },

                            else => log.warn(
                                "unknown CSI s with intermediate: {f}",
                                .{input},
                            ),
                        },

                        else => log.warn(
                            "ignoring unimplemented CSI s with intermediates: {f}",
                            .{input},
                        ),
                    }
                },

                's' => switch (input.intermediates.len) {
                    // DECSLRM
                    0 => switch (input.params.len) {
                        // CSI S is ambiguous with zero params so we defer
                        // to our handler to do the proper logic. If mode 69
                        // is set, then we should invoke DECSLRM, otherwise
                        // we should invoke SC.
                        0 => self.handler.vt(.left_and_right_margin_ambiguous, {}),
                        1 => self.handler.vt(.left_and_right_margin, .{ .top_left = input.params[0], .bottom_right = 0 }),
                        2 => self.handler.vt(.left_and_right_margin, .{ .top_left = input.params[0], .bottom_right = input.params[1] }),
                        else => log.warn("invalid DECSLRM command: {f}", .{input}),
                    },

                    1 => switch (input.intermediates[0]) {
                        '?' => {
                            for (input.params) |mode_int| {
                                if (modes.modeFromInt(mode_int, false)) |mode| {
                                    self.handler.vt(.save_mode, .{ .mode = mode });
                                } else {
                                    log.warn(
                                        "unimplemented save mode: {}",
                                        .{mode_int},
                                    );
                                }
                            }
                        },

                        // XTSHIFTESCAPE
                        '>' => capture: {
                            const capture = switch (input.params.len) {
                                0 => false,
                                1 => switch (input.params[0]) {
                                    0 => false,
                                    1 => true,
                                    else => {
                                        log.warn("invalid XTSHIFTESCAPE command: {f}", .{input});
                                        break :capture;
                                    },
                                },
                                else => {
                                    log.warn("invalid XTSHIFTESCAPE command: {f}", .{input});
                                    break :capture;
                                },
                            };

                            self.handler.vt(.mouse_shift_capture, capture);
                        },

                        else => log.warn(
                            "unknown CSI s with intermediate: {f}",
                            .{input},
                        ),
                    },

                    else => log.warn(
                        "ignoring unimplemented CSI s with intermediates: {f}",
                        .{input},
                    ),
                },

                // XTWINOPS
                't' => switch (input.intermediates.len) {
                    0 => {
                        if (input.params.len > 0) {
                            switch (input.params[0]) {
                                8 => if (input.params.len <= 3) {
                                    // resize the text area in characters
                                    self.handler.vt(.resize_window, .{
                                        .rows = if (input.params.len > 1) input.params[1] else 0,
                                        .columns = if (input.params.len > 2) input.params[2] else 0,
                                    });
                                } else log.warn(
                                    "ignoring CSI 8 t with extra parameters: {f}",
                                    .{input},
                                ),
                                14 => if (input.params.len == 1) {
                                    // report the text area size in pixels
                                    self.handler.vt(.size_report, .csi_14_t);
                                } else log.warn(
                                    "ignoring CSI 14 t with extra parameters: {f}",
                                    .{input},
                                ),
                                16 => if (input.params.len == 1) {
                                    // report cell size in pixels
                                    self.handler.vt(.size_report, .csi_16_t);
                                } else log.warn(
                                    "ignoring CSI 16 t with extra parameters: {f}",
                                    .{input},
                                ),
                                18 => if (input.params.len == 1) {
                                    // report text area size in characters
                                    self.handler.vt(.size_report, .csi_18_t);
                                } else log.warn(
                                    "ignoring CSI 18 t with extra parameters: {f}",
                                    .{input},
                                ),
                                19 => if (input.params.len == 1) {
                                    // report screen size in characters
                                    self.handler.vt(.size_report, .csi_19_t);
                                } else log.warn(
                                    "ignoring CSI 19 t with extra parameters: {f}",
                                    .{input},
                                ),
                                21 => if (input.params.len == 1) {
                                    // report window title
                                    self.handler.vt(.size_report, .csi_21_t);
                                } else log.warn(
                                    "ignoring CSI 21 t with extra parameters: {f}",
                                    .{input},
                                ),
                                inline 22, 23 => |number| if ((input.params.len == 2 or
                                    input.params.len == 3) and
                                    // we only support window title
                                    (input.params[1] == 0 or
                                        input.params[1] == 2))
                                {
                                    // push/pop title
                                    const index: u16 = if (input.params.len == 3)
                                        input.params[2]
                                    else
                                        0;
                                    switch (number) {
                                        22 => self.handler.vt(.title_push, index),
                                        23 => self.handler.vt(.title_pop, index),
                                        else => @compileError("unreachable"),
                                    }
                                } else logUnsupportedOnce(
                                    "ignoring CSI 22/23 t with extra parameters: {f}",
                                    .{input},
                                    input.params[0],
                                ),
                                else => logUnsupportedOnce(
                                    "ignoring CSI t with unimplemented parameter: {f}",
                                    .{input},
                                    input.params[0],
                                ),
                            }
                        } else log.err(
                            "ignoring CSI t with no parameters: {f}",
                            .{input},
                        );
                    },
                    else => log.warn(
                        "ignoring unimplemented CSI t with intermediates: {f}",
                        .{input},
                    ),
                },

                'u' => switch (input.intermediates.len) {
                    0 => self.handler.vt(.restore_cursor, {}),

                    // Kitty keyboard protocol
                    1 => switch (input.intermediates[0]) {
                        '?' => self.handler.vt(.kitty_keyboard_query, {}),

                        '>' => push: {
                            const flags: u5 = if (input.params.len == 1)
                                std.math.cast(u5, input.params[0]) orelse {
                                    log.warn("invalid pushKittyKeyboard command: {f}", .{input});
                                    break :push;
                                }
                            else
                                0;

                            self.handler.vt(.kitty_keyboard_push, .{ .flags = @as(kitty.KeyFlags, @bitCast(flags)) });
                        },

                        '<' => {
                            const number: u16 = if (input.params.len == 1)
                                input.params[0]
                            else
                                1;

                            self.handler.vt(.kitty_keyboard_pop, number);
                        },

                        '=' => set: {
                            const flags: u5 = if (input.params.len >= 1)
                                std.math.cast(u5, input.params[0]) orelse {
                                    log.warn("invalid setKittyKeyboard command: {f}", .{input});
                                    break :set;
                                }
                            else
                                0;

                            const number: u16 = if (input.params.len >= 2)
                                input.params[1]
                            else
                                1;

                            const action_tag: streampkg.Action.Tag = switch (number) {
                                1 => .kitty_keyboard_set,
                                2 => .kitty_keyboard_set_or,
                                3 => .kitty_keyboard_set_not,
                                else => {
                                    log.warn("invalid setKittyKeyboard command: {f}", .{input});
                                    break :set;
                                },
                            };

                            const kitty_flags: streampkg.Action.KittyKeyboardFlags = .{ .flags = @as(kitty.KeyFlags, @bitCast(flags)) };
                            switch (action_tag) {
                                .kitty_keyboard_set => self.handler.vt(.kitty_keyboard_set, kitty_flags),
                                .kitty_keyboard_set_or => self.handler.vt(.kitty_keyboard_set_or, kitty_flags),
                                .kitty_keyboard_set_not => self.handler.vt(.kitty_keyboard_set_not, kitty_flags),
                                else => unreachable,
                            }
                        },

                        else => log.warn(
                            "unknown CSI s with intermediate: {f}",
                            .{input},
                        ),
                    },

                    else => log.warn(
                        "ignoring unimplemented CSI u: {f}",
                        .{input},
                    ),
                },

                // ICH - Insert Blanks
                '@' => switch (input.intermediates.len) {
                    0 => self.handler.vt(.insert_blanks, switch (input.params.len) {
                        0 => 1,
                        1 => @max(1, input.params[0]),
                        else => {
                            @branchHint(.unlikely);
                            log.warn("invalid ICH command: {f}", .{input});
                            return;
                        },
                    }),

                    else => log.warn(
                        "ignoring unimplemented CSI @: {f}",
                        .{input},
                    ),
                },

                'y' => switch (input.intermediates.len) {
                    1 => switch (input.intermediates[0]) {
                        // DECRQCRA - Request Checksum of Rectangular Area.
                        // The page number (the second parameter) is ignored.
                        '*' => {
                            if (input.params.len > 6) {
                                log.warn("invalid DECRQCRA command: {f}", .{input});
                                return;
                            }

                            var params: [6]u16 = @splat(0);
                            @memcpy(params[0..input.params.len], input.params);
                            self.handler.vt(.request_xt_checksum, xt_checksum.Request{
                                .id = params[0],
                                .top = params[2],
                                .left = params[3],
                                .bottom = params[4],
                                .right = params[5],
                            });
                        },

                        // XTCHECKSUM - Select checksum extension. Bits
                        // beyond the ones we know are ignored, as in xterm.
                        '#' => {
                            if (input.params.len > 1) {
                                log.warn("invalid XTCHECKSUM command: {f}", .{input});
                                return;
                            }

                            const bits: u16 = if (input.params.len == 1) input.params[0] else 0;
                            self.handler.vt(.xt_checksum_extension, .{
                                .flags = @as(xt_checksum.Flags, @bitCast(@as(u5, @truncate(bits)))),
                            });
                        },

                        else => log.warn(
                            "ignoring unimplemented CSI y: {f}",
                            .{input},
                        ),
                    },

                    else => log.warn(
                        "ignoring unimplemented CSI y: {f}",
                        .{input},
                    ),
                },

                '}' => decsasd: {
                    if (input.intermediates.len != 1) {
                        log.warn("unimplemented CSI callback: {f}", .{input});
                        break :decsasd;
                    }

                    switch (input.intermediates[0]) {
                        // DECSASD - Select Active Status Display
                        '$' => {},

                        // DECIC - Insert Column
                        '\'' => {
                            self.handler.vt(.insert_columns, switch (input.params.len) {
                                0 => 1,
                                1 => @max(1, input.params[0]),
                                else => {
                                    @branchHint(.unlikely);
                                    log.warn("invalid DECIC command: {f}", .{input});
                                    break :decsasd;
                                },
                            });
                            break :decsasd;
                        },

                        else => {
                            log.warn("unimplemented CSI callback: {f}", .{input});
                            break :decsasd;
                        },
                    }

                    if (input.params.len != 1) {
                        log.warn("unimplemented CSI callback: {f}", .{input});
                        break :decsasd;
                    }

                    const display: ansi.StatusDisplay = switch (input.params[0]) {
                        0 => .main,
                        1 => .status_line,
                        else => {
                            log.warn("unimplemented CSI callback: {f}", .{input});
                            break :decsasd;
                        },
                    };

                    self.handler.vt(.active_status_display, display);
                },

                // DECDC - Delete Column
                '~' => switch (input.intermediates.len) {
                    1 => switch (input.intermediates[0]) {
                        '\'' => self.handler.vt(.delete_columns, switch (input.params.len) {
                            0 => 1,
                            1 => @max(1, input.params[0]),
                            else => {
                                @branchHint(.unlikely);
                                log.warn("invalid DECDC command: {f}", .{input});
                                return;
                            },
                        }),

                        else => log.warn("unimplemented CSI action: {f}", .{input}),
                    },

                    else => log.warn("unimplemented CSI action: {f}", .{input}),
                },

                else => log.warn("unimplemented CSI action: {f}", .{input}),
            }
        }

        inline fn oscDispatch(self: *Self, cmd: osc.Command) void {
            // The branch hints here are based on real world data
            // which indicates that the most common OSC commands are:
            //
            // 1. hyperlink_end
            // 2. change_window_title
            // 3. change_window_icon
            // 4. hyperlink_start
            // 5. report_pwd
            // 6. color_operation
            // 7. semantic_prompt
            //
            // Together, these 7 commands make up about 96% of all
            // OSC commands encountered in real world scenarios.
            //
            // Additionally, within the prongs, unlikely branch
            // hints have been added to branches that deal with
            // invalid sequences/commands, this is in order to
            // optimize for the happy path where we're getting
            // valid data from the program we're running.
            //
            // ref: https://github.com/qwerasd205/asciinema-stats

            switch (cmd) {
                .semantic_prompt => |sp| {
                    @branchHint(.likely);
                    self.handler.vt(.semantic_prompt, sp);
                },

                .change_window_title => |title| {
                    @branchHint(.likely);
                    if (!std.unicode.utf8ValidateSlice(title)) {
                        @branchHint(.unlikely);
                        log.warn("change title request: invalid utf-8, ignoring request", .{});
                        return;
                    }

                    self.handler.vt(.window_title, .{ .title = title });
                },

                .change_window_icon => |icon| {
                    @branchHint(.likely);
                    logUnsupportedOnce(
                        "OSC 1 (change icon) received and ignored icon={s}",
                        .{icon},
                        0,
                    );
                },

                .clipboard_contents => |clip| {
                    self.handler.vt(.clipboard_contents, .{
                        .kind = clip.kind,
                        .data = clip.data,
                        .terminator = clip.terminator,
                    });
                },

                .report_pwd => |v| {
                    @branchHint(.likely);
                    self.handler.vt(.report_pwd, .{ .url = v.value });
                },

                .mouse_shape => |v| {
                    if (v.value.len == 0) {
                        self.handler.vt(.mouse_shape_reset, {});
                        return;
                    }

                    const shape = MouseShape.fromString(v.value) orelse {
                        @branchHint(.unlikely);
                        log.warn("unknown cursor shape: {s}", .{v.value});
                        return;
                    };

                    self.handler.vt(.mouse_shape, shape);
                },

                .color_operation => |v| {
                    @branchHint(.likely);
                    self.handler.vt(.color_operation, .{
                        .op = v.op,
                        .requests = v.requests,
                        .terminator = v.terminator,
                    });
                },

                .kitty_color_protocol => |v| {
                    self.handler.vt(.kitty_color_report, v);
                },

                .show_desktop_notification => |v| {
                    self.handler.vt(.show_desktop_notification, .{
                        .title = v.title,
                        .body = v.body,
                    });
                },

                .hyperlink_start => |v| {
                    @branchHint(.likely);
                    self.handler.vt(.start_hyperlink, .{
                        .uri = v.uri,
                        .id = v.id,
                    });
                },

                .hyperlink_end => {
                    @branchHint(.likely);
                    self.handler.vt(.end_hyperlink, {});
                },

                .conemu_progress_report => |v| {
                    self.handler.vt(.progress_report, v);
                },

                .kitty_clipboard_protocol => |v| {
                    self.handler.vt(.kitty_clipboard, v);
                },

                .kitty_dnd_protocol => |v| {
                    self.handler.vt(.kitty_dnd, v);
                },

                .program_status => |v| {
                    self.handler.vt(.program_status, v);
                },

                .unknown => |v| {
                    @branchHint(.unlikely);
                    self.handler.vt(.osc_unknown, v);
                },

                .conemu_sleep,
                .conemu_show_message_box,
                .conemu_change_tab_title,
                .conemu_wait_input,
                .conemu_guimacro,
                .conemu_comment,
                .conemu_xterm_emulation,
                .conemu_output_environment_variable,
                .conemu_run_process,
                .kitty_text_sizing,
                .kitty_desktop_notification,
                .hierarchical_context,
                => {
                    log.debug("unimplemented OSC callback: {}", .{cmd});
                },

                .invalid => {
                    @branchHint(.cold);
                    // This is an invalid internal state, not an invalid OSC
                    // string being parsed. We shouldn't see this.
                    log.warn("invalid OSC, should never happen", .{});
                },
            }
        }

        inline fn configureCharset(
            self: *Self,
            intermediates: []const u8,
            set: charsets.Charset,
        ) void {
            if (intermediates.len != 1) {
                log.warn("invalid charset intermediate: {any}", .{intermediates});
                return;
            }

            const slot: charsets.Slots = switch (intermediates[0]) {
                // TODO: support slots '-', '.', '/'

                '(' => .G0,
                ')' => .G1,
                '*' => .G2,
                '+' => .G3,
                else => {
                    @branchHint(.unlikely);
                    log.warn("invalid charset intermediate: {any}", .{intermediates});
                    return;
                },
            };

            self.handler.vt(.configure_charset, .{
                .slot = slot,
                .charset = set,
            });
        }

        inline fn escDispatch(
            self: *Self,
            action: Parser.Action.ESC,
        ) void {
            // The branch hints here are based on real world data
            // which indicates that the most common ESC finals are:
            //
            // 1. B
            // 2. \
            // 3. 0
            // 4. M
            // 5. 8
            // 6. 7
            // 7. >
            // 8. =
            //
            // Together, these 8 finals make up nearly 99% of all
            // ESC sequences encountered in real world scenarios.
            //
            // Additionally, within the prongs, unlikely branch
            // hints have been added to branches that deal with
            // invalid sequences/commands, this is in order to
            // optimize for the happy path where we're getting
            // valid data from the program we're running.
            //
            // ref: https://github.com/qwerasd205/asciinema-stats

            switch (action.final) {
                // Charsets
                'B' => {
                    @branchHint(.likely);
                    self.configureCharset(action.intermediates, .ascii);
                },
                'A' => self.configureCharset(action.intermediates, .british),
                '0' => {
                    @branchHint(.likely);
                    self.configureCharset(action.intermediates, .dec_special);
                },

                // DECSC - Save Cursor
                '7' => {
                    @branchHint(.likely);
                    switch (action.intermediates.len) {
                        0 => self.handler.vt(.save_cursor, {}),
                        else => {
                            @branchHint(.unlikely);
                            log.warn("invalid command: {f}", .{action});
                            return;
                        },
                    }
                },

                '8' => blk: {
                    @branchHint(.likely);
                    switch (action.intermediates.len) {
                        // DECRC - Restore Cursor
                        0 => {
                            self.handler.vt(.restore_cursor, {});
                            break :blk {};
                        },

                        1 => switch (action.intermediates[0]) {
                            // DECALN - Fill Screen with E
                            '#' => {
                                self.handler.vt(.decaln, {});
                                break :blk {};
                            },

                            else => {},
                        },

                        else => {}, // fall through
                    }

                    logUnsupportedOnce(
                        "unimplemented ESC action: {f}",
                        .{action},
                        action.final,
                    );
                },

                // DECBI - Back Index
                '6' => switch (action.intermediates.len) {
                    0 => self.handler.vt(.back_index, {}),
                    else => {
                        @branchHint(.unlikely);
                        log.warn("invalid back index command: {f}", .{action});
                        return;
                    },
                },

                // DECFI - Forward Index
                '9' => switch (action.intermediates.len) {
                    0 => self.handler.vt(.forward_index, {}),
                    else => {
                        @branchHint(.unlikely);
                        log.warn("invalid forward index command: {f}", .{action});
                        return;
                    },
                },

                // IND - Index
                'D' => switch (action.intermediates.len) {
                    0 => self.handler.vt(.index, {}),
                    else => {
                        @branchHint(.unlikely);
                        log.warn("invalid index command: {f}", .{action});
                        return;
                    },
                },

                // NEL - Next Line
                'E' => switch (action.intermediates.len) {
                    0 => self.handler.vt(.next_line, {}),
                    else => {
                        @branchHint(.unlikely);
                        log.warn("invalid next line command: {f}", .{action});
                        return;
                    },
                },

                // HTS - Horizontal Tab Set
                'H' => switch (action.intermediates.len) {
                    0 => self.handler.vt(.tab_set, {}),
                    else => {
                        @branchHint(.unlikely);
                        log.warn("invalid tab set command: {f}", .{action});
                        return;
                    },
                },

                // RI - Reverse Index
                'M' => {
                    @branchHint(.likely);
                    switch (action.intermediates.len) {
                        0 => self.handler.vt(.reverse_index, {}),
                        else => {
                            @branchHint(.unlikely);
                            log.warn("invalid reverse index command: {f}", .{action});
                            return;
                        },
                    }
                },

                // SS2 - Single Shift 2
                'N' => switch (action.intermediates.len) {
                    0 => self.handler.vt(.invoke_charset, .{
                        .bank = .GL,
                        .charset = .G2,
                        .locking = true,
                    }),
                    else => {
                        @branchHint(.unlikely);
                        log.warn("invalid single shift 2 command: {f}", .{action});
                        return;
                    },
                },

                // SS3 - Single Shift 3
                'O' => switch (action.intermediates.len) {
                    0 => self.handler.vt(.invoke_charset, .{
                        .bank = .GL,
                        .charset = .G3,
                        .locking = true,
                    }),
                    else => {
                        @branchHint(.unlikely);
                        log.warn("invalid single shift 3 command: {f}", .{action});
                        return;
                    },
                },

                // SPA - Start of Guarded Area
                'V' => switch (action.intermediates.len) {
                    0 => self.handler.vt(.protected_mode_iso, {}),
                    else => log.warn("unimplemented ESC callback: {f}", .{action}),
                },

                // EPA - End of Guarded Area
                'W' => switch (action.intermediates.len) {
                    0 => self.handler.vt(.protected_mode_off, {}),
                    else => log.warn("unimplemented ESC callback: {f}", .{action}),
                },

                // DECID
                'Z' => if (action.intermediates.len == 0) {
                    self.handler.vt(.device_attributes, .primary);
                } else log.warn("unimplemented ESC callback: {f}", .{action}),

                // RIS - Full Reset
                'c' => switch (action.intermediates.len) {
                    0 => self.handler.vt(.full_reset, {}),
                    else => {
                        log.warn("invalid full reset command: {f}", .{action});
                        return;
                    },
                },

                // LS2 - Locking Shift 2
                'n' => switch (action.intermediates.len) {
                    0 => self.handler.vt(.invoke_charset, .{
                        .bank = .GL,
                        .charset = .G2,
                        .locking = false,
                    }),
                    else => {
                        @branchHint(.unlikely);
                        log.warn("invalid single shift 2 command: {f}", .{action});
                        return;
                    },
                },

                // LS3 - Locking Shift 3
                'o' => switch (action.intermediates.len) {
                    0 => self.handler.vt(.invoke_charset, .{
                        .bank = .GL,
                        .charset = .G3,
                        .locking = false,
                    }),
                    else => {
                        @branchHint(.unlikely);
                        log.warn("invalid single shift 3 command: {f}", .{action});
                        return;
                    },
                },

                // LS1R - Locking Shift 1 Right
                '~' => switch (action.intermediates.len) {
                    0 => self.handler.vt(.invoke_charset, .{
                        .bank = .GR,
                        .charset = .G1,
                        .locking = false,
                    }),
                    else => {
                        @branchHint(.unlikely);
                        log.warn("invalid locking shift 1 right command: {f}", .{action});
                        return;
                    },
                },

                // LS2R - Locking Shift 2 Right
                '}' => switch (action.intermediates.len) {
                    0 => self.handler.vt(.invoke_charset, .{
                        .bank = .GR,
                        .charset = .G2,
                        .locking = false,
                    }),
                    else => {
                        @branchHint(.unlikely);
                        log.warn("invalid locking shift 2 right command: {f}", .{action});
                        return;
                    },
                },

                // LS3R - Locking Shift 3 Right
                '|' => switch (action.intermediates.len) {
                    0 => self.handler.vt(.invoke_charset, .{
                        .bank = .GR,
                        .charset = .G3,
                        .locking = false,
                    }),
                    else => {
                        @branchHint(.unlikely);
                        log.warn("invalid locking shift 3 right command: {f}", .{action});
                        return;
                    },
                },

                // Set application keypad mode
                '=' => {
                    @branchHint(.likely);
                    switch (action.intermediates.len) {
                        0 => self.handler.vt(.set_mode, .{ .mode = .keypad_keys }),
                        else => log.warn("unimplemented setMode: {f}", .{action}),
                    }
                },

                // Reset application keypad mode
                '>' => {
                    @branchHint(.likely);
                    switch (action.intermediates.len) {
                        0 => self.handler.vt(.reset_mode, .{ .mode = .keypad_keys }),
                        else => log.warn("unimplemented setMode: {f}", .{action}),
                    }
                },

                // Sets ST (string terminator). We don't have to do anything
                // because our parser always accepts ST.
                '\\' => {
                    @branchHint(.likely);
                },

                else => logUnsupportedOnce(
                    "unimplemented ESC action: {f}",
                    .{action},
                    action.final,
                ),
            }
        }
    };
}

/// A point in the byte stream where `Stream.nextSliceUntil` can stop.
///
/// Each boundary is reached by exactly one byte. The stream stops right
/// after that byte and describes it in a `Stop`, so you learn where a
/// string starts or ends from the same parse that handles it, without
/// parsing any byte twice.
///
/// Most boundaries mark the first or last byte of a control string: an
/// APC, DCS or OSC sequence, made of an introducer, some content, and a
/// terminator. `ground` is different. It marks the state between
/// sequences rather than a byte inside one.
///
/// Terminal protocols spell control bytes two ways, and both are
/// recognized here. A 7-bit introducer is ESC followed by one byte, such
/// as `ESC ]` for OSC. The 8-bit form is a single byte in the range 0x80
/// to 0x9F, such as 0x9D for OSC. The string terminator ST is `ESC \` or
/// the single byte 0x9C.
pub const Boundary = enum {
    /// The stream is not inside any escape sequence or partial UTF-8
    /// character. This is a safe point to insert your own sequences.
    ///
    /// Ground is a state, not an event. If the stream is already at
    /// ground when you ask for it, the call stops immediately and
    /// consumes nothing.
    ground,

    /// The byte that started an APC string: `_` after ESC, or 0x9F.
    ///
    /// SOS (`X` or 0x98) and PM (`^` or 0x9E) strings report this too,
    /// because the parser handles all three the same way. Use
    /// `Stop.Start.byte` to tell them apart.
    apc_start,

    /// The byte that ended an APC, SOS or PM string.
    apc_end,

    /// The byte that started a DCS string: `P` after ESC, or 0x90.
    ///
    /// A DCS has a header before its payload: parameters, intermediates
    /// and a final byte, in the same shape as a CSI sequence. The stop
    /// lands on the introducer, so the header follows it. The handler's
    /// `dcs_hook` action still marks where the payload begins. A 0x90
    /// inside the header restarts the header without leaving the
    /// string, so it does not stop.
    dcs_start,

    /// The byte that ended a DCS string, whether it was still in its
    /// header or already in its payload. A DCS cut short in its header
    /// reports this without the handler ever seeing a `dcs_hook`.
    dcs_end,

    /// The byte that started an OSC string: `]` after ESC, or 0x9D.
    osc_start,

    /// The byte that ended an OSC string. This is reported for every
    /// OSC, including ones with a number the handler does not know.
    osc_end,

    /// A set of boundaries to stop at.
    pub const Set = std.EnumSet(Boundary);

    /// The kind of control string that started or ended. `apc` covers
    /// SOS and PM too, see `apc_start`.
    pub const StringKind = lib.Enum(lib.target, &.{ "apc", "dcs", "osc" });

    /// How a control string started.
    ///
    /// - `esc`: ESC followed by `_` (APC), `X` (SOS), `^` (PM), `P` (DCS)
    ///   or `]` (OSC). The stop's `consumed` count includes only the final
    ///   byte, because the ESC may have been consumed by an earlier call.
    /// - `c1`: a single 8-bit byte, 0x9F (APC), 0x98 (SOS), 0x9E (PM),
    ///   0x90 (DCS) or 0x9D (OSC). At ground these bytes are decoded as
    ///   UTF-8 instead, so they only start a string when they arrive
    ///   inside another escape sequence.
    pub const Introducer = lib.Enum(lib.target, &.{ "esc", "c1" });

    /// How a control string ended.
    ///
    /// - `st_esc`: ESC, the first byte of the terminator `ESC \`. The ESC
    ///   is consumed but the byte after it is not. That byte is handled
    ///   as a normal escape sequence by the next call.
    /// - `st_c1`: 0x9C, the 8-bit terminator.
    /// - `bel`: BEL (0x07). Only an OSC ends this way.
    /// - `cancelled`: CAN (0x18) or SUB (0x1A).
    /// - `aborted`: any other 8-bit control byte. It either runs as a
    ///   control or starts a new sequence of its own. See `Stop.reached`.
    ///
    /// `st_esc`, `st_c1` and `bel` are proper terminators. `cancelled`
    /// and `aborted` cut the string short.
    ///
    /// Inside an OSC, and inside a DCS once its header is complete, every
    /// 8-bit byte is content. Only ESC, CAN, SUB and (for OSC) BEL end
    /// those strings, so `st_c1` and `aborted` are only ever reported for
    /// an APC or for a DCS still in its header.
    pub const EndReason = lib.Enum(lib.target, &.{
        "st_esc",
        "st_c1",
        "cancelled",
        "aborted",
        "bel",
    });

    /// Where `Stream.nextSliceUntil` stopped and why.
    pub const Stop = struct {
        /// The number of input bytes consumed, including the byte that
        /// reached the boundary. This is 0 when the stream was already at
        /// ground and `.ground` was requested.
        consumed: usize,

        /// Every requested boundary that the stopping byte reached.
        ///
        /// This is usually one boundary. It holds two when a single byte
        /// does two things:
        ///
        /// - It ends a string and returns to ground. BEL, CAN, SUB, 0x9C
        ///   and the other 8-bit controls all do this, so an end stop also
        ///   includes `ground` when you asked for it.
        /// - It ends one string and starts another. An 8-bit introducer
        ///   of a different kind does this inside an APC, or inside a DCS
        ///   header: 0x90 or 0x9D in an APC ends it and starts a DCS or
        ///   OSC, and 0x9F, 0x98, 0x9E or 0x9D in a DCS header ends it
        ///   and starts an APC or OSC. Both `start` and `end` are set and
        ///   the end's reason is `aborted`.
        ///
        /// For example, in `ESC _ a 0x9D 2 ; t BEL` the 0x9D ends the APC
        /// and starts an OSC. Asking for `.apc_end` and `.osc_start` gives
        /// one stop on the 0x9D with both in `reached`, and the OSC's
        /// content `2;t` begins right after it.
        ///
        /// The second case never happens inside an OSC, or inside a DCS
        /// past its header, because 8-bit bytes are content there. It
        /// also does not happen for 0x98, 0x9E or 0x9F inside an APC,
        /// which the parser drops without a stop. A start and an end of
        /// the same kind never coincide.
        reached: Set,

        /// Set when `reached` contains a string start.
        start: ?Start = null,

        /// Set when `reached` contains a string end.
        end: ?End = null,

        pub const Start = struct {
            kind: StringKind,
            introducer: Introducer,

            /// The byte that started the string, such as `_`, `P`, `]`
            /// or 0x9F.
            byte: u8,
        };

        pub const End = struct {
            kind: StringKind,
            reason: EndReason,

            /// The byte that ended the string, such as ESC, BEL or 0x9C.
            byte: u8,
        };
    };
};

/// Scratch state for `Stream.nextSliceUntil`. The parsing functions take
/// a `comptime until: bool` and an `Until.Arg(until)`, which is one of
/// these in until mode and `void` otherwise, so the plain `nextSlice`
/// instantiation contains none of the boundary checks.
const Until = struct {
    /// The boundaries the caller asked to stop at.
    boundaries: Boundary.Set,

    /// The start of the full input. Every parsing function sees a
    /// subslice of it, so the byte that reaches a boundary is turned
    /// into a consumed count from its address, without threading
    /// offsets back up through every return value.
    base: [*]const u8,

    /// The stop being built. Null until a byte reaches a boundary.
    stop: ?Boundary.Stop = null,

    /// The string kind a parser state belongs to, or null for a state
    /// that is not inside a control string. The DCS states form one
    /// family: a string starts when the parser enters a family from
    /// outside it and ends when the parser leaves it, so moving
    /// between the DCS header and payload states is not a boundary.
    fn family(state: Parser.State) ?Boundary.StringKind {
        return switch (state) {
            .sos_pm_apc_string => .apc,
            .dcs_entry,
            .dcs_param,
            .dcs_intermediate,
            .dcs_passthrough,
            .dcs_ignore,
            => .dcs,
            .osc_string => .osc,
            else => null,
        };
    }

    /// Note that `c` moved the parser from state `old` to state `new`,
    /// and record a string end, a string start, or both, if that
    /// transition left or entered a string family.
    fn transition(
        self: *Until,
        old: Parser.State,
        new: Parser.State,
        c: u8,
    ) void {
        if (old == new) return;
        const from = family(old);
        const to = family(new);
        if (from) |kind| {
            if (to == null or to.? != kind) self.stringEnd(kind, c);
        }
        if (to) |kind| {
            if (from == null or from.? != kind) self.stringStart(kind, c);
        }
    }

    /// Note that `c` entered a string of the given kind.
    fn stringStart(self: *Until, kind: Boundary.StringKind, c: u8) void {
        const boundary: Boundary = switch (kind) {
            .apc => .apc_start,
            .dcs => .dcs_start,
            .osc => .osc_start,
        };
        if (!self.boundaries.contains(boundary)) return;
        const stop = self.stopPtr();
        stop.reached.insert(boundary);
        stop.start = .{
            .kind = kind,
            .introducer = if (c >= 0x80) .c1 else .esc,
            .byte = c,
        };
    }

    /// Note that `c` left a string of the given kind.
    fn stringEnd(self: *Until, kind: Boundary.StringKind, c: u8) void {
        const boundary: Boundary = switch (kind) {
            .apc => .apc_end,
            .dcs => .dcs_end,
            .osc => .osc_end,
        };
        if (!self.boundaries.contains(boundary)) return;
        const stop = self.stopPtr();
        stop.reached.insert(boundary);
        stop.end = .{
            .kind = kind,
            .reason = switch (c) {
                0x07 => .bel,
                0x18, 0x1A => .cancelled,
                0x1B => .st_esc,
                0x9C => .st_c1,
                else => .aborted,
            },
            .byte = c,
        };
    }

    fn stopPtr(self: *Until) *Boundary.Stop {
        if (self.stop == null) self.stop = .{
            .consumed = 0,
            .reached = .empty,
        };
        return &self.stop.?;
    }

    /// The parameter type the parsing functions take for a given
    /// `comptime until: bool`: a pointer to this in until mode and
    /// `void` otherwise.
    fn Arg(comptime until: bool) type {
        return if (until) *Until else void;
    }
};

/// Logs an unsupported-input message at most once per distinct key
/// per process.
///
/// These messages are emitted in response to input that the terminal
/// application controls, so a misbehaving (or merely chatty) program
/// can trigger the same message millions of times, e.g. by toggling
/// an unimplemented mode on every frame. Each log call has a real
/// throughput cost (formatting plus a blocking write per message)
/// while adding no diagnostic value beyond the first occurrence.
///
/// The keys seen so far are tracked in a small fixed table (64 bytes)
/// instantiated per (format, argument type) tuple, i.e. roughly per
/// call site. Real streams only ever produce a handful of distinct
/// unsupported values per site, so if the table ever fills, messages
/// for further new values are suppressed as well: by that point the
/// log already shows this class of problem and unbounded distinct
/// values would flood it anyway.
fn logUnsupportedOnce(
    comptime format: []const u8,
    args: anytype,
    key: u16,
) void {
    // u32 slots so every u16 key is representable alongside an empty
    // sentinel and so 32-bit targets (e.g. wasm32) have native
    // atomics.
    const empty = std.math.maxInt(u32);
    const Static = struct {
        var seen: [16]u32 = @splat(empty);
    };

    // The atomics make concurrent streams safe: slots are only ever
    // claimed, never changed, so the scan can stop at the first empty
    // slot. The worst case race is a benign duplicate message.
    for (&Static.seen) |*slot| {
        const cur = @atomicLoad(u32, slot, .acquire);
        if (cur == key) return; // already logged
        if (cur != empty) continue; // other key, keep scanning

        // Empty slot: claim it for this key and log below.
        const actual = @cmpxchgStrong(
            u32,
            slot,
            empty,
            key,
            .acq_rel,
            .acquire,
        ) orelse break;

        // Lost the race: suppress if it was to the same key, keep
        // scanning otherwise.
        if (actual == key) return;
    } else return; // table full: suppress new values too

    log.warn(format, args);
}

test Action {
    // Forces the C type to be reified when the target is C, ensuring
    // all our types are C ABI compatible.
    _ = Action.C;
}

test "stream: print" {
    const H = struct {
        c: ?u21 = 0,

        pub fn vt(
            self: *@This(),
            comptime action: Action.Tag,
            value: Action.Value(action),
        ) void {
            switch (action) {
                .print => self.c = value.cp,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{ .handler = .{} });
    s.next('x');
    try testing.expectEqual(@as(u21, 'x'), s.handler.c.?);
}

test "simd: print invalid utf-8" {
    const H = struct {
        c: ?u21 = 0,

        pub fn vt(
            self: *@This(),
            comptime action: Action.Tag,
            value: Action.Value(action),
        ) void {
            switch (action) {
                .print => self.c = value.cp,
                .print_slice => self.c = @intCast(value.cps[value.cps.len - 1]),
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{ .handler = .{} });
    s.nextSlice(&.{0xFF});
    try testing.expectEqual(@as(u21, 0xFFFD), s.handler.c.?);
}

test "simd: complete incomplete utf-8" {
    const H = struct {
        c: ?u21 = null,

        pub fn vt(
            self: *@This(),
            comptime action: Action.Tag,
            value: Action.Value(action),
        ) void {
            switch (action) {
                .print => self.c = value.cp,
                .print_slice => self.c = @intCast(value.cps[value.cps.len - 1]),
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{ .handler = .{} });
    s.nextSlice(&.{0xE0}); // 3 byte
    try testing.expect(s.handler.c == null);
    s.nextSlice(&.{0xA0}); // still incomplete
    try testing.expect(s.handler.c == null);
    s.nextSlice(&.{0x80});
    try testing.expectEqual(@as(u21, 0x800), s.handler.c.?);
}

test "stream: ground state C0 controls are executed, not printed" {
    const H = struct {
        buf: [128]u21 = undefined,
        len: usize = 0,

        pub fn vt(
            self: *@This(),
            comptime action: Action.Tag,
            value: Action.Value(action),
        ) void {
            switch (action) {
                .print => {
                    self.buf[self.len] = value.cp;
                    self.len += 1;
                },
                .print_slice => for (value.cps) |cp| {
                    self.buf[self.len] = @intCast(cp);
                    self.len += 1;
                },
                else => {},
            }
        }
    };

    // Every C0 control except ESC must never produce a print action
    // in the ground state. ESC is excluded because it begins an
    // escape sequence rather than executing.
    for (0..0x20) |c| {
        if (c == 0x1B) continue;

        // Scalar path.
        {
            var s: Stream(H) = .init(.{ .handler = .{} });
            s.next('A');
            s.next(@intCast(c));
            s.next('B');
            try testing.expectEqual(@as(usize, 2), s.handler.len);
            try testing.expectEqual(@as(u21, 'A'), s.handler.buf[0]);
            try testing.expectEqual(@as(u21, 'B'), s.handler.buf[1]);
        }

        // Batched path.
        {
            var s: Stream(H) = .init(.{ .handler = .{} });
            s.nextSlice(&.{ 'A', 'B', @intCast(c), 'C', 'D' });
            try testing.expectEqual(@as(usize, 4), s.handler.len);
            for ("ABCD", 0..) |expected, i| {
                try testing.expectEqual(@as(u21, expected), s.handler.buf[i]);
            }
        }

        // Batched path with a run long enough to exercise the
        // vectorized printable-run scan on either side of the control.
        {
            var s: Stream(H) = .init(.{ .handler = .{} });
            var input: [65]u8 = @splat('A');
            input[32] = @intCast(c);
            s.nextSlice(&input);
            try testing.expectEqual(@as(usize, 64), s.handler.len);
            for (s.handler.buf[0..s.handler.len]) |cp| {
                try testing.expectEqual(@as(u21, 'A'), cp);
            }
        }
    }
}

test "stream: ground state UTF-8-decoded C1 controls are ignored" {
    const H = struct {
        buf: [128]u21 = undefined,
        len: usize = 0,

        pub fn vt(
            self: *@This(),
            comptime action: Action.Tag,
            value: Action.Value(action),
        ) void {
            switch (action) {
                .print => {
                    self.buf[self.len] = value.cp;
                    self.len += 1;
                },
                .print_slice => for (value.cps) |cp| {
                    self.buf[self.len] = @intCast(cp);
                    self.len += 1;
                },
                else => {},
            }
        }
    };

    // Every C1 control that arrives as well-formed UTF-8 (a two byte
    // 0xC2-lead sequence) must be dropped: not printed and not
    // interpreted as a control (e.g. U+009B must not start a CSI).
    for (0x80..0xA0) |c| {
        const enc: [2]u8 = .{ 0xC2, @intCast(c) };

        // Scalar path.
        {
            var s: Stream(H) = .init(.{ .handler = .{} });
            s.next('A');
            s.next(enc[0]);
            s.next(enc[1]);
            s.next('B');
            try testing.expectEqual(@as(usize, 2), s.handler.len);
            try testing.expectEqual(@as(u21, 'A'), s.handler.buf[0]);
            try testing.expectEqual(@as(u21, 'B'), s.handler.buf[1]);
        }

        // Batched path.
        {
            var s: Stream(H) = .init(.{ .handler = .{} });
            s.nextSlice(&.{ 'A', 'B', enc[0], enc[1], 'C', 'D' });
            try testing.expectEqual(@as(usize, 4), s.handler.len);
            for ("ABCD", 0..) |expected, i| {
                try testing.expectEqual(@as(u21, expected), s.handler.buf[i]);
            }
        }

        // Batched path with a run long enough to exercise the
        // vectorized printable-run scan on either side of the control.
        {
            var s: Stream(H) = .init(.{ .handler = .{} });
            var input: [66]u8 = @splat('A');
            input[32] = enc[0];
            input[33] = enc[1];
            s.nextSlice(&input);
            try testing.expectEqual(@as(usize, 64), s.handler.len);
            for (s.handler.buf[0..s.handler.len]) |cp| {
                try testing.expectEqual(@as(u21, 'A'), cp);
            }
        }
    }

    // U+00A0 (NBSP), just past the C1 range, must still print.
    {
        var s: Stream(H) = .init(.{ .handler = .{} });
        s.nextSlice(&.{ 0xC2, 0xA0 });
        try testing.expectEqual(@as(usize, 1), s.handler.len);
        try testing.expectEqual(@as(u21, 0xA0), s.handler.buf[0]);
    }

    // A codepoint whose continuation byte falls in the C1 range must
    // still print: "Ü" is 0xC3 0x9C.
    {
        var s: Stream(H) = .init(.{ .handler = .{} });
        s.nextSlice("Ü");
        try testing.expectEqual(@as(usize, 1), s.handler.len);
        try testing.expectEqual(@as(u21, 0xDC), s.handler.buf[0]);
    }

    // A raw C1 byte is ill-formed UTF-8, not a decoded C1: it must
    // still produce a U+FFFD replacement.
    {
        var s: Stream(H) = .init(.{ .handler = .{} });
        s.nextSlice(&.{0x9B});
        try testing.expectEqual(@as(usize, 1), s.handler.len);
        try testing.expectEqual(@as(u21, 0xFFFD), s.handler.buf[0]);
    }
}

test "stream: cursor right (CUF)" {
    const H = struct {
        amount: u16 = 0,

        pub fn vt(
            self: *@This(),
            comptime action: Action.Tag,
            value: Action.Value(action),
        ) void {
            switch (action) {
                .cursor_right => self.amount = value.value,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{ .handler = .{} });
    s.nextSlice("\x1B[C");
    try testing.expectEqual(@as(u16, 1), s.handler.amount);

    s.nextSlice("\x1B[5C");
    try testing.expectEqual(@as(u16, 5), s.handler.amount);

    s.handler.amount = 0;
    s.nextSlice("\x1B[5;4C");
    try testing.expectEqual(@as(u16, 0), s.handler.amount);

    s.handler.amount = 0;
    s.nextSlice("\x1b[?3C");
    try testing.expectEqual(@as(u16, 0), s.handler.amount);
}

test "stream: dec set mode (SM) and reset mode (RM)" {
    const H = struct {
        mode: modes.Mode = @as(modes.Mode, @fromBackingInt(1)),

        pub fn vt(
            self: *@This(),
            comptime action: Action.Tag,
            value: Action.Value(action),
        ) void {
            switch (action) {
                .set_mode => self.mode = value.mode,
                .reset_mode => self.mode = @as(modes.Mode, @fromBackingInt(1)),
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{ .handler = .{} });
    s.nextSlice("\x1B[?6h");
    try testing.expectEqual(@as(modes.Mode, .origin), s.handler.mode);

    s.nextSlice("\x1B[?6l");
    try testing.expectEqual(@as(modes.Mode, @fromBackingInt(1)), s.handler.mode);

    s.handler.mode = @as(modes.Mode, @fromBackingInt(1));
    s.nextSlice("\x1B[6 h");
    try testing.expectEqual(@as(modes.Mode, @fromBackingInt(1)), s.handler.mode);
}

test "stream: ansi set mode (SM) and reset mode (RM)" {
    const H = struct {
        mode: ?modes.Mode = null,

        pub fn vt(
            self: *@This(),
            comptime action: Action.Tag,
            value: Action.Value(action),
        ) void {
            switch (action) {
                .set_mode => self.mode = value.mode,
                .reset_mode => self.mode = null,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{ .handler = .{} });
    s.nextSlice("\x1B[4h");
    try testing.expectEqual(@as(modes.Mode, .insert), s.handler.mode.?);

    s.nextSlice("\x1B[4l");
    try testing.expect(s.handler.mode == null);

    s.handler.mode = null;
    s.nextSlice("\x1B[>5h");
    try testing.expect(s.handler.mode == null);
}

test "stream: DECSTR dispatch" {
    const H = struct {
        calls: usize = 0,

        pub fn vt(self: *@This(), comptime action: Action.Tag, value: Action.Value(action)) void {
            _ = value;
            switch (action) {
                .soft_reset => self.calls += 1,
                else => {},
            }
        }
    };

    const cases = [_]struct {
        input: []const u8,
        calls: usize,
    }{
        .{ .input = "\x1b[!p", .calls = 1 },
        .{ .input = "\x1b[1!p", .calls = 0 },
        .{ .input = "\x1b[?!p", .calls = 0 },
        .{ .input = "\x1b[$p", .calls = 0 },
    };

    for (cases) |case| {
        var s: Stream(H) = .init(.{ .handler = .{} });
        s.nextSlice(case.input);
        try testing.expectEqual(case.calls, s.handler.calls);
    }
}

test "stream: device status dispatch" {
    const H = struct {
        calls: usize = 0,
        value: ?Action.DeviceStatus = null,

        pub fn vt(self: *@This(), comptime action: Action.Tag, value: Action.Value(action)) void {
            switch (action) {
                .device_status => {
                    self.calls += 1;
                    self.value = value;
                },
                else => {},
            }
        }
    };

    const cases = [_]struct {
        input: []const u8,
        value: ?Action.DeviceStatus = null,
    }{
        .{ .input = "\x1b[5n", .value = .{ .request = .operating_status } },
        .{ .input = "\x1b[?26n", .value = .{ .request = .keyboard_status } },
        .{ .input = "\x1b[?63;123n", .value = .{ .request = .memory_checksum, .id = 123 } },
        .{ .input = "\x1b[?63n", .value = .{ .request = .memory_checksum } },
        // Only DECCKSR takes an id.
        .{ .input = "\x1b[?26;1n" },
        .{ .input = "\x1b[?63;1;2n" },
        .{ .input = "\x1b[n" },
        // Unknown requests are ignored.
        .{ .input = "\x1b[?64n" },
    };

    for (cases) |case| {
        var s: Stream(H) = .init(.{ .handler = .{} });
        s.nextSlice(case.input);
        try testing.expectEqual(@intFromBool(case.value != null), s.handler.calls);
        try testing.expectEqual(case.value, s.handler.value);
    }
}

test "stream: DECRQCRA dispatch" {
    const H = struct {
        calls: usize = 0,
        req: ?xt_checksum.Request = null,

        pub fn vt(self: *@This(), comptime action: Action.Tag, value: Action.Value(action)) void {
            switch (action) {
                .request_xt_checksum => {
                    self.calls += 1;
                    self.req = value;
                },
                else => {},
            }
        }
    };

    const cases = [_]struct {
        input: []const u8,
        req: ?xt_checksum.Request = null,
    }{
        .{
            .input = "\x1b[7;1;2;3;4;5*y",
            .req = .{ .id = 7, .top = 2, .left = 3, .bottom = 4, .right = 5 },
        },
        .{ .input = "\x1b[7*y", .req = .{ .id = 7 } },
        .{ .input = "\x1b[*y", .req = .{} },
        .{ .input = "\x1b[1;1;2;3*y", .req = .{ .id = 1, .top = 2, .left = 3 } },
        .{ .input = "\x1b[1;1;1;1;1;1;1*y" },
        .{ .input = "\x1b[1;1;1;1;1;1y" },
        .{ .input = "\x1b[1;1;1;1;1;1\"y" },
    };

    for (cases) |case| {
        var s: Stream(H) = .init(.{ .handler = .{} });
        s.nextSlice(case.input);
        if (case.req) |req| {
            try testing.expectEqual(1, s.handler.calls);
            try testing.expectEqual(req, s.handler.req.?);
        } else {
            try testing.expectEqual(0, s.handler.calls);
        }
    }
}

test "stream: XTCHECKSUM dispatch" {
    const H = struct {
        calls: usize = 0,
        flags: ?xt_checksum.Flags = null,

        pub fn vt(self: *@This(), comptime action: Action.Tag, value: Action.Value(action)) void {
            switch (action) {
                .xt_checksum_extension => {
                    self.calls += 1;
                    self.flags = value.flags;
                },
                else => {},
            }
        }
    };

    const cases = [_]struct {
        input: []const u8,
        flags: ?xt_checksum.Flags = null,
    }{
        .{ .input = "\x1b[#y", .flags = .{} },
        .{ .input = "\x1b[0#y", .flags = .{} },
        .{ .input = "\x1b[5#y", .flags = .{ .positive = true, .no_trim = true } },
        .{ .input = "\x1b[48#y", .flags = .{ .full = true } },
        .{ .input = "\x1b[1;2#y" },
    };

    for (cases) |case| {
        var s: Stream(H) = .init(.{ .handler = .{} });
        s.nextSlice(case.input);
        if (case.flags) |flags| {
            try testing.expectEqual(1, s.handler.calls);
            try testing.expectEqual(flags, s.handler.flags.?);
        } else {
            try testing.expectEqual(0, s.handler.calls);
        }
    }
}

test "stream: DECRQM dispatch" {
    const H = struct {
        calls: usize = 0,
        mode: ?modes.Mode = null,
        raw: ?Action.RawMode = null,

        pub fn vt(self: *@This(), comptime action: Action.Tag, value: Action.Value(action)) void {
            switch (action) {
                .request_mode => {
                    self.calls += 1;
                    self.mode = value.mode;
                },
                .request_mode_unknown => {
                    self.calls += 1;
                    self.raw = value;
                },
                else => {},
            }
        }
    };

    const cases = [_]struct {
        input: []const u8,
        mode: ?modes.Mode = null,
        raw: ?Action.RawMode = null,
    }{
        .{ .input = "\x1b[4$p", .mode = .insert },
        .{ .input = "\x1b[?4$p", .mode = .slow_scroll },
        .{ .input = "\x1b[9999$p", .raw = .{ .mode = 9999, .ansi = true } },
        .{ .input = "\x1b[?9999$p", .raw = .{ .mode = 9999, .ansi = false } },
        .{ .input = "\x1b[4p" },
        .{ .input = "\x1b[?4p" },
        .{ .input = "\x1b[4!p" },
        .{ .input = "\x1b[4 p" },
        .{ .input = "\x1b[>4$p" },
        .{ .input = "\x1b[?4!p" },
        .{ .input = "\x1b[$p" },
        .{ .input = "\x1b[?$p" },
        .{ .input = "\x1b[4;20$p" },
        .{ .input = "\x1b[?4;7$p" },
        .{ .input = "\x1b[4:20$p" },
    };
    for (cases) |case| {
        for (0..case.input.len + 1) |split| {
            var s: Stream(H) = .init(.{ .handler = .{} });
            s.nextSlice(case.input[0..split]);
            if (split < case.input.len) try testing.expectEqual(0, s.handler.calls);
            s.nextSlice(case.input[split..]);
            try testing.expectEqual(@as(usize, if (case.mode != null or case.raw != null) 1 else 0), s.handler.calls);
            try testing.expectEqual(case.mode, s.handler.mode);
            try testing.expectEqualDeep(case.raw, s.handler.raw);
        }
    }
}

test "stream: ansi set mode (SM) and reset mode (RM) with unknown value" {
    const H = struct {
        mode: ?modes.Mode = null,

        pub fn setMode(self: *@This(), mode: modes.Mode, v: bool) !void {
            self.mode = null;
            if (v) self.mode = mode;
        }

        pub fn vt(
            self: *@This(),
            comptime action: Action.Tag,
            value: Action.Value(action),
        ) void {
            _ = self;
            _ = value;
        }
    };

    var s: Stream(H) = .init(.{ .handler = .{} });
    s.nextSlice("\x1B[6h");
    try testing.expect(s.handler.mode == null);

    s.nextSlice("\x1B[6l");
    try testing.expect(s.handler.mode == null);
}

test "stream: restore mode" {
    const H = struct {
        const Self = @This();
        called: bool = false,

        pub fn vt(
            self: *Self,
            comptime action: Stream(Self).Action.Tag,
            value: Stream(Self).Action.Value(action),
        ) void {
            _ = value;
            switch (action) {
                .top_and_bottom_margin => self.called = true,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{ .handler = .{} });
    for ("\x1B[?42r") |c| s.next(c);
    try testing.expect(!s.handler.called);
}

test "stream: pop kitty keyboard with no params defaults to 1" {
    const H = struct {
        const Self = @This();
        n: u16 = 0,

        pub fn vt(
            self: *Self,
            comptime action: streampkg.Action.Tag,
            value: streampkg.Action.Value(action),
        ) void {
            switch (action) {
                .kitty_keyboard_pop => self.n = value,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{ .handler = .{} });
    for ("\x1B[<u") |c| s.next(c);
    try testing.expectEqual(@as(u16, 1), s.handler.n);
}

test "stream: DECSCA" {
    const H = struct {
        const Self = @This();
        v: ?ansi.ProtectedMode = null,

        pub fn vt(
            self: *Self,
            comptime action: Stream(Self).Action.Tag,
            value: Stream(Self).Action.Value(action),
        ) void {
            _ = value;
            switch (action) {
                .protected_mode_off => self.v = .off,
                .protected_mode_iso => self.v = .iso,
                .protected_mode_dec => self.v = .dec,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{ .handler = .{} });
    {
        for ("\x1B[\"q") |c| s.next(c);
        try testing.expectEqual(ansi.ProtectedMode.off, s.handler.v.?);
    }
    {
        for ("\x1B[0\"q") |c| s.next(c);
        try testing.expectEqual(ansi.ProtectedMode.off, s.handler.v.?);
    }
    {
        for ("\x1B[2\"q") |c| s.next(c);
        try testing.expectEqual(ansi.ProtectedMode.off, s.handler.v.?);
    }
    {
        for ("\x1B[1\"q") |c| s.next(c);
        try testing.expectEqual(ansi.ProtectedMode.dec, s.handler.v.?);
    }
}

test "stream: DECED, DECSED" {
    const H = struct {
        const Self = @This();
        mode: ?csi.EraseDisplay = null,
        protected: ?bool = null,

        pub fn vt(
            self: *Self,
            comptime action: anytype,
            value: anytype,
        ) void {
            switch (action) {
                .erase_display_below => {
                    self.mode = .below;
                    self.protected = value;
                },
                .erase_display_above => {
                    self.mode = .above;
                    self.protected = value;
                },
                .erase_display_complete => {
                    self.mode = .complete;
                    self.protected = value;
                },
                .erase_display_scrollback => {
                    self.mode = .scrollback;
                    self.protected = value;
                },
                .erase_display_scroll_complete => {
                    self.mode = .scroll_complete;
                    self.protected = value;
                },
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{ .handler = .{} });
    {
        for ("\x1B[?J") |c| s.next(c);
        try testing.expectEqual(csi.EraseDisplay.below, s.handler.mode.?);
        try testing.expect(s.handler.protected.?);
    }
    {
        for ("\x1B[?0J") |c| s.next(c);
        try testing.expectEqual(csi.EraseDisplay.below, s.handler.mode.?);
        try testing.expect(s.handler.protected.?);
    }
    {
        for ("\x1B[?1J") |c| s.next(c);
        try testing.expectEqual(csi.EraseDisplay.above, s.handler.mode.?);
        try testing.expect(s.handler.protected.?);
    }
    {
        for ("\x1B[?2J") |c| s.next(c);
        try testing.expectEqual(csi.EraseDisplay.complete, s.handler.mode.?);
        try testing.expect(s.handler.protected.?);
    }
    {
        for ("\x1B[?3J") |c| s.next(c);
        try testing.expectEqual(csi.EraseDisplay.scrollback, s.handler.mode.?);
        try testing.expect(s.handler.protected.?);
    }

    {
        for ("\x1B[J") |c| s.next(c);
        try testing.expectEqual(csi.EraseDisplay.below, s.handler.mode.?);
        try testing.expect(!s.handler.protected.?);
    }
    {
        for ("\x1B[0J") |c| s.next(c);
        try testing.expectEqual(csi.EraseDisplay.below, s.handler.mode.?);
        try testing.expect(!s.handler.protected.?);
    }
    {
        for ("\x1B[1J") |c| s.next(c);
        try testing.expectEqual(csi.EraseDisplay.above, s.handler.mode.?);
        try testing.expect(!s.handler.protected.?);
    }
    {
        for ("\x1B[2J") |c| s.next(c);
        try testing.expectEqual(csi.EraseDisplay.complete, s.handler.mode.?);
        try testing.expect(!s.handler.protected.?);
    }
    {
        for ("\x1B[3J") |c| s.next(c);
        try testing.expectEqual(csi.EraseDisplay.scrollback, s.handler.mode.?);
        try testing.expect(!s.handler.protected.?);
    }
    {
        // Invalid and ignored by the handler
        for ("\x1B[>0J") |c| s.next(c);
        try testing.expectEqual(csi.EraseDisplay.scrollback, s.handler.mode.?);
        try testing.expect(!s.handler.protected.?);
    }
}

test "stream: DECEL, DECSEL" {
    const H = struct {
        const Self = @This();
        mode: ?csi.EraseLine = null,
        protected: ?bool = null,

        pub fn vt(
            self: *Self,
            comptime action: anytype,
            value: anytype,
        ) void {
            switch (action) {
                .erase_line_right => {
                    self.mode = .right;
                    self.protected = value;
                },
                .erase_line_left => {
                    self.mode = .left;
                    self.protected = value;
                },
                .erase_line_complete => {
                    self.mode = .complete;
                    self.protected = value;
                },
                .erase_line_right_unless_pending_wrap => {
                    self.mode = .right_unless_pending_wrap;
                    self.protected = value;
                },
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{ .handler = .{} });
    {
        for ("\x1B[?K") |c| s.next(c);
        try testing.expectEqual(csi.EraseLine.right, s.handler.mode.?);
        try testing.expect(s.handler.protected.?);
    }
    {
        for ("\x1B[?0K") |c| s.next(c);
        try testing.expectEqual(csi.EraseLine.right, s.handler.mode.?);
        try testing.expect(s.handler.protected.?);
    }
    {
        for ("\x1B[?1K") |c| s.next(c);
        try testing.expectEqual(csi.EraseLine.left, s.handler.mode.?);
        try testing.expect(s.handler.protected.?);
    }
    {
        for ("\x1B[?2K") |c| s.next(c);
        try testing.expectEqual(csi.EraseLine.complete, s.handler.mode.?);
        try testing.expect(s.handler.protected.?);
    }

    {
        for ("\x1B[K") |c| s.next(c);
        try testing.expectEqual(csi.EraseLine.right, s.handler.mode.?);
        try testing.expect(!s.handler.protected.?);
    }
    {
        for ("\x1B[0K") |c| s.next(c);
        try testing.expectEqual(csi.EraseLine.right, s.handler.mode.?);
        try testing.expect(!s.handler.protected.?);
    }
    {
        for ("\x1B[1K") |c| s.next(c);
        try testing.expectEqual(csi.EraseLine.left, s.handler.mode.?);
        try testing.expect(!s.handler.protected.?);
    }
    {
        for ("\x1B[2K") |c| s.next(c);
        try testing.expectEqual(csi.EraseLine.complete, s.handler.mode.?);
        try testing.expect(!s.handler.protected.?);
    }
    {
        // Invalid and ignored by the handler
        for ("\x1B[<1K") |c| s.next(c);
        try testing.expectEqual(csi.EraseLine.complete, s.handler.mode.?);
        try testing.expect(!s.handler.protected.?);
    }
}

test "stream: DECSCUSR" {
    const H = struct {
        style: ?ansi.CursorStyle = null,

        pub fn vt(
            self: *@This(),
            comptime action: Stream(@This()).Action.Tag,
            value: Stream(@This()).Action.Value(action),
        ) void {
            switch (action) {
                .cursor_style => self.style = value,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{ .handler = .{} });
    s.nextSlice("\x1B[ q");
    try testing.expect(s.handler.style.? == .default);

    s.nextSlice("\x1B[1 q");
    try testing.expect(s.handler.style.? == .blinking_block);

    // Invalid and ignored by the handler
    s.nextSlice("\x1B[?0 q");
    try testing.expect(s.handler.style.? == .blinking_block);
}

test "stream: DECSCUSR without space" {
    const H = struct {
        style: ?ansi.CursorStyle = null,

        pub fn vt(
            self: *@This(),
            comptime action: Stream(@This()).Action.Tag,
            value: Stream(@This()).Action.Value(action),
        ) void {
            switch (action) {
                .cursor_style => self.style = value,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{ .handler = .{} });
    s.nextSlice("\x1B[q");
    try testing.expect(s.handler.style == null);

    s.nextSlice("\x1B[1q");
    try testing.expect(s.handler.style == null);
}

test "stream: XTSHIFTESCAPE" {
    const H = struct {
        escape: ?bool = null,

        pub fn vt(
            self: *@This(),
            comptime action: streampkg.Action.Tag,
            value: streampkg.Action.Value(action),
        ) void {
            switch (action) {
                .mouse_shift_capture => self.escape = value,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{ .handler = .{} });
    s.nextSlice("\x1B[>2s");
    try testing.expect(s.handler.escape == null);

    s.nextSlice("\x1B[>s");
    try testing.expect(s.handler.escape.? == false);

    s.nextSlice("\x1B[>0s");
    try testing.expect(s.handler.escape.? == false);

    s.nextSlice("\x1B[>1s");
    try testing.expect(s.handler.escape.? == true);

    // Invalid and ignored by the handler
    s.nextSlice("\x1B[1 s");
    try testing.expect(s.handler.escape.? == true);
}

test "stream: change window title with invalid utf-8" {
    const H = struct {
        seen: bool = false,

        pub fn vt(
            self: *@This(),
            comptime action: anytype,
            value: anytype,
        ) void {
            _ = value;
            switch (action) {
                .window_title => self.seen = true,
                else => {},
            }
        }
    };

    {
        var s: Stream(H) = .init(.{ .handler = .{} });
        s.nextSlice("\x1b]2;abc\x1b\\");
        try testing.expect(s.handler.seen);
    }

    {
        var s: Stream(H) = .init(.{ .handler = .{} });
        s.nextSlice("\x1b]2;abc\xc0\x1b\\");
        try testing.expect(!s.handler.seen);
    }
}

test "stream: osc 52 large payload in chunks" {
    const alloc = testing.allocator;

    const H = struct {
        const Self = @This();
        data: std.ArrayListUnmanaged(u8) = .empty,
        kind: u8 = 0,
        terminator: ?osc.Terminator = null,
        count: usize = 0,

        pub fn vt(
            self: *Self,
            comptime action: Action.Tag,
            value: Action.Value(action),
        ) void {
            switch (action) {
                .clipboard_contents => {
                    self.count += 1;
                    self.kind = value.kind;
                    self.terminator = value.terminator;
                    self.data.appendSlice(
                        testing.allocator,
                        value.data,
                    ) catch @panic("OOM");
                },
                else => {},
            }
        }
    };

    // A payload that far exceeds the fixed buffer so the allocating
    // capture is used, fed in chunk sizes that don't align with the
    // sequence so the bulk path sees every kind of boundary.
    const prefix = "\x1b]52;c;";
    const payload_len = 150_000;
    var input: std.ArrayListUnmanaged(u8) = .empty;
    defer input.deinit(alloc);
    try input.appendSlice(alloc, prefix);
    for (0..payload_len) |i| try input.append(
        alloc,
        'A' + @as(u8, @intCast(i % 26)),
    );
    try input.appendSlice(alloc, "\x1b\\");

    var s: Stream(H) = .init(.{ .handler = .{}, .allocator = alloc });
    defer s.parser.deinit();
    defer s.handler.data.deinit(alloc);

    var i: usize = 0;
    while (i < input.items.len) {
        const end = @min(i + 4093, input.items.len);
        s.nextSlice(input.items[i..end]);
        i = end;
    }

    try testing.expectEqual(@as(usize, 1), s.handler.count);
    try testing.expectEqual(@as(u8, 'c'), s.handler.kind);
    try testing.expectEqual(osc.Terminator.st, s.handler.terminator.?);
    try testing.expectEqualSlices(
        u8,
        input.items[prefix.len .. prefix.len + payload_len],
        s.handler.data.items,
    );
}

test "stream: osc bulk path matches per-byte path" {
    const alloc = testing.allocator;

    // Records every dispatch relevant to OSC processing in a
    // normalized text form so streams fed different ways can be
    // compared byte-for-byte.
    const H = struct {
        const Self = @This();
        alloc: Allocator,
        journal: std.ArrayListUnmanaged(u8) = .empty,

        fn record(self: *Self, comptime fmt: []const u8, args: anytype) void {
            const s = self.alloc.print(
                fmt,
                args,
            ) catch @panic("OOM");
            defer self.alloc.free(s);
            self.journal.appendSlice(self.alloc, s) catch @panic("OOM");
        }

        pub fn vt(
            self: *Self,
            comptime action: Action.Tag,
            value: Action.Value(action),
        ) void {
            switch (action) {
                .clipboard_contents => self.record(
                    "clip kind={c} term={s} data={s}\n",
                    .{ value.kind, @tagName(value.terminator), value.data },
                ),
                .kitty_clipboard => self.record(
                    "kitty meta={s} payload={?s}\n",
                    .{ value.metadata, value.payload },
                ),
                .window_title => self.record(
                    "title {s}\n",
                    .{value.title},
                ),
                // Normalize prints to per-codepoint so the per-byte
                // and slice paths journal identically.
                .print => self.record("print {u}\n", .{value.cp}),
                .print_slice => for (value.cps) |cp| self.record(
                    "print {u}\n",
                    .{@as(u21, @intCast(cp))},
                ),
                else => {},
            }
        }
    };

    const ys: [3000]u8 = @splat('y');
    const xs: [3000]u8 = @splat('x');

    const cases = [_][]const u8{
        "\x1b]52;c;aGVsbG8=\x1b\\",
        "\x1b]52;c;aGVsbG8=\x07",
        "\x1b]52;;aGVsbG8=\x07",
        // Ignored C0 byte embedded in the payload.
        "\x1b]52;c;aGVs\x01bG8=\x07",
        // CAN and SUB aborts.
        "\x1b]52;c;aGVsbG8=\x18",
        "\x1b]52;c;aGVsbG8=\x1a",
        // C1 byte embedded in the payload is data.
        "\x1b]0;ab\x9ccd\x07",
        // Terminated with trailing printable text.
        "\x1b]0;a title\x07x",
        // Back-to-back sequences.
        "\x1b]2;another title\x1b\\\x1b]0;t2\x07",
        "\x1b]5522;type=write;aGVsbG8=\x1b\\",
        // Invalid OSC number.
        "\x1b]999;junk\x07",
        // Exceeds the fixed buffer: allocating capture.
        "\x1b]52;c;" ++ ys ++ "\x1b\\",
        // Exceeds the fixed buffer: overflow, no dispatch.
        "\x1b]0;" ++ xs ++ "\x07",
    };

    for (cases) |case| {
        // Reference: byte-at-a-time.
        var ref: Stream(H) = .init(.{
            .handler = .{ .alloc = alloc },
            .allocator = alloc,
        });
        defer ref.parser.deinit();
        defer ref.handler.journal.deinit(alloc);
        for (case) |c| ref.next(c);

        // The whole slice at once.
        {
            var s: Stream(H) = .init(.{
                .handler = .{ .alloc = alloc },
                .allocator = alloc,
            });
            defer s.parser.deinit();
            defer s.handler.journal.deinit(alloc);
            s.nextSlice(case);
            try testing.expectEqualSlices(
                u8,
                ref.handler.journal.items,
                s.handler.journal.items,
            );
        }

        // Split into two slices at every possible boundary.
        for (0..case.len + 1) |split| {
            var s: Stream(H) = .init(.{
                .handler = .{ .alloc = alloc },
                .allocator = alloc,
            });
            defer s.parser.deinit();
            defer s.handler.journal.deinit(alloc);
            s.nextSlice(case[0..split]);
            s.nextSlice(case[split..]);
            try testing.expectEqualSlices(
                u8,
                ref.handler.journal.items,
                s.handler.journal.items,
            );
        }
    }
}

test "stream: insert characters" {
    const H = struct {
        const Self = @This();
        called: bool = false,

        pub fn vt(
            self: *Self,
            comptime action: anytype,
            value: anytype,
        ) void {
            _ = value;
            switch (action) {
                .insert_blanks => self.called = true,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{ .handler = .{} });
    for ("\x1B[42@") |c| s.next(c);
    try testing.expect(s.handler.called);

    s.handler.called = false;
    for ("\x1B[?42@") |c| s.next(c);
    try testing.expect(!s.handler.called);
}

test "stream: insert characters explicit zero clamps to 1" {
    const H = struct {
        const Self = @This();
        value: ?usize = null,

        pub fn vt(
            self: *Self,
            comptime action: anytype,
            value: anytype,
        ) void {
            switch (action) {
                .insert_blanks => self.value = value,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{ .handler = .{} });
    for ("\x1B[0@") |c| s.next(c);
    try testing.expectEqual(@as(usize, 1), s.handler.value.?);
}

test "stream: DECIC and DECDC" {
    const H = struct {
        const Self = @This();
        insert: ?usize = null,
        delete: ?usize = null,

        pub fn vt(
            self: *Self,
            comptime action: anytype,
            value: anytype,
        ) void {
            switch (action) {
                .insert_columns => self.insert = value,
                .delete_columns => self.delete = value,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{ .handler = .{} });
    for ("\x1B['}") |c| s.next(c);
    try testing.expectEqual(@as(usize, 1), s.handler.insert.?);
    for ("\x1B[3'}") |c| s.next(c);
    try testing.expectEqual(@as(usize, 3), s.handler.insert.?);
    for ("\x1B[0'~") |c| s.next(c);
    try testing.expectEqual(@as(usize, 1), s.handler.delete.?);
    for ("\x1B[5'~") |c| s.next(c);
    try testing.expectEqual(@as(usize, 5), s.handler.delete.?);

    // Without the intermediate these are other sequences.
    s.handler = .{};
    for ("\x1B[3}\x1B[3~") |c| s.next(c);
    try testing.expect(s.handler.insert == null);
    try testing.expect(s.handler.delete == null);
}

test "stream: DECBI and DECFI" {
    const H = struct {
        const Self = @This();
        back: usize = 0,
        forward: usize = 0,

        pub fn vt(
            self: *Self,
            comptime action: anytype,
            value: anytype,
        ) void {
            _ = value;
            switch (action) {
                .back_index => self.back += 1,
                .forward_index => self.forward += 1,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{ .handler = .{} });
    for ("\x1B6\x1B9\x1B9") |c| s.next(c);
    try testing.expectEqual(@as(usize, 1), s.handler.back);
    try testing.expectEqual(@as(usize, 2), s.handler.forward);
}

test "stream: SCOSC" {
    const H = struct {
        const Self = @This();
        called: bool = false,

        pub fn vt(
            self: *Self,
            comptime action: Stream(Self).Action.Tag,
            value: Stream(Self).Action.Value(action),
        ) void {
            _ = value;
            switch (action) {
                .left_and_right_margin => @panic("bad"),
                .left_and_right_margin_ambiguous => self.called = true,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{ .handler = .{} });
    for ("\x1B[s") |c| s.next(c);
    try testing.expect(s.handler.called);
}

test "stream: SCORC" {
    const H = struct {
        const Self = @This();
        called: bool = false,

        pub fn vt(
            self: *Self,
            comptime action: streampkg.Action.Tag,
            value: streampkg.Action.Value(action),
        ) void {
            _ = value;
            switch (action) {
                .restore_cursor => self.called = true,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{ .handler = .{} });
    for ("\x1B[u") |c| s.next(c);
    try testing.expect(s.handler.called);
}

test "stream: too many csi params" {
    const H = struct {
        pub fn vt(
            self: *@This(),
            comptime action: anytype,
            value: anytype,
        ) void {
            _ = self;
            _ = value;
            switch (action) {
                .cursor_right => unreachable,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{ .handler = .{} });
    s.nextSlice("\x1B[1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1C");
}

test "stream: csi param too long" {
    const H = struct {
        pub fn vt(
            self: *@This(),
            comptime action: anytype,
            value: anytype,
        ) void {
            _ = self;
            _ = action;
            _ = value;
        }
    };

    var s: Stream(H) = .init(.{ .handler = .{} });
    s.nextSlice("\x1B[1111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111C");
}

test "stream: send report with CSI t" {
    const H = struct {
        style: ?csi.SizeReportStyle = null,

        pub fn vt(
            self: *@This(),
            comptime action: streampkg.Action.Tag,
            value: streampkg.Action.Value(action),
        ) void {
            switch (action) {
                .size_report => self.style = value,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{ .handler = .{} });

    s.nextSlice("\x1b[14t");
    try testing.expectEqual(csi.SizeReportStyle.csi_14_t, s.handler.style);

    s.nextSlice("\x1b[16t");
    try testing.expectEqual(csi.SizeReportStyle.csi_16_t, s.handler.style);

    s.nextSlice("\x1b[18t");
    try testing.expectEqual(csi.SizeReportStyle.csi_18_t, s.handler.style);

    s.nextSlice("\x1b[19t");
    try testing.expectEqual(csi.SizeReportStyle.csi_19_t, s.handler.style);

    s.nextSlice("\x1b[21t");
    try testing.expectEqual(csi.SizeReportStyle.csi_21_t, s.handler.style);
}

test "stream: CSI 8 t resize window" {
    const H = struct {
        size: ?streampkg.Action.ResizeWindow = null,

        pub fn vt(
            self: *@This(),
            comptime action: streampkg.Action.Tag,
            value: streampkg.Action.Value(action),
        ) void {
            switch (action) {
                .resize_window => self.size = value,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{ .handler = .{} });

    s.nextSlice("\x1b[8;40;120t");
    try testing.expectEqual(40, s.handler.size.?.rows);
    try testing.expectEqual(120, s.handler.size.?.columns);

    // Omitted parameters keep the current size
    s.nextSlice("\x1b[8;;100t");
    try testing.expectEqual(0, s.handler.size.?.rows);
    try testing.expectEqual(100, s.handler.size.?.columns);

    s.nextSlice("\x1b[8;30t");
    try testing.expectEqual(30, s.handler.size.?.rows);
    try testing.expectEqual(0, s.handler.size.?.columns);

    s.nextSlice("\x1b[8t");
    try testing.expectEqual(0, s.handler.size.?.rows);
    try testing.expectEqual(0, s.handler.size.?.columns);

    // Extra parameters are invalid
    s.handler.size = null;
    s.nextSlice("\x1b[8;30;100;1t");
    try testing.expect(s.handler.size == null);
}

test "stream: invalid CSI t" {
    const H = struct {
        style: ?csi.SizeReportStyle = null,

        pub fn sendSizeReport(self: *@This(), style: csi.SizeReportStyle) void {
            self.style = style;
        }

        pub fn vt(
            self: *@This(),
            comptime action: anytype,
            value: anytype,
        ) void {
            _ = self;
            _ = action;
            _ = value;
        }
    };

    var s: Stream(H) = .init(.{ .handler = .{} });

    s.nextSlice("\x1b[19t");
    try testing.expectEqual(null, s.handler.style);
}

test "stream: CSI t push title" {
    const H = struct {
        index: ?u16 = null,

        pub fn vt(
            self: *@This(),
            comptime action: streampkg.Action.Tag,
            value: streampkg.Action.Value(action),
        ) void {
            switch (action) {
                .title_push => self.index = value,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{ .handler = .{} });

    s.nextSlice("\x1b[22;0t");
    try testing.expectEqual(@as(u16, 0), s.handler.index.?);
}

test "stream: CSI t push title with explicit window" {
    const H = struct {
        index: ?u16 = null,

        pub fn vt(
            self: *@This(),
            comptime action: streampkg.Action.Tag,
            value: streampkg.Action.Value(action),
        ) void {
            switch (action) {
                .title_push => self.index = value,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{ .handler = .{} });

    s.nextSlice("\x1b[22;2t");
    try testing.expectEqual(@as(u16, 0), s.handler.index.?);
}

test "stream: CSI t push title with explicit icon" {
    const H = struct {
        index: ?u16 = null,

        pub fn vt(
            self: *@This(),
            comptime action: streampkg.Action.Tag,
            value: streampkg.Action.Value(action),
        ) void {
            switch (action) {
                .title_push => self.index = value,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{ .handler = .{} });

    s.nextSlice("\x1b[22;1t");
    try testing.expectEqual(null, s.handler.index);
}

test "stream: CSI t push title with index" {
    const H = struct {
        index: ?u16 = null,

        pub fn vt(
            self: *@This(),
            comptime action: streampkg.Action.Tag,
            value: streampkg.Action.Value(action),
        ) void {
            switch (action) {
                .title_push => self.index = value,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{ .handler = .{} });

    s.nextSlice("\x1b[22;0;5t");
    try testing.expectEqual(@as(u16, 5), s.handler.index.?);
}

test "stream: CSI t pop title" {
    const H = struct {
        index: ?u16 = null,

        pub fn vt(
            self: *@This(),
            comptime action: streampkg.Action.Tag,
            value: streampkg.Action.Value(action),
        ) void {
            switch (action) {
                .title_pop => self.index = value,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{ .handler = .{} });

    s.nextSlice("\x1b[23;0t");
    try testing.expectEqual(@as(u16, 0), s.handler.index.?);
}

test "stream: CSI t pop title with explicit window" {
    const H = struct {
        index: ?u16 = null,

        pub fn vt(
            self: *@This(),
            comptime action: streampkg.Action.Tag,
            value: streampkg.Action.Value(action),
        ) void {
            switch (action) {
                .title_pop => self.index = value,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{ .handler = .{} });

    s.nextSlice("\x1b[23;2t");
    try testing.expectEqual(@as(u16, 0), s.handler.index.?);
}

test "stream: CSI t pop title with explicit icon" {
    const H = struct {
        index: ?u16 = null,

        pub fn vt(
            self: *@This(),
            comptime action: streampkg.Action.Tag,
            value: streampkg.Action.Value(action),
        ) void {
            switch (action) {
                .title_pop => self.index = value,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{ .handler = .{} });

    s.nextSlice("\x1b[23;1t");
    try testing.expectEqual(null, s.handler.index);
}

test "stream: CSI t pop title with index" {
    const H = struct {
        index: ?u16 = null,

        pub fn vt(
            self: *@This(),
            comptime action: streampkg.Action.Tag,
            value: streampkg.Action.Value(action),
        ) void {
            switch (action) {
                .title_pop => self.index = value,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{ .handler = .{} });

    s.nextSlice("\x1b[23;0;5t");
    try testing.expectEqual(@as(u16, 5), s.handler.index.?);
}

test "stream CSI W clear tab stops" {
    const H = struct {
        action: ?Action.Key = null,

        pub fn vt(
            self: *@This(),
            comptime action: anytype,
            value: anytype,
        ) void {
            _ = value;
            self.action = action;
        }
    };

    var s: Stream(H) = .init(.{ .handler = .{} });

    s.nextSlice("\x1b[2W");
    try testing.expectEqual(Action.Key.tab_clear_current, s.handler.action.?);

    s.nextSlice("\x1b[5W");
    try testing.expectEqual(Action.Key.tab_clear_all, s.handler.action.?);
}

test "stream CSI W tab set" {
    const H = struct {
        action: ?Action.Key = null,

        pub fn vt(
            self: *@This(),
            comptime action: anytype,
            value: anytype,
        ) void {
            _ = value;
            self.action = action;
        }
    };

    var s: Stream(H) = .init(.{ .handler = .{} });

    s.nextSlice("\x1b[W");
    try testing.expectEqual(Action.Key.tab_set, s.handler.action.?);

    s.handler.action = null;
    s.nextSlice("\x1b[0W");
    try testing.expectEqual(Action.Key.tab_set, s.handler.action.?);

    s.handler.action = null;
    s.nextSlice("\x1b[>W");
    try testing.expect(s.handler.action == null);

    s.handler.action = null;
    s.nextSlice("\x1b[99W");
    try testing.expect(s.handler.action == null);
}

test "stream CSI ? W reset tab stops" {
    const H = struct {
        action: ?Action.Key = null,

        pub fn vt(
            self: *@This(),
            comptime action: anytype,
            value: anytype,
        ) void {
            _ = value;
            self.action = action;
        }
    };

    var s: Stream(H) = .init(.{ .handler = .{} });

    s.nextSlice("\x1b[?2W");
    try testing.expect(s.handler.action == null);

    s.nextSlice("\x1b[?5W");
    try testing.expectEqual(Action.Key.tab_reset, s.handler.action.?);

    // Invalid and ignored by the handler
    s.handler.action = null;
    s.nextSlice("\x1b[?1;2;3W");
    try testing.expect(s.handler.action == null);
}

test "stream: SGR with 17+ parameters for underline color" {
    const H = struct {
        attrs: usize = 0,
        last: ?sgr.Attribute = null,

        pub fn vt(
            self: *@This(),
            comptime action: anytype,
            value: anytype,
        ) void {
            switch (action) {
                .set_attributes => {
                    var p = value.parser();
                    while (p.next()) |attr| {
                        self.attrs += 1;
                        self.last = attr;
                    }
                },
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{ .handler = .{} });

    // Kakoune-style SGR with underline color as 17th parameter
    // This tests the fix where param 17 was being dropped
    s.nextSlice("\x1b[4:3;38;2;51;51;51;48;2;170;170;170;58;2;255;97;136;0m");
    try testing.expectEqual(5, s.handler.attrs);
    try testing.expectEqual(sgr.Attribute.unset, s.handler.last.?);
}

test "stream: tab clear with no param clears the current stop" {
    const H = struct {
        action: ?Action.Tag = null,

        pub fn vt(
            self: *@This(),
            comptime action: Action.Tag,
            value: Action.Value(action),
        ) void {
            _ = value;
            switch (action) {
                .tab_clear_current, .tab_clear_all => self.action = action,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{ .handler = .{} });
    s.nextSlice("\x1b[g");
    try testing.expectEqual(@as(?Action.Tag, .tab_clear_current), s.handler.action);

    s.handler.action = null;
    s.nextSlice("\x1b[0g");
    try testing.expectEqual(@as(?Action.Tag, .tab_clear_current), s.handler.action);

    s.handler.action = null;
    s.nextSlice("\x1b[3g");
    try testing.expectEqual(@as(?Action.Tag, .tab_clear_all), s.handler.action);
}

test "stream: tab clear with overflowing param" {
    // Regression test for a fuzz crash: CSI with a parameter value that
    // saturates to 65535 (u16 max) causes @fromBackingInt to panic when
    // converting to TabClear (enum(u8)).
    const H = struct {
        called: bool = false,

        pub fn vt(
            self: *@This(),
            comptime action: Action.Tag,
            value: Action.Value(action),
        ) void {
            _ = value;
            switch (action) {
                .tab_clear_current, .tab_clear_all => self.called = true,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{ .handler = .{} });
    // This is the exact input from the fuzz crash (minus the mode byte):
    // CSI with a huge numeric param that saturates to 65535, followed by 'g'.
    s.nextSlice("\x1b[388888888888888888888888888888888888g\x1b[0m");
}

/// A test handler that accumulates APC bytes regardless of whether they
/// arrive per-byte (apc_put) or in bulk (apc_put_slice).
const ApcTestHandler = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,
    slices: usize = 0,
    puts: usize = 0,
    started: usize = 0,
    ended: usize = 0,

    pub fn vt(
        self: *@This(),
        comptime action: Action.Tag,
        value: Action.Value(action),
    ) void {
        switch (action) {
            .apc_start => self.started += 1,
            .apc_end => self.ended += 1,
            .apc_put => {
                self.buf[self.len] = value;
                self.len += 1;
                self.puts += 1;
            },
            .apc_put_slice => {
                @memcpy(self.buf[self.len..][0..value.bytes.len], value.bytes);
                self.len += value.bytes.len;
                self.slices += 1;
            },
            else => {},
        }
    }
};

test "stream: apc bulk slice" {
    var s: Stream(ApcTestHandler) = .init(.{ .handler = .{} });
    s.nextSlice("\x1b_Gf=24,s=10,v=20;aGVsbG8=\x1b\\");

    try testing.expectEqual(@as(usize, 1), s.handler.started);
    try testing.expectEqual(@as(usize, 1), s.handler.ended);
    try testing.expectEqualStrings(
        "Gf=24,s=10,v=20;aGVsbG8=",
        s.handler.buf[0..s.handler.len],
    );

    // With SIMD enabled the body must arrive as a single slice.
    if (comptime build_options.simd and !debug) {
        try testing.expectEqual(@as(usize, 1), s.handler.slices);
        try testing.expectEqual(@as(usize, 0), s.handler.puts);
    }
}

test "stream: apc bulk slice C1 ST" {
    var s: Stream(ApcTestHandler) = .init(.{ .handler = .{} });
    s.nextSlice("\x1b_Gpayload\x9c");

    try testing.expectEqual(@as(usize, 1), s.handler.started);
    try testing.expectEqual(@as(usize, 1), s.handler.ended);
    try testing.expectEqualStrings(
        "Gpayload",
        s.handler.buf[0..s.handler.len],
    );
}

test "stream: apc bulk slice split across inputs" {
    var s: Stream(ApcTestHandler) = .init(.{ .handler = .{} });
    s.nextSlice("\x1b_Gf=24,s=10");
    s.nextSlice(",v=20;aGVs");
    s.nextSlice("bG8=\x1b\\");

    try testing.expectEqual(@as(usize, 1), s.handler.started);
    try testing.expectEqual(@as(usize, 1), s.handler.ended);
    try testing.expectEqualStrings(
        "Gf=24,s=10,v=20;aGVsbG8=",
        s.handler.buf[0..s.handler.len],
    );
}

test "stream: apc bulk slice keeps C0 bytes as data" {
    var s: Stream(ApcTestHandler) = .init(.{ .handler = .{} });
    // BEL does not terminate an APC string; it is payload data.
    s.nextSlice("\x1b_Gx\x07y\x1b\\");

    try testing.expectEqual(@as(usize, 1), s.handler.ended);
    try testing.expectEqualStrings("Gx\x07y", s.handler.buf[0..s.handler.len]);
}

test "stream: apc aborted by CAN" {
    var s: Stream(ApcTestHandler) = .init(.{ .handler = .{} });
    // CAN (0x18) aborts the APC string via the anywhere => ground
    // transition. Exiting the sos_pm_apc_string state emits apc_end,
    // and the trailing bytes are printed, not treated as APC data.
    s.nextSlice("\x1b_Gabcdefghijklmnopqrstuvwxyz0123456789\x18def");

    try testing.expectEqual(@as(usize, 1), s.handler.started);
    try testing.expectEqual(@as(usize, 1), s.handler.ended);
    try testing.expectEqualStrings(
        "Gabcdefghijklmnopqrstuvwxyz0123456789",
        s.handler.buf[0..s.handler.len],
    );
}

test "stream: apc scalar path matches" {
    var s: Stream(ApcTestHandler) = .init(.{ .handler = .{} });
    for ("\x1b_Gf=24;aGVsbG8=\x1b\\") |c| s.next(c);

    try testing.expectEqual(@as(usize, 1), s.handler.started);
    try testing.expectEqual(@as(usize, 1), s.handler.ended);
    try testing.expectEqualStrings(
        "Gf=24;aGVsbG8=",
        s.handler.buf[0..s.handler.len],
    );
}

test "stream: apc vector boundaries match scalar path" {
    const positions = [_]usize{ 15, 16, 17, 31, 32, 33, 63, 64, 65 };
    const controls = [_]u8{ 0x18, 0x1A, 0x1B, 0x80, 0xFF };

    for (positions) |position| for (controls) |control| {
        var input: [96]u8 = undefined;
        input[0..3].* = "\x1b_G".*;
        @memset(input[3 .. 3 + position], 'a');
        input[3 + position] = control;
        input[4 + position] = '\\';
        const bytes = input[0 .. 5 + position];

        var bulk: Stream(ApcTestHandler) = .init(.{ .handler = .{} });
        bulk.nextSlice(bytes);
        var scalar: Stream(ApcTestHandler) = .init(.{ .handler = .{} });
        for (bytes) |byte| scalar.next(byte);

        try testing.expectEqual(scalar.handler.started, bulk.handler.started);
        try testing.expectEqual(scalar.handler.ended, bulk.handler.ended);
        try testing.expectEqualStrings(
            scalar.handler.buf[0..scalar.handler.len],
            bulk.handler.buf[0..bulk.handler.len],
        );
    };
}

const ContinuationTestHandler = struct {
    committed: usize = 0,
    apc_active: bool = false,
    apc_buf: [256]u8 = undefined,
    apc_len: usize = 0,
    dcs_active: bool = false,

    pub fn deinit(_: *@This()) void {}

    pub fn vt(
        self: *@This(),
        comptime action: Action.Tag,
        value: Action.Value(action),
    ) void {
        switch (action) {
            .apc_start => self.apc_active = true,
            .apc_put => {
                self.apc_buf[self.apc_len] = value;
                self.apc_len += 1;
            },
            .apc_put_slice => {
                @memcpy(
                    self.apc_buf[self.apc_len..][0..value.bytes.len],
                    value.bytes,
                );
                self.apc_len += value.bytes.len;
            },
            .dcs_hook => self.dcs_active = true,
            .dcs_put => {},
            .apc_end => {
                self.apc_active = false;
                self.apc_len = 0;
                self.committed += 1;
            },
            .dcs_unhook => {
                self.dcs_active = false;
                self.committed += 1;
            },
            .print => self.committed += 1,
            .print_slice => self.committed += value.cps.len,
            .print_repeat => self.committed += value,
            else => self.committed += 1,
        }
    }
};

const ContinuationNullHandler = struct {
    pub fn deinit(_: *@This()) void {}

    pub fn vt(
        _: *@This(),
        comptime _: Action.Tag,
        _: anytype,
    ) void {}
};

/// Test helper: the ground-only form of nextSliceUntil, returning the
/// consumed count the way the former nextSliceUntilGround did.
fn untilGround(stream: anytype, input: []const u8) !?usize {
    const stop = stream.nextSliceUntil(input, .initOne(.ground)) orelse return null;
    try testing.expect(stop.reached.eql(.initOne(.ground)));
    try testing.expect(stop.start == null);
    try testing.expect(stop.end == null);
    return stop.consumed;
}

test "stream: nextSliceUntil ground stops at the earliest boundary" {
    const S = Stream(ContinuationTestHandler);
    var stream: S = .init(.{ .handler = .{} });
    defer stream.deinit();

    stream.nextSlice("\x1b[31");
    try testing.expect(!stream.ground());
    stream.handler.committed = 0;

    const input = "mABC\x1b[";
    const consumed = (try untilGround(&stream, input)).?;
    try testing.expectEqual(@as(usize, 1), consumed);
    try testing.expect(stream.ground());
    try testing.expectEqual(@as(usize, 1), stream.handler.committed);

    // The suffix was not inspected by the handler and can be processed after
    // the caller performs work at the boundary.
    stream.nextSlice(input[consumed..]);
    try testing.expect(!stream.ground());
    try testing.expectEqual(Parser.State.csi_entry, stream.parser.state);
    try testing.expectEqual(@as(usize, 4), stream.handler.committed);
}

test "stream: nextSliceUntil ground consumes all input without a boundary" {
    const S = Stream(ContinuationNullHandler);
    var stream: S = .init(.{ .handler = .{} });
    defer stream.deinit();

    try testing.expectEqual(
        @as(?usize, 0),
        try untilGround(&stream, "unprocessed"),
    );
    try testing.expect(stream.ground());

    stream.nextSlice("\x1b[");
    try testing.expectEqual(
        @as(?usize, null),
        try untilGround(&stream, "123"),
    );
    try testing.expect(!stream.ground());

    // A boundary on the final byte is distinguishable from exhausting the
    // input while still pending.
    try testing.expectEqual(
        @as(?usize, 1),
        try untilGround(&stream, "m"),
    );
    try testing.expect(stream.ground());
}

test "stream: nextSliceUntil ground handles UTF-8 boundaries" {
    const S = Stream(ContinuationTestHandler);

    // A completed codepoint is committed synchronously, and the printable
    // suffix remains untouched.
    var valid: S = .init(.{ .handler = .{} });
    defer valid.deinit();
    valid.nextSlice(&.{0xF0});
    const valid_input = [_]u8{ 0x9F, 0x98, 0x84, 'X' };
    try testing.expectEqual(
        @as(?usize, 3),
        try untilGround(&valid, &valid_input),
    );
    try testing.expect(valid.ground());
    try testing.expectEqual(@as(usize, 1), valid.handler.committed);

    // A malformed continuation emits the replacement codepoint and retries
    // the same byte. Ground is observed after that complete byte operation.
    var malformed: S = .init(.{ .handler = .{} });
    defer malformed.deinit();
    malformed.nextSlice(&.{ 0xE0, 0xA0 });
    try testing.expectEqual(
        @as(?usize, 1),
        try untilGround(&malformed, "A!"),
    );
    try testing.expect(malformed.ground());
    try testing.expectEqual(@as(usize, 2), malformed.handler.committed);

    // If the retried byte is ESC, the stream has begun VT state at the end of
    // that byte and must continue to the following ground boundary.
    var retry_escape: S = .init(.{ .handler = .{} });
    defer retry_escape.deinit();
    retry_escape.nextSlice(&.{ 0xE0, 0xA0 });
    try testing.expectEqual(
        @as(?usize, 3),
        try untilGround(&retry_escape, "\x1b[mX"),
    );
    try testing.expect(retry_escape.ground());
}

test "stream: nextSliceUntil ground handles aborts and bulk strings" {
    const S = Stream(ContinuationTestHandler);

    var aborted: S = .init(.{ .handler = .{} });
    defer aborted.deinit();
    aborted.nextSlice("\x1b[123");
    try testing.expectEqual(
        @as(?usize, 1),
        try untilGround(&aborted, &.{ 0x18, 'X' }),
    );
    try testing.expect(aborted.ground());

    var apc: S = .init(.{ .handler = .{} });
    defer apc.deinit();
    apc.nextSlice("\x1b_Gseed");
    var input: [131]u8 = undefined;
    @memset(input[0..128], 'a');
    input[128..130].* = "\x1b\\".*;
    input[130] = 'X';
    try testing.expectEqual(
        @as(?usize, 130),
        try untilGround(&apc, &input),
    );
    try testing.expect(apc.ground());
}

test "stream: nextSliceUntil ground tracks only the consumed prefix" {
    const S = Stream(ContinuationNullHandler);
    var stream: S = .init(.{
        .allocator = testing.allocator,
        .handler = .{},
        .continuation_max_bytes = 64,
    });
    defer stream.deinit();

    stream.nextSlice("\x1b[31");
    try testing.expectEqual(
        @as(?usize, 1),
        try untilGround(&stream, "mX\x1b["),
    );

    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try stream.writeContinuation(&writer);
    try testing.expectEqual(@as(usize, 0), writer.buffered().len);

    stream.nextSlice("\x1b[");
    try testing.expectEqual(
        @as(?usize, null),
        try untilGround(&stream, "123"),
    );
    var pending_writer: std.Io.Writer = .fixed(&buf);
    try stream.writeContinuation(&pending_writer);
    try testing.expectEqualStrings("\x1b[123", pending_writer.buffered());
}

/// A test handler for boundary stops: records APC lifecycle, content,
/// how many codepoints were printed, and the DCS and OSC actions that
/// a string of those kinds produces.
const BoundaryTestHandler = struct {
    started: usize = 0,
    ended: usize = 0,
    last_terminated: ?bool = null,
    buf: [512]u8 = undefined,
    len: usize = 0,
    prints: usize = 0,
    dcs_hooks: usize = 0,
    dcs_unhooks: usize = 0,
    titles: usize = 0,
    clipboards: usize = 0,

    pub fn deinit(_: *@This()) void {}

    pub fn vt(
        self: *@This(),
        comptime action: Action.Tag,
        value: Action.Value(action),
    ) void {
        switch (action) {
            .apc_start => self.started += 1,
            .apc_end => {
                self.ended += 1;
                self.last_terminated = value.terminated;
            },
            .apc_put => {
                self.buf[self.len] = value;
                self.len += 1;
            },
            .apc_put_slice => {
                @memcpy(self.buf[self.len..][0..value.bytes.len], value.bytes);
                self.len += value.bytes.len;
            },
            .print => self.prints += 1,
            .print_slice => self.prints += value.cps.len,
            .dcs_hook => self.dcs_hooks += 1,
            .dcs_unhook => self.dcs_unhooks += 1,
            .window_title => self.titles += 1,
            .clipboard_contents => self.clipboards += 1,
            else => {},
        }
    }
};

/// Same as BoundaryTestHandler but with a vtRaw hook, which disables
/// every bulk fast path so every byte goes through Parser.next.
const BoundaryRawTestHandler = struct {
    inner: BoundaryTestHandler = .{},

    pub fn deinit(_: *@This()) void {}

    pub fn vtRaw(_: *@This(), _: Parser.Action) !bool {
        return false;
    }

    pub fn vt(
        self: *@This(),
        comptime action: Action.Tag,
        value: Action.Value(action),
    ) void {
        self.inner.vt(action, value);
    }
};

fn boundaryHandler(stream: anytype) *BoundaryTestHandler {
    return switch (@TypeOf(stream.handler)) {
        BoundaryTestHandler => &stream.handler,
        BoundaryRawTestHandler => &stream.handler.inner,
        else => unreachable,
    };
}

const apc_end_set: Boundary.Set = .initOne(.apc_end);
const apc_start_set: Boundary.Set = .initOne(.apc_start);
const apc_set: Boundary.Set = .initMany(&.{ .apc_start, .apc_end });
const dcs_end_set: Boundary.Set = .initOne(.dcs_end);
const osc_end_set: Boundary.Set = .initOne(.osc_end);
const dcs_set: Boundary.Set = .initMany(&.{ .dcs_start, .dcs_end });
const osc_set: Boundary.Set = .initMany(&.{ .osc_start, .osc_end });
/// Every string boundary, without ground.
const strings_set: Boundary.Set = apc_set.unionWith(dcs_set).unionWith(osc_set);
/// Every boundary.
const all_set: Boundary.Set = strings_set.unionWith(.initOne(.ground));

/// Expected result of feeding one byte to a stream inside an APC or an
/// OSC: the end reason if the byte ends the string, and the parser state
/// after it.
const StringExit = struct {
    reason: ?Boundary.EndReason,
    state: Parser.State,
};

fn expectedApcExit(c: u8) StringExit {
    return switch (c) {
        0x18, 0x1A => .{ .reason = .cancelled, .state = .ground },
        0x1B => .{ .reason = .st_esc, .state = .escape },
        0x9C => .{ .reason = .st_c1, .state = .ground },
        0x90 => .{ .reason = .aborted, .state = .dcs_entry },
        0x9B => .{ .reason = .aborted, .state = .csi_entry },
        0x9D => .{ .reason = .aborted, .state = .osc_string },
        // A string introducer inside a string is a self-transition
        // in the parser: no exit, no entry, the byte is dropped.
        0x98, 0x9E, 0x9F => .{ .reason = null, .state = .sos_pm_apc_string },
        0x80...0x8F, 0x91...0x97, 0x99, 0x9A => .{ .reason = .aborted, .state = .ground },
        // Ignored by the table: not data, not an exit.
        0xA0...0xFF => .{ .reason = null, .state = .sos_pm_apc_string },
        // Everything else is data.
        else => .{ .reason = null, .state = .sos_pm_apc_string },
    };
}

fn testApcExits(comptime H: type) !void {
    const S = Stream(H);
    var c: u8 = 0;
    while (true) : (c += 1) {
        const expected = expectedApcExit(c);
        var s: S = .init(.{ .handler = .{} });
        defer s.deinit();
        s.nextSlice("\x1b_Gab");
        try testing.expectEqual(Parser.State.sos_pm_apc_string, s.parser.state);
        const h = boundaryHandler(&s);
        try testing.expectEqual(@as(usize, 1), h.started);
        try testing.expectEqualStrings("Gab", h.buf[0..h.len]);

        const input = [_]u8{c};
        const stop_ = s.nextSliceUntil(&input, apc_end_set);
        try testing.expectEqual(expected.state, s.parser.state);

        if (expected.reason) |reason| {
            const stop = stop_ orelse return error.ExpectedStop;
            try testing.expectEqual(@as(usize, 1), stop.consumed);
            try testing.expect(stop.reached.eql(apc_end_set));
            try testing.expect(stop.start == null);
            const end = stop.end orelse return error.ExpectedEnd;
            try testing.expectEqual(Boundary.StringKind.apc, end.kind);
            try testing.expectEqual(reason, end.reason);
            try testing.expectEqual(c, end.byte);
            try testing.expectEqual(@as(usize, 1), h.ended);
            const terminated = switch (reason) {
                .st_esc, .st_c1, .bel => true,
                .cancelled, .aborted => false,
            };
            try testing.expectEqual(terminated, h.last_terminated.?);
        } else {
            try testing.expectEqual(@as(?Boundary.Stop, null), stop_);
            try testing.expectEqual(@as(usize, 0), h.ended);
            // 0x7F and C0 bytes are data; the rest are dropped.
            const data = switch (c) {
                0x00...0x17, 0x19, 0x1C...0x7F => true,
                else => false,
            };
            try testing.expectEqualStrings(
                if (data) "Gab" ++ [_]u8{c} else "Gab",
                h.buf[0..h.len],
            );
        }

        if (c == 0xFF) break;
    }
}

test "stream: nextSliceUntil every apc exit" {
    try testApcExits(BoundaryTestHandler);
}

test "stream: nextSliceUntil every apc exit through the scalar path" {
    try testApcExits(BoundaryRawTestHandler);
}

test "stream: nextSliceUntil apc st_esc leaves the next byte for the next call" {
    const S = Stream(BoundaryTestHandler);

    // A full ST: the backslash is an ordinary escape on the next call.
    {
        var s: S = .init(.{ .handler = .{} });
        defer s.deinit();
        s.nextSlice("\x1b_Gab");
        const stop = s.nextSliceUntil("\x1b\\x", apc_end_set).?;
        try testing.expectEqual(@as(usize, 1), stop.consumed);
        try testing.expectEqual(Boundary.EndReason.st_esc, stop.end.?.reason);
        try testing.expectEqual(Parser.State.escape, s.parser.state);
        try testing.expectEqual(@as(?Boundary.Stop, null), s.nextSliceUntil("\\x", apc_end_set));
        try testing.expect(s.ground());
        try testing.expectEqual(@as(usize, 1), s.handler.prints);
        try testing.expectEqualStrings("Gab", s.handler.buf[0..s.handler.len]);
    }

    // ESC then another byte: the string still ended at the ESC and the
    // byte after it is dispatched as that escape sequence.
    {
        var s: S = .init(.{ .handler = .{} });
        defer s.deinit();
        s.nextSlice("\x1b_Gab");
        const stop = s.nextSliceUntil("\x1b[1mx", apc_end_set).?;
        try testing.expectEqual(@as(usize, 1), stop.consumed);
        try testing.expectEqual(Boundary.EndReason.st_esc, stop.end.?.reason);
        try testing.expectEqual(@as(usize, 1), s.handler.ended);
        try testing.expect(s.handler.last_terminated.?);
        try testing.expectEqual(@as(?Boundary.Stop, null), s.nextSliceUntil("[1mx", apc_end_set));
        try testing.expect(s.ground());
        try testing.expectEqual(@as(usize, 1), s.handler.prints);
    }
}

test "stream: nextSliceUntil apc introducers" {
    const S = Stream(BoundaryTestHandler);

    // ESC introducers from ground, ESC and final in one call.
    for ([_]u8{ '_', 'X', '^' }) |final| {
        var s: S = .init(.{ .handler = .{} });
        defer s.deinit();
        const input = [_]u8{ 0x1B, final, 'G' };
        const stop = s.nextSliceUntil(&input, apc_start_set).?;
        try testing.expectEqual(@as(usize, 2), stop.consumed);
        try testing.expect(stop.reached.eql(apc_start_set));
        try testing.expect(stop.end == null);
        const start = stop.start.?;
        try testing.expectEqual(Boundary.StringKind.apc, start.kind);
        try testing.expectEqual(Boundary.Introducer.esc, start.introducer);
        try testing.expectEqual(final, start.byte);
        try testing.expectEqual(Parser.State.sos_pm_apc_string, s.parser.state);
        try testing.expectEqual(@as(usize, 1), s.handler.started);
        // The first byte after the introducer is the first byte of
        // content and has not been consumed.
        try testing.expectEqual(@as(usize, 0), s.handler.len);
    }

    // ESC consumed by an earlier call: consumed covers only the final.
    {
        var s: S = .init(.{ .handler = .{} });
        defer s.deinit();
        try testing.expectEqual(@as(?Boundary.Stop, null), s.nextSliceUntil("\x1b", apc_start_set));
        const stop = s.nextSliceUntil("_G", apc_start_set).?;
        try testing.expectEqual(@as(usize, 1), stop.consumed);
        try testing.expectEqual(Boundary.Introducer.esc, stop.start.?.introducer);
        try testing.expectEqual(@as(u8, '_'), stop.start.?.byte);
    }

    // C1 introducers from non-ground states. At ground a raw C1 byte
    // goes through the UTF-8 decoder instead, so prime with a CSI
    // (the csi_param fast path) and with a bare ESC (Parser.next).
    for ([_]u8{ 0x98, 0x9E, 0x9F }) |c1| {
        for ([_][]const u8{ "\x1b[1", "\x1b" }) |prime| {
            var s: S = .init(.{ .handler = .{} });
            defer s.deinit();
            s.nextSlice(prime);
            try testing.expect(!s.ground());
            const input = [_]u8{ c1, 'G' };
            const stop = s.nextSliceUntil(&input, apc_start_set).?;
            try testing.expectEqual(@as(usize, 1), stop.consumed);
            try testing.expect(stop.reached.eql(apc_start_set));
            const start = stop.start.?;
            try testing.expectEqual(Boundary.StringKind.apc, start.kind);
            try testing.expectEqual(Boundary.Introducer.c1, start.introducer);
            try testing.expectEqual(c1, start.byte);
            try testing.expectEqual(Parser.State.sos_pm_apc_string, s.parser.state);
            try testing.expectEqual(@as(usize, 1), s.handler.started);
        }
    }
}

/// One stop as seen by a caller looping over nextSliceUntil, with
/// consumed made absolute within the whole input.
const AbsoluteStop = struct {
    end: usize,
    reached: Boundary.Set,
    start: ?Boundary.Stop.Start,
    end_info: ?Boundary.Stop.End,
};

/// Feed input through nextSliceUntil in a loop, recording every stop
/// at its absolute offset. When ground is in the set and the stream is
/// at ground, it is dropped for that call so the loop makes progress.
fn collectStops(
    stream: anytype,
    input: []const u8,
    base: usize,
    set: Boundary.Set,
    out: *std.ArrayList(AbsoluteStop),
) !void {
    var rem = input;
    while (rem.len > 0) {
        var call_set = set;
        if (stream.ground()) call_set.remove(.ground);
        const stop = stream.nextSliceUntil(rem, call_set) orelse break;
        try testing.expect(stop.consumed > 0);
        try testing.expect(stop.consumed <= rem.len);
        try out.append(testing.allocator, .{
            .end = base + (input.len - rem.len) + stop.consumed,
            .reached = stop.reached,
            .start = stop.start,
            .end_info = stop.end,
        });
        rem = rem[stop.consumed..];
    }
}

test "stream: nextSliceUntil stops do not depend on the split" {
    const S = Stream(BoundaryTestHandler);
    const input = "\x1b_Gf=100\x1b\\";

    // Reference: one call.
    var reference: std.ArrayList(AbsoluteStop) = .empty;
    defer reference.deinit(testing.allocator);
    {
        var s: S = .init(.{ .handler = .{} });
        defer s.deinit();
        try collectStops(&s, input, 0, apc_set, &reference);
        try testing.expect(s.ground());
    }
    try testing.expectEqual(@as(usize, 2), reference.items.len);
    try testing.expectEqual(@as(usize, 2), reference.items[0].end);
    try testing.expect(reference.items[0].reached.eql(apc_start_set));
    try testing.expectEqual(@as(u8, '_'), reference.items[0].start.?.byte);
    try testing.expectEqual(@as(usize, 9), reference.items[1].end);
    try testing.expect(reference.items[1].reached.eql(apc_end_set));
    try testing.expectEqual(Boundary.EndReason.st_esc, reference.items[1].end_info.?.reason);

    // Every split point, including between ESC and '_' (0..1) and
    // between the terminating ESC and the backslash (0..9).
    for (0..input.len + 1) |split| {
        var stops: std.ArrayList(AbsoluteStop) = .empty;
        defer stops.deinit(testing.allocator);
        var s: S = .init(.{ .handler = .{} });
        defer s.deinit();
        try collectStops(&s, input[0..split], 0, apc_set, &stops);
        try collectStops(&s, input[split..], split, apc_set, &stops);
        try testing.expect(s.ground());
        try testing.expectEqualDeep(reference.items, stops.items);
        try testing.expectEqual(@as(usize, 1), s.handler.started);
        try testing.expectEqual(@as(usize, 1), s.handler.ended);
        try testing.expectEqualStrings("Gf=100", s.handler.buf[0..s.handler.len]);
    }
}

test "stream: nextSliceUntil C1 introducer inside an apc is dropped" {
    // The parser treats 0x98, 0x9E, 0x9F inside a string as a
    // self-transition: no apc_end, no apc_start, and the byte is not
    // data. So this does not restart the string and reports nothing.
    const S = Stream(BoundaryTestHandler);
    var s: S = .init(.{ .handler = .{} });
    defer s.deinit();
    const input = "\x1b_a\x9fb\x1b\\";
    var stops: std.ArrayList(AbsoluteStop) = .empty;
    defer stops.deinit(testing.allocator);
    try collectStops(&s, input, 0, apc_set, &stops);
    try testing.expectEqual(@as(usize, 2), stops.items.len);
    try testing.expectEqual(@as(usize, 2), stops.items[0].end);
    try testing.expect(stops.items[0].reached.eql(apc_start_set));
    try testing.expectEqual(@as(usize, 6), stops.items[1].end);
    try testing.expect(stops.items[1].reached.eql(apc_end_set));
    try testing.expectEqual(@as(usize, 1), s.handler.started);
    try testing.expectEqual(@as(usize, 1), s.handler.ended);
    try testing.expectEqualStrings("ab", s.handler.buf[0..s.handler.len]);
}

test "stream: nextSliceUntil combined ground and apc end" {
    const S = Stream(BoundaryTestHandler);
    const set: Boundary.Set = .initMany(&.{ .ground, .apc_end });

    // CAN ends the string and reaches ground on the same byte.
    {
        var s: S = .init(.{ .handler = .{} });
        defer s.deinit();
        s.nextSlice("\x1b_Gab");
        const stop = s.nextSliceUntil("\x18x", set).?;
        try testing.expectEqual(@as(usize, 1), stop.consumed);
        try testing.expect(stop.reached.eql(set));
        try testing.expectEqual(Boundary.EndReason.cancelled, stop.end.?.reason);
        try testing.expect(s.ground());
    }

    // 0x9C too.
    {
        var s: S = .init(.{ .handler = .{} });
        defer s.deinit();
        s.nextSlice("\x1b_Gab");
        const stop = s.nextSliceUntil("\x9cx", set).?;
        try testing.expectEqual(@as(usize, 1), stop.consumed);
        try testing.expect(stop.reached.eql(set));
        try testing.expectEqual(Boundary.EndReason.st_c1, stop.end.?.reason);
        try testing.expect(s.ground());
    }

    // ESC ends the string but ground is only reached on the backslash.
    {
        var s: S = .init(.{ .handler = .{} });
        defer s.deinit();
        s.nextSlice("\x1b_Gab");
        const stop = s.nextSliceUntil("\x1b\\x", set).?;
        try testing.expectEqual(@as(usize, 1), stop.consumed);
        try testing.expect(stop.reached.eql(apc_end_set));
        try testing.expectEqual(Boundary.EndReason.st_esc, stop.end.?.reason);
        try testing.expect(!s.ground());

        const ground_stop = s.nextSliceUntil("\\x", set).?;
        try testing.expectEqual(@as(usize, 1), ground_stop.consumed);
        try testing.expect(ground_stop.reached.eql(.initOne(.ground)));
        try testing.expect(ground_stop.end == null);
        try testing.expect(s.ground());

        // Already at ground: a stop with nothing consumed.
        const idle = s.nextSliceUntil("x", set).?;
        try testing.expectEqual(@as(usize, 0), idle.consumed);
        try testing.expect(idle.reached.eql(.initOne(.ground)));
        try testing.expectEqual(@as(usize, 0), s.handler.prints);
    }
}

test "stream: nextSliceUntil apc start with ground requested" {
    // From ground, the start of an APC is the first boundary reached:
    // ESC leaves ground, '_' enters the string.
    const S = Stream(BoundaryTestHandler);
    var s: S = .init(.{ .handler = .{} });
    defer s.deinit();
    const stop = s.nextSliceUntil("\x1b_Gab\x1b\\", apc_set).?;
    try testing.expectEqual(@as(usize, 2), stop.consumed);
    try testing.expect(stop.reached.eql(apc_start_set));

    // Ground is reached before the next APC, so with ground requested
    // the stop lands on the backslash of the ST.
    const end = s.nextSliceUntil("Gab\x1b\\\x1b_x", all_set).?;
    try testing.expectEqual(@as(usize, 4), end.consumed);
    try testing.expect(end.reached.eql(apc_end_set));
    const ground = s.nextSliceUntil("\\\x1b_x", all_set).?;
    try testing.expectEqual(@as(usize, 1), ground.consumed);
    try testing.expect(ground.reached.eql(.initOne(.ground)));
}

/// Expected result of feeding one byte to a stream inside an OSC.
fn expectedOscExit(c: u8) StringExit {
    return switch (c) {
        0x07 => .{ .reason = .bel, .state = .ground },
        0x18, 0x1A => .{ .reason = .cancelled, .state = .ground },
        0x1B => .{ .reason = .st_esc, .state = .escape },
        // Every byte from 0x20 up is data, including 0x9C, 0x9D, 0x9F
        // and 0xA0 to 0xFF. The remaining C0 bytes are ignored.
        else => .{ .reason = null, .state = .osc_string },
    };
}

fn testOscExits(comptime H: type) !void {
    const S = Stream(H);
    var c: u8 = 0;
    while (true) : (c += 1) {
        const expected = expectedOscExit(c);
        var s: S = .init(.{ .handler = .{} });
        defer s.deinit();
        s.nextSlice("\x1b]2;ab");
        try testing.expectEqual(Parser.State.osc_string, s.parser.state);
        const h = boundaryHandler(&s);

        const input = [_]u8{c};
        const stop_ = s.nextSliceUntil(&input, osc_end_set);
        try testing.expectEqual(expected.state, s.parser.state);

        if (expected.reason) |reason| {
            const stop = stop_ orelse return error.ExpectedStop;
            try testing.expectEqual(@as(usize, 1), stop.consumed);
            try testing.expect(stop.reached.eql(osc_end_set));
            try testing.expect(stop.start == null);
            const end = stop.end orelse return error.ExpectedEnd;
            try testing.expectEqual(Boundary.StringKind.osc, end.kind);
            try testing.expectEqual(reason, end.reason);
            try testing.expectEqual(c, end.byte);
            // A proper terminator dispatches the title.
            if (reason == .bel or reason == .st_esc) {
                try testing.expectEqual(@as(usize, 1), h.titles);
            }
        } else {
            try testing.expectEqual(@as(?Boundary.Stop, null), stop_);
            try testing.expectEqual(@as(usize, 0), h.titles);
        }

        if (c == 0xFF) break;
    }
}

test "stream: nextSliceUntil every osc exit" {
    try testOscExits(BoundaryTestHandler);
}

test "stream: nextSliceUntil every osc exit through the scalar path" {
    try testOscExits(BoundaryRawTestHandler);
}

test "stream: nextSliceUntil osc end without a dispatch" {
    // An OSC with a number the terminal doesn't know never reaches
    // the handler, but it still ends.
    inline for (.{ BoundaryTestHandler, BoundaryRawTestHandler }) |H| {
        var s: Stream(H) = .init(.{ .handler = .{} });
        defer s.deinit();
        const stop = s.nextSliceUntil("\x1b]9999;ab\x07x", osc_end_set).?;
        try testing.expectEqual(@as(usize, 10), stop.consumed);
        try testing.expect(stop.reached.eql(osc_end_set));
        try testing.expectEqual(Boundary.StringKind.osc, stop.end.?.kind);
        try testing.expectEqual(Boundary.EndReason.bel, stop.end.?.reason);
        try testing.expect(s.ground());
        try testing.expectEqual(@as(usize, 0), boundaryHandler(&s).titles);
        try testing.expectEqual(@as(usize, 0), boundaryHandler(&s).prints);
    }
}

test "stream: nextSliceUntil osc st_esc leaves the next byte for the next call" {
    inline for (.{ BoundaryTestHandler, BoundaryRawTestHandler }) |H| {
        // ESC then backslash: the proper terminator.
        {
            var s: Stream(H) = .init(.{ .handler = .{} });
            defer s.deinit();
            s.nextSlice("\x1b]2;ab");
            const stop = s.nextSliceUntil("\x1b\\x", osc_end_set).?;
            try testing.expectEqual(@as(usize, 1), stop.consumed);
            try testing.expectEqual(Boundary.EndReason.st_esc, stop.end.?.reason);
            try testing.expectEqual(Parser.State.escape, s.parser.state);
            try testing.expectEqual(@as(?Boundary.Stop, null), s.nextSliceUntil("\\x", osc_end_set));
            try testing.expect(s.ground());
            try testing.expectEqual(@as(usize, 1), boundaryHandler(&s).titles);
            try testing.expectEqual(@as(usize, 1), boundaryHandler(&s).prints);
        }

        // ESC then another byte: the string still ended at the ESC and
        // the next byte starts its own sequence.
        {
            var s: Stream(H) = .init(.{ .handler = .{} });
            defer s.deinit();
            s.nextSlice("\x1b]2;ab");
            const stop = s.nextSliceUntil("\x1b[1mx", osc_end_set).?;
            try testing.expectEqual(@as(usize, 1), stop.consumed);
            try testing.expectEqual(Boundary.EndReason.st_esc, stop.end.?.reason);
            try testing.expectEqual(@as(?Boundary.Stop, null), s.nextSliceUntil("[1mx", osc_end_set));
            try testing.expect(s.ground());
            try testing.expectEqual(@as(usize, 1), boundaryHandler(&s).titles);
            try testing.expectEqual(@as(usize, 1), boundaryHandler(&s).prints);
        }
    }
}

/// Expected result of feeding one byte to a stream inside a DCS. A null
/// state means the byte stays inside the DCS family; which state it
/// lands in is the parse table's business.
const DcsExit = struct {
    reason: ?Boundary.EndReason,
    state: ?Parser.State,
};

/// The inputs that put the parser in each DCS state.
const dcs_entries = [_]struct { input: []const u8, state: Parser.State }{
    .{ .input = "\x1bP", .state = .dcs_entry },
    .{ .input = "\x1bP1", .state = .dcs_param },
    .{ .input = "\x1bP ", .state = .dcs_intermediate },
    .{ .input = "\x1bP1q", .state = .dcs_passthrough },
    .{ .input = "\x1bP:", .state = .dcs_ignore },
};

fn expectedDcsExit(state: Parser.State, c: u8) DcsExit {
    // In the header the 8-bit controls take their usual transitions.
    // In the payload (passthrough and ignore) they are data.
    const header = switch (state) {
        .dcs_entry, .dcs_param, .dcs_intermediate => true,
        else => false,
    };
    const data: DcsExit = .{ .reason = null, .state = state };
    return switch (c) {
        0x18, 0x1A => .{ .reason = .cancelled, .state = .ground },
        0x1B => .{ .reason = .st_esc, .state = .escape },
        0x9C => if (header) .{ .reason = .st_c1, .state = .ground } else data,
        0x9B => if (header) .{ .reason = .aborted, .state = .csi_entry } else data,
        0x9D => if (header) .{ .reason = .aborted, .state = .osc_string } else data,
        0x98, 0x9E, 0x9F => if (header) .{ .reason = .aborted, .state = .sos_pm_apc_string } else data,
        // 0x90 restarts the header without leaving the string.
        0x90 => if (header) .{ .reason = null, .state = .dcs_entry } else data,
        0x80...0x8F, 0x91...0x97, 0x99, 0x9A => if (header) .{ .reason = .aborted, .state = .ground } else data,
        // 0x00 to 0x7F move within the family or stay put; 0xA0 to
        // 0xFF are ignored in the header and data in the payload.
        else => .{ .reason = null, .state = null },
    };
}

fn testDcsExits(comptime H: type) !void {
    const S = Stream(H);
    for (dcs_entries) |entry| {
        var c: u8 = 0;
        while (true) : (c += 1) {
            const expected = expectedDcsExit(entry.state, c);
            var s: S = .init(.{ .handler = .{} });
            defer s.deinit();
            s.nextSlice(entry.input);
            try testing.expectEqual(entry.state, s.parser.state);
            const h = boundaryHandler(&s);

            const input = [_]u8{c};
            const stop_ = s.nextSliceUntil(&input, dcs_end_set);
            if (expected.state) |state| {
                try testing.expectEqual(state, s.parser.state);
            } else {
                try testing.expectEqual(
                    @as(?Boundary.StringKind, .dcs),
                    Until.family(s.parser.state),
                );
            }

            if (expected.reason) |reason| {
                const stop = stop_ orelse return error.ExpectedStop;
                try testing.expectEqual(@as(usize, 1), stop.consumed);
                try testing.expect(stop.reached.eql(dcs_end_set));
                try testing.expect(stop.start == null);
                const end = stop.end orelse return error.ExpectedEnd;
                try testing.expectEqual(Boundary.StringKind.dcs, end.kind);
                try testing.expectEqual(reason, end.reason);
                try testing.expectEqual(c, end.byte);
                // Leaving the payload unhooks. Leaving the header never
                // hooked, so there is nothing to unhook.
                const hooked: usize = if (entry.state == .dcs_passthrough) 1 else 0;
                try testing.expectEqual(hooked, h.dcs_hooks);
                try testing.expectEqual(hooked, h.dcs_unhooks);
            } else {
                try testing.expectEqual(@as(?Boundary.Stop, null), stop_);
                try testing.expectEqual(@as(usize, 0), h.dcs_unhooks);
            }

            if (c == 0xFF) break;
        }
    }
}

test "stream: nextSliceUntil every dcs exit" {
    try testDcsExits(BoundaryTestHandler);
}

test "stream: nextSliceUntil every dcs exit through the scalar path" {
    try testDcsExits(BoundaryRawTestHandler);
}

test "stream: nextSliceUntil dcs header restart is not a boundary" {
    inline for (.{ BoundaryTestHandler, BoundaryRawTestHandler }) |H| {
        var s: Stream(H) = .init(.{ .handler = .{} });
        defer s.deinit();
        const input = "\x1bP1\x902qx\x1b\\";
        var stops: std.ArrayList(AbsoluteStop) = .empty;
        defer stops.deinit(testing.allocator);
        try collectStops(&s, input, 0, dcs_set, &stops);
        try testing.expectEqual(@as(usize, 2), stops.items.len);
        try testing.expectEqual(@as(usize, 2), stops.items[0].end);
        try testing.expect(stops.items[0].reached.eql(.initOne(.dcs_start)));
        try testing.expectEqual(@as(u8, 'P'), stops.items[0].start.?.byte);
        try testing.expectEqual(@as(usize, input.len - 1), stops.items[1].end);
        try testing.expect(stops.items[1].reached.eql(dcs_end_set));
        try testing.expectEqual(Boundary.EndReason.st_esc, stops.items[1].end_info.?.reason);
        try testing.expect(s.ground());
        try testing.expectEqual(@as(usize, 1), boundaryHandler(&s).dcs_hooks);
        try testing.expectEqual(@as(usize, 1), boundaryHandler(&s).dcs_unhooks);
    }
}

test "stream: nextSliceUntil dcs and osc introducers" {
    const Case = struct {
        input: []const u8,
        kind: Boundary.StringKind,
        introducer: Boundary.Introducer,
        byte: u8,
        consumed: usize,
        state: Parser.State,
    };
    const cases = [_]Case{
        // From ground.
        .{ .input = "\x1bP1q", .kind = .dcs, .introducer = .esc, .byte = 'P', .consumed = 2, .state = .dcs_entry },
        .{ .input = "\x1b]2;ab", .kind = .osc, .introducer = .esc, .byte = ']', .consumed = 2, .state = .osc_string },
        // From inside a CSI, where ESC restarts.
        .{ .input = "\x1b[1\x1bP1q", .kind = .dcs, .introducer = .esc, .byte = 'P', .consumed = 5, .state = .dcs_entry },
        .{ .input = "\x1b[1\x1b]2;ab", .kind = .osc, .introducer = .esc, .byte = ']', .consumed = 5, .state = .osc_string },
        // C1 introducers from inside a CSI. At ground they would be
        // decoded as UTF-8 and never start a string.
        .{ .input = "\x1b[1\x901q", .kind = .dcs, .introducer = .c1, .byte = 0x90, .consumed = 4, .state = .dcs_entry },
        .{ .input = "\x1b[1\x9d2;ab", .kind = .osc, .introducer = .c1, .byte = 0x9D, .consumed = 4, .state = .osc_string },
    };

    inline for (.{ BoundaryTestHandler, BoundaryRawTestHandler }) |H| {
        for (cases) |case| {
            var s: Stream(H) = .init(.{ .handler = .{} });
            defer s.deinit();
            const stop = s.nextSliceUntil(case.input, strings_set).?;
            try testing.expectEqual(case.consumed, stop.consumed);
            const start_boundary: Boundary = switch (case.kind) {
                .apc => .apc_start,
                .dcs => .dcs_start,
                .osc => .osc_start,
            };
            try testing.expect(stop.reached.eql(.initOne(start_boundary)));
            try testing.expect(stop.end == null);
            const start = stop.start orelse return error.ExpectedStart;
            try testing.expectEqual(case.kind, start.kind);
            try testing.expectEqual(case.introducer, start.introducer);
            try testing.expectEqual(case.byte, start.byte);
            try testing.expectEqual(case.state, s.parser.state);
        }
    }
}

/// Handler counts expected after a complete input.
const ExpectedCounts = struct {
    started: usize = 0,
    ended: usize = 0,
    dcs_hooks: usize = 0,
    dcs_unhooks: usize = 0,
    titles: usize = 0,
    clipboards: usize = 0,

    fn check(self: ExpectedCounts, h: *BoundaryTestHandler) !void {
        try testing.expectEqual(self.started, h.started);
        try testing.expectEqual(self.ended, h.ended);
        try testing.expectEqual(self.dcs_hooks, h.dcs_hooks);
        try testing.expectEqual(self.dcs_unhooks, h.dcs_unhooks);
        try testing.expectEqual(self.titles, h.titles);
        try testing.expectEqual(self.clipboards, h.clipboards);
    }
};

/// Feed `input` in one call, collecting the reference stops into
/// `reference`, then at every split point, and require the same stops
/// and the same handler counts every time.
fn testSplits(
    comptime H: type,
    input: []const u8,
    reference: *std.ArrayList(AbsoluteStop),
    counts: ExpectedCounts,
) !void {
    const S = Stream(H);
    {
        var s: S = .init(.{ .handler = .{} });
        defer s.deinit();
        try collectStops(&s, input, 0, strings_set, reference);
        try testing.expect(s.ground());
        try counts.check(boundaryHandler(&s));
    }

    for (0..input.len + 1) |split| {
        var stops: std.ArrayList(AbsoluteStop) = .empty;
        defer stops.deinit(testing.allocator);
        var s: S = .init(.{ .handler = .{} });
        defer s.deinit();
        try collectStops(&s, input[0..split], 0, strings_set, &stops);
        try collectStops(&s, input[split..], split, strings_set, &stops);
        try testing.expect(s.ground());
        try testing.expectEqualDeep(reference.items, stops.items);
        try counts.check(boundaryHandler(&s));
    }
}

test "stream: nextSliceUntil osc stops do not depend on the split" {
    inline for (.{ BoundaryTestHandler, BoundaryRawTestHandler }) |H| {
        const input = "\x1b]52;c;QUJD\x07";
        var reference: std.ArrayList(AbsoluteStop) = .empty;
        defer reference.deinit(testing.allocator);
        try testSplits(H, input, &reference, .{ .clipboards = 1 });
        try testing.expectEqual(@as(usize, 2), reference.items.len);
        try testing.expectEqual(@as(usize, 2), reference.items[0].end);
        try testing.expect(reference.items[0].reached.eql(.initOne(.osc_start)));
        try testing.expectEqual(@as(u8, ']'), reference.items[0].start.?.byte);
        try testing.expectEqual(@as(usize, input.len), reference.items[1].end);
        try testing.expect(reference.items[1].reached.eql(osc_end_set));
        try testing.expectEqual(Boundary.EndReason.bel, reference.items[1].end_info.?.reason);
    }
}

test "stream: nextSliceUntil dcs stops do not depend on the split" {
    inline for (.{ BoundaryTestHandler, BoundaryRawTestHandler }) |H| {
        // A DCS with an intermediate (DECRQSS) and one with parameters.
        for ([_][]const u8{ "\x1bP$qm\x1b\\", "\x1bP1;2|data\x1b\\" }) |input| {
            var reference: std.ArrayList(AbsoluteStop) = .empty;
            defer reference.deinit(testing.allocator);
            try testSplits(H, input, &reference, .{ .dcs_hooks = 1, .dcs_unhooks = 1 });
            try testing.expectEqual(@as(usize, 2), reference.items.len);
            try testing.expectEqual(@as(usize, 2), reference.items[0].end);
            try testing.expect(reference.items[0].reached.eql(.initOne(.dcs_start)));
            try testing.expectEqual(@as(u8, 'P'), reference.items[0].start.?.byte);
            try testing.expectEqual(@as(usize, input.len - 1), reference.items[1].end);
            try testing.expect(reference.items[1].reached.eql(dcs_end_set));
            try testing.expectEqual(Boundary.EndReason.st_esc, reference.items[1].end_info.?.reason);
        }
    }
}

test "stream: nextSliceUntil string end that is also a string start" {
    inline for (.{ BoundaryTestHandler, BoundaryRawTestHandler }) |H| {
        // 0x9D inside an APC ends it and starts an OSC on the same byte.
        {
            var s: Stream(H) = .init(.{ .handler = .{} });
            defer s.deinit();
            const input = "\x1b_a\x9d0;x\x07";
            var stops: std.ArrayList(AbsoluteStop) = .empty;
            defer stops.deinit(testing.allocator);
            try collectStops(&s, input, 0, strings_set, &stops);
            try testing.expectEqual(@as(usize, 3), stops.items.len);
            try testing.expect(stops.items[0].reached.eql(apc_start_set));

            const both = stops.items[1];
            try testing.expectEqual(@as(usize, 4), both.end);
            try testing.expect(both.reached.eql(.initMany(&.{ .apc_end, .osc_start })));
            try testing.expectEqual(Boundary.StringKind.apc, both.end_info.?.kind);
            try testing.expectEqual(Boundary.EndReason.aborted, both.end_info.?.reason);
            try testing.expectEqual(@as(u8, 0x9D), both.end_info.?.byte);
            try testing.expectEqual(Boundary.StringKind.osc, both.start.?.kind);
            try testing.expectEqual(Boundary.Introducer.c1, both.start.?.introducer);
            try testing.expectEqual(@as(u8, 0x9D), both.start.?.byte);

            try testing.expectEqual(@as(usize, input.len), stops.items[2].end);
            try testing.expect(stops.items[2].reached.eql(osc_end_set));
            try testing.expectEqual(Boundary.EndReason.bel, stops.items[2].end_info.?.reason);
            try testing.expect(s.ground());
            try testing.expectEqual(@as(usize, 1), boundaryHandler(&s).ended);
            try testing.expectEqual(false, boundaryHandler(&s).last_terminated.?);
        }

        // 0x9F inside a DCS header ends it and starts an APC. The DCS
        // never hooked.
        {
            var s: Stream(H) = .init(.{ .handler = .{} });
            defer s.deinit();
            const input = "\x1bP1\x9fb\x1b\\";
            var stops: std.ArrayList(AbsoluteStop) = .empty;
            defer stops.deinit(testing.allocator);
            try collectStops(&s, input, 0, strings_set, &stops);
            try testing.expectEqual(@as(usize, 3), stops.items.len);
            try testing.expect(stops.items[0].reached.eql(.initOne(.dcs_start)));

            const both = stops.items[1];
            try testing.expectEqual(@as(usize, 4), both.end);
            try testing.expect(both.reached.eql(.initMany(&.{ .dcs_end, .apc_start })));
            try testing.expectEqual(Boundary.StringKind.dcs, both.end_info.?.kind);
            try testing.expectEqual(Boundary.EndReason.aborted, both.end_info.?.reason);
            try testing.expectEqual(Boundary.StringKind.apc, both.start.?.kind);
            try testing.expectEqual(Boundary.Introducer.c1, both.start.?.introducer);
            try testing.expectEqual(@as(u8, 0x9F), both.start.?.byte);

            try testing.expectEqual(@as(usize, input.len - 1), stops.items[2].end);
            try testing.expect(stops.items[2].reached.eql(apc_end_set));
            try testing.expectEqual(Boundary.EndReason.st_esc, stops.items[2].end_info.?.reason);
            try testing.expect(s.ground());
            try testing.expectEqual(@as(usize, 0), boundaryHandler(&s).dcs_hooks);
            try testing.expectEqual(@as(usize, 0), boundaryHandler(&s).dcs_unhooks);
            try testing.expectEqual(@as(usize, 1), boundaryHandler(&s).started);
            try testing.expectEqualStrings("b", boundaryHandler(&s).buf[0..boundaryHandler(&s).len]);
        }

        // 0x90 inside an APC ends it and starts a DCS.
        {
            var s: Stream(H) = .init(.{ .handler = .{} });
            defer s.deinit();
            const input = "\x1b_a\x90q\x1b\\";
            var stops: std.ArrayList(AbsoluteStop) = .empty;
            defer stops.deinit(testing.allocator);
            try collectStops(&s, input, 0, strings_set, &stops);
            try testing.expectEqual(@as(usize, 3), stops.items.len);
            try testing.expect(stops.items[0].reached.eql(apc_start_set));

            const both = stops.items[1];
            try testing.expectEqual(@as(usize, 4), both.end);
            try testing.expect(both.reached.eql(.initMany(&.{ .apc_end, .dcs_start })));
            try testing.expectEqual(Boundary.StringKind.apc, both.end_info.?.kind);
            try testing.expectEqual(Boundary.EndReason.aborted, both.end_info.?.reason);
            try testing.expectEqual(Boundary.StringKind.dcs, both.start.?.kind);
            try testing.expectEqual(Boundary.Introducer.c1, both.start.?.introducer);
            try testing.expectEqual(@as(u8, 0x90), both.start.?.byte);

            try testing.expectEqual(@as(usize, input.len - 1), stops.items[2].end);
            try testing.expect(stops.items[2].reached.eql(dcs_end_set));
            try testing.expectEqual(Boundary.EndReason.st_esc, stops.items[2].end_info.?.reason);
            try testing.expect(s.ground());
            try testing.expectEqual(@as(usize, 1), boundaryHandler(&s).dcs_hooks);
            try testing.expectEqual(@as(usize, 1), boundaryHandler(&s).dcs_unhooks);
        }
    }
}

test "stream: nextSliceUntil combined ground and osc end" {
    const S = Stream(BoundaryTestHandler);
    const set: Boundary.Set = .initMany(&.{ .ground, .osc_end });

    // BEL ends the string and reaches ground on the same byte.
    {
        var s: S = .init(.{ .handler = .{} });
        defer s.deinit();
        s.nextSlice("\x1b]2;ab");
        const stop = s.nextSliceUntil("\x07x", set).?;
        try testing.expectEqual(@as(usize, 1), stop.consumed);
        try testing.expect(stop.reached.eql(set));
        try testing.expectEqual(Boundary.EndReason.bel, stop.end.?.reason);
        try testing.expect(s.ground());
        try testing.expectEqual(@as(usize, 0), s.handler.prints);
    }

    // ESC ends the string but ground is only reached on the backslash.
    {
        var s: S = .init(.{ .handler = .{} });
        defer s.deinit();
        s.nextSlice("\x1b]2;ab");
        const stop = s.nextSliceUntil("\x1b\\x", set).?;
        try testing.expectEqual(@as(usize, 1), stop.consumed);
        try testing.expect(stop.reached.eql(osc_end_set));
        try testing.expectEqual(Boundary.EndReason.st_esc, stop.end.?.reason);
        try testing.expect(!s.ground());

        const ground_stop = s.nextSliceUntil("\\x", set).?;
        try testing.expectEqual(@as(usize, 1), ground_stop.consumed);
        try testing.expect(ground_stop.reached.eql(.initOne(.ground)));
        try testing.expect(ground_stop.end == null);
        try testing.expect(s.ground());
    }
}

/// Hashes every handler action in a chunking-independent way: bulk
/// actions are flattened to their per-element form so two streams fed
/// the same bytes in different pieces hash the same.
const DifferentialHandler = struct {
    hasher: std.hash.Wyhash = .init(0),
    actions: usize = 0,

    pub fn deinit(_: *@This()) void {}

    pub fn vt(
        self: *@This(),
        comptime action: Action.Tag,
        value: Action.Value(action),
    ) void {
        switch (action) {
            .print_slice => for (value.cps) |cp| self.record(.print, @as(u32, cp)),
            .print => self.record(.print, @as(u32, value.cp)),
            .apc_put_slice => for (value.bytes) |b| self.record(.apc_put, b),
            else => self.record(action, value),
        }
    }

    fn record(self: *@This(), comptime tag: Action.Tag, value: anytype) void {
        self.actions += 1;
        self.hasher.update(@tagName(tag));
        std.hash.autoHashStrat(&self.hasher, value, .Deep);
    }

    fn final(self: *@This()) u64 {
        return self.hasher.final();
    }
};

/// Feed one input through a single nextSlice and through a loop of
/// nextSliceUntil requesting every boundary, and require the same
/// handler actions and the same parser state at every stop.
fn differential(input: []const u8) !void {
    const S = Stream(DifferentialHandler);

    var plain: S = .init(.{ .handler = .{} });
    defer plain.deinit();
    plain.nextSlice(input);

    // `reference` is fed exactly the bytes `until` reports consumed,
    // call by call, so it is the "second Stream fed those bytes".
    var until: S = .init(.{ .handler = .{} });
    defer until.deinit();
    var reference: S = .init(.{ .handler = .{} });
    defer reference.deinit();

    var stops: usize = 0;
    var rem = input;
    while (rem.len > 0) {
        var set = all_set;
        if (until.ground()) set.remove(.ground);
        const stop = until.nextSliceUntil(rem, set) orelse {
            reference.nextSlice(rem);
            rem = rem[rem.len..];
            break;
        };
        stops += 1;
        try testing.expect(stop.consumed > 0);
        try testing.expect(stop.consumed <= rem.len);
        reference.nextSlice(rem[0..stop.consumed]);
        rem = rem[stop.consumed..];

        try testing.expectEqual(reference.parser.state, until.parser.state);
        try testing.expectEqual(reference.utf8decoder.state, until.utf8decoder.state);
        if (stop.reached.contains(.ground)) try testing.expect(until.ground());
        const kind = Until.family(until.parser.state);
        if (stop.reached.contains(.apc_start)) {
            try testing.expectEqual(@as(?Boundary.StringKind, .apc), kind);
            try testing.expectEqual(Boundary.StringKind.apc, stop.start.?.kind);
        }
        if (stop.reached.contains(.dcs_start)) {
            try testing.expectEqual(@as(?Boundary.StringKind, .dcs), kind);
            try testing.expectEqual(Boundary.StringKind.dcs, stop.start.?.kind);
        }
        if (stop.reached.contains(.osc_start)) {
            try testing.expectEqual(@as(?Boundary.StringKind, .osc), kind);
            try testing.expectEqual(Boundary.StringKind.osc, stop.start.?.kind);
        }
        if (stop.reached.contains(.apc_end)) {
            try testing.expect(kind == null or kind.? != .apc);
            try testing.expectEqual(Boundary.StringKind.apc, stop.end.?.kind);
        }
        if (stop.reached.contains(.dcs_end)) {
            try testing.expect(kind == null or kind.? != .dcs);
            try testing.expectEqual(Boundary.StringKind.dcs, stop.end.?.kind);
        }
        if (stop.reached.contains(.osc_end)) {
            try testing.expect(kind == null or kind.? != .osc);
            try testing.expectEqual(Boundary.StringKind.osc, stop.end.?.kind);
        }
        // A start and an end of the same kind never coincide.
        if (stop.start) |start| if (stop.end) |end| {
            try testing.expect(start.kind != end.kind);
        };
    }

    try testing.expectEqual(plain.parser.state, until.parser.state);
    try testing.expectEqual(plain.utf8decoder.state, until.utf8decoder.state);
    try testing.expectEqual(plain.handler.actions, until.handler.actions);
    try testing.expectEqual(plain.handler.final(), until.handler.final());
    try testing.expectEqual(plain.handler.final(), reference.handler.final());
}

/// Sees every parser action before the stream handles it and notes the
/// one input shape the stream logs at error level (CSI t with no
/// parameters), which the test runner would count as a failure.
const LogErrProbe = struct {
    csi_t_no_params: bool = false,

    pub fn deinit(_: *@This()) void {}

    pub fn vtRaw(self: *@This(), action: Parser.Action) !bool {
        switch (action) {
            .csi_dispatch => |dispatch| if (dispatch.final == 't' and
                dispatch.intermediates.len == 0 and
                dispatch.params.len == 0)
            {
                self.csi_t_no_params = true;
            },
            else => {},
        }
        return true;
    }

    pub fn vt(_: *@This(), comptime _: Action.Tag, _: anytype) void {}
};

/// True if the stream would log at error level for this input, which
/// the test runner counts as a failure.
fn logsErr(input: []const u8) bool {
    var probe: Stream(LogErrProbe) = .init(.{ .handler = .{} });
    defer probe.deinit();
    probe.nextSlice(input);
    return probe.handler.csi_t_no_params;
}

test "stream: nextSliceUntil differential on generated streams" {
    const alloc = testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const rand = prng.random();

    // Pieces a generated stream is made of. Weighted toward control
    // strings and the bytes that end one, with enough text to cross
    // the 4096-byte decode chunk.
    const Piece = enum { text, utf8, csi, osc, osc_cut, dcs, dcs_cut, apc_esc, apc_c1, apc_cut, raw, big_text, big_apc };
    const terminators = [_][]const u8{ "\x1b\\", "\x9c", "\x18", "\x1a", "\x9f", "\x90", "\x9b", "\x85", "\x1b[m", "\x1b_", "\x9d", "\x07" };

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    var runs: usize = 0;
    while (runs < 64) {
        buf.clearRetainingCapacity();
        const pieces = rand.intRangeAtMost(usize, 1, 48);
        for (0..pieces) |_| {
            switch (rand.enumValue(Piece)) {
                .text => for (0..rand.intRangeAtMost(usize, 1, 64)) |_| {
                    try buf.append(alloc, rand.intRangeAtMost(u8, 0x20, 0x7E));
                },
                .utf8 => for (0..rand.intRangeAtMost(usize, 1, 32)) |_| {
                    var cp_buf: [4]u8 = undefined;
                    const cp: u21 = rand.intRangeAtMost(u21, 0x80, 0x10FFFF);
                    const n = std.unicode.utf8Encode(cp, &cp_buf) catch continue;
                    try buf.appendSlice(alloc, cp_buf[0..n]);
                },
                .csi => {
                    var seq: [32]u8 = undefined;
                    try buf.appendSlice(alloc, try std.fmt.bufPrint(&seq, "\x1b[{d};{d}{c}", .{
                        rand.intRangeAtMost(u8, 0, 99),
                        rand.intRangeAtMost(u8, 0, 99),
                        "mHJKABCDhlr"[rand.uintLessThan(usize, 11)],
                    }));
                },
                .osc => {
                    var seq: [32]u8 = undefined;
                    try buf.appendSlice(alloc, try std.fmt.bufPrint(&seq, "\x1b]{d};title{d}{s}", .{
                        rand.intRangeAtMost(u8, 0, 9),
                        rand.int(u16),
                        if (rand.boolean()) "\x07" else "\x1b\\",
                    }));
                },
                .osc_cut => {
                    try buf.appendSlice(alloc, if (rand.boolean()) "\x1b]" else "\x9d");
                    try buf.appendSlice(alloc, "52;c;");
                    for (0..rand.intRangeAtMost(usize, 0, 100)) |_| {
                        try buf.append(alloc, rand.intRangeAtMost(u8, 0x20, 0xFF));
                    }
                    try buf.appendSlice(alloc, terminators[rand.uintLessThan(usize, terminators.len)]);
                },
                .dcs, .dcs_cut => |kind| {
                    try buf.appendSlice(alloc, if (rand.boolean()) "\x1bP" else "\x90");
                    // A header that may be cut short, or a payload.
                    var seq: [16]u8 = undefined;
                    try buf.appendSlice(alloc, try std.fmt.bufPrint(&seq, "{d};{d}", .{
                        rand.intRangeAtMost(u8, 0, 99),
                        rand.intRangeAtMost(u8, 0, 99),
                    }));
                    if (kind == .dcs or rand.boolean()) {
                        try buf.append(alloc, "q|$p"[rand.uintLessThan(usize, 4)]);
                        for (0..rand.intRangeAtMost(usize, 0, 100)) |_| {
                            try buf.append(alloc, rand.intRangeAtMost(u8, 0x00, 0xFF));
                        }
                    }
                    try buf.appendSlice(alloc, if (kind == .dcs)
                        "\x1b\\"
                    else
                        terminators[rand.uintLessThan(usize, terminators.len)]);
                },
                .apc_esc, .apc_c1, .apc_cut => |kind| {
                    try buf.appendSlice(alloc, if (kind == .apc_c1) "\x9f" else "\x1b_");
                    try buf.appendSlice(alloc, "Gf=100,a=T;");
                    for (0..rand.intRangeAtMost(usize, 0, 200)) |_| {
                        try buf.append(alloc, rand.intRangeAtMost(u8, 0x20, 0x7E));
                    }
                    try buf.appendSlice(alloc, terminators[rand.uintLessThan(usize, terminators.len)]);
                },
                .raw => for (0..rand.intRangeAtMost(usize, 1, 16)) |_| {
                    try buf.append(alloc, rand.int(u8));
                },
                .big_text => for (0..rand.intRangeAtMost(usize, 4000, 9000)) |_| {
                    try buf.append(alloc, rand.intRangeAtMost(u8, 0x20, 0x7E));
                },
                .big_apc => {
                    try buf.appendSlice(alloc, "\x1b_Gf=100,a=T;");
                    for (0..rand.intRangeAtMost(usize, 4000, 9000)) |_| {
                        try buf.append(alloc, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"[rand.uintLessThan(usize, 64)]);
                    }
                    try buf.appendSlice(alloc, "\x1b\\");
                },
            }
        }
        // Random bytes can spell the one sequence the stream logs an
        // error for; skip those inputs rather than fail the run.
        if (logsErr(buf.items)) continue;
        try differential(buf.items);
        runs += 1;
    }
}

test "stream: nextSliceUntil differential on the fuzz corpus" {
    const alloc = testing.allocator;
    const io = testing.io;

    // The corpus lives in the repo; tests run from the build root.
    const path = "test/fuzz-libghostty/corpus/stream-cmin";
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer dir.close(io);

    var files: usize = 0;
    var skipped: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const data = try dir.readFileAlloc(io, entry.name, alloc, .limited(4 << 20));
        defer alloc.free(data);

        if (logsErr(data)) {
            skipped += 1;
            continue;
        }

        try differential(data);
        files += 1;
    }
    try testing.expect(files > 1000);
    try testing.expect(skipped < files / 10);
}

test "stream: continuation lifecycle" {
    const S = Stream(ContinuationTestHandler);

    var disabled: S = .init(.{ .handler = .{} });
    defer disabled.deinit();
    var disabled_buf: [1]u8 = undefined;
    var disabled_writer: std.Io.Writer = .fixed(&disabled_buf);
    try testing.expectError(
        error.ContinuationDisabled,
        disabled.writeContinuation(&disabled_writer),
    );

    var zero_capacity: S = .init(.{
        .handler = .{},
        .continuation_max_bytes = 0,
    });
    defer zero_capacity.deinit();
    var zero_capacity_buf: [1]u8 = undefined;
    var zero_capacity_writer: std.Io.Writer = .fixed(&zero_capacity_buf);
    try testing.expectError(
        error.ContinuationDisabled,
        zero_capacity.writeContinuation(&zero_capacity_writer),
    );
    var no_allocator: S = .init(.{
        .handler = .{},
        .continuation_max_bytes = 64,
    });
    defer no_allocator.deinit();
    var no_allocator_buf: [1]u8 = undefined;
    var no_allocator_writer: std.Io.Writer = .fixed(&no_allocator_buf);
    try testing.expectError(
        error.ContinuationDisabled,
        no_allocator.writeContinuation(&no_allocator_writer),
    );

    var tracked = S.init(.{
        .allocator = testing.allocator,
        .handler = .{},
        .continuation_max_bytes = 64,
    });
    defer tracked.deinit();

    tracked.nextSlice("complete input");
    var empty_buf: [1]u8 = undefined;
    var empty_writer: std.Io.Writer = .fixed(&empty_buf);
    try tracked.writeContinuation(&empty_writer);
    try testing.expectEqual(@as(usize, 0), empty_writer.end);

    tracked.nextSlice("\x1b[");
    var short_buf: [1]u8 = undefined;
    var short_writer: std.Io.Writer = .fixed(&short_buf);
    try testing.expectError(
        error.WriteFailed,
        tracked.writeContinuation(&short_writer),
    );

    var failing = testing.FailingAllocator.init(testing.allocator, .{
        .fail_index = 0,
    });
    var failing_stream = Stream(ContinuationNullHandler).init(.{
        .allocator = failing.allocator(),
        .handler = .{},
        .continuation_max_bytes = 64,
    });
    defer failing_stream.deinit();
    failing_stream.nextSlice("\x1b[");
    var unavailable_buf: [1]u8 = undefined;
    var unavailable_writer: std.Io.Writer = .fixed(&unavailable_buf);
    try testing.expectError(
        error.ContinuationUnavailable,
        failing_stream.writeContinuation(&unavailable_writer),
    );
}

test "stream: continuation suffixes are replay safe" {
    const Case = struct {
        input: []const u8,
        expected: []const u8,
    };
    const cases = [_]Case{
        .{ .input = "text\x1b", .expected = "\x1b" },
        .{ .input = "text\x1b[12;", .expected = "\x1b[12;" },
        .{ .input = "text\x1b[1\x07;2", .expected = "\x1b[1;2" },
        .{ .input = "text\x1b]2;hello", .expected = "\x1b]2;hello" },
        .{ .input = "text\x1b_Gabc", .expected = "\x1b_Gabc" },
        .{ .input = "text\x1bP+qabc", .expected = "\x1bP+qabc" },
        .{ .input = "text\xE0\xA0\xF0", .expected = "\xF0" },
        .{ .input = "text\x1b[12\x1b", .expected = "\x1b" },
        .{
            .input = "text\x1b[12\x9D2;title",
            .expected = "\x1b]2;title",
        },
        .{ .input = "text\x1b_Gabc\x9B1", .expected = "\x1b[1" },
    };

    const S = Stream(ContinuationTestHandler);
    for (cases) |case| {
        var stream = S.init(.{
            .allocator = testing.allocator,
            .handler = .{},
            .continuation_max_bytes = 1024,
        });
        defer stream.deinit();
        stream.nextSlice(case.input);

        var buf: [1024]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        try stream.writeContinuation(&writer);
        try testing.expectEqualStrings(case.expected, writer.buffered());
    }
}

test "stream: continuation reconstructs every unfinished VT state" {
    const Case = struct {
        input: []const u8,
        state: Parser.State,
    };
    const cases = [_]Case{
        .{ .input = "\x1b", .state = .escape },
        .{ .input = "\x1b(", .state = .escape_intermediate },
        .{ .input = "\x1b[", .state = .csi_entry },
        .{ .input = "\x1b[1", .state = .csi_param },
        .{ .input = "\x1b[1$", .state = .csi_intermediate },
        .{ .input = "\x1b[:", .state = .csi_ignore },
        .{ .input = "\x1bP", .state = .dcs_entry },
        .{ .input = "\x1bP1", .state = .dcs_param },
        .{ .input = "\x1bP1$", .state = .dcs_intermediate },
        .{ .input = "\x1bP1q", .state = .dcs_passthrough },
        .{ .input = "\x1bP:", .state = .dcs_ignore },
        .{ .input = "\x1b]2;title", .state = .osc_string },
        .{ .input = "\x1b_Gpayload", .state = .sos_pm_apc_string },
    };
    const S = Stream(ContinuationTestHandler);

    for (cases) |case| {
        var source = S.init(.{
            .allocator = testing.allocator,
            .handler = .{},
            .continuation_max_bytes = 1024,
        });
        defer source.deinit();
        source.nextSlice(case.input);
        try testing.expectEqual(case.state, source.parser.state);

        var buf: [1024]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        try source.writeContinuation(&writer);

        var restored = S.init(.{
            .allocator = testing.allocator,
            .handler = .{},
            .continuation_max_bytes = 1024,
        });
        defer restored.deinit();
        restored.nextSlice(writer.buffered());
        try testing.expectEqual(@as(usize, 0), restored.handler.committed);
        try testing.expectEqual(source.parser.state, restored.parser.state);
        try testing.expectEqual(source.utf8decoder.state, restored.utf8decoder.state);
    }

    // Parser ground is still unfinished while the UTF-8 decoder is waiting
    // for the remaining bytes of a codepoint.
    var utf8 = S.init(.{
        .allocator = testing.allocator,
        .handler = .{},
        .continuation_max_bytes = 4,
    });
    defer utf8.deinit();
    utf8.next(0xF0);
    try testing.expectEqual(Parser.State.ground, utf8.parser.state);
    try testing.expect(utf8.utf8decoder.state != 0);
    var utf8_buf: [4]u8 = undefined;
    var utf8_writer: std.Io.Writer = .fixed(&utf8_buf);
    try utf8.writeContinuation(&utf8_writer);
    try testing.expectEqualSlices(u8, &.{0xF0}, utf8_writer.buffered());
}

test "stream: continuation is chunking-independent and idempotent" {
    const S = Stream(ContinuationTestHandler);
    const input = "committed\x1b[1\x07;2";

    var bulk = S.init(.{
        .allocator = testing.allocator,
        .handler = .{},
        .continuation_max_bytes = 1024,
    });
    defer bulk.deinit();
    bulk.nextSlice(input);

    var scalar = S.init(.{
        .allocator = testing.allocator,
        .handler = .{},
        .continuation_max_bytes = 1024,
    });
    defer scalar.deinit();
    for (input) |c| scalar.next(c);

    var bulk_buf: [1024]u8 = undefined;
    var bulk_writer: std.Io.Writer = .fixed(&bulk_buf);
    try bulk.writeContinuation(&bulk_writer);
    var scalar_buf: [1024]u8 = undefined;
    var scalar_writer: std.Io.Writer = .fixed(&scalar_buf);
    try scalar.writeContinuation(&scalar_writer);
    try testing.expectEqualStrings(
        bulk_writer.buffered(),
        scalar_writer.buffered(),
    );

    var restored = S.init(.{
        .allocator = testing.allocator,
        .handler = .{},
        .continuation_max_bytes = 1024,
    });
    defer restored.deinit();
    restored.nextSlice(bulk_writer.buffered());
    try testing.expectEqual(@as(usize, 0), restored.handler.committed);

    var restored_buf: [1024]u8 = undefined;
    var restored_writer: std.Io.Writer = .fixed(&restored_buf);
    try restored.writeContinuation(&restored_writer);
    try testing.expectEqualStrings(
        bulk_writer.buffered(),
        restored_writer.buffered(),
    );

    bulk.handler.committed = 0;
    restored.handler.committed = 0;
    bulk.nextSlice("mZ");
    restored.next('m');
    restored.next('Z');
    try testing.expectEqual(bulk.handler.committed, restored.handler.committed);
}

test "stream: continuation rebuilds APC handler input" {
    const S = Stream(ContinuationTestHandler);
    var source = S.init(.{
        .allocator = testing.allocator,
        .handler = .{},
        .continuation_max_bytes = 1024,
    });
    defer source.deinit();
    source.nextSlice("committed\x1b_Gabc");

    var continuation: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&continuation);
    try source.writeContinuation(&writer);

    var restored = S.init(.{
        .allocator = testing.allocator,
        .handler = .{},
        .continuation_max_bytes = 1024,
    });
    defer restored.deinit();
    restored.nextSlice(writer.buffered());
    try testing.expectEqual(@as(usize, 0), restored.handler.committed);
    try testing.expect(restored.handler.apc_active);
    try testing.expectEqualStrings(
        source.handler.apc_buf[0..source.handler.apc_len],
        restored.handler.apc_buf[0..restored.handler.apc_len],
    );

    source.handler.committed = 0;
    restored.handler.committed = 0;
    source.nextSlice("\x1b\\");
    restored.nextSlice("\x1b\\");
    try testing.expectEqual(source.handler.committed, restored.handler.committed);
    try testing.expect(!source.handler.apc_active);
    try testing.expect(!restored.handler.apc_active);
}

test "stream: continuation cap and recovery" {
    const S = Stream(ContinuationTestHandler);

    // The raw feed exceeds the cap, but only the unfinished three-byte
    // CSI suffix is retained.
    var seeded = S.init(.{
        .allocator = testing.allocator,
        .handler = .{},
        .continuation_max_bytes = 4,
    });
    defer seeded.deinit();
    seeded.nextSlice("committed text\x1b[1");
    var seeded_buf: [4]u8 = undefined;
    var seeded_writer: std.Io.Writer = .fixed(&seeded_buf);
    try seeded.writeContinuation(&seeded_writer);
    try testing.expectEqualStrings("\x1b[1", seeded_writer.buffered());

    var exceeded = S.init(.{
        .allocator = testing.allocator,
        .handler = .{},
        .continuation_max_bytes = 4,
    });
    defer exceeded.deinit();
    exceeded.nextSlice("\x1b[123");
    var unavailable_buf: [1]u8 = undefined;
    var unavailable_writer: std.Io.Writer = .fixed(&unavailable_buf);
    try testing.expectError(
        error.ContinuationUnavailable,
        exceeded.writeContinuation(&unavailable_writer),
    );

    // Completing the CSI reaches ground and recovers without rebuilding the
    // Stream. A later unfinished sequence is tracked normally.
    exceeded.nextSlice("mtext\x1b[");
    var recovered_buf: [4]u8 = undefined;
    var recovered_writer: std.Io.Writer = .fixed(&recovered_buf);
    try exceeded.writeContinuation(&recovered_writer);
    try testing.expectEqualStrings("\x1b[", recovered_writer.buffered());

    // A fresh ESC seed also recovers broken tracking even when the stream
    // never reaches ground: the ESC abandons the previous unfinished
    // state and everything after it is retained.
    exceeded.nextSlice("\x1b[123");
    var reexceeded_buf: [1]u8 = undefined;
    var reexceeded_writer: std.Io.Writer = .fixed(&reexceeded_buf);
    try testing.expectError(
        error.ContinuationUnavailable,
        exceeded.writeContinuation(&reexceeded_writer),
    );
    exceeded.nextSlice("\x1b]0;");
    var seed_buf: [4]u8 = undefined;
    var seed_writer: std.Io.Writer = .fixed(&seed_buf);
    try exceeded.writeContinuation(&seed_writer);
    try testing.expectEqualStrings("\x1b]0;", seed_writer.buffered());
}

test "stream: continuation spans multiple bulk feeds" {
    const S = Stream(ContinuationTestHandler);

    // An unfinished APC grows across feeds that contain no new seed.
    var apc = S.init(.{
        .allocator = testing.allocator,
        .handler = .{},
        .continuation_max_bytes = 1024,
    });
    defer apc.deinit();
    apc.nextSlice("text\x1b_Gab");
    apc.nextSlice("cd");
    apc.nextSlice("ef");
    var apc_buf: [16]u8 = undefined;
    var apc_writer: std.Io.Writer = .fixed(&apc_buf);
    try apc.writeContinuation(&apc_writer);
    try testing.expectEqualStrings("\x1b_Gabcdef", apc_writer.buffered());

    // An incomplete UTF-8 sequence grows across feeds of its
    // continuation bytes.
    var utf8 = S.init(.{
        .allocator = testing.allocator,
        .handler = .{},
        .continuation_max_bytes = 1024,
    });
    defer utf8.deinit();
    utf8.nextSlice("text\xF0");
    utf8.nextSlice("\x9F");
    var utf8_buf: [4]u8 = undefined;
    var utf8_writer: std.Io.Writer = .fixed(&utf8_buf);
    try utf8.writeContinuation(&utf8_writer);
    try testing.expectEqualSlices(u8, "\xF0\x9F", utf8_writer.buffered());

    // A later feed with its own seed drops everything retained earlier.
    utf8.nextSlice("\x98\x84 done \x1b[38;5");
    var seed_buf: [8]u8 = undefined;
    var seed_writer: std.Io.Writer = .fixed(&seed_buf);
    try utf8.writeContinuation(&seed_writer);
    try testing.expectEqualStrings("\x1b[38;5", seed_writer.buffered());
}

test "stream: continuation exact cap and large unfinished string" {
    const S = Stream(ContinuationNullHandler);

    var exact = S.init(.{
        .allocator = testing.allocator,
        .handler = .{},
        .continuation_max_bytes = 5,
    });
    defer exact.deinit();
    exact.nextSlice("\x1b[123");
    var exact_buf: [5]u8 = undefined;
    var exact_writer: std.Io.Writer = .fixed(&exact_buf);
    try exact.writeContinuation(&exact_writer);
    try testing.expectEqualStrings("\x1b[123", exact_writer.buffered());

    const payload_len = 12 * 1024;
    const input = try testing.allocator.alloc(u8, payload_len);
    defer testing.allocator.free(input);
    input[0..3].* = "\x1b_G".*;
    @memset(input[3..], 'A');

    var large = S.init(.{
        .allocator = testing.allocator,
        .handler = .{},
        .continuation_max_bytes = payload_len,
    });
    defer large.deinit();
    large.nextSlice(input);
    const large_buf = try testing.allocator.alloc(u8, payload_len);
    defer testing.allocator.free(large_buf);
    var large_writer: std.Io.Writer = .fixed(large_buf);
    try large.writeContinuation(&large_writer);
    try testing.expectEqualSlices(u8, input, large_writer.buffered());
}

test "stream: continuation allocation failure recovers" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const alloc = failing.allocator();
    const S = Stream(ContinuationNullHandler);
    var stream = S.init(.{
        .allocator = alloc,
        .handler = .{},
        .continuation_max_bytes = 16 * 1024,
    });
    defer stream.deinit();

    var input = try testing.allocator.alloc(u8, 12 * 1024);
    defer testing.allocator.free(input);
    input[0..2].* = "\x1b[".*;
    @memset(input[2..], '1');

    failing.fail_index = failing.alloc_index;
    // ArrayList growth remaps in place, which bypasses fail_index, so arm
    // the resize failure index too.
    failing.resize_fail_index = failing.resize_index;
    stream.nextSlice(input);
    var unavailable_buf: [1]u8 = undefined;
    var unavailable_writer: std.Io.Writer = .fixed(&unavailable_buf);
    try testing.expectError(
        error.ContinuationUnavailable,
        stream.writeContinuation(&unavailable_writer),
    );

    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    stream.next('m');
    var recovered_buf: [1]u8 = undefined;
    var recovered_writer: std.Io.Writer = .fixed(&recovered_buf);
    try stream.writeContinuation(&recovered_writer);
    try testing.expectEqual(@as(usize, 0), recovered_writer.end);
}

test "stream: continuation every-byte cuts preserve future behavior" {
    const corpora = [_][]const u8{
        "plain \xF0\x9F\x98\x84 utf8",
        "bad \xE0\xA0\xF0\x9F\x98\x84 utf8",
        "\x1b[1\x07;2mstyled\x1b[0m",
        "\x1b]2;window title\x1b\\text",
        "\x1bP$qm\x1b\\text",
        "\x1b_Ga=q;payload\x1b\\text",
        "\x1b_25a1;s\x1b\\text",
        "\x1b]2;first\x1b\\\x1b_Gsecond",
        "\x1b[12\x9D2;title\x1b\\text",
        "\x1b[12\x18text\x1b[1\x1Atext",
    };
    const S = Stream(ContinuationTestHandler);

    for (corpora) |corpus| for (0..corpus.len + 1) |cut| {
        var source = S.init(.{
            .allocator = testing.allocator,
            .handler = .{},
            .continuation_max_bytes = 64 * 1024,
        });
        defer source.deinit();
        source.nextSlice(corpus[0..cut]);

        var continuation: [64 * 1024]u8 = undefined;
        var continuation_writer: std.Io.Writer = .fixed(&continuation);
        try source.writeContinuation(&continuation_writer);

        var restored = S.init(.{
            .allocator = testing.allocator,
            .handler = .{},
            .continuation_max_bytes = 64 * 1024,
        });
        defer restored.deinit();
        restored.nextSlice(continuation_writer.buffered());
        try testing.expectEqual(@as(usize, 0), restored.handler.committed);
        try testing.expectEqual(source.handler.apc_active, restored.handler.apc_active);
        try testing.expectEqual(source.handler.dcs_active, restored.handler.dcs_active);
        if (source.handler.apc_active) {
            try testing.expectEqualStrings(
                source.handler.apc_buf[0..source.handler.apc_len],
                restored.handler.apc_buf[0..restored.handler.apc_len],
            );
        }

        var reexport: [64 * 1024]u8 = undefined;
        var reexport_writer: std.Io.Writer = .fixed(&reexport);
        try restored.writeContinuation(&reexport_writer);
        try testing.expectEqualStrings(
            continuation_writer.buffered(),
            reexport_writer.buffered(),
        );

        source.handler.committed = 0;
        restored.handler.committed = 0;
        source.nextSlice(corpus[cut..]);
        var offset = cut;
        var partition = cut +% corpus.len +% 1;
        while (offset < corpus.len) {
            partition = partition *% 1664525 +% 1013904223;
            const len = @min(1 + partition % 7, corpus.len - offset);
            restored.nextSlice(corpus[offset..][0..len]);
            offset += len;
        }
        try testing.expectEqual(source.handler.committed, restored.handler.committed);
        try testing.expectEqual(source.handler.apc_active, restored.handler.apc_active);
        try testing.expectEqual(source.handler.dcs_active, restored.handler.dcs_active);

        var source_final: [64]u8 = undefined;
        var source_final_writer: std.Io.Writer = .fixed(&source_final);
        try source.writeContinuation(&source_final_writer);
        var restored_final: [64]u8 = undefined;
        var restored_final_writer: std.Io.Writer = .fixed(&restored_final);
        try restored.writeContinuation(&restored_final_writer);
        try testing.expectEqualStrings(
            source_final_writer.buffered(),
            restored_final_writer.buffered(),
        );
    };
}
