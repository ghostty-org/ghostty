/// Generates text corpora for exercising the Unicode Bidirectional
/// Algorithm (UAX #9).
///
/// The point of this generator is that bidi benchmark corpora are
/// reproducible from a seed rather than checked into the repository, per
/// the guidance in `src/benchmark/AGENTS.md`. A profile picks the script
/// mix; the same seed and profile always produce the same bytes, so
/// branch-to-branch comparisons are meaningful.
///
/// Output is line-oriented so the same corpus can feed both the bidi
/// benchmarks and the terminal stream benchmarks.
const Bidi = @This();

const std = @import("std");
const assert = std.debug.assert;
const Generator = @import("Generator.zig");

/// The script mix to generate.
pub const Profile = enum {
    /// Printable ASCII only. This is the corpus that matters most: it is
    /// what the overwhelming majority of terminal output looks like, and
    /// it is the one that must show no measurable regression when bidi
    /// support lands.
    ascii,

    /// Hebrew, including niqqud so combining marks are exercised.
    hebrew,

    /// Arabic, including tashkeel.
    arabic,

    /// Persian: Farsi-specific letters, ZWNJ inside compound words, and
    /// Extended Arabic-Indic digits. Persian is called out separately
    /// from Arabic because its digits are European Number while Arabic's
    /// are Arabic Number, which is a classic source of resolution bugs.
    persian,

    /// Latin and RTL words interleaved, the common real-world case.
    mixed,

    /// RTL text with numbers embedded. Numbers always render
    /// left-to-right even inside RTL, so this exercises the weak-type
    /// rules (W1-W7) that a naive implementation gets wrong.
    numeric,

    /// Deliberately hostile: direction alternating every character,
    /// nested isolates and embeddings, bracket pairs spanning direction
    /// changes. This is the worst case for resolution cost and the best
    /// case for finding rule bugs.
    adversarial,
};

/// Random number generator.
rand: std.Random,

/// Which script mix to generate.
profile: Profile = .ascii,

/// Terminal width to wrap at. Lines are broken with a newline once this
/// many codepoints have been emitted, so generated rows resemble what a
/// terminal actually holds.
cols: u16 = 120,

/// Current column, tracked across `next` calls so wrapping is continuous.
col: u16 = 0,

const latin_lower = "abcdefghijklmnopqrstuvwxyz";

/// Hebrew letters alef..tav.
const hebrew_letters = blk: {
    var out: [27]u21 = undefined;
    for (0..27) |i| out[i] = 0x05D0 + i;
    break :blk out;
};

/// Hebrew points (niqqud), which are nonspacing marks.
const hebrew_marks = [_]u21{ 0x05B0, 0x05B4, 0x05B7, 0x05B8, 0x05BC };

/// Common Arabic letters.
const arabic_letters = [_]u21{
    0x0627, 0x0628, 0x062A, 0x062B, 0x062C, 0x062D, 0x062E, 0x062F,
    0x0631, 0x0632, 0x0633, 0x0634, 0x0635, 0x0636, 0x0637, 0x0638,
    0x0639, 0x063A, 0x0641, 0x0642, 0x0643, 0x0644, 0x0645, 0x0646,
    0x0647, 0x0648, 0x064A,
};

/// Arabic tashkeel (nonspacing marks).
const arabic_marks = [_]u21{ 0x064B, 0x064E, 0x064F, 0x0650, 0x0651, 0x0652 };

/// Letters specific to Persian beyond the shared Arabic set.
const persian_letters = [_]u21{ 0x067E, 0x0686, 0x0698, 0x06AF, 0x06A9, 0x06CC };

/// Arabic-Indic digits. Bidi_Class AN.
const arabic_indic_digits = blk: {
    var out: [10]u21 = undefined;
    for (0..10) |i| out[i] = 0x0660 + i;
    break :blk out;
};

/// Extended Arabic-Indic digits, used for Persian. Bidi_Class EN.
const ext_arabic_indic_digits = blk: {
    var out: [10]u21 = undefined;
    for (0..10) |i| out[i] = 0x06F0 + i;
    break :blk out;
};

/// Explicit bidi formatting characters, used by the adversarial profile.
const isolates = [_]u21{ 0x2066, 0x2067, 0x2068 }; // LRI, RLI, FSI
const pop_isolate: u21 = 0x2069; // PDI
const embeddings = [_]u21{ 0x202A, 0x202B, 0x202D, 0x202E }; // LRE, RLE, LRO, RLO
const pop_embedding: u21 = 0x202C; // PDF

/// Mirrored bracket pairs, which exercise rule N0.
const bracket_pairs = [_][2]u21{
    .{ '(', ')' },
    .{ '[', ']' },
    .{ '{', '}' },
};

pub fn generator(self: *Bidi) Generator {
    return .init(self, next);
}

