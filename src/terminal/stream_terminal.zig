const std = @import("std");
const testing = std.testing;
const csi = @import("csi.zig");
const device_attributes = @import("device_attributes.zig");
const device_status = @import("device_status.zig");
const stream = @import("stream.zig");
const Action = stream.Action;
const Screen = @import("Screen.zig");
const modes = @import("modes.zig");
const osc_color = @import("osc/parsers/color.zig");
const kitty_color = @import("kitty/color.zig");
const size_report = @import("size_report.zig");
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

    /// Callbacks for certain effects that handlers may have. These
    /// may or may not fully replace internal handling of certain effects,
    /// but they allow for the handler to trigger or query external
    /// effects.
    effects: Effects = .readonly,

    pub const Effects = struct {
        /// Called when the terminal needs to write data back to the pty,
        /// e.g. in response to a DECRQM query. The data is only valid
        /// during the lifetime of the call so callers must copy it
        /// if it needs to be stored or used after the call returns.
        write_pty: ?*const fn (*Handler, [:0]const u8) void,

        /// Called when the bell is rung (BEL).
        bell: ?*const fn (*Handler) void,

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

        /// Called in response to XTWINOPS size queries (CSI 14/16/18 t).
        /// Returns the current terminal geometry used for encoding.
        /// Return null to silently ignore the query.
        size: ?*const fn (*Handler) ?size_report.Size,

        /// Called when the terminal title changes via escape sequences
        /// (e.g. OSC 0/2). The new title can be queried via
        /// handler.terminal.getTitle().
        title_changed: ?*const fn (*Handler) void,

        /// Called in response to an XTVERSION query. Returns the version
        /// string to report (e.g. "ghostty 1.2.3"). The returned memory
        /// must be valid for the lifetime of the call. The maximum length
        /// is 256 bytes; longer strings will be silently ignored.
        xtversion: ?*const fn (*Handler) []const u8,

        /// Called when an OSC 5522 (kitty clipboard protocol) sequence
        /// is received. The metadata and payload slices are only valid
        /// during the call. Implementers should use the OSC readOption
        /// helpers to parse the metadata.
        kitty_clipboard: ?*const fn (
            *Handler,
            metadata: []const u8,
            payload: ?[]const u8,
        ) void,

        /// No effects means that the stream effectively becomes readonly
        /// that only affects pure terminal state and ignores all side
        /// effects beyond that.
        pub const readonly: Effects = .{
            .bell = null,
            .color_scheme = null,
            .device_attributes = null,
            .enquiry = null,
            .kitty_clipboard = null,
            .size = null,
            .title_changed = null,
            .write_pty = null,
            .xtversion = null,
        };
    };

    pub fn init(terminal: *Terminal) Handler {
        return .{
            .terminal = terminal,
        };
    }

    pub fn deinit(self: *Handler) void {
        // Currently does nothing but may in the future so callers should
        // call this.
        _ = self;
    }

    pub fn vt(
        self: *Handler,
        comptime action: Action.Tag,
        value: Action.Value(action),
    ) void {
        self.vtFallible(action, value) catch |err| {
            log.warn("error handling VT action action={} err={}", .{ action, err });
        };
    }

    inline fn vtFallible(
        self: *Handler,
        comptime action: Action.Tag,
        value: Action.Value(action),
    ) !void {
        switch (action) {
            .print => try self.terminal.print(value.cp),
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
            .cursor_style => {
                const blink = switch (value) {
                    .default, .steady_block, .steady_bar, .steady_underline => false,
                    .blinking_block, .blinking_bar, .blinking_underline => true,
                };
                const style: Screen.CursorStyle = switch (value) {
                    .default, .blinking_block, .steady_block => .block,
                    .blinking_bar, .steady_bar => .bar,
                    .blinking_underline, .steady_underline => .underline,
                };
                self.terminal.modes.set(.cursor_blinking, blink);
                self.terminal.screens.active.cursor.cursor_style = style;
            },
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
                else => self.terminal.setAttribute(value) catch {},
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
            .full_reset => self.terminal.fullReset(),
            .start_hyperlink => try self.terminal.screens.active.startHyperlink(value.uri, value.id),
            .end_hyperlink => self.terminal.screens.active.endHyperlink(),
            .semantic_prompt => try self.terminal.semanticPrompt(value),
            .mouse_shape => self.terminal.mouse_shape = value,
            .color_operation => try self.colorOperation(value.op, &value.requests),
            .kitty_color_report => try self.kittyColorOperation(value),

            // Effect-based handlers
            .bell => self.bell(),
            .device_attributes => self.reportDeviceAttributes(value),
            .device_status => self.deviceStatus(value.request),
            .enquiry => self.reportEnquiry(),
            .kitty_keyboard_query => self.queryKittyKeyboard(),
            .request_mode => self.requestMode(value.mode),
            .request_mode_unknown => self.requestModeUnknown(value.mode, value.ansi),
            .size_report => self.reportSize(value),
            .window_title => self.windowTitle(value.title),
            .xtversion => self.reportXtversion(),

            // No supported DCS commands have any terminal-modifying effects,
            // but they may in the future. For now we just ignore it.
            .dcs_hook,
            .dcs_put,
            .dcs_unhook,
            => {},

            // APC can modify terminal state (Kitty graphics) but we don't
            // currently support it in the readonly stream.
            .apc_start,
            .apc_end,
            .apc_put,
            => {},

            .kitty_clipboard => if (self.effects.kitty_clipboard) |f| {
                f(self, value.metadata, value.payload);
            },

            // Have no terminal-modifying effect
            .report_pwd,
            .show_desktop_notification,
            .progress_report,
            .clipboard_contents,
            .title_push,
            .title_pop,
            => {},
        }
    }

    inline fn writePty(self: *Handler, data: [:0]const u8) void {
        const func = self.effects.write_pty orelse return;
        func(self, data);
    }

    fn bell(self: *Handler) void {
        const func = self.effects.bell orelse return;
        func(self);
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
                self.writePty(switch (scheme) {
                    .dark => "\x1B[?997;1n",
                    .light => "\x1B[?997;2n",
                });
            },
        }
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

    fn windowTitle(self: *Handler, title_raw: []const u8) void {
        // Prevent DoS attacks by limiting title length.
        const max_title_len = 1024;
        const title = if (title_raw.len > max_title_len) title: {
            log.warn("title length {d} exceeds max length {d}, truncating", .{
                title_raw.len,
                max_title_len,
            });
            break :title title_raw[0..max_title_len];
        } else title_raw;

        self.terminal.setTitle(title) catch |err| {
            log.warn("error setting title err={}", .{err});
            return;
        };

        const func = self.effects.title_changed orelse return;
        func(self);
    }

    fn requestMode(self: *Handler, mode: modes.Mode) void {
        const report = self.terminal.modes.getReport(.fromMode(mode));
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
            .in_band_size_reports,
            .focus_event,
            => {},

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
        op: osc_color.Operation,
        requests: *const osc_color.List,
    ) !void {
        _ = op;
        if (requests.count() == 0) return;

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

                .query,
                .reset_special,
                => {},
            }
        }
    }

    fn kittyColorOperation(
        self: *Handler,
        request: kitty_color.OSC,
    ) !void {
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
                .query => {},
            }
        }
    }
};

