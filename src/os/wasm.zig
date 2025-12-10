//! This file contains helpers for wasm compilation.
const std = @import("std");
const builtin = @import("builtin");
const options = @import("build_options");

comptime {
    if (!builtin.target.cpu.arch.isWasm()) {
        @compileError("wasm.zig should only be analyzed for wasm32 builds");
    }
}

/// True if we're in shared memory mode. If true, then the memory buffer
/// in JS will be backed by a SharedArrayBuffer and some behaviors change.
pub const shared_mem = options.wasm_shared;

/// The allocator to use in wasm environments.
///
/// The return values of this should NOT be sent to the host environment
/// unless toHostOwned is called on them. In this case, the caller is expected
/// to call free. If a pointer is NOT host-owned, then the wasm module is
/// expected to call the normal alloc.free/destroy functions.
pub const alloc = if (builtin.is_test)
    std.testing.allocator
else
    std.heap.wasm_allocator;
