//! Kitty keyboard protocol support.

const std = @import("std");

/// Stack for the key flags. This implements the push/pop behavior
/// of the CSI > u and CSI < u sequences. We implement the stack as
/// fixed size to avoid heap allocation.
pub const FlagStack = struct {
    const len = 8;

    flags: [len]Flags = @splat(.{}),
    idx: u3 = 0,

    /// Return the current stack value
    pub fn current(self: FlagStack) Flags {
        return self.flags[self.idx];
    }

    /// Perform the "set" operation as described in the spec for
    /// the CSI = u sequence.
    pub fn set(
        self: *FlagStack,
        mode: SetMode,
        v: Flags,
    ) void {
        switch (mode) {
            .set => self.flags[self.idx] = v,
            .@"or" => self.flags[self.idx] = @bitCast(
                self.flags[self.idx].int() | v.int(),
            ),
            .not => self.flags[self.idx] = @bitCast(
                self.flags[self.idx].int() & ~v.int(),
            ),
        }
    }

    /// Push a new set of flags onto the stack. If the stack is full
    /// then the oldest entry is evicted.
    pub fn push(self: *FlagStack, flags: Flags) void {
        // Overflow and wrap around if we're full, which evicts
        // the oldest entry.
        self.idx +%= 1;
        self.flags[self.idx] = flags;
    }

    /// Pop `n` entries from the stack. This will just wrap around
    /// if `n` is greater than the amount in the stack.
    pub fn pop(self: *FlagStack, n: usize) void {
        // If n is more than our length then we just reset the stack.
        // This also avoids a DoS vector where a malicious client
        // could send a huge number of pop commands to waste cpu.
        if (n >= self.flags.len) {
            self.idx = 0;
            self.flags = @splat(.{});
            return;
        }

        for (0..n) |_| {
            self.flags[self.idx] = .{};
            self.idx -%= 1;
        }
    }

    // Make sure we the overflow works as expected
    test {
        const testing = std.testing;
        var stack: FlagStack = .{};
        stack.idx = stack.flags.len - 1;
        stack.idx +%= 1;
        try testing.expect(stack.idx == 0);

        stack.idx = 0;
        stack.idx -%= 1;
        try testing.expect(stack.idx == stack.flags.len - 1);
    }
};

/// The possible flags for the Kitty keyboard protocol.
pub const Flags = packed struct(u5) {
    disambiguate: bool = false,
    report_events: bool = false,
    report_alternates: bool = false,
    report_all: bool = false,
    report_associated: bool = false,

    /// Sets all modes on.
    pub const @"true": Flags = .{
        .disambiguate = true,
        .report_events = true,
        .report_alternates = true,
        .report_all = true,
        .report_associated = true,
    };

    pub fn int(self: Flags) u5 {
        return @bitCast(self);
    }

    // Its easy to get packed struct ordering wrong so this test checks.
    test {
        const testing = std.testing;

        try testing.expectEqual(
            @as(u5, 0b1),
            (Flags{ .disambiguate = true }).int(),
        );
        try testing.expectEqual(
            @as(u5, 0b10),
            (Flags{ .report_events = true }).int(),
        );
    }
};

/// The possible modes for setting the key flags.
pub const SetMode = enum { set, @"or", not };

test "FlagStack: push pop" {
    const testing = std.testing;
    var stack: FlagStack = .{};
    stack.push(.{ .disambiguate = true });
    try testing.expectEqual(
        Flags{ .disambiguate = true },
        stack.current(),
    );

    stack.pop(1);
    try testing.expectEqual(Flags{}, stack.current());
}

test "FlagStack: pop big number" {
    const testing = std.testing;
    var stack: FlagStack = .{};
    stack.pop(100);
    try testing.expectEqual(Flags{}, stack.current());
}

test "FlagStack: set" {
    const testing = std.testing;
    var stack: FlagStack = .{};
    stack.set(.set, .{ .disambiguate = true });
    try testing.expectEqual(
        Flags{ .disambiguate = true },
        stack.current(),
    );

    stack.set(.@"or", .{ .report_events = true });
    try testing.expectEqual(
        Flags{
            .disambiguate = true,
            .report_events = true,
        },
        stack.current(),
    );

    stack.set(.not, .{ .report_events = true });
    try testing.expectEqual(
        Flags{ .disambiguate = true },
        stack.current(),
    );
}
