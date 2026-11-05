//! Link text for TUIs which paint wrapped URLs and paths using hard line breaks.
const std = @import("std");
const terminal = @import("terminal/main.zig");
const Allocator = std.mem.Allocator;

/// One detection owns the target and its exact screen spans. Consumers never
/// reconstruct a URL from a rectangular selection or rerun normalization.
pub const Result = struct {
    target: [:0]const u8,
    kind: enum { url, path },
    source: enum { logical_line, inferred_continuation },
    selection: terminal.Selection,
    spans: []const terminal.Selection,

    pub fn deinit(self: Result, alloc: Allocator) void {
        alloc.free(self.target);
        alloc.free(self.spans);
    }

    pub fn contains(self: Result, screen: *terminal.Screen, pin: terminal.Pin) bool {
        for (self.spans) |span| if (span.contains(screen, pin)) return true;
        return false;
    }

    pub fn fromMatch(alloc: Allocator, match: terminal.StringMap.Match) !Result {
        const lo = match.offset + @as(usize, @intCast(match.region.starts()[0]));
        const hi = match.offset + @as(usize, @intCast(match.region.ends()[0]));
        const target = try alloc.dupeZ(u8, match.map.string[lo..hi]);
        errdefer alloc.free(target);
        var spans: std.ArrayList(terminal.Selection) = .empty;
        defer spans.deinit(alloc);
        for (lo..hi) |offset| {
            const pin = match.map.map.get(offset).?;
            if (spans.items.len > 0) {
                const last = &spans.items[spans.items.len - 1];
                const end = last.end();
                if (end.node == pin.node and end.y == pin.y) {
                    last.* = terminal.Selection.init(last.start(), pin, false);
                    continue;
                }
            }
            try spans.append(alloc, terminal.Selection.init(pin, pin, false));
        }
        var inferred = false;
        for (spans.items, 0..) |span, index| {
            if (index + 1 < spans.items.len and !span.end().rowAndCell().row.wrap)
                inferred = true;
        }
        return .{
            .target = target,
            .kind = if (@import("omg_link_check.zig").needsCheck(target)) .path else .url,
            .source = if (inferred) .inferred_continuation else .logical_line,
            .selection = match.selection(),
            .spans = try spans.toOwnedSlice(alloc),
        };
    }
};

/// Keep the search local, including when the mouse is over a continuation.
/// Full-width URL/path runs can cross a hard row boundary, including a
/// small, consistent TUI inset. Keep original byte-to-pin anchors so padding
/// is excluded from both the opened target and link decoration.
pub fn stringMap(alloc: Allocator, screen: *terminal.Screen, line: terminal.Selection) !terminal.StringMap {
    var first = line.start();
    var last = line.end();
    for (0..8) |_| {
        first = first.up(1) orelse break;
    }
    first.x = 0;
    for (0..8) |_| {
        last = last.down(1) orelse break;
    }
    last.x = last.node.cols() - 1;
    const source = try screen.selectionStringMap(alloc, .{
        .sel = terminal.Selection.init(first, last, false),
        .trim = false,
    });
    defer source.deinit(alloc);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(alloc);
    var pins: @TypeOf(source.map) = .empty;
    errdefer pins.deinit(alloc);
    var joined = false;
    var i: usize = 0;
    while (i < source.string.len) : (i += 1) {
        const c = source.string[i];
        const pin = source.map.get(i).?;
        if (c == '\n' and i > 0 and i + 1 < source.string.len) {
            // A TUI may reserve a column on each side of its text area.
            // Infer that inset from the first nonblank cell on this row.
            var row_start = i;
            while (row_start > 0 and source.string[row_start - 1] != '\n') row_start -= 1;
            var content_start = row_start;
            while (content_start < i and source.string[content_start] == ' ') content_start += 1;
            const inset = if (content_start < i) source.map.get(content_start).?.x else 0;
            var end = bytes.items.len;
            while (end > 0 and bytes.items[end - 1] == ' ') end -= 1;
            var start = end;
            while (start > 0 and isURLChar(bytes.items[start - 1])) start -= 1;
            var next = i + 1;
            while (next < source.string.len and source.string[next] == ' ') next += 1;
            if (end > start and next < source.string.len and inset <= 3 and
                isCandidate(bytes.items[start..end]) and isURLChar(source.string[next]))
            {
                const prev_pin = pins.get(end - 1).?;
                const next_pin = source.map.get(next).?;
                const tail = prev_pin.node.cols() - 1 - prev_pin.x;
                // Editors without padding reserve their final column for
                // the cursor (e.g. pi-tui's layoutWidth = contentWidth - 1).
                const right_inset = @max(inset, 1);
                const component_wrap = enclosedComponentWrap(
                    bytes.items[start..end],
                    bytes.items[0..start],
                    &source,
                    next,
                    tail,
                    right_inset,
                    inset,
                );
                if ((tail <= right_inset or component_wrap) and next_pin.x == inset and
                    prev_pin.rowAndCell().cell.semantic_content != .prompt and
                    next_pin.rowAndCell().cell.semantic_content != .prompt)
                {
                    // Rebuild the compact pin map rather than retaining anchors
                    // for the TUI's right padding.
                    var trimmed: @TypeOf(pins) = .empty;
                    errdefer trimmed.deinit(alloc);
                    for (0..end) |offset| try trimmed.append(alloc, pins.get(offset).?, 1);
                    pins.deinit(alloc);
                    pins = trimmed;
                    bytes.shrinkRetainingCapacity(end);
                    joined = true;
                    i = next - 1;
                    continue;
                }
            }
        }
        try bytes.append(alloc, c);
        try pins.append(alloc, pin, 1);
    }
    if (!joined) {
        pins.deinit(alloc);
        pins = .empty;
        return screen.selectionStringMap(alloc, .{ .sel = line, .trim = false });
    }
    return .{ .string = try bytes.toOwnedSliceSentinel(alloc, 0), .map = pins };
}

