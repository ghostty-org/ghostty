const std = @import("std");
const WasmTarget = @import("../os/wasm/target.zig").Target;

/// Possible implementations, used for build options.
pub const Backend = enum {
    opengl,
    webgl,

    pub fn default(
        target: std.Target,
        wasm_target: WasmTarget,
    ) Backend {
        if (target.cpu.arch == .wasm32) {
            return switch (wasm_target) {
                .browser => .webgl,
            };
        }

        return .opengl;
    }
};
