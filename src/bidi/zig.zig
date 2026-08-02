//! A native Zig implementation of the Unicode Bidirectional Algorithm
//! (UAX #9).
//!
//! This implements the full algorithm: paragraph level detection (P2-P3),
//! explicit embeddings and isolates (X1-X8), isolating run sequences (X10),
//! weak type resolution (W1-W7), paired brackets (N0/BD16), neutral
//! resolution (N1-N2), implicit levels (I1-I2), and reordering (L1-L2).
//!
//! Rule numbers from the specification appear in comments throughout.
//! They are not decoration: the rules are subtle, frequently reordered
//! between revisions, and the only practical way to review this code is
//! side by side with the spec, so every block says which rule it is.
//!
//! Character properties come from the build-time tables in `src/unicode`,
//! which derive them from the UCD via uucode. Nothing here parses Unicode
//! data at runtime and no third-party bidi library is linked.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const unicode = @import("../unicode/main.zig");
const types = @import("types.zig");

const BidiClass = unicode.BidiClass;
const Direction = types.Direction;
const Level = types.Level;
const LevelRun = types.LevelRun;
const Options = types.Options;
const Result = types.Result;
const max_depth = types.max_depth;

/// The maximum number of bracket pairs we track per isolating run
/// sequence (BD16). The spec fixes this at 63 and requires that
/// processing stop, not fail, once it is exceeded.
const max_bracket_pairs = 63;

/// A directional override status (X1).
const Override = enum { neutral, ltr, rtl };

/// One entry on the directional status stack (X1).
const Status = struct {
    level: Level,
    override: Override,
    isolate: bool,
};

/// A bracket pair discovered by BD16, in sequence-relative positions.
const BracketPair = struct {
    open: u16,
    close: u16,
};

