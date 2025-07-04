const props = @This();
const std = @import("std");
const assert = std.debug.assert;
const Graphemes = @import("Graphemes");
const DisplayWidth = @import("DisplayWidth");
const lut = @import("lut.zig");

graphemes: Graphemes,
display_width: DisplayWidth,

// Public only for unicode-test
pub fn init(alloc: std.mem.Allocator) !props {
    const graphemes = try Graphemes.init(alloc);
    return .{
        .graphemes = graphemes,
        .display_width = try DisplayWidth.initWithGraphemes(alloc, graphemes),
    };
}

// Public only for unicode-test
pub fn deinit(self: *props, alloc: std.mem.Allocator) void {
    self.graphemes.deinit(alloc);
    self.display_width.deinit(alloc);
}

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

    /// Gets the grapheme boundary class for a codepoint. This is VERY
    /// SLOW. The use case for this is only in generating lookup tables.
    pub fn init(ctx: props, cp: u21) GraphemeBoundaryClass {
        return switch (Graphemes.gbp(ctx.graphemes, cp)) {
            .Emoji_Modifier_Base => .extended_pictographic_base,
            .Emoji_Modifier => .emoji_modifier,
            .Extended_Pictographic => .extended_pictographic,
            .L => .L,
            .V => .V,
            .T => .T,
            .LV => .LV,
            .LVT => .LVT,
            .Prepend => .prepend,
            .Extend => .extend,
            .ZWJ => .zwj,
            .SpacingMark => .spacing_mark,
            .Regional_Indicator => .regional_indicator,
            // This is obviously not INVALID invalid, there is SOME grapheme
            // boundary class for every codepoint. But we don't care about
            // anything that doesn't fit into the above categories.
            .none, .Control, .CR, .LF => .invalid,
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

pub fn get(ctx: props, cp: u21) !Properties {
    if (cp > 0x10FFFF) {
        return .{
            .width = 0,
            .grapheme_boundary_class = .invalid,
        };
    } else {
        const zg_width = DisplayWidth.codePointWidth(ctx.display_width, cp);

        return .{
            .width = @intCast(@min(2, @max(0, zg_width))),
            .grapheme_boundary_class = .init(ctx, cp),
        };
    }
}

pub fn eql(ctx: props, a: Properties, b: Properties) bool {
    _ = ctx;
    return a.eql(b);
}

/// Runnable binary to generate the lookup tables and output to stdout.
pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var self = try init(alloc);
    defer self.deinit(alloc);

    const gen: lut.Generator(
        Properties,
        props,
    ) = .{ .ctx = self };

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
