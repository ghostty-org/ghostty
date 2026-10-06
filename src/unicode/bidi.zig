//! An implementation of the implicit portion of the Unicode Bidirectional
//! Algorithm (UAX #9) suitable for reordering a single terminal row for
//! display.
//!
//! This implements rules W1-W7, N0-N2, I1-I2 and L1-L2. Explicit
//! directional formatting characters (embeddings, overrides and isolates)
//! are not supported and are treated as neutrals; in a terminal they are
//! zero-width and attached to the preceding cell anyway. Mirroring of
//! brackets (L4) is left to the text shaper.
//!
//! The algorithm operates on arbitrary "items" rather than codepoints so
//! that callers can feed it one class per terminal cell.

const std = @import("std");
const assert = std.debug.assert;
const uucode = @import("uucode");
const table = @import("props_table.zig").table;

pub const Class = uucode.types.BidiClass;

/// The maximum embedding level we can produce. With implicit-only
/// resolution, levels never exceed base + 2.
pub const max_level = 2;

/// Returns the bidi class of a codepoint.
pub fn class(cp: u21) Class {
    return table.get(cp).bidi_class;
}

/// Returns true if the given class is a strong right-to-left class.
/// A line that contains no strong RTL characters (and no explicit
/// formatting, which we don't support) never needs reordering when the
/// paragraph direction is left-to-right.
pub fn isRtl(c: Class) bool {
    return switch (c) {
        .right_to_left, .right_to_left_arabic => true,
        else => false,
    };
}

/// Returns true if the codepoint is a strong right-to-left codepoint.
/// This is fast for ASCII.
pub fn isRtlCodepoint(cp: u21) bool {
    // The first RTL codepoint is U+0590 (Hebrew block).
    if (cp < 0x0590) return false;
    return isRtl(class(cp));
}

/// The paragraph direction to use.
pub const Direction = enum(u1) {
    ltr = 0,
    rtl = 1,

    /// Determine the paragraph direction using rules P2 and P3: the
    /// direction of the first strong character, or `default` if there
    /// is none.
    pub fn detect(classes: []const Class, default: Direction) Direction {
        for (classes) |c| switch (c) {
            .left_to_right => return .ltr,
            .right_to_left, .right_to_left_arabic => return .rtl,
            else => {},
        };
        return default;
    }
};

