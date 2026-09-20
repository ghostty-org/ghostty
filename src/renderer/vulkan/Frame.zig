const Self = @This();

const std = @import("std");
const c = @import("api.zig").c;
const Context = @import("Context.zig");
const RenderPass = @import("RenderPass.zig");
const Target = @import("Target.zig");
const Vulkan = @import("../Vulkan.zig");
const Renderer = @import("../generic.zig").Renderer(Vulkan);
const Health = @import("../../renderer.zig").Health;

const log = std.log.scoped(.vulkan);

pub const Options = struct {};

context: *Context,
renderer: *Renderer,
target: *Target,
command_buffer: c.VkCommandBuffer,
descriptor_pool: c.VkDescriptorPool,

pub fn begin(opts: Options, renderer: *Renderer, target: *Target) !Self {
    _ = opts;
    const context = renderer.api.context;
    const command_buffer = try context.beginCommands();
    errdefer c.vkFreeCommandBuffers(context.device, context.command_pool, 1, &command_buffer);

    const max_sets = 4096;
    const pool_sizes = [_]c.VkDescriptorPoolSize{
        .{ .type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = max_sets },
        .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = max_sets },
        .{ .type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = max_sets * 2 },
    };
    var pool_info = std.mem.zeroes(c.VkDescriptorPoolCreateInfo);
    pool_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    pool_info.maxSets = max_sets;
    pool_info.poolSizeCount = pool_sizes.len;
    pool_info.pPoolSizes = &pool_sizes;
    var descriptor_pool: c.VkDescriptorPool = null;
    try Context.result(c.vkCreateDescriptorPool(context.device, &pool_info, null, &descriptor_pool));

    return .{
        .context = context,
        .renderer = renderer,
        .target = target,
        .command_buffer = command_buffer,
        .descriptor_pool = descriptor_pool,
    };
}

pub inline fn renderPass(self: *const Self, attachments: []const RenderPass.Options.Attachment) RenderPass {
    return .begin(self.context, self.command_buffer, self.descriptor_pool, .{ .attachments = attachments });
}

pub fn complete(self: *Self, sync: bool) void {
    _ = sync;
    self.target.recordReadback(self.command_buffer);
    self.context.submitCommands(self.command_buffer) catch |err| {
        log.warn("failed to submit frame err={}", .{err});
        c.vkDestroyDescriptorPool(self.context.device, self.descriptor_pool, null);
        self.renderer.frameCompleted(.unhealthy);
        return;
    };
    c.vkDestroyDescriptorPool(self.context.device, self.descriptor_pool, null);

    const frame = self.renderer.api.present(self.target.*) catch |err| {
        log.warn("failed to present frame err={}", .{err});
        self.renderer.frameCompleted(.unhealthy);
        return;
    };
    self.renderer.pushFrame(frame);
    _ = self.renderer.surface_mailbox.push(.redraw, .{ .forever = {} });
    self.renderer.frameCompleted(Health.healthy);
}