pub fn next(
    self: *Bidi,
    writer: *std.Io.Writer,
    max_len: usize,
) Generator.Error!void {
    var rem = max_len;

    // Scratch for one emitted unit (a word plus its trailing separator).
    // Words are capped well below this, so a unit always fits.
    var buf: [256]u8 = undefined;

    while (rem > 0) {
        const n = self.writeUnit(&buf);
        assert(n > 0);

        if (n > rem) {
            // The next unit doesn't fit. Pad with spaces rather than
            // truncating mid-codepoint, which would emit invalid UTF-8.
            for (0..rem) |_| try writer.writeByte(' ');
            return;
        }

        try writer.writeAll(buf[0..n]);
        rem -= n;
    }
}

/// Write one unit (a word and its separator) into `buf`, returning the
/// number of bytes written.
fn writeUnit(self: *Bidi, buf: []u8) usize {
    var w: Writer = .{ .buf = buf };

    switch (self.profile) {
        .ascii => self.writeLatinWord(&w),
        .hebrew => self.writeHebrewWord(&w),
        .arabic => self.writeArabicWord(&w, false),
        .persian => self.writePersianWord(&w),
        .mixed => {
            // Roughly half Latin, half RTL, which is what a localized CLI
            // session actually looks like.
            if (self.rand.boolean()) {
                self.writeLatinWord(&w);
            } else if (self.rand.boolean()) {
                self.writeHebrewWord(&w);
            } else {
                self.writeArabicWord(&w, false);
            }
        },
        .numeric => self.writeNumericUnit(&w),
        .adversarial => self.writeAdversarialUnit(&w),
    }

    // Separator: newline at the wrap column, space otherwise.
    if (self.col >= self.cols) {
        w.cp('\n');
        self.col = 0;
    } else {
        w.cp(' ');
        self.col += 1;
    }

    return w.len;
}

fn writeLatinWord(self: *Bidi, w: *Writer) void {
    const n = self.rand.intRangeAtMost(usize, 2, 9);
    for (0..n) |_| {
        w.cp(latin_lower[self.rand.uintLessThan(usize, latin_lower.len)]);
        self.col += 1;
    }
}

fn writeHebrewWord(self: *Bidi, w: *Writer) void {
    const n = self.rand.intRangeAtMost(usize, 2, 7);
    for (0..n) |_| {
        w.cp(hebrew_letters[self.rand.uintLessThan(usize, hebrew_letters.len)]);
        self.col += 1;

        // Niqqud are nonspacing, so they occupy no column.
        if (self.rand.float(f32) < 0.25) {
            w.cp(hebrew_marks[self.rand.uintLessThan(usize, hebrew_marks.len)]);
        }
    }
}

fn writeArabicWord(self: *Bidi, w: *Writer, persian: bool) void {
    const n = self.rand.intRangeAtMost(usize, 2, 7);
    for (0..n) |_| {
        const cp = if (persian and self.rand.float(f32) < 0.3)
            persian_letters[self.rand.uintLessThan(usize, persian_letters.len)]
        else
            arabic_letters[self.rand.uintLessThan(usize, arabic_letters.len)];
        w.cp(cp);
        self.col += 1;

        // Tashkeel are nonspacing.
        if (self.rand.float(f32) < 0.2) {
            w.cp(arabic_marks[self.rand.uintLessThan(usize, arabic_marks.len)]);
        }
    }
}

fn writePersianWord(self: *Bidi, w: *Writer) void {
    self.writeArabicWord(w, true);

    // Persian compounds are frequently joined with ZWNJ, which breaks
    // cursive joining without introducing a spacing character.
    if (self.rand.float(f32) < 0.35) {
        w.cp(0x200C);
        self.writeArabicWord(w, true);
    }
}

fn writeNumericUnit(self: *Bidi, w: *Writer) void {
    switch (self.rand.uintLessThan(u8, 4)) {
        // A bare RTL word.
        0 => self.writeArabicWord(w, false),

        // ASCII digits (European Number) inside RTL context.
        1 => {
            const n = self.rand.intRangeAtMost(usize, 1, 6);
            for (0..n) |_| {
                w.cp('0' + self.rand.uintLessThan(u21, 10));
                self.col += 1;
            }
        },

        // Arabic-Indic digits (Arabic Number).
        2 => {
            const n = self.rand.intRangeAtMost(usize, 1, 6);
            for (0..n) |_| {
                w.cp(arabic_indic_digits[self.rand.uintLessThan(usize, 10)]);
                self.col += 1;
            }
        },

        // A decimal with separators, which exercises ES/CS resolution.
        3 => {
            const n = self.rand.intRangeAtMost(usize, 1, 3);
            for (0..n) |i| {
                if (i > 0) {
                    w.cp('.');
                    self.col += 1;
                }
                for (0..self.rand.intRangeAtMost(usize, 1, 3)) |_| {
                    w.cp(ext_arabic_indic_digits[self.rand.uintLessThan(usize, 10)]);
                    self.col += 1;
                }
            }
        },

        else => unreachable,
    }
}