test "OMG hard wrapped URL retains target from either row" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 40, .rows = 8 });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    const prefix = "https://example.com/abcdefghijklmnopqrst";
    try testing.expectEqual(@as(usize, 40), prefix.len);
    // Cursor addressing, as used by full-screen TUIs, does not set soft wrap.
    stream.nextSlice(prefix ++ "\x1b[2;1Hvwx/path) next\x1b[3;1Hother text");
    const screen = t.screens.active;
    var config = try @import("renderer/link.zig").Set.fromConfig(alloc, &.{.{
        .regex = @import("config/url.zig").no_space_regex,
        .action = .{ .open = {} },
        .highlight = .{ .hover_mods = @import("input.zig").ctrlOrSuper(.{}) },
    }});
    defer config.deinit(alloc);
    for (0..2) |y| {
        const pin = screen.pages.pin(.{ .active = .{ .x = 2, .y = @intCast(y) } }).?;
        const line = screen.selectLine(.{ .pin = pin, .whitespace = null }).?;
        const map = try stringMap(alloc, screen, line);
        defer map.deinit(alloc);
        var it = map.searchIterator(config.links[0].regex);
        var match = (try it.next()).?;
        defer match.deinit();
        const detected = try Result.fromMatch(alloc, match);
        defer detected.deinit(alloc);
        try testing.expect(detected.contains(screen, pin));
        try testing.expectEqualStrings(prefix ++ "vwx/path", detected.target);
        try testing.expectEqual(@as(usize, 2), detected.spans.len);
    }
    var frame: terminal.RenderState = .empty;
    defer frame.deinit(alloc);
    try frame.update(alloc, &t);
    var cache: @import("omg_link_check.zig") = .{};
    defer cache.deinit(alloc);
    var cells = try @import("renderer/omg_link.zig").collect(alloc, alloc, screen, &frame, config.links, &cache, @import("input.zig").ctrlOrSuper(.{}));
    defer cells.deinit(alloc);
    try testing.expectEqual(@as(usize, prefix.len + "vwx/path".len), cells.count());
    try testing.expect(cells.contains(.{ .x = 0, .y = 1 }));
    try testing.expect(!cells.contains(.{ .x = 8, .y = 1 }));

    // A closing Markdown delimiter ends the link even at the right edge.
    // Two trailing columns are outside the unpadded cursor-reserve heuristic;
    // short rows and whitespace inside text still terminate candidates.
    for ([_][]const u8{
        "https://example.com/abcdefghijklmnopqrs)",
        "https://example.com/abcdefghijklmnopqr  ",
        "https://example.com/short",
    }) |head| {
        stream.nextSlice("\x1b[2J\x1b[H");
        stream.nextSlice(head);
        stream.nextSlice("\x1b[2;1Hvwx/path");
        const pin = screen.pages.pin(.{ .active = .{ .x = 0, .y = 0 } }).?;
        const line = screen.selectLine(.{ .pin = pin, .whitespace = null }).?;
        const map = try stringMap(alloc, screen, line);
        defer map.deinit(alloc);
        try testing.expect(std.mem.indexOf(u8, map.string, "vwx/path") == null);
        var it = map.searchIterator(config.links[0].regex);
        var match = (try it.next()).?;
        defer match.deinit();
        try testing.expectEqual(@as(usize, 0), screen.pages.pointFromPin(.active, match.selection().end()).?.coord().y);
    }
}

