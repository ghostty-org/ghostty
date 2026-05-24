const std = @import("std");
const WasmTarget = @import("../os/wasm/target.zig").Target;

/// Possible implementations, used for build options.
pub const Backend = enum {
    opengl,
    metal,
    webgl,
    /// Vulkan is on this fork only and is a work in progress: selecting
    /// `-Drenderer=vulkan` currently fails at comptime in `renderer.zig`.
    /// The scaffolding (apprt platform callbacks, public C API) is in
    /// place; the renderer itself lands in follow-up commits on
    /// `qt-vulkan-renderer`.
    vulkan,

    pub fn default(
        target: std.Target,
        wasm_target: WasmTarget,
    ) Backend {
        if (target.cpu.arch == .wasm32) {
            return switch (wasm_target) {
                .browser => .webgl,
            };
        }

        if (target.os.tag.isDarwin()) return .metal;
        return .opengl;
    }
};
