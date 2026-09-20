const Self = @This();

const std = @import("std");
const c = @import("api.zig").c;
const Context = @import("Context.zig");
const bufferpkg = @import("buffer.zig");

pub const PixelFormat = enum { gray, rgba, bgra };

pub const Options = struct {
    context: *Context,
    format: c.VkFormat,
    upload_format: PixelFormat,
    min_filter: c.VkFilter,
    mag_filter: c.VkFilter,
    address_mode: c.VkSamplerAddressMode,
    unnormalized_coordinates: bool = false,
};

context: *Context,
image: c.VkImage,
memory: c.VkDeviceMemory,
view: c.VkImageView,
sampler: c.VkSampler,
width: usize,
height: usize,
format: c.VkFormat,
upload_format: PixelFormat,

pub const Error = anyerror;

pub fn init(opts: Options, width: usize, height: usize, data: ?[]const u8) Error!Self {
    var image_info = std.mem.zeroes(c.VkImageCreateInfo);
    image_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    image_info.imageType = c.VK_IMAGE_TYPE_2D;
    image_info.format = opts.format;
    image_info.extent = .{ .width = @intCast(width), .height = @intCast(height), .depth = 1 };
    image_info.mipLevels = 1;
    image_info.arrayLayers = 1;
    image_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
    image_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
    image_info.usage = c.VK_IMAGE_USAGE_SAMPLED_BIT |
        c.VK_IMAGE_USAGE_TRANSFER_DST_BIT |
        c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT |
        c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    image_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
    image_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;

    var image: c.VkImage = null;
    try Context.result(c.vkCreateImage(opts.context.device, &image_info, null, &image));
    errdefer c.vkDestroyImage(opts.context.device, image, null);

    var requirements = std.mem.zeroes(c.VkMemoryRequirements);
    c.vkGetImageMemoryRequirements(opts.context.device, image, &requirements);
    var alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
    alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    alloc_info.allocationSize = requirements.size;
    alloc_info.memoryTypeIndex = try opts.context.memoryType(
        requirements.memoryTypeBits,
        c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
    );

    var memory: c.VkDeviceMemory = null;
    try Context.result(c.vkAllocateMemory(opts.context.device, &alloc_info, null, &memory));
    errdefer c.vkFreeMemory(opts.context.device, memory, null);
    try Context.result(c.vkBindImageMemory(opts.context.device, image, memory, 0));

    var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
    view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    view_info.image = image;
    view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
    view_info.format = opts.format;
    view_info.components = .{
        .r = c.VK_COMPONENT_SWIZZLE_IDENTITY,
        .g = c.VK_COMPONENT_SWIZZLE_IDENTITY,
        .b = c.VK_COMPONENT_SWIZZLE_IDENTITY,
        .a = c.VK_COMPONENT_SWIZZLE_IDENTITY,
    };
    view_info.subresourceRange = colorRange();

    var view: c.VkImageView = null;
    try Context.result(c.vkCreateImageView(opts.context.device, &view_info, null, &view));
    errdefer c.vkDestroyImageView(opts.context.device, view, null);

    var sampler_info = std.mem.zeroes(c.VkSamplerCreateInfo);
    sampler_info.sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
    sampler_info.magFilter = opts.mag_filter;
    sampler_info.minFilter = opts.min_filter;
    sampler_info.mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_NEAREST;
    sampler_info.addressModeU = opts.address_mode;
    sampler_info.addressModeV = opts.address_mode;
    sampler_info.addressModeW = opts.address_mode;
    sampler_info.maxLod = 0;
    sampler_info.unnormalizedCoordinates = if (opts.unnormalized_coordinates) c.VK_TRUE else c.VK_FALSE;

    var sampler: c.VkSampler = null;
    try Context.result(c.vkCreateSampler(opts.context.device, &sampler_info, null, &sampler));
    errdefer c.vkDestroySampler(opts.context.device, sampler, null);

    var self: Self = .{
        .context = opts.context,
        .image = image,
        .memory = memory,
        .view = view,
        .sampler = sampler,
        .width = width,
        .height = height,
        .format = opts.format,
        .upload_format = opts.upload_format,
    };
    errdefer self.deinit();
    try self.initialize(data);
    return self;
}

