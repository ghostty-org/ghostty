const std = @import("std");
const build_options = @import("terminal_options");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const terminal = @import("main.zig");
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

    /// Tracks whether we received an ESC byte that could be the start
    /// of a 7-bit ST (ESC \). Because ESC is now forwarded as .put in
    /// dcs_passthrough (to prevent premature DCS termination from ESC
    /// bytes embedded in tmux control mode output), we must detect
    /// 7-bit ST ourselves.
    pending_esc: bool = false,

    pub fn deinit(self: *Handler) void {
        self.discard();
    }

    pub fn hook(self: *Handler, alloc: Allocator, dcs: DCS) ?Command {
        assert(self.state == .inactive);

        // Initialize our state to ignore in case of error
        self.state = .ignore;
        self.pending_esc = false;

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
        // Handle 7-bit ST detection. Because ESC (0x1B) is now forwarded
        // as .put in dcs_passthrough (rather than triggering a state
        // transition to .escape), we must detect the ESC + '\' sequence
        // that forms 7-bit ST ourselves.
        if (self.pending_esc) {
            self.pending_esc = false;
            if (byte == 0x5C) {
                // ESC \ = 7-bit ST → terminate DCS, same as unhook()
                return self.unhook();
            }

            // Not ST: forward the stored ESC to the sub-handler first,
            // then fall through to handle the current byte normally.
            if (self.forwardPut(0x1B)) |cmd| return cmd;
            return self.forwardPut(byte);
        }

        if (byte == 0x1B) {
            self.pending_esc = true;
            return null;
        }

        return self.forwardPut(byte);
    }

    /// Forward a byte to the appropriate sub-handler.
    fn forwardPut(self: *Handler, byte: u8) ?Command {
        return self.tryPut(byte) catch |err| {
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
        self.pending_esc = false;
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
        self.pending_esc = false;
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

        /// Returns the next terminfo key being requested and null
        /// when there are no more keys. The returned value is NOT hex-decoded
        /// because we expect to use a comptime lookup table.
        pub fn next(self: *XTGETTCAP) ?[]const u8 {
            const items = self.data.written();
            if (self.i >= items.len) return null;
            var rem = items[self.i..];
            const idx = std.mem.indexOf(u8, rem, ";") orelse rem.len;

            // Note that if we're at the end, idx + 1 is len + 1 so we're over
            // the end but that's okay because our check above is >= so we'll
            // never read.
            self.i += idx + 1;

            return rem[0..idx];
        }
    };

    /// Supported DECRQSS settings
    pub const DECRQSS = enum {
        none,
        sgr,
        decscusr,
        decstbm,
        decslrm,
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

test "XTGETTCAP command" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    defer h.deinit();
    try testing.expect(h.hook(alloc, .{ .intermediates = "+", .final = 'q' }) == null);
    for ("536D756C78") |byte| _ = h.put(byte);
    var cmd = h.unhook().?;
    defer cmd.deinit();
    try testing.expect(cmd == .xtgettcap);
    try testing.expectEqualStrings("536D756C78", cmd.xtgettcap.next().?);
    try testing.expect(cmd.xtgettcap.next() == null);
}

test "XTGETTCAP mixed case" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    defer h.deinit();
    try testing.expect(h.hook(alloc, .{ .intermediates = "+", .final = 'q' }) == null);
    for ("536d756C78") |byte| _ = h.put(byte);
    var cmd = h.unhook().?;
    defer cmd.deinit();
    try testing.expect(cmd == .xtgettcap);
    try testing.expectEqualStrings("536D756C78", cmd.xtgettcap.next().?);
    try testing.expect(cmd.xtgettcap.next() == null);
}

test "XTGETTCAP command multiple keys" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    defer h.deinit();
    try testing.expect(h.hook(alloc, .{ .intermediates = "+", .final = 'q' }) == null);
    for ("536D756C78;536D756C78") |byte| _ = h.put(byte);
    var cmd = h.unhook().?;
    defer cmd.deinit();
    try testing.expect(cmd == .xtgettcap);
    try testing.expectEqualStrings("536D756C78", cmd.xtgettcap.next().?);
    try testing.expectEqualStrings("536D756C78", cmd.xtgettcap.next().?);
    try testing.expect(cmd.xtgettcap.next() == null);
}