pub const Resolver = struct {
    /// The input, borrowed for the duration of a resolve call so N0 can
    /// look up bracket properties without copying.
    codepoints: []const u21 = &.{},

    /// Original Bidi_Class per input element, never mutated after setup.
    /// L1 needs the original classes, not the resolved ones.
    orig: std.ArrayList(BidiClass) = .empty,

    /// Working classes, mutated by the W, N, and X override rules.
    class: std.ArrayList(BidiClass) = .empty,

    /// Resolved embedding level per input element.
    levels: std.ArrayList(Level) = .empty,

    /// Indices of elements not removed by X9, in logical order. All of
    /// X10 through I2 operate on this subsequence.
    keep: std.ArrayList(u16) = .empty,

    /// For each element, the index of its matching PDI (BD9), or the
    /// input length if it has none. Only meaningful for isolate
    /// initiators.
    matching_pdi: std.ArrayList(u16) = .empty,

    /// True for each PDI that matches an earlier isolate initiator.
    /// Precomputed so X10 does not have to rescan.
    matched_pdi: std.ArrayList(bool) = .empty,

    /// Positions (indices into `keep`) of the current isolating run
    /// sequence, built fresh for each sequence in X10.
    seq: std.ArrayList(u16) = .empty,

    /// The directional status stack (X1).
    stack: std.ArrayList(Status) = .empty,

    /// Scratch index stack, used for BD9 isolate matching.
    stack_u16: std.ArrayList(u16) = .empty,

    /// Bracket pair scratch for N0.
    bracket_stack: std.ArrayList(struct { cp: u21, pos: u16 }) = .empty,
    bracket_pairs: std.ArrayList(BracketPair) = .empty,

    /// Output permutations.
    v2l: std.ArrayList(u16) = .empty,
    l2v: std.ArrayList(u16) = .empty,
    runs: std.ArrayList(LevelRun) = .empty,

    pub const empty: Resolver = .{};

    pub fn deinit(self: *Resolver, alloc: Allocator) void {
        self.orig.deinit(alloc);
        self.class.deinit(alloc);
        self.levels.deinit(alloc);
        self.keep.deinit(alloc);
        self.matching_pdi.deinit(alloc);
        self.matched_pdi.deinit(alloc);
        self.seq.deinit(alloc);
        self.stack.deinit(alloc);
        self.stack_u16.deinit(alloc);
        self.bracket_stack.deinit(alloc);
        self.bracket_pairs.deinit(alloc);
        self.v2l.deinit(alloc);
        self.l2v.deinit(alloc);
        self.runs.deinit(alloc);
        self.* = undefined;
    }

    /// Resolve one paragraph. See `types.Result` for the lifetime of the
    /// returned slices.
    pub fn resolve(
        self: *Resolver,
        alloc: Allocator,
        codepoints: []const u21,
        opts: Options,
    ) Allocator.Error!Result {
        assert(codepoints.len <= std.math.maxInt(u16));
        if (codepoints.len == 0) return .empty;
        const n: u16 = @intCast(codepoints.len);

        // Fast path: text that cannot be affected by the algorithm at all
        // resolves to the identity without touching any of the machinery
        // below. This is the overwhelmingly common case in a terminal.
        //
        // A SIMD version of this scan is a separate change; the scalar
        // form here already keeps plain left-to-right rows off the slow
        // path, which is what matters for correctness of the fast path
        // being *sound* rather than merely fast.
        if (opts.direction != .rtl and isTriviallyLtr(codepoints)) {
            self.runs.clearRetainingCapacity();
            try self.runs.append(alloc, .{
                .visual_start = 0,
                .len = n,
                .logical_start = 0,
                .level = 0,
            });
            return .{
                .direction = .ltr,
                .len = n,
                .identity = true,
                .levels = &.{},
                .v2l = &.{},
                .l2v = &.{},
                .runs = self.runs.items,
            };
        }

        try self.prepare(alloc, codepoints);

        // P2-P3: determine the paragraph embedding level.
        const para_level: Level = switch (opts.direction) {
            .ltr => 0,
            .rtl => 1,
            .auto => self.paragraphLevel(0, n),
        };

        try self.resolveExplicit(alloc, para_level);
        try self.resolveSequences(alloc, para_level);
        self.resolveImplicitLevels(para_level);
        self.applyL1(para_level);
        try self.reorder(alloc);

        return .{
            .direction = types.levelDirection(para_level),
            .len = n,
            .identity = false,
            .levels = self.levels.items,
            .v2l = self.v2l.items,
            .l2v = self.l2v.items,
            .runs = self.runs.items,
        };
    }

    /// True if no codepoint in the input can influence bidi resolution,
    /// meaning visual order is guaranteed to equal logical order.
    ///
    /// This must never produce a false negative. A false positive would
    /// merely cost performance; a false negative renders text backwards.
    /// Everything below U+0590 is left-to-right or neutral, which covers
    /// Latin, Greek, Cyrillic, and all of ASCII.
    fn isTriviallyLtr(codepoints: []const u21) bool {
        for (codepoints) |cp| {
            if (cp < 0x0590) continue;
            return false;
        }
        return true;
    }

    /// Populate the per-element arrays and compute matching PDIs.
    fn prepare(
        self: *Resolver,
        alloc: Allocator,
        codepoints: []const u21,
    ) Allocator.Error!void {
        const n: u16 = @intCast(codepoints.len);
        self.codepoints = codepoints;

        self.orig.clearRetainingCapacity();
        self.class.clearRetainingCapacity();
        self.levels.clearRetainingCapacity();
        self.matching_pdi.clearRetainingCapacity();
        self.matched_pdi.clearRetainingCapacity();

        try self.orig.ensureTotalCapacity(alloc, n);
        try self.class.ensureTotalCapacity(alloc, n);
        try self.levels.ensureTotalCapacity(alloc, n);
        try self.matching_pdi.ensureTotalCapacity(alloc, n);
        try self.matched_pdi.ensureTotalCapacity(alloc, n);

        for (codepoints) |cp| {
            const c = unicode.bidiClass(cp);
            self.orig.appendAssumeCapacity(c);
            self.class.appendAssumeCapacity(c);
            self.levels.appendAssumeCapacity(0);
            self.matching_pdi.appendAssumeCapacity(n);
            self.matched_pdi.appendAssumeCapacity(false);
        }

        // BD9: match each isolate initiator with its PDI.
        //
        // A stack gives this in one pass. The naive form -- scanning
        // forward from every initiator counting depth -- is quadratic on
        // input consisting mostly of isolate initiators, and a terminal
        // has to assume the program on the other end of the pty can print
        // exactly that.
        const classes = self.orig.items;
        self.stack_u16.clearRetainingCapacity();
        for (classes, 0..) |c, i| {
            if (c.isIsolateInitiator()) {
                try self.stack_u16.append(alloc, @intCast(i));
                continue;
            }
            if (c != .pdi) continue;

            // The PDI matches the most recent unmatched initiator, which
            // is the one on top of the stack.
            const open = self.stack_u16.pop() orelse continue;
            self.matching_pdi.items[open] = @intCast(i);
            self.matched_pdi.items[i] = true;
        }
        // Initiators still on the stack have no matching PDI and keep the
        // sentinel value of `n` assigned above.
    }

    /// P2-P3 over the range [start, end): the paragraph level is derived
    /// from the first strong character, skipping over isolate runs.
    fn paragraphLevel(self: *Resolver, start: u16, end: u16) Level {
        const classes = self.orig.items;
        var i = start;
        while (i < end) : (i += 1) {
            switch (classes[i]) {
                // P2: skip characters between an isolate initiator and
                // its matching PDI entirely.
                .lri, .rli, .fsi => {
                    i = self.matching_pdi.items[i];
                    if (i >= end) break;
                },

                // P3: L gives level 0, R and AL give level 1.
                .l => return 0,
                .r, .al => return 1,

                else => {},
            }
        }
        return 0;
    }

    /// X1-X8: compute explicit embedding levels and apply overrides.
    fn resolveExplicit(
        self: *Resolver,
        alloc: Allocator,
        para_level: Level,
    ) Allocator.Error!void {
        const n: u16 = @intCast(self.orig.items.len);

        self.stack.clearRetainingCapacity();
        try self.stack.append(alloc, .{
            .level = para_level,
            .override = .neutral,
            .isolate = false,
        });

        var overflow_isolate: usize = 0;
        var overflow_embedding: usize = 0;
        var valid_isolate: usize = 0;

        var i: u16 = 0;
        while (i < n) : (i += 1) {
            const c = self.orig.items[i];
            switch (c) {
                // X2-X5: explicit embeddings and overrides.
                .rle, .lre, .rlo, .lro => {
                    const top = self.stack.items[self.stack.items.len - 1];
                    self.levels.items[i] = top.level;

                    const rtl = c == .rle or c == .rlo;
                    const new_level = nextLevel(top.level, rtl);

                    if (new_level <= max_depth and
                        overflow_isolate == 0 and
                        overflow_embedding == 0)
                    {
                        try self.stack.append(alloc, .{
                            .level = new_level,
                            .override = switch (c) {
                                .rlo => .rtl,
                                .lro => .ltr,
                                else => .neutral,
                            },
                            .isolate = false,
                        });
                    } else if (overflow_isolate == 0) {
                        overflow_embedding += 1;
                    }
                },

                // X5a-X5c: isolate initiators.
                .rli, .lri, .fsi => {
                    // X5c: FSI behaves as RLI or LRI depending on the
                    // first strong character inside the isolate.
                    const rtl = switch (c) {
                        .rli => true,
                        .lri => false,
                        .fsi => self.paragraphLevel(
                            i + 1,
                            self.matching_pdi.items[i],
                        ) == 1,
                        else => unreachable,
                    };

                    const top = self.stack.items[self.stack.items.len - 1];

                    // The initiator itself takes the level in effect
                    // before the isolate is entered, and is subject to the
                    // current override.
                    self.levels.items[i] = top.level;
                    switch (top.override) {
                        .neutral => {},
                        .ltr => self.class.items[i] = .l,
                        .rtl => self.class.items[i] = .r,
                    }

                    const new_level = nextLevel(top.level, rtl);
                    if (new_level <= max_depth and
                        overflow_isolate == 0 and
                        overflow_embedding == 0)
                    {
                        valid_isolate += 1;
                        try self.stack.append(alloc, .{
                            .level = new_level,
                            .override = .neutral,
                            .isolate = true,
                        });
                    } else {
                        overflow_isolate += 1;
                    }
                },

                // X6a: pop directional isolate status.
                .pdi => {
                    if (overflow_isolate > 0) {
                        overflow_isolate -= 1;
                    } else if (valid_isolate > 0) {
                        overflow_embedding = 0;
                        while (!self.stack.items[self.stack.items.len - 1].isolate) {
                            _ = self.stack.pop();
                        }
                        _ = self.stack.pop();
                        valid_isolate -= 1;
                    }

                    // The PDI takes the level and override of whatever is
                    // on top of the stack *after* the pops above.
                    const top = self.stack.items[self.stack.items.len - 1];
                    self.levels.items[i] = top.level;
                    switch (top.override) {
                        .neutral => {},
                        .ltr => self.class.items[i] = .l,
                        .rtl => self.class.items[i] = .r,
                    }
                },

                // X7: pop directional format status.
                .pdf => {
                    self.levels.items[i] =
                        self.stack.items[self.stack.items.len - 1].level;

                    if (overflow_isolate > 0) {
                        // An overflowing isolate takes precedence.
                    } else if (overflow_embedding > 0) {
                        overflow_embedding -= 1;
                    } else if (!self.stack.items[self.stack.items.len - 1].isolate and
                        self.stack.items.len >= 2)
                    {
                        _ = self.stack.pop();
                    }
                },

                // X8: paragraph separators reset to the paragraph level.
                .b => self.levels.items[i] = para_level,

                // Boundary neutrals are removed by X9 but still need a
                // level so that later phases can index uniformly.
                .bn => self.levels.items[i] =
                    self.stack.items[self.stack.items.len - 1].level,

                // X6: everything else.
                else => {
                    const top = self.stack.items[self.stack.items.len - 1];
                    self.levels.items[i] = top.level;
                    switch (top.override) {
                        .neutral => {},
                        .ltr => self.class.items[i] = .l,
                        .rtl => self.class.items[i] = .r,
                    }
                },
            }
        }

        // X9: build the list of characters that survive. Rather than
        // physically removing the embedding and override formatting
        // characters we skip them, which keeps a level for every input
        // element so callers can map results back one to one.
        self.keep.clearRetainingCapacity();
        try self.keep.ensureTotalCapacity(alloc, n);
        for (self.orig.items, 0..) |c, idx| {
            if (c.isRemovedByX9()) continue;
            self.keep.appendAssumeCapacity(@intCast(idx));
        }
    }

    /// X10 plus W1-W7, N0-N2: split into isolating run sequences and
    /// resolve weak and neutral types within each.
    fn resolveSequences(
        self: *Resolver,
        alloc: Allocator,
        para_level: Level,
    ) Allocator.Error!void {
        const keep = self.keep.items;
        if (keep.len == 0) return;

        // Walk level runs over the retained subsequence. A level run is a
        // maximal range with the same resolved level.
        var run_start: usize = 0;
        while (run_start < keep.len) {
            const level = self.levels.items[keep[run_start]];
            var run_end = run_start + 1;
            while (run_end < keep.len and
                self.levels.items[keep[run_end]] == level) run_end += 1;

            // X10: a level run begins an isolating run sequence unless it
            // starts with a PDI that matches an earlier isolate
            // initiator, in which case it was already consumed by the
            // sequence containing that initiator.
            const first = keep[run_start];
            const starts_sequence = self.orig.items[first] != .pdi or
                !self.matched_pdi.items[first];

            if (starts_sequence) {
                try self.buildSequence(alloc, run_start, run_end);
                try self.resolveSequence(alloc, para_level);
            }

            run_start = run_end;
        }
    }

    /// Collect the level runs making up one isolating run sequence (X10),
    /// storing positions into `keep` in `self.seq`.
    fn buildSequence(
        self: *Resolver,
        alloc: Allocator,
        run_start: usize,
        run_end: usize,
    ) Allocator.Error!void {
        const keep = self.keep.items;
        self.seq.clearRetainingCapacity();

        var start = run_start;
        var end = run_end;
        while (true) {
            var i = start;
            while (i < end) : (i += 1) try self.seq.append(alloc, @intCast(i));

            // If this run ends with an isolate initiator that has a
            // matching PDI, the run containing that PDI continues the
            // same sequence.
            const last = keep[end - 1];
            if (!self.orig.items[last].isIsolateInitiator()) break;
            const pdi = self.matching_pdi.items[last];
            if (pdi >= self.orig.items.len) break;

            // Find the PDI's position in `keep` and the level run that
            // starts there.
            const pos = self.keepIndexOf(pdi) orelse break;
            const level = self.levels.items[keep[pos]];
            var next_end = pos + 1;
            while (next_end < keep.len and
                self.levels.items[keep[next_end]] == level) next_end += 1;

            start = pos;
            end = next_end;
        }
    }

    fn keepIndexOf(self: *Resolver, idx: u16) ?usize {
        // `keep` is sorted, so this is a binary search.
        var lo: usize = 0;
        var hi: usize = self.keep.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const v = self.keep.items[mid];
            if (v == idx) return mid;
            if (v < idx) lo = mid + 1 else hi = mid;
        }
        return null;
    }

    /// Apply W1-W7, N0-N2 to the isolating run sequence in `self.seq`.
    fn resolveSequence(
        self: *Resolver,
        alloc: Allocator,
        para_level: Level,
    ) Allocator.Error!void {
        const seq = self.seq.items;
        if (seq.len == 0) return;

        const keep = self.keep.items;
        const level = self.levels.items[keep[seq[0]]];
        const e: BidiClass = if (level & 1 == 0) .l else .r;

        // X10: compute sos and eos, the assumed types before and after
        // the sequence, from the higher of the sequence's level and the
        // level of the adjacent text.
        const sos = boundaryClass(level, blk: {
            const first = seq[0];
            break :blk if (first == 0)
                para_level
            else
                self.levels.items[keep[first - 1]];
        });

        const eos = boundaryClass(level, blk: {
            const last = seq[seq.len - 1];
            const last_idx = keep[last];
            // An isolate initiator with no matching PDI runs to the end
            // of the paragraph, so its eos uses the paragraph level.
            if (self.orig.items[last_idx].isIsolateInitiator() and
                self.matching_pdi.items[last_idx] >= self.orig.items.len)
            {
                break :blk para_level;
            }
            break :blk if (last + 1 >= keep.len)
                para_level
            else
                self.levels.items[keep[last + 1]];
        });

        // W1: NSM takes the type of the previous character; at the start
        // of the sequence it takes sos. After an isolate initiator or
        // PDI it becomes ON.
        {
            var prev = sos;
            for (seq) |p| {
                const idx = keep[p];
                const c = self.class.items[idx];
                if (c == .nsm) {
                    self.class.items[idx] = if (prev.isIsolateInitiator() or prev == .pdi)
                        .on
                    else
                        prev;
                }
                prev = self.class.items[idx];
            }
        }

        // W2: EN becomes AN when the last strong type before it is AL.
        {
            var strong = sos;
            for (seq) |p| {
                const idx = keep[p];
                switch (self.class.items[idx]) {
                    .l, .r, .al => strong = self.class.items[idx],
                    .en => if (strong == .al) {
                        self.class.items[idx] = .an;
                    },
                    else => {},
                }
            }
        }

        // W3: AL becomes R.
        for (seq) |p| {
            const idx = keep[p];
            if (self.class.items[idx] == .al) self.class.items[idx] = .r;
        }

        // W4: a single ES between two EN becomes EN; a single CS between
        // two numbers of the same type becomes that type.
        if (seq.len >= 3) {
            var i: usize = 1;
            while (i + 1 < seq.len) : (i += 1) {
                const idx = keep[seq[i]];
                const c = self.class.items[idx];
                if (c != .es and c != .cs) continue;
                const prev = self.class.items[keep[seq[i - 1]]];
                const next = self.class.items[keep[seq[i + 1]]];
                if (prev == .en and next == .en) {
                    self.class.items[idx] = .en;
                } else if (c == .cs and prev == .an and next == .an) {
                    self.class.items[idx] = .an;
                }
            }
        }

        // W5: a sequence of ET adjacent to EN becomes EN.
        {
            var i: usize = 0;
            while (i < seq.len) {
                if (self.class.items[keep[seq[i]]] != .et) {
                    i += 1;
                    continue;
                }

                var j = i;
                while (j < seq.len and
                    self.class.items[keep[seq[j]]] == .et) j += 1;

                const before_en = i > 0 and
                    self.class.items[keep[seq[i - 1]]] == .en;
                const after_en = j < seq.len and
                    self.class.items[keep[seq[j]]] == .en;

                if (before_en or after_en) {
                    var k = i;
                    while (k < j) : (k += 1) {
                        self.class.items[keep[seq[k]]] = .en;
                    }
                }

                i = j;
            }
        }

        // W6: any remaining separators and terminators become ON.
        for (seq) |p| {
            const idx = keep[p];
            switch (self.class.items[idx]) {
                .et, .es, .cs => self.class.items[idx] = .on,
                else => {},
            }
        }

        // W7: EN becomes L when the last strong type before it is L.
        {
            var strong = sos;
            for (seq) |p| {
                const idx = keep[p];
                switch (self.class.items[idx]) {
                    .l, .r => strong = self.class.items[idx],
                    .en => if (strong == .l) {
                        self.class.items[idx] = .l;
                    },
                    else => {},
                }
            }
        }

        try self.resolveBrackets(alloc, e, sos);
        self.resolveNeutrals(e, sos, eos);
    }

    /// N0 with BD16: resolve paired brackets.
    fn resolveBrackets(
        self: *Resolver,
        alloc: Allocator,
        e: BidiClass,
        sos: BidiClass,
    ) Allocator.Error!void {
        const seq = self.seq.items;
        const keep = self.keep.items;

        // BD16: locate bracket pairs with a stack, capped at 63 entries.
        // Exceeding the cap stops pair processing rather than failing.
        self.bracket_stack.clearRetainingCapacity();
        self.bracket_pairs.clearRetainingCapacity();

        for (seq, 0..) |p, i| {
            const idx = keep[p];

            // Only characters that are still ON participate.
            if (self.class.items[idx] != .on) continue;

            const cp = self.codepoints[idx];
            switch (unicode.bidiPairedBracketType(cp)) {
                .none => {},

                .open => {
                    if (self.bracket_stack.items.len >= max_bracket_pairs) {
                        // BD16: stop processing entirely on overflow.
                        self.bracket_pairs.clearRetainingCapacity();
                        return;
                    }
                    // Remember the closing bracket we are looking for, so
                    // matching is a single comparison below.
                    const want = unicode.bidiPairedBracket(cp) orelse continue;
                    try self.bracket_stack.append(alloc, .{
                        .cp = canonicalBracket(want),
                        .pos = @intCast(i),
                    });
                },

                .close => {
                    const have = canonicalBracket(cp);
                    var k = self.bracket_stack.items.len;
                    while (k > 0) {
                        k -= 1;
                        if (self.bracket_stack.items[k].cp != have) continue;

                        try self.bracket_pairs.append(alloc, .{
                            .open = self.bracket_stack.items[k].pos,
                            .close = @intCast(i),
                        });

                        // BD16: discard the matched opening bracket and
                        // everything pushed after it.
                        self.bracket_stack.shrinkRetainingCapacity(k);
                        break;
                    }
                },
            }
        }

        // Pairs must be processed in order of their opening bracket.
        std.mem.sort(BracketPair, self.bracket_pairs.items, {}, struct {
            fn lessThan(_: void, a: BracketPair, b: BracketPair) bool {
                return a.open < b.open;
            }
        }.lessThan);

        const o: BidiClass = if (e == .l) .r else .l;

        for (self.bracket_pairs.items) |pair| {
            // N0 b/c: look for a strong type inside the pair. EN and AN
            // count as R for this purpose.
            var found_e = false;
            var found_o = false;
            var i = pair.open + 1;
            while (i < pair.close) : (i += 1) {
                const s = strongClass(self.class.items[keep[seq[i]]]) orelse continue;
                if (s == e) found_e = true else found_o = true;
            }

            const new_class: ?BidiClass = if (found_e)
                // N0 b: a strong type matching the embedding direction
                // sets both brackets to that direction.
                e
            else if (found_o) blk: {
                // N0 c: only the opposite direction appears inside.
                // Check the preceding context.
                var prev: BidiClass = sos;
                var j = pair.open;
                while (j > 0) {
                    j -= 1;
                    if (strongClass(self.class.items[keep[seq[j]]])) |s| {
                        prev = s;
                        break;
                    }
                }
                // N0 c1: context matches the opposite direction, so use
                // it. N0 c2: otherwise fall back to the embedding
                // direction.
                break :blk if (prev == o) o else e;
            } else
                // N0 d: no strong type inside, leave the brackets alone.
                null;

            const nc = new_class orelse continue;
            self.class.items[keep[seq[pair.open]]] = nc;
            self.class.items[keep[seq[pair.close]]] = nc;

            // N0 note: any NSM following a paired bracket whose type
            // changed takes the same type. The original class is what
            // matters here, since W1 has already rewritten the working
            // class.
            self.applyBracketNsm(pair.open, nc);
            self.applyBracketNsm(pair.close, nc);
        }
    }

    fn applyBracketNsm(self: *Resolver, pos: u16, nc: BidiClass) void {
        const seq = self.seq.items;
        const keep = self.keep.items;
        var i: usize = pos + 1;
        while (i < seq.len) : (i += 1) {
            const idx = keep[seq[i]];
            if (self.orig.items[idx] != .nsm) break;
            self.class.items[idx] = nc;
        }
    }

    /// N1-N2: resolve remaining neutral and isolate formatting types.
    fn resolveNeutrals(
        self: *Resolver,
        e: BidiClass,
        sos: BidiClass,
        eos: BidiClass,
    ) void {
        const seq = self.seq.items;
        const keep = self.keep.items;

        var i: usize = 0;
        while (i < seq.len) {
            if (!isNI(self.class.items[keep[seq[i]]])) {
                i += 1;
                continue;
            }

            var j = i;
            while (j < seq.len and isNI(self.class.items[keep[seq[j]]])) j += 1;

            // The types bracketing this run of neutrals, with numbers
            // counting as R.
            const before: BidiClass = if (i == 0)
                sos
            else
                strongOrNumber(self.class.items[keep[seq[i - 1]]]);

            const after: BidiClass = if (j >= seq.len)
                eos
            else
                strongOrNumber(self.class.items[keep[seq[j]]]);

            // N1: neutrals between two matching directions take that
            // direction. N2: otherwise they take the embedding direction.
            const resolved: BidiClass = if (before == after and
                (before == .l or before == .r)) before else e;

            var k = i;
            while (k < j) : (k += 1) {
                self.class.items[keep[seq[k]]] = resolved;
            }

            i = j;
        }
    }

    /// I1-I2: raise levels according to the resolved types.
    fn resolveImplicitLevels(self: *Resolver, para_level: Level) void {
        for (self.keep.items) |idx| {
            const level = self.levels.items[idx];
            const c = self.class.items[idx];
            if (level & 1 == 0) {
                // I1: at an even level, R goes up one, AN and EN go up
                // two.
                self.levels.items[idx] = switch (c) {
                    .r => level + 1,
                    .an, .en => level + 2,
                    else => level,
                };
            } else {
                // I2: at an odd level, L, EN, and AN all go up one.
                self.levels.items[idx] = switch (c) {
                    .l, .en, .an => level + 1,
                    else => level,
                };
            }
        }

        // Characters removed by X9 never received an implicit level.
        // Give them the level of the preceding retained character so they
        // do not split a level run, which is the behavior recommended for
        // implementations that retain the formatting characters.
        var last: Level = para_level;
        for (self.orig.items, 0..) |c, i| {
            if (!c.isRemovedByX9()) {
                last = self.levels.items[i];
                continue;
            }
            self.levels.items[i] = last;
        }
    }

    /// L1: reset separators and trailing whitespace to the paragraph
    /// level. This uses the *original* classes, not the resolved ones.
    fn applyL1(self: *Resolver, para_level: Level) void {
        const orig = self.orig.items;
        const n = orig.len;

        var i: usize = 0;
        var reset_from: ?usize = 0;
        while (i < n) : (i += 1) {
            switch (orig[i]) {
                // L1 items 1 and 2: segment and paragraph separators go
                // to the paragraph level, along with any run of
                // whitespace or isolate formatting characters before
                // them.
                .b, .s => {
                    self.levels.items[i] = para_level;
                    if (reset_from) |from| {
                        var k = from;
                        while (k < i) : (k += 1) self.levels.items[k] = para_level;
                    }
                    reset_from = i + 1;
                },

                // L1 items 3 and 4: whitespace and isolate formatting
                // characters are candidates for resetting if they run to
                // the end of the line or up to a separator. Characters
                // removed by X9 are transparent here.
                .ws, .lri, .rli, .fsi, .pdi => {
                    if (reset_from == null) reset_from = i;
                },

                .rle, .lre, .rlo, .lro, .pdf, .bn => {},

                else => reset_from = null,
            }
        }

        // L1 item 4: a trailing run reaching the end of the line.
        if (reset_from) |from| {
            var k = from;
            while (k < n) : (k += 1) self.levels.items[k] = para_level;
        }
    }

    /// L2 plus level run extraction: reverse contiguous runs from the
    /// highest level down to the lowest odd level.
    fn reorder(self: *Resolver, alloc: Allocator) Allocator.Error!void {
        const n: u16 = @intCast(self.levels.items.len);
        const levels = self.levels.items;

        self.v2l.clearRetainingCapacity();
        self.l2v.clearRetainingCapacity();
        try self.v2l.resize(alloc, n);
        try self.l2v.resize(alloc, n);

        for (self.v2l.items, 0..) |*v, i| v.* = @intCast(i);

        // Find the highest level and the lowest odd level.
        var highest: Level = 0;
        var lowest_odd: Level = max_depth + 1;
        for (levels) |l| {
            if (l > highest) highest = l;
            if (l & 1 == 1 and l < lowest_odd) lowest_odd = l;
        }

        // L2: for each level from the highest down to the lowest odd,
        // reverse every contiguous run of characters at or above it.
        if (lowest_odd <= highest) {
            var level = highest;
            while (level >= lowest_odd) : (level -= 1) {
                var i: usize = 0;
                while (i < n) {
                    if (levels[self.v2l.items[i]] < level) {
                        i += 1;
                        continue;
                    }
                    var j = i;
                    while (j < n and levels[self.v2l.items[j]] >= level) j += 1;
                    std.mem.reverse(u16, self.v2l.items[i..j]);
                    i = j;
                }

                // Level is unsigned; stop before it wraps.
                if (level == 0) break;
            }
        }

        // The inverse permutation.
        for (self.v2l.items, 0..) |logical, visual| {
            self.l2v.items[logical] = @intCast(visual);
        }

        // Extract level runs in visual order.
        self.runs.clearRetainingCapacity();
        var i: usize = 0;
        while (i < n) {
            const level = levels[self.v2l.items[i]];
            var j = i + 1;
            while (j < n and levels[self.v2l.items[j]] == level) j += 1;

            // The lowest logical index in the run. For an RTL run the
            // logical indices descend as the visual indices ascend.
            var lo: u16 = self.v2l.items[i];
            for (self.v2l.items[i..j]) |idx| lo = @min(lo, idx);

            try self.runs.append(alloc, .{
                .visual_start = @intCast(i),
                .len = @intCast(j - i),
                .logical_start = lo,
                .level = level,
            });

            i = j;
        }
    }
};

