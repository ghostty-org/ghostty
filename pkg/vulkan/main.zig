//! Vulkan loader bindings.
//!
//! Lightweight `@cImport` wrapper around the system Vulkan headers,
//! shaped after `pkg/opengl/`. `c` is the raw C API; higher-level
//! Zig helpers go alongside as the renderer needs them.

pub const c = @import("c.zig").c;
