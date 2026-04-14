//! This File is Layer 1 of the architecture (see README.md), processing the
//! Unicode Character Database (UCD) files
//! (see https://www.unicode.org/reports/tr44/).

const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const config = @import("config.zig");
const inlineAssert = config.quirks.inlineAssert;

const n = config.max_code_point + 1;

unicode_data: []UnicodeData = undefined,
case_folding: []CaseFolding = undefined,
special_casing: []SpecialCasing = undefined,
derived_core_properties: []DerivedCoreProperties = undefined,
derived_bidi_class: []types.BidiClass = undefined,
east_asian_width: []types.EastAsianWidth = undefined,
original_grapheme_break: []types.OriginalGraphemeBreak = undefined,
emoji_data: []EmojiData = undefined,
emoji_vs: []EmojiVariationSequence = undefined,
bidi_paired_bracket: []types.BidiPairedBracket = undefined,
blocks: []types.Block = undefined,
scripts: []types.Script = undefined,
joining_types: []types.JoiningType = undefined,
joining_groups: []types.JoiningGroup = undefined,
is_composition_exclusions: []bool = undefined,
indic_positional_category: []types.IndicPositionalCategory = undefined,
indic_syllabic_category: []types.IndicSyllabicCategory = undefined,

const Self = @This();

pub const UcdSection = std.meta.FieldEnum(Self);

pub fn needsSection(comptime table_config: config.Table, comptime ucd_section: UcdSection) bool {
    inline for (table_config.fields) |field| {
        if (fieldNeedsSection(field.name, ucd_section)) {
            return true;
        }
    }
    inline for (table_config.extensions) |extension| {
        inline for (extension.inputs) |field| {
            if (fieldNeedsSection(field, ucd_section)) {
                return true;
            }
        }
    }

    return false;
}

fn needsSectionAny(comptime table_configs: []const config.Table, comptime ucd_section: UcdSection) bool {
    @setEvalBranchQuota(20_000);

    inline for (table_configs) |table_config| {
        if (needsSection(table_config, ucd_section)) {
            return true;
        }
    }

    return false;
}

const field_to_sections = std.StaticStringMap([]const UcdSection).initComptime(.{
    .{ "name", &.{.unicode_data} },
    .{ "general_category", &.{.unicode_data} },
    .{ "canonical_combining_class", &.{.unicode_data} },
    .{ "bidi_class", &.{.derived_bidi_class} },
    .{ "decomposition_type", &.{.unicode_data} },
    .{ "decomposition_mapping", &.{.unicode_data} },
    .{ "numeric_type", &.{.unicode_data} },
    .{ "numeric_value_decimal", &.{.unicode_data} },
    .{ "numeric_value_digit", &.{.unicode_data} },
    .{ "numeric_value_numeric", &.{.unicode_data} },
    .{ "is_bidi_mirrored", &.{.unicode_data} },
    .{ "unicode_1_name", &.{.unicode_data} },
    .{ "simple_uppercase_mapping", &.{.unicode_data} },
    .{ "simple_lowercase_mapping", &.{.unicode_data} },
    .{ "simple_titlecase_mapping", &.{.unicode_data} },
    .{ "case_folding_simple", &.{.case_folding} },
    .{ "case_folding_full", &.{.case_folding} },
    .{ "case_folding_turkish_only", &.{.case_folding} },
    .{ "case_folding_common_only", &.{.case_folding} },
    .{ "case_folding_simple_only", &.{.case_folding} },
    .{ "case_folding_full_only", &.{.case_folding} },
    .{ "has_special_casing", &.{.special_casing} },
    .{ "special_lowercase_mapping", &.{.special_casing} },
    .{ "special_titlecase_mapping", &.{.special_casing} },
    .{ "special_uppercase_mapping", &.{.special_casing} },
    .{ "special_casing_condition", &.{.special_casing} },
    .{ "is_math", &.{.derived_core_properties} },
    .{ "is_alphabetic", &.{.derived_core_properties} },
    .{ "is_lowercase", &.{.derived_core_properties} },
    .{ "is_uppercase", &.{.derived_core_properties} },
    .{ "is_cased", &.{.derived_core_properties} },
    .{ "is_case_ignorable", &.{.derived_core_properties} },
    .{ "changes_when_lowercased", &.{.derived_core_properties} },
    .{ "changes_when_uppercased", &.{.derived_core_properties} },
    .{ "changes_when_titlecased", &.{.derived_core_properties} },
    .{ "changes_when_casefolded", &.{.derived_core_properties} },
    .{ "changes_when_casemapped", &.{.derived_core_properties} },
    .{ "is_id_start", &.{.derived_core_properties} },
    .{ "is_id_continue", &.{.derived_core_properties} },
    .{ "is_xid_start", &.{.derived_core_properties} },
    .{ "is_xid_continue", &.{.derived_core_properties} },
    .{ "is_default_ignorable", &.{.derived_core_properties} },
    .{ "is_grapheme_extend", &.{.derived_core_properties} },
    .{ "is_grapheme_base", &.{.derived_core_properties} },
    .{ "is_grapheme_link", &.{.derived_core_properties} },
    .{ "indic_conjunct_break", &.{.derived_core_properties} },
    .{ "east_asian_width", &.{.east_asian_width} },
    .{ "original_grapheme_break", &.{.original_grapheme_break} },
    .{ "is_emoji", &.{.emoji_data} },
    .{ "is_emoji_presentation", &.{.emoji_data} },
    .{ "is_emoji_modifier", &.{.emoji_data} },
    .{ "is_emoji_modifier_base", &.{.emoji_data} },
    .{ "is_emoji_component", &.{.emoji_data} },
    .{ "is_extended_pictographic", &.{.emoji_data} },
    .{ "is_emoji_vs_base", &.{.emoji_vs} },
    .{ "is_emoji_vs_text", &.{.emoji_vs} },
    .{ "is_emoji_vs_emoji", &.{.emoji_vs} },
    .{ "bidi_paired_bracket", &.{.bidi_paired_bracket} },
    .{ "block", &.{.blocks} },
    .{ "script", &.{.scripts} },
    .{ "lowercase_mapping", &.{ .special_casing, .unicode_data } },
    .{ "titlecase_mapping", &.{ .special_casing, .unicode_data } },
    .{ "uppercase_mapping", &.{ .special_casing, .unicode_data } },
    .{ "grapheme_break", &.{ .emoji_data, .original_grapheme_break, .derived_core_properties } },
    .{ "joining_type", &.{.joining_types} },
    .{ "joining_group", &.{.joining_groups} },
    .{ "is_composition_exclusion", &.{.is_composition_exclusions} },
    .{ "indic_positional_category", &.{.indic_positional_category} },
    .{ "indic_syllabic_category", &.{.indic_syllabic_category} },
});

fn fieldNeedsSection(comptime field: []const u8, comptime ucd_section: UcdSection) bool {
    const sections = field_to_sections.get(field) orelse return false;
    return std.mem.indexOfScalar(UcdSection, sections, ucd_section) != null;
}

pub fn init(allocator: std.mem.Allocator, comptime table_configs: []const config.Table) !Self {
    const start = try std.time.Instant.now();

    var self: Self = .{};

    if (comptime needsSectionAny(table_configs, .unicode_data)) {
        self.unicode_data = try allocator.alloc(UnicodeData, n);
        try parseUnicodeData(allocator, self.unicode_data);
    }

    if (comptime needsSectionAny(table_configs, .case_folding)) {
        self.case_folding = try allocator.alloc(CaseFolding, n);
        try parseCaseFolding(allocator, self.case_folding);
    }

    if (comptime needsSectionAny(table_configs, .special_casing)) {
        self.special_casing = try allocator.alloc(SpecialCasing, n);
        try parseSpecialCasing(allocator, self.special_casing);
    }

    if (comptime needsSectionAny(table_configs, .derived_core_properties)) {
        self.derived_core_properties = try allocator.alloc(DerivedCoreProperties, n);
        try parseDerivedCoreProperties(allocator, self.derived_core_properties);
    }

    if (comptime needsSectionAny(table_configs, .derived_bidi_class)) {
        self.derived_bidi_class = try allocator.alloc(types.BidiClass, n);
        try parseDerivedBidiClass(allocator, self.derived_bidi_class);
    }

    if (comptime needsSectionAny(table_configs, .east_asian_width)) {
        self.east_asian_width = try allocator.alloc(types.EastAsianWidth, n);
        try parseEastAsianWidth(allocator, self.east_asian_width);
    }

    if (comptime needsSectionAny(table_configs, .original_grapheme_break)) {
        self.original_grapheme_break = try allocator.alloc(types.OriginalGraphemeBreak, n);
        try parseGraphemeBreak(allocator, self.original_grapheme_break);
    }

    if (comptime needsSectionAny(table_configs, .emoji_data)) {
        self.emoji_data = try allocator.alloc(EmojiData, n);
        try parseEmojiData(allocator, self.emoji_data);
    }

    if (comptime needsSectionAny(table_configs, .emoji_vs)) {
        self.emoji_vs = try allocator.alloc(EmojiVariationSequence, n);
        try parseEmojiVariationSequences(allocator, self.emoji_vs);
    }

    if (comptime needsSectionAny(table_configs, .bidi_paired_bracket)) {
        self.bidi_paired_bracket = try allocator.alloc(types.BidiPairedBracket, n);
        try parseBidiBrackets(allocator, self.bidi_paired_bracket);
    }

    if (comptime needsSectionAny(table_configs, .blocks)) {
        self.blocks = try allocator.alloc(types.Block, n);
        try parseBlocks(allocator, self.blocks);
    }

    if (comptime needsSectionAny(table_configs, .scripts)) {
        self.scripts = try allocator.alloc(types.Script, n);
        try parseScripts(allocator, self.scripts);
    }

    if (comptime needsSectionAny(table_configs, .joining_types)) {
        self.joining_types = try allocator.alloc(types.JoiningType, n);
        try parseJoiningType(allocator, self.joining_types);
    }

    if (comptime needsSectionAny(table_configs, .joining_groups)) {
        self.joining_groups = try allocator.alloc(types.JoiningGroup, n);
        try parseJoiningGroup(allocator, self.joining_groups);
    }

    if (comptime needsSectionAny(table_configs, .is_composition_exclusions)) {
        self.is_composition_exclusions = try allocator.alloc(bool, n);
        try parseCompositionExclusions(allocator, self.is_composition_exclusions);
    }

    if (comptime needsSectionAny(table_configs, .indic_positional_category)) {
        self.indic_positional_category = try allocator.alloc(types.IndicPositionalCategory, n);
        try parseIndicPositionalCategory(allocator, self.indic_positional_category);
    }

    if (comptime needsSectionAny(table_configs, .indic_syllabic_category)) {
        self.indic_syllabic_category = try allocator.alloc(types.IndicSyllabicCategory, n);
        try parseIndicSyllabicCategory(allocator, self.indic_syllabic_category);
    }

    const end = try std.time.Instant.now();
    std.log.debug("Ucd init time: {d}ms\n", .{end.since(start) / std.time.ns_per_ms});

    return self;
}

