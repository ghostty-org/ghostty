const std = @import("std");
const assert = std.debug.assert;

/// A booid (/ˈbwɪd/, rhymes with "squid") is a Ghostty identifier based
/// loosely on Snowflake-style IDs. Booids are used to uniquely identify
/// Ghostty objects.
///
/// A booid is a 64-bit value with the following structure:
///
///   - 42 bits of millisecond level precision time since Aug 6, 2025 GMT.
///     The epoch is 1754438400.
///   - 10 bits for unique machine ID (1024 possible values).
///   - 12 bit monotonic sequence number (4096 possible values).
///
/// As a result, we can generate approximately 4096 booids per millisecond
/// for a single machine ID and ~4 million booids per millisecond across
/// a fully saturated cluster.
///
/// "Cluster?" Why are we talking about clusters? Ghostty is a local
/// terminal emulator! I'm thinking in advance of when we support tmux-style
/// servers that you can attach to and detach from, which will form a
/// cluster. A 10-bit cluster ID seems excessive, but the other used bits
/// are more than big enough so the 10-bits is mostly leftover. We can
/// partition the 10 bits further if we want to later.
///
/// For now, all Ghostty IDs will use random machine ID on launch. We can
/// address the machine ID issue later when we have servers. My thinking
/// for now is that we actually assign machine IDs client side and remap
/// them for API requests so that we don't need any distributed consensus.
/// This would allow a local machine to be connected to at most 1,023 (one
/// reserved value for local) remote machines, which also seems... unlikely!
///
/// ## Design Considerations
///
/// We chose a 64-bit identifier to keep it simple to transport IDs
/// across various ABIs and protocols easily. A 128-bit identifier (such
/// as a UUID) would require manually unpacking and repacking two 64-bit
/// components since there is no well-defined 128-bit integer type for C ABIs
/// and many popular desktop transport protocols such as D-Bus also don't
/// natively support 128-bit integers.
///
/// Ghostty won't be generating booids at a super high rate. At the time
/// of writing this, booids are going to be used to identify surfaces, and
/// surfaces are only created when a new terminal is launched, which requires
/// creating a pty, launching a process, etc. So the speed and number of booids
/// is naturally limited.
pub const Booid = packed struct(u64) {
    /// Sequence number. This is a monotonic sequence number that starts
    /// at zero per millisecond.j:want
    seq: u12,

    /// Machine ID. This is always zero for the local machine. Ghostty
    /// doesn't currently support saving the ID outside of the local machine
    /// so this is mostly unused. See the notes in the struct doc comment
    /// for how I'm thinking about this.
    machine: u10,

    /// Milliseconds since Aug 6, 2025 GMT (or 1754438400 since Unix epoch).
    timestamp: u42,
};

pub const epoch = 1754438400; // Aug 6, 2025 GMT

/// A booid generator that assumes no local concurrency.
pub const Generator = struct {
    last: Booid,

    /// A local ID generator (machine ID 0).
    pub const local: Generator = .{
        .last = .{
            .timestamp = 0,
            .machine = 0,
            .seq = 0,
        },
    };

    /// Get the next booid from the generator.
    pub fn next(self: *Generator) error{Overflow}!Booid {
        const timestamp = timestamp: {
            const now_unix = std.time.milliTimestamp();
            assert(now_unix >= epoch);
            const now_i64 = now_unix - epoch;
            break :timestamp std.math.cast(u42, now_i64) orelse
                return error.Overflow;
        };

        // If our timestamp changed, we reset our sequence number
        if (timestamp != self.last.timestamp) {
            assert(timestamp > self.last.timestamp);
            const result: Booid = .{
                .timestamp = timestamp,
                .machine = self.last.machine,
                .seq = 0,
            };
            self.last = result;
            return result;
        }

        // Increase our sequence number
        self.last.seq = std.math.add(u12, self.last.seq, 1) catch
            return error.Overflow;
        return self.last;
    }
};

test Generator {
    const testing = std.testing;

    var g: Generator = .local;
    const a = try g.next();
    const b = try g.next();
    try testing.expect(a != b);
    try testing.expect(a.timestamp <= b.timestamp);
    try testing.expect(a.machine == b.machine);
    try testing.expect(a.seq < b.seq);
    try testing.expect(@as(u64, @bitCast(a)) < @as(u64, @bitCast(b)));
}
