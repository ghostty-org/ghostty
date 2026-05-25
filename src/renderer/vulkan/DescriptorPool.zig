//! Wrapper for `VkDescriptorPool` with allocation + per-set helpers.
//!
//! Vulkan descriptor sets are the per-pipeline resource-binding
//! handles: a descriptor set holds references to uniform buffers,
//! sampled images, samplers, etc., that a particular shader stage
//! draws from. They're allocated from a pool, populated via
//! `vkUpdateDescriptorSets`, and bound at draw time with
//! `vkCmdBindDescriptorSets`.
//!
//! Lifetime model: this wrapper assumes the pool outlives all sets
//! allocated from it (caller arranges teardown order). Sets aren't
//! individually freed — destroying the pool reclaims everything.
//! That matches the per-frame pool pattern the renderer will use
//! (reset the pool at frame start; reallocate the sets for that
//! frame).
//!
//! Caps are caller-provided. Pass realistic numbers — over-pooling
//! is fine; under-pooling fails at allocation time.

const Self = @This();

const std = @import("std");
const vk = @import("vulkan").c;

const Device = @import("Device.zig");

const log = std.log.scoped(.vulkan);

pub const Error = error{
    /// `vkCreateDescriptorPool` / `vkAllocateDescriptorSets` returned
    /// a non-success status.
    VulkanFailed,
};

/// Construction caps. `max_sets` is the total number of descriptor
/// sets the pool can ever vend; the per-type counts are individual
/// resource counts pooled across all those sets.
pub const Options = struct {
    device: *const Device,
    max_sets: u32,
    uniform_buffers: u32 = 0,
    combined_image_samplers: u32 = 0,
    storage_buffers: u32 = 0,
};

device: *const Device,
pool: vk.VkDescriptorPool,

pub fn init(opts: Options) Error!Self {
    // Vulkan spec requires `maxSets > 0` and `poolSizeCount > 0` —
    // a pool that vends N sets but doesn't admit any descriptor
    // type would be useless and is rejected by some drivers
    // (loose drivers accept it and fail at allocation time). Catch
    // both shapes here so the caller gets a clear error instead of
    // a downstream allocation failure.
    if (opts.max_sets == 0) {
        log.err("DescriptorPool.init: max_sets must be > 0", .{});
        return error.VulkanFailed;
    }
    if (opts.uniform_buffers == 0 and
        opts.combined_image_samplers == 0 and
        opts.storage_buffers == 0)
    {
        log.err(
            "DescriptorPool.init: at least one per-type cap must be > 0 " ++
                "(uniform_buffers, combined_image_samplers, storage_buffers)",
            .{},
        );
        return error.VulkanFailed;
    }

    // Build a small VkDescriptorPoolSize array from whichever caps
    // are non-zero. Vulkan accepts an array; we cap at 3 entries
    // matching the three types `Options` exposes.
    var sizes: [3]vk.VkDescriptorPoolSize = undefined;
    var n: u32 = 0;
    if (opts.uniform_buffers > 0) {
        sizes[n] = .{
            .type = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = opts.uniform_buffers,
        };
        n += 1;
    }
    if (opts.combined_image_samplers > 0) {
        sizes[n] = .{
            .type = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = opts.combined_image_samplers,
        };
        n += 1;
    }
    if (opts.storage_buffers > 0) {
        sizes[n] = .{
            .type = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = opts.storage_buffers,
        };
        n += 1;
    }

    const info: vk.VkDescriptorPoolCreateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .pNext = null,
        // No FREE_DESCRIPTOR_SET_BIT — we tear down by destroying
        // the pool (or `vkResetDescriptorPool` for the per-frame
        // step pool).
        .flags = 0,
        .maxSets = opts.max_sets,
        .poolSizeCount = n,
        .pPoolSizes = &sizes,
    };
    var pool: vk.VkDescriptorPool = undefined;
    const r = opts.device.dispatch.createDescriptorPool(
        opts.device.device,
        &info,
        null,
        &pool,
    );
    if (r != vk.VK_SUCCESS) {
        log.err("vkCreateDescriptorPool failed: result={}", .{r});
        return error.VulkanFailed;
    }
    return .{ .device = opts.device, .pool = pool };
}

pub fn deinit(self: *Self) void {
    self.device.dispatch.destroyDescriptorPool(
        self.device.device,
        self.pool,
        null,
    );
    self.* = undefined;
}

/// Allocate a single descriptor set against the provided layout.
/// On success the set is uninitialized — populate it with
/// `vkUpdateDescriptorSets` before binding.
pub fn allocate(
    self: *Self,
    layout: vk.VkDescriptorSetLayout,
) Error!vk.VkDescriptorSet {
    var layouts = [_]vk.VkDescriptorSetLayout{layout};
    const info: vk.VkDescriptorSetAllocateInfo = .{
        .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .pNext = null,
        .descriptorPool = self.pool,
        .descriptorSetCount = 1,
        .pSetLayouts = &layouts,
    };
    var set: vk.VkDescriptorSet = undefined;
    const r = self.device.dispatch.allocateDescriptorSets(
        self.device.device,
        &info,
        &set,
    );
    if (r != vk.VK_SUCCESS) {
        log.err("vkAllocateDescriptorSets failed: result={}", .{r});
        return error.VulkanFailed;
    }
    return set;
}

test {
    std.testing.refAllDecls(@This());
}