const UnicodeData = struct {
    name: []const u8 = &.{},
    general_category: types.GeneralCategory = .other_not_assigned,
    canonical_combining_class: u8 = 0,
    bidi_class: ?types.BidiClass = null,
    decomposition_type: types.DecompositionType = .default,
    decomposition_mapping: []const u21,
    numeric_type: types.NumericType = .none,
    numeric_value_decimal: ?u4 = null,
    numeric_value_digit: ?u4 = null,
    numeric_value_numeric: []const u8 = &.{},
    is_bidi_mirrored: bool = false,
    unicode_1_name: []const u8 = &.{},
    simple_uppercase_mapping: u21,
    simple_lowercase_mapping: u21,
    simple_titlecase_mapping: u21,
};

const CaseFolding = struct {
    case_folding_turkish_only: ?u21 = null,
    case_folding_common_only: ?u21 = null,
    case_folding_simple_only: ?u21 = null,
    case_folding_full_only: []const u21 = &.{},
};

const SpecialCasing = struct {
    has_special_casing: bool = false,
    special_lowercase_mapping: []const u21 = &.{},
    special_titlecase_mapping: []const u21 = &.{},
    special_uppercase_mapping: []const u21 = &.{},
    special_casing_condition: []const types.SpecialCasingCondition = &.{},
};

const DerivedCoreProperties = packed struct {
    is_math: bool = false,
    is_alphabetic: bool = false,
    is_lowercase: bool = false,
    is_uppercase: bool = false,
    is_cased: bool = false,
    is_case_ignorable: bool = false,
    changes_when_lowercased: bool = false,
    changes_when_uppercased: bool = false,
    changes_when_titlecased: bool = false,
    changes_when_casefolded: bool = false,
    changes_when_casemapped: bool = false,
    is_id_start: bool = false,
    is_id_continue: bool = false,
    is_xid_start: bool = false,
    is_xid_continue: bool = false,
    is_default_ignorable: bool = false,
    is_grapheme_extend: bool = false,
    is_grapheme_base: bool = false,
    is_grapheme_link: bool = false,
    indic_conjunct_break: types.IndicConjunctBreak = .none,
};

const EmojiData = packed struct {
    is_emoji: bool = false,
    is_emoji_presentation: bool = false,
    is_emoji_modifier: bool = false,
    is_emoji_modifier_base: bool = false,
    is_emoji_component: bool = false,
    is_extended_pictographic: bool = false,
};

const EmojiVariationSequence = packed struct {
    is_text: bool = false, // VS15
    is_emoji: bool = false, // VS16
};

// Public for GraphemeBreakTest in src/grapheme.zig
pub fn parseCp(str: []const u8) !u21 {
    return std.fmt.parseInt(u21, str, 16);
}

fn parseRange(str: []const u8) !struct { start: u21, end: u21 } {
    if (std.mem.indexOf(u8, str, "..")) |dot_idx| {
        const start = try parseCp(str[0..dot_idx]);
        const end = try parseCp(str[dot_idx + 2 ..]);
        return .{ .start = start, .end = end };
    } else {
        const cp = try parseCp(str);
        return .{ .start = cp, .end = cp };
    }
}

test "parseCp" {
    try std.testing.expectEqual(0x0000, try parseCp("0000"));
    try std.testing.expectEqual(0x1F600, try parseCp("1F600"));
}

test "parseRange" {
    const range = try parseRange("0030..0039");
    try std.testing.expectEqual(0x0030, range.start);
    try std.testing.expectEqual(0x0039, range.end);

    const single = try parseRange("1F600");
    try std.testing.expectEqual(0x1F600, single.start);
    try std.testing.expectEqual(0x1F600, single.end);
}

// Public for GraphemeBreakTest in src/grapheme.zig
pub fn trim(line: []const u8) []const u8 {
    if (std.mem.indexOf(u8, line, "#")) |idx| {
        return std.mem.trim(u8, line[0..idx], " \t\r");
    }
    return std.mem.trim(u8, line, " \t\r");
}

fn parseUnicodeData(allocator: std.mem.Allocator, unicode_data: []UnicodeData) !void {
    const file_path = "ucd/UnicodeData.txt";

    // TODO: look for defaults in the Derived Extracted properties files:
    // https://www.unicode.org/reports/tr44/#Derived_Extracted
    //
    // > For nondefault values of properties, if there is any inadvertent
    // mismatch between the primary data files specifying those properties and
    // these lists of extracted properties, the primary data files are taken as
    // definitive. However, for default values of properties, the extracted
    // data files are definitive.

    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024 * 10);
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    var next_cp: u21 = 0;
    var range_data: ?UnicodeData = null;

    while (lines.next()) |line| {
        const trimmed = trim(line);
        if (trimmed.len == 0) continue;

        var parts = std.mem.splitScalar(u8, trimmed, ';');
        const cp_str = parts.next().?;
        const cp = try parseCp(cp_str);

        // Fill ranges or gaps
        while (next_cp < cp) : (next_cp += 1) {
            var data: UnicodeData = range_data orelse .{
                .decomposition_mapping = &.{},
                .simple_uppercase_mapping = 0,
                .simple_titlecase_mapping = 0,
                .simple_lowercase_mapping = 0,
            };
            data.decomposition_mapping = try allocator.dupe(u21, &.{next_cp});
            data.simple_uppercase_mapping = next_cp;
            data.simple_titlecase_mapping = next_cp;
            data.simple_lowercase_mapping = next_cp;
            unicode_data[next_cp] = data;
        }

        if (range_data != null) {
            // We're in a range, so the next entry marks the last, with the same
            // information.
            inlineAssert(std.mem.endsWith(u8, parts.next().?, "Last>"));
            var data = range_data.?;
            data.decomposition_mapping = try allocator.dupe(u21, &.{next_cp});
            data.simple_uppercase_mapping = next_cp;
            data.simple_titlecase_mapping = next_cp;
            data.simple_lowercase_mapping = next_cp;
            unicode_data[next_cp] = data;
            range_data = null;
            next_cp = cp + 1;
            continue;
        }

        const name_str = parts.next().?; // Field 1
        const general_category_str = parts.next().?; // Field 2
        const canonical_combining_class = std.fmt.parseInt(u8, parts.next().?, 10) catch 0; // Field 3
        const bidi_class_str = parts.next().?; // Field 4
        const decomposition_str = parts.next().?; // Field 5: Combined type and mapping
        const numeric_decimal_str = parts.next().?; // Field 6
        const numeric_digit_str = parts.next().?; // Field 7
        const numeric_numeric_str = parts.next().?; // Field 8
        const is_bidi_mirrored = std.mem.eql(u8, parts.next().?, "Y"); // Field 9
        const unicode_1_name = parts.next().?; // Field 10
        _ = parts.next().?; // Field 11: Obsolete ISO_Comment
        const simple_uppercase_mapping_str = parts.next().?; // Field 12
        const simple_lowercase_mapping_str = parts.next().?; // Field 13
        const simple_titlecase_mapping_str = parts.next().?; // Field 14

        const name = if (std.mem.endsWith(u8, name_str, "First>")) name_str["<".len..(name_str.len - ", First>".len)] else name_str;
        const general_category = general_category_map.get(general_category_str) orelse blk: {
            std.log.err("Unknown general category: {s}", .{general_category_str});
            if (!config.is_updating_ucd) {
                unreachable;
            } else {
                break :blk .other_not_assigned;
            }
        };

        const bidi_class = bidi_class_map.get(bidi_class_str) orelse blk: {
            std.log.err("Unknown bidi class: {s}", .{bidi_class_str});
            if (!config.is_updating_ucd) {
                unreachable;
            } else {
                break :blk .left_to_right;
            }
        };

        const simple_uppercase_mapping = if (simple_uppercase_mapping_str.len == 0)
            cp
        else
            try parseCp(simple_uppercase_mapping_str);
        const simple_lowercase_mapping = if (simple_lowercase_mapping_str.len == 0)
            cp
        else
            try parseCp(simple_lowercase_mapping_str);
        const simple_titlecase_mapping = if (simple_titlecase_mapping_str.len == 0)
            simple_uppercase_mapping
        else
            try parseCp(simple_titlecase_mapping_str);

        // Parse decomposition type and mapping from single field
        var decomposition_type: types.DecompositionType = undefined;
        var decomposition_mapping: [40]u21 = undefined; // Max is currently 18
        var decomposition_mapping_len: usize = undefined;

        if (decomposition_str.len > 0) {
            decomposition_mapping_len = 0;

            // Non-empty field means canonical unless explicit type is given
            decomposition_type = types.DecompositionType.canonical;
            var mapping_str = decomposition_str;

            if (std.mem.startsWith(u8, decomposition_str, "<")) {
                // Compatibility decomposition with type in angle brackets
                const end_bracket = std.mem.indexOf(u8, decomposition_str, ">") orelse {
                    std.log.err("Invalid decomposition format: {s}", .{decomposition_str});
                    unreachable;
                };
                const type_str = decomposition_str[1..end_bracket];
                decomposition_type = std.meta.stringToEnum(types.DecompositionType, type_str) orelse blk: {
                    std.log.err("Unknown decomposition type: {s}", .{type_str});
                    if (!config.is_updating_ucd) {
                        unreachable;
                    } else {
                        break :blk .canonical;
                    }
                };
                mapping_str = std.mem.trim(u8, decomposition_str[end_bracket + 1 ..], " \t\r");
            }

            // Parse code points from mapping string
            if (mapping_str.len > 0) {
                var mapping_parts = std.mem.splitScalar(u8, mapping_str, ' ');

                while (mapping_parts.next()) |part| {
                    if (part.len == 0) continue;
                    decomposition_mapping[decomposition_mapping_len] = try parseCp(part);
                    decomposition_mapping_len += 1;
                }
            }
        } else {
            // Default: character decomposes to itself (field 5 empty)
            decomposition_type = .default;
            decomposition_mapping_len = 1;
            decomposition_mapping[0] = cp;
        }

        // Determine numeric type and parse values based on which field has a value
        var numeric_type = types.NumericType.none;
        var numeric_value_decimal: ?u4 = null;
        var numeric_value_digit: ?u4 = null;

        if (numeric_decimal_str.len > 0) {
            numeric_type = types.NumericType.decimal;
            numeric_value_decimal = std.fmt.parseInt(u4, numeric_decimal_str, 10) catch |err| {
                std.log.err("Invalid decimal numeric value '{s}' at code point {X}: {}", .{ numeric_decimal_str, cp, err });
                unreachable;
            };
        } else if (numeric_digit_str.len > 0) {
            numeric_type = types.NumericType.digit;
            numeric_value_digit = std.fmt.parseInt(u4, numeric_digit_str, 10) catch |err| {
                std.log.err("Invalid digit numeric value '{s}' at code point {X}: {}", .{ numeric_digit_str, cp, err });
                unreachable;
            };
        } else if (numeric_numeric_str.len > 0) {
            numeric_type = types.NumericType.numeric;
        }

        const data = UnicodeData{
            .name = try allocator.dupe(u8, name),
            .general_category = general_category,
            .canonical_combining_class = canonical_combining_class,
            .bidi_class = bidi_class,
            .decomposition_type = decomposition_type,
            .decomposition_mapping = try allocator.dupe(
                u21,
                decomposition_mapping[0..decomposition_mapping_len],
            ),
            .numeric_type = numeric_type,
            .numeric_value_decimal = numeric_value_decimal,
            .numeric_value_digit = numeric_value_digit,
            .numeric_value_numeric = try allocator.dupe(u8, numeric_numeric_str),
            .is_bidi_mirrored = is_bidi_mirrored,
            .unicode_1_name = try allocator.dupe(u8, unicode_1_name),
            .simple_uppercase_mapping = simple_uppercase_mapping,
            .simple_lowercase_mapping = simple_lowercase_mapping,
            .simple_titlecase_mapping = simple_titlecase_mapping,
        };

        // Handle range entries with "First>" and "Last>"
        if (std.mem.endsWith(u8, name_str, "First>")) {
            range_data = data;
        }

        unicode_data[cp] = data;
        next_cp = cp + 1;
    }

    // Fill any remaining gaps at the end with default values
    for (next_cp..config.max_code_point + 1) |cp_usize| {
        const cp: u21 = @intCast(cp_usize);
        unicode_data[cp_usize] = .{
            .decomposition_mapping = try allocator.dupe(u21, &.{cp}),
            .simple_uppercase_mapping = cp,
            .simple_titlecase_mapping = cp,
            .simple_lowercase_mapping = cp,
        };
    }
}

