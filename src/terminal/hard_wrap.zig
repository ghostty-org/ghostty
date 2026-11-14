//! Rejoin lines that a program wrapped itself.
//!
//! Soft wraps (the terminal running out of columns) are already undone
//! by the formatter's `unwrap` option. Full-screen programs such as
//! coding agents lay out their own text instead: they break long lines
//! at the window width with a real newline and indent the continuation
//! with spaces. The terminal can't tell those breaks apart from real
//! ones, so a copied URL or command comes out split.
//!
//! `unwrap` guesses which breaks were made for wrapping, using only the
//! text and the window width, and joins them:
//!
//!   - The upper line must end at the right edge of the window, and the
//!     first word of the lower line must be too long to have fitted on
//!     it (the usual reflow test).
//!   - A blank line, a list item, or box-drawing borders on either side
//!     always stop a join.
//!   - The continuation indent is dropped. Words are joined with one
//!     space; a token longer than a whole line (a URL, a path, a long
//!     command) that was cut mid-way is joined with no space.
const std = @import("std");
const Allocator = std.mem.Allocator;
const unicode = @import("../unicode/main.zig");

pub const Options = struct {
    /// Width of the terminal in columns.
    cols: usize,

    /// Screen column where the first line of text starts. A selection
    /// can begin in the middle of a row, so its first line is shorter
    /// in the text than on screen.
    first_col: usize = 0,

    /// A line counts as reaching the right edge when it ends within this
    /// many columns of it. Programs often keep a small right margin.
    edge_slack: usize = 4,

    /// A line that ends more than this many columns short of the wrap
    /// width is never joined. Word wrapping only leaves that much room
    /// when the next word is huge, which is far more often an unrelated
    /// line (like a shell prompt) than a wrapped one.
    max_gap: usize = 16,
};

const Line = struct {
    /// The line without trailing whitespace.
    text: []const u8,

    /// Bytes of leading whitespace.
    indent_len: usize,

    /// Screen columns of leading whitespace (plus the first column).
    indent: usize,

    /// Screen column just past the last visible character.
    end: usize,

    fn content(self: Line) []const u8 {
        return self.text[self.indent_len..];
    }

    fn blank(self: Line) bool {
        return self.content().len == 0;
    }
};

/// Returns `text` with lines that look hard-wrapped joined back
/// together. The result is owned by the caller.
pub fn unwrap(
    alloc: Allocator,
    text: []const u8,
    opts: Options,
) Allocator.Error![]u8 {
    var lines: std.ArrayList(Line) = .empty;
    defer lines.deinit(alloc);

    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const start_col = if (lines.items.len == 0) opts.first_col else 0;
        try lines.append(alloc, measure(raw, start_col, opts.cols));
    }

    // The widest line approximates the width the program wrapped at.
    var widest: usize = 0;
    for (lines.items) |l| widest = @max(widest, l.end);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    for (lines.items, 0..) |cur, i| {
        if (i == 0) {
            try out.appendSlice(alloc, cur.text);
            continue;
        }

        const prev = lines.items[i - 1];
        switch (joinKind(prev, cur, widest, opts)) {
            .none => {
                try out.append(alloc, '\n');
                try out.appendSlice(alloc, cur.text);
            },
            .space => {
                try out.append(alloc, ' ');
                try out.appendSlice(alloc, cur.content());
            },
            .tight => try out.appendSlice(alloc, cur.content()),
        }
    }

    // Keep a trailing newline if the input had one: the loop above
    // turned it into an empty last line already.
    return try out.toOwnedSlice(alloc);
}

