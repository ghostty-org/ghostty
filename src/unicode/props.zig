const props = @This();
const std = @import("std");
const assert = std.debug.assert;
const uucode = @import("uucode");
const lut = @import("lut.zig");

/// The lookup tables for Ghostty.
pub const table = table: {
    // This is only available after running main() below as part of the Ghostty
    // build.zig, but due to Zig's lazy analysis we can still reference it here.
    const generated = @import("unicode_tables").Tables(Properties);
    const Tables = lut.Tables(Properties);
    break :table Tables{
        .stage1 = &generated.stage1,
        .stage2 = &generated.stage2,
        .stage3 = &generated.stage3,
    };
};

/// Property set per codepoint that Ghostty cares about.
///
/// Adding to this lets you find new properties but also potentially makes
/// our lookup tables less efficient. Any changes to this should run the
/// benchmarks in src/bench to verify that we haven't regressed.
pub const Properties = struct {
    /// Codepoint width. We clamp to [0, 2] since Ghostty handles control
    /// characters and we max out at 2 for wide characters (i.e. 3-em dash
    /// becomes a 2-em dash).
    width: u2 = 0,

    /// Grapheme boundary class.
    grapheme_boundary_class: GraphemeBoundaryClass = .invalid,

    // Needed for lut.Generator
    pub fn eql(a: Properties, b: Properties) bool {
        return a.width == b.width and
            a.grapheme_boundary_class == b.grapheme_boundary_class;
    }

    // Needed for lut.Generator
    pub fn format(
        self: Properties,
        comptime layout: []const u8,
        opts: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = layout;
        _ = opts;
        try std.fmt.format(writer,
            \\.{{
            \\    .width= {},
            \\    .grapheme_boundary_class= .{s},
            \\}}
        , .{
            self.width,
            @tagName(self.grapheme_boundary_class),
        });
    }
};

/// Possible grapheme boundary classes. This isn't an exhaustive list:
/// we omit control, CR, LF, etc. because in Ghostty's usage that are
/// impossible because they're handled by the terminal.
pub const GraphemeBoundaryClass = enum(u4) {
    invalid,
    L,
    V,
    T,
    LV,
    LVT,
    prepend,
    extend,
    zwj,
    spacing_mark,
    regional_indicator,
    extended_pictographic,
    extended_pictographic_base, // \p{Extended_Pictographic} & \p{Emoji_Modifier_Base}
    emoji_modifier, // \p{Emoji_Modifier}

    /// Gets the grapheme boundary class for a codepoint.
    /// The use case for this is only in generating lookup tables.
    pub fn init(cp: u21) GraphemeBoundaryClass {
        if (cp > uucode.config.max_code_point) return .invalid;
        if (uucode.get(.is_emoji_modifier, cp)) return .emoji_modifier;
        if (uucode.get(.is_emoji_modifier_base, cp)) return .extended_pictographic_base;

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

            .zwnj,
            .indic_conjunct_break_extend,
            .indic_conjunct_break_linker,
            => .extend,

            // This is obviously not INVALID invalid, there is SOME grapheme
            // boundary class for every codepoint. But we don't care about
            // anything that doesn't fit into the above categories.
            .other,
            .indic_conjunct_break_consonant,
            .cr,
            .lf,
            .control,
            => .invalid,
        };
    }

    /// Returns true if this is an extended pictographic type. This
    /// should be used instead of comparing the enum value directly
    /// because we classify multiple.
    pub fn isExtendedPictographic(self: GraphemeBoundaryClass) bool {
        return switch (self) {
            .extended_pictographic,
            .extended_pictographic_base,
            => true,

            else => false,
        };
    }
};