const general_category_map = std.StaticStringMap(types.GeneralCategory).initComptime(.{
    .{ "Lu", .letter_uppercase },
    .{ "Ll", .letter_lowercase },
    .{ "Lt", .letter_titlecase },
    .{ "Lm", .letter_modifier },
    .{ "Lo", .letter_other },
    .{ "Mn", .mark_nonspacing },
    .{ "Mc", .mark_spacing_combining },
    .{ "Me", .mark_enclosing },
    .{ "Nd", .number_decimal_digit },
    .{ "Nl", .number_letter },
    .{ "No", .number_other },
    .{ "Pc", .punctuation_connector },
    .{ "Pd", .punctuation_dash },
    .{ "Ps", .punctuation_open },
    .{ "Pe", .punctuation_close },
    .{ "Pi", .punctuation_initial_quote },
    .{ "Pf", .punctuation_final_quote },
    .{ "Po", .punctuation_other },
    .{ "Sm", .symbol_math },
    .{ "Sc", .symbol_currency },
    .{ "Sk", .symbol_modifier },
    .{ "So", .symbol_other },
    .{ "Zs", .separator_space },
    .{ "Zl", .separator_line },
    .{ "Zp", .separator_paragraph },
    .{ "Cc", .other_control },
    .{ "Cf", .other_format },
    .{ "Cs", .other_surrogate },
    .{ "Co", .other_private_use },
    .{ "Cn", .other_not_assigned },
});

const bidi_class_map = std.StaticStringMap(types.BidiClass).initComptime(.{
    .{ "L", .left_to_right },
    .{ "LRE", .left_to_right_embedding },
    .{ "LRO", .left_to_right_override },
    .{ "R", .right_to_left },
    .{ "AL", .right_to_left_arabic },
    .{ "RLE", .right_to_left_embedding },
    .{ "RLO", .right_to_left_override },
    .{ "PDF", .pop_directional_format },
    .{ "EN", .european_number },
    .{ "ES", .european_number_separator },
    .{ "ET", .european_number_terminator },
    .{ "AN", .arabic_number },
    .{ "CS", .common_number_separator },
    .{ "NSM", .nonspacing_mark },
    .{ "BN", .boundary_neutral },
    .{ "B", .paragraph_separator },
    .{ "S", .segment_separator },
    .{ "WS", .whitespace },
    .{ "ON", .other_neutrals },
    .{ "LRI", .left_to_right_isolate },
    .{ "RLI", .right_to_left_isolate },
    .{ "FSI", .first_strong_isolate },
    .{ "PDI", .pop_directional_isolate },
});

const bidi_longform_map = std.StaticStringMap(types.BidiClass).initComptime(.{
    .{ "Left_To_Right", .left_to_right },
    .{ "Right_To_Left", .right_to_left },
    .{ "Arabic_Letter", .right_to_left_arabic },
    .{ "European_Terminator", .european_number_terminator },
});

fn parseCaseFolding(
    allocator: std.mem.Allocator,
    case_folding: []CaseFolding,
) !void {
    @memset(case_folding, .{});

    const file_path = "ucd/CaseFolding.txt";

    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = trim(line);
        if (trimmed.len == 0) continue;

        var parts = std.mem.splitScalar(u8, trimmed, ';');
        const cp_str = std.mem.trim(u8, parts.next().?, " \t\r");
        const cp = try parseCp(cp_str);

        const status_str = std.mem.trim(u8, parts.next().?, " \t\r");
        const status = if (status_str.len > 0) status_str[0] else 0;

        const mapping_str = std.mem.trim(u8, parts.next() orelse "", " \t\r");
        var mapping_parts = std.mem.splitScalar(u8, mapping_str, ' ');

        var mapping: [9]u21 = undefined; // Max is currently 3
        var mapping_len: u2 = 0;

        while (mapping_parts.next()) |part| {
            if (part.len == 0) continue;
            const mapped_cp = try parseCp(part);
            mapping[mapping_len] = mapped_cp;
            mapping_len += 1;
        }

        switch (status) {
            'S' => {
                inlineAssert(mapping_len == 1);
                case_folding[cp].case_folding_simple_only = mapping[0];
            },
            'C' => {
                inlineAssert(mapping_len == 1);
                case_folding[cp].case_folding_common_only = mapping[0];
            },
            'T' => {
                inlineAssert(mapping_len == 1);
                case_folding[cp].case_folding_turkish_only = mapping[0];
            },
            'F' => {
                inlineAssert(mapping_len > 1);
                case_folding[cp].case_folding_full_only = try allocator.dupe(
                    u21,
                    mapping[0..mapping_len],
                );
            },
            else => unreachable,
        }
    }
}

fn parseSpecialCasing(
    allocator: std.mem.Allocator,
    special_casing: []SpecialCasing,
) !void {
    @memset(special_casing, .{});

    const file_path = "ucd/SpecialCasing.txt";

    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = trim(line);
        if (trimmed.len == 0) continue;

        var parts = std.mem.splitScalar(u8, trimmed, ';');
        const cp_str = std.mem.trim(u8, parts.next().?, " \t\r");
        const cp = try parseCp(cp_str);

        const lower_str = std.mem.trim(u8, parts.next().?, " \t\r");
        const title_str = std.mem.trim(u8, parts.next().?, " \t\r");
        const upper_str = std.mem.trim(u8, parts.next().?, " \t\r");

        // TODO: this doesn't handle multiple condition lists in the Turkish and Azeri section
        // Parse the optional condition list
        var conditions: [6]types.SpecialCasingCondition = undefined; // Max is currently 2
        var conditions_len: u8 = 0;
        if (parts.next()) |condition_str| {
            const trimmed_conditions = std.mem.trim(u8, condition_str, " \t\r");
            if (trimmed_conditions.len > 0) {
                var condition_parts = std.mem.splitScalar(u8, trimmed_conditions, ' ');
                while (condition_parts.next()) |condition_part| {
                    const trimmed_condition = std.mem.trim(u8, condition_part, " \t\r");
                    if (trimmed_condition.len == 0) continue;
                    const condition = special_casing_condition_map.get(trimmed_condition) orelse blk: {
                        std.log.err("Unknown special casing condition '{s}'", .{trimmed_condition});
                        if (!config.is_updating_ucd) {
                            unreachable;
                        } else {
                            break :blk .final_sigma;
                        }
                    };
                    conditions[conditions_len] = condition;
                    conditions_len += 1;
                }
            }
        }

        // Parse mappings
        var lower_mapping: [9]u21 = undefined; // Max is currently 3
        var lower_mapping_len: u8 = 0;
        var lower_parts = std.mem.splitScalar(u8, lower_str, ' ');
        while (lower_parts.next()) |part| {
            if (part.len == 0) continue;
            lower_mapping[lower_mapping_len] = try parseCp(part);
            lower_mapping_len += 1;
        }

        var title_mapping: [9]u21 = undefined; // Max is currently 3
        var title_mapping_len: u8 = 0;
        var title_parts = std.mem.splitScalar(u8, title_str, ' ');
        while (title_parts.next()) |part| {
            if (part.len == 0) continue;
            title_mapping[title_mapping_len] = try parseCp(part);
            title_mapping_len += 1;
        }

        var upper_mapping: [9]u21 = undefined; // Max is currently 3
        var upper_mapping_len: u8 = 0;
        var upper_parts = std.mem.splitScalar(u8, upper_str, ' ');
        while (upper_parts.next()) |part| {
            if (part.len == 0) continue;
            upper_mapping[upper_mapping_len] = try parseCp(part);
            upper_mapping_len += 1;
        }

        special_casing[cp].has_special_casing = true;
        special_casing[cp].special_lowercase_mapping = try allocator.dupe(
            u21,
            lower_mapping[0..lower_mapping_len],
        );
        special_casing[cp].special_titlecase_mapping = try allocator.dupe(
            u21,
            title_mapping[0..title_mapping_len],
        );
        special_casing[cp].special_uppercase_mapping = try allocator.dupe(
            u21,
            upper_mapping[0..upper_mapping_len],
        );
        special_casing[cp].special_casing_condition = try allocator.dupe(
            types.SpecialCasingCondition,
            conditions[0..conditions_len],
        );
    }
}

const special_casing_condition_map = std.StaticStringMap(types.SpecialCasingCondition).initComptime(.{
    .{ "Final_Sigma", .final_sigma },
    .{ "After_Soft_Dotted", .after_soft_dotted },
    .{ "More_Above", .more_above },
    .{ "After_I", .after_i },
    .{ "Not_Before_Dot", .not_before_dot },
    .{ "lt", .lt },
    .{ "tr", .tr },
    .{ "az", .az },
});

fn parseDerivedCoreProperties(
    allocator: std.mem.Allocator,
    derived_core_properties: []DerivedCoreProperties,
) !void {
    @memset(derived_core_properties, .{});

    const file_path = "ucd/DerivedCoreProperties.txt";

    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024 * 2);
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = trim(line);
        if (trimmed.len == 0) continue;

        var parts = std.mem.splitScalar(u8, trimmed, ';');
        const cp_str = std.mem.trim(u8, parts.next().?, " \t\r");
        const property_str = std.mem.trim(u8, parts.next().?, " \t\r");
        const value_str = if (parts.next()) |v| std.mem.trim(u8, v, " \t\r") else "";

        const range = try parseRange(cp_str);
        const property = derived_core_property_map.get(property_str) orelse blk: {
            std.log.err("Unknown DerivedCoreProperties property: {s}", .{property_str});
            if (!config.is_updating_ucd) {
                unreachable;
            } else {
                break :blk .is_alphabetic;
            }
        };

        const indic_conjunct_break = indic_conjunct_break_map.get(value_str);

        var cp: u21 = range.start;
        while (cp <= range.end) : (cp += 1) {
            switch (property) {
                .indic_conjunct_break => {
                    derived_core_properties[cp].indic_conjunct_break = indic_conjunct_break orelse blk: {
                        std.log.err("Unknown InCB value: {s}", .{value_str});
                        if (!config.is_updating_ucd) {
                            unreachable;
                        } else {
                            break :blk .linker;
                        }
                    };
                },
                inline else => |p| {
                    @field(derived_core_properties[cp], @tagName(p)) = true;
                },
            }
        }
    }
}

