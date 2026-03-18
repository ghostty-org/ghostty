const std = @import("std");

/// Result of word extraction. The caller must free `word` using the
/// allocator that was passed to `extract`.
pub const Result = struct {
    /// The cleaned filename (trailing punctuation stripped, line:col
    /// removed, backslash-spaces unescaped).
    word: []const u8,
    /// Start byte index in the original text (before cleanup).
    start: usize,
    /// End byte index (exclusive) in the original text (before cleanup).
    end: usize,
};

/// Characters that are valid in filenames. Scanning stops at the first
/// character NOT in this set (unless escape- or quote-aware rules apply).
fn isFilenameChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9' => true,
        '.', '-', '_', '+', '~', ':' => true,
        else => false,
    };
}

/// Extracts a candidate filename from `text` at the given `offset`.
/// Returns a Result with the cleaned word and its raw bounds, or null
/// if no valid candidate is found at the position.
///
/// The caller must free `result.word` using `alloc`.
pub fn extract(alloc: std.mem.Allocator, text: []const u8, offset: usize) ?Result {
    if (offset >= text.len) return null;
    if (!isFilenameChar(text[offset]) and text[offset] != '"' and text[offset] != '\'') return null;

    // Phase 1: Check if cursor is inside quotes
    if (extractQuoted(alloc, text, offset)) |result| return result;

    // Phase 2: Character-set scan with escape awareness
    return extractWord(alloc, text, offset);
}

/// Checks if offset is inside a quoted string ("..." or '...').
/// If so, returns the content between the quotes.
fn extractQuoted(alloc: std.mem.Allocator, text: []const u8, offset: usize) ?Result {
    // Scan left for an opening quote, recording its position
    var open: usize = undefined;
    const quote_char: u8 = find_quote: {
        var i = offset;
        while (i > 0) {
            i -= 1;
            if (text[i] == '"' or text[i] == '\'') {
                open = i;
                break :find_quote text[i];
            }
            // If we hit a newline or other control char, no quote
            if (text[i] < 0x20) return null;
        }
        return null;
    };

    // Verify cursor is inside this quoted string (no closing quote between open and offset)
    for (text[open + 1 .. offset]) |c| {
        if (c == quote_char) return null; // Cursor is between two quoted strings
    }

    // Find the closing quote
    var close: usize = offset + 1;
    while (close < text.len) : (close += 1) {
        if (text[close] == quote_char) break;
    } else {
        return null; // No closing quote found
    }

    const content_start = open + 1;
    const content_end = close;
    const content = text[content_start..content_end];
    if (content.len == 0) return null;

    const word = cleanup(alloc, content) orelse return null;
    return .{ .word = word, .start = content_start, .end = content_end };
}

/// Scans outward from offset using the filename charset.
/// Handles backslash-escaped spaces.
fn extractWord(alloc: std.mem.Allocator, text: []const u8, offset: usize) ?Result {
    // Scan left
    var left = offset;
    while (left > 0) {
        const prev = left - 1;
        if (isFilenameChar(text[prev])) {
            left = prev;
            continue;
        }
        // Check for backslash-escaped space: `\ `
        if (text[prev] == ' ' and prev > 0 and text[prev - 1] == '\\') {
            left = prev - 1;
            continue;
        }
        break;
    }

    // Scan right
    var right = offset + 1;
    while (right < text.len) {
        if (isFilenameChar(text[right])) {
            right += 1;
            continue;
        }
        // Check for backslash-escaped space
        if (text[right] == '\\' and right + 1 < text.len and text[right + 1] == ' ') {
            right += 2;
            continue;
        }
        break;
    }

    const raw = text[left..right];
    if (raw.len == 0) return null;

    const word = cleanup(alloc, raw) orelse return null;
    return .{ .word = word, .start = left, .end = right };
}

/// Post-extraction cleanup:
/// 1. Strip trailing punctuation (. , : ; ! ?)
/// 2. Strip :line[:col] suffix
/// 3. Replace `\ ` with ` ` (unescape spaces)
fn cleanup(alloc: std.mem.Allocator, raw: []const u8) ?[]const u8 {
    // Step 1: Strip trailing punctuation
    var end = raw.len;
    while (end > 0) {
        switch (raw[end - 1]) {
            '.', ',', ':', ';', '!', '?' => end -= 1,
            else => break,
        }
    }
    if (end == 0) return null;

    // Step 2: Strip :line[:col] suffix
    const after_strip = stripLineCol(raw[0..end]);
    if (after_strip.len == 0) return null;

    // Step 3: Unescape backslash-spaces
    var escaped_count: usize = 0;
    var i: usize = 0;
    while (i < after_strip.len) : (i += 1) {
        if (i + 1 < after_strip.len and after_strip[i] == '\\' and after_strip[i + 1] == ' ') {
            escaped_count += 1;
            i += 1;
        }
    }

    if (escaped_count == 0) {
        return alloc.dupe(u8, after_strip) catch return null;
    }

    const result = alloc.alloc(u8, after_strip.len - escaped_count) catch return null;
    var out: usize = 0;
    i = 0;
    while (i < after_strip.len) : (i += 1) {
        if (i + 1 < after_strip.len and after_strip[i] == '\\' and after_strip[i + 1] == ' ') {
            result[out] = ' ';
            out += 1;
            i += 1;
        } else {
            result[out] = after_strip[i];
            out += 1;
        }
    }
    return result[0..out];
}

