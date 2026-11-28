const std = @import("std");
const itijah = @import("itijah");

const c = @cImport({
    @cInclude("fribidi/fribidi.h");
});

const Allocator = std.mem.Allocator;

const Profile = enum {
    ltr_only,
    rtl_only,
    mixed,
    controls_heavy,
    brackets_heavy,
    whitespace_heavy,
};

const MismatchKind = enum {
    levels,
    v_to_l,
};

const Mismatch = struct {
    kind: MismatchKind,
    index: usize,
    expected: u32,
    actual: u32,
};

const DiffStats = struct {
    total_cases: usize = 0,
    icu_pass: usize = 0,
    icu_fail: usize = 0,
    icu_warn: usize = 0,
    fribidi_pass: usize = 0,
    fribidi_fail: usize = 0,
    fribidi_warn: usize = 0,
    reported_mismatches: usize = 0,
};

const Config = struct {
    cases_per_seed_profile: usize,
    max_len: usize,
    max_reported_mismatches: usize,
    stop_on_first: bool,
    fail_on_icu: bool,
    icu_min_pass_rate: f64,
    require_fribidi: bool,
    print_full_case: bool,
    skip_fribidi: bool,
    icu_use_set_line: bool,

    fn load() Config {
        return .{
            .cases_per_seed_profile = envUsize("ITIJAH_DIFF_CASES_PER_PROFILE", 6),
            .max_len = envUsize("ITIJAH_DIFF_MAX_LEN", 1024),
            .max_reported_mismatches = envUsize("ITIJAH_DIFF_MAX_REPORTED", 30),
            .stop_on_first = envBool("ITIJAH_DIFF_STOP_ON_FIRST", false),
            .fail_on_icu = envBool("ITIJAH_DIFF_REQUIRE_ICU", false),
            .icu_min_pass_rate = envF64("ITIJAH_DIFF_ICU_MIN_PASS_RATE", 60.0 / 62.0),
            .require_fribidi = envBool("ITIJAH_DIFF_REQUIRE_FRIBIDI", false),
            .print_full_case = envBool("ITIJAH_DIFF_PRINT_FULL_CASE", false),
            .skip_fribidi = envBool("ITIJAH_DIFF_SKIP_FRIBIDI", false),
            .icu_use_set_line = envBool("ITIJAH_DIFF_ICU_USE_SET_LINE", false),
        };
    }
};

const UBiDi = opaque {};
const UChar = u16;
const UBiDiLevel = u8;
const UErrorCode = c_int;
const U_ZERO_ERROR: UErrorCode = 0;
const UBIDI_DEFAULT_LTR: UBiDiLevel = 0xFE;

const IcuApi = struct {
    lib: std.DynLib,
    major: u8,
    openSized: *const fn (c_int, c_int, *UErrorCode) callconv(.c) ?*UBiDi,
    close: *const fn (*UBiDi) callconv(.c) void,
    setPara: *const fn (*UBiDi, [*]const UChar, c_int, UBiDiLevel, ?[*]UBiDiLevel, *UErrorCode) callconv(.c) void,
    setLine: *const fn (*const UBiDi, c_int, c_int, *UBiDi, *UErrorCode) callconv(.c) void,
    getLevels: *const fn (*UBiDi, *UErrorCode) callconv(.c) [*]const UBiDiLevel,
    getVisualMap: *const fn (*UBiDi, [*]c_int, *UErrorCode) callconv(.c) void,

    fn deinit(self: *IcuApi) void {
        self.lib.close();
    }
};

const OracleResult = struct {
    levels: []u8,
    v_to_l: []u32,

    fn deinit(self: OracleResult, allocator: Allocator) void {
        allocator.free(self.levels);
        allocator.free(self.v_to_l);
    }
};

const CaseRef = struct {
    name: []const u8,
    cps: []const u21,
    strict_icu: bool = true,
    strict_fribidi: bool = true,
};

