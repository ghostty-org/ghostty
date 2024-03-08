const std = @import("std");
const assert = std.debug.assert;

/// The available charset slots for a terminal.
pub const Slots = enum(u3) {
    G0 = 0,
    G1 = 1,
    G2 = 2,
    G3 = 3,
};

/// The name of the active slots.
pub const ActiveSlot = enum { GL, GR };

/// The list of supported character sets and their associated tables.
pub const Charset = enum {
    utf8,
    ascii,
    british,
    dec_special,

    /// The table for the given charset. This returns a pointer to a
    /// slice that is guaranteed to be 255 chars that can be used to map
    /// ASCII to the given charset.
    pub fn table(set: Charset) []const u16 {
        return switch (set) {
            .british => &british,
            .dec_special => &dec_special,

            // utf8 is not a table, callers should double-check if the
            // charset is utf8 and NOT use tables.
            .utf8 => unreachable,

            // recommended that callers just map ascii directly but we can
            // support a table
            .ascii => &ascii,
        };
    }
};

/// Just a basic c => c ascii table
const ascii = initTable();

/// https://vt100.net/docs/vt220-rm/chapter2.html
const british = british: {
    var table = initTable();
    table[0x23] = 0x00a3;
    break :british table;
};

/// https://en.wikipedia.org/wiki/DEC_Special_Graphics
const dec_special = tech: {
    var table = initTable();
    table[0x60] = 0x25C6;
    table[0x61] = 0x2592;
    table[0x62] = 0x2409;
    table[0x63] = 0x240C;
    table[0x64] = 0x240D;
    table[0x65] = 0x240A;
    table[0x66] = 0x00B0;
    table[0x67] = 0x00B1;
    table[0x68] = 0x2424;
    table[0x69] = 0x240B;
    table[0x6a] = 0x2518;
    table[0x6b] = 0x2510;
    table[0x6c] = 0x250C;
    table[0x6d] = 0x2514;
    table[0x6e] = 0x253C;
    table[0x6f] = 0x23BA;
    table[0x70] = 0x23BB;
    table[0x71] = 0x2500;
    table[0x72] = 0x23BC;
    table[0x73] = 0x23BD;
    table[0x74] = 0x251C;
    table[0x75] = 0x2524;
    table[0x76] = 0x2534;
    table[0x77] = 0x252C;
    table[0x78] = 0x2502;
    table[0x79] = 0x2264;
    table[0x7a] = 0x2265;
    table[0x7b] = 0x03C0;
    table[0x7c] = 0x2260;
    table[0x7d] = 0x00A3;
    table[0x7e] = 0x00B7;
    break :tech table;
};

/// Our table length is 256 so we can contain all ASCII chars.
const table_len = std.math.maxInt(u8) + 1;

/// Creates a table that maps ASCII to ASCII as a getting started point.
fn initTable() [table_len]u16 {
    var result: [table_len]u16 = undefined;
    var i: usize = 0;
    while (i < table_len) : (i += 1) result[i] = @intCast(i);
    assert(i == table_len);
    return result;
}

test {
    const testing = std.testing;
    const info = @typeInfo(Charset).Enum;
    inline for (info.fields) |field| {
        // utf8 has no table
        if (@field(Charset, field.name) == .utf8) continue;

        const table = @field(Charset, field.name).table();

        // Yes, I could use `table_len` here, but I want to explicitly use a
        // hardcoded constant so that if there are miscompilations or a comptime
        // issue, we catch it.
        try testing.expectEqual(@as(usize, 256), table.len);
    }
}
