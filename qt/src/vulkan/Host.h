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
// via `instance()`. Requires a physical device that supports
// VK_KHR_external_memory_fd, VK_EXT_external_memory_dma_buf, and
// VK_EXT_image_drm_format_modifier — all three are needed for the
// dmabuf-as-importable-image export path libghostty's Vulkan
// renderer uses to hand frames back to the host.
//
// The compositor dmabuf modifier registry that this host's
// `get_supported_modifiers` callback reads is primed elsewhere
// (in `GhosttySurface`'s ctor on the GUI thread, via
// `wayland::primeDmabufModifierRegistry` from
// `qt/src/wayland/DmabufRegistry.h`). That priming is a Wayland
// concern and used to leak into `Host::instance`'s `call_once` —
// which made `Host` (a Vulkan object) responsible for a
// Wayland-protocol concern it doesn't otherwise touch.

#pragma once

#include <cstdint>
#include <memory>

#include <vulkan/vulkan.h>

#include "ghostty.h"

namespace vulkan {

/// Receiver for a presented dmabuf-backed frame. Implemented by
/// `GhosttySurface`; abstract so `vulkan::Host` doesn't need to
/// know about the widget type. Replaces an earlier cross-TU
/// forward declaration of a free function `presentToGhosttySurface`
/// that coupled `Host.cpp` directly to `GhosttySurface.cpp`.
class PresentSink {
public:
  virtual ~PresentSink() = default;
  /// Hand off a rendered frame. Called on the libghostty renderer
  /// thread; the implementation is responsible for marshalling to
  /// whatever thread it composites on. The fd is borrowed for the
  /// duration of the call — implementations that need to retain
  /// it must `dup()`.
  virtual void presentDmabuf(int dmabuf_fd, std::uint32_t drm_format,
                              std::uint64_t drm_modifier,
                              std::uint32_t width, std::uint32_t height,
                              std::uint32_t stride, bool image_backed) = 0;
};

/// Process-wide Vulkan setup. One per Ghastty process; threadsafe
/// to call `instance()` from anywhere (constructs once via
/// std::call_once on first access).
class Host {
public:
  /// Return the process-wide host, or nullptr if Vulkan can't be
  /// brought up on this system. Cached after the first call so
  /// repeated lookups are cheap.
  static Host *instance();

  /// Build a `ghostty_platform_vulkan_s` callback struct whose
  /// `present` callback delivers frames to `sink`. `sink` must
  /// outlive the lifetime of any libghostty surface that was
  /// configured with the returned platform struct. Other callbacks
  /// (handle lookups, modifier registry) ignore `sink` and route
  /// through the process singleton.
  ghostty_platform_vulkan_s asPlatform(PresentSink *sink) const;

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