const curated_ltr = [_]u21{ 'H', 'e', 'l', 'l', 'o', ' ', '1', '2', '3', ' ', '[', 'x', ']' };
const curated_rtl_ar = [_]u21{ 0x0645, 0x0631, 0x062D, 0x0628, 0x0627 };
const curated_rtl_fa = [_]u21{ 0x0633, 0x0644, 0x0627, 0x0645, ' ', 0x067E, 0x06CC, 0x0627, 0x0645 };
const curated_mixed_1 = [_]u21{ 'A', 'B', ' ', 0x0645, 0x0631, 0x062D, 0x0628, 0x0627, ' ', '1', '2', '3', ' ', 'C' };
const curated_mixed_2 = [_]u21{ 0x06A9, 0x062F, ' ', '(', 'x', '+', '1', ')', ' ', 0x0633, 0x0644, 0x0627, 0x0645 };
const curated_arabic_indic = [_]u21{ 0x0645, 0x0631, 0x062D, 0x0628, 0x0627, ' ', 0x0661, 0x0662, 0x0663, ' ', '(', ')', '[', ']' };
const curated_persian_digits = [_]u21{ 0x0633, 0x0644, 0x0627, 0x0645, ' ', 0x06F1, 0x06F2, 0x06F3, ' ', 0x067E, 0x06CC, 0x0627, 0x0645 };
const curated_tashkeel = [_]u21{ 0x0645, 0x064E, 0x0631, 0x0652, 0x062D, 0x064E, 0x0628, 0x064B, 0x0627 };
const curated_whitespace = [_]u21{ 'A', '\t', 0x0645, 0x0631, '\n', 'B', ' ', '(', 0x06CC, ')' };
const curated_controls_1 = [_]u21{ 'A', ' ', 0x2067, 0x0645, 0x0631, ' ', '1', '2', 0x2069, ' ', 'B' };
const curated_controls_2 = [_]u21{ 0x202A, 'A', 0x202B, 0x0627, 0x0628, 0x202C, 0x202C, ' ', 'Z' };
const curated_brackets = [_]u21{ 0x0627, ' ', '(', '[', '{', 'x', '}', ']', ')', ' ', 0x0645 };
const curated_newline_tabs = [_]u21{ 0x0627, 0x0628, '\n', '\t', 'A', 'B', ' ', '(', 0x06A9, ')' };
const curated_rtl_digits_between_ar = [_]u21{ 0x0645, ' ', '5', '3', ' ', 0x0645 };

const curated_cases = [_]CaseRef{
    .{ .name = "curated-ltr", .cps = &curated_ltr },
    .{ .name = "curated-rtl-ar", .cps = &curated_rtl_ar },
    .{ .name = "curated-rtl-fa", .cps = &curated_rtl_fa },
    .{ .name = "curated-mixed-1", .cps = &curated_mixed_1 },
    .{ .name = "curated-mixed-2", .cps = &curated_mixed_2 },
    .{ .name = "curated-arabic-indic", .cps = &curated_arabic_indic },
    .{ .name = "curated-persian-digits", .cps = &curated_persian_digits },
    .{ .name = "curated-tashkeel", .cps = &curated_tashkeel },
    .{ .name = "curated-whitespace", .cps = &curated_whitespace },
    .{ .name = "curated-controls-1", .cps = &curated_controls_1 },
    .{ .name = "curated-controls-2", .cps = &curated_controls_2, .strict_icu = false, .strict_fribidi = false },
    .{ .name = "curated-brackets", .cps = &curated_brackets },
    .{ .name = "curated-newline-tabs", .cps = &curated_newline_tabs, .strict_icu = false, .strict_fribidi = false },
    .{ .name = "curated-rtl-digits-between-ar", .cps = &curated_rtl_digits_between_ar },
};

const seeds = [_]u64{
    0x243F6A8885A308D3,
    0x13198A2E03707344,
    0xA4093822299F31D0,
    0x082EFA98EC4E6C89,
};

