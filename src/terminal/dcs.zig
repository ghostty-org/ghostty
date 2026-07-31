const std = @import("std");
const build_options = @import("terminal_options");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const terminal = @import("main.zig");
const terminfo = @import("../terminfo/main.zig");
const DCS = terminal.DCS;

const log = std.log.scoped(.terminal_dcs);

/// DCS command handler. This should be hooked into a terminal.Stream handler.
/// The hook/put/unhook functions are meant to be called from the
/// terminal.stream dcsHook, dcsPut, and dcsUnhook functions, respectively.
pub const Handler = struct {
    state: State = .{ .inactive = {} },

    /// Maximum bytes any DCS command can take. This is to prevent
    /// malicious input from causing us to allocate too much memory.
    /// This is arbitrarily set to 1MB today, increase if needed.
    max_bytes: usize = 1024 * 1024,

    pub fn deinit(self: *Handler) void {
        self.discard();
    }

    pub fn hook(self: *Handler, alloc: Allocator, dcs: DCS) ?Command {
        assert(self.state == .inactive);

        // Initialize our state to ignore in case of error
        self.state = .ignore;

        // Try to parse the hook.
        const hk_ = self.tryHook(alloc, dcs) catch |err| {
            log.info("error initializing DCS hook, will ignore hook err={}", .{err});
            return null;
        };
        const hk = hk_ orelse {
            log.info("unknown DCS hook: {}", .{dcs});
            return null;
        };

        self.state = hk.state;
        return hk.command;
    }

    const Hook = struct {
        state: State,
        command: ?Command = null,
    };

    fn tryHook(self: Handler, alloc: Allocator, dcs: DCS) !?Hook {
        return switch (dcs.intermediates.len) {
            0 => switch (dcs.final) {
                // Tmux control mode
                'p' => tmux: {
                    if (comptime !build_options.tmux_control_mode) {
                        log.debug("tmux control mode not enabled in build, ignoring", .{});
                        break :tmux null;
                    }

                    // Tmux control mode must start with ESC P 1000 p
                    if (dcs.params.len != 1 or dcs.params[0] != 1000) break :tmux null;

                    break :tmux .{
                        .state = .{
                            .tmux = .{
                                .max_bytes = self.max_bytes,
                                .buffer = try .initCapacity(
                                    alloc,
                                    128, // Arbitrary choice to limit initial reallocs
                                ),
                            },
                        },
                        .command = .{ .tmux = .enter },
                    };
                },

                else => null,
            },

            1 => switch (dcs.intermediates[0]) {
                '+' => switch (dcs.final) {
                    // XTGETTCAP
                    // https://github.com/mitchellh/ghostty/issues/517
                    'q' => .{
                        .state = .{
                            .xtgettcap = try .initCapacity(
                                alloc,
                                128, // Arbitrary choice
                            ),
                        },
                    },

                    else => null,
                },

                '$' => switch (dcs.final) {
                    // DECRQSS
                    'q' => .{ .state = .{
                        .decrqss = .{},
                    } },

                    else => null,
                },

                else => null,
            },

            else => null,
        };
    }

    /// Put a byte into the DCS handler. This will return a command
    /// if a command needs to be executed.
    pub fn put(self: *Handler, byte: u8) ?Command {
        return self.tryPut(byte) catch |err| {
            // On error we just discard our state and ignore the rest
            log.info("error putting byte into DCS handler err={}", .{err});
            self.discard();
            self.state = .ignore;
            return null;
        };
    }

    fn tryPut(self: *Handler, byte: u8) !?Command {
        switch (self.state) {
            .inactive,
            .ignore,
            => {},

            .tmux => |*tmux| if (comptime build_options.tmux_control_mode) {
                return .{
                    .tmux = (try tmux.put(byte)) orelse return null,
                };
            } else unreachable,

            .xtgettcap => |*list| {
                if (list.written().len >= self.max_bytes) {
                    return error.OutOfMemory;
                }

                try list.writer.writeByte(byte);
            },

            .decrqss => |*buffer| {
                if (buffer.len >= buffer.data.len) {
                    return error.OutOfMemory;
                }

                buffer.data[buffer.len] = byte;
                buffer.len += 1;
            },
        }

        return null;
    }

    pub fn unhook(self: *Handler) ?Command {
        // Note: we do NOT call deinit here on purpose because some commands
        // transfer memory ownership. If state needs cleanup, the switch
        // prong below should handle it.
        defer self.state = .inactive;

        return switch (self.state) {
            .inactive,
            .ignore,
            => null,

            .tmux => if (comptime build_options.tmux_control_mode) tmux: {
                self.state.deinit();
                break :tmux .{ .tmux = .exit };
            } else unreachable,

            .xtgettcap => |*list| xtgettcap: {
                // Note: purposely do not deinit our state here because
                // we copy it into the resulting command.
                const items = list.written();
                for (items, 0..) |b, i| items[i] = std.ascii.toUpper(b);
                break :xtgettcap .{ .xtgettcap = .{ .data = list.* } };
            },

            .decrqss => |buffer| .{ .decrqss = switch (buffer.len) {
                0 => .none,
                1 => switch (buffer.data[0]) {
                    'm' => .sgr,
                    'r' => .decstbm,
                    's' => .decslrm,
                    else => .none,
                },
                2 => switch (buffer.data[0]) {
                    ' ' => switch (buffer.data[1]) {
                        'q' => .decscusr,
                        else => .none,
                    },
                    else => .none,
                },
                else => unreachable,
            } },
        };
    }

    fn discard(self: *Handler) void {
        self.state.deinit();
        self.state = .inactive;
    }
};

