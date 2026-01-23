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

    /// Open a URL template with capture group substitution.
    /// The template can contain $0-$9 for capture groups, and $$ for literal $.
    open_url: [:0]const u8,
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

    /// Parse a Highlight value from a CLI string.
    /// Supports: "always", "hover"
    pub fn parseCLI(input: ?[]const u8) error{InvalidValue}!Highlight {
        const value = input orelse return error.InvalidValue;
        if (std.mem.eql(u8, value, "always")) return .always;
        if (std.mem.eql(u8, value, "hover")) return .hover;
        return error.InvalidValue;
    }
};

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
        .action = switch (self.action) {
            .open, ._open_osc8 => self.action,
            .open_url => |url| .{ .open_url = try alloc.dupeZ(u8, url) },
        },
        .highlight = self.highlight,
    };
}

/// Check if two links are equal.
pub fn equal(self: *const Link, other: *const Link) bool {
    const action_eq = switch (self.action) {
        .open => other.action == .open,
        ._open_osc8 => other.action == ._open_osc8,
        .open_url => |url| switch (other.action) {
            .open_url => |other_url| std.mem.eql(u8, url, other_url),
            else => false,
        },
    };
    return action_eq and
        std.meta.eql(self.highlight, other.highlight) and
        std.mem.eql(u8, self.regex, other.regex);
}

test "clone with open_url" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const original = Link{
        .regex = "JIRA-(\\d+)",
        .action = .{ .open_url = "https://jira.example.com/browse/$1" },
        .highlight = .always,
    };

    const cloned = try original.clone(alloc);
    defer alloc.free(cloned.regex);
    defer alloc.free(cloned.action.open_url);

    try testing.expect(original.equal(&cloned));
    try testing.expect(cloned.regex.ptr != original.regex.ptr);
    try testing.expect(cloned.action.open_url.ptr != original.action.open_url.ptr);
}

test "equal with open_url" {
    const a = Link{
        .regex = "TEST",
        .action = .{ .open_url = "https://example.com/$1" },
        .highlight = .hover,
    };
    const b = Link{
        .regex = "TEST",
        .action = .{ .open_url = "https://example.com/$1" },
        .highlight = .hover,
    };
    const c = Link{
        .regex = "TEST",
        .action = .{ .open_url = "https://other.com/$1" },
        .highlight = .hover,
    };
    const d = Link{
        .regex = "TEST",
        .action = .open,
        .highlight = .hover,
    };

    try std.testing.expect(a.equal(&b));
    try std.testing.expect(!a.equal(&c));
    try std.testing.expect(!a.equal(&d));
}