/// Resolve the embedding levels of each item.
///
/// `classes` are the original bidi classes of each item. `levels` must
/// be the same length and will receive the resolved embedding level of
/// each item. `work` is a scratch buffer of the same length.
///
/// `codepoints`, if given, are the (primary) codepoints of each item
/// and are used to resolve paired brackets (N0). If null, brackets are
/// treated as ordinary neutrals.
pub fn resolveLevels(
    classes: []const Class,
    codepoints: ?[]const u21,
    work: []Class,
    levels: []u8,
    para: Direction,
) void {
    assert(classes.len == work.len);
    assert(classes.len == levels.len);
    if (codepoints) |cps| assert(cps.len == classes.len);
    const len = classes.len;
    if (len == 0) return;

    const base: u8 = @intFromEnum(para);
    const e: Class = if (base == 0) .left_to_right else .right_to_left;

    // Normalize the classes we don't support into neutrals. Explicit
    // formatting characters behave like BN after X9, and BN is ignored
    // by the remaining rules which we approximate by treating them as
    // ON (they will then take on the direction of their surroundings).
    for (classes, work) |c, *w| w.* = switch (c) {
        .left_to_right_embedding,
        .left_to_right_override,
        .right_to_left_embedding,
        .right_to_left_override,
        .pop_directional_format,
        .left_to_right_isolate,
        .right_to_left_isolate,
        .first_strong_isolate,
        .pop_directional_isolate,
        .boundary_neutral,
        => .other_neutrals,
        else => c,
    };

    // W1: NSM takes the type of the previous character (or sos).
    {
        var prev: Class = e;
        for (work) |*w| {
            if (w.* == .nonspacing_mark) w.* = prev;
            prev = w.*;
        }
    }

    // W2: EN preceded (searching backwards to the first strong type)
    // by AL becomes AN.
    // W3: AL becomes R.
    {
        var last_strong: Class = e;
        for (work) |*w| switch (w.*) {
            .left_to_right, .right_to_left => last_strong = w.*,
            .right_to_left_arabic => {
                last_strong = .right_to_left_arabic;
                w.* = .right_to_left;
            },
            .european_number => if (last_strong == .right_to_left_arabic) {
                w.* = .arabic_number;
            },
            else => {},
        };
    }

    // W4: A single ES between two ENs becomes EN. A single CS between
    // two numbers of the same type becomes that type.
    if (len >= 3) {
        for (1..len - 1) |i| {
            const prev = work[i - 1];
            const next = work[i + 1];
            switch (work[i]) {
                .european_number_separator => if (prev == .european_number and
                    next == .european_number)
                {
                    work[i] = .european_number;
                },
                .common_number_separator => if (prev == next and
                    (prev == .european_number or prev == .arabic_number))
                {
                    work[i] = prev;
                },
                else => {},
            }
        }
    }

    // W5: A sequence of ETs adjacent to an EN becomes all ENs.
    {
        var i: usize = 0;
        while (i < len) {
            if (work[i] != .european_number_terminator) {
                i += 1;
                continue;
            }

            const start = i;
            while (i < len and work[i] == .european_number_terminator) i += 1;
            const adjacent_en =
                (start > 0 and work[start - 1] == .european_number) or
                (i < len and work[i] == .european_number);
            if (adjacent_en) @memset(work[start..i], .european_number);
        }
    }

    // W6: Remaining separators and terminators become ON.
    // W7: EN preceded (searching backwards to the first strong type)
    // by L becomes L.
    {
        var last_strong: Class = e;
        for (work) |*w| switch (w.*) {
            .european_number_separator,
            .european_number_terminator,
            .common_number_separator,
            => w.* = .other_neutrals,
            .left_to_right, .right_to_left => last_strong = w.*,
            .european_number => if (last_strong == .left_to_right) {
                w.* = .left_to_right;
            },
            else => {},
        };
    }

    // N0: Paired brackets.
    if (codepoints) |cps| resolveBrackets(classes, cps, work, e);

    // N1/N2: Sequences of neutrals take the direction of the surrounding
    // strong text if both sides agree (numbers count as R), otherwise
    // they take the embedding direction.
    {
        var i: usize = 0;
        while (i < len) {
            if (!isNeutral(work[i])) {
                i += 1;
                continue;
            }

            const start = i;
            while (i < len and isNeutral(work[i])) i += 1;
            const before: Class = if (start == 0) e else strongDir(work[start - 1]);
            const after: Class = if (i == len) e else strongDir(work[i]);
            @memset(work[start..i], if (before == after) before else e);
        }
    }

    // I1/I2: Resolve implicit levels.
    for (work, levels) |w, *level| {
        level.* = base;
        if (base & 1 == 0) {
            switch (w) {
                .right_to_left => level.* += 1,
                .arabic_number, .european_number => level.* += 2,
                else => {},
            }
        } else {
            switch (w) {
                .left_to_right, .arabic_number, .european_number => level.* += 1,
                else => {},
            }
        }
    }

    // L1: Segment and paragraph separators, along with any sequence of
    // whitespace before them or at the end of the line, are reset to
    // the paragraph level. This uses the original classes.
    {
        var trailing = true;
        var i: usize = len;
        while (i > 0) {
            i -= 1;
            switch (classes[i]) {
                .segment_separator, .paragraph_separator => {
                    levels[i] = base;
                    trailing = true;
                },
                .whitespace,
                .left_to_right_isolate,
                .right_to_left_isolate,
                .first_strong_isolate,
                .pop_directional_isolate,
                .boundary_neutral,
                .left_to_right_embedding,
                .left_to_right_override,
                .right_to_left_embedding,
                .right_to_left_override,
                .pop_directional_format,
                => if (trailing) {
                    levels[i] = base;
                },
                else => trailing = false,
            }
        }
    }
}

