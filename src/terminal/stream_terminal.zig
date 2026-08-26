const std = @import("std");
const Allocator = std.mem.Allocator;
const build_options = @import("terminal_options");
const testing = std.testing;
const apc = @import("apc.zig");
const clipboard = @import("clipboard.zig");
const csi = @import("csi.zig");
const dcs = @import("dcs.zig");
const device_attributes = @import("device_attributes.zig");
const device_status = @import("device_status.zig");
const stream = @import("stream.zig");
const Action = stream.Action;
const Screen = @import("Screen.zig");
const color = @import("color.zig");
const modes = @import("modes.zig");
const osc = @import("osc.zig");
const osc_color = @import("osc/parsers/color.zig");
const kitty_clipboard = @import("kitty/clipboard.zig");
const kitty_color = @import("kitty/color.zig");
const paste_pkg = @import("paste.zig");
const kitty_dnd = @import("kitty/dnd.zig");
const size_report = @import("size_report.zig");
const simd = @import("../simd/main.zig");
const terminfo = @import("../terminfo/main.zig");
const Terminal = @import("Terminal.zig");

const log = std.log.scoped(.stream_terminal);

/// This is a Stream implementation that processes actions against
/// a Terminal and updates the Terminal state.
pub const Stream = stream.Stream(Handler);

