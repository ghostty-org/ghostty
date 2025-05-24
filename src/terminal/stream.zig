const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const simd = @import("../simd/main.zig");
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

/// Returns a type that can process a stream of tty control characters.
/// This will call various callback functions on type T. Type T only has to
/// implement the callbacks it cares about; any unimplemented callbacks will
/// logged at runtime.
///
/// To figure out what callbacks exist, search the source for "hasDecl". This
/// isn't ideal but for now that's the best approach.
///
/// This is implemented this way because we purposely do NOT want dynamic
/// dispatch for performance reasons. The way this is implemented forces
/// comptime resolution for all function calls.
pub fn Stream(comptime Handler: type) type {
    return struct {
        const Self = @This();

        // We use T with @hasDecl so it needs to be a struct. Unwrap the
        // pointer if we were given one.
        const T = switch (@typeInfo(Handler)) {
            .pointer => |p| p.child,
            else => Handler,
        };

        handler: Handler,
        parser: Parser = .{},
        utf8decoder: UTF8Decoder = .{},

        pub fn deinit(self: *Self) void {
            self.parser.deinit();
        }

        /// Process a string of characters.
        pub fn nextSlice(self: *Self, input: []const u8) !void {
            // Debug mode disables the SIMD optimizations
            if (comptime debug) {
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

        fn nextSliceCapped(self: *Self, input: []const u8, cp_buf: []u32) !void {
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
        fn consumeAllEscapes(self: *Self, input: []const u8) !usize {
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
        fn consumeUntilGround(self: *Self, input: []const u8) !usize {
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
        pub fn next(self: *Self, c: u8) !void {
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
        fn nextUtf8(self: *Self, c: u8) !void {
            assert(self.parser.state == .ground);

            const res = self.utf8decoder.next(c);
            const consumed = res[1];
            if (res[0]) |codepoint| {
                try self.handleCodepoint(codepoint);
            }
            if (!consumed) {
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
            if (c <= 0xF) {
                try self.execute(@intCast(c));
                return;
            }
            if (c == 0x1B) {
                try self.nextNonUtf8(@intCast(c));
                return;
            }
            try self.print(@intCast(c));
        }

        /// Process the next character and call any callbacks if necessary.
        ///
        /// This assumes that we're not in the UTF-8 decoding state. If
        /// we may be in the UTF-8 decoding state call nextSlice or next.
        fn nextNonUtf8(self: *Self, c: u8) !void {
            assert(self.parser.state != .ground or c == 0x1B);

            // Fast path for ESC
            if (self.parser.state == .ground and c == 0x1B) {
                self.parser.state = .escape;
                self.parser.clear();
                return;
            }
            // Fast path for CSI entry.
            if (self.parser.state == .escape and c == '[') {
                self.parser.state = .csi_entry;
                return;
            }
            // Fast path for CSI params.
            if (self.parser.state == .csi_param) csi_param: {
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
                    '0'...'9' => if (self.parser.params_idx < 16) {
                        self.parser.param_acc *|= 10;
                        self.parser.param_acc +|= c - '0';
                        // The parser's CSI param action uses param_acc_idx
                        // to decide if there's a final param that needs to
                        // be consumed or not, but it doesn't matter really
                        // what it is as long as it's not 0.
                        self.parser.param_acc_idx |= 1;
                    },
                    // A parameter separator:
                    ':', ';' => if (self.parser.params_idx < 16) {
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

            const actions = self.parser.next(c);
            for (actions) |action_opt| {
                const action = action_opt orelse continue;
                if (comptime debug) log.info("action: {}", .{action});

                // If this handler handles everything manually then we do nothing
                // if it can be processed.
                if (@hasDecl(T, "handleManually")) {
                    const processed = self.handler.handleManually(action) catch |err| err: {
                        log.warn("error handling action manually err={} action={}", .{
                            err,
                            action,
                        });

                        break :err false;
                    };

                    if (processed) continue;
                }

                switch (action) {
                    .print => |p| if (@hasDecl(T, "print")) try self.handler.print(p),
                    .execute => |code| try self.execute(code),
                    .csi_dispatch => |csi_action| try self.csiDispatch(csi_action),
                    .esc_dispatch => |esc| try self.escDispatch(esc),
                    .osc_dispatch => |cmd| try self.oscDispatch(cmd),
                    .dcs_hook => |dcs| if (@hasDecl(T, "dcsHook")) {
                        try self.handler.dcsHook(dcs);
                    } else log.warn("unimplemented DCS hook", .{}),
                    .dcs_put => |code| if (@hasDecl(T, "dcsPut")) {
                        try self.handler.dcsPut(code);
                    } else log.warn("unimplemented DCS put: {x}", .{code}),
                    .dcs_unhook => if (@hasDecl(T, "dcsUnhook")) {
                        try self.handler.dcsUnhook();
                    } else log.warn("unimplemented DCS unhook", .{}),
                    .apc_start => if (@hasDecl(T, "apcStart")) {
                        try self.handler.apcStart();
                    } else log.warn("unimplemented APC start", .{}),
                    .apc_put => |code| if (@hasDecl(T, "apcPut")) {
                        try self.handler.apcPut(code);
                    } else log.warn("unimplemented APC put: {x}", .{code}),
                    .apc_end => if (@hasDecl(T, "apcEnd")) {
                        try self.handler.apcEnd();
                    } else log.warn("unimplemented APC end", .{}),
                }
            }
        }

        pub fn print(self: *Self, c: u21) !void {
            if (@hasDecl(T, "print")) {
                try self.handler.print(c);
            }
        }

        pub fn execute(self: *Self, c: u8) !void {
            const c0: ansi.C0 = @enumFromInt(c);
            if (comptime debug) log.info("execute: {}", .{c0});
            switch (c0) {
                // We ignore SOH/STX: https://github.com/microsoft/terminal/issues/10786
                .NUL, .SOH, .STX => {},

                .ENQ => if (@hasDecl(T, "enquiry"))
                    try self.handler.enquiry()
                else
                    log.warn("unimplemented execute: {x}", .{c}),

                .BEL => if (@hasDecl(T, "bell"))
                    try self.handler.bell()
                else
                    log.warn("unimplemented execute: {x}", .{c}),

                .BS => if (@hasDecl(T, "backspace"))
                    try self.handler.backspace()
                else
                    log.warn("unimplemented execute: {x}", .{c}),

                .HT => if (@hasDecl(T, "horizontalTab"))
                    try self.handler.horizontalTab(1)
                else
                    log.warn("unimplemented execute: {x}", .{c}),

                .LF, .VT, .FF => if (@hasDecl(T, "linefeed"))
                    try self.handler.linefeed()
                else
                    log.warn("unimplemented execute: {x}", .{c}),

                .CR => if (@hasDecl(T, "carriageReturn"))
                    try self.handler.carriageReturn()
                else
                    log.warn("unimplemented execute: {x}", .{c}),

                .SO => if (@hasDecl(T, "invokeCharset"))
                    try self.handler.invokeCharset(.GL, .G1, false)
                else
                    log.warn("unimplemented invokeCharset: {x}", .{c}),

                .SI => if (@hasDecl(T, "invokeCharset"))
                    try self.handler.invokeCharset(.GL, .G0, false)
                else
                    log.warn("unimplemented invokeCharset: {x}", .{c}),

                else => log.warn("invalid C0 character, ignoring: 0x{x}", .{c}),
            }
        }

        fn csiDispatch(self: *Self, input: Parser.Action.CSI) !void {
            switch (input.final) {
                // CUU - Cursor Up
                'A', 'k' => switch (input.intermediates.len) {
                    0 => if (@hasDecl(T, "setCursorUp")) try self.handler.setCursorUp(
                        switch (input.params.len) {
                            0 => 1,
                            1 => input.params[0],
                            else => {
                                log.warn("invalid cursor up command: {}", .{input});
                                return;
                            },
                        },
                        false,
                    ) else log.warn("unimplemented CSI callback: {}", .{input}),

                    else => log.warn(
                        "ignoring unimplemented CSI A with intermediates: {s}",
                        .{input.intermediates},
                    ),
                },

                // CUD - Cursor Down
                'B' => switch (input.intermediates.len) {
                    0 => if (@hasDecl(T, "setCursorDown")) try self.handler.setCursorDown(
                        switch (input.params.len) {
                            0 => 1,
                            1 => input.params[0],
                            else => {
                                log.warn("invalid cursor down command: {}", .{input});
                                return;
                            },
                        },
                        false,
                    ) else log.warn("unimplemented CSI callback: {}", .{input}),

                    else => log.warn(
                        "ignoring unimplemented CSI B with intermediates: {s}",
                        .{input.intermediates},
                    ),
                },

                // CUF - Cursor Right
                'C' => switch (input.intermediates.len) {
                    0 => if (@hasDecl(T, "setCursorRight")) try self.handler.setCursorRight(
                        switch (input.params.len) {
                            0 => 1,
                            1 => input.params[0],
                            else => {
                                log.warn("invalid cursor right command: {}", .{input});
                                return;
                            },
                        },
                    ) else log.warn("unimplemented CSI callback: {}", .{input}),

                    else => log.warn(
                        "ignoring unimplemented CSI C with intermediates: {s}",
                        .{input.intermediates},
                    ),
                },

                // CUB - Cursor Left
                'D', 'j' => switch (input.intermediates.len) {
                    0 => if (@hasDecl(T, "setCursorLeft")) try self.handler.setCursorLeft(
                        switch (input.params.len) {
                            0 => 1,
                            1 => input.params[0],
                            else => {
                                log.warn("invalid cursor left command: {}", .{input});
                                return;
                            },
                        },
                    ) else log.warn("unimplemented CSI callback: {}", .{input}),

                    else => log.warn(
                        "ignoring unimplemented CSI D with intermediates: {s}",
                        .{input.intermediates},
                    ),
                },

                // CNL - Cursor Next Line
                'E' => switch (input.intermediates.len) {
                    0 => if (@hasDecl(T, "setCursorDown")) try self.handler.setCursorDown(
                        switch (input.params.len) {
                            0 => 1,
                            1 => input.params[0],
                            else => {
                                log.warn("invalid cursor up command: {}", .{input});
                                return;
                            },
                        },
                        true,
                    ) else log.warn("unimplemented CSI callback: {}", .{input}),

                    else => log.warn(
                        "ignoring unimplemented CSI E with intermediates: {s}",
                        .{input.intermediates},
                    ),
                },

                // CPL - Cursor Previous Line
                'F' => switch (input.intermediates.len) {
                    0 => if (@hasDecl(T, "setCursorUp")) try self.handler.setCursorUp(
                        switch (input.params.len) {
                            0 => 1,
                            1 => input.params[0],
                            else => {
                                log.warn("invalid cursor down command: {}", .{input});
                                return;
                            },
                        },
                        true,
                    ) else log.warn("unimplemented CSI callback: {}", .{input}),

                    else => log.warn(
                        "ignoring unimplemented CSI F with intermediates: {s}",
                        .{input.intermediates},
                    ),
                },

                // HPA - Cursor Horizontal Position Absolute
                // TODO: test
                'G', '`' => switch (input.intermediates.len) {
                    0 => if (@hasDecl(T, "setCursorCol")) switch (input.params.len) {
                        0 => try self.handler.setCursorCol(1),
                        1 => try self.handler.setCursorCol(input.params[0]),
                        else => log.warn("invalid HPA command: {}", .{input}),
                    } else log.warn("unimplemented CSI callback: {}", .{input}),

                    else => log.warn(
                        "ignoring unimplemented CSI G with intermediates: {s}",
                        .{input.intermediates},
                    ),
                },

                // CUP - Set Cursor Position.
                // TODO: test
                'H', 'f' => switch (input.intermediates.len) {
                    0 => if (@hasDecl(T, "setCursorPos")) switch (input.params.len) {
                        0 => try self.handler.setCursorPos(1, 1),
                        1 => try self.handler.setCursorPos(input.params[0], 1),
                        2 => try self.handler.setCursorPos(input.params[0], input.params[1]),
                        else => log.warn("invalid CUP command: {}", .{input}),
                    } else log.warn("unimplemented CSI callback: {}", .{input}),

                    else => log.warn(
                        "ignoring unimplemented CSI H with intermediates: {s}",
                        .{input.intermediates},
                    ),
                },

                // CHT - Cursor Horizontal Tabulation
                'I' => switch (input.intermediates.len) {
                    0 => if (@hasDecl(T, "horizontalTab")) try self.handler.horizontalTab(
                        switch (input.params.len) {
                            0 => 1,
                            1 => input.params[0],
                            else => {
                                log.warn("invalid horizontal tab command: {}", .{input});
                                return;
                            },
                        },
                    ) else log.warn("unimplemented CSI callback: {}", .{input}),

                    else => log.warn(
                        "ignoring unimplemented CSI I with intermediates: {s}",
                        .{input.intermediates},
                    ),
                },

                // Erase Display
                'J' => if (@hasDecl(T, "eraseDisplay")) {
                    const protected_: ?bool = switch (input.intermediates.len) {
                        0 => false,
                        1 => if (input.intermediates[0] == '?') true else null,
                        else => null,
                    };

                    const protected = protected_ orelse {
                        log.warn("invalid erase display command: {}", .{input});
                        return;
                    };

                    const mode_: ?csi.EraseDisplay = switch (input.params.len) {
                        0 => .below,
                        1 => std.meta.intToEnum(csi.EraseDisplay, input.params[0]) catch null,
                        else => null,
                    };

                    const mode = mode_ orelse {
                        log.warn("invalid erase display command: {}", .{input});
                        return;
                    };

                    try self.handler.eraseDisplay(mode, protected);
                } else log.warn("unimplemented CSI callback: {}", .{input}),

                // Erase Line
                'K' => if (@hasDecl(T, "eraseLine")) {
                    const protected_: ?bool = switch (input.intermediates.len) {
                        0 => false,
                        1 => if (input.intermediates[0] == '?') true else null,
                        else => null,
                    };

                    const protected = protected_ orelse {
                        log.warn("invalid erase line command: {}", .{input});
                        return;
                    };

                    const mode_: ?csi.EraseLine = switch (input.params.len) {
                        0 => .right,
                        1 => if (input.params[0] < 3) @enumFromInt(input.params[0]) else null,
                        else => null,
                    };

                    const mode = mode_ orelse {
                        log.warn("invalid erase line command: {}", .{input});
                        return;
                    };

                    try self.handler.eraseLine(mode, protected);
                } else log.warn("unimplemented CSI callback: {}", .{input}),

                // IL - Insert Lines
                // TODO: test
                'L' => switch (input.intermediates.len) {
                    0 => if (@hasDecl(T, "insertLines")) switch (input.params.len) {
                        0 => try self.handler.insertLines(1),
                        1 => try self.handler.insertLines(input.params[0]),
                        else => log.warn("invalid IL command: {}", .{input}),
                    } else log.warn("unimplemented CSI callback: {}", .{input}),

                    else => log.warn(
                        "ignoring unimplemented CSI L with intermediates: {s}",
                        .{input.intermediates},
                    ),
                },

                // DL - Delete Lines
                // TODO: test
                'M' => switch (input.intermediates.len) {
                    0 => if (@hasDecl(T, "deleteLines")) switch (input.params.len) {
                        0 => try self.handler.deleteLines(1),
                        1 => try self.handler.deleteLines(input.params[0]),
                        else => log.warn("invalid DL command: {}", .{input}),
                    } else log.warn("unimplemented CSI callback: {}", .{input}),

                    else => log.warn(
                        "ignoring unimplemented CSI M with intermediates: {s}",
                        .{input.intermediates},
                    ),
                },

                // Delete Character (DCH)
                'P' => switch (input.intermediates.len) {
                    0 => if (@hasDecl(T, "deleteChars")) try self.handler.deleteChars(
                        switch (input.params.len) {
                            0 => 1,
                            1 => input.params[0],
                            else => {
                                log.warn("invalid delete characters command: {}", .{input});
                                return;
                            },
                        },
                    ) else log.warn("unimplemented CSI callback: {}", .{input}),

                    else => log.warn(
                        "ignoring unimplemented CSI P with intermediates: {s}",
                        .{input.intermediates},
                    ),
                },

                // Scroll Up (SD)

                'S' => switch (input.intermediates.len) {
                    0 => if (@hasDecl(T, "scrollUp")) try self.handler.scrollUp(
                        switch (input.params.len) {
                            0 => 1,
                            1 => input.params[0],
                            else => {
                                log.warn("invalid scroll up command: {}", .{input});
                                return;
                            },
                        },
                    ) else log.warn("unimplemented CSI callback: {}", .{input}),

                    else => log.warn(
                        "ignoring unimplemented CSI S with intermediates: {s}",
                        .{input.intermediates},
                    ),
                },

                // Scroll Down (SD)
                'T' => switch (input.intermediates.len) {
                    0 => if (@hasDecl(T, "scrollDown")) try self.handler.scrollDown(
                        switch (input.params.len) {
                            0 => 1,
                            1 => input.params[0],
                            else => {
                                log.warn("invalid scroll down command: {}", .{input});
                                return;
                            },
                        },
                    ) else log.warn("unimplemented CSI callback: {}", .{input}),

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
                            if (@hasDecl(T, "tabSet"))
                                try self.handler.tabSet()
                            else
                                log.warn("unimplemented tab set callback: {}", .{input});

                            return;
                        }

                        switch (input.params.len) {
                            0 => unreachable,

                            1 => switch (input.params[0]) {
                                0 => unreachable,

                                2 => if (@hasDecl(T, "tabClear"))
                                    try self.handler.tabClear(.current)
                                else
                                    log.warn("unimplemented tab clear callback: {}", .{input}),

                                5 => if (@hasDecl(T, "tabClear"))
                                    try self.handler.tabClear(.all)
                                else
                                    log.warn("unimplemented tab clear callback: {}", .{input}),

                                else => {},
                            },

                            else => {},
                        }

                        log.warn("invalid cursor tabulation control: {}", .{input});
                        return;
                    },

                    1 => if (input.intermediates[0] == '?' and input.params[0] == 5) {
                        if (@hasDecl(T, "tabReset"))
                            try self.handler.tabReset()
                        else
                            log.warn("unimplemented tab reset callback: {}", .{input});
                    } else log.warn("invalid cursor tabulation control: {}", .{input}),

                    else => log.warn(
                        "ignoring unimplemented CSI W with intermediates: {s}",
                        .{input.intermediates},
                    ),
                },

                // Erase Characters (ECH)
                'X' => switch (input.intermediates.len) {
                    0 => if (@hasDecl(T, "eraseChars")) try self.handler.eraseChars(
                        switch (input.params.len) {
                            0 => 1,
                            1 => input.params[0],
                            else => {
                                log.warn("invalid erase characters command: {}", .{input});
                                return;
                            },
                        },
                    ) else log.warn("unimplemented CSI callback: {}", .{input}),

                    else => log.warn(
                        "ignoring unimplemented CSI X with intermediates: {s}",
                        .{input.intermediates},
                    ),
                },

                // CHT - Cursor Horizontal Tabulation Back
                'Z' => switch (input.intermediates.len) {
                    0 => if (@hasDecl(T, "horizontalTabBack")) try self.handler.horizontalTabBack(
                        switch (input.params.len) {
                            0 => 1,
                            1 => input.params[0],
                            else => {
                                log.warn("invalid horizontal tab back command: {}", .{input});
                                return;
                            },
                        },
                    ) else log.warn("unimplemented CSI callback: {}", .{input}),

                    else => log.warn(
                        "ignoring unimplemented CSI Z with intermediates: {s}",
                        .{input.intermediates},
                    ),
                },

                // HPR - Cursor Horizontal Position Relative
                'a' => switch (input.intermediates.len) {
                    0 => if (@hasDecl(T, "setCursorColRelative")) try self.handler.setCursorColRelative(
                        switch (input.params.len) {
                            0 => 1,
                            1 => input.params[0],
                            else => {
                                log.warn("invalid HPR command: {}", .{input});
                                return;
                            },
                        },
                    ) else log.warn("unimplemented CSI callback: {}", .{input}),

                    else => log.warn(
                        "ignoring unimplemented CSI a with intermediates: {s}",
                        .{input.intermediates},
                    ),
                },

                // Repeat Previous Char (REP)
                'b' => switch (input.intermediates.len) {
                    0 => if (@hasDecl(T, "printRepeat")) try self.handler.printRepeat(
                        switch (input.params.len) {
                            0 => 1,
                            1 => input.params[0],
                            else => {
                                log.warn("invalid print repeat command: {}", .{input});
                                return;
                            },
                        },
                    ) else log.warn("unimplemented CSI callback: {}", .{input}),

                    else => log.warn(
                        "ignoring unimplemented CSI b with intermediates: {s}",
                        .{input.intermediates},
                    ),
                },

                // c - Device Attributes (DA1)
                'c' => if (@hasDecl(T, "deviceAttributes")) {
                    const req: ansi.DeviceAttributeReq = switch (input.intermediates.len) {
                        0 => ansi.DeviceAttributeReq.primary,
                        1 => switch (input.intermediates[0]) {
                            '>' => ansi.DeviceAttributeReq.secondary,
                            '=' => ansi.DeviceAttributeReq.tertiary,
                            else => null,
                        },
                        else => @as(?ansi.DeviceAttributeReq, null),
                    } orelse {
                        log.warn("invalid device attributes command: {}", .{input});
                        return;
                    };

                    try self.handler.deviceAttributes(req, input.params);
                } else log.warn("unimplemented CSI callback: {}", .{input}),

                // VPA - Cursor Vertical Position Absolute
                'd' => switch (input.intermediates.len) {
                    0 => if (@hasDecl(T, "setCursorRow")) try self.handler.setCursorRow(
                        switch (input.params.len) {
                            0 => 1,
                            1 => input.params[0],
                            else => {
                                log.warn("invalid VPA command: {}", .{input});
                                return;
                            },
                        },
                    ) else log.warn("unimplemented CSI callback: {}", .{input}),

                    else => log.warn(
                        "ignoring unimplemented CSI d with intermediates: {s}",
                        .{input.intermediates},
                    ),
                },

                // VPR - Cursor Vertical Position Relative
                'e' => switch (input.intermediates.len) {
                    0 => if (@hasDecl(T, "setCursorRowRelative")) try self.handler.setCursorRowRelative(
                        switch (input.params.len) {
                            0 => 1,
                            1 => input.params[0],
                            else => {
                                log.warn("invalid VPR command: {}", .{input});
                                return;
                            },
                        },
                    ) else log.warn("unimplemented CSI callback: {}", .{input}),

                    else => log.warn(
                        "ignoring unimplemented CSI e with intermediates: {s}",
                        .{input.intermediates},
                    ),
                },

                // TBC - Tab Clear
                // TODO: test
                'g' => switch (input.intermediates.len) {
                    0 => if (@hasDecl(T, "tabClear")) try self.handler.tabClear(
                        switch (input.params.len) {
                            1 => @enumFromInt(input.params[0]),
                            else => {
                                log.warn("invalid tab clear command: {}", .{input});
                                return;
                            },
                        },
                    ) else log.warn("unimplemented CSI callback: {}", .{input}),

                    else => log.warn(
                        "ignoring unimplemented CSI g with intermediates: {s}",
                        .{input.intermediates},
                    ),
                },

                // SM - Set Mode
                'h' => if (@hasDecl(T, "setMode")) mode: {
                    const ansi_mode = ansi: {
                        if (input.intermediates.len == 0) break :ansi true;
                        if (input.intermediates.len == 1 and
                            input.intermediates[0] == '?') break :ansi false;

                        log.warn("invalid set mode command: {}", .{input});
                        break :mode;
                    };

                    for (input.params) |mode_int| {
                        if (modes.modeFromInt(mode_int, ansi_mode)) |mode| {
                            try self.handler.setMode(mode, true);
                        } else {
                            log.warn("unimplemented mode: {}", .{mode_int});
                        }
                    }
                } else log.warn("unimplemented CSI callback: {}", .{input}),

                // RM - Reset Mode
                'l' => if (@hasDecl(T, "setMode")) mode: {
                    const ansi_mode = ansi: {
                        if (input.intermediates.len == 0) break :ansi true;
                        if (input.intermediates.len == 1 and
                            input.intermediates[0] == '?') break :ansi false;

                        log.warn("invalid set mode command: {}", .{input});
                        break :mode;
                    };

                    for (input.params) |mode_int| {
                        if (modes.modeFromInt(mode_int, ansi_mode)) |mode| {
                            try self.handler.setMode(mode, false);
                        } else {
                            log.warn("unimplemented mode: {}", .{mode_int});
                        }
                    }
                } else log.warn("unimplemented CSI callback: {}", .{input}),

                // SGR - Select Graphic Rendition
                'm' => switch (input.intermediates.len) {
                    0 => if (@hasDecl(T, "setAttribute")) {
                        // log.info("parse SGR params={any}", .{input.params});
                        var p: sgr.Parser = .{
                            .params = input.params,
                            .params_sep = input.params_sep,
                        };
                        while (p.next()) |attr| {
                            // log.info("SGR attribute: {}", .{attr});
                            try self.handler.setAttribute(attr);
                        }
                    } else log.warn("unimplemented CSI callback: {}", .{input}),

                    1 => switch (input.intermediates[0]) {
                        '>' => if (@hasDecl(T, "setModifyKeyFormat")) blk: {
                            if (input.params.len == 0) {
                                // Reset
                                try self.handler.setModifyKeyFormat(.{ .legacy = {} });
                                break :blk;
                            }

                            var format: ansi.ModifyKeyFormat = switch (input.params[0]) {
                                0 => .{ .legacy = {} },
                                1 => .{ .cursor_keys = {} },
                                2 => .{ .function_keys = {} },
                                4 => .{ .other_keys = .none },
                                else => {
                                    log.warn("invalid setModifyKeyFormat: {}", .{input});
                                    break :blk;
                                },
                            };

                            if (input.params.len > 2) {
                                log.warn("invalid setModifyKeyFormat: {}", .{input});
                                break :blk;
                            }

                            if (input.params.len == 2) {
                                switch (format) {
                                    // We don't support any of the subparams yet for these.
                                    .legacy => {},
                                    .cursor_keys => {},
                                    .function_keys => {},

                                    // We only support the numeric form.
                                    .other_keys => |*v| switch (input.params[1]) {
                                        2 => v.* = .numeric,
                                        else => v.* = .none,
                                    },
                                }
                            }

                            try self.handler.setModifyKeyFormat(format);
                        } else log.warn("unimplemented setModifyKeyFormat: {}", .{input}),

                        else => log.warn(
                            "unknown CSI m with intermediate: {}",
                            .{input.intermediates[0]},
                        ),
                    },

                    else => {
                        // Nothing, but I wanted a place to put this comment:
                        // there are others forms of CSI m that have intermediates.
                        // `vim --clean` uses `CSI ? 4 m` and I don't know what
                        // that means. And there is also `CSI > m` which is used
                        // to control modifier key reporting formats that we don't
                        // support yet.
                        log.warn(
                            "ignoring unimplemented CSI m with intermediates: {s}",
                            .{input.intermediates},
                        );
                    },
                },

                // TODO: test
                'n' => {
                    // Handle deviceStatusReport first
                    if (input.intermediates.len == 0 or
                        input.intermediates[0] == '?')
                    {
                        if (!@hasDecl(T, "deviceStatusReport")) {
                            log.warn("unimplemented CSI callback: {}", .{input});
                            return;
                        }

                        if (input.params.len != 1) {
                            log.warn("invalid device status report command: {}", .{input});
                            return;
                        }

                        const question = question: {
                            if (input.intermediates.len == 0) break :question false;
                            if (input.intermediates.len == 1 and
                                input.intermediates[0] == '?') break :question true;

                            log.warn("invalid set mode command: {}", .{input});
                            return;
                        };

                        const req = device_status.reqFromInt(input.params[0], question) orelse {
                            log.warn("invalid device status report command: {}", .{input});
                            return;
                        };

                        try self.handler.deviceStatusReport(req);
                        return;
                    }

                    // Handle other forms of CSI n
                    switch (input.intermediates.len) {
                        0 => unreachable, // handled above

                        1 => switch (input.intermediates[0]) {
                            '>' => if (@hasDecl(T, "setModifyKeyFormat")) {
                                // This isn't strictly correct. CSI > n has parameters that
                                // control what exactly is being disabled. However, we
                                // only support reverting back to modify other keys in
                                // numeric except format.
                                try self.handler.setModifyKeyFormat(.{ .other_keys = .numeric_except });
                            } else log.warn("unimplemented setModifyKeyFormat: {}", .{input}),

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
                            log.warn("invalid DECRQM command: {}", .{input});
                            break :decrqm;
                        }

                        if (@hasDecl(T, "requestMode")) {
                            try self.handler.requestMode(input.params[0], ansi_mode);
                        } else log.warn("unimplemented DECRQM callback: {}", .{input});
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
                            if (@hasDecl(T, "setCursorStyle")) try self.handler.setCursorStyle(
                                switch (input.params.len) {
                                    0 => ansi.CursorStyle.default,
                                    1 => @enumFromInt(input.params[0]),
                                    else => {
                                        log.warn("invalid set curor style command: {}", .{input});
                                        return;
                                    },
                                },
                            ) else log.warn("unimplemented CSI callback: {}", .{input});
                        },

                        // DECSCA
                        '"' => {
                            if (@hasDecl(T, "setProtectedMode")) {
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
                                    log.warn("invalid set protected mode command: {}", .{input});
                                    return;
                                };

                                try self.handler.setProtectedMode(mode);
                            } else log.warn("unimplemented CSI callback: {}", .{input});
                        },

                        // XTVERSION
                        '>' => {
                            if (@hasDecl(T, "reportXtversion")) try self.handler.reportXtversion();
                        },
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

                'r' => switch (input.intermediates.len) {
                    // DECSTBM - Set Top and Bottom Margins
                    0 => if (@hasDecl(T, "setTopAndBottomMargin")) {
                        switch (input.params.len) {
                            0 => try self.handler.setTopAndBottomMargin(0, 0),
                            1 => try self.handler.setTopAndBottomMargin(input.params[0], 0),
                            2 => try self.handler.setTopAndBottomMargin(input.params[0], input.params[1]),
                            else => log.warn("invalid DECSTBM command: {}", .{input}),
                        }
                    } else log.warn(
                        "unimplemented CSI callback: {}",
                        .{input},
                    ),

                    1 => switch (input.intermediates[0]) {
                        // Restore Mode
                        '?' => if (@hasDecl(T, "restoreMode")) {
                            for (input.params) |mode_int| {
                                if (modes.modeFromInt(mode_int, false)) |mode| {
                                    try self.handler.restoreMode(mode);
                                } else {
                                    log.warn(
                                        "unimplemented restore mode: {}",
                                        .{mode_int},
                                    );
                                }
                            }
                        },

                        else => log.warn(
                            "unknown CSI s with intermediate: {}",
                            .{input},
                        ),
                    },

                    else => log.warn(
                        "ignoring unimplemented CSI s with intermediates: {s}",
                        .{input},
                    ),
                },

                's' => switch (input.intermediates.len) {
                    // DECSLRM
                    0 => if (@hasDecl(T, "setLeftAndRightMargin")) {
                        switch (input.params.len) {
                            // CSI S is ambiguous with zero params so we defer
                            // to our handler to do the proper logic. If mode 69
                            // is set, then we should invoke DECSLRM, otherwise
                            // we should invoke SC.
                            0 => try self.handler.setLeftAndRightMarginAmbiguous(),
                            1 => try self.handler.setLeftAndRightMargin(input.params[0], 0),
                            2 => try self.handler.setLeftAndRightMargin(input.params[0], input.params[1]),
                            else => log.warn("invalid DECSLRM command: {}", .{input}),
                        }
                    } else log.warn(
                        "unimplemented CSI callback: {}",
                        .{input},
                    ),

                    1 => switch (input.intermediates[0]) {
                        '?' => if (@hasDecl(T, "saveMode")) {
                            for (input.params) |mode_int| {
                                if (modes.modeFromInt(mode_int, false)) |mode| {
                                    try self.handler.saveMode(mode);
                                } else {
                                    log.warn(
                                        "unimplemented save mode: {}",
                                        .{mode_int},
                                    );
                                }
                            }
                        },

                        // XTSHIFTESCAPE
                        '>' => if (@hasDecl(T, "setMouseShiftCapture")) capture: {
                            const capture = switch (input.params.len) {
                                0 => false,
                                1 => switch (input.params[0]) {
                                    0 => false,
                                    1 => true,
                                    else => {
                                        log.warn("invalid XTSHIFTESCAPE command: {}", .{input});
                                        break :capture;
                                    },
                                },
                                else => {
                                    log.warn("invalid XTSHIFTESCAPE command: {}", .{input});
                                    break :capture;
                                },
                            };

                            try self.handler.setMouseShiftCapture(capture);
                        } else log.warn(
                            "unimplemented CSI callback: {}",
                            .{input},
                        ),

                        else => log.warn(
                            "unknown CSI s with intermediate: {}",
                            .{input},
                        ),
                    },

                    else => log.warn(
                        "ignoring unimplemented CSI s with intermediates: {s}",
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
                                    if (@hasDecl(T, "sendSizeReport")) {
                                        self.handler.sendSizeReport(.csi_14_t);
                                    } else log.warn(
                                        "ignoring unimplemented CSI 14 t",
                                        .{},
                                    );
                                } else log.warn(
                                    "ignoring CSI 14 t with extra parameters: {}",
                                    .{input},
                                ),
                                16 => if (input.params.len == 1) {
                                    // report cell size in pixels
                                    if (@hasDecl(T, "sendSizeReport")) {
                                        self.handler.sendSizeReport(.csi_16_t);
                                    } else log.warn(
                                        "ignoring unimplemented CSI 16 t",
                                        .{},
                                    );
                                } else log.warn(
                                    "ignoring CSI 16 t with extra parameters: {s}",
                                    .{input},
                                ),
                                18 => if (input.params.len == 1) {
                                    // report screen size in characters
                                    if (@hasDecl(T, "sendSizeReport")) {
                                        self.handler.sendSizeReport(.csi_18_t);
                                    } else log.warn(
                                        "ignoring unimplemented CSI 18 t",
                                        .{},
                                    );
                                } else log.warn(
                                    "ignoring CSI 18 t with extra parameters: {s}",
                                    .{input},
                                ),
                                21 => if (input.params.len == 1) {
                                    // report window title
                                    if (@hasDecl(T, "sendSizeReport")) {
                                        self.handler.sendSizeReport(.csi_21_t);
                                    } else log.warn(
                                        "ignoring unimplemented CSI 21 t",
                                        .{},
                                    );
                                } else log.warn(
                                    "ignoring CSI 21 t with extra parameters: {s}",
                                    .{input},
                                ),
                                inline 22, 23 => |number| if ((input.params.len == 2 or
                                    input.params.len == 3) and
                                    // we only support window title
                                    (input.params[1] == 0 or
                                        input.params[1] == 2))
                                {
                                    // push/pop title
                                    if (@hasDecl(T, "pushPopTitle")) {
                                        self.handler.pushPopTitle(.{
                                            .op = switch (number) {
                                                22 => .push,
                                                23 => .pop,
                                                else => @compileError("unreachable"),
                                            },
                                            .index = if (input.params.len == 3)
                                                input.params[2]
                                            else
                                                0,
                                        });
                                    } else log.warn(
                                        "ignoring unimplemented CSI 22/23 t",
                                        .{},
                                    );
                                } else log.warn(
                                    "ignoring CSI 22/23 t with extra parameters: {s}",
                                    .{input},
                                ),
                                else => log.warn(
                                    "ignoring CSI t with unimplemented parameter: {s}",
                                    .{input},
                                ),
                            }
                        } else log.err(
                            "ignoring CSI t with no parameters: {s}",
                            .{input},
                        );
                    },
                    else => log.warn(
                        "ignoring unimplemented CSI t with intermediates: {s}",
                        .{input},
                    ),
                },

                'u' => switch (input.intermediates.len) {
                    0 => if (@hasDecl(T, "restoreCursor"))
                        try self.handler.restoreCursor()
                    else
                        log.warn("unimplemented CSI callback: {}", .{input}),

                    // Kitty keyboard protocol
                    1 => switch (input.intermediates[0]) {
                        '?' => if (@hasDecl(T, "queryKittyKeyboard")) {
                            try self.handler.queryKittyKeyboard();
                        },

                        '>' => if (@hasDecl(T, "pushKittyKeyboard")) push: {
                            const flags: u5 = if (input.params.len == 1)
                                std.math.cast(u5, input.params[0]) orelse {
                                    log.warn("invalid pushKittyKeyboard command: {}", .{input});
                                    break :push;
                                }
                            else
                                0;

                            try self.handler.pushKittyKeyboard(@bitCast(flags));
                        },

                        '<' => if (@hasDecl(T, "popKittyKeyboard")) {
                            const number: u16 = if (input.params.len == 1)
                                input.params[0]
                            else
                                1;

                            try self.handler.popKittyKeyboard(number);
                        },

                        '=' => if (@hasDecl(T, "setKittyKeyboard")) set: {
                            const flags: u5 = if (input.params.len >= 1)
                                std.math.cast(u5, input.params[0]) orelse {
                                    log.warn("invalid setKittyKeyboard command: {}", .{input});
                                    break :set;
                                }
                            else
                                0;

                            const number: u16 = if (input.params.len >= 2)
                                input.params[1]
                            else
                                1;

                            const mode: kitty.KeySetMode = switch (number) {
                                1 => .set,
                                2 => .@"or",
                                3 => .not,
                                else => {
                                    log.warn("invalid setKittyKeyboard command: {}", .{input});
                                    break :set;
                                },
                            };

                            try self.handler.setKittyKeyboard(
                                mode,
                                @bitCast(flags),
                            );
                        },

                        else => log.warn(
                            "unknown CSI s with intermediate: {}",
                            .{input},
                        ),
                    },

                    else => log.warn(
                        "ignoring unimplemented CSI u: {}",
                        .{input},
                    ),
                },

                // ICH - Insert Blanks
                '@' => switch (input.intermediates.len) {
                    0 => if (@hasDecl(T, "insertBlanks")) switch (input.params.len) {
                        0 => try self.handler.insertBlanks(1),
                        1 => try self.handler.insertBlanks(input.params[0]),
                        else => log.warn("invalid ICH command: {}", .{input}),
                    } else log.warn("unimplemented CSI callback: {}", .{input}),

                    else => log.warn(
                        "ignoring unimplemented CSI @: {}",
                        .{input},
                    ),
                },

                // DECSASD - Select Active Status Display
                '}' => {
                    const success = decsasd: {
                        // Verify we're getting a DECSASD command
                        if (input.intermediates.len != 1 or input.intermediates[0] != '$')
                            break :decsasd false;
                        if (input.params.len != 1)
                            break :decsasd false;
                        if (!@hasDecl(T, "setActiveStatusDisplay"))
                            break :decsasd false;

                        const display = std.meta.intToEnum(
                            ansi.StatusDisplay,
                            input.params[0],
                        ) catch break :decsasd false;

                        try self.handler.setActiveStatusDisplay(display);
                        break :decsasd true;
                    };

                    if (!success) log.warn("unimplemented CSI callback: {}", .{input});
                },

                else => if (@hasDecl(T, "csiUnimplemented"))
                    try self.handler.csiUnimplemented(input)
                else
                    log.warn("unimplemented CSI action: {}", .{input}),
            }
        }

        fn oscDispatch(self: *Self, cmd: osc.Command) !void {
            switch (cmd) {
                .change_window_title => |title| {
                    if (@hasDecl(T, "changeWindowTitle")) {
                        if (!std.unicode.utf8ValidateSlice(title)) {
                            log.warn("change title request: invalid utf-8, ignoring request", .{});
                            return;
                        }

                        try self.handler.changeWindowTitle(title);
                        return;
                    } else log.warn("unimplemented OSC callback: {}", .{cmd});
                },

                .change_window_icon => |icon| {
                    log.info("OSC 1 (change icon) received and ignored icon={s}", .{icon});
                },

                .clipboard_contents => |clip| {
                    if (@hasDecl(T, "clipboardContents")) {
                        try self.handler.clipboardContents(clip.kind, clip.data);
                        return;
                    } else log.warn("unimplemented OSC callback: {}", .{cmd});
                },

                .prompt_start => |v| {
                    if (@hasDecl(T, "promptStart")) {
                        switch (v.kind) {
                            .primary, .right => try self.handler.promptStart(v.aid, v.redraw),
                            .continuation, .secondary => try self.handler.promptContinuation(v.aid),
                        }
                        return;
                    } else log.warn("unimplemented OSC callback: {}", .{cmd});
                },

                .prompt_end => {
                    if (@hasDecl(T, "promptEnd")) {
                        try self.handler.promptEnd();
                        return;
                    } else log.warn("unimplemented OSC callback: {}", .{cmd});
                },

                .end_of_input => {
                    if (@hasDecl(T, "endOfInput")) {
                        try self.handler.endOfInput();
                        return;
                    } else log.warn("unimplemented OSC callback: {}", .{cmd});
                },

                .end_of_command => |end| {
                    if (@hasDecl(T, "endOfCommand")) {
                        try self.handler.endOfCommand(end.exit_code);
                        return;
                    } else log.warn("unimplemented OSC callback: {}", .{cmd});
                },

                .report_pwd => |v| {
                    if (@hasDecl(T, "reportPwd")) {
                        try self.handler.reportPwd(v.value);
                        return;
                    } else log.warn("unimplemented OSC callback: {}", .{cmd});
                },

                .mouse_shape => |v| {
                    if (@hasDecl(T, "setMouseShape")) {
                        const shape = MouseShape.fromString(v.value) orelse {
                            log.warn("unknown cursor shape: {s}", .{v.value});
                            return;
                        };

                        try self.handler.setMouseShape(shape);
                        return;
                    } else log.warn("unimplemented OSC callback: {}", .{cmd});
                },

                .color_operation => |v| {
                    if (@hasDecl(T, "handleColorOperation")) {
                        try self.handler.handleColorOperation(v.source, &v.operations, v.terminator);
                        return;
                    } else log.warn("unimplemented OSC callback: {}", .{cmd});
                },

                .kitty_color_protocol => |v| {
                    if (@hasDecl(T, "sendKittyColorReport")) {
                        try self.handler.sendKittyColorReport(v);
                        return;
                    } else log.warn("unimplemented OSC callback: {}", .{cmd});
                },

                .show_desktop_notification => |v| {
                    if (@hasDecl(T, "showDesktopNotification")) {
                        try self.handler.showDesktopNotification(v.title, v.body);
                        return;
                    } else log.warn("unimplemented OSC callback: {}", .{cmd});
                },

                .hyperlink_start => |v| {
                    if (@hasDecl(T, "startHyperlink")) {
                        try self.handler.startHyperlink(v.uri, v.id);
                        return;
                    } else log.warn("unimplemented OSC callback: {}", .{cmd});
                },

                .hyperlink_end => {
                    if (@hasDecl(T, "endHyperlink")) {
                        try self.handler.endHyperlink();
                        return;
                    } else log.warn("unimplemented OSC callback: {}", .{cmd});
                },

                .progress, .sleep, .show_message_box, .change_conemu_tab_title, .wait_input => {
                    log.warn("unimplemented OSC callback: {}", .{cmd});
                },
            }

            // Fall through for when we don't have a handler.
            if (@hasDecl(T, "oscUnimplemented")) {
                try self.handler.oscUnimplemented(cmd);
            } else {
                log.warn("unimplemented OSC command: {s}", .{@tagName(cmd)});
            }
        }

        fn configureCharset(
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
                    log.warn("invalid charset intermediate: {any}", .{intermediates});
                    return;
                },
            };

            if (@hasDecl(T, "configureCharset")) {
                try self.handler.configureCharset(slot, set);
                return;
            }

            log.warn("unimplemented configureCharset callback slot={} set={}", .{
                slot,
                set,
            });
        }

        fn escDispatch(
            self: *Self,
            action: Parser.Action.ESC,
        ) !void {
            switch (action.final) {
                // Charsets
                'B' => try self.configureCharset(action.intermediates, .ascii),
                'A' => try self.configureCharset(action.intermediates, .british),
                '0' => try self.configureCharset(action.intermediates, .dec_special),

                // DECSC - Save Cursor
                '7' => if (@hasDecl(T, "saveCursor")) switch (action.intermediates.len) {
                    0 => try self.handler.saveCursor(),
                    else => {
                        log.warn("invalid command: {}", .{action});
                        return;
                    },
                } else log.warn("unimplemented ESC callback: {}", .{action}),

                '8' => blk: {
                    switch (action.intermediates.len) {
                        // DECRC - Restore Cursor
                        0 => if (@hasDecl(T, "restoreCursor")) {
                            try self.handler.restoreCursor();
                            break :blk {};
                        } else log.warn("unimplemented restore cursor callback: {}", .{action}),

                        1 => switch (action.intermediates[0]) {
                            // DECALN - Fill Screen with E
                            '#' => if (@hasDecl(T, "decaln")) {
                                try self.handler.decaln();
                                break :blk {};
                            } else log.warn("unimplemented ESC callback: {}", .{action}),

                            else => {},
                        },

                        else => {}, // fall through
                    }

                    log.warn("unimplemented ESC action: {}", .{action});
                },

                // IND - Index
                'D' => if (@hasDecl(T, "index")) switch (action.intermediates.len) {
                    0 => try self.handler.index(),
                    else => {
                        log.warn("invalid index command: {}", .{action});
                        return;
                    },
                } else log.warn("unimplemented ESC callback: {}", .{action}),

                // NEL - Next Line
                'E' => if (@hasDecl(T, "nextLine")) switch (action.intermediates.len) {
                    0 => try self.handler.nextLine(),
                    else => {
                        log.warn("invalid next line command: {}", .{action});
                        return;
                    },
                } else log.warn("unimplemented ESC callback: {}", .{action}),

                // HTS - Horizontal Tab Set
                'H' => if (@hasDecl(T, "tabSet")) switch (action.intermediates.len) {
                    0 => try self.handler.tabSet(),
                    else => {
                        log.warn("invalid tab set command: {}", .{action});
                        return;
                    },
                } else log.warn("unimplemented tab set callback: {}", .{action}),

                // RI - Reverse Index
                'M' => if (@hasDecl(T, "reverseIndex")) switch (action.intermediates.len) {
                    0 => try self.handler.reverseIndex(),
                    else => {
                        log.warn("invalid reverse index command: {}", .{action});
                        return;
                    },
                } else log.warn("unimplemented ESC callback: {}", .{action}),

                // SS2 - Single Shift 2
                'N' => if (@hasDecl(T, "invokeCharset")) switch (action.intermediates.len) {
                    0 => try self.handler.invokeCharset(.GL, .G2, true),
                    else => {
                        log.warn("invalid single shift 2 command: {}", .{action});
                        return;
                    },
                } else log.warn("unimplemented invokeCharset: {}", .{action}),

                // SS3 - Single Shift 3
                'O' => if (@hasDecl(T, "invokeCharset")) switch (action.intermediates.len) {
                    0 => try self.handler.invokeCharset(.GL, .G3, true),
                    else => {
                        log.warn("invalid single shift 3 command: {}", .{action});
                        return;
                    },
                } else log.warn("unimplemented invokeCharset: {}", .{action}),

                // SPA - Start of Guarded Area
                'V' => if (@hasDecl(T, "setProtectedMode") and action.intermediates.len == 0) {
                    try self.handler.setProtectedMode(ansi.ProtectedMode.iso);
                } else log.warn("unimplemented ESC callback: {}", .{action}),

                // EPA - End of Guarded Area
                'W' => if (@hasDecl(T, "setProtectedMode") and action.intermediates.len == 0) {
                    try self.handler.setProtectedMode(ansi.ProtectedMode.off);
                } else log.warn("unimplemented ESC callback: {}", .{action}),

                // DECID
                'Z' => if (@hasDecl(T, "deviceAttributes") and action.intermediates.len == 0) {
                    try self.handler.deviceAttributes(.primary, &.{});
                } else log.warn("unimplemented ESC callback: {}", .{action}),

                // RIS - Full Reset
                'c' => if (@hasDecl(T, "fullReset")) switch (action.intermediates.len) {
                    0 => try self.handler.fullReset(),
                    else => {
                        log.warn("invalid full reset command: {}", .{action});
                        return;
                    },
                } else log.warn("unimplemented ESC callback: {}", .{action}),

                // LS2 - Locking Shift 2
                'n' => if (@hasDecl(T, "invokeCharset")) switch (action.intermediates.len) {
                    0 => try self.handler.invokeCharset(.GL, .G2, false),
                    else => {
                        log.warn("invalid single shift 2 command: {}", .{action});
                        return;
                    },
                } else log.warn("unimplemented invokeCharset: {}", .{action}),

                // LS3 - Locking Shift 3
                'o' => if (@hasDecl(T, "invokeCharset")) switch (action.intermediates.len) {
                    0 => try self.handler.invokeCharset(.GL, .G3, false),
                    else => {
                        log.warn("invalid single shift 3 command: {}", .{action});
                        return;
                    },
                } else log.warn("unimplemented invokeCharset: {}", .{action}),

                // LS1R - Locking Shift 1 Right
                '~' => if (@hasDecl(T, "invokeCharset")) switch (action.intermediates.len) {
                    0 => try self.handler.invokeCharset(.GR, .G1, false),
                    else => {
                        log.warn("invalid locking shift 1 right command: {}", .{action});
                        return;
                    },
                } else log.warn("unimplemented invokeCharset: {}", .{action}),

                // LS2R - Locking Shift 2 Right
                '}' => if (@hasDecl(T, "invokeCharset")) switch (action.intermediates.len) {
                    0 => try self.handler.invokeCharset(.GR, .G2, false),
                    else => {
                        log.warn("invalid locking shift 2 right command: {}", .{action});
                        return;
                    },
                } else log.warn("unimplemented invokeCharset: {}", .{action}),

                // LS3R - Locking Shift 3 Right
                '|' => if (@hasDecl(T, "invokeCharset")) switch (action.intermediates.len) {
                    0 => try self.handler.invokeCharset(.GR, .G3, false),
                    else => {
                        log.warn("invalid locking shift 3 right command: {}", .{action});
                        return;
                    },
                } else log.warn("unimplemented invokeCharset: {}", .{action}),

                // Set application keypad mode
                '=' => if (@hasDecl(T, "setMode") and action.intermediates.len == 0) {
                    try self.handler.setMode(.keypad_keys, true);
                } else log.warn("unimplemented setMode: {}", .{action}),

                // Reset application keypad mode
                '>' => if (@hasDecl(T, "setMode") and action.intermediates.len == 0) {
                    try self.handler.setMode(.keypad_keys, false);
                } else log.warn("unimplemented setMode: {}", .{action}),

                else => if (@hasDecl(T, "escUnimplemented"))
                    try self.handler.escUnimplemented(action)
                else
                    log.warn("unimplemented ESC action: {}", .{action}),

                // Sets ST (string terminator). We don't have to do anything
                // because our parser always accepts ST.
                '\\' => {},
            }
        }
    };
}

test "stream: print" {
    const H = struct {
        c: ?u21 = 0,

        pub fn print(self: *@This(), c: u21) !void {
            self.c = c;
        }
    };

    var s: Stream(H) = .{ .handler = .{} };
    try s.next('x');
    try testing.expectEqual(@as(u21, 'x'), s.handler.c.?);
}

test "simd: print invalid utf-8" {
    const H = struct {
        c: ?u21 = 0,

        pub fn print(self: *@This(), c: u21) !void {
            self.c = c;
        }
    };

    var s: Stream(H) = .{ .handler = .{} };
    try s.nextSlice(&.{0xFF});
    try testing.expectEqual(@as(u21, 0xFFFD), s.handler.c.?);
}

test "simd: complete incomplete utf-8" {
    const H = struct {
        c: ?u21 = null,

        pub fn print(self: *@This(), c: u21) !void {
            self.c = c;
        }
    };

    var s: Stream(H) = .{ .handler = .{} };
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

        pub fn setCursorRight(self: *@This(), v: u16) !void {
            self.amount = v;
        }
    };

    var s: Stream(H) = .{ .handler = .{} };
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
        pub fn setMode(self: *@This(), mode: modes.Mode, v: bool) !void {
            self.mode = @as(modes.Mode, @enumFromInt(1));
            if (v) self.mode = mode;
        }
    };

    var s: Stream(H) = .{ .handler = .{} };
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

        pub fn setMode(self: *@This(), mode: modes.Mode, v: bool) !void {
            self.mode = null;
            if (v) self.mode = mode;
        }
    };

    var s: Stream(H) = .{ .handler = .{} };
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
    };

    var s: Stream(H) = .{ .handler = .{} };
    try s.nextSlice("\x1B[6h");
    try testing.expect(s.handler.mode == null);

    try s.nextSlice("\x1B[6l");
    try testing.expect(s.handler.mode == null);
}