test "OMG inset agent URL and image path normalize before existence checks" {
    const alloc = std.testing.allocator;
    const mods = @import("input.zig").ctrlOrSuper(.{});
    for (0..2) |inset| {
        for ([_][]const u8{
            "https://github.com/lance-format/lance/pull/10239",
            "/var/folders/2z/zl8wrct518v_n3zcgjmc07200000gn/T/omg-paste/omg-paste-6FF04F2F-370F-4063-9DAE-F110F639E9307.png",
            ".pi/test-runs/safety-state-week-20261105/week-monitor/progress.json",
            "src/gateway/tests/reports/integration/validation/output.json",
        }) |target| {
            var t = try terminal.Terminal.init(std.testing.io, alloc, .{ .cols = 40, .rows = 8 });
            defer t.deinit(alloc);
            try t.setPwd("/repo");
            var stream = t.vtStream();
            defer stream.deinit();
            var offset: usize = 0;
            var row: usize = 1;
            while (offset < target.len) : (row += 1) {
                var buf: [32]u8 = undefined;
                stream.nextSlice(try std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ row, inset + 1 }));
                const width = 40 - inset - @max(inset, 1);
                const end = @min(offset + width, target.len);
                stream.nextSlice(target[offset..end]);
                // Editors paint the cursor reserve/right padding as spaces.
                stream.nextSlice(" ");
                offset = end;
            }
            const screen = t.screens.active;
            var config = try @import("renderer/link.zig").Set.fromConfig(alloc, &.{.{
                .regex = @import("config/url.zig").no_space_regex ++ "|" ++ @import("config/omg_path.zig").regex,
                .action = .{ .open = {} },
                .highlight = .{ .hover_mods = mods },
            }});
            defer config.deinit(alloc);
            for (0..row - 1) |y| {
                const pin = screen.pages.pin(.{ .active = .{ .x = 2, .y = @intCast(y) } }).?;
                const line = screen.selectLine(.{ .pin = pin, .whitespace = null }).?;
                const map = try stringMap(alloc, screen, line);
                defer map.deinit(alloc);
                var it = map.searchIterator(config.links[0].regex);
                var match = (try it.next()).?;
                defer match.deinit();
                const detected = try Result.fromMatch(alloc, match);
                defer detected.deinit(alloc);
                try std.testing.expect(detected.contains(screen, pin));
                try std.testing.expectEqualStrings(target, detected.target);
                try std.testing.expectEqual(row - 1, detected.spans.len);
                try std.testing.expectEqual(.inferred_continuation, detected.source);
                try std.testing.expectEqual(!std.mem.startsWith(u8, target, "https://"), detected.kind == .path);
                const margin = screen.pages.pin(.{ .active = .{ .x = 39, .y = @intCast(y) } }).?;
                try std.testing.expect(!detected.contains(screen, margin));
            }
            var cache: @import("omg_link_check.zig") = .{};
            defer cache.deinit(alloc);
            var frame: terminal.RenderState = .empty;
            defer frame.deinit(alloc);
            try frame.update(alloc, &t);
            var pending = try @import("renderer/omg_link.zig").collect(alloc, alloc, screen, &frame, config.links, &cache, mods);
            defer pending.deinit(alloc);
            if (!std.mem.startsWith(u8, target, "https://")) {
                try std.testing.expectEqual(@import("omg_link_check.zig").Status.queued, cache.get("/repo", target).?);
                cache.clear(alloc);
                _ = try cache.putPending(alloc, "/repo", target);
                try std.testing.expect(cache.resolve("/repo", target, true));
            }
            var cells = try @import("renderer/omg_link.zig").collect(alloc, alloc, screen, &frame, config.links, &cache, mods);
            defer cells.deinit(alloc);
            try std.testing.expectEqual(target.len, cells.count());
            try std.testing.expect(cells.contains(.{ .x = 1, .y = 1 }));
            if (inset > 0) try std.testing.expect(!cells.contains(.{ .x = 0, .y = 1 }));
            try std.testing.expect(!cells.contains(.{ .x = 39, .y = 0 }));
        }
    }
}

