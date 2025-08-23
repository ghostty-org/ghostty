const props = @This();

const std = @import("std");
const assert = std.debug.assert;
const ziglyph = @import("ziglyph");
const lut = @import("lut.zig");
const Properties = @import("Properties.zig");
const GraphemeBoundaryClass = Properties.GraphemeBoundaryClass;

/// Gets the grapheme boundary class for a codepoint. This is VERY
/// SLOW. The use case for this is only in generating lookup tables.
fn graphemeBoundaryClass(cp: u21) GraphemeBoundaryClass {
    // We special-case modifier bases because we should not break
    // if a modifier isn't next to a base.
    if (ziglyph.emoji.isEmojiModifierBase(cp)) {
        assert(ziglyph.emoji.isExtendedPictographic(cp));
        return .extended_pictographic_base;
    }

    if (ziglyph.emoji.isEmojiModifier(cp)) return .emoji_modifier;
    if (ziglyph.emoji.isExtendedPictographic(cp)) return .extended_pictographic;
    if (ziglyph.grapheme_break.isL(cp)) return .L;
    if (ziglyph.grapheme_break.isV(cp)) return .V;
    if (ziglyph.grapheme_break.isT(cp)) return .T;
    if (ziglyph.grapheme_break.isLv(cp)) return .LV;
    if (ziglyph.grapheme_break.isLvt(cp)) return .LVT;
    if (ziglyph.grapheme_break.isPrepend(cp)) return .prepend;
    if (ziglyph.grapheme_break.isExtend(cp)) return .extend;
    if (ziglyph.grapheme_break.isZwj(cp)) return .zwj;
    if (ziglyph.grapheme_break.isSpacingmark(cp)) return .spacing_mark;
    if (ziglyph.grapheme_break.isRegionalIndicator(cp)) return .regional_indicator;

    // This is obviously not INVALID invalid, there is SOME grapheme
    // boundary class for every codepoint. But we don't care about
    // anything that doesn't fit into the above categories.
    return .invalid;
}

pub fn get(cp: u21) Properties {
    const zg_width = ziglyph.display_width.codePointWidth(cp, .half);
    return .{
        .width = @intCast(@min(2, @max(0, zg_width))),
        .grapheme_boundary_class = graphemeBoundaryClass(cp),
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
// IMPORTANT: UNCOMMENT THIS WHENEVER MAKING CODEPOINTWIDTH CHANGES.
// test "unicode props: tables match ziglyph" {
//     const testing = std.testing;
//
//     const min = 0xFF + 1; // start outside ascii
//     for (min..std.math.maxInt(u21)) |cp| {
//         const t = table.get(@intCast(cp));
//         const zg = @min(2, @max(0, ziglyph.display_width.codePointWidth(@intCast(cp), .half)));
//         if (t.width != zg) {
//             std.log.warn("mismatch cp=U+{x} t={} zg={}", .{ cp, t, zg });
//             try testing.expect(false);
//         }
//     }
// }
