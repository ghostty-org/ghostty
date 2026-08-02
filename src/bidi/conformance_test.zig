//! Conformance tests against the Unicode Character Database's own bidi
//! test suites, `BidiTest.txt` and `BidiCharacterTest.txt`.
//!
//! Together these are roughly 600,000 cases covering every combination of
//! rules the algorithm has. They are the only way to claim UAX #9
//! conformance honestly: hand-written tests check the cases an author
//! thought of, which are by definition the ones they did not get wrong.
//!
//! The data files are ~15 MB combined, which is more than is reasonable
//! to vendor into the repository without a deliberate decision by the
//! maintainers, so these tests read them from `src/bidi/testdata/` and
//! skip (loudly) when they are absent:
//!
//!     curl -o src/bidi/testdata/BidiTest.txt \
//!       https://www.unicode.org/Public/UCD/latest/ucd/BidiTest.txt
//!     curl -o src/bidi/testdata/BidiCharacterTest.txt \
//!       https://www.unicode.org/Public/UCD/latest/ucd/BidiCharacterTest.txt
//!     zig build test -Dtest-filter="bidi conformance"
//!
//! The UCD version must match the one the tables in `src/unicode` were
//! generated from, which is whatever uucode vendors.

const std = @import("std");
const testing = std.testing;
const unicode = @import("../unicode/main.zig");
const types = @import("types.zig");
const zig_backend = @import("zig.zig");

const BidiClass = unicode.BidiClass;
const Level = types.Level;

/// A representative codepoint for each Bidi_Class.
///
/// `BidiTest.txt` specifies inputs as class names rather than characters,
/// so a conforming implementation has to pick a character per class. Every
/// one of these is verified against our own tables in a test below, so a
/// wrong choice fails loudly instead of silently testing the wrong thing.
pub fn sampleCodepoint(c: BidiClass) u21 {
    return switch (c) {
        .l => 0x0061, // LATIN SMALL LETTER A
        .r => 0x05D0, // HEBREW LETTER ALEF
        .al => 0x0627, // ARABIC LETTER ALEF
        .en => 0x0030, // DIGIT ZERO
        .es => 0x002B, // PLUS SIGN
        .et => 0x0023, // NUMBER SIGN
        .an => 0x0660, // ARABIC-INDIC DIGIT ZERO
        .cs => 0x002C, // COMMA
        .nsm => 0x0300, // COMBINING GRAVE ACCENT
        .bn => 0x00AD, // SOFT HYPHEN
        .b => 0x2029, // PARAGRAPH SEPARATOR
        .s => 0x0009, // CHARACTER TABULATION
        .ws => 0x0020, // SPACE
        .on => 0x0021, // EXCLAMATION MARK
        .lre => 0x202A,
        .rle => 0x202B,
        .pdf => 0x202C,
        .lro => 0x202D,
        .rlo => 0x202E,
        .lri => 0x2066,
        .rli => 0x2067,
        .fsi => 0x2068,
        .pdi => 0x2069,
    };
}

