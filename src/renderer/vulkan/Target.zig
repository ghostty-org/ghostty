const Self = @This();

const std = @import("std");
const c = @import("api.zig").c;
const Context = @import("Context.zig");
const Texture = @import("Texture.zig");
const bufferpkg = @import("buffer.zig");
const Dmabuf = @import("../Dmabuf.zig");

const log = std.log.scoped(.vulkan);
const drm_format_abgr8888: u32 = @as(u32, 'A') |
    (@as(u32, 'B') << 8) |
    (@as(u32, '2') << 16) |
    (@as(u32, '4') << 24);
const drm_format_mod_linear: u64 = 0;

pub const Options = struct {
    context: *Context,
    width: usize,
    height: usize,
    format: c.VkFormat,
};

context: *Context,
texture: Texture,
readback: bufferpkg.Handle,
export_image: ?ExportImage,
width: usize,
height: usize,

pub fn init(opts: Options) !Self {
    const texture = try Texture.init(.{
        .context = opts.context,
        .format = opts.format,
        .upload_format = .rgba,
        .min_filter = c.VK_FILTER_LINEAR,
        .mag_filter = c.VK_FILTER_LINEAR,
        .address_mode = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
    }, opts.width, opts.height, null);
    errdefer texture.deinit();

    const readback = try bufferpkg.Handle.init(.{
        .context = opts.context,
        .usage = c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
    }, opts.width * opts.height * 4);
    errdefer readback.deinit();

    const export_image: ?ExportImage = if (opts.context.supports_dmabuf)
        ExportImage.init(opts.context, opts.width, opts.height, opts.format) catch |err| fallback: {
            log.warn("DMA-BUF export image unavailable, using memory presentation err={}", .{err});
            break :fallback null;
        }
    else
        null;
    errdefer if (export_image) |value| value.deinit();

    return .{
        .context = opts.context,
        .texture = texture,
        .readback = readback,
        .export_image = export_image,
        .width = opts.width,
        .height = opts.height,
    };
}

pub fn deinit(self: *Self) void {
    if (self.export_image) |value| value.deinit();
    self.readback.deinit();
    self.texture.deinit();
}

pub fn recordReadback(self: *const Self, command_buffer: c.VkCommandBuffer) void {
    Texture.imageBarrier(
        command_buffer,
        self.texture.image,
        c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        c.VK_ACCESS_TRANSFER_READ_BIT,
        c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        c.VK_PIPELINE_STAGE_TRANSFER_BIT,
        c.VK_IMAGE_LAYOUT_GENERAL,
        c.VK_IMAGE_LAYOUT_GENERAL,
    );

    var region = std.mem.zeroes(c.VkBufferImageCopy);
    region.imageSubresource = .{
        .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
        .mipLevel = 0,
        .baseArrayLayer = 0,
        .layerCount = 1,
    };
    region.imageExtent = .{
        .width = @intCast(self.width),
        .height = @intCast(self.height),
        .depth = 1,
    };
    c.vkCmdCopyImageToBuffer(
        command_buffer,
        self.texture.image,
        c.VK_IMAGE_LAYOUT_GENERAL,
        self.readback.buffer,
        1,
        &region,
    );

    if (self.export_image) |export_image| {
        Texture.imageBarrier(
            command_buffer,
            export_image.image,
            c.VK_ACCESS_MEMORY_READ_BIT,
            c.VK_ACCESS_TRANSFER_WRITE_BIT,
            c.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
            c.VK_PIPELINE_STAGE_TRANSFER_BIT,
            c.VK_IMAGE_LAYOUT_GENERAL,
            c.VK_IMAGE_LAYOUT_GENERAL,
        );
        var image_copy = std.mem.zeroes(c.VkImageCopy);
        image_copy.srcSubresource = .{
            .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
            .mipLevel = 0,
            .baseArrayLayer = 0,
            .layerCount = 1,
        };
        image_copy.dstSubresource = image_copy.srcSubresource;
        image_copy.extent = .{
            .width = @intCast(self.width),
            .height = @intCast(self.height),
            .depth = 1,
        };
        c.vkCmdCopyImage(
            command_buffer,
            self.texture.image,
            c.VK_IMAGE_LAYOUT_GENERAL,
            export_image.image,
            c.VK_IMAGE_LAYOUT_GENERAL,
            1,
            &image_copy,
        );
        Texture.imageBarrier(
            command_buffer,
            export_image.image,
            c.VK_ACCESS_TRANSFER_WRITE_BIT,
            c.VK_ACCESS_MEMORY_READ_BIT,
            c.VK_PIPELINE_STAGE_TRANSFER_BIT,
            c.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
            c.VK_IMAGE_LAYOUT_GENERAL,
            c.VK_IMAGE_LAYOUT_GENERAL,
        );
    }

    var barrier = std.mem.zeroes(c.VkBufferMemoryBarrier);
    barrier.sType = c.VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER;
    barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
    barrier.dstAccessMask = c.VK_ACCESS_HOST_READ_BIT;
    barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
    barrier.buffer = self.readback.buffer;
    barrier.offset = 0;
    barrier.size = c.VK_WHOLE_SIZE;
    c.vkCmdPipelineBarrier(
        command_buffer,
        c.VK_PIPELINE_STAGE_TRANSFER_BIT,
        c.VK_PIPELINE_STAGE_HOST_BIT,
        0,
        0,
        null,
        1,
        &barrier,
        0,
        null,
    );
}

