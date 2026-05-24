//! Wrapper for `VkImage` + `VkDeviceMemory` + `VkImageView`.
//!
//! Holds a 2D image, the backing device-local memory, and a view
//! configured for color sampling. All three handles are libghostty-
//! owned and destroyed in `deinit`.
//!
//! **Data upload is intentionally not implemented yet.** The OpenGL
//! backend uploads inline via `glTexImage2D` / `glTexSubImage2D` —
//! the GPU driver buffers it for us. Vulkan needs an explicit
//! staging buffer + a recorded command buffer + a queue submit +
//! layout barriers, all of which want their own commit alongside
//! a `Buffer.zig` + command-pool infrastructure. Until that lands:
//!
//!   - `init(opts, w, h, data)` panics with a TODO if `data != null`.
//!   - `replaceRegion` panics unconditionally.
//!
//! The handle-management side (create image / allocate memory / bind
//! / create view / destroy) is fully implemented and exercised by
//! callers that just need an unpopulated texture — e.g. the cell
//! render target.
//!
//! Counterpart: `src/renderer/opengl/Texture.zig`.

const Self = @This();

const std = @import("std");
const vk = @import("vulkan").c;

const Device = @import("Device.zig");

const log = std.log.scoped(.vulkan);

/// Texture construction parameters. Vulkan-native rather than mirroring
/// the OpenGL backend's separate `format` / `internal_format` — Vulkan
/// encodes both into one `VkFormat`.
pub const Options = struct {
    device: *const Device,

    /// Pixel format. Common choices:
    ///   - `VK_FORMAT_R8G8B8A8_UNORM`     — color atlases, render target.
    ///   - `VK_FORMAT_R8G8B8A8_SRGB`      — sRGB color atlases.
    ///   - `VK_FORMAT_R8_UNORM`           — grayscale glyph atlas.
    format: vk.VkFormat,

    /// `VkImageUsageFlagBits` for the image. Typical:
    ///   - Atlas:           `SAMPLED | TRANSFER_DST`
    ///   - Render target:   `COLOR_ATTACHMENT | SAMPLED` (+ external
    ///                       memory flags wired in by the export path)
    usage: vk.VkImageUsageFlags,

    /// Aspect mask for the image view. Defaults to color; depth images
    /// would override.
    aspect: vk.VkImageAspectFlags = vk.VK_IMAGE_ASPECT_COLOR_BIT,
};

pub const Error = error{
    /// A `vkCreate*` or `vkAllocate*` returned a non-success status.
    /// Logged with the raw `VkResult`.
    VulkanFailed,
    /// `findMemoryType` couldn't find a `DEVICE_LOCAL` memory type
    /// matching the image's requirements. Effectively unrecoverable
    /// — typical Vulkan devices always expose at least one.
    NoSuitableMemoryType,
};

image: vk.VkImage,
memory: vk.VkDeviceMemory,
view: vk.VkImageView,
format: vk.VkFormat,
extent: vk.VkExtent2D,
device: *const Device,

/// Create a 2D texture. The image is left in `VK_IMAGE_LAYOUT_UNDEFINED`
/// — callers are responsible for transitioning it to the layout they
/// need (typically `TRANSFER_DST_OPTIMAL` for upload then
/// `SHADER_READ_ONLY_OPTIMAL` for sampling).
///
/// Passing non-null `data` currently panics; the upload path lands
/// in a follow-up commit alongside `Buffer.zig` and a command pool.
pub fn init(
    opts: Options,
    width: usize,
    height: usize,
    data: ?[]const u8,
) Error!Self {
    if (data != null) {
        @panic("Texture data upload not yet implemented — see " ++
            "`qt-vulkan-renderer` branch follow-ups for the " ++
            "staging-buffer + command-pool pipeline.");
    }

    const dev = opts.device;

    // ---- 1. VkImage ---------------------------------------------
    const image_info: vk.VkImageCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .imageType = vk.VK_IMAGE_TYPE_2D,
        .format = opts.format,
        .extent = .{
            .width = @intCast(width),
            .height = @intCast(height),
            .depth = 1,
        },
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = vk.VK_SAMPLE_COUNT_1_BIT,
        .tiling = vk.VK_IMAGE_TILING_OPTIMAL,
        .usage = opts.usage,
        .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
        .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
    };
    var image: vk.VkImage = undefined;
    {
        const r = dev.dispatch.createImage(dev.device, &image_info, null, &image);
        if (r != vk.VK_SUCCESS) {
            log.err("vkCreateImage failed: result={}", .{r});
            return error.VulkanFailed;
        }
    }
    errdefer dev.dispatch.destroyImage(dev.device, image, null);

    // ---- 2. VkDeviceMemory --------------------------------------
    var reqs: vk.VkMemoryRequirements = undefined;
    dev.dispatch.getImageMemoryRequirements(dev.device, image, &reqs);

    const memory_type_index = dev.findMemoryType(
        reqs.memoryTypeBits,
        vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
    ) orelse {
        log.err(
            "no DEVICE_LOCAL memory type found for image (typeBits=0x{x})",
            .{reqs.memoryTypeBits},
        );
        return error.NoSuitableMemoryType;
    };

    const alloc_info: vk.VkMemoryAllocateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .pNext = null,
        .allocationSize = reqs.size,
        .memoryTypeIndex = memory_type_index,
    };
    var memory: vk.VkDeviceMemory = undefined;
    {
        const r = dev.dispatch.allocateMemory(dev.device, &alloc_info, null, &memory);
        if (r != vk.VK_SUCCESS) {
            log.err("vkAllocateMemory failed: result={}", .{r});
            return error.VulkanFailed;
        }
    }
    errdefer dev.dispatch.freeMemory(dev.device, memory, null);

    {
        const r = dev.dispatch.bindImageMemory(dev.device, image, memory, 0);
        if (r != vk.VK_SUCCESS) {
            log.err("vkBindImageMemory failed: result={}", .{r});
            return error.VulkanFailed;
        }
    }

    // ---- 3. VkImageView -----------------------------------------
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
            .aspectMask = opts.aspect,
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
            log.err("vkCreateImageView failed: result={}", .{r});
            return error.VulkanFailed;
        }
    }

    return .{
        .image = image,
        .memory = memory,
        .view = view,
        .format = opts.format,
        .extent = .{ .width = @intCast(width), .height = @intCast(height) },
        .device = dev,
    };
}

pub fn deinit(self: Self) void {
    const dev = self.device;
    dev.dispatch.destroyImageView(dev.device, self.view, null);
    dev.dispatch.destroyImage(dev.device, self.image, null);
    dev.dispatch.freeMemory(dev.device, self.memory, null);
}

/// Replace a region of the texture with the provided data. The
/// staging-buffer + command-buffer pipeline this needs hasn't landed
/// yet — currently panics.
pub fn replaceRegion(
    self: Self,
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    data: []const u8,
) Error!void {
    _ = self;
    _ = x;
    _ = y;
    _ = width;
    _ = height;
    _ = data;
    @panic("Texture.replaceRegion not yet implemented — see " ++
        "`qt-vulkan-renderer` branch follow-ups.");
}

test {
    std.testing.refAllDecls(@This());
}