fn classFromName(name: []const u8) ?BidiClass {
    const map = .{
        .{ "L", BidiClass.l },     .{ "R", BidiClass.r },
        .{ "AL", BidiClass.al },   .{ "EN", BidiClass.en },
        .{ "ES", BidiClass.es },   .{ "ET", BidiClass.et },
        .{ "AN", BidiClass.an },   .{ "CS", BidiClass.cs },
        .{ "NSM", BidiClass.nsm }, .{ "BN", BidiClass.bn },
        .{ "B", BidiClass.b },     .{ "S", BidiClass.s },
        .{ "WS", BidiClass.ws },   .{ "ON", BidiClass.on },
        .{ "LRE", BidiClass.lre }, .{ "RLE", BidiClass.rle },
        .{ "LRO", BidiClass.lro }, .{ "RLO", BidiClass.rlo },
        .{ "PDF", BidiClass.pdf }, .{ "LRI", BidiClass.lri },
        .{ "RLI", BidiClass.rli }, .{ "FSI", BidiClass.fsi },
        .{ "PDI", BidiClass.pdi },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

/// Expected levels, where null means "implementation dependent" (the `x`
/// marker used for characters removed by X9).
const Expected = struct {
    levels: std.ArrayList(?Level) = .empty,
    reorder: std.ArrayList(u16) = .empty,

    fn deinit(self: *Expected, alloc: std.mem.Allocator) void {
        self.levels.deinit(alloc);
        self.reorder.deinit(alloc);
    }
};

/// Check one case: resolve `cps` and compare against the expected levels
/// and visual order. Returns null on success or a description on failure.
pub fn checkCase(
    alloc: std.mem.Allocator,
    resolver: *zig_backend.Resolver,
    cps: []const u21,
    direction: types.ParagraphDirection,
    expected: *const Expected,
) !bool {
    const result = try resolver.resolve(alloc, cps, .{ .direction = direction });

    // Levels, skipping the entries the suite marks as don't-care.
    if (expected.levels.items.len != cps.len) return false;
    for (expected.levels.items, 0..) |want_, i| {
        const want = want_ orelse continue;
        if (result.level(i) != want) return false;
    }

    // Visual order, omitting the characters the suite treats as removed.
    var got: std.ArrayList(u16) = .empty;
    defer got.deinit(alloc);
    for (0..cps.len) |v| {
        const logical = result.logicalIndex(v);
        if (expected.levels.items[logical] == null) continue;
        try got.append(alloc, @intCast(logical));
    }

    if (got.items.len != expected.reorder.items.len) return false;
    for (got.items, expected.reorder.items) |a, b| {
        if (a != b) return false;
    }

    return true;
}

fn parseLevels(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(?Level),
    spec: []const u8,
) !void {
    out.clearRetainingCapacity();
    var it = std.mem.tokenizeAny(u8, spec, " \t");
    while (it.next()) |tok| {
        if (std.mem.eql(u8, tok, "x")) {
            try out.append(alloc, null);
        } else {
            try out.append(alloc, try std.fmt.parseInt(Level, tok, 10));
        }
    }
}

fn parseReorder(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u16),
    spec: []const u8,
) !void {
    out.clearRetainingCapacity();
    var it = std.mem.tokenizeAny(u8, spec, " \t");
    while (it.next()) |tok| {
        try out.append(alloc, try std.fmt.parseInt(u16, tok, 10));
    }
}

/// Read a UCD test file from `src/bidi/testdata`, or return null if it
/// has not been downloaded.
fn openUcd(alloc: std.mem.Allocator, comptime name: []const u8) !?[]u8 {
    const path = "src/bidi/testdata/" ++ name;
    return std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        path,
        alloc,
        .unlimited,
    ) catch |err| switch (err) {
        error.FileNotFound => {
            std.log.warn(
                "skipping bidi conformance: {s} not present. " ++
                    "See the comment at the top of conformance_test.zig.",
                .{path},
            );
            return null;
        },
        else => return err,
    };
}

test "bidi conformance: BidiTest.txt" {
    const alloc = testing.allocator;

    const content = (try openUcd(alloc, "BidiTest.txt")) orelse
        return error.SkipZigTest;
    defer alloc.free(content);

    var resolver: zig_backend.Resolver = .empty;
    defer resolver.deinit(alloc);

    var expected: Expected = .{};
    defer expected.deinit(alloc);

    var cps: std.ArrayList(u21) = .empty;
    defer cps.deinit(alloc);

    var total: usize = 0;
    var failed: usize = 0;
    var first_failure: [256]u8 = undefined;
    var first_failure_len: usize = 0;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (std.mem.startsWith(u8, line, "@Levels:")) {
            try parseLevels(alloc, &expected.levels, line["@Levels:".len..]);
            continue;
        }
        if (std.mem.startsWith(u8, line, "@Reorder:")) {
            try parseReorder(alloc, &expected.reorder, line["@Reorder:".len..]);
            continue;
        }

        // A data line: "<class> <class> ...; <bitset>"
        const semi = std.mem.indexOfScalar(u8, line, ';') orelse continue;
        const classes = line[0..semi];
        const bitset = try std.fmt.parseInt(u8, std.mem.trim(u8, line[semi + 1 ..], " \t"), 10);

        cps.clearRetainingCapacity();
        var ok = true;
        var it = std.mem.tokenizeAny(u8, classes, " \t");
        while (it.next()) |name| {
            const c = classFromName(name) orelse {
                ok = false;
                break;
            };
            try cps.append(alloc, sampleCodepoint(c));
        }
        if (!ok) continue;

        // Bit 1 is auto, bit 2 is LTR, bit 4 is RTL.
        const dirs = [_]struct { mask: u8, dir: types.ParagraphDirection }{
            .{ .mask = 1, .dir = .auto },
            .{ .mask = 2, .dir = .ltr },
            .{ .mask = 4, .dir = .rtl },
        };
        for (dirs) |d| {
            if (bitset & d.mask == 0) continue;
            total += 1;
            const pass = try checkCase(alloc, &resolver, cps.items, d.dir, &expected);
            if (!pass) {
                failed += 1;
                if (first_failure_len == 0) {
                    if (std.fmt.bufPrint(
                        &first_failure,
                        "classes=[{s}] dir={s}",
                        .{ std.mem.trim(u8, classes, " \t"), @tagName(d.dir) },
                    )) |msg| {
                        first_failure_len = msg.len;
                    } else |_| {}
                }
            }
        }
    }

    std.log.warn("BidiTest.txt: {d} cases, {d} failed", .{ total, failed });
    if (failed > 0) {
        std.log.warn("first failure: {s}", .{first_failure[0..first_failure_len]});
    }
    try testing.expect(total > 0);
    try testing.expectEqual(@as(usize, 0), failed);
}