/// The next embedding level above `level` in the given direction (X2-X5).
fn nextLevel(level: Level, rtl: bool) Level {
    return if (rtl)
        (level + 1) | 1
    else
        (level + 2) & ~@as(Level, 1);
}

/// X10: the assumed type at a sequence boundary, from the higher of the
/// two adjacent levels.
fn boundaryClass(seq_level: Level, adjacent_level: Level) BidiClass {
    const level = @max(seq_level, adjacent_level);
    return if (level & 1 == 0) .l else .r;
}

/// True for the "neutral or isolate formatting" types (BD13 note, N1).
fn isNI(c: BidiClass) bool {
    return switch (c) {
        .b, .s, .ws, .on, .fsi, .lri, .rli, .pdi => true,
        else => false,
    };
}

/// The strong direction a class contributes for N0, where numbers count
/// as R. Returns null for classes that are not strong.
fn strongClass(c: BidiClass) ?BidiClass {
    return switch (c) {
        .l => .l,
        .r, .en, .an => .r,
        else => null,
    };
}

/// Like `strongClass` but total, mapping non-strong types to themselves.
/// Used by N1 where the neighbours are already resolved.
fn strongOrNumber(c: BidiClass) BidiClass {
    return switch (c) {
        .l => .l,
        .r, .en, .an => .r,
        else => c,
    };
}