/// A stream handler that updates terminal state. By default, it is
/// readonly in the sense that it only updates terminal state and ignores
/// all other sequences that require a response or otherwise have side
/// effects (e.g. clipboards).
///
/// You can manually set various effects callbacks in the `effects` field
/// to implement certain effects such as bells, titles, clipboard, etc.
pub const Handler = struct {
    /// The terminal state to modify.
    terminal: *Terminal,

    /// True after an error prevented a terminal-owned semantic update.
    ///
    /// When an error happens during terminal processing, streams continue
    /// forward and remain best-effort. A terminal can't really stop in
    /// the middle it must go on. But this is flagged to true to let
    /// consumers know some sort of unhandle-able error state happened
    /// (e.g. an allocation failure).
    ///
    /// Only non-handled outcomes set this. Gracefully handled outcomes
    /// that don't meaningfully negatively impact the terminal state
    /// such as hitting Kitty image limits, failure to write a response,
    /// do not flag this.
    semantic_failure: bool = false,

    /// Callbacks for certain effects that handlers may have. These
    /// may or may not fully replace internal handling of certain effects,
    /// but they allow for the handler to trigger or query external
    /// effects.
    effects: Effects = .readonly,

    /// Whether CSI 21 t may report the terminal title. This is disabled by
    /// default because reporting an attacker-controlled title to the pty can
    /// inject text into the input stream of the foreground process.
    title_report: bool = false,

    /// The APC command handler maintains the APC state. APC is like
    /// CSI or OSC, but it is a private escape sequence that is used
    /// to send commands to the terminal emulator. This is used by
    /// the kitty graphics protocol.
    apc_handler: apc.Handler = .{},

    /// The DCS command handler maintains state for DCS queries.
    dcs_handler: dcs.Handler = .{},

    /// The in-flight Kitty clipboard protocol (OSC 5522) write
    /// transaction, if any. Null means no transaction is active.
    /// Heap-allocated since transactions are rare and short-lived.
    kitty_clipboard_write: ?*kitty_clipboard.WriteState = null,

    /// Kitty clipboard protocol (OSC 5522) session password grants,
    /// recorded when a clipboard_read or clipboard_write reply asks to
    /// remember the user's decision.
    kitty_clipboard_grants: kitty_clipboard.Grants = .{},

    /// Maximum total decoded bytes accumulated by one Kitty clipboard
    /// protocol (OSC 5522) write transaction, captured when the
    /// transaction begins. Data beyond the limit fails the transaction
    /// with EFBIG.
    kitty_clipboard_write_max_bytes: usize = kitty_clipboard.max_write_size,

    /// Called for sequence identifiers not supported by this library.
    /// Currently, only APC is reported. Content is borrowed and only valid
    /// for the duration of the callback. Set `apc_handler.unknown_max_bytes`
    /// before starting the Stream to enable APC capture.
    unknown_sequence: ?*const fn (*Handler, UnknownSequence) void = null,

    /// The name of the terminfo entry this terminal runs as, reported in
    /// response to an XTGETTCAP query for "TN".
    ///
    /// The memory must remain valid for the lifetime of the handler.
    /// Empty names and names longer than `max_terminfo_name_bytes` are
    /// silently ignored.
    terminfo_name: ?[]const u8 = null,

    /// Maximum byte length accepted for `terminfo_name`.
    pub const max_terminfo_name_bytes = 128;

    pub const Effects = struct {
        /// Called when the terminal needs to write data back to the pty,
        /// e.g. in response to a DECRQM query. The data is only valid
        /// during the lifetime of the call so callers must copy it
        /// if it needs to be stored or used after the call returns.
        write_pty: ?*const fn (*Handler, []const u8) void,

        /// Called when the bell is rung (BEL).
        bell: ?*const fn (*Handler) void,

        /// Called when the running program requests a desktop notification
        /// via OSC 9 or OSC 777. The title and body are borrowed and only
        /// valid for the duration of the callback.
        desktop_notification: ?*const fn (*Handler, Action.ShowDesktopNotification) void,

        /// Called when drag and drop protocol state changes in a way the
        /// embedder may need to act on: the running program registering
        /// or unregistering to accept drops, answering a drag, or
        /// concluding a drop. The event says what changed; the details
        /// are read from `handler.terminal.kitty_dnd` (Kitty's OSC 72 is
        /// the only drag and drop protocol today). Native drag events
        /// flow the other way, by calling `kitty.dnd.State` directly.
        drag_and_drop: ?*const fn (*Handler, kitty_dnd.Event) void,

        /// Called in response to a color scheme DSR query (CSI ? 996 n).
        /// Returns the current color scheme. Return null to silently
        /// ignore the query.
        color_scheme: ?*const fn (*Handler) ?device_status.ColorScheme,

        /// Called in response to a device attributes query (CSI c,
        /// CSI > c, CSI = c). Returns the response to encode and
        /// write back to the pty.
        device_attributes: ?*const fn (*Handler) device_attributes.Attributes,

        /// Called in response to ENQ (0x05). Returns the raw response
        /// bytes to write back to the pty. The returned memory must be
        /// valid for the lifetime of the call.
        enquiry: ?*const fn (*Handler) []const u8,

        /// Called for XTWINOPS size queries (CSI 14/16/18 t) and when VT input
        /// enables in-band size reports (mode 2048). Returns the current
        /// terminal geometry used for encoding. Return null to suppress the
        /// XTWINOPS response or mode 2048 report.
        size: ?*const fn (*Handler) ?size_report.Size,

        /// Called when the terminal title changes via escape sequences
        /// (e.g. OSC 0/2). The new title can be queried via
        /// handler.terminal.getTitle().
        title_changed: ?*const fn (*Handler) void,

        /// Called when the terminal pwd changes via escape sequences
        /// (e.g. OSC 7). The new pwd can be queried via
        /// handler.terminal.getPwd().
        pwd_changed: ?*const fn (*Handler) void,

        /// Called when the running program reports progress via OSC 9;4.
        progress_report: ?*const fn (*Handler, osc.Command.ProgressReport) void,

        /// Called when the running program writes to a clipboard.
        clipboard_write: ?*const fn (*Handler, clipboard.Write) void,

        /// Called when the running program requests clipboard contents
        /// (OSC 52 with a "?" payload, or a Kitty clipboard (OSC 5522)
        /// read). Answering one lets the program read the user's
        /// clipboard, so the embedder is expected to mediate consent.
        ///
        /// Reads are synchronous: the callback must answer through
        /// `read.reply` before it returns, so an embedder that needs to
        /// ask the user must block (e.g. run a modal prompt) while the
        /// stream waits. Returning without a reply, or replying with any
        /// failure, answers the program with an empty clipboard (OSC 52)
        /// or the matching protocol status (OSC 5522) so it doesn't hang.
        /// If this is null, OSC 52 reads are ignored and OSC 5522 reads
        /// are refused with EPERM.
        ///
        /// OSC 5522 requests carry the program's MIME list, name, and
        /// password grant state; a reply that sets `remember` records a
        /// session grant so later requests with the same password arrive
        /// with `granted` set. Kitty itself serves a request for only the
        /// targets listing (`list` with no `mimes`) without prompting.
        ///
        /// Installing this also enables Kitty paste events (mode 5522):
        /// `paste` sends the program an event instead of the text, and
        /// the program's follow-up read arrives here with `granted` set
        /// since the user already pasted. See `paste`.
        clipboard_read: ?*const fn (*Handler, clipboard.Read) void,

        /// Called in response to an XTVERSION query. Returns the version
        /// string to report (e.g. "ghostty 1.2.3"). The returned memory
        /// must be valid for the lifetime of the call. The maximum length
        /// is 256 bytes; longer strings will be silently ignored.
        xtversion: ?*const fn (*Handler) []const u8,

        /// No effects means that the stream effectively becomes readonly
        /// that only affects pure terminal state and ignores all side
        /// effects beyond that.
        pub const readonly: Effects = .{
            .bell = null,
            .clipboard_read = null,
            .clipboard_write = null,
            .color_scheme = null,
            .desktop_notification = null,
            .device_attributes = null,
            .drag_and_drop = null,
            .enquiry = null,
            .progress_report = null,
            .size = null,
            .title_changed = null,
            .pwd_changed = null,
            .write_pty = null,
            .xtversion = null,
        };
    };

    /// A sequence unsupported by the active handler. Payload data is borrowed
    /// only for the duration of the handler callback.
    pub const UnknownSequence = union(enum) {
        apc: String,

        /// Content between a string sequence's introducer and terminator.
        pub const String = struct {
            content: []const u8,
            truncated: bool,
        };
    };

    pub fn init(terminal: *Terminal) Handler {
        return .{
            .terminal = terminal,
        };
    }

    pub fn deinit(self: *Handler) void {
        self.kittyClipboardAbort();
        self.kitty_clipboard_grants.deinit(self.terminal.gpa());
        self.apc_handler.deinit();
        self.dcs_handler.deinit();
    }

    /// Resize the terminal and apply any side effects (if supported)
    /// as a result of that.
    ///
    /// This is different than a direct `Terminal.resize` operation
    /// because it also handles the side effects like mode 2048 in-band
    /// size reports if write_pty is set.
    pub fn resize(self: *Handler, value: Terminal.Resize) !void {
        try self.terminal.resize(self.terminal.gpa(), value);

        // Mode 2048 reports require complete, current cell pixel geometry.
        const cell_size = value.cell_size_px orelse return;

        // If we have no in-band size reports enabled then do nothing.
        if (!self.terminal.modes.get(.in_band_size_reports)) return;

        // If we have no write_pty effect, do nothing.
        const write_pty = self.effects.write_pty orelse return;

        // The maximum mode-2048 response is covered by size_report's maximum
        // value test. Reserve the final byte for the callback's sentinel.
        var buf: [128]u8 = undefined;
        var writer: std.Io.Writer = .fixed(buf[0 .. buf.len - 1]);
        size_report.encode(&writer, .mode_2048, .{
            .rows = value.rows,
            .columns = value.cols,
            .cell_width = cell_size.width,
            .cell_height = cell_size.height,
        }) catch unreachable;
        buf[writer.end] = 0;
        write_pty(self, buf[0..writer.end :0]);
    }

    /// A paste request; see `paste`.
    pub const Paste = paste_pkg.Request;

    pub const PasteError = Allocator.Error || std.Io.RandomSecureError || error{
        /// The data could inject commands and allow_unsafe was false.
        /// Nothing was written.
        UnsafePaste,

        /// The contents reader failed. Nothing was written.
        ReadFailed,

        /// No write_pty effect is set, so nothing can be written.
        NoWritePty,
    };

    /// The size of the chunks a paste streams to write_pty in.
    pub const paste_chunk_size = 4096;

    /// Paste into the terminal, applying the terminal's current state
    /// as necessary to owner mode 5522, bracketed paste, unsafe paste, etc.
    /// Returns true if anything was written to the pty.
    ///
    /// The output streams to write_pty in chunks of `paste_chunk_size`.
    /// The contents are read at most once and only the pasted text
    /// representation is ever read, buffered whole while it is checked
    /// and encoded; see `terminal.paste`.
    pub fn paste(self: *Handler, req: Paste) PasteError!bool {
        if (self.effects.write_pty == null) return error.NoWritePty;

        var buf: [paste_chunk_size]u8 = undefined;
        var pty: PtyWriter = .init(self, &buf);
        // Delivered on error too: a partial paste has its frame closed
        // and the program must see that.
        defer pty.writer.flush() catch unreachable;

        return paste_pkg.paste(.{
            .terminal = self.terminal,
            .alloc = self.terminal.gpa(),
            // Paste events need the program's follow-up Kitty
            // clipboard read served.
            .kitty_clipboard = if (self.effects.clipboard_read != null) .{
                .grants = &self.kitty_clipboard_grants,
                .io = self.terminal.io(),
            } else null,
            .writer = &pty.writer,
        }, req) catch |err| switch (err) {
            // The pty writer never fails.
            error.WriteFailed => unreachable,
            error.ReadFailed,
            error.OutOfMemory,
            error.UnsafePaste,
            error.EntropyUnavailable,
            error.Canceled,
            => |e| e,
        };
    }

    pub fn vt(
        self: *Handler,
        comptime action: Action.Tag,
        value: Action.Value(action),
    ) void {
        self.vtFallible(action, value) catch |err| {
            self.semantic_failure = true;
            log.warn("error handling VT action action={} err={}", .{ action, err });
        };
    }

    fn unknownSequence(self: *Handler, value: UnknownSequence) void {
        const func = self.unknown_sequence orelse return;
        func(self, value);
    }

    inline fn vtFallible(
        self: *Handler,
        comptime action: Action.Tag,
        value: Action.Value(action),
    ) !void {
        switch (action) {
            .print => try self.terminal.print(value.cp),
            .print_slice => try self.terminal.printSlice(value.cps),
            .print_repeat => try self.terminal.printRepeat(value),
            .backspace => self.terminal.backspace(),
            .carriage_return => self.terminal.carriageReturn(),
            .linefeed => try self.terminal.linefeed(),
            .index => try self.terminal.index(),
            .next_line => {
                try self.terminal.index();
                self.terminal.carriageReturn();
            },
            .reverse_index => self.terminal.reverseIndex(),
            .cursor_up => self.terminal.cursorUp(value.value),
            .cursor_down => self.terminal.cursorDown(value.value),
            .cursor_left => self.terminal.cursorLeft(value.value),
            .cursor_right => self.terminal.cursorRight(value.value),
            .cursor_pos => self.terminal.setCursorPos(value.row, value.col),
            .cursor_col => self.terminal.setCursorPos(self.terminal.screens.active.cursor.y + 1, value.value),
            .cursor_row => self.terminal.setCursorPos(value.value, self.terminal.screens.active.cursor.x + 1),
            .cursor_col_relative => self.terminal.setCursorPos(
                self.terminal.screens.active.cursor.y + 1,
                self.terminal.screens.active.cursor.x + 1 +| value.value,
            ),
            .cursor_row_relative => self.terminal.setCursorPos(
                self.terminal.screens.active.cursor.y + 1 +| value.value,
                self.terminal.screens.active.cursor.x + 1,
            ),
            .cursor_style => self.terminal.setCursorStyle(value),
            .erase_display_below => self.terminal.eraseDisplay(.below, value),
            .erase_display_above => self.terminal.eraseDisplay(.above, value),
            .erase_display_complete => self.terminal.eraseDisplay(.complete, value),
            .erase_display_scrollback => self.terminal.eraseDisplay(.scrollback, value),
            .erase_display_scroll_complete => self.terminal.eraseDisplay(.scroll_complete, value),
            .erase_line_right => self.terminal.eraseLine(.right, value),
            .erase_line_left => self.terminal.eraseLine(.left, value),
            .erase_line_complete => self.terminal.eraseLine(.complete, value),
            .erase_line_right_unless_pending_wrap => self.terminal.eraseLine(.right_unless_pending_wrap, value),
            .delete_chars => self.terminal.deleteChars(value),
            .erase_chars => self.terminal.eraseChars(value),
            .insert_lines => self.terminal.insertLines(value),
            .insert_blanks => self.terminal.insertBlanks(value),
            .delete_lines => self.terminal.deleteLines(value),
            .scroll_up => try self.terminal.scrollUp(value),
            .scroll_down => self.terminal.scrollDown(value),
            .horizontal_tab => self.horizontalTab(value),
            .horizontal_tab_back => self.horizontalTabBack(value),
            .tab_clear_current => self.terminal.tabClear(.current),
            .tab_clear_all => self.terminal.tabClear(.all),
            .tab_set => self.terminal.tabSet(),
            .tab_reset => self.terminal.tabReset(),
            .set_mode => try self.setMode(value.mode, true),
            .reset_mode => try self.setMode(value.mode, false),
            .save_mode => self.terminal.modes.save(value.mode),
            .restore_mode => {
                const v = self.terminal.modes.restore(value.mode);
                try self.setMode(value.mode, v);
            },
            .top_and_bottom_margin => self.terminal.setTopAndBottomMargin(value.top_left, value.bottom_right),
            .left_and_right_margin => self.terminal.setLeftAndRightMargin(value.top_left, value.bottom_right),
            .left_and_right_margin_ambiguous => {
                if (self.terminal.modes.get(.enable_left_and_right_margin)) {
                    self.terminal.setLeftAndRightMargin(0, 0);
                } else {
                    self.terminal.saveCursor();
                }
            },
            .save_cursor => self.terminal.saveCursor(),
            .restore_cursor => self.terminal.restoreCursor(),
            .invoke_charset => self.terminal.invokeCharset(value.bank, value.charset, value.locking),
            .configure_charset => self.terminal.configureCharset(value.slot, value.charset),
            .set_attribute => switch (value) {
                .unknown => {},
                else => try self.terminal.setAttribute(value),
            },
            .protected_mode_off => self.terminal.setProtectedMode(.off),
            .protected_mode_iso => self.terminal.setProtectedMode(.iso),
            .protected_mode_dec => self.terminal.setProtectedMode(.dec),
            .mouse_shift_capture => self.terminal.flags.mouse_shift_capture = if (value) .true else .false,
            .kitty_keyboard_push => self.terminal.screens.active.kitty_keyboard.push(value.flags),
            .kitty_keyboard_pop => self.terminal.screens.active.kitty_keyboard.pop(@intCast(value)),
            .kitty_keyboard_set => self.terminal.screens.active.kitty_keyboard.set(.set, value.flags),
            .kitty_keyboard_set_or => self.terminal.screens.active.kitty_keyboard.set(.@"or", value.flags),
            .kitty_keyboard_set_not => self.terminal.screens.active.kitty_keyboard.set(.not, value.flags),
            .modify_key_format => {
                self.terminal.flags.modify_other_keys_2 = false;
                switch (value) {
                    .other_keys_numeric => self.terminal.flags.modify_other_keys_2 = true,
                    else => {},
                }
            },
            .active_status_display => self.terminal.status_display = value,
            .decaln => try self.terminal.decaln(),
            .full_reset => {
                self.terminal.fullReset();

                // Full reset clears grants
                self.kitty_clipboard_grants.deinit(self.terminal.gpa());
                self.kitty_clipboard_grants = .{};

                // Clear the progress bar
                self.progressReport(.{ .state = .remove });
            },
            .start_hyperlink => try self.terminal.screens.active.startHyperlink(value.uri, value.id),
            .end_hyperlink => self.terminal.screens.active.endHyperlink(),
            .semantic_prompt => try self.terminal.semanticPrompt(value),
            .mouse_shape => self.terminal.mouse_shape = value,
            .color_operation => self.colorOperation(
                &value.requests,
                value.terminator,
            ) catch |err| log.warn("error reporting OSC color err={}", .{err}),
            .kitty_color_report => self.kittyColorOperation(value) catch |err| {
                log.warn("error reporting Kitty colors err={}", .{err});
            },
            .kitty_clipboard => self.kittyClipboard(value) catch |err| {
                // Clipboard operations are external effects, not terminal
                // state; a failed transaction was already answered.
                log.warn("error handling kitty clipboard err={}", .{err});
            },

            // APC
            .apc_start => self.apc_handler.start(),
            .apc_put => self.apc_handler.feed(self.terminal.gpa(), value),
            .apc_put_slice => self.apc_handler.feedSlice(self.terminal.gpa(), value.bytes),
            .apc_end => self.apcEnd(value.terminated),

            // Effect-based handlers
            .bell => self.bell(),
            .show_desktop_notification => self.desktopNotification(value),
            .device_attributes => self.reportDeviceAttributes(value),
            .device_status => self.deviceStatus(value.request),
            .enquiry => self.reportEnquiry(),
            .kitty_keyboard_query => self.queryKittyKeyboard(),
            .request_mode => self.requestMode(value.mode),
            .request_mode_unknown => self.requestModeUnknown(value.mode, value.ansi),
            .size_report => self.reportSize(value),
            .window_title => try self.windowTitle(value.title),
            .report_pwd => try self.reportPwd(value.url),
            .progress_report => self.progressReport(value),
            .xtversion => self.reportXtversion(),
            .clipboard_contents => self.clipboardContents(
                value.kind,
                value.data,
                value.terminator,
            ) catch |err| {
                // Clipboard operations are external effects, not terminal state.
                log.warn("error handling clipboard operation err={}", .{err});
            },
            .kitty_dnd => self.kittyDnd(value) catch |err| {
                // Drag and drop is a self-contained subsystem: an OOM
                // updating its state or a failure writing a response
                // degrades it without corrupting terminal state, so we log.
                log.warn("error handling kitty dnd err={}", .{err});
            },

            .dcs_hook => try self.dcsHook(value),
            .dcs_put => try self.dcsPut(value),
            .dcs_unhook => try self.dcsUnhook(),

            // Have no terminal-modifying effect
            .title_push,
            .title_pop,
            => {},
        }
    }

    inline fn writePty(self: *Handler, data: []const u8) void {
        const func = self.effects.write_pty orelse return;
        func(self, data);
    }

    fn dcsHook(self: *Handler, value: Action.Value(.dcs_hook)) !void {
        var cmd = self.dcs_handler.hook(
            self.terminal.gpa(),
            value,
        ) orelse return;
        defer cmd.deinit();
        try self.dcsCommand(&cmd);
    }

    fn dcsPut(self: *Handler, value: u8) !void {
        var cmd = self.dcs_handler.put(value) orelse return;
        defer cmd.deinit();
        try self.dcsCommand(&cmd);
    }

    fn dcsUnhook(self: *Handler) !void {
        var cmd = self.dcs_handler.unhook() orelse return;
        defer cmd.deinit();
        try self.dcsCommand(&cmd);
    }

    fn dcsCommand(self: *Handler, cmd: *dcs.Command) !void {
        switch (cmd.*) {
            .decrqss => |request| {
                var response: [
                    dcs.Command.DECRQSS.max_response_bytes + 1
                ]u8 = undefined;
                const encoded = try request.encode(
                    self.terminal,
                    response[0 .. response.len - 1],
                );
                response[encoded.len] = 0;
                self.writePty(response[0..encoded.len :0]);
            },

            .xtgettcap => |*gettcap| {
                if (self.effects.write_pty == null) return;
                const map = comptime terminfo.ghostty.xtgettcapMap();
                while (gettcap.next()) |key| {
                    if (std.mem.eql(u8, key, encoded_tn_key)) {
                        self.writeTerminfoName();
                        continue;
                    }
                    self.writePty(map.get(key) orelse continue);
                }
            },

            .tmux => {},
        }
    }

    // Hex-encoded "TN", the XTGETTCAP key naming the terminfo entry.
    // The static map also carries this key with Ghostty's own name, so
    // it is intercepted before the lookup: an embedder that never
    // configured a name must not be reported as Ghostty's entry.
    const encoded_tn_key = &std.fmt.bytesToHex("TN", .upper);

    /// Answer an XTGETTCAP "TN" query from the configured terminfo name.
    /// Unset, empty, or over-long names leave the query unanswered.
    fn writeTerminfoName(self: *Handler) void {
        const name = self.terminfo_name orelse return;
        if (name.len == 0 or name.len > max_terminfo_name_bytes) return;

        // Fixed upper bound for an encoded "TN" reply calculated
        // at comptime from our max terminfo size.
        const max_tn_response_bytes =
            comptime "\x1bP1+r".len + encoded_tn_key.len + "=".len +
            (max_terminfo_name_bytes * 2) + "\x1b\\".len +
            1; // null terminator

        // Values are hex-encoded uppercase, matching the static map. The
        // buffer fits any name allowed above, so the print cannot fail.
        var buf: [max_tn_response_bytes]u8 = undefined;
        self.writePty(std.fmt.bufPrintZ(
            &buf,
            "\x1bP1+r" ++ encoded_tn_key ++ "={X}\x1b\\",
            .{name},
        ) catch unreachable);
    }

    fn bell(self: *Handler) void {
        const func = self.effects.bell orelse return;
        func(self);
    }

    fn desktopNotification(
        self: *Handler,
        notification: Action.ShowDesktopNotification,
    ) void {
        const func = self.effects.desktop_notification orelse return;
        func(self, notification);
    }

    fn progressReport(self: *Handler, report: osc.Command.ProgressReport) void {
        const func = self.effects.progress_report orelse return;
        func(self, report);
    }

    fn clipboardContents(
        self: *Handler,
        kind: u8,
        data: []const u8,
        terminator: osc.Terminator,
    ) !void {
        const location: clipboard.Location = switch (kind) {
            's' => .selection,
            'p' => .primary,
            else => .standard,
        };

        // OSC 52 uses a "?" payload to request the clipboard contents.
        if (data.len == 1 and data[0] == '?') {
            self.clipboardRead(location, terminator);
            return;
        }

        const func = self.effects.clipboard_write orelse return;

        // OSC 52 uses an empty payload to clear the selected clipboard.
        if (data.len == 0) {
            func(self, .{
                .location = location,
                .contents = &.{},
                .name = "",
                .granted = false,
                .can_remember = false,
                .reply_ctx = self,
                .reply_fn = &ignoreWriteReply,
            });
            return;
        }

        // Decode the base64 payload with the SIMD decoder (the same one
        // used for Kitty clipboard payloads) rather than the scalar std
        // implementation; clipboard payloads can be megabytes. The
        // Kitty clipboard spec governs OSC 52 base64 handling too: a
        // request with characters outside the base64 alphabet is
        // discarded entirely (never partially decoded), while a
        // missing-padding tail is tolerated since OSC 52 has no way
        // to report errors to the client.
        const alloc = self.terminal.gpa();
        const buf = try alloc.alloc(u8, simd.base64.maxLen(data));
        defer alloc.free(buf);
        const decoded = simd.base64.decodeStrict(data, buf, .optional) catch {
            log.warn("OSC 52 clipboard write is not valid base64, ignoring", .{});
            return;
        };

        const contents = [_]clipboard.Content{.{
            .mime = "text/plain",
            .data = decoded,
        }};
        func(self, .{
            .location = location,
            .contents = &contents,
            .name = "",
            .granted = false,
            .can_remember = false,
            .reply_ctx = self,
            .reply_fn = &ignoreWriteReply,
        });
    }

    /// Reply target for clipboard writes on protocols without a write
    /// acknowledgement (OSC 52, OSC 1337 Copy): the reply is accepted
    /// and discarded.
    fn ignoreWriteReply(_: *anyopaque, _: clipboard.Write.Result) void {}

    fn clipboardRead(
        self: *Handler,
        location: clipboard.Location,
        terminator: osc.Terminator,
    ) void {
        const func = self.effects.clipboard_read orelse return;

        var state: ClipboardReadState = .{
            .handler = self,
            .location = location,
            .terminator = terminator,
        };
        func(self, .{
            .location = location,
            .mimes = &.{"text/plain"},
            .list = false,
            .name = "",
            .granted = false,
            .can_remember = false,
            .reply_ctx = &state,
            .reply_fn = &ClipboardReadState.reply,
        });

        // The program is waiting on us, so a callback that returned
        // without a (successful) reply gets an empty clipboard rather
        // than silence.
        if (!state.replied) state.respond("") catch |err| {
            log.warn("error replying to clipboard read err={}", .{err});
        };
    }

    /// Reply state for one synchronous clipboard read. This lives on the
    /// clipboardRead stack frame, so it is only valid during the callback.
    const ClipboardReadState = struct {
        handler: *Handler,
        location: clipboard.Location,
        terminator: osc.Terminator,
        replied: bool = false,

        fn reply(ctx: *anyopaque, result: clipboard.Read.Result) void {
            const self: *ClipboardReadState = @ptrCast(@alignCast(ctx));
            if (self.replied) {
                log.warn("clipboard read replied more than once, ignoring", .{});
                return;
            }

            // OSC 52 carries a single text value.
            const data: []const u8 = switch (result) {
                .denied, .unsupported, .busy, .io_error => "",
                .success => |s| for (s.contents) |c| {
                    if (clipboard.isTextMime(c.mime)) break c.data;
                } else "",
            };

            self.respond(data) catch |err| {
                // Leave replied unset so clipboardRead falls back to the
                // empty reply.
                log.warn("error replying to clipboard read err={}", .{err});
                return;
            };
            self.replied = true;
        }

        fn respond(
            self: *ClipboardReadState,
            data: []const u8,
        ) error{ OutOfMemory, WriteFailed }!void {
            const handler = self.handler;
            var stack = std.heap.stackFallback(256, handler.terminal.gpa());
            const alloc = stack.get();

            var aw: std.Io.Writer.Allocating = .init(alloc);
            defer aw.deinit();
            const kind: u8 = switch (self.location) {
                .selection => 's',
                .primary => 'p',
                .standard, _ => 'c',
            };
            try aw.writer.print("\x1b]52;{c};", .{kind});
            try std.base64.standard.Encoder.encodeWriter(&aw.writer, data);
            try aw.writer.writeAll(self.terminator.string());

            const written = try aw.toOwnedSliceSentinel(0);
            defer alloc.free(written);
            handler.writePty(written);
        }
    };

    /// Handle one Kitty clipboard protocol (OSC 5522) packet.
    fn kittyClipboard(
        self: *Handler,
        v: Action.Value(.kitty_clipboard),
    ) error{OutOfMemory}!void {
        // Decode and validate the metadata.
        var arena: std.heap.ArenaAllocator = .init(self.terminal.gpa());
        defer arena.deinit();
        const meta = (kitty_clipboard.Metadata.parse(
            arena.allocator(),
            v.metadata,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidValue => {
                const state = self.kitty_clipboard_write orelse return;
                switch (kitty_clipboard.Metadata.operation(v.metadata) orelse return) {
                    .wdata, .walias => self.kittyClipboardFinish(
                        state,
                        .EINVAL,
                        v.terminator,
                    ),
                    .read, .write => {},
                }
                return;
            },
        }) orelse return;

        const payload = v.payload orelse "";
        switch (meta.op) {
            .read => try self.kittyClipboardRead(&meta, payload, v.terminator),
            .write => try self.kittyClipboardWriteBegin(&meta, v.terminator),
            .wdata => try self.kittyClipboardData(&meta, payload, v.terminator),
            .walias => try self.kittyClipboardAlias(&meta, payload, v.terminator),
        }
    }

    fn kittyClipboardRead(
        self: *Handler,
        meta: *const kitty_clipboard.Metadata,
        payload: []const u8,
        terminator: osc.Terminator,
    ) error{OutOfMemory}!void {
        // The payload is the requested MIME list. Kitty drops a read
        // request with an undecodable payload without any response.
        const alloc = self.terminal.gpa();
        const decoded = kitty_clipboard.Payload.init(
            alloc,
            payload,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Invalid => return,
        };
        defer decoded.deinit(alloc);
        if (!decoded.isValidUtf8()) return;

        // Without a clipboard_read effect nothing can serve the read.
        // EPERM is the protocol's denial so clients degrade gracefully.
        const func = self.effects.clipboard_read orelse {
            self.kittyClipboardRespond(&.{
                .op = .read,
                .status = .EPERM,
                .id = meta.id,
                .terminator = terminator,
            });
            return;
        };

        // The targets type ('.') asks for the listing of available
        // types rather than data. Requested types beyond the cap are
        // dropped and simply never served, which is how the protocol
        // reports an unavailable type anyway.
        var mimes_buf: [kitty_clipboard.max_read_mimes][]const u8 = undefined;
        const mimes, const list = mimes: {
            var targets = false;
            var len: usize = 0;
            var it = decoded.mimeIterator();
            while (it.next()) |mime| {
                if (std.mem.eql(u8, mime, kitty_clipboard.targets_mime)) {
                    targets = true;
                    continue;
                }
                if (len == mimes_buf.len) continue;
                mimes_buf[len] = mime;
                len += 1;
            }
            break :mimes .{ mimes_buf[0..len], targets };
        };

        // Per the spec a password without a name is no password. A
        // stored grant for it lets the embedder skip its prompt. A
        // prompt-exempt request never consults the grants: the
        // embedder serves it without a prompt anyway, and consuming a
        // one-time paste password on a listing would burn the grant
        // before the follow-up data read.
        const pw: []const u8 = if (meta.name.len > 0) meta.pw else "";
        const granted = !kitty_clipboard.readPromptExempt(mimes.len) and
            self.kitty_clipboard_grants.use(alloc, pw, .read);

        var state: KittyClipboardReadState = .{
            .handler = self,
            .primary = meta.loc == .primary,
            .id = meta.id,
            .pw = pw,
            .mimes = mimes,
            .list = list,
            .terminator = terminator,
        };
        func(self, .{
            .location = meta.loc,
            .mimes = mimes,
            .list = list,
            .name = meta.name,
            .granted = granted,
            .can_remember = pw.len > 0,
            .reply_ctx = &state,
            .reply_fn = &KittyClipboardReadState.reply,
        });

        // The program is waiting on us, so a callback that returned
        // without a reply is answered as a denial rather than silence.
        if (!state.replied) state.respondStatus(.EPERM);
    }

    /// Reply state for one synchronous Kitty clipboard read. This lives
    /// on the kittyClipboardRead stack frame, so it is only valid during
    /// the callback.
    const KittyClipboardReadState = struct {
        handler: *Handler,
        primary: bool,
        id: []const u8,

        /// The effective password, empty when the request had none.
        pw: []const u8,

        /// The requested types; only these are served from a reply.
        mimes: []const []const u8,
        list: bool,
        terminator: osc.Terminator,
        replied: bool = false,

        fn reply(ctx: *anyopaque, result: clipboard.Read.Result) void {
            const self: *KittyClipboardReadState = @ptrCast(@alignCast(ctx));
            if (self.replied) {
                log.warn("clipboard read replied more than once, ignoring", .{});
                return;
            }
            self.replied = true;

            const success = switch (result) {
                .denied => return self.respondStatus(.EPERM),
                .unsupported => return self.respondStatus(.ENOSYS),
                .busy => return self.respondStatus(.EBUSY),
                .io_error => return self.respondStatus(.EIO),
                .success => |s| s,
            };

            // Remembering is only offered when the request carried a
            // usable password.
            if (success.remember and self.pw.len > 0) {
                self.handler.kitty_clipboard_grants.grant(
                    self.handler.terminal.gpa(),
                    self.pw,
                    .read,
                    false,
                ) catch |err| {
                    log.warn("error recording clipboard grant err={}", .{err});
                };
            }

            self.respondSuccess(&success) catch |err| {
                log.warn("error replying to clipboard read err={}", .{err});
                self.respondStatus(.EIO);
            };
        }

        /// Answer with a single status packet.
        fn respondStatus(
            self: *const KittyClipboardReadState,
            status: kitty_clipboard.Status,
        ) void {
            self.handler.kittyClipboardRespond(&.{
                .op = .read,
                .status = status,
                .id = self.id,
                .terminator = self.terminator,
            });
        }

        /// Answer with the full success sequence (OK, listing, DATA
        /// chunks, DONE), serving only the requested representations
        /// in request order.
        fn respondSuccess(
            self: *const KittyClipboardReadState,
            success: *const clipboard.Read.Result.Success,
        ) error{ OutOfMemory, WriteFailed }!void {
            const handler = self.handler;
            if (handler.effects.write_pty == null) return;

            var served_buf: [kitty_clipboard.max_read_mimes]clipboard.Content = undefined;
            var served_len: usize = 0;
            for (self.mimes) |mime| {
                for (success.contents) |content| {
                    if (!std.mem.eql(u8, content.mime, mime)) continue;
                    served_buf[served_len] = content;
                    served_len += 1;
                    break;
                }
            }

            // Status packets fit on the stack; DATA packets carry the
            // clipboard contents and fall back to the heap.
            var stack = std.heap.stackFallback(1024, handler.terminal.gpa());
            const alloc = stack.get();
            var aw: std.Io.Writer.Allocating = .init(alloc);
            defer aw.deinit();
            try (kitty_clipboard.ReadSuccess{
                .primary = self.primary,
                .id = self.id,
                .list = self.list,
                .available = success.available,
                .contents = served_buf[0..served_len],
                .terminator = self.terminator,
            }).encode(&aw.writer);

            const written = try aw.toOwnedSliceSentinel(0);
            defer alloc.free(written);
            handler.writePty(written);
        }
    };

    fn kittyClipboardWriteBegin(
        self: *Handler,
        meta: *const kitty_clipboard.Metadata,
        terminator: osc.Terminator,
    ) error{OutOfMemory}!void {
        // A new write silently replaces any in-flight transaction.
        self.kittyClipboardAbort();

        // Without a clipboard_write effect a commit can never succeed,
        // so fail the transaction up front instead of spooling data
        // we'd only throw away. Later wdata packets are ignored.
        if (self.effects.clipboard_write == null) {
            self.kittyClipboardRespond(&.{
                .op = .write,
                .status = .ENOSYS,
                .id = meta.id,
                .terminator = terminator,
            });
            return;
        }

        // Setup our write state
        const alloc = self.terminal.gpa();
        const state = try alloc.create(kitty_clipboard.WriteState);
        errdefer alloc.destroy(state);
        state.* = try .init(alloc, meta, .{
            .max_size = self.kitty_clipboard_write_max_bytes,
        });
        self.kitty_clipboard_write = state;
    }

    fn kittyClipboardData(
        self: *Handler,
        meta: *const kitty_clipboard.Metadata,
        payload: []const u8,
        terminator: osc.Terminator,
    ) error{OutOfMemory}!void {
        // Data without a transaction is silently ignored.
        const state = self.kitty_clipboard_write orelse return;

        // A wdata packet without a MIME type commits the transaction.
        if (meta.mime.len == 0) return self.kittyClipboardCommit(
            state,
            terminator,
        );

        state.data(
            self.terminal.gpa(),
            meta,
            payload,
        ) catch |err| switch (err) {
            // Failing to spool matches kitty's EIO for a failed buffer
            // write.
            error.OutOfMemory => {
                self.kittyClipboardFinish(
                    state,
                    .EIO,
                    terminator,
                );
                return error.OutOfMemory;
            },

            // Data over the write limit aborts the transaction and is
            // reported to the client.
            error.TooLarge => self.kittyClipboardFinish(
                state,
                .EFBIG,
                terminator,
            ),

            // An invalid base64 payload stream aborts the transaction.
            error.Invalid => self.kittyClipboardFinish(
                state,
                .EINVAL,
                terminator,
            ),
        };
    }

    fn kittyClipboardAlias(
        self: *Handler,
        meta: *const kitty_clipboard.Metadata,
        payload: []const u8,
        terminator: osc.Terminator,
    ) error{OutOfMemory}!void {
        // Aliases without a transaction are silently ignored. Once a
        // transaction exists, a missing target MIME type is invalid and
        // aborts the transaction.
        const state = self.kitty_clipboard_write orelse return;
        if (meta.mime.len == 0) return self.kittyClipboardFinish(
            state,
            .EINVAL,
            terminator,
        );

        state.alias(
            self.terminal.gpa(),
            meta,
            payload,
        ) catch |err| switch (err) {
            error.OutOfMemory => {
                self.kittyClipboardFinish(
                    state,
                    .EIO,
                    terminator,
                );
                return error.OutOfMemory;
            },

            // An undecodable alias payload aborts the transaction.
            error.Invalid => self.kittyClipboardFinish(
                state,
                .EINVAL,
                terminator,
            ),
        };
    }

    fn kittyClipboardCommit(
        self: *Handler,
        state: *kitty_clipboard.WriteState,
        terminator: osc.Terminator,
    ) error{OutOfMemory}!void {
        const alloc = self.terminal.gpa();
        const committed = state.commit(alloc) catch |err| switch (err) {
            error.OutOfMemory => {
                self.kittyClipboardFinish(state, .EIO, terminator);
                return error.OutOfMemory;
            },

            // The last MIME type's payload stream was not correctly
            // padded, which aborts the transaction.
            error.Invalid => {
                self.kittyClipboardFinish(state, .EINVAL, terminator);
                return;
            },
        };
        defer committed.deinit(alloc);

        // The effect can't be null here (checked when the transaction
        // began) but if an embedder cleared it mid-transaction that's
        // ENOSYS.
        const func = self.effects.clipboard_write orelse {
            self.kittyClipboardFinish(state, .ENOSYS, terminator);
            return;
        };

        // Per the spec a password without a name is no password. A
        // stored grant for it lets the embedder skip its prompt.
        const pw: []const u8 = if (committed.name.len > 0) committed.pw else "";
        const granted = self.kitty_clipboard_grants.use(alloc, pw, .write);

        var reply_state: KittyClipboardWriteReplyState = .{
            .handler = self,
            .pw = pw,
        };
        func(self, .{
            .location = committed.loc,
            .contents = committed.contents,
            .name = committed.name,
            .granted = granted,
            .can_remember = pw.len > 0,
            .reply_ctx = &reply_state,
            .reply_fn = &KittyClipboardWriteReplyState.reply,
        });

        // The program is waiting on the commit status, so a callback
        // that returned without a reply is answered as a denial rather
        // than silence.
        self.kittyClipboardFinish(
            state,
            reply_state.status orelse .EPERM,
            terminator,
        );
    }

    /// Reply state for one synchronous Kitty clipboard write. This lives
    /// on the kittyClipboardCommit stack frame, so it is only valid
    /// during the callback.
    const KittyClipboardWriteReplyState = struct {
        handler: *Handler,

        /// The effective password, empty when the request had none.
        pw: []const u8,

        /// The replied commit status, mapped 1:1 from the reply result;
        /// null until the callback replies.
        status: ?kitty_clipboard.Status = null,

        fn reply(ctx: *anyopaque, result: clipboard.Write.Result) void {
            const self: *KittyClipboardWriteReplyState = @ptrCast(@alignCast(ctx));
            if (self.status != null) {
                log.warn("clipboard write replied more than once, ignoring", .{});
                return;
            }
            self.status = switch (result) {
                .denied => .EPERM,
                .unsupported => .ENOSYS,
                .busy => .EBUSY,
                .invalid_data => .EINVAL,
                .io_error => .EIO,
                .success => |success| status: {
                    // Remembering is only offered when the request
                    // carried a usable password.
                    if (success.remember and self.pw.len > 0) {
                        self.handler.kitty_clipboard_grants.grant(
                            self.handler.terminal.gpa(),
                            self.pw,
                            .write,
                            false,
                        ) catch |err| {
                            log.warn("error recording clipboard grant err={}", .{err});
                        };
                    }
                    break :status .DONE;
                },
            };
        }
    };

    /// Answer a write transaction with its final status and drop it.
    /// The id echoed is the one from the transaction's opening write
    /// packet, matching kitty.
    fn kittyClipboardFinish(
        self: *Handler,
        state: *const kitty_clipboard.WriteState,
        status: kitty_clipboard.Status,
        terminator: osc.Terminator,
    ) void {
        self.kittyClipboardRespond(&.{
            .op = .write,
            .status = status,
            .id = state.id,
            .terminator = terminator,
        });
        self.kittyClipboardAbort();
    }

    /// Drop any in-flight write transaction without responding.
    fn kittyClipboardAbort(self: *Handler) void {
        if (self.kitty_clipboard_write) |state| {
            const alloc = self.terminal.gpa();
            state.deinit(alloc);
            alloc.destroy(state);
            self.kitty_clipboard_write = null;
        }
    }

    /// Encode and write a single response packet. Unlike kitty, which
    /// always terminates responses with ST, we echo the terminator of
    /// the request being answered, matching our other OSC responses.
    fn kittyClipboardRespond(
        self: *Handler,
        response: *const kitty_clipboard.Response,
    ) void {
        if (self.effects.write_pty == null) return;

        // Our responses carry at most a status and the echoed id so
        // they virtually always fit on the stack.
        var stack = std.heap.stackFallback(1024, self.terminal.gpa());
        const alloc = stack.get();
        var aw: std.Io.Writer.Allocating = .init(alloc);
        defer aw.deinit();
        response.encode(&aw.writer) catch return;
        const resp = aw.toOwnedSliceSentinel(0) catch return;
        defer alloc.free(resp);
        self.writePty(resp);
    }

    /// Handle an OSC 72 drag and drop command.
    fn kittyDnd(
        self: *Handler,
        v: Action.KittyDnd,
    ) (Allocator.Error || std.Io.Writer.Error)!void {
        // Responses are usually small (queries, errors) but data
        // serving can produce many chunks, so fall back to the heap.
        var stack = std.heap.stackFallback(512, self.terminal.gpa());
        const response_alloc = stack.get();
        var aw: std.Io.Writer.Allocating = .init(response_alloc);
        defer aw.deinit();

        // The state is allocated on registration and owned by the
        // terminal, so it uses the terminal's allocator, not the
        // response's.
        const event = try kitty_dnd.handleCommand(
            &self.terminal.kitty_dnd,
            self.terminal.gpa(),
            &aw.writer,
            v,
        );

        if (aw.written().len > 0) {
            const written = aw.toOwnedSliceSentinel(0) catch return;
            defer response_alloc.free(written);
            self.writePty(written);
        }

        if (event) |ev| {
            const func = self.effects.drag_and_drop orelse return;
            func(self, ev);
        }
    }

    fn reportDeviceAttributes(self: *Handler, req: device_attributes.Req) void {
        const func = self.effects.device_attributes orelse return;
        const attrs = func(self);

        var stack = std.heap.stackFallback(128, self.terminal.gpa());
        const alloc = stack.get();

        var aw: std.Io.Writer.Allocating = .init(alloc);
        defer aw.deinit();

        attrs.encode(req, &aw.writer) catch return;

        const written = aw.toOwnedSliceSentinel(0) catch return;
        defer alloc.free(written);
        self.writePty(written);
    }

    fn deviceStatus(self: *Handler, req: device_status.Request) void {
        switch (req) {
            .operating_status => self.writePty("\x1B[0n"),

            .cursor_position => {
                const pos: struct {
                    x: usize,
                    y: usize,
                } = if (self.terminal.modes.get(.origin)) .{
                    .x = self.terminal.screens.active.cursor.x -| self.terminal.scrolling_region.left,
                    .y = self.terminal.screens.active.cursor.y -| self.terminal.scrolling_region.top,
                } else .{
                    .x = self.terminal.screens.active.cursor.x,
                    .y = self.terminal.screens.active.cursor.y,
                };

                var buf: [64]u8 = undefined;
                const resp = std.fmt.bufPrintZ(&buf, "\x1B[{};{}R", .{
                    pos.y + 1,
                    pos.x + 1,
                }) catch return;
                self.writePty(resp);
            },

            .color_scheme => {
                const func = self.effects.color_scheme orelse return;
                const scheme = func(self) orelse return;
                var buf: [device_status.max_color_scheme_report_encode_size + 1]u8 = undefined;
                var writer: std.Io.Writer = .fixed(buf[0..device_status.max_color_scheme_report_encode_size]);
                device_status.encodeColorSchemeReport(&writer, scheme) catch return;
                buf[writer.end] = 0;
                self.writePty(buf[0..writer.end :0]);
            },

            .visibility => self.sendVisibilityReport(),
        }
    }

    fn sendVisibilityReport(self: *Handler) void {
        const write_pty = self.effects.write_pty orelse return;

        var buf: [device_status.max_visibility_report_encode_size + 1]u8 = undefined;
        var writer: std.Io.Writer = .fixed(buf[0..device_status.max_visibility_report_encode_size]);
        device_status.encodeVisibilityReport(
            &writer,
            if (self.terminal.flags.visible) .potentially_visible else .not_visible,
        ) catch return;
        buf[writer.end] = 0;
        write_pty(self, buf[0..writer.end :0]);
    }

    fn reportEnquiry(self: *Handler) void {
        const func = self.effects.enquiry orelse return;
        const response = func(self);
        if (response.len == 0) return;
        var buf: [256]u8 = undefined;
        if (response.len >= buf.len) return;
        @memcpy(buf[0..response.len], response);
        buf[response.len] = 0;
        self.writePty(buf[0..response.len :0]);
    }

    fn reportXtversion(self: *Handler) void {
        const version = if (self.effects.xtversion) |func| func(self) else "";
        var buf: [288]u8 = undefined;
        const resp = std.fmt.bufPrintZ(
            &buf,
            "\x1BP>|{s}\x1B\\",
            .{if (version.len > 0) version else "libghostty"},
        ) catch return;
        self.writePty(resp);
    }

    fn reportSize(self: *Handler, style: csi.SizeReportStyle) void {
        // Almost all size reports will fit in 256 bytes so try that
        // on the stack before falling back to a heap allocation.
        var stack = std.heap.stackFallback(
            256,
            self.terminal.gpa(),
        );
        const alloc = stack.get();

        // Allocating writing to accumulate the response.
        var aw: std.Io.Writer.Allocating = .init(alloc);
        defer aw.deinit();

        // Build the response.
        switch (style) {
            .csi_21_t => {
                if (!self.title_report) return;
                const title = self.terminal.getTitle() orelse "";
                aw.writer.print("\x1b]l{s}\x1b\\", .{title}) catch return;
            },

            .csi_14_t, .csi_16_t, .csi_18_t => {
                const get_size = self.effects.size orelse return;
                const s = get_size(self) orelse return;
                const report_style: size_report.Style = switch (style) {
                    .csi_14_t => .csi_14_t,
                    .csi_16_t => .csi_16_t,
                    .csi_18_t => .csi_18_t,
                    .csi_21_t => unreachable,
                };
                size_report.encode(
                    &aw.writer,
                    report_style,
                    s,
                ) catch |err| {
                    log.warn("error encoding size report err={}", .{err});
                    return;
                };
            },
        }

        const resp = aw.toOwnedSliceSentinel(0) catch return;
        defer alloc.free(resp);
        self.writePty(resp);
    }

    fn reportMode2048(self: *Handler) void {
        const get_size = self.effects.size orelse return;
        const current = get_size(self) orelse return;

        var buf: [128]u8 = undefined;
        var writer: std.Io.Writer = .fixed(buf[0 .. buf.len - 1]);
        size_report.encode(&writer, .mode_2048, current) catch return;
        buf[writer.end] = 0;
        self.writePty(buf[0..writer.end :0]);
    }

    fn windowTitle(self: *Handler, title_raw: []const u8) !void {
        // Prevent DoS attacks by limiting title length.
        const max_title_len = 1024;
        const title = if (title_raw.len > max_title_len) title: {
            log.warn("title length {d} exceeds max length {d}, truncating", .{
                title_raw.len,
                max_title_len,
            });
            break :title title_raw[0..max_title_len];
        } else title_raw;

        try self.terminal.setTitle(title);

        const func = self.effects.title_changed orelse return;
        func(self);
    }

    fn reportPwd(self: *Handler, url_raw: []const u8) !void {
        // Prevent DoS attacks by limiting url length. Headroom for
        // Linux PATH_MAX (4096) plus URI scheme/host and percent-encoding.
        const max_url_len = 4096;
        const url = if (url_raw.len > max_url_len) url: {
            log.warn("pwd url length {d} exceeds max length {d}, truncating", .{
                url_raw.len,
                max_url_len,
            });
            break :url url_raw[0..max_url_len];
        } else url_raw;

        // We store the raw payload unparsed. Embedders read it via
        // getPwd() and are responsible for decoding any URI scheme.
        try self.terminal.setPwd(url);

        const func = self.effects.pwd_changed orelse return;
        func(self);
    }

    fn requestMode(self: *Handler, mode: modes.Mode) void {
        var report = self.terminal.modes.getReport(.fromMode(mode));

        // Kitty paste events (mode 5522) can't work without a clipboard
        // read effect, so if that isn't set mark it as unrecognized.
        if (mode == .kitty_paste_events and
            self.effects.clipboard_read == null)
        {
            report.state = .not_recognized;
        }

        self.sendModeReport(report);
    }

    fn requestModeUnknown(self: *Handler, mode_raw: u16, ansi: bool) void {
        const report = self.terminal.modes.getReport(.{
            .value = @truncate(mode_raw),
            .ansi = ansi,
        });
        self.sendModeReport(report);
    }

    fn sendModeReport(self: *Handler, report: modes.Report) void {
        var buf: [modes.Report.max_size + 1]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        report.encode(&writer) catch |err| {
            log.warn("error encoding mode report err={}", .{err});
            return;
        };
        const len = writer.buffered().len;
        buf[len] = 0;
        self.writePty(buf[0..len :0]);
    }

    fn queryKittyKeyboard(self: *Handler) void {
        // Max response is "\x1b[?31u\x00" (7 bytes): the flags are a u5 (max 31).
        var buf: [32]u8 = undefined;
        const resp = std.fmt.bufPrintZ(&buf, "\x1b[?{}u", .{
            self.terminal.screens.active.kitty_keyboard.current().int(),
        }) catch return;
        self.writePty(resp);
    }

    inline fn horizontalTab(self: *Handler, count: u16) void {
        for (0..count) |_| {
            const x = self.terminal.screens.active.cursor.x;
            self.terminal.horizontalTab();
            if (x == self.terminal.screens.active.cursor.x) break;
        }
    }

    inline fn horizontalTabBack(self: *Handler, count: u16) void {
        for (0..count) |_| {
            const x = self.terminal.screens.active.cursor.x;
            self.terminal.horizontalTabBack();
            if (x == self.terminal.screens.active.cursor.x) break;
        }
    }

    fn setMode(self: *Handler, mode: modes.Mode, enabled: bool) !void {
        // Set the mode on the terminal
        self.terminal.modes.set(mode, enabled);

        // Some modes require additional processing
        switch (mode) {
            .autorepeat,
            .reverse_colors,
            => {},

            .origin => self.terminal.setCursorPos(1, 1),

            .enable_left_and_right_margin => if (!enabled) {
                self.terminal.scrolling_region.left = 0;
                self.terminal.scrolling_region.right = self.terminal.cols - 1;
            },

            .alt_screen_legacy => try self.terminal.switchScreenMode(.@"47", enabled),
            .alt_screen => try self.terminal.switchScreenMode(.@"1047", enabled),
            .alt_screen_save_cursor_clear_enter => try self.terminal.switchScreenMode(.@"1049", enabled),

            .save_cursor => if (enabled) {
                self.terminal.saveCursor();
            } else {
                self.terminal.restoreCursor();
            },

            .enable_mode_3 => {},

            .@"132_column" => try self.terminal.deccolm(
                self.terminal.screens.active.alloc,
                if (enabled) .@"132_cols" else .@"80_cols",
            ),

            .synchronized_output,
            .linefeed,
            .focus_event,
            => {},

            // Enabling mode 2048 reports already-committed pixel geometry.
            // Waiting for the next resize leaves late-enabling clients without
            // the dimensions they need for their first image frame.
            .in_band_size_reports => if (enabled) self.reportMode2048(),

            .report_visibility => if (enabled) self.sendVisibilityReport(),

            .mouse_event_x10 => {
                if (enabled) {
                    self.terminal.flags.mouse_event = .x10;
                } else {
                    self.terminal.flags.mouse_event = .none;
                }
            },
            .mouse_event_normal => {
                if (enabled) {
                    self.terminal.flags.mouse_event = .normal;
                } else {
                    self.terminal.flags.mouse_event = .none;
                }
            },
            .mouse_event_button => {
                if (enabled) {
                    self.terminal.flags.mouse_event = .button;
                } else {
                    self.terminal.flags.mouse_event = .none;
                }
            },
            .mouse_event_any => {
                if (enabled) {
                    self.terminal.flags.mouse_event = .any;
                } else {
                    self.terminal.flags.mouse_event = .none;
                }
            },

            .mouse_format_utf8 => self.terminal.flags.mouse_format = if (enabled) .utf8 else .x10,
            .mouse_format_sgr => self.terminal.flags.mouse_format = if (enabled) .sgr else .x10,
            .mouse_format_urxvt => self.terminal.flags.mouse_format = if (enabled) .urxvt else .x10,
            .mouse_format_sgr_pixels => self.terminal.flags.mouse_format = if (enabled) .sgr_pixels else .x10,

            else => {},
        }
    }

    fn colorOperation(
        self: *Handler,
        requests: *const osc_color.List,
        terminator: osc.Terminator,
    ) !void {
        if (requests.count() == 0) return;

        var stack = std.heap.stackFallback(1024, self.terminal.gpa());
        const alloc = stack.get();
        var response: std.Io.Writer.Allocating = .init(alloc);
        defer response.deinit();
        const writer = &response.writer;

        var it = requests.constIterator(0);
        while (it.next()) |req| {
            switch (req.*) {
                .set => |set| {
                    switch (set.target) {
                        .palette => |i| {
                            self.terminal.flags.dirty.palette = true;
                            self.terminal.colors.palette.set(i, set.color);
                        },
                        .dynamic => |dynamic| switch (dynamic) {
                            .foreground => self.terminal.colors.foreground.set(set.color),
                            .background => self.terminal.colors.background.set(set.color),
                            .cursor => self.terminal.colors.cursor.set(set.color),
                            .pointer_foreground,
                            .pointer_background,
                            .tektronix_foreground,
                            .tektronix_background,
                            .highlight_background,
                            .tektronix_cursor,
                            .highlight_foreground,
                            => {},
                        },
                        .special => {},
                    }
                },

                .reset => |target| switch (target) {
                    .palette => |i| {
                        self.terminal.flags.dirty.palette = true;
                        self.terminal.colors.palette.reset(i);
                    },
                    .dynamic => |dynamic| switch (dynamic) {
                        .foreground => self.terminal.colors.foreground.reset(),
                        .background => self.terminal.colors.background.reset(),
                        .cursor => self.terminal.colors.cursor.reset(),
                        .pointer_foreground,
                        .pointer_background,
                        .tektronix_foreground,
                        .tektronix_background,
                        .highlight_background,
                        .tektronix_cursor,
                        .highlight_foreground,
                        => {},
                    },
                    .special => {},
                },

                .reset_palette => {
                    const mask = &self.terminal.colors.palette.mask;
                    var mask_it = mask.iterator(.{});
                    while (mask_it.next()) |i| {
                        self.terminal.flags.dirty.palette = true;
                        self.terminal.colors.palette.reset(@intCast(i));
                    }
                    mask.* = .initEmpty();
                },

                .query => |target| {
                    if (self.effects.write_pty == null) continue;
                    const c = self.terminal.colorForXterm(target) orelse continue;
                    try writeXtermColorReport(writer, target, c, terminator);
                },

                .reset_special => {},
            }
        }

        if (response.written().len > 0) {
            const resp = try response.toOwnedSliceSentinel(0);
            defer alloc.free(resp);
            self.writePty(resp);
        }
    }

    fn writeXtermColorReport(
        writer: *std.Io.Writer,
        target: osc_color.Target,
        c: color.RGB,
        terminator: osc.Terminator,
    ) !void {
        switch (target) {
            .palette => |i| {
                try writer.print("\x1b]4;{d};", .{i});
                try c.encodeRgb16(writer);
                try writer.writeAll(terminator.string());
            },
            .dynamic => |dynamic| switch (dynamic) {
                .foreground,
                .background,
                .cursor,
                => {
                    try writer.print("\x1b]{d};", .{@intFromEnum(dynamic)});
                    try c.encodeRgb16(writer);
                    try writer.writeAll(terminator.string());
                },
                .pointer_foreground,
                .pointer_background,
                .tektronix_foreground,
                .tektronix_background,
                .highlight_background,
                .tektronix_cursor,
                .highlight_foreground,
                => {},
            },
            .special => {},
        }
    }

    fn kittyColorOperation(
        self: *Handler,
        request: kitty_color.OSC,
    ) !void {
        var stack = std.heap.stackFallback(1024, self.terminal.gpa());
        const alloc = stack.get();
        var response: std.Io.Writer.Allocating = .init(alloc);
        defer response.deinit();
        const writer = &response.writer;

        for (request.list.items) |item| {
            switch (item) {
                .set => |v| switch (v.key) {
                    .palette => |palette| {
                        self.terminal.flags.dirty.palette = true;
                        self.terminal.colors.palette.set(palette, v.color);
                    },
                    .special => |special| switch (special) {
                        .foreground => self.terminal.colors.foreground.set(v.color),
                        .background => self.terminal.colors.background.set(v.color),
                        .cursor => self.terminal.colors.cursor.set(v.color),
                        else => {},
                    },
                },
                .reset => |key| switch (key) {
                    .palette => |palette| {
                        self.terminal.flags.dirty.palette = true;
                        self.terminal.colors.palette.reset(palette);
                    },
                    .special => |special| switch (special) {
                        .foreground => self.terminal.colors.foreground.reset(),
                        .background => self.terminal.colors.background.reset(),
                        .cursor => self.terminal.colors.cursor.reset(),
                        else => {},
                    },
                },
                .query => |key| {
                    if (self.effects.write_pty == null) continue;
                    const c = self.terminal.colorForKitty(key) orelse {
                        if (!key.hasTerminalQueryColor()) continue;
                        if (response.written().len == 0) try writer.writeAll("\x1b]21");
                        try writer.print(";{f}=", .{key});
                        continue;
                    };

                    if (response.written().len == 0) try writer.writeAll("\x1b]21");
                    try writer.print(";{f}=", .{key});
                    try c.encodeRgb8(writer);
                },
            }
        }

        if (response.written().len > 0) {
            try writer.writeAll(request.terminator.string());
            const resp = try response.toOwnedSliceSentinel(0);
            defer alloc.free(resp);
            self.writePty(resp);
        }
    }

    fn apcEnd(self: *Handler, terminated: bool) void {
        const io = self.terminal.io();
        const alloc = self.terminal.gpa();
        var result = self.apc_handler.end() orelse return;
        defer result.deinit(alloc);
        switch (result) {
            .unknown => |*unknown| {
                if (terminated) self.unknownSequence(.{ .apc = .{
                    .content = unknown.content,
                    .truncated = unknown.truncated,
                } });
            },
            .kitty => |*kitty_cmd| if (comptime build_options.kitty_graphics) {
                if (self.terminal.kittyGraphics(
                    io,
                    alloc,
                    kitty_cmd,
                )) |resp| resp: {
                    // Don't waste time encoding if we can't write responses
                    // anyways.
                    if (self.effects.write_pty == null) break :resp;

                    // Encode and write the response if we have one.
                    var buf: [1024]u8 = undefined;
                    var writer: std.Io.Writer = .fixed(&buf);
                    resp.encode(&writer) catch return;
                    writer.writeByte(0) catch return;
                    const final = writer.buffered();
                    if (final.len > 3) self.writePty(final[0 .. final.len - 1 :0]);
                }
            },

            .glyph => |*glyph_req| if (comptime build_options.glyph_protocol) {
                const resp = self.terminal.glyphProtocol(alloc, glyph_req);
                if (resp) |r| resp_block: {
                    // Don't waste time encoding if we can't write responses
                    // anyways.
                    if (self.effects.write_pty == null) break :resp_block;

                    // Glyph responses are short and bounded by the protocol
                    // fields we emit, so this matches the Kitty response
                    // buffer size above with ample headroom.
                    var buf: [apc.glyph.Response.max_wire_bytes]u8 = undefined;
                    var writer: std.Io.Writer = .fixed(&buf);
                    r.formatWire(&writer) catch return;
                    writer.writeByte(0) catch return;
                    const final = writer.buffered();
                    self.writePty(final[0 .. final.len - 1 :0]);
                }
            },
        }
    }
};