test "stream: restore mode" {
    const H = struct {
        const Self = @This();
        called: bool = false,

        pub fn setTopAndBottomMargin(self: *Self, t: u16, b: u16) !void {
            _ = t;
            _ = b;
            self.called = true;
        }
    };

    var s: Stream(H) = .{ .handler = .{} };
    for ("\x1B[?42r") |c| try s.next(c);
    try testing.expect(!s.handler.called);
}

test "stream: pop kitty keyboard with no params defaults to 1" {
    const H = struct {
        const Self = @This();
        n: u16 = 0,

        pub fn popKittyKeyboard(self: *Self, n: u16) !void {
            self.n = n;
        }
    };

    var s: Stream(H) = .{ .handler = .{} };
    for ("\x1B[<u") |c| try s.next(c);
    try testing.expectEqual(@as(u16, 1), s.handler.n);
}

test "stream: DECSCA" {
    const H = struct {
        const Self = @This();
        v: ?ansi.ProtectedMode = null,

        pub fn setProtectedMode(self: *Self, v: ansi.ProtectedMode) !void {
            self.v = v;
        }
    };

    var s: Stream(H) = .{ .handler = .{} };
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

        pub fn eraseDisplay(
            self: *Self,
            mode: csi.EraseDisplay,
            protected: bool,
        ) !void {
            self.mode = mode;
            self.protected = protected;
        }
    };

    var s: Stream(H) = .{ .handler = .{} };
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

        pub fn eraseLine(
            self: *Self,
            mode: csi.EraseLine,
            protected: bool,
        ) !void {
            self.mode = mode;
            self.protected = protected;
        }
    };

    var s: Stream(H) = .{ .handler = .{} };
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

        pub fn setCursorStyle(self: *@This(), style: ansi.CursorStyle) !void {
            self.style = style;
        }
    };

    var s: Stream(H) = .{ .handler = .{} };
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

        pub fn setCursorStyle(self: *@This(), style: ansi.CursorStyle) !void {
            self.style = style;
        }
    };

    var s: Stream(H) = .{ .handler = .{} };
    try s.nextSlice("\x1B[q");
    try testing.expect(s.handler.style == null);

    try s.nextSlice("\x1B[1q");
    try testing.expect(s.handler.style == null);
}

