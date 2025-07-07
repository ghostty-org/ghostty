const std = @import("std");
pub const lut = @import("lut.zig");

const grapheme = @import("grapheme.zig");
const props = @import("props.zig");
pub const table = props.table;
pub const Properties = props.Properties;
pub const graphemeBreak = grapheme.graphemeBreak;
pub const GraphemeBreakState = grapheme.BreakState;

/// Build Ghostty with `zig build -Doptimize=ReleaseFast -Demit-unicode-test`.
///
/// Usage: ./zig-out/bin/unicode-test [width|class|break|all] [old|zg|ziglyph|all]
///
///     width:    this verifies the table codepoint widths match
///     class:    this verifies the table grapheme boundary classes match
///     break:    this will verify the grapheme break implementation. This
///               iterates over billions of codepoints so it is SLOW.
///
///     old:      compare against old implementation
///     zg:       compare against zg
///     ziglyph:  compare against ziglyph
///
/// Note: To disable/enable `old` comparisons, (un)comment sections of these
/// files (search for "old"):
///   * ./main.zig (this file)
///   * ./props.zig
///   * ./grapheme.zig
///   * src/build/GhosttyUnicodeTest.zig
///   * src/build/UnicodeTables.zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    const ziglyph = @import("ziglyph");
    const Graphemes = @import("Graphemes");
    const DisplayWidth = @import("DisplayWidth");

    const testAll = args.len < 2 or std.mem.eql(u8, args[1], "all");
    const compareAll = args.len < 3 or std.mem.eql(u8, args[2], "all");
    const compareOld = compareAll or std.mem.eql(u8, args[2], "old");
    const compareZg = compareAll or std.mem.eql(u8, args[2], "zg");
    const compareZiglyph = compareAll or std.mem.eql(u8, args[2], "ziglyph");

    // Set the min and max to control the test range.
    const min = 0;
    const max = 0x110000;

    if (testAll or std.mem.eql(u8, args[1], "width")) {
        std.log.info("============== testing codepoint width ==============", .{});

        for (min..max) |cp| {
            if (cp % 0x10000 == 0) std.log.info("progress: cp={x}", .{cp});

            const t = table.get(@intCast(cp));

            if (compareOld) {
                const oldT = props.oldTable.get(@intCast(cp));
                if (oldT.width != t.width) {
                    std.log.warn("[old mismatch] cp={x} t={} old={}", .{ cp, t.width, oldT.width });
                }
            }

            if (compareZg) {
                const zg_width = @min(2, @max(0, DisplayWidth.codePointWidth(@intCast(cp))));
                if (t.width != zg_width) {
                    std.log.warn("[zg mismatch] cp={x} t={} zg={}", .{ cp, t.width, zg_width });
                }
            }

            if (compareZiglyph) {
                const ziglyph_width = @min(2, @max(0, DisplayWidth.codePointWidth(@intCast(cp))));
                if (t.width != ziglyph_width) {
                    std.log.warn("[ziglyph mismatch] cp={x} t={} zg={}", .{ cp, t.width, ziglyph_width });
                }
            }
        }
    }

    if (testAll or std.mem.eql(u8, args[1], "class")) {
        std.log.info("============== testing grapheme boundary class ======", .{});

        for (min..max) |cp| {
            if (cp % 0x10000 == 0) std.log.info("progress: cp={x}", .{cp});

            const t = table.get(@intCast(cp));

            if (compareOld) {
                const oldT = props.oldTable.get(@intCast(cp));
                if (oldT.grapheme_boundary_class != t.grapheme_boundary_class) {
                    std.log.warn("[old mismatch] cp={x} t={} old={}", .{ cp, t.grapheme_boundary_class, oldT.grapheme_boundary_class });
                }
            }

            if (compareZg) {
                const gbp = Graphemes.gbp(@intCast(cp));
                const matches = switch (t.grapheme_boundary_class) {
                    .extended_pictographic_base => gbp == .Emoji_Modifier_Base,
                    .emoji_modifier => gbp == .Emoji_Modifier,
                    .extended_pictographic => gbp == .Extended_Pictographic,
                    .L => gbp == .L,
                    .V => gbp == .V,
                    .T => gbp == .T,
                    .LV => gbp == .LV,
                    .LVT => gbp == .LVT,
                    .prepend => gbp == .Prepend,
                    .extend => gbp == .Extend,
                    .zwj => gbp == .ZWJ,
                    .spacing_mark => gbp == .SpacingMark,
                    .regional_indicator => gbp == .Regional_Indicator,
                    .invalid => gbp == .none or gbp == .Control or gbp == .CR or gbp == .LF,
                };

                if (!matches) {
                    std.log.warn("[zg mismatch] cp={x} t={} zg={}", .{ cp, t.grapheme_boundary_class, gbp });
                }
            }

            if (compareZiglyph) {
                const ziglyph_valid = (ziglyph.emoji.isEmojiModifierBase(@intCast(cp)) or
                    ziglyph.emoji.isEmojiModifier(@intCast(cp)) or
                    ziglyph.emoji.isExtendedPictographic(@intCast(cp)) or
                    ziglyph.grapheme_break.isL(@intCast(cp)) or
                    ziglyph.grapheme_break.isV(@intCast(cp)) or
                    ziglyph.grapheme_break.isT(@intCast(cp)) or
                    ziglyph.grapheme_break.isLv(@intCast(cp)) or
                    ziglyph.grapheme_break.isLvt(@intCast(cp)) or
                    ziglyph.grapheme_break.isPrepend(@intCast(cp)) or
                    ziglyph.grapheme_break.isExtend(@intCast(cp)) or
                    ziglyph.grapheme_break.isZwj(@intCast(cp)) or
                    ziglyph.grapheme_break.isSpacingmark(@intCast(cp)) or
                    ziglyph.grapheme_break.isRegionalIndicator(@intCast(cp)));

                const matches = switch (t.grapheme_boundary_class) {
                    .extended_pictographic_base => ziglyph.emoji.isEmojiModifierBase(@intCast(cp)),
                    .emoji_modifier => ziglyph.emoji.isEmojiModifier(@intCast(cp)),
                    .extended_pictographic => ziglyph.emoji.isExtendedPictographic(@intCast(cp)),
                    .L => ziglyph.grapheme_break.isL(@intCast(cp)),
                    .V => ziglyph.grapheme_break.isV(@intCast(cp)),
                    .T => ziglyph.grapheme_break.isT(@intCast(cp)),
                    .LV => ziglyph.grapheme_break.isLv(@intCast(cp)),
                    .LVT => ziglyph.grapheme_break.isLvt(@intCast(cp)),
                    .prepend => ziglyph.grapheme_break.isPrepend(@intCast(cp)),
                    .extend => ziglyph.grapheme_break.isExtend(@intCast(cp)),
                    .zwj => ziglyph.grapheme_break.isZwj(@intCast(cp)),
                    .spacing_mark => ziglyph.grapheme_break.isSpacingmark(@intCast(cp)),
                    .regional_indicator => ziglyph.grapheme_break.isRegionalIndicator(@intCast(cp)),
                    .invalid => !ziglyph_valid,
                };

                if (!matches) {
                    std.log.warn("[ziglyph mismatch] cp={x} t={} ziglyph_valid={}", .{ cp, t.grapheme_boundary_class, ziglyph_valid });
                }
            }
        }
    }

    var state: GraphemeBreakState = .{};
    var old_state: GraphemeBreakState = .{};
    var zg_state: Graphemes.State = .{};
    var ziglyph_state: u3 = 0;

    if (testAll or std.mem.eql(u8, args[1], "break")) {
        std.log.info("============== testing grapheme break ===============", .{});

        for (min..max) |cp1| {
            if (cp1 % 0x100 == 0) std.log.info("progress: cp1={x}", .{cp1});

            if (cp1 == '\r' or cp1 == '\n' or
                Graphemes.gbp(@intCast(cp1)) == .Control) continue;

            for (min..max) |cp2| {
                if (cp2 == '\r' or cp2 == '\n' or
                    Graphemes.gbp(@intCast(cp1)) == .Control) continue;

                const gb = graphemeBreak(@intCast(cp1), @intCast(cp2), &state);

                if (compareOld) {
                    const old_gb = grapheme.oldGraphemeBreak(@intCast(cp1), @intCast(cp2), &old_state);
                    if (gb != old_gb) {
                        std.log.warn("[old mismatch] cp1={x} cp2={x} gb={} old_gb={} state={} old_state={}", .{
                            cp1,
                            cp2,
                            gb,
                            old_gb,
                            state,
                            old_state,
                        });
                    }
                }

                if (compareZg) {
                    const zg_gb = Graphemes.graphemeBreak(@intCast(cp1), @intCast(cp2), &zg_state);
                    if (gb != zg_gb) {
                        std.log.warn("[zg mismatch] cp1={x} cp2={x} gb={} zg_gb={} state={} zg_state={}", .{
                            cp1,
                            cp2,
                            gb,
                            zg_gb,
                            state,
                            zg_state,
                        });
                    }
                }

                if (compareZiglyph) {
                    const ziglyph_gb = ziglyph.graphemeBreak(@intCast(cp1), @intCast(cp2), &ziglyph_state);
                    if (gb != ziglyph_gb) {
                        std.log.warn("[ziglyph mismatch] cp1={x} cp2={x} gb={} ziglyph_gb={} state={} ziglyph_state={}", .{
                            cp1,
                            cp2,
                            gb,
                            ziglyph_gb,
                            state,
                            ziglyph_state,
                        });
                    }
                }
            }
        }
    }
}

pub const std_options: std.Options = .{
    .log_level = .debug,
};
