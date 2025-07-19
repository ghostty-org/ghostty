const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const xev = @import("../global.zig").xev;
const apprt = @import("../apprt.zig");
const build_config = @import("../build_config.zig");
const configpkg = @import("../config.zig");
const internal_os = @import("../os/main.zig");
const renderer = @import("../renderer.zig");
const termio = @import("../termio.zig");
const terminal = @import("../terminal/main.zig");
const terminfo = @import("../terminfo/main.zig");
const posix = std.posix;

const log = std.log.scoped(.io_handler);

/// This is used as the handler for the terminal.Stream type. This is
/// stateful and is expected to live for the entire lifetime of the terminal.
/// It is NOT VALID to stop a stream handler, create a new one, and use that
/// unless all of the member fields are copied.
pub const StreamHandler = struct {
    alloc: Allocator,
    size: *renderer.Size,
    terminal: *terminal.Terminal,

    /// Mailbox for data to the termio thread.
    termio_mailbox: *termio.Mailbox,

    /// Mailbox for the surface.
    surface_mailbox: apprt.surface.Mailbox,

    /// The shared render state
    renderer_state: *renderer.State,

    /// The mailbox for notifying the renderer of things.
    renderer_mailbox: *renderer.Thread.Mailbox,

    /// A handle to wake up the renderer. This hints to the renderer that that
    /// a repaint should happen.
    renderer_wakeup: xev.Async,

    /// The default cursor state. This is used with CSI q. This is
    /// set to true when we're currently in the default cursor state.
    default_cursor: bool = true,
    default_cursor_style: terminal.CursorStyle,
    default_cursor_blink: ?bool,
    default_cursor_color: ?terminal.color.RGB,

    /// Actual cursor color. This can be changed with OSC 12. If unset, falls
    /// back to the default cursor color.
    cursor_color: ?terminal.color.RGB,

    /// The default foreground and background color are those set by the user's
    /// config file.
    default_foreground_color: terminal.color.RGB,
    default_background_color: terminal.color.RGB,

    /// The foreground and background color as set by an OSC 10 or OSC 11
    /// sequence. If unset then the respective color falls back to the default
    /// value.
    foreground_color: ?terminal.color.RGB,
    background_color: ?terminal.color.RGB,

    /// The response to use for ENQ requests. The memory is owned by
    /// whoever owns StreamHandler.
    enquiry_response: []const u8,

    /// The color reporting format for OSC requests.
    osc_color_report_format: configpkg.Config.OSCColorReportFormat,

    /// The clipboard write access configuration.
    clipboard_write: configpkg.ClipboardAccess,

    //---------------------------------------------------------------
    // Internal state

    /// The APC command handler maintains the APC state. APC is like
    /// CSI or OSC, but it is a private escape sequence that is used
    /// to send commands to the terminal emulator. This is used by
    /// the kitty graphics protocol.
    apc: terminal.apc.Handler = .{},

    /// The DCS handler maintains DCS state. DCS is like CSI or OSC,
    /// but requires more stateful parsing. This is used by functionality
    /// such as XTGETTCAP.
    dcs: terminal.dcs.Handler = .{},

    /// This is set to true when a message was written to the termio
    /// mailbox. This can be used by callers to determine if they need
    /// to wake up the termio thread.
    termio_messaged: bool = false,

    /// This is set to true when we've seen a title escape sequence. We use
    /// this to determine if we need to default the window title.
    seen_title: bool = false,

    pub fn deinit(self: *StreamHandler) void {
        self.apc.deinit();
        self.dcs.deinit();
    }

    /// This queues a render operation with the renderer thread. The render
    /// isn't guaranteed to happen immediately but it will happen as soon as
    /// practical.
    pub inline fn queueRender(self: *StreamHandler) !void {
        try self.renderer_wakeup.notify();
    }

    /// Change the configuration for this handler.
    pub fn changeConfig(self: *StreamHandler, config: *termio.DerivedConfig) void {
        self.osc_color_report_format = config.osc_color_report_format;
        self.clipboard_write = config.clipboard_write;
        self.enquiry_response = config.enquiry_response;
        self.default_foreground_color = config.foreground.toTerminalRGB();
        self.default_background_color = config.background.toTerminalRGB();
        self.default_cursor_style = config.cursor_style;
        self.default_cursor_blink = config.cursor_blink;
        self.default_cursor_color = color: {
            if (config.cursor_color) |color| switch (color) {
                .color => break :color color.color.toTerminalRGB(),
                .@"cell-foreground",
                .@"cell-background",
                => {},
            };

            break :color null;
        };

        // If our cursor is the default, then we update it immediately.
        if (self.default_cursor) self.setCursorStyle(.default) catch |err| {
            log.warn("failed to set default cursor style: {}", .{err});
        };

        // The config could have changed any of our colors so update mode 2031
        self.surfaceMessageWriter(.{ .report_color_scheme = false });
    }

    inline fn surfaceMessageWriter(
        self: *StreamHandler,
        msg: apprt.surface.Message,
    ) void {
        // See messageWriter which has similar logic and explains why
        // we may have to do this.
        if (self.surface_mailbox.push(msg, .{ .instant = {} }) == 0) {
            self.renderer_state.mutex.unlock();
            defer self.renderer_state.mutex.lock();
            _ = self.surface_mailbox.push(msg, .{ .forever = {} });
        }
    }

    inline fn messageWriter(self: *StreamHandler, msg: termio.Message) void {
        self.termio_mailbox.send(msg, self.renderer_state.mutex);
        self.termio_messaged = true;
    }

    /// Send a renderer message and unlock the renderer state mutex
    /// if necessary to ensure we don't deadlock.
    ///
    /// This assumes the renderer state mutex is locked.
    inline fn rendererMessageWriter(
        self: *StreamHandler,
        msg: renderer.Message,
    ) void {
        // See termio.Mailbox.send for more details on how this works.

        // Try instant first. If it works then we can return.
        if (self.renderer_mailbox.push(msg, .{ .instant = {} }) > 0) {
            return;
        }

        // Instant would have blocked. Release the renderer mutex,
        // wake up the renderer to allow it to process the message,
        // and then try again.
        self.renderer_state.mutex.unlock();
        defer self.renderer_state.mutex.lock();
        self.renderer_wakeup.notify() catch |err| {
            // This is an EXTREMELY unlikely case. We still don't return
            // and attempt to send the message because its most likely
            // that everything is fine, but log in case a freeze happens.
            log.warn(
                "failed to notify renderer, may deadlock err={}",
                .{err},
            );
        };
        _ = self.renderer_mailbox.push(msg, .{ .forever = {} });
    }

    pub fn dcsHook(self: *StreamHandler, dcs: terminal.DCS) !void {
        var cmd = self.dcs.hook(self.alloc, dcs) orelse return;
        defer cmd.deinit();
        try self.dcsCommand(&cmd);
    }

    pub fn dcsPut(self: *StreamHandler, byte: u8) !void {
        var cmd = self.dcs.put(byte) orelse return;
        defer cmd.deinit();
        try self.dcsCommand(&cmd);
    }

    pub fn dcsUnhook(self: *StreamHandler) !void {
        var cmd = self.dcs.unhook() orelse return;
        defer cmd.deinit();
        try self.dcsCommand(&cmd);
    }

    fn dcsCommand(self: *StreamHandler, cmd: *terminal.dcs.Command) !void {
        // log.warn("DCS command: {}", .{cmd});
        switch (cmd.*) {
            .tmux => |tmux| {
                // TODO: process it
                log.warn("tmux control mode event unimplemented cmd={}", .{tmux});
            },

            .xtgettcap => |*gettcap| {
                const map = comptime terminfo.ghostty.xtgettcapMap();
                while (gettcap.next()) |key| {
                    const response = map.get(key) orelse continue;
                    self.messageWriter(.{ .write_stable = response });
                }
            },

            .decrqss => |decrqss| {
                var response: [128]u8 = undefined;
                var stream = std.io.fixedBufferStream(&response);
                const writer = stream.writer();

                // Offset the stream position to just past the response prefix.
                // We will write the "payload" (if any) below. If no payload is
                // written then we send an invalid DECRPSS response.
                const prefix_fmt = "\x1bP{d}$r";
                const prefix_len = std.fmt.comptimePrint(prefix_fmt, .{0}).len;
                stream.pos = prefix_len;

                switch (decrqss) {
                    // Invalid or unhandled request
                    .none => {},

                    .sgr => {
                        const buf = try self.terminal.printAttributes(stream.buffer[stream.pos..]);

                        // printAttributes wrote into our buffer, so adjust the stream
                        // position
                        stream.pos += buf.len;

                        try writer.writeByte('m');
                    },

                    .decscusr => {
                        const blink = self.terminal.modes.get(.cursor_blinking);
                        const style: u8 = switch (self.terminal.screen.cursor.cursor_style) {
                            .block => if (blink) 1 else 2,
                            .underline => if (blink) 3 else 4,
                            .bar => if (blink) 5 else 6,

                            // Below here, the cursor styles aren't represented by
                            // DECSCUSR so we map it to some other style.
                            .block_hollow => if (blink) 1 else 2,
                        };
                        try writer.print("{d} q", .{style});
                    },

                    .decstbm => {
                        try writer.print("{d};{d}r", .{
                            self.terminal.scrolling_region.top + 1,
                            self.terminal.scrolling_region.bottom + 1,
                        });
                    },

                    .decslrm => {
                        // We only send a valid response when left and right
                        // margin mode (DECLRMM) is enabled.
                        if (self.terminal.modes.get(.enable_left_and_right_margin)) {
                            try writer.print("{d};{d}s", .{
                                self.terminal.scrolling_region.left + 1,
                                self.terminal.scrolling_region.right + 1,
                            });
                        }
                    },
                }

                // Our response is valid if we have a response payload
                const valid = stream.pos > prefix_len;

                // Write the terminator
                try writer.writeAll("\x1b\\");

                // Write the response prefix into the buffer
                _ = try std.fmt.bufPrint(response[0..prefix_len], prefix_fmt, .{@intFromBool(valid)});
                const msg = try termio.Message.writeReq(self.alloc, response[0..stream.pos]);
                self.messageWriter(msg);
            },
        }
    }

    pub fn apcStart(self: *StreamHandler) !void {
        self.apc.start();
    }

    pub fn apcPut(self: *StreamHandler, byte: u8) !void {
        self.apc.feed(self.alloc, byte);
    }

    pub fn apcEnd(self: *StreamHandler) !void {
        var cmd = self.apc.end() orelse return;
        defer cmd.deinit(self.alloc);

        // log.warn("APC command: {}", .{cmd});
        switch (cmd) {
            .kitty => |*kitty_cmd| {
                if (self.terminal.kittyGraphics(self.alloc, kitty_cmd)) |resp| {
                    var buf: [1024]u8 = undefined;
                    var buf_stream = std.io.fixedBufferStream(&buf);
                    try resp.encode(buf_stream.writer());
                    const final = buf_stream.getWritten();
                    if (final.len > 2) {
                        log.debug("kitty graphics response: {s}", .{std.fmt.fmtSliceHexLower(final)});
                        self.messageWriter(try termio.Message.writeReq(self.alloc, final));
                    }
                }
            },
        }
    }

    pub fn print(self: *StreamHandler, ch: u21) !void {
        try self.terminal.print(ch);
    }

    pub fn printRepeat(self: *StreamHandler, count: usize) !void {
        try self.terminal.printRepeat(count);
    }

    pub fn bell(self: *StreamHandler) !void {
        self.surfaceMessageWriter(.ring_bell);
    }

    pub fn backspace(self: *StreamHandler) !void {
        self.terminal.backspace();
    }

    pub fn horizontalTab(self: *StreamHandler, count: u16) !void {
        for (0..count) |_| {
            const x = self.terminal.screen.cursor.x;
            try self.terminal.horizontalTab();
            if (x == self.terminal.screen.cursor.x) break;
        }
    }

    pub fn horizontalTabBack(self: *StreamHandler, count: u16) !void {
        for (0..count) |_| {
            const x = self.terminal.screen.cursor.x;
            try self.terminal.horizontalTabBack();
            if (x == self.terminal.screen.cursor.x) break;
        }
    }

    pub fn linefeed(self: *StreamHandler) !void {
        // Small optimization: call index instead of linefeed because they're
        // identical and this avoids one layer of function call overhead.
        try self.terminal.index();
    }

    pub fn carriageReturn(self: *StreamHandler) !void {
        self.terminal.carriageReturn();
    }

    pub fn setCursorLeft(self: *StreamHandler, amount: u16) !void {
        self.terminal.cursorLeft(amount);
    }

    pub fn setCursorRight(self: *StreamHandler, amount: u16) !void {
        self.terminal.cursorRight(amount);
    }

    pub fn setCursorDown(self: *StreamHandler, amount: u16, carriage: bool) !void {
        self.terminal.cursorDown(amount);
        if (carriage) self.terminal.carriageReturn();
    }

    pub fn setCursorUp(self: *StreamHandler, amount: u16, carriage: bool) !void {
        self.terminal.cursorUp(amount);
        if (carriage) self.terminal.carriageReturn();
    }

    pub fn setCursorCol(self: *StreamHandler, col: u16) !void {
        self.terminal.setCursorPos(self.terminal.screen.cursor.y + 1, col);
    }

    pub fn setCursorColRelative(self: *StreamHandler, offset: u16) !void {
        self.terminal.setCursorPos(
            self.terminal.screen.cursor.y + 1,
            self.terminal.screen.cursor.x + 1 +| offset,
        );
    }

    pub fn setCursorRow(self: *StreamHandler, row: u16) !void {
        self.terminal.setCursorPos(row, self.terminal.screen.cursor.x + 1);
    }

    pub fn setCursorRowRelative(self: *StreamHandler, offset: u16) !void {
        self.terminal.setCursorPos(
            self.terminal.screen.cursor.y + 1 +| offset,
            self.terminal.screen.cursor.x + 1,
        );
    }

    pub fn setCursorPos(self: *StreamHandler, row: u16, col: u16) !void {
        self.terminal.setCursorPos(row, col);
    }

    pub fn eraseDisplay(self: *StreamHandler, mode: terminal.EraseDisplay, protected: bool) !void {
        if (mode == .complete) {
            // Whenever we erase the full display, scroll to bottom.
            try self.terminal.scrollViewport(.{ .bottom = {} });
            try self.queueRender();
        }

        self.terminal.eraseDisplay(mode, protected);
    }

    pub fn eraseLine(self: *StreamHandler, mode: terminal.EraseLine, protected: bool) !void {
        self.terminal.eraseLine(mode, protected);
    }

    pub fn deleteChars(self: *StreamHandler, count: usize) !void {
        self.terminal.deleteChars(count);
    }

    pub fn eraseChars(self: *StreamHandler, count: usize) !void {
        self.terminal.eraseChars(count);
    }

    pub fn insertLines(self: *StreamHandler, count: usize) !void {
        self.terminal.insertLines(count);
    }

    pub fn insertBlanks(self: *StreamHandler, count: usize) !void {
        self.terminal.insertBlanks(count);
    }

    pub fn deleteLines(self: *StreamHandler, count: usize) !void {
        self.terminal.deleteLines(count);
    }

    pub fn reverseIndex(self: *StreamHandler) !void {
        self.terminal.reverseIndex();
    }

    pub fn index(self: *StreamHandler) !void {
        try self.terminal.index();
    }

    pub fn nextLine(self: *StreamHandler) !void {
        try self.terminal.index();
        self.terminal.carriageReturn();
    }

    pub fn setTopAndBottomMargin(self: *StreamHandler, top: u16, bot: u16) !void {
        self.terminal.setTopAndBottomMargin(top, bot);
    }

    pub fn setLeftAndRightMarginAmbiguous(self: *StreamHandler) !void {
        if (self.terminal.modes.get(.enable_left_and_right_margin)) {
            try self.setLeftAndRightMargin(0, 0);
        } else {
            try self.saveCursor();
        }
    }

    pub fn setLeftAndRightMargin(self: *StreamHandler, left: u16, right: u16) !void {
        self.terminal.setLeftAndRightMargin(left, right);
    }

    pub fn setModifyKeyFormat(self: *StreamHandler, format: terminal.ModifyKeyFormat) !void {
        self.terminal.flags.modify_other_keys_2 = false;
        switch (format) {
            .other_keys => |v| switch (v) {
                .numeric => self.terminal.flags.modify_other_keys_2 = true,
                else => {},
            },
            else => {},
        }
    }

    pub fn requestMode(self: *StreamHandler, mode_raw: u16, ansi: bool) !void {
        // Get the mode value and respond.
        const code: u8 = code: {
            const mode = terminal.modes.modeFromInt(mode_raw, ansi) orelse break :code 0;
            if (self.terminal.modes.get(mode)) break :code 1;
            break :code 2;
        };

        var msg: termio.Message = .{ .write_small = .{} };
        const resp = try std.fmt.bufPrint(
            &msg.write_small.data,
            "\x1B[{s}{};{}$y",
            .{
                if (ansi) "" else "?",
                mode_raw,
                code,
            },
        );
        msg.write_small.len = @intCast(resp.len);
        self.messageWriter(msg);
    }

    pub fn saveMode(self: *StreamHandler, mode: terminal.Mode) !void {
        // log.debug("save mode={}", .{mode});
        self.terminal.modes.save(mode);
    }

    pub fn restoreMode(self: *StreamHandler, mode: terminal.Mode) !void {
        // For restore mode we have to restore but if we set it, we
        // always have to call setMode because setting some modes have
        // side effects and we want to make sure we process those.
        const v = self.terminal.modes.restore(mode);
        // log.debug("restore mode={} v={}", .{ mode, v });
        try self.setMode(mode, v);
    }

    pub fn setMode(self: *StreamHandler, mode: terminal.Mode, enabled: bool) !void {
        // Note: this function doesn't need to grab the render state or
        // terminal locks because it is only called from process() which
        // grabs the lock.

        // If we are setting cursor blinking, we ignore it if we have
        // a default cursor blink setting set. This is a really weird
        // behavior so this comment will go deep into trying to explain it.
        //
        // There are two ways to set cursor blinks: DECSCUSR (CSI _ q)
        // and DEC mode 12. DECSCUSR is the modern approach and has a
        // way to revert to the "default" (as defined by the terminal)
        // cursor style and blink by doing "CSI 0 q". DEC mode 12 controls
        // blinking and is either on or off and has no way to set a
        // default. DEC mode 12 is also the more antiquated approach.
        //
        // The problem is that if the user specifies a desired default
        // cursor blink with `cursor-style-blink`, the moment a running
        // program uses DEC mode 12, the cursor blink can never be reset
        // to the default without an explicit DECSCUSR. But if a program
        // is using mode 12, it is by definition not using DECSCUSR.
        // This makes for somewhat annoying interactions where a poorly
        // (or legacy) behaved program will stop blinking, and it simply
        // never restarts.
        //
        // To get around this, we have a special case where if the user
        // specifies some explicit default cursor blink desire, we ignore
        // DEC mode 12. We allow DECSCUSR to still set the cursor blink
        // because programs using DECSCUSR usually are well behaved and
        // reset the cursor blink to the default when they exit.
        //
        // To be extra safe, users can also add a manual `CSI 0 q` to
        // their shell config when they render prompts to ensure the
        // cursor is exactly as they request.
        if (mode == .cursor_blinking and
            self.default_cursor_blink != null)
        {
            return;
        }

        // We first always set the raw mode on our mode state.
        self.terminal.modes.set(mode, enabled);

        // And then some modes require additional processing.
        switch (mode) {
            // Just noting here that autorepeat has no effect on
            // the terminal. xterm ignores this mode and so do we.
            // We know about just so that we don't log that it is
            // an unknown mode.
            .autorepeat => {},

            // Schedule a render since we changed colors
            .reverse_colors => {
                self.terminal.flags.dirty.reverse_colors = true;
                try self.queueRender();
            },

            // Origin resets cursor pos. This is called whether or not
            // we're enabling or disabling origin mode and whether or
            // not the value changed.
            .origin => self.terminal.setCursorPos(1, 1),

            .enable_left_and_right_margin => if (!enabled) {
                // When we disable left/right margin mode we need to
                // reset the left/right margins.
                self.terminal.scrolling_region.left = 0;
                self.terminal.scrolling_region.right = self.terminal.cols - 1;
            },

            .alt_screen_legacy => {
                self.terminal.switchScreenMode(.@"47", enabled);
                try self.queueRender();
            },

            .alt_screen => {
                self.terminal.switchScreenMode(.@"1047", enabled);
                try self.queueRender();
            },

            .alt_screen_save_cursor_clear_enter => {
                self.terminal.switchScreenMode(.@"1049", enabled);
                try self.queueRender();
            },

            // Mode 1048 is xterm's conditional save cursor depending
            // on if alt screen is enabled or not (at the terminal emulator
            // level). Alt screen is always enabled for us so this just
            // does a save/restore cursor.
            .save_cursor => {
                if (enabled) {
                    self.terminal.saveCursor();
                } else {
                    try self.terminal.restoreCursor();
                }
            },

            // Force resize back to the window size
            .enable_mode_3 => {
                const grid_size = self.size.grid();
                self.terminal.resize(
                    self.alloc,
                    grid_size.columns,
                    grid_size.rows,
                ) catch |err| {
                    log.err("error updating terminal size: {}", .{err});
                };
            },

            .@"132_column" => try self.terminal.deccolm(
                self.alloc,
                if (enabled) .@"132_cols" else .@"80_cols",
            ),

            // We need to start a timer to prevent the emulator being hung
            // forever.
            .synchronized_output => {
                if (enabled) self.messageWriter(.{ .start_synchronized_output = {} });
                try self.queueRender();
            },

            .linefeed => {
                self.messageWriter(.{ .linefeed_mode = enabled });
            },

            .in_band_size_reports => if (enabled) self.messageWriter(.{
                .size_report = .mode_2048,
            }),

            .focus_event => if (enabled) self.messageWriter(.{
                .focused = self.terminal.flags.focused,
            }),

            .mouse_event_x10 => {
                if (enabled) {
                    self.terminal.flags.mouse_event = .x10;
                    try self.setMouseShape(.default);
                } else {
                    self.terminal.flags.mouse_event = .none;
                    try self.setMouseShape(.text);
                }
            },
            .mouse_event_normal => {
                if (enabled) {
                    self.terminal.flags.mouse_event = .normal;
                    try self.setMouseShape(.default);
                } else {
                    self.terminal.flags.mouse_event = .none;
                    try self.setMouseShape(.text);
                }
            },
            .mouse_event_button => {
                if (enabled) {
                    self.terminal.flags.mouse_event = .button;
                    try self.setMouseShape(.default);
                } else {
                    self.terminal.flags.mouse_event = .none;
                    try self.setMouseShape(.text);
                }
            },
            .mouse_event_any => {
                if (enabled) {
                    self.terminal.flags.mouse_event = .any;
                    try self.setMouseShape(.default);
                } else {
                    self.terminal.flags.mouse_event = .none;
                    try self.setMouseShape(.text);
                }
            },

            .mouse_format_utf8 => self.terminal.flags.mouse_format = if (enabled) .utf8 else .x10,
            .mouse_format_sgr => self.terminal.flags.mouse_format = if (enabled) .sgr else .x10,
            .mouse_format_urxvt => self.terminal.flags.mouse_format = if (enabled) .urxvt else .x10,
            .mouse_format_sgr_pixels => self.terminal.flags.mouse_format = if (enabled) .sgr_pixels else .x10,

            else => {},
        }
    }

    pub fn setMouseShiftCapture(self: *StreamHandler, v: bool) !void {
        self.terminal.flags.mouse_shift_capture = if (v) .true else .false;
    }

    pub fn setAttribute(self: *StreamHandler, attr: terminal.Attribute) !void {
        switch (attr) {
            .unknown => |unk| log.warn("unimplemented or unknown SGR attribute: {any}", .{unk}),

            else => self.terminal.setAttribute(attr) catch |err|
                log.warn("error setting attribute {}: {}", .{ attr, err }),
        }
    }

    pub fn startHyperlink(self: *StreamHandler, uri: []const u8, id: ?[]const u8) !void {
        try self.terminal.screen.startHyperlink(uri, id);
    }

    pub fn endHyperlink(self: *StreamHandler) !void {
        self.terminal.screen.endHyperlink();
    }

    pub fn deviceAttributes(
        self: *StreamHandler,
        req: terminal.DeviceAttributeReq,
        params: []const u16,
    ) !void {
        _ = params;

        // For the below, we quack as a VT220. We don't quack as
        // a 420 because we don't support DCS sequences.
        switch (req) {
            .primary => self.messageWriter(.{
                // 62 = Level 2 conformance
                // 22 = Color text
                // 52 = Clipboard access
                .write_stable = if (self.clipboard_write != .deny)
                    "\x1B[?62;22;52c"
                else
                    "\x1B[?62;22c",
            }),

            .secondary => self.messageWriter(.{
                .write_stable = "\x1B[>1;10;0c",
            }),

            else => log.warn("unimplemented device attributes req: {}", .{req}),
        }
    }

    pub fn deviceStatusReport(
        self: *StreamHandler,
        req: terminal.device_status.Request,
    ) !void {
        switch (req) {
            .operating_status => self.messageWriter(.{ .write_stable = "\x1B[0n" }),

            .cursor_position => {
                const pos: struct {
                    x: usize,
                    y: usize,
                } = if (self.terminal.modes.get(.origin)) .{
                    .x = self.terminal.screen.cursor.x -| self.terminal.scrolling_region.left,
                    .y = self.terminal.screen.cursor.y -| self.terminal.scrolling_region.top,
                } else .{
                    .x = self.terminal.screen.cursor.x,
                    .y = self.terminal.screen.cursor.y,
                };

                // Response always is at least 4 chars, so this leaves the
                // remainder for the row/column as base-10 numbers. This
                // will support a very large terminal.
                var msg: termio.Message = .{ .write_small = .{} };
                const resp = try std.fmt.bufPrint(&msg.write_small.data, "\x1B[{};{}R", .{
                    pos.y + 1,
                    pos.x + 1,
                });
                msg.write_small.len = @intCast(resp.len);

                self.messageWriter(msg);
            },

            .color_scheme => self.surfaceMessageWriter(.{ .report_color_scheme = true }),
        }
    }

    pub fn setCursorStyle(
        self: *StreamHandler,
        style: terminal.CursorStyleReq,
    ) !void {
        // Assume we're setting to a non-default.
        self.default_cursor = false;

        switch (style) {
            .default => {
                self.default_cursor = true;
                self.terminal.screen.cursor.cursor_style = self.default_cursor_style;
                self.terminal.modes.set(
                    .cursor_blinking,
                    self.default_cursor_blink orelse true,
                );
            },

            .blinking_block => {
                self.terminal.screen.cursor.cursor_style = .block;
                self.terminal.modes.set(.cursor_blinking, true);
            },

            .steady_block => {
                self.terminal.screen.cursor.cursor_style = .block;
                self.terminal.modes.set(.cursor_blinking, false);
            },

            .blinking_underline => {
                self.terminal.screen.cursor.cursor_style = .underline;
                self.terminal.modes.set(.cursor_blinking, true);
            },

            .steady_underline => {
                self.terminal.screen.cursor.cursor_style = .underline;
                self.terminal.modes.set(.cursor_blinking, false);
            },

            .blinking_bar => {
                self.terminal.screen.cursor.cursor_style = .bar;
                self.terminal.modes.set(.cursor_blinking, true);
            },

            .steady_bar => {
                self.terminal.screen.cursor.cursor_style = .bar;
                self.terminal.modes.set(.cursor_blinking, false);
            },

            else => log.warn("unimplemented cursor style: {}", .{style}),
        }
    }

    pub fn setProtectedMode(self: *StreamHandler, mode: terminal.ProtectedMode) !void {
        self.terminal.setProtectedMode(mode);
    }

    pub fn decaln(self: *StreamHandler) !void {
        try self.terminal.decaln();
    }

    pub fn tabClear(self: *StreamHandler, cmd: terminal.TabClear) !void {
        self.terminal.tabClear(cmd);
    }

    pub fn tabSet(self: *StreamHandler) !void {
        self.terminal.tabSet();
    }

    pub fn tabReset(self: *StreamHandler) !void {
        self.terminal.tabReset();
    }

    pub fn saveCursor(self: *StreamHandler) !void {
        self.terminal.saveCursor();
    }

    pub fn restoreCursor(self: *StreamHandler) !void {
        try self.terminal.restoreCursor();
    }

    pub fn enquiry(self: *StreamHandler) !void {
        log.debug("sending enquiry response={s}", .{self.enquiry_response});
        self.messageWriter(try termio.Message.writeReq(self.alloc, self.enquiry_response));
    }

    pub fn scrollDown(self: *StreamHandler, count: usize) !void {
        self.terminal.scrollDown(count);
    }

    pub fn scrollUp(self: *StreamHandler, count: usize) !void {
        self.terminal.scrollUp(count);
    }

    pub fn setActiveStatusDisplay(
        self: *StreamHandler,
        req: terminal.StatusDisplay,
    ) !void {
        self.terminal.status_display = req;
    }

    pub fn configureCharset(
        self: *StreamHandler,
        slot: terminal.CharsetSlot,
        set: terminal.Charset,
    ) !void {
        self.terminal.configureCharset(slot, set);
    }

    pub fn invokeCharset(
        self: *StreamHandler,
        active: terminal.CharsetActiveSlot,
        slot: terminal.CharsetSlot,
        single: bool,
    ) !void {
        self.terminal.invokeCharset(active, slot, single);
    }

    pub fn fullReset(
        self: *StreamHandler,
    ) !void {
        self.terminal.fullReset();
        try self.setMouseShape(.text);

        // Reset resets our palette so we report it for mode 2031.
        self.surfaceMessageWriter(.{ .report_color_scheme = false });
    }

    pub fn queryKittyKeyboard(self: *StreamHandler) !void {
        log.debug("querying kitty keyboard mode", .{});
        var data: termio.Message.WriteReq.Small.Array = undefined;
        const resp = try std.fmt.bufPrint(&data, "\x1b[?{}u", .{
            self.terminal.screen.kitty_keyboard.current().int(),
        });

        self.messageWriter(.{
            .write_small = .{
                .data = data,
                .len = @intCast(resp.len),
            },
        });
    }

    pub fn pushKittyKeyboard(
        self: *StreamHandler,
        flags: terminal.kitty.KeyFlags,
    ) !void {
        log.debug("pushing kitty keyboard mode: {}", .{flags});
        self.terminal.screen.kitty_keyboard.push(flags);
    }

    pub fn popKittyKeyboard(self: *StreamHandler, n: u16) !void {
        log.debug("popping kitty keyboard mode n={}", .{n});
        self.terminal.screen.kitty_keyboard.pop(@intCast(n));
    }

    pub fn setKittyKeyboard(
        self: *StreamHandler,
        mode: terminal.kitty.KeySetMode,
        flags: terminal.kitty.KeyFlags,
    ) !void {
        log.debug("setting kitty keyboard mode: {} {}", .{ mode, flags });
        self.terminal.screen.kitty_keyboard.set(mode, flags);
    }

    pub fn reportXtversion(
        self: *StreamHandler,
    ) !void {
        log.debug("reporting XTVERSION: ghostty {s}", .{build_config.version_string});
        var buf: [288]u8 = undefined;
        const resp = try std.fmt.bufPrint(
            &buf,
            "\x1BP>|{s} {s}\x1B\\",
            .{
                "ghostty",
                build_config.version_string,
            },
        );
        const msg = try termio.Message.writeReq(self.alloc, resp);
        self.messageWriter(msg);
    }

    //-------------------------------------------------------------------------
    // OSC

    pub fn changeWindowTitle(self: *StreamHandler, title: []const u8) !void {
        var buf: [256]u8 = undefined;
        if (title.len >= buf.len) {
            log.warn("change title requested larger than our buffer size, ignoring", .{});
            return;
        }

        @memcpy(buf[0..title.len], title);
        buf[title.len] = 0;

        // Special handling for the empty title. We treat the empty title
        // as resetting to as if we never saw a title. Other terminals
        // behave this way too (e.g. iTerm2).
        if (title.len == 0) {
            // If we have a pwd then we set the title as the pwd else
            // we just set it to blank.
            if (self.terminal.getPwd()) |pwd| pwd: {
                if (pwd.len >= buf.len) break :pwd;
                @memcpy(buf[0..pwd.len], pwd);
                buf[pwd.len] = 0;
            }

            self.surfaceMessageWriter(.{ .set_title = buf });
            self.seen_title = false;
            return;
        }

        self.seen_title = true;
        self.surfaceMessageWriter(.{ .set_title = buf });
    }

    pub fn setMouseShape(
        self: *StreamHandler,
        shape: terminal.MouseShape,
    ) !void {
        // Avoid changing the shape it it is already set to avoid excess
        // cross-thread messaging.
        if (self.terminal.mouse_shape == shape) return;

        self.terminal.mouse_shape = shape;
        self.surfaceMessageWriter(.{ .set_mouse_shape = shape });
    }

    pub fn clipboardContents(self: *StreamHandler, kind: u8, data: []const u8) !void {
        // Note: we ignore the "kind" field and always use the standard clipboard.
        // iTerm also appears to do this but other terminals seem to only allow
        // certain. Let's investigate more.

        const clipboard_type: apprt.Clipboard = switch (kind) {
            'c' => .standard,
            's' => .selection,
            'p' => .primary,
            else => .standard,
        };

        // Get clipboard contents
        if (data.len == 1 and data[0] == '?') {
            self.surfaceMessageWriter(.{ .clipboard_read = clipboard_type });
            return;
        }

        // Write clipboard contents
        self.surfaceMessageWriter(.{
            .clipboard_write = .{
                .req = try apprt.surface.Message.WriteReq.init(
                    self.alloc,
                    data,
                ),
                .clipboard_type = clipboard_type,
            },
        });
    }

    pub fn promptStart(self: *StreamHandler, aid: ?[]const u8, redraw: bool) !void {
        _ = aid;
        self.terminal.markSemanticPrompt(.prompt);
        self.terminal.flags.shell_redraws_prompt = redraw;
    }

    pub fn promptContinuation(self: *StreamHandler, aid: ?[]const u8) !void {
        _ = aid;
        self.terminal.markSemanticPrompt(.prompt_continuation);
    }

    pub fn promptEnd(self: *StreamHandler) !void {
        self.terminal.markSemanticPrompt(.input);
    }

    pub fn endOfInput(self: *StreamHandler) !void {
        self.terminal.markSemanticPrompt(.command);
    }

    pub fn reportPwd(self: *StreamHandler, url: []const u8) !void {
        // Special handling for the empty URL. We treat the empty URL
        // as resetting the pwd as if we never saw a pwd. I can't find any
        // other terminal that does this but it seems like a reasonable
        // behavior that enables some useful features. For example, the macOS
        // proxy icon can be hidden when a program reports it doesn't know
        // the pwd rather than showing a stale pwd.
        if (url.len == 0) {
            // Blank value can never fail because no allocs happen.
            self.terminal.setPwd("") catch unreachable;

            // If we haven't seen a title, we're using the pwd as our title.
            // Set it to blank which will reset our title behavior.
            if (!self.seen_title) {
                try self.changeWindowTitle("");
                assert(!self.seen_title);
            }

            // Report the change.
            self.surfaceMessageWriter(.{ .pwd_change = .{ .stable = "" } });
            return;
        }

        if (builtin.os.tag == .windows) {
            log.warn("reportPwd unimplemented on windows", .{});
            return;
        }

        const uri: std.Uri = internal_os.hostname.parseUrl(url) catch |e| {
            log.warn("invalid url in OSC 7: {}", .{e});
            return;
        };

        if (!std.mem.eql(u8, "file", uri.scheme) and
            !std.mem.eql(u8, "kitty-shell-cwd", uri.scheme))
        {
            log.warn("OSC 7 scheme must be file, got: {s}", .{uri.scheme});
            return;
        }

        // RFC 793 defines port numbers as 16-bit numbers. 5 digits is sufficient to represent
        // the maximum since 2^16 - 1 = 65_535.
        // See https://www.rfc-editor.org/rfc/rfc793#section-3.1.
        const PORT_NUMBER_MAX_DIGITS = 5;
        // Make sure there is space for a max length hostname + the max number of digits.
        var host_and_port_buf: [posix.HOST_NAME_MAX + PORT_NUMBER_MAX_DIGITS]u8 = undefined;
        const hostname_from_uri = internal_os.hostname.bufPrintHostnameFromFileUri(
            &host_and_port_buf,
            uri,
        ) catch |err| switch (err) {
            error.NoHostnameInUri => {
                log.warn("OSC 7 uri must contain a hostname: {}", .{err});
                return;
            },
            error.NoSpaceLeft => |e| {
                log.warn("failed to get full hostname for OSC 7 validation: {}", .{e});
                return;
            },
        };

        // OSC 7 is a little sketchy because anyone can send any value from
        // any host (such an SSH session). The best practice terminals follow
        // is to valid the hostname to be local.
        const host_valid = internal_os.hostname.isLocalHostname(
            hostname_from_uri,
        ) catch |err| switch (err) {
            error.PermissionDenied,
            error.Unexpected,
            => {
                log.warn("failed to get hostname for OSC 7 validation: {}", .{err});
                return;
            },
        };
        if (!host_valid) {
            log.warn("OSC 7 host must be local", .{});
            return;
        }

        // We need to unescape the path. We first try to unescape onto
        // the stack and fall back to heap allocation if we have to.
        var pathBuf: [1024]u8 = undefined;
        const path, const heap = path: {
            // Get the raw string of the URI. Its unclear to me if the various
            // tags of this enum guarantee no percent-encoding so we just
            // check all of it. This isn't a performance critical path.
            const path = switch (uri.path) {
                .raw => |v| v,
                .percent_encoded => |v| v,
            };

            // If the path doesn't have any escapes, we can use it directly.
            if (std.mem.indexOfScalar(u8, path, '%') == null)
                break :path .{ path, false };

            // First try to stack-allocate
            var fba = std.heap.FixedBufferAllocator.init(&pathBuf);
            if (std.fmt.allocPrint(fba.allocator(), "{raw}", .{uri.path})) |v|
                break :path .{ v, false }
            else |_| {}

            // Fall back to heap
            if (std.fmt.allocPrint(self.alloc, "{raw}", .{uri.path})) |v|
                break :path .{ v, true }
            else |_| {}

            // Fall back to using it directly...
            log.warn("failed to unescape OSC 7 path, using it directly path={s}", .{path});
            break :path .{ path, false };
        };
        defer if (heap) self.alloc.free(path);

        log.debug("terminal pwd: {s}", .{path});
        try self.terminal.setPwd(path);

        // Report it to the surface. If creating our write request fails
        // then we just ignore it.
        if (apprt.surface.Message.WriteReq.init(self.alloc, path)) |req| {
            self.surfaceMessageWriter(.{ .pwd_change = req });
        } else |err| {
            log.warn("error notifying surface of pwd change err={}", .{err});
        }

        // If we haven't seen a title, use our pwd as the title.
        if (!self.seen_title) {
            try self.changeWindowTitle(path);
            self.seen_title = false;
        }
    }

    pub fn handleColorOperation(
        self: *StreamHandler,
        operations: *const terminal.osc.Command.ColorOperation.List,
        terminator: terminal.osc.Terminator,
    ) !void {
        // return early if there is nothing to do
        if (operations.count() == 0) return;

        var buffer: [1024]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buffer);
        const alloc = fba.allocator();

        var response: std.ArrayListUnmanaged(u8) = .empty;
        const writer = response.writer(alloc);

        var it = operations.constIterator(0);

        while (it.next()) |op| {
            switch (op.*) {
                .set => |set| set: {
                    switch (set.kind) {
                        .palette => |i| {
                            self.terminal.flags.dirty.palette = true;
                            self.terminal.color_palette.colors[i] = set.color;
                            self.terminal.color_palette.mask.set(i);
                        },
                        .dynamic_color => |i| {
                            switch (i) {
                                .foreground => {
                                    self.foreground_color = set.color;
                                    _ = self.renderer_mailbox.push(.{
                                        .foreground_color = set.color,
                                    }, .{ .forever = {} });
                                },
                                .background => {
                                    self.background_color = set.color;
                                    _ = self.renderer_mailbox.push(.{
                                        .background_color = set.color,
                                    }, .{ .forever = {} });
                                },
                                .cursor => {
                                    self.cursor_color = set.color;
                                    _ = self.renderer_mailbox.push(.{
                                        .cursor_color = set.color,
                                    }, .{ .forever = {} });
                                },
                                .pointer_foreground,
                                .pointer_background,
                                .tektronix_foreground,
                                .tektronix_background,
                                .highlight_background,
                                .tektronix_cursor,
                                .highlight_foreground,
                                => {
                                    log.warn("setting dynamic color {} ({s}) not implemented", .{
                                        i,
                                        @tagName(i),
                                    });
                                    break :set;
                                },
                            }
                        },
                    }

                    // Notify the surface of the color change
                    self.surfaceMessageWriter(.{ .color_change = .{
                        .kind = set.kind,
                        .color = set.color,
                    } });
                },

                .reset => |kind| reset: {
                    switch (kind) {
                        .palette => |i| {
                            const mask = &self.terminal.color_palette.mask;
                            self.terminal.flags.dirty.palette = true;
                            self.terminal.color_palette.colors[i] = self.terminal.default_palette[i];
                            mask.unset(i);

                            self.surfaceMessageWriter(.{
                                .color_change = .{
                                    .kind = .{ .palette = @intCast(i) },
                                    .color = self.terminal.color_palette.colors[i],
                                },
                            });
                        },
                        .dynamic_color => |i| {
                            switch (i) {
                                .foreground => {
                                    self.foreground_color = null;
                                    _ = self.renderer_mailbox.push(.{
                                        .foreground_color = self.foreground_color,
                                    }, .{ .forever = {} });

                                    self.surfaceMessageWriter(.{ .color_change = .{
                                        .kind = kind,
                                        .color = self.default_foreground_color,
                                    } });
                                },
                                .background => {
                                    self.background_color = null;
                                    _ = self.renderer_mailbox.push(.{
                                        .background_color = self.background_color,
                                    }, .{ .forever = {} });

                                    self.surfaceMessageWriter(.{ .color_change = .{
                                        .kind = kind,
                                        .color = self.default_background_color,
                                    } });
                                },
                                .cursor => {
                                    self.cursor_color = null;

                                    _ = self.renderer_mailbox.push(.{
                                        .cursor_color = self.cursor_color,
                                    }, .{ .forever = {} });

                                    if (self.default_cursor_color) |color| {
                                        self.surfaceMessageWriter(.{ .color_change = .{
                                            .kind = kind,
                                            .color = color,
                                        } });
                                    }
                                },
                                .pointer_foreground,
                                .pointer_background,
                                .tektronix_foreground,
                                .tektronix_background,
                                .highlight_background,
                                .tektronix_cursor,
                                .highlight_foreground,
                                => {
                                    log.warn("resetting dynamic color {} ({s}) not implemented", .{
                                        i,
                                        @tagName(i),
                                    });
                                    break :reset;
                                },
                            }
                        },
                    }
                },

                .report => |kind| report: {
                    if (self.osc_color_report_format == .none) break :report;

                    const color = switch (kind) {
                        .palette => |i| self.terminal.color_palette.colors[i],
                        .dynamic_color => |i| switch (i) {
                            .foreground => self.foreground_color orelse self.default_foreground_color,
                            .background => self.background_color orelse self.default_background_color,
                            .cursor => self.cursor_color orelse
                                self.default_cursor_color orelse
                                self.foreground_color orelse
                                self.default_foreground_color,
                            .pointer_foreground,
                            .pointer_background,
                            .tektronix_foreground,
                            .tektronix_background,
                            .highlight_background,
                            .tektronix_cursor,
                            .highlight_foreground,
                            => {
                                log.warn("reporting dynamic color {} ({s}) not implemented", .{
                                    i,
                                    @tagName(i),
                                });
                                break :report;
                            },
                        },
                    };

                    switch (self.osc_color_report_format) {
                        .@"16-bit" => switch (kind) {
                            .palette => |i| try writer.print(
                                "\x1b]4;{d};rgb:{x:0>4}/{x:0>4}/{x:0>4}",
                                .{
                                    i,
                                    @as(u16, color.r) * 257,
                                    @as(u16, color.g) * 257,
                                    @as(u16, color.b) * 257,
                                },
                            ),
                            .dynamic_color => |i| try writer.print(
                                "\x1b]{};rgb:{x:0>4}/{x:0>4}/{x:0>4}",
                                .{
                                    i,
                                    @as(u16, color.r) * 257,
                                    @as(u16, color.g) * 257,
                                    @as(u16, color.b) * 257,
                                },
                            ),
                        },

                        .@"8-bit" => switch (kind) {
                            .palette => |i| try writer.print(
                                "\x1b]4;{d};rgb:{x:0>2}/{x:0>2}/{x:0>2}",
                                .{
                                    i,
                                    @as(u16, color.r),
                                    @as(u16, color.g),
                                    @as(u16, color.b),
                                },
                            ),
                            .dynamic_color => |i| try writer.print(
                                "\x1b]{};rgb:{x:0>2}/{x:0>2}/{x:0>2}",
                                .{
                                    i,
                                    @as(u16, color.r),
                                    @as(u16, color.g),
                                    @as(u16, color.b),
                                },
                            ),
                        },

                        .none => unreachable,
                    }

                    try writer.writeAll(terminator.string());
                },
            }
        }

        if (response.items.len > 0) {
            // If any of the operations were reports send it to the terminal.
            const msg = try termio.Message.writeReq(self.alloc, response.items);
            self.messageWriter(msg);
        }
    }

    pub fn showDesktopNotification(
        self: *StreamHandler,
        title: []const u8,
        body: []const u8,
    ) !void {
        var message = apprt.surface.Message{ .desktop_notification = undefined };

        const title_len = @min(title.len, message.desktop_notification.title.len);
        @memcpy(message.desktop_notification.title[0..title_len], title[0..title_len]);
        message.desktop_notification.title[title_len] = 0;

        const body_len = @min(body.len, message.desktop_notification.body.len);
        @memcpy(message.desktop_notification.body[0..body_len], body[0..body_len]);
        message.desktop_notification.body[body_len] = 0;

        self.surfaceMessageWriter(message);
    }

    /// Send a report to the pty.
    pub fn sendSizeReport(self: *StreamHandler, style: terminal.SizeReportStyle) void {
        switch (style) {
            .csi_14_t => self.messageWriter(.{ .size_report = .csi_14_t }),
            .csi_16_t => self.messageWriter(.{ .size_report = .csi_16_t }),
            .csi_18_t => self.messageWriter(.{ .size_report = .csi_18_t }),
            .csi_21_t => self.surfaceMessageWriter(.{ .report_title = .csi_21_t }),
        }
    }

    pub fn sendKittyColorReport(
        self: *StreamHandler,
        request: terminal.kitty.color.OSC,
    ) !void {
        var buf = std.ArrayList(u8).init(self.alloc);
        defer buf.deinit();
        const writer = buf.writer();

        for (request.list.items) |item| {
            switch (item) {
                .query => |key| {
                    // If the writer buffer is empty, we need to write our prefix
                    if (buf.items.len == 0) try writer.writeAll("\x1b]21");

                    const color: terminal.color.RGB = switch (key) {
                        .palette => |palette| self.terminal.color_palette.colors[palette],
                        .special => |special| switch (special) {
                            .foreground => self.foreground_color orelse self.default_foreground_color,
                            .background => self.background_color orelse self.default_background_color,
                            .cursor => self.cursor_color orelse self.default_cursor_color,
                            else => {
                                log.warn("ignoring unsupported kitty color protocol key: {}", .{key});
                                continue;
                            },
                        },
                    } orelse {
                        try writer.print(";{}=", .{key});
                        continue;
                    };

                    try writer.print(
                        ";{}=rgb:{x:0>2}/{x:0>2}/{x:0>2}",
                        .{ key, color.r, color.g, color.b },
                    );
                },
                .set => |v| switch (v.key) {
                    .palette => |palette| {
                        self.terminal.flags.dirty.palette = true;
                        self.terminal.color_palette.colors[palette] = v.color;
                        self.terminal.color_palette.mask.unset(palette);
                    },

                    .special => |special| {
                        const msg: renderer.Message = switch (special) {
                            .foreground => msg: {
                                self.foreground_color = v.color;
                                break :msg .{ .foreground_color = v.color };
                            },
                            .background => msg: {
                                self.background_color = v.color;
                                break :msg .{ .background_color = v.color };
                            },
                            .cursor => msg: {
                                self.cursor_color = v.color;
                                break :msg .{ .cursor_color = v.color };
                            },
                            else => {
                                log.warn(
                                    "ignoring unsupported kitty color protocol key: {}",
                                    .{v.key},
                                );
                                continue;
                            },
                        };

                        // See messageWriter which has similar logic and
                        // explains why we may have to do this.
                        self.rendererMessageWriter(msg);
                    },
                },
                .reset => |key| switch (key) {
                    .palette => |palette| {
                        self.terminal.flags.dirty.palette = true;
                        self.terminal.color_palette.colors[palette] = self.terminal.default_palette[palette];
                        self.terminal.color_palette.mask.unset(palette);
                    },

                    .special => |special| {
                        const msg: renderer.Message = switch (special) {
                            .foreground => msg: {
                                self.foreground_color = null;
                                break :msg .{ .foreground_color = self.foreground_color };
                            },
                            .background => msg: {
                                self.background_color = null;
                                break :msg .{ .background_color = self.background_color };
                            },
                            .cursor => msg: {
                                self.cursor_color = null;
                                break :msg .{ .cursor_color = self.cursor_color };
                            },
                            else => {
                                log.warn(
                                    "ignoring unsupported kitty color protocol key: {}",
                                    .{key},
                                );
                                continue;
                            },
                        };

                        // See messageWriter which has similar logic and
                        // explains why we may have to do this.
                        self.rendererMessageWriter(msg);
                    },
                },
            }
        }

        // If we had any writes to our buffer, we queue them now
        if (buf.items.len > 0) {
            try writer.writeAll(request.terminator.string());
            self.messageWriter(.{
                .write_alloc = .{
                    .alloc = self.alloc,
                    .data = try buf.toOwnedSlice(),
                },
            });
        }

        // Note: we don't have to do a queueRender here because every
        // processed stream will queue a render once it is done processing
        // the read() syscall.
    }

    /// Display a GUI progress report.
    pub fn handleProgressReport(self: *StreamHandler, report: terminal.osc.Command.ProgressReport) error{}!void {
        self.surfaceMessageWriter(.{ .progress_report = report });
    }
};