pub const Command = union(enum) {
    /// XTGETTCAP
    xtgettcap: XTGETTCAP,

    /// DECRQSS
    decrqss: DECRQSS,

    /// Tmux control mode
    tmux: if (build_options.tmux_control_mode)
        terminal.tmux.ControlNotification
    else
        void,

    pub fn deinit(self: *Command) void {
        switch (self.*) {
            .xtgettcap => |*v| v.data.deinit(),
            .decrqss => {},
            .tmux => {},
        }
    }

    pub const XTGETTCAP = struct {
        data: std.Io.Writer.Allocating,
        i: usize = 0,

        pub const encoded_key_name = &std.fmt.bytesToHex("TN", .upper);

        pub const name_response: [:0]const u8 = response: {
            const map = terminfo.ghostty.xtgettcapMap();
            break :response map.get(encoded_key_name).?;
        };

        pub const Response = union(enum) {
            static: [:0]const u8,

            /// The "TN" capability: the reply must match the caller's TERM,
            /// so only the caller can produce it. Encode it with
            /// `encodeName`, or use `name_response` if TERM is Ghostty's
            /// own entry.
            name,
        };

        /// Returns the reply for the next requested capability, skipping
        /// any keys we have no capability for. Static replies are valid
        /// for the lifetime of the program.
        pub fn next(self: *XTGETTCAP) ?Response {
            // The keys are uppercased by `unhook` before the command is
            // produced, which matches how the map hex-encodes its keys.
            const map = comptime terminfo.ghostty.xtgettcapMap();
            const items = self.data.written();
            while (self.i < items.len) {
                const rem = items[self.i..];
                const len = std.mem.indexOfScalar(u8, rem, ';') orelse rem.len;
                self.i += len + 1;

                const key = rem[0..len];
                if (std.mem.eql(u8, key, encoded_key_name)) return .name;
                return .{ .static = map.get(key) orelse continue };
            }

            return null;
        }

        pub const max_name_bytes = 128;

        pub const max_name_response_bytes =
            "\x1bP1+r".len + encoded_key_name.len + "=".len +
            (max_name_bytes * 2) + "\x1b\\".len +
            1; // null terminator

        /// Encodes the "TN" reply for the given terminal name. Returns
        /// null for an empty or over-long name, or if the response does
        /// not fit in `buf`.
        pub fn encodeName(name: []const u8, buf: []u8) ?[:0]const u8 {
            if (name.len == 0 or name.len > max_name_bytes) return null;

            var writer: std.Io.Writer = .fixed(buf);
            writer.writeAll("\x1bP1+r" ++ encoded_key_name ++ "=") catch return null;

            // Values are hex-encoded uppercase, matching the static map.
            const charset = "0123456789ABCDEF";
            for (name) |b| {
                writer.writeByte(charset[b >> 4]) catch return null;
                writer.writeByte(charset[b & 0xF]) catch return null;
            }

            writer.writeAll("\x1b\\") catch return null;
            writer.writeByte(0) catch return null;

            const final = writer.buffered();
            return final[0 .. final.len - 1 :0];
        }
    };

    /// Supported DECRQSS settings
    pub const DECRQSS = enum {
        none,
        sgr,
        decscusr,
        decstbm,
        decslrm,

        /// Fixed upper bound for an encoded DECRPSS response. The comptime
        /// calculated max at the time of writing this was around 63 so this
        /// leaves a ton of space for future stuff. We don't do the comptime
        /// calculation cause it complicated the implementation a bit too
        /// much.
        pub const max_response_bytes = 256;

        /// Encode the response for this request.
        pub fn encode(
            self: DECRQSS,
            t: *terminal.Terminal,
            response: []u8,
        ) ![]const u8 {
            var writer: std.Io.Writer = .fixed(response);

            const prefix_fmt = "\x1bP{d}$r";
            const prefix_len = std.fmt.comptimePrint(prefix_fmt, .{0}).len;
            writer.end = prefix_len;

            switch (self) {
                .none => {},
                .sgr => {
                    const buf = try t.printAttributes(writer.buffer[writer.end..]);
                    writer.end += buf.len;
                    try writer.writeByte('m');
                },
                .decscusr => {
                    const blink = t.modes.get(.cursor_blinking);
                    const style: u8 = switch (t.screens.active.cursor.cursor_style) {
                        .block, .block_hollow => if (blink) 1 else 2,
                        .underline => if (blink) 3 else 4,
                        .bar => if (blink) 5 else 6,
                    };
                    try writer.print("{d} q", .{style});
                },
                .decstbm => try writer.print("{d};{d}r", .{
                    t.scrolling_region.top + 1,
                    t.scrolling_region.bottom + 1,
                }),
                .decslrm => if (t.modes.get(.enable_left_and_right_margin)) {
                    try writer.print("{d};{d}s", .{
                        t.scrolling_region.left + 1,
                        t.scrolling_region.right + 1,
                    });
                },
            }

            const valid = writer.end > prefix_len;
            try writer.writeAll("\x1b\\");
            _ = try std.fmt.bufPrint(
                response[0..prefix_len],
                prefix_fmt,
                .{@intFromBool(valid)},
            );
            return writer.buffered();
        }
    };
};