pub fn get(cp: u21) Properties {
    const width = if (cp > uucode.config.max_code_point)
        1
    else
        uucode.get(.width, cp);

    return .{
        .width = width,
        .grapheme_boundary_class = .init(cp),
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
    try t.writeZig(std.io.getStdOut().writer());

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

test "unicode props: tables match ziglyph" {
    if (std.valgrind.runningOnValgrind() > 0) return error.SkipZigTest;

    const ziglyph = @import("ziglyph");
    const testing = std.testing;

    const min = 0xFF + 1; // start outside ascii
    const max = std.math.maxInt(u21) + 1;
    for (min..max) |cp| {
        const t = table.get(@intCast(cp));
        const zg = @min(2, @max(0, ziglyph.display_width.codePointWidth(@intCast(cp), .half)));
        if (t.width != zg) {

            // Known exceptions
            if (cp == 0x0897) continue; // non-spacing mark (t = 0)
            if (cp == 0x2065) continue; // unassigned (t = 1)
            if (cp >= 0x2630 and cp <= 0x2637) continue; // east asian width is wide (t = 2)
            if (cp >= 0x268A and cp <= 0x268F) continue; // east asian width is wide (t = 2)
            if (cp >= 0x2FFC and cp <= 0x2FFF) continue; // east asian width is wide (t = 2)
            if (cp == 0x31E4 or cp == 0x31E5) continue; // east asian width is wide (t = 2)
            if (cp == 0x31EF) continue; // east asian width is wide (t = 2)
            if (cp >= 0x4DC0 and cp <= 0x4DFF) continue; // east asian width is wide (t = 2)
            if (cp >= 0xFFF0 and cp <= 0xFFF8) continue; // unassigned (t = 1)
            if (cp >= 0xFFF0 and cp <= 0xFFF8) continue; // unassigned (t = 1)
            if (cp >= 0x10D69 and cp <= 0x10D6D) continue; // non-spacing mark, despite being east asian width normal (t = 0)
            if (cp >= 0x10EFC and cp <= 0x10EFF) continue; // non-spacing mark, despite being east asian width normal (t = 0)
            if (cp >= 0x113BB and cp <= 0x113C0) continue; // non-spacing mark, despite being east asian width normal (t = 0)
            if (cp == 0x113CE) continue; // non-spacing mark, despite being east asian width normal (t = 0)
            if (cp == 0x113D0) continue; // non-spacing mark, despite being east asian width normal (t = 0)
            if (cp == 0x113D2) continue; // non-spacing mark, despite being east asian width normal (t = 0)
            if (cp == 0x113E1) continue; // non-spacing mark, despite being east asian width normal (t = 0)
            if (cp == 0x113E2) continue; // non-spacing mark, despite being east asian width normal (t = 0)
            if (cp == 0x1171E) continue; // mark spacing combining (t = 1)
            if (cp == 0x11F5A) continue; // non-spacing mark, despite being east asian width normal (t = 0)
            if (cp == 0x1611E) continue; // non-spacing mark, despite being east asian width normal (t = 0)
            if (cp == 0x1611F) continue; // non-spacing mark, despite being east asian width normal (t = 0)
            if (cp >= 0x16120 and cp <= 0x1612F) continue; // non-spacing mark, despite being east asian width normal (t = 0)
            if (cp >= 0xE0000 and cp <= 0xE0FFF) continue; // ziglyph ignores these with 0, but many are unassigned (t = 1)
            if (cp == 0x18CFF) continue; // east asian width is wide (t = 2)
            if (cp >= 0x1D300 and cp <= 0x1D376) continue; // east asian width is wide (t = 2)
            if (cp == 0x1E5EE) continue; // non-spacing mark, despite being east asian width normal (t = 0)
            if (cp == 0x1E5EF) continue; // non-spacing mark, despite being east asian width normal (t = 0)
            if (cp == 0x1FA89) continue; // east asian width is wide (t = 2)
            if (cp == 0x1FA8F) continue; // east asian width is wide (t = 2)
            if (cp == 0x1FABE) continue; // east asian width is wide (t = 2)
            if (cp == 0x1FAC6) continue; // east asian width is wide (t = 2)
            if (cp == 0x1FADC) continue; // east asian width is wide (t = 2)
            if (cp == 0x1FADF) continue; // east asian width is wide (t = 2)
            if (cp == 0x1FAE9) continue; // east asian width is wide (t = 2)

            std.log.warn("mismatch cp=U+{x} t={} zg={}", .{ cp, t.width, zg });
            try testing.expect(false);
        }
    }
}
