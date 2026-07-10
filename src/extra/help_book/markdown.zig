//! Minimal markdown-to-HTML renderer for the Apple Help Book.
//!
//! This converts the pandoc-flavored markdown used by the in-repo docs
//! (src/build/mdgen/*.md) and the config/keybind doc comments (via
//! help_strings) into plain HTML: headings with website-compatible
//! anchor ids, fenced and indented code blocks, lists, GFM tables,
//! definition lists, blockquotes with GitHub `[!NOTE]`/`[!WARNING]`
//! callouts, "Note:"/"Warning:" callout paragraphs, and inline
//! code/strong/emphasis/links/autolinks. It is NOT a general markdown
//! renderer.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn render(alloc: Allocator, w: *std.Io.Writer, source: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var lines: std.ArrayList([]const u8) = .empty;
    var iter = std.mem.splitScalar(u8, source, '\n');
    while (iter.next()) |line| {
        // Skip the pandoc title line (% GHOSTTY(5) ...).
        if (lines.items.len == 0 and std.mem.startsWith(u8, line, "% GHOSTTY(")) continue;
        try lines.append(arena, line);
    }

    var r: Renderer = .{
        .arena = arena,
        .w = w,
        .slug_counts = .init(arena),
    };
    var i: usize = 0;
    while (i < lines.items.len) i = try r.renderBlock(lines.items, i);
}