const State = union(enum) {
    /// We're not in a DCS state at the moment.
    inactive,

    /// We're hooked, but its an unknown DCS command or one that went
    /// invalid due to some bad input, so we're ignoring the rest.
    ignore,

    /// XTGETTCAP
    xtgettcap: std.Io.Writer.Allocating,

    /// DECRQSS
    decrqss: struct {
        data: [2]u8 = undefined,
        len: u2 = 0,
    },

    /// Tmux control mode: https://github.com/tmux/tmux/wiki/Control-Mode
    tmux: if (build_options.tmux_control_mode)
        terminal.tmux.ControlParser
    else
        void,

    pub fn deinit(self: *State) void {
        switch (self.*) {
            .inactive,
            .ignore,
            => {},

            .xtgettcap => |*v| v.deinit(),
            .decrqss => {},
            .tmux => |*v| if (comptime build_options.tmux_control_mode) {
                v.deinit();
            } else unreachable,
        }
    }
};

test "unknown DCS command" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    defer h.deinit();
    try testing.expect(h.hook(alloc, .{ .final = 'A' }) == null);
    try testing.expect(h.state == .ignore);
    try testing.expect(h.unhook() == null);
    try testing.expect(h.state == .inactive);
}

fn parseXTGETTCAP(input: []const u8) !Command {
    const testing = std.testing;

    var h: Handler = .{};
    defer h.deinit();
    try testing.expect(h.hook(
        testing.allocator,
        .{ .intermediates = "+", .final = 'q' },
    ) == null);
    for (input) |byte| _ = h.put(byte);

    return h.unhook().?;
}

const smulx_response =
    "\x1bP1+r" ++ std.fmt.bytesToHex("Smulx", .upper) ++ "=" ++
    std.fmt.bytesToHex("\\E[4:%p1%dm", .upper) ++ "\x1b\\";

test "XTGETTCAP command" {
    const testing = std.testing;

    var cmd = try parseXTGETTCAP(&std.fmt.bytesToHex("Smulx", .upper));
    defer cmd.deinit();

    try testing.expect(cmd == .xtgettcap);
    try testing.expectEqualStrings(smulx_response, cmd.xtgettcap.next().?.static);
    try testing.expect(cmd.xtgettcap.next() == null);
}

test "XTGETTCAP mixed case" {
    const testing = std.testing;

    var cmd = try parseXTGETTCAP(&std.fmt.bytesToHex("Smulx", .lower));
    defer cmd.deinit();

    try testing.expect(cmd == .xtgettcap);
    try testing.expectEqualStrings(smulx_response, cmd.xtgettcap.next().?.static);
    try testing.expect(cmd.xtgettcap.next() == null);
}