pub fn readPixelsAlloc(self: *const Self, alloc: std.mem.Allocator) ![]u8 {
    const size = self.width * self.height * 4;
    const pixels = try alloc.alloc(u8, size);
    errdefer alloc.free(pixels);

    var mapped: ?*anyopaque = null;
    try Context.result(c.vkMapMemory(
        self.context.device,
        self.readback.memory,
        0,
        size,
        0,
        &mapped,
    ));
    defer c.vkUnmapMemory(self.context.device, self.readback.memory);
    const src: [*]const u8 = @ptrCast(mapped.?);
    @memcpy(pixels, src[0..size]);
    return pixels;
}

pub fn exportDmabuf(self: *const Self) !Dmabuf {
    const export_image = self.export_image orelse return error.DmabufUnsupported;

    var fd_info = std.mem.zeroes(c.VkMemoryGetFdInfoKHR);
    fd_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_GET_FD_INFO_KHR;
    fd_info.memory = export_image.memory;
    fd_info.handleType = c.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT;
    var fd: c_int = -1;
    try Context.result(self.context.get_memory_fd.?(self.context.device, &fd_info, &fd));
    errdefer {
        if (fd >= 0) _ = std.posix.system.close(fd);
    }

    var planes: Dmabuf.Planes = .{ .count = 1 };
    planes.fds[0] = fd;
    planes.offsets[0] = @intCast(export_image.layout.offset);
    planes.strides[0] = @intCast(export_image.layout.rowPitch);
    try planes.validate();

    return .{
        .width = @intCast(self.width),
        .height = @intCast(self.height),
        .fourcc = drm_format_abgr8888,
        .modifier = export_image.modifier,
        .premultiplied = true,
        .planes = planes,
    };
}

