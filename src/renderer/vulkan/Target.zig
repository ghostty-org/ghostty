//! Render target: an exportable `VkImage` backed by linear-tiled,
//! externally-shareable `VkDeviceMemory` whose dmabuf fd is the
//! payload of `ghostty_platform_vulkan_s.present`.
//!
//! This is what makes the whole Vulkan port worthwhile: instead of
//! reading the frame back into a `QImage` like the OpenGL path does,
//! the host (Qt RHI via `QRhiTexture`) imports our memory directly
//! and composites it in-GPU. Zero-copy, no readback.
//!
//! Layout: **linear tiling** for v1. Linear is the safest cross-
//! driver choice for dmabuf consumers — every Wayland compositor,
//! every Qt RHI backend, every reader can accept linear without
//! modifier negotiation. The cost is reduced rasterization perf vs
//! `VK_IMAGE_TILING_OPTIMAL`. For a terminal at ~60Hz with a few
//! megapixels of fill, linear is fine. Driver-chosen DRM format
//! modifiers (the "optimal+exportable" path via
//! `VK_EXT_image_drm_format_modifier`) is a contained follow-up.
//!
//! Ownership: libghostty owns the `VkImage`, `VkDeviceMemory`, and
//! the dmabuf fd for the lifetime of the `Target`. The fd is passed
//! to the host via `present` as a borrow; the host must `dup()` if
//! it needs to hold it past the call. `deinit` closes the fd and
//! frees the memory.
//!
//! Counterpart: `src/renderer/opengl/Target.zig`.

const Self = @This();

const std = @import("std");
const vk = @import("vulkan").c;

const Device = @import("Device.zig");

const log = std.log.scoped(.vulkan);

/// DRM modifier sentinel for "linear, no tiling". Matches
/// `DRM_FORMAT_MOD_LINEAR` from `<drm/drm_fourcc.h>`. Hardcoded so we
/// don't pull in libdrm headers just for a single constant.
pub const DRM_FORMAT_MOD_LINEAR: u64 = 0;

pub const Options = struct {
    device: *const Device,

    /// Color format. The DRM fourcc the host receives is derived
    /// from this — see `vkFormatToDrmFourcc` below.
    format: vk.VkFormat,

    /// Render target dimensions, in pixels.
    width: u32,
    height: u32,

    /// Extra `VkImageUsageFlagBits` beyond the defaults
    /// (`COLOR_ATTACHMENT_BIT | SAMPLED_BIT`). Rarely needed; left
    /// as an escape hatch for things like a transfer source for
    /// debug captures.
    extra_usage: vk.VkImageUsageFlags = 0,
};

pub const Error = error{
    /// A `vkCreate*` / `vkAllocate*` / `vkBind*` / `vkGetMemoryFdKHR`
    /// returned a non-success status.
    VulkanFailed,
    /// `Device.findMemoryType` couldn't find a memory type matching
    /// the image's requirements and the export memory flag bit.
    NoSuitableMemoryType,
    /// The provided `VkFormat` doesn't map to a known DRM fourcc.
    /// Currently the renderer only ever uses
    /// `VK_FORMAT_B8G8R8A8_UNORM` / `_R8G8B8A8_UNORM` so this is a
    /// guard against config drift rather than a real failure mode.
    UnsupportedFormat,
};

device: *const Device,

image: vk.VkImage,
memory: vk.VkDeviceMemory,
view: vk.VkImageView,

format: vk.VkFormat,
width: u32,
height: u32,

/// dmabuf fd. Owned by `Target` until `deinit`; the host must
/// `dup()` if it wants to hold it past a `present` call.
fd: i32,

/// DRM fourcc the host should interpret the dmabuf as. Derived from
/// `format` at construction time so the apprt callback can pass it
/// straight through.
drm_format: u32,

/// DRM modifier. Always `DRM_FORMAT_MOD_LINEAR` for v1.
drm_modifier: u64,