fn parseBidiBrackets(
    allocator: std.mem.Allocator,
    bidi_paired_bracket: []types.BidiPairedBracket,
) !void {
    @memset(bidi_paired_bracket, .none);

    const file_path = "ucd/BidiBrackets.txt";

    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024 * 2);
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = trim(line);
        if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "#")) continue;

        var parts = std.mem.splitScalar(u8, trimmed, ';');
        const cp_str = std.mem.trim(u8, parts.next().?, " \t\r");
        const paired_cp_str = std.mem.trim(u8, parts.next().?, " \t\r");

        const op = try parseCp(cp_str);
        const paired = try parseCp(paired_cp_str);

        const type_str = std.mem.trim(u8, parts.next().?, " \t\r");
        const bracket_type: types.BidiPairedBracket = switch (type_str[0]) {
            'c' => .{ .close = paired },
            'o' => .{ .open = paired },
            else => unreachable,
        };

        bidi_paired_bracket[op] = bracket_type;
    }
}

const derived_core_property_map = std.StaticStringMap(std.meta.FieldEnum(DerivedCoreProperties)).initComptime(.{
    .{ "Math", .is_math },
    .{ "Alphabetic", .is_alphabetic },
    .{ "Lowercase", .is_lowercase },
    .{ "Uppercase", .is_uppercase },
    .{ "Cased", .is_cased },
    .{ "Case_Ignorable", .is_case_ignorable },
    .{ "Changes_When_Lowercased", .changes_when_lowercased },
    .{ "Changes_When_Uppercased", .changes_when_uppercased },
    .{ "Changes_When_Titlecased", .changes_when_titlecased },
    .{ "Changes_When_Casefolded", .changes_when_casefolded },
    .{ "Changes_When_Casemapped", .changes_when_casemapped },
    .{ "ID_Start", .is_id_start },
    .{ "ID_Continue", .is_id_continue },
    .{ "XID_Start", .is_xid_start },
    .{ "XID_Continue", .is_xid_continue },
    .{ "Default_Ignorable_Code_Point", .is_default_ignorable },
    .{ "Grapheme_Extend", .is_grapheme_extend },
    .{ "Grapheme_Base", .is_grapheme_base },
    .{ "Grapheme_Link", .is_grapheme_link },
    .{ "InCB", .indic_conjunct_break },
});

const indic_conjunct_break_map = std.StaticStringMap(types.IndicConjunctBreak).initComptime(.{
    .{ "Linker", .linker },
    .{ "Consonant", .consonant },
    .{ "Extend", .extend },
});

fn parseDerivedBidiClass(
    allocator: std.mem.Allocator,
    derived_bidi_class: []types.BidiClass,
) !void {
    @memset(derived_bidi_class, .left_to_right);

    const file_path = "ucd/extracted/DerivedBidiClass.txt";

    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024 * 2);
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        // Handle @missing directives first
        if (std.mem.startsWith(u8, trimmed, "# @missing:")) {
            const missing_line = trimmed["# @missing:".len..];
            var parts = std.mem.splitScalar(u8, missing_line, ';');
            const cp_str = std.mem.trim(u8, parts.next().?, " \t\r");
            const class_str = std.mem.trim(u8, parts.next().?, " \t\r");

            const range = try parseRange(cp_str);

            // Skip Left_To_Right as it's the default
            if (std.mem.eql(u8, class_str, "Left_To_Right")) {
                continue;
            }

            const bidi_class = bidi_longform_map.get(class_str) orelse blk: {
                std.log.err("Unknown @missing BidiClass value: {s}", .{class_str});
                if (!config.is_updating_ucd) {
                    unreachable;
                } else {
                    break :blk .left_to_right;
                }
            };

            var cp: u21 = range.start;
            while (cp <= range.end) : (cp += 1) {
                derived_bidi_class[cp] = bidi_class;
            }
            continue;
        }

        // Handle regular entries
        const data_line = trim(trimmed);
        if (data_line.len == 0) continue;

        var parts = std.mem.splitScalar(u8, data_line, ';');
        const cp_str = std.mem.trim(u8, parts.next().?, " \t\r");
        const class_str = std.mem.trim(u8, parts.next().?, " \t\r");

        const range = try parseRange(cp_str);

        const bidi_class = bidi_class_map.get(class_str) orelse blk: {
            std.log.err("Unknown BidiClass value: {s}", .{class_str});
            if (!config.is_updating_ucd) {
                unreachable;
            } else {
                break :blk .left_to_right;
            }
        };

        var cp: u21 = range.start;
        while (cp <= range.end) : (cp += 1) {
            derived_bidi_class[cp] = bidi_class;
        }
    }
}

fn parseEastAsianWidth(
    allocator: std.mem.Allocator,
    east_asian_width: []types.EastAsianWidth,
) !void {
    @memset(east_asian_width, .neutral);

    const file_path = "ucd/extracted/DerivedEastAsianWidth.txt";

    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        // Handle @missing directives first
        if (std.mem.startsWith(u8, trimmed, "# @missing:")) {
            const missing_line = trimmed["# @missing:".len..];
            var parts = std.mem.splitScalar(u8, missing_line, ';');
            const cp_str = std.mem.trim(u8, parts.next().?, " \t\r");
            const width_str = std.mem.trim(u8, parts.next().?, " \t\r");

            const range = try parseRange(cp_str);

            // Skip `neutral` as it's the default
            if (std.mem.eql(u8, width_str, "Neutral")) {
                continue;
            }

            if (!std.mem.eql(u8, width_str, "Wide")) {
                std.log.err("Unknown @missing EastAsianWidth value: {s}", .{width_str});
                if (!config.is_updating_ucd) {
                    unreachable;
                }
            }

            var cp: u21 = range.start;
            while (cp <= range.end) : (cp += 1) {
                east_asian_width[cp] = .wide;
            }
            continue;
        }

        // Handle regular entries
        const data_line = trim(trimmed);
        if (data_line.len == 0) continue;

        var parts = std.mem.splitScalar(u8, data_line, ';');
        const cp_str = std.mem.trim(u8, parts.next().?, " \t\r");
        const width_str = std.mem.trim(u8, parts.next().?, " \t\r");

        const range = try parseRange(cp_str);

        const width = east_asian_width_map.get(width_str) orelse blk: {
            std.log.err("Unknown EastAsianWidth value: {s}", .{width_str});
            if (!config.is_updating_ucd) {
                unreachable;
            } else {
                break :blk .wide;
            }
        };

        var cp: u21 = range.start;
        while (cp <= range.end) : (cp += 1) {
            east_asian_width[cp] = width;
        }
    }
}

const east_asian_width_map = std.StaticStringMap(types.EastAsianWidth).initComptime(.{
    .{ "F", .fullwidth },
    .{ "H", .halfwidth },
    .{ "W", .wide },
    .{ "Na", .narrow },
    .{ "A", .ambiguous },
    .{ "N", .neutral },
});

fn parseGraphemeBreak(
    allocator: std.mem.Allocator,
    grapheme_break: []types.OriginalGraphemeBreak,
) !void {
    @memset(grapheme_break, .other);

    const file_path = "ucd/auxiliary/GraphemeBreakProperty.txt";

    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = trim(line);
        if (trimmed.len == 0) continue;

        var parts = std.mem.splitScalar(u8, trimmed, ';');
        const cp_str = std.mem.trim(u8, parts.next().?, " \t\r");
        const prop_str = std.mem.trim(u8, parts.next().?, " \t\r");

        const range = try parseRange(cp_str);

        const prop = grapheme_break_property_map.get(prop_str) orelse types.OriginalGraphemeBreak.other;

        var cp: u21 = range.start;
        while (cp <= range.end) : (cp += 1) {
            grapheme_break[cp] = prop;
        }
    }
}

const grapheme_break_property_map = std.StaticStringMap(types.OriginalGraphemeBreak).initComptime(.{
    .{ "Prepend", .prepend },
    .{ "CR", .cr },
    .{ "LF", .lf },
    .{ "Control", .control },
    .{ "Extend", .extend },
    .{ "Regional_Indicator", .regional_indicator },
    .{ "SpacingMark", .spacing_mark },
    .{ "L", .l },
    .{ "V", .v },
    .{ "T", .t },
    .{ "LV", .lv },
    .{ "LVT", .lvt },
    .{ "ZWJ", .zwj },
});

fn parseEmojiData(
    allocator: std.mem.Allocator,
    emoji_data: []EmojiData,
) !void {
    @memset(emoji_data, .{});

    const file_path = "ucd/emoji/emoji-data.txt";

    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = trim(line);
        if (trimmed.len == 0) continue;

        var parts = std.mem.splitScalar(u8, trimmed, ';');
        const cp_str = std.mem.trim(u8, parts.next().?, " \t\r");
        const prop_str = std.mem.trim(u8, parts.next().?, " \t\r");

        const range = try parseRange(cp_str);

        var cp: u21 = range.start;
        while (cp <= range.end) : (cp += 1) {
            const property = emoji_data_property_map.get(prop_str) orelse blk: {
                std.log.err("Unknown EmojiData property: {s}", .{prop_str});
                if (!config.is_updating_ucd) {
                    unreachable;
                } else {
                    break :blk .is_emoji;
                }
            };

            switch (property) {
                inline else => |p| {
                    @field(emoji_data[cp], @tagName(p)) = true;
                },
            }
        }
    }
}

const emoji_data_property_map = std.StaticStringMap(std.meta.FieldEnum(EmojiData)).initComptime(.{
    .{ "Emoji", .is_emoji },
    .{ "Emoji_Presentation", .is_emoji_presentation },
    .{ "Emoji_Modifier", .is_emoji_modifier },
    .{ "Emoji_Modifier_Base", .is_emoji_modifier_base },
    .{ "Emoji_Component", .is_emoji_component },
    .{ "Extended_Pictographic", .is_extended_pictographic },
});

fn parseEmojiVariationSequences(
    allocator: std.mem.Allocator,
    emoji_vs: []EmojiVariationSequence,
) !void {
    @memset(emoji_vs, .{});

    const file_path = "ucd/emoji/emoji-variation-sequences.txt";

    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = trim(line);
        if (trimmed.len == 0) continue;

        var parts = std.mem.splitScalar(u8, trimmed, ' ');
        const cp = try parseCp(parts.next().?);
        const vs = try parseCp(parts.next().?);

        if (vs == 0xFE0E) {
            emoji_vs[cp].is_text = true;
        } else if (vs == 0xFE0F) {
            emoji_vs[cp].is_emoji = true;
        } else {
            std.log.err("Unknown Emoji Variation Selector: {x}", .{vs});
        }
    }
}

