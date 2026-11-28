const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;

const level_mod = @import("level.zig");
const BidiLevel = level_mod.BidiLevel;
const types = @import("types.zig");
const ParDirection = types.ParDirection;
const unicode = @import("../data/unicode.zig");
const BidiClass = unicode.BidiClass;

const max_explicit_level = level_mod.max_explicit_level;
const max_depth = level_mod.max_depth;

/// A run of consecutive codepoints sharing the same resolved properties.
const Run = struct {
    pos: u32,
    len: u32,
    class: BidiClass,
    orig_class: BidiClass, // class at start of W1 (for N0 NSM handling)
    level: BidiLevel,
    isolate_level: u8,
    bracket_cp: u21, // paired bracket codepoint, 0 = none
    is_open_bracket: bool,
};

const LevelRun = struct {
    start: usize,
    end: usize, // exclusive
};

const IsolatingRunSequence = struct {
    run_indices: []const u32,
    sos: BidiClass,
    eos: BidiClass,
};

const IsolatingRunSequences = struct {
    sequences: []IsolatingRunSequence,
    run_indices_pool: []u32,
};

const IsolatingSeqMeta = struct {
    head: i32,
    tail: i32,
    has_items: bool,
};

const IsolatingSeqNode = struct {
    level_run_idx: u32,
    next: i32,
};

const BracketPair = struct {
    open_run_idx: u32,
    close_run_idx: u32,
    seq_idx: u32,
    open_seq_pos: u32,
    close_seq_pos: u32,
};

const BracketInfo = struct {
    cp: u21,
    is_open: bool,
};

pub const EmbeddingScratch = struct {
    classes: ArrayList(BidiClass) = .empty,
    runs: ArrayList(Run) = .empty,
    level_runs: ArrayList(LevelRun) = .empty,
    levels: ArrayList(BidiLevel) = .empty,
    run_indices_pool: ArrayList(u32) = .empty,
    sequences: ArrayList(IsolatingRunSequence) = .empty,
    irs_stack: ArrayList(u32) = .empty,
    irs_finished: ArrayList(u32) = .empty,
    irs_seq_meta: ArrayList(IsolatingSeqMeta) = .empty,
    irs_seq_nodes: ArrayList(IsolatingSeqNode) = .empty,
    et_run_indices: ArrayList(u32) = .empty,
    bracket_pairs: ArrayList(BracketPair) = .empty,

    pub fn deinit(self: *EmbeddingScratch, allocator: Allocator) void {
        self.classes.deinit(allocator);
        self.runs.deinit(allocator);
        self.level_runs.deinit(allocator);
        self.levels.deinit(allocator);
        self.run_indices_pool.deinit(allocator);
        self.sequences.deinit(allocator);
        self.irs_stack.deinit(allocator);
        self.irs_finished.deinit(allocator);
        self.irs_seq_meta.deinit(allocator);
        self.irs_seq_nodes.deinit(allocator);
        self.et_run_indices.deinit(allocator);
        self.bracket_pairs.deinit(allocator);
    }
};

/// Status entry for the directional status stack (X1-X8).
const StatusEntry = struct {
    level: BidiLevel,
    override: Override,
    isolate: bool,
    isolate_level: u8,
};

const Override = enum { none, ltr, rtl };

fn requiresExplicitGranularity(class: BidiClass) bool {
    return switch (class) {
        .left_to_right_embedding,
        .right_to_left_embedding,
        .left_to_right_override,
        .right_to_left_override,
        .pop_directional_format,
        => true,
        else => false,
    };
}

fn requiresWeakGranularity(class: BidiClass) bool {
    return switch (class) {
        .european_number_separator,
        .common_number_separator,
        .european_number_terminator,
        .nonspacing_mark,
        => true,
        else => false,
    };
}

fn isRtlOrNonLtrStrong(class: BidiClass) bool {
    return switch (class) {
        .right_to_left,
        .right_to_left_arabic,
        .arabic_number,
        => true,
        else => false,
    };
}

pub fn hasStrongRtl(codepoints: []const u21) bool {
    for (codepoints) |cp| {
        if (unicode.isRtlStrong(unicode.bidiClass(cp))) return true;
    }
    return false;
}

fn canUseLtrAllZeroPreScan(par_dir: ParDirection, codepoints: []const u21) bool {
    if (par_dir == .rtl) return false;

    var has_ltr_strong = false;
    for (codepoints) |cp| {
        const class = unicode.bidiClass(cp);
        switch (class) {
            .left_to_right => has_ltr_strong = true,
            .right_to_left,
            .right_to_left_arabic,
            .arabic_number,
            .left_to_right_embedding,
            .right_to_left_embedding,
            .left_to_right_override,
            .right_to_left_override,
            .pop_directional_format,
            .left_to_right_isolate,
            .right_to_left_isolate,
            .first_strong_isolate,
            .pop_directional_isolate,
            => return false,
            else => {},
        }
    }

    return switch (par_dir) {
        .ltr, .auto_ltr => true,
        .auto_rtl => has_ltr_strong,
        .rtl => unreachable,
    };
}

fn canUseSimpleLtrFastPath(par_dir: ParDirection, classes: []const BidiClass) bool {
    if (par_dir != .ltr and par_dir != .auto_ltr) return false;

    for (classes) |class| {
        if (class == .left_to_right) continue;
        if (isRtlOrNonLtrStrong(class)) return false;
        if (requiresExplicitGranularity(class)) return false;
        if (requiresWeakGranularity(class)) return false;
        if (unicode.isIsolateInitiator(class) or class == .pop_directional_isolate) return false;
        if (class == .european_number or class == .arabic_number) return false;
    }
    return true;
}

fn canUseLtrAllZeroResolvedFastPath(par_dir: ParDirection, classes: []const BidiClass) bool {
    if (par_dir != .ltr and par_dir != .auto_ltr) return false;

    for (classes) |class| {
        switch (class) {
            .right_to_left,
            .right_to_left_arabic,
            .arabic_number,
            .left_to_right_embedding,
            .right_to_left_embedding,
            .left_to_right_override,
            .right_to_left_override,
            .pop_directional_format,
            .left_to_right_isolate,
            .right_to_left_isolate,
            .first_strong_isolate,
            .pop_directional_isolate,
            => return false,
            else => {},
        }
    }
    return true;
}

/// Resolve paragraph embedding levels for a codepoint sequence.
/// Implements Rules P2-P3, X1-X8, W1-W7, N0-N2, I1-I2.
pub fn getParEmbeddingLevels(
    allocator: Allocator,
    codepoints: []const u21,
    par_dir: *ParDirection,
) !types.EmbeddingResult {
    const len: u32 = @intCast(codepoints.len);
    if (len == 0) {
        const levels = try allocator.alloc(BidiLevel, 0);
        const resolved_dir = resolveEmptyParDirection(par_dir);
        return .{
            .levels = levels,
            .resolved_par_dir = resolved_dir,
        };
    }

    if (canUseLtrAllZeroPreScan(par_dir.*, codepoints)) {
        const levels = try allocator.alloc(BidiLevel, len);
        @memset(levels, level_mod.ltr_level);
        par_dir.* = .ltr;
        return .{
            .levels = levels,
            .resolved_par_dir = .ltr,
        };
    }

    // Get bidi classes
    const classes = try allocator.alloc(BidiClass, len);
    defer allocator.free(classes);

    for (codepoints, 0..) |cp, i| {
        classes[i] = unicode.bidiClass(cp);
    }

    // Fast path: non-RTL paragraph request with all-L input resolves trivially.
    if (par_dir.* != .rtl) {
        var all_ltr = true;
        for (classes) |class| {
            if (class != .left_to_right) {
                all_ltr = false;
                break;
            }
        }
        if (all_ltr) {
            const levels = try allocator.alloc(BidiLevel, len);
            @memset(levels, level_mod.ltr_level);
            par_dir.* = .ltr;
            return .{
                .levels = levels,
                .resolved_par_dir = .ltr,
            };
        }
    }

    // Fast path: explicit/weak-free LTR text (spaces/punctuation/separators only around L).
    if (canUseSimpleLtrFastPath(par_dir.*, classes)) {
        const levels = try allocator.alloc(BidiLevel, len);
        @memset(levels, level_mod.ltr_level);
        par_dir.* = .ltr;
        return .{
            .levels = levels,
            .resolved_par_dir = .ltr,
        };
    }

    // Fast path: no RTL-driving classes and no explicit/isolate controls in LTR paragraph.
    // Under these constraints, all resolved levels are 0.
    if (canUseLtrAllZeroResolvedFastPath(par_dir.*, classes)) {
        const levels = try allocator.alloc(BidiLevel, len);
        @memset(levels, level_mod.ltr_level);
        par_dir.* = .ltr;
        return .{
            .levels = levels,
            .resolved_par_dir = .ltr,
        };
    }

    // P2-P3: Determine paragraph level
    var base_level: BidiLevel = par_dir.toLevel();
    if (par_dir.isAuto()) {
        const detected = findFirstStrongDir(classes);
        if (detected) |dir| {
            base_level = dir.toLevel();
        }
        // else: keep fallback from auto_ltr (0) or auto_rtl (1)
    }
    const resolved_dir: ParDirection = if (level_mod.isRtl(base_level)) .rtl else .ltr;
    par_dir.* = resolved_dir;

    // Build run-length encoded runs
    var runs = ArrayList(Run){};
    defer runs.deinit(allocator);
    try buildRuns(allocator, &runs, classes, codepoints, len);

    // X1-X8: Resolve explicit levels
    try resolveExplicit(&runs, base_level);

    // X9: Remove explicit codes (we keep them in the array but mark them BN)
    // Already handled by resolveExplicit setting class to BN

    for (runs.items) |*run| {
        run.orig_class = run.class;
    }

    // X10: Build isolating run sequences for W/N processing.
    const level_runs = try computeLevelRuns(allocator, runs.items);
    defer allocator.free(level_runs);

    const sequences_data = try computeIsolatingRunSequences(allocator, runs.items, level_runs, base_level);
    defer deinitIsolatingRunSequences(allocator, sequences_data);
    const sequences = sequences_data.sequences;

    // W1-W7: Resolve weak types per isolating run sequence.
    try resolveWeak(allocator, runs.items, sequences);

    // N0-N2: Resolve brackets and neutrals per isolating run sequence.
    try resolveBracketsAndNeutrals(allocator, codepoints, runs.items, sequences);

    // I1-I2: Resolve implicit levels
    resolveImplicit(runs.items);

    // Fill final levels from runs
    const levels = try allocator.alloc(BidiLevel, len);
    errdefer allocator.free(levels);
    fillLevelsFromRuns(runs.items, levels);

    // Match X9 reinsertion behavior: removed codes inherit the previous
    // resolved level (or paragraph level at index 0) so they don't perturb L2.
    setRemovedLevelsFromPreceding(levels, classes, base_level);

    // L1 (parts 1-3): Reset levels for segment/paragraph separators and whitespace before them
    applyL1(levels, classes, base_level);

    return .{
        .levels = levels,
        .resolved_par_dir = resolved_dir,
    };
}