/// A writer that delivers everything through the write_pty effect:
/// the buffer as it fills, and data that doesn't fit it directly.
/// Never fails, since the effect can't.
const PtyWriter = struct {
    handler: *Handler,
    writer: std.Io.Writer,

    fn init(handler: *Handler, buffer: []u8) PtyWriter {
        return .{
            .handler = handler,
            .writer = .{
                .vtable = &.{ .drain = drain },
                .buffer = buffer,
            },
        };
    }

    fn drain(
        w: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        const self: *PtyWriter = @alignCast(@fieldParentPtr("writer", w));

        // Buffered bytes go first to keep the order.
        if (w.end > 0) {
            self.handler.writePty(w.buffer[0..w.end]);
            w.end = 0;
        }

        var consumed: usize = 0;
        for (data[0 .. data.len - 1]) |slice| {
            if (slice.len > 0) self.handler.writePty(slice);
            consumed += slice.len;
        }

        const pattern = data[data.len - 1];
        for (0..splat) |_| {
            if (pattern.len > 0) self.handler.writePty(pattern);
            consumed += pattern.len;
        }
        return consumed;
    }
};

test "resize clears synchronized output on unchanged cell dimensions" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();

    t.modes.set(.synchronized_output, true);
    try s.handler.resize(.{
        .cols = 80,
        .rows = 24,
        .cell_size_px = .{ .width = 9, .height = 18 },
    });

    try testing.expect(!t.modes.get(.synchronized_output));
    try testing.expectEqual(@as(u32, 720), t.width_px);
    try testing.expectEqual(@as(u32, 432), t.height_px);
}

test "unknown APC effect callback" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var count: usize = 0;
        var content: [16]u8 = undefined;
        var content_len: usize = undefined;
        var truncated: bool = undefined;

        fn unknownSequence(_: *Handler, value: Handler.UnknownSequence) void {
            switch (value) {
                .apc => |apc_value| {
                    content_len = apc_value.content.len;
                    @memcpy(content[0..apc_value.content.len], apc_value.content);
                    truncated = apc_value.truncated;
                },
            }
            count += 1;
        }
    };
    S.count = 0;

    var handler: Handler = .init(&t);
    handler.unknown_sequence = &S.unknownSequence;
    handler.apc_handler.unknown_max_bytes = 8;
    var s: Stream = .init(.{
        .allocator = testing.allocator,
        .handler = handler,
    });
    defer s.deinit();

    // Unknown OSC commands retain their legacy behavior and are ignored.
    s.nextSlice("\x1B]999;abcdef\x07");
    s.nextSlice("\x1B_abcd;payload\x1B\\");

    try testing.expectEqual(@as(usize, 1), S.count);
    try testing.expectEqualStrings("abcd;pay", S.content[0..S.content_len]);
    try testing.expect(S.truncated);

    // Aborted unknown APCs are suppressed.
    s.nextSlice("\x1B_Xpayload\x18");
    try testing.expectEqual(@as(usize, 1), S.count);
}

test "resize reports mode 2048 geometry" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var response: [128]u8 = undefined;
        var response_len: usize = 0;

        fn writePty(_: *Handler, data: []const u8) void {
            @memcpy(response[0..data.len], data);
            response_len = data.len;
        }
    };
    S.response_len = 0;

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    t.modes.set(.in_band_size_reports, true);
    try s.handler.resize(.{
        .cols = 100,
        .rows = 40,
        .cell_size_px = .{ .width = 9, .height = 18 },
    });

    try testing.expectEqualStrings(
        "\x1B[48;40;100;720;900t",
        S.response[0..S.response_len],
    );
}

test "resize suppresses mode 2048 reports" {
    const S = struct {
        var calls: usize = 0;

        fn writePty(_: *Handler, _: []const u8) void {
            calls += 1;
        }
    };
    S.calls = 0;

    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);
    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    // Disabled mode suppresses a report even with pixels and a callback.
    try s.handler.resize(.{
        .cols = 80,
        .rows = 24,
        .cell_size_px = .{ .width = 9, .height = 18 },
    });
    try testing.expectEqual(@as(usize, 0), S.calls);

    // Missing pixel geometry suppresses a report even with the mode enabled.
    t.modes.set(.in_band_size_reports, true);
    try s.handler.resize(.{ .cols = 80, .rows = 24 });
    try testing.expectEqual(@as(usize, 0), S.calls);

    // A read-only stream has no write effect and remains successful.
    var readonly_terminal: Terminal = try .init(
        testing.io,
        testing.allocator,
        .{ .cols = 80, .rows = 24 },
    );
    defer readonly_terminal.deinit(testing.allocator);
    readonly_terminal.modes.set(.in_band_size_reports, true);
    var readonly_stream: Stream = .init(.{
        .allocator = testing.allocator,
        .handler = .init(&readonly_terminal),
    });
    defer readonly_stream.deinit();
    try readonly_stream.handler.resize(.{
        .cols = 80,
        .rows = 24,
        .cell_size_px = .{ .width = 9, .height = 18 },
    });
    try testing.expectEqual(@as(usize, 0), S.calls);
}

test "resize failure preserves terminal state and does not write" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const alloc = failing.allocator();
    var t: Terminal = try .init(testing.io, alloc, .{ .cols = 10, .rows = 1 });
    defer t.deinit(alloc);

    const S = struct {
        var called: bool = false;

        fn writePty(_: *Handler, _: []const u8) void {
            called = true;
        }
    };
    S.called = false;

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    var s: Stream = .init(.{ .allocator = alloc, .handler = handler });
    defer s.deinit();

    t.modes.set(.synchronized_output, true);
    t.modes.set(.in_band_size_reports, true);
    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, s.handler.resize(.{
        .cols = 513,
        .rows = 1,
        .cell_size_px = .{ .width = 9, .height = 18 },
    }));

    try testing.expect(t.modes.get(.synchronized_output));
    try testing.expect(!S.called);
    try testing.expectEqual(@as(@TypeOf(t.cols), 10), t.cols);
    try testing.expectEqual(@as(u32, 0), t.width_px);
    try testing.expectEqual(@as(u32, 0), t.height_px);
}

test "resize effects do not change canonical terminal state" {
    var authoritative: Terminal = try .init(
        testing.io,
        testing.allocator,
        .{ .cols = 10, .rows = 5 },
    );
    defer authoritative.deinit(testing.allocator);
    var readonly: Terminal = try .init(
        testing.io,
        testing.allocator,
        .{ .cols = 10, .rows = 5 },
    );
    defer readonly.deinit(testing.allocator);

    const S = struct {
        fn writePty(_: *Handler, _: []const u8) void {}
    };
    var authoritative_handler: Handler = .init(&authoritative);
    authoritative_handler.effects.write_pty = &S.writePty;
    var authoritative_stream: Stream = .init(.{
        .allocator = testing.allocator,
        .handler = authoritative_handler,
    });
    defer authoritative_stream.deinit();
    var readonly_stream: Stream = .init(.{
        .allocator = testing.allocator,
        .handler = .init(&readonly),
    });
    defer readonly_stream.deinit();

    authoritative.modes.set(.in_band_size_reports, true);
    readonly.modes.set(.in_band_size_reports, true);
    const value: Terminal.Resize = .{
        .cols = 20,
        .rows = 10,
        .cell_size_px = .{ .width = 9, .height = 18 },
    };
    try authoritative_stream.handler.resize(value);
    try readonly_stream.handler.resize(value);

    try testing.expectEqual(authoritative.cols, readonly.cols);
    try testing.expectEqual(authoritative.rows, readonly.rows);
    try testing.expectEqual(authoritative.width_px, readonly.width_px);
    try testing.expectEqual(authoritative.height_px, readonly.height_px);
    try testing.expect(std.meta.eql(authoritative.modes, readonly.modes));
    try testing.expect(std.meta.eql(
        authoritative.scrolling_region,
        readonly.scrolling_region,
    ));
}

test "basic print" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();

    s.nextSlice("Hello");
    try testing.expectEqual(@as(usize, 5), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);

    const str = try t.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("Hello", str);
}

test "semantic failure is sticky while processing continues" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const alloc = failing.allocator();
    var t: Terminal = try .init(testing.io, alloc, .{ .cols = 10, .rows = 2 });
    defer t.deinit(alloc);

    var s: Stream = .init(.{ .allocator = alloc, .handler = .init(&t) });
    defer s.deinit();
    try testing.expect(!s.handler.semantic_failure);

    // Setting the title is a terminal-owned semantic update. Force its
    // allocation to fail at the central vtFallible boundary.
    failing.fail_index = failing.alloc_index;
    s.nextSlice("\x1B]2;unavailable\x1B\\");
    try testing.expect(s.handler.semantic_failure);

    // Later input and RIS remain best-effort and never clear the diagnostic.
    failing.fail_index = std.math.maxInt(usize);
    s.nextSlice("ignored");
    s.nextSlice("\x1Bc");
    s.nextSlice("OK");
    try testing.expect(s.handler.semantic_failure);

    const str = try t.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("OK", str);

    // A new execution root starts without inheriting the diagnostic.
    var fresh = Handler.init(&t);
    defer fresh.deinit();
    try testing.expect(!fresh.semantic_failure);
}

test "cursor movement" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();

    // Move cursor using escape sequences
    s.nextSlice("Hello\x1B[1;1H");
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);

    // Move to position 2,3
    s.nextSlice("\x1B[2;3H");
    try testing.expectEqual(@as(usize, 2), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.y);
}

test "erase operations" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 20, .rows = 10 });
    defer t.deinit(testing.allocator);

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();

    // Print some text
    s.nextSlice("Hello World");
    try testing.expectEqual(@as(usize, 11), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);

    // Move cursor to position 1,6 and erase from cursor to end of line
    s.nextSlice("\x1B[1;6H");
    s.nextSlice("\x1B[K");

    const str = try t.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("Hello", str);
}

test "tabs" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 10 });
    defer t.deinit(testing.allocator);

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();

    s.nextSlice("A\tB");
    try testing.expectEqual(@as(usize, 9), t.screens.active.cursor.x);

    const str = try t.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("A       B", str);
}

test "modes" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();

    // Test wraparound mode
    try testing.expect(t.modes.get(.wraparound));
    s.nextSlice("\x1B[?7l"); // Disable wraparound
    try testing.expect(!t.modes.get(.wraparound));
    s.nextSlice("\x1B[?7h"); // Enable wraparound
    try testing.expect(t.modes.get(.wraparound));
}

test "scrolling regions" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();

    // Set scrolling region from line 5 to 20
    s.nextSlice("\x1B[5;20r");
    try testing.expectEqual(@as(usize, 4), t.scrolling_region.top);
    try testing.expectEqual(@as(usize, 19), t.scrolling_region.bottom);
    try testing.expectEqual(@as(usize, 0), t.scrolling_region.left);
    try testing.expectEqual(@as(usize, 79), t.scrolling_region.right);
}

test "charsets" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();

    // Configure G0 as DEC special graphics
    s.nextSlice("\x1B(0");
    s.nextSlice("`"); // Should print diamond character

    const str = try t.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("◆", str);
}

test "alt screen" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit(testing.allocator);

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();

    // Write to primary screen
    s.nextSlice("Primary");
    try testing.expectEqual(.primary, t.screens.active_key);

    // Switch to alt screen
    s.nextSlice("\x1B[?1049h");
    try testing.expectEqual(.alternate, t.screens.active_key);

    // Write to alt screen
    s.nextSlice("Alt");

    // Switch back to primary
    s.nextSlice("\x1B[?1049l");
    try testing.expectEqual(.primary, t.screens.active_key);

    const str = try t.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("Primary", str);
}

