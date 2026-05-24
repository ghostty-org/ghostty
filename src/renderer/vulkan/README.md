# Vulkan renderer backend (fork-only, in progress)

This directory will hold the Vulkan analogues of the per-backend
files that live in `../opengl/` and `../metal/`:

| File           | Counterpart in `../opengl/`         | Notes                                                              |
| -------------- | ----------------------------------- | ------------------------------------------------------------------ |
| `buffer.zig`   | `opengl/buffer.zig`                 | Vertex / uniform buffers backed by `VkBuffer` + `VkDeviceMemory`.  |
| `Pipeline.zig` | `opengl/Pipeline.zig`               | Graphics pipeline + descriptor set layout creation.                |
| `RenderPass.zig` | `opengl/RenderPass.zig`           | `VkRenderPass` + framebuffer setup for the cell-bg / text passes.  |
| `Sampler.zig`  | `opengl/Sampler.zig`                | `VkSampler` (linear for atlases, nearest for cells).               |
| `Target.zig`   | `opengl/Target.zig`                 | Render target image + view (exportable for dmabuf handoff).        |
| `Texture.zig`  | `opengl/Texture.zig`                | `VkImage` + `VkImageView` + upload helpers for the glyph atlas.    |
| `Frame.zig`    | `opengl/Frame.zig`                  | Per-frame command buffer + sync primitives (semaphores / fences).  |
| `shaders.zig`  | `opengl/shaders.zig`                | Loader for the SPIR-V blobs (built at compile time via glslang).   |

The renderer's top-level lives one directory up at
`../Vulkan.zig` and is the single module imported by
`src/renderer.zig` when `build_config.renderer == .vulkan`. That file
currently fails at comptime with a pointer back to the
`qt-vulkan-renderer` branch — see its header comment for the full
contract `GenericRenderer(Vulkan)` expects this directory's modules
to satisfy.

## Why dmabuf, not Vulkan swapchains?

The Qt frontend wants to keep `GhosttySurface` as a `QWidget` so that
splits (`QSplitter`), tabs (`QTabWidget`), and translucent composition
keep working. That rules out `QVulkanWindow`. Instead libghostty
exports the rendered `VkImage` memory as a dmabuf fd
(`VK_KHR_external_memory_fd`); the Qt side imports it as a
`QRhiTexture` in a `QRhiWidget` and composites it like any other
GPU-backed widget. This gives us Vulkan GPU rendering without losing
the widget tree — the path 3 ("zero-copy GPU interop") described in
the session-log on the `qt-vulkan-renderer` branch.