/// Resolve paragraph embedding levels using reusable scratch buffers.
///
/// Returned levels are owned by `scratch` and remain valid until the next call that
/// mutates the same scratch object.
pub fn getParEmbeddingLevelsScratchView(
    allocator: Allocator,
    scratch: *EmbeddingScratch,
    codepoints: []const u21,
    par_dir: *ParDirection,
) !types.EmbeddingScratchView {
    const len = codepoints.len;
    const len_u32: u32 = @intCast(len);
    if (len == 0) {
        scratch.levels.items.len = 0;
        const resolved_dir = resolveEmptyParDirection(par_dir);
        return .{
            .levels = scratch.levels.items,
            .resolved_par_dir = resolved_dir,
        };
    }

    if (canUseLtrAllZeroPreScan(par_dir.*, codepoints)) {
        try scratch.levels.ensureTotalCapacity(allocator, len);
        scratch.levels.items.len = len;
        @memset(scratch.levels.items, level_mod.ltr_level);
        par_dir.* = .ltr;
        return .{
            .levels = scratch.levels.items,
            .resolved_par_dir = .ltr,
        };
    }

    // Get bidi classes
    try scratch.classes.ensureTotalCapacity(allocator, len);
    scratch.classes.items.len = len;
    const classes = scratch.classes.items;

    for (codepoints, 0..) |cp, i| {
        classes[i] = unicode.bidiClass(cp);
    }

    // Fast path: non-RTL paragraph request with all-L input resolves trivially.
    if (par_dir.* != .rtl) {
        var all_ltr = true;
        for (classes) |class| {
            if (class != .left_to_right) {
                all_ltr = false;
                break;
            }
        }
        if (all_ltr) {
            try scratch.levels.ensureTotalCapacity(allocator, len);
            scratch.levels.items.len = len;
            @memset(scratch.levels.items, level_mod.ltr_level);
            par_dir.* = .ltr;
            return .{
                .levels = scratch.levels.items,
                .resolved_par_dir = .ltr,
            };
        }
    }

    // Fast path: explicit/weak-free LTR text (spaces/punctuation/separators only around L).
    if (canUseSimpleLtrFastPath(par_dir.*, classes)) {
        try scratch.levels.ensureTotalCapacity(allocator, len);
        scratch.levels.items.len = len;
        @memset(scratch.levels.items, level_mod.ltr_level);
        par_dir.* = .ltr;
        return .{
            .levels = scratch.levels.items,
            .resolved_par_dir = .ltr,
        };
    }

    if (canUseLtrAllZeroResolvedFastPath(par_dir.*, classes)) {
        try scratch.levels.ensureTotalCapacity(allocator, len);
        scratch.levels.items.len = len;
        @memset(scratch.levels.items, level_mod.ltr_level);
        par_dir.* = .ltr;
        return .{
            .levels = scratch.levels.items,
            .resolved_par_dir = .ltr,
        };
    }

    // P2-P3: Determine paragraph level
    var base_level: BidiLevel = par_dir.toLevel();
    if (par_dir.isAuto()) {
        const detected = findFirstStrongDir(classes);
        if (detected) |dir| {
            base_level = dir.toLevel();
        }
        // else: keep fallback from auto_ltr (0) or auto_rtl (1)
    }
    const resolved_dir: ParDirection = if (level_mod.isRtl(base_level)) .rtl else .ltr;
    par_dir.* = resolved_dir;

    // Build run-length encoded runs
    scratch.runs.clearRetainingCapacity();
    try buildRuns(allocator, &scratch.runs, classes, codepoints, len_u32);

    // X1-X8: Resolve explicit levels
    try resolveExplicit(&scratch.runs, base_level);

    // X9: Remove explicit codes (we keep them in the array but mark them BN)
    // Already handled by resolveExplicit setting class to BN

    for (scratch.runs.items) |*run| {
        run.orig_class = run.class;
    }

    // X10: Build isolating run sequences for W/N processing.
    const level_runs = try computeLevelRunsScratch(allocator, scratch, scratch.runs.items);
    const sequences = if (runsHaveIsolates(scratch.runs.items))
        try computeIsolatingRunSequencesScratch(
            allocator,
            scratch,
            scratch.runs.items,
            level_runs,
            base_level,
        )
    else
        try computeIsolatingRunSequencesNoIsolatesScratch(
            allocator,
            scratch,
            scratch.runs.items,
            level_runs,
            base_level,
        );
    try resolveWeakWithEtBuffer(allocator, &scratch.et_run_indices, scratch.runs.items, sequences);
    try resolveBracketsAndNeutralsScratch(allocator, scratch, codepoints, scratch.runs.items, sequences);

    // I1-I2: Resolve implicit levels
    resolveImplicit(scratch.runs.items);

    // Fill final levels from runs.
    try scratch.levels.ensureTotalCapacity(allocator, len);
    scratch.levels.items.len = len;
    fillLevelsFromRuns(scratch.runs.items, scratch.levels.items);

    // Match X9 reinsertion behavior: removed codes inherit the previous
    // resolved level (or paragraph level at index 0) so they don't perturb L2.
    setRemovedLevelsFromPreceding(scratch.levels.items, classes, base_level);

    // L1 (parts 1-3): Reset levels for segment/paragraph separators and whitespace before them
    applyL1(scratch.levels.items, classes, base_level);

    return .{
        .levels = scratch.levels.items,
        .resolved_par_dir = resolved_dir,
    };
}

/// P2: Find first strong character direction, skipping isolate pairs.
fn findFirstStrongDir(classes: []const BidiClass) ?level_mod.Direction {
    var valid_isolate_count: u32 = 0;
    for (classes) |class| {
        if (class == .pop_directional_isolate) {
            if (valid_isolate_count > 0) valid_isolate_count -= 1;
        } else if (unicode.isIsolateInitiator(class)) {
            valid_isolate_count += 1;
        } else if (valid_isolate_count == 0 and unicode.isStrong(class)) {
            return if (unicode.isRtlStrong(class)) .rtl else .ltr;
        }
    }
    return null;
}

fn buildRuns(
    allocator: Allocator,
    runs: *ArrayList(Run),
    classes: []const BidiClass,
    codepoints: []const u21,
    len: u32,
) !void {
    const use_preallocated_runs = len >= 128;
    if (use_preallocated_runs) {
        const estimated = estimateRunCount(classes, codepoints, len);
        try runs.ensureTotalCapacity(allocator, estimated);
    }

    var i: u32 = 0;
    while (i < len) {
        const class = classes[i];
        const bracket = pairedBracketInfoForClass(class, codepoints[i]);
        const start = i;
        i += 1;

        // Brackets, isolates, and explicit formatting codes must be their own runs.
        if (bracket.cp != 0 or unicode.isIsolate(class) or requiresExplicitGranularity(class) or requiresWeakGranularity(class)) {
            if (use_preallocated_runs) {
                runs.appendAssumeCapacity(.{
                    .pos = start,
                    .len = 1,
                    .class = class,
                    .orig_class = class,
                    .level = 0,
                    .isolate_level = 0,
                    .bracket_cp = bracket.cp,
                    .is_open_bracket = bracket.is_open,
                });
            } else try runs.append(allocator, .{
                .pos = start,
                .len = 1,
                .class = class,
                .orig_class = class,
                .level = 0,
                .isolate_level = 0,
                .bracket_cp = bracket.cp,
                .is_open_bracket = bracket.is_open,
            });
            continue;
        }

        // Merge consecutive same-class runs when no per-codepoint handling is required.
        while (i < len and
            classes[i] == class and
            pairedBracketInfoForClass(classes[i], codepoints[i]).cp == 0 and
            !unicode.isIsolate(classes[i]) and
            !requiresExplicitGranularity(classes[i]) and
            !requiresWeakGranularity(classes[i]))
        {
            i += 1;
        }
        if (use_preallocated_runs) {
            runs.appendAssumeCapacity(.{
                .pos = start,
                .len = i - start,
                .class = class,
                .orig_class = class,
                .level = 0,
                .isolate_level = 0,
                .bracket_cp = 0,
                .is_open_bracket = false,
            });
        } else try runs.append(allocator, .{
            .pos = start,
            .len = i - start,
            .class = class,
            .orig_class = class,
            .level = 0,
            .isolate_level = 0,
            .bracket_cp = 0,
            .is_open_bracket = false,
        });
    }
}

fn estimateRunCount(classes: []const BidiClass, codepoints: []const u21, len: u32) usize {
    var i: u32 = 0;
    var count: usize = 0;
    while (i < len) {
        const class = classes[i];
        const bcp = pairedBracketInfoForClass(class, codepoints[i]).cp;
        i += 1;
        count += 1;

        if (bcp != 0 or unicode.isIsolate(class) or requiresExplicitGranularity(class) or requiresWeakGranularity(class)) {
            continue;
        }

        while (i < len and
            classes[i] == class and
            pairedBracketInfoForClass(classes[i], codepoints[i]).cp == 0 and
            !unicode.isIsolate(classes[i]) and
            !requiresExplicitGranularity(classes[i]) and
            !requiresWeakGranularity(classes[i]))
        {
            i += 1;
        }
    }
    return count;
}

fn pairedBracketInfoForClass(class: BidiClass, cp: u21) BracketInfo {
    if (class != .other_neutrals) {
        return .{
            .cp = 0,
            .is_open = false,
        };
    }
    return pairedBracketInfo(cp);
}

fn pairedBracketInfo(cp: u21) BracketInfo {
    const normalized_cp = unicode.normalizeBidiBracketCp(cp);
    const bpb = unicode.pairedBracket(normalized_cp);
    return switch (bpb) {
        .open => |paired| .{
            .cp = unicode.normalizeBidiBracketCp(paired),
            .is_open = true,
        },
        .close => |paired| .{
            .cp = unicode.normalizeBidiBracketCp(paired),
            .is_open = false,
        },
        .none => .{
            .cp = 0,
            .is_open = false,
        },
    };
}