test "cursor save and restore" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();

    // Move cursor to 10,15
    s.nextSlice("\x1B[10;15H");
    try testing.expectEqual(@as(usize, 14), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 9), t.screens.active.cursor.y);

    // Save cursor
    s.nextSlice("\x1B7");

    // Move cursor elsewhere
    s.nextSlice("\x1B[1;1H");
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);

    // Restore cursor
    s.nextSlice("\x1B8");
    try testing.expectEqual(@as(usize, 14), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 9), t.screens.active.cursor.y);
}

test "attributes" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();

    // Set bold and write text
    s.nextSlice("\x1B[1mBold\x1B[0m");

    // Verify we can write attributes - just check the string was written
    const str = try t.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("Bold", str);
}

test "DECRQSS responses" {
    var t: Terminal = try .init(
        testing.io,
        testing.allocator,
        .{ .cols = 80, .rows = 24 },
    );
    defer t.deinit(testing.allocator);

    const S = struct {
        var response: [dcs.Command.DECRQSS.max_response_bytes]u8 = undefined;
        var response_len: usize = 0;
        var calls: usize = 0;

        fn reset() void {
            response_len = 0;
            calls = 0;
        }

        fn writePty(_: *Handler, data: []const u8) void {
            @memcpy(response[0..data.len], data);
            response_len = data.len;
            calls += 1;
        }

        fn expectResponse(expected: []const u8) !void {
            try testing.expectEqual(@as(usize, 1), calls);
            try testing.expectEqualStrings(
                expected,
                response[0..response_len],
            );
            reset();
        }
    };
    S.reset();

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    // SGR
    s.nextSlice("\x1B[1m\x1BP$qm\x1B\\");
    try S.expectResponse("\x1BP1$r0;1m\x1B\\");

    // Overline
    s.nextSlice("\x1B[0;53m\x1BP$qm\x1B\\");
    try S.expectResponse("\x1BP1$r0;53m\x1B\\");

    // Requests larger than the parser's fixed request buffer are ignored,
    // and the next DCS command must still be processed normally.
    s.nextSlice("\x1BP$qfoo\x1B\\");
    try testing.expectEqual(@as(usize, 0), S.calls);
    try testing.expect(!s.handler.semantic_failure);
    s.nextSlice("\x1BP$qm\x1B\\");
    try S.expectResponse("\x1BP1$r0;53m\x1B\\");
}

test "DECRQSS without write effect is ignored" {
    var t: Terminal = try .init(
        testing.io,
        testing.allocator,
        .{ .cols = 80, .rows = 24 },
    );
    defer t.deinit(testing.allocator);

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();

    s.nextSlice("\x1BP$qm\x1B\\");
    try testing.expect(!s.handler.semantic_failure);
}

test "XTGETTCAP responses" {
    var t: Terminal = try .init(
        testing.io,
        testing.allocator,
        .{ .cols = 80, .rows = 24 },
    );
    defer t.deinit(testing.allocator);

    const S = struct {
        var response: [128]u8 = undefined;
        var response_len: usize = 0;
        var calls: usize = 0;

        fn reset() void {
            response_len = 0;
            calls = 0;
        }

        fn writePty(_: *Handler, data: []const u8) void {
            @memcpy(response[0..data.len], data);
            response_len = data.len;
            calls += 1;
        }

        fn expectResponse(expected: []const u8) !void {
            try testing.expectEqual(@as(usize, 1), calls);
            try testing.expectEqualStrings(
                expected,
                response[0..response_len],
            );
            reset();
        }
    };
    S.reset();

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    // The full capability table comes from the static terminfo map; this
    // checks the wiring for a valued and a valueless (boolean) capability.
    s.nextSlice("\x1BP+q" ++ std.fmt.bytesToHex("Co", .upper) ++ "\x1B\\");
    try S.expectResponse("\x1BP1+r" ++ std.fmt.bytesToHex("Co", .upper) ++ "=" ++
        std.fmt.bytesToHex("256", .upper) ++ "\x1B\\");
    s.nextSlice("\x1BP+q" ++ std.fmt.bytesToHex("am", .upper) ++ "\x1B\\");
    try S.expectResponse("\x1BP1+r" ++ std.fmt.bytesToHex("am", .upper) ++ "\x1B\\");

    // One response per requested key; lowercase hex is normalized by the
    // DCS parser. The capture holds the last ("Co") reply.
    s.nextSlice("\x1BP+q" ++ std.fmt.bytesToHex("am", .lower) ++ ";" ++
        std.fmt.bytesToHex("Co", .lower) ++ "\x1B\\");
    try testing.expectEqual(@as(usize, 2), S.calls);
    try testing.expectEqualStrings(
        "\x1BP1+r" ++ std.fmt.bytesToHex("Co", .upper) ++ "=" ++
            std.fmt.bytesToHex("256", .upper) ++ "\x1B\\",
        S.response[0..S.response_len],
    );
    S.reset();

    // Unknown and malformed keys are skipped without an error.
    s.nextSlice("\x1BP+qWHO;5;GG\x1B\\");
    try testing.expectEqual(@as(usize, 0), S.calls);
    try testing.expect(!s.handler.semantic_failure);
}

test "XTGETTCAP without write effect is ignored" {
    var t: Terminal = try .init(
        testing.io,
        testing.allocator,
        .{ .cols = 80, .rows = 24 },
    );
    defer t.deinit(testing.allocator);

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();

    s.nextSlice("\x1BP+q" ++ std.fmt.bytesToHex("TN", .upper) ++ ";" ++
        std.fmt.bytesToHex("am", .upper) ++ "\x1B\\");
    try testing.expect(!s.handler.semantic_failure);
}

test "XTGETTCAP TN responses" {
    var t: Terminal = try .init(
        testing.io,
        testing.allocator,
        .{ .cols = 80, .rows = 24 },
    );
    defer t.deinit(testing.allocator);

    const S = struct {
        var response: [512]u8 = undefined;
        var response_len: usize = 0;
        var calls: usize = 0;

        fn reset() void {
            response_len = 0;
            calls = 0;
        }

        fn writePty(_: *Handler, data: []const u8) void {
            @memcpy(response[0..data.len], data);
            response_len = data.len;
            calls += 1;
        }

        fn expectResponse(expected: []const u8) !void {
            try testing.expectEqual(@as(usize, 1), calls);
            try testing.expectEqualStrings(
                expected,
                response[0..response_len],
            );
            reset();
        }
    };
    S.reset();

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    const tn_query = "\x1BP+q" ++ std.fmt.bytesToHex("TN", .upper) ++ "\x1B\\";

    // While no name is configured the query goes unanswered.
    s.nextSlice(tn_query);
    try testing.expectEqual(@as(usize, 0), S.calls);

    // A configured name is reported hex-encoded.
    s.handler.terminfo_name = "xterm-256color";
    s.nextSlice(tn_query);
    try S.expectResponse("\x1BP1+r" ++ std.fmt.bytesToHex("TN", .upper) ++ "=" ++
        std.fmt.bytesToHex("xterm-256color", .upper) ++ "\x1B\\");

    // A maximum-length name is still reported in full.
    const max_name = "a" ** Handler.max_terminfo_name_bytes;
    s.handler.terminfo_name = max_name;
    s.nextSlice(tn_query);
    try S.expectResponse("\x1BP1+r" ++ std.fmt.bytesToHex("TN", .upper) ++ "=" ++
        std.fmt.bytesToHex(max_name.*, .upper) ++ "\x1B\\");

    // An empty name is silent; "Co" is still answered.
    s.handler.terminfo_name = "";
    s.nextSlice("\x1BP+q" ++ std.fmt.bytesToHex("TN", .upper) ++ ";" ++
        std.fmt.bytesToHex("Co", .upper) ++ "\x1B\\");
    try S.expectResponse("\x1BP1+r" ++ std.fmt.bytesToHex("Co", .upper) ++ "=" ++
        std.fmt.bytesToHex("256", .upper) ++ "\x1B\\");

    // As are names beyond the maximum length.
    s.handler.terminfo_name = "a" ** (Handler.max_terminfo_name_bytes + 1);
    s.nextSlice(tn_query);
    try testing.expectEqual(@as(usize, 0), S.calls);
    try testing.expect(!s.handler.semantic_failure);
}

test "DCS command memory is released" {
    var t: Terminal = try .init(
        testing.io,
        testing.allocator,
        .{ .cols = 80, .rows = 24 },
    );
    defer t.deinit(testing.allocator);

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });

    // A completed command transfers its allocation to Command; dcsCommand
    // must release it even when there is no write effect.
    s.nextSlice("\x1BP+q536D756C78\x1B\\");

    // An incomplete command remains owned by the handler and must be released
    // when the stream is deinitialized. testing.allocator detects either leak.
    s.nextSlice("\x1BP+q536D756C78");
    s.deinit();
}

test "DECALN screen alignment" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 3 });
    defer t.deinit(testing.allocator);

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();

    // Run DECALN
    s.nextSlice("\x1B#8");

    // Verify entire screen is filled with 'E'
    const str = try t.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("EEEEEEEEEE\nEEEEEEEEEE\nEEEEEEEEEE", str);

    // Cursor should be at 1,1
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
}

test "full reset" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();

    // Make some changes
    s.nextSlice("Hello");
    s.nextSlice("\x1B[10;20H");
    s.nextSlice("\x1B[5;20r"); // Set scroll region
    s.nextSlice("\x1B[?7l"); // Disable wraparound
    s.nextSlice("\x1B_25a1;r;cp=e0a0;AAAAAAAAAAAAAA==\x1B\\");
    try testing.expect(t.glyph_glossary.contains(0xE0A0));

    // Full reset
    s.nextSlice("\x1Bc");

    // Verify reset state
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 0), t.scrolling_region.top);
    try testing.expectEqual(@as(usize, 23), t.scrolling_region.bottom);
    try testing.expect(t.modes.get(.wraparound));
    try testing.expect(!t.glyph_glossary.contains(0xE0A0));
}

test "glyph protocol APC with write_pty callback" {
    if (comptime !build_options.glyph_protocol) return error.SkipZigTest;

    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var last_response: ?[:0]const u8 = null;
        fn writePty(_: *Handler, data: []const u8) void {
            if (last_response) |old| testing.allocator.free(old);
            last_response = testing.allocator.dupeZ(u8, data) catch @panic("OOM");
        }
    };
    S.last_response = null;
    defer if (S.last_response) |old| testing.allocator.free(old);

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    s.nextSlice("\x1B_25a1;s\x1B\\");
    try testing.expectEqualStrings("\x1B_25a1;s;fmt=glyf\x1B\\", S.last_response.?);

    s.nextSlice("\x1B_25a1;r;cp=e0a0;AAAAAAAAAAAAAA==\x1B\\");
    try testing.expectEqualStrings("\x1B_25a1;r;cp=e0a0;status=0\x1B\\", S.last_response.?);
    try testing.expect(t.glyph_glossary.contains(0xE0A0));
}

test "ignores query actions" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();

    // These should be ignored without error
    s.nextSlice("\x1B[c"); // Device attributes
    s.nextSlice("\x1B[5n"); // Device status report
    s.nextSlice("\x1B[6n"); // Cursor position report
    s.nextSlice("\x1B]4;0;?\x1B\\"); // OSC color query
    s.nextSlice("\x1B]21;foreground=?\x1B\\"); // Kitty color query
    s.nextSlice("\x1B]52;c;%%%invalid-base64%%%\x1B\\");
    s.nextSlice("\x1B_Ga=p,i=999\x1B\\"); // Missing Kitty image
    s.nextSlice("\x1B_25a1;r;cp=41;%%%invalid%%%\x1B\\"); // Rejected glyph

    // Query, malformed input, protocol failure responses, and external-effect
    // failures do not imply that terminal-owned semantic state diverged.
    try testing.expect(!s.handler.semantic_failure);

    // Terminal should still be functional
    s.nextSlice("Test");
    const str = try t.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("Test", str);
}

test "OSC 4 set and reset palette" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();

    // Save default color
    const default_color_0 = t.colors.palette.original[0];

    // Set color 0 to red
    s.nextSlice("\x1b]4;0;rgb:ff/00/00\x1b\\");
    try testing.expectEqual(@as(u8, 0xff), t.colors.palette.current[0].r);
    try testing.expectEqual(@as(u8, 0x00), t.colors.palette.current[0].g);
    try testing.expectEqual(@as(u8, 0x00), t.colors.palette.current[0].b);
    try testing.expect(t.colors.palette.mask.isSet(0));

    // Reset color 0
    s.nextSlice("\x1b]104;0\x1b\\");
    try testing.expectEqual(default_color_0, t.colors.palette.current[0]);
    try testing.expect(!t.colors.palette.mask.isSet(0));
}

test "OSC 104 reset all palette colors" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();

    // Set multiple colors
    s.nextSlice("\x1b]4;0;rgb:ff/00/00\x1b\\");
    s.nextSlice("\x1b]4;1;rgb:00/ff/00\x1b\\");
    s.nextSlice("\x1b]4;2;rgb:00/00/ff\x1b\\");
    try testing.expect(t.colors.palette.mask.isSet(0));
    try testing.expect(t.colors.palette.mask.isSet(1));
    try testing.expect(t.colors.palette.mask.isSet(2));

    // Reset all palette colors
    s.nextSlice("\x1b]104\x1b\\");
    try testing.expectEqual(t.colors.palette.original[0], t.colors.palette.current[0]);
    try testing.expectEqual(t.colors.palette.original[1], t.colors.palette.current[1]);
    try testing.expectEqual(t.colors.palette.original[2], t.colors.palette.current[2]);
    try testing.expect(!t.colors.palette.mask.isSet(0));
    try testing.expect(!t.colors.palette.mask.isSet(1));
    try testing.expect(!t.colors.palette.mask.isSet(2));
}

test "OSC 10 set and reset foreground color" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();

    // Initially unset
    try testing.expect(t.colors.foreground.get() == null);

    // Set foreground to red
    s.nextSlice("\x1b]10;rgb:ff/00/00\x1b\\");
    const fg = t.colors.foreground.get().?;
    try testing.expectEqual(@as(u8, 0xff), fg.r);
    try testing.expectEqual(@as(u8, 0x00), fg.g);
    try testing.expectEqual(@as(u8, 0x00), fg.b);

    // Reset foreground
    s.nextSlice("\x1b]110\x1b\\");
    try testing.expect(t.colors.foreground.get() == null);
}

test "OSC 11 set and reset background color" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();

    const default: color.RGB = .{ .r = 0x10, .g = 0x20, .b = 0x30 };
    t.colors.background.default = default;

    // Set background to green
    s.nextSlice("\x1b]11;rgb:00/ff/00\x1b\\");
    const bg = t.colors.background.get().?;
    try testing.expectEqual(@as(u8, 0x00), bg.r);
    try testing.expectEqual(@as(u8, 0xff), bg.g);
    try testing.expectEqual(@as(u8, 0x00), bg.b);

    // Reset background
    s.nextSlice("\x1b]111\x1b\\");
    try testing.expectEqual(default, t.colors.background.get().?);
    try testing.expectEqual(null, t.colors.background.override);

    // A reset color continues to follow later configuration changes.
    const updated: color.RGB = .{ .r = 0x40, .g = 0x50, .b = 0x60 };
    t.colors.background.default = updated;
    try testing.expectEqual(updated, t.colors.background.get().?);
}

test "OSC 12 set and reset cursor color" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();

    // Set cursor to blue
    s.nextSlice("\x1b]12;rgb:00/00/ff\x1b\\");
    const cursor = t.colors.cursor.get().?;
    try testing.expectEqual(@as(u8, 0x00), cursor.r);
    try testing.expectEqual(@as(u8, 0x00), cursor.g);
    try testing.expectEqual(@as(u8, 0xff), cursor.b);

    // Reset cursor
    s.nextSlice("\x1b]112\x1b\\");
    // After reset, cursor might be null (using default)
}

test "OSC color query responses" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var last_response: ?[:0]const u8 = null;

        fn reset() void {
            if (last_response) |old| testing.allocator.free(old);
            last_response = null;
        }

        fn writePty(_: *Handler, data: []const u8) void {
            reset();
            last_response = testing.allocator.dupeZ(u8, data) catch @panic("OOM");
        }
    };
    S.last_response = null;
    defer S.reset();

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    s.nextSlice("\x1b]10;?\x1b\\");
    try testing.expect(S.last_response == null);

    s.nextSlice("\x1b]11;?\x1b\\");
    try testing.expect(S.last_response == null);

    s.nextSlice("\x1b]4;2;rgb:12/34/56;2;?\x1b\\");
    try testing.expectEqualStrings(
        "\x1b]4;2;rgb:1212/3434/5656\x1b\\",
        S.last_response.?,
    );

    s.nextSlice("\x1b]10;rgb:01/02/03\x1b\\");
    s.nextSlice("\x1b]11;rgb:04/05/06\x1b\\");
    s.nextSlice("\x1b]12;rgb:07/08/09\x1b\\");
    s.nextSlice("\x1b]10;?;?;?\x1b\\");
    try testing.expectEqualStrings(
        "\x1b]10;rgb:0101/0202/0303\x1b\\" ++
            "\x1b]11;rgb:0404/0505/0606\x1b\\" ++
            "\x1b]12;rgb:0707/0808/0909\x1b\\",
        S.last_response.?,
    );

    s.nextSlice("\x1b]112\x1b\\");
    s.nextSlice("\x1b]12;?\x07");
    try testing.expectEqualStrings(
        "\x1b]12;rgb:0101/0202/0303\x07",
        S.last_response.?,
    );
}

test "kitty color protocol set palette" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();

    // Set palette color 5 to magenta using kitty protocol
    s.nextSlice("\x1b]21;5=rgb:ff/00/ff\x1b\\");
    try testing.expectEqual(@as(u8, 0xff), t.colors.palette.current[5].r);
    try testing.expectEqual(@as(u8, 0x00), t.colors.palette.current[5].g);
    try testing.expectEqual(@as(u8, 0xff), t.colors.palette.current[5].b);
    try testing.expect(t.colors.palette.mask.isSet(5));
    try testing.expect(t.flags.dirty.palette);
}

test "kitty color protocol reset palette" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();

    // Set and then reset palette color
    const original = t.colors.palette.original[7];
    s.nextSlice("\x1b]21;7=rgb:aa/bb/cc\x1b\\");
    try testing.expect(t.colors.palette.mask.isSet(7));

    s.nextSlice("\x1b]21;7=\x1b\\");
    try testing.expectEqual(original, t.colors.palette.current[7]);
    try testing.expect(!t.colors.palette.mask.isSet(7));
}

test "kitty color protocol set foreground" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();

    // Set foreground using kitty protocol
    s.nextSlice("\x1b]21;foreground=rgb:12/34/56\x1b\\");
    const fg = t.colors.foreground.get().?;
    try testing.expectEqual(@as(u8, 0x12), fg.r);
    try testing.expectEqual(@as(u8, 0x34), fg.g);
    try testing.expectEqual(@as(u8, 0x56), fg.b);
}

test "kitty color protocol set background" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();

    // Set background using kitty protocol
    s.nextSlice("\x1b]21;background=rgb:78/9a/bc\x1b\\");
    const bg = t.colors.background.get().?;
    try testing.expectEqual(@as(u8, 0x78), bg.r);
    try testing.expectEqual(@as(u8, 0x9a), bg.g);
    try testing.expectEqual(@as(u8, 0xbc), bg.b);
}

test "kitty color protocol set cursor" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();

    // Set cursor using kitty protocol
    s.nextSlice("\x1b]21;cursor=rgb:de/f0/12\x1b\\");
    const cursor = t.colors.cursor.get().?;
    try testing.expectEqual(@as(u8, 0xde), cursor.r);
    try testing.expectEqual(@as(u8, 0xf0), cursor.g);
    try testing.expectEqual(@as(u8, 0x12), cursor.b);
}

test "kitty color protocol reset foreground" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();

    // Set and reset foreground
    s.nextSlice("\x1b]21;foreground=rgb:11/22/33\x1b\\");
    try testing.expect(t.colors.foreground.get() != null);

    s.nextSlice("\x1b]21;foreground=\x1b\\");
    // After reset, should be unset
    try testing.expect(t.colors.foreground.get() == null);
}

test "kitty color protocol query responses" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var last_response: ?[:0]const u8 = null;

        fn reset() void {
            if (last_response) |old| testing.allocator.free(old);
            last_response = null;
        }

        fn writePty(_: *Handler, data: []const u8) void {
            reset();
            last_response = testing.allocator.dupeZ(u8, data) catch @panic("OOM");
        }
    };
    S.last_response = null;
    defer S.reset();

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    s.nextSlice("\x1b]21;background=?\x1b\\");
    try testing.expectEqualStrings(
        "\x1b]21;background=\x1b\\",
        S.last_response.?,
    );

    s.nextSlice("\x1b]21;foreground=rgb:12/34/56;2=rgb:aa/bb/cc\x1b\\");
    s.nextSlice("\x1b]21;foreground=?;background=?;2=?\x1b\\");
    try testing.expectEqualStrings(
        "\x1b]21;foreground=rgb:12/34/56;background=;2=rgb:aa/bb/cc\x1b\\",
        S.last_response.?,
    );
}

test "palette dirty flag set on color change" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();

    // Clear dirty flag
    t.flags.dirty.palette = false;

    // Setting palette color should set dirty flag
    s.nextSlice("\x1b]4;0;rgb:ff/00/00\x1b\\");
    try testing.expect(t.flags.dirty.palette);

    // Clear and test reset
    t.flags.dirty.palette = false;
    s.nextSlice("\x1b]104;0\x1b\\");
    try testing.expect(t.flags.dirty.palette);

    // Clear and test kitty protocol
    t.flags.dirty.palette = false;
    s.nextSlice("\x1b]21;1=rgb:00/ff/00\x1b\\");
    try testing.expect(t.flags.dirty.palette);
}

test "semantic prompt fresh line" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();

    s.nextSlice("Hello");
    s.nextSlice("\x1b]133;L\x07");
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.y);
}

test "semantic prompt fresh line new prompt" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();

    // Write some text and then send OSC 133;A (fresh_line_new_prompt)
    s.nextSlice("Hello");
    s.nextSlice("\x1b]133;A\x07");

    // Should do a fresh line (carriage return + index)
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.y);

    // Should set cursor semantic_content to prompt
    try testing.expectEqual(.prompt, t.screens.active.cursor.semantic_content);

    // Test with redraw option
    s.nextSlice("prompt$ ");
    s.nextSlice("\x1b]133;A;redraw=1\x07");
    try testing.expect(t.flags.shell_redraws_prompt == .true);
}

test "semantic prompt end of input, then start output" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();

    // Write some text and then send OSC 133;A (fresh_line_new_prompt)
    s.nextSlice("Hello");
    s.nextSlice("\x1b]133;A\x07");
    s.nextSlice("prompt$ ");
    s.nextSlice("\x1b]133;B\x07");
    try testing.expectEqual(.input, t.screens.active.cursor.semantic_content);
    s.nextSlice("\x1b]133;C\x07");
    try testing.expectEqual(.output, t.screens.active.cursor.semantic_content);
}

test "semantic prompt prompt_start" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();

    // Write some text
    s.nextSlice("Hello");

    // OSC 133;P marks the start of a prompt (without fresh line behavior)
    s.nextSlice("\x1b]133;P\x07");
    try testing.expectEqual(.prompt, t.screens.active.cursor.semantic_content);
    try testing.expectEqual(@as(usize, 5), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
}

test "semantic prompt new_command" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();

    // Write some text
    s.nextSlice("Hello");
    s.nextSlice("\x1b]133;N\x07");

    // Should behave like fresh_line_new_prompt - cursor moves to column 0
    // on next line since we had content
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.y);
    try testing.expectEqual(.prompt, t.screens.active.cursor.semantic_content);
}

test "semantic prompt new_command at column zero" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();

    // OSC 133;N when already at column 0 should stay on same line
    s.nextSlice("\x1b]133;N\x07");
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(.prompt, t.screens.active.cursor.semantic_content);
}

test "semantic prompt end_prompt_start_input_terminate_eol clears on linefeed" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();

    // Set input terminated by EOL
    s.nextSlice("\x1b]133;I\x07");
    try testing.expectEqual(.input, t.screens.active.cursor.semantic_content);

    // Linefeed should reset semantic content to output
    s.nextSlice("\n");
    try testing.expectEqual(.output, t.screens.active.cursor.semantic_content);
}

test "bell effect callback" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    // Test bell with null callback (default readonly effects) doesn't crash
    {
        var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
        defer s.deinit();

        s.nextSlice("\x07");

        // Terminal should still be functional after bell
        s.nextSlice("AfterBell");
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AfterBell", str);
    }

    t.fullReset();

    // Test bell with a callback
    {
        const S = struct {
            var bell_count: usize = 0;
            fn bell(_: *Handler) void {
                bell_count += 1;
            }
        };
        S.bell_count = 0;

        var handler: Handler = .init(&t);
        handler.effects.bell = &S.bell;

        var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
        defer s.deinit();

        s.nextSlice("\x07");
        try testing.expectEqual(@as(usize, 1), S.bell_count);

        s.nextSlice("\x07\x07");
        try testing.expectEqual(@as(usize, 3), S.bell_count);
    }
}