/// Joins only the lines where a single token (a URL, a path, a long
/// command) was cut by a hard wrap, removing the line break and the
/// indent around it. Used for finding links that an agent broke across
/// lines.
///
/// Returns null when nothing was joined. Otherwise returns the joined
/// text and fills `src` with the offset in `text` of every output byte,
/// so callers can map matches back to screen cells.
///
/// Blank cells may appear as NUL bytes (as in the renderer's screen
/// string) and are treated like spaces.
pub fn joinCutTokens(
    alloc: Allocator,
    text: []const u8,
    opts: Options,
    src: *std.ArrayList(usize),
) Allocator.Error!?[]u8 {
    // Find the byte ranges to skip: from the end of each upper line's
    // visible text up to the first visible byte of the line below.
    var gaps: std.ArrayList([2]usize) = .empty;
    defer gaps.deinit(alloc);

    var prev: ?Line = null;
    var prev_start: usize = 0;
    var line_start: usize = 0;
    while (line_start <= text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, line_start, '\n');
        const line_end = nl orelse text.len;
        const start_col = if (line_start == 0) opts.first_col else 0;
        const cur = measure(text[line_start..line_end], start_col, opts.cols);

        if (prev) |p| if (cutToken(p, cur, opts)) {
            try gaps.append(alloc, .{
                prev_start + p.text.len,
                line_start + cur.indent_len,
            });
        };

        prev = cur;
        prev_start = line_start;
        line_start = (nl orelse break) + 1;
    }

    if (gaps.items.len == 0) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    src.clearRetainingCapacity();

    var i: usize = 0;
    for (gaps.items) |gap| {
        try out.appendSlice(alloc, text[i..gap[0]]);
        for (i..gap[0]) |j| try src.append(alloc, j);
        i = gap[1];
    }
    try out.appendSlice(alloc, text[i..]);
    for (i..text.len) |j| try src.append(alloc, j);

    return try out.toOwnedSlice(alloc);
}

/// True if the break between `prev` and `cur` cut a single token in
/// two. Word wrapping moves a word that fits to the next line whole, so
/// a token is only cut when it is longer than a full line.
fn cutToken(prev: Line, cur: Line, opts: Options) bool {
    if (prev.blank() or cur.blank()) return false;
    if (prev.end + opts.edge_slack < opts.cols) return false;
    if (isBoxChar(lastCodepoint(prev.text)) or
        isBoxChar(firstCodepoint(cur.content()))) return false;

    const last_word = lastToken(prev.content());
    const next_word = firstToken(cur.content());
    if (last_word.len == 0 or next_word.len == 0) return false;

    // The upper line ends at the edge, so its end is the wrap width.
    const line_width = prev.end -| cur.indent;
    return width(last_word) + width(next_word) > line_width;
}

const Join = enum { none, space, tight };

fn joinKind(prev: Line, cur: Line, widest: usize, opts: Options) Join {
    if (prev.blank() or cur.blank()) return .none;

    // The block has to be wrapped near the window width. Individual
    // lines can end well short of it when the next word is long, so
    // the reflow test below decides for each line.
    if (widest + opts.edge_slack < opts.cols) return .none;

    // Structure that must keep its own lines.
    if (startsStructure(cur.content())) return .none;
    if (isBoxChar(lastCodepoint(prev.text)) or
        isBoxChar(firstCodepoint(cur.content()))) return .none;

    // Reflow test: if the next word would have fitted after the upper
    // line, the program would have put it there, so this break is real.
    const next_word = firstToken(cur.content());
    if (prev.end + 1 + width(next_word) <= widest) return .none;
    if (prev.end + opts.max_gap < widest) return .none;

    // A token longer than a whole line was cut mid-way.
    if (prev.end >= widest and cutToken(prev, cur, opts)) return .tight;

    return .space;
}

fn measure(raw: []const u8, start_col: usize, cols: usize) Line {
    const text = std.mem.trimEnd(u8, raw, blank_bytes ++ "\r");
    var indent_len: usize = 0;
    while (indent_len < text.len and
        std.mem.indexOfScalar(u8, blank_bytes, text[indent_len]) != null) indent_len += 1;
    return .{
        .text = text,
        .indent_len = indent_len,
        .indent = start_col + indent_len,
        .end = lastRowEnd(start_col + width(text), cols),
    };
}

/// A line longer than the window was wrapped by the terminal and spans
/// several rows. What matters for joining is where its last row ends.
fn lastRowEnd(end: usize, cols: usize) usize {
    if (cols == 0 or end <= cols) return end;
    return (end - 1) % cols + 1;
}

/// Lines that start a list item, heading, or quote.
fn startsStructure(s: []const u8) bool {
    if (s.len == 0) return false;

    // Bullets: "- ", "* ", "+ ", "• ".
    for ([_][]const u8{ "- ", "* ", "+ ", "• ", "> ", "# " }) |p| {
        if (std.mem.startsWith(u8, s, p)) return true;
    }

    // Numbered items: "1. " or "1) ".
    var n: usize = 0;
    while (n < s.len and std.ascii.isDigit(s[n])) n += 1;
    if (n > 0 and n + 1 < s.len and
        (s[n] == '.' or s[n] == ')') and s[n + 1] == ' ') return true;

    return false;
}