/// X1-X8: Process explicit embedding, override, and isolate codes.
fn resolveExplicit(
    runs: *ArrayList(Run),
    base_level: BidiLevel,
) !void {
    var stack: [max_depth + 2]StatusEntry = undefined;
    var stack_size: u8 = 0;
    var level = base_level;
    var override: Override = .none;
    var isolate_level: u8 = 0;
    var over_pushed: usize = 0;
    var isolate_overflow: usize = 0;
    var valid_isolate_count: usize = 0;
    for (runs.items, 0..) |*run, run_idx| {
        const class = run.class;
        switch (class) {
            // X2-X5: Explicit embeddings and overrides
            .right_to_left_embedding => {
                // X3: RLE
                if (over_pushed == 0 and isolate_overflow == 0) {
                    if (level_mod.nextOddLevel(level)) |new_level| {
                        stack[stack_size] = .{ .level = level, .override = override, .isolate = false, .isolate_level = isolate_level };
                        stack_size += 1;
                        level = new_level;
                        override = .none;
                    } else {
                        over_pushed += 1;
                    }
                } else if (isolate_overflow == 0) {
                    over_pushed += 1;
                }
                run.level = level;
                run.class = .boundary_neutral;
            },
            .left_to_right_embedding => {
                // X2: LRE
                if (over_pushed == 0 and isolate_overflow == 0) {
                    if (level_mod.nextEvenLevel(level)) |new_level| {
                        stack[stack_size] = .{ .level = level, .override = override, .isolate = false, .isolate_level = isolate_level };
                        stack_size += 1;
                        level = new_level;
                        override = .none;
                    } else {
                        over_pushed += 1;
                    }
                } else if (isolate_overflow == 0) {
                    over_pushed += 1;
                }
                run.level = level;
                run.class = .boundary_neutral;
            },
            .right_to_left_override => {
                // X4: RLO
                if (over_pushed == 0 and isolate_overflow == 0) {
                    if (level_mod.nextOddLevel(level)) |new_level| {
                        stack[stack_size] = .{ .level = level, .override = override, .isolate = false, .isolate_level = isolate_level };
                        stack_size += 1;
                        level = new_level;
                        override = .rtl;
                    } else {
                        over_pushed += 1;
                    }
                } else if (isolate_overflow == 0) {
                    over_pushed += 1;
                }
                run.level = level;
                run.class = .boundary_neutral;
            },
            .left_to_right_override => {
                // X5: LRO
                if (over_pushed == 0 and isolate_overflow == 0) {
                    if (level_mod.nextEvenLevel(level)) |new_level| {
                        stack[stack_size] = .{ .level = level, .override = override, .isolate = false, .isolate_level = isolate_level };
                        stack_size += 1;
                        level = new_level;
                        override = .ltr;
                    } else {
                        over_pushed += 1;
                    }
                } else if (isolate_overflow == 0) {
                    over_pushed += 1;
                }
                run.level = level;
                run.class = .boundary_neutral;
            },

            // X5a-X5c: Isolate initiators
            .right_to_left_isolate => {
                run.level = level;
                run.isolate_level = isolate_level;
                if (override == .rtl) run.class = .right_to_left else if (override == .ltr) run.class = .left_to_right;

                if (over_pushed == 0 and isolate_overflow == 0) {
                    if (level_mod.nextOddLevel(level)) |new_level| {
                        valid_isolate_count += 1;
                        stack[stack_size] = .{ .level = level, .override = override, .isolate = true, .isolate_level = isolate_level };
                        stack_size += 1;
                        level = new_level;
                        override = .none;
                        isolate_level += 1;
                    } else {
                        isolate_overflow += 1;
                    }
                } else {
                    isolate_overflow += 1;
                }
            },
            .left_to_right_isolate => {
                run.level = level;
                run.isolate_level = isolate_level;
                if (override == .rtl) run.class = .right_to_left else if (override == .ltr) run.class = .left_to_right;

                if (over_pushed == 0 and isolate_overflow == 0) {
                    if (level_mod.nextEvenLevel(level)) |new_level| {
                        valid_isolate_count += 1;
                        stack[stack_size] = .{ .level = level, .override = override, .isolate = true, .isolate_level = isolate_level };
                        stack_size += 1;
                        level = new_level;
                        override = .none;
                        isolate_level += 1;
                    } else {
                        isolate_overflow += 1;
                    }
                } else {
                    isolate_overflow += 1;
                }
            },
            .first_strong_isolate => {
                run.level = level;
                run.isolate_level = isolate_level;
                if (override == .rtl) run.class = .right_to_left else if (override == .ltr) run.class = .left_to_right;

                // FSI: look ahead to determine direction, then act as LRI or RLI
                const fsi_dir = findFsiDirection(runs.items, run_idx);
                const new_level_opt = if (fsi_dir == .rtl) level_mod.nextOddLevel(level) else level_mod.nextEvenLevel(level);

                if (over_pushed == 0 and isolate_overflow == 0) {
                    if (new_level_opt) |new_level| {
                        valid_isolate_count += 1;
                        stack[stack_size] = .{ .level = level, .override = override, .isolate = true, .isolate_level = isolate_level };
                        stack_size += 1;
                        level = new_level;
                        override = .none;
                        isolate_level += 1;
                    } else {
                        isolate_overflow += 1;
                    }
                } else {
                    isolate_overflow += 1;
                }
            },

            // X6a: PDI
            .pop_directional_isolate => {
                if (isolate_overflow > 0) {
                    isolate_overflow -= 1;
                } else if (valid_isolate_count > 0) {
                    over_pushed = 0;
                    // Pop until we find an isolate entry
                    while (stack_size > 0) {
                        stack_size -= 1;
                        if (stack[stack_size].isolate) {
                            level = stack[stack_size].level;
                            override = stack[stack_size].override;
                            isolate_level = stack[stack_size].isolate_level;
                            break;
                        }
                    }
                    valid_isolate_count -= 1;
                }
                run.level = level;
                run.isolate_level = isolate_level;
                if (override == .rtl) run.class = .right_to_left else if (override == .ltr) run.class = .left_to_right;
            },

            // X7: PDF
            .pop_directional_format => {
                if (over_pushed > 0) {
                    over_pushed -= 1;
                } else if (stack_size > 0 and !stack[stack_size - 1].isolate) {
                    stack_size -= 1;
                    level = stack[stack_size].level;
                    override = stack[stack_size].override;
                }
                run.level = level;
                run.class = .boundary_neutral;
            },

            .boundary_neutral => {
                run.level = level;
            },

            .paragraph_separator => {
                run.level = base_level;
                run.isolate_level = 0;
                level = base_level;
                override = .none;
                isolate_level = 0;
                over_pushed = 0;
                isolate_overflow = 0;
                valid_isolate_count = 0;
                stack_size = 0;
            },

            // X6: All other characters
            else => {
                run.level = level;
                run.isolate_level = isolate_level;
                if (override == .rtl) {
                    run.class = .right_to_left;
                } else if (override == .ltr) {
                    run.class = .left_to_right;
                }
            },
        }
    }
}

/// P2/P3 for FSI: find the direction of the text following an FSI until its matching PDI.
fn findFsiDirection(runs: []const Run, run_idx: usize) level_mod.Direction {
    var depth: u32 = 1;
    var i = run_idx + 1;
    while (i < runs.len) : (i += 1) {
        const class = runs[i].class;
        if (unicode.isIsolateInitiator(class)) {
            depth += 1;
        } else if (class == .pop_directional_isolate) {
            depth -= 1;
            if (depth == 0) break;
        } else if (depth == 1 and unicode.isStrong(class)) {
            return if (unicode.isRtlStrong(class)) .rtl else .ltr;
        }
    }
    return .ltr;
}

fn fillLevelsFromRuns(runs: []const Run, levels: []BidiLevel) void {
    for (runs) |run| {
        for (run.pos..run.pos + run.len) |i| {
            levels[i] = run.level;
        }
    }
}

fn computeLevelRuns(allocator: Allocator, runs: []const Run) ![]LevelRun {
    if (runs.len == 0) return allocator.alloc(LevelRun, 0);

    var count: usize = 1;
    var current_level = runs[0].level;
    var i: usize = 1;
    while (i < runs.len) : (i += 1) {
        const run = runs[i];
        if (!unicode.isRemovedByX9(run.class) and run.level != current_level) {
            count += 1;
            current_level = run.level;
        }
    }

    const out = try allocator.alloc(LevelRun, count);
    var out_idx: usize = 0;
    var current_start: usize = 0;
    current_level = runs[0].level;
    i = 1;
    while (i < runs.len) : (i += 1) {
        const run = runs[i];
        if (!unicode.isRemovedByX9(run.class) and run.level != current_level) {
            out[out_idx] = .{
                .start = current_start,
                .end = i,
            };
            out_idx += 1;
            current_start = i;
            current_level = run.level;
        }
    }
    out[out_idx] = .{
        .start = current_start,
        .end = runs.len,
    };
    return out;
}

fn computeLevelRunsScratch(
    allocator: Allocator,
    scratch: *EmbeddingScratch,
    runs: []const Run,
) ![]const LevelRun {
    scratch.level_runs.clearRetainingCapacity();
    if (runs.len == 0) return scratch.level_runs.items;

    var count: usize = 1;
    var current_level = runs[0].level;
    var i: usize = 1;
    while (i < runs.len) : (i += 1) {
        const run = runs[i];
        if (!unicode.isRemovedByX9(run.class) and run.level != current_level) {
            count += 1;
            current_level = run.level;
        }
    }

    try scratch.level_runs.ensureTotalCapacity(allocator, count);
    scratch.level_runs.items.len = count;
    const out = scratch.level_runs.items;

    var out_idx: usize = 0;
    var current_start: usize = 0;
    current_level = runs[0].level;
    i = 1;
    while (i < runs.len) : (i += 1) {
        const run = runs[i];
        if (!unicode.isRemovedByX9(run.class) and run.level != current_level) {
            out[out_idx] = .{
                .start = current_start,
                .end = i,
            };
            out_idx += 1;
            current_start = i;
            current_level = run.level;
        }
    }
    out[out_idx] = .{
        .start = current_start,
        .end = runs.len,
    };
    return out;
}

fn computeIsolatingRunSequencesNoIsolatesScratch(
    allocator: Allocator,
    scratch: *EmbeddingScratch,
    runs: []const Run,
    level_runs: []const LevelRun,
    base_level: BidiLevel,
) ![]const IsolatingRunSequence {
    try scratch.sequences.ensureTotalCapacity(allocator, level_runs.len);
    scratch.sequences.items.len = level_runs.len;

    var total_run_indices: usize = 0;
    for (level_runs) |range| {
        total_run_indices += range.end - range.start;
    }

    try scratch.run_indices_pool.ensureTotalCapacity(allocator, total_run_indices);
    scratch.run_indices_pool.items.len = total_run_indices;

    var pool_offset: usize = 0;
    for (level_runs, 0..) |range, i| {
        const start = pool_offset;
        for (range.start..range.end) |run_idx| {
            scratch.run_indices_pool.items[pool_offset] = @intCast(run_idx);
            pool_offset += 1;
        }
        const run_indices = scratch.run_indices_pool.items[start..pool_offset];
        const se = computeSequenceSosEos(runs, run_indices, base_level);
        scratch.sequences.items[i] = .{
            .run_indices = run_indices,
            .sos = se.sos,
            .eos = se.eos,
        };
    }

    return scratch.sequences.items;
}