test "basic print" {
    var t: Terminal = try .init(testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    var s: Stream = .initAlloc(testing.allocator, .init(&t));
    defer s.deinit();

    s.nextSlice("Hello");
    try testing.expectEqual(@as(usize, 5), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);

    const str = try t.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("Hello", str);
}

test "cursor movement" {
    var t: Terminal = try .init(testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    var s: Stream = .initAlloc(testing.allocator, .init(&t));
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
    var t: Terminal = try .init(testing.allocator, .{ .cols = 20, .rows = 10 });
    defer t.deinit(testing.allocator);

    var s: Stream = .initAlloc(testing.allocator, .init(&t));
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
    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 10 });
    defer t.deinit(testing.allocator);

    var s: Stream = .initAlloc(testing.allocator, .init(&t));
    defer s.deinit();

    s.nextSlice("A\tB");
    try testing.expectEqual(@as(usize, 9), t.screens.active.cursor.x);

    const str = try t.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("A       B", str);
}

test "modes" {
    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    var s: Stream = .initAlloc(testing.allocator, .init(&t));
    defer s.deinit();

    // Test wraparound mode
    try testing.expect(t.modes.get(.wraparound));
    s.nextSlice("\x1B[?7l"); // Disable wraparound
    try testing.expect(!t.modes.get(.wraparound));
    s.nextSlice("\x1B[?7h"); // Enable wraparound
    try testing.expect(t.modes.get(.wraparound));
}

