const std = @import("std");
const getpkg = @import("get.zig");
pub const config = @import("config.zig");
pub const types = @import("types.zig");
pub const ascii = @import("ascii.zig");
pub const grapheme = @import("grapheme.zig");
pub const code_point = @import("code_point.zig");
pub const utf8 = @import("utf8.zig");
pub const x = @import("x/root.zig");
const testing = std.testing;

pub const FieldEnum = getpkg.FieldEnum;
pub const TypeOf = getpkg.TypeOf;
pub const TypeOfAll = getpkg.TypeOfAll;
pub const get = getpkg.get;
pub const getAll = getpkg.getAll;
pub const hasField = getpkg.hasField;

test {
    _ = config;
    _ = ascii;
    _ = grapheme;
    _ = code_point;
    _ = utf8;
    _ = x;
}

test "name" {
    try testing.expect(std.mem.eql(u8, get(.name, 65), "LATIN CAPITAL LETTER A"));
}

test "is_alphabetic" {
    try testing.expect(get(.is_alphabetic, 65)); // 'A'
    try testing.expect(get(.is_alphabetic, 97)); // 'a'
    try testing.expect(!get(.is_alphabetic, 0));
}

test "case_folding_simple" {
    try testing.expectEqual(97, get(.case_folding_simple, 65)); // 'a'
    try testing.expectEqual(97, get(.case_folding_simple, 97)); // 'a'
}

test "simple_uppercase_mapping" {
    try testing.expectEqual(65, get(.simple_uppercase_mapping, 97)); // 'a'
    try testing.expectEqual(65, get(.simple_uppercase_mapping, 65)); // 'A'
}

test "generalCategory" {
    try testing.expect(get(.general_category, 65) == .letter_uppercase); // 'A'
}

test "getAll" {
    const d1 = getAll("1", 65);
    try testing.expect(d1.general_category == .letter_uppercase);
    try testing.expect(d1.case_folding_simple.unshift(65) == 97);

    const d_checks = getAll("checks", 65);
    // auto should become packed for these checks
    try testing.expectEqual(.@"packed", @typeInfo(TypeOfAll("checks")).@"struct".layout);
    try testing.expect(d_checks.simple_uppercase_mapping.unshift(65) == 65);
    try testing.expect(d_checks.is_alphabetic);
    try testing.expect(d_checks.is_uppercase);
    try testing.expect(!d_checks.is_lowercase);
}

test "get extension foo" {
    try testing.expectEqual(0, get(.foo, 65));
    try testing.expectEqual(3, get(.foo, 0));
}

test "get extension emoji_odd_or_even" {
    try testing.expectEqual(.odd_emoji, get(.emoji_odd_or_even, 0x1F34B)); // 🍋
}

test "get packed optional enum works" {
    try testing.expectEqual(.odd_emoji, get(.opt_emoji_odd_or_even, 0x1F34B)); // 🍋
    try testing.expectEqual(null, get(.opt_emoji_odd_or_even, 0x01D8)); // ǘ
}

test "get packed optional bool works" {
    try testing.expectEqual(true, get(.maybe_bit, 0x1200));
    try testing.expectEqual(false, get(.maybe_bit, 0x1235));
    try testing.expectEqual(null, get(.maybe_bit, 0x1236));
}

test "get union unpacked, shift" {
    try testing.expectEqual(0x1234, get(.next_or_prev, 0x1233).next);
    try testing.expectEqual(0x1200, get(.next_or_prev, 0x1201).prev);
    try testing.expectEqual(.none, get(.next_or_prev, 0x1235));
}

test "get union unpacked, direct" {
    try testing.expectEqual(0x1234, get(.next_or_prev_direct, 0x1233).next);
    try testing.expectEqual(0x1200, get(.next_or_prev_direct, 0x1201).prev);
    try testing.expectEqual(.none, get(.next_or_prev_direct, 0x1235));
}

test "get union packed, shift" {
    try testing.expectEqual(5, @bitSizeOf(@FieldType(TypeOfAll("pack"), "bidi_paired_bracket")));
    try testing.expectEqual(0x0029, get(.bidi_paired_bracket, 0x0028).open);
    try testing.expectEqual(0x2997, get(.bidi_paired_bracket, 0x2998).close);
    try testing.expectEqual(.none, get(.bidi_paired_bracket, 0x4000));
}

