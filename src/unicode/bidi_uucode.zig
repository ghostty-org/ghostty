const bidi_uucode = @This();
const std = @import("std");
const uucode = @import("uucode");
const lut = @import("lut.zig");
const BidiClass = @import("bidi_props.zig").BidiClass;
const BidiPairedBracketType = @import("bidi_props.zig").BidiPairedBracketType;
const BidiProperties = @import("bidi_props.zig").BidiProperties;

/// Errors that can only occur while generating the table, i.e. at build
/// time on the host. They signal that the UCD has grown values our packed
/// encoding can no longer represent, which must fail the build loudly
/// rather than silently truncate.
pub const Error = error{
    BracketDeltaOutOfRange,
    MirrorDeltaOutOfRange,
    MirrorsToItself,
};

pub fn get(cp: u21) Error!BidiProperties {
    // u21 can encode values past the last Unicode codepoint. Those are not
    // characters at all, so there is no meaningful bidi class for them; the
    // `l` default is arbitrary but harmless. This is not the same thing as
    // an *unassigned* codepoint, which does have a well-defined default
    // that uucode derives from the `@missing` lines in DerivedBidiClass.txt.
    if (cp > uucode.config.max_code_point) return .{};

    const mirror_delta: i13 = delta: {
        const glyph = uucode.get(.bidi_mirroring, cp) orelse break :delta 0;

        // Zero is our sentinel for "no mirroring glyph", so a codepoint that
        // mirrors to itself would be indistinguishable from one that does
        // not mirror at all. No such codepoint exists today; if the UCD ever
        // adds one the encoding in `bidi_props.zig` needs to change.
        if (glyph == cp) return Error.MirrorsToItself;

        break :delta std.math.cast(
            i13,
            @as(i32, glyph) - @as(i32, cp),
        ) orelse return Error.MirrorDeltaOutOfRange;
    };

    const bracket: struct { kind: BidiPairedBracketType, cp: u21 } =
        switch (uucode.get(.bidi_paired_bracket, cp)) {
            .open => |v| .{ .kind = .open, .cp = v },
            .close => |v| .{ .kind = .close, .cp = v },
            .none => .{ .kind = .none, .cp = cp },
        };

    const bracket_delta: i3 = if (bracket.kind == .none) 0 else std.math.cast(
        i3,
        @as(i32, bracket.cp) - @as(i32, cp),
    ) orelse return Error.BracketDeltaOutOfRange;

    return .{
        .class = fromUucode(uucode.get(.bidi_class, cp)),
        .bracket = bracket.kind,
        .mirrored = uucode.get(.is_bidi_mirrored, cp),
        .bracket_delta = bracket_delta,
        .mirror_delta = mirror_delta,
    };
}

/// Map uucode's spelled-out Bidi_Class names onto the UAX #9 abbreviations
/// we use. This switch is deliberately exhaustive with no `else` branch so
/// that a uucode upgrade which adds a class fails to compile instead of
/// silently folding the new class into an existing one.
fn fromUucode(class: uucode.types.BidiClass) BidiClass {
    return switch (class) {
        .left_to_right => .l,
        .right_to_left => .r,
        .right_to_left_arabic => .al,

        .european_number => .en,
        .european_number_separator => .es,
        .european_number_terminator => .et,
        .arabic_number => .an,
        .common_number_separator => .cs,
        .nonspacing_mark => .nsm,
        .boundary_neutral => .bn,

        .paragraph_separator => .b,
        .segment_separator => .s,
        .whitespace => .ws,
        .other_neutrals => .on,

        .left_to_right_embedding => .lre,
        .left_to_right_override => .lro,
        .right_to_left_embedding => .rle,
        .right_to_left_override => .rlo,
        .pop_directional_format => .pdf,
        .left_to_right_isolate => .lri,
        .right_to_left_isolate => .rli,
        .first_strong_isolate => .fsi,
        .pop_directional_isolate => .pdi,
    };
}

/// Runnable binary to generate the lookup tables and output to stdout.
pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();

    const gen: lut.Generator(
        BidiProperties,
        struct {
            pub fn get(ctx: @This(), cp: u21) !BidiProperties {
                _ = ctx;
                return bidi_uucode.get(cp);
            }

            pub fn eql(ctx: @This(), a: BidiProperties, b: BidiProperties) bool {
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
    var stdout = std.Io.File.stdout().writer(init.io, &buf);
    try t.writeZig(&stdout.interface);
    // Use flush instead of end because stdout is a pipe when captured by
    // the build system, and pipes cannot be truncated (Windows returns
    // INVALID_PARAMETER, Linux returns EINVAL).
    try stdout.interface.flush();

    // Uncomment when manually debugging to see our table sizes.
    // std.log.warn("stage1={} stage2={} stage3={}", .{
    //     t.stage1.len,
    //     t.stage2.len,
    //     t.stage3.len,
    // });
}

test "unicode bidi: tables match uucode" {
    if (std.valgrind.runningOnValgrind() > 0) return error.SkipZigTest;

    const testing = std.testing;
    const table = @import("bidi_table.zig").table;

    for (0..std.math.maxInt(u21) + 1) |cp| {
        const t = table.get(@intCast(cp));
        const uu = try bidi_uucode.get(@intCast(cp));

        if (!t.eql(uu)) {
            std.log.warn(
                "mismatch cp=U+{x} t={f} uu={f}",
                .{ cp, t, uu },
            );
            try testing.expect(false);
        }
    }
}

test "unicode bidi: paired brackets agree with mirroring glyphs" {
    if (std.valgrind.runningOnValgrind() > 0) return error.SkipZigTest;

    const testing = std.testing;

    // Every paired bracket's Bidi_Paired_Bracket is also its
    // Bidi_Mirroring_Glyph. The UCD maintains this consistency, and rule N0
    // combined with rule L4 relies on it: a bracket pair that mirrored to
    // something other than its pair would render as a mismatched pair. We
    // store the two deltas independently rather than deriving one from the
    // other, so this test is what guards the assumption.
    for (0..uucode.config.max_code_point + 1) |cp| {
        const p = try bidi_uucode.get(@intCast(cp));
        if (p.bracket == .none) continue;

        try testing.expect(p.mirrored);
        try testing.expectEqual(
            p.pairedBracket(@intCast(cp)),
            p.mirroringGlyph(@intCast(cp)),
        );
    }
}