test "OMG enclosed path word wrap keeps its complete target and decorations" {
    const alloc = std.testing.allocator;
    const mods = @import("input.zig").ctrlOrSuper(.{});
    const prefix = "  Check backfill progress ";
    const head = "/tmp/safety-state-week-backfill/paimon-switch/";
    const tail = "watch-progress.json";
    const target = head ++ tail;
    const cases = [_]struct {
        open: []const u8,
        close: []const u8,
        fits: bool = false,
        joined: bool,
    }{
        .{ .open = "(", .close = ")", .joined = true },
        .{ .open = "[", .close = "]", .joined = true },
        .{ .open = "<", .close = ">", .joined = true },
        .{ .open = "\"", .close = "\"", .joined = true },
        .{ .open = "'", .close = "'", .joined = true },
        .{ .open = "`", .close = "`", .joined = true },
        .{ .open = "(", .close = ")", .fits = true, .joined = false },
        .{ .open = "(", .close = "", .joined = false },
        .{ .open = "", .close = "", .joined = false },
        .{ .open = "(", .close = "]", .joined = false },
    };
    for (cases) |case| {
        const first = try std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ prefix, case.open, head });
        defer alloc.free(first);
        const columns = first.len + (if (case.fits) tail.len + 5 else 6);
        var t = try terminal.Terminal.init(std.testing.io, alloc, .{ .cols = @intCast(columns), .rows = 4 });
        defer t.deinit(alloc);
        try t.setPwd("/repo");
        var stream = t.vtStream();
        defer stream.deinit();
        stream.nextSlice(first);
        stream.nextSlice("\x1b[2;3H" ++ tail);
        stream.nextSlice(case.close);
        var config = try @import("renderer/link.zig").Set.fromConfig(alloc, &.{.{
            .regex = @import("config/omg_path.zig").regex,
            .action = .{ .open = {} },
            .highlight = .{ .hover_mods = mods },
        }});
        defer config.deinit(alloc);
        const screen = t.screens.active;
        for (0..@as(usize, if (case.joined) 2 else 1)) |y| {
            const x = if (y == 0) prefix.len + case.open.len + 2 else 3;
            const pin = screen.pages.pin(.{ .active = .{ .x = @intCast(x), .y = @intCast(y) } }).?;
            const line = screen.selectLine(.{ .pin = pin, .whitespace = null }).?;
            const map = try stringMap(alloc, screen, line);
            defer map.deinit(alloc);
            var it = map.searchIterator(config.links[0].regex);
            var match = (try it.next()).?;
            defer match.deinit();
            const detected = try Result.fromMatch(alloc, match);
            defer detected.deinit(alloc);
            try std.testing.expectEqualStrings(if (case.joined) target else head, detected.target);
            try std.testing.expect(detected.contains(screen, pin));
            try std.testing.expectEqual(@as(usize, if (case.joined) 2 else 1), detected.spans.len);
        }
        if (!case.joined) continue;
        var frame: terminal.RenderState = .empty;
        defer frame.deinit(alloc);
        try frame.update(alloc, &t);
        var cache: @import("omg_link_check.zig") = .{};
        defer cache.deinit(alloc);
        _ = try cache.putPending(alloc, "/repo", target);
        try std.testing.expect(cache.resolve("/repo", target, true));
        var cells = try @import("renderer/omg_link.zig").collect(alloc, alloc, screen, &frame, config.links, &cache, mods);
        defer cells.deinit(alloc);
        try std.testing.expectEqual(target.len, cells.count());
        try std.testing.expect(cells.contains(.{ .x = 3, .y = 1 }));
        try std.testing.expect(!cells.contains(.{ .x = @intCast(2 + tail.len), .y = 1 }));
    }
}

