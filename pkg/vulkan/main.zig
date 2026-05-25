//! Vulkan bindings.
//!
//! Shaped after `pkg/opengl/`: `c` is the raw C API (a thin `@cImport`
//! wrapper around the system Vulkan headers); the per-resource files
//! alongside provide opinionated typed wrappers the renderer
//! consumes as primitives.
//!
//! The Vulkan renderer in `src/renderer/vulkan/` builds renderer
//! policy on top of these (Pipeline / RenderPass / Frame / Target
//! etc.); anything that's pure Vulkan-API plumbing belongs here.
//!
//! Vulkan core API + the dmabuf-related extensions the renderer relies
//! on for zero-copy presentation:
//!
//!   - VK_KHR_external_memory / VK_KHR_external_memory_fd
//!   - VK_EXT_external_memory_dma_buf
//!   - VK_EXT_image_drm_format_modifier
//!
//! VK_USE_PLATFORM_* macros are intentionally NOT set in `c.zig` —
//! libghostty talks to its host purely via dmabuf fds (handed back to
//! the apprt's `ghostty_platform_vulkan_s.present` callback), so it
//! never sees a `wl_display` or `xcb_connection`. That keeps the
//! binding portable and lets the host (Qt RHI) do all the
//! platform-specific compositing.

pub const c = @import("c.zig").c;
pub const Device = @import("Device.zig");
pub const Sampler = @import("Sampler.zig");
pub const CommandPool = @import("CommandPool.zig");
pub const DescriptorPool = @import("DescriptorPool.zig");