/// Row stride in bytes — `vkGetImageSubresourceLayout` tells us the
/// driver's actual rowPitch (which may include alignment padding).
/// The host needs this for the dmabuf import.
stride: u32,

/// Current image layout, mirroring the same field on `Texture`.
/// Starts at `UNDEFINED`; the renderer transitions it as needed
/// across the frame.
layout: vk.VkImageLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,

pub fn init(opts: Options) Error!Self {
    const dev = opts.device;
    const drm_format = try vkFormatToDrmFourcc(opts.format);

    // COLOR_ATTACHMENT — we render into this via dynamic rendering.
    // SAMPLED — the renderer's custom-shader path samples the target.
    // TRANSFER_SRC — readback for debug / screenshot tooling.
    const usage = @as(vk.VkImageUsageFlags, vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT) |
        vk.VK_IMAGE_USAGE_SAMPLED_BIT |
        vk.VK_IMAGE_USAGE_TRANSFER_SRC_BIT |
        opts.extra_usage;

    // ---- 1. VkImage (with external-memory chain) ----------------
    const external_memory_image_info: vk.VkExternalMemoryImageCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO,
        .pNext = null,
        .handleTypes = vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
    };
    const image_info: vk.VkImageCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .pNext = &external_memory_image_info,
        .flags = 0,
        .imageType = vk.VK_IMAGE_TYPE_2D,
        .format = opts.format,
        .extent = .{ .width = opts.width, .height = opts.height, .depth = 1 },
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = vk.VK_SAMPLE_COUNT_1_BIT,
        .tiling = vk.VK_IMAGE_TILING_LINEAR,
        .usage = usage,
        .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
        .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
    };
    var image: vk.VkImage = undefined;
    {
        const r = dev.dispatch.createImage(dev.device, &image_info, null, &image);
        if (r != vk.VK_SUCCESS) {
            log.err("vkCreateImage (Target) failed: result={}", .{r});
            return error.VulkanFailed;
        }
    }
    errdefer dev.dispatch.destroyImage(dev.device, image, null);

    // ---- 2. VkDeviceMemory (with export chain) ------------------
    var reqs: vk.VkMemoryRequirements = undefined;
    dev.dispatch.getImageMemoryRequirements(dev.device, image, &reqs);

    // DEVICE_LOCAL is preferred but not required for linear export
    // memory — some drivers only expose HOST_VISIBLE memory types
    // matching the requirements bitmask for linear tiling. We don't
    // care which heap as long as it's exportable.
    const memory_type_index = dev.findMemoryType(reqs.memoryTypeBits, 0) orelse {
        log.err(
            "no exportable memory type for Target (typeBits=0x{x})",
            .{reqs.memoryTypeBits},
        );
        return error.NoSuitableMemoryType;
    };

    const export_info: vk.VkExportMemoryAllocateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO,
        .pNext = null,
        .handleTypes = vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
    };
    const alloc_info: vk.VkMemoryAllocateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .pNext = &export_info,
        .allocationSize = reqs.size,
        .memoryTypeIndex = memory_type_index,
    };
    var memory: vk.VkDeviceMemory = undefined;
    {
        const r = dev.dispatch.allocateMemory(dev.device, &alloc_info, null, &memory);
        if (r != vk.VK_SUCCESS) {
            log.err("vkAllocateMemory (Target) failed: result={}", .{r});
            return error.VulkanFailed;
        }
    }
    errdefer dev.dispatch.freeMemory(dev.device, memory, null);

    {
        const r = dev.dispatch.bindImageMemory(dev.device, image, memory, 0);
        if (r != vk.VK_SUCCESS) {
            log.err("vkBindImageMemory (Target) failed: result={}", .{r});
            return error.VulkanFailed;
        }
    }

    // ---- 3. Export the dmabuf fd --------------------------------
    const fd_info: vk.VkMemoryGetFdInfoKHR = .{
        .sType = vk.VK_STRUCTURE_TYPE_MEMORY_GET_FD_INFO_KHR,
        .pNext = null,
        .memory = memory,
        .handleType = vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
    };
    var fd: c_int = -1;
    {
        const r = dev.dispatch.getMemoryFdKHR(dev.device, &fd_info, &fd);
        if (r != vk.VK_SUCCESS or fd < 0) {
            log.err("vkGetMemoryFdKHR failed: result={} fd={}", .{ r, fd });
            return error.VulkanFailed;
        }
    }
    errdefer std.posix.close(fd);

    // ---- 4. Stride from the driver's subresource layout ---------
    const subresource: vk.VkImageSubresource = .{
        .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
        .mipLevel = 0,
        .arrayLayer = 0,
    };
    var sub_layout: vk.VkSubresourceLayout = undefined;
    dev.dispatch.getImageSubresourceLayout(dev.device, image, &subresource, &sub_layout);

    // ---- 5. VkImageView -----------------------------------------
    const view_info: vk.VkImageViewCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .image = image,
        .viewType = vk.VK_IMAGE_VIEW_TYPE_2D,
        .format = opts.format,
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
    {
        const r = dev.dispatch.createImageView(dev.device, &view_info, null, &view);
        if (r != vk.VK_SUCCESS) {
            log.err("vkCreateImageView (Target) failed: result={}", .{r});
            return error.VulkanFailed;
        }
    }

    return .{
        .device = dev,
        .image = image,
        .memory = memory,
        .view = view,
        .format = opts.format,
        .width = opts.width,
        .height = opts.height,
        .fd = fd,
        .drm_format = drm_format,
        .drm_modifier = DRM_FORMAT_MOD_LINEAR,
        .stride = @intCast(sub_layout.rowPitch),
    };
}