test "desktop_notification effect callback" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    // A null callback (the default readonly effects) silently ignores
    // notifications and leaves the terminal usable.
    {
        var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
        defer s.deinit();

        s.nextSlice("\x1B]9;Ignored\x1B\\AfterNotification");
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AfterNotification", str);
    }

    t.fullReset();

    const S = struct {
        var count: usize = 0;
        var last_title: []const u8 = "";
        var last_body: []const u8 = "";

        fn desktopNotification(
            _: *Handler,
            notification: Action.ShowDesktopNotification,
        ) void {
            count += 1;
            last_title = notification.title;
            last_body = notification.body;
        }
    };
    S.count = 0;
    S.last_title = "";
    S.last_body = "";

    var handler: Handler = .init(&t);
    handler.effects.desktop_notification = &S.desktopNotification;

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    // OSC 9 is split across writes and carries only a body.
    s.nextSlice("\x1B]9;Build ");
    try testing.expectEqual(@as(usize, 0), S.count);
    s.nextSlice("complete\x1B\\");
    try testing.expectEqual(@as(usize, 1), S.count);
    try testing.expectEqualStrings("", S.last_title);
    try testing.expectEqualStrings("Build complete", S.last_body);

    // OSC 777 preserves its separate title and body fields.
    s.nextSlice("\x1B]777;notify;Codex;Needs attention\x07");
    try testing.expectEqual(@as(usize, 2), S.count);
    try testing.expectEqualStrings("Codex", S.last_title);
    try testing.expectEqualStrings("Needs attention", S.last_body);
}

test "progress_report effect callback" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    // A null callback (the default readonly effects) silently ignores reports.
    {
        var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
        defer s.deinit();
        s.nextSlice("\x1B]9;4;1;25\x1B\\");
    }

    const S = struct {
        var count: usize = 0;
        var last_state: osc.Command.ProgressReport.State = .remove;
        var last_progress: ?u8 = null;

        fn progressReport(_: *Handler, report: osc.Command.ProgressReport) void {
            count += 1;
            last_state = report.state;
            last_progress = report.progress;
        }
    };
    S.count = 0;
    S.last_state = .remove;
    S.last_progress = null;

    var handler: Handler = .init(&t);
    handler.effects.progress_report = &S.progressReport;

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    const cases = [_]struct {
        sequence: []const u8,
        state: osc.Command.ProgressReport.State,
        progress: ?u8,
    }{
        .{ .sequence = "\x1B]9;4;0;\x1B\\", .state = .remove, .progress = null },
        .{ .sequence = "\x1B]9;4;1;42\x07", .state = .set, .progress = 42 },
        .{ .sequence = "\x1B]9;4;2;7\x1B\\", .state = .@"error", .progress = 7 },
        .{ .sequence = "\x1B]9;4;3\x1B\\", .state = .indeterminate, .progress = null },
        .{ .sequence = "\x1B]9;4;4;75\x1B\\", .state = .pause, .progress = 75 },
    };

    for (cases, 1..) |case, expected_count| {
        // Split each sequence to verify parsing survives PTY read boundaries.
        const midpoint = case.sequence.len / 2;
        s.nextSlice(case.sequence[0..midpoint]);
        try testing.expectEqual(expected_count - 1, S.count);
        s.nextSlice(case.sequence[midpoint..]);
        try testing.expectEqual(expected_count, S.count);
        try testing.expectEqual(case.state, S.last_state);
        try testing.expectEqual(case.progress, S.last_progress);
    }

    // A full reset (RIS) removes any active progress bar.
    s.nextSlice("\x1B]9;4;1;50\x1B\\");
    try testing.expectEqual(@as(usize, cases.len + 1), S.count);
    try testing.expectEqual(osc.Command.ProgressReport.State.set, S.last_state);
    s.nextSlice("\x1Bc");
    try testing.expectEqual(@as(usize, cases.len + 2), S.count);
    try testing.expectEqual(osc.Command.ProgressReport.State.remove, S.last_state);
    try testing.expectEqual(@as(?u8, null), S.last_progress);
}

test "clipboard_write effect callback" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    // A null callback (the default readonly effects) silently ignores writes.
    {
        var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
        defer s.deinit();

        s.nextSlice("\x1B]52;c;aGVsbG8=\x1B\\");

        // Terminal should still be functional after the ignored sequence
        s.nextSlice("AfterClipboard");
        const str = try t.plainString(testing.allocator);
        defer testing.allocator.free(str);
        try testing.expectEqualStrings("AfterClipboard", str);
    }

    t.fullReset();

    const S = struct {
        var count: usize = 0;
        var result: clipboard.Write.Result = .{ .success = .{} };
        var last_location: clipboard.Location = .standard;
        var last_contents_len: usize = 0;
        var last_mime: ?[]u8 = null;
        var last_data: ?[]u8 = null;

        fn clearCapture() void {
            if (last_mime) |value| testing.allocator.free(value);
            if (last_data) |value| testing.allocator.free(value);
            last_mime = null;
            last_data = null;
            last_contents_len = 0;
        }

        fn clipboardWrite(_: *Handler, write: clipboard.Write) void {
            clearCapture();
            count += 1;
            last_location = write.location;
            last_contents_len = write.contents.len;
            if (write.contents.len > 0) {
                last_mime = testing.allocator.dupe(u8, write.contents[0].mime) catch
                    @panic("failed to capture clipboard MIME type");
                last_data = testing.allocator.dupe(u8, write.contents[0].data) catch
                    @panic("failed to capture clipboard data");
            }
            write.reply(result);
        }
    };
    S.count = 0;
    S.result = .denied;
    S.clearCapture();
    defer S.clearCapture();

    var handler: Handler = .init(&t);
    handler.effects.clipboard_write = &S.clipboardWrite;

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    // Selectors are normalized and payloads are decoded before the callback.
    const cases = [_]struct {
        sequence: []const u8,
        location: clipboard.Location,
        data: []const u8,
    }{
        .{ .sequence = "\x1B]52;c;aGVsbG8=\x1B\\", .location = .standard, .data = "hello" },
        .{ .sequence = "\x1B]52;s;d29ybGQ=\x07", .location = .selection, .data = "world" },
        .{ .sequence = "\x1B]52;p;cHJpbWFyeQ==\x1B\\", .location = .primary, .data = "primary" },
        .{ .sequence = "\x1B]52;0;Y3V0\x1B\\", .location = .standard, .data = "cut" },
        .{ .sequence = "\x1B]52;x;ZmFsbGJhY2s=\x1B\\", .location = .standard, .data = "fallback" },
        .{ .sequence = "\x1B]52;c;YQBi\x1B\\", .location = .standard, .data = "a\x00b" },
        // Missing padding is tolerated for OSC 52 since it has no way
        // to report errors to the client, matching kitty.
        .{ .sequence = "\x1B]52;c;dW5wYWRkZWQ\x1B\\", .location = .standard, .data = "unpadded" },
    };

    for (cases, 1..) |case, expected_count| {
        s.nextSlice(case.sequence);
        try testing.expectEqual(expected_count, S.count);
        try testing.expectEqual(case.location, S.last_location);
        try testing.expectEqual(@as(usize, 1), S.last_contents_len);
        try testing.expectEqualStrings("text/plain", S.last_mime.?);
        try testing.expectEqualSlices(u8, case.data, S.last_data.?);
    }

    // Empty data is a clear, represented by an empty contents slice.
    s.nextSlice("\x1B]52;s;\x1B\\");
    try testing.expectEqual(@as(usize, cases.len + 1), S.count);
    try testing.expectEqual(clipboard.Location.selection, S.last_location);
    try testing.expectEqual(@as(usize, 0), S.last_contents_len);
    try testing.expect(S.last_mime == null);
    try testing.expect(S.last_data == null);

    // Reads and malformed base64 are ignored. The whole request is
    // discarded on invalid characters (including whitespace) rather
    // than decoding around them, per the Kitty clipboard spec that
    // governs OSC 52 base64 handling.
    s.nextSlice("\x1B]52;c;?\x1B\\");
    s.nextSlice("\x1B]52;c;***\x1B\\");
    s.nextSlice("\x1B]52;c;SGVs!!!bG8=\x1B\\");
    s.nextSlice("\x1B]52;c;aGVs bG8=\x1B\\");
    try testing.expectEqual(@as(usize, cases.len + 1), S.count);

    // OSC 1337 Copy shares the normalized clipboard write path.
    s.nextSlice("\x1B]1337;Copy=:aVRlcm0y\x1B\\");
    try testing.expectEqual(@as(usize, cases.len + 2), S.count);
    try testing.expectEqual(clipboard.Location.standard, S.last_location);
    try testing.expectEqualStrings("text/plain", S.last_mime.?);
    try testing.expectEqualStrings("iTerm2", S.last_data.?);

    // Parsing across write boundaries still invokes exactly one atomic write.
    s.nextSlice("\x1B]52;p;ZnJh");
    s.nextSlice("Z21lbnRlZA==\x1B");
    s.nextSlice("\\");
    try testing.expectEqual(@as(usize, cases.len + 3), S.count);
    try testing.expectEqual(clipboard.Location.primary, S.last_location);
    try testing.expectEqualStrings("text/plain", S.last_mime.?);
    try testing.expectEqualStrings("fragmented", S.last_data.?);

    // Reply results are intentionally ignored for protocols without a
    // write acknowledgement. The denied reply above did not stop later writes.
    try testing.expect(S.result == .denied);
}

test "clipboard_read effect callback" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var written: std.ArrayList(u8) = .empty;
        var count: usize = 0;
        var last_location: clipboard.Location = .standard;
        var last_mimes: []const []const u8 = &.{};
        var last_list: bool = true;
        var last_name: []const u8 = "unset";
        var last_granted: bool = true;
        var last_can_remember: bool = true;
        var result: ?clipboard.Read.Result = .{ .success = .{ .contents = &.{.{
            .mime = "text/plain",
            .data = "hello",
        }} } };
        var reply_twice: bool = false;

        fn writePty(_: *Handler, data: []const u8) void {
            written.appendSlice(testing.allocator, data) catch @panic("OOM");
        }

        fn clipboardRead(_: *Handler, read: clipboard.Read) void {
            count += 1;
            last_location = read.location;
            last_mimes = read.mimes;
            last_list = read.list;
            last_name = read.name;
            last_granted = read.granted;
            last_can_remember = read.can_remember;
            if (result) |r| read.reply(r);
            if (reply_twice) read.reply(.{ .success = .{ .contents = &.{.{
                .mime = "text/plain",
                .data = "again",
            }} } });
        }
    };
    defer S.written.deinit(testing.allocator);

    // A null callback (the default readonly effects) silently ignores reads.
    {
        var handler: Handler = .init(&t);
        handler.effects.write_pty = &S.writePty;
        var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
        defer s.deinit();

        s.nextSlice("\x1B]52;c;?\x1B\\");
        try testing.expectEqual(0, S.written.items.len);
    }

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_read = &S.clipboardRead;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    // Success echoes the normalized selector and request terminator.
    s.nextSlice("\x1B]52;c;?\x1B\\");
    try testing.expectEqual(1, S.count);
    try testing.expectEqual(clipboard.Location.standard, S.last_location);
    try testing.expectEqual(1, S.last_mimes.len);
    try testing.expectEqualStrings("text/plain", S.last_mimes[0]);
    try testing.expect(!S.last_list);
    try testing.expectEqualStrings("", S.last_name);
    try testing.expect(!S.last_granted);
    try testing.expect(!S.last_can_remember);
    try testing.expectEqualStrings("\x1B]52;c;aGVsbG8=\x1B\\", S.written.items);

    S.written.clearRetainingCapacity();
    s.nextSlice("\x1B]52;p;?\x07");
    try testing.expectEqual(clipboard.Location.primary, S.last_location);
    try testing.expectEqualStrings("\x1B]52;p;aGVsbG8=\x07", S.written.items);

    // Only the first text representation is used.
    S.written.clearRetainingCapacity();
    S.result = .{
        .success = .{
            .contents = &.{
                .{ .mime = "image/png", .data = "\x89PNG" },
                .{ .mime = "UTF8_STRING", .data = "hi" },
            },
            // OSC 52 has no session passwords, so remember is ignored.
            .remember = true,
        },
    };
    s.nextSlice("\x1B]52;s;?\x1B\\");
    try testing.expectEqual(clipboard.Location.selection, S.last_location);
    try testing.expectEqualStrings("\x1B]52;s;aGk=\x1B\\", S.written.items);

    // Every failure, no text, and no reply all answer with an empty
    // clipboard.
    for ([_]?clipboard.Read.Result{
        .denied,
        .unsupported,
        .busy,
        .io_error,
        .{ .success = .{} },
        null,
    }) |result| {
        S.written.clearRetainingCapacity();
        S.result = result;
        s.nextSlice("\x1B]52;c;?\x1B\\");
        try testing.expectEqualStrings("\x1B]52;c;\x1B\\", S.written.items);
    }

    // A second reply is ignored.
    S.written.clearRetainingCapacity();
    S.result = .{ .success = .{ .contents = &.{.{ .mime = "text/plain", .data = "hello" }} } };
    S.reply_twice = true;
    s.nextSlice("\x1B]52;c;?\x1B\\");
    try testing.expectEqualStrings("\x1B]52;c;aGVsbG8=\x1B\\", S.written.items);
}

test "clipboard_write allocation failure is ignored" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var count: usize = 0;

        fn clipboardWrite(_: *Handler, write: clipboard.Write) void {
            count += 1;
            write.reply(.{ .success = .{} });
        }
    };
    S.count = 0;

    var handler: Handler = .init(&t);
    handler.effects.clipboard_write = &S.clipboardWrite;

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    // Only the decoded scratch data uses the terminal allocator here. Swap in
    // an allocator that always fails, then restore it before terminal teardown.
    {
        const alloc = t.screens.active.alloc;
        t.screens.active.alloc = testing.failing_allocator;
        defer t.screens.active.alloc = alloc;
        s.nextSlice("\x1B]52;c;aGVsbG8=\x1B\\");
    }
    try testing.expectEqual(@as(usize, 0), S.count);
    try testing.expect(!s.handler.semantic_failure);
}

/// Shared capture state for the Kitty clipboard (OSC 5522) tests below:
/// records every pty response and the most recent clipboard write.
const KittyClipboardCapture = struct {
    var responses: [1024]u8 = undefined;
    var responses_len: usize = 0;

    // Write capture. A null write_result returns without replying.
    var write_count: usize = 0;
    var write_result: ?clipboard.Write.Result = .{ .success = .{} };
    var write_reply_twice: bool = false;
    var last_location: clipboard.Location = .standard;
    var last_contents_len: usize = 0;
    var last_mimes: [8][64]u8 = undefined;
    var last_mime_lens: [8]usize = @splat(0);
    var last_data: [8][256]u8 = undefined;
    var last_data_lens: [8]usize = @splat(0);
    var last_write_name: [64]u8 = undefined;
    var last_write_name_len: usize = 0;
    var last_write_granted: bool = false;
    var last_write_can_remember: bool = false;

    // Read capture. A null read_result returns without replying.
    var read_count: usize = 0;
    var read_result: ?clipboard.Read.Result = null;
    var read_reply_twice: bool = false;
    var last_read_location: clipboard.Location = .standard;
    var last_read_mimes: [8][64]u8 = undefined;
    var last_read_mime_lens: [8]usize = @splat(0);
    var last_read_mimes_len: usize = 0;
    var last_read_list: bool = false;
    var last_read_name: [64]u8 = undefined;
    var last_read_name_len: usize = 0;
    var last_read_granted: bool = false;
    var last_read_can_remember: bool = false;

    fn reset() void {
        responses_len = 0;
        write_count = 0;
        write_result = .{ .success = .{} };
        write_reply_twice = false;
        last_location = .standard;
        last_contents_len = 0;
        last_mime_lens = @splat(0);
        last_data_lens = @splat(0);
        last_write_name_len = 0;
        last_write_granted = false;
        last_write_can_remember = false;
        read_count = 0;
        read_result = null;
        read_reply_twice = false;
        last_read_location = .standard;
        last_read_mime_lens = @splat(0);
        last_read_mimes_len = 0;
        last_read_list = false;
        last_read_name_len = 0;
        last_read_granted = false;
        last_read_can_remember = false;
    }

    fn writePty(_: *Handler, data: []const u8) void {
        @memcpy(responses[responses_len..][0..data.len], data);
        responses_len += data.len;
    }

    fn clipboardWrite(_: *Handler, write: clipboard.Write) void {
        write_count += 1;
        last_location = write.location;
        last_contents_len = write.contents.len;
        for (write.contents[0..@min(write.contents.len, last_mimes.len)], 0..) |content, i| {
            last_mime_lens[i] = content.mime.len;
            @memcpy(last_mimes[i][0..content.mime.len], content.mime);
            last_data_lens[i] = content.data.len;
            @memcpy(last_data[i][0..content.data.len], content.data);
        }
        last_write_name_len = write.name.len;
        @memcpy(last_write_name[0..write.name.len], write.name);
        last_write_granted = write.granted;
        last_write_can_remember = write.can_remember;
        if (write_result) |r| write.reply(r);
        if (write_reply_twice) write.reply(.io_error);
    }

    fn clipboardRead(_: *Handler, read: clipboard.Read) void {
        read_count += 1;
        last_read_location = read.location;
        last_read_mimes_len = read.mimes.len;
        for (read.mimes[0..@min(read.mimes.len, last_read_mimes.len)], 0..) |mime, i| {
            last_read_mime_lens[i] = mime.len;
            @memcpy(last_read_mimes[i][0..mime.len], mime);
        }
        last_read_list = read.list;
        last_read_name_len = read.name.len;
        @memcpy(last_read_name[0..read.name.len], read.name);
        last_read_granted = read.granted;
        last_read_can_remember = read.can_remember;
        if (read_result) |r| read.reply(r);
        if (read_reply_twice) read.reply(.denied);
    }

    fn responseSlice() []const u8 {
        return responses[0..responses_len];
    }

    fn readMimeAt(i: usize) []const u8 {
        return last_read_mimes[i][0..last_read_mime_lens[i]];
    }

    fn readName() []const u8 {
        return last_read_name[0..last_read_name_len];
    }

    fn writeName() []const u8 {
        return last_write_name[0..last_write_name_len];
    }

    fn mimeAt(i: usize) []const u8 {
        return last_mimes[i][0..last_mime_lens[i]];
    }

    fn dataAt(i: usize) []const u8 {
        return last_data[i][0..last_data_lens[i]];
    }
};

test "kitty clipboard write transaction round trip" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = KittyClipboardCapture;
    S.reset();

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_write = &S.clipboardWrite;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    // Begin a write, stream two MIME types (one chunked), alias the
    // plain text, and commit. Only the commit produces a response.
    s.nextSlice("\x1B]5522;type=write:id=42\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata:mime=dGV4dC9wbGFpbg==;R2hvc3Q=\x1B\\"); // "Ghost"
    s.nextSlice("\x1B]5522;type=wdata:mime=dGV4dC9wbGFpbg==;dHk=\x1B\\"); // "ty"
    s.nextSlice("\x1B]5522;type=wdata:mime=dGV4dC9odG1s;PGI+aGk8L2I+\x1B\\"); // "<b>hi</b>"
    // Alias "TEXT UTF8_STRING" -> text/plain.
    s.nextSlice("\x1B]5522;type=walias:mime=dGV4dC9wbGFpbg==;VEVYVCBVVEY4X1NUUklORw==\x1B\\");
    try testing.expectEqual(@as(usize, 0), S.write_count);
    try testing.expectEqual(@as(usize, 0), S.responses_len);

    s.nextSlice("\x1B]5522;type=wdata\x1B\\");
    try testing.expectEqual(@as(usize, 1), S.write_count);
    try testing.expectEqual(clipboard.Location.standard, S.last_location);
    try testing.expectEqual(@as(usize, 4), S.last_contents_len);
    try testing.expectEqualStrings("text/plain", S.mimeAt(0));
    try testing.expectEqualStrings("Ghostty", S.dataAt(0));
    try testing.expectEqualStrings("text/html", S.mimeAt(1));
    try testing.expectEqualStrings("<b>hi</b>", S.dataAt(1));
    try testing.expectEqualStrings("TEXT", S.mimeAt(2));
    try testing.expectEqualStrings("Ghostty", S.dataAt(2));
    try testing.expectEqualStrings("UTF8_STRING", S.mimeAt(3));
    try testing.expectEqualStrings("Ghostty", S.dataAt(3));
    try testing.expectEqualStrings(
        "\x1B]5522;type=write:status=DONE:id=42\x1B\\",
        S.responseSlice(),
    );

    // A commit with no transaction in flight is silently ignored.
    s.nextSlice("\x1B]5522;type=wdata\x1B\\");
    try testing.expectEqual(@as(usize, 1), S.write_count);
}

test "kitty clipboard write result maps to response status" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = KittyClipboardCapture;

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_write = &S.clipboardWrite;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    const cases = [_]struct {
        result: ?clipboard.Write.Result,
        response: []const u8,
    }{
        .{ .result = .{ .success = .{} }, .response = "\x1B]5522;type=write:status=DONE\x1B\\" },
        .{ .result = .denied, .response = "\x1B]5522;type=write:status=EPERM\x1B\\" },
        .{ .result = .unsupported, .response = "\x1B]5522;type=write:status=ENOSYS\x1B\\" },
        .{ .result = .busy, .response = "\x1B]5522;type=write:status=EBUSY\x1B\\" },
        .{ .result = .invalid_data, .response = "\x1B]5522;type=write:status=EINVAL\x1B\\" },
        .{ .result = .io_error, .response = "\x1B]5522;type=write:status=EIO\x1B\\" },
        // No reply at all is a denial rather than silence.
        .{ .result = null, .response = "\x1B]5522;type=write:status=EPERM\x1B\\" },
    };

    for (cases) |case| {
        S.reset();
        S.write_result = case.result;

        // An immediately-committed write with no data is a clear.
        s.nextSlice("\x1B]5522;type=write\x1B\\");
        s.nextSlice("\x1B]5522;type=wdata\x1B\\");
        try testing.expectEqual(@as(usize, 1), S.write_count);
        try testing.expectEqual(@as(usize, 0), S.last_contents_len);
        try testing.expectEqualStrings(case.response, S.responseSlice());
    }

    // A second reply is ignored.
    S.reset();
    S.write_reply_twice = true;
    s.nextSlice("\x1B]5522;type=write\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata\x1B\\");
    try testing.expectEqualStrings(
        "\x1B]5522;type=write:status=DONE\x1B\\",
        S.responseSlice(),
    );

    // The response echoes the request terminator, unlike kitty which
    // always uses ST.
    S.reset();
    s.nextSlice("\x1B]5522;type=write:loc=primary\x07");
    s.nextSlice("\x1B]5522;type=wdata\x07");
    try testing.expectEqual(clipboard.Location.primary, S.last_location);
    try testing.expectEqualStrings(
        "\x1B]5522;type=write:status=DONE\x07",
        S.responseSlice(),
    );

    // A system without a primary selection answers a loc=primary write
    // with ENOSYS, echoing the id.
    S.reset();
    S.write_result = .unsupported;
    s.nextSlice("\x1B]5522;type=write:loc=primary:id=p1\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata\x1B\\");
    try testing.expectEqual(clipboard.Location.primary, S.last_location);
    try testing.expectEqualStrings(
        "\x1B]5522;type=write:status=ENOSYS:id=p1\x1B\\",
        S.responseSlice(),
    );
}

test "kitty clipboard write without clipboard effect responds ENOSYS" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = KittyClipboardCapture;
    S.reset();

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    // The transaction fails as soon as it begins; the rest of it is
    // ignored without further responses.
    s.nextSlice("\x1B]5522;type=write:id=x\x1B\\");
    try testing.expectEqualStrings(
        "\x1B]5522;type=write:status=ENOSYS:id=x\x1B\\",
        S.responseSlice(),
    );
    s.nextSlice("\x1B]5522;type=wdata:mime=dGV4dC9wbGFpbg==;R2hvc3Q=\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata\x1B\\");
    try testing.expectEqualStrings(
        "\x1B]5522;type=write:status=ENOSYS:id=x\x1B\\",
        S.responseSlice(),
    );
}

test "kitty clipboard read without effect is denied with EPERM" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = KittyClipboardCapture;
    S.reset();

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_write = &S.clipboardWrite;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    // The denial never includes loc (only OK responses do) and echoes
    // the sanitized id.
    s.nextSlice("\x1B]5522;type=read:loc=primary:id=*4 2*;dGV4dC9wbGFpbg==\x1B\\");
    try testing.expectEqualStrings(
        "\x1B]5522;type=read:status=EPERM:id=42\x1B\\",
        S.responseSlice(),
    );

    // A missing payload is an empty MIME list, still answered.
    S.reset();
    s.nextSlice("\x1B]5522;type=read\x07");
    try testing.expectEqualStrings(
        "\x1B]5522;type=read:status=EPERM\x07",
        S.responseSlice(),
    );

    // An undecodable payload is dropped without a response.
    S.reset();
    s.nextSlice("\x1B]5522;type=read;!!!\x1B\\");
    try testing.expectEqual(@as(usize, 0), S.responses_len);
}

