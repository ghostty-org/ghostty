//! Vulkan renderer (fork-only, in progress).
//!
//! This file is a placeholder. Selecting `-Drenderer=vulkan` currently
//! fails at comptime in `src/renderer.zig`'s `Renderer` switch with a
//! pointer back to the `qt-vulkan-renderer` branch. The scaffolding
//! that lets this file exist — the `Backend.vulkan` enum value, the
//! `GHOSTTY_PLATFORM_VULKAN` C API, and the apprt platform callbacks
//! in `src/apprt/embedded.zig` — has landed; the renderer body has
//! not.
//!
//! To bring the renderer up, this module must satisfy the contract
//! `GenericRenderer(impl)` (see `src/renderer/generic.zig`) consumes
//! from a backend, mirroring `OpenGL.zig` / `Metal.zig`:
//!
//!   pub const Target      = …/vulkan/Target.zig
//!   pub const Frame       = …/vulkan/Frame.zig
//!   pub const RenderPass  = …/vulkan/RenderPass.zig
//!   pub const Pipeline    = …/vulkan/Pipeline.zig
//!   pub const Buffer      = (from …/vulkan/buffer.zig)
//!   pub const Sampler     = …/vulkan/Sampler.zig
//!   pub const Texture     = …/vulkan/Texture.zig
//!   pub const shaders     = …/vulkan/shaders.zig
//!   pub const custom_shader_target: shadertoy.Target
//!   pub const custom_shader_y_is_down: bool
//!   pub const swap_chain_count: comptime_int
//!   pub fn init(alloc, opts) !Vulkan
//!   pub fn deinit(self: *Vulkan) void
//!   …plus the per-frame begin/end + atlas-upload + present hooks
//!
//! The apprt-side handle plumbing (`opts.rt_surface.platform.vulkan`)
//! is already wired and exposes:
//!
//!   - host-owned VkInstance / VkPhysicalDevice / VkDevice / VkQueue
//!     (libghostty does NOT destroy these)
//!   - `get_instance_proc_addr` to bootstrap the Vulkan loader
//!   - `present(dmabuf_fd, drm_format, drm_modifier, w, h, stride)`
//!     to hand a rendered frame to the host as a dmabuf (the host
//!     imports it without a CPU readback — e.g. into a Qt RHI
//!     QRhiTexture).
//!
//! Open design questions to resolve in follow-up commits:
//!   - shader pipeline: compile `src/renderer/shaders/glsl/*.glsl` to
//!     SPIR-V at build time via the glslang already vendored for
//!     `src/renderer/shadertoy.zig` (`GLSLANG_CLIENT_VULKAN`,
//!     `GLSLANG_TARGET_VULKAN_1_2`), then `@embedFile` the blobs.
//!   - external-memory format negotiation: pick a DRM format /
//!     modifier set that intersects what the host (Qt RHI) supports.
//!   - `must_draw_from_app_thread`: Vulkan is thread-friendly but the
//!     apprt API contract should be made explicit here.
//!
//! Submodules landed so far:
//!   - `vulkan/Device.zig` — wraps the host-provided VkInstance /
//!     VkPhysicalDevice / VkDevice / VkQueue. Validates the API
//!     version and required extensions, and resolves the function-
//!     pointer dispatch table. Re-exported as `Device` below.
//!
//! Binding: the Vulkan C API ships as the `vulkan` Zig module from
//! `pkg/vulkan/` (mirrors the `pkg/opengl/` pattern — a thin
//! `@cImport` wrapper over the system `vulkan/vulkan.h`). It is only
//! pulled into the dependency graph when `build_config.renderer ==
//! .vulkan` (see `src/build/SharedDeps.zig`), and libvulkan is
//! linked at the same gate.
//!
//! See the parity branch description in `qt/PARITY.md` once it lands.

pub const Device = @import("vulkan/Device.zig");
pub const Sampler = @import("vulkan/Sampler.zig");
pub const Texture = @import("vulkan/Texture.zig");
pub const CommandPool = @import("vulkan/CommandPool.zig");
pub const Pipeline = @import("vulkan/Pipeline.zig");
pub const shaders = @import("vulkan/shaders.zig");

const bufferpkg = @import("vulkan/buffer.zig");
pub const Buffer = bufferpkg.Buffer;
