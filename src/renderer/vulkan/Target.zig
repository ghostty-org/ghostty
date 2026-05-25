//! Render target: a `VkImage` whose memory is exported as a dmabuf
//! fd so the host (Qt) can present it via
//! `ghostty_platform_vulkan_s.present` without a CPU readback round
//! trip through libghostty.
//!
//! Two construction modes, picked at `init` time after probing
//! `VK_EXT_image_drm_format_modifier`:
//!
//!   - `.direct` — the render image itself is allocated with
//!     `VkImageDrmFormatModifierExplicitCreateInfoEXT`
//!     (`DRM_FORMAT_MOD_LINEAR`, single plane). Its `VkDeviceMemory`
//!     is what we `vkGetMemoryFdKHR` and hand to the host. No second
//!     allocation, no end-of-frame copy. Used when the driver
//!     advertises `COLOR_ATTACHMENT_BIT | TRANSFER_SRC_BIT |
//!     SAMPLED_BIT` for the LINEAR modifier in
//!     `VkDrmFormatModifierPropertiesEXT.drmFormatModifierTilingFeatures`.
//!
//!   - `.legacy_copy` — fallback for drivers (notably NVIDIA at time
//!     of writing) that don't expose `COLOR_ATTACHMENT_BIT` for
//!     LINEAR via either the legacy `vkGetPhysicalDeviceFormatProperties`
//!     query or the modifier-extension query. Allocates an OPTIMAL-
//!     tiled render image plus a separate dmabuf-exported LINEAR
//!     `VkBuffer`, and inserts a `vkCmdCopyImageToBuffer` at the end
//!     of each frame. Behavior identical to the pre-modifier-path
//!     code.
//!
//! Why two modes? NVIDIA's `linearTilingFeatures` for BGRA8 doesn't
//! include `COLOR_ATTACHMENT_BIT`, so a LINEAR `VkImage` silently
//! rasterizes nothing (confirmed via
//! `vkGetPhysicalDeviceFormatProperties`: linearTilingFeatures=0x1dc03
//! for `B8G8R8A8_UNORM`). The modifier-extension query is a separate
//! channel and *may* expose different feature bits per modifier — so
//! we always probe. Where the probe says yes, we drop the redundant
//! buffer + copy; where it says no, we keep working.
//!
//! Ownership: libghostty owns the image, any buffer, all memory, and
//! the dmabuf fd for the lifetime of the `Target`. The fd is passed
//! to the host via `present` as a borrow; the host must `dup()` if
//! it needs to hold it past the call. `deinit` closes the fd and
//! frees all the memory.
//!
//! Counterpart: `src/renderer/opengl/Target.zig`.

const Self = @This();

const std = @import("std");
const vk = @import("vulkan").c;

const apprt = @import("../../apprt.zig");
const Device = @import("Device.zig");

const log = std.log.scoped(.vulkan);

/// DRM modifier sentinel for "linear, no tiling". Matches
/// `DRM_FORMAT_MOD_LINEAR` from `<drm/drm_fourcc.h>`. Hardcoded so we
/// don't pull in libdrm headers just for a single constant.
pub const DRM_FORMAT_MOD_LINEAR: u64 = 0;

/// Upper bound for the number of DRM format modifiers we ever expect
/// a driver to expose for a single format. Real-world drivers expose
/// well under 20 (mostly LINEAR + a handful of vendor tiled variants);
/// 64 gives us comfortable headroom with a ~1.5 KiB stack buffer and
/// avoids allocator threading through the per-surface init path.
const MAX_MODIFIERS: usize = 64;

/// Which dmabuf-export strategy this `Target` settled on. See the
/// module-level doc comment for the full rationale.
pub const Tiling = enum {
    /// Render image's own memory is exported as the dmabuf. Single
    /// plane, `DRM_FORMAT_MOD_LINEAR`. No separate buffer, no copy.
    direct,

    /// OPTIMAL render image + separate LINEAR `VkBuffer` dmabuf
    /// target. End-of-frame `vkCmdCopyImageToBuffer`. Used when
    /// neither tiling channel exposes `COLOR_ATTACHMENT_BIT` for
    /// LINEAR.
    legacy_copy,
};