/// Strips a trailing `:<digits>` suffix from a path.
fn stripTrailingDigitsAndColon(path: []const u8) []const u8 {
    var i = path.len;
    while (i > 0) {
        if (!std.ascii.isDigit(path[i - 1])) break;
        i -= 1;
    }
    if (i > 0 and i < path.len and path[i - 1] == ':') {
        return path[0 .. i - 1];
    }
    return path;
}

/// Strips a trailing `:<line>[:<col>]` suffix from a file path.
/// For example, "file.rb:42:10" becomes "file.rb".
fn stripLineCol(path: []const u8) []const u8 {
    const after_col = stripTrailingDigitsAndColon(path);
    return stripTrailingDigitsAndColon(after_col);
}

// ── Tests ──────────────────────────────────────────────────────────────

test "extract simple filename" {
    const r = extract(std.testing.allocator, "check README.md please", 6) orelse unreachable;
    defer std.testing.allocator.free(r.word);
    try std.testing.expectEqualStrings("README.md", r.word);
    try std.testing.expectEqual(@as(usize, 6), r.start);
    try std.testing.expectEqual(@as(usize, 15), r.end);
}

test "extract filename at start" {
    const r = extract(std.testing.allocator, "Makefile is here", 0) orelse unreachable;
    defer std.testing.allocator.free(r.word);
    try std.testing.expectEqualStrings("Makefile", r.word);
    try std.testing.expectEqual(@as(usize, 0), r.start);
}

test "extract filename at end" {
    const r = extract(std.testing.allocator, "edit .gitignore", 5) orelse unreachable;
    defer std.testing.allocator.free(r.word);
    try std.testing.expectEqualStrings(".gitignore", r.word);
}

test "extract dotfile" {
    const r = extract(std.testing.allocator, "see .env for config", 4) orelse unreachable;
    defer std.testing.allocator.free(r.word);
    try std.testing.expectEqualStrings(".env", r.word);
}

test "extract with line:col suffix" {
    const r = extract(std.testing.allocator, "error in file.rb:42:10 here", 9) orelse unreachable;
    defer std.testing.allocator.free(r.word);
    try std.testing.expectEqualStrings("file.rb", r.word);
}

test "extract with line suffix only" {
    const r = extract(std.testing.allocator, "see file.rb:52", 4) orelse unreachable;
    defer std.testing.allocator.free(r.word);
    try std.testing.expectEqualStrings("file.rb", r.word);
}

test "extract trailing period stripped" {
    const r = extract(std.testing.allocator, "Check README.md. Done.", 6) orelse unreachable;
    defer std.testing.allocator.free(r.word);
    try std.testing.expectEqualStrings("README.md", r.word);
}

test "extract backslash-escaped space" {
    const r = extract(std.testing.allocator, "open my\\ file.txt now", 5) orelse unreachable;
    defer std.testing.allocator.free(r.word);
    try std.testing.expectEqualStrings("my file.txt", r.word);
}

test "extract double-quoted filename" {
    const r = extract(std.testing.allocator, "open \"my file.txt\" now", 7) orelse unreachable;
    defer std.testing.allocator.free(r.word);
    try std.testing.expectEqualStrings("my file.txt", r.word);
}

test "extract single-quoted filename" {
    const r = extract(std.testing.allocator, "open 'my file.txt' now", 7) orelse unreachable;
    defer std.testing.allocator.free(r.word);
    try std.testing.expectEqualStrings("my file.txt", r.word);
}

test "extract returns null for space" {
    try std.testing.expect(extract(std.testing.allocator, "hello world", 5) == null);
}

test "extract returns null for empty" {
    try std.testing.expect(extract(std.testing.allocator, "", 0) == null);
}

test "extract returns null for out-of-bounds offset" {
    try std.testing.expect(extract(std.testing.allocator, "hello", 10) == null);
}

test "extract complex filename" {
    const r = extract(std.testing.allocator, "see my-component.test.tsx for details", 4) orelse unreachable;
    defer std.testing.allocator.free(r.word);
    try std.testing.expectEqualStrings("my-component.test.tsx", r.word);
}

test "extract cursor in middle of word" {
    const r = extract(std.testing.allocator, "edit README.md now", 10) orelse unreachable;
    defer std.testing.allocator.free(r.word);
    try std.testing.expectEqualStrings("README.md", r.word);
    try std.testing.expectEqual(@as(usize, 5), r.start);
    try std.testing.expectEqual(@as(usize, 14), r.end);
}

test "stripLineCol" {
    try std.testing.expectEqualStrings("file.rb", stripLineCol("file.rb"));
    try std.testing.expectEqualStrings("file.rb", stripLineCol("file.rb:52"));
    try std.testing.expectEqualStrings("file.rb", stripLineCol("file.rb:42:10"));
    try std.testing.expectEqualStrings("file.rb:", stripLineCol("file.rb:"));
    try std.testing.expectEqualStrings("", stripLineCol(""));
    try std.testing.expectEqualStrings("12345", stripLineCol("12345"));
}