test "XTGETTCAP command multiple keys" {
    const testing = std.testing;

    const key = std.fmt.bytesToHex("Smulx", .upper);
    var cmd = try parseXTGETTCAP(key ++ ";" ++ key);
    defer cmd.deinit();

    try testing.expect(cmd == .xtgettcap);
    try testing.expectEqualStrings(smulx_response, cmd.xtgettcap.next().?.static);
    try testing.expectEqualStrings(smulx_response, cmd.xtgettcap.next().?.static);
    try testing.expect(cmd.xtgettcap.next() == null);
}

test "XTGETTCAP command invalid data" {
    const testing = std.testing;

    var cmd = try parseXTGETTCAP(
        "not_hex_encoded;" ++ std.fmt.bytesToHex("Smulx", .upper),
    );
    defer cmd.deinit();

    try testing.expect(cmd == .xtgettcap);
    try testing.expectEqualStrings(smulx_response, cmd.xtgettcap.next().?.static);
    try testing.expect(cmd.xtgettcap.next() == null);
}

test "XTGETTCAP response for a known key" {
    const testing = std.testing;

    var cmd = try parseXTGETTCAP(&std.fmt.bytesToHex("Smulx", .lower));
    defer cmd.deinit();

    try testing.expectEqualStrings(
        smulx_response,
        cmd.xtgettcap.next().?.static,
    );
    try testing.expect(cmd.xtgettcap.next() == null);
}

test "XTGETTCAP response defers the terminal name to the caller" {
    const testing = std.testing;

    var cmd = try parseXTGETTCAP(&std.fmt.bytesToHex("TN", .upper));
    defer cmd.deinit();

    try testing.expect(cmd.xtgettcap.next().? == .name);
    try testing.expect(cmd.xtgettcap.next() == null);
}

test "XTGETTCAP name_response uses Ghostty's own terminfo entry" {
    const testing = std.testing;

    // Derive the name rather than hardcoding it: terminfo/ghostty.zig
    // documents that the primary name is a workaround it intends to change.
    const expected = comptime expected: {
        const hex = std.fmt.bytesToHex(terminfo.ghostty.names[0], .upper);
        break :expected "\x1bP1+r" ++ std.fmt.bytesToHex("TN", .upper) ++
            "=" ++ hex ++ "\x1b\\";
    };
    try testing.expectEqualStrings(
        expected,
        Command.XTGETTCAP.name_response,
    );
}

test "XTGETTCAP encodeName" {
    const testing = std.testing;

    var buf: [Command.XTGETTCAP.max_name_response_bytes]u8 = undefined;
    try testing.expectEqualStrings(
        "\x1bP1+r" ++ std.fmt.bytesToHex("TN", .upper) ++ "=" ++
            std.fmt.bytesToHex("xterm-256color", .upper) ++ "\x1b\\",
        Command.XTGETTCAP.encodeName("xterm-256color", &buf).?,
    );

    try testing.expect(Command.XTGETTCAP.encodeName("", &buf) == null);

    const long: [Command.XTGETTCAP.max_name_bytes + 1]u8 = @splat('a');
    try testing.expect(Command.XTGETTCAP.encodeName(&long, &buf) == null);

    const max: [Command.XTGETTCAP.max_name_bytes]u8 = @splat('a');
    try testing.expect(Command.XTGETTCAP.encodeName(&max, &buf) != null);
}

test "XTGETTCAP response skips keys we have no capability for" {
    const testing = std.testing;

    const input = "not_hex_encoded;" ++
        std.fmt.bytesToHex("unsupported_key", .upper) ++ ";" ++
        std.fmt.bytesToHex("Smulx", .upper);
    var cmd = try parseXTGETTCAP(input);
    defer cmd.deinit();

    try testing.expectEqualStrings(
        smulx_response,
        cmd.xtgettcap.next().?.static,
    );
    try testing.expect(cmd.xtgettcap.next() == null);
}

test "XTGETTCAP response with no known keys" {
    const testing = std.testing;

    const input = "not_hex_encoded;" ++
        std.fmt.bytesToHex("unsupported_key", .upper);
    var cmd = try parseXTGETTCAP(input);
    defer cmd.deinit();

    try testing.expect(cmd.xtgettcap.next() == null);
}