fn parseBlocks(
    allocator: std.mem.Allocator,
    blocks: []types.Block,
) !void {
    @memset(blocks, .no_block);

    const file_path = "ucd/Blocks.txt";

    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = trim(line);
        if (trimmed.len == 0) continue;

        var parts = std.mem.splitScalar(u8, trimmed, ';');
        const cp_str = std.mem.trim(u8, parts.next().?, " \t\r");
        const block_name = std.mem.trim(u8, parts.next().?, " \t\r");

        const range = try parseRange(cp_str);

        const block = block_name_map.get(block_name) orelse blk: {
            std.log.err("Unknown block name: {s}", .{block_name});
            if (!config.is_updating_ucd) {
                unreachable;
            } else {
                break :blk .no_block;
            }
        };

        var cp: u21 = range.start;
        while (cp <= range.end) : (cp += 1) {
            blocks[cp] = block;
        }
    }
}

const block_name_map = std.StaticStringMap(types.Block).initComptime(.{
    .{ "Adlam", .adlam },
    .{ "Aegean Numbers", .aegean_numbers },
    .{ "Ahom", .ahom },
    .{ "Alchemical Symbols", .alchemical_symbols },
    .{ "Alphabetic Presentation Forms", .alphabetic_presentation_forms },
    .{ "Anatolian Hieroglyphs", .anatolian_hieroglyphs },
    .{ "Ancient Greek Musical Notation", .ancient_greek_musical_notation },
    .{ "Ancient Greek Numbers", .ancient_greek_numbers },
    .{ "Ancient Symbols", .ancient_symbols },
    .{ "Arabic Extended-A", .arabic_extended_a },
    .{ "Arabic Extended-B", .arabic_extended_b },
    .{ "Arabic Extended-C", .arabic_extended_c },
    .{ "Arabic Mathematical Alphabetic Symbols", .arabic_mathematical_alphabetic_symbols },
    .{ "Arabic Presentation Forms-A", .arabic_presentation_forms_a },
    .{ "Arabic Presentation Forms-B", .arabic_presentation_forms_b },
    .{ "Arabic Supplement", .arabic_supplement },
    .{ "Arabic", .arabic },
    .{ "Armenian", .armenian },
    .{ "Arrows", .arrows },
    .{ "Avestan", .avestan },
    .{ "Balinese", .balinese },
    .{ "Bamum Supplement", .bamum_supplement },
    .{ "Bamum", .bamum },
    .{ "Basic Latin", .basic_latin },
    .{ "Bassa Vah", .bassa_vah },
    .{ "Batak", .batak },
    .{ "Bengali", .bengali },
    .{ "Beria Erfe", .beria_erfe },
    .{ "Bhaiksuki", .bhaiksuki },
    .{ "Block Elements", .block_elements },
    .{ "Bopomofo Extended", .bopomofo_extended },
    .{ "Bopomofo", .bopomofo },
    .{ "Box Drawing", .box_drawing },
    .{ "Brahmi", .brahmi },
    .{ "Braille Patterns", .braille_patterns },
    .{ "Buginese", .buginese },
    .{ "Buhid", .buhid },
    .{ "Byzantine Musical Symbols", .byzantine_musical_symbols },
    .{ "CJK Compatibility Forms", .cjk_compatibility_forms },
    .{ "CJK Compatibility Ideographs Supplement", .cjk_compatibility_ideographs_supplement },
    .{ "CJK Compatibility Ideographs", .cjk_compatibility_ideographs },
    .{ "CJK Compatibility", .cjk_compatibility },
    .{ "CJK Radicals Supplement", .cjk_radicals_supplement },
    .{ "CJK Strokes", .cjk_strokes },
    .{ "CJK Symbols and Punctuation", .cjk_symbols_and_punctuation },
    .{ "CJK Unified Ideographs Extension A", .cjk_unified_ideographs_extension_a },
    .{ "CJK Unified Ideographs Extension B", .cjk_unified_ideographs_extension_b },
    .{ "CJK Unified Ideographs Extension C", .cjk_unified_ideographs_extension_c },
    .{ "CJK Unified Ideographs Extension D", .cjk_unified_ideographs_extension_d },
    .{ "CJK Unified Ideographs Extension E", .cjk_unified_ideographs_extension_e },
    .{ "CJK Unified Ideographs Extension F", .cjk_unified_ideographs_extension_f },
    .{ "CJK Unified Ideographs Extension G", .cjk_unified_ideographs_extension_g },
    .{ "CJK Unified Ideographs Extension H", .cjk_unified_ideographs_extension_h },
    .{ "CJK Unified Ideographs Extension I", .cjk_unified_ideographs_extension_i },
    .{ "CJK Unified Ideographs Extension J", .cjk_unified_ideographs_extension_j },
    .{ "CJK Unified Ideographs", .cjk_unified_ideographs },
    .{ "Carian", .carian },
    .{ "Caucasian Albanian", .caucasian_albanian },
    .{ "Chakma", .chakma },
    .{ "Cham", .cham },
    .{ "Cherokee Supplement", .cherokee_supplement },
    .{ "Cherokee", .cherokee },
    .{ "Chess Symbols", .chess_symbols },
    .{ "Chorasmian", .chorasmian },
    .{ "Combining Diacritical Marks Extended", .combining_diacritical_marks_extended },
    .{ "Combining Diacritical Marks Supplement", .combining_diacritical_marks_supplement },
    .{ "Combining Diacritical Marks for Symbols", .combining_diacritical_marks_for_symbols },
    .{ "Combining Diacritical Marks", .combining_diacritical_marks },
    .{ "Combining Half Marks", .combining_half_marks },
    .{ "Common Indic Number Forms", .common_indic_number_forms },
    .{ "Control Pictures", .control_pictures },
    .{ "Coptic Epact Numbers", .coptic_epact_numbers },
    .{ "Coptic", .coptic },
    .{ "Counting Rod Numerals", .counting_rod_numerals },
    .{ "Cuneiform Numbers and Punctuation", .cuneiform_numbers_and_punctuation },
    .{ "Cuneiform", .cuneiform },
    .{ "Currency Symbols", .currency_symbols },
    .{ "Cypriot Syllabary", .cypriot_syllabary },
    .{ "Cypro-Minoan", .cypro_minoan },
    .{ "Cyrillic Extended-A", .cyrillic_extended_a },
    .{ "Cyrillic Extended-B", .cyrillic_extended_b },
    .{ "Cyrillic Extended-C", .cyrillic_extended_c },
    .{ "Cyrillic Extended-D", .cyrillic_extended_d },
    .{ "Cyrillic Supplement", .cyrillic_supplement },
    .{ "Cyrillic", .cyrillic },
    .{ "Deseret", .deseret },
    .{ "Devanagari Extended", .devanagari_extended },
    .{ "Devanagari Extended-A", .devanagari_extended_a },
    .{ "Devanagari", .devanagari },
    .{ "Dingbats", .dingbats },
    .{ "Dives Akuru", .dives_akuru },
    .{ "Dogra", .dogra },
    .{ "Domino Tiles", .domino_tiles },
    .{ "Duployan", .duployan },
    .{ "Early Dynastic Cuneiform", .early_dynastic_cuneiform },
    .{ "Egyptian Hieroglyph Format Controls", .egyptian_hieroglyph_format_controls },
    .{ "Egyptian Hieroglyphs Extended-A", .egyptian_hieroglyphs_extended_a },
    .{ "Egyptian Hieroglyphs", .egyptian_hieroglyphs },
    .{ "Elbasan", .elbasan },
    .{ "Elymaic", .elymaic },
    .{ "Emoticons", .emoticons },
    .{ "Enclosed Alphanumeric Supplement", .enclosed_alphanumeric_supplement },
    .{ "Enclosed Alphanumerics", .enclosed_alphanumerics },
    .{ "Enclosed CJK Letters and Months", .enclosed_cjk_letters_and_months },
    .{ "Enclosed Ideographic Supplement", .enclosed_ideographic_supplement },
    .{ "Ethiopic Extended", .ethiopic_extended },
    .{ "Ethiopic Extended-A", .ethiopic_extended_a },
    .{ "Ethiopic Extended-B", .ethiopic_extended_b },
    .{ "Ethiopic Supplement", .ethiopic_supplement },
    .{ "Ethiopic", .ethiopic },
    .{ "Garay", .garay },
    .{ "General Punctuation", .general_punctuation },
    .{ "Geometric Shapes Extended", .geometric_shapes_extended },
    .{ "Geometric Shapes", .geometric_shapes },
    .{ "Georgian Extended", .georgian_extended },
    .{ "Georgian Supplement", .georgian_supplement },
    .{ "Georgian", .georgian },
    .{ "Glagolitic Supplement", .glagolitic_supplement },
    .{ "Glagolitic", .glagolitic },
    .{ "Gothic", .gothic },
    .{ "Grantha", .grantha },
    .{ "Greek Extended", .greek_extended },
    .{ "Greek and Coptic", .greek_and_coptic },
    .{ "Gujarati", .gujarati },
    .{ "Gunjala Gondi", .gunjala_gondi },
    .{ "Gurmukhi", .gurmukhi },
    .{ "Gurung Khema", .gurung_khema },
    .{ "Halfwidth and Fullwidth Forms", .halfwidth_and_fullwidth_forms },
    .{ "Hangul Compatibility Jamo", .hangul_compatibility_jamo },
    .{ "Hangul Jamo Extended-A", .hangul_jamo_extended_a },
    .{ "Hangul Jamo Extended-B", .hangul_jamo_extended_b },
    .{ "Hangul Jamo", .hangul_jamo },
    .{ "Hangul Syllables", .hangul_syllables },
    .{ "Hanifi Rohingya", .hanifi_rohingya },
    .{ "Hanunoo", .hanunoo },
    .{ "Hatran", .hatran },
    .{ "Hebrew", .hebrew },
    .{ "High Private Use Surrogates", .high_private_use_surrogates },
    .{ "High Surrogates", .high_surrogates },
    .{ "Hiragana", .hiragana },
    .{ "IPA Extensions", .ipa_extensions },
    .{ "Ideographic Description Characters", .ideographic_description_characters },
    .{ "Ideographic Symbols and Punctuation", .ideographic_symbols_and_punctuation },
    .{ "Imperial Aramaic", .imperial_aramaic },
    .{ "Indic Siyaq Numbers", .indic_siyaq_numbers },
    .{ "Inscriptional Pahlavi", .inscriptional_pahlavi },
    .{ "Inscriptional Parthian", .inscriptional_parthian },
    .{ "Javanese", .javanese },
    .{ "Kaithi", .kaithi },
    .{ "Kaktovik Numerals", .kaktovik_numerals },
    .{ "Kana Extended-A", .kana_extended_a },
    .{ "Kana Extended-B", .kana_extended_b },
    .{ "Kana Supplement", .kana_supplement },
    .{ "Kanbun", .kanbun },
    .{ "Kangxi Radicals", .kangxi_radicals },
    .{ "Kannada", .kannada },
    .{ "Katakana Phonetic Extensions", .katakana_phonetic_extensions },
    .{ "Katakana", .katakana },
    .{ "Kawi", .kawi },
    .{ "Kayah Li", .kayah_li },
    .{ "Kharoshthi", .kharoshthi },
    .{ "Khitan Small Script", .khitan_small_script },
    .{ "Khmer Symbols", .khmer_symbols },
    .{ "Khmer", .khmer },
    .{ "Khojki", .khojki },
    .{ "Khudawadi", .khudawadi },
    .{ "Kirat Rai", .kirat_rai },
    .{ "Lao", .lao },
    .{ "Latin Extended Additional", .latin_extended_additional },
    .{ "Latin Extended-A", .latin_extended_a },
    .{ "Latin Extended-B", .latin_extended_b },
    .{ "Latin Extended-C", .latin_extended_c },
    .{ "Latin Extended-D", .latin_extended_d },
    .{ "Latin Extended-E", .latin_extended_e },
    .{ "Latin Extended-F", .latin_extended_f },
    .{ "Latin Extended-G", .latin_extended_g },
    .{ "Latin-1 Supplement", .latin_1_supplement },
    .{ "Lepcha", .lepcha },
    .{ "Letterlike Symbols", .letterlike_symbols },
    .{ "Limbu", .limbu },
    .{ "Linear A", .linear_a },
    .{ "Linear B Ideograms", .linear_b_ideograms },
    .{ "Linear B Syllabary", .linear_b_syllabary },
    .{ "Lisu Supplement", .lisu_supplement },
    .{ "Lisu", .lisu },
    .{ "Low Surrogates", .low_surrogates },
    .{ "Lycian", .lycian },
    .{ "Lydian", .lydian },
    .{ "Mahajani", .mahajani },
    .{ "Mahjong Tiles", .mahjong_tiles },
    .{ "Makasar", .makasar },
    .{ "Malayalam", .malayalam },
    .{ "Mandaic", .mandaic },
    .{ "Manichaean", .manichaean },
    .{ "Marchen", .marchen },
    .{ "Masaram Gondi", .masaram_gondi },
    .{ "Mathematical Alphanumeric Symbols", .mathematical_alphanumeric_symbols },
    .{ "Mathematical Operators", .mathematical_operators },
    .{ "Mayan Numerals", .mayan_numerals },
    .{ "Medefaidrin", .medefaidrin },
    .{ "Meetei Mayek Extensions", .meetei_mayek_extensions },
    .{ "Meetei Mayek", .meetei_mayek },
    .{ "Mende Kikakui", .mende_kikakui },
    .{ "Meroitic Cursive", .meroitic_cursive },
    .{ "Meroitic Hieroglyphs", .meroitic_hieroglyphs },
    .{ "Miao", .miao },
    .{ "Miscellaneous Mathematical Symbols-A", .miscellaneous_mathematical_symbols_a },
    .{ "Miscellaneous Mathematical Symbols-B", .miscellaneous_mathematical_symbols_b },
    .{ "Miscellaneous Symbols Supplement", .miscellaneous_symbols_supplement },
    .{ "Miscellaneous Symbols and Arrows", .miscellaneous_symbols_and_arrows },
    .{ "Miscellaneous Symbols and Pictographs", .miscellaneous_symbols_and_pictographs },
    .{ "Miscellaneous Symbols", .miscellaneous_symbols },
    .{ "Miscellaneous Technical", .miscellaneous_technical },
    .{ "Modi", .modi },
    .{ "Modifier Tone Letters", .modifier_tone_letters },
    .{ "Mongolian Supplement", .mongolian_supplement },
    .{ "Mongolian", .mongolian },
    .{ "Mro", .mro },
    .{ "Multani", .multani },
    .{ "Musical Symbols", .musical_symbols },
    .{ "Myanmar Extended-A", .myanmar_extended_a },
    .{ "Myanmar Extended-B", .myanmar_extended_b },
    .{ "Myanmar Extended-C", .myanmar_extended_c },
    .{ "Myanmar", .myanmar },
    .{ "NKo", .nko },
    .{ "Nabataean", .nabataean },
    .{ "Nag Mundari", .nag_mundari },
    .{ "Nandinagari", .nandinagari },
    .{ "New Tai Lue", .new_tai_lue },
    .{ "Newa", .newa },
    .{ "Number Forms", .number_forms },
    .{ "Nushu", .nushu },
    .{ "Nyiakeng Puachue Hmong", .nyiakeng_puachue_hmong },
    .{ "Ogham", .ogham },
    .{ "Ol Chiki", .ol_chiki },
    .{ "Ol Onal", .ol_onal },
    .{ "Old Hungarian", .old_hungarian },
    .{ "Old Italic", .old_italic },
    .{ "Old North Arabian", .old_north_arabian },
    .{ "Old Permic", .old_permic },
    .{ "Old Persian", .old_persian },
    .{ "Old Sogdian", .old_sogdian },
    .{ "Old South Arabian", .old_south_arabian },
    .{ "Old Turkic", .old_turkic },
    .{ "Old Uyghur", .old_uyghur },
    .{ "Optical Character Recognition", .optical_character_recognition },
    .{ "Oriya", .oriya },
    .{ "Ornamental Dingbats", .ornamental_dingbats },
    .{ "Osage", .osage },
    .{ "Osmanya", .osmanya },
    .{ "Ottoman Siyaq Numbers", .ottoman_siyaq_numbers },
    .{ "Pahawh Hmong", .pahawh_hmong },
    .{ "Palmyrene", .palmyrene },
    .{ "Pau Cin Hau", .pau_cin_hau },
    .{ "Phags-pa", .phags_pa },
    .{ "Phaistos Disc", .phaistos_disc },
    .{ "Phoenician", .phoenician },
    .{ "Phonetic Extensions Supplement", .phonetic_extensions_supplement },
    .{ "Phonetic Extensions", .phonetic_extensions },
    .{ "Playing Cards", .playing_cards },
    .{ "Private Use Area", .private_use_area },
    .{ "Psalter Pahlavi", .psalter_pahlavi },
    .{ "Rejang", .rejang },
    .{ "Rumi Numeral Symbols", .rumi_numeral_symbols },
    .{ "Runic", .runic },
    .{ "Samaritan", .samaritan },
    .{ "Saurashtra", .saurashtra },
    .{ "Sharada Supplement", .sharada_supplement },
    .{ "Sharada", .sharada },
    .{ "Shavian", .shavian },
    .{ "Shorthand Format Controls", .shorthand_format_controls },
    .{ "Siddham", .siddham },
    .{ "Sidetic", .sidetic },
    .{ "Sinhala Archaic Numbers", .sinhala_archaic_numbers },
    .{ "Sinhala", .sinhala },
    .{ "Small Form Variants", .small_form_variants },
    .{ "Small Kana Extension", .small_kana_extension },
    .{ "Sogdian", .sogdian },
    .{ "Sora Sompeng", .sora_sompeng },
    .{ "Soyombo", .soyombo },
    .{ "Spacing Modifier Letters", .spacing_modifier_letters },
    .{ "Specials", .specials },
    .{ "Sundanese Supplement", .sundanese_supplement },
    .{ "Sundanese", .sundanese },
    .{ "Sunuwar", .sunuwar },
    .{ "Superscripts and Subscripts", .superscripts_and_subscripts },
    .{ "Supplemental Arrows-A", .supplemental_arrows_a },
    .{ "Supplemental Arrows-B", .supplemental_arrows_b },
    .{ "Supplemental Arrows-C", .supplemental_arrows_c },
    .{ "Supplemental Mathematical Operators", .supplemental_mathematical_operators },
    .{ "Supplemental Punctuation", .supplemental_punctuation },
    .{ "Supplemental Symbols and Pictographs", .supplemental_symbols_and_pictographs },
    .{ "Supplementary Private Use Area-A", .supplementary_private_use_area_a },
    .{ "Supplementary Private Use Area-B", .supplementary_private_use_area_b },
    .{ "Sutton SignWriting", .sutton_signwriting },
    .{ "Syloti Nagri", .syloti_nagri },
    .{ "Symbols and Pictographs Extended-A", .symbols_and_pictographs_extended_a },
    .{ "Symbols for Legacy Computing Supplement", .symbols_for_legacy_computing_supplement },
    .{ "Symbols for Legacy Computing", .symbols_for_legacy_computing },
    .{ "Syriac Supplement", .syriac_supplement },
    .{ "Syriac", .syriac },
    .{ "Tagalog", .tagalog },
    .{ "Tagbanwa", .tagbanwa },
    .{ "Tags", .tags },
    .{ "Tai Le", .tai_le },
    .{ "Tai Tham", .tai_tham },
    .{ "Tai Viet", .tai_viet },
    .{ "Tai Xuan Jing Symbols", .tai_xuan_jing_symbols },
    .{ "Tai Yo", .tai_yo },
    .{ "Takri", .takri },
    .{ "Tamil Supplement", .tamil_supplement },
    .{ "Tamil", .tamil },
    .{ "Tangsa", .tangsa },
    .{ "Tangut Components Supplement", .tangut_components_supplement },
    .{ "Tangut Components", .tangut_components },
    .{ "Tangut Supplement", .tangut_supplement },
    .{ "Tangut", .tangut },
    .{ "Telugu", .telugu },
    .{ "Thaana", .thaana },
    .{ "Thai", .thai },
    .{ "Tibetan", .tibetan },
    .{ "Tifinagh", .tifinagh },
    .{ "Tirhuta", .tirhuta },
    .{ "Todhri", .todhri },
    .{ "Tolong Siki", .tolong_siki },
    .{ "Toto", .toto },
    .{ "Transport and Map Symbols", .transport_and_map_symbols },
    .{ "Tulu-Tigalari", .tulu_tigalari },
    .{ "Ugaritic", .ugaritic },
    .{ "Unified Canadian Aboriginal Syllabics Extended", .unified_canadian_aboriginal_syllabics_extended },
    .{ "Unified Canadian Aboriginal Syllabics Extended-A", .unified_canadian_aboriginal_syllabics_extended_a },
    .{ "Unified Canadian Aboriginal Syllabics", .unified_canadian_aboriginal_syllabics },
    .{ "Vai", .vai },
    .{ "Variation Selectors Supplement", .variation_selectors_supplement },
    .{ "Variation Selectors", .variation_selectors },
    .{ "Vedic Extensions", .vedic_extensions },
    .{ "Vertical Forms", .vertical_forms },
    .{ "Vithkuqi", .vithkuqi },
    .{ "Wancho", .wancho },
    .{ "Warang Citi", .warang_citi },
    .{ "Yezidi", .yezidi },
    .{ "Yi Radicals", .yi_radicals },
    .{ "Yi Syllables", .yi_syllables },
    .{ "Yijing Hexagram Symbols", .yijing_hexagram_symbols },
    .{ "Zanabazar Square", .zanabazar_square },
    .{ "Znamenny Musical Notation", .znamenny_musical_notation },
});

