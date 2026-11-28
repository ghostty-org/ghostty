const std = @import("std");
const uucode = @import("uucode");

pub const BidiClass = uucode.types.BidiClass;
pub const JoiningType = uucode.types.JoiningType;
pub const BidiPairedBracket = uucode.types.BidiPairedBracket;

pub inline fn bidiClass(cp: u21) BidiClass {
    return uucode.get(.bidi_class, cp);
}

pub inline fn pairedBracket(cp: u21) BidiPairedBracket {
    return uucode.get(.bidi_paired_bracket, cp);
}

/// BD16 canonical-equivalence normalization for bracket matching:
/// U+2329/U+232A are normalized to U+3008/U+3009.
pub inline fn normalizeBidiBracketCp(cp: u21) u21 {
    return switch (cp) {
        0x2329 => 0x3008,
        0x232A => 0x3009,
        else => cp,
    };
}

pub inline fn joiningType(cp: u21) JoiningType {
    return uucode.get(.joining_type, cp);
}

pub inline fn isBidiMirrored(cp: u21) bool {
    return uucode.get(.is_bidi_mirrored, cp);
}

pub fn isStrong(class: BidiClass) bool {
    return switch (class) {
        .left_to_right, .right_to_left, .right_to_left_arabic => true,
        else => false,
    };
}

pub fn isRtlStrong(class: BidiClass) bool {
    return switch (class) {
        .right_to_left, .right_to_left_arabic => true,
        else => false,
    };
}

pub fn isNeutral(class: BidiClass) bool {
    return switch (class) {
        .paragraph_separator, .segment_separator, .whitespace, .other_neutrals => true,
        else => false,
    };
}

pub fn isNeutralOrIsolate(class: BidiClass) bool {
    return switch (class) {
        .paragraph_separator,
        .segment_separator,
        .whitespace,
        .other_neutrals,
        .left_to_right_isolate,
        .right_to_left_isolate,
        .first_strong_isolate,
        .pop_directional_isolate,
        => true,
        else => false,
    };
}

pub fn isExplicitOrBn(class: BidiClass) bool {
    return switch (class) {
        .left_to_right_embedding,
        .right_to_left_embedding,
        .left_to_right_override,
        .right_to_left_override,
        .pop_directional_format,
        .boundary_neutral,
        => true,
        else => false,
    };
}

pub fn isIsolateInitiator(class: BidiClass) bool {
    return switch (class) {
        .left_to_right_isolate, .right_to_left_isolate, .first_strong_isolate => true,
        else => false,
    };
}

pub fn isIsolate(class: BidiClass) bool {
    return switch (class) {
        .left_to_right_isolate,
        .right_to_left_isolate,
        .first_strong_isolate,
        .pop_directional_isolate,
        => true,
        else => false,
    };
}

pub fn isRemovedByX9(class: BidiClass) bool {
    return switch (class) {
        .left_to_right_embedding,
        .right_to_left_embedding,
        .left_to_right_override,
        .right_to_left_override,
        .pop_directional_format,
        .boundary_neutral,
        => true,
        else => false,
    };
}

pub fn isBidiControl(cp: u21) bool {
    return switch (cp) {
        0x200E,
        0x200F, // LRM, RLM
        0x061C, // ALM
        0x202A...0x202E, // LRE, RLE, PDF, LRO, RLO
        0x2066...0x2069, // LRI, RLI, FSI, PDI
        => true,
        else => false,
    };
}

test "bidi class lookups" {
    const testing = std.testing;

    try testing.expectEqual(BidiClass.left_to_right, bidiClass('A'));
    try testing.expectEqual(BidiClass.right_to_left, bidiClass(0x05D0)); // Alef
    try testing.expectEqual(BidiClass.right_to_left_arabic, bidiClass(0x0627)); // Arabic Alef
    try testing.expectEqual(BidiClass.european_number, bidiClass('0'));
    try testing.expectEqual(BidiClass.whitespace, bidiClass(' '));
    try testing.expectEqual(BidiClass.other_neutrals, bidiClass('!'));

    try testing.expect(isStrong(.left_to_right));
    try testing.expect(isStrong(.right_to_left));
    try testing.expect(!isStrong(.european_number));

    try testing.expect(isBidiControl(0x200E));
    try testing.expect(isBidiControl(0x2066));
    try testing.expect(!isBidiControl('A'));
}
