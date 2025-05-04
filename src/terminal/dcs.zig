const std = @import("std");
const assert = std.debug.assert;
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

    pub fn deinit(self: *Handler) void {
        self.discard();
    }

    pub fn hook(self: *Handler, alloc: Allocator, dcs: DCS) ?Command {
        assert(self.state == .inactive);

        // Initialize our state to ignore in case of error
        self.state = .{ .ignore = {} };

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
                    // Tmux control mode must start with ESC P 1000 p
                    if (dcs.params.len != 1 or dcs.params[0] != 1000) break :tmux null;

                    break :tmux .{
                        .state = .{
                            .tmux = .{
                                .max_bytes = self.max_bytes,
                                .buffer = try std.ArrayList(u8).initCapacity(
                                    alloc,
                                    128, // Arbitrary choice to limit initial reallocs
                                ),
                            },
                        },
                        .command = .{ .tmux = .{ .enter = {} } },
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
                            .xtgettcap = try std.ArrayList(u8).initCapacity(
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
            self.state = .{ .ignore = {} };
            return null;
        };
    }

    fn tryPut(self: *Handler, byte: u8) !?Command {
        switch (self.state) {
            .inactive,
            .ignore,
            => {},

            .tmux => |*tmux| return .{
                .tmux = (try tmux.put(byte)) orelse return null,
            },

            .xtgettcap => |*list| {
                if (list.items.len >= self.max_bytes) {
                    return error.OutOfMemory;
                }

                try list.append(byte);
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
        defer self.state = .{ .inactive = {} };

        return switch (self.state) {
            .inactive,
            .ignore,
            => null,

            .tmux => tmux: {
                self.state.deinit();
                break :tmux .{ .tmux = .{ .exit = {} } };
            },

            .xtgettcap => |list| xtgettcap: {
                for (list.items, 0..) |b, i| {
                    list.items[i] = std.ascii.toUpper(b);
                }
                break :xtgettcap .{ .xtgettcap = .{ .data = list } };
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
        self.state = .{ .inactive = {} };
    }
};

pub const Command = union(enum) {
    /// XTGETTCAP
    xtgettcap: XTGETTCAP,

    /// DECRQSS
    decrqss: DECRQSS,

    /// Tmux control mode
    tmux: terminal.tmux.Notification,

    pub fn deinit(self: Command) void {
        switch (self) {
            .xtgettcap => |*v| v.data.deinit(),
            .decrqss => {},
            .tmux => {},
        }
    }

    pub const XTGETTCAP = struct {
        data: std.ArrayList(u8),
        i: usize = 0,

        /// Returns the next terminfo key being requested and null
        /// when there are no more keys. The returned value is NOT hex-decoded
        /// because we expect to use a comptime lookup table.
        pub fn next(self: *XTGETTCAP) ?[]const u8 {
            if (self.i >= self.data.items.len) return null;

            var rem = self.data.items[self.i..];
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

    /// Tmux control mode
    pub const Tmux = union(enum) {
        enter: void,
        exit: void,
    };
};

const State = union(enum) {
    /// We're not in a DCS state at the moment.
    inactive: void,

    /// We're hooked, but its an unknown DCS command or one that went
    /// invalid due to some bad input, so we're ignoring the rest.
    ignore: void,

    /// XTGETTCAP
    xtgettcap: std.ArrayList(u8),

    /// DECRQSS
    decrqss: struct {
        data: [2]u8 = undefined,
        len: u2 = 0,
    },

    /// Tmux control mode: https://github.com/tmux/tmux/wiki/Control-Mode
    tmux: terminal.tmux.Client,

    pub fn deinit(self: *State) void {
        switch (self.*) {
            .inactive,
            .ignore,
            => {},

            .xtgettcap => |*v| v.deinit(),
            .decrqss => {},
            .tmux => |*v| v.deinit(),
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
