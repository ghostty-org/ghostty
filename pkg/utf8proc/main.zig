pub const c = @import("c.zig");

/// Given a codepoint, return a character width analogous to `wcwidth(codepoint)`,
/// except that a width of 0 is returned for non-printable codepoints
/// instead of -1 as in `wcwidth`.
pub fn charwidth(codepoint: u21) u8 {
    return @intCast(c.utf8proc_charwidth(@intCast(codepoint)));
}

/// Given a pair of consecutive codepoints, return whether a grapheme break is
/// permitted between them (as defined by the extended grapheme clusters in UAX#29).
pub fn graphemeBreakStateful(cp1: u21, cp2: u21, state: *i32) bool {
    return c.utf8proc_grapheme_break_stateful(
        @intCast(cp1),
        @intCast(cp2),
        state,
    );
}

test {}