/// BD16 requires canonical equivalence when matching brackets, which in
/// practice means the two CJK angle bracket pairs that are singleton
/// decompositions of the mathematical ones.
fn canonicalBracket(cp: u21) u21 {
    return switch (cp) {
        0x3008 => 0x2329,
        0x3009 => 0x232A,
        else => cp,
    };
}

// -- Tests --------------------------------------------------------------
//
// The UCD conformance suites in `conformance_test.zig` are the
// authoritative check and cover ~862,000 cases. The tests below are
// deliberately small and readable: they document what the algorithm is
// supposed to do for the cases a terminal actually hits, and they run on
// every build without needing the 15 MB of UCD data downloaded.

const testing = std.testing;

/// Resolve a string of codepoints and return the visual order as a string
/// of the same codepoints, for tests that are easier to read as text.
fn testVisual(
    alloc: Allocator,
    resolver: *Resolver,
    cps: []const u21,
    dir: types.ParagraphDirection,
    out: []u21,
) ![]u21 {
    const result = try resolver.resolve(alloc, cps, .{ .direction = dir });
    for (0..cps.len) |v| out[v] = cps[result.logicalIndex(v)];
    return out[0..cps.len];
}

test "uba: pure ascii takes the identity fast path" {
    const alloc = testing.allocator;
    var r: Resolver = .empty;
    defer r.deinit(alloc);

    const cps = [_]u21{ 'h', 'e', 'l', 'l', 'o' };
    const result = try r.resolve(alloc, &cps, .{});

    try testing.expect(result.identity);
    try testing.expectEqual(Direction.ltr, result.direction);
    try testing.expectEqual(@as(usize, 0), result.levels.len);
    for (0..cps.len) |i| try testing.expectEqual(i, result.logicalIndex(i));
}