fn computeIsolatingRunSequencesScratch(
    allocator: Allocator,
    scratch: *EmbeddingScratch,
    runs: []const Run,
    level_runs: []const LevelRun,
    base_level: BidiLevel,
) ![]const IsolatingRunSequence {
    scratch.sequences.clearRetainingCapacity();
    scratch.run_indices_pool.clearRetainingCapacity();
    scratch.irs_stack.clearRetainingCapacity();
    scratch.irs_finished.clearRetainingCapacity();
    scratch.irs_seq_meta.clearRetainingCapacity();
    scratch.irs_seq_nodes.clearRetainingCapacity();

    if (level_runs.len == 0) {
        return scratch.sequences.items;
    }

    try scratch.irs_stack.ensureTotalCapacity(allocator, level_runs.len + 1);
    try scratch.irs_finished.ensureTotalCapacity(allocator, level_runs.len);
    try scratch.irs_seq_meta.ensureTotalCapacity(allocator, level_runs.len + 1);
    try scratch.irs_seq_nodes.ensureTotalCapacity(allocator, level_runs.len);

    try scratch.irs_seq_meta.append(allocator, .{
        .head = -1,
        .tail = -1,
        .has_items = false,
    });
    try scratch.irs_stack.append(allocator, 0);

    for (level_runs, 0..) |level_run, level_run_idx| {
        const start_class = runs[level_run.start].class;
        const end_class = blk: {
            var i = level_run.end;
            while (i > level_run.start) {
                i -= 1;
                if (!unicode.isRemovedByX9(runs[i].class)) break :blk runs[i].class;
            }
            break :blk start_class;
        };

        const seq_idx: u32 = if (start_class == .pop_directional_isolate and scratch.irs_stack.items.len > 1) blk: {
            const top = scratch.irs_stack.items.len - 1;
            const idx = scratch.irs_stack.items[top];
            scratch.irs_stack.items.len = top;
            break :blk idx;
        } else blk: {
            const idx: u32 = @intCast(scratch.irs_seq_meta.items.len);
            try scratch.irs_seq_meta.append(allocator, .{
                .head = -1,
                .tail = -1,
                .has_items = false,
            });
            break :blk idx;
        };

        const node_idx: i32 = @intCast(scratch.irs_seq_nodes.items.len);
        try scratch.irs_seq_nodes.append(allocator, .{
            .level_run_idx = @intCast(level_run_idx),
            .next = -1,
        });

        var seq_meta = &scratch.irs_seq_meta.items[seq_idx];
        if (!seq_meta.has_items) {
            seq_meta.head = node_idx;
            seq_meta.tail = node_idx;
            seq_meta.has_items = true;
        } else {
            const tail_idx: usize = @intCast(seq_meta.tail);
            scratch.irs_seq_nodes.items[tail_idx].next = node_idx;
            seq_meta.tail = node_idx;
        }

        if (unicode.isIsolateInitiator(end_class)) {
            try scratch.irs_stack.append(allocator, seq_idx);
        } else {
            try scratch.irs_finished.append(allocator, seq_idx);
        }
    }

    while (scratch.irs_stack.items.len > 0) {
        const top = scratch.irs_stack.items.len - 1;
        const seq_idx = scratch.irs_stack.items[top];
        scratch.irs_stack.items.len = top;
        if (!scratch.irs_seq_meta.items[seq_idx].has_items) continue;
        try scratch.irs_finished.append(allocator, seq_idx);
    }

    try scratch.sequences.ensureTotalCapacity(allocator, scratch.irs_finished.items.len);
    scratch.sequences.items.len = scratch.irs_finished.items.len;

    var total_run_indices: usize = 0;
    for (scratch.irs_finished.items) |seq_idx| {
        var node_idx = scratch.irs_seq_meta.items[seq_idx].head;
        while (node_idx >= 0) {
            const node = scratch.irs_seq_nodes.items[@intCast(node_idx)];
            const level_run = level_runs[node.level_run_idx];
            total_run_indices += level_run.end - level_run.start;
            node_idx = node.next;
        }
    }

    try scratch.run_indices_pool.ensureTotalCapacity(allocator, total_run_indices);
    scratch.run_indices_pool.items.len = total_run_indices;

    var pool_offset: usize = 0;
    for (scratch.irs_finished.items, 0..) |seq_idx, seq_out_idx| {
        const start = pool_offset;
        var node_idx = scratch.irs_seq_meta.items[seq_idx].head;
        while (node_idx >= 0) {
            const node = scratch.irs_seq_nodes.items[@intCast(node_idx)];
            const level_run = level_runs[node.level_run_idx];
            for (level_run.start..level_run.end) |run_idx| {
                scratch.run_indices_pool.items[pool_offset] = @intCast(run_idx);
                pool_offset += 1;
            }
            node_idx = node.next;
        }

        const run_indices = scratch.run_indices_pool.items[start..pool_offset];
        const se = computeSequenceSosEos(runs, run_indices, base_level);
        scratch.sequences.items[seq_out_idx] = .{
            .run_indices = run_indices,
            .sos = se.sos,
            .eos = se.eos,
        };
    }

    return scratch.sequences.items;
}

fn classFromLevel(level: BidiLevel) BidiClass {
    return if (level_mod.isRtl(level)) .right_to_left else .left_to_right;
}

fn runIndexToUsize(run_idx: u32) usize {
    return @intCast(run_idx);
}

fn typeAnEnAsRtl(class: BidiClass) BidiClass {
    return switch (class) {
        .european_number, .arabic_number => .right_to_left,
        else => class,
    };
}

fn isStrongForN0(class: BidiClass) bool {
    return class == .left_to_right or class == .right_to_left;
}

fn resolveEmptyParDirection(par_dir: *ParDirection) ParDirection {
    const resolved: ParDirection = switch (par_dir.*) {
        .auto_ltr => .ltr,
        .auto_rtl => .rtl,
        else => par_dir.*,
    };
    par_dir.* = resolved;
    return resolved;
}

fn implicitLevelForStrong(level: BidiLevel, strong_class: BidiClass) BidiLevel {
    const strong_is_rtl = strong_class == .right_to_left;
    return level + @as(BidiLevel, @intFromBool(level_mod.isRtl(level) != strong_is_rtl));
}

fn firstNonRemovedRun(runs: []const Run, seq: []const u32) ?usize {
    for (seq) |run_idx| {
        const run_idx_usize = runIndexToUsize(run_idx);
        if (!unicode.isRemovedByX9(runs[run_idx_usize].class)) return run_idx_usize;
    }
    return null;
}

fn lastNonRemovedRun(runs: []const Run, seq: []const u32) ?usize {
    var i = seq.len;
    while (i > 0) {
        i -= 1;
        const run_idx = runIndexToUsize(seq[i]);
        if (!unicode.isRemovedByX9(runs[run_idx].class)) return run_idx;
    }
    return null;
}

fn computeSequenceSosEos(runs: []const Run, seq: []const u32, base_level: BidiLevel) struct { sos: BidiClass, eos: BidiClass } {
    const first_non_removed = firstNonRemovedRun(runs, seq) orelse runIndexToUsize(seq[0]);
    const last_non_removed = lastNonRemovedRun(runs, seq) orelse runIndexToUsize(seq[seq.len - 1]);

    const seq_level = runs[first_non_removed].level;
    const end_level = runs[last_non_removed].level;

    const start_run_idx = runIndexToUsize(seq[0]);
    const pred_level: BidiLevel = blk: {
        var i = start_run_idx;
        while (i > 0) {
            i -= 1;
            if (!unicode.isRemovedByX9(runs[i].class)) break :blk runs[i].level;
        }
        break :blk base_level;
    };

    const succ_level: BidiLevel = blk: {
        const last_class = runs[last_non_removed].class;
        if (unicode.isIsolateInitiator(last_class)) break :blk base_level;

        var i = runIndexToUsize(seq[seq.len - 1]) + 1;
        while (i < runs.len) : (i += 1) {
            if (!unicode.isRemovedByX9(runs[i].class)) break :blk runs[i].level;
        }
        break :blk base_level;
    };

    return .{
        .sos = classFromLevel(@max(seq_level, pred_level)),
        .eos = classFromLevel(@max(end_level, succ_level)),
    };
}

fn deinitIsolatingRunSequences(allocator: Allocator, sequences_data: IsolatingRunSequences) void {
    allocator.free(sequences_data.run_indices_pool);
    allocator.free(sequences_data.sequences);
}

fn runsHaveIsolates(runs: []const Run) bool {
    for (runs) |run| {
        if (unicode.isIsolate(run.class)) return true;
    }
    return false;
}

fn computeIsolatingRunSequences(
    allocator: Allocator,
    runs: []const Run,
    level_runs: []const LevelRun,
    base_level: BidiLevel,
) !IsolatingRunSequences {
    const SequenceBuilder = struct {
        ranges: ArrayList(LevelRun) = .empty,

        fn deinit(self: *@This(), a: Allocator) void {
            self.ranges.deinit(a);
        }
    };

    if (level_runs.len == 0) {
        const sequences = try allocator.alloc(IsolatingRunSequence, 0);
        errdefer allocator.free(sequences);
        const run_indices_pool = try allocator.alloc(u32, 0);
        return .{
            .sequences = sequences,
            .run_indices_pool = run_indices_pool,
        };
    }

    const has_isolates = runsHaveIsolates(runs);

    // Common fast path: no isolate controls in input.
    // Avoid temporary per-sequence builders and directly materialize
    // flattened IRS run-index slices.
    if (!has_isolates) {
        const sequences = try allocator.alloc(IsolatingRunSequence, level_runs.len);
        errdefer allocator.free(sequences);

        var total_run_indices: usize = 0;
        for (level_runs) |range| {
            total_run_indices += range.end - range.start;
        }

        const run_indices_pool = try allocator.alloc(u32, total_run_indices);
        errdefer allocator.free(run_indices_pool);

        var pool_offset: usize = 0;
        for (level_runs, 0..) |range, i| {
            const start = pool_offset;
            for (range.start..range.end) |run_idx| {
                run_indices_pool[pool_offset] = @intCast(run_idx);
                pool_offset += 1;
            }
            const run_indices = run_indices_pool[start..pool_offset];
            const se = computeSequenceSosEos(runs, run_indices, base_level);
            sequences[i] = .{
                .run_indices = run_indices,
                .sos = se.sos,
                .eos = se.eos,
            };
        }

        return .{
            .sequences = sequences,
            .run_indices_pool = run_indices_pool,
        };
    }

    var finished = ArrayList(SequenceBuilder){};
    defer {
        for (finished.items) |*seq| seq.deinit(allocator);
        finished.deinit(allocator);
    }
    try finished.ensureTotalCapacity(allocator, level_runs.len);

    if (has_isolates) {
        var stack = ArrayList(SequenceBuilder){};
        defer {
            for (stack.items) |*seq| seq.deinit(allocator);
            stack.deinit(allocator);
        }

        try stack.ensureTotalCapacity(allocator, level_runs.len + 1);
        try stack.append(allocator, .{});

        for (level_runs) |level_run| {
            const start_class = runs[level_run.start].class;
            const end_class = blk: {
                var i = level_run.end;
                while (i > level_run.start) {
                    i -= 1;
                    if (!unicode.isRemovedByX9(runs[i].class)) break :blk runs[i].class;
                }
                break :blk start_class;
            };

            var sequence: SequenceBuilder = if (start_class == .pop_directional_isolate and stack.items.len > 1) blk: {
                const idx = stack.items.len - 1;
                const seq = stack.items[idx];
                stack.items.len = idx;
                break :blk seq;
            } else .{};
            sequence.ranges.append(allocator, level_run) catch |err| {
                sequence.deinit(allocator);
                return err;
            };

            if (unicode.isIsolateInitiator(end_class)) {
                stack.appendAssumeCapacity(sequence);
            } else {
                try finished.append(allocator, sequence);
            }
        }

        while (stack.items.len > 0) {
            const idx = stack.items.len - 1;
            var sequence = stack.items[idx];
            stack.items.len = idx;
            if (sequence.ranges.items.len == 0) {
                sequence.deinit(allocator);
                continue;
            }
            finished.append(allocator, sequence) catch |err| {
                sequence.deinit(allocator);
                return err;
            };
        }
    } else {
        for (level_runs) |level_run| {
            var sequence = SequenceBuilder{};
            try sequence.ranges.append(allocator, level_run);
            try finished.append(allocator, sequence);
        }
    }

    const sequences = try allocator.alloc(IsolatingRunSequence, finished.items.len);
    errdefer allocator.free(sequences);
    var total_run_indices: usize = 0;
    for (finished.items) |seq_builder| {
        for (seq_builder.ranges.items) |range| {
            total_run_indices += range.end - range.start;
        }
    }

    const run_indices_pool = try allocator.alloc(u32, total_run_indices);
    errdefer allocator.free(run_indices_pool);

    var pool_offset: usize = 0;
    for (finished.items, 0..) |seq_builder, i| {
        const start = pool_offset;
        for (seq_builder.ranges.items) |range| {
            for (range.start..range.end) |run_idx| {
                run_indices_pool[pool_offset] = @intCast(run_idx);
                pool_offset += 1;
            }
        }
        const run_indices = run_indices_pool[start..pool_offset];
        const se = computeSequenceSosEos(runs, run_indices, base_level);
        sequences[i] = .{
            .run_indices = run_indices,
            .sos = se.sos,
            .eos = se.eos,
        };
    }

    return .{
        .sequences = sequences,
        .run_indices_pool = run_indices_pool,
    };
}

