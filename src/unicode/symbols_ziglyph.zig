const props = @This();
const std = @import("std");
const assert = std.debug.assert;
const ziglyph = @import("ziglyph");
const lut = @import("lut.zig");

/// Returns true of the codepoint is a "symbol-like" character, which
/// for now we define as anything in a private use area and anything
/// in several unicode blocks:
/// - Dingbats
/// - Emoticons
/// - Miscellaneous Symbols
/// - Enclosed Alphanumerics
/// - Enclosed Alphanumeric Supplement
/// - Miscellaneous Symbols and Pictographs
/// - Transport and Map Symbols
///
/// In the future it may be prudent to expand this to encompass more
/// symbol-like characters, and/or exclude some PUA sections.
pub fn isSymbol(cp: u21) bool {
    return ziglyph.general_category.isPrivateUse(cp) or
        ziglyph.blocks.isDingbats(cp) or
        ziglyph.blocks.isEmoticons(cp) or
        ziglyph.blocks.isMiscellaneousSymbols(cp) or
        ziglyph.blocks.isEnclosedAlphanumerics(cp) or
        ziglyph.blocks.isEnclosedAlphanumericSupplement(cp) or
        ziglyph.blocks.isMiscellaneousSymbolsAndPictographs(cp) or
        ziglyph.blocks.isTransportAndMapSymbols(cp);
}

/// Runnable binary to generate the lookup tables and output to stdout.
pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const gen: lut.Generator(
        bool,
        struct {
            pub fn get(ctx: @This(), cp: u21) !bool {
                _ = ctx;
                return isSymbol(cp);
            }

            pub fn eql(ctx: @This(), a: bool, b: bool) bool {
                _ = ctx;
                return a == b;
            }
        },
    ) = .{};

    const t = try gen.generate(alloc);
    defer alloc.free(t.stage1);
    defer alloc.free(t.stage2);
    defer alloc.free(t.stage3);

    var buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&buf);
    const writer = &stdout_writer.interface;

    try t.writeZig(writer);

    // Uncomment when manually debugging to see our table sizes.
    // std.log.warn("stage1={} stage2={} stage3={}", .{
    //     t.stage1.len,
    //     t.stage2.len,
    //     t.stage3.len,
    // });

    try writer.flush();
}

// This is not very fast in debug modes, so its commented by default.
// IMPORTANT: UNCOMMENT THIS WHENEVER MAKING CHANGES.
test "unicode symbols: tables match ziglyph" {
    if (std.valgrind.runningOnValgrind() > 0) return error.SkipZigTest;

    const testing = std.testing;
    const table = @import("symbols_table.zig").table;

    for (0..std.math.maxInt(u21)) |cp| {
        const t = table.get(@intCast(cp));
        const zg = isSymbol(@intCast(cp));

        if (t != zg) {
            std.log.warn("mismatch cp=U+{x} t={} zg={}", .{ cp, t, zg });
            try testing.expect(false);
        }
    }
}