test "bidi conformance: BidiCharacterTest.txt" {
    const alloc = testing.allocator;

    const content = (try openUcd(alloc, "BidiCharacterTest.txt")) orelse
        return error.SkipZigTest;
    defer alloc.free(content);

    var resolver: zig_backend.Resolver = .empty;
    defer resolver.deinit(alloc);

    var expected: Expected = .{};
    defer expected.deinit(alloc);

    var cps: std.ArrayList(u21) = .empty;
    defer cps.deinit(alloc);

    var total: usize = 0;
    var failed: usize = 0;
    var first_failure: [512]u8 = undefined;
    var first_failure_len: usize = 0;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        // <codepoints>;<direction>;<para level>;<levels>;<reorder>
        var fields = std.mem.splitScalar(u8, line, ';');
        const cps_str = fields.next() orelse continue;
        const dir_str = fields.next() orelse continue;
        const para_str = fields.next() orelse continue;
        const levels_str = fields.next() orelse continue;
        const reorder_str = fields.next() orelse continue;

        cps.clearRetainingCapacity();
        var it = std.mem.tokenizeAny(u8, cps_str, " \t");
        while (it.next()) |tok| {
            try cps.append(alloc, try std.fmt.parseInt(u21, tok, 16));
        }
        if (cps.items.len == 0) continue;

        const dir: types.ParagraphDirection = switch (try std.fmt.parseInt(u8, dir_str, 10)) {
            0 => .ltr,
            1 => .rtl,
            2 => .auto,
            else => continue,
        };

        try parseLevels(alloc, &expected.levels, levels_str);
        try parseReorder(alloc, &expected.reorder, reorder_str);

        total += 1;

        // The suite also states the resolved paragraph level.
        const want_para = try std.fmt.parseInt(Level, para_str, 10);
        const result = try resolver.resolve(alloc, cps.items, .{ .direction = dir });
        const got_para: Level = switch (result.direction) {
            .ltr => 0,
            .rtl => 1,
        };

        const pass = got_para == want_para and
            try checkCase(alloc, &resolver, cps.items, dir, &expected);

        if (!pass) {
            failed += 1;
            if (first_failure_len == 0) {
                if (std.fmt.bufPrint(
                    &first_failure,
                    "cps=[{s}] dir={s}",
                    .{ std.mem.trim(u8, cps_str, " \t"), @tagName(dir) },
                )) |msg| {
                    first_failure_len = msg.len;
                } else |_| {}
            }
        }
    }

    std.log.warn("BidiCharacterTest.txt: {d} cases, {d} failed", .{ total, failed });
    if (failed > 0) {
        std.log.warn("first failure: {s}", .{first_failure[0..first_failure_len]});
    }
    try testing.expect(total > 0);
    try testing.expectEqual(@as(usize, 0), failed);
}

test "conformance: sample codepoints have the class they claim" {
    // If any of these drifted, BidiTest.txt would be silently exercising
    // the wrong characters and could pass while the implementation is
    // wrong. BN is the exception: several classes have no single
    // canonical representative, so we assert on the class we looked up.
    for (std.enums.values(BidiClass)) |c| {
        const cp = sampleCodepoint(c);
        try testing.expectEqual(c, unicode.bidiClass(cp));
    }
}
