const benchmark = @import("benchmark/main.zig");

comptime {
    // Force-reference our memset override so its export is emitted
    // when its needed. See quirks_memset.zig for lots of details.
    _ = @import("quirks_memset.zig");
}

pub const main = benchmark.cli.main;
