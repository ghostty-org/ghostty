const std = @import("std");
const testing = std.testing;

const itijah = @import("../lib.zig");
const BidiLevel = itijah.BidiLevel;
const ParDirection = itijah.ParDirection;

const bidi_test_data: []const u8 = @embedFile("BidiTest");
const bidi_char_test_data: []const u8 = @embedFile("BidiCharTest");

const ExpectedLevel = struct {
    ignored: bool,
    value: BidiLevel,
};

const Stats = struct {
    total: usize = 0,
    executed: usize = 0,
    passed: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,
};

const Mode = struct {
    name: []const u8,
    full: bool,
    max_bidi_cases: usize,
    max_char_cases: usize,
};

const bidi_class_names = [_]struct { name: []const u8, class: itijah.BidiClass }{
    .{ .name = "L", .class = .left_to_right },
    .{ .name = "R", .class = .right_to_left },
    .{ .name = "AL", .class = .right_to_left_arabic },
    .{ .name = "EN", .class = .european_number },
    .{ .name = "ES", .class = .european_number_separator },
    .{ .name = "ET", .class = .european_number_terminator },
    .{ .name = "AN", .class = .arabic_number },
    .{ .name = "CS", .class = .common_number_separator },
    .{ .name = "NSM", .class = .nonspacing_mark },
    .{ .name = "BN", .class = .boundary_neutral },
    .{ .name = "B", .class = .paragraph_separator },
    .{ .name = "S", .class = .segment_separator },
    .{ .name = "WS", .class = .whitespace },
    .{ .name = "ON", .class = .other_neutrals },
    .{ .name = "LRE", .class = .left_to_right_embedding },
    .{ .name = "LRO", .class = .left_to_right_override },
    .{ .name = "RLE", .class = .right_to_left_embedding },
    .{ .name = "RLO", .class = .right_to_left_override },
    .{ .name = "PDF", .class = .pop_directional_format },
    .{ .name = "LRI", .class = .left_to_right_isolate },
    .{ .name = "RLI", .class = .right_to_left_isolate },
    .{ .name = "FSI", .class = .first_strong_isolate },
    .{ .name = "PDI", .class = .pop_directional_isolate },
};

fn selectedMode() Mode {
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "ITIJAH_CONFORMANCE_MODE")) |mode_name| {
        defer std.heap.page_allocator.free(mode_name);
        if (std.ascii.eqlIgnoreCase(mode_name, "full")) {
            return .{
                .name = "full",
                .full = true,
                .max_bidi_cases = std.math.maxInt(usize),
                .max_char_cases = std.math.maxInt(usize),
            };
        }
    } else |_| {}

    if (std.process.getEnvVarOwned(std.heap.page_allocator, "ITIJAH_CONFORMANCE_FULL")) |flag| {
        defer std.heap.page_allocator.free(flag);
        if (std.mem.eql(u8, flag, "1") or std.ascii.eqlIgnoreCase(flag, "true")) {
            return .{
                .name = "full",
                .full = true,
                .max_bidi_cases = std.math.maxInt(usize),
                .max_char_cases = std.math.maxInt(usize),
            };
        }
    } else |_| {}

    return .{
        .name = "filtered",
        .full = false,
        .max_bidi_cases = 3000,
        .max_char_cases = 3000,
    };
}

fn classFromName(name: []const u8) ?itijah.BidiClass {
    for (bidi_class_names) |entry| {
        if (std.mem.eql(u8, name, entry.name)) return entry.class;
    }
    return null;
}

fn cpForClass(class: itijah.BidiClass) u21 {
    return switch (class) {
        .left_to_right => 'A',
        .right_to_left => 0x05D0,
        .right_to_left_arabic => 0x0627,
        .european_number => '0',
        .european_number_separator => '+',
        .european_number_terminator => '#',
        .arabic_number => 0x0660,
        .common_number_separator => ',',
        .nonspacing_mark => 0x0300,
        .boundary_neutral => 0x200B,
        .paragraph_separator => 0x000A,
        .segment_separator => 0x0009,
        .whitespace => ' ',
        .other_neutrals => '!',
        .left_to_right_embedding => 0x202A,
        .left_to_right_override => 0x202D,
        .right_to_left_embedding => 0x202B,
        .right_to_left_override => 0x202E,
        .pop_directional_format => 0x202C,
        .left_to_right_isolate => 0x2066,
        .right_to_left_isolate => 0x2067,
        .first_strong_isolate => 0x2068,
        .pop_directional_isolate => 0x2069,
    };
}