fn writeAdversarialUnit(self: *Bidi, w: *Writer) void {
    switch (self.rand.uintLessThan(u8, 4)) {
        // Direction flips every single character. Maximal level runs.
        0 => {
            const n = self.rand.intRangeAtMost(usize, 4, 12);
            for (0..n) |i| {
                const cp = if (i % 2 == 0)
                    latin_lower[self.rand.uintLessThan(usize, latin_lower.len)]
                else
                    hebrew_letters[self.rand.uintLessThan(usize, hebrew_letters.len)];
                w.cp(cp);
                self.col += 1;
            }
        },

        // Nested isolates.
        1 => {
            const depth = self.rand.intRangeAtMost(usize, 1, 6);
            for (0..depth) |_| {
                w.cp(isolates[self.rand.uintLessThan(usize, isolates.len)]);
            }
            self.writeHebrewWord(w);
            for (0..depth) |_| w.cp(pop_isolate);
        },

        // Nested embeddings and overrides.
        2 => {
            const depth = self.rand.intRangeAtMost(usize, 1, 5);
            for (0..depth) |_| {
                w.cp(embeddings[self.rand.uintLessThan(usize, embeddings.len)]);
            }
            self.writeLatinWord(w);
            for (0..depth) |_| w.cp(pop_embedding);
        },

        // A bracket pair straddling a direction change, for rule N0.
        3 => {
            const pair = bracket_pairs[self.rand.uintLessThan(usize, bracket_pairs.len)];
            w.cp(pair[0]);
            self.col += 1;
            self.writeHebrewWord(w);
            self.writeLatinWord(w);
            w.cp(pair[1]);
            self.col += 1;
        },

        else => unreachable,
    }
}

/// A tiny UTF-8 sink over a fixed buffer. Codepoints are known-valid
/// here (they come from the tables above), so encoding cannot fail.
const Writer = struct {
    buf: []u8,
    len: usize = 0,

    fn cp(self: *Writer, c: u21) void {
        const n = std.unicode.utf8Encode(c, self.buf[self.len..]) catch unreachable;
        self.len += n;
    }
};

test "bidi: every profile emits valid utf8" {
    const testing = std.testing;

    for (std.enums.values(Profile)) |profile| {
        var prng = std.Random.DefaultPrng.init(42);
        var buf: [8192]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        var gen: Bidi = .{ .rand = prng.random(), .profile = profile };
        try gen.generator().next(&writer, buf.len);

        const out = writer.buffered();
        try testing.expectEqual(buf.len, out.len);
        try testing.expect(std.unicode.utf8ValidateSlice(out));
    }
}

test "bidi: same seed produces same bytes" {
    const testing = std.testing;

    var a_buf: [4096]u8 = undefined;
    var b_buf: [4096]u8 = undefined;

    for (std.enums.values(Profile)) |profile| {
        var a_prng = std.Random.DefaultPrng.init(7);
        var a_writer: std.Io.Writer = .fixed(&a_buf);
        var a: Bidi = .{ .rand = a_prng.random(), .profile = profile };
        try a.generator().next(&a_writer, a_buf.len);

        var b_prng = std.Random.DefaultPrng.init(7);
        var b_writer: std.Io.Writer = .fixed(&b_buf);
        var b: Bidi = .{ .rand = b_prng.random(), .profile = profile };
        try b.generator().next(&b_writer, b_buf.len);

        try testing.expectEqualSlices(u8, a_writer.buffered(), b_writer.buffered());
    }
}

test "bidi: ascii profile stays in ascii" {
    const testing = std.testing;

    var prng = std.Random.DefaultPrng.init(1);
    var buf: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    var gen: Bidi = .{ .rand = prng.random(), .profile = .ascii };
    try gen.generator().next(&writer, buf.len);

    // The whole no-regression argument rests on this corpus being able to
    // take the fast path, so it must contain nothing above U+007F.
    for (writer.buffered()) |c| try testing.expect(c < 0x80);
}

test "bidi: rtl profiles actually emit rtl" {
    const testing = std.testing;
    const unicode = @import("../unicode/main.zig");

    for ([_]Profile{ .hebrew, .arabic, .persian }) |profile| {
        var prng = std.Random.DefaultPrng.init(3);
        var buf: [4096]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        var gen: Bidi = .{ .rand = prng.random(), .profile = profile };
        try gen.generator().next(&writer, buf.len);

        var rtl: usize = 0;
        var view = try std.unicode.Utf8View.init(writer.buffered());
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            switch (unicode.bidiClass(cp)) {
                .r, .al => rtl += 1,
                else => {},
            }
        }

        // A corpus that generated no RTL would silently make every bidi
        // benchmark measure the fast path instead.
        try testing.expect(rtl > 100);
    }
}

test "bidi: wraps at the configured column" {
    const testing = std.testing;

    var prng = std.Random.DefaultPrng.init(9);
    var buf: [8192]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    var gen: Bidi = .{ .rand = prng.random(), .profile = .ascii, .cols = 40 };
    try gen.generator().next(&writer, buf.len);

    var lines = std.mem.splitScalar(u8, writer.buffered(), '\n');
    var count: usize = 0;
    while (lines.next()) |line| : (count += 1) {
        // Skip the last line, which is truncated by the buffer bound.
        if (lines.peek() == null) break;
        // Words are emitted whole, so a line can overshoot by at most one
        // word plus its separator.
        try testing.expect(line.len <= 40 + 16);
    }
    try testing.expect(count > 10);
}