pub const Options = struct {
    device: *const Device,
    format: vk.VkFormat,
    width: u32,
    height: u32,
    /// Extra `VkImageUsageFlagBits` for the render image, beyond the
    /// defaults (`COLOR_ATTACHMENT_BIT | SAMPLED_BIT |
    /// TRANSFER_SRC_BIT`). Rarely needed.
    extra_usage: vk.VkImageUsageFlags = 0,

    /// Per-surface platform callbacks. `Device.platform` is also a
    /// `Platform.Vulkan`, but it's the singleton's copy — its
    /// `userdata` points at whichever surface initialized the
    /// device first. Splits/tabs share the device but each gets its
    /// own platform with the right `userdata`, so `present()` reaches
    /// the right window. Falls back to `device.platform` when
    /// null (e.g. smoke test).
    platform: ?apprt.embedded.Platform.Vulkan = null,
};

pub const Error = error{
    VulkanFailed,
    NoSuitableMemoryType,
    UnsupportedFormat,
};

device: *const Device,

/// Per-surface platform — see `Options.platform`. Null means "use
/// `device.platform`" (the singleton's copy from the first surface).
platform: ?apprt.embedded.Platform.Vulkan = null,

/// Which present strategy this target uses. Decides whether
/// `recordPresentBarrier` emits a copy.
tiling: Tiling,

// ---- render image ---------------------------------------------------
// In `.direct` mode this image's memory is the dmabuf; in
// `.legacy_copy` mode it's internal OPTIMAL memory we copy out of.
image: vk.VkImage,
image_memory: vk.VkDeviceMemory,
view: vk.VkImageView,

// ---- dmabuf buffer (legacy mode only) -------------------------------
// `null` in `.direct` mode — the image's memory is the dmabuf.
dmabuf_buffer: ?vk.VkBuffer,
dmabuf_memory: ?vk.VkDeviceMemory,

format: vk.VkFormat,
width: u32,
height: u32,

fd: i32,
drm_format: u32,
drm_modifier: u64,
stride: u32,

/// Current layout of the render image. Tracked so
/// `recordPresentBarrier` knows what oldLayout to use in its barrier.
/// The renderer transitions it elsewhere too (RenderPass).
layout: vk.VkImageLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,

pub fn init(opts: Options) Error!Self {
    const dev = opts.device;
    const drm_format = try vkFormatToDrmFourcc(opts.format);

    const required_features: vk.VkFormatFeatureFlags =
        @as(vk.VkFormatFeatureFlags, vk.VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT) |
        vk.VK_FORMAT_FEATURE_TRANSFER_SRC_BIT |
        vk.VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT;

    if (try probeLinearModifierSupported(dev, opts.format, required_features)) {
        log.info(
            "Target: direct dmabuf export (LINEAR modifier) {}x{}",
            .{ opts.width, opts.height },
        );
        return try initDirect(opts, drm_format);
    } else {
        log.warn(
            "Target: LINEAR modifier lacks COLOR_ATTACHMENT support; " ++
                "falling back to OPTIMAL render + LINEAR-buffer copy",
            .{},
        );
        return try initLegacyCopy(opts, drm_format);
    }
}

