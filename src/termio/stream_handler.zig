const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const xev = @import("../global.zig").xev;
const apprt = @import("../apprt.zig");
const Message = apprt.surface.Message;
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

    /// The tmux control mode viewer state.
    tmux_viewer: if (tmux_enabled) ?*terminal.tmux.Viewer else void = if (tmux_enabled) null else {},

    /// This is set to true when a message was written to the termio
    /// mailbox. This can be used by callers to determine if they need
    /// to wake up the termio thread.
    termio_messaged: bool = false,

    /// This is set to true when we've seen a title escape sequence. We use
    /// this to determine if we need to default the window title.
    seen_title: bool = false,

    pub const Stream = terminal.Stream(StreamHandler);

    /// True if we have tmux control mode built in.
    pub const tmux_enabled = terminal.options.tmux_control_mode;

    pub fn deinit(self: *StreamHandler) void {
        self.apc.deinit();
        self.dcs.deinit();
        if (comptime tmux_enabled) tmux: {
            const viewer = self.tmux_viewer orelse break :tmux;
            viewer.deinit();
            self.alloc.destroy(viewer);
            self.tmux_viewer = null;
        }
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
        self.default_cursor_style = config.cursor_style;
        self.default_cursor_blink = config.cursor_blink;

        // If our cursor is the default, then we update it immediately.
        if (self.default_cursor) self.setCursorStyle(.default) catch |err| {
            log.warn("failed to set default cursor style: {}", .{err});
        };

        // The config could have changed any of our colors so update mode 2031
        self.messageWriter(.{ .color_scheme_report = .{ .force = false } });
    }

    inline fn surfaceMessageWriter(
        self: *StreamHandler,
        msg: Message,
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

    pub fn vt(
        self: *StreamHandler,
        comptime action: Stream.Action.Tag,
        value: Stream.Action.Value(action),
    ) !void {
        // The branch hints here are based on real world data
        // which indicates that the most common actions are:
        //
        // 1. print
        // 2. set_attribute
        // 3. carriage_return
        // 4. line_feed
        // 5. cursor_pos
        //
        // Together, these 5 actions make up nearly 98% of
        // all actions encountered in real world scenarios.
        //
        // ref: https://github.com/qwerasd205/asciinema-stats
        switch (action) {
            .print => {
                @branchHint(.likely);
                try self.terminal.print(value.cp);
            },
            .print_repeat => try self.terminal.printRepeat(value),
            .bell => self.bell(),
            .backspace => self.terminal.backspace(),
            .horizontal_tab => self.horizontalTab(value),
            .horizontal_tab_back => self.horizontalTabBack(value),
            .linefeed => {
                @branchHint(.likely);
                try self.linefeed();
            },
            .carriage_return => {
                @branchHint(.likely);
                self.terminal.carriageReturn();
            },
            .enquiry => try self.enquiry(),
            .invoke_charset => self.terminal.invokeCharset(value.bank, value.charset, value.locking),
            .cursor_up => self.terminal.cursorUp(value.value),
            .cursor_down => self.terminal.cursorDown(value.value),
            .cursor_left => self.terminal.cursorLeft(value.value),
            .cursor_right => self.terminal.cursorRight(value.value),
            .cursor_pos => {
                @branchHint(.likely);
                self.terminal.setCursorPos(value.row, value.col);
            },
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
            .cursor_style => try self.setCursorStyle(value),
            .erase_display_below => self.terminal.eraseDisplay(.below, value),
            .erase_display_above => self.terminal.eraseDisplay(.above, value),
            .erase_display_complete => {
                self.terminal.scrollViewport(.{ .bottom = {} });
                self.terminal.eraseDisplay(.complete, value);
            },
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
            .tab_clear_current => self.terminal.tabClear(.current),
            .tab_clear_all => self.terminal.tabClear(.all),
            .tab_set => self.terminal.tabSet(),
            .tab_reset => self.terminal.tabReset(),
            .index => try self.index(),
            .next_line => try self.nextLine(),
            .reverse_index => try self.reverseIndex(),
            .full_reset => try self.fullReset(),
            .set_mode => try self.setMode(value.mode, true),
            .reset_mode => try self.setMode(value.mode, false),
            .save_mode => self.terminal.modes.save(value.mode),
            .restore_mode => {
                // For restore mode we have to restore but if we set it, we
                // always have to call setMode because setting some modes have
                // side effects and we want to make sure we process those.
                const v = self.terminal.modes.restore(value.mode);
                try self.setMode(value.mode, v);
            },
            .request_mode => try self.requestMode(value.mode),
            .request_mode_unknown => try self.requestModeUnknown(value.mode, value.ansi),
            .top_and_bottom_margin => self.terminal.setTopAndBottomMargin(value.top_left, value.bottom_right),
            .left_and_right_margin => self.terminal.setLeftAndRightMargin(value.top_left, value.bottom_right),
            .left_and_right_margin_ambiguous => {
                if (self.terminal.modes.get(.enable_left_and_right_margin)) {
                    self.terminal.setLeftAndRightMargin(0, 0);
                } else {
                    self.terminal.saveCursor();
                }
            },
            .save_cursor => try self.saveCursor(),
            .restore_cursor => try self.restoreCursor(),
            .modify_key_format => try self.setModifyKeyFormat(value),
            .protected_mode_off => self.terminal.setProtectedMode(.off),
            .protected_mode_iso => self.terminal.setProtectedMode(.iso),
            .protected_mode_dec => self.terminal.setProtectedMode(.dec),
            .mouse_shift_capture => self.terminal.flags.mouse_shift_capture = if (value) .true else .false,
            .size_report => self.sendSizeReport(value),
            .xtversion => try self.reportXtversion(),
            .device_attributes => try self.deviceAttributes(value),
            .device_status => try self.deviceStatusReport(value.request),
            .kitty_keyboard_query => try self.queryKittyKeyboard(),
            .kitty_keyboard_push => {
                log.debug("pushing kitty keyboard mode: {}", .{value.flags});
                self.terminal.screens.active.kitty_keyboard.push(value.flags);
            },
            .kitty_keyboard_pop => {
                log.debug("popping kitty keyboard mode n={}", .{value});
                self.terminal.screens.active.kitty_keyboard.pop(@intCast(value));
            },
            .kitty_keyboard_set => {
                log.debug("setting kitty keyboard mode: set {}", .{value.flags});
                self.terminal.screens.active.kitty_keyboard.set(.set, value.flags);
            },
            .kitty_keyboard_set_or => {
                log.debug("setting kitty keyboard mode: or {}", .{value.flags});
                self.terminal.screens.active.kitty_keyboard.set(.@"or", value.flags);
            },
            .kitty_keyboard_set_not => {
                log.debug("setting kitty keyboard mode: not {}", .{value.flags});
                self.terminal.screens.active.kitty_keyboard.set(.not, value.flags);
            },
            .kitty_color_report => try self.kittyColorReport(value),
            .color_operation => try self.colorOperation(value.op, &value.requests, value.terminator),
            .end_hyperlink => try self.endHyperlink(),
            .active_status_display => self.terminal.status_display = value,
            .decaln => try self.decaln(),
            .window_title => try self.windowTitle(value.title),
            .report_pwd => try self.reportPwd(value.url),
            .show_desktop_notification => try self.showDesktopNotification(value.title, value.body),
            .progress_report => self.progressReport(value),
            .start_hyperlink => try self.startHyperlink(value.uri, value.id),
            .clipboard_contents => try self.clipboardContents(value.kind, value.data),
            .semantic_prompt => try self.semanticPrompt(value),
            .mouse_shape => try self.setMouseShape(value),
            .configure_charset => self.configureCharset(value.slot, value.charset),
            .set_attribute => {
                @branchHint(.likely);
                switch (value) {
                    .unknown => |unk| {
                        // We optimize for the happy path scenario here, since
                        // unknown/invalid SGRs aren't that common in the wild.
                        @branchHint(.unlikely);
                        log.warn("unimplemented or unknown SGR attribute: {any}", .{unk});
                    },
                    else => {
                        @branchHint(.likely);
                        self.terminal.setAttribute(value) catch |err| {
                            @branchHint(.cold);
                            log.warn("error setting attribute {}: {}", .{ value, err });
                        };
                    },
                }
            },
            .dcs_hook => try self.dcsHook(value),
            .dcs_put => try self.dcsPut(value),
            .dcs_unhook => try self.dcsUnhook(),
            .apc_start => self.apc.start(),
            .apc_end => try self.apcEnd(),
            .apc_put => self.apc.feed(self.alloc, value),

            // Unimplemented
            .title_push,
            .title_pop,
            => {},
        }
    }

    pub inline fn dcsHook(self: *StreamHandler, dcs: terminal.DCS) !void {
        var cmd = self.dcs.hook(self.alloc, dcs) orelse return;
        defer cmd.deinit();
        try self.dcsCommand(&cmd);
    }

    pub inline fn dcsPut(self: *StreamHandler, byte: u8) !void {
        var cmd = self.dcs.put(byte) orelse return;
        defer cmd.deinit();
        try self.dcsCommand(&cmd);
    }

    pub inline fn dcsUnhook(self: *StreamHandler) !void {
        var cmd = self.dcs.unhook() orelse return;
        defer cmd.deinit();
        try self.dcsCommand(&cmd);
    }

    fn dcsCommand(self: *StreamHandler, cmd: *terminal.dcs.Command) !void {
        // log.warn("DCS command: {}", .{cmd});
        switch (cmd.*) {
            .tmux => |tmux| tmux: {
                // If tmux control mode is disabled at the build level,
                // then this whole block shouldn't be analyzed.
                if (comptime !tmux_enabled) break :tmux;
                log.info("tmux control mode event cmd={f}", .{tmux});

                switch (tmux) {
                    .enter => {
                        // Setup our viewer state
                        assert(self.tmux_viewer == null);
                        const viewer = try self.alloc.create(terminal.tmux.Viewer);
                        errdefer self.alloc.destroy(viewer);
                        viewer.* = try .init(self.alloc);
                        errdefer viewer.deinit();
                        self.tmux_viewer = viewer;
                        break :tmux;
                    },

                    .exit => {
                        // Free our viewer state if we have one
                        if (self.tmux_viewer) |viewer| {
                            viewer.deinit();
                            self.alloc.destroy(viewer);
                            self.tmux_viewer = null;
                        }

                        // And always break since we assert below
                        // that we're not handling an exit command.
                        break :tmux;
                    },

                    else => {},
                }

                assert(tmux != .enter);
                assert(tmux != .exit);

                const viewer = self.tmux_viewer orelse {
                    // This can only really happen if we failed to
                    // initialize the viewer on enter.
                    log.info(
                        "received tmux control mode command without viewer: {f}",
                        .{tmux},
                    );

                    break :tmux;
                };

                for (viewer.next(.{ .tmux = tmux })) |action| {
                    log.info("tmux viewer action={f}", .{action});
                    switch (action) {
                        .exit => {
                            // We ignore this because we will fully exit when
                            // our DCS connection ends. We may want to handle
                            // this in the future to notify our GUI we're
                            // disconnected though.
                        },

                        .command => |command| {
                            assert(command.len > 0);
                            assert(command[command.len - 1] == '\n');
                            self.messageWriter(try termio.Message.writeReq(
                                self.alloc,
                                command,
                            ));
                        },

                        .windows => {
                            // TODO
                        },
                    }
                }
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
                        const style: u8 = switch (self.terminal.screens.active.cursor.cursor_style) {
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

    pub fn apcEnd(self: *StreamHandler) !void {
        var cmd = self.apc.end() orelse return;
        defer cmd.deinit(self.alloc);

        // log.warn("APC command: {}", .{cmd});
        switch (cmd) {
            .kitty => |*kitty_cmd| {
                if (self.terminal.kittyGraphics(self.alloc, kitty_cmd)) |resp| {
                    var buf: [1024]u8 = undefined;
                    var writer: std.Io.Writer = .fixed(&buf);
                    try resp.encode(&writer);
                    const final = writer.buffered();
                    if (final.len > 2) {
                        log.debug("kitty graphics response: {x}", .{final});
                        self.messageWriter(try termio.Message.writeReq(self.alloc, final));
                    }
                }
            },
        }
    }

    inline fn bell(self: *StreamHandler) void {
        self.surfaceMessageWriter(.ring_bell);
    }

    inline fn horizontalTab(self: *StreamHandler, count: u16) void {
        for (0..count) |_| {
            const x = self.terminal.screens.active.cursor.x;
            self.terminal.horizontalTab();
            if (x == self.terminal.screens.active.cursor.x) break;
        }
    }

    inline fn horizontalTabBack(self: *StreamHandler, count: u16) void {
        for (0..count) |_| {
            const x = self.terminal.screens.active.cursor.x;
            self.terminal.horizontalTabBack();
            if (x == self.terminal.screens.active.cursor.x) break;
        }
    }

    inline fn linefeed(self: *StreamHandler) !void {
        // Small optimization: call index instead of linefeed because they're
        // identical and this avoids one layer of function call overhead.
        try self.terminal.index();
    }

    pub inline fn reverseIndex(self: *StreamHandler) !void {
        self.terminal.reverseIndex();
    }

    pub inline fn index(self: *StreamHandler) !void {
        try self.terminal.index();
    }

    pub inline fn nextLine(self: *StreamHandler) !void {
        try self.terminal.index();
        self.terminal.carriageReturn();
    }

    pub fn setModifyKeyFormat(self: *StreamHandler, format: terminal.ModifyKeyFormat) !void {
        self.terminal.flags.modify_other_keys_2 = false;
        switch (format) {
            .other_keys_numeric => self.terminal.flags.modify_other_keys_2 = true,
            else => {},
        }
    }

    fn requestMode(self: *StreamHandler, mode: terminal.Mode) !void {
        const tag: terminal.modes.ModeTag = @bitCast(@intFromEnum(mode));
        const code: u8 = if (self.terminal.modes.get(mode)) 1 else 2;

        var msg: termio.Message = .{ .write_small = .{} };
        const resp = try std.fmt.bufPrint(
            &msg.write_small.data,
            "\x1B[{s}{};{}$y",
            .{
                if (tag.ansi) "" else "?",
                tag.value,
                code,
            },
        );
        msg.write_small.len = @intCast(resp.len);
        self.messageWriter(msg);
    }

    fn requestModeUnknown(self: *StreamHandler, mode_raw: u16, ansi: bool) !void {
        var msg: termio.Message = .{ .write_small = .{} };
        const resp = try std.fmt.bufPrint(
            &msg.write_small.data,
            "\x1B[{s}{};0$y",
            .{
                if (ansi) "" else "?",
                mode_raw,
            },
        );
        msg.write_small.len = @intCast(resp.len);
        self.messageWriter(msg);
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
            .reverse_colors => self.terminal.flags.dirty.reverse_colors = true,

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
                try self.terminal.switchScreenMode(.@"47", enabled);
            },

            .alt_screen => {
                try self.terminal.switchScreenMode(.@"1047", enabled);
            },

            .alt_screen_save_cursor_clear_enter => {
                try self.terminal.switchScreenMode(.@"1049", enabled);
            },

            // Mode 1048 is xterm's conditional save cursor depending
            // on if alt screen is enabled or not (at the terminal emulator
            // level). Alt screen is always enabled for us so this just
            // does a save/restore cursor.
            .save_cursor => {
                if (enabled) {
                    self.terminal.saveCursor();
                } else {
                    self.terminal.restoreCursor();
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

    inline fn startHyperlink(self: *StreamHandler, uri: []const u8, id: ?[]const u8) !void {
        try self.terminal.screens.active.startHyperlink(uri, id);
    }

    pub inline fn endHyperlink(self: *StreamHandler) !void {
        self.terminal.screens.active.endHyperlink();
    }

    pub fn deviceAttributes(
        self: *StreamHandler,
        req: terminal.DeviceAttributeReq,
    ) !void {
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
                    .x = self.terminal.screens.active.cursor.x -| self.terminal.scrolling_region.left,
                    .y = self.terminal.screens.active.cursor.y -| self.terminal.scrolling_region.top,
                } else .{
                    .x = self.terminal.screens.active.cursor.x,
                    .y = self.terminal.screens.active.cursor.y,
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

            .color_scheme => self.messageWriter(.{ .color_scheme_report = .{ .force = true } }),
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
                self.terminal.screens.active.cursor.cursor_style = self.default_cursor_style;
                self.terminal.modes.set(
                    .cursor_blinking,
                    self.default_cursor_blink orelse true,
                );
            },

            .blinking_block => {
                self.terminal.screens.active.cursor.cursor_style = .block;
                self.terminal.modes.set(.cursor_blinking, true);
            },

            .steady_block => {
                self.terminal.screens.active.cursor.cursor_style = .block;
                self.terminal.modes.set(.cursor_blinking, false);
            },

            .blinking_underline => {
                self.terminal.screens.active.cursor.cursor_style = .underline;
                self.terminal.modes.set(.cursor_blinking, true);
            },

            .steady_underline => {
                self.terminal.screens.active.cursor.cursor_style = .underline;
                self.terminal.modes.set(.cursor_blinking, false);
            },

            .blinking_bar => {
                self.terminal.screens.active.cursor.cursor_style = .bar;
                self.terminal.modes.set(.cursor_blinking, true);
            },

            .steady_bar => {
                self.terminal.screens.active.cursor.cursor_style = .bar;
                self.terminal.modes.set(.cursor_blinking, false);
            },
        }
    }

    pub inline fn decaln(self: *StreamHandler) !void {
        try self.terminal.decaln();
    }

    pub inline fn saveCursor(self: *StreamHandler) !void {
        self.terminal.saveCursor();
    }

    pub inline fn restoreCursor(self: *StreamHandler) !void {
        self.terminal.restoreCursor();
    }

    pub fn enquiry(self: *StreamHandler) !void {
        log.debug("sending enquiry response={s}", .{self.enquiry_response});
        self.messageWriter(try termio.Message.writeReq(self.alloc, self.enquiry_response));
    }

    fn configureCharset(
        self: *StreamHandler,
        slot: terminal.CharsetSlot,
        set: terminal.Charset,
    ) void {
        self.terminal.configureCharset(slot, set);
    }

    pub fn fullReset(
        self: *StreamHandler,
    ) !void {
        self.terminal.fullReset();
        try self.setMouseShape(.text);

        // Reset resets our palette so we report it for mode 2031.
        self.messageWriter(.{ .color_scheme_report = .{ .force = false } });

        // Clear the progress bar
        self.progressReport(.{ .state = .remove });
    }

    pub fn queryKittyKeyboard(self: *StreamHandler) !void {
        log.debug("querying kitty keyboard mode", .{});
        var data: termio.Message.WriteReq.Small.Array = undefined;
        const resp = try std.fmt.bufPrint(&data, "\x1b[?{}u", .{
            self.terminal.screens.active.kitty_keyboard.current().int(),
        });

        self.messageWriter(.{
            .write_small = .{
                .data = data,
                .len = @intCast(resp.len),
            },
        });
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

    fn windowTitle(self: *StreamHandler, title: []const u8) !void {
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

    inline fn setMouseShape(
        self: *StreamHandler,
        shape: terminal.MouseShape,
    ) !void {
        // Avoid changing the shape it it is already set to avoid excess
        // cross-thread messaging.
        if (self.terminal.mouse_shape == shape) return;

        self.terminal.mouse_shape = shape;
        self.surfaceMessageWriter(.{ .set_mouse_shape = shape });
    }

    fn clipboardContents(self: *StreamHandler, kind: u8, data: []const u8) !void {
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

    fn semanticPrompt(
        self: *StreamHandler,
        cmd: Stream.Action.SemanticPrompt,
    ) !void {
        switch (cmd.action) {
            .end_input_start_output => {
                const message: Message = .{
                    .start_command = c: {
                        var w: std.Io.Writer.Allocating = .init(self.alloc);
                        defer w.deinit();

                        cmd.writeCommandLine(&w.writer) catch break :c .{ .command_line = null };

                        break :c Message.StartCommand.init(self.alloc, w.written());
                    },
                };

                self.surfaceMessageWriter(message);
            },

            .end_command => {
                // The specification seems to not specify the type but
                // other terminals accept 32-bits, but exit codes are really
                // bytes, so we just do our best here.
                const code: u8 = code: {
                    const raw: i32 = cmd.readOption(.exit_code) orelse 0;
                    break :code std.math.cast(u8, raw) orelse 1;
                };

                self.surfaceMessageWriter(.{ .stop_command = code });
            },

            // Handled by Terminal, no special handling by us
            .end_prompt_start_input,
            .end_prompt_start_input_terminate_eol,
            .fresh_line,
            .fresh_line_new_prompt,
            .new_command,
            .prompt_start,
            => {},
        }

        // We do this last so failures are still processed correctly
        // above.
        try self.terminal.semanticPrompt(cmd);
    }

    fn reportPwd(self: *StreamHandler, url: []const u8) !void {
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
                try self.windowTitle("");
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

        // Attempt to parse this file-style URI using options appropriate
        // for this OSC 7 context (e.g. kitty-shell-cwd expects the full,
        // unencoded path).
        const uri: std.Uri = internal_os.uri.parse(url, .{
            .mac_address = comptime builtin.os.tag != .macos,
            .raw_path = std.mem.startsWith(u8, url, "kitty-shell-cwd://"),
        }) catch |e| {
            log.warn("invalid url in OSC 7: {}", .{e});
            return;
        };

        if (!std.mem.eql(u8, "file", uri.scheme) and
            !std.mem.eql(u8, "kitty-shell-cwd", uri.scheme))
        {
            log.warn("OSC 7 scheme must be file or kitty-shell-cwd, got: {s}", .{uri.scheme});
            return;
        }

        var host_buffer: [std.Uri.host_name_max]u8 = undefined;
        const host = uri.getHost(&host_buffer) catch |err| switch (err) {
            error.UriMissingHost => {
                log.warn("OSC 7 uri must contain a hostname: {}", .{err});
                return;
            },
            error.UriHostTooLong => {
                log.warn("failed to get full hostname for OSC 7 validation: {}", .{err});
                return;
            },
        };

        // OSC 7 is a little sketchy because anyone can send any value from
        // any host (such an SSH session). The best practice terminals follow
        // is to valid the hostname to be local.
        const host_valid = internal_os.hostname.isLocal(host) catch |err| switch (err) {
            error.PermissionDenied,
            error.Unexpected,
            => {
                log.warn("failed to get hostname for OSC 7 validation: {}", .{err});
                return;
            },
        };
        if (!host_valid) {
            log.warn("OSC 7 host ({s}) must be local", .{host});
            return;
        }

        // We need the raw path, which might require unescaping. We try to
        // avoid making any heap allocations by using the stack first.
        var arena_alloc: std.heap.ArenaAllocator = .init(self.alloc);
        var stack_alloc = std.heap.stackFallback(1024, arena_alloc.allocator());
        defer arena_alloc.deinit();
        const path = try uri.path.toRawMaybeAlloc(stack_alloc.get());

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
            try self.windowTitle(path);
            self.seen_title = false;
        }
    }

    fn colorOperation(
        self: *StreamHandler,
        op: terminal.osc.color.Operation,
        requests: *const terminal.osc.color.List,
        terminator: terminal.osc.Terminator,
    ) !void {
        // We'll need op one day if we ever implement reporting special colors.
        _ = op;

        // return early if there is nothing to do
        if (requests.count() == 0) return;

        var buffer: [1024]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&buffer);
        const alloc = fba.allocator();

        var response: std.ArrayListUnmanaged(u8) = .empty;
        const writer = response.writer(alloc);

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
                            => log.info("setting dynamic color {s} not implemented", .{
                                @tagName(dynamic),
                            }),
                        },
                        .special => log.info("setting special colors not implemented", .{}),
                    }

                    // Notify the surface of the color change
                    self.surfaceMessageWriter(.{ .color_change = .{
                        .target = set.target,
                        .color = set.color,
                    } });
                },

                .reset => |target| switch (target) {
                    .palette => |i| {
                        self.terminal.flags.dirty.palette = true;
                        self.terminal.colors.palette.reset(i);

                        self.surfaceMessageWriter(.{
                            .color_change = .{
                                .target = target,
                                .color = self.terminal.colors.palette.current[i],
                            },
                        });
                    },
                    .dynamic => |dynamic| switch (dynamic) {
                        .foreground => {
                            self.terminal.colors.foreground.reset();

                            if (self.terminal.colors.foreground.default) |c| {
                                self.surfaceMessageWriter(.{ .color_change = .{
                                    .target = target,
                                    .color = c,
                                } });
                            }
                        },
                        .background => {
                            self.terminal.colors.background.reset();

                            if (self.terminal.colors.background.default) |c| {
                                self.surfaceMessageWriter(.{ .color_change = .{
                                    .target = target,
                                    .color = c,
                                } });
                            }
                        },
                        .cursor => {
                            self.terminal.colors.cursor.reset();

                            if (self.terminal.colors.cursor.default) |c| {
                                self.surfaceMessageWriter(.{ .color_change = .{
                                    .target = target,
                                    .color = c,
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
                        => log.warn("resetting dynamic color {s} not implemented", .{
                            @tagName(dynamic),
                        }),
                    },
                    .special => log.info("resetting special colors not implemented", .{}),
                },

                .reset_palette => {
                    const mask = &self.terminal.colors.palette.mask;
                    var mask_it = mask.iterator(.{});
                    while (mask_it.next()) |i| {
                        self.terminal.flags.dirty.palette = true;
                        self.terminal.colors.palette.reset(@intCast(i));
                        self.surfaceMessageWriter(.{
                            .color_change = .{
                                .target = .{ .palette = @intCast(i) },
                                .color = self.terminal.colors.palette.current[i],
                            },
                        });
                    }
                    mask.* = .initEmpty();
                },

                .reset_special => log.warn(
                    "resetting all special colors not implemented",
                    .{},
                ),

                .query => |kind| report: {
                    if (self.osc_color_report_format == .none) break :report;

                    const color = switch (kind) {
                        .palette => |i| self.terminal.colors.palette.current[i],
                        .dynamic => |dynamic| switch (dynamic) {
                            .foreground => self.terminal.colors.foreground.get().?,
                            .background => self.terminal.colors.background.get().?,
                            .cursor => self.terminal.colors.cursor.get() orelse
                                self.terminal.colors.foreground.get().?,
                            .pointer_foreground,
                            .pointer_background,
                            .tektronix_foreground,
                            .tektronix_background,
                            .highlight_background,
                            .tektronix_cursor,
                            .highlight_foreground,
                            => {
                                log.info(
                                    "reporting dynamic color {s} not implemented",
                                    .{@tagName(dynamic)},
                                );
                                break :report;
                            },
                        },
                        .special => {
                            log.info("reporting special colors not implemented", .{});
                            break :report;
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
                            .dynamic => |dynamic| try writer.print(
                                "\x1b]{d};rgb:{x:0>4}/{x:0>4}/{x:0>4}",
                                .{
                                    @intFromEnum(dynamic),
                                    @as(u16, color.r) * 257,
                                    @as(u16, color.g) * 257,
                                    @as(u16, color.b) * 257,
                                },
                            ),
                            .special => unreachable,
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
                            .dynamic => |dynamic| try writer.print(
                                "\x1b]{d};rgb:{x:0>2}/{x:0>2}/{x:0>2}",
                                .{
                                    @intFromEnum(dynamic),
                                    @as(u16, color.r),
                                    @as(u16, color.g),
                                    @as(u16, color.b),
                                },
                            ),
                            .special => unreachable,
                        },

                        .none => unreachable,
                    }

                    try writer.writeAll(terminator.string());
                },
            }
        }

        if (response.items.len > 0) {
            // If any of the operations were reports, finalize the report
            // string and send it to the terminal.
            const msg = try termio.Message.writeReq(self.alloc, response.items);
            self.messageWriter(msg);
        }
    }

    fn showDesktopNotification(
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

    fn kittyColorReport(
        self: *StreamHandler,
        request: terminal.kitty.color.OSC,
    ) !void {
        var stream: std.Io.Writer.Allocating = .init(self.alloc);
        defer stream.deinit();
        const writer = &stream.writer;

        for (request.list.items) |item| {
            switch (item) {
                .query => |key| {
                    // If the writer buffer is empty, we need to write our prefix
                    if (stream.written().len == 0) try writer.writeAll("\x1b]21");

                    const color: terminal.color.RGB = switch (key) {
                        .palette => |palette| self.terminal.colors.palette.current[palette],
                        .special => |special| switch (special) {
                            .foreground => self.terminal.colors.foreground.get(),
                            .background => self.terminal.colors.background.get(),
                            .cursor => self.terminal.colors.cursor.get(),
                            else => {
                                log.warn("ignoring unsupported kitty color protocol key: {f}", .{key});
                                continue;
                            },
                        },
                    } orelse {
                        try writer.print(";{f}=", .{key});
                        continue;
                    };

                    try writer.print(
                        ";{f}=rgb:{x:0>2}/{x:0>2}/{x:0>2}",
                        .{ key, color.r, color.g, color.b },
                    );
                },
                .set => |v| switch (v.key) {
                    .palette => |palette| {
                        self.terminal.flags.dirty.palette = true;
                        self.terminal.colors.palette.set(palette, v.color);
                    },

                    .special => |special| switch (special) {
                        .foreground => self.terminal.colors.foreground.set(v.color),
                        .background => self.terminal.colors.background.set(v.color),
                        .cursor => self.terminal.colors.cursor.set(v.color),
                        else => {
                            log.warn(
                                "ignoring unsupported kitty color protocol key: {f}",
                                .{v.key},
                            );
                            continue;
                        },
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
                        else => {
                            log.warn(
                                "ignoring unsupported kitty color protocol key: {f}",
                                .{key},
                            );
                            continue;
                        },
                    },
                },
            }
        }

        // If we had any writes to our buffer, we queue them now
        if (stream.written().len > 0) {
            try writer.writeAll(request.terminator.string());
            self.messageWriter(.{
                .write_alloc = .{
                    .alloc = self.alloc,
                    .data = try stream.toOwnedSlice(),
                },
            });
        }

        // Note: we don't have to do a queueRender here because every
        // processed stream will queue a render once it is done processing
        // the read() syscall.
    }

    /// Display a GUI progress report.
    fn progressReport(self: *StreamHandler, report: terminal.osc.Command.ProgressReport) void {
        self.surfaceMessageWriter(.{ .progress_report = report });
    }
};