fn isBoxChar(cp: ?u21) bool {
    const c = cp orelse return false;
    return c >= 0x2500 and c <= 0x257F;
}

fn firstCodepoint(s: []const u8) ?u21 {
    var view = std.unicode.Utf8View.init(s) catch return null;
    var it = view.iterator();
    return it.nextCodepoint();
}

fn lastCodepoint(s: []const u8) ?u21 {
    if (s.len == 0) return null;
    var i = s.len - 1;
    while (i > 0 and (s[i] & 0xC0) == 0x80) i -= 1;
    return std.unicode.utf8Decode(s[i..]) catch null;
}

/// Bytes that stand for an empty cell. NUL is how the renderer's
/// screen string writes cells that were never printed to.
const blank_bytes = " \t\x00";

fn firstToken(s: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, s, blank_bytes) orelse s.len;
    return s[0..end];
}

fn lastToken(s: []const u8) []const u8 {
    const start = if (std.mem.lastIndexOfAny(u8, s, blank_bytes)) |i| i + 1 else 0;
    return s[start..];
}

/// Display width in terminal columns.
fn width(s: []const u8) usize {
    var view = std.unicode.Utf8View.init(s) catch return s.len;
    var it = view.iterator();
    var w: usize = 0;
    var prev_wide = false;
    while (it.nextCodepoint()) |cp| {
        // A NUL is one empty cell, except right after a wide character,
        // where it is the second half of that character.
        const cw: usize = if (cp == 0) @intFromBool(!prev_wide) else unicode.codepointWidth(cp);
        prev_wide = cw == 2;
        w += cw;
    }
    return w;
}

fn testUnwrap(input: []const u8, opts: Options, expected: []const u8) !void {
    const alloc = std.testing.allocator;
    const out = try unwrap(alloc, input, opts);
    defer alloc.free(out);
    try std.testing.expectEqualStrings(expected, out);
}

test "hard_wrap: paragraph wrapped by an agent is joined" {
    // 30 columns, two-space continuation indent like Claude Code.
    try testUnwrap(
        "⏺ The quick brown fox jumps\n" ++
            "  over the lazy dog and keeps\n" ++
            "  running.",
        .{ .cols = 30 },
        "⏺ The quick brown fox jumps over the lazy dog and keeps running.",
    );
}

test "hard_wrap: URL cut mid-way is joined without a space" {
    try testUnwrap(
        "  https://example.com/a/very/lo\n" ++
            "  ng/path/to/some/file.html",
        .{ .cols = 32 },
        "  https://example.com/a/very/long/path/to/some/file.html",
    );
}

test "hard_wrap: URL after words on the same line" {
    try testUnwrap(
        "  Open https://example.com/abc\n" ++
            "  defghijklmnopqrstuvwxyz01234\n" ++
            "  56 to see it.",
        .{ .cols = 30 },
        "  Open https://example.com/abcdefghijklmnopqrstuvwxyz0123456 to see it.",
    );
}

test "hard_wrap: short lines are left alone" {
    try testUnwrap(
        "hello world\nbye\n",
        .{ .cols = 80 },
        "hello world\nbye\n",
    );
}

test "hard_wrap: line near the edge with a short next word" {
    // The first line shows the wrap width is 29. "fi" would have
    // fitted after "here", so that break is real.
    try testUnwrap(
        "  aaaa bbbb cccc dddd eeee fff\n\n  echo something long here\n  fi",
        .{ .cols = 30 },
        "  aaaa bbbb cccc dddd eeee fff\n\n  echo something long here\n  fi",
    );
}

test "hard_wrap: blank lines and list items stop joins" {
    try testUnwrap(
        "  aaaa bbbb cccc dddd eeee ff\n" ++
            "  - item one\n" ++
            "\n" ++
            "  next paragraph",
        .{ .cols = 30 },
        "  aaaa bbbb cccc dddd eeee ff\n" ++
            "  - item one\n" ++
            "\n" ++
            "  next paragraph",
    );
}