fn findNextNonBnInSequence(
    runs: []const Run,
    seq: IsolatingRunSequence,
    start_pos: usize,
    fallback: BidiClass,
) BidiClass {
    var pos = start_pos;
    while (pos < seq.run_indices.len) : (pos += 1) {
        const run_idx = runIndexToUsize(seq.run_indices[pos]);
        const class = runs[run_idx].class;
        if (class != .boundary_neutral) return class;
    }
    return fallback;
}

fn resolveWeakWithEtBuffer(
    allocator: Allocator,
    et_run_indices: *ArrayList(u32),
    runs: []Run,
    sequences: []const IsolatingRunSequence,
) !void {
    for (sequences) |seq| {
        try et_run_indices.ensureTotalCapacity(allocator, seq.run_indices.len);
        et_run_indices.clearRetainingCapacity();

        var prev_class_before_w4 = seq.sos;
        var prev_class_before_w5 = seq.sos;
        var prev_class_before_w1 = seq.sos;
        var last_strong_w2: [max_depth + 2]BidiClass = undefined;
        @memset(last_strong_w2[0..], seq.sos);

        for (seq.run_indices, 0..) |run_idx, pos| {
            const run_idx_usize = runIndexToUsize(run_idx);
            var class = runs[run_idx_usize].class;
            const iso_level = @min(@as(usize, runs[run_idx_usize].isolate_level), last_strong_w2.len - 1);
            if (class == .boundary_neutral) {
                continue;
            }

            var w2_class = class;

            // W1
            if (class == .nonspacing_mark) {
                class = switch (prev_class_before_w1) {
                    .left_to_right_isolate,
                    .right_to_left_isolate,
                    .first_strong_isolate,
                    .pop_directional_isolate,
                    => .other_neutrals,
                    else => prev_class_before_w1,
                };
                runs[run_idx_usize].class = class;
                w2_class = class;
            }
            prev_class_before_w1 = class;

            // W2 / W3
            if (class == .european_number and last_strong_w2[iso_level] == .right_to_left_arabic) {
                class = .arabic_number;
            } else if (class == .right_to_left_arabic) {
                class = .right_to_left;
            }
            runs[run_idx_usize].class = class;

            switch (w2_class) {
                .left_to_right,
                .right_to_left,
                .right_to_left_arabic,
                => last_strong_w2[iso_level] = w2_class,
                else => {},
            }

            const class_before_w456 = class;

            // W4/W5/W6 (separators)
            switch (class) {
                .european_number => {
                    for (et_run_indices.items) |idx| {
                        runs[runIndexToUsize(idx)].class = .european_number;
                    }
                    et_run_indices.clearRetainingCapacity();
                },
                .european_number_separator, .common_number_separator => {
                    var next_class = findNextNonBnInSequence(runs, seq, pos + 1, seq.sos);
                    if (next_class == .european_number and last_strong_w2[iso_level] == .right_to_left_arabic) {
                        next_class = .arabic_number;
                    }

                    class = blk: {
                        if (prev_class_before_w4 == next_class) {
                            if (next_class == .european_number) break :blk .european_number;
                            if (next_class == .arabic_number and class == .common_number_separator) break :blk .arabic_number;
                        }
                        break :blk .other_neutrals;
                    };
                    runs[run_idx_usize].class = class;
                },
                .european_number_terminator => {
                    if (prev_class_before_w5 == .european_number) {
                        runs[run_idx_usize].class = .european_number;
                    } else {
                        et_run_indices.appendAssumeCapacity(run_idx);
                    }
                },
                else => {},
            }

            prev_class_before_w5 = runs[run_idx_usize].class;

            // W6 (terminators)
            if (prev_class_before_w5 != .european_number_terminator) {
                for (et_run_indices.items) |idx| {
                    runs[runIndexToUsize(idx)].class = .other_neutrals;
                }
                et_run_indices.clearRetainingCapacity();
            }

            prev_class_before_w4 = class_before_w456;
        }

        for (et_run_indices.items) |idx| {
            runs[runIndexToUsize(idx)].class = .other_neutrals;
        }
        et_run_indices.clearRetainingCapacity();

        // W7
        var last_strong_w7: [max_depth + 2]BidiClass = undefined;
        @memset(last_strong_w7[0..], seq.sos);
        var prev_non_bn_run_idx: ?u32 = null;
        for (seq.run_indices) |run_idx| {
            const run_idx_usize = runIndexToUsize(run_idx);
            if (runs[run_idx_usize].class == .boundary_neutral) continue;
            const iso_level = @min(@as(usize, runs[run_idx_usize].isolate_level), last_strong_w7.len - 1);

            const prev_type = if (prev_non_bn_run_idx) |prev_idx| blk: {
                const prev_idx_usize = runIndexToUsize(prev_idx);
                if (runs[prev_idx_usize].level == runs[run_idx_usize].level) {
                    break :blk runs[prev_idx_usize].class;
                }
                break :blk classFromLevel(@max(runs[prev_idx_usize].level, runs[run_idx_usize].level));
            } else seq.sos;

            if (prev_type == .left_to_right or prev_type == .right_to_left) {
                last_strong_w7[iso_level] = prev_type;
            }

            if (runs[run_idx_usize].class == .european_number and last_strong_w7[iso_level] == .left_to_right) {
                runs[run_idx_usize].class = .left_to_right;
            }

            prev_non_bn_run_idx = run_idx;
        }
    }
}

fn resolveWeak(allocator: Allocator, runs: []Run, sequences: []const IsolatingRunSequence) !void {
    var et_run_indices = ArrayList(u32){};
    defer et_run_indices.deinit(allocator);
    try resolveWeakWithEtBuffer(allocator, &et_run_indices, runs, sequences);
}

fn isNi(class: BidiClass) bool {
    return switch (class) {
        .paragraph_separator,
        .segment_separator,
        .whitespace,
        .other_neutrals,
        .first_strong_isolate,
        .left_to_right_isolate,
        .right_to_left_isolate,
        .pop_directional_isolate,
        => true,
        else => false,
    };
}

const OpenEntry = struct {
    run_idx: u32,
    seq_pos: u32,
    paired_close: u21,
};

fn collectBracketPairsPerSequenceInto(
    allocator: Allocator,
    pairs: *ArrayList(BracketPair),
    codepoints: []const u21,
    runs: []const Run,
    sequences: []const IsolatingRunSequence,
) !void {
    pairs.clearRetainingCapacity();
    if (sequences.len == 0) return;

    var bracket_candidate_count: usize = 0;
    for (runs) |run| {
        if (run.bracket_cp != 0 and run.class == .other_neutrals) {
            bracket_candidate_count += 1;
        }
    }
    try pairs.ensureTotalCapacity(allocator, bracket_candidate_count / 2);

    for (sequences, 0..) |seq, seq_idx| {
        const seq_pairs_start = pairs.items.len;
        var overflowed = false;
        var stack: [63]OpenEntry = undefined;
        var stack_size: u8 = 0;

        // UAX #9 BD16: bracket pairing is evaluated per IRS using a stack.
        for (seq.run_indices, 0..) |run_idx, seq_pos| {
            const run_idx_usize = runIndexToUsize(run_idx);
            const run = runs[run_idx_usize];
            if (unicode.isRemovedByX9(run.class)) continue;

            if (run.bracket_cp != 0 and run.class == .other_neutrals) {
                if (run.is_open_bracket) {
                    if (stack_size >= stack.len) {
                        overflowed = true;
                        break;
                    }

                    stack[stack_size] = .{
                        .run_idx = @intCast(run_idx),
                        .seq_pos = @intCast(seq_pos),
                        .paired_close = run.bracket_cp,
                    };
                    stack_size += 1;
                } else {
                    var stack_idx = stack_size;
                    while (stack_idx > 0) {
                        stack_idx -= 1;
                        const entry = stack[stack_idx];
                        const run_cp = codepoints[@as(usize, run.pos)];
                        if (entry.paired_close == unicode.normalizeBidiBracketCp(run_cp)) {
                            try pairs.append(allocator, .{
                                .open_run_idx = @intCast(entry.run_idx),
                                .close_run_idx = run_idx,
                                .seq_idx = @intCast(seq_idx),
                                .open_seq_pos = entry.seq_pos,
                                .close_seq_pos = @intCast(seq_pos),
                            });
                            stack_size = stack_idx;
                            break;
                        }
                    }
                }
            }
        }

        // UAX #9 BD16: if overflow occurs, discard bracket pairs for that IRS.
        if (overflowed) pairs.items.len = seq_pairs_start;
    }

    std.mem.sort(BracketPair, pairs.items, {}, struct {
        fn lessThan(_: void, a: BracketPair, b: BracketPair) bool {
            return a.open_run_idx < b.open_run_idx;
        }
    }.lessThan);
}

fn collectBracketPairsPerSequence(
    allocator: Allocator,
    codepoints: []const u21,
    runs: []const Run,
    sequences: []const IsolatingRunSequence,
) ![]BracketPair {
    var pairs = ArrayList(BracketPair){};
    errdefer pairs.deinit(allocator);
    try collectBracketPairsPerSequenceInto(allocator, &pairs, codepoints, runs, sequences);
    return try pairs.toOwnedSlice(allocator);
}

