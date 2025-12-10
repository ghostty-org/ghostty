const std = @import("std");
const build_options = @import("terminal_options");
const assert = @import("../quirks.zig").inlineAssert;
const LibEnum = @import("../lib/enum.zig").Enum;

/// The available charset slots for a terminal.
pub const Slots = LibEnum(
    if (build_options.c_abi) .c else .zig,
    &.{ "G0", "G1", "G2", "G3" },
);

/// The name of the active slots.
pub const ActiveSlot = LibEnum(
    if (build_options.c_abi) .c else .zig,
    &.{ "GL", "GR" },
);

/// The list of supported character sets and their associated tables.
pub const Charset = LibEnum(
    if (build_options.c_abi) .c else .zig,
    &.{ "utf8", "ascii", "british", "dec_special" },
);

/// The table for the given charset. This returns a pointer to a
/// slice that is guaranteed to be 255 chars that can be used to map
/// ASCII to the given charset.
pub inline fn table(set: Charset) []const u16 {
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

/// Just a basic c => c ascii table
const ascii = initTable();

/// https://vt100.net/docs/vt220-rm/chapter2.html
const british = british: {
    var tbl = initTable();
    tbl[0x23] = 0x00a3;
    break :british tbl;
};

/// https://en.wikipedia.org/wiki/DEC_Special_Graphics
const dec_special = tech: {
    var tbl = initTable();
    tbl[0x60] = 0x25C6;
    tbl[0x61] = 0x2592;
    tbl[0x62] = 0x2409;
    tbl[0x63] = 0x240C;
    tbl[0x64] = 0x240D;
    tbl[0x65] = 0x240A;
    tbl[0x66] = 0x00B0;
    tbl[0x67] = 0x00B1;
    tbl[0x68] = 0x2424;
    tbl[0x69] = 0x240B;
    tbl[0x6a] = 0x2518;
    tbl[0x6b] = 0x2510;
    tbl[0x6c] = 0x250C;
    tbl[0x6d] = 0x2514;
    tbl[0x6e] = 0x253C;
    tbl[0x6f] = 0x23BA;
    tbl[0x70] = 0x23BB;
    tbl[0x71] = 0x2500;
    tbl[0x72] = 0x23BC;
    tbl[0x73] = 0x23BD;
    tbl[0x74] = 0x251C;
    tbl[0x75] = 0x2524;
    tbl[0x76] = 0x2534;
    tbl[0x77] = 0x252C;
    tbl[0x78] = 0x2502;
    tbl[0x79] = 0x2264;
    tbl[0x7a] = 0x2265;
    tbl[0x7b] = 0x03C0;
    tbl[0x7c] = 0x2260;
    tbl[0x7d] = 0x00A3;
    tbl[0x7e] = 0x00B7;
    break :tech tbl;
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
    const info = @typeInfo(Charset).@"enum";
    inline for (info.fields) |field| {
        // utf8 has no table
        if (@field(Charset, field.name) == .utf8) continue;

        const tbl = table(@field(Charset, field.name));

        // Yes, I could use `table_len` here, but I want to explicitly use a
        // hardcoded constant so that if there are miscompilations or a comptime
        // issue, we catch it.
        try testing.expectEqual(@as(usize, 256), tbl.len);
    }
}