test "uba: hebrew reverses" {
    const alloc = testing.allocator;
    var r: Resolver = .empty;
    defer r.deinit(alloc);

    // Alef, bet, gimel. Logical order is alef-bet-gimel; on screen the
    // alef must appear rightmost.
    const cps = [_]u21{ 0x05D0, 0x05D1, 0x05D2 };
    var buf: [3]u21 = undefined;
    const visual = try testVisual(alloc, &r, &cps, .auto, &buf);

    try testing.expectEqualSlices(u21, &.{ 0x05D2, 0x05D1, 0x05D0 }, visual);

    // P2/P3: the first strong character is R, so the paragraph is RTL.
    const result = try r.resolve(alloc, &cps, .{});
    try testing.expectEqual(Direction.rtl, result.direction);
    try testing.expect(!result.identity);
}

test "uba: mixed latin and hebrew reverses only the hebrew" {
    const alloc = testing.allocator;
    var r: Resolver = .empty;
    defer r.deinit(alloc);

    // "abc" + space + hebrew alef/bet/gimel, in an LTR paragraph.
    const cps = [_]u21{ 'a', 'b', 'c', ' ', 0x05D0, 0x05D1, 0x05D2 };
    var buf: [7]u21 = undefined;
    const visual = try testVisual(alloc, &r, &cps, .auto, &buf);

    try testing.expectEqualSlices(
        u21,
        &.{ 'a', 'b', 'c', ' ', 0x05D2, 0x05D1, 0x05D0 },
        visual,
    );
}

