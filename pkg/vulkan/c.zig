// Vulkan core API + the dmabuf-related extensions the renderer relies
// on for zero-copy presentation:
//
//   - VK_KHR_external_memory / VK_KHR_external_memory_fd
//   - VK_EXT_external_memory_dma_buf
//   - VK_EXT_image_drm_format_modifier
//
// VK_USE_PLATFORM_* macros are intentionally NOT set here — the
// renderer talks to its host purely via dmabuf fds (handed back to
// the apprt's `ghostty_platform_vulkan_s.present` callback), so
// libghostty never sees a wl_display or xcb_connection. That keeps
// the binding portable and lets the host (Qt RHI) do all the
// platform-specific compositing.
pub const c = @cImport({
    @cInclude("vulkan/vulkan.h");
});
