//! Wrapper for `VkImage` + `VkDeviceMemory` + `VkImageView` with a
//! staging-buffer upload path.
//!
//! Holds a 2D image, the backing device-local memory, and a view
//! configured for color sampling. All three handles are libghostty-
//! owned and destroyed in `deinit`.
//!
//! Uploads go through a temporary `Buffer(u8)` staging buffer
//! (`HOST_VISIBLE | HOST_COHERENT | TRANSFER_SRC`) and a per-call
//! `CommandPool` that drives the layout-transition →
//! `vkCmdCopyBufferToImage` → layout-transition sequence. Both
//! resources are destroyed by the time `replaceRegion` returns — the
//! upload is synchronous from the caller's perspective. That's the
//! right tradeoff for atlas resizes (rare; the renderer can afford
//! the stall) but won't fit the eventual per-frame upload path,
//! which will reuse a long-lived `CommandPool` and fence-paced
//! submission.
//!
//! Layout tracking: a single `layout: VkImageLayout` field records
//! whether the image currently sits in `UNDEFINED` (fresh) or
//! `SHADER_READ_ONLY_OPTIMAL` (after at least one upload). The
//! barrier sequence in `replaceRegion` reads this field to pick the
//! right `srcAccessMask` / `srcStageMask`.
//!
//! Counterpart: `src/renderer/opengl/Texture.zig`.

const Self = @This();

const std = @import("std");
const vk = @import("vulkan").c;

const Device = @import("Device.zig");
const CommandPool = @import("CommandPool.zig");
const bufferpkg = @import("buffer.zig");

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
    /// `TRANSFER_DST_BIT` is forced on at create time so the upload
    /// path always works — callers don't have to remember.
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
/// Aspect mask the image was created with (e.g. COLOR_BIT for
/// renderable textures, DEPTH_BIT for depth attachments). Stored
/// so per-frame `replaceRegion` barrier/copy use the same aspect
/// the image view was made with — hardcoding COLOR_BIT here was a
/// silent validation error for any non-color caller.
aspect: vk.VkImageAspectFlags,
width: usize,
height: usize,
device: *const Device,

/// Current image layout. Starts at `UNDEFINED`; `replaceRegion`
/// drives it to `SHADER_READ_ONLY_OPTIMAL` on the first call and
/// keeps it there afterwards. Read by the barrier sequence in
/// `replaceRegion` to pick the right transition source.
layout: vk.VkImageLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,

/// Create a 2D texture. With non-null `data`, the image is uploaded
/// and ends in `SHADER_READ_ONLY_OPTIMAL`. With null `data`, the
/// image is left in `UNDEFINED` — the caller transitions it later
/// (typically via `replaceRegion` or as a render target).
pub fn init(
    opts: Options,
    width: usize,
    height: usize,
    data: ?[]const u8,
) Error!Self {
    const dev = opts.device;

    // ---- 1. VkImage ---------------------------------------------
    // Force TRANSFER_DST_BIT so `replaceRegion` always works without
    // callers having to remember to set it.
    const usage = opts.usage | @as(vk.VkImageUsageFlags, vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT);
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
    errdefer dev.dispatch.destroyImageView(dev.device, view, null);

    var self: Self = .{
        .image = image,
        .memory = memory,
        .view = view,
        .format = opts.format,
        .aspect = opts.aspect,
        .width = width,
        .height = height,
        .device = dev,
    };

    if (data) |d| try self.replaceRegion(0, 0, width, height, d);
    return self;
}

pub fn deinit(self: Self) void {
    const dev = self.device;
    dev.dispatch.destroyImageView(dev.device, self.view, null);
    dev.dispatch.destroyImage(dev.device, self.image, null);
    dev.dispatch.freeMemory(dev.device, self.memory, null);
}