test "uba: numbers stay left to right inside rtl" {
    const alloc = testing.allocator;
    var r: Resolver = .empty;
    defer r.deinit(alloc);

    // Hebrew followed by "123". The Hebrew reverses; the digits must not.
    // Getting this wrong is how phone numbers and versions end up
    // silently backwards.
    const cps = [_]u21{ 0x05D0, 0x05D1, ' ', '1', '2', '3' };
    var buf: [6]u21 = undefined;
    const visual = try testVisual(alloc, &r, &cps, .auto, &buf);

    try testing.expectEqualSlices(
        u21,
        &.{ '1', '2', '3', ' ', 0x05D1, 0x05D0 },
        visual,
    );
}

test "uba: arabic-indic digits are AN, extended ones are EN" {
    const alloc = testing.allocator;
    var r: Resolver = .empty;
    defer r.deinit(alloc);

    // Both digit runs render left to right within themselves. This is the
    // Persian-versus-Arabic distinction that P0.1's tables encode; here we
    // just confirm neither run gets internally reversed.
    inline for (.{
        [_]u21{ 0x05D0, 0x0660, 0x0661, 0x0662 },
        [_]u21{ 0x05D0, 0x06F0, 0x06F1, 0x06F2 },
    }) |cps| {
        var buf: [4]u21 = undefined;
        const visual = try testVisual(alloc, &r, &cps, .auto, &buf);
        try testing.expectEqualSlices(
            u21,
            &.{ cps[1], cps[2], cps[3], 0x05D0 },
            visual,
        );
    }
}