fn parseScripts(
    allocator: std.mem.Allocator,
    scripts: []types.Script,
) !void {
    @memset(scripts, .unknown);

    const file_path = "ucd/Scripts.txt";

    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = trim(line);
        if (trimmed.len == 0) continue;

        var parts = std.mem.splitScalar(u8, trimmed, ';');
        const cp_str = std.mem.trim(u8, parts.next().?, " \t\r");
        const script_name = std.mem.trim(u8, parts.next().?, " \t\r");

        const range = try parseRange(cp_str);
        const script = script_name_map.get(script_name) orelse blk: {
            std.log.err("Unknown script name: {s}", .{script_name});
            if (!config.is_updating_ucd) {
                unreachable;
            } else {
                break :blk .unknown;
            }
        };

        var cp: u21 = range.start;
        while (cp <= range.end) : (cp += 1) {
            scripts[cp] = script;
        }
    }
}

const script_name_map = std.StaticStringMap(types.Script).initComptime(.{
    .{ "Adlam", .adlam },
    .{ "Ahom", .ahom },
    .{ "Anatolian_Hieroglyphs", .anatolian_hieroglyphs },
    .{ "Arabic", .arabic },
    .{ "Armenian", .armenian },
    .{ "Avestan", .avestan },
    .{ "Balinese", .balinese },
    .{ "Bamum", .bamum },
    .{ "Bassa_Vah", .bassa_vah },
    .{ "Batak", .batak },
    .{ "Bengali", .bengali },
    .{ "Beria_Erfe", .beria_erfe },
    .{ "Bhaiksuki", .bhaiksuki },
    .{ "Bopomofo", .bopomofo },
    .{ "Brahmi", .brahmi },
    .{ "Braille", .braille },
    .{ "Buginese", .buginese },
    .{ "Buhid", .buhid },
    .{ "Canadian_Aboriginal", .canadian_aboriginal },
    .{ "Carian", .carian },
    .{ "Caucasian_Albanian", .caucasian_albanian },
    .{ "Chakma", .chakma },
    .{ "Cham", .cham },
    .{ "Cherokee", .cherokee },
    .{ "Chorasmian", .chorasmian },
    .{ "Common", .common },
    .{ "Coptic", .coptic },
    .{ "Cuneiform", .cuneiform },
    .{ "Cypriot", .cypriot },
    .{ "Cypro_Minoan", .cypro_minoan },
    .{ "Cyrillic", .cyrillic },
    .{ "Deseret", .deseret },
    .{ "Devanagari", .devanagari },
    .{ "Dives_Akuru", .dives_akuru },
    .{ "Dogra", .dogra },
    .{ "Duployan", .duployan },
    .{ "Egyptian_Hieroglyphs", .egyptian_hieroglyphs },
    .{ "Elbasan", .elbasan },
    .{ "Elymaic", .elymaic },
    .{ "Ethiopic", .ethiopic },
    .{ "Garay", .garay },
    .{ "Georgian", .georgian },
    .{ "Glagolitic", .glagolitic },
    .{ "Gothic", .gothic },
    .{ "Grantha", .grantha },
    .{ "Greek", .greek },
    .{ "Gujarati", .gujarati },
    .{ "Gunjala_Gondi", .gunjala_gondi },
    .{ "Gurmukhi", .gurmukhi },
    .{ "Gurung_Khema", .gurung_khema },
    .{ "Han", .han },
    .{ "Hangul", .hangul },
    .{ "Hanifi_Rohingya", .hanifi_rohingya },
    .{ "Hanunoo", .hanunoo },
    .{ "Hatran", .hatran },
    .{ "Hebrew", .hebrew },
    .{ "Hiragana", .hiragana },
    .{ "Imperial_Aramaic", .imperial_aramaic },
    .{ "Inherited", .inherited },
    .{ "Inscriptional_Pahlavi", .inscriptional_pahlavi },
    .{ "Inscriptional_Parthian", .inscriptional_parthian },
    .{ "Javanese", .javanese },
    .{ "Kaithi", .kaithi },
    .{ "Kannada", .kannada },
    .{ "Katakana", .katakana },
    .{ "Kawi", .kawi },
    .{ "Kayah_Li", .kayah_li },
    .{ "Kharoshthi", .kharoshthi },
    .{ "Khitan_Small_Script", .khitan_small_script },
    .{ "Khmer", .khmer },
    .{ "Khojki", .khojki },
    .{ "Khudawadi", .khudawadi },
    .{ "Kirat_Rai", .kirat_rai },
    .{ "Lao", .lao },
    .{ "Latin", .latin },
    .{ "Lepcha", .lepcha },
    .{ "Limbu", .limbu },
    .{ "Linear_A", .linear_a },
    .{ "Linear_B", .linear_b },
    .{ "Lisu", .lisu },
    .{ "Lycian", .lycian },
    .{ "Lydian", .lydian },
    .{ "Mahajani", .mahajani },
    .{ "Makasar", .makasar },
    .{ "Malayalam", .malayalam },
    .{ "Mandaic", .mandaic },
    .{ "Manichaean", .manichaean },
    .{ "Marchen", .marchen },
    .{ "Masaram_Gondi", .masaram_gondi },
    .{ "Medefaidrin", .medefaidrin },
    .{ "Meetei_Mayek", .meetei_mayek },
    .{ "Mende_Kikakui", .mende_kikakui },
    .{ "Meroitic_Cursive", .meroitic_cursive },
    .{ "Meroitic_Hieroglyphs", .meroitic_hieroglyphs },
    .{ "Miao", .miao },
    .{ "Modi", .modi },
    .{ "Mongolian", .mongolian },
    .{ "Mro", .mro },
    .{ "Multani", .multani },
    .{ "Myanmar", .myanmar },
    .{ "Nabataean", .nabataean },
    .{ "Nag_Mundari", .nag_mundari },
    .{ "Nandinagari", .nandinagari },
    .{ "New_Tai_Lue", .new_tai_lue },
    .{ "Newa", .newa },
    .{ "Nko", .nko },
    .{ "Nushu", .nushu },
    .{ "Nyiakeng_Puachue_Hmong", .nyiakeng_puachue_hmong },
    .{ "Ogham", .ogham },
    .{ "Ol_Chiki", .ol_chiki },
    .{ "Ol_Onal", .ol_onal },
    .{ "Old_Hungarian", .old_hungarian },
    .{ "Old_Italic", .old_italic },
    .{ "Old_North_Arabian", .old_north_arabian },
    .{ "Old_Permic", .old_permic },
    .{ "Old_Persian", .old_persian },
    .{ "Old_Sogdian", .old_sogdian },
    .{ "Old_South_Arabian", .old_south_arabian },
    .{ "Old_Turkic", .old_turkic },
    .{ "Old_Uyghur", .old_uyghur },
    .{ "Oriya", .oriya },
    .{ "Osage", .osage },
    .{ "Osmanya", .osmanya },
    .{ "Pahawh_Hmong", .pahawh_hmong },
    .{ "Palmyrene", .palmyrene },
    .{ "Pau_Cin_Hau", .pau_cin_hau },
    .{ "Phags_Pa", .phags_pa },
    .{ "Phoenician", .phoenician },
    .{ "Psalter_Pahlavi", .psalter_pahlavi },
    .{ "Rejang", .rejang },
    .{ "Runic", .runic },
    .{ "Samaritan", .samaritan },
    .{ "Saurashtra", .saurashtra },
    .{ "Sharada", .sharada },
    .{ "Shavian", .shavian },
    .{ "Siddham", .siddham },
    .{ "Sidetic", .sidetic },
    .{ "SignWriting", .signwriting },
    .{ "Sinhala", .sinhala },
    .{ "Sogdian", .sogdian },
    .{ "Sora_Sompeng", .sora_sompeng },
    .{ "Soyombo", .soyombo },
    .{ "Sundanese", .sundanese },
    .{ "Sunuwar", .sunuwar },
    .{ "Syloti_Nagri", .syloti_nagri },
    .{ "Syriac", .syriac },
    .{ "Tagalog", .tagalog },
    .{ "Tagbanwa", .tagbanwa },
    .{ "Tai_Le", .tai_le },
    .{ "Tai_Tham", .tai_tham },
    .{ "Tai_Viet", .tai_viet },
    .{ "Tai_Yo", .tai_yo },
    .{ "Takri", .takri },
    .{ "Tamil", .tamil },
    .{ "Tangsa", .tangsa },
    .{ "Tangut", .tangut },
    .{ "Telugu", .telugu },
    .{ "Thaana", .thaana },
    .{ "Thai", .thai },
    .{ "Tibetan", .tibetan },
    .{ "Tifinagh", .tifinagh },
    .{ "Tirhuta", .tirhuta },
    .{ "Todhri", .todhri },
    .{ "Tolong_Siki", .tolong_siki },
    .{ "Toto", .toto },
    .{ "Tulu_Tigalari", .tulu_tigalari },
    .{ "Ugaritic", .ugaritic },
    .{ "Vai", .vai },
    .{ "Vithkuqi", .vithkuqi },
    .{ "Wancho", .wancho },
    .{ "Warang_Citi", .warang_citi },
    .{ "Yezidi", .yezidi },
    .{ "Yi", .yi },
    .{ "Zanabazar_Square", .zanabazar_square },
});