test "OMG enclosed component wraps span three rows without joining unrelated rows" {
    const alloc = std.testing.allocator;
    const mods = @import("input.zig").ctrlOrSuper(.{});
    const prefix = "  Check progress (";
    const head = "/tmp/safety-state-week-backfill/";
    const middle = "another-long-directory-with-many-characters/";
    const tail = "watch-progress.json";
    const target = head ++ middle ++ tail;
    const cases = [_]struct { column: u16 = 3, close: []const u8 = ")", prose: bool = false, joined: bool }{
        .{ .joined = true },
        .{ .column = 4, .joined = false },
        .{ .close = "]", .joined = false },
        .{ .prose = true, .joined = false },
    };
    for (cases) |case| {
        var t = try terminal.Terminal.init(std.testing.io, alloc, .{
            .cols = prefix.len + head.len + 6,
            .rows = 5,
        });
        defer t.deinit(alloc);
        try t.setPwd("/repo");
        var stream = t.vtStream();
        defer stream.deinit();
        stream.nextSlice(prefix ++ head);
        var position: [32]u8 = undefined;
        stream.nextSlice(try std.fmt.bufPrint(&position, "\x1b[2;{d}H", .{case.column}));
        stream.nextSlice(if (case.prose) "unrelated text" else middle);
        stream.nextSlice("\x1b[3;3H" ++ tail);
        stream.nextSlice(case.close);
        var config = try @import("renderer/link.zig").Set.fromConfig(alloc, &.{.{
            .regex = @import("config/omg_path.zig").regex,
            .action = .{ .open = {} },
            .highlight = .{ .hover_mods = mods },
        }});
        defer config.deinit(alloc);
        const screen = t.screens.active;
        for (0..@as(usize, if (case.joined) 3 else 1)) |y| {
            const pin = screen.pages.pin(.{ .active = .{
                .x = @intCast(if (y == 0) prefix.len + 2 else 3),
                .y = @intCast(y),
            } }).?;
            const line = screen.selectLine(.{ .pin = pin, .whitespace = null }).?;
            const map = try stringMap(alloc, screen, line);
            defer map.deinit(alloc);
            var it = map.searchIterator(config.links[0].regex);
            var match = (try it.next()).?;
            defer match.deinit();
            const detected = try Result.fromMatch(alloc, match);
            defer detected.deinit(alloc);
            try std.testing.expectEqualStrings(if (case.joined) target else head, detected.target);
            try std.testing.expectEqual(@as(usize, if (case.joined) 3 else 1), detected.spans.len);
            try std.testing.expect(detected.contains(screen, pin));
        }
        if (!case.joined) continue;
        var frame: terminal.RenderState = .empty;
        defer frame.deinit(alloc);
        try frame.update(alloc, &t);
        var cache: @import("omg_link_check.zig") = .{};
        defer cache.deinit(alloc);
        _ = try cache.putPending(alloc, "/repo", target);
        try std.testing.expect(cache.resolve("/repo", target, true));
        var cells = try @import("renderer/omg_link.zig").collect(alloc, alloc, screen, &frame, config.links, &cache, mods);
        defer cells.deinit(alloc);
        try std.testing.expectEqual(target.len, cells.count());
        try std.testing.expect(cells.contains(.{ .x = 3, .y = 2 }));
    }
}

