const streampkg = @This();
const std = @import("std");
const build_options = @import("terminal_options");
const assert = @import("../quirks.zig").inlineAssert;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const simd = @import("../simd/main.zig");
const lib = @import("../lib/main.zig");
const Parser = @import("Parser.zig");
const ansi = @import("ansi.zig");
const charsets = @import("charsets.zig");
const device_status = @import("device_status.zig");
const csi = @import("csi.zig");
const kitty = @import("kitty.zig");
const modes = @import("modes.zig");
const osc = @import("osc.zig");
const sgr = @import("sgr.zig");
const UTF8Decoder = @import("UTF8Decoder.zig");
const MouseShape = @import("mouse_shape.zig").MouseShape;

const log = std.log.scoped(.stream);

/// Flip this to true when you want verbose debug output for
/// debugging terminal stream issues. In addition to louder
/// output this will also disable the SIMD optimizations in
/// order to make it easier to see every byte. So if you're
/// debugging an issue in the SIMD code then you'll need to
/// do something else.
const debug = false;

const lib_target: lib.Target = if (build_options.c_abi) .c else .zig;

/// The possible actions that can be emitted by the Stream
/// function for handling.
pub const Action = union(Key) {
    print: Print,
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
    device_attributes: ansi.DeviceAttributeReq,
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
    apc_end,
    apc_put: u8,
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
    set_attribute: sgr.Attribute,
    kitty_color_report: kitty.color.OSC,
    color_operation: ColorOperation,
    semantic_prompt: SemanticPrompt,

    pub const Key = lib.Enum(
        lib_target,
        &.{
            "print",
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
            "set_attribute",
            "kitty_color_report",
            "color_operation",
            "semantic_prompt",
        },
    );

    /// C ABI functions.
    const c_union = lib.TaggedUnion(
        lib_target,
        @This(),
        // TODO: Before shipping an ABI-compatible libghostty, verify this.
        // This was just arbitrarily chosen for now.
        [16]u64,
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

    pub const InvokeCharset = lib.Struct(lib_target, struct {
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

        pub const C = u16;

        pub fn cval(self: DeviceStatus) DeviceStatus.C {
            return @bitCast(self.request);
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

    pub const ConfigureCharset = lib.Struct(lib_target, struct {
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
};

/// Returns a type that can process a stream of tty control characters.
/// This will call the `vt` function on type T with the following signature:
///
///   fn(comptime action: Action.Key, value: Action.Value(action)) !void
///
/// The handler type T can choose to react to whatever actions it cares
/// about in its pursuit of implementing a terminal emulator or other
/// functionality.
///
/// The Handler type must also have a `deinit` function.
///
/// The "comptime" key is on purpose (vs. a standard Zig tagged union)
/// because it allows the compiler to optimize away unimplemented actions.
/// e.g. you don't need to pay a conditional branching cost on every single
/// action because the Zig compiler codegens separate code paths for every
/// single action at comptime.
pub fn Stream(comptime Handler: type) type {
    return struct {
        const Self = @This();

        pub const Action = streampkg.Action;

        const T = switch (@typeInfo(Handler)) {
            .pointer => |p| p.child,
            else => Handler,
        };

        handler: Handler,
        parser: Parser,
        utf8decoder: UTF8Decoder,

        /// Initialize an allocation-free stream. This will preallocate various
        /// sizes as necessary and anything over that will be dropped. If you
        /// want to support more dynamic behavior use initAlloc instead.
        ///
        /// As a concrete example of something that requires heap allocation,
        /// consider OSC 52 (clipboard operations) which can be arbitrarily
        /// large.
        ///
        /// If you want to limit allocation size, use an allocator with
        /// a size limit with initAlloc.
        ///
        /// This takes ownership of the handler and will call deinit
        /// when the stream is deinitialized.
        pub fn init(h: Handler) Self {
            return .{
                .handler = h,
                .parser = .init(),
                .utf8decoder = .{},
            };
        }

        /// Initialize the stream that supports heap allocation as necessary.
        pub fn initAlloc(alloc: Allocator, h: Handler) Self {
            var self: Self = .init(h);
            self.parser.osc_parser.alloc = alloc;
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.parser.deinit();
            self.handler.deinit();
        }

        /// Process a string of characters.
        pub inline fn nextSlice(self: *Self, input: []const u8) !void {
            // Disable SIMD optimizations if build requests it or if our
            // manual debug mode is on.
            if (comptime debug or !build_options.simd) {
                for (input) |c| try self.next(c);
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
                try self.nextSliceCapped(input[i .. i + len], &cp_buf);
                i += len;
                if (i >= input.len) break;
            }
        }

        inline fn nextSliceCapped(self: *Self, input: []const u8, cp_buf: []u32) !void {
            assert(input.len <= cp_buf.len);

            var offset: usize = 0;

            // If the scalar UTF-8 decoder was in the middle of processing
            // a code sequence, we continue until it's not.
            while (self.utf8decoder.state != 0) {
                if (offset >= input.len) return;
                try self.nextUtf8(input[offset]);
                offset += 1;
            }
            if (offset >= input.len) return;

            // If we're not in the ground state then we process until
            // we are. This can happen if the last chunk of input put us
            // in the middle of a control sequence.
            offset += try self.consumeUntilGround(input[offset..]);
            if (offset >= input.len) return;
            offset += try self.consumeAllEscapes(input[offset..]);

            // If we're in the ground state then we can use SIMD to process
            // input until we see an ESC (0x1B), since all other characters
            // up to that point are just UTF-8.
            while (self.parser.state == .ground and offset < input.len) {
                const res = simd.vt.utf8DecodeUntilControlSeq(input[offset..], cp_buf);
                for (cp_buf[0..res.decoded]) |cp| {
                    if (cp <= 0xF) {
                        try self.execute(@intCast(cp));
                    } else {
                        try self.print(@intCast(cp));
                    }
                }
                // Consume the bytes we just processed.
                offset += res.consumed;

                if (offset >= input.len) return;

                // If our offset is NOT an escape then we must have a
                // partial UTF-8 sequence. In that case, we pass it off
                // to the scalar parser.
                if (input[offset] != 0x1B) {
                    const rem = input[offset..];
                    for (rem) |c| try self.nextUtf8(c);
                    return;
                }

                // Process control sequences until we run out.
                offset += try self.consumeAllEscapes(input[offset..]);
            }
        }

        /// Parses back-to-back escape sequences until none are left.
        /// Returns the number of bytes consumed from the provided input.
        ///
        /// Expects input to start with 0x1B, use consumeUntilGround first
        /// if the stream may be in the middle of an escape sequence.
        inline fn consumeAllEscapes(self: *Self, input: []const u8) !usize {
            var offset: usize = 0;
            while (input[offset] == 0x1B) {
                self.parser.state = .escape;
                self.parser.clear();
                offset += 1;
                offset += try self.consumeUntilGround(input[offset..]);
                if (offset >= input.len) return input.len;
            }
            return offset;
        }

        /// Parses escape sequences until the parser reaches the ground state.
        /// Returns the number of bytes consumed from the provided input.
        inline fn consumeUntilGround(self: *Self, input: []const u8) !usize {
            var offset: usize = 0;
            while (self.parser.state != .ground) {
                if (offset >= input.len) return input.len;
                try self.nextNonUtf8(input[offset]);
                offset += 1;
            }
            return offset;
        }

        /// Like nextSlice but takes one byte and is necessarily a scalar
        /// operation that can't use SIMD. Prefer nextSlice if you can and
        /// try to get multiple bytes at once.
        pub inline fn next(self: *Self, c: u8) !void {
            // The scalar path can be responsible for decoding UTF-8.
            if (self.parser.state == .ground) {
                try self.nextUtf8(c);
                return;
            }

            try self.nextNonUtf8(c);
        }

        /// Process the next byte and print as necessary.
        ///
        /// This assumes we're in the UTF-8 decoding state. If we may not
        /// be in the UTF-8 decoding state call nextSlice or next.
        inline fn nextUtf8(self: *Self, c: u8) !void {
            assert(self.parser.state == .ground);

            const res = self.utf8decoder.next(c);
            const consumed = res[1];
            if (res[0]) |codepoint| {
                try self.handleCodepoint(codepoint);
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
                    try self.handleCodepoint(codepoint);
                }
            }
        }

        /// To be called whenever the utf-8 decoder produces a codepoint.
        ///
        /// This function is abstracted this way to handle the case where
        /// the decoder emits a 0x1B after rejecting an ill-formed sequence.
        inline fn handleCodepoint(self: *Self, c: u21) !void {
            // We need to increase the eval branch limit because a lot of
            // tests end up running almost completely at comptime due to
            // a chain of inline functions.
            @setEvalBranchQuota(100_000);

            // C0 control
            if (c <= 0xF) {
                @branchHint(.unlikely);
                try self.execute(@intCast(c));
                return;
            }
            // ESC
            if (c == 0x1B) {
                self.parser.state = .escape;
                self.parser.clear();
                return;
            }
            try self.print(@intCast(c));
        }

        /// Process the next character and call any callbacks if necessary.
        ///
        /// This assumes that we're not in the UTF-8 decoding state. If
        /// we may be in the UTF-8 decoding state call nextSlice or next.
        fn nextNonUtf8(self: *Self, c: u8) !void {
            assert(self.parser.state != .ground);

            // Fast path for CSI entry.
            if (self.parser.state == .escape and c == '[') {
                self.parser.state = .csi_entry;
                return;
            }
            // Fast path for CSI params.
            if (self.parser.state == .csi_param) csi_param: {
                // csi_param is the most common parser state
                // other than ground by a fairly wide margin.
                //
                // ref: https://github.com/qwerasd205/asciinema-stats
                @branchHint(.likely);
                switch (c) {
                    // A C0 escape (yes, this is valid):
                    0x00...0x0F => try self.execute(c),
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
                    // Explicitly ignored:
                    0x7F => {},
                    // Defer to the state machine to
                    // handle any other characters:
                    else => break :csi_param,
                }
                return;
            }

            // We explicitly inline this call here for performance reasons.
            //
            // We do this rather than mark Parser.next as inline because doing
            // that causes weird behavior in some tests- I'm not sure if they
            // miscompile or it's just very counter-intuitive comptime stuff,
            // but regardless, this is the easy solution.
            const actions = @call(.always_inline, Parser.next, .{ &self.parser, c });

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
                    .print => |p| try self.print(p),
                    .execute => |code| try self.execute(code),
                    .csi_dispatch => |csi_action| try self.csiDispatch(csi_action),
                    .esc_dispatch => |esc| try self.escDispatch(esc),
                    .osc_dispatch => |cmd| try self.oscDispatch(cmd),
                    .dcs_hook => |dcs| try self.handler.vt(.dcs_hook, dcs),
                    .dcs_put => |code| try self.handler.vt(.dcs_put, code),
                    .dcs_unhook => try self.handler.vt(.dcs_unhook, {}),
                    .apc_start => try self.handler.vt(.apc_start, {}),
                    .apc_put => |code| try self.handler.vt(.apc_put, code),
                    .apc_end => try self.handler.vt(.apc_end, {}),
                }
            }
        }

        pub inline fn print(self: *Self, c: u21) !void {
            try self.handler.vt(.print, .{ .cp = c });
        }

        pub inline fn execute(self: *Self, c: u8) !void {
            // If the character is > 0x7F, it's a C1 (8-bit) control,
            // which is strictly equivalent to `ESC` plus `c - 0x40`.
            if (c > 0x7F) {
                @branchHint(.unlikely);
                log.info("executing C1 0x{x} as ESC {c}", .{ c, c - 0x40 });
                try self.escDispatch(.{
                    .intermediates = &.{},
                    .final = c - 0x40,
                });
                return;
            }

            const c0: ansi.C0 = @enumFromInt(c);
            if (comptime debug) log.info("execute: {f}", .{c0});
            switch (c0) {
                // We ignore SOH/STX: https://github.com/microsoft/terminal/issues/10786
                .NUL, .SOH, .STX => {},

                .ENQ => try self.handler.vt(.enquiry, {}),
                .BEL => try self.handler.vt(.bell, {}),
                .BS => try self.handler.vt(.backspace, {}),
                .HT => try self.handler.vt(.horizontal_tab, 1),
                .LF, .VT, .FF => try self.handler.vt(.linefeed, {}),
                .CR => try self.handler.vt(.carriage_return, {}),
                .SO => try self.handler.vt(.invoke_charset, .{ .bank = .GL, .charset = .G1, .locking = false }),
                .SI => try self.handler.vt(.invoke_charset, .{ .bank = .GL, .charset = .G0, .locking = false }),

                else => log.warn("invalid C0 character, ignoring: 0x{x}", .{c}),
            }
        }

        inline fn csiDispatch(self: *Self, input: Parser.Action.CSI) !void {
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
                        0 => try self.handler.vt(.cursor_up, .{
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
                    0 => try self.handler.vt(.cursor_down, .{
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
                        0 => try self.handler.vt(.cursor_right, .{
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
                    0 => try self.handler.vt(.cursor_left, .{
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
                        try self.handler.vt(.cursor_down, .{
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
                        try self.handler.vt(.carriage_return, {});
                    },

                    else => log.warn(
                        "ignoring unimplemented CSI E with intermediates: {s}",
                        .{input.intermediates},
                    ),
                },

                // CPL - Cursor Previous Line
                'F' => switch (input.intermediates.len) {
                    0 => {
                        try self.handler.vt(.cursor_up, .{
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
                        try self.handler.vt(.carriage_return, {});
                    },

                    else => log.warn(
                        "ignoring unimplemented CSI F with intermediates: {s}",
                        .{input.intermediates},
                    ),
                },

                // HPA - Cursor Horizontal Position Absolute
                // TODO: test
                'G', '`' => switch (input.intermediates.len) {
                    0 => try self.handler.vt(.cursor_col, .{
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
                            try self.handler.vt(.cursor_pos, pos);
                        },

                        else => log.warn(
                            "ignoring unimplemented CSI H with intermediates: {s}",
                            .{input.intermediates},
                        ),
                    }
                },

                // CHT - Cursor Horizontal Tabulation
                'I' => switch (input.intermediates.len) {
                    0 => try self.handler.vt(.horizontal_tab, switch (input.params.len) {
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
                        1 => std.meta.intToEnum(csi.EraseDisplay, input.params[0]) catch null,
                        else => null,
                    };

                    const mode = mode_ orelse {
                        log.warn("invalid erase display command: {f}", .{input});
                        return;
                    };

                    switch (mode) {
                        .below => try self.handler.vt(.erase_display_below, protected),
                        .above => try self.handler.vt(.erase_display_above, protected),
                        .complete => try self.handler.vt(.erase_display_complete, protected),
                        .scrollback => try self.handler.vt(.erase_display_scrollback, protected),
                        .scroll_complete => try self.handler.vt(.erase_display_scroll_complete, protected),
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
                        1 => if (input.params[0] < 3) @enumFromInt(input.params[0]) else null,
                        else => null,
                    };

                    const mode = mode_ orelse {
                        @branchHint(.unlikely);
                        log.warn("invalid erase line command: {f}", .{input});
                        return;
                    };

                    switch (mode) {
                        .right => try self.handler.vt(.erase_line_right, protected),
                        .left => try self.handler.vt(.erase_line_left, protected),
                        .complete => try self.handler.vt(.erase_line_complete, protected),
                        .right_unless_pending_wrap => try self.handler.vt(.erase_line_right_unless_pending_wrap, protected),
                        _ => {
                            @branchHint(.unlikely);
                            log.warn("invalid erase line mode: {}", .{mode});
                        },
                    }
                },

                // IL - Insert Lines
                // TODO: test
                'L' => switch (input.intermediates.len) {
                    0 => try self.handler.vt(.insert_lines, switch (input.params.len) {
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
                    0 => try self.handler.vt(.delete_lines, switch (input.params.len) {
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
                    0 => try self.handler.vt(.delete_chars, switch (input.params.len) {
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
                    0 => try self.handler.vt(.scroll_up, switch (input.params.len) {
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
                    0 => try self.handler.vt(.scroll_down, switch (input.params.len) {
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
                            try self.handler.vt(.tab_set, {});
                            return;
                        }

                        switch (input.params.len) {
                            0 => unreachable,

                            1 => switch (input.params[0]) {
                                0 => unreachable,

                                2 => try self.handler.vt(.tab_clear_current, {}),

                                5 => try self.handler.vt(.tab_clear_all, {}),

                                else => {},
                            },

                            else => {},
                        }

                        log.warn("invalid cursor tabulation control: {f}", .{input});
                        return;
                    },

                    1 => if (input.intermediates[0] == '?' and input.params[0] == 5) {
                        try self.handler.vt(.tab_reset, {});
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
                        0 => try self.handler.vt(.erase_chars, switch (input.params.len) {
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
                    0 => try self.handler.vt(.horizontal_tab_back, switch (input.params.len) {
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
                    0 => try self.handler.vt(.cursor_col_relative, .{
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
                    0 => try self.handler.vt(.print_repeat, switch (input.params.len) {
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
                    const req: ?ansi.DeviceAttributeReq = switch (input.intermediates.len) {
                        0 => .primary,
                        1 => switch (input.intermediates[0]) {
                            '>' => .secondary,
                            '=' => .tertiary,
                            else => null,
                        },
                        else => null,
                    };

                    if (req) |r| {
                        try self.handler.vt(.device_attributes, r);
                    } else {
                        log.warn("invalid device attributes command: {f}", .{input});
                        return;
                    }
                },

                // VPA - Cursor Vertical Position Absolute
                'd' => switch (input.intermediates.len) {
                    0 => try self.handler.vt(.cursor_row, .{
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
                    0 => try self.handler.vt(.cursor_row_relative, .{
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
                            1 => @enumFromInt(input.params[0]),
                            else => {
                                log.warn("invalid tab clear command: {f}", .{input});
                                return;
                            },
                        };
                        switch (mode) {
                            .current => try self.handler.vt(.tab_clear_current, {}),
                            .all => try self.handler.vt(.tab_clear_all, {}),
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
                            try self.handler.vt(.set_mode, .{ .mode = mode });
                        } else {
                            log.warn("unimplemented mode: {}", .{mode_int});
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
                            try self.handler.vt(.reset_mode, .{ .mode = mode });
                        } else {
                            log.warn("unimplemented mode: {}", .{mode_int});
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
                            var p: sgr.Parser = .{
                                .params = input.params,
                                .params_sep = input.params_sep,
                            };
                            while (p.next()) |attr| {
                                // log.info("SGR attribute: {}", .{attr});
                                try self.handler.vt(.set_attribute, attr);
                            }
                        },

                        1 => switch (input.intermediates[0]) {
                            '>' => blk: {
                                if (input.params.len == 0) {
                                    // Reset
                                    try self.handler.vt(.modify_key_format, .legacy);
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

                                try self.handler.vt(.modify_key_format, format);
                            },

                            else => log.warn(
                                "unknown CSI m with intermediate: {}",
                                .{input.intermediates[0]},
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
                        if (input.params.len != 1) {
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

                        try self.handler.vt(.device_status, .{ .request = req });
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
                                try self.handler.vt(.modify_key_format, .other_keys_numeric_except);
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

                // DECRQM - Request Mode
                'p' => switch (input.intermediates.len) {
                    2 => decrqm: {
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
                            try self.handler.vt(.request_mode, .{ .mode = m });
                        } else {
                            try self.handler.vt(.request_mode_unknown, .{
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
                            try self.handler.vt(.cursor_style, style);
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
                                .off => try self.handler.vt(.protected_mode_off, {}),
                                .iso => try self.handler.vt(.protected_mode_iso, {}),
                                .dec => try self.handler.vt(.protected_mode_dec, {}),
                            }
                        },

                        // XTVERSION
                        '>' => try self.handler.vt(.xtversion, {}),
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
                            0 => try self.handler.vt(.top_and_bottom_margin, .{ .top_left = 0, .bottom_right = 0 }),
                            1 => try self.handler.vt(.top_and_bottom_margin, .{ .top_left = input.params[0], .bottom_right = 0 }),
                            2 => try self.handler.vt(.top_and_bottom_margin, .{ .top_left = input.params[0], .bottom_right = input.params[1] }),
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
                                        try self.handler.vt(.restore_mode, .{ .mode = mode });
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
                        0 => try self.handler.vt(.left_and_right_margin_ambiguous, {}),
                        1 => try self.handler.vt(.left_and_right_margin, .{ .top_left = input.params[0], .bottom_right = 0 }),
                        2 => try self.handler.vt(.left_and_right_margin, .{ .top_left = input.params[0], .bottom_right = input.params[1] }),
                        else => log.warn("invalid DECSLRM command: {f}", .{input}),
                    },

                    1 => switch (input.intermediates[0]) {
                        '?' => {
                            for (input.params) |mode_int| {
                                if (modes.modeFromInt(mode_int, false)) |mode| {
                                    try self.handler.vt(.save_mode, .{ .mode = mode });
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

                            try self.handler.vt(.mouse_shift_capture, capture);
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
                                14 => if (input.params.len == 1) {
                                    // report the text area size in pixels
                                    try self.handler.vt(.size_report, .csi_14_t);
                                } else log.warn(
                                    "ignoring CSI 14 t with extra parameters: {f}",
                                    .{input},
                                ),
                                16 => if (input.params.len == 1) {
                                    // report cell size in pixels
                                    try self.handler.vt(.size_report, .csi_16_t);
                                } else log.warn(
                                    "ignoring CSI 16 t with extra parameters: {f}",
                                    .{input},
                                ),
                                18 => if (input.params.len == 1) {
                                    // report screen size in characters
                                    try self.handler.vt(.size_report, .csi_18_t);
                                } else log.warn(
                                    "ignoring CSI 18 t with extra parameters: {f}",
                                    .{input},
                                ),
                                21 => if (input.params.len == 1) {
                                    // report window title
                                    try self.handler.vt(.size_report, .csi_21_t);
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
                                        22 => try self.handler.vt(.title_push, index),
                                        23 => try self.handler.vt(.title_pop, index),
                                        else => @compileError("unreachable"),
                                    }
                                } else log.warn(
                                    "ignoring CSI 22/23 t with extra parameters: {f}",
                                    .{input},
                                ),
                                else => log.warn(
                                    "ignoring CSI t with unimplemented parameter: {f}",
                                    .{input},
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
                    0 => try self.handler.vt(.restore_cursor, {}),

                    // Kitty keyboard protocol
                    1 => switch (input.intermediates[0]) {
                        '?' => try self.handler.vt(.kitty_keyboard_query, {}),

                        '>' => push: {
                            const flags: u5 = if (input.params.len == 1)
                                std.math.cast(u5, input.params[0]) orelse {
                                    log.warn("invalid pushKittyKeyboard command: {f}", .{input});
                                    break :push;
                                }
                            else
                                0;

                            try self.handler.vt(.kitty_keyboard_push, .{ .flags = @as(kitty.KeyFlags, @bitCast(flags)) });
                        },

                        '<' => {
                            const number: u16 = if (input.params.len == 1)
                                input.params[0]
                            else
                                1;

                            try self.handler.vt(.kitty_keyboard_pop, number);
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
                                .kitty_keyboard_set => try self.handler.vt(.kitty_keyboard_set, kitty_flags),
                                .kitty_keyboard_set_or => try self.handler.vt(.kitty_keyboard_set_or, kitty_flags),
                                .kitty_keyboard_set_not => try self.handler.vt(.kitty_keyboard_set_not, kitty_flags),
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
                    0 => try self.handler.vt(.insert_blanks, switch (input.params.len) {
                        0 => 1,
                        1 => input.params[0],
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

                // DECSASD - Select Active Status Display
                '}' => decsasd: {
                    // Verify we're getting a DECSASD command
                    if (input.intermediates.len != 1 or input.intermediates[0] != '$') {
                        log.warn("unimplemented CSI callback: {f}", .{input});
                        break :decsasd;
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

                    try self.handler.vt(.active_status_display, display);
                },

                else => log.warn("unimplemented CSI action: {f}", .{input}),
            }
        }

        inline fn oscDispatch(self: *Self, cmd: osc.Command) !void {
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
                    try self.handler.vt(.semantic_prompt, sp);
                },

                .change_window_title => |title| {
                    @branchHint(.likely);
                    if (!std.unicode.utf8ValidateSlice(title)) {
                        @branchHint(.unlikely);
                        log.warn("change title request: invalid utf-8, ignoring request", .{});
                        return;
                    }

                    try self.handler.vt(.window_title, .{ .title = title });
                },

                .change_window_icon => |icon| {
                    @branchHint(.likely);
                    log.info("OSC 1 (change icon) received and ignored icon={s}", .{icon});
                },

                .clipboard_contents => |clip| {
                    try self.handler.vt(.clipboard_contents, .{
                        .kind = clip.kind,
                        .data = clip.data,
                    });
                },

                .report_pwd => |v| {
                    @branchHint(.likely);
                    try self.handler.vt(.report_pwd, .{ .url = v.value });
                },

                .mouse_shape => |v| {
                    const shape = MouseShape.fromString(v.value) orelse {
                        @branchHint(.unlikely);
                        log.warn("unknown cursor shape: {s}", .{v.value});
                        return;
                    };

                    try self.handler.vt(.mouse_shape, shape);
                },

                .color_operation => |v| {
                    @branchHint(.likely);
                    try self.handler.vt(.color_operation, .{
                        .op = v.op,
                        .requests = v.requests,
                        .terminator = v.terminator,
                    });
                },

                .kitty_color_protocol => |v| {
                    try self.handler.vt(.kitty_color_report, v);
                },

                .show_desktop_notification => |v| {
                    try self.handler.vt(.show_desktop_notification, .{
                        .title = v.title,
                        .body = v.body,
                    });
                },

                .hyperlink_start => |v| {
                    @branchHint(.likely);
                    try self.handler.vt(.start_hyperlink, .{
                        .uri = v.uri,
                        .id = v.id,
                    });
                },

                .hyperlink_end => {
                    @branchHint(.likely);
                    try self.handler.vt(.end_hyperlink, {});
                },

                .conemu_progress_report => |v| {
                    try self.handler.vt(.progress_report, v);
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
                .kitty_clipboard_protocol,
                .kitty_desktop_notification,
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
        ) !void {
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

            try self.handler.vt(.configure_charset, .{
                .slot = slot,
                .charset = set,
            });
        }

        inline fn escDispatch(
            self: *Self,
            action: Parser.Action.ESC,
        ) !void {
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
                    try self.configureCharset(action.intermediates, .ascii);
                },
                'A' => try self.configureCharset(action.intermediates, .british),
                '0' => {
                    @branchHint(.likely);
                    try self.configureCharset(action.intermediates, .dec_special);
                },

                // DECSC - Save Cursor
                '7' => {
                    @branchHint(.likely);
                    switch (action.intermediates.len) {
                        0 => try self.handler.vt(.save_cursor, {}),
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
                            try self.handler.vt(.restore_cursor, {});
                            break :blk {};
                        },

                        1 => switch (action.intermediates[0]) {
                            // DECALN - Fill Screen with E
                            '#' => {
                                try self.handler.vt(.decaln, {});
                                break :blk {};
                            },

                            else => {},
                        },

                        else => {}, // fall through
                    }

                    log.warn("unimplemented ESC action: {f}", .{action});
                },

                // IND - Index
                'D' => switch (action.intermediates.len) {
                    0 => try self.handler.vt(.index, {}),
                    else => {
                        @branchHint(.unlikely);
                        log.warn("invalid index command: {f}", .{action});
                        return;
                    },
                },

                // NEL - Next Line
                'E' => switch (action.intermediates.len) {
                    0 => try self.handler.vt(.next_line, {}),
                    else => {
                        @branchHint(.unlikely);
                        log.warn("invalid next line command: {f}", .{action});
                        return;
                    },
                },

                // HTS - Horizontal Tab Set
                'H' => switch (action.intermediates.len) {
                    0 => try self.handler.vt(.tab_set, {}),
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
                        0 => try self.handler.vt(.reverse_index, {}),
                        else => {
                            @branchHint(.unlikely);
                            log.warn("invalid reverse index command: {f}", .{action});
                            return;
                        },
                    }
                },

                // SS2 - Single Shift 2
                'N' => switch (action.intermediates.len) {
                    0 => try self.handler.vt(.invoke_charset, .{
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
                    0 => try self.handler.vt(.invoke_charset, .{
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
                    0 => try self.handler.vt(.protected_mode_iso, {}),
                    else => log.warn("unimplemented ESC callback: {f}", .{action}),
                },

                // EPA - End of Guarded Area
                'W' => switch (action.intermediates.len) {
                    0 => try self.handler.vt(.protected_mode_off, {}),
                    else => log.warn("unimplemented ESC callback: {f}", .{action}),
                },

                // DECID
                'Z' => if (action.intermediates.len == 0) {
                    try self.handler.vt(.device_attributes, .primary);
                } else log.warn("unimplemented ESC callback: {f}", .{action}),

                // RIS - Full Reset
                'c' => switch (action.intermediates.len) {
                    0 => try self.handler.vt(.full_reset, {}),
                    else => {
                        log.warn("invalid full reset command: {f}", .{action});
                        return;
                    },
                },

                // LS2 - Locking Shift 2
                'n' => switch (action.intermediates.len) {
                    0 => try self.handler.vt(.invoke_charset, .{
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
                    0 => try self.handler.vt(.invoke_charset, .{
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
                    0 => try self.handler.vt(.invoke_charset, .{
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
                    0 => try self.handler.vt(.invoke_charset, .{
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
                    0 => try self.handler.vt(.invoke_charset, .{
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
                        0 => try self.handler.vt(.set_mode, .{ .mode = .keypad_keys }),
                        else => log.warn("unimplemented setMode: {f}", .{action}),
                    }
                },

                // Reset application keypad mode
                '>' => {
                    @branchHint(.likely);
                    switch (action.intermediates.len) {
                        0 => try self.handler.vt(.reset_mode, .{ .mode = .keypad_keys }),
                        else => log.warn("unimplemented setMode: {f}", .{action}),
                    }
                },

                // Sets ST (string terminator). We don't have to do anything
                // because our parser always accepts ST.
                '\\' => {
                    @branchHint(.likely);
                },

                else => log.warn("unimplemented ESC action: {f}", .{action}),
            }
        }
    };
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
        ) !void {
            switch (action) {
                .print => self.c = value.cp,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{});
    try s.next('x');
    try testing.expectEqual(@as(u21, 'x'), s.handler.c.?);
}

test "simd: print invalid utf-8" {
    const H = struct {
        c: ?u21 = 0,

        pub fn vt(
            self: *@This(),
            comptime action: Action.Tag,
            value: Action.Value(action),
        ) !void {
            switch (action) {
                .print => self.c = value.cp,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{});
    try s.nextSlice(&.{0xFF});
    try testing.expectEqual(@as(u21, 0xFFFD), s.handler.c.?);
}

test "simd: complete incomplete utf-8" {
    const H = struct {
        c: ?u21 = null,

        pub fn vt(
            self: *@This(),
            comptime action: Action.Tag,
            value: Action.Value(action),
        ) !void {
            switch (action) {
                .print => self.c = value.cp,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{});
    try s.nextSlice(&.{0xE0}); // 3 byte
    try testing.expect(s.handler.c == null);
    try s.nextSlice(&.{0xA0}); // still incomplete
    try testing.expect(s.handler.c == null);
    try s.nextSlice(&.{0x80});
    try testing.expectEqual(@as(u21, 0x800), s.handler.c.?);
}

test "stream: cursor right (CUF)" {
    const H = struct {
        amount: u16 = 0,

        pub fn vt(
            self: *@This(),
            comptime action: Action.Tag,
            value: Action.Value(action),
        ) !void {
            switch (action) {
                .cursor_right => self.amount = value.value,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{});
    try s.nextSlice("\x1B[C");
    try testing.expectEqual(@as(u16, 1), s.handler.amount);

    try s.nextSlice("\x1B[5C");
    try testing.expectEqual(@as(u16, 5), s.handler.amount);

    s.handler.amount = 0;
    try s.nextSlice("\x1B[5;4C");
    try testing.expectEqual(@as(u16, 0), s.handler.amount);

    s.handler.amount = 0;
    try s.nextSlice("\x1b[?3C");
    try testing.expectEqual(@as(u16, 0), s.handler.amount);
}

test "stream: dec set mode (SM) and reset mode (RM)" {
    const H = struct {
        mode: modes.Mode = @as(modes.Mode, @enumFromInt(1)),

        pub fn vt(
            self: *@This(),
            comptime action: Action.Tag,
            value: Action.Value(action),
        ) !void {
            switch (action) {
                .set_mode => self.mode = value.mode,
                .reset_mode => self.mode = @as(modes.Mode, @enumFromInt(1)),
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{});
    try s.nextSlice("\x1B[?6h");
    try testing.expectEqual(@as(modes.Mode, .origin), s.handler.mode);

    try s.nextSlice("\x1B[?6l");
    try testing.expectEqual(@as(modes.Mode, @enumFromInt(1)), s.handler.mode);

    s.handler.mode = @as(modes.Mode, @enumFromInt(1));
    try s.nextSlice("\x1B[6 h");
    try testing.expectEqual(@as(modes.Mode, @enumFromInt(1)), s.handler.mode);
}

test "stream: ansi set mode (SM) and reset mode (RM)" {
    const H = struct {
        mode: ?modes.Mode = null,

        pub fn vt(
            self: *@This(),
            comptime action: Action.Tag,
            value: Action.Value(action),
        ) !void {
            switch (action) {
                .set_mode => self.mode = value.mode,
                .reset_mode => self.mode = null,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{});
    try s.nextSlice("\x1B[4h");
    try testing.expectEqual(@as(modes.Mode, .insert), s.handler.mode.?);

    try s.nextSlice("\x1B[4l");
    try testing.expect(s.handler.mode == null);

    s.handler.mode = null;
    try s.nextSlice("\x1B[>5h");
    try testing.expect(s.handler.mode == null);
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
        ) !void {
            _ = self;
            _ = value;
        }
    };

    var s: Stream(H) = .init(.{});
    try s.nextSlice("\x1B[6h");
    try testing.expect(s.handler.mode == null);

    try s.nextSlice("\x1B[6l");
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
        ) !void {
            _ = value;
            switch (action) {
                .top_and_bottom_margin => self.called = true,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{});
    for ("\x1B[?42r") |c| try s.next(c);
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
        ) !void {
            switch (action) {
                .kitty_keyboard_pop => self.n = value,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{});
    for ("\x1B[<u") |c| try s.next(c);
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
        ) !void {
            _ = value;
            switch (action) {
                .protected_mode_off => self.v = .off,
                .protected_mode_iso => self.v = .iso,
                .protected_mode_dec => self.v = .dec,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{});
    {
        for ("\x1B[\"q") |c| try s.next(c);
        try testing.expectEqual(ansi.ProtectedMode.off, s.handler.v.?);
    }
    {
        for ("\x1B[0\"q") |c| try s.next(c);
        try testing.expectEqual(ansi.ProtectedMode.off, s.handler.v.?);
    }
    {
        for ("\x1B[2\"q") |c| try s.next(c);
        try testing.expectEqual(ansi.ProtectedMode.off, s.handler.v.?);
    }
    {
        for ("\x1B[1\"q") |c| try s.next(c);
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
        ) !void {
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

    var s: Stream(H) = .init(.{});
    {
        for ("\x1B[?J") |c| try s.next(c);
        try testing.expectEqual(csi.EraseDisplay.below, s.handler.mode.?);
        try testing.expect(s.handler.protected.?);
    }
    {
        for ("\x1B[?0J") |c| try s.next(c);
        try testing.expectEqual(csi.EraseDisplay.below, s.handler.mode.?);
        try testing.expect(s.handler.protected.?);
    }
    {
        for ("\x1B[?1J") |c| try s.next(c);
        try testing.expectEqual(csi.EraseDisplay.above, s.handler.mode.?);
        try testing.expect(s.handler.protected.?);
    }
    {
        for ("\x1B[?2J") |c| try s.next(c);
        try testing.expectEqual(csi.EraseDisplay.complete, s.handler.mode.?);
        try testing.expect(s.handler.protected.?);
    }
    {
        for ("\x1B[?3J") |c| try s.next(c);
        try testing.expectEqual(csi.EraseDisplay.scrollback, s.handler.mode.?);
        try testing.expect(s.handler.protected.?);
    }

    {
        for ("\x1B[J") |c| try s.next(c);
        try testing.expectEqual(csi.EraseDisplay.below, s.handler.mode.?);
        try testing.expect(!s.handler.protected.?);
    }
    {
        for ("\x1B[0J") |c| try s.next(c);
        try testing.expectEqual(csi.EraseDisplay.below, s.handler.mode.?);
        try testing.expect(!s.handler.protected.?);
    }
    {
        for ("\x1B[1J") |c| try s.next(c);
        try testing.expectEqual(csi.EraseDisplay.above, s.handler.mode.?);
        try testing.expect(!s.handler.protected.?);
    }
    {
        for ("\x1B[2J") |c| try s.next(c);
        try testing.expectEqual(csi.EraseDisplay.complete, s.handler.mode.?);
        try testing.expect(!s.handler.protected.?);
    }
    {
        for ("\x1B[3J") |c| try s.next(c);
        try testing.expectEqual(csi.EraseDisplay.scrollback, s.handler.mode.?);
        try testing.expect(!s.handler.protected.?);
    }
    {
        // Invalid and ignored by the handler
        for ("\x1B[>0J") |c| try s.next(c);
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
        ) !void {
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

    var s: Stream(H) = .init(.{});
    {
        for ("\x1B[?K") |c| try s.next(c);
        try testing.expectEqual(csi.EraseLine.right, s.handler.mode.?);
        try testing.expect(s.handler.protected.?);
    }
    {
        for ("\x1B[?0K") |c| try s.next(c);
        try testing.expectEqual(csi.EraseLine.right, s.handler.mode.?);
        try testing.expect(s.handler.protected.?);
    }
    {
        for ("\x1B[?1K") |c| try s.next(c);
        try testing.expectEqual(csi.EraseLine.left, s.handler.mode.?);
        try testing.expect(s.handler.protected.?);
    }
    {
        for ("\x1B[?2K") |c| try s.next(c);
        try testing.expectEqual(csi.EraseLine.complete, s.handler.mode.?);
        try testing.expect(s.handler.protected.?);
    }

    {
        for ("\x1B[K") |c| try s.next(c);
        try testing.expectEqual(csi.EraseLine.right, s.handler.mode.?);
        try testing.expect(!s.handler.protected.?);
    }
    {
        for ("\x1B[0K") |c| try s.next(c);
        try testing.expectEqual(csi.EraseLine.right, s.handler.mode.?);
        try testing.expect(!s.handler.protected.?);
    }
    {
        for ("\x1B[1K") |c| try s.next(c);
        try testing.expectEqual(csi.EraseLine.left, s.handler.mode.?);
        try testing.expect(!s.handler.protected.?);
    }
    {
        for ("\x1B[2K") |c| try s.next(c);
        try testing.expectEqual(csi.EraseLine.complete, s.handler.mode.?);
        try testing.expect(!s.handler.protected.?);
    }
    {
        // Invalid and ignored by the handler
        for ("\x1B[<1K") |c| try s.next(c);
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
        ) !void {
            switch (action) {
                .cursor_style => self.style = value,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{});
    try s.nextSlice("\x1B[ q");
    try testing.expect(s.handler.style.? == .default);

    try s.nextSlice("\x1B[1 q");
    try testing.expect(s.handler.style.? == .blinking_block);

    // Invalid and ignored by the handler
    try s.nextSlice("\x1B[?0 q");
    try testing.expect(s.handler.style.? == .blinking_block);
}

test "stream: DECSCUSR without space" {
    const H = struct {
        style: ?ansi.CursorStyle = null,

        pub fn vt(
            self: *@This(),
            comptime action: Stream(@This()).Action.Tag,
            value: Stream(@This()).Action.Value(action),
        ) !void {
            switch (action) {
                .cursor_style => self.style = value,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{});
    try s.nextSlice("\x1B[q");
    try testing.expect(s.handler.style == null);

    try s.nextSlice("\x1B[1q");
    try testing.expect(s.handler.style == null);
}

test "stream: XTSHIFTESCAPE" {
    const H = struct {
        escape: ?bool = null,

        pub fn vt(
            self: *@This(),
            comptime action: streampkg.Action.Tag,
            value: streampkg.Action.Value(action),
        ) !void {
            switch (action) {
                .mouse_shift_capture => self.escape = value,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{});
    try s.nextSlice("\x1B[>2s");
    try testing.expect(s.handler.escape == null);

    try s.nextSlice("\x1B[>s");
    try testing.expect(s.handler.escape.? == false);

    try s.nextSlice("\x1B[>0s");
    try testing.expect(s.handler.escape.? == false);

    try s.nextSlice("\x1B[>1s");
    try testing.expect(s.handler.escape.? == true);

    // Invalid and ignored by the handler
    try s.nextSlice("\x1B[1 s");
    try testing.expect(s.handler.escape.? == true);
}

test "stream: change window title with invalid utf-8" {
    const H = struct {
        seen: bool = false,

        pub fn vt(
            self: *@This(),
            comptime action: anytype,
            value: anytype,
        ) !void {
            _ = value;
            switch (action) {
                .window_title => self.seen = true,
                else => {},
            }
        }
    };

    {
        var s: Stream(H) = .init(.{});
        try s.nextSlice("\x1b]2;abc\x1b\\");
        try testing.expect(s.handler.seen);
    }

    {
        var s: Stream(H) = .init(.{});
        try s.nextSlice("\x1b]2;abc\xc0\x1b\\");
        try testing.expect(!s.handler.seen);
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
        ) !void {
            _ = value;
            switch (action) {
                .insert_blanks => self.called = true,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{});
    for ("\x1B[42@") |c| try s.next(c);
    try testing.expect(s.handler.called);

    s.handler.called = false;
    for ("\x1B[?42@") |c| try s.next(c);
    try testing.expect(!s.handler.called);
}

test "stream: SCOSC" {
    const H = struct {
        const Self = @This();
        called: bool = false,

        pub fn vt(
            self: *Self,
            comptime action: Stream(Self).Action.Tag,
            value: Stream(Self).Action.Value(action),
        ) !void {
            _ = value;
            switch (action) {
                .left_and_right_margin => @panic("bad"),
                .left_and_right_margin_ambiguous => self.called = true,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{});
    for ("\x1B[s") |c| try s.next(c);
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
        ) !void {
            _ = value;
            switch (action) {
                .restore_cursor => self.called = true,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{});
    for ("\x1B[u") |c| try s.next(c);
    try testing.expect(s.handler.called);
}

test "stream: too many csi params" {
    const H = struct {
        pub fn vt(
            self: *@This(),
            comptime action: anytype,
            value: anytype,
        ) !void {
            _ = self;
            _ = value;
            switch (action) {
                .cursor_right => unreachable,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{});
    try s.nextSlice("\x1B[1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1C");
}

test "stream: csi param too long" {
    const H = struct {
        pub fn vt(
            self: *@This(),
            comptime action: anytype,
            value: anytype,
        ) !void {
            _ = self;
            _ = action;
            _ = value;
        }
    };

    var s: Stream(H) = .init(.{});
    try s.nextSlice("\x1B[1111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111C");
}

test "stream: send report with CSI t" {
    const H = struct {
        style: ?csi.SizeReportStyle = null,

        pub fn vt(
            self: *@This(),
            comptime action: streampkg.Action.Tag,
            value: streampkg.Action.Value(action),
        ) !void {
            switch (action) {
                .size_report => self.style = value,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{});

    try s.nextSlice("\x1b[14t");
    try testing.expectEqual(csi.SizeReportStyle.csi_14_t, s.handler.style);

    try s.nextSlice("\x1b[16t");
    try testing.expectEqual(csi.SizeReportStyle.csi_16_t, s.handler.style);

    try s.nextSlice("\x1b[18t");
    try testing.expectEqual(csi.SizeReportStyle.csi_18_t, s.handler.style);

    try s.nextSlice("\x1b[21t");
    try testing.expectEqual(csi.SizeReportStyle.csi_21_t, s.handler.style);
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
        ) !void {
            _ = self;
            _ = action;
            _ = value;
        }
    };

    var s: Stream(H) = .init(.{});

    try s.nextSlice("\x1b[19t");
    try testing.expectEqual(null, s.handler.style);
}

test "stream: CSI t push title" {
    const H = struct {
        index: ?u16 = null,

        pub fn vt(
            self: *@This(),
            comptime action: streampkg.Action.Tag,
            value: streampkg.Action.Value(action),
        ) !void {
            switch (action) {
                .title_push => self.index = value,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{});

    try s.nextSlice("\x1b[22;0t");
    try testing.expectEqual(@as(u16, 0), s.handler.index.?);
}

test "stream: CSI t push title with explicit window" {
    const H = struct {
        index: ?u16 = null,

        pub fn vt(
            self: *@This(),
            comptime action: streampkg.Action.Tag,
            value: streampkg.Action.Value(action),
        ) !void {
            switch (action) {
                .title_push => self.index = value,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{});

    try s.nextSlice("\x1b[22;2t");
    try testing.expectEqual(@as(u16, 0), s.handler.index.?);
}

test "stream: CSI t push title with explicit icon" {
    const H = struct {
        index: ?u16 = null,

        pub fn vt(
            self: *@This(),
            comptime action: streampkg.Action.Tag,
            value: streampkg.Action.Value(action),
        ) !void {
            switch (action) {
                .title_push => self.index = value,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{});

    try s.nextSlice("\x1b[22;1t");
    try testing.expectEqual(null, s.handler.index);
}

test "stream: CSI t push title with index" {
    const H = struct {
        index: ?u16 = null,

        pub fn vt(
            self: *@This(),
            comptime action: streampkg.Action.Tag,
            value: streampkg.Action.Value(action),
        ) !void {
            switch (action) {
                .title_push => self.index = value,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{});

    try s.nextSlice("\x1b[22;0;5t");
    try testing.expectEqual(@as(u16, 5), s.handler.index.?);
}

test "stream: CSI t pop title" {
    const H = struct {
        index: ?u16 = null,

        pub fn vt(
            self: *@This(),
            comptime action: streampkg.Action.Tag,
            value: streampkg.Action.Value(action),
        ) !void {
            switch (action) {
                .title_pop => self.index = value,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{});

    try s.nextSlice("\x1b[23;0t");
    try testing.expectEqual(@as(u16, 0), s.handler.index.?);
}

test "stream: CSI t pop title with explicit window" {
    const H = struct {
        index: ?u16 = null,

        pub fn vt(
            self: *@This(),
            comptime action: streampkg.Action.Tag,
            value: streampkg.Action.Value(action),
        ) !void {
            switch (action) {
                .title_pop => self.index = value,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{});

    try s.nextSlice("\x1b[23;2t");
    try testing.expectEqual(@as(u16, 0), s.handler.index.?);
}

test "stream: CSI t pop title with explicit icon" {
    const H = struct {
        index: ?u16 = null,

        pub fn vt(
            self: *@This(),
            comptime action: streampkg.Action.Tag,
            value: streampkg.Action.Value(action),
        ) !void {
            switch (action) {
                .title_pop => self.index = value,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{});

    try s.nextSlice("\x1b[23;1t");
    try testing.expectEqual(null, s.handler.index);
}

test "stream: CSI t pop title with index" {
    const H = struct {
        index: ?u16 = null,

        pub fn vt(
            self: *@This(),
            comptime action: streampkg.Action.Tag,
            value: streampkg.Action.Value(action),
        ) !void {
            switch (action) {
                .title_pop => self.index = value,
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{});

    try s.nextSlice("\x1b[23;0;5t");
    try testing.expectEqual(@as(u16, 5), s.handler.index.?);
}

test "stream CSI W clear tab stops" {
    const H = struct {
        action: ?Action.Key = null,

        pub fn vt(
            self: *@This(),
            comptime action: anytype,
            value: anytype,
        ) !void {
            _ = value;
            self.action = action;
        }
    };

    var s: Stream(H) = .init(.{});

    try s.nextSlice("\x1b[2W");
    try testing.expectEqual(Action.Key.tab_clear_current, s.handler.action.?);

    try s.nextSlice("\x1b[5W");
    try testing.expectEqual(Action.Key.tab_clear_all, s.handler.action.?);
}

test "stream CSI W tab set" {
    const H = struct {
        action: ?Action.Key = null,

        pub fn vt(
            self: *@This(),
            comptime action: anytype,
            value: anytype,
        ) !void {
            _ = value;
            self.action = action;
        }
    };

    var s: Stream(H) = .init(.{});

    try s.nextSlice("\x1b[W");
    try testing.expectEqual(Action.Key.tab_set, s.handler.action.?);

    s.handler.action = null;
    try s.nextSlice("\x1b[0W");
    try testing.expectEqual(Action.Key.tab_set, s.handler.action.?);

    s.handler.action = null;
    try s.nextSlice("\x1b[>W");
    try testing.expect(s.handler.action == null);

    s.handler.action = null;
    try s.nextSlice("\x1b[99W");
    try testing.expect(s.handler.action == null);
}

test "stream CSI ? W reset tab stops" {
    const H = struct {
        action: ?Action.Key = null,

        pub fn vt(
            self: *@This(),
            comptime action: anytype,
            value: anytype,
        ) !void {
            _ = value;
            self.action = action;
        }
    };

    var s: Stream(H) = .init(.{});

    try s.nextSlice("\x1b[?2W");
    try testing.expect(s.handler.action == null);

    try s.nextSlice("\x1b[?5W");
    try testing.expectEqual(Action.Key.tab_reset, s.handler.action.?);

    // Invalid and ignored by the handler
    s.handler.action = null;
    try s.nextSlice("\x1b[?1;2;3W");
    try testing.expect(s.handler.action == null);
}

test "stream: SGR with 17+ parameters for underline color" {
    const H = struct {
        attrs: ?sgr.Attribute = null,
        called: bool = false,

        pub fn vt(
            self: *@This(),
            comptime action: anytype,
            value: anytype,
        ) !void {
            switch (action) {
                .set_attribute => {
                    self.attrs = value;
                    self.called = true;
                },
                else => {},
            }
        }
    };

    var s: Stream(H) = .init(.{});

    // Kakoune-style SGR with underline color as 17th parameter
    // This tests the fix where param 17 was being dropped
    try s.nextSlice("\x1b[4:3;38;2;51;51;51;48;2;170;170;170;58;2;255;97;136;0m");
    try testing.expect(s.handler.called);
}
