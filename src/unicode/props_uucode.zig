const props = @This();
const std = @import("std");
const assert = std.debug.assert;
const uucode = @import("uucode");
const lut = @import("lut.zig");
const Properties = @import("props.zig").Properties;
const GraphemeBoundaryClass = @import("props.zig").GraphemeBoundaryClass;

/// Gets the grapheme boundary class for a codepoint.
/// The use case for this is only in generating lookup tables.
fn graphemeBoundaryClass(cp: u21) GraphemeBoundaryClass {
    if (cp > uucode.config.max_code_point) return .invalid;

    return switch (uucode.get(.grapheme_break, cp)) {
        .extended_pictographic => .extended_pictographic,
        .l => .L,
        .v => .V,
        .t => .T,
        .lv => .LV,
        .lvt => .LVT,
        .prepend => .prepend,
        .zwj => .zwj,
        .spacing_mark => .spacing_mark,
        .regional_indicator => .regional_indicator,
        .emoji_modifier => .emoji_modifier,
        .emoji_modifier_base => .extended_pictographic_base,

        .zwnj,
        .indic_conjunct_break_extend,
        .indic_conjunct_break_linker,
        => .extend,

        // This is obviously not INVALID invalid, there is SOME grapheme
        // boundary class for every codepoint. But we don't care about
        // anything that doesn't fit into the above categories. Also note
        // that `indic_conjunct_break_consonant` is `other` in
        // 'GraphemeBreakProperty.txt' (it's missing).
        .other,
        .indic_conjunct_break_consonant,
        .cr,
        .lf,
        .control,
        => .invalid,
    };
}

pub fn get(cp: u21) Properties {
    if (cp > uucode.config.max_code_point) return .{
        .width = 1,
        .grapheme_boundary_class = .invalid,
        .emoji_vs_base = false,
    };

    return .{
        .width = uucode.get(.width, cp),
        .grapheme_boundary_class = graphemeBoundaryClass(cp),
        .emoji_vs_base = uucode.get(.is_emoji_vs_base, cp),
    };
}

/// Runnable binary to generate the lookup tables and output to stdout.
pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const gen: lut.Generator(
        Properties,
        struct {
            pub fn get(ctx: @This(), cp: u21) !Properties {
                _ = ctx;
                return props.get(cp);
            }

            pub fn eql(ctx: @This(), a: Properties, b: Properties) bool {
                _ = ctx;
                return a.eql(b);
            }
        },
    ) = .{};

    const t = try gen.generate(alloc);
    defer alloc.free(t.stage1);
    defer alloc.free(t.stage2);
    defer alloc.free(t.stage3);

    var buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&buf);
    try t.writeZig(&stdout.interface);
    try stdout.end();

    // Uncomment when manually debugging to see our table sizes.
    // std.log.warn("stage1={} stage2={} stage3={}", .{
    //     t.stage1.len,
    //     t.stage2.len,
    //     t.stage3.len,
    // });
}

test "unicode props: tables match uucode" {
    if (std.valgrind.runningOnValgrind() > 0) return error.SkipZigTest;

    const testing = std.testing;
    const table = @import("props_table.zig").table;

    const min = 0xFF + 1; // start outside ascii
    const max = std.math.maxInt(u21) + 1;
    for (min..max) |cp| {
        const t = table.get(@intCast(cp));
        const uu = if (cp > uucode.config.max_code_point)
            1
        else
            uucode.get(.width, @intCast(cp));
        if (t.width != uu) {
            std.log.warn("mismatch cp=U+{x} t={} uu={}", .{ cp, t.width, uu });
            try testing.expect(false);
        }
    }
}