/// Ask the driver, via `VK_EXT_image_drm_format_modifier`'s
/// per-modifier feature list, whether `DRM_FORMAT_MOD_LINEAR`
/// supports the format-feature flags we need to use the image as a
/// color attachment + transfer source + sampled.
fn probeLinearModifierSupported(
    dev: *const Device,
    format: vk.VkFormat,
    required_features: vk.VkFormatFeatureFlags,
) Error!bool {
    var mods: [MAX_MODIFIERS]vk.VkDrmFormatModifierPropertiesEXT = undefined;

    // First pass: get count.
    var mod_list: vk.VkDrmFormatModifierPropertiesListEXT = .{
        .sType = vk.VK_STRUCTURE_TYPE_DRM_FORMAT_MODIFIER_PROPERTIES_LIST_EXT,
        .pNext = null,
        .drmFormatModifierCount = 0,
        .pDrmFormatModifierProperties = null,
    };
    var props2: vk.VkFormatProperties2 = .{
        .sType = vk.VK_STRUCTURE_TYPE_FORMAT_PROPERTIES_2,
        .pNext = &mod_list,
        .formatProperties = std.mem.zeroes(vk.VkFormatProperties),
    };
    dev.dispatch.getPhysicalDeviceFormatProperties2(
        dev.physical_device,
        format,
        &props2,
    );

    if (mod_list.drmFormatModifierCount == 0) return false;
    if (mod_list.drmFormatModifierCount > MAX_MODIFIERS) {
        // Cap to our stack buffer; we only look for LINEAR (which
        // tends to be first or close to it), so a truncation here is
        // very unlikely to hide it. Log if we ever hit this.
        log.warn(
            "modifier list truncated: driver reports {}, MAX_MODIFIERS={}",
            .{ mod_list.drmFormatModifierCount, MAX_MODIFIERS },
        );
        mod_list.drmFormatModifierCount = MAX_MODIFIERS;
    }

    // Second pass: fill list.
    mod_list.pDrmFormatModifierProperties = &mods[0];
    dev.dispatch.getPhysicalDeviceFormatProperties2(
        dev.physical_device,
        format,
        &props2,
    );

    for (mods[0..mod_list.drmFormatModifierCount]) |m| {
        if (m.drmFormatModifier != DRM_FORMAT_MOD_LINEAR) continue;
        // Single-plane only — multi-plane modifiers need a wider
        // present-callback ABI (one fd/offset/stride per plane).
        if (m.drmFormatModifierPlaneCount != 1) continue;
        if ((m.drmFormatModifierTilingFeatures & required_features) == required_features) {
            return true;
        }
    }
    return false;
}

