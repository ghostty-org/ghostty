# Vulkan renderer backend

This directory holds the **renderer-policy** Vulkan files for libghostty.
Pure Vulkan-API wrappers (Device dispatch table, Sampler, CommandPool,
DescriptorPool) live in `pkg/vulkan/`, mirroring how `pkg/opengl/`
relates to `src/renderer/opengl/`.

## File layout

Renderer policy (this directory):

| File                | OpenGL counterpart        | Notes                                                              |
| ------------------- | ------------------------- | ------------------------------------------------------------------ |
| `Target.zig`        | `opengl/Target.zig`       | Render image + dmabuf export (direct or legacy_copy mode).         |
| `Texture.zig`       | `opengl/Texture.zig`      | `VkImage` + `VkImageView` + upload helpers for the glyph atlas.    |
| `buffer.zig`        | `opengl/buffer.zig`       | `Buffer(T)` host-coherent.                                         |
| `buffer_pool.zig`   | (none — GL implicit)      | Cross-frame `VkBuffer` recycle pool, per-thread pending list.      |
| `ThreadState.zig`   | (none — GL implicit)      | Per-renderer-thread frame fence / CB / descriptor pool / last-tgt. |
| `Pipeline.zig`      | `opengl/Pipeline.zig`     | Graphics pipeline + descriptor set layout creation.                |
| `RenderPass.zig`    | `opengl/RenderPass.zig`   | Dynamic-rendering pass + step recorder.                            |
| `Frame.zig`         | `opengl/Frame.zig`        | Per-draw command buffer + fence-paced submit-then-wait.            |
| `shaders.zig`       | `opengl/shaders.zig`      | GLSL → SPIR-V via glslang + the OpenGL-GLSL → Vulkan-GLSL rewrite. |

Pure Vulkan-API wrappers (in `pkg/vulkan/`):

| File                  | OpenGL counterpart       | Notes                                                              |
| --------------------- | ------------------------ | ------------------------------------------------------------------ |
| `Device.zig`          | (no analogue — GL ctx)   | Host-provided VkInstance/Device/Queue + function dispatch table.   |
| `Sampler.zig`         | `pkg/opengl/Sampler.zig` | `VkSampler` (linear for atlases, nearest for cells).               |
| `CommandPool.zig`     | (none)                   | `VkCommandPool` + one-shot record/submit helper.                   |
| `DescriptorPool.zig`  | (none)                   | Per-frame `VkDescriptorPool`.                                      |

The renderer's top-level lives one directory up at `../Vulkan.zig`
and is the single module imported by `src/renderer.zig` when
`build_config.renderer == .vulkan`. It re-exports the `pkg/vulkan/`
types as `Vulkan.Device`, `Vulkan.Sampler`, etc., so call sites use a
single `Vulkan.*` namespace regardless of where each type physically
lives.

## Why dmabuf, not Vulkan swapchains?

The Qt frontend wants to keep `GhosttySurface` as a `QWidget` so that
splits (`QSplitter`), tabs (`QTabWidget`), and translucent composition
keep working. That rules out `QVulkanWindow`. Instead libghostty
exports the rendered `VkImage` memory as a dmabuf fd
(`VK_KHR_external_memory_fd` + `VK_EXT_image_drm_format_modifier`); the
Qt side imports it via `zwp_linux_dmabuf_v1` and attaches it to a
`wl_subsurface` parented to the top-level `wl_surface`. The compositor
scans the buffer out directly — no readback, no QImage round trip.