fn applyBracketPairsN0(runs: []Run, sequences: []const IsolatingRunSequence, pairs: []const BracketPair) void {
    for (pairs) |pair| {
        const open_run_idx = runIndexToUsize(pair.open_run_idx);
        const close_run_idx = runIndexToUsize(pair.close_run_idx);
        const seq = sequences[@intCast(pair.seq_idx)];
        const open_seq_pos: usize = @intCast(pair.open_seq_pos);
        const close_seq_pos: usize = @intCast(pair.close_seq_pos);
        const embedding_level = runs[open_run_idx].level;
        const pair_iso_level = runs[open_run_idx].isolate_level;

        var class_to_set: ?BidiClass = null;

        // N0b: strong type inside pair matching the embedding level.
        var seq_pos = open_seq_pos + 1;
        while (seq_pos < close_seq_pos) : (seq_pos += 1) {
            const run_idx = runIndexToUsize(seq.run_indices[seq_pos]);
            const strong_t = typeAnEnAsRtl(runs[run_idx].class);
            if (!isStrongForN0(strong_t)) continue;

            const this_level = implicitLevelForStrong(runs[run_idx].level, strong_t);
            if (this_level == embedding_level) {
                class_to_set = classFromLevel(embedding_level);
                break;
            }
        }

        // N0c: opposite-direction strong inside the pair, context from preceding strong.
        if (class_to_set == null) {
            var prec_strong_level = embedding_level;

            var back_seq_pos = open_seq_pos;
            while (back_seq_pos > 0) {
                back_seq_pos -= 1;
                const back_run_idx = runIndexToUsize(seq.run_indices[back_seq_pos]);
                const strong_t = typeAnEnAsRtl(runs[back_run_idx].class);
                if (!isStrongForN0(strong_t)) continue;

                prec_strong_level = implicitLevelForStrong(runs[back_run_idx].level, strong_t);
                break;
            }

            seq_pos = open_seq_pos + 1;
            while (seq_pos < close_seq_pos) : (seq_pos += 1) {
                const run_idx = runIndexToUsize(seq.run_indices[seq_pos]);
                const strong_t = typeAnEnAsRtl(runs[run_idx].class);
                if (!isStrongForN0(strong_t)) continue;

                class_to_set = classFromLevel(prec_strong_level);
                break;
            }
        }

        if (class_to_set) |new_class| {
            runs[open_run_idx].class = new_class;
            runs[close_run_idx].class = new_class;

            var run_idx = open_run_idx + 1;
            while (run_idx < runs.len) : (run_idx += 1) {
                if (runs[run_idx].isolate_level != pair_iso_level) break;
                if (runs[run_idx].class == .boundary_neutral) continue;
                if (runs[run_idx].orig_class == .nonspacing_mark) {
                    runs[run_idx].class = new_class;
                } else break;
            }

            run_idx = close_run_idx + 1;
            while (run_idx < runs.len) : (run_idx += 1) {
                if (runs[run_idx].isolate_level != pair_iso_level) break;
                if (runs[run_idx].class == .boundary_neutral) continue;
                if (runs[run_idx].orig_class == .nonspacing_mark) {
                    runs[run_idx].class = new_class;
                } else break;
            }
        }
    }
}

fn resolveNeutralsN1N2(runs: []Run, sequences: []const IsolatingRunSequence) void {
    for (sequences) |seq| {
        // N1-N2
        var run_pos: usize = 0;
        while (run_pos < seq.run_indices.len) {
            const idx = runIndexToUsize(seq.run_indices[run_pos]);
            const class = runs[idx].class;

            if (class == .boundary_neutral) {
                run_pos += 1;
                continue;
            }

            if (isNi(class)) {
                const ni_start = run_pos;
                const ni_level = runs[runIndexToUsize(seq.run_indices[ni_start])].level;
                const ni_e = classFromLevel(ni_level);
                run_pos += 1;
                while (run_pos < seq.run_indices.len) : (run_pos += 1) {
                    const c = runs[runIndexToUsize(seq.run_indices[run_pos])].class;
                    if (!(isNi(c) or c == .boundary_neutral)) break;
                }

                const prev_type: BidiClass = if (ni_start > 0) blk: {
                    var p = ni_start;
                    while (p > 0) {
                        p -= 1;
                        const prev_idx = runIndexToUsize(seq.run_indices[p]);
                        if (runs[prev_idx].class == .boundary_neutral) continue;
                        if (runs[prev_idx].level == ni_level) {
                            break :blk typeAnEnAsRtl(runs[prev_idx].class);
                        }
                        break :blk classFromLevel(@max(runs[prev_idx].level, ni_level));
                    }
                    break :blk seq.sos;
                } else seq.sos;

                const next_type: BidiClass = blk: {
                    var p = run_pos;
                    while (p < seq.run_indices.len) : (p += 1) {
                        const next_idx = runIndexToUsize(seq.run_indices[p]);
                        if (runs[next_idx].class == .boundary_neutral) continue;
                        if (runs[next_idx].level == ni_level) {
                            break :blk typeAnEnAsRtl(runs[next_idx].class);
                        }
                        break :blk classFromLevel(@max(runs[next_idx].level, ni_level));
                    }
                    break :blk seq.eos;
                };

                const new_class: BidiClass = if (prev_type == next_type) prev_type else ni_e;

                for (ni_start..run_pos) |p| {
                    const ni_idx = runIndexToUsize(seq.run_indices[p]);
                    if (runs[ni_idx].class != .boundary_neutral) {
                        runs[ni_idx].class = new_class;
                    }
                }

                if (run_pos >= seq.run_indices.len) break;
            }
            run_pos += 1;
        }
    }
}

fn resolveBracketsAndNeutrals(
    allocator: Allocator,
    codepoints: []const u21,
    runs: []Run,
    sequences: []const IsolatingRunSequence,
) !void {
    if (runs.len == 0) return;

    var has_bracket_candidates = false;
    for (runs) |run| {
        if (run.bracket_cp != 0 and run.class == .other_neutrals) {
            has_bracket_candidates = true;
            break;
        }
    }

    if (has_bracket_candidates) {
        const pairs = try collectBracketPairsPerSequence(allocator, codepoints, runs, sequences);
        defer allocator.free(pairs);
        applyBracketPairsN0(runs, sequences, pairs);
    }

    resolveNeutralsN1N2(runs, sequences);
}

fn resolveBracketsAndNeutralsScratch(
    allocator: Allocator,
    scratch: *EmbeddingScratch,
    codepoints: []const u21,
    runs: []Run,
    sequences: []const IsolatingRunSequence,
) !void {
    if (runs.len == 0) return;

    var has_bracket_candidates = false;
    for (runs) |run| {
        if (run.bracket_cp != 0 and run.class == .other_neutrals) {
            has_bracket_candidates = true;
            break;
        }
    }

    if (has_bracket_candidates) {
        try collectBracketPairsPerSequenceInto(
            allocator,
            &scratch.bracket_pairs,
            codepoints,
            runs,
            sequences,
        );
        applyBracketPairsN0(runs, sequences, scratch.bracket_pairs.items);
    }

    resolveNeutralsN1N2(runs, sequences);
}

/// I1-I2: Resolve implicit levels.
fn resolveImplicit(runs: []Run) void {
    for (runs) |*run| {
        if (unicode.isRemovedByX9(run.class) or run.class == .boundary_neutral) continue;

        if (level_mod.isEven(run.level)) {
            // I1: Even level
            switch (run.class) {
                .right_to_left => run.level += 1,
                .arabic_number, .european_number => run.level += 2,
                else => {},
            }
        } else {
            // I2: Odd level
            switch (run.class) {
                .left_to_right, .european_number, .arabic_number => run.level += 1,
                else => {},
            }
        }
    }
}

/// L1 (parts 1-3): Reset segment separators, paragraph separators,
/// and any whitespace/isolate formatting before them to paragraph level.
fn applyL1(levels: []BidiLevel, orig_classes: []const BidiClass, para_level: BidiLevel) void {
    if (levels.len == 0) return;

    // Reset separators and preceding WS/format/isolates.
    for (orig_classes, 0..) |class, i| {
        if (class != .paragraph_separator and class != .segment_separator) continue;

        levels[i] = para_level;
        var j = i;
        while (j > 0) {
            j -= 1;
            if (!shouldResetToParagraphLevel(orig_classes[j])) break;
            levels[j] = para_level;
        }
    }

    // Reset trailing WS/format/isolate types at the end of paragraph.
    var i = levels.len;
    while (i > 0) {
        i -= 1;
        if (!shouldResetToParagraphLevel(orig_classes[i])) break;
        levels[i] = para_level;
    }
}

fn shouldResetToParagraphLevel(class: BidiClass) bool {
    return class == .whitespace or unicode.isIsolate(class) or unicode.isRemovedByX9(class);
}

fn setRemovedLevelsFromPreceding(levels: []BidiLevel, orig_classes: []const BidiClass, para_level: BidiLevel) void {
    if (levels.len == 0) return;

    if (unicode.isRemovedByX9(orig_classes[0])) {
        levels[0] = para_level;
    }

    var i: usize = 1;
    while (i < levels.len) : (i += 1) {
        if (unicode.isRemovedByX9(orig_classes[i])) {
            levels[i] = levels[i - 1];
        }
    }
}

fn getParEmbeddingLevelsAllocProbe(allocator: Allocator) !void {
    const input = [_]u21{ 'a', 0x2067, '(', 0x05D0, ')', 0x2069, ' ', '[', '1', ']', 'b' };
    var dir: ParDirection = .auto_ltr;
    var result = try getParEmbeddingLevels(allocator, &input, &dir);
    defer result.deinit(allocator);
}

fn computeIsolatingRunSequencesPopProbe(allocator: Allocator) !void {
    const runs = [_]Run{
        .{
            .pos = 0,
            .len = 1,
            .class = .right_to_left_isolate,
            .orig_class = .right_to_left_isolate,
            .level = 1,
            .isolate_level = 0,
            .bracket_cp = 0,
            .is_open_bracket = false,
        },
        .{
            .pos = 1,
            .len = 1,
            .class = .pop_directional_isolate,
            .orig_class = .pop_directional_isolate,
            .level = 1,
            .isolate_level = 0,
            .bracket_cp = 0,
            .is_open_bracket = false,
        },
    };
    const level_runs = [_]LevelRun{
        .{ .start = 0, .end = 1 },
        .{ .start = 1, .end = 2 },
    };

    const sequences_data = try computeIsolatingRunSequences(allocator, &runs, &level_runs, 1);
    defer deinitIsolatingRunSequences(allocator, sequences_data);
}

test "allocation failure safety: getParEmbeddingLevels" {
    const testing = std.testing;
    try testing.checkAllAllocationFailures(testing.allocator, getParEmbeddingLevelsAllocProbe, .{});
}

test "allocation failure safety: computeIsolatingRunSequences pop path" {
    const testing = std.testing;
    try testing.checkAllAllocationFailures(testing.allocator, computeIsolatingRunSequencesPopProbe, .{});
}

test "regression: isolate stack capacity allows seed and first isolate sequence" {
    const testing = std.testing;
    const gpa = testing.allocator;

    const runs = [_]Run{
        .{
            .pos = 0,
            .len = 1,
            .class = .right_to_left_isolate,
            .orig_class = .right_to_left_isolate,
            .level = 1,
            .isolate_level = 0,
            .bracket_cp = 0,
            .is_open_bracket = false,
        },
    };
    const level_runs = [_]LevelRun{
        .{ .start = 0, .end = 1 },
    };

    const sequences_data = try computeIsolatingRunSequences(gpa, &runs, &level_runs, 1);
    defer deinitIsolatingRunSequences(gpa, sequences_data);

    try testing.expectEqual(@as(usize, 1), sequences_data.sequences.len);
    try testing.expectEqual(@as(usize, 1), sequences_data.sequences[0].run_indices.len);
    try testing.expectEqual(@as(usize, 0), sequences_data.sequences[0].run_indices[0]);
}