test "XTGETTCAP command invalid data" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    defer h.deinit();
    try testing.expect(h.hook(alloc, .{ .intermediates = "+", .final = 'q' }) == null);
    for ("who;536D756C78") |byte| _ = h.put(byte);
    var cmd = h.unhook().?;
    defer cmd.deinit();
    try testing.expect(cmd == .xtgettcap);
    try testing.expectEqualStrings("WHO", cmd.xtgettcap.next().?);
    try testing.expectEqualStrings("536D756C78", cmd.xtgettcap.next().?);
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

test "7-bit ST (ESC \\) terminates DCS via put" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Use XTGETTCAP as a simple DCS to test with
    var h: Handler = .{};
    defer h.deinit();
    try testing.expect(h.hook(alloc, .{ .intermediates = "+", .final = 'q' }) == null);

    // Put some data
    for ("536D756C78") |byte| _ = h.put(byte);

    // Now send ESC \ (7-bit ST)
    try testing.expect(h.put(0x1B) == null); // ESC buffered
    var cmd = h.put(0x5C).?; // '\' completes ST → unhook
    defer cmd.deinit();
    try testing.expect(cmd == .xtgettcap);
    try testing.expectEqualStrings("536D756C78", cmd.xtgettcap.next().?);
    try testing.expect(cmd.xtgettcap.next() == null);

    // Handler should be inactive after ST
    try testing.expect(h.state == .inactive);
    try testing.expect(h.pending_esc == false);
}

test "ESC followed by non-backslash is forwarded" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Use XTGETTCAP as a simple DCS to test with
    var h: Handler = .{};
    defer h.deinit();
    try testing.expect(h.hook(alloc, .{ .intermediates = "+", .final = 'q' }) == null);

    // Put some data
    for ("AB") |byte| _ = h.put(byte);

    // Send ESC followed by '[' (not ST — this is CSI start)
    try testing.expect(h.put(0x1B) == null); // ESC buffered
    try testing.expect(h.put('[') == null); // Not ST, both bytes forwarded

    // The ESC and '[' should be in the buffer
    var cmd = h.unhook().?;
    defer cmd.deinit();
    try testing.expect(cmd == .xtgettcap);
    // Buffer should contain: "AB" + ESC + "["
    try testing.expectEqualStrings("AB\x1b[", cmd.xtgettcap.next().?);
}

test "tmux: ESC in block content does not cause exit" {
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

    // Simulate tmux sending a %begin block with embedded ESC sequences
    // (like capture-pane -e output with SGR codes)
    const block_with_esc =
        "%begin 1234 1 0\n" ++
        "\x1b[32mhello\x1b[0m\n" ++ // SGR green + reset
        "%end 1234 1 0\n";

    var got_block_end = false;
    for (block_with_esc) |byte| {
        if (h.put(byte)) |cmd| {
            // We should get a tmux block_end notification, NOT an exit
            try testing.expect(cmd == .tmux);
            switch (cmd.tmux) {
                .exit => return error.TestUnexpectedResult,
                .block_end => {
                    got_block_end = true;
                },
                else => {},
            }
        }
    }

    // We should still be in tmux state (not exited)
    try testing.expect(h.state == .tmux);
    try testing.expect(got_block_end);
}

test "tmux: 7-bit ST exits tmux control mode" {
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

    // Send ESC \ (7-bit ST) to terminate tmux control mode
    try testing.expect(h.put(0x1B) == null);
    var cmd = h.put(0x5C).?;
    defer cmd.deinit();
    try testing.expect(cmd == .tmux);
    try testing.expect(cmd.tmux == .exit);
    try testing.expect(h.state == .inactive);
}

test "pending_esc is cleared on hook" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    defer h.deinit();

    // Manually set pending_esc (simulating leftover state)
    h.pending_esc = true;

    // Hook into XTGETTCAP — hook should clear pending_esc
    try testing.expect(h.hook(alloc, .{ .intermediates = "+", .final = 'q' }) == null);
    try testing.expect(h.pending_esc == false);

    // Clean up: unhook so deinit doesn't leak
    var cmd = h.unhook().?;
    cmd.deinit();
}