test "kitty clipboard read round trip" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = KittyClipboardCapture;
    S.reset();

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_read = &S.clipboardRead;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    S.read_result = .{
        .success = .{
            .contents = &.{
                // Unrequested representations are never served, and the
                // served ones follow request order, not reply order.
                .{ .mime = "image/png", .data = "\x89PNG" },
                .{ .mime = "text/html", .data = "<b>hi</b>" },
                .{ .mime = "text/plain", .data = "Ghostty" },
            },
            .available = &.{ "text/plain", "text/html" },
        },
    };

    // Request the targets listing plus two types from the primary
    // selection: ". text/plain text/html".
    s.nextSlice("\x1B]5522;type=read:loc=primary:id=r1;LiB0ZXh0L3BsYWluIHRleHQvaHRtbA==\x1B\\");
    try testing.expectEqual(@as(usize, 1), S.read_count);
    try testing.expectEqual(clipboard.Location.primary, S.last_read_location);
    try testing.expectEqual(@as(usize, 2), S.last_read_mimes_len);
    try testing.expectEqualStrings("text/plain", S.readMimeAt(0));
    try testing.expectEqualStrings("text/html", S.readMimeAt(1));
    try testing.expect(S.last_read_list);
    try testing.expectEqualStrings("", S.readName());
    try testing.expect(!S.last_read_granted);
    try testing.expect(!S.last_read_can_remember);
    try testing.expectEqualStrings(
        "\x1B]5522;type=read:status=OK:loc=primary:id=r1\x1B\\" ++
            "\x1B]5522;type=read:status=DATA:id=r1:mime=Lg==;dGV4dC9wbGFpbiB0ZXh0L2h0bWwK\x1B\\" ++
            "\x1B]5522;type=read:status=DATA:id=r1:mime=dGV4dC9wbGFpbg==;R2hvc3R0eQ==\x1B\\" ++
            "\x1B]5522;type=read:status=DATA:id=r1:mime=dGV4dC9odG1s;PGI+aGk8L2I+\x1B\\" ++
            "\x1B]5522;type=read:status=DONE:id=r1\x1B\\",
        S.responseSlice(),
    );

    // Without the listing request `available` is ignored. The response
    // echoes the request terminator.
    S.responses_len = 0;
    s.nextSlice("\x1B]5522;type=read:id=r2;dGV4dC9wbGFpbg==\x07");
    try testing.expectEqual(clipboard.Location.standard, S.last_read_location);
    try testing.expectEqual(@as(usize, 1), S.last_read_mimes_len);
    try testing.expect(!S.last_read_list);
    try testing.expectEqualStrings(
        "\x1B]5522;type=read:status=OK:id=r2\x07" ++
            "\x1B]5522;type=read:status=DATA:id=r2:mime=dGV4dC9wbGFpbg==;R2hvc3R0eQ==\x07" ++
            "\x1B]5522;type=read:status=DONE:id=r2\x07",
        S.responseSlice(),
    );

    // A listing-only request carries no types.
    S.responses_len = 0;
    s.nextSlice("\x1B]5522;type=read;Lg==\x1B\\");
    try testing.expectEqual(@as(usize, 0), S.last_read_mimes_len);
    try testing.expect(S.last_read_list);
    try testing.expectEqualStrings(
        "\x1B]5522;type=read:status=OK\x1B\\" ++
            "\x1B]5522;type=read:status=DATA:mime=Lg==;dGV4dC9wbGFpbiB0ZXh0L2h0bWwK\x1B\\" ++
            "\x1B]5522;type=read:status=DONE\x1B\\",
        S.responseSlice(),
    );
}

test "kitty clipboard read result maps to response status" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = KittyClipboardCapture;

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_read = &S.clipboardRead;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    const cases = [_]struct {
        result: ?clipboard.Read.Result,
        response: []const u8,
    }{
        .{ .result = .denied, .response = "\x1B]5522;type=read:status=EPERM:id=x\x1B\\" },
        .{ .result = .unsupported, .response = "\x1B]5522;type=read:status=ENOSYS:id=x\x1B\\" },
        .{ .result = .busy, .response = "\x1B]5522;type=read:status=EBUSY:id=x\x1B\\" },
        .{ .result = .io_error, .response = "\x1B]5522;type=read:status=EIO:id=x\x1B\\" },
        // No reply at all is a denial rather than silence.
        .{ .result = null, .response = "\x1B]5522;type=read:status=EPERM:id=x\x1B\\" },
        // A success with nothing to serve is still OK then DONE.
        .{ .result = .{ .success = .{} }, .response = "\x1B]5522;type=read:status=OK:id=x\x1B\\" ++
            "\x1B]5522;type=read:status=DONE:id=x\x1B\\" },
    };

    for (cases) |case| {
        S.reset();
        S.read_result = case.result;
        s.nextSlice("\x1B]5522;type=read:id=x;dGV4dC9wbGFpbg==\x1B\\");
        try testing.expectEqual(@as(usize, 1), S.read_count);
        try testing.expectEqualStrings(case.response, S.responseSlice());
    }

    // A second reply is ignored.
    S.reset();
    S.read_result = .{ .success = .{ .contents = &.{.{ .mime = "text/plain", .data = "hello" }} } };
    S.read_reply_twice = true;
    s.nextSlice("\x1B]5522;type=read;dGV4dC9wbGFpbg==\x1B\\");
    try testing.expectEqualStrings(
        "\x1B]5522;type=read:status=OK\x1B\\" ++
            "\x1B]5522;type=read:status=DATA:mime=dGV4dC9wbGFpbg==;aGVsbG8=\x1B\\" ++
            "\x1B]5522;type=read:status=DONE\x1B\\",
        S.responseSlice(),
    );
}

test "kitty clipboard read caps requested types" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = KittyClipboardCapture;
    S.reset();

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_read = &S.clipboardRead;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    // "a/0 a/1 a/2 a/3 a/4 a/5 .": extras are dropped but the listing
    // request after them still counts.
    S.read_result = .{ .success = .{} };
    s.nextSlice("\x1B]5522;type=read;YS8wIGEvMSBhLzIgYS8zIGEvNCBhLzUgLg==\x1B\\");
    try testing.expectEqual(@as(usize, 1), S.read_count);
    try testing.expectEqual(kitty_clipboard.max_read_mimes, S.last_read_mimes_len);
    try testing.expectEqualStrings("a/0", S.readMimeAt(0));
    try testing.expectEqualStrings("a/3", S.readMimeAt(kitty_clipboard.max_read_mimes - 1));
    try testing.expect(S.last_read_list);
}

test "kitty clipboard read password grants" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = KittyClipboardCapture;
    S.reset();

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_read = &S.clipboardRead;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    // Every read requests a data type ("text/plain"): a request with
    // no data types never consults the grants at all.
    //
    // pw="secret", name="app": the first request isn't granted but the
    // reply may ask to remember it.
    S.read_result = .{ .success = .{ .remember = true } };
    s.nextSlice("\x1B]5522;type=read:pw=c2VjcmV0:name=YXBw;dGV4dC9wbGFpbg==\x1B\\");
    try testing.expectEqual(@as(usize, 1), S.read_count);
    try testing.expectEqualStrings("app", S.readName());
    try testing.expect(!S.last_read_granted);
    try testing.expect(S.last_read_can_remember);

    // The same password is now granted; a different one is not.
    S.read_result = .{ .success = .{} };
    s.nextSlice("\x1B]5522;type=read:pw=c2VjcmV0:name=YXBw;dGV4dC9wbGFpbg==\x1B\\");
    try testing.expect(S.last_read_granted);
    s.nextSlice("\x1B]5522;type=read:pw=b3RoZXI=:name=YXBw;dGV4dC9wbGFpbg==\x1B\\");
    try testing.expect(!S.last_read_granted);
    try testing.expect(S.last_read_can_remember);

    // A password without a name doesn't count: it is neither granted
    // nor rememberable, even if the reply asks.
    S.read_result = .{ .success = .{ .remember = true } };
    s.nextSlice("\x1B]5522;type=read:pw=c2VjcmV0;dGV4dC9wbGFpbg==\x1B\\");
    try testing.expectEqualStrings("", S.readName());
    try testing.expect(!S.last_read_granted);
    try testing.expect(!S.last_read_can_remember);
    s.nextSlice("\x1B]5522;type=read:pw=b3RoZXI=;dGV4dC9wbGFpbg==\x1B\\");
    try testing.expect(!S.last_read_can_remember);
    S.read_result = .{ .success = .{} };
    s.nextSlice("\x1B]5522;type=read:pw=b3RoZXI=:name=YXBw;dGV4dC9wbGFpbg==\x1B\\");
    try testing.expect(!S.last_read_granted);

    // A grant is advisory: the request is still forwarded and the
    // embedder may deny it.
    S.responses_len = 0;
    S.read_result = .denied;
    s.nextSlice("\x1B]5522;type=read:id=d:pw=c2VjcmV0:name=YXBw;dGV4dC9wbGFpbg==\x1B\\");
    try testing.expect(S.last_read_granted);
    try testing.expectEqualStrings(
        "\x1B]5522;type=read:status=EPERM:id=d\x1B\\",
        S.responseSlice(),
    );

    // Grants are freed with the stream (the testing allocator catches
    // the leak otherwise).
}

test "kitty clipboard read targets-only never consumes a one-time grant" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = KittyClipboardCapture;
    S.reset();

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_read = &S.clipboardRead;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    // A one-time read grant, as minted for a paste event.
    try s.handler.kitty_clipboard_grants.grant(testing.allocator, "otp", .read, true);

    // A targets-only read (payload ".") is prompt-exempt so it never
    // consults, and must not burn, the one-time password.
    S.read_result = .{ .success = .{} };
    s.nextSlice("\x1B]5522;type=read:pw=b3Rw:name=YXBw;Lg==\x1B\\");
    try testing.expectEqual(@as(usize, 1), S.read_count);
    try testing.expect(S.last_read_list);
    try testing.expectEqual(@as(usize, 0), S.last_read_mimes_len);
    try testing.expect(!S.last_read_granted);

    // The follow-up data read still consumes the grant, exactly once.
    s.nextSlice("\x1B]5522;type=read:pw=b3Rw:name=YXBw;dGV4dC9wbGFpbg==\x1B\\");
    try testing.expect(S.last_read_granted);
    s.nextSlice("\x1B]5522;type=read:pw=b3Rw:name=YXBw;dGV4dC9wbGFpbg==\x1B\\");
    try testing.expect(!S.last_read_granted);
}

test "kitty clipboard write password grants" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = KittyClipboardCapture;
    S.reset();

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_write = &S.clipboardWrite;
    handler.effects.clipboard_read = &S.clipboardRead;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    // pw="secret", name="app": the first commit isn't granted but the
    // reply may ask to remember it.
    S.write_result = .{ .success = .{ .remember = true } };
    s.nextSlice("\x1B]5522;type=write:pw=c2VjcmV0:name=YXBw\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata\x1B\\");
    try testing.expectEqual(@as(usize, 1), S.write_count);
    try testing.expectEqualStrings("app", S.writeName());
    try testing.expect(!S.last_write_granted);
    try testing.expect(S.last_write_can_remember);

    // The same password is now granted; a different one is not.
    S.write_result = .{ .success = .{} };
    s.nextSlice("\x1B]5522;type=write:pw=c2VjcmV0:name=YXBw\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata\x1B\\");
    try testing.expect(S.last_write_granted);
    s.nextSlice("\x1B]5522;type=write:pw=b3RoZXI=:name=YXBw\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata\x1B\\");
    try testing.expect(!S.last_write_granted);
    try testing.expect(S.last_write_can_remember);

    // Directions are independent: a write grant doesn't satisfy reads.
    S.read_result = .{ .success = .{} };
    s.nextSlice("\x1B]5522;type=read:pw=c2VjcmV0:name=YXBw\x1B\\");
    try testing.expect(!S.last_read_granted);

    // A password without a name doesn't count: it is neither granted
    // nor rememberable, even if the reply asks.
    S.write_result = .{ .success = .{ .remember = true } };
    s.nextSlice("\x1B]5522;type=write:pw=c2VjcmV0\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata\x1B\\");
    try testing.expectEqualStrings("", S.writeName());
    try testing.expect(!S.last_write_granted);
    try testing.expect(!S.last_write_can_remember);

    // A grant is advisory: the request is still forwarded and the
    // embedder may deny it.
    S.responses_len = 0;
    S.write_result = .denied;
    s.nextSlice("\x1B]5522;type=write:id=d:pw=c2VjcmV0:name=YXBw\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata\x1B\\");
    try testing.expect(S.last_write_granted);
    try testing.expectEqualStrings(
        "\x1B]5522;type=write:status=EPERM:id=d\x1B\\",
        S.responseSlice(),
    );

    // Grants are freed with the stream (the testing allocator catches
    // the leak otherwise).
}

test "kitty clipboard malformed packets are silently dropped" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = KittyClipboardCapture;
    S.reset();

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_write = &S.clipboardWrite;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    // Missing type, unknown type, bare metadata record, invalid mime
    // base64, and orphaned transaction packets all drop silently.
    s.nextSlice("\x1B]5522;loc=primary\x1B\\");
    s.nextSlice("\x1B]5522;type=bobr\x1B\\");
    s.nextSlice("\x1B]5522;type=read:bare\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata:mime=!!!;R2hvc3Q=\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata:mime=dGV4dC9wbGFpbg==;R2hvc3Q=\x1B\\");
    s.nextSlice("\x1B]5522;type=walias:mime=dGV4dC9wbGFpbg==;VEVYVA==\x1B\\");
    try testing.expectEqual(@as(usize, 0), S.write_count);
    try testing.expectEqual(@as(usize, 0), S.responses_len);
    try testing.expect(!s.handler.semantic_failure);

    // The terminal is still functional afterwards.
    s.nextSlice("ok");
    const str = try t.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("ok", str);
}

test "kitty clipboard new write replaces in-flight transaction" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = KittyClipboardCapture;
    S.reset();

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_write = &S.clipboardWrite;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    s.nextSlice("\x1B]5522;type=write:id=old\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata:mime=dGV4dC9wbGFpbg==;b2xk\x1B\\"); // "old"
    s.nextSlice("\x1B]5522;type=write:id=new\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata:mime=dGV4dC9wbGFpbg==;bmV3\x1B\\"); // "new"
    s.nextSlice("\x1B]5522;type=wdata\x1B\\");

    try testing.expectEqual(@as(usize, 1), S.write_count);
    try testing.expectEqual(@as(usize, 1), S.last_contents_len);
    try testing.expectEqualStrings("new", S.dataAt(0));
    try testing.expectEqualStrings(
        "\x1B]5522;type=write:status=DONE:id=new\x1B\\",
        S.responseSlice(),
    );
}

test "kitty clipboard invalid write packets abort with EINVAL" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = KittyClipboardCapture;
    S.reset();

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_write = &S.clipboardWrite;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    const invalid_packets = [_][]const u8{
        // Alias payload decodes to a non-UTF-8 byte.
        "\x1B]5522;type=walias:mime=dGV4dC9wbGFpbg==;/w==\x1B\\",
        // Alias has no target MIME type.
        "\x1B]5522;type=walias;VEVYVA==\x1B\\",
        // Alias target MIME decodes to non-UTF-8 bytes.
        "\x1B]5522;type=walias:mime=//4=;VEVYVA==\x1B\\",
        // Write data MIME decodes to non-UTF-8 bytes.
        "\x1B]5522;type=wdata:mime=//4=;R2hvc3Q=\x1B\\",
    };

    for (invalid_packets) |packet| {
        S.responses_len = 0;
        s.nextSlice("\x1B]5522;type=write:id=w\x1B\\");
        s.nextSlice("\x1B]5522;type=wdata:mime=dGV4dC9wbGFpbg==;R2hvc3Q=\x1B\\");
        s.nextSlice(packet);
        try testing.expectEqualStrings(
            "\x1B]5522;type=write:status=EINVAL:id=w\x1B\\",
            S.responseSlice(),
        );
        try testing.expect(!s.handler.semantic_failure);

        // The transaction is gone: a commit does nothing further.
        s.nextSlice("\x1B]5522;type=wdata\x1B\\");
        try testing.expectEqual(@as(usize, 0), S.write_count);
        try testing.expectEqualStrings(
            "\x1B]5522;type=write:status=EINVAL:id=w\x1B\\",
            S.responseSlice(),
        );
    }
}

test "kitty clipboard invalid read text does not abort a write" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = KittyClipboardCapture;
    S.reset();
    S.read_result = .{ .success = .{} };

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_read = &S.clipboardRead;
    handler.effects.clipboard_write = &S.clipboardWrite;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    s.nextSlice("\x1B]5522;type=write:id=w\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata:mime=dGV4dC9wbGFpbg==;R2hvc3Q=\x1B\\");

    // The read payload decodes to a non-UTF-8 byte. It is dropped without
    // invoking the clipboard effect or disturbing the write transaction.
    s.nextSlice("\x1B]5522;type=read;/w==\x1B\\");
    try testing.expectEqual(@as(usize, 0), S.read_count);
    try testing.expectEqual(@as(usize, 0), S.responses_len);

    s.nextSlice("\x1B]5522;type=wdata\x1B\\");
    try testing.expectEqual(@as(usize, 1), S.write_count);
    try testing.expectEqualStrings(
        "\x1B]5522;type=write:status=DONE:id=w\x1B\\",
        S.responseSlice(),
    );
}

test "kitty clipboard oversized text write aborts with EFBIG" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = KittyClipboardCapture;
    S.reset();

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_write = &S.clipboardWrite;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    // Shrink the limit so the test doesn't have to stream the
    // default 64MiB.
    s.handler.kitty_clipboard_write_max_bytes = 4;

    s.nextSlice("\x1B]5522;type=write:id=w\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata:mime=dGV4dC9wbGFpbg==;SGVsbA==\x1B\\"); // "Hell"
    try testing.expectEqual(@as(usize, 0), S.responses_len);
    s.nextSlice("\x1B]5522;type=wdata:mime=dGV4dC9wbGFpbg==;bw==\x1B\\"); // "o"
    try testing.expectEqualStrings(
        "\x1B]5522;type=write:status=EFBIG:id=w\x1B\\",
        S.responseSlice(),
    );
    try testing.expect(!s.handler.semantic_failure);

    // The transaction is gone: later data and the commit do nothing.
    s.nextSlice("\x1B]5522;type=wdata:mime=dGV4dC9wbGFpbg==;IQ==\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata\x1B\\");
    try testing.expectEqual(@as(usize, 0), S.write_count);
    try testing.expectEqualStrings(
        "\x1B]5522;type=write:status=EFBIG:id=w\x1B\\",
        S.responseSlice(),
    );
}

test "kitty clipboard invalid wdata chunk aborts with EINVAL" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = KittyClipboardCapture;
    S.reset();

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_write = &S.clipboardWrite;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    s.nextSlice("\x1B]5522;type=write:id=w\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata:mime=dGV4dC9wbGFpbg==;SGVsbG8=\x1B\\"); // "Hello"
    s.nextSlice("\x1B]5522;type=wdata:mime=dGV4dC9wbGFpbg==;!!!bad!!!\x1B\\");
    try testing.expectEqualStrings(
        "\x1B]5522;type=write:status=EINVAL:id=w\x1B\\",
        S.responseSlice(),
    );
    try testing.expect(!s.handler.semantic_failure);

    // The transaction is gone: later data and the commit do nothing.
    s.nextSlice("\x1B]5522;type=wdata:mime=dGV4dC9wbGFpbg==;V29ybGQ=\x1B\\"); // "World"
    s.nextSlice("\x1B]5522;type=wdata\x1B\\");
    try testing.expectEqual(@as(usize, 0), S.write_count);
    try testing.expectEqualStrings(
        "\x1B]5522;type=write:status=EINVAL:id=w\x1B\\",
        S.responseSlice(),
    );
}

test "kitty clipboard wdata chunks split one base64 stream" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = KittyClipboardCapture;
    S.reset();

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_write = &S.clipboardWrite;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    // "some data" encoded as one stream, split at non-group
    // boundaries across packets.
    s.nextSlice("\x1B]5522;type=write\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata:mime=dGV4dC9wbGFpbg==;c29\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata:mime=dGV4dC9wbGFpbg==;tZSBk\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata:mime=dGV4dC9wbGFpbg==;YXRh\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata\x1B\\");

    try testing.expectEqual(@as(usize, 1), S.write_count);
    try testing.expectEqualStrings("some data", S.dataAt(0));
    try testing.expectEqualStrings(
        "\x1B]5522;type=write:status=DONE\x1B\\",
        S.responseSlice(),
    );
}

test "kitty clipboard unpadded wdata stream aborts at commit" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = KittyClipboardCapture;
    S.reset();

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_write = &S.clipboardWrite;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    // "Hello" without its final padding byte: every packet decodes,
    // but the stream ends mid-group so the commit reports EINVAL.
    s.nextSlice("\x1B]5522;type=write:id=w\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata:mime=dGV4dC9wbGFpbg==;SGVsbG8\x1B\\");
    try testing.expectEqual(@as(usize, 0), S.responses_len);
    s.nextSlice("\x1B]5522;type=wdata\x1B\\");
    try testing.expectEqual(@as(usize, 0), S.write_count);
    try testing.expectEqualStrings(
        "\x1B]5522;type=write:status=EINVAL:id=w\x1B\\",
        S.responseSlice(),
    );
    try testing.expect(!s.handler.semantic_failure);
}

test "kitty clipboard in-flight transaction is freed on deinit" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = KittyClipboardCapture;
    S.reset();

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_write = &S.clipboardWrite;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    // Never committed: stream deinit must free the transaction (the
    // testing allocator catches the leak otherwise).
    s.nextSlice("\x1B]5522;type=write\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata:mime=dGV4dC9wbGFpbg==;R2hvc3Q=\x1B\\");
    try testing.expectEqual(@as(usize, 0), S.write_count);
}

test "kitty clipboard allocation failure is ignored" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = KittyClipboardCapture;
    S.reset();

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_write = &S.clipboardWrite;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    // Only transaction state uses the terminal allocator here. Swap in
    // an allocator that always fails, then restore it before teardown.
    {
        const alloc = t.screens.active.alloc;
        t.screens.active.alloc = testing.failing_allocator;
        defer t.screens.active.alloc = alloc;
        s.nextSlice("\x1B]5522;type=write\x1B\\");
    }

    // Clipboard writes are external effects, best-effort like OSC 52;
    // the failed transaction never started and is not a semantic
    // failure.
    try testing.expect(!s.handler.semantic_failure);
    s.nextSlice("\x1B]5522;type=wdata:mime=dGV4dC9wbGFpbg==;R2hvc3Q=\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata\x1B\\");
    try testing.expectEqual(@as(usize, 0), S.write_count);
    try testing.expectEqual(@as(usize, 0), S.responses_len);
}

test "kitty clipboard without write_pty still commits writes" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = KittyClipboardCapture;
    S.reset();

    var handler: Handler = .init(&t);
    handler.effects.clipboard_write = &S.clipboardWrite;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    s.nextSlice("\x1B]5522;type=write\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata:mime=dGV4dC9wbGFpbg==;R2hvc3Q=\x1B\\");
    s.nextSlice("\x1B]5522;type=wdata\x1B\\");
    try testing.expectEqual(@as(usize, 1), S.write_count);
    try testing.expectEqualStrings("Ghost", S.dataAt(0));

    // Reads are dropped without a way to respond.
    s.nextSlice("\x1B]5522;type=read\x1B\\");
    try testing.expectEqual(@as(usize, 0), S.responses_len);
}

test "request mode DECRQM with write_pty callback" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    // Without callback, DECRQM should not crash
    {
        var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
        defer s.deinit();

        // DECRQM for mode 7 (wraparound) — should be silently ignored
        s.nextSlice("\x1B[?7$p");
    }

    t.fullReset();

    // With callback, DECRQM should produce a response
    {
        const S = struct {
            var last_response: ?[:0]const u8 = null;
            fn writePty(_: *Handler, data: []const u8) void {
                if (last_response) |old| testing.allocator.free(old);
                last_response = testing.allocator.dupeZ(u8, data) catch @panic("OOM");
            }
        };
        S.last_response = null;
        defer if (S.last_response) |old| testing.allocator.free(old);

        var handler: Handler = .init(&t);
        handler.effects.write_pty = &S.writePty;

        var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
        defer s.deinit();

        // Wraparound mode (7) is set by default
        s.nextSlice("\x1B[?7$p");
        try testing.expectEqualStrings("\x1B[?7;1$y", S.last_response.?);

        // Disable wraparound and query again
        s.nextSlice("\x1B[?7l");
        s.nextSlice("\x1B[?7$p");
        try testing.expectEqualStrings("\x1B[?7;2$y", S.last_response.?);

        // Query an unknown mode
        s.nextSlice("\x1B[?9999$p");
        try testing.expectEqualStrings("\x1B[?9999;0$y", S.last_response.?);

        // Query DECECM, which Ghostty recognizes but does not allow changing
        s.nextSlice("\x1B[?117$p");
        try testing.expectEqualStrings("\x1B[?117;4$y", S.last_response.?);
    }
}

test "stream: CSI W with intermediate but no params" {
    // Regression test from AFL++ crash. CSI ? W without
    // parameters caused an out-of-bounds access on input.params[0].
    var t: Terminal = try .init(testing.io, testing.allocator, .{
        .cols = 80,
        .rows = 24,
        .max_scrollback_bytes = 100,
    });
    defer t.deinit(testing.allocator);

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();

    s.nextSlice("\x1b[?W");
}

test "window_title effect is called" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var title_changed_count: usize = 0;
        fn titleChanged(_: *Handler) void {
            title_changed_count += 1;
        }
    };
    S.title_changed_count = 0;

    var handler: Handler = .init(&t);
    handler.effects.title_changed = &S.titleChanged;

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    // Set window title via OSC 2
    s.nextSlice("\x1b]2;Hello World\x1b\\");
    try testing.expectEqualStrings("Hello World", t.getTitle().?);
    try testing.expectEqual(@as(usize, 1), S.title_changed_count);
}

