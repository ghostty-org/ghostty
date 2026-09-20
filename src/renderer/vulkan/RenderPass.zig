const Self = @This();

const std = @import("std");
const c = @import("api.zig").c;
const Context = @import("Context.zig");
const bufferpkg = @import("buffer.zig");
const Pipeline = @import("Pipeline.zig");
const Sampler = @import("Sampler.zig");
const Target = @import("Target.zig");
const Texture = @import("Texture.zig");

pub const Options = struct {
    attachments: []const Attachment,

    pub const Attachment = struct {
        target: union(enum) { texture: Texture, target: Target },
        clear_color: ?[4]f32 = null,
    };
};

pub const Primitive = enum { triangle, triangle_strip };

pub const Step = struct {
    pipeline: Pipeline,
    uniforms: ?bufferpkg.Handle = null,
    buffers: []const ?bufferpkg.Handle = &.{},
    textures: []const ?Texture = &.{},
    samplers: []const ?Sampler = &.{},
    draw: Draw,

    pub const Draw = struct {
        type: Primitive,
        vertex_count: usize,
        instance_count: usize = 1,
    };
};

context: *Context,
command_buffer: c.VkCommandBuffer,
descriptor_pool: c.VkDescriptorPool,
attachment: Options.Attachment,
width: usize,
height: usize,

pub fn begin(
    context: *Context,
    command_buffer: c.VkCommandBuffer,
    descriptor_pool: c.VkDescriptorPool,
    opts: Options,
) Self {
    const attachment = opts.attachments[0];
    const texture: Texture = switch (attachment.target) {
        .texture => |value| value,
        .target => |value| value.texture,
    };

    Texture.imageBarrier(
        command_buffer,
        texture.image,
        c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_TRANSFER_READ_BIT,
        c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        c.VK_PIPELINE_STAGE_ALL_GRAPHICS_BIT | c.VK_PIPELINE_STAGE_TRANSFER_BIT,
        c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        c.VK_IMAGE_LAYOUT_GENERAL,
        c.VK_IMAGE_LAYOUT_GENERAL,
    );

    var color_attachment = std.mem.zeroes(c.VkRenderingAttachmentInfo);
    color_attachment.sType = c.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO;
    color_attachment.imageView = texture.view;
    color_attachment.imageLayout = c.VK_IMAGE_LAYOUT_GENERAL;
    color_attachment.loadOp = if (attachment.clear_color != null) c.VK_ATTACHMENT_LOAD_OP_CLEAR else c.VK_ATTACHMENT_LOAD_OP_LOAD;
    color_attachment.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
    if (attachment.clear_color) |color| {
        color_attachment.clearValue.color.float32 = color;
    }

    var rendering = std.mem.zeroes(c.VkRenderingInfo);
    rendering.sType = c.VK_STRUCTURE_TYPE_RENDERING_INFO;
    rendering.renderArea.extent = .{ .width = @intCast(texture.width), .height = @intCast(texture.height) };
    rendering.layerCount = 1;
    rendering.colorAttachmentCount = 1;
    rendering.pColorAttachments = &color_attachment;
    c.vkCmdBeginRendering(command_buffer, &rendering);

    var viewport = std.mem.zeroes(c.VkViewport);
    viewport.x = 0;
    viewport.y = @floatFromInt(texture.height);
    viewport.width = @floatFromInt(texture.width);
    viewport.height = -@as(f32, @floatFromInt(texture.height));
    viewport.minDepth = 0;
    viewport.maxDepth = 1;
    c.vkCmdSetViewport(command_buffer, 0, 1, &viewport);

    var scissor = std.mem.zeroes(c.VkRect2D);
    scissor.extent = .{ .width = @intCast(texture.width), .height = @intCast(texture.height) };
    c.vkCmdSetScissor(command_buffer, 0, 1, &scissor);

    return .{
        .context = context,
        .command_buffer = command_buffer,
        .descriptor_pool = descriptor_pool,
        .attachment = attachment,
        .width = texture.width,
        .height = texture.height,
    };
}