test "stream: XTSHIFTESCAPE" {
    const H = struct {
        escape: ?bool = null,

        pub fn setMouseShiftCapture(self: *@This(), v: bool) !void {
            self.escape = v;
        }
    };

    var s: Stream(H) = .{ .handler = .{} };
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

        pub fn changeWindowTitle(self: *@This(), title: []const u8) !void {
            _ = title;

            self.seen = true;
        }
    };

    {
        var s: Stream(H) = .{ .handler = .{} };
        try s.nextSlice("\x1b]2;abc\x1b\\");
        try testing.expect(s.handler.seen);
    }

    {
        var s: Stream(H) = .{ .handler = .{} };
        try s.nextSlice("\x1b]2;abc\xc0\x1b\\");
        try testing.expect(!s.handler.seen);
    }
}

test "stream: insert characters" {
    const H = struct {
        const Self = @This();
        called: bool = false,

        pub fn insertBlanks(self: *Self, v: u16) !void {
            _ = v;
            self.called = true;
        }
    };

    var s: Stream(H) = .{ .handler = .{} };
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

        pub fn setLeftAndRightMargin(self: *Self, left: u16, right: u16) !void {
            _ = self;
            _ = left;
            _ = right;
            @panic("bad");
        }

        pub fn setLeftAndRightMarginAmbiguous(self: *Self) !void {
            self.called = true;
        }
    };

    var s: Stream(H) = .{ .handler = .{} };
    for ("\x1B[s") |c| try s.next(c);
    try testing.expect(s.handler.called);
}