test "get union packed, direct" {
    try testing.expectEqual(0x0029, get(.bidi_paired_bracket_direct, 0x0028).open);
    try testing.expectEqual(0x2997, get(.bidi_paired_bracket_direct, 0x2998).close);
    try testing.expectEqual(.none, get(.bidi_paired_bracket_direct, 0x4000));
}

test "get bidi_class" {
    try testing.expectEqual(.arabic_number, get(.bidi_class, 0x0600));
}

test "special_casing_condition" {
    const conditions1 = get(.special_casing_condition, 65); // 'A'
    try testing.expectEqual(0, conditions1.len);

    // Greek Capital Sigma (U+03A3) which has Final_Sigma condition
    const conditions = get(.special_casing_condition, 0x03A3);
    try testing.expectEqual(1, conditions.len);
    try testing.expectEqual(types.SpecialCasingCondition.final_sigma, conditions[0]);
}

test "special_lowercase_mapping" {
    var buffer: [1]u21 = undefined;

    // Greek Capital Sigma (U+03A3) which has Final_Sigma condition
    const mapping = get(.special_lowercase_mapping, 0x03A3).with(&buffer, 0x03A3);
    try testing.expectEqual(1, mapping.len);
    try testing.expectEqual(0x03C2, mapping[0]); // Should map to Greek Small Letter Final Sigma
}

test "info extension" {
    // ǰ -> J
    try testing.expectEqual(0x004A, get(.uppercase_mapping_first_char, 0x01F0));

    try testing.expect(get(.has_simple_lowercase, 0x1FD9)); // Ῑ
    try testing.expect(!get(.has_simple_lowercase, 0x1FE0)); // ῠ

    // MALAYALAM FRACTION ONE ONE-HUNDRED-AND-SIXTIETH
    try testing.expect(std.mem.eql(u8, "061/1", get(.numeric_value_numeric_reversed, 0x0D58)));
}

test "is_emoji_vs_base" {
    try testing.expect(get(.is_emoji_vs_base, 0x231B)); // ⌛
    try testing.expect(get(.is_emoji_vs_base, 0x1F327)); // 🌧
    try testing.expect(!get(.is_emoji_vs_base, 0x1F46C)); // 👬
}

test "block" {
    try testing.expectEqual(.basic_latin, get(.block, 0x0041)); // 'A'
    try testing.expectEqual(.greek_and_coptic, get(.block, 0x03B1)); // α
    try testing.expectEqual(.cjk_unified_ideographs, get(.block, 0x4E00)); // 一
}

test "script" {
    try testing.expectEqual(.latin, get(.script, 0x0041)); // 'A'
    try testing.expectEqual(.greek, get(.script, 0x03B1)); // α
    try testing.expectEqual(.han, get(.script, 0x4E00)); // 一
    try testing.expectEqual(.arabic, get(.script, 0x0627)); // ا
}

test "decomposition" {
    var buffer: [1]u21 = undefined;
    // LATIN CAPITAL LETTER A WITH GRAVE
    var mapping = get(.decomposition_mapping, 0x00C0).with(&buffer, 0x00C0);
    try testing.expectEqual(.canonical, get(.decomposition_type, 0x00C0));
    try testing.expect(std.mem.eql(u21, mapping, &.{ 0x0041, 0x0300 }));

    // ARABIC LIGATURE KAF WITH MEEM INITIAL FORM
    mapping = get(.decomposition_mapping, 0xFCC8).with(&buffer, 0xFCC8);
    try testing.expectEqual(.initial, get(.decomposition_type, 0xFCC8));
    try testing.expect(std.mem.eql(u21, mapping, &.{ 0x0643, 0x0645 }));

    // 'A'
    mapping = get(.decomposition_mapping, 0x0041).with(&buffer, 0x0041);
    try testing.expectEqual(.default, get(.decomposition_type, 0x0041));
    try testing.expect(std.mem.eql(u21, mapping, &.{0x0041}));
}

test "canonical_decomposition" {
    var buffer: [1]u21 = undefined;
    // LATIN CAPITAL LETTER A WITH GRAVE
    var mapping = get(.canonical_decomposition_mapping, 0x00C0).with(&buffer, 0x00C0);
    try testing.expect(std.mem.eql(u21, mapping, &.{ 0x0041, 0x0300 }));

    // ARABIC LIGATURE KAF WITH MEEM INITIAL FORM
    mapping = get(.canonical_decomposition_mapping, 0xFCC8).with(&buffer, 0xFCC8);
    try testing.expectEqual(0, mapping.len);
}

