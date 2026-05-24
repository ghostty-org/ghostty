// See `Host.h` for the contract.

#include "Host.h"

#include <array>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <optional>
#include <vector>

namespace vulkan {

namespace {

constexpr const char *kRequiredDeviceExtensions[] = {
    "VK_KHR_external_memory_fd",
    "VK_EXT_external_memory_dma_buf",
};

bool hasRequiredExtensions(VkPhysicalDevice pd) {
  uint32_t n = 0;
  vkEnumerateDeviceExtensionProperties(pd, nullptr, &n, nullptr);
  if (n == 0) return false;
  std::vector<VkExtensionProperties> exts(n);
  vkEnumerateDeviceExtensionProperties(pd, nullptr, &n, exts.data());
  for (const char *req : kRequiredDeviceExtensions) {
    bool found = false;
    for (const auto &e : exts) {
      if (std::strcmp(e.extensionName, req) == 0) {
        found = true;
        break;
      }
    }
    if (!found) return false;
  }
  return true;
}

std::optional<uint32_t> findGraphicsQueueFamily(VkPhysicalDevice pd) {
  uint32_t n = 0;
  vkGetPhysicalDeviceQueueFamilyProperties(pd, &n, nullptr);
  if (n == 0) return std::nullopt;
  std::vector<VkQueueFamilyProperties> props(n);
  vkGetPhysicalDeviceQueueFamilyProperties(pd, &n, props.data());
  for (uint32_t i = 0; i < n; ++i) {
    if (props[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) return i;
  }
  return std::nullopt;
}

// ---- Platform callback trampolines ----------------------------------
//
// `ghostty_platform_vulkan_s` is a plain C ABI; the callback
// signatures take a `void *userdata` that libghostty hands back to
// each callback. We use that as our `Host *`.

void *cbGetInstanceProcAddr(void *ud, const char *name) {
  auto *self = static_cast<Host *>(ud);
  // Cast through `void(*)()` to silence strict-aliasing concerns
  // about converting a function pointer to `void *` (the ABI we
  // exposed in include/ghostty.h returns `void *` for portability,
  // matching the OpenGL `get_proc_address` callback shape).
  auto fp = vkGetInstanceProcAddr(self->vkInstance(), name);
  return reinterpret_cast<void *>(fp);
}

void *cbInstance(void *ud) {
  return static_cast<Host *>(ud)->vkInstance();
}
void *cbPhysicalDevice(void *ud) {
  return static_cast<Host *>(ud)->vkPhysicalDevice();
}
void *cbDevice(void *ud) {
  return static_cast<Host *>(ud)->vkDevice();
}
void *cbQueue(void *ud) {
  return static_cast<Host *>(ud)->vkQueue();
}
uint32_t cbQueueFamilyIndex(void *ud) {
  return static_cast<Host *>(ud)->vkQueueFamilyIndex();
}

// Present: libghostty hands us the rendered frame as a dmabuf fd.
// For now this just logs — actual import + display via QRhiTexture
// is the next chunk of Qt-side work.
void cbPresent(
    void *ud,
    int dmabuf_fd,
    uint32_t drm_format,
    uint64_t drm_modifier,
    uint32_t width,
    uint32_t height,
    uint32_t stride) {
  (void)ud;
  std::fprintf(
      stderr,
      "[vulkan] present cb: fd=%d fourcc=0x%08x mod=0x%016lx %ux%u stride=%u\n",
      dmabuf_fd, drm_format, static_cast<unsigned long>(drm_modifier),
      width, height, stride);
}

} // namespace

bool Host::init() {
  // ---- instance ---------------------------------------------------
  VkApplicationInfo appInfo{};
  appInfo.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
  appInfo.pApplicationName = "ghastty";
  appInfo.applicationVersion = 1;
  appInfo.pEngineName = "ghastty";
  appInfo.engineVersion = 1;
  appInfo.apiVersion = VK_API_VERSION_1_3;

  VkInstanceCreateInfo instInfo{};
  instInfo.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
  instInfo.pApplicationInfo = &appInfo;
  if (vkCreateInstance(&instInfo, nullptr, &m_instance) != VK_SUCCESS) {
    std::fprintf(stderr, "[vulkan] vkCreateInstance failed\n");
    return false;
  }

  // ---- physical device -------------------------------------------
  uint32_t pdCount = 0;
  vkEnumeratePhysicalDevices(m_instance, &pdCount, nullptr);
  if (pdCount == 0) {
    std::fprintf(stderr, "[vulkan] no physical devices\n");
    return false;
  }
  std::vector<VkPhysicalDevice> pds(pdCount);
  vkEnumeratePhysicalDevices(m_instance, &pdCount, pds.data());

  for (auto pd : pds) {
    VkPhysicalDeviceProperties props;
    vkGetPhysicalDeviceProperties(pd, &props);
    if (props.apiVersion < VK_API_VERSION_1_3) continue;
    if (!hasRequiredExtensions(pd)) continue;
    auto qfi = findGraphicsQueueFamily(pd);
    if (!qfi) continue;
    m_physicalDevice = pd;
    m_queueFamilyIndex = *qfi;
    break;
  }
  if (m_physicalDevice == VK_NULL_HANDLE) {
    std::fprintf(stderr,
                 "[vulkan] no suitable physical device "
                 "(need Vulkan 1.3 + external_memory_fd + dma_buf)\n");
    return false;
  }

  // ---- logical device + queue ------------------------------------
  float queuePriority = 1.0f;
  VkDeviceQueueCreateInfo qci{};
  qci.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
  qci.queueFamilyIndex = m_queueFamilyIndex;
  qci.queueCount = 1;
  qci.pQueuePriorities = &queuePriority;

  VkDeviceCreateInfo dci{};
  dci.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
  dci.queueCreateInfoCount = 1;
  dci.pQueueCreateInfos = &qci;
  dci.enabledExtensionCount =
      static_cast<uint32_t>(std::size(kRequiredDeviceExtensions));
  dci.ppEnabledExtensionNames = kRequiredDeviceExtensions;

  if (vkCreateDevice(m_physicalDevice, &dci, nullptr, &m_device) != VK_SUCCESS) {
    std::fprintf(stderr, "[vulkan] vkCreateDevice failed\n");
    return false;
  }

  vkGetDeviceQueue(m_device, m_queueFamilyIndex, 0, &m_queue);

  VkPhysicalDeviceProperties props;
  vkGetPhysicalDeviceProperties(m_physicalDevice, &props);
  std::fprintf(stderr,
               "[vulkan] device ready: %s (Vulkan %u.%u.%u, qfi=%u)\n",
               props.deviceName,
               VK_API_VERSION_MAJOR(props.apiVersion),
               VK_API_VERSION_MINOR(props.apiVersion),
               VK_API_VERSION_PATCH(props.apiVersion),
               m_queueFamilyIndex);
  return true;
}

Host::~Host() {
  if (m_device != VK_NULL_HANDLE) vkDestroyDevice(m_device, nullptr);
  if (m_instance != VK_NULL_HANDLE) vkDestroyInstance(m_instance, nullptr);
}

ghostty_platform_vulkan_s Host::asPlatform(void *userdata) const {
  (void)userdata;
  ghostty_platform_vulkan_s p{};
  p.userdata = const_cast<Host *>(this);
  p.get_instance_proc_addr = cbGetInstanceProcAddr;
  p.instance = cbInstance;
  p.physical_device = cbPhysicalDevice;
  p.device = cbDevice;
  p.queue = cbQueue;
  p.queue_family_index = cbQueueFamilyIndex;
  p.present = cbPresent;
  return p;
}

Host *Host::instance() {
  static std::once_flag once;
  static std::unique_ptr<Host> host;
  std::call_once(once, []() {
    auto candidate = std::unique_ptr<Host>(new Host());
    if (candidate->init()) {
      host = std::move(candidate);
    }
    // candidate's destructor runs on init failure and cleans up
    // any partial state.
  });
  return host.get();
}

} // namespace vulkan