test "stream: SCORC" {
    const H = struct {
        const Self = @This();
        called: bool = false,

        pub fn restoreCursor(self: *Self) !void {
            self.called = true;
        }
    };

    var s: Stream(H) = .{ .handler = .{} };
    for ("\x1B[u") |c| try s.next(c);
    try testing.expect(s.handler.called);
}

test "stream: too many csi params" {
    const H = struct {
        pub fn setCursorRight(self: *@This(), v: u16) !void {
            _ = v;
            _ = self;
            unreachable;
        }
    };

    var s: Stream(H) = .{ .handler = .{} };
    try s.nextSlice("\x1B[1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1;1C");
}

test "stream: csi param too long" {
    const H = struct {
        pub fn setCursorRight(self: *@This(), v: u16) !void {
            _ = v;
            _ = self;
        }
    };

    var s: Stream(H) = .{ .handler = .{} };
    try s.nextSlice("\x1B[1111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111C");
}

test "stream: send report with CSI t" {
    const H = struct {
        style: ?csi.SizeReportStyle = null,

        pub fn sendSizeReport(self: *@This(), style: csi.SizeReportStyle) void {
            self.style = style;
        }
    };

    var s: Stream(H) = .{ .handler = .{} };

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
    };

    var s: Stream(H) = .{ .handler = .{} };

    try s.nextSlice("\x1b[19t");
    try testing.expectEqual(null, s.handler.style);
}