fn isFilteredBidiClass(class: itijah.BidiClass) bool {
    return switch (class) {
        .left_to_right,
        .right_to_left,
        .right_to_left_arabic,
        .european_number,
        .arabic_number,
        .european_number_separator,
        .european_number_terminator,
        .common_number_separator,
        .segment_separator,
        .paragraph_separator,
        .whitespace,
        .other_neutrals,
        => true,
        else => false,
    };
}

fn splitAndTrim(line: []const u8, sep: u8) struct { []const u8, []const u8 } {
    var parts = std.mem.splitScalar(u8, line, sep);
    const left = std.mem.trim(u8, parts.next() orelse "", " \t");
    const right = std.mem.trim(u8, parts.next() orelse "", " \t");
    return .{ left, right };
}

fn parseExpectedLevelsInto(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(ExpectedLevel),
    raw: []const u8,
) !void {
    out.clearRetainingCapacity();
    var iter = std.mem.tokenizeAny(u8, raw, " \t");
    while (iter.next()) |tok| {
        if (std.mem.eql(u8, tok, "x")) {
            try out.append(allocator, .{ .ignored = true, .value = 0 });
        } else {
            const level = try std.fmt.parseInt(u7, tok, 10);
            try out.append(allocator, .{ .ignored = false, .value = level });
        }
    }
}

fn parseExpectedOrderingInto(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u32),
    raw: []const u8,
) !void {
    out.clearRetainingCapacity();
    var iter = std.mem.tokenizeAny(u8, raw, " \t");
    while (iter.next()) |tok| {
        try out.append(allocator, try std.fmt.parseInt(u32, tok, 10));
    }
}

fn parseDirectionFromBidiBit(bit_value: u32) ?ParDirection {
    return switch (bit_value) {
        1 => .auto_ltr,
        2 => .ltr,
        4 => .rtl,
        8 => .auto_rtl,
        else => null,
    };
}

fn parseDirectionForCharacterTest(raw: []const u8) !ParDirection {
    const value = try std.fmt.parseInt(u8, raw, 10);
    return switch (value) {
        0 => .ltr,
        1 => .rtl,
        2 => .auto_ltr,
        3 => .auto_rtl,
        else => error.InvalidParagraphDirection,
    };
}

fn runCase(
    allocator: std.mem.Allocator,
    codepoints: []const u21,
    direction: ParDirection,
    expected_levels: []const ExpectedLevel,
    expected_ordering: []const u32,
) !bool {
    var dir = direction;
    var emb = try itijah.getParEmbeddingLevels(allocator, codepoints, &dir);
    defer emb.deinit(allocator);

    if (emb.levels.len != expected_levels.len) return false;
    for (emb.levels, expected_levels) |actual, expected| {
        if (expected.ignored) continue;
        if (actual != expected.value) return false;
    }

    const base_level = dir.toLevel();
    var vis = try itijah.reorderLine(allocator, codepoints, emb.levels, base_level);
    defer vis.deinit(allocator);

    if (vis.v_to_l.len != expected_levels.len) return false;
    for (0..vis.v_to_l.len) |logical_idx| {
        if (vis.v_to_l[vis.l_to_v[logical_idx]] != logical_idx) return false;
    }

    var actual_ordering = std.ArrayList(u32).empty;
    defer actual_ordering.deinit(allocator);
    for (vis.v_to_l) |logical_idx| {
        if (!expected_levels[logical_idx].ignored) {
            try actual_ordering.append(allocator, logical_idx);
        }
    }

    if (actual_ordering.items.len != expected_ordering.len) return false;
    for (actual_ordering.items, expected_ordering) |actual, expected| {
        if (actual != expected) return false;
    }

    return true;
}