test "uba: brackets mirror position in rtl (N0)" {
    const alloc = testing.allocator;
    var r: Resolver = .empty;
    defer r.deinit(alloc);

    // Hebrew with a parenthesized Hebrew word. The parentheses must swap
    // places so they still enclose. Note the codepoints are unchanged;
    // substituting the mirrored glyph is a rendering step (rule L4), not
    // a reordering one.
    const cps = [_]u21{ 0x05D0, ' ', '(', 0x05D1, 0x05D2, ')' };
    var buf: [6]u21 = undefined;
    const visual = try testVisual(alloc, &r, &cps, .auto, &buf);

    try testing.expectEqualSlices(
        u21,
        &.{ ')', 0x05D2, 0x05D1, '(', ' ', 0x05D0 },
        visual,
    );
}

test "uba: forced paragraph direction overrides P2/P3" {
    const alloc = testing.allocator;
    var r: Resolver = .empty;
    defer r.deinit(alloc);

    const cps = [_]u21{ 'a', 'b', ' ', 0x05D0, 0x05D1 };

    // Auto: first strong is L, so LTR.
    {
        const result = try r.resolve(alloc, &cps, .{ .direction = .auto });
        try testing.expectEqual(Direction.ltr, result.direction);
    }

    // Forced RTL moves the Latin run to the right of the Hebrew.
    {
        var buf: [5]u21 = undefined;
        const visual = try testVisual(alloc, &r, &cps, .rtl, &buf);
        try testing.expectEqualSlices(
            u21,
            &.{ 0x05D1, 0x05D0, ' ', 'a', 'b' },
            visual,
        );
    }
}

