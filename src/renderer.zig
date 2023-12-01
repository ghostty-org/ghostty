//! Renderer implementation and utilities. The renderer is responsible for
//! taking the internal screen state and turning into some output format,
//! usually for a screen.
//!
//! The renderer is closely tied to the windowing system which usually
//! has to prepare the window for the given renderer using system-specific
//! APIs. The renderers in this package assume that the renderer is already
//! setup (OpenGL has a context, Vulkan has a surface, etc.)

const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("build_config.zig");
const WasmTarget = @import("os/wasm/target.zig").Target;

pub usingnamespace @import("renderer/cursor.zig");
pub usingnamespace @import("renderer/message.zig");
pub usingnamespace @import("renderer/size.zig");
pub const shadertoy = @import("renderer/shadertoy.zig");
pub const Metal = @import("renderer/Metal.zig");
pub const OpenGL = @import("renderer/OpenGL.zig");
pub const WebGL = @import("renderer/WebGL.zig");
pub const Options = @import("renderer/Options.zig");
pub const Thread = @import("renderer/Thread.zig");
pub const State = @import("renderer/State.zig");

/// Possible implementations, used for build options.
pub const Impl = enum {
    opengl,
    metal,
    webgl,

    pub fn default(
        target: std.zig.CrossTarget,
        wasm_target: WasmTarget,
    ) Impl {
        if (target.getCpuArch() == .wasm32) {
            return switch (wasm_target) {
                .browser => .webgl,
            };
        }

        if (target.isDarwin()) return .metal;
        return .opengl;
    }
};

/// The implementation to use for the renderer. This is comptime chosen
/// so that every build has exactly one renderer implementation.
pub const Renderer = switch (build_config.renderer) {
    .metal => Metal,
    .opengl => OpenGL,
    .webgl => WebGL,
};

test {
    @import("std").testing.refAllDecls(@This());
}
