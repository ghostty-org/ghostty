//! A link is a clickable element that can be used to trigger some action.
//! A link is NOT just a URL that opens in a browser. A link is any generic
//! regular expression match over terminal text that can trigger various
//! action types.
const Link = @This();

const oni = @import("oniguruma");

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
};

pub const Highlight = union(enum) {
    /// Always highlight the link.
    always: void,

    /// Only highlight the link when the mouse is hovering over it.
    hover: void,
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