/// `.direct` mode: allocate the render image with
/// `VkImageDrmFormatModifierExplicitCreateInfoEXT` and export its own
/// memory as the dmabuf.
fn initDirect(opts: Options, drm_format: u32) Error!Self {
    const dev = opts.device;

    const image_usage = @as(vk.VkImageUsageFlags, vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT) |
        vk.VK_IMAGE_USAGE_SAMPLED_BIT |
        vk.VK_IMAGE_USAGE_TRANSFER_SRC_BIT |
        opts.extra_usage;

    // BGRA8, single-plane LINEAR — rowPitch is just width * bpp.
    const bytes_per_pixel: u32 = 4;
    const row_pitch: vk.VkDeviceSize = @as(vk.VkDeviceSize, opts.width) * bytes_per_pixel;

    // ---- 1. Image: LINEAR-modifier, externally-shareable -----------
    const plane_layout: vk.VkSubresourceLayout = .{
        .offset = 0,
        .size = 0, // ignored for EXPLICIT create-info
        .rowPitch = row_pitch,
        .arrayPitch = 0,
        .depthPitch = 0,
    };
    const mod_create: vk.VkImageDrmFormatModifierExplicitCreateInfoEXT = .{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_EXPLICIT_CREATE_INFO_EXT,
        .pNext = null,
        .drmFormatModifier = DRM_FORMAT_MOD_LINEAR,
        .drmFormatModifierPlaneCount = 1,
        .pPlaneLayouts = &plane_layout,
    };
    const ext_image_info: vk.VkExternalMemoryImageCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO,
        .pNext = &mod_create,
        .handleTypes = vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
    };
    const image_info: vk.VkImageCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .pNext = &ext_image_info,
        .flags = 0,
        .imageType = vk.VK_IMAGE_TYPE_2D,
        .format = opts.format,
        .extent = .{ .width = opts.width, .height = opts.height, .depth = 1 },
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = vk.VK_SAMPLE_COUNT_1_BIT,
        .tiling = vk.VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT,
        .usage = image_usage,
        .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
        .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
    };
    var image: vk.VkImage = undefined;
    if (dev.dispatch.createImage(dev.device, &image_info, null, &image) != vk.VK_SUCCESS) {
        log.err("vkCreateImage (Target direct) failed", .{});
        return error.VulkanFailed;
    }
    errdefer dev.dispatch.destroyImage(dev.device, image, null);

    // ---- 2. Image memory: exportable, host-cacheable for Qt mmap ---
    var image_reqs: vk.VkMemoryRequirements = undefined;
    dev.dispatch.getImageMemoryRequirements(dev.device, image, &image_reqs);

    // HOST_CACHED matters: Qt's `presentVulkanDmabuf` mmaps and reads
    // every pixel into a QImage. Without HOST_CACHED, NVIDIA hands
    // back write-combining memory and that read crawls (see legacy
    // path note for the ~260 ms regression we hit). HOST_COHERENT
    // avoids explicit flushes. Fall back to uncached if cached isn't
    // available for the memory type bits the image requires.
    const host_flags_cached =
        @as(vk.VkMemoryPropertyFlags, vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) |
        vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT |
        vk.VK_MEMORY_PROPERTY_HOST_CACHED_BIT;
    const host_flags_uncached =
        @as(vk.VkMemoryPropertyFlags, vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) |
        vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    const image_mem_idx = dev.findMemoryType(image_reqs.memoryTypeBits, host_flags_cached) orelse
        dev.findMemoryType(image_reqs.memoryTypeBits, host_flags_uncached) orelse
        {
            log.err(
                "no HOST_VISIBLE memory type for direct dmabuf image (typeBits=0x{x})",
                .{image_reqs.memoryTypeBits},
            );
            return error.NoSuitableMemoryType;
        };
    const export_info: vk.VkExportMemoryAllocateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO,
        .pNext = null,
        .handleTypes = vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
    };
    const image_alloc: vk.VkMemoryAllocateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .pNext = &export_info,
        .allocationSize = image_reqs.size,
        .memoryTypeIndex = image_mem_idx,
    };
    var image_memory: vk.VkDeviceMemory = undefined;
    if (dev.dispatch.allocateMemory(dev.device, &image_alloc, null, &image_memory) != vk.VK_SUCCESS) {
        log.err("vkAllocateMemory (Target direct image) failed", .{});
        return error.VulkanFailed;
    }
    errdefer dev.dispatch.freeMemory(dev.device, image_memory, null);
    if (dev.dispatch.bindImageMemory(dev.device, image, image_memory, 0) != vk.VK_SUCCESS) {
        log.err("vkBindImageMemory (Target direct image) failed", .{});
        return error.VulkanFailed;
    }

    // ---- 3. View ---------------------------------------------------
    const view = try createView(dev, image, opts.format);
    errdefer dev.dispatch.destroyImageView(dev.device, view, null);

    // ---- 4. Export memory as dmabuf fd -----------------------------
    const fd = try exportDmabufFd(dev, image_memory);
    errdefer std.posix.close(fd);

    // ---- 5. Query the actual plane stride --------------------------
    // We requested rowPitch = width * 4 via EXPLICIT create-info, but
    // the driver can technically round up; ask for what we actually got.
    var subres: vk.VkImageSubresource = .{
        .aspectMask = vk.VK_IMAGE_ASPECT_MEMORY_PLANE_0_BIT_EXT,
        .mipLevel = 0,
        .arrayLayer = 0,
    };
    var layout: vk.VkSubresourceLayout = undefined;
    dev.dispatch.getImageSubresourceLayout(dev.device, image, &subres, &layout);

    return .{
        .device = dev,
        .platform = opts.platform,
        .tiling = .direct,
        .image = image,
        .image_memory = image_memory,
        .view = view,
        .dmabuf_buffer = null,
        .dmabuf_memory = null,
        .format = opts.format,
        .width = opts.width,
        .height = opts.height,
        .fd = fd,
        .drm_format = drm_format,
        .drm_modifier = DRM_FORMAT_MOD_LINEAR,
        .stride = @intCast(layout.rowPitch),
    };
}

