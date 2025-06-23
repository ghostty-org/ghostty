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

const cursor = @import("renderer/cursor.zig");
const message = @import("renderer/message.zig");
const size = @import("renderer/size.zig");
pub const shadertoy = @import("renderer/shadertoy.zig");
pub const GenericRenderer = @import("renderer/generic.zig").Renderer;
pub const Metal = @import("renderer/Metal.zig");
pub const OpenGL = @import("renderer/OpenGL.zig");
pub const WebGL = @import("renderer/WebGL.zig");
pub const Options = @import("renderer/Options.zig");
pub const Thread = @import("renderer/Thread.zig");
pub const State = @import("renderer/State.zig");
pub const CursorStyle = cursor.Style;
pub const Message = message.Message;
pub const Size = size.Size;
pub const Coordinate = size.Coordinate;
pub const CellSize = size.CellSize;
pub const ScreenSize = size.ScreenSize;
pub const GridSize = size.GridSize;
pub const Padding = size.Padding;
pub const cursorStyle = cursor.style;

/// Possible implementations, used for build options.
pub const Impl = enum {
    opengl,
    metal,
    webgl,

    pub fn default(
        target: std.Target,
        wasm_target: WasmTarget,
    ) Impl {
        if (target.cpu.arch == .wasm32) {
            return switch (wasm_target) {
                .browser => .webgl,
            };
        }

        if (target.os.tag.isDarwin()) return .metal;
        return .opengl;
    }
};

/// The implementation to use for the renderer. This is comptime chosen
/// so that every build has exactly one renderer implementation.
pub const Renderer = switch (build_config.renderer) {
    .metal => GenericRenderer(Metal),
    .opengl => GenericRenderer(OpenGL),
    .webgl => WebGL,
};

/// The health status of a renderer. These must be shared across all
/// renderers even if some states aren't reachable so that our API users
/// can use the same enum for all renderers.
pub const Health = enum(c_int) {
    healthy = 0,
    unhealthy = 1,
};

test {
    // Our comptime-chosen renderer
    _ = Renderer;

    _ = cursor;
    _ = message;
    _ = shadertoy;
    _ = size;
    _ = Thread;
    _ = State;
}
