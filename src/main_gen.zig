const synthetic = @import("synthetic/main.zig");

comptime {
    // Force-reference our memset override so its export is emitted
    // (not on Darwin or x86_64). See quirks_memset.zig for why this exists.
    _ = @import("quirks_memset.zig");
}

pub const main = synthetic.cli.main;