test "DECRQSS command" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    defer h.deinit();
    try testing.expect(h.hook(alloc, .{ .intermediates = "$", .final = 'q' }) == null);
    _ = h.put('m');
    var cmd = h.unhook().?;
    defer cmd.deinit();
    try testing.expect(cmd == .decrqss);
    try testing.expect(cmd.decrqss == .sgr);
}

test "DECRQSS invalid command" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    defer h.deinit();
    try testing.expect(h.hook(alloc, .{ .intermediates = "$", .final = 'q' }) == null);
    _ = h.put('z');
    var cmd = h.unhook().?;
    defer cmd.deinit();
    try testing.expect(cmd == .decrqss);
    try testing.expect(cmd.decrqss == .none);

    h.discard();

    try testing.expect(h.hook(alloc, .{ .intermediates = "$", .final = 'q' }) == null);
    _ = h.put('"');
    _ = h.put(' ');
    _ = h.put('q');
    try testing.expect(h.unhook() == null);
}

test "DECRQSS response encoding" {
    const testing = std.testing;

    var t: terminal.Terminal = try .init(
        testing.io,
        testing.allocator,
        .{ .cols = 80, .rows = 24 },
    );
    defer t.deinit(testing.allocator);

    const S = struct {
        fn expectResponse(
            term: *terminal.Terminal,
            request: Command.DECRQSS,
            expected: []const u8,
        ) !void {
            var buf: [Command.DECRQSS.max_response_bytes]u8 = undefined;
            const encoded = try request.encode(term, &buf);
            try testing.expectEqualStrings(expected, encoded);
        }
    };

    try S.expectResponse(&t, .none, "\x1BP0$r\x1B\\");
    try S.expectResponse(&t, .sgr, "\x1BP1$r0m\x1B\\");

    try t.setAttribute(.bold);
    try t.setAttribute(.{ .underline = .curly });
    try S.expectResponse(&t, .sgr, "\x1BP1$r0;1;4:3m\x1B\\");

    t.setCursorStyle(.steady_underline);
    try S.expectResponse(&t, .decscusr, "\x1BP1$r4 q\x1B\\");

    t.scrolling_region.top = 4;
    t.scrolling_region.bottom = 19;
    try S.expectResponse(&t, .decstbm, "\x1BP1$r5;20r\x1B\\");

    try S.expectResponse(&t, .decslrm, "\x1BP0$r\x1B\\");
    t.modes.set(.enable_left_and_right_margin, true);
    t.scrolling_region.left = 2;
    t.scrolling_region.right = 69;
    try S.expectResponse(&t, .decslrm, "\x1BP1$r3;70s\x1B\\");
}

test "DECRQSS largest response fits fixed buffer" {
    const testing = std.testing;

    var t: terminal.Terminal = try .init(
        testing.io,
        testing.allocator,
        .{ .cols = 80, .rows = 24 },
    );
    defer t.deinit(testing.allocator);

    try t.setAttribute(.bold);
    try t.setAttribute(.faint);
    try t.setAttribute(.italic);
    try t.setAttribute(.{ .underline = .dashed });
    try t.setAttribute(.blink);
    try t.setAttribute(.inverse);
    try t.setAttribute(.invisible);
    try t.setAttribute(.strikethrough);
    try t.setAttribute(.{ .direct_color_fg = .{
        .r = 255,
        .g = 255,
        .b = 255,
    } });
    try t.setAttribute(.{ .direct_color_bg = .{
        .r = 255,
        .g = 255,
        .b = 255,
    } });

    var buf: [Command.DECRQSS.max_response_bytes]u8 = undefined;
    const encoded = try Command.DECRQSS.sgr.encode(&t, &buf);

    const expected =
        "\x1BP1$r0;1;2;3;4:5;5;7;8;9" ++
        ";38:2::255:255:255" ++
        ";48:2::255:255:255m\x1B\\";
    try testing.expectEqualStrings(expected, encoded);
    try testing.expect(encoded.len <= Command.DECRQSS.max_response_bytes);
}

test "tmux enter and implicit exit" {
    if (comptime !build_options.tmux_control_mode) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    defer h.deinit();

    {
        var cmd = h.hook(alloc, .{ .params = &.{1000}, .final = 'p' }).?;
        defer cmd.deinit();
        try testing.expect(cmd == .tmux);
        try testing.expect(cmd.tmux == .enter);
    }

    {
        var cmd = h.unhook().?;
        defer cmd.deinit();
        try testing.expect(cmd == .tmux);
        try testing.expect(cmd.tmux == .exit);
    }
}