const ExportImage = struct {
    context: *Context,
    image: c.VkImage,
    memory: c.VkDeviceMemory,
    modifier: u64,
    layout: c.VkSubresourceLayout,

    fn init(context: *Context, width: usize, height: usize, format: c.VkFormat) !ExportImage {
        const modifier = try chooseModifier(context, format);

        var modifier_info = std.mem.zeroes(c.VkImageDrmFormatModifierListCreateInfoEXT);
        modifier_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_LIST_CREATE_INFO_EXT;
        modifier_info.drmFormatModifierCount = 1;
        modifier_info.pDrmFormatModifiers = &modifier;

        var external_info = std.mem.zeroes(c.VkExternalMemoryImageCreateInfo);
        external_info.sType = c.VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO;
        external_info.pNext = &modifier_info;
        external_info.handleTypes = c.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT;

        var image_info = std.mem.zeroes(c.VkImageCreateInfo);
        image_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        image_info.pNext = &external_info;
        image_info.imageType = c.VK_IMAGE_TYPE_2D;
        image_info.format = format;
        image_info.extent = .{ .width = @intCast(width), .height = @intCast(height), .depth = 1 };
        image_info.mipLevels = 1;
        image_info.arrayLayers = 1;
        image_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
        image_info.tiling = c.VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT;
        image_info.usage = c.VK_IMAGE_USAGE_TRANSFER_DST_BIT;
        image_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        image_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;

        var image: c.VkImage = null;
        try Context.result(c.vkCreateImage(context.device, &image_info, null, &image));
        errdefer c.vkDestroyImage(context.device, image, null);

        var requirements = std.mem.zeroes(c.VkMemoryRequirements);
        c.vkGetImageMemoryRequirements(context.device, image, &requirements);

        var dedicated = std.mem.zeroes(c.VkMemoryDedicatedAllocateInfo);
        dedicated.sType = c.VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO;
        dedicated.image = image;
        var export_info = std.mem.zeroes(c.VkExportMemoryAllocateInfo);
        export_info.sType = c.VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO;
        export_info.pNext = &dedicated;
        export_info.handleTypes = c.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT;
        var alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        alloc_info.pNext = &export_info;
        alloc_info.allocationSize = requirements.size;
        alloc_info.memoryTypeIndex = try context.memoryType(requirements.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);

        var memory: c.VkDeviceMemory = null;
        try Context.result(c.vkAllocateMemory(context.device, &alloc_info, null, &memory));
        errdefer c.vkFreeMemory(context.device, memory, null);
        try Context.result(c.vkBindImageMemory(context.device, image, memory, 0));

        var modifier_props = std.mem.zeroes(c.VkImageDrmFormatModifierPropertiesEXT);
        modifier_props.sType = c.VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_PROPERTIES_EXT;
        try Context.result(context.get_image_drm_format_modifier_properties.?(context.device, image, &modifier_props));

        const subresource = c.VkImageSubresource{
            .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
            .mipLevel = 0,
            .arrayLayer = 0,
        };
        var layout = std.mem.zeroes(c.VkSubresourceLayout);
        c.vkGetImageSubresourceLayout(context.device, image, &subresource, &layout);

        const command_buffer = try context.beginCommands();
        Texture.imageBarrier(
            command_buffer,
            image,
            0,
            c.VK_ACCESS_TRANSFER_WRITE_BIT,
            c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
            c.VK_PIPELINE_STAGE_TRANSFER_BIT,
            c.VK_IMAGE_LAYOUT_UNDEFINED,
            c.VK_IMAGE_LAYOUT_GENERAL,
        );
        try context.submitCommands(command_buffer);

        return .{
            .context = context,
            .image = image,
            .memory = memory,
            .modifier = modifier_props.drmFormatModifier,
            .layout = layout,
        };
    }

    fn deinit(self: ExportImage) void {
        c.vkDestroyImage(self.context.device, self.image, null);
        c.vkFreeMemory(self.context.device, self.memory, null);
    }

    fn chooseModifier(context: *Context, format: c.VkFormat) !u64 {
        var list = std.mem.zeroes(c.VkDrmFormatModifierPropertiesListEXT);
        list.sType = c.VK_STRUCTURE_TYPE_DRM_FORMAT_MODIFIER_PROPERTIES_LIST_EXT;
        var props = std.mem.zeroes(c.VkFormatProperties2);
        props.sType = c.VK_STRUCTURE_TYPE_FORMAT_PROPERTIES_2;
        props.pNext = &list;
        c.vkGetPhysicalDeviceFormatProperties2(context.physical_device, format, &props);
        if (list.drmFormatModifierCount == 0) return error.NoDrmModifier;

        const alloc = std.heap.c_allocator;
        const modifiers = try alloc.alloc(c.VkDrmFormatModifierPropertiesEXT, list.drmFormatModifierCount);
        defer alloc.free(modifiers);
        list.pDrmFormatModifierProperties = modifiers.ptr;
        c.vkGetPhysicalDeviceFormatProperties2(context.physical_device, format, &props);

        var fallback: ?u64 = null;
        for (modifiers) |value| {
            if ((value.drmFormatModifierTilingFeatures & c.VK_FORMAT_FEATURE_TRANSFER_DST_BIT) == 0) continue;
            if (fallback == null) fallback = value.drmFormatModifier;
            if (value.drmFormatModifier == drm_format_mod_linear) return value.drmFormatModifier;
        }
        return fallback orelse error.NoTransferDrmModifier;
    }
};