test "is_composition_exclusion" {
    try testing.expect(get(.is_composition_exclusion, 0x0958));
    try testing.expect(!get(.is_composition_exclusion, 0x0300));
}

test "joining_type" {
    try testing.expectEqual(.dual_joining, get(.joining_type, 0x0628)); // ب BEH
    try testing.expectEqual(.right_joining, get(.joining_type, 0x0627)); // ا ALEF
    try testing.expectEqual(.non_joining, get(.joining_type, 0x0041)); // 'A'
}

test "joining_group" {
    try testing.expectEqual(.beh, get(.joining_group, 0x0628)); // ب BEH
    try testing.expectEqual(.alef, get(.joining_group, 0x0627)); // ا ALEF
    try testing.expectEqual(.no_joining_group, get(.joining_group, 0x0041)); // 'A'
}

test "indic_positional_category" {
    try testing.expectEqual(.top, get(.indic_positional_category, 0x0A81)); // Gujarati Sign Candrabindu
    try testing.expectEqual(.right, get(.indic_positional_category, 0x1182E)); // Dogra Vowel Sign Ii
    try testing.expectEqual(.not_applicable, get(.indic_positional_category, 0x0041)); // 'A'
}

test "indic_syllabic_category" {
    try testing.expectEqual(.consonant, get(.indic_syllabic_category, 0x0A97)); // ગ Gujarati Letter Ga
    try testing.expectEqual(.vowel_dependent, get(.indic_syllabic_category, 0x1182E)); // Dogra Vowel Sign Ii
    try testing.expectEqual(.other, get(.indic_syllabic_category, 0x0041)); // 'A'
}

test "east_asian_width" {
    try testing.expectEqual(.narrow, get(.east_asian_width, 0x0041)); // 'A'
    try testing.expectEqual(.wide, get(.east_asian_width, 0x4E00)); // 一
    try testing.expectEqual(.fullwidth, get(.east_asian_width, 0xFF01)); // ！
}

test "canonical_combining_class" {
    try testing.expectEqual(@as(u8, 230), get(.canonical_combining_class, 0x0300)); // COMBINING GRAVE ACCENT
    try testing.expectEqual(@as(u8, 0), get(.canonical_combining_class, 0x0041)); // 'A'
}

test "numeric_type" {
    try testing.expectEqual(.decimal, get(.numeric_type, 0x0030)); // '0'
    try testing.expectEqual(.digit, get(.numeric_type, 0x00B2)); // ²
    try testing.expectEqual(.numeric, get(.numeric_type, 0x00BD)); // ½
    try testing.expectEqual(.none, get(.numeric_type, 0x0041)); // 'A'
}

test "numeric_value_decimal" {
    try testing.expectEqual(@as(?u4, 0), get(.numeric_value_decimal, 0x0030)); // '0'
    try testing.expectEqual(@as(?u4, 5), get(.numeric_value_decimal, 0x0035)); // '5'
    try testing.expectEqual(@as(?u4, null), get(.numeric_value_decimal, 0x0041)); // 'A'
}

test "numeric_value_digit" {
    try testing.expectEqual(@as(?u4, 2), get(.numeric_value_digit, 0x00B2)); // ²
    try testing.expectEqual(@as(?u4, null), get(.numeric_value_digit, 0x0041)); // 'A'
}

test "is_bidi_mirrored" {
    try testing.expect(get(.is_bidi_mirrored, 0x0028)); // '('
    try testing.expect(!get(.is_bidi_mirrored, 0x0041)); // 'A'
}

test "unicode_1_name" {
    try testing.expect(std.mem.eql(u8, "NULL", get(.unicode_1_name, 0x0000)));
    try testing.expect(std.mem.eql(u8, "", get(.unicode_1_name, 0x0041))); // 'A' has no Unicode 1.0 name
}

test "simple_titlecase_mapping" {
    try testing.expectEqual(0x0041, get(.simple_titlecase_mapping, 0x0061)); // 'a' -> 'A'
    try testing.expectEqual(0x0041, get(.simple_titlecase_mapping, 0x0041)); // 'A' -> 'A'
}

test "simple_lowercase_mapping" {
    try testing.expectEqual(0x0061, get(.simple_lowercase_mapping, 0x0041)); // 'A' -> 'a'
    try testing.expectEqual(0x0061, get(.simple_lowercase_mapping, 0x0061)); // 'a' -> 'a'
}