/// Replace a region of the texture with the provided data. Performs:
///   1. Allocate a host-coherent staging buffer holding `data`.
///   2. One-shot command buffer:
///      a. Barrier: current layout → TRANSFER_DST_OPTIMAL.
///      b. `vkCmdCopyBufferToImage`.
///      c. Barrier: TRANSFER_DST_OPTIMAL → SHADER_READ_ONLY_OPTIMAL.
///   3. Submit + `vkQueueWaitIdle`.
///   4. Free staging buffer + command pool.
///
/// On success, `self.layout` is `SHADER_READ_ONLY_OPTIMAL`.
pub fn replaceRegion(
    self: *Self,
    x: usize,
    y: usize,
    width: usize,
    height: usize,
    data: []const u8,
) Error!void {
    if (data.len == 0) return;
    const dev = self.device;

    // ---- staging buffer -----------------------------------------
    var staging = try bufferpkg.Buffer(u8).initFill(.{
        .device = dev,
        .usage = vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
    }, data);
    // `destroyImmediate` instead of `deinit`: replaceRegion runs
    // synchronously on the calling thread (typically the main /
    // app-init thread, NOT the renderer thread), and
    // `OneShot.endAndSubmit` below calls `vkQueueWaitIdle` so the
    // staging buffer is provably done with the GPU before this
    // defer fires. Routing it into `Vulkan.buffer_pool` from a
    // non-renderer thread would leak it forever — the pool's
    // `cycle()` runs only on the renderer thread.
    defer staging.destroyImmediate();

    // ---- command pool (one-shot) --------------------------------
    var pool = try CommandPool.init(dev);
    defer pool.deinit();
    const session = try pool.beginOneShot();

    // ---- barrier: current → TRANSFER_DST_OPTIMAL ----------------
    const old_layout = self.layout;
    const src_access: vk.VkAccessFlags = switch (old_layout) {
        vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL => vk.VK_ACCESS_SHADER_READ_BIT,
        else => 0,
    };
    const src_stage: vk.VkPipelineStageFlags = switch (old_layout) {
        vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL =>
            vk.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
        else => vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
    };
    {
        const barrier: vk.VkImageMemoryBarrier = .{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = src_access,
            .dstAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT,
            .oldLayout = old_layout,
            .newLayout = vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .image = self.image,
            .subresourceRange = .{
                .aspectMask = self.aspect,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };
        dev.dispatch.cmdPipelineBarrier(
            session.cb,
            src_stage,
            vk.VK_PIPELINE_STAGE_TRANSFER_BIT,
            0, // dependencyFlags
            0, null, // memory barriers
            0, null, // buffer memory barriers
            1, &barrier,
        );
    }

    // ---- vkCmdCopyBufferToImage ---------------------------------
    {
        const region: vk.VkBufferImageCopy = .{
            .bufferOffset = 0,
            .bufferRowLength = 0, // tightly packed
            .bufferImageHeight = 0,
            .imageSubresource = .{
                .aspectMask = self.aspect,
                .mipLevel = 0,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .imageOffset = .{
                .x = @intCast(x),
                .y = @intCast(y),
                .z = 0,
            },
            .imageExtent = .{
                .width = @intCast(width),
                .height = @intCast(height),
                .depth = 1,
            },
        };
        dev.dispatch.cmdCopyBufferToImage(
            session.cb,
            staging.buffer,
            self.image,
            vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            1,
            &region,
        );
    }

    // ---- barrier: TRANSFER_DST → SHADER_READ_ONLY ---------------
    {
        const barrier: vk.VkImageMemoryBarrier = .{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT,
            .dstAccessMask = vk.VK_ACCESS_SHADER_READ_BIT,
            .oldLayout = vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .newLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .image = self.image,
            .subresourceRange = .{
                .aspectMask = self.aspect,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };
        dev.dispatch.cmdPipelineBarrier(
            session.cb,
            vk.VK_PIPELINE_STAGE_TRANSFER_BIT,
            vk.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
            0,
            0, null,
            0, null,
            1, &barrier,
        );
    }

    try session.endAndSubmit();
    self.layout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
}

test {
    std.testing.refAllDecls(@This());
}