/// `.legacy_copy` mode: OPTIMAL render image + separate LINEAR
/// dmabuf-exported `VkBuffer`. Behavior identical to the
/// pre-modifier-path code.
fn initLegacyCopy(opts: Options, drm_format: u32) Error!Self {
    const dev = opts.device;

    // BGRA8 — 4 bytes/pixel, packed (no per-row padding).
    const bytes_per_pixel: u32 = 4;
    const stride: u32 = opts.width * bytes_per_pixel;
    const buffer_size: vk.VkDeviceSize = @as(vk.VkDeviceSize, stride) * opts.height;

    // ---- 1. Render image: OPTIMAL tiling, internal memory ----------
    const image_usage = @as(vk.VkImageUsageFlags, vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT) |
        vk.VK_IMAGE_USAGE_SAMPLED_BIT |
        vk.VK_IMAGE_USAGE_TRANSFER_SRC_BIT |
        opts.extra_usage;
    const image_info: vk.VkImageCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .imageType = vk.VK_IMAGE_TYPE_2D,
        .format = opts.format,
        .extent = .{ .width = opts.width, .height = opts.height, .depth = 1 },
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = vk.VK_SAMPLE_COUNT_1_BIT,
        .tiling = vk.VK_IMAGE_TILING_OPTIMAL,
        .usage = image_usage,
        .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
        .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
    };
    var image: vk.VkImage = undefined;
    if (dev.dispatch.createImage(dev.device, &image_info, null, &image) != vk.VK_SUCCESS) {
        log.err("vkCreateImage (Target legacy render) failed", .{});
        return error.VulkanFailed;
    }
    errdefer dev.dispatch.destroyImage(dev.device, image, null);

    var image_reqs: vk.VkMemoryRequirements = undefined;
    dev.dispatch.getImageMemoryRequirements(dev.device, image, &image_reqs);
    const image_mem_idx = dev.findMemoryType(
        image_reqs.memoryTypeBits,
        vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
    ) orelse return error.NoSuitableMemoryType;
    const image_alloc: vk.VkMemoryAllocateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .pNext = null,
        .allocationSize = image_reqs.size,
        .memoryTypeIndex = image_mem_idx,
    };
    var image_memory: vk.VkDeviceMemory = undefined;
    if (dev.dispatch.allocateMemory(dev.device, &image_alloc, null, &image_memory) != vk.VK_SUCCESS) {
        log.err("vkAllocateMemory (Target legacy render image) failed", .{});
        return error.VulkanFailed;
    }
    errdefer dev.dispatch.freeMemory(dev.device, image_memory, null);
    if (dev.dispatch.bindImageMemory(dev.device, image, image_memory, 0) != vk.VK_SUCCESS) {
        log.err("vkBindImageMemory (Target legacy render image) failed", .{});
        return error.VulkanFailed;
    }

    // ---- 2. View ---------------------------------------------------
    const view = try createView(dev, image, opts.format);
    errdefer dev.dispatch.destroyImageView(dev.device, view, null);

    // ---- 3. Dmabuf buffer: LINEAR pixel data, external memory -----
    const ext_buffer_info: vk.VkExternalMemoryBufferCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_BUFFER_CREATE_INFO,
        .pNext = null,
        .handleTypes = vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
    };
    const buffer_info: vk.VkBufferCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .pNext = &ext_buffer_info,
        .flags = 0,
        .size = buffer_size,
        .usage = vk.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
    };
    var dmabuf_buffer: vk.VkBuffer = undefined;
    if (dev.dispatch.createBuffer(dev.device, &buffer_info, null, &dmabuf_buffer) != vk.VK_SUCCESS) {
        log.err("vkCreateBuffer (Target dmabuf) failed", .{});
        return error.VulkanFailed;
    }
    errdefer dev.dispatch.destroyBuffer(dev.device, dmabuf_buffer, null);

    var buf_reqs: vk.VkMemoryRequirements = undefined;
    dev.dispatch.getBufferMemoryRequirements(dev.device, dmabuf_buffer, &buf_reqs);
    // Prefer HOST_CACHED so reads from the mmap'd dmabuf are fast.
    // Without it (HOST_VISIBLE | HOST_COHERENT only), NVIDIA gives
    // back write-combining memory: GPU writes are fast but HOST reads
    // crawl (~10 MB/s) because the mapping is uncached. The Qt
    // `presentVulkanDmabuf` `QImage::copy()` reads every pixel, so a
    // small ~3 MB frame took ~260 ms there. HOST_COHERENT is still
    // requested so we don't need explicit flushes between GPU writes
    // and host reads; HOST_CACHED on top makes the host reads
    // cacheable.
    const host_flags_cached =
        @as(vk.VkMemoryPropertyFlags, vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) |
        vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT |
        vk.VK_MEMORY_PROPERTY_HOST_CACHED_BIT;
    const host_flags_uncached =
        @as(vk.VkMemoryPropertyFlags, vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) |
        vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    const dmabuf_mem_idx = dev.findMemoryType(buf_reqs.memoryTypeBits, host_flags_cached) orelse
        dev.findMemoryType(buf_reqs.memoryTypeBits, host_flags_uncached) orelse
        {
            log.err(
                "no HOST_VISIBLE memory type for dmabuf (typeBits=0x{x})",
                .{buf_reqs.memoryTypeBits},
            );
            return error.NoSuitableMemoryType;
        };
    const export_info: vk.VkExportMemoryAllocateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO,
        .pNext = null,
        .handleTypes = vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
    };
    const buf_alloc: vk.VkMemoryAllocateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .pNext = &export_info,
        .allocationSize = buf_reqs.size,
        .memoryTypeIndex = dmabuf_mem_idx,
    };
    var dmabuf_memory: vk.VkDeviceMemory = undefined;
    if (dev.dispatch.allocateMemory(dev.device, &buf_alloc, null, &dmabuf_memory) != vk.VK_SUCCESS) {
        log.err("vkAllocateMemory (Target dmabuf) failed", .{});
        return error.VulkanFailed;
    }
    errdefer dev.dispatch.freeMemory(dev.device, dmabuf_memory, null);
    if (dev.dispatch.bindBufferMemory(dev.device, dmabuf_buffer, dmabuf_memory, 0) != vk.VK_SUCCESS) {
        log.err("vkBindBufferMemory (Target dmabuf) failed", .{});
        return error.VulkanFailed;
    }

    const fd = try exportDmabufFd(dev, dmabuf_memory);
    errdefer std.posix.close(fd);

    return .{
        .device = dev,
        .platform = opts.platform,
        .tiling = .legacy_copy,
        .image = image,
        .image_memory = image_memory,
        .view = view,
        .dmabuf_buffer = dmabuf_buffer,
        .dmabuf_memory = dmabuf_memory,
        .format = opts.format,
        .width = opts.width,
        .height = opts.height,
        .fd = fd,
        .drm_format = drm_format,
        .drm_modifier = DRM_FORMAT_MOD_LINEAR,
        .stride = stride,
    };
}