test "OMG link result owns soft wrapped Unicode target and spans" {
    const alloc = std.testing.allocator;
    var t = try terminal.Terminal.init(std.testing.io, alloc, .{ .cols = 20, .rows = 8 });
    defer t.deinit(alloc);
    var stream = t.vtStream();
    defer stream.deinit();
    const target = "https://example.com/中文/path";
    stream.nextSlice(target);
    const screen = t.screens.active;
    const pin = screen.pages.pin(.{ .active = .{ .x = 2, .y = 1 } }).?;
    const line = screen.selectLine(.{ .pin = pin, .whitespace = null }).?;
    var config = try @import("renderer/link.zig").Set.fromConfig(alloc, &.{.{
        .regex = @import("config/url.zig").no_space_regex,
        .action = .{ .open = {} },
        .highlight = .{ .hover_mods = @import("input.zig").ctrlOrSuper(.{}) },
    }});
    defer config.deinit(alloc);
    const detected = blk: {
        const map = try stringMap(alloc, screen, line);
        defer map.deinit(alloc);
        var it = map.searchIterator(config.links[0].regex);
        var match = (try it.next()).?;
        defer match.deinit();
        break :blk try Result.fromMatch(alloc, match);
    };
    defer detected.deinit(alloc);
    try std.testing.expectEqualStrings(target, detected.target);
    try std.testing.expectEqual(.logical_line, detected.source);
    try std.testing.expect(detected.contains(screen, pin));
    try std.testing.expectEqual(@as(usize, 2), detected.spans.len);
}

fn isURLChar(c: u8) bool {
    return c > ' ' and c < 127 and std.mem.indexOfScalar(u8, "<>\"'`()[]{}", c) == null;
}

/// Validate the complete enclosure before accepting a component wrap. The
/// bounded lookahead can cross several directory rows, but never blank lines,
/// prompt cells, mismatched delimiters or components that fit the prior row.
fn enclosedComponentWrap(
    head: []const u8,
    before: []const u8,
    source: *const terminal.StringMap,
    next_offset: usize,
    remaining_columns: usize,
    right_inset: usize,
    inset: usize,
) bool {
    if (head.len == 0 or head[head.len - 1] != '/' or before.len == 0) return false;
    const close: u8 = switch (before[before.len - 1]) {
        '(' => ')',
        '[' => ']',
        '<' => '>',
        '\'' => '\'',
        '"' => '"',
        '`' => '`',
        else => return false,
    };
    var offset = next_offset;
    var room = remaining_columns;
    for (0..8) |_| {
        var end = offset;
        while (end < source.string.len and isURLChar(source.string[end])) : (end += 1) {}
        if (end == offset or end == source.string.len) return false;
        const first = source.map.get(offset) orelse return false;
        if (first.x != inset) return false;
        for (offset..end) |index| {
            const pin = source.map.get(index) orelse return false;
            if (pin.rowAndCell().cell.semantic_content == .prompt) return false;
        }
        const width = end - offset;
        if (source.string[end] == close) return room < width + 1 + right_inset;
        if (source.string[end - 1] != '/' or room >= width + right_inset) return false;
        var next = end;
        while (next < source.string.len and source.string[next] == ' ') : (next += 1) {}
        if (next == source.string.len or source.string[next] != '\n') return false;
        next += 1;
        while (next < source.string.len and source.string[next] == ' ') : (next += 1) {}
        const last = source.map.get(end - 1) orelse return false;
        room = last.node.cols() - 1 - last.x;
        offset = next;
    }
    return false;
}

fn isCandidate(value: []const u8) bool {
    if (std.mem.startsWith(u8, value, "https://") or
        std.mem.startsWith(u8, value, "http://") or
        std.mem.startsWith(u8, value, "/") or
        std.mem.startsWith(u8, value, "~/") or
        std.mem.startsWith(u8, value, "./") or
        std.mem.startsWith(u8, value, "../")) return true;

    // Bare relative directory paths use the same continuation mapping as
    // absolute paths. A hidden directory such as .pi/ is not the ./ prefix.
    if (value.len == 0 or std.mem.indexOfScalar(u8, value, '/') == null or
        std.mem.indexOf(u8, value, "...") != null) return false;
    if (!std.ascii.isAlphanumeric(value[0]) and value[0] != '.' and value[0] != '_') return false;
    for (value) |c| {
        if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "._-/", c) == null) return false;
    }
    return true;
}
