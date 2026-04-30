//! Inspired by WebKit's quirks.cpp[1], this file centralizes all our
//! sad environment-specific hacks that we have to do to make things work.
//! This is a last resort; if we can find a general solution to a problem,
//! we of course prefer that, but sometimes other software, fonts, etc. are
//! just broken or weird and we have to work around it.
//!
//! [1]: https://github.com/WebKit/WebKit/blob/main/Source/WebCore/page/Quirks.cpp

const std = @import("std");
const builtin = @import("builtin");

const font = @import("font/main.zig");

/// If true, the default font features should be disabled for the given face.
pub fn disableDefaultFontFeatures(face: *const font.Face) bool {
    _ = face;

    // This function used to do something, but we integrated the logic
    // we checked for directly into our shaping algorithm. It's likely
    // there are other broken fonts for other reasons so I'm keeping this
    // around so its easy to add more checks in the future.
    return false;

    // var buf: [64]u8 = undefined;
    // const name = face.name(&buf) catch |err| switch (err) {
    //     // If the name doesn't fit in buf we know this will be false
    //     // because we have no quirks fonts that are longer than buf!
    //     error.OutOfMemory => return false,
    // };
}

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