test "hard_wrap: box borders are kept" {
    try testUnwrap(
        "│ some text inside a box   │\n" ++
            "│ more text inside the box │",
        .{ .cols = 28 },
        "│ some text inside a box   │\n" ++
            "│ more text inside the box │",
    );
}

test "hard_wrap: selection starting mid-row" {
    // The first line starts at column 10 on screen.
    try testUnwrap(
        "brown fox jumps\n  over the lazy dog",
        .{ .cols = 27, .first_col = 10 },
        "brown fox jumps over the lazy dog",
    );
}

fn testJoinCut(input: []const u8, opts: Options, expected: ?[]const u8) !void {
    const alloc = std.testing.allocator;
    var src: std.ArrayList(usize) = .empty;
    defer src.deinit(alloc);
    const out = try joinCutTokens(alloc, input, opts, &src);
    defer if (out) |o| alloc.free(o);
    if (expected) |e| {
        try std.testing.expectEqualStrings(e, out.?);
        try std.testing.expectEqual(out.?.len, src.items.len);
        for (out.?, src.items) |c, j| try std.testing.expectEqual(input[j], c);
    } else {
        try std.testing.expect(out == null);
    }
}

test "hard_wrap: joinCutTokens joins a cut URL only" {
    try testJoinCut(
        "  see the docs\n" ++
            "  https://example.com/a/very/lo\n" ++
            "  ng/path/to/some/file.html and\n" ++
            "  more text",
        .{ .cols = 32 },
        "  see the docs\n" ++
            "  https://example.com/a/very/long/path/to/some/file.html and\n" ++
            "  more text",
    );
}

test "hard_wrap: joinCutTokens leaves word wraps alone" {
    try testJoinCut(
        "  The quick brown fox jumps\n  over the lazy dog",
        .{ .cols = 28 },
        null,
    );
}

test "hard_wrap: joinCutTokens with NUL cells" {
    // Renderer rows are padded to the full width with NUL cells.
    try testJoinCut(
        "\x00\x00https://example.com/abcdefgh\n" ++
            "\x00\x00ijkl\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\n",
        .{ .cols = 30 },
        "\x00\x00https://example.com/abcdefghijkl\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\n",
    );
}

test "hard_wrap: prose with lines ending short of the edge" {
    // Real word wrapping at 40 columns: some lines end several columns
    // early because the next word was long.
    try testUnwrap(
        "  This paragraph was wrapped by the\n" ++
            "  program itself, so every line ends\n" ++
            "  with a real newline. Copy it with\n" ++
            "  Cmd+Shift+C and it should come out as\n" ++
            "  one line, while Cmd+C keeps the\n" ++
            "  breaks exactly as shown on screen.",
        .{ .cols = 40 },
        "  This paragraph was wrapped by the program itself, so every line " ++
            "ends with a real newline. Copy it with Cmd+Shift+C and it should " ++
            "come out as one line, while Cmd+C keeps the breaks exactly as " ++
            "shown on screen.",
    );
}

test "hard_wrap: line wrapped by the terminal does not skew the width" {
    // The first line is a long shell command the terminal wrapped
    // itself (one line in the copied text, 2+ rows on screen). It must
    // not be glued to the output, and the output must still join.
    try testUnwrap(
        "% clear; sh /a/very/long/path/to/some/script/wrap-test.sh\n" ++
            "  This paragraph was wrapped by the tool\n" ++
            "  itself, honestly.",
        .{ .cols = 40 },
        "% clear; sh /a/very/long/path/to/some/script/wrap-test.sh\n" ++
            "  This paragraph was wrapped by the tool itself, honestly.",
    );
}

test "hard_wrap: short line before a long word is not joined" {
    // "Last login" ends far from the edge; the prompt below only
    // passes the reflow test because its first word is very long.
    try testUnwrap(
        "Last login: Sun Nov 15 on ttys007\n" ++
            "user@a-very-long-host-name-here-x ~ % ls\n" ++
            "  Some wrapped output that runs nearly to the edge\n" ++
            "  of the window.",
        .{ .cols = 52 },
        "Last login: Sun Nov 15 on ttys007\n" ++
            "user@a-very-long-host-name-here-x ~ % ls\n" ++
            "  Some wrapped output that runs nearly to the edge of the window.",
    );
}
