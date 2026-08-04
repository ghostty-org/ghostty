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

    /// The native Zig implementation of UAX #9 in `zig.zig`. No third
    /// party library is involved, so there is no licensing question and
    /// nothing extra to cross-compile.
    zig,

    pub fn default(target: std.Target) Backend {
        _ = target;

        // The pipeline that consumes bidi results is complete, and the
        // `bidi` config option now defaults to reordering. This still
        // returns `noop`, so a default build compiles no resolver and
        // the option has nothing to drive: reordering requires
        // `-Dbidi-backend=zig`.
        //
        // That is deliberate. Turning this on is what exposes every user
        // to the feature, and it is gated on review by people who read
        // the scripts involved, which no amount of passing tests
        // substitutes for.
        return .noop;
    }
};
