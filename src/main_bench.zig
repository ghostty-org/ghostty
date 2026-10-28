const benchmark = @import("benchmark/main.zig");

comptime {
    // Force-reference our memset override so its export is emitted.
    // See quirks_memset.zig for details on why this exists.
    _ = @import("quirks_memset.zig");
}

pub const main = benchmark.cli.main;