const Renderer = struct {
    arena: Allocator,
    w: *std.Io.Writer,
    slug_counts: std.StringHashMap(usize),

    fn renderBlock(self: *Renderer, lines: []const []const u8, start: usize) anyerror!usize {
        const w = self.w;
        const line = lines[start];
        const trimmed = std.mem.trim(u8, line, " ");

        // Blank line
        if (trimmed.len == 0) return start + 1;

        // Fenced code block
        if (std.mem.startsWith(u8, trimmed, "```")) {
            try w.writeAll("<pre><code>");
            var i = start + 1;
            while (i < lines.len) : (i += 1) {
                if (std.mem.startsWith(u8, std.mem.trim(u8, lines[i], " "), "```")) break;
                try writeEscaped(w, lines[i]);
                try w.writeByte('\n');
            }
            try w.writeAll("</code></pre>\n");
            return @min(i + 1, lines.len);
        }

        // Indented code block (4 spaces). Blank lines continue the block
        // as long as more indented content follows.
        if (std.mem.startsWith(u8, line, "    ")) {
            try w.writeAll("<pre><code>");
            var i = start;
            while (i < lines.len) : (i += 1) {
                if (std.mem.startsWith(u8, lines[i], "    ")) {
                    try writeEscaped(w, lines[i][4..]);
                    try w.writeByte('\n');
                    continue;
                }
                if (std.mem.trim(u8, lines[i], " ").len > 0) break;

                // Blank: only continue when more indented content follows.
                var j = i + 1;
                while (j < lines.len and std.mem.trim(u8, lines[j], " ").len == 0) j += 1;
                if (j >= lines.len or !std.mem.startsWith(u8, lines[j], "    ")) break;
                try w.writeByte('\n');
            }
            try w.writeAll("</code></pre>\n");
            return i;
        }

        // ATX heading. The page provides its own <h1> title, so markdown
        // heading levels are shifted down by one.
        if (line[0] == '#') {
            var level: usize = 0;
            while (level < line.len and line[level] == '#') level += 1;
            if (level <= 5 and level < line.len and line[level] == ' ') {
                const text = std.mem.trim(u8, line[level + 1 ..], " ");
                const id = try self.headingId(text);
                try w.print("<h{d} id=\"{s}\">", .{ level + 1, id });
                try self.writeInline(text);
                try w.print("</h{d}>\n", .{level + 1});
                return start + 1;
            }
        }

        // Horizontal rule
        if (std.mem.eql(u8, trimmed, "---") or std.mem.eql(u8, trimmed, "***")) {
            try w.writeAll("<hr>\n");
            return start + 1;
        }

        // Blockquote. A GitHub-style `[!NOTE]`/`[!WARNING]` marker on the
        // first line turns the quote into the same styled callout as a
        // "Note:"/"Warning:" paragraph.
        if (trimmed[0] == '>') {
            var text: std.ArrayList(u8) = .empty;
            var class: ?[]const u8 = null;
            var i = start;
            while (i < lines.len) : (i += 1) {
                var t = std.mem.trim(u8, lines[i], " ");
                if (t.len == 0 or t[0] != '>') break;
                t = std.mem.trimLeft(u8, t[1..], " ");
                if (i == start) {
                    if (std.mem.eql(u8, t, "[!NOTE]")) {
                        class = "note";
                        continue;
                    }
                    if (std.mem.eql(u8, t, "[!WARNING]")) {
                        class = "warning";
                        continue;
                    }
                }
                if (text.items.len > 0) try text.append(self.arena, '\n');
                try text.appendSlice(self.arena, t);
            }
            if (class) |c| {
                try w.print("<div class=\"{s}\"><p>", .{c});
                try self.writeInline(text.items);
                try w.writeAll("</p></div>\n");
            } else {
                try w.writeAll("<blockquote><p>");
                try self.writeInline(text.items);
                try w.writeAll("</p></blockquote>\n");
            }
            return i;
        }

        // GFM table
        if (trimmed[0] == '|') return try self.renderTable(lines, start);

        // Definition (pandoc definition list): a `: ` line following a term
        // paragraph. Rendered as an indented paragraph.
        if (std.mem.startsWith(u8, trimmed, ": ") or std.mem.eql(u8, trimmed, ":")) {
            var text: std.ArrayList(u8) = .empty;
            var i = start;
            while (i < lines.len) : (i += 1) {
                var t = std.mem.trim(u8, lines[i], " ");
                if (t.len == 0) break;
                if (std.mem.startsWith(u8, t, ": ")) t = std.mem.trimLeft(u8, t[2..], " ");
                if (i > start) try text.append(self.arena, '\n');
                try text.appendSlice(self.arena, t);
            }
            try w.writeAll("<p class=\"def\">");
            try self.writeInline(text.items);
            try w.writeAll("</p>\n");
            return i;
        }

        // List
        if (listItem(line) != null) return try self.renderList(lines, start);

        // Paragraph: consume until a blank line or structural element.
        // Lines are joined before inline rendering so that emphasis and
        // links can span line breaks. A paragraph starting with "Note:"
        // or "Warning:" (the doc comment callout convention) becomes a
        // styled callout with the prefix stripped.
        const callout: ?[]const u8 = if (std.ascii.startsWithIgnoreCase(trimmed, "note:"))
            "note"
        else if (std.ascii.startsWithIgnoreCase(trimmed, "warning:"))
            "warning"
        else
            null;

        var text: std.ArrayList(u8) = .empty;
        var i = start;
        while (i < lines.len) : (i += 1) {
            var t = std.mem.trim(u8, lines[i], " ");
            if (t.len == 0) break;
            if (i > start) {
                // An indented line continues the paragraph (a hanging
                // indent); indented code cannot interrupt a paragraph.
                if (t[0] == '#' or t[0] == '|' or t[0] == ':' or t[0] == '>' or
                    std.mem.startsWith(u8, t, "```") or
                    listItem(lines[i]) != null) break;
                try text.append(self.arena, '\n');
            } else if (callout) |class| {
                // The class name plus ':' is the matched prefix length.
                t = std.mem.trimLeft(u8, t[class.len + 1 ..], " ");
            }
            try text.appendSlice(self.arena, t);
        }
        if (callout) |class| {
            try w.print("<div class=\"{s}\"><p>", .{class});
            try self.writeInline(text.items);
            try w.writeAll("</p></div>\n");
        } else {
            try w.writeAll("<p>");
            try self.writeInline(text.items);
            try w.writeAll("</p>\n");
        }
        return i;
    }

    const ListItem = struct {
        indent: usize,
        ordered: bool,
        text: []const u8,
    };

    /// Parse a list item marker: `- `, `* `, or `1. ` after any indent.
    fn listItem(line: []const u8) ?ListItem {
        const indent = line.len - std.mem.trimLeft(u8, line, " ").len;
        const rest = line[indent..];
        if (rest.len >= 2 and (rest[0] == '-' or rest[0] == '*') and rest[1] == ' ')
            return .{ .indent = indent, .ordered = false, .text = rest[2..] };
        var d: usize = 0;
        while (d < rest.len and std.ascii.isDigit(rest[d])) d += 1;
        if (d > 0 and d + 1 < rest.len and rest[d] == '.' and rest[d + 1] == ' ')
            return .{ .indent = indent, .ordered = true, .text = rest[d + 2 ..] };
        return null;
    }

    fn renderList(self: *Renderer, lines: []const []const u8, start: usize) !usize {
        const w = self.w;

        const Level = struct { indent: usize, ordered: bool };
        var stack: std.ArrayList(Level) = .empty;
        defer stack.deinit(self.arena);

        // Item text and its continuation lines are accumulated and
        // rendered in a single writeInline call when the item (or an
        // inner paragraph) ends, so inline spans can wrap across lines.
        var text: std.ArrayList(u8) = .empty;
        var text_para = false;
        var pending_blank = false;

        var i = start;
        while (i < lines.len) : (i += 1) {
            const line = lines[i];
            const trimmed = std.mem.trim(u8, line, " ");

            if (trimmed.len == 0) {
                pending_blank = true;
                continue;
            }

            if (listItem(line)) |item| {
                try self.flushListText(&text, text_para);
                text_para = false;
                pending_blank = false;

                // Close levels deeper than this item, and a same-level list
                // of the other kind (ordered vs. unordered).
                while (stack.items.len > 0 and
                    (stack.items[stack.items.len - 1].indent > item.indent or
                        (stack.items[stack.items.len - 1].indent == item.indent and
                            stack.items[stack.items.len - 1].ordered != item.ordered)))
                {
                    const lvl = stack.pop().?;
                    try w.writeAll(if (lvl.ordered) "</li>\n</ol>\n" else "</li>\n</ul>\n");
                }

                if (stack.items.len == 0 or
                    item.indent > stack.items[stack.items.len - 1].indent)
                {
                    // Open a new (possibly nested) level.
                    try stack.append(self.arena, .{
                        .indent = item.indent,
                        .ordered = item.ordered,
                    });
                    try w.writeAll(if (item.ordered) "<ol>\n<li>" else "<ul>\n<li>");
                } else {
                    // Sibling item at the current level.
                    try w.writeAll("</li>\n<li>");
                }
                try text.appendSlice(self.arena, item.text);
                continue;
            }

            // Continuation line: must be indented past the item marker.
            const indent = line.len - std.mem.trimLeft(u8, line, " ").len;
            if (stack.items.len > 0 and
                indent >= stack.items[stack.items.len - 1].indent + 2)
            {
                if (pending_blank) {
                    try self.flushListText(&text, text_para);
                    text_para = true;
                    pending_blank = false;
                } else if (text.items.len > 0) {
                    try text.append(self.arena, '\n');
                }
                try text.appendSlice(self.arena, trimmed);
                continue;
            }

            break;
        }

        try self.flushListText(&text, text_para);
        while (stack.items.len > 0) {
            const lvl = stack.pop().?;
            try w.writeAll(if (lvl.ordered) "</li>\n</ol>\n" else "</li>\n</ul>\n");
        }
        return i;
    }

    /// Render the pending item or continuation text of renderList, as a
    /// nested paragraph when it followed a blank line within its item.
    fn flushListText(self: *Renderer, text: *std.ArrayList(u8), para: bool) !void {
        if (text.items.len == 0) return;
        if (para) {
            try self.w.writeAll("\n<p>");
            try self.writeInline(text.items);
            try self.w.writeAll("</p>");
        } else {
            try self.writeInline(text.items);
        }
        text.clearRetainingCapacity();
    }

    fn renderTable(self: *Renderer, lines: []const []const u8, start: usize) !usize {
        const w = self.w;
        try w.writeAll("<table>\n");
        var i = start;
        var row: usize = 0;
        while (i < lines.len) : (i += 1) {
            const trimmed = std.mem.trim(u8, lines[i], " ");
            if (trimmed.len == 0 or trimmed[0] != '|') break;

            // The separator row (|---|---|) is implied.
            if (row == 1) {
                row += 1;
                continue;
            }

            const tag = if (row == 0) "th" else "td";
            try w.writeAll("<tr>");
            var cells = std.mem.splitScalar(u8, std.mem.trim(u8, trimmed, "|"), '|');
            while (cells.next()) |cell| {
                try w.print("<{s}>", .{tag});
                try self.writeInline(std.mem.trim(u8, cell, " "));
                try w.print("</{s}>", .{tag});
            }
            try w.writeAll("</tr>\n");
            row += 1;
        }
        try w.writeAll("</table>\n");
        return i;
    }

    /// Generate a heading anchor id compatible with the website's
    /// remark-heading-ids plugin: lowercased, slugified, de-duplicated
    /// with a numeric suffix starting at 2.
    fn headingId(self: *Renderer, text: []const u8) ![]const u8 {
        var slug: std.ArrayList(u8) = .empty;
        var last_dash = true; // avoid a leading dash
        for (text) |c| {
            const lower = std.ascii.toLower(c);
            if (std.ascii.isAlphanumeric(lower) or lower == '_' or lower == '.') {
                try slug.append(self.arena, lower);
                last_dash = false;
            } else if ((c == ' ' or c == '-') and !last_dash) {
                try slug.append(self.arena, '-');
                last_dash = true;
            }
        }
        while (slug.items.len > 0 and slug.items[slug.items.len - 1] == '-')
            _ = slug.pop();

        const base = try slug.toOwnedSlice(self.arena);
        const gop = try self.slug_counts.getOrPut(base);
        if (!gop.found_existing) {
            gop.value_ptr.* = 1;
            return base;
        }
        gop.value_ptr.* += 1;
        return try std.fmt.allocPrint(self.arena, "{s}-{d}", .{ base, gop.value_ptr.* });
    }

    /// Render inline markdown: `code`, **strong**, _emphasis_/*emphasis*,
    /// [text](href), <https://...> autolinks, and backslash escapes.
    fn writeInline(self: *Renderer, s: []const u8) anyerror!void {
        const w = self.w;
        var i: usize = 0;
        while (i < s.len) {
            const c = s[i];

            if (c == '\\' and i + 1 < s.len) {
                try writeEscapedByte(w, s[i + 1]);
                i += 2;
                continue;
            }

            // Code span: opens with a run of N backticks and closes with a
            // matching run (CommonMark), so literal backticks can appear
            // inside, e.g. `` Cmd+` ``.
            if (c == '`') code: {
                var open: usize = 1;
                while (i + open < s.len and s[i + open] == '`') open += 1;
                var search = i + open;
                const end = while (std.mem.indexOfScalarPos(u8, s, search, '`')) |cand| {
                    var run: usize = 1;
                    while (cand + run < s.len and s[cand + run] == '`') run += 1;
                    if (run == open) break cand;
                    search = cand + run;
                } else break :code;
                var content = s[i + open .. end];
                // One space of padding is stripped so the content can
                // start or end with a backtick (CommonMark).
                if (content.len >= 2 and content[0] == ' ' and
                    content[content.len - 1] == ' ' and
                    std.mem.trim(u8, content, " ").len > 0)
                    content = content[1 .. content.len - 1];
                try w.writeAll("<code>");
                try writeEscaped(w, content);
                try w.writeAll("</code>");
                i = end + open;
                continue;
            }

            if (c == '*' and i + 1 < s.len and s[i + 1] == '*') {
                if (std.mem.indexOfPos(u8, s, i + 2, "**")) |end| {
                    try w.writeAll("<strong>");
                    try self.writeInline(s[i + 2 .. end]);
                    try w.writeAll("</strong>");
                    i = end + 2;
                    continue;
                }
            }

            if ((c == '*' or c == '_') and i + 1 < s.len and s[i + 1] != ' ' and
                // An underscore inside a word is literal, not emphasis.
                !(c == '_' and i > 0 and std.ascii.isAlphanumeric(s[i - 1])))
            emph: {
                var search = i + 1;
                const end = while (std.mem.indexOfScalarPos(u8, s, search, c)) |cand| {
                    // Empty emphasis is not emphasis (e.g. a stray "**").
                    if (cand == i + 1) {
                        search = cand + 1;
                        continue;
                    }
                    if (s[cand - 1] == ' ') break :emph;
                    // Skip intraword underscores when looking for the
                    // closing marker.
                    if (c == '_' and cand + 1 < s.len and
                        std.ascii.isAlphanumeric(s[cand + 1]))
                    {
                        search = cand + 1;
                        continue;
                    }
                    break cand;
                } else break :emph;
                try w.writeAll("<em>");
                try self.writeInline(s[i + 1 .. end]);
                try w.writeAll("</em>");
                i = end + 1;
                continue;
            }

            if (c == '[') link: {
                const text_end = std.mem.indexOfScalarPos(u8, s, i + 1, ']') orelse break :link;
                if (text_end + 1 >= s.len or s[text_end + 1] != '(') break :link;
                const href_end = std.mem.indexOfScalarPos(u8, s, text_end + 2, ')') orelse break :link;
                try w.writeAll("<a href=\"");
                try self.rewriteHref(s[text_end + 2 .. href_end]);
                try w.writeAll("\">");
                try self.writeInline(s[i + 1 .. text_end]);
                try w.writeAll("</a>");
                i = href_end + 1;
                continue;
            }

            // Autolink: <https://example.com>
            if (c == '<' and (std.mem.startsWith(u8, s[i..], "<http") or
                std.mem.startsWith(u8, s[i..], "<mailto:")))
            {
                if (std.mem.indexOfScalarPos(u8, s, i + 1, '>')) |end| {
                    const url = s[i + 1 .. end];
                    try w.writeAll("<a href=\"");
                    try writeEscaped(w, url);
                    try w.writeAll("\">");
                    try writeEscaped(w, url);
                    try w.writeAll("</a>");
                    i = end + 1;
                    continue;
                }
            }

            try writeEscapedByte(w, c);
            i += 1;
        }
    }

    /// Rewrite an internal website link to its help book equivalent:
    /// generated reference anchors map to the option./action. pages and
    /// other absolute website paths become ghostty.org URLs.
    fn rewriteHref(self: *Renderer, href: []const u8) !void {
        const w = self.w;

        if (std.mem.startsWith(u8, href, "/docs/config/reference#")) {
            try w.print("option.{s}.html", .{href["/docs/config/reference#".len..]});
            return;
        }
        if (std.mem.startsWith(u8, href, "/docs/config/keybind/reference#")) {
            try w.print("action.{s}.html", .{href["/docs/config/keybind/reference#".len..]});
            return;
        }
        if (href.len > 0 and href[0] == '/') {
            try w.writeAll("https://ghostty.org");
            try writeEscaped(w, href);
            return;
        }
        try writeEscaped(w, href);
    }
};