fn runBidiTest(allocator: std.mem.Allocator, mode: Mode) !Stats {
    var stats = Stats{};
    var expected_levels_raw: []const u8 = "";
    var expected_reorder_raw: []const u8 = "";
    var have_expected_levels = false;
    var have_expected_reorder = false;

    var expected_levels = std.ArrayList(ExpectedLevel).empty;
    defer expected_levels.deinit(allocator);
    var expected_ordering = std.ArrayList(u32).empty;
    defer expected_ordering.deinit(allocator);

    var classes = std.ArrayList(itijah.BidiClass).empty;
    defer classes.deinit(allocator);
    var cps = std.ArrayList(u21).empty;
    defer cps.deinit(allocator);

    var line_iter = std.mem.splitScalar(u8, bidi_test_data, '\n');
    while (line_iter.next()) |line| {
        var comment_split = std.mem.splitScalar(u8, line, '#');
        const uncommented = std.mem.trim(u8, comment_split.first(), " \t\r");
        if (uncommented.len == 0) continue;

        if (uncommented[0] == '@') {
            if (std.mem.startsWith(u8, uncommented, "@Levels:")) {
                expected_levels_raw = std.mem.trim(u8, uncommented["@Levels:".len..], " \t");
                try parseExpectedLevelsInto(allocator, &expected_levels, expected_levels_raw);
                have_expected_levels = true;
            } else if (std.mem.startsWith(u8, uncommented, "@Reorder:")) {
                expected_reorder_raw = std.mem.trim(u8, uncommented["@Reorder:".len..], " \t");
                try parseExpectedOrderingInto(allocator, &expected_ordering, expected_reorder_raw);
                have_expected_reorder = true;
            }
            continue;
        }

        stats.total += 1;
        if (!have_expected_levels or !have_expected_reorder or expected_levels_raw.len == 0 or expected_reorder_raw.len == 0) {
            stats.skipped += 1;
            continue;
        }
        if (!mode.full and stats.executed >= mode.max_bidi_cases) {
            stats.skipped += 1;
            continue;
        }

        const classes_raw, const bitset_raw = splitAndTrim(uncommented, ';');
        if (classes_raw.len == 0 or bitset_raw.len == 0) {
            stats.skipped += 1;
            continue;
        }

        classes.clearRetainingCapacity();
        cps.clearRetainingCapacity();

        var class_iter = std.mem.tokenizeAny(u8, classes_raw, " \t");
        var filtered_out = false;
        while (class_iter.next()) |token| {
            const class = classFromName(token) orelse {
                filtered_out = true;
                break;
            };
            if (!mode.full and !isFilteredBidiClass(class)) {
                filtered_out = true;
                break;
            }
            try classes.append(allocator, class);
            try cps.append(allocator, cpForClass(class));
        }

        if (filtered_out or classes.items.len == 0) {
            stats.skipped += 1;
            continue;
        }

        if (expected_levels.items.len != cps.items.len) {
            stats.skipped += 1;
            continue;
        }

        const bitset = try std.fmt.parseInt(u32, bitset_raw, 10);
        var used_any = false;
        var bit: u32 = 1;
        while (bit <= 8) : (bit <<= 1) {
            if (bitset & bit == 0) continue;
            const direction = parseDirectionFromBidiBit(bit) orelse continue;
            used_any = true;

            stats.executed += 1;
            if (try runCase(allocator, cps.items, direction, expected_levels.items, expected_ordering.items)) {
                stats.passed += 1;
            } else {
                stats.failed += 1;
                if (stats.failed <= 16) {
                    std.debug.print(
                        "BidiTest fail sample #{d}: dir={s} classes=\"{s}\" levels=\"{s}\" reorder=\"{s}\"\n",
                        .{
                            stats.failed,
                            @tagName(direction),
                            classes_raw,
                            expected_levels_raw,
                            expected_reorder_raw,
                        },
                    );
                }
            }
        }

        if (!used_any) stats.skipped += 1;
    }

    return stats;
}

