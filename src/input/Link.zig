//! A link is a clickable element that can be used to trigger some action.
//! A link is NOT just a URL that opens in a browser. A link is any generic
//! regular expression match over terminal text that can trigger various
//! action types.
const Link = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const oni = @import("oniguruma");
const Mods = @import("key.zig").Mods;

/// The regular expression that will be used to match the link. Ownership
/// of this memory is up to the caller. The link will never free this memory.
regex: []const u8,

/// The action that will be triggered when the link is clicked.
action: Action,

/// The situations in which the link will be highlighted. A link is only
/// clickable by the mouse when it is highlighted, so this also controls
/// when the link is clickable.
highlight: Highlight,

pub const Action = union(enum) {
    /// Open the full matched value using the default open program.
    /// For example, on macOS this is "open" and on Linux this is "xdg-open".
    open: void,

    /// Open the OSC8 hyperlink under the mouse position. _-prefixed means
    /// this can't be user-specified, it's only used internally.
    _open_osc8: void,
};

pub const Highlight = union(enum) {
    /// Always highlight the link.
    always: void,

    /// Only highlight the link when the mouse is hovering over it.
    hover: void,

    /// Highlight anytime the given mods are pressed, either when
    /// hovering or always. For always, all links will be highlighted
    /// when the mods are pressed regardless of if the mouse is hovering
    /// over them.
    ///
    /// Note that if "shift" is specified here, this will NEVER match in
    /// TUI programs that capture mouse events. "Shift" with mouse capture
    /// escapes the mouse capture but strips the "shift" so it can't be
    /// detected.
    always_mods: Mods,
    hover_mods: Mods,
};

/// The result of parsing a matched link string for a trailing
/// `:line[:col]` suffix, e.g. `src/main.zig:42:10`.
pub const ParsedFilePath = struct {
    path: []const u8,
    line: ?[]const u8 = null,
    col: ?[]const u8 = null,
};

/// Parse a trailing `:line[:col]` suffix from a matched link string.
/// The numeric components are returned as substrings of the input;
/// they are validated to be all digits but not range-checked.
pub fn parseFilePath(str: []const u8) ParsedFilePath {
    var result: ParsedFilePath = .{ .path = str };
    for (0..2) |_| {
        const idx = std.mem.lastIndexOfScalar(u8, result.path, ':') orelse break;
        const seg = result.path[idx + 1 ..];
        if (!allDigits(seg)) break;
        result.col = result.line;
        result.line = seg;
        result.path = result.path[0..idx];
    }

    return result;
}

fn allDigits(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

test "parseFilePath" {
    const testing = std.testing;

    {
        const p = parseFilePath("src/main.zig");
        try testing.expectEqualStrings("src/main.zig", p.path);
        try testing.expect(p.line == null);
        try testing.expect(p.col == null);
    }
    {
        const p = parseFilePath("src/main.zig:42");
        try testing.expectEqualStrings("src/main.zig", p.path);
        try testing.expectEqualStrings("42", p.line.?);
        try testing.expect(p.col == null);
    }
    {
        const p = parseFilePath("/abs/path/main.zig:42:10");
        try testing.expectEqualStrings("/abs/path/main.zig", p.path);
        try testing.expectEqualStrings("42", p.line.?);
        try testing.expectEqualStrings("10", p.col.?);
    }
    {
        // Numeric suffix segments are parsed even for non-path strings;
        // callers are expected to validate the path on disk.
        const p = parseFilePath("magnet:?xt=urn:btih:1234567890");
        try testing.expectEqualStrings("magnet:?xt=urn:btih", p.path);
        try testing.expectEqualStrings("1234567890", p.line.?);
        try testing.expect(p.col == null);
    }
    {
        const p = parseFilePath("foo:bar");
        try testing.expectEqualStrings("foo:bar", p.path);
        try testing.expect(p.line == null);
    }
}

/// Returns a new oni.Regex that can be used to match the link.
pub fn oniRegex(self: *const Link) !oni.Regex {
    return try oni.Regex.init(
        self.regex,
        .{},
        oni.Encoding.utf8,
        oni.Syntax.default,
        null,
    );
}

/// Deep clone the link.
pub fn clone(self: *const Link, alloc: Allocator) Allocator.Error!Link {
    return .{
        .regex = try alloc.dupe(u8, self.regex),
        .action = self.action,
        .highlight = self.highlight,
    };
}

/// Check if two links are equal.
pub fn equal(self: *const Link, other: *const Link) bool {
    return std.meta.eql(self.action, other.action) and
        std.meta.eql(self.highlight, other.highlight) and
        std.mem.eql(u8, self.regex, other.regex);
}
