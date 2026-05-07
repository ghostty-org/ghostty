//! Helper for initializing CLI and environment state from Juicy Main.
const std = @import("std");
const assert = @import("../../quirks.zig").inlineAssert;
const compat_args = @import("args.zig");
const compat_env = @import("env.zig");

/// Asserts that both the compat args and env static local vars are both unset.
pub fn run(init: std.process.Init.Minimal) void {
    assert(compat_env.os_environ == null and compat_args.args == null);

    // Snapshot the environment into the global environment state if we have it
    // (POSIX systems).
    if (std.process.Environ.Block == std.process.Environ.PosixBlock) {
        compat_env.os_environ = init.environ.block.view().slice;
    }

    // Stash our args
    compat_args.args = init.args;
}