fn runBidiCharacterTest(allocator: std.mem.Allocator, mode: Mode) !Stats {
    var stats = Stats{};
    var line_iter = std.mem.splitScalar(u8, bidi_char_test_data, '\n');
    var cps = std.ArrayList(u21).empty;
    defer cps.deinit(allocator);
    var expected_levels = std.ArrayList(ExpectedLevel).empty;
    defer expected_levels.deinit(allocator);
    var expected_ordering = std.ArrayList(u32).empty;
    defer expected_ordering.deinit(allocator);

    while (line_iter.next()) |line| {
        var comment_split = std.mem.splitScalar(u8, line, '#');
        const uncommented = std.mem.trim(u8, comment_split.first(), " \t\r");
        if (uncommented.len == 0) continue;

        stats.total += 1;
        if (!mode.full and stats.executed >= mode.max_char_cases) {
            stats.skipped += 1;
            continue;
        }

        var fields = std.mem.splitScalar(u8, uncommented, ';');
        const cps_raw = std.mem.trim(u8, fields.next() orelse "", " \t");
        const para_dir_raw = std.mem.trim(u8, fields.next() orelse "", " \t");
        _ = std.mem.trim(u8, fields.next() orelse "", " \t"); // expected paragraph level
        const levels_raw = std.mem.trim(u8, fields.next() orelse "", " \t");
        const reorder_raw = std.mem.trim(u8, fields.next() orelse "", " \t");

        if (cps_raw.len == 0 or para_dir_raw.len == 0 or levels_raw.len == 0) {
            stats.skipped += 1;
            continue;
        }

        cps.clearRetainingCapacity();
        var cps_iter = std.mem.tokenizeAny(u8, cps_raw, " \t");
        var filtered_out = false;
        while (cps_iter.next()) |hex_cp| {
            const cp = std.fmt.parseInt(u21, hex_cp, 16) catch {
                filtered_out = true;
                break;
            };
            if (!mode.full) {
                const class = itijah.unicode.bidiClass(cp);
                if (!isFilteredBidiClass(class)) {
                    filtered_out = true;
                    break;
                }
            }
            try cps.append(allocator, cp);
        }

        if (filtered_out or cps.items.len == 0) {
            stats.skipped += 1;
            continue;
        }

        const direction = parseDirectionForCharacterTest(para_dir_raw) catch {
            stats.skipped += 1;
            continue;
        };
        try parseExpectedLevelsInto(allocator, &expected_levels, levels_raw);
        try parseExpectedOrderingInto(allocator, &expected_ordering, reorder_raw);

        if (expected_levels.items.len != cps.items.len) {
            stats.skipped += 1;
            continue;
        }

        stats.executed += 1;
        if (try runCase(allocator, cps.items, direction, expected_levels.items, expected_ordering.items)) {
            stats.passed += 1;
        } else {
            stats.failed += 1;
            if (stats.failed <= 16) {
                std.debug.print(
                    "BidiCharacterTest fail sample #{d}: dir={s} cps=\"{s}\" levels=\"{s}\" reorder=\"{s}\"\n",
                    .{
                        stats.failed,
                        @tagName(direction),
                        cps_raw,
                        levels_raw,
                        reorder_raw,
                    },
                );
            }
        }
    }

    return stats;
}

test "BidiTest.txt conformance harness" {
    const mode = selectedMode();

    const stats = try runBidiTest(testing.allocator, mode);
    std.debug.print(
        "BidiTest ({s}): total={d} executed={d} passed={d} failed={d} skipped={d}\n",
        .{ mode.name, stats.total, stats.executed, stats.passed, stats.failed, stats.skipped },
    );

    try testing.expect(stats.executed > 0);
    try testing.expect(stats.passed > 0);
    try testing.expectEqual(@as(usize, 0), stats.failed);
}

test "BidiCharacterTest.txt conformance harness" {
    const mode = selectedMode();

    const stats = try runBidiCharacterTest(testing.allocator, mode);
    std.debug.print(
        "BidiCharacterTest ({s}): total={d} executed={d} passed={d} failed={d} skipped={d}\n",
        .{ mode.name, stats.total, stats.executed, stats.passed, stats.failed, stats.skipped },
    );

    try testing.expect(stats.executed > 0);
    try testing.expect(stats.passed > 0);
    try testing.expectEqual(@as(usize, 0), stats.failed);
}