fn createView(
    dev: *const Device,
    image: vk.VkImage,
    format: vk.VkFormat,
) Error!vk.VkImageView {
    const view_info: vk.VkImageViewCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .image = image,
        .viewType = vk.VK_IMAGE_VIEW_TYPE_2D,
        .format = format,
        .components = .{
            .r = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
            .g = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
            .b = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
            .a = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
        },
        .subresourceRange = .{
            .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    };
    var view: vk.VkImageView = undefined;
    if (dev.dispatch.createImageView(dev.device, &view_info, null, &view) != vk.VK_SUCCESS) {
        log.err("vkCreateImageView (Target) failed", .{});
        return error.VulkanFailed;
    }
    return view;
}

fn exportDmabufFd(dev: *const Device, memory: vk.VkDeviceMemory) Error!i32 {
    const fd_info: vk.VkMemoryGetFdInfoKHR = .{
        .sType = vk.VK_STRUCTURE_TYPE_MEMORY_GET_FD_INFO_KHR,
        .pNext = null,
        .memory = memory,
        .handleType = vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
    };
    var fd: c_int = -1;
    if (dev.dispatch.getMemoryFdKHR(dev.device, &fd_info, &fd) != vk.VK_SUCCESS or fd < 0) {
        log.err("vkGetMemoryFdKHR (Target) failed: fd={}", .{fd});
        return error.VulkanFailed;
    }
    return fd;
}