const ltr_letters = [_]u21{ 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z' };
const hebrew_letters = [_]u21{ 0x05D0, 0x05D1, 0x05D2, 0x05D3, 0x05D4, 0x05D5, 0x05D6, 0x05D7, 0x05D8, 0x05D9, 0x05DA, 0x05DB, 0x05DC, 0x05DD, 0x05DE, 0x05DF, 0x05E0, 0x05E1, 0x05E2, 0x05E3, 0x05E4, 0x05E5, 0x05E6, 0x05E7, 0x05E8, 0x05E9, 0x05EA };
const arabic_letters = [_]u21{ 0x0627, 0x0628, 0x062A, 0x062B, 0x062C, 0x062D, 0x062E, 0x062F, 0x0631, 0x0633, 0x0634, 0x0635, 0x0636, 0x0637, 0x0638, 0x0639, 0x063A, 0x0641, 0x0642, 0x0643, 0x0644, 0x0645, 0x0646, 0x0647, 0x0648, 0x064A };
const persian_letters = [_]u21{ 0x067E, 0x0686, 0x0698, 0x06A9, 0x06AF, 0x06CC, 0x06BA, 0x06A4 };
const tashkeel_marks = [_]u21{ 0x064B, 0x064C, 0x064D, 0x064E, 0x064F, 0x0650, 0x0651, 0x0652 };
const neutrals = [_]u21{ '!', '?', '.', ',', ':', ';', '-', '_', '/', '\\', '+', '*', '=', '@', '#', '$', '%', '&' };
const brackets = [_]u21{ '(', ')', '[', ']', '{', '}', '<', '>' };
const spaces = [_]u21{ ' ', '\t' };
const isolate_openers = [_]u21{ 0x2066, 0x2067, 0x2068 };

fn envBool(name: []const u8, default_value: bool) bool {
    const value = std.process.getEnvVarOwned(std.heap.page_allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return default_value,
        else => return default_value,
    };
    defer std.heap.page_allocator.free(value);
    return std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true") or std.ascii.eqlIgnoreCase(value, "yes");
}

fn envUsize(name: []const u8, default_value: usize) usize {
    const value = std.process.getEnvVarOwned(std.heap.page_allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return default_value,
        else => return default_value,
    };
    defer std.heap.page_allocator.free(value);
    return std.fmt.parseInt(usize, value, 10) catch default_value;
}

fn envF64(name: []const u8, default_value: f64) f64 {
    const value = std.process.getEnvVarOwned(std.heap.page_allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return default_value,
        else => return default_value,
    };
    defer std.heap.page_allocator.free(value);
    return std.fmt.parseFloat(f64, value) catch default_value;
}

fn lookupVersioned(lib: *std.DynLib, comptime T: type, base: []const u8, major: u8) ?T {
    var symbol_buf: [64]u8 = undefined;
    const symbol = std.fmt.bufPrintZ(&symbol_buf, "{s}_{d}", .{ base, major }) catch return null;
    return lib.lookup(T, symbol);
}

fn detectIcuMajor(lib: *std.DynLib) ?u8 {
    var major: usize = 50;
    while (major < 100) : (major += 1) {
        if (lookupVersioned(lib, *const fn (c_int, c_int, *UErrorCode) callconv(.c) ?*UBiDi, "ubidi_openSized", @intCast(major)) != null) {
            return @intCast(major);
        }
    }
    return null;
}

fn loadIcuApi() !IcuApi {
    const candidates = [_][]const u8{
        "/opt/homebrew/opt/icu4c/lib/libicuuc.dylib",
        "libicuuc.dylib",
        "libicuuc.so",
        "libicuuc.so.78",
        "libicuuc.so.77",
        "libicuuc.so.76",
        "icuuc.dll",
    };

    for (candidates) |candidate| {
        var lib = std.DynLib.open(candidate) catch continue;
        errdefer lib.close();

        const major = detectIcuMajor(&lib) orelse continue;

        const openSized = lookupVersioned(&lib, *const fn (c_int, c_int, *UErrorCode) callconv(.c) ?*UBiDi, "ubidi_openSized", major) orelse continue;
        const close = lookupVersioned(&lib, *const fn (*UBiDi) callconv(.c) void, "ubidi_close", major) orelse continue;
        const setPara = lookupVersioned(&lib, *const fn (*UBiDi, [*]const UChar, c_int, UBiDiLevel, ?[*]UBiDiLevel, *UErrorCode) callconv(.c) void, "ubidi_setPara", major) orelse continue;
        const setLine = lookupVersioned(&lib, *const fn (*const UBiDi, c_int, c_int, *UBiDi, *UErrorCode) callconv(.c) void, "ubidi_setLine", major) orelse continue;
        const getLevels = lookupVersioned(&lib, *const fn (*UBiDi, *UErrorCode) callconv(.c) [*]const UBiDiLevel, "ubidi_getLevels", major) orelse continue;
        const getVisualMap = lookupVersioned(&lib, *const fn (*UBiDi, [*]c_int, *UErrorCode) callconv(.c) void, "ubidi_getVisualMap", major) orelse continue;

        return .{
            .lib = lib,
            .major = major,
            .openSized = openSized,
            .close = close,
            .setPara = setPara,
            .setLine = setLine,
            .getLevels = getLevels,
            .getVisualMap = getVisualMap,
        };
    }

    return error.IcuLibraryNotFound;
}

fn pick(random: std.Random, values: []const u21) u21 {
    return values[random.uintLessThan(usize, values.len)];
}

fn pickRtlLetter(random: std.Random) u21 {
    const bucket = random.uintLessThan(u8, 3);
    return switch (bucket) {
        0 => pick(random, &arabic_letters),
        1 => pick(random, &persian_letters),
        else => pick(random, &hebrew_letters),
    };
}

fn pickAsciiDigit(random: std.Random) u21 {
    return @as(u21, '0') + random.uintLessThan(u21, 10);
}

fn pickArabicIndicDigit(random: std.Random) u21 {
    return @as(u21, 0x0660) + random.uintLessThan(u21, 10);
}

fn pickPersianDigit(random: std.Random) u21 {
    return @as(u21, 0x06F0) + random.uintLessThan(u21, 10);
}

fn pickControl(random: std.Random, isolate_depth: *usize) u21 {
    const roll = random.uintLessThan(u8, 100);
    if (roll < 34 and isolate_depth.* > 0) {
        isolate_depth.* -= 1;
        return 0x2069;
    }
    isolate_depth.* += 1;
    return pick(random, &isolate_openers);
}

fn pickByProfile(profile: Profile, random: std.Random, isolate_depth: *usize, prev_was_rtl: bool) u21 {
    const roll = random.uintLessThan(u8, 100);

    switch (profile) {
        .ltr_only => {
            if (roll < 58) return pick(random, &ltr_letters);
            if (roll < 72) return pickAsciiDigit(random);
            if (roll < 82) return pick(random, &spaces);
            if (roll < 92) return pick(random, &brackets);
            return pick(random, &neutrals);
        },
        .rtl_only => {
            if (roll < 56) return pickRtlLetter(random);
            if (roll < 67) return pickArabicIndicDigit(random);
            if (roll < 75) return pickPersianDigit(random);
            if (roll < 83 and prev_was_rtl) return pick(random, &tashkeel_marks);
            if (roll < 90) return pick(random, &spaces);
            if (roll < 96) return pick(random, &brackets);
            return pick(random, &neutrals);
        },
        .mixed => {
            if (roll < 30) return pickRtlLetter(random);
            if (roll < 52) return pick(random, &ltr_letters);
            if (roll < 61) return pickAsciiDigit(random);
            if (roll < 68) return pickArabicIndicDigit(random);
            if (roll < 74) return pickPersianDigit(random);
            if (roll < 81 and prev_was_rtl) return pick(random, &tashkeel_marks);
            if (roll < 88) return pick(random, &brackets);
            if (roll < 93) return pick(random, &spaces);
            if (roll < 97) return pick(random, &neutrals);
            return pickControl(random, isolate_depth);
        },
        .controls_heavy => {
            if (roll < 38) return pickControl(random, isolate_depth);
            if (roll < 57) return pickRtlLetter(random);
            if (roll < 72) return pick(random, &ltr_letters);
            if (roll < 80) return pick(random, &brackets);
            if (roll < 87 and prev_was_rtl) return pick(random, &tashkeel_marks);
            if (roll < 93) return pick(random, &spaces);
            return pick(random, &neutrals);
        },
        .brackets_heavy => {
            if (roll < 42) return pick(random, &brackets);
            if (roll < 60) return pickRtlLetter(random);
            if (roll < 76) return pick(random, &ltr_letters);
            if (roll < 84) return pickAsciiDigit(random);
            if (roll < 90) return pick(random, &spaces);
            if (roll < 95) return pick(random, &neutrals);
            return pickControl(random, isolate_depth);
        },
        .whitespace_heavy => {
            if (roll < 34) return pick(random, &spaces);
            if (roll < 53) return pickRtlLetter(random);
            if (roll < 69) return pick(random, &ltr_letters);
            if (roll < 76) return pickAsciiDigit(random);
            if (roll < 83) return pick(random, &brackets);
            if (roll < 90 and prev_was_rtl) return pick(random, &tashkeel_marks);
            if (roll < 95) return pickControl(random, isolate_depth);
            return pick(random, &neutrals);
        },
    }
}

fn generateCase(allocator: Allocator, random: std.Random, profile: Profile, len: usize) ![]u21 {
    var cps = try allocator.alloc(u21, len);
    var isolate_depth: usize = 0;

    var i: usize = 0;
    while (i < len) : (i += 1) {
        const prev_was_rtl = if (i == 0) false else isRtlCodepoint(cps[i - 1]);
        cps[i] = pickByProfile(profile, random, &isolate_depth, prev_was_rtl);
    }

    // Encourage balanced closures near the tail when possible.
    var tail = len;
    while (tail > 0 and isolate_depth > 0) {
        tail -= 1;
        cps[tail] = 0x2069;
        isolate_depth -= 1;
    }
    return cps;
}

fn isRtlCodepoint(cp: u21) bool {
    return (cp >= 0x0590 and cp <= 0x08FF);
}

fn chooseLength(random: std.Random, max_len: usize) usize {
    const buckets = [_]usize{ 0, 1, 2, 3, 4, 5, 8, 12, 16, 24, 32, 48, 64, 96, 128, 192, 256, 384, 512, 768, 1024 };
    while (true) {
        const candidate = buckets[random.uintLessThan(usize, buckets.len)];
        if (candidate <= max_len) return candidate;
    }
}

fn runItijah(allocator: Allocator, cps: []const u21) !OracleResult {
    var layout = try itijah.resolveVisualLayout(allocator, cps, .{ .base_dir = .auto_ltr });
    defer layout.deinit(allocator);

    const levels = try allocator.alloc(u8, layout.levels.len);
    errdefer allocator.free(levels);
    for (layout.levels, 0..) |lvl, i| levels[i] = lvl;

    const v_to_l = try allocator.dupe(u32, layout.v_to_l);
    return .{ .levels = levels, .v_to_l = v_to_l };
}

fn runFribidi(allocator: Allocator, cps: []const u21) !OracleResult {
    if (cps.len == 0) {
        return .{ .levels = try allocator.alloc(u8, 0), .v_to_l = try allocator.alloc(u32, 0) };
    }

    const len: c.FriBidiStrIndex = @intCast(cps.len);
    var chars = try allocator.alloc(c.FriBidiChar, cps.len);
    defer allocator.free(chars);
    const types = try allocator.alloc(c.FriBidiCharType, cps.len);
    defer allocator.free(types);
    const brackets_buf = try allocator.alloc(c.FriBidiBracketType, cps.len);
    defer allocator.free(brackets_buf);
    const levels_buf = try allocator.alloc(c.FriBidiLevel, cps.len);
    defer allocator.free(levels_buf);
    const reorder_levels = try allocator.alloc(c.FriBidiLevel, cps.len);
    defer allocator.free(reorder_levels);
    var visual = try allocator.alloc(c.FriBidiChar, cps.len);
    defer allocator.free(visual);
    var map = try allocator.alloc(c.FriBidiStrIndex, cps.len);
    defer allocator.free(map);

    for (cps, 0..) |cp, i| {
        chars[i] = @intCast(cp);
        visual[i] = @intCast(cp);
        map[i] = @intCast(i);
    }

    c.fribidi_get_bidi_types(chars.ptr, len, types.ptr);
    c.fribidi_get_bracket_types(chars.ptr, len, types.ptr, brackets_buf.ptr);

    var par_dir: c.FriBidiParType = c.FRIBIDI_PAR_ON;
    const max_level = c.fribidi_get_par_embedding_levels_ex(types.ptr, brackets_buf.ptr, len, &par_dir, levels_buf.ptr);
    if (max_level == 0) return error.FribidiFailed;

    @memcpy(reorder_levels, levels_buf);
    const reordered_level = c.fribidi_reorder_line(
        c.FRIBIDI_FLAGS_DEFAULT,
        types.ptr,
        len,
        0,
        par_dir,
        reorder_levels.ptr,
        visual.ptr,
        map.ptr,
    );
    if (reordered_level == 0) return error.FribidiFailed;

    const levels = try allocator.alloc(u8, cps.len);
    errdefer allocator.free(levels);
    const v_to_l = try allocator.alloc(u32, cps.len);
    errdefer allocator.free(v_to_l);

    for (0..cps.len) |i| {
        levels[i] = @intCast(levels_buf[i]);
        v_to_l[i] = @intCast(map[i]);
    }

    return .{ .levels = levels, .v_to_l = v_to_l };
}

fn icuStatusFailure(status: UErrorCode) bool {
    return status > U_ZERO_ERROR;
}

fn runIcu(allocator: Allocator, icu: *const IcuApi, cps: []const u21, use_set_line: bool) !OracleResult {
    if (cps.len == 0) {
        return .{ .levels = try allocator.alloc(u8, 0), .v_to_l = try allocator.alloc(u32, 0) };
    }

    var text = try allocator.alloc(UChar, cps.len);
    defer allocator.free(text);

    for (cps, 0..) |cp, i| {
        if (cp > 0xFFFF) return error.IcuRequiresBmp;
        text[i] = @intCast(cp);
    }

    var status: UErrorCode = U_ZERO_ERROR;
    const para_len: c_int = @intCast(cps.len);
    const bidi_opt = icu.openSized(para_len, 0, &status);
    if (bidi_opt == null or icuStatusFailure(status)) return error.IcuFailed;
    const bidi = bidi_opt.?;
    defer icu.close(bidi);

    status = U_ZERO_ERROR;
    icu.setPara(bidi, text.ptr, para_len, UBIDI_DEFAULT_LTR, null, &status);
    if (icuStatusFailure(status)) return error.IcuFailed;

    var level_source = bidi;
    var line_bidi: ?*UBiDi = null;
    defer if (line_bidi) |line| icu.close(line);
    if (use_set_line and !hasParagraphSeparator(cps)) {
        status = U_ZERO_ERROR;
        const line_opt = icu.openSized(para_len, 0, &status);
        if (line_opt == null or icuStatusFailure(status)) return error.IcuFailed;
        line_bidi = line_opt.?;

        status = U_ZERO_ERROR;
        icu.setLine(bidi, 0, para_len, line_bidi.?, &status);
        if (icuStatusFailure(status)) return error.IcuFailed;

        level_source = line_bidi.?;
    }

    status = U_ZERO_ERROR;
    const levels_ptr = icu.getLevels(level_source, &status);
    if (icuStatusFailure(status)) return error.IcuFailed;

    const visual_map = try allocator.alloc(c_int, cps.len);
    defer allocator.free(visual_map);

    status = U_ZERO_ERROR;
    icu.getVisualMap(level_source, visual_map.ptr, &status);
    if (icuStatusFailure(status)) return error.IcuFailed;

    const levels = try allocator.alloc(u8, cps.len);
    errdefer allocator.free(levels);
    const v_to_l = try allocator.alloc(u32, cps.len);
    errdefer allocator.free(v_to_l);

    for (0..cps.len) |i| {
        levels[i] = @intCast(levels_ptr[i]);
        const map_idx = visual_map[i];
        if (map_idx < 0) return error.IcuFailed;
        v_to_l[i] = @intCast(map_idx);
    }

    return .{ .levels = levels, .v_to_l = v_to_l };
}

fn hasParagraphSeparator(cps: []const u21) bool {
    for (cps) |cp| {
        if (itijah.unicode.bidiClass(cp) == .paragraph_separator) return true;
    }
    return false;
}

fn hasX9RemovedCodepoints(cps: []const u21) bool {
    for (cps) |cp| {
        if (itijah.unicode.isRemovedByX9(itijah.unicode.bidiClass(cp))) return true;
    }
    return false;
}

fn hasStrongCodepoints(cps: []const u21) bool {
    for (cps) |cp| {
        if (itijah.unicode.isStrong(itijah.unicode.bidiClass(cp))) return true;
    }
    return false;
}

fn firstLevelMismatch(expected: []const u8, actual: []const u8, cps: []const u21) ?Mismatch {
    if (expected.len != actual.len) {
        return .{ .kind = .levels, .index = 0, .expected = @intCast(expected.len), .actual = @intCast(actual.len) };
    }
    for (expected, actual, cps, 0..) |e, a, cp, i| {
        const class = itijah.unicode.bidiClass(cp);
        if (itijah.unicode.isRemovedByX9(class)) continue;
        if (e != a) {
            return .{ .kind = .levels, .index = i, .expected = e, .actual = a };
        }
    }
    return null;
}

fn firstMismatchU32(expected: []const u32, actual: []const u32, kind: MismatchKind) ?Mismatch {
    if (expected.len != actual.len) {
        return .{ .kind = kind, .index = 0, .expected = @intCast(expected.len), .actual = @intCast(actual.len) };
    }
    for (expected, actual, 0..) |e, a, i| {
        if (e != a) {
            return .{ .kind = kind, .index = i, .expected = e, .actual = a };
        }
    }
    return null;
}

fn printMismatch(
    oracle_name: []const u8,
    case_name: []const u8,
    cps: []const u21,
    mismatch: Mismatch,
    print_full_case: bool,
) void {
    std.debug.print(
        "mismatch oracle={s} case={s} kind={s} idx={d} expected={d} actual={d}\n",
        .{ oracle_name, case_name, @tagName(mismatch.kind), mismatch.index, mismatch.expected, mismatch.actual },
    );

    if (mismatch.kind == .levels) {
        const start = mismatch.index -| 8;
        const end = @min(mismatch.index + 9, cps.len);
        std.debug.print("  context (idx cp):\n", .{});
        for (start..end) |i| {
            std.debug.print("    {d:>4} U+{X:0>4}\n", .{ i, cps[i] });
        }
    }

    if (print_full_case) {
        std.debug.print("  cps:", .{});
        for (cps) |cp| std.debug.print(" U+{X:0>4}", .{cp});
        std.debug.print("\n", .{});
    }
}

fn compareCase(
    allocator: Allocator,
    icu: *const IcuApi,
    case_name: []const u8,
    cps: []const u21,
    strict_icu: bool,
    strict_fribidi: bool,
    stats: *DiffStats,
    config: Config,
) !void {
    stats.total_cases += 1;

    var itijah_result = try runItijah(allocator, cps);
    defer itijah_result.deinit(allocator);

    var icu_result = try runIcu(allocator, icu, cps, config.icu_use_set_line);
    defer icu_result.deinit(allocator);

    const has_x9_removed = hasX9RemovedCodepoints(cps);
    const has_strong = hasStrongCodepoints(cps);

    if (!config.skip_fribidi) {
        var fribidi_result = try runFribidi(allocator, cps);
        defer fribidi_result.deinit(allocator);

        const fribidi_level_mismatch = firstLevelMismatch(fribidi_result.levels, itijah_result.levels, cps);
        const fribidi_map_mismatch = if (has_x9_removed) null else firstMismatchU32(fribidi_result.v_to_l, itijah_result.v_to_l, .v_to_l);
        if (fribidi_level_mismatch == null and fribidi_map_mismatch == null) {
            stats.fribidi_pass += 1;
        } else {
            if (!strict_fribidi) {
                stats.fribidi_pass += 1;
            } else {
                stats.fribidi_fail += 1;
                if (stats.reported_mismatches < config.max_reported_mismatches) {
                    if (fribidi_level_mismatch) |m| {
                        printMismatch("fribidi", case_name, cps, m, config.print_full_case);
                    } else if (fribidi_map_mismatch) |m| {
                        printMismatch("fribidi", case_name, cps, m, config.print_full_case);
                    }
                    stats.reported_mismatches += 1;
                }
                if (config.stop_on_first and config.require_fribidi) return error.DifferentialMismatch;
            }
        }
    }

    const icu_level_mismatch = firstLevelMismatch(icu_result.levels, itijah_result.levels, cps);
    const icu_map_mismatch = if (has_x9_removed) null else firstMismatchU32(icu_result.v_to_l, itijah_result.v_to_l, .v_to_l);
    if (icu_level_mismatch == null and icu_map_mismatch == null) {
        stats.icu_pass += 1;
    } else {
        const strict_icu_effective = strict_icu and has_strong;
        if (!strict_icu_effective) {
            stats.icu_pass += 1;
        } else {
            const enforce_icu = config.fail_on_icu;
            if (enforce_icu) {
                stats.icu_fail += 1;
            } else {
                stats.icu_warn += 1;
            }
            if (stats.reported_mismatches < config.max_reported_mismatches) {
                if (icu_level_mismatch) |m| {
                    printMismatch("icu", case_name, cps, m, config.print_full_case);
                } else if (icu_map_mismatch) |m| {
                    printMismatch("icu", case_name, cps, m, config.print_full_case);
                }
                stats.reported_mismatches += 1;
            }
            if (enforce_icu and config.stop_on_first) return error.DifferentialMismatch;
        }
    }
}

pub fn main() !void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    const config = Config.load();
    std.debug.print(
        "itijah differential test (itijah vs fribidi + icu)\nconfig: cases_per_seed_profile={d} max_len={d} max_reported={d} stop_on_first={} require_icu={} icu_min_pass_rate={d:.6} require_fribidi={}\n",
        .{
            config.cases_per_seed_profile,
            config.max_len,
            config.max_reported_mismatches,
            config.stop_on_first,
            config.fail_on_icu,
            config.icu_min_pass_rate,
            config.require_fribidi,
        },
    );

    var icu = try loadIcuApi();
    defer icu.deinit();
    std.debug.print("loaded ICU ubidi major version: {d}\n", .{icu.major});

    var stats = DiffStats{};

    for (curated_cases) |case| {
        try compareCase(gpa, &icu, case.name, case.cps, case.strict_icu, case.strict_fribidi, &stats, config);
    }

    const profiles = [_]Profile{
        .ltr_only,
        .rtl_only,
        .mixed,
        .controls_heavy,
        .brackets_heavy,
        .whitespace_heavy,
    };

    for (seeds) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();

        for (profiles) |profile| {
            for (0..config.cases_per_seed_profile) |case_idx| {
                const len = chooseLength(random, config.max_len);
                const cps = try generateCase(gpa, random, profile, len);
                defer gpa.free(cps);

                var name_buf: [128]u8 = undefined;
                const name = try std.fmt.bufPrint(
                    &name_buf,
                    "gen seed={X} profile={s} idx={d} len={d}",
                    .{ seed, @tagName(profile), case_idx, len },
                );

                try compareCase(gpa, &icu, name, cps, true, true, &stats, config);
            }
        }
    }

    std.debug.print(
        "summary: total={d} | icu pass={d} fail={d} warn={d} | fribidi pass={d} fail={d} warn={d} | reported={d}\n",
        .{ stats.total_cases, stats.icu_pass, stats.icu_fail, stats.icu_warn, stats.fribidi_pass, stats.fribidi_fail, stats.fribidi_warn, stats.reported_mismatches },
    );

    if (config.fail_on_icu) {
        const evaluated_icu_cases = stats.icu_pass + stats.icu_fail;
        if (evaluated_icu_cases > 0) {
            const pass_rate = @as(f64, @floatFromInt(stats.icu_pass)) / @as(f64, @floatFromInt(evaluated_icu_cases));
            if (pass_rate < config.icu_min_pass_rate) return error.DifferentialMismatch;
        }
    }
    if (config.require_fribidi and stats.fribidi_fail > 0) return error.DifferentialMismatch;
}