test "window_title effect not called without callback" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();

    // Should not crash when no callback is set
    s.nextSlice("\x1b]2;Hello World\x1b\\");

    // Title should still be set on terminal state
    try testing.expectEqualStrings("Hello World", t.getTitle().?);

    // Terminal should still be functional
    s.nextSlice("Test");
    const str = try t.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("Test", str);
}

test "window_title effect with empty title" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var title_changed_count: usize = 0;
        fn titleChanged(_: *Handler) void {
            title_changed_count += 1;
        }
    };
    S.title_changed_count = 0;

    var handler: Handler = .init(&t);
    handler.effects.title_changed = &S.titleChanged;

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    // Set empty window title
    s.nextSlice("\x1b]2;\x1b\\");
    try testing.expect(t.getTitle() == null);
    try testing.expectEqual(@as(usize, 1), S.title_changed_count);
}

test "kitty_keyboard_query" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var written: ?[]const u8 = null;
        var written_buf: [64]u8 = undefined;
        fn writePty(_: *Handler, data: []const u8) void {
            std.debug.assert(data.len <= written_buf.len);
            @memcpy(written_buf[0..data.len], data);
            written = written_buf[0..data.len];
        }
    };
    S.written = null;

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    // Default kitty keyboard flags should be 0
    s.nextSlice("\x1b[?u");
    try testing.expectEqualStrings("\x1b[?0u", S.written.?);

    // Push kitty keyboard mode with flags and query again
    S.written = null;
    s.nextSlice("\x1b[>1u"); // push with disambiguate flag
    s.nextSlice("\x1b[?u");
    try testing.expectEqualStrings("\x1b[?1u", S.written.?);
}

test "xtversion default" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var written: ?[]const u8 = null;
        var written_buf: [64]u8 = undefined;
        fn writePty(_: *Handler, data: []const u8) void {
            std.debug.assert(data.len <= written_buf.len);
            @memcpy(written_buf[0..data.len], data);
            written = written_buf[0..data.len];
        }
    };
    S.written = null;

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    // Without xtversion effect set, should report "libghostty"
    s.nextSlice("\x1b[>0q");
    try testing.expectEqualStrings("\x1bP>|libghostty\x1b\\", S.written.?);
}

test "xtversion with effect" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var written: ?[]const u8 = null;
        var written_buf: [64]u8 = undefined;
        fn writePty(_: *Handler, data: []const u8) void {
            std.debug.assert(data.len <= written_buf.len);
            @memcpy(written_buf[0..data.len], data);
            written = written_buf[0..data.len];
        }
        fn xtversion(_: *Handler) []const u8 {
            return "ghostty 1.2.3";
        }
    };
    S.written = null;

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.xtversion = &S.xtversion;

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    s.nextSlice("\x1b[>0q");
    try testing.expectEqualStrings("\x1bP>|ghostty 1.2.3\x1b\\", S.written.?);
}

test "xtversion with empty string effect" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var written: ?[]const u8 = null;
        var written_buf: [64]u8 = undefined;
        fn writePty(_: *Handler, data: []const u8) void {
            std.debug.assert(data.len <= written_buf.len);
            @memcpy(written_buf[0..data.len], data);
            written = written_buf[0..data.len];
        }
        fn xtversion(_: *Handler) []const u8 {
            return "";
        }
    };
    S.written = null;

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.xtversion = &S.xtversion;

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    // Empty string from effect should fall back to "libghostty"
    s.nextSlice("\x1b[>0q");
    try testing.expectEqualStrings("\x1bP>|libghostty\x1b\\", S.written.?);
}

test "size report csi_14_t with effect" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: []const u8) void {
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
        fn getSize(_: *Handler) ?size_report.Size {
            return .{ .rows = 24, .columns = 80, .cell_width = 9, .cell_height = 18 };
        }
    };
    S.written = null;

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.size = &S.getSize;

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    // CSI 14 t - report text area size in pixels
    s.nextSlice("\x1b[14t");
    defer testing.allocator.free(S.written.?);
    try testing.expectEqualStrings("\x1b[4;432;720t", S.written.?);
}

test "mode 2048 enable reports current geometry and disable is silent" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var response: [128]u8 = undefined;
        var response_len: usize = 0;
        var calls: usize = 0;

        fn writePty(_: *Handler, data: []const u8) void {
            @memcpy(response[0..data.len], data);
            response_len = data.len;
            calls += 1;
        }

        fn getSize(_: *Handler) ?size_report.Size {
            return .{ .rows = 24, .columns = 80, .cell_width = 8, .cell_height = 16 };
        }
    };
    S.response_len = 0;
    S.calls = 0;

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.size = &S.getSize;

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    s.nextSlice("\x1b[?2048h");
    s.nextSlice("\x1b[?2048h");

    try testing.expectEqual(@as(usize, 2), S.calls);
    try testing.expectEqualStrings("\x1b[48;24;80;384;640t", S.response[0..S.response_len]);

    s.nextSlice("\x1b[?2048l");
    try testing.expectEqual(@as(usize, 2), S.calls);
    try testing.expect(!t.modes.get(.in_band_size_reports));
}

test "mode 2048 enable tolerates missing effects" {
    const S = struct {
        var calls: usize = 0;

        fn writePty(_: *Handler, _: []const u8) void {
            calls += 1;
        }

        fn getSize(_: *Handler) ?size_report.Size {
            return .{ .rows = 24, .columns = 80, .cell_width = 8, .cell_height = 16 };
        }
    };
    S.calls = 0;

    var no_size_terminal: Terminal = try .init(
        testing.io,
        testing.allocator,
        .{ .cols = 80, .rows = 24 },
    );
    defer no_size_terminal.deinit(testing.allocator);
    var no_size_handler: Handler = .init(&no_size_terminal);
    no_size_handler.effects.write_pty = &S.writePty;
    var no_size_stream: Stream = .init(.{
        .allocator = testing.allocator,
        .handler = no_size_handler,
    });
    defer no_size_stream.deinit();

    no_size_stream.nextSlice("\x1b[?2048h");
    try testing.expect(no_size_terminal.modes.get(.in_band_size_reports));
    try testing.expectEqual(@as(usize, 0), S.calls);

    var no_write_terminal: Terminal = try .init(
        testing.io,
        testing.allocator,
        .{ .cols = 80, .rows = 24 },
    );
    defer no_write_terminal.deinit(testing.allocator);
    var no_write_handler: Handler = .init(&no_write_terminal);
    no_write_handler.effects.size = &S.getSize;
    var no_write_stream: Stream = .init(.{
        .allocator = testing.allocator,
        .handler = no_write_handler,
    });
    defer no_write_stream.deinit();

    no_write_stream.nextSlice("\x1b[?2048h");
    try testing.expect(no_write_terminal.modes.get(.in_band_size_reports));
    try testing.expectEqual(@as(usize, 0), S.calls);
}

test "size report csi_16_t with effect" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: []const u8) void {
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
        fn getSize(_: *Handler) ?size_report.Size {
            return .{ .rows = 24, .columns = 80, .cell_width = 9, .cell_height = 18 };
        }
    };
    S.written = null;

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.size = &S.getSize;

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    // CSI 16 t - report cell size in pixels
    s.nextSlice("\x1b[16t");
    defer testing.allocator.free(S.written.?);
    try testing.expectEqualStrings("\x1b[6;18;9t", S.written.?);
}

test "size report csi_18_t with effect" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: []const u8) void {
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
        fn getSize(_: *Handler) ?size_report.Size {
            return .{ .rows = 24, .columns = 80, .cell_width = 9, .cell_height = 18 };
        }
    };
    S.written = null;

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.size = &S.getSize;

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    // CSI 18 t - report text area size in characters
    s.nextSlice("\x1b[18t");
    defer testing.allocator.free(S.written.?);
    try testing.expectEqualStrings("\x1b[8;24;80t", S.written.?);
}

test "size report no effect callback" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: []const u8) void {
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
    };
    S.written = null;

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    // Without size effect, size reports should be silently ignored
    s.nextSlice("\x1b[14t");
    try testing.expect(S.written == null);
}

test "size report csi_21_t title disabled by default" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: []const u8) void {
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
    };
    S.written = null;

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    // Set a title first
    s.nextSlice("\x1b]2;My Title\x1b\\");

    // CSI 21 t - report title (no size effect needed)
    s.nextSlice("\x1b[21t");
    try testing.expect(S.written == null);
}

test "size report csi_21_t title enabled" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: []const u8) void {
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
    };
    S.written = null;

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.title_report = true;

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    // Set a title first
    s.nextSlice("\x1b]2;My Title\x1b\\");

    // CSI 21 t - report title (no size effect needed)
    s.nextSlice("\x1b[21t");
    defer testing.allocator.free(S.written.?);
    try testing.expectEqualStrings("\x1b]lMy Title\x1b\\", S.written.?);
}

test "enquiry no effect" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: []const u8) void {
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
    };
    S.written = null;

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    // ENQ without enquiry effect should not write anything
    s.nextSlice("\x05");
    try testing.expect(S.written == null);
}

test "enquiry with effect" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: []const u8) void {
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
        fn enquiry(_: *Handler) []const u8 {
            return "ghostty";
        }
    };
    S.written = null;

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.enquiry = &S.enquiry;

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    s.nextSlice("\x05");
    defer testing.allocator.free(S.written.?);
    try testing.expectEqualStrings("ghostty", S.written.?);
}

test "enquiry with empty response" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: []const u8) void {
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
        fn enquiry(_: *Handler) []const u8 {
            return "";
        }
    };
    S.written = null;

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.enquiry = &S.enquiry;

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    // Empty enquiry response should not write anything
    s.nextSlice("\x05");
    try testing.expect(S.written == null);
}

test "device status: operating status" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: []const u8) void {
            if (written) |old| testing.allocator.free(old);
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
    };
    S.written = null;
    defer if (S.written) |old| testing.allocator.free(old);

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    // CSI 5 n — operating status report
    s.nextSlice("\x1B[5n");
    try testing.expectEqualStrings("\x1B[0n", S.written.?);
}

test "device status: cursor position" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: []const u8) void {
            if (written) |old| testing.allocator.free(old);
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
    };
    S.written = null;
    defer if (S.written) |old| testing.allocator.free(old);

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    // Default position is 0,0 — reported as 1,1
    s.nextSlice("\x1B[6n");
    try testing.expectEqualStrings("\x1B[1;1R", S.written.?);

    // Move cursor to row 5, col 10
    s.nextSlice("\x1B[5;10H");
    s.nextSlice("\x1B[6n");
    try testing.expectEqualStrings("\x1B[5;10R", S.written.?);
}

test "device status: cursor position with origin mode" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: []const u8) void {
            if (written) |old| testing.allocator.free(old);
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
    };
    S.written = null;
    defer if (S.written) |old| testing.allocator.free(old);

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    // Set scroll region rows 5-20
    s.nextSlice("\x1B[5;20r");
    // Enable origin mode
    s.nextSlice("\x1B[?6h");
    // Move to row 3, col 5 within the region
    s.nextSlice("\x1B[3;5H");
    // Query cursor position
    s.nextSlice("\x1B[6n");
    // Should report position relative to the scroll region
    try testing.expectEqualStrings("\x1B[3;5R", S.written.?);
}

test "device status: color scheme dark" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: []const u8) void {
            if (written) |old| testing.allocator.free(old);
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
        fn colorScheme(_: *Handler) ?device_status.ColorScheme {
            return .dark;
        }
    };
    S.written = null;
    defer if (S.written) |old| testing.allocator.free(old);

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.color_scheme = &S.colorScheme;

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    // CSI ? 996 n — color scheme query
    s.nextSlice("\x1B[?996n");
    try testing.expectEqualStrings("\x1B[?997;1n", S.written.?);
}

test "device status: color scheme light" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: []const u8) void {
            if (written) |old| testing.allocator.free(old);
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
        fn colorScheme(_: *Handler) ?device_status.ColorScheme {
            return .light;
        }
    };
    S.written = null;
    defer if (S.written) |old| testing.allocator.free(old);

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.color_scheme = &S.colorScheme;

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    // CSI ? 996 n — color scheme query
    s.nextSlice("\x1B[?996n");
    try testing.expectEqualStrings("\x1B[?997;2n", S.written.?);
}

test "device status: color scheme without callback" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: []const u8) void {
            if (written) |old| testing.allocator.free(old);
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
    };
    S.written = null;
    defer if (S.written) |old| testing.allocator.free(old);

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    // Without color_scheme effect, query should be silently ignored
    s.nextSlice("\x1B[?996n");
    try testing.expect(S.written == null);
}

test "visibility reports" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var written: ?[]const u8 = null;
        var count: usize = 0;

        fn writePty(_: *Handler, data: []const u8) void {
            if (written) |old| testing.allocator.free(old);
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
            count += 1;
        }
    };
    S.written = null;
    S.count = 0;
    defer if (S.written) |old| testing.allocator.free(old);

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    // Mode 2033 is supported and initially disabled.
    s.nextSlice("\x1B[?2033$p");
    try testing.expectEqualStrings("\x1B[?2033;2$y", S.written.?);

    // A one-shot query reports the current state without enabling the mode.
    s.nextSlice("\x1B[?998n");
    try testing.expectEqualStrings("\x1B[?999;1n", S.written.?);
    try testing.expect(!t.modes.get(.report_visibility));

    // Enabling always sends an immediate report, even when already enabled.
    t.flags.visible = false;
    s.nextSlice("\x1B[?2033h");
    try testing.expectEqualStrings("\x1B[?999;2n", S.written.?);
    const count = S.count;
    s.nextSlice("\x1B[?2033h");
    try testing.expectEqual(count + 1, S.count);

    // Disabling sends no report.
    s.nextSlice("\x1B[?2033l");
    try testing.expectEqual(count + 1, S.count);

    // A terminal reset preserves the view's externally owned visibility.
    s.nextSlice("\x1Bc");
    s.nextSlice("\x1B[?998n");
    try testing.expectEqualStrings("\x1B[?999;2n", S.written.?);
}

test "device status: readonly ignores all" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();

    // All device status queries should be silently ignored without effects
    s.nextSlice("\x1B[5n");
    s.nextSlice("\x1B[6n");
    s.nextSlice("\x1B[?996n");
    s.nextSlice("\x1B[?998n");

    // Terminal should still be functional
    s.nextSlice("Test");
    const str = try t.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("Test", str);
}

test "device attributes: primary DA" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: []const u8) void {
            if (written) |old| testing.allocator.free(old);
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
        fn da(_: *Handler) device_attributes.Attributes {
            return .{};
        }
    };
    S.written = null;
    defer if (S.written) |old| testing.allocator.free(old);

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.device_attributes = &S.da;

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    s.nextSlice("\x1B[c");
    try testing.expectEqualStrings("\x1b[?62;22c", S.written.?);
}

test "device attributes: secondary DA" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: []const u8) void {
            if (written) |old| testing.allocator.free(old);
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
        fn da(_: *Handler) device_attributes.Attributes {
            return .{};
        }
    };
    S.written = null;
    defer if (S.written) |old| testing.allocator.free(old);

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.device_attributes = &S.da;

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    s.nextSlice("\x1B[>c");
    try testing.expectEqualStrings("\x1b[>1;0;0c", S.written.?);
}

test "device attributes: tertiary DA" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: []const u8) void {
            if (written) |old| testing.allocator.free(old);
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
        fn da(_: *Handler) device_attributes.Attributes {
            return .{};
        }
    };
    S.written = null;
    defer if (S.written) |old| testing.allocator.free(old);

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.device_attributes = &S.da;

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    s.nextSlice("\x1B[=c");
    try testing.expectEqualStrings("\x1bP!|00000000\x1b\\", S.written.?);
}

test "device attributes: readonly ignores" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();

    // All DA queries should be silently ignored without effects
    s.nextSlice("\x1B[c");
    s.nextSlice("\x1B[>c");
    s.nextSlice("\x1B[=c");

    // Terminal should still be functional
    s.nextSlice("Test");
    const str = try t.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("Test", str);
}

test "device attributes: custom response" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: []const u8) void {
            if (written) |old| testing.allocator.free(old);
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
        fn da(_: *Handler) device_attributes.Attributes {
            return .{
                .primary = .{
                    .conformance_level = .vt420,
                    .features = &.{ .ansi_color, .clipboard },
                },
                .secondary = .{
                    .device_type = .vt420,
                    .firmware_version = 100,
                },
            };
        }
    };
    S.written = null;
    defer if (S.written) |old| testing.allocator.free(old);

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.device_attributes = &S.da;

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    s.nextSlice("\x1B[c");
    try testing.expectEqualStrings("\x1b[?64;22;52c", S.written.?);

    s.nextSlice("\x1B[>c");
    try testing.expectEqualStrings("\x1b[>41;100;0c", S.written.?);
}

test "kitty graphics APC response" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: []const u8) void {
            if (written) |old| testing.allocator.free(old);
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
    };
    S.written = null;
    defer if (S.written) |old| testing.allocator.free(old);

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    // Send a kitty graphics transmit command with image id 1
    s.nextSlice("\x1b_Ga=t,t=d,f=24,i=1,s=1,v=2,c=10,r=1;////////\x1b\\");

    // Should have written a response back
    try testing.expectEqualStrings("\x1b_Gi=1;OK\x1b\\", S.written.?);
}

test "kitty graphics via APC" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    const handler: Handler = .init(&t);
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    // Send a kitty graphics transmit command via APC:
    // ESC _ G <payload> ESC \
    // a=t,t=d,f=24,i=1,s=1,v=2,c=10,r=1;//////// (1x2 RGB direct)
    s.nextSlice("\x1b_Ga=t,t=d,f=24,i=1,s=1,v=2,c=10,r=1;////////\x1b\\");

    const storage = &t.screens.active.kitty_images;
    const img = storage.imageById(1).?;
    try testing.expectEqual(.rgb, img.format);
}

test "continuation reconstructs standard stream without duplicate effects" {
    const S = struct {
        var bell_count: usize = 0;
        var title_count: usize = 0;
        var write_count: usize = 0;
        var notification_count: usize = 0;
        var clipboard_count: usize = 0;

        fn bell(_: *Handler) void {
            bell_count += 1;
        }

        fn titleChanged(_: *Handler) void {
            title_count += 1;
        }

        fn writePty(_: *Handler, _: []const u8) void {
            write_count += 1;
        }

        fn desktopNotification(
            _: *Handler,
            _: Action.ShowDesktopNotification,
        ) void {
            notification_count += 1;
        }

        fn clipboardWrite(
            _: *Handler,
            write: clipboard.Write,
        ) void {
            clipboard_count += 1;
            write.reply(.{ .success = .{} });
        }

        fn reset() void {
            bell_count = 0;
            title_count = 0;
            write_count = 0;
            notification_count = 0;
            clipboard_count = 0;
        }
    };
    S.reset();

    const committed = "A\n\x07" ++
        "\x1b]2;title\x1b\\" ++
        "\x1b[5n" ++
        "\x1b]9;body\x1b\\" ++
        "\x1b]52;c;aA==\x1b\\";

    var source_terminal: Terminal = try .init(
        testing.io,
        testing.allocator,
        .{ .cols = 80, .rows = 24 },
    );
    defer source_terminal.deinit(testing.allocator);

    var source_handler: Handler = .init(&source_terminal);
    source_handler.effects.bell = &S.bell;
    source_handler.effects.title_changed = &S.titleChanged;
    source_handler.effects.write_pty = &S.writePty;
    source_handler.effects.desktop_notification = &S.desktopNotification;
    source_handler.effects.clipboard_write = &S.clipboardWrite;
    var source = Stream.init(.{
        .allocator = testing.allocator,
        .handler = source_handler,
        .continuation_max_bytes = 1024,
    });
    defer source.deinit();

    // Terminal mutation and all callbacks have already committed. The
    // unfinished CSI is the only input needed to recreate the stream state.
    source.nextSlice(committed ++ "\x1b[31");
    try testing.expectEqual(@as(usize, 1), S.bell_count);
    try testing.expectEqual(@as(usize, 1), S.title_count);
    try testing.expectEqual(@as(usize, 1), S.write_count);
    try testing.expectEqual(@as(usize, 1), S.notification_count);
    try testing.expectEqual(@as(usize, 1), S.clipboard_count);

    var continuation_buf: [1024]u8 = undefined;
    var continuation_writer: std.Io.Writer = .fixed(&continuation_buf);
    try source.writeContinuation(&continuation_writer);
    try testing.expectEqualStrings("\x1b[31", continuation_writer.buffered());

    var restored_terminal: Terminal = try .init(
        testing.io,
        testing.allocator,
        .{ .cols = 80, .rows = 24 },
    );
    defer restored_terminal.deinit(testing.allocator);

    // Stand in for restoring the already-committed terminal snapshot.
    {
        var snapshot_stream: Stream = .init(.{
            .allocator = testing.allocator,
            .handler = .init(&restored_terminal),
        });
        defer snapshot_stream.deinit();
        snapshot_stream.nextSlice(committed);
    }

    const before = try restored_terminal.plainString(testing.allocator);
    defer testing.allocator.free(before);
    const before_x = restored_terminal.screens.active.cursor.x;
    const before_y = restored_terminal.screens.active.cursor.y;
    const before_style = restored_terminal.screens.active.cursor.style_id;
    const before_title = restored_terminal.getTitle().?;

    var restored_handler: Handler = .init(&restored_terminal);
    restored_handler.effects.bell = &S.bell;
    restored_handler.effects.title_changed = &S.titleChanged;
    restored_handler.effects.write_pty = &S.writePty;
    restored_handler.effects.desktop_notification = &S.desktopNotification;
    restored_handler.effects.clipboard_write = &S.clipboardWrite;
    var restored = Stream.init(.{
        .allocator = testing.allocator,
        .handler = restored_handler,
        .continuation_max_bytes = 1024,
    });
    defer restored.deinit();

    S.reset();
    restored.nextSlice(continuation_writer.buffered());
    try testing.expectEqual(@as(usize, 0), S.bell_count);
    try testing.expectEqual(@as(usize, 0), S.title_count);
    try testing.expectEqual(@as(usize, 0), S.write_count);
    try testing.expectEqual(@as(usize, 0), S.notification_count);
    try testing.expectEqual(@as(usize, 0), S.clipboard_count);
    const after = try restored_terminal.plainString(testing.allocator);
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(before, after);
    try testing.expectEqual(before_x, restored_terminal.screens.active.cursor.x);
    try testing.expectEqual(before_y, restored_terminal.screens.active.cursor.y);
    try testing.expectEqual(before_style, restored_terminal.screens.active.cursor.style_id);
    try testing.expectEqualStrings(before_title, restored_terminal.getTitle().?);

    source.nextSlice("mB");
    restored.nextSlice("mB");
    const source_text = try source_terminal.plainString(testing.allocator);
    defer testing.allocator.free(source_text);
    const restored_text = try restored_terminal.plainString(testing.allocator);
    defer testing.allocator.free(restored_text);
    try testing.expectEqualStrings(source_text, restored_text);
    try testing.expectEqual(
        source_terminal.screens.active.cursor.style_id,
        restored_terminal.screens.active.cursor.style_id,
    );
}

test "kitty dnd: query response" {
    const S = struct {
        var pty: std.ArrayListUnmanaged(u8) = .empty;
        fn writePty(_: *Handler, data: []const u8) void {
            pty.appendSlice(testing.allocator, data) catch unreachable;
        }
    };
    S.pty = .empty;
    defer S.pty.deinit(testing.allocator);

    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    s.nextSlice("\x1B]72;t=q:i=3\x1B\\");
    try testing.expectEqualStrings("\x1b]72;t=q:i=3\x1b\\", S.pty.items);
}

test "kitty dnd: register, drop, and serve data" {
    const S = struct {
        var pty: std.ArrayListUnmanaged(u8) = .empty;
        fn writePty(_: *Handler, data: []const u8) void {
            pty.appendSlice(testing.allocator, data) catch unreachable;
        }
    };
    S.pty = .empty;
    defer S.pty.deinit(testing.allocator);

    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    // Client registers to accept drops.
    s.nextSlice("\x1B]72;t=a;text/plain text/uri-list\x1B\\");
    try testing.expectEqualStrings("", S.pty.items);
    try testing.expect(t.kitty_dnd != null);

    // A native drop arrives; the embedder feeds it to the terminal
    // state and delivers the produced event bytes itself.
    {
        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        try t.kitty_dnd.?.dragDrop(testing.allocator, &aw.writer, .{
            .cell_x = 2,
            .cell_y = 1,
            .pixel_x = 20,
            .pixel_y = 18,
            .operations = .{ .copy = true },
        }, &.{
            .{ .mime = "text/plain", .data = "hello" },
        });
        try testing.expectEqualStrings(
            "\x1b]72;t=M:x=2:y=1:X=20:Y=18:o=1:m=0;text/plain \x1b\\",
            aw.written(),
        );
    }

    // The client requests the data and concludes.
    s.nextSlice("\x1B]72;t=r:x=1\x1B\\");
    try testing.expectEqualStrings(
        "\x1b]72;t=r:x=1:m=0;aGVsbG8=\x1b\\" ++ "\x1b]72;t=r:x=1\x1b\\",
        S.pty.items,
    );
    S.pty.clearRetainingCapacity();

    s.nextSlice("\x1B]72;t=r\x1B\\");
    try testing.expectEqualStrings("", S.pty.items);
    try testing.expect(t.kitty_dnd.?.drop.items == null);
}