pub fn deinit(self: *Self) void {
    const dev = self.device;
    dev.dispatch.destroyImageView(dev.device, self.view, null);
    dev.dispatch.destroyImage(dev.device, self.image, null);
    dev.dispatch.freeMemory(dev.device, self.memory, null);
    if (self.fd >= 0) std.posix.close(self.fd);
    self.* = undefined;
}

/// Hand the target's dmabuf fd to the host's `present` callback. The
/// fd is a temporary borrow valid only until this call returns; the
/// host must `dup()` if it needs to hold it past then. The
/// underlying memory remains owned by libghostty.
pub fn present(self: *const Self) void {
    self.device.platform.present(
        self.device.platform.userdata,
        self.fd,
        self.drm_format,
        self.drm_modifier,
        self.width,
        self.height,
        self.stride,
    );
}

/// Map a `VkFormat` to its DRM fourcc. Vulkan and DRM disagree on
/// byte order naming: Vulkan format names are in memory order, DRM
/// names are little-endian from MSB. The mapping table here covers
/// the formats the renderer actually targets — extend as new ones
/// are added.
fn vkFormatToDrmFourcc(format: vk.VkFormat) Error!u32 {
    // DRM fourcc helpers — packing 4 ASCII chars LSB-first.
    const fourcc = struct {
        fn make(a: u8, b: u8, c: u8, d: u8) u32 {
            return (@as(u32, a)) |
                (@as(u32, b) << 8) |
                (@as(u32, c) << 16) |
                (@as(u32, d) << 24);
        }
    };
    return switch (format) {
        // Vulkan B,G,R,A in memory = DRM_FORMAT_ARGB8888 ("AR24").
        // This is what Wayland compositors prefer.
        vk.VK_FORMAT_B8G8R8A8_UNORM,
        vk.VK_FORMAT_B8G8R8A8_SRGB,
        => fourcc.make('A', 'R', '2', '4'),
        // Vulkan R,G,B,A in memory = DRM_FORMAT_ABGR8888 ("AB24").
        vk.VK_FORMAT_R8G8B8A8_UNORM,
        vk.VK_FORMAT_R8G8B8A8_SRGB,
        => fourcc.make('A', 'B', '2', '4'),
        else => error.UnsupportedFormat,
    };
}

test {
    std.testing.refAllDecls(@This());
}