test "regression: explicit overflow counters handle long explicit runs" {
    const testing = std.testing;
    const gpa = testing.allocator;

    const repeats = 400;
    var input: [repeats + 1 + repeats + 1]u21 = undefined;

    for (0..repeats) |i| input[i] = 0x202A; // LRE
    input[repeats] = 'A';
    for (0..repeats) |i| input[repeats + 1 + i] = 0x202C; // PDF
    input[input.len - 1] = 'B';

    var dir: ParDirection = .ltr;
    var result = try getParEmbeddingLevels(gpa, &input, &dir);
    defer result.deinit(gpa);

    try testing.expectEqual(@as(BidiLevel, 0), result.levels[input.len - 1]);
}

test "regression: BD16 overflow keeps expected conformance behavior" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const reorder = @import("reorder.zig");

    const opens = 64;
    const closes = 64;
    var cps: [1 + opens + 1 + closes]u21 = undefined;
    cps[0] = 'a';
    for (0..opens) |i| cps[1 + i] = '(';
    cps[1 + opens] = 'b';
    for (0..closes) |i| cps[1 + opens + 1 + i] = ')';

    var dir: ParDirection = .rtl;
    var emb = try getParEmbeddingLevels(gpa, &cps, &dir);
    defer emb.deinit(gpa);

    for (0..(1 + opens + 1)) |i| {
        try testing.expectEqual(@as(BidiLevel, 2), emb.levels[i]);
    }
    for ((1 + opens + 1)..emb.levels.len) |i| {
        try testing.expectEqual(@as(BidiLevel, 1), emb.levels[i]);
    }

    var vis = try reorder.reorderLine(gpa, &cps, emb.levels, dir.toLevel());
    defer vis.deinit(gpa);

    for (0..closes) |i| {
        try testing.expectEqual(@as(u32, @intCast(cps.len - 1 - i)), vis.v_to_l[i]);
    }
    for (0..(1 + opens + 1)) |i| {
        try testing.expectEqual(@as(u32, @intCast(i)), vis.v_to_l[closes + i]);
    }
}

test "spec target: N0 does not pair across disjoint IRS at same isolate level" {
    const testing = std.testing;
    const gpa = testing.allocator;

    // Two disjoint IRS at isolate_level=1:
    //   IRS1: LRI "(" "A" PDI
    //   IRS2: LRI "C" ")" PDI
    // The open from IRS1 and close from IRS2 should not pair in a strict per-IRS N0 pass.
    const cps = [_]u21{
        0x2066, // LRI
        '(',
        'A',
        0x2069, // PDI
        'B',
        0x2066, // LRI
        'C',
        ')',
        0x2069, // PDI
    };

    const classes = try gpa.alloc(BidiClass, cps.len);
    defer gpa.free(classes);
    for (cps, 0..) |cp, i| classes[i] = unicode.bidiClass(cp);

    var runs = ArrayList(Run){};
    defer runs.deinit(gpa);
    try buildRuns(gpa, &runs, classes, &cps, @intCast(cps.len));
    try resolveExplicit(&runs, 0);
    for (runs.items) |*run| run.orig_class = run.class;

    const level_runs = try computeLevelRuns(gpa, runs.items);
    defer gpa.free(level_runs);
    const sequences_data = try computeIsolatingRunSequences(gpa, runs.items, level_runs, 0);
    defer deinitIsolatingRunSequences(gpa, sequences_data);
    try resolveWeak(gpa, runs.items, sequences_data.sequences);

    const pairs = try collectBracketPairsPerSequence(gpa, &cps, runs.items, sequences_data.sequences);
    defer gpa.free(pairs);

    const run_to_seq = try gpa.alloc(i32, runs.items.len);
    defer gpa.free(run_to_seq);
    @memset(run_to_seq, -1);
    for (sequences_data.sequences, 0..) |seq, seq_idx| {
        for (seq.run_indices) |run_idx| {
            run_to_seq[runIndexToUsize(run_idx)] = @intCast(seq_idx);
        }
    }

    var cross_irs_pairs: usize = 0;
    for (pairs) |pair| {
        const s_open = run_to_seq[runIndexToUsize(pair.open_run_idx)];
        const s_close = run_to_seq[runIndexToUsize(pair.close_run_idx)];
        try testing.expectEqual(s_open, s_close);
        if (s_open != -1 and s_close != -1 and s_open != s_close) {
            cross_irs_pairs += 1;
        }
    }

    // Spec-target expectation: bracket pairing must be independent per IRS.
    try testing.expectEqual(@as(usize, 0), cross_irs_pairs);
}

test "spec target: N0 ignores strong text from nested isolate inside bracket span" {
    const testing = std.testing;
    const gpa = testing.allocator;

    // The outer IRS contains the bracket pair around a nested isolate:
    //   LRI Hebrew "(" RLI "A" PDI ")" PDI
    // The nested "A" is globally between "(" and ")", but it is not in the
    // outer IRS and must not trigger N0c for the outer bracket pair.
    const cps = [_]u21{
        0x2066, // LRI
        0x05D0, // Hebrew letter, preceding strong in the outer IRS
        '(',
        0x2067, // RLI
        'A',
        0x2069, // PDI for nested RLI
        ')',
        0x2069, // PDI for outer LRI
    };

    const classes = try gpa.alloc(BidiClass, cps.len);
    defer gpa.free(classes);
    for (cps, 0..) |cp, i| classes[i] = unicode.bidiClass(cp);

    var runs = ArrayList(Run){};
    defer runs.deinit(gpa);
    try buildRuns(gpa, &runs, classes, &cps, @intCast(cps.len));
    try resolveExplicit(&runs, 0);
    for (runs.items) |*run| run.orig_class = run.class;

    const level_runs = try computeLevelRuns(gpa, runs.items);
    defer gpa.free(level_runs);
    const sequences_data = try computeIsolatingRunSequences(gpa, runs.items, level_runs, 0);
    defer deinitIsolatingRunSequences(gpa, sequences_data);
    try resolveWeak(gpa, runs.items, sequences_data.sequences);

    const pairs = try collectBracketPairsPerSequence(gpa, &cps, runs.items, sequences_data.sequences);
    defer gpa.free(pairs);
    try testing.expectEqual(@as(usize, 1), pairs.len);

    const open_idx = runIndexToUsize(pairs[0].open_run_idx);
    const close_idx = runIndexToUsize(pairs[0].close_run_idx);
    try testing.expectEqual(@as(u32, 2), runs.items[open_idx].pos);
    try testing.expectEqual(@as(u32, 6), runs.items[close_idx].pos);

    var nested_strong_is_in_pair_irs = false;
    const seq = sequences_data.sequences[runIndexToUsize(pairs[0].seq_idx)];
    for (seq.run_indices) |run_idx| {
        if (runs.items[runIndexToUsize(run_idx)].pos == 4) {
            nested_strong_is_in_pair_irs = true;
        }
    }
    try testing.expect(!nested_strong_is_in_pair_irs);

    applyBracketPairsN0(runs.items, sequences_data.sequences, pairs);

    try testing.expectEqual(BidiClass.other_neutrals, runs.items[open_idx].class);
    try testing.expectEqual(BidiClass.other_neutrals, runs.items[close_idx].class);
}

test "P2-P3: paragraph direction detection" {
    const testing = std.testing;
    const gpa = testing.allocator;

    // Pure LTR
    {
        var dir: ParDirection = .auto_ltr;
        var result = try getParEmbeddingLevels(gpa, &[_]u21{ 'H', 'e', 'l', 'l', 'o' }, &dir);
        defer result.deinit(gpa);
        try testing.expectEqual(ParDirection.ltr, result.resolved_par_dir);
        for (result.levels) |l| try testing.expectEqual(@as(BidiLevel, 0), l);
    }

    // Pure RTL (Hebrew)
    {
        var dir: ParDirection = .auto_ltr;
        var result = try getParEmbeddingLevels(gpa, &[_]u21{ 0x05D0, 0x05D1, 0x05D2 }, &dir);
        defer result.deinit(gpa);
        try testing.expectEqual(ParDirection.rtl, result.resolved_par_dir);
        for (result.levels) |l| try testing.expectEqual(@as(BidiLevel, 1), l);
    }

    // Empty input
    {
        var dir: ParDirection = .auto_ltr;
        var result = try getParEmbeddingLevels(gpa, &[_]u21{}, &dir);
        defer result.deinit(gpa);
        try testing.expectEqual(@as(usize, 0), result.levels.len);
        try testing.expectEqual(ParDirection.ltr, result.resolved_par_dir);
        try testing.expectEqual(ParDirection.ltr, dir);
    }

    // Empty input keeps auto_rtl fallback consistent with non-empty no-strong input.
    {
        var dir: ParDirection = .auto_rtl;
        var result = try getParEmbeddingLevels(gpa, &[_]u21{}, &dir);
        defer result.deinit(gpa);
        try testing.expectEqual(@as(usize, 0), result.levels.len);
        try testing.expectEqual(ParDirection.rtl, result.resolved_par_dir);
        try testing.expectEqual(ParDirection.rtl, dir);
    }

    // Scratch view follows the same empty-input writeback contract.
    {
        var scratch = EmbeddingScratch{};
        defer scratch.deinit(gpa);

        var dir: ParDirection = .auto_rtl;
        const view = try getParEmbeddingLevelsScratchView(gpa, &scratch, &[_]u21{}, &dir);
        try testing.expectEqual(@as(usize, 0), view.levels.len);
        try testing.expectEqual(ParDirection.rtl, view.resolved_par_dir);
        try testing.expectEqual(ParDirection.rtl, dir);
    }
}

test "fast path: allocation-free pre-scan preserves auto_rtl fallback semantics" {
    const testing = std.testing;
    const gpa = testing.allocator;

    {
        var dir: ParDirection = .auto_rtl;
        const input = [_]u21{ 'A', ' ', '1', ')' };
        var result = try getParEmbeddingLevels(gpa, &input, &dir);
        defer result.deinit(gpa);

        try testing.expectEqual(ParDirection.ltr, result.resolved_par_dir);
        try testing.expectEqual(ParDirection.ltr, dir);
        for (result.levels) |level| try testing.expectEqual(@as(BidiLevel, 0), level);
    }

    {
        var dir: ParDirection = .auto_rtl;
        const input = [_]u21{ ' ', '1', ')' };
        var result = try getParEmbeddingLevels(gpa, &input, &dir);
        defer result.deinit(gpa);

        try testing.expectEqual(ParDirection.rtl, result.resolved_par_dir);
        try testing.expectEqual(ParDirection.rtl, dir);
        try testing.expectEqual(@as(BidiLevel, 1), result.levels[0]);
        try testing.expectEqual(@as(BidiLevel, 2), result.levels[1]);
    }

    {
        var dir: ParDirection = .auto_ltr;
        const input = [_]u21{ 0x2066, ')', 0x2069 };
        var result = try getParEmbeddingLevels(gpa, &input, &dir);
        defer result.deinit(gpa);

        try testing.expectEqual(@as(BidiLevel, 2), result.levels[1]);
    }
}

test "public helper: hasStrongRtl detects R and AL only" {
    const testing = std.testing;

    try testing.expect(!hasStrongRtl(&[_]u21{ 'A', ' ', '1', ')' }));
    try testing.expect(hasStrongRtl(&[_]u21{ 'A', 0x05D0 }));
    try testing.expect(hasStrongRtl(&[_]u21{ 'A', 0x0627 }));
    try testing.expect(!hasStrongRtl(&[_]u21{ 0x0661, 0x0662 }));
}

