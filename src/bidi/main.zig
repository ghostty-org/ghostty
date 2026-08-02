//! Unicode Bidirectional Algorithm (UAX #9) support.
//!
//! This package turns a paragraph of codepoints in *logical* order into the
//! information needed to display it in *visual* order: an embedding level
//! per element, a permutation between the two orders, and the level runs a
//! shaper needs to hand correctly-directioned text to HarfBuzz.
//!
//! ## What this package does not do
//!
//! It knows nothing about terminals. It operates on a flat array of
//! codepoints and returns flat index mappings. Adapting a row of terminal
//! cells (wide-character spacers, grapheme continuations, styles) into that
//! array, and caching the result per row, belongs to the caller. Keeping
//! the boundary here means the algorithm can be tested against the Unicode
//! conformance suites without a terminal in the picture.
//!
//! It also never mutates anything. Logical order remains authoritative
//! everywhere in Ghostty; visual order is derived for display and thrown
//! away. See `src/terminal/point.zig` for the types that keep the two
//! coordinate spaces apart at compile time.
//!
//! ## Backends
//!
//! The implementation is selected at comptime via `-Dbidi-backend`, in the
//! same style as the font shaper in `src/font/shape.zig`. Only the identity
//! `noop` backend exists today; a native Zig implementation of UAX #9 lands
//! behind this same interface, at which point selecting it is a one-word
//! build-flag change and nothing outside this package moves.

const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("../build_config.zig");

pub const noop = @import("noop.zig");
pub const scan = @import("scan.zig");
pub const types = @import("types.zig");
pub const zig = @import("zig.zig");

pub const Backend = @import("backend.zig").Backend;
pub const Direction = types.Direction;
pub const Level = types.Level;
pub const LevelRun = types.LevelRun;
pub const Options = types.Options;
pub const ParagraphDirection = types.ParagraphDirection;
pub const Result = types.Result;
pub const levelDirection = types.levelDirection;
pub const max_depth = types.max_depth;

/// Build options.
pub const options: struct {
    backend: Backend,
} = .{
    .backend = build_config.bidi_backend,
};

/// The resolver implementation for our build options.
///
/// Every backend exposes the same API:
///
///     var resolver: Resolver = .empty;
///     defer resolver.deinit(alloc);
///     const result = try resolver.resolve(alloc, codepoints, .{});
///
/// The result borrows the resolver's buffers and is valid only until the
/// next `resolve` call.
pub const Resolver = switch (options.backend) {
    .noop => noop.Resolver,
    .zig => zig.Resolver,
};

test {
    _ = types;

    // Always test every backend regardless of what we're built with, the
    // same way `src/font/shape.zig` always tests its noop shaper. The
    // conformance suite in particular must run on every build.
    _ = noop;
    _ = scan;
    _ = zig;
    _ = @import("conformance_test.zig");
}

test "Resolver: round trips through the selected backend" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var resolver: Resolver = .empty;
    defer resolver.deinit(alloc);

    const cps = [_]u21{ 'a', 'b', 'c' };
    const result = try resolver.resolve(alloc, &cps, .{});
    try testing.expectEqual(@as(usize, 3), result.len);

    // Whatever the backend, visual and logical indices must round trip.
    for (0..result.len) |i| {
        try testing.expectEqual(i, result.logicalIndex(result.visualIndex(i)));
    }

    // And the level runs must cover every element exactly once.
    var covered: usize = 0;
    for (result.runs) |run| covered += run.len;
    try testing.expectEqual(result.len, covered);
}