/// Write the string with HTML special characters escaped, including double
/// quotes so this is safe in attribute values too.
pub fn writeEscaped(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| try writeEscapedByte(w, c);
}

/// Write a single byte HTML-escaped. Control characters that are invalid
/// in HTML (all but tab, LF, CR) are skipped.
pub fn writeEscapedByte(w: *std.Io.Writer, c: u8) !void {
    switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\t', '\n', '\r' => try w.writeByte(c),
        0...8, 11, 12, 14...31 => {},
        else => try w.writeByte(c),
    }
}

test "markdown blocks" {
    const testing = std.testing;

    var stream: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stream.deinit();

    try render(testing.allocator, &stream.writer,
        \\% GHOSTTY(5) Version @@VERSION@@ | Title line
        \\
        \\# NAME
        \\
        \\A paragraph with `code` and a [link](/docs/config/reference#font-size).
        \\
        \\    indented = code <block>
        \\
        \\    more
        \\
        \\| A | B |
        \\|---|---|
        \\| 1 | 2 |
    );

    const out = stream.written();
    try testing.expect(std.mem.indexOf(u8, out, "GHOSTTY(5)") == null);
    try testing.expect(std.mem.indexOf(u8, out, "<h2 id=\"name\">NAME</h2>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<a href=\"option.font-size.html\">link</a>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<pre><code>indented = code &lt;block&gt;\n\nmore\n</code></pre>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<tr><th>A</th><th>B</th></tr>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<tr><td>1</td><td>2</td></tr>") != null);
}

test "markdown definitions and inlines" {
    const testing = std.testing;

    var stream: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stream.deinit();

    try render(testing.allocator, &stream.writer,
        \\_\$XDG_CONFIG_HOME/ghostty/config_
        \\
        \\: **On macOS**, see <https://example.com> for details
        \\that wrap onto more lines.
    );

    var stream2: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stream2.deinit();
    try render(testing.allocator, &stream2.writer,
        \\**A strong span that
        \\wraps across lines.** Trailing text.
    );
    try testing.expect(std.mem.indexOf(
        u8,
        stream2.written(),
        "<p><strong>A strong span that\nwraps across lines.</strong> Trailing text.</p>",
    ) != null);

    const out = stream.written();
    try testing.expect(std.mem.indexOf(u8, out, "<p><em>$XDG_CONFIG_HOME/ghostty/config</em></p>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<p class=\"def\"><strong>On macOS</strong>, see <a href=\"https://example.com\">https://example.com</a> for details\nthat wrap onto more lines.</p>") != null);
}

test "markdown doc comment with callout" {
    const testing = std.testing;

    var stream: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stream.deinit();

    try render(testing.allocator, &stream.writer,
        \\Some `text` that is **bold**.
        \\
        \\    code = here
        \\
        \\Warning: careful.
        \\
        \\  - `a`
        \\
        \\    One thing.
        \\
        \\  - b two
        \\
        \\Done.
    );
    try testing.expectEqualStrings(
        "<p>Some <code>text</code> that is <strong>bold</strong>.</p>\n" ++
            "<pre><code>code = here\n</code></pre>\n" ++
            "<div class=\"warning\"><p>careful.</p></div>\n" ++
            "<ul>\n<li><code>a</code>\n<p>One thing.</p></li>\n<li>b two</li>\n</ul>\n" ++
            "<p>Done.</p>\n",
        stream.written(),
    );
}

test "markdown writeEscaped" {
    const testing = std.testing;

    var stream: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stream.deinit();

    try writeEscaped(&stream.writer, "a & <b> \"q\"\x07");
    try testing.expectEqualStrings("a &amp; &lt;b&gt; &quot;q&quot;", stream.written());
}

test "markdown blockquote callouts" {
    const testing = std.testing;

    var stream: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stream.deinit();

    try render(testing.allocator, &stream.writer,
        \\> [!NOTE]
        \\> The exact behavior of each option may differ across
        \\> compositors -- experiment with them!
        \\
        \\> A plain quote.
    );

    const out = stream.written();
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "<div class=\"note\"><p>The exact behavior of each option may differ across\ncompositors -- experiment with them!</p></div>\n",
    ) != null);
    try testing.expect(std.mem.indexOf(u8, out, "<blockquote><p>A plain quote.</p></blockquote>\n") != null);
    try testing.expect(std.mem.indexOf(u8, out, "[!NOTE]") == null);
}