/// Rule N0: resolve paired brackets. See BD16 for identifying pairs.
fn resolveBrackets(
    classes: []const Class,
    cps: []const u21,
    work: []Class,
    e: Class,
) void {
    // BD16: identify bracket pairs using a stack. The stack is limited
    // to 63 elements; if it overflows we stop looking for pairs.
    const max_stack = 63;
    const Opening = struct { close: u21, pos: usize };
    const Pair = struct { open: usize, close: usize };
    var stack: [max_stack]Opening = undefined;
    var stack_len: usize = 0;
    var pairs: [max_stack]Pair = undefined;
    var pairs_len: usize = 0;

    find: for (cps, 0..) |cp, i| {
        // Only brackets that are still ON after the W rules count.
        if (work[i] != .other_neutrals) continue;
        switch (uucode.get(.bidi_paired_bracket, cp)) {
            .none => {},
            .open => |close| {
                if (stack_len == max_stack) break :find;
                stack[stack_len] = .{ .close = close, .pos = i };
                stack_len += 1;
            },
            .close => {
                var j = stack_len;
                while (j > 0) {
                    j -= 1;
                    if (stack[j].close != cp) continue;
                    if (pairs_len == max_stack) break :find;
                    pairs[pairs_len] = .{ .open = stack[j].pos, .close = i };
                    pairs_len += 1;
                    stack_len = j;
                    break;
                }
            },
        }
    }

    // Pairs must be processed in order of their opening bracket.
    std.mem.sort(Pair, pairs[0..pairs_len], {}, struct {
        fn lessThan(_: void, a: Pair, b: Pair) bool {
            return a.open < b.open;
        }
    }.lessThan);

    for (pairs[0..pairs_len]) |pair| {
        // Find the strong types within the brackets. EN and AN are
        // treated as R.
        var found_e = false;
        var found_opposite = false;
        for (work[pair.open + 1 .. pair.close]) |w| {
            const d = strongOrNull(w) orelse continue;
            if (d == e) {
                found_e = true;
                break;
            }
            found_opposite = true;
        }

        const dir: Class = dir: {
            // N0 b: a strong type matching the embedding direction.
            if (found_e) break :dir e;

            // N0 d: no strong types within the brackets.
            if (!found_opposite) continue;

            // N0 c: only the opposite direction is within the brackets,
            // so we use the direction of the preceding context (or sos).
            const before: Class = before: {
                var k = pair.open;
                while (k > 0) {
                    k -= 1;
                    if (strongOrNull(work[k])) |d| break :before d;
                }
                break :before e;
            };
            break :dir if (before != e) before else e;
        };

        work[pair.open] = dir;
        work[pair.close] = dir;

        // NSMs following a bracket whose type changed take its type.
        for ([_]usize{ pair.open, pair.close }) |pos| {
            var k = pos + 1;
            while (k < work.len and classes[k] == .nonspacing_mark) : (k += 1) {
                work[k] = dir;
            }
        }
    }
}

/// The strong direction of a resolved class for N0, or null if neutral.
fn strongOrNull(c: Class) ?Class {
    return switch (c) {
        .left_to_right => .left_to_right,
        .right_to_left, .arabic_number, .european_number => .right_to_left,
        else => null,
    };
}

fn isNeutral(c: Class) bool {
    return switch (c) {
        .paragraph_separator,
        .segment_separator,
        .whitespace,
        .other_neutrals,
        => true,
        else => false,
    };
}

/// The strong direction of a resolved class for the purposes of N1.
fn strongDir(c: Class) Class {
    return switch (c) {
        .left_to_right => .left_to_right,
        .right_to_left, .arabic_number, .european_number => .right_to_left,
        else => unreachable,
    };
}

/// Compute the visual order (L2) from the resolved levels. On return,
/// `order[visual_index]` is the logical index of the item displayed at
/// that position. `order` must be the same length as `levels`.
pub fn reorder(levels: []const u8, order: []u16) void {
    assert(levels.len == order.len);
    for (order, 0..) |*o, i| o.* = @intCast(i);
    if (levels.len == 0) return;

    var highest: u8 = 0;
    var lowest_odd: u8 = std.math.maxInt(u8);
    for (levels) |l| {
        highest = @max(highest, l);
        if (l & 1 == 1) lowest_odd = @min(lowest_odd, l);
    }
    if (lowest_odd == std.math.maxInt(u8)) {
        // No odd levels. We still need to handle the case where we have
        // even levels above 0 (i.e. numbers at level 2), but reversing
        // those an even number of times is a no-op.
        return;
    }

    // From the highest level down to the lowest odd level, reverse any
    // contiguous sequence of items at that level or higher.
    var level = highest;
    while (level >= lowest_odd) : (level -= 1) {
        var i: usize = 0;
        while (i < levels.len) {
            if (levels[order[i]] < level) {
                i += 1;
                continue;
            }

            const start = i;
            while (i < levels.len and levels[order[i]] >= level) i += 1;
            std.mem.reverse(u16, order[start..i]);
        }

        if (level == 0) break;
    }
}