test "kitty dnd: state updates work without write_pty effect" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = .init(&t) });
    defer s.deinit();

    // Queries produce no output (nowhere to write) but registration
    // state still updates.
    s.nextSlice("\x1B]72;t=q\x1B\\");
    s.nextSlice("\x1B]72;t=a\x1B\\");
    try testing.expect(t.kitty_dnd != null);

    // The terminal remains functional.
    s.nextSlice("ok");
    const str = try t.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("ok", str);
}

test "kitty dnd: registration survives terminal reset" {
    const S = struct {
        var pty: std.ArrayListUnmanaged(u8) = .empty;
        fn writePty(_: *Handler, data: []const u8) void {
            pty.appendSlice(testing.allocator, data) catch unreachable;
        }
    };
    S.pty = .empty;
    defer S.pty.deinit(testing.allocator);

    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    // Start a chunked command, then reset mid-chunk.
    s.nextSlice("\x1B]72;t=a:i=5\x1B\\");
    s.nextSlice("\x1B]72;t=m:o=1:m=1;text/pl\x1B\\");
    s.nextSlice("\x1Bc");

    // Registration survives (matching kitty), chunking was interrupted
    // so a new command is not treated as a continuation.
    try testing.expect(t.kitty_dnd != null);
    try testing.expect(!t.kitty_dnd.?.chunking.active);
    s.nextSlice("\x1B]72;t=q\x1B\\");
    try testing.expectEqualStrings("\x1b]72;t=q\x1b\\", S.pty.items);
}

test "kitty dnd: effect reports registration, acceptance, and conclusion" {
    const S = struct {
        var events: std.ArrayListUnmanaged(kitty_dnd.Event) = .empty;
        var mimes: std.ArrayListUnmanaged(u8) = .empty;

        fn clear() void {
            events.deinit(testing.allocator);
            events = .empty;
            mimes.deinit(testing.allocator);
            mimes = .empty;
        }

        fn dragAndDrop(handler: *Handler, ev: kitty_dnd.Event) void {
            events.append(testing.allocator, ev) catch unreachable;
            // Registration details are read from the terminal state.
            if (ev == .registration) {
                mimes.clearRetainingCapacity();
                const state = handler.terminal.kitty_dnd orelse return;
                var it = state.registeredMimes();
                while (it.next()) |m| {
                    mimes.appendSlice(testing.allocator, m) catch unreachable;
                    mimes.append(testing.allocator, ',') catch unreachable;
                }
            }
        }
    };
    S.clear();
    defer S.clear();

    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    var handler: Handler = .init(&t);
    handler.effects.drag_and_drop = &S.dragAndDrop;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    // Registration with a MIME list, read back from the state.
    s.nextSlice("\x1B]72;t=a;image/png text/plain\x1B\\");
    try testing.expectEqual(@as(usize, 1), S.events.items.len);
    try testing.expect(S.events.items[0] == .registration);
    try testing.expectEqualStrings("image/png,text/plain,", S.mimes.items);

    // A native drag and the client's answer.
    {
        var aw: std.Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        try t.kitty_dnd.?.dragDrop(testing.allocator, &aw.writer, .{
            .cell_x = 0,
            .cell_y = 0,
            .pixel_x = 0,
            .pixel_y = 0,
            .operations = .{ .copy = true },
        }, &.{.{ .mime = "text/plain", .data = "x" }});
    }
    s.nextSlice("\x1B]72;t=m:o=2;text/plain\x1B\\");
    try testing.expectEqual(@as(usize, 2), S.events.items.len);
    try testing.expect(S.events.items[1] == .acceptance);

    // Conclusion carries the performed operation.
    s.nextSlice("\x1B]72;t=r:o=2\x1B\\");
    try testing.expectEqual(@as(usize, 3), S.events.items.len);
    try testing.expectEqual(kitty_dnd.Event.concluded_move, S.events.items[2]);

    // Unregistration reports with the state gone.
    s.nextSlice("\x1B]72;t=A\x1B\\");
    try testing.expectEqual(@as(usize, 4), S.events.items.len);
    try testing.expect(S.events.items[3] == .registration);
    try testing.expect(t.kitty_dnd == null);
    try testing.expectEqualStrings("", S.mimes.items);
}

/// Capture state for the Handler.paste tests below: every pty write and
/// the clipboard reads the program makes afterwards.
const PasteCapture = struct {
    var written: std.ArrayList(u8) = .empty;
    var write_count: usize = 0;
    var read_count: usize = 0;
    var read_granted_count: usize = 0;
    var last_read_granted: bool = false;
    var last_read_name: [64]u8 = undefined;
    var last_read_name_len: usize = 0;

    fn reset() void {
        written.clearRetainingCapacity();
        write_count = 0;
        read_count = 0;
        read_granted_count = 0;
        last_read_granted = false;
        last_read_name_len = 0;
    }

    fn deinit() void {
        written.deinit(testing.allocator);
        written = .empty;
    }

    fn writePty(_: *Handler, data: []const u8) void {
        written.appendSlice(testing.allocator, data) catch @panic("OOM");
        write_count += 1;
    }

    fn clipboardRead(_: *Handler, read: clipboard.Read) void {
        read_count += 1;
        last_read_granted = read.granted;
        if (read.granted) read_granted_count += 1;
        last_read_name_len = read.name.len;
        @memcpy(last_read_name[0..read.name.len], read.name);
        read.reply(.{ .success = .{ .contents = &.{.{
            .mime = "text/plain",
            .data = "Ghostty",
        }} } });
    }

    fn readName() []const u8 {
        return last_read_name[0..last_read_name_len];
    }
};

test "paste: no write_pty effect is an error" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    var handler: Handler = .init(&t);
    defer handler.deinit();
    try testing.expectError(error.NoWritePty, handler.paste(.{
        .contents = .{ .memory = &.{.{ .mime = "text/plain", .data = "hello" }} },
    }));
}

test "paste: plain text converts newlines and strips unsafe bytes" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = PasteCapture;
    S.reset();
    defer S.deinit();

    var handler: Handler = .init(&t);
    defer handler.deinit();
    handler.effects.write_pty = &S.writePty;

    // Newlines are unsafe unbracketed; the embedder confirmed.
    try testing.expect(try handler.paste(.{
        .contents = .{ .memory = &.{.{ .mime = "text/plain", .data = "hel\x1blo\nwor\x00ld" }} },
        .allow_unsafe = true,
    }));
    try testing.expectEqualStrings("hel lo\rwor ld", S.written.items);
    try testing.expectEqual(@as(usize, 1), S.write_count);

    // The first text representation is used; others are ignored.
    S.reset();
    try testing.expect(try handler.paste(.{
        .contents = .{ .memory = &.{
            .{ .mime = "image/png", .data = "\x89PNG" },
            .{ .mime = "UTF8_STRING", .data = "hi" },
            .{ .mime = "text/plain", .data = "ignored" },
        } },
    }));
    try testing.expectEqualStrings("hi", S.written.items);
    try testing.expectEqual(@as(usize, 1), S.write_count);
}

test "paste: unsafe text is refused unless allowed" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = PasteCapture;
    S.reset();
    defer S.deinit();

    var handler: Handler = .init(&t);
    defer handler.deinit();
    handler.effects.write_pty = &S.writePty;

    try testing.expectError(error.UnsafePaste, handler.paste(.{
        .contents = .{ .memory = &.{.{ .mime = "text/plain", .data = "rm -rf /\n" }} },
    }));
    try testing.expectEqual(@as(usize, 0), S.write_count);

    try testing.expect(try handler.paste(.{
        .contents = .{ .memory = &.{.{ .mime = "text/plain", .data = "rm -rf /\n" }} },
        .allow_unsafe = true,
    }));
    try testing.expectEqualStrings("rm -rf /\r", S.written.items);
}

test "paste: bracketed paste frames the text" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = PasteCapture;
    S.reset();
    defer S.deinit();

    var handler: Handler = .init(&t);
    defer handler.deinit();
    handler.effects.write_pty = &S.writePty;
    t.modes.set(.bracketed_paste, true);

    // Newlines are safe inside the frame and are preserved.
    try testing.expect(try handler.paste(.{
        .contents = .{ .memory = &.{.{ .mime = "text/plain", .data = "hello\nworld" }} },
    }));
    try testing.expectEqualStrings("\x1b[200~hello\nworld\x1b[201~", S.written.items);
    try testing.expectEqual(@as(usize, 1), S.write_count);

    // The frame terminator is not.
    S.reset();
    try testing.expectError(error.UnsafePaste, handler.paste(.{
        .contents = .{ .memory = &.{.{ .mime = "text/plain", .data = "he\x1b[201~llo" }} },
    }));
    try testing.expectEqual(@as(usize, 0), S.write_count);

    // Allowed, the stripper still defuses it: ESC becomes a space.
    try testing.expect(try handler.paste(.{
        .contents = .{ .memory = &.{.{ .mime = "text/plain", .data = "he\x1b[201~llo" }} },
        .allow_unsafe = true,
    }));
    try testing.expectEqualStrings("\x1b[200~he [201~llo\x1b[201~", S.written.items);
}

test "paste: no text representation writes nothing" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = PasteCapture;
    S.reset();
    defer S.deinit();

    var handler: Handler = .init(&t);
    defer handler.deinit();
    handler.effects.write_pty = &S.writePty;

    try testing.expect(!try handler.paste(.{
        .contents = .{ .memory = &.{.{ .mime = "image/png", .data = "\x89PNG" }} },
    }));
    try testing.expect(!try handler.paste(.{
        .contents = .{ .memory = &.{} },
    }));
    try testing.expect(!try handler.paste(.{
        .contents = .{ .memory = &.{.{ .mime = "text/plain", .data = "" }} },
    }));
    try testing.expectEqual(@as(usize, 0), S.write_count);
}

test "paste: large text streams to the pty in chunks" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = PasteCapture;
    S.reset();
    defer S.deinit();

    var handler: Handler = .init(&t);
    defer handler.deinit();
    handler.effects.write_pty = &S.writePty;
    t.modes.set(.bracketed_paste, true);

    // Two full chunks and a partial one with the frame, never the
    // whole thing at once.
    const data = "x" ** 10_000;
    try testing.expect(try handler.paste(.{
        .contents = .{ .memory = &.{.{ .mime = "text/plain", .data = data }} },
    }));
    const total = data.len + "\x1b[200~\x1b[201~".len;
    try testing.expectEqual(
        @as(usize, (total + Handler.paste_chunk_size - 1) / Handler.paste_chunk_size),
        S.write_count,
    );
    try testing.expectEqual(total, S.written.items.len);
    try testing.expect(std.mem.startsWith(u8, S.written.items, "\x1b[200~xxx"));
    try testing.expect(std.mem.endsWith(u8, S.written.items, "xxx\x1b[201~"));
}

/// A paste contents reader for the tests: serves fixed data per MIME
/// type in pieces, counting the reads of each representation.
const PasteReader = struct {
    mimes: []const []const u8,
    data: []const []const u8,
    piece: usize = 3,
    reads: [4]usize = @splat(0),
    /// Fail after this many bytes of a read.
    fail_after: ?usize = null,

    fn contents(self: *PasteReader) paste_pkg.Contents {
        return .{ .reader = .{
            .mimes = self.mimes,
            .read = .{ .ctx = self, .read_fn = &read },
        } };
    }

    fn read(ctx: ?*anyopaque, mime: []const u8, sink: *std.Io.Writer) clipboard.MimeReader.Error!void {
        const self: *PasteReader = @ptrCast(@alignCast(ctx.?));
        const index: usize = for (self.mimes, 0..) |m, i| {
            if (std.mem.eql(u8, m, mime)) break i;
        } else return error.ReadFailed;
        self.reads[index] += 1;
        const data = self.data[index];
        var offset: usize = 0;
        while (offset < data.len) {
            if (self.fail_after) |limit| if (offset >= limit) return error.ReadFailed;
            const n = @min(self.piece, data.len - offset);
            try sink.writeAll(data[offset..][0..n]);
            offset += n;
        }
    }
};

test "paste: reader contents are read on demand" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = PasteCapture;
    S.reset();
    defer S.deinit();

    var handler: Handler = .init(&t);
    defer handler.deinit();
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_read = &S.clipboardRead;

    // Unsafe text is refused from one read with nothing written; the
    // image is never read.
    var reader: PasteReader = .{
        .mimes = &.{ "image/png", "text/plain" },
        .data = &.{ "\x89PNG", "echo hi\nrm -rf /\n" },
    };
    try testing.expectError(error.UnsafePaste, handler.paste(.{
        .contents = reader.contents(),
    }));
    try testing.expectEqual(@as(usize, 0), S.write_count);
    try testing.expectEqual(@as(usize, 0), reader.reads[0]);
    try testing.expectEqual(@as(usize, 1), reader.reads[1]);

    // Allowed, the text is read once, encoded.
    reader.reads = @splat(0);
    try testing.expect(try handler.paste(.{
        .contents = reader.contents(),
        .allow_unsafe = true,
    }));
    try testing.expectEqualStrings("echo hi\rrm -rf /\r", S.written.items);
    try testing.expectEqual(@as(usize, 0), reader.reads[0]);
    try testing.expectEqual(@as(usize, 1), reader.reads[1]);

    // Safe text is read once too: buffered for the check, then written.
    S.reset();
    reader = .{
        .mimes = &.{"text/plain"},
        .data = &.{"hello world"},
    };
    try testing.expect(try handler.paste(.{ .contents = reader.contents() }));
    try testing.expectEqualStrings("hello world", S.written.items);
    try testing.expectEqual(@as(usize, 1), reader.reads[0]);

    // Empty text is nothing to paste, found on the one read.
    S.reset();
    reader = .{
        .mimes = &.{"text/plain"},
        .data = &.{""},
    };
    try testing.expect(!try handler.paste(.{ .contents = reader.contents() }));
    try testing.expectEqual(@as(usize, 0), S.write_count);
    try testing.expectEqual(@as(usize, 1), reader.reads[0]);

    // A paste event lists the types and reads nothing at all.
    S.reset();
    t.modes.set(.kitty_paste_events, true);
    reader = .{
        .mimes = &.{ "text/plain", "image/png" },
        .data = &.{ "secret", "\x89PNG" },
    };
    try testing.expect(try handler.paste(.{ .contents = reader.contents() }));
    try testing.expect(std.mem.indexOf(u8, S.written.items, ";dGV4dC9wbGFpbiBpbWFnZS9wbmcK\x1b\\") != null);
    try testing.expect(std.mem.indexOf(u8, S.written.items, "secret") == null);
    try testing.expectEqual(@as(usize, 0), reader.reads[0]);
    try testing.expectEqual(@as(usize, 0), reader.reads[1]);
}

test "paste: reader failure writes nothing" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = PasteCapture;
    S.reset();
    defer S.deinit();

    var handler: Handler = .init(&t);
    defer handler.deinit();
    handler.effects.write_pty = &S.writePty;
    t.modes.set(.bracketed_paste, true);

    // The read is buffered whole before anything is written, so a
    // mid-read failure discards the buffer, checked or not.
    var reader: PasteReader = .{
        .mimes = &.{"text/plain"},
        .data = &.{"hello world"},
        .fail_after = 6,
    };
    try testing.expectError(error.ReadFailed, handler.paste(.{
        .contents = reader.contents(),
    }));
    try testing.expectEqual(@as(usize, 0), S.write_count);

    try testing.expectError(error.ReadFailed, handler.paste(.{
        .contents = reader.contents(),
        .allow_unsafe = true,
    }));
    try testing.expectEqual(@as(usize, 0), S.write_count);
}

test "paste: mode 5522 sends an event the program can read with" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = PasteCapture;
    S.reset();
    defer S.deinit();

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_read = &S.clipboardRead;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();
    t.modes.set(.kitty_paste_events, true);
    t.modes.set(.bracketed_paste, true);

    // Every representation is listed, the data is never written, and
    // the one-time password rides on every packet.
    try testing.expect(try s.handler.paste(.{
        .contents = .{ .memory = &.{
            .{ .mime = "text/plain", .data = "secret" },
            .{ .mime = "image/png", .data = "" },
        } },
    }));
    try testing.expectEqual(@as(usize, 1), S.write_count);
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, S.written.items, "\x1b]5522;"));
    try testing.expect(std.mem.indexOf(u8, S.written.items, "secret") == null);
    try testing.expect(std.mem.indexOf(u8, S.written.items, "\x1b[200~") == null);

    // OK packet: parse the (base64) password out.
    const ok_prefix = "\x1b]5522;type=read:status=OK:pw=";
    try testing.expect(std.mem.startsWith(u8, S.written.items, ok_prefix));
    const pw_end = std.mem.indexOfPos(u8, S.written.items, ok_prefix.len, "\x1b\\").?;
    // Copied out since the capture buffer is reused below.
    var pw_buf: [64]u8 = undefined;
    const pw_b64 = pw_buf[0 .. pw_end - ok_prefix.len];
    @memcpy(pw_b64, S.written.items[ok_prefix.len..pw_end]);
    try testing.expectEqual(
        std.base64.standard.Encoder.calcSize(kitty_clipboard.otp_len),
        pw_b64.len,
    );

    // Listing packet: base64 of "text/plain image/png\n".
    var expected_buf: [256]u8 = undefined;
    const expected = try std.fmt.bufPrint(
        &expected_buf,
        "\x1b]5522;type=read:status=OK:pw={s}\x1b\\" ++
            "\x1b]5522;type=read:status=DATA:mime=Lg==:pw={s};dGV4dC9wbGFpbiBpbWFnZS9wbmcK\x1b\\" ++
            "\x1b]5522;type=read:status=DONE:pw={s}\x1b\\",
        .{ pw_b64, pw_b64, pw_b64 },
    );
    try testing.expectEqualStrings(expected, S.written.items);

    // The program reads with the password and the name "Paste event":
    // the read arrives granted, exactly once.
    var read_buf: [256]u8 = undefined;
    const read = try std.fmt.bufPrint(
        &read_buf,
        "\x1b]5522;type=read:pw={s}:name=UGFzdGUgZXZlbnQ=;dGV4dC9wbGFpbg==\x1b\\",
        .{pw_b64},
    );
    S.reset();
    s.nextSlice(read);
    try testing.expectEqual(@as(usize, 1), S.read_count);
    try testing.expect(S.last_read_granted);
    try testing.expectEqualStrings("Paste event", S.readName());
    try testing.expectEqualStrings(
        "\x1b]5522;type=read:status=OK\x1b\\" ++
            "\x1b]5522;type=read:status=DATA:mime=dGV4dC9wbGFpbg==;R2hvc3R0eQ==\x1b\\" ++
            "\x1b]5522;type=read:status=DONE\x1b\\",
        S.written.items,
    );

    // The password was one-time: a second read is not granted.
    S.reset();
    s.nextSlice(read);
    try testing.expectEqual(@as(usize, 1), S.read_count);
    try testing.expect(!S.last_read_granted);
    try testing.expectEqual(@as(usize, 0), S.read_granted_count);

    // Every event mints a fresh password.
    S.reset();
    try testing.expect(try s.handler.paste(.{
        .contents = .{ .memory = &.{.{ .mime = "text/plain", .data = "secret" }} },
    }));
    try testing.expect(std.mem.indexOf(u8, S.written.items, pw_b64) == null);
}

test "paste: mode 5522 reports the selection as primary" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = PasteCapture;
    S.reset();
    defer S.deinit();

    var handler: Handler = .init(&t);
    defer handler.deinit();
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_read = &S.clipboardRead;
    t.modes.set(.kitty_paste_events, true);

    for ([_]clipboard.Location{ .primary, .selection }) |location| {
        S.reset();
        try testing.expect(try handler.paste(.{
            .source = .{ .clipboard = location },
            .contents = .{ .memory = &.{.{ .mime = "text/plain", .data = "x" }} },
        }));
        try testing.expect(std.mem.startsWith(
            u8,
            S.written.items,
            "\x1b]5522;type=read:status=OK:loc=primary:pw=",
        ));
        // Only on the OK packet.
        try testing.expectEqual(@as(usize, 1), std.mem.count(u8, S.written.items, "loc=primary"));
    }

    S.reset();
    try testing.expect(try handler.paste(.{
        .source = .{ .clipboard = .standard },
        .contents = .{ .memory = &.{.{ .mime = "text/plain", .data = "x" }} },
    }));
    try testing.expect(std.mem.indexOf(u8, S.written.items, "loc=") == null);
}

test "paste: mode 5522 without clipboard_read pastes text" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = PasteCapture;
    S.reset();
    defer S.deinit();

    var handler: Handler = .init(&t);
    defer handler.deinit();
    handler.effects.write_pty = &S.writePty;
    t.modes.set(.kitty_paste_events, true);

    try testing.expect(try handler.paste(.{
        .contents = .{ .memory = &.{.{ .mime = "text/plain", .data = "hello" }} },
    }));
    try testing.expectEqualStrings("hello", S.written.items);
    try testing.expectEqual(@as(usize, 0), handler.kitty_clipboard_grants.entries.items.len);
}

test "paste: text source never becomes an event" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = PasteCapture;
    S.reset();
    defer S.deinit();

    var handler: Handler = .init(&t);
    defer handler.deinit();
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_read = &S.clipboardRead;
    t.modes.set(.kitty_paste_events, true);

    try testing.expect(try handler.paste(.{
        .source = .text,
        .contents = .{ .memory = &.{.{ .mime = "text/plain", .data = "committed" }} },
    }));
    try testing.expectEqualStrings("committed", S.written.items);
    try testing.expectEqual(@as(usize, 0), handler.kitty_clipboard_grants.entries.items.len);
}

test "paste: mode 5522 without entropy fails and records no grant" {
    var t: Terminal = try .init(std.Io.failing, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = PasteCapture;
    S.reset();
    defer S.deinit();

    var handler: Handler = .init(&t);
    defer handler.deinit();
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_read = &S.clipboardRead;
    t.modes.set(.kitty_paste_events, true);

    try testing.expectError(error.EntropyUnavailable, handler.paste(.{
        .contents = .{ .memory = &.{.{ .mime = "text/plain", .data = "secret" }} },
    }));
    try testing.expectEqual(@as(usize, 0), S.write_count);
    try testing.expectEqual(@as(usize, 0), handler.kitty_clipboard_grants.entries.items.len);

    // Text pastes need no entropy and still work.
    try testing.expect(try handler.paste(.{
        .source = .text,
        .contents = .{ .memory = &.{.{ .mime = "text/plain", .data = "hello" }} },
    }));
    try testing.expectEqualStrings("hello", S.written.items);
}

test "paste: mode 5522 DECRQM requires clipboard read effect" {
    if (comptime build_options.artifact != .lib) return error.SkipZigTest;

    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = PasteCapture;
    S.reset();
    defer S.deinit();

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    // A paste event is unusable if its follow-up read can't be served, so
    // the mode isn't advertised without a clipboard read effect.
    s.nextSlice("\x1B[?5522$p");
    try testing.expectEqualStrings("\x1B[?5522;0$y", S.written.items);

    S.reset();
    s.nextSlice("\x1B[?5522h");
    try testing.expect(t.modes.get(.kitty_paste_events));
    s.nextSlice("\x1B[?5522$p");
    try testing.expectEqualStrings("\x1B[?5522;0$y", S.written.items);

    // Installing the effect makes the current mode state reportable.
    S.reset();
    s.handler.effects.clipboard_read = &S.clipboardRead;
    s.nextSlice("\x1B[?5522$p");
    try testing.expectEqualStrings("\x1B[?5522;1$y", S.written.items);

    S.reset();
    s.nextSlice("\x1B[?5522l");
    try testing.expect(!t.modes.get(.kitty_paste_events));
    s.nextSlice("\x1B[?5522$p");
    try testing.expectEqualStrings("\x1B[?5522;2$y", S.written.items);

    // Removing the effect stops advertising the capability again.
    S.reset();
    s.handler.effects.clipboard_read = null;
    s.nextSlice("\x1B[?5522$p");
    try testing.expectEqualStrings("\x1B[?5522;0$y", S.written.items);
}

test "full reset drops kitty clipboard grants" {
    var t: Terminal = try .init(testing.io, testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = PasteCapture;
    S.reset();
    defer S.deinit();

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.clipboard_read = &S.clipboardRead;
    var s: Stream = .init(.{ .allocator = testing.allocator, .handler = handler });
    defer s.deinit();

    try s.handler.kitty_clipboard_grants.grant(testing.allocator, "pw", .read, false);
    try testing.expectEqual(@as(usize, 1), s.handler.kitty_clipboard_grants.entries.items.len);

    s.nextSlice("\x1Bc");
    try testing.expectEqual(@as(usize, 0), s.handler.kitty_clipboard_grants.entries.items.len);

    // A read with the old password is no longer granted, and the
    // handler keeps working (grants can be recorded again).
    S.reset();
    s.nextSlice("\x1b]5522;type=read:pw=cHc=:name=YXBw;dGV4dC9wbGFpbg==\x1b\\");
    try testing.expectEqual(@as(usize, 1), S.read_count);
    try testing.expect(!S.last_read_granted);
    try s.handler.kitty_clipboard_grants.grant(testing.allocator, "pw", .read, false);
}