fn parseJoiningType(
    allocator: std.mem.Allocator,
    joining_types: []types.JoiningType,
) !void {
    @memset(joining_types, .non_joining);

    const file_path = "ucd/extracted/DerivedJoiningType.txt";

    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = trim(line);
        if (trimmed.len == 0) continue;

        var parts = std.mem.splitScalar(u8, trimmed, ';');
        const cp_str = std.mem.trim(u8, parts.next().?, " \t\r");
        const jt_str = std.mem.trim(u8, parts.next().?, " \t\r");

        const range = try parseRange(cp_str);
        const jt = joining_type_map.get(jt_str) orelse blk: {
            std.log.err("Unknown joining type: {s}", .{jt_str});
            if (!config.is_updating_ucd) {
                unreachable;
            } else {
                break :blk .non_joining;
            }
        };

        var cp: u21 = range.start;
        while (cp <= range.end) : (cp += 1) {
            joining_types[cp] = jt;
        }
    }
}

const joining_type_map = std.StaticStringMap(types.JoiningType).initComptime(.{
    .{ "C", .join_causing },
    .{ "D", .dual_joining },
    .{ "L", .left_joining },
    .{ "R", .right_joining },
    .{ "T", .transparent },
});

fn parseJoiningGroup(
    allocator: std.mem.Allocator,
    joining_groups: []types.JoiningGroup,
) !void {
    @memset(joining_groups, .no_joining_group);

    const file_path = "ucd/extracted/DerivedJoiningGroup.txt";

    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = trim(line);
        if (trimmed.len == 0) continue;

        var parts = std.mem.splitScalar(u8, trimmed, ';');
        const cp_str = std.mem.trim(u8, parts.next().?, " \t\r");
        const jg_str = std.mem.trim(u8, parts.next().?, " \t\r");

        const range = try parseRange(cp_str);
        const jg = joining_group_map.get(jg_str) orelse blk: {
            std.log.err("Unknown joining group: {s}", .{jg_str});
            if (!config.is_updating_ucd) {
                unreachable;
            } else {
                break :blk .no_joining_group;
            }
        };

        var cp: u21 = range.start;
        while (cp <= range.end) : (cp += 1) {
            joining_groups[cp] = jg;
        }
    }
}