pub fn deinit(self: *Self) void {
    const dev = self.device;
    if (self.fd >= 0) std.posix.close(self.fd);
    if (self.dmabuf_buffer) |b| dev.dispatch.destroyBuffer(dev.device, b, null);
    if (self.dmabuf_memory) |m| dev.dispatch.freeMemory(dev.device, m, null);
    dev.dispatch.destroyImageView(dev.device, self.view, null);
    dev.dispatch.destroyImage(dev.device, self.image, null);
    dev.dispatch.freeMemory(dev.device, self.image_memory, null);
    self.* = undefined;
}

/// Record the end-of-frame barrier(s) that make the rendered pixels
/// visible to the host's later mmap read. Dispatches on `self.tiling`:
///
///   - `.direct`: just an image layout/memory barrier — the render
///     image's own memory is the dmabuf, so we transition
///     `GENERAL → GENERAL` with `COLOR_ATTACHMENT_WRITE → HOST_READ`
///     visibility (`COLOR_ATTACHMENT_OUTPUT → HOST` stages). The
///     LINEAR-modifier image stays in GENERAL throughout — it's both
///     the render target and the host-mapped surface.
///
///   - `.legacy_copy`: the original behavior — transition the
///     render image to `TRANSFER_SRC_OPTIMAL`, `vkCmdCopyImageToBuffer`
///     into the dmabuf buffer, buffer-memory barrier for HOST_READ
///     visibility.
///
/// Call this AFTER all RenderPass work has been recorded but BEFORE
/// `vkEndCommandBuffer`.
pub fn recordPresentBarrier(self: *Self, cb: vk.VkCommandBuffer) void {
    switch (self.tiling) {
        .direct => self.recordDirectBarrier(cb),
        .legacy_copy => self.recordCopyToDmabuf(cb),
    }
}

