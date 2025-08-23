const std = @import("std");
const builtin = @import("builtin");
const benchmark = @import("benchmark/main.zig");

pub const main = benchmark.cli.main;
