//! Inspired by WebKit's quirks.cpp[1], this file centralizes all our
//! sad environment-specific hacks that we have to do to make things work.
//! This is a last resort; if we can find a general solution to a problem,
//! we of course prefer that, but sometimes other software, fonts, etc. are
//! just broken or weird and we have to work around it.
//!
//! [1]: https://github.com/WebKit/WebKit/blob/main/Source/WebCore/page/Quirks.cpp

const std = @import("std");

const font = @import("font/main.zig");

/// If true, the default font features should be disabled for the given face.
pub fn disableDefaultFontFeatures(face: *const font.Face) bool {
    var buf: [64]u8 = undefined;
    const name = face.name(&buf) catch |err| switch (err) {
        // If the name doesn't fit in buf we know this will be false
        // because we have no quirks fonts that are longer than buf!
        error.OutOfMemory => return false,
    };

    // Menlo and Monaco both have a default ligature of "fi" that looks
    // really bad in terminal grids, so we want to disable ligatures
    // by default for these faces.
    return std.mem.eql(u8, name, "Menlo") or
        std.mem.eql(u8, name, "Monaco");
}