test "scrolling regions" {
    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    var s: Stream = .initAlloc(testing.allocator, .init(&t));
    defer s.deinit();

    // Set scrolling region from line 5 to 20
    s.nextSlice("\x1B[5;20r");
    try testing.expectEqual(@as(usize, 4), t.scrolling_region.top);
    try testing.expectEqual(@as(usize, 19), t.scrolling_region.bottom);
    try testing.expectEqual(@as(usize, 0), t.scrolling_region.left);
    try testing.expectEqual(@as(usize, 79), t.scrolling_region.right);
}

test "charsets" {
    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    var s: Stream = .initAlloc(testing.allocator, .init(&t));
    defer s.deinit();

    // Configure G0 as DEC special graphics
    s.nextSlice("\x1B(0");
    s.nextSlice("`"); // Should print diamond character

    const str = try t.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("◆", str);
}

test "alt screen" {
    var t: Terminal = try .init(testing.allocator, .{ .cols = 10, .rows = 5 });
    defer t.deinit(testing.allocator);

    var s: Stream = .initAlloc(testing.allocator, .init(&t));
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
    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    var s: Stream = .initAlloc(testing.allocator, .init(&t));
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
    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    var s: Stream = .initAlloc(testing.allocator, .init(&t));
    defer s.deinit();

    // Set bold and write text
    s.nextSlice("\x1B[1mBold\x1B[0m");

    // Verify we can write attributes - just check the string was written
    const str = try t.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("Bold", str);
}

test "DECALN screen alignment" {
    var t: Terminal = try .init(testing.allocator, .{ .cols = 10, .rows = 3 });
    defer t.deinit(testing.allocator);

    var s: Stream = .initAlloc(testing.allocator, .init(&t));
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
    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    var s: Stream = .initAlloc(testing.allocator, .init(&t));
    defer s.deinit();

    // Make some changes
    s.nextSlice("Hello");
    s.nextSlice("\x1B[10;20H");
    s.nextSlice("\x1B[5;20r"); // Set scroll region
    s.nextSlice("\x1B[?7l"); // Disable wraparound

    // Full reset
    s.nextSlice("\x1Bc");

    // Verify reset state
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(@as(usize, 0), t.scrolling_region.top);
    try testing.expectEqual(@as(usize, 23), t.scrolling_region.bottom);
    try testing.expect(t.modes.get(.wraparound));
}

test "ignores query actions" {
    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    var s: Stream = .initAlloc(testing.allocator, .init(&t));
    defer s.deinit();

    // These should be ignored without error
    s.nextSlice("\x1B[c"); // Device attributes
    s.nextSlice("\x1B[5n"); // Device status report
    s.nextSlice("\x1B[6n"); // Cursor position report

    // Terminal should still be functional
    s.nextSlice("Test");
    const str = try t.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("Test", str);
}

