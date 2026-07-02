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
    /// Open the matched value using the default open program. For example,
    /// on macOS this is "open" and on Linux this is "xdg-open".
    ///
    /// If null, the full matched value is opened as-is. If set, the value
    /// is a template containing `\0`-`\9` placeholders that are substituted
    /// with the whole match (`\0`) and regex capture groups (`\1`-`\9`)
    /// before opening. This allows building a URL or path from capture
    /// groups, e.g. to open a specific line/column in an editor that
    /// registers its own URL scheme: `vscode://file\1:\2:\3`.
    open: ?[]const u8,

    /// Open the OSC8 hyperlink under the mouse position. _-prefixed means
    /// this can't be user-specified, it's only used internally.
    _open_osc8: void,

    pub const Error = error{
        InvalidFormat,
    };

    /// Parse an action in the format of "name" or "name:param", where
    /// "param" is the (optional, depending on the action) parameter.
    pub fn parse(input: []const u8) Error!Action {
        const colon_idx = std.mem.indexOfScalar(u8, input, ':');
        const name = input[0..(colon_idx orelse input.len)];

        if (std.mem.eql(u8, name, "open")) {
            const param = colon_idx orelse return .{ .open = null };
            return .{ .open = input[param + 1 ..] };
        }

        // "_open_osc8" is intentionally not parseable; it is internal-only.
        return Error.InvalidFormat;
    }
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
            .open => |template| .{
                .open = if (template) |t| try alloc.dupe(u8, t) else null,
            },
            ._open_osc8 => .{ ._open_osc8 = {} },
        },
        .highlight = self.highlight,
    };
}

/// Check if two links are equal.
pub fn equal(self: *const Link, other: *const Link) bool {
    return std.meta.eql(self.action, other.action) and
        std.meta.eql(self.highlight, other.highlight) and
        std.mem.eql(u8, self.regex, other.regex);
}

test "Action parse open" {
    const testing = std.testing;
    const action = try Action.parse("open");
    try testing.expect(action == .open);
    try testing.expect(action.open == null);
}

test "Action parse open with template" {
    const testing = std.testing;
    const action = try Action.parse("open:vscode://file\\1:\\2:\\3");
    try testing.expect(action == .open);
    try testing.expectEqualStrings("vscode://file\\1:\\2:\\3", action.open.?);
}

test "Action parse invalid" {
    const testing = std.testing;
    try testing.expectError(Action.Error.InvalidFormat, Action.parse("nope"));
    try testing.expectError(Action.Error.InvalidFormat, Action.parse("_open_osc8"));
}
