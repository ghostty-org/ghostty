const std = @import("std");
const testing = std.testing;

// Differential parity against external engines is intentionally kept out of the core
// dependency graph. This test stays as a guardrail so `zig build test`
// remains stable in environments where only itijah dependencies are present.
//
// External parity workflow (planned):
// - Run itijah and reference engines on the same corpus out-of-tree.
// - Materialize comparison fixtures.
// - Validate levels, visual output, and logical/visual maps in CI.
test "parity is external to dependency graph" {
    try testing.expect(true);
    std.log.info("reference parity is external; no direct module dependency", .{});
}