test "stream: CSI t push title" {
    const H = struct {
        op: ?csi.TitlePushPop = null,

        pub fn pushPopTitle(self: *@This(), op: csi.TitlePushPop) void {
            self.op = op;
        }
    };

    var s: Stream(H) = .{ .handler = .{} };

    try s.nextSlice("\x1b[22;0t");
    try testing.expectEqual(csi.TitlePushPop{
        .op = .push,
        .index = 0,
    }, s.handler.op.?);
}

test "stream: CSI t push title with explicit window" {
    const H = struct {
        op: ?csi.TitlePushPop = null,

        pub fn pushPopTitle(self: *@This(), op: csi.TitlePushPop) void {
            self.op = op;
        }
    };

    var s: Stream(H) = .{ .handler = .{} };

    try s.nextSlice("\x1b[22;2t");
    try testing.expectEqual(csi.TitlePushPop{
        .op = .push,
        .index = 0,
    }, s.handler.op.?);
}

test "stream: CSI t push title with explicit icon" {
    const H = struct {
        op: ?csi.TitlePushPop = null,

        pub fn pushPopTitle(self: *@This(), op: csi.TitlePushPop) void {
            self.op = op;
        }
    };

    var s: Stream(H) = .{ .handler = .{} };

    try s.nextSlice("\x1b[22;1t");
    try testing.expectEqual(null, s.handler.op);
}

