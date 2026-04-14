//! copyv: https://github.com/ghostty-org/ghostty/blob/9fb03ba55c9e53901193187d5c43341f5b1b430d/src/quirks.zig#L1-L10 begin
//! Inspired by WebKit's quirks.cpp[1], this file centralizes all our
//! sad environment-specific hacks that we have to do to make things work.
//! This is a last resort; if we can find a general solution to a problem,
//! we of course prefer that, but sometimes other software, fonts, etc. are
//! just broken or weird and we have to work around it.
//!
//! [1]: https://github.com/WebKit/WebKit/blob/main/Source/WebCore/page/Quirks.cpp

const std = @import("std");
const builtin = @import("builtin");
// copyv: end

/// copyv: https://github.com/ghostty-org/ghostty/blob/9fb03ba55c9e53901193187d5c43341f5b1b430d/src/quirks.zig#L32-L57 begin
/// We use our own assert function instead of `std.debug.assert`.
///
/// The only difference between this and the one in
/// the stdlib is that this version is marked inline.
///
/// The reason for this is that, despite the promises of the doc comment
/// on the stdlib function, the function call to `std.debug.assert` isn't
/// always optimized away in `ReleaseFast` mode, at least in Zig 0.15.2.
///
/// In the majority of places, the overhead from calling an empty function
/// is negligible, but we have some asserts inside tight loops and hotpaths
/// that cause significant overhead (as much as 15-20%) when they don't get
/// optimized out.
pub const inlineAssert = switch (builtin.mode) {
    // In debug builds we just use std.debug.assert because this
    // fixes up stack traces. `inline` causes broken stack traces. This
    // is probably a Zig compiler bug but until it is fixed we have to
    // do this for development sanity.
    .Debug => std.debug.assert,

    .ReleaseSmall, .ReleaseSafe, .ReleaseFast => (struct {
        inline fn assert(ok: bool) void {
            if (!ok) unreachable;
        }
    }).assert,
};
// copyv: end
