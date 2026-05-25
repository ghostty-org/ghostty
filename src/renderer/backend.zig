const std = @import("std");
const WasmTarget = @import("../os/wasm/target.zig").Target;

/// Possible implementations, used for build options.
pub const Backend = enum {
    opengl,
    metal,
    webgl,
    /// Vulkan is on this fork only. Embedded-only — the host owns
    /// the VkInstance/Device/Queue and hands them in via
    /// `ghostty_platform_vulkan_s`; libghostty renders against
    /// those handles and exports the result as a dmabuf fd.
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