test "stream: CSI t push title with index" {
    const H = struct {
        op: ?csi.TitlePushPop = null,

        pub fn pushPopTitle(self: *@This(), op: csi.TitlePushPop) void {
            self.op = op;
        }
    };

    var s: Stream(H) = .{ .handler = .{} };

    try s.nextSlice("\x1b[22;0;5t");
    try testing.expectEqual(csi.TitlePushPop{
        .op = .push,
        .index = 5,
    }, s.handler.op.?);
}

test "stream: CSI t pop title" {
    const H = struct {
        op: ?csi.TitlePushPop = null,

        pub fn pushPopTitle(self: *@This(), op: csi.TitlePushPop) void {
            self.op = op;
        }
    };

    var s: Stream(H) = .{ .handler = .{} };

    try s.nextSlice("\x1b[23;0t");
    try testing.expectEqual(csi.TitlePushPop{
        .op = .pop,
        .index = 0,
    }, s.handler.op.?);
}

test "stream: CSI t pop title with explicit window" {
    const H = struct {
        op: ?csi.TitlePushPop = null,

        pub fn pushPopTitle(self: *@This(), op: csi.TitlePushPop) void {
            self.op = op;
        }
    };

    var s: Stream(H) = .{ .handler = .{} };

    try s.nextSlice("\x1b[23;2t");
    try testing.expectEqual(csi.TitlePushPop{
        .op = .pop,
        .index = 0,
    }, s.handler.op.?);
}

