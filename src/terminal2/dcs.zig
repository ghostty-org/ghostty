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

    pub fn hook(self: *Handler, alloc: Allocator, dcs: DCS) void {
        assert(self.state == .inactive);
        self.state = if (tryHook(alloc, dcs)) |state_| state: {
            if (state_) |state| break :state state else {
                log.info("unknown DCS hook: {}", .{dcs});
                break :state .{ .ignore = {} };
            }
        } else |err| state: {
            log.info(
                "error initializing DCS hook, will ignore hook err={}",
                .{err},
            );
            break :state .{ .ignore = {} };
        };
    }

    fn tryHook(alloc: Allocator, dcs: DCS) !?State {
        return switch (dcs.intermediates.len) {
            1 => switch (dcs.intermediates[0]) {
                '+' => switch (dcs.final) {
                    // XTGETTCAP
                    // https://github.com/mitchellh/ghostty/issues/517
                    'q' => .{
                        .xtgettcap = try std.ArrayList(u8).initCapacity(
                            alloc,
                            128, // Arbitrary choice
                        ),
                    },

                    else => null,
                },

                '$' => switch (dcs.final) {
                    // DECRQSS
                    'q' => .{
                        .decrqss = .{},
                    },

                    else => null,
                },

                else => null,
            },

            else => null,
        };
    }

    pub fn put(self: *Handler, byte: u8) void {
        self.tryPut(byte) catch |err| {
            // On error we just discard our state and ignore the rest
            log.info("error putting byte into DCS handler err={}", .{err});
            self.discard();
            self.state = .{ .ignore = {} };
        };
    }

    fn tryPut(self: *Handler, byte: u8) !void {
        switch (self.state) {
            .inactive,
            .ignore,
            => {},

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
    }

    pub fn unhook(self: *Handler) ?Command {
        defer self.state = .{ .inactive = {} };
        return switch (self.state) {
            .inactive,
            .ignore,
            => null,

            .xtgettcap => |list| .{ .xtgettcap = .{ .data = list } },

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
        switch (self.state) {
            .inactive,
            .ignore,
            => {},

            .xtgettcap => |*list| list.deinit(),

            .decrqss => {},
        }

        self.state = .{ .inactive = {} };
    }
};

pub const Command = union(enum) {
    /// XTGETTCAP
    xtgettcap: XTGETTCAP,

    /// DECRQSS
    decrqss: DECRQSS,

    pub fn deinit(self: Command) void {
        switch (self) {
            .xtgettcap => |*v| {
                v.data.deinit();
            },
            .decrqss => {},
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
};

test "unknown DCS command" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    defer h.deinit();
    h.hook(alloc, .{ .final = 'A' });
    try testing.expect(h.state == .ignore);
    try testing.expect(h.unhook() == null);
    try testing.expect(h.state == .inactive);
}

test "XTGETTCAP command" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    defer h.deinit();
    h.hook(alloc, .{ .intermediates = "+", .final = 'q' });
    for ("536D756C78") |byte| h.put(byte);
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
    h.hook(alloc, .{ .intermediates = "+", .final = 'q' });
    for ("536D756C78;536D756C78") |byte| h.put(byte);
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
    h.hook(alloc, .{ .intermediates = "+", .final = 'q' });
    for ("who;536D756C78") |byte| h.put(byte);
    var cmd = h.unhook().?;
    defer cmd.deinit();
    try testing.expect(cmd == .xtgettcap);
    try testing.expectEqualStrings("who", cmd.xtgettcap.next().?);
    try testing.expectEqualStrings("536D756C78", cmd.xtgettcap.next().?);
    try testing.expect(cmd.xtgettcap.next() == null);
}

test "DECRQSS command" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    defer h.deinit();
    h.hook(alloc, .{ .intermediates = "$", .final = 'q' });
    h.put('m');
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
    h.hook(alloc, .{ .intermediates = "$", .final = 'q' });
    h.put('z');
    var cmd = h.unhook().?;
    defer cmd.deinit();
    try testing.expect(cmd == .decrqss);
    try testing.expect(cmd.decrqss == .none);

    h.discard();

    h.hook(alloc, .{ .intermediates = "$", .final = 'q' });
    h.put('"');
    h.put(' ');
    h.put('q');
    try testing.expect(h.unhook() == null);
}