test "OSC 4 set and reset palette" {
    var t: Terminal = try .init(testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    var s: Stream = .initAlloc(testing.allocator, .init(&t));
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
    var t: Terminal = try .init(testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    var s: Stream = .initAlloc(testing.allocator, .init(&t));
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
    var t: Terminal = try .init(testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    var s: Stream = .initAlloc(testing.allocator, .init(&t));
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
    var t: Terminal = try .init(testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    var s: Stream = .initAlloc(testing.allocator, .init(&t));
    defer s.deinit();

    // Set background to green
    s.nextSlice("\x1b]11;rgb:00/ff/00\x1b\\");
    const bg = t.colors.background.get().?;
    try testing.expectEqual(@as(u8, 0x00), bg.r);
    try testing.expectEqual(@as(u8, 0xff), bg.g);
    try testing.expectEqual(@as(u8, 0x00), bg.b);

    // Reset background
    s.nextSlice("\x1b]111\x1b\\");
    try testing.expect(t.colors.background.get() == null);
}

test "OSC 12 set and reset cursor color" {
    var t: Terminal = try .init(testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    var s: Stream = .initAlloc(testing.allocator, .init(&t));
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

test "kitty color protocol set palette" {
    var t: Terminal = try .init(testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    var s: Stream = .initAlloc(testing.allocator, .init(&t));
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
    var t: Terminal = try .init(testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    var s: Stream = .initAlloc(testing.allocator, .init(&t));
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
    var t: Terminal = try .init(testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    var s: Stream = .initAlloc(testing.allocator, .init(&t));
    defer s.deinit();

    // Set foreground using kitty protocol
    s.nextSlice("\x1b]21;foreground=rgb:12/34/56\x1b\\");
    const fg = t.colors.foreground.get().?;
    try testing.expectEqual(@as(u8, 0x12), fg.r);
    try testing.expectEqual(@as(u8, 0x34), fg.g);
    try testing.expectEqual(@as(u8, 0x56), fg.b);
}

test "kitty color protocol set background" {
    var t: Terminal = try .init(testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    var s: Stream = .initAlloc(testing.allocator, .init(&t));
    defer s.deinit();

    // Set background using kitty protocol
    s.nextSlice("\x1b]21;background=rgb:78/9a/bc\x1b\\");
    const bg = t.colors.background.get().?;
    try testing.expectEqual(@as(u8, 0x78), bg.r);
    try testing.expectEqual(@as(u8, 0x9a), bg.g);
    try testing.expectEqual(@as(u8, 0xbc), bg.b);
}

test "kitty color protocol set cursor" {
    var t: Terminal = try .init(testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    var s: Stream = .initAlloc(testing.allocator, .init(&t));
    defer s.deinit();

    // Set cursor using kitty protocol
    s.nextSlice("\x1b]21;cursor=rgb:de/f0/12\x1b\\");
    const cursor = t.colors.cursor.get().?;
    try testing.expectEqual(@as(u8, 0xde), cursor.r);
    try testing.expectEqual(@as(u8, 0xf0), cursor.g);
    try testing.expectEqual(@as(u8, 0x12), cursor.b);
}

test "kitty color protocol reset foreground" {
    var t: Terminal = try .init(testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    var s: Stream = .initAlloc(testing.allocator, .init(&t));
    defer s.deinit();

    // Set and reset foreground
    s.nextSlice("\x1b]21;foreground=rgb:11/22/33\x1b\\");
    try testing.expect(t.colors.foreground.get() != null);

    s.nextSlice("\x1b]21;foreground=\x1b\\");
    // After reset, should be unset
    try testing.expect(t.colors.foreground.get() == null);
}

test "palette dirty flag set on color change" {
    var t: Terminal = try .init(testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    var s: Stream = .initAlloc(testing.allocator, .init(&t));
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
    var t: Terminal = try .init(testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    var s: Stream = .initAlloc(testing.allocator, .init(&t));
    defer s.deinit();

    s.nextSlice("Hello");
    s.nextSlice("\x1b]133;L\x07");
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 1), t.screens.active.cursor.y);
}

test "semantic prompt fresh line new prompt" {
    var t: Terminal = try .init(testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    var s: Stream = .initAlloc(testing.allocator, .init(&t));
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
    var t: Terminal = try .init(testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    var s: Stream = .initAlloc(testing.allocator, .init(&t));
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
    var t: Terminal = try .init(testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    var s: Stream = .initAlloc(testing.allocator, .init(&t));
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
    var t: Terminal = try .init(testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    var s: Stream = .initAlloc(testing.allocator, .init(&t));
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
    var t: Terminal = try .init(testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    var s: Stream = .initAlloc(testing.allocator, .init(&t));
    defer s.deinit();

    // OSC 133;N when already at column 0 should stay on same line
    s.nextSlice("\x1b]133;N\x07");
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.x);
    try testing.expectEqual(@as(usize, 0), t.screens.active.cursor.y);
    try testing.expectEqual(.prompt, t.screens.active.cursor.semantic_content);
}

test "semantic prompt end_prompt_start_input_terminate_eol clears on linefeed" {
    var t: Terminal = try .init(testing.allocator, .{ .cols = 10, .rows = 10 });
    defer t.deinit(testing.allocator);

    var s: Stream = .initAlloc(testing.allocator, .init(&t));
    defer s.deinit();

    // Set input terminated by EOL
    s.nextSlice("\x1b]133;I\x07");
    try testing.expectEqual(.input, t.screens.active.cursor.semantic_content);

    // Linefeed should reset semantic content to output
    s.nextSlice("\n");
    try testing.expectEqual(.output, t.screens.active.cursor.semantic_content);
}

test "bell effect callback" {
    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    // Test bell with null callback (default readonly effects) doesn't crash
    {
        var s: Stream = .initAlloc(testing.allocator, .init(&t));
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

        var s: Stream = .initAlloc(testing.allocator, handler);
        defer s.deinit();

        s.nextSlice("\x07");
        try testing.expectEqual(@as(usize, 1), S.bell_count);

        s.nextSlice("\x07\x07");
        try testing.expectEqual(@as(usize, 3), S.bell_count);
    }
}

test "request mode DECRQM with write_pty callback" {
    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    // Without callback, DECRQM should not crash
    {
        var s: Stream = .initAlloc(testing.allocator, .init(&t));
        defer s.deinit();

        // DECRQM for mode 7 (wraparound) — should be silently ignored
        s.nextSlice("\x1B[?7$p");
    }

    t.fullReset();

    // With callback, DECRQM should produce a response
    {
        const S = struct {
            var last_response: ?[:0]const u8 = null;
            fn writePty(_: *Handler, data: [:0]const u8) void {
                if (last_response) |old| testing.allocator.free(old);
                last_response = testing.allocator.dupeZ(u8, data) catch @panic("OOM");
            }
        };
        S.last_response = null;
        defer if (S.last_response) |old| testing.allocator.free(old);

        var handler: Handler = .init(&t);
        handler.effects.write_pty = &S.writePty;

        var s: Stream = .initAlloc(testing.allocator, handler);
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
    }
}

test "stream: CSI W with intermediate but no params" {
    // Regression test from AFL++ crash. CSI ? W without
    // parameters caused an out-of-bounds access on input.params[0].
    var t: Terminal = try .init(testing.allocator, .{
        .cols = 80,
        .rows = 24,
        .max_scrollback = 100,
    });
    defer t.deinit(testing.allocator);

    var s: Stream = .initAlloc(testing.allocator, .init(&t));
    defer s.deinit();

    s.nextSlice("\x1b[?W");
}

test "window_title effect is called" {
    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
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

    var s: Stream = .initAlloc(testing.allocator, handler);
    defer s.deinit();

    // Set window title via OSC 2
    s.nextSlice("\x1b]2;Hello World\x1b\\");
    try testing.expectEqualStrings("Hello World", t.getTitle().?);
    try testing.expectEqual(@as(usize, 1), S.title_changed_count);
}

test "window_title effect not called without callback" {
    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    var s: Stream = .initAlloc(testing.allocator, .init(&t));
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
    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
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

    var s: Stream = .initAlloc(testing.allocator, handler);
    defer s.deinit();

    // Set empty window title
    s.nextSlice("\x1b]2;\x1b\\");
    try testing.expect(t.getTitle() == null);
    try testing.expectEqual(@as(usize, 1), S.title_changed_count);
}

test "kitty_keyboard_query" {
    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var written: ?[:0]const u8 = null;
        fn writePty(_: *Handler, data: [:0]const u8) void {
            written = data;
        }
    };
    S.written = null;

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;

    var s: Stream = .initAlloc(testing.allocator, handler);
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
    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var written: ?[:0]const u8 = null;
        fn writePty(_: *Handler, data: [:0]const u8) void {
            written = data;
        }
    };
    S.written = null;

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;

    var s: Stream = .initAlloc(testing.allocator, handler);
    defer s.deinit();

    // Without xtversion effect set, should report "libghostty"
    s.nextSlice("\x1b[>0q");
    try testing.expectEqualStrings("\x1bP>|libghostty\x1b\\", S.written.?);
}

test "xtversion with effect" {
    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var written: ?[:0]const u8 = null;
        fn writePty(_: *Handler, data: [:0]const u8) void {
            written = data;
        }
        fn xtversion(_: *Handler) []const u8 {
            return "ghostty 1.2.3";
        }
    };
    S.written = null;

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.xtversion = &S.xtversion;

    var s: Stream = .initAlloc(testing.allocator, handler);
    defer s.deinit();

    s.nextSlice("\x1b[>0q");
    try testing.expectEqualStrings("\x1bP>|ghostty 1.2.3\x1b\\", S.written.?);
}

test "xtversion with empty string effect" {
    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var written: ?[:0]const u8 = null;
        fn writePty(_: *Handler, data: [:0]const u8) void {
            written = data;
        }
        fn xtversion(_: *Handler) []const u8 {
            return "";
        }
    };
    S.written = null;

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;
    handler.effects.xtversion = &S.xtversion;

    var s: Stream = .initAlloc(testing.allocator, handler);
    defer s.deinit();

    // Empty string from effect should fall back to "libghostty"
    s.nextSlice("\x1b[>0q");
    try testing.expectEqualStrings("\x1bP>|libghostty\x1b\\", S.written.?);
}

test "size report csi_14_t with effect" {
    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: [:0]const u8) void {
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

    var s: Stream = .initAlloc(testing.allocator, handler);
    defer s.deinit();

    // CSI 14 t - report text area size in pixels
    s.nextSlice("\x1b[14t");
    defer testing.allocator.free(S.written.?);
    try testing.expectEqualStrings("\x1b[4;432;720t", S.written.?);
}

test "size report csi_16_t with effect" {
    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: [:0]const u8) void {
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

    var s: Stream = .initAlloc(testing.allocator, handler);
    defer s.deinit();

    // CSI 16 t - report cell size in pixels
    s.nextSlice("\x1b[16t");
    defer testing.allocator.free(S.written.?);
    try testing.expectEqualStrings("\x1b[6;18;9t", S.written.?);
}

test "size report csi_18_t with effect" {
    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: [:0]const u8) void {
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

    var s: Stream = .initAlloc(testing.allocator, handler);
    defer s.deinit();

    // CSI 18 t - report text area size in characters
    s.nextSlice("\x1b[18t");
    defer testing.allocator.free(S.written.?);
    try testing.expectEqualStrings("\x1b[8;24;80t", S.written.?);
}

test "size report no effect callback" {
    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: [:0]const u8) void {
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
    };
    S.written = null;

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;

    var s: Stream = .initAlloc(testing.allocator, handler);
    defer s.deinit();

    // Without size effect, size reports should be silently ignored
    s.nextSlice("\x1b[14t");
    try testing.expect(S.written == null);
}

test "size report csi_21_t title" {
    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: [:0]const u8) void {
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
    };
    S.written = null;

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;

    var s: Stream = .initAlloc(testing.allocator, handler);
    defer s.deinit();

    // Set a title first
    s.nextSlice("\x1b]2;My Title\x1b\\");

    // CSI 21 t - report title (no size effect needed)
    s.nextSlice("\x1b[21t");
    defer testing.allocator.free(S.written.?);
    try testing.expectEqualStrings("\x1b]lMy Title\x1b\\", S.written.?);
}

test "enquiry no effect" {
    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: [:0]const u8) void {
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
    };
    S.written = null;

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;

    var s: Stream = .initAlloc(testing.allocator, handler);
    defer s.deinit();

    // ENQ without enquiry effect should not write anything
    s.nextSlice("\x05");
    try testing.expect(S.written == null);
}

test "enquiry with effect" {
    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: [:0]const u8) void {
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

    var s: Stream = .initAlloc(testing.allocator, handler);
    defer s.deinit();

    s.nextSlice("\x05");
    defer testing.allocator.free(S.written.?);
    try testing.expectEqualStrings("ghostty", S.written.?);
}

test "enquiry with empty response" {
    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: [:0]const u8) void {
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

    var s: Stream = .initAlloc(testing.allocator, handler);
    defer s.deinit();

    // Empty enquiry response should not write anything
    s.nextSlice("\x05");
    try testing.expect(S.written == null);
}

test "device status: operating status" {
    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: [:0]const u8) void {
            if (written) |old| testing.allocator.free(old);
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
    };
    S.written = null;
    defer if (S.written) |old| testing.allocator.free(old);

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;

    var s: Stream = .initAlloc(testing.allocator, handler);
    defer s.deinit();

    // CSI 5 n — operating status report
    s.nextSlice("\x1B[5n");
    try testing.expectEqualStrings("\x1B[0n", S.written.?);
}

test "device status: cursor position" {
    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: [:0]const u8) void {
            if (written) |old| testing.allocator.free(old);
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
    };
    S.written = null;
    defer if (S.written) |old| testing.allocator.free(old);

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;

    var s: Stream = .initAlloc(testing.allocator, handler);
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
    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: [:0]const u8) void {
            if (written) |old| testing.allocator.free(old);
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
    };
    S.written = null;
    defer if (S.written) |old| testing.allocator.free(old);

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;

    var s: Stream = .initAlloc(testing.allocator, handler);
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
    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: [:0]const u8) void {
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

    var s: Stream = .initAlloc(testing.allocator, handler);
    defer s.deinit();

    // CSI ? 996 n — color scheme query
    s.nextSlice("\x1B[?996n");
    try testing.expectEqualStrings("\x1B[?997;1n", S.written.?);
}

test "device status: color scheme light" {
    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: [:0]const u8) void {
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

    var s: Stream = .initAlloc(testing.allocator, handler);
    defer s.deinit();

    // CSI ? 996 n — color scheme query
    s.nextSlice("\x1B[?996n");
    try testing.expectEqualStrings("\x1B[?997;2n", S.written.?);
}

test "device status: color scheme without callback" {
    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: [:0]const u8) void {
            if (written) |old| testing.allocator.free(old);
            written = testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
    };
    S.written = null;
    defer if (S.written) |old| testing.allocator.free(old);

    var handler: Handler = .init(&t);
    handler.effects.write_pty = &S.writePty;

    var s: Stream = .initAlloc(testing.allocator, handler);
    defer s.deinit();

    // Without color_scheme effect, query should be silently ignored
    s.nextSlice("\x1B[?996n");
    try testing.expect(S.written == null);
}

test "device status: readonly ignores all" {
    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    var s: Stream = .initAlloc(testing.allocator, .init(&t));
    defer s.deinit();

    // All device status queries should be silently ignored without effects
    s.nextSlice("\x1B[5n");
    s.nextSlice("\x1B[6n");
    s.nextSlice("\x1B[?996n");

    // Terminal should still be functional
    s.nextSlice("Test");
    const str = try t.plainString(testing.allocator);
    defer testing.allocator.free(str);
    try testing.expectEqualStrings("Test", str);
}

test "device attributes: primary DA" {
    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: [:0]const u8) void {
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

    var s: Stream = .initAlloc(testing.allocator, handler);
    defer s.deinit();

    s.nextSlice("\x1B[c");
    try testing.expectEqualStrings("\x1b[?62;22c", S.written.?);
}

test "device attributes: secondary DA" {
    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: [:0]const u8) void {
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

    var s: Stream = .initAlloc(testing.allocator, handler);
    defer s.deinit();

    s.nextSlice("\x1B[>c");
    try testing.expectEqualStrings("\x1b[>1;0;0c", S.written.?);
}

test "device attributes: tertiary DA" {
    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: [:0]const u8) void {
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

    var s: Stream = .initAlloc(testing.allocator, handler);
    defer s.deinit();

    s.nextSlice("\x1B[=c");
    try testing.expectEqualStrings("\x1bP!|00000000\x1b\\", S.written.?);
}

test "device attributes: readonly ignores" {
    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    var s: Stream = .initAlloc(testing.allocator, .init(&t));
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
    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *Handler, data: [:0]const u8) void {
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

    var s: Stream = .initAlloc(testing.allocator, handler);
    defer s.deinit();

    s.nextSlice("\x1B[c");
    try testing.expectEqualStrings("\x1b[?64;22;52c", S.written.?);

    s.nextSlice("\x1B[>c");
    try testing.expectEqualStrings("\x1b[>41;100;0c", S.written.?);
}

test "kitty_clipboard effects callback" {
    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    // Without callback: OSC 5522 is silently ignored
    {
        var s: Stream = .initAlloc(testing.allocator, .init(&t));
        defer s.deinit();
        s.nextSlice("\x1b]5522;type=read:mime=dGV4dC9wbGFpbg==\x1b\\");
    }

    t.fullReset();

    // With callback: metadata and payload are delivered
    {
        const S = struct {
            var last_metadata: ?[]const u8 = null;
            var last_payload: ?[]const u8 = null;

            fn kittyClipboard(
                _: *Handler,
                metadata: []const u8,
                payload: ?[]const u8,
            ) void {
                if (last_metadata) |m| testing.allocator.free(m);
                if (last_payload) |p| testing.allocator.free(p);
                last_metadata = testing.allocator.dupe(u8, metadata) catch @panic("OOM");
                last_payload = if (payload) |p|
                    testing.allocator.dupe(u8, p) catch @panic("OOM")
                else
                    null;
            }
        };
        S.last_metadata = null;
        S.last_payload = null;
        defer {
            if (S.last_metadata) |m| testing.allocator.free(m);
            if (S.last_payload) |p| testing.allocator.free(p);
        }

        var handler: Handler = .init(&t);
        handler.effects.kitty_clipboard = &S.kittyClipboard;

        var s: Stream = .initAlloc(testing.allocator, handler);
        defer s.deinit();

        // Read request (no payload)
        s.nextSlice("\x1b]5522;type=read:mime=dGV4dC9wbGFpbg==:password=c2VjcmV0\x1b\\");
        try testing.expectEqualStrings(
            "type=read:mime=dGV4dC9wbGFpbg==:password=c2VjcmV0",
            S.last_metadata.?,
        );
        try testing.expect(S.last_payload == null);

        // Write with payload
        s.nextSlice("\x1b]5522;type=wdata:mime=aW1hZ2UvcG5n;SGVsbG8=\x1b\\");
        try testing.expectEqualStrings("type=wdata:mime=aW1hZ2UvcG5n", S.last_metadata.?);
        try testing.expectEqualStrings("SGVsbG8=", S.last_payload.?);
    }
}

test "kitty_clipboard mode 5522 set and reset" {
    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    var s: Stream = .initAlloc(testing.allocator, .init(&t));
    defer s.deinit();

    // Default: off
    try testing.expect(!t.modes.get(.kitty_clipboard_protocol));

    // DECSET 5522
    s.nextSlice("\x1b[?5522h");
    try testing.expect(t.modes.get(.kitty_clipboard_protocol));

    // DECRST 5522
    s.nextSlice("\x1b[?5522l");
    try testing.expect(!t.modes.get(.kitty_clipboard_protocol));

    // Full reset clears it
    s.nextSlice("\x1b[?5522h");
    try testing.expect(t.modes.get(.kitty_clipboard_protocol));
    t.fullReset();
    try testing.expect(!t.modes.get(.kitty_clipboard_protocol));
}

test "kitty_clipboard effects callback receives multiple sequences in order" {
    var t: Terminal = try .init(testing.allocator, .{ .cols = 80, .rows = 24 });
    defer t.deinit(testing.allocator);

    // An app may send several OSC 5522 in one write — each must dispatch.
    // If the callback only fires for the last one (parser state bug) or
    // metadata slices alias each other across calls, this catches it.
    const S = struct {
        var calls: std.ArrayList([]const u8) = .empty;
        fn cb(_: *Handler, metadata: []const u8, _: ?[]const u8) void {
            calls.append(testing.allocator, testing.allocator.dupe(u8, metadata) catch @panic("OOM")) catch @panic("OOM");
        }
    };
    S.calls = .empty;
    defer {
        for (S.calls.items) |m| testing.allocator.free(m);
        S.calls.deinit(testing.allocator);
    }

    var handler: Handler = .init(&t);
    handler.effects.kitty_clipboard = &S.cb;

    var s: Stream = .initAlloc(testing.allocator, handler);
    defer s.deinit();

    s.nextSlice(
        "\x1b]5522;type=read:mime=AAA\x1b\\" ++
            "\x1b]5522;type=read:mime=BBB\x1b\\" ++
            "\x1b]5522;type=read:mime=CCC\x1b\\",
    );

    try testing.expectEqual(@as(usize, 3), S.calls.items.len);
    try testing.expectEqualStrings("type=read:mime=AAA", S.calls.items[0]);
    try testing.expectEqualStrings("type=read:mime=BBB", S.calls.items[1]);
    try testing.expectEqualStrings("type=read:mime=CCC", S.calls.items[2]);
}
