const std = @import("std");

/// Possible bidi implementations, used for build options.
///
/// The backend is a comptime interface in the same spirit as
/// `font.Shaper` in `src/font/shape.zig`: every backend exposes the same
/// `Resolver` API and the same result vocabulary from `types.zig`, so
/// swapping one for another cannot change behavior outside this package.
///
/// This seam exists deliberately. Ghostty is MIT licensed, and the obvious
/// off-the-shelf bidi implementation (FriBidi) is LGPL, which is awkward to
/// statically link into a distributed binary. Keeping the backend swappable
/// means that choice is never load-bearing.
pub const Backend = enum {
    /// No reordering at all. Every row resolves to the identity mapping at
    /// left-to-right. This is the "bidi compiled out" state: it links no
    /// bidi implementation and costs a single branch per resolve call.
    noop,

    pub fn default(target: std.Target) Backend {
        _ = target;

        // Bidi is not enabled by default yet. The rendering pipeline that
        // consumes it does not exist, so anything other than `noop` would
        // only add cost. This flips once the phases that integrate it land.
        return .noop;
    }
};