test "uba: isolates confine their contents" {
    const alloc = testing.allocator;
    var r: Resolver = .empty;
    defer r.deinit(alloc);

    // "a" RLI hebrew PDI "b". The isolate keeps the Hebrew from
    // interacting with the surrounding Latin, so "a" and "b" stay put.
    const cps = [_]u21{ 'a', 0x2067, 0x05D0, 0x05D1, 0x2069, 'b' };
    const result = try r.resolve(alloc, &cps, .{});

    try testing.expectEqual(Direction.ltr, result.direction);
    try testing.expectEqual(@as(usize, 0), result.visualIndex(0)); // 'a'
    try testing.expectEqual(@as(usize, 5), result.visualIndex(5)); // 'b'

    // Inside the isolate the Hebrew is reversed.
    try testing.expect(result.visualIndex(2) > result.visualIndex(3));
}

test "uba: overrides force direction (RLO)" {
    const alloc = testing.allocator;
    var r: Resolver = .empty;
    defer r.deinit(alloc);

    // RLO makes even Latin letters resolve as RTL, which is exactly the
    // Trojan Source vector. The algorithm must honor it; the defense is a
    // paste-time warning, not silently ignoring the character.
    const cps = [_]u21{ 0x202E, 'a', 'b', 'c', 0x202C };
    const result = try r.resolve(alloc, &cps, .{});

    try testing.expect(result.visualIndex(1) > result.visualIndex(3));
}

test "uba: trailing whitespace resets to paragraph level (L1)" {
    const alloc = testing.allocator;
    var r: Resolver = .empty;
    defer r.deinit(alloc);

    // In an RTL paragraph, trailing spaces belong at the paragraph level
    // so they do not drag to the wrong edge.
    const cps = [_]u21{ 0x05D0, 0x05D1, ' ', ' ' };
    const result = try r.resolve(alloc, &cps, .{});

    try testing.expectEqual(Direction.rtl, result.direction);
    try testing.expectEqual(@as(Level, 1), result.level(2));
    try testing.expectEqual(@as(Level, 1), result.level(3));
}

test "uba: level runs cover every element exactly once" {
    const alloc = testing.allocator;
    var r: Resolver = .empty;
    defer r.deinit(alloc);

    const inputs = [_][]const u21{
        &.{ 'a', 'b', 'c' },
        &.{ 0x05D0, 0x05D1 },
        &.{ 'a', ' ', 0x05D0, ' ', '1', '2' },
        &.{ 'a', 0x2067, 0x05D0, 0x2069, 'b' },
        &.{ 0x202E, 'a', 0x05D0, 0x202C, '!' },
    };

    for (inputs) |cps| {
        const result = try r.resolve(alloc, cps, .{});

        var covered: usize = 0;
        var expect_start: u16 = 0;
        for (result.runs) |run| {
            try testing.expectEqual(expect_start, run.visual_start);
            covered += run.len;
            expect_start += run.len;
        }
        try testing.expectEqual(result.len, covered);

        // The two permutations must be mutual inverses.
        for (0..result.len) |i| {
            try testing.expectEqual(i, result.logicalIndex(result.visualIndex(i)));
            try testing.expectEqual(i, result.visualIndex(result.logicalIndex(i)));
        }
    }
}

test "uba: steady state performs no allocations" {
    var counting: std.testing.FailingAllocator = .init(testing.allocator, .{
        .fail_index = std.math.maxInt(usize),
    });
    const alloc = counting.allocator();

    var r: Resolver = .empty;
    defer r.deinit(alloc);

    const cps = [_]u21{ 'a', ' ', 0x05D0, 0x05D1, ' ', '4', '2' };

    // Warm up: these calls are allowed to grow the scratch buffers.
    for (0..4) |_| _ = try r.resolve(alloc, &cps, .{});
    const after_warmup = counting.allocations;

    for (0..128) |_| _ = try r.resolve(alloc, &cps, .{});
    try testing.expectEqual(after_warmup, counting.allocations);
}

test "uba: empty and single element input" {
    const alloc = testing.allocator;
    var r: Resolver = .empty;
    defer r.deinit(alloc);

    {
        const result = try r.resolve(alloc, &.{}, .{});
        try testing.expectEqual(@as(usize, 0), result.len);
    }
    {
        const result = try r.resolve(alloc, &.{0x05D0}, .{});
        try testing.expectEqual(@as(usize, 1), result.len);
        try testing.expectEqual(Direction.rtl, result.direction);
        try testing.expectEqual(@as(usize, 0), result.logicalIndex(0));
    }
}