test "explicit levels: LRE/RLE" {
    const testing = std.testing;
    const gpa = testing.allocator;

    // RLE + Hebrew text
    {
        var dir: ParDirection = .ltr;
        const input = [_]u21{ 0x202B, 0x05D0, 0x05D1, 0x202C }; // RLE, Alef, Bet, PDF
        var result = try getParEmbeddingLevels(gpa, &input, &dir);
        defer result.deinit(gpa);
        try testing.expectEqual(@as(BidiLevel, 1), result.levels[1]); // Alef at level 1
        try testing.expectEqual(@as(BidiLevel, 1), result.levels[2]); // Bet at level 1
    }
}

test "conformance regression: explicit controls do not perturb ordering (sample 1)" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const reorder = @import("reorder.zig");

    const cps = [_]u21{ 0x0061, 0x202E, 0x202C, 0x0020, 0x0031, 0x0020, 0x0032, 0x002D, 0x0033 };
    const expected_levels_non_ignored = [_]BidiLevel{ 2, 2, 2, 2, 2, 2, 2 };
    const ignored = [_]bool{ false, true, true, false, false, false, false, false, false };
    const expected_order = [_]u32{ 0, 3, 4, 5, 6, 7, 8 };

    var dir: ParDirection = .rtl;
    var emb = try getParEmbeddingLevels(gpa, &cps, &dir);
    defer emb.deinit(gpa);

    var actual_levels = std.ArrayList(BidiLevel).empty;
    defer actual_levels.deinit(gpa);
    for (emb.levels, 0..) |level, idx| {
        if (!ignored[idx]) {
            try actual_levels.append(gpa, level);
        }
    }
    try testing.expectEqualSlices(BidiLevel, &expected_levels_non_ignored, actual_levels.items);

    var vis = try reorder.reorderLine(gpa, &cps, emb.levels, dir.toLevel());
    defer vis.deinit(gpa);

    var actual = std.ArrayList(u32).empty;
    defer actual.deinit(gpa);
    for (vis.v_to_l) |logical_idx| {
        if (!ignored[logical_idx]) {
            try actual.append(gpa, logical_idx);
        }
    }
    try testing.expectEqualSlices(u32, &expected_order, actual.items);
}

test "conformance regression: explicit controls with brackets in RTL (sample 6)" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const reorder = @import("reorder.zig");

    const cps = [_]u21{ 0x0061, 0x0028, 0x0062, 0x202B, 0x202C, 0x0029, 0x0020, 0x0031, 0x0020, 0x0032 };
    const expected_levels_non_ignored = [_]BidiLevel{ 2, 2, 2, 2, 2, 2, 2, 2 };
    const ignored = [_]bool{ false, false, false, true, true, false, false, false, false, false };
    const expected_order = [_]u32{ 0, 1, 2, 5, 6, 7, 8, 9 };

    var dir: ParDirection = .rtl;
    var emb = try getParEmbeddingLevels(gpa, &cps, &dir);
    defer emb.deinit(gpa);

    var actual_levels = std.ArrayList(BidiLevel).empty;
    defer actual_levels.deinit(gpa);
    for (emb.levels, 0..) |level, idx| {
        if (!ignored[idx]) {
            try actual_levels.append(gpa, level);
        }
    }
    try testing.expectEqualSlices(BidiLevel, &expected_levels_non_ignored, actual_levels.items);

    var vis = try reorder.reorderLine(gpa, &cps, emb.levels, dir.toLevel());
    defer vis.deinit(gpa);

    var actual = std.ArrayList(u32).empty;
    defer actual.deinit(gpa);
    for (vis.v_to_l) |logical_idx| {
        if (!ignored[logical_idx]) {
            try actual.append(gpa, logical_idx);
        }
    }
    try testing.expectEqualSlices(u32, &expected_order, actual.items);
}

test "conformance regression: R ON RLE B in ltr keeps ON at level 0" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const reorder = @import("reorder.zig");

    // R ON RLE B => cps: ALEF, '!', RLE, '\n'
    const cps = [_]u21{ 0x05D0, 0x0021, 0x202B, 0x000A };
    const ignored = [_]bool{ false, false, true, false };
    const expected_levels_non_ignored = [_]BidiLevel{ 1, 0, 0 };
    const expected_order = [_]u32{ 0, 1, 3 };

    var dir: ParDirection = .ltr;
    var emb = try getParEmbeddingLevels(gpa, &cps, &dir);
    defer emb.deinit(gpa);

    var actual_levels = std.ArrayList(BidiLevel).empty;
    defer actual_levels.deinit(gpa);
    for (emb.levels, 0..) |level, idx| {
        if (!ignored[idx]) {
            try actual_levels.append(gpa, level);
        }
    }
    try testing.expectEqualSlices(BidiLevel, &expected_levels_non_ignored, actual_levels.items);

    var vis = try reorder.reorderLine(gpa, &cps, emb.levels, dir.toLevel());
    defer vis.deinit(gpa);

    var actual = std.ArrayList(u32).empty;
    defer actual.deinit(gpa);
    for (vis.v_to_l) |logical_idx| {
        if (!ignored[logical_idx]) {
            try actual.append(gpa, logical_idx);
        }
    }
    try testing.expectEqualSlices(u32, &expected_order, actual.items);
}

test "conformance regression: EN ES ES EN in rtl" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const reorder = @import("reorder.zig");

    const cps = [_]u21{ '0', '+', '+', '1' };
    const expected_levels = [_]BidiLevel{ 2, 1, 1, 2 };
    const expected_order = [_]u32{ 3, 2, 1, 0 };

    var dir: ParDirection = .rtl;
    var emb = try getParEmbeddingLevels(gpa, &cps, &dir);
    defer emb.deinit(gpa);

    try testing.expectEqualSlices(BidiLevel, &expected_levels, emb.levels);

    var vis = try reorder.reorderLine(gpa, &cps, emb.levels, dir.toLevel());
    defer vis.deinit(gpa);
    try testing.expectEqualSlices(u32, &expected_order, vis.v_to_l);
}

test "conformance regression: BidiCharacter sample 1" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const reorder = @import("reorder.zig");

    const cps = [_]u21{ 0x0041, 0x200F, 0x005B, 0x05D0, 0x005D, 0x200D, 0x20D6 };
    const ignored = [_]bool{ false, false, false, false, false, true, false };
    const expected_levels_non_ignored = [_]BidiLevel{ 0, 1, 1, 1, 1, 1 };
    const expected_order = [_]u32{ 0, 6, 4, 3, 2, 1 };

    var dir: ParDirection = .ltr;
    var emb = try getParEmbeddingLevels(gpa, &cps, &dir);
    defer emb.deinit(gpa);

    var actual_levels = std.ArrayList(BidiLevel).empty;
    defer actual_levels.deinit(gpa);
    for (emb.levels, 0..) |level, idx| {
        if (!ignored[idx]) {
            try actual_levels.append(gpa, level);
        }
    }
    try testing.expectEqualSlices(BidiLevel, &expected_levels_non_ignored, actual_levels.items);

    var vis = try reorder.reorderLine(gpa, &cps, emb.levels, dir.toLevel());
    defer vis.deinit(gpa);
    var actual_order = std.ArrayList(u32).empty;
    defer actual_order.deinit(gpa);
    for (vis.v_to_l) |logical_idx| {
        if (!ignored[logical_idx]) {
            try actual_order.append(gpa, logical_idx);
        }
    }
    try testing.expectEqualSlices(u32, &expected_order, actual_order.items);
}

test "conformance regression: BidiCharacter sample 4" {
    const testing = std.testing;
    const gpa = testing.allocator;
    const reorder = @import("reorder.zig");

    const cps = [_]u21{ 0x0061, 0x0028, 0x0062, 0x202B, 0x202C, 0x0029, 0x0020, 0x05D0 };
    const ignored = [_]bool{ false, false, false, true, true, false, false, false };
    const expected_levels_non_ignored = [_]BidiLevel{ 2, 2, 2, 2, 1, 1 };
    const expected_order = [_]u32{ 7, 6, 0, 1, 2, 5 };

    var dir: ParDirection = .rtl;
    var emb = try getParEmbeddingLevels(gpa, &cps, &dir);
    defer emb.deinit(gpa);

    var actual_levels = std.ArrayList(BidiLevel).empty;
    defer actual_levels.deinit(gpa);
    for (emb.levels, 0..) |level, idx| {
        if (!ignored[idx]) {
            try actual_levels.append(gpa, level);
        }
    }
    try testing.expectEqualSlices(BidiLevel, &expected_levels_non_ignored, actual_levels.items);

    var vis = try reorder.reorderLine(gpa, &cps, emb.levels, dir.toLevel());
    defer vis.deinit(gpa);
    var actual_order = std.ArrayList(u32).empty;
    defer actual_order.deinit(gpa);
    for (vis.v_to_l) |logical_idx| {
        if (!ignored[logical_idx]) {
            try actual_order.append(gpa, logical_idx);
        }
    }
    try testing.expectEqualSlices(u32, &expected_order, actual_order.items);
}

test "scratch view matches default API" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var scratch = EmbeddingScratch{};
    defer scratch.deinit(gpa);

    const input = [_]u21{ 'a', 0x05D0, '(', '1', ')', 0x2067, 0x05D1, 0x2069, 'b' };

    var dir_default: ParDirection = .auto_ltr;
    var result_default = try getParEmbeddingLevels(gpa, &input, &dir_default);
    defer result_default.deinit(gpa);

    var dir_view: ParDirection = .auto_ltr;
    const view = try getParEmbeddingLevelsScratchView(gpa, &scratch, &input, &dir_view);

    try testing.expectEqual(dir_default, dir_view);
    try testing.expectEqualSlices(BidiLevel, result_default.levels, view.levels);
}

test "scratch view API matches default API and reuses capacity" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var scratch = EmbeddingScratch{};
    defer scratch.deinit(gpa);

    const input_big = [_]u21{
        'a', 'b', ' ', 0x05D0, 0x05D1, ' ', '(', '1', '2', ')', ' ', 0x2067, 0x0627, 0x2069, 'Z',
    };
    var dir_default: ParDirection = .auto_ltr;
    var result_default = try getParEmbeddingLevels(gpa, &input_big, &dir_default);
    defer result_default.deinit(gpa);

    var dir_view: ParDirection = .auto_ltr;
    const view_big = try getParEmbeddingLevelsScratchView(gpa, &scratch, &input_big, &dir_view);
    try testing.expectEqual(dir_default, dir_view);
    try testing.expectEqualSlices(BidiLevel, result_default.levels, view_big.levels);

    const input_small = [_]u21{ 'A', ' ', 0x05D0, 0x05D1 };
    var dir_small: ParDirection = .auto_ltr;
    const view_small = try getParEmbeddingLevelsScratchView(gpa, &scratch, &input_small, &dir_small);
    try testing.expectEqual(@as(usize, input_small.len), view_small.levels.len);
}

test "memory leak check" {
    const gpa = std.testing.allocator;
    var dir: ParDirection = .auto_ltr;
    // Mixed LTR/RTL
    const input = [_]u21{ 'A', 'B', 0x05D0, 0x05D1, 'C', 'D' };
    var result = try getParEmbeddingLevels(gpa, &input, &dir);
    result.deinit(gpa);
    // If GPA doesn't report leaks, we're good
}