test "case_folding_full" {
    var buffer: [1]u21 = undefined;
    // ß (U+00DF) maps to "ss" (0x0073, 0x0073)
    const mapping = get(.case_folding_full, 0x00DF).with(&buffer, 0x00DF);
    try testing.expectEqual(2, mapping.len);
    try testing.expectEqual(0x0073, mapping[0]);
    try testing.expectEqual(0x0073, mapping[1]);
}

test "case_folding_turkish_only" {
    // U+0049 'I' has Turkish-only case folding to U+0131 (ı)
    const mapping = get(.case_folding_turkish_only, 0x0049);
    try testing.expectEqual(1, mapping.len);
    try testing.expectEqual(0x0131, mapping[0]);
}

test "case_folding_common_only" {
    // U+0041 'A' has common case folding to U+0061 'a'
    const mapping = get(.case_folding_common_only, 0x0041);
    try testing.expectEqual(1, mapping.len);
    try testing.expectEqual(0x0061, mapping[0]);
}

test "case_folding_simple_only" {
    // U+1E9E (ẞ) has simple-only case folding to U+00DF (ß)
    const mapping = get(.case_folding_simple_only, 0x1E9E);
    try testing.expectEqual(1, mapping.len);
    try testing.expectEqual(0x00DF, mapping[0]);
}

test "case_folding_full_only" {
    // ß (U+00DF) has full-only case folding to "ss"
    const mapping = get(.case_folding_full_only, 0x00DF);
    try testing.expectEqual(2, mapping.len);
    try testing.expectEqual(0x0073, mapping[0]);
    try testing.expectEqual(0x0073, mapping[1]);
}

test "has_special_casing" {
    try testing.expect(get(.has_special_casing, 0x00DF)); // ß
    try testing.expect(!get(.has_special_casing, 0x0041)); // 'A'
}

test "special_titlecase_mapping" {
    var buffer: [1]u21 = undefined;
    // ß (U+00DF) has special titlecase mapping to "Ss" (0x0053, 0x0073)
    const mapping = get(.special_titlecase_mapping, 0x00DF).with(&buffer, 0x00DF);
    try testing.expectEqual(2, mapping.len);
    try testing.expectEqual(0x0053, mapping[0]);
    try testing.expectEqual(0x0073, mapping[1]);
}

test "special_uppercase_mapping" {
    var buffer: [1]u21 = undefined;
    // ß (U+00DF) has special uppercase mapping to "SS" (0x0053, 0x0053)
    const mapping = get(.special_uppercase_mapping, 0x00DF).with(&buffer, 0x00DF);
    try testing.expectEqual(2, mapping.len);
    try testing.expectEqual(0x0053, mapping[0]);
    try testing.expectEqual(0x0053, mapping[1]);
}

test "lowercase_mapping" {
    var buffer: [1]u21 = undefined;
    const mapping = get(.lowercase_mapping, 0x0041).with(&buffer, 0x0041); // 'A' -> 'a'
    try testing.expectEqual(1, mapping.len);
    try testing.expectEqual(0x0061, mapping[0]);
}

test "titlecase_mapping" {
    var buffer: [1]u21 = undefined;
    const mapping = get(.titlecase_mapping, 0x0061).with(&buffer, 0x0061); // 'a' -> 'A'
    try testing.expectEqual(1, mapping.len);
    try testing.expectEqual(0x0041, mapping[0]);
}

test "is_math" {
    try testing.expect(get(.is_math, 0x002B)); // '+'
    try testing.expect(!get(.is_math, 0x0041)); // 'A'
}

test "is_cased" {
    try testing.expect(get(.is_cased, 0x0041)); // 'A'
    try testing.expect(!get(.is_cased, 0x0030)); // '0'
}

test "is_case_ignorable" {
    try testing.expect(get(.is_case_ignorable, 0x0027)); // apostrophe
    try testing.expect(!get(.is_case_ignorable, 0x0041)); // 'A'
}

test "changes_when_lowercased" {
    try testing.expect(get(.changes_when_lowercased, 0x0041)); // 'A'
    try testing.expect(!get(.changes_when_lowercased, 0x0061)); // 'a'
}

test "changes_when_uppercased" {
    try testing.expect(get(.changes_when_uppercased, 0x0061)); // 'a'
    try testing.expect(!get(.changes_when_uppercased, 0x0041)); // 'A'
}

test "changes_when_titlecased" {
    try testing.expect(get(.changes_when_titlecased, 0x0061)); // 'a'
    try testing.expect(!get(.changes_when_titlecased, 0x0041)); // 'A'
}