pub fn deinit(self: Self) void {
    c.vkDestroySampler(self.context.device, self.sampler, null);
    c.vkDestroyImageView(self.context.device, self.view, null);
    c.vkDestroyImage(self.context.device, self.image, null);
    c.vkFreeMemory(self.context.device, self.memory, null);
}

pub fn replaceRegion(self: Self, x: usize, y: usize, width: usize, height: usize, data: []const u8) Error!void {
    const staging = try bufferpkg.Handle.init(.{
        .context = self.context,
        .usage = c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
    }, data.len);
    defer staging.deinit();
    try staging.write(0, data);

    const command_buffer = try self.context.beginCommands();
    var region = std.mem.zeroes(c.VkBufferImageCopy);
    region.imageSubresource = .{
        .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
        .mipLevel = 0,
        .baseArrayLayer = 0,
        .layerCount = 1,
    };
    region.imageOffset = .{ .x = @intCast(x), .y = @intCast(y), .z = 0 };
    region.imageExtent = .{ .width = @intCast(width), .height = @intCast(height), .depth = 1 };
    c.vkCmdCopyBufferToImage(
        command_buffer,
        staging.buffer,
        self.image,
        c.VK_IMAGE_LAYOUT_GENERAL,
        1,
        &region,
    );
    imageBarrier(
        command_buffer,
        self.image,
        c.VK_ACCESS_TRANSFER_WRITE_BIT,
        c.VK_ACCESS_SHADER_READ_BIT,
        c.VK_PIPELINE_STAGE_TRANSFER_BIT,
        c.VK_PIPELINE_STAGE_ALL_GRAPHICS_BIT,
        c.VK_IMAGE_LAYOUT_GENERAL,
        c.VK_IMAGE_LAYOUT_GENERAL,
    );
    try self.context.submitCommands(command_buffer);
}

fn initialize(self: *Self, data: ?[]const u8) !void {
    const command_buffer = try self.context.beginCommands();
    imageBarrier(
        command_buffer,
        self.image,
        0,
        if (data == null) c.VK_ACCESS_SHADER_READ_BIT else c.VK_ACCESS_TRANSFER_WRITE_BIT,
        c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
        if (data == null) c.VK_PIPELINE_STAGE_ALL_GRAPHICS_BIT else c.VK_PIPELINE_STAGE_TRANSFER_BIT,
        c.VK_IMAGE_LAYOUT_UNDEFINED,
        c.VK_IMAGE_LAYOUT_GENERAL,
    );
    try self.context.submitCommands(command_buffer);
    if (data) |bytes| try self.replaceRegion(0, 0, self.width, self.height, bytes);
}

pub fn colorRange() c.VkImageSubresourceRange {
    return .{
        .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
        .baseMipLevel = 0,
        .levelCount = 1,
        .baseArrayLayer = 0,
        .layerCount = 1,
    };
}

pub fn imageBarrier(
    command_buffer: c.VkCommandBuffer,
    image: c.VkImage,
    src_access: c.VkAccessFlags,
    dst_access: c.VkAccessFlags,
    src_stage: c.VkPipelineStageFlags,
    dst_stage: c.VkPipelineStageFlags,
    old_layout: c.VkImageLayout,
    new_layout: c.VkImageLayout,
) void {
    var barrier = std.mem.zeroes(c.VkImageMemoryBarrier);
    barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    barrier.srcAccessMask = src_access;
    barrier.dstAccessMask = dst_access;
    barrier.oldLayout = old_layout;
    barrier.newLayout = new_layout;
    barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
    barrier.image = image;
    barrier.subresourceRange = colorRange();
    c.vkCmdPipelineBarrier(
        command_buffer,
        src_stage,
        dst_stage,
        0,
        0,
        null,
        0,
        null,
        1,
        &barrier,
    );
}
