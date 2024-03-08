//! Kitty keyboard protocol support.

const std = @import("std");

/// Stack for the key flags. This implements the push/pop behavior
/// of the CSI > u and CSI < u sequences. We implement the stack as
/// fixed size to avoid heap allocation.
pub const KeyFlagStack = struct {
    const len = 8;

    flags: [len]KeyFlags = .{.{}} ** len,
    idx: u3 = 0,

    /// Return the current stack value
    pub fn current(self: KeyFlagStack) KeyFlags {
        return self.flags[self.idx];
    }

    /// Perform the "set" operation as described in the spec for
    /// the CSI = u sequence.
    pub fn set(
        self: *KeyFlagStack,
        mode: KeySetMode,
        v: KeyFlags,
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
    pub fn push(self: *KeyFlagStack, flags: KeyFlags) void {
        // Overflow and wrap around if we're full, which evicts
        // the oldest entry.
        self.idx +%= 1;
        self.flags[self.idx] = flags;
    }

    /// Pop `n` entries from the stack. This will just wrap around
    /// if `n` is greater than the amount in the stack.
    pub fn pop(self: *KeyFlagStack, n: usize) void {
        // If n is more than our length then we just reset the stack.
        // This also avoids a DoS vector where a malicious client
        // could send a huge number of pop commands to waste cpu.
        if (n >= self.flags.len) {
            self.idx = 0;
            self.flags = .{.{}} ** len;
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
        var stack: KeyFlagStack = .{};
        stack.idx = stack.flags.len - 1;
        stack.idx +%= 1;
        try testing.expect(stack.idx == 0);

        stack.idx = 0;
        stack.idx -%= 1;
        try testing.expect(stack.idx == stack.flags.len - 1);
    }
};

/// The possible flags for the Kitty keyboard protocol.
pub const KeyFlags = packed struct(u5) {
    disambiguate: bool = false,
    report_events: bool = false,
    report_alternates: bool = false,
    report_all: bool = false,
    report_associated: bool = false,

    pub fn int(self: KeyFlags) u5 {
        return @bitCast(self);
    }

    // Its easy to get packed struct ordering wrong so this test checks.
    test {
        const testing = std.testing;

        try testing.expectEqual(
            @as(u5, 0b1),
            (KeyFlags{ .disambiguate = true }).int(),
        );
        try testing.expectEqual(
            @as(u5, 0b10),
            (KeyFlags{ .report_events = true }).int(),
        );
    }
};

/// The possible modes for setting the key flags.
pub const KeySetMode = enum { set, @"or", not };

test "KeyFlagStack: push pop" {
    const testing = std.testing;
    var stack: KeyFlagStack = .{};
    stack.push(.{ .disambiguate = true });
    try testing.expectEqual(
        KeyFlags{ .disambiguate = true },
        stack.current(),
    );

    stack.pop(1);
    try testing.expectEqual(KeyFlags{}, stack.current());
}

test "KeyFlagStack: pop big number" {
    const testing = std.testing;
    var stack: KeyFlagStack = .{};
    stack.pop(100);
    try testing.expectEqual(KeyFlags{}, stack.current());
}

test "KeyFlagStack: set" {
    const testing = std.testing;
    var stack: KeyFlagStack = .{};
    stack.set(.set, .{ .disambiguate = true });
    try testing.expectEqual(
        KeyFlags{ .disambiguate = true },
        stack.current(),
    );

    stack.set(.@"or", .{ .report_events = true });
    try testing.expectEqual(
        KeyFlags{
            .disambiguate = true,
            .report_events = true,
        },
        stack.current(),
    );

    stack.set(.not, .{ .report_events = true });
    try testing.expectEqual(
        KeyFlags{ .disambiguate = true },
        stack.current(),
    );
}