test "changes_when_casefolded" {
    try testing.expect(get(.changes_when_casefolded, 0x0041)); // 'A'
    try testing.expect(!get(.changes_when_casefolded, 0x0061)); // 'a'
}

test "changes_when_casemapped" {
    try testing.expect(get(.changes_when_casemapped, 0x0041)); // 'A'
    try testing.expect(!get(.changes_when_casemapped, 0x0030)); // '0'
}

test "is_id_start" {
    try testing.expect(get(.is_id_start, 0x0041)); // 'A'
    try testing.expect(!get(.is_id_start, 0x0030)); // '0'
}

test "is_id_continue" {
    try testing.expect(get(.is_id_continue, 0x0041)); // 'A'
    try testing.expect(get(.is_id_continue, 0x0030)); // '0'
}

test "is_xid_start" {
    try testing.expect(get(.is_xid_start, 0x0041)); // 'A'
    try testing.expect(!get(.is_xid_start, 0x0030)); // '0'
}

test "is_xid_continue" {
    try testing.expect(get(.is_xid_continue, 0x0041)); // 'A'
    try testing.expect(get(.is_xid_continue, 0x0030)); // '0'
}

test "is_default_ignorable" {
    try testing.expect(get(.is_default_ignorable, 0x00AD)); // SOFT HYPHEN
    try testing.expect(!get(.is_default_ignorable, 0x0041)); // 'A'
}

test "is_grapheme_extend" {
    try testing.expect(get(.is_grapheme_extend, 0x0300)); // COMBINING GRAVE ACCENT
    try testing.expect(!get(.is_grapheme_extend, 0x0041)); // 'A'
}

test "is_grapheme_base" {
    try testing.expect(get(.is_grapheme_base, 0x0041)); // 'A'
    try testing.expect(!get(.is_grapheme_base, 0x0300)); // COMBINING GRAVE ACCENT
}

test "is_grapheme_link" {
    try testing.expect(get(.is_grapheme_link, 0x094D)); // DEVANAGARI SIGN VIRAMA
    try testing.expect(!get(.is_grapheme_link, 0x0041)); // 'A'
}

test "indic_conjunct_break" {
    try testing.expectEqual(.linker, get(.indic_conjunct_break, 0x094D)); // DEVANAGARI SIGN VIRAMA
    try testing.expectEqual(.consonant, get(.indic_conjunct_break, 0x0915)); // DEVANAGARI LETTER KA
    try testing.expectEqual(.none, get(.indic_conjunct_break, 0x0041)); // 'A'
}

test "original_grapheme_break" {
    try testing.expectEqual(.cr, get(.original_grapheme_break, 0x000D));
    try testing.expectEqual(.lf, get(.original_grapheme_break, 0x000A));
    try testing.expectEqual(.other, get(.original_grapheme_break, 0x0041)); // 'A'
}

test "is_emoji" {
    try testing.expect(get(.is_emoji, 0x1F600)); // 😀
    try testing.expect(!get(.is_emoji, 0x0041)); // 'A'
}

test "is_emoji_presentation" {
    try testing.expect(get(.is_emoji_presentation, 0x1F600)); // 😀
    try testing.expect(!get(.is_emoji_presentation, 0x0041)); // 'A'
}

test "is_emoji_modifier" {
    try testing.expect(get(.is_emoji_modifier, 0x1F3FB)); // EMOJI MODIFIER FITZPATRICK TYPE-1-2
    try testing.expect(!get(.is_emoji_modifier, 0x0041)); // 'A'
}

test "is_emoji_component" {
    try testing.expect(get(.is_emoji_component, 0x1F3FB)); // EMOJI MODIFIER FITZPATRICK TYPE-1-2
    try testing.expect(!get(.is_emoji_component, 0x0041)); // 'A'
}

test "is_extended_pictographic" {
    try testing.expect(get(.is_extended_pictographic, 0x1F600)); // 😀
    try testing.expect(!get(.is_extended_pictographic, 0x0041)); // 'A'
}

test "is_emoji_vs_text" {
    try testing.expect(get(.is_emoji_vs_text, 0x231B)); // ⌛
    try testing.expect(!get(.is_emoji_vs_text, 0x1F46C)); // 👬
}

test "is_emoji_vs_emoji" {
    try testing.expect(get(.is_emoji_vs_emoji, 0x231B)); // ⌛
    try testing.expect(!get(.is_emoji_vs_emoji, 0x1F46C)); // 👬
}
