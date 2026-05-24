// Vulkan host setup for the Ghastty Qt frontend.
//
// libghostty (when built with `-Drenderer=vulkan`) doesn't create
// its own VkInstance / VkDevice — the host does, then hands the
// handles down via the `ghostty_platform_vulkan_s` callback struct
// declared in `include/ghostty.h`. This class is the Qt-side owner
// of those handles.
//
// The host is process-singleton (one Vulkan instance + device shared
// across every `GhosttySurface`), constructed lazily on first use
// via `instance()`. If Vulkan isn't available (no loader, no
// suitable physical device with `VK_KHR_external_memory_fd` +
// `VK_EXT_external_memory_dma_buf`), construction fails gracefully
// and the caller falls back to the OpenGL path.

#pragma once

#include <cstdint>
#include <memory>

#include <vulkan/vulkan.h>

#include "ghostty.h"

namespace vulkan {

/// Process-wide Vulkan setup. One per Ghastty process; threadsafe
/// to call `instance()` from anywhere (constructs once via
/// std::call_once on first access).
class Host {
public:
  /// Return the process-wide host, or nullptr if Vulkan can't be
  /// brought up on this system. Cached after the first call so
  /// repeated lookups are cheap.
  static Host *instance();

  /// Build a `ghostty_platform_vulkan_s` callback struct populated
  /// with this host's handles. `surface_userdata` is round-tripped
  /// through as the `userdata` field — used by the `present`
  /// callback to identify which `GhosttySurface` the dmabuf is for.
  /// The other handle-lookup callbacks ignore it and route through
  /// `Host::instance()`.
  ghostty_platform_vulkan_s asPlatform(void *surface_userdata) const;

  VkInstance vkInstance() const { return m_instance; }
  VkPhysicalDevice vkPhysicalDevice() const { return m_physicalDevice; }
  VkDevice vkDevice() const { return m_device; }
  VkQueue vkQueue() const { return m_queue; }
  uint32_t vkQueueFamilyIndex() const { return m_queueFamilyIndex; }

  ~Host();

  // No copy/move — singleton.
  Host(const Host &) = delete;
  Host &operator=(const Host &) = delete;

private:
  Host() = default;
  bool init();

  VkInstance m_instance = VK_NULL_HANDLE;
  VkPhysicalDevice m_physicalDevice = VK_NULL_HANDLE;
  VkDevice m_device = VK_NULL_HANDLE;
  VkQueue m_queue = VK_NULL_HANDLE;
  uint32_t m_queueFamilyIndex = 0;
};

} // namespace vulkan