const joining_group_map = std.StaticStringMap(types.JoiningGroup).initComptime(.{
    .{ "No_Joining_Group", .no_joining_group },
    .{ "African_Feh", .african_feh },
    .{ "African_Noon", .african_noon },
    .{ "African_Qaf", .african_qaf },
    .{ "Ain", .ain },
    .{ "Alaph", .alaph },
    .{ "Alef", .alef },
    .{ "Beh", .beh },
    .{ "Beth", .beth },
    .{ "Burushaski_Yeh_Barree", .burushaski_yeh_barree },
    .{ "Dal", .dal },
    .{ "Dalath_Rish", .dalath_rish },
    .{ "E", .e },
    .{ "Farsi_Yeh", .farsi_yeh },
    .{ "Fe", .fe },
    .{ "Feh", .feh },
    .{ "Final_Semkath", .final_semkath },
    .{ "Gaf", .gaf },
    .{ "Gamal", .gamal },
    .{ "Hah", .hah },
    .{ "Hanifi_Rohingya_Kinna_Ya", .hanifi_rohingya_kinna_ya },
    .{ "Hanifi_Rohingya_Pa", .hanifi_rohingya_pa },
    .{ "He", .he },
    .{ "Heh", .heh },
    .{ "Heh_Goal", .heh_goal },
    .{ "Heth", .heth },
    .{ "Kaf", .kaf },
    .{ "Kaph", .kaph },
    .{ "Kashmiri_Yeh", .kashmiri_yeh },
    .{ "Khaph", .khaph },
    .{ "Knotted_Heh", .knotted_heh },
    .{ "Lam", .lam },
    .{ "Lamadh", .lamadh },
    .{ "Malayalam_Bha", .malayalam_bha },
    .{ "Malayalam_Ja", .malayalam_ja },
    .{ "Malayalam_Lla", .malayalam_lla },
    .{ "Malayalam_Llla", .malayalam_llla },
    .{ "Malayalam_Nga", .malayalam_nga },
    .{ "Malayalam_Nna", .malayalam_nna },
    .{ "Malayalam_Nnna", .malayalam_nnna },
    .{ "Malayalam_Nya", .malayalam_nya },
    .{ "Malayalam_Ra", .malayalam_ra },
    .{ "Malayalam_Ssa", .malayalam_ssa },
    .{ "Malayalam_Tta", .malayalam_tta },
    .{ "Manichaean_Aleph", .manichaean_aleph },
    .{ "Manichaean_Ayin", .manichaean_ayin },
    .{ "Manichaean_Beth", .manichaean_beth },
    .{ "Manichaean_Daleth", .manichaean_daleth },
    .{ "Manichaean_Dhamedh", .manichaean_dhamedh },
    .{ "Manichaean_Five", .manichaean_five },
    .{ "Manichaean_Gimel", .manichaean_gimel },
    .{ "Manichaean_Heth", .manichaean_heth },
    .{ "Manichaean_Hundred", .manichaean_hundred },
    .{ "Manichaean_Kaph", .manichaean_kaph },
    .{ "Manichaean_Lamedh", .manichaean_lamedh },
    .{ "Manichaean_Mem", .manichaean_mem },
    .{ "Manichaean_Nun", .manichaean_nun },
    .{ "Manichaean_One", .manichaean_one },
    .{ "Manichaean_Pe", .manichaean_pe },
    .{ "Manichaean_Qoph", .manichaean_qoph },
    .{ "Manichaean_Resh", .manichaean_resh },
    .{ "Manichaean_Sadhe", .manichaean_sadhe },
    .{ "Manichaean_Samekh", .manichaean_samekh },
    .{ "Manichaean_Taw", .manichaean_taw },
    .{ "Manichaean_Ten", .manichaean_ten },
    .{ "Manichaean_Teth", .manichaean_teth },
    .{ "Manichaean_Thamedh", .manichaean_thamedh },
    .{ "Manichaean_Twenty", .manichaean_twenty },
    .{ "Manichaean_Waw", .manichaean_waw },
    .{ "Manichaean_Yodh", .manichaean_yodh },
    .{ "Manichaean_Zayin", .manichaean_zayin },
    .{ "Meem", .meem },
    .{ "Mim", .mim },
    .{ "Noon", .noon },
    .{ "Nun", .nun },
    .{ "Nya", .nya },
    .{ "Pe", .pe },
    .{ "Qaf", .qaf },
    .{ "Qaph", .qaph },
    .{ "Reh", .reh },
    .{ "Reversed_Pe", .reversed_pe },
    .{ "Rohingya_Yeh", .rohingya_yeh },
    .{ "Sad", .sad },
    .{ "Sadhe", .sadhe },
    .{ "Seen", .seen },
    .{ "Semkath", .semkath },
    .{ "Shin", .shin },
    .{ "Straight_Waw", .straight_waw },
    .{ "Swash_Kaf", .swash_kaf },
    .{ "Syriac_Waw", .syriac_waw },
    .{ "Tah", .tah },
    .{ "Taw", .taw },
    .{ "Teh_Marbuta", .teh_marbuta },
    .{ "Teh_Marbuta_Goal", .teh_marbuta_goal },
    .{ "Teth", .teth },
    .{ "Thin_Noon", .thin_noon },
    .{ "Thin_Yeh", .thin_yeh },
    .{ "Vertical_Tail", .vertical_tail },
    .{ "Waw", .waw },
    .{ "Yeh", .yeh },
    .{ "Yeh_Barree", .yeh_barree },
    .{ "Yeh_With_Tail", .yeh_with_tail },
    .{ "Yudh", .yudh },
    .{ "Yudh_He", .yudh_he },
    .{ "Zain", .zain },
    .{ "Zhain", .zhain },
});

fn parseCompositionExclusions(
    allocator: std.mem.Allocator,
    is_composition_exclusions: []bool,
) !void {
    @memset(is_composition_exclusions, false);

    const file_path = "ucd/CompositionExclusions.txt";

    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = trim(line);
        if (trimmed.len == 0) continue;

        const cp_str = trimmed;
        const range = try parseRange(cp_str);

        var cp: u21 = range.start;
        while (cp <= range.end) : (cp += 1) {
            is_composition_exclusions[cp] = true;
        }
    }
}

fn parseIndicPositionalCategory(
    allocator: std.mem.Allocator,
    indic_positional_category: []types.IndicPositionalCategory,
) !void {
    @memset(indic_positional_category, .not_applicable);

    const file_path = "ucd/IndicPositionalCategory.txt";

    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = trim(line);
        if (trimmed.len == 0) continue;

        var parts = std.mem.splitScalar(u8, trimmed, ';');
        const cp_str = std.mem.trim(u8, parts.next().?, " \t\r");
        const ipc_str = std.mem.trim(u8, parts.next().?, " \t\r");

        const range = try parseRange(cp_str);
        const ipc = indic_positional_category_map.get(ipc_str) orelse blk: {
            std.log.err("Unknown indic positional category: {s}", .{ipc_str});
            if (!config.is_updating_ucd) {
                unreachable;
            } else {
                break :blk .not_applicable;
            }
        };

        var cp: u21 = range.start;
        while (cp <= range.end) : (cp += 1) {
            indic_positional_category[cp] = ipc;
        }
    }
}

const indic_positional_category_map = std.StaticStringMap(types.IndicPositionalCategory).initComptime(.{
    .{ "Not_Applicable", .not_applicable },
    .{ "Right", .right },
    .{ "Left", .left },
    .{ "Visual_Order_Left", .visual_order_left },
    .{ "Left_And_Right", .left_and_right },
    .{ "Top", .top },
    .{ "Bottom", .bottom },
    .{ "Top_And_Bottom", .top_and_bottom },
    .{ "Top_And_Right", .top_and_right },
    .{ "Top_And_Left", .top_and_left },
    .{ "Top_And_Left_And_Right", .top_and_left_and_right },
    .{ "Bottom_And_Right", .bottom_and_right },
    .{ "Bottom_And_Left", .bottom_and_left },
    .{ "Top_And_Bottom_And_Right", .top_and_bottom_and_right },
    .{ "Top_And_Bottom_And_Left", .top_and_bottom_and_left },
    .{ "Overstruck", .overstruck },
});

fn parseIndicSyllabicCategory(
    allocator: std.mem.Allocator,
    indic_syllabic_category: []types.IndicSyllabicCategory,
) !void {
    @memset(indic_syllabic_category, .other);

    const file_path = "ucd/IndicSyllabicCategory.txt";

    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = trim(line);
        if (trimmed.len == 0) continue;

        var parts = std.mem.splitScalar(u8, trimmed, ';');
        const cp_str = std.mem.trim(u8, parts.next().?, " \t\r");
        const isc_str = std.mem.trim(u8, parts.next().?, " \t\r");

        const range = try parseRange(cp_str);
        const ipc = indic_syllabic_category_map.get(isc_str) orelse blk: {
            std.log.err("Unknown indic syllabic category: {s}", .{isc_str});
            if (!config.is_updating_ucd) {
                unreachable;
            } else {
                break :blk .other;
            }
        };

        var cp: u21 = range.start;
        while (cp <= range.end) : (cp += 1) {
            indic_syllabic_category[cp] = ipc;
        }
    }
}

const indic_syllabic_category_map = std.StaticStringMap(types.IndicSyllabicCategory).initComptime(.{
    .{ "Other", .other },
    .{ "Bindu", .bindu },
    .{ "Visarga", .visarga },
    .{ "Avagraha", .avagraha },
    .{ "Nukta", .nukta },
    .{ "Virama", .virama },
    .{ "Pure_Killer", .pure_killer },
    .{ "Reordering_Killer", .reordering_killer },
    .{ "Invisible_Stacker", .invisible_stacker },
    .{ "Vowel_Independent", .vowel_independent },
    .{ "Vowel_Dependent", .vowel_dependent },
    .{ "Vowel", .vowel },
    .{ "Consonant_Placeholder", .consonant_placeholder },
    .{ "Consonant", .consonant },
    .{ "Consonant_Dead", .consonant_dead },
    .{ "Consonant_With_Stacker", .consonant_with_stacker },
    .{ "Consonant_Prefixed", .consonant_prefixed },
    .{ "Consonant_Preceding_Repha", .consonant_preceding_repha },
    .{ "Consonant_Initial_Postfixed", .consonant_initial_postfixed },
    .{ "Consonant_Succeeding_Repha", .consonant_succeeding_repha },
    .{ "Consonant_Subjoined", .consonant_subjoined },
    .{ "Consonant_Medial", .consonant_medial },
    .{ "Consonant_Final", .consonant_final },
    .{ "Consonant_Head_Letter", .consonant_head_letter },
    .{ "Modifying_Letter", .modifying_letter },
    .{ "Tone_Letter", .tone_letter },
    .{ "Tone_Mark", .tone_mark },
    .{ "Gemination_Mark", .gemination_mark },
    .{ "Cantillation_Mark", .cantillation_mark },
    .{ "Register_Shifter", .register_shifter },
    .{ "Syllable_Modifier", .syllable_modifier },
    .{ "Consonant_Killer", .consonant_killer },
    .{ "Non_Joiner", .non_joiner },
    .{ "Joiner", .joiner },
    .{ "Number_Joiner", .number_joiner },
    .{ "Number", .number },
    .{ "Brahmi_Joining_Number", .brahmi_joining_number },
});