test "markdown code spans with literal backticks" {
    const testing = std.testing;

    var stream: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stream.deinit();

    try render(testing.allocator, &stream.writer,
        \\Toggle by pressing `` Cmd+` `` anywhere.
        \\
        \\Default: ``\t '"│`|:;,()[]{}<>$``
    );

    const out = stream.written();
    try testing.expect(std.mem.indexOf(u8, out, "<p>Toggle by pressing <code>Cmd+`</code> anywhere.</p>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<p>Default: <code>\\t '&quot;│`|:;,()[]{}&lt;&gt;$</code></p>") != null);
}

test "markdown code span across list continuation lines" {
    const testing = std.testing;

    var stream: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stream.deinit();

    try render(testing.allocator, &stream.writer,
        \\  * `--cache=<bool>`: to reinstall a single
        \\    host, prefer `ghostty +ssh-cache
        \\    --remove=<host>` followed by a connection.
    );

    try testing.expect(std.mem.indexOf(
        u8,
        stream.written(),
        "<li><code>--cache=&lt;bool&gt;</code>: to reinstall a single\n" ++
            "host, prefer <code>ghostty +ssh-cache\n--remove=&lt;host&gt;</code> followed by a connection.</li>",
    ) != null);
}

test "markdown hanging indent continues a paragraph" {
    const testing = std.testing;

    var stream: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stream.deinit();

    try render(testing.allocator, &stream.writer,
        \\macOS: To hide the titlebar without removing the native window borders
        \\       or rounded corners, use `macos-titlebar-style = hidden` instead.
    );

    const out = stream.written();
    try testing.expect(std.mem.indexOf(u8, out, "<pre>") == null);
    try testing.expect(std.mem.indexOf(
        u8,
        out,
        "borders\nor rounded corners, use <code>macos-titlebar-style = hidden</code> instead.",
    ) != null);
}

test "markdown lists" {
    const testing = std.testing;

    var stream: std.Io.Writer.Allocating = .init(testing.allocator);
    defer stream.deinit();

    try render(testing.allocator, &stream.writer,
        \\- one
        \\  - nested
        \\- two
        \\
        \\1. first
        \\2. second
    );

    const out = stream.written();
    try testing.expect(std.mem.indexOf(u8, out, "<ul>\n<li>one<ul>\n<li>nested</li>\n</ul>\n</li>\n<li>two</li>\n</ul>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "<ol>\n<li>first</li>\n<li>second</li>\n</ol>") != null);
}