fn recordDirectBarrier(self: *Self, cb: vk.VkCommandBuffer) void {
    const dev = self.device;

    // Image stays in GENERAL — it's the render target AND the
    // host-mapped surface. We only need a memory barrier so the host's
    // mmap read sees the writes from the COLOR_ATTACHMENT_OUTPUT stage.
    const img_barrier: vk.VkImageMemoryBarrier = .{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = vk.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        .dstAccessMask = vk.VK_ACCESS_HOST_READ_BIT,
        .oldLayout = vk.VK_IMAGE_LAYOUT_GENERAL,
        .newLayout = vk.VK_IMAGE_LAYOUT_GENERAL,
        .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
        .image = self.image,
        .subresourceRange = .{
            .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    };
    dev.dispatch.cmdPipelineBarrier(
        cb,
        vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        vk.VK_PIPELINE_STAGE_HOST_BIT,
        0,
        0, null,
        0, null,
        1, &img_barrier,
    );

    self.layout = vk.VK_IMAGE_LAYOUT_GENERAL;
}

fn recordCopyToDmabuf(self: *Self, cb: vk.VkCommandBuffer) void {
    const dev = self.device;

    // Image: GENERAL → TRANSFER_SRC_OPTIMAL (the RenderPass leaves us
    // in GENERAL on complete, but if it was UNDEFINED for some reason
    // we still need a valid transition; UNDEFINED is also legal).
    const img_barrier: vk.VkImageMemoryBarrier = .{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = vk.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        .dstAccessMask = vk.VK_ACCESS_TRANSFER_READ_BIT,
        .oldLayout = vk.VK_IMAGE_LAYOUT_GENERAL,
        .newLayout = vk.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
        .image = self.image,
        .subresourceRange = .{
            .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    };
    dev.dispatch.cmdPipelineBarrier(
        cb,
        vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        vk.VK_PIPELINE_STAGE_TRANSFER_BIT,
        0,
        0, null,
        0, null,
        1, &img_barrier,
    );

    // Copy image → buffer. BGRA8, packed (stride = width*4).
    const region: vk.VkBufferImageCopy = .{
        .bufferOffset = 0,
        .bufferRowLength = 0, // 0 = tightly packed (uses imageExtent.width)
        .bufferImageHeight = 0,
        .imageSubresource = .{
            .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
            .mipLevel = 0,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
        .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
        .imageExtent = .{ .width = self.width, .height = self.height, .depth = 1 },
    };
    dev.dispatch.cmdCopyImageToBuffer(
        cb,
        self.image,
        vk.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        self.dmabuf_buffer.?,
        1,
        &region,
    );

    // Memory barrier so the host's later mmap read sees the bytes.
    // HOST_READ_BIT is the destination access; HOST_BIT is the
    // destination stage. (External fd consumers may need an explicit
    // sync2 release barrier, but for an mmap-based read after a
    // fence-wait this is sufficient on the GPU side.)
    const buf_barrier: vk.VkBufferMemoryBarrier = .{
        .sType = vk.VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT,
        .dstAccessMask = vk.VK_ACCESS_HOST_READ_BIT,
        .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
        .buffer = self.dmabuf_buffer.?,
        .offset = 0,
        .size = vk.VK_WHOLE_SIZE,
    };
    dev.dispatch.cmdPipelineBarrier(
        cb,
        vk.VK_PIPELINE_STAGE_TRANSFER_BIT,
        vk.VK_PIPELINE_STAGE_HOST_BIT,
        0,
        0, null,
        1, &buf_barrier,
        0, null,
    );

    // Track the new image layout so the next frame's RenderPass.begin
    // doesn't see stale state (it currently transitions from UNDEFINED
    // unconditionally, but be defensive).
    self.layout = vk.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
}

pub fn present(self: *const Self) void {
    // Prefer the per-surface platform — its `userdata` points at THIS
    // surface's GhosttySurface, so present reaches the right window.
    // Fall back to the device's singleton copy when no platform was
    // attached (only the smoke test does this).
    const platform = if (self.platform) |p| p else self.device.platform;
    // `image_backed` is the host's signal that this fd is importable
    // by a 2D-image consumer (Wayland linux-dmabuf-v1, Vulkan
    // external image, etc.). True in `.direct` mode where the fd was
    // exported from a VkImage; false in `.legacy_copy` where it was
    // exported from a VkBuffer and can only be read via mmap.
    platform.present(
        platform.userdata,
        self.fd,
        self.drm_format,
        self.drm_modifier,
        self.width,
        self.height,
        self.stride,
        self.tiling == .direct,
    );
}

fn vkFormatToDrmFourcc(format: vk.VkFormat) Error!u32 {
    const fourcc = struct {
        fn make(a: u8, b: u8, c: u8, d: u8) u32 {
            return (@as(u32, a)) |
                (@as(u32, b) << 8) |
                (@as(u32, c) << 16) |
                (@as(u32, d) << 24);
        }
    };
    return switch (format) {
        vk.VK_FORMAT_B8G8R8A8_UNORM,
        vk.VK_FORMAT_B8G8R8A8_SRGB,
        => fourcc.make('A', 'R', '2', '4'),
        vk.VK_FORMAT_R8G8B8A8_UNORM,
        vk.VK_FORMAT_R8G8B8A8_SRGB,
        => fourcc.make('A', 'B', '2', '4'),
        else => error.UnsupportedFormat,
    };
}

test {
    std.testing.refAllDecls(@This());
}