test "stream: CSI t pop title with explicit icon" {
    const H = struct {
        op: ?csi.TitlePushPop = null,

        pub fn pushPopTitle(self: *@This(), op: csi.TitlePushPop) void {
            self.op = op;
        }
    };

    var s: Stream(H) = .{ .handler = .{} };

    try s.nextSlice("\x1b[23;1t");
    try testing.expectEqual(null, s.handler.op);
}

test "stream: CSI t pop title with index" {
    const H = struct {
        op: ?csi.TitlePushPop = null,

        pub fn pushPopTitle(self: *@This(), op: csi.TitlePushPop) void {
            self.op = op;
        }
    };

    var s: Stream(H) = .{ .handler = .{} };

    try s.nextSlice("\x1b[23;0;5t");
    try testing.expectEqual(csi.TitlePushPop{
        .op = .pop,
        .index = 5,
    }, s.handler.op.?);
}

test "stream CSI W clear tab stops" {
    const H = struct {
        op: ?csi.TabClear = null,

        pub fn tabClear(self: *@This(), op: csi.TabClear) !void {
            self.op = op;
        }
    };

    var s: Stream(H) = .{ .handler = .{} };

    try s.nextSlice("\x1b[2W");
    try testing.expectEqual(csi.TabClear.current, s.handler.op.?);

    try s.nextSlice("\x1b[5W");
    try testing.expectEqual(csi.TabClear.all, s.handler.op.?);
}

test "stream CSI W tab set" {
    const H = struct {
        called: bool = false,

        pub fn tabSet(self: *@This()) !void {
            self.called = true;
        }
    };

    var s: Stream(H) = .{ .handler = .{} };

    try s.nextSlice("\x1b[W");
    try testing.expect(s.handler.called);

    s.handler.called = false;
    try s.nextSlice("\x1b[0W");
    try testing.expect(s.handler.called);

    s.handler.called = false;
    try s.nextSlice("\x1b[>W");
    try testing.expect(!s.handler.called);

    s.handler.called = false;
    try s.nextSlice("\x1b[99W");
    try testing.expect(!s.handler.called);
}

test "stream CSI ? W reset tab stops" {
    const H = struct {
        reset: bool = false,

        pub fn tabReset(self: *@This()) !void {
            self.reset = true;
        }
    };

    var s: Stream(H) = .{ .handler = .{} };

    try s.nextSlice("\x1b[?2W");
    try testing.expect(!s.handler.reset);

    try s.nextSlice("\x1b[?5W");
    try testing.expect(s.handler.reset);

    // Invalid and ignored by the handler
    try s.nextSlice("\x1b[?1;2;3W");
    try testing.expect(s.handler.reset);
}