fn testResolve(
    comptime text: []const u8,
    para: Direction,
    expected_visual: []const u8,
) !void {
    const testing = std.testing;
    var cps: [128]u21 = undefined;
    var len: usize = 0;
    var it = (try std.unicode.Utf8View.init(text)).iterator();
    while (it.nextCodepoint()) |cp| : (len += 1) cps[len] = cp;

    var classes: [128]Class = undefined;
    var work: [128]Class = undefined;
    var levels: [128]u8 = undefined;
    var order: [128]u16 = undefined;
    for (cps[0..len], classes[0..len]) |cp, *c| c.* = class(cp);
    resolveLevels(classes[0..len], cps[0..len], work[0..len], levels[0..len], para);
    reorder(levels[0..len], order[0..len]);

    var buf: [512]u8 = undefined;
    var buf_len: usize = 0;
    for (order[0..len]) |i| {
        buf_len += try std.unicode.utf8Encode(cps[i], buf[buf_len..]);
    }
    try testing.expectEqualStrings(expected_visual, buf[0..buf_len]);
}

test "bidi class" {
    const testing = std.testing;
    try testing.expectEqual(Class.left_to_right, class('a'));
    try testing.expectEqual(Class.whitespace, class(' '));
    try testing.expectEqual(Class.european_number, class('1'));
    try testing.expectEqual(Class.right_to_left, class(0x05D0)); // Hebrew alef
    try testing.expectEqual(Class.right_to_left_arabic, class(0x0627)); // Arabic alef
    try testing.expectEqual(Class.arabic_number, class(0x0660)); // Arabic-Indic zero
    try testing.expect(isRtlCodepoint(0x05D0));
    try testing.expect(isRtlCodepoint(0x0627));
    try testing.expect(!isRtlCodepoint('a'));
    try testing.expect(!isRtlCodepoint(0x0660));
}

test "bidi pure LTR is unchanged" {
    try testResolve("hello world", .ltr, "hello world");
}

test "bidi pure RTL in LTR paragraph is reversed" {
    try testResolve("אבג", .ltr, "גבא");
}

test "bidi RTL words with spaces in LTR paragraph" {
    try testResolve("אב גד", .ltr, "דג בא");
}

test "bidi mixed LTR and RTL" {
    try testResolve("abc אבג def", .ltr, "abc גבא def");
}

test "bidi trailing whitespace stays at paragraph level" {
    try testResolve("abc אב  ", .ltr, "abc בא  ");
    try testResolve("אב  ", .ltr, "בא  ");
}

test "bidi numbers in RTL text keep their order" {
    try testResolve("אב 123 גד", .ltr, "דג 123 בא");
}

test "bidi arabic numbers after arabic letters" {
    // W2: European digits after AL become AN but still display LTR.
    try testResolve("ابت 12", .ltr, "12 تبا");
}

test "bidi number with separators" {
    try testResolve("א 1.5 ב", .ltr, "ב 1.5 א");
    try testResolve("א 1,000 ב", .ltr, "ב 1,000 א");
}

test "bidi neutrals between differing directions" {
    // The '-' is between L and R so it takes the embedding direction.
    try testResolve("ab-אב", .ltr, "ab-בא");
    try testResolve("אב-ab", .ltr, "בא-ab");
}

test "bidi RTL paragraph" {
    try testResolve("אבג", .rtl, "גבא");
    try testResolve("abc אבג", .rtl, "גבא abc");
}

test "bidi paragraph direction detection" {
    const testing = std.testing;
    try testing.expectEqual(Direction.rtl, Direction.detect(&.{ .whitespace, .right_to_left }, .ltr));
    try testing.expectEqual(Direction.ltr, Direction.detect(&.{ .european_number, .left_to_right }, .rtl));
    try testing.expectEqual(Direction.rtl, Direction.detect(&.{.whitespace}, .rtl));
}

test "bidi nonspacing marks follow their base" {
    // Hebrew alef + point qamats, then bet.
    try testResolve("\u{05D0}\u{05B8}\u{05D1}", .ltr, "\u{05D1}\u{05B8}\u{05D0}");
}

test "bidi bracket pairs" {
    // Brackets enclosing RTL text within RTL text are RTL.
    try testResolve("א (ב) ג", .ltr, "ג )ב( א");
    // A trailing bracket pair around RTL text after RTL text.
    try testResolve("א (ב)", .ltr, ")ב( א");
    // Brackets enclosing LTR text are LTR in an LTR paragraph.
    try testResolve("א (b) ג", .ltr, "א (b) ג");
    // Brackets enclosing RTL text preceded by LTR text are LTR.
    try testResolve("a (ב)", .ltr, "a (ב)");
    // Unmatched brackets are ordinary neutrals.
    try testResolve("א (ב", .ltr, "ב( א");
}