pub fn step(self: *Self, step_: Step) void {
    if (step_.draw.instance_count == 0) return;
    _ = step_.draw.type;

    var alloc_info = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
    alloc_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
    alloc_info.descriptorPool = self.descriptor_pool;
    alloc_info.descriptorSetCount = 1;
    alloc_info.pSetLayouts = &self.context.descriptor_set_layout;
    var descriptor_set: c.VkDescriptorSet = null;
    Context.result(c.vkAllocateDescriptorSets(self.context.device, &alloc_info, &descriptor_set)) catch return;

    var writes: [4]c.VkWriteDescriptorSet = undefined;
    var buffer_infos: [2]c.VkDescriptorBufferInfo = undefined;
    var image_infos: [2]c.VkDescriptorImageInfo = undefined;
    var write_count: usize = 0;
    var buffer_count: usize = 0;
    var image_count: usize = 0;

    if (step_.uniforms) |buffer| {
        buffer_infos[buffer_count] = .{ .buffer = buffer.buffer, .offset = 0, .range = c.VK_WHOLE_SIZE };
        writes[write_count] = descriptorWrite(descriptor_set, 0, c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER);
        writes[write_count].pBufferInfo = &buffer_infos[buffer_count];
        write_count += 1;
        buffer_count += 1;
    }
    if (step_.buffers.len > 1) if (step_.buffers[1]) |buffer| {
        buffer_infos[buffer_count] = .{ .buffer = buffer.buffer, .offset = 0, .range = c.VK_WHOLE_SIZE };
        writes[write_count] = descriptorWrite(descriptor_set, 1, c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER);
        writes[write_count].pBufferInfo = &buffer_infos[buffer_count];
        write_count += 1;
        buffer_count += 1;
    };
    for (step_.textures, 0..) |texture_, i| if (texture_) |texture| {
        if (i >= image_infos.len) break;
        const sampler = if (i < step_.samplers.len and step_.samplers[i] != null)
            step_.samplers[i].?.sampler
        else
            texture.sampler;
        image_infos[image_count] = .{
            .sampler = sampler,
            .imageView = texture.view,
            .imageLayout = c.VK_IMAGE_LAYOUT_GENERAL,
        };
        writes[write_count] = descriptorWrite(descriptor_set, @intCast(2 + i), c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER);
        writes[write_count].pImageInfo = &image_infos[image_count];
        write_count += 1;
        image_count += 1;
    };
    if (write_count > 0) c.vkUpdateDescriptorSets(self.context.device, @intCast(write_count), &writes, 0, null);

    c.vkCmdBindPipeline(self.command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, step_.pipeline.pipeline);
    c.vkCmdBindDescriptorSets(
        self.command_buffer,
        c.VK_PIPELINE_BIND_POINT_GRAPHICS,
        self.context.pipeline_layout,
        0,
        1,
        &descriptor_set,
        0,
        null,
    );
    if (step_.buffers.len > 0) if (step_.buffers[0]) |vertex| {
        const offset: c.VkDeviceSize = 0;
        c.vkCmdBindVertexBuffers(self.command_buffer, 0, 1, &vertex.buffer, &offset);
    };
    c.vkCmdDraw(
        self.command_buffer,
        @intCast(step_.draw.vertex_count),
        @intCast(step_.draw.instance_count),
        0,
        0,
    );
}

pub fn complete(self: *const Self) void {
    c.vkCmdEndRendering(self.command_buffer);
    const texture: Texture = switch (self.attachment.target) {
        .texture => |value| value,
        .target => |value| value.texture,
    };
    Texture.imageBarrier(
        self.command_buffer,
        texture.image,
        c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_TRANSFER_READ_BIT,
        c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        c.VK_PIPELINE_STAGE_ALL_GRAPHICS_BIT | c.VK_PIPELINE_STAGE_TRANSFER_BIT,
        c.VK_IMAGE_LAYOUT_GENERAL,
        c.VK_IMAGE_LAYOUT_GENERAL,
    );
}

fn descriptorWrite(set: c.VkDescriptorSet, binding: u32, descriptor_type: c.VkDescriptorType) c.VkWriteDescriptorSet {
    var write = std.mem.zeroes(c.VkWriteDescriptorSet);
    write.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    write.dstSet = set;
    write.dstBinding = binding;
    write.descriptorCount = 1;
    write.descriptorType = descriptor_type;
    return write;
}
